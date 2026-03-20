#!/bin/bash
# check-ip-on-start.sh
# SessionStart hook：每次会话启动时强制执行完整 IP 地理位置检查
# 触发时机：Claude Code 新建/恢复会话时（matcher: startup）

LOG_PREFIX="START"
source "$(dirname "$0")/ip-guard-lib.sh"

main() {
    log "会话启动，开始完整 IP 检查"

    # ── 1. 读取旧缓存，获取上次已通过的城市（必须在写入新缓存前读取）──
    local old_city=""
    if [ -f "$CACHE_FILE" ]; then
        local old_ts old_country old_city_cached old_ip
        IFS='|' read -r old_ts old_country old_city_cached old_ip < "$CACHE_FILE"

        # 验证缓存格式：时间戳必须为纯数字，IP 不能为空
        if [[ "$old_ts" =~ ^[0-9]+$ ]] && [ -n "$old_ip" ]; then
            old_city="$old_city_cached"
        else
            log "缓存格式异常（ts=${old_ts} ip=${old_ip}），忽略旧城市记录"
        fi
    fi

    # ── 2. 完整地理查询（SessionStart 每次必须查，不使用缓存跳过）──
    local geo_result
    geo_result=$(query_geo)

    if [ $? -ne 0 ] || [ -z "$geo_result" ]; then
        # 接口不可用时放行（fail-safe：网络故障不应阻止用户使用）
        log "接口不可用，放行（fail-safe）"
        exit 0
    fi

    local ip country region city org
    IFS='|' read -r ip country region city org <<< "$geo_result"

    # ── 3. 写入新缓存（覆盖旧值，供后续 UserPromptSubmit 使用）──
    echo "$(date +%s)|${country}|${city}|${ip}" > "$CACHE_FILE"
    log "IP=${ip} COUNTRY=${country} CITY=${city} 缓存已更新"

    # ── 4. 禁止名单检查 + 城市变化检测（共享逻辑，拦截时内部 exit 2）──
    process_geo_result "$ip" "$country" "$region" "$city" "$org" "$old_city"

    exit 0
}

main
