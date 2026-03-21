#!/bin/bash
# check-ip-on-start.sh
# SessionStart hook：每次会话启动时执行网络与 IP 检测
# 触发时机：Claude Code 新建/恢复会话时（matcher: startup）

LOG_PREFIX="START"
source "$(dirname "$0")/ip-guard-lib.sh"

main() {
    log "会话启动，开始检测"

    # ── 1. 前置判断：非原生直连则跳过全部检测 ─────────────────────────────────
    if ! is_native_connection; then
        log "非原生直连（ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}），跳过检测"
        exit 0
    fi

    # ── 2. 直连测试 ────────────────────────────────────────────────────────────
    log "测试直连：${ANTHROPIC_DIRECT}"
    if test_direct; then
        # 可达：写入缓存，放行
        # 直连成功时不做 geo 查询，country/city 留空
        local current_ip
        current_ip=$(query_current_ip)
        echo "$(date +%s)|||${current_ip:-}" > "$CACHE_FILE"
        log "直连可达，IP=${current_ip:-unknown}，写入缓存，放行"
        exit 0
    fi

    log "直连不可达，进行 IP 地理查询"

    # ── 3. Geo 查询（ipinfo.io 主 → ip-api.com 备）────────────────────────────
    local geo_result
    geo_result=$(query_geo)

    if [ $? -ne 0 ] || [ -z "$geo_result" ]; then
        log "geo 查询失败，fail-safe 放行"
        exit 0
    fi

    local ip country region city org
    IFS='|' read -r ip country region city org <<< "$geo_result"
    log "geo 查询结果：IP=${ip} COUNTRY=${country} CITY=${city}"

    # ── 4. 禁用区检查（命中则内部 exit 2，非禁用区 fail-safe 放行）────────────
    process_geo_result "$ip" "$country"

    exit 0
}

main