#!/bin/bash
# check-ip-on-start.sh
# SessionStart hook：每次会话启动时执行网络与 IP 检测
# 触发时机：Claude Code 新建/恢复会话时（matcher: startup）

LOG_PREFIX="START"
source "$(dirname "$0")/ip-guard-lib.sh"

main() {
    log "触发：SessionStart | 脚本：${BASH_SOURCE[0]}"

    # ── 1. 前置判断：非原生直连则跳过全部检测 ─────────────────────────────────
    if ! is_native_connection; then
        exit 0
    fi

    # ── 2. 直连测试，记录 direct_ok ────────────────────────────────────────────
    local direct_ok="false"
    log "测试直连：${ANTHROPIC_DIRECT}"
    test_direct
    local direct_rc=$?
    if [ $direct_rc -eq 0 ]; then
        direct_ok="true"
        log "直连可达（direct_ok=true）"
    elif [ $direct_rc -eq 2 ]; then
        log "直连被明确拒绝（HTTP 403），硬拦截"
        echo "[访问受限] 检测到当前 IP 被 Anthropic 明确拒绝（HTTP 403），无法使用 Claude。请切换网络后重试。" >&2
        exit 2
    else
        log "直连不可达（连接超时/拒绝，direct_ok=false）"
    fi

    # ── 3. Geo 查询（ipinfo.io 主 → ip-api.com 备）────────────────────────────
    local geo_result
    geo_result=$(query_geo)

    if [ $? -ne 0 ] || [ -z "$geo_result" ]; then
        log "geo 查询失败，fail-safe 放行"
        exit 0
    fi

    local ip country region city org
    IFS='|' read -r ip country region city org <<< "$geo_result"
    log "geo 查询结果：IP=${ip} COUNTRY=${country} REGION=${region} CITY=${city} ORG=${org}"

    # ── 4. 核心检测（禁用区 + IP 历史，逻辑由 direct_ok 决定）───────────────
    process_geo_result "$ip" "$country" "$region" "$city" "$org" "$direct_ok"

    exit 0
}

main