#!/bin/bash
# check-ip-on-prompt.sh
# UserPromptSubmit hook：每次用户发送消息前检查
# 触发时机：用户每次提交 prompt 时（无 matcher，全量触发）
# 策略：IP 未变且缓存未过期则直接放行；否则重新完整检测

LOG_PREFIX="PROMPT"
source "$(dirname "$0")/ip-guard-lib.sh"

main() {
    log "触发：UserPromptSubmit | 脚本：${BASH_SOURCE[0]}"

    # ── 1. 前置判断：非原生直连则跳过全部检测 ─────────────────────────────────
    if ! is_native_connection; then
        exit 0
    fi

    # ── 2. 轻量查询：获取当前公网 IP ──────────────────────────────────────────
    log "轻量查询当前公网 IP..."
    local current_ip
    current_ip=$(query_current_ip)

    if [ -z "$current_ip" ]; then
        log "无法获取当前 IP，fail-safe 放行"
        exit 0
    fi
    log "当前公网 IP：${current_ip}"

    local now
    now=$(date +%s)

    # ── 3. 读取缓存 ────────────────────────────────────────────────────────────
    local cached_ts="" cached_country="" cached_city="" cached_ip=""
    if [ -f "$CACHE_FILE" ]; then
        IFS='|' read -r cached_ts cached_country cached_city cached_ip < "$CACHE_FILE"
        log "读取缓存：IP=${cached_ip} COUNTRY=${cached_country} CITY=${cached_city} TS=${cached_ts}"

        if ! [[ "$cached_ts" =~ ^[0-9]+$ ]]; then
            log "缓存时间戳异常（${cached_ts}），强制重新检测"
            cached_ts=""
        fi
    else
        log "缓存文件不存在"
    fi

    # ── 4. 判断是否复用缓存（IP 相同 且 未过期）──────────────────────────────
    local elapsed=0
    [ -n "$cached_ts" ] && elapsed=$((now - cached_ts))

    if [ "$current_ip" = "$cached_ip" ] && [ -n "$cached_ts" ] && [ "$elapsed" -lt "$RECHECK_INTERVAL" ]; then
        log "IP 未变（${current_ip}），缓存有效（${elapsed}s < ${RECHECK_INTERVAL}s），放行"
        exit 0
    fi

    # ── 5. 记录重新检测的原因 ──────────────────────────────────────────────────
    if [ -n "$cached_ip" ] && [ "$current_ip" != "$cached_ip" ]; then
        log "IP 变化：${cached_ip} → ${current_ip}，重新检测"
    elif [ -n "$cached_ts" ]; then
        log "缓存过期（${elapsed}s >= ${RECHECK_INTERVAL}s），重新检测（IP=${current_ip}）"
    else
        log "无有效缓存，首次检测（IP=${current_ip}）"
    fi

    # ── 6. 直连测试，记录 direct_ok ────────────────────────────────────────────
    run_direct_test
    local direct_ok="$DIRECT_OK"

    # ── 7. Geo 查询（ipinfo.io 主 → ip-api.com 备）────────────────────────────
    log "发起 geo 查询：IP=${current_ip}"
    local geo_result
    geo_result=$(query_geo "$current_ip")

    if [ $? -ne 0 ] || [ -z "$geo_result" ]; then
        log "geo 查询失败，fail-safe 放行"
        exit 0
    fi

    local ip country region city org
    IFS='|' read -r ip country region city org <<< "$geo_result"
    log "geo 查询结果：IP=${ip} COUNTRY=${country} REGION=${region} CITY=${city} ORG=${org}"

    # ── 8. 核心检测（禁用区 + IP 历史，逻辑由 direct_ok 决定）───────────────
    process_geo_result "$ip" "$country" "$region" "$city" "$org" "$direct_ok"

    exit 0
}

main