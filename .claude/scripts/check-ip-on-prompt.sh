#!/bin/bash
# check-ip-on-prompt.sh
# UserPromptSubmit hook：每次用户发送消息前检查 IP
# 触发时机：用户每次提交 prompt 时（无 matcher，全量触发）
# 策略：IP 未变且缓存未过期则跳过查询；IP 变化或超 10min 则重新完整查询

LOG_PREFIX="PROMPT"
source "$(dirname "$0")/ip-guard-lib.sh"

main() {
    # ── 1. 轻量查询：获取当前公网 IP（不含地理信息，开销极小）──
    local current_ip
    current_ip=$(query_current_ip)

    if [ -z "$current_ip" ]; then
        # 无法获取 IP 时放行（fail-safe）
        log "无法获取当前 IP，放行（fail-safe）"
        exit 0
    fi

    local now
    now=$(date +%s)

    # ── 2. 读取并验证缓存 ──
    local cached_ts="" cached_country="" cached_city="" cached_ip=""
    if [ -f "$CACHE_FILE" ]; then
        IFS='|' read -r cached_ts cached_country cached_city cached_ip < "$CACHE_FILE"

        # 验证时间戳为合法数字，异常时强制重新查询
        if ! [[ "$cached_ts" =~ ^[0-9]+$ ]]; then
            log "缓存时间戳异常（${cached_ts}），强制重新查询"
            cached_ts=""
        fi
    fi

    # ── 3. 判断是否可以复用缓存（IP 未变 且 缓存未过期）──
    local elapsed=0
    [ -n "$cached_ts" ] && elapsed=$((now - cached_ts))

    if [ "$current_ip" = "$cached_ip" ] && [ -n "$cached_ts" ] && [ "$elapsed" -lt "$RECHECK_INTERVAL" ]; then
        log "IP 未变（${current_ip}），缓存有效（${elapsed}s < ${RECHECK_INTERVAL}s），跳过查询"

        # 缓存命中时仍需做禁止名单检查
        if is_blocked "$cached_country"; then
            log "拦截（缓存命中）：COUNTRY=${cached_country}"
            echo "[访问受限] 检测到您当前的网络 IP（${current_ip}）位于受限地区（${cached_country}），无法使用 Claude。请切换网络后重试。" >&2
            exit 2
        fi
        exit 0
    fi

    # ── 4. 记录需要完整查询的原因 ──
    if [ -n "$cached_ip" ] && [ "$current_ip" != "$cached_ip" ]; then
        log "IP 变化：${cached_ip} → ${current_ip}，立即重新查询"
    elif [ -n "$cached_ts" ]; then
        log "IP 未变（${current_ip}），缓存过期（${elapsed}s >= ${RECHECK_INTERVAL}s），重新查询"
    else
        log "无有效缓存，执行首次查询（IP=${current_ip}）"
    fi

    # ── 5. 完整地理查询 ──
    local geo_result
    geo_result=$(query_geo "$current_ip")

    if [ $? -ne 0 ] || [ -z "$geo_result" ]; then
        # 接口不可用时放行（fail-safe）
        log "地理查询接口失败，放行（fail-safe）"
        exit 0
    fi

    local ip country region city org
    IFS='|' read -r ip country region city org <<< "$geo_result"

    # ── 6. 更新缓存（写入最新结果，供下次复用）──
    echo "${now}|${country}|${city}|${ip}" > "$CACHE_FILE"
    log "IP=${ip} COUNTRY=${country} CITY=${city} 缓存已更新"

    # ── 7. 禁止名单检查 + 城市变化检测（共享逻辑，拦截时内部 exit 2）──
    # old_city 来自本次查询前的缓存，用于对比是否发生城市切换
    process_geo_result "$ip" "$country" "$region" "$city" "$org" "$cached_city"

    log "放行：IP=${ip} COUNTRY=${country} CITY=${city}"
    exit 0
}

main
