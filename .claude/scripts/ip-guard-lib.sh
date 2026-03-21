#!/bin/bash
# ip-guard-lib.sh
# 共享库：由 check-ip-on-start.sh 和 check-ip-on-prompt.sh 引用
# 包含所有核心逻辑：前置判断、直连测试、查询、缓存、拦截

# ─── 配置常量 ────────────────────────────────────────────────────────────────

ANTHROPIC_DIRECT="https://api.anthropic.com"
CACHE_DIR="$HOME/.cache/claude-ip-guard"
CACHE_FILE="$CACHE_DIR/ip_cache"           # 格式: timestamp|country|city|ip
BLOCKED_COUNTRIES=(
    "CN"  # 中国大陆 - 监管/地缘政治
    "RU"  # 俄罗斯 - 美国制裁
    "KP"  # 朝鲜 - OFAC 制裁
    "IR"  # 伊朗 - OFAC 制裁
    "SY"  # 叙利亚 - OFAC 制裁
    "CU"  # 古巴 - OFAC 制裁
    "BY"  # 白俄罗斯 - 制裁相关
    "VE"  # 委内瑞拉
    "MM"  # 缅甸
    "LY"  # 利比亚
    "SO"  # 索马里
    "YE"  # 也门
    "ML"  # 马里
    "CF"  # 中非共和国
    "SS"  # 南苏丹
    "CD"  # 刚果民主共和国
    "ER"  # 厄立特里亚
    "AF"  # 阿富汗
    "UA"  # 乌克兰（俄占区受限，脚本无法细分省级，整国拦截）
)
CURL_TIMEOUT=5
RECHECK_INTERVAL=600  # UserPromptSubmit 缓存有效期（秒）

# ─── 探测 Python 解释器（兼容 Windows Git Bash / macOS / Linux）──────────────
# Windows Git Bash 中 python3 指向 Windows Store 别名（不可用），需回退到 python

_detect_python() {
    if command -v python3 &>/dev/null && python3 -c "import sys; sys.exit(0)" 2>/dev/null; then
        echo "python3"
    elif command -v python &>/dev/null && python -c "import sys; sys.exit(0)" 2>/dev/null; then
        echo "python"
    else
        echo ""
    fi
}

PYTHON=$(_detect_python)
if [ -z "$PYTHON" ]; then
    echo "[ip-guard] 错误：未找到可用的 Python 解释器（需要 Python 3）" >&2
    exit 1
fi

# ─── 初始化缓存目录 ───────────────────────────────────────────────────────────

if ! mkdir -p "$CACHE_DIR"; then
    echo "[ip-guard] 错误：无法创建缓存目录 $CACHE_DIR" >&2
    exit 1
fi

LOG_FILE="$CACHE_DIR/ip-guard-$(date '+%Y-%m-%d').log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${LOG_PREFIX:-UNKNOWN}] $*" >> "$LOG_FILE"
}

# ─── 前置判断：是否原生直连 ───────────────────────────────────────────────────
# 返回 0（是原生）：ANTHROPIC_BASE_URL 未设置，或等于官方地址
# 返回 1（非原生）：用户配置了第三方代理，跳过全部检测

is_native_connection() {
    local base_url="${ANTHROPIC_BASE_URL:-}"
    [ -z "$base_url" ] || [ "$base_url" = "$ANTHROPIC_DIRECT" ]
}

# ─── 直连测试 ─────────────────────────────────────────────────────────────────
# 测试能否与 api.anthropic.com 建立 TCP+TLS 连接
# 任何 HTTP 状态码（含 4xx 认证失败）= 握手成功 = 可达
# 返回 0（可达）或 1（超时/拒绝）

test_direct() {
    local status
    status=$(curl -s \
        --max-time        "$CURL_TIMEOUT" \
        --connect-timeout "$CURL_TIMEOUT" \
        -o /dev/null \
        -w "%{http_code}" \
        "$ANTHROPIC_DIRECT" 2>/dev/null)
    [[ "$status" =~ ^[1-9][0-9]{2}$ ]]
}

# ─── IP 查询 ──────────────────────────────────────────────────────────────────

# 轻量查询：仅获取当前公网 IP，不含地理信息
# 用于 UserPromptSubmit 快速比对，开销极小
query_current_ip() {
    curl -s --max-time "$CURL_TIMEOUT" "https://api.ipify.org?format=json" 2>/dev/null \
        | $PYTHON -c "import sys,json; d=json.load(sys.stdin); print(d.get('ip',''))" 2>/dev/null
}

# 简单校验 IPv4 格式，防止异常值拼接进 URL
_validate_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# 完整地理查询：获取 ip|country|region|city|org
# 参数 $1: 指定 IP（可选，留空则查当前出口 IP）
query_geo() {
    local target="${1:-}"
    local url result parsed

    if [ -n "$target" ] && ! _validate_ipv4 "$target"; then
        log "IP 格式非法，跳过查询：${target}"
        return 1
    fi

    # ── 主接口：ipinfo.io（HTTPS）──
    if [ -n "$target" ]; then
        url="https://ipinfo.io/${target}/json"
    else
        url="https://ipinfo.io/json"
    fi

    result=$(curl -s --max-time "$CURL_TIMEOUT" "$url" 2>/dev/null)
    if [ -n "$result" ]; then
        parsed=$(echo "$result" | $PYTHON -c "
import sys, json
try:
    d = json.load(sys.stdin)
    ip      = d.get('ip', '')
    country = d.get('country', '')
    region  = d.get('region', '')
    city    = d.get('city', '')
    org     = d.get('org', '')
    if ip and country:
        print(f'{ip}|{country}|{region}|{city}|{org}')
except Exception:
    pass
" 2>/dev/null)
        if [ -n "$parsed" ]; then
            echo "$parsed"
            return 0
        fi
    fi

    # ── 备用接口：ip-api.com（HTTP，免费）──
    if [ -n "$target" ]; then
        url="http://ip-api.com/json/${target}"
    else
        url="http://ip-api.com/json/"
    fi

    result=$(curl -s --max-time "$CURL_TIMEOUT" "$url" 2>/dev/null)
    if [ -n "$result" ]; then
        parsed=$(echo "$result" | $PYTHON -c "
import sys, json
try:
    d = json.load(sys.stdin)
    ip      = d.get('query', '')
    country = d.get('countryCode', '')
    region  = d.get('regionName', '')
    city    = d.get('city', '')
    org     = d.get('isp', '')
    if ip and country:
        print(f'{ip}|{country}|{region}|{city}|{org}')
except Exception:
    pass
" 2>/dev/null)
        if [ -n "$parsed" ]; then
            echo "$parsed"
            return 0
        fi
    fi

    return 1
}

# ─── 禁止名单检查 ─────────────────────────────────────────────────────────────

is_blocked() {
    local code="$1"
    for b in "${BLOCKED_COUNTRIES[@]}"; do
        [ "$code" = "$b" ] && return 0
    done
    return 1
}

# ─── 核心检测逻辑 ─────────────────────────────────────────────────────────────
# 仅做禁用区检查（城市切换检测已移除）
# 禁用区：exit 2（不写缓存）
# 非禁用区：fail-safe，exit 0（不写缓存，连接本身未通）

process_geo_result() {
    local ip="$1" country="$2"

    if is_blocked "$country"; then
        log "拦截：IP=${ip} COUNTRY=${country}"
        echo "[访问受限] 检测到您当前的网络 IP（${ip}）位于受限地区（${country}），无法使用 Claude。请切换网络后重试。" >&2
        exit 2
    fi

    log "放行（非禁用区，fail-safe）：IP=${ip} COUNTRY=${country}"
}