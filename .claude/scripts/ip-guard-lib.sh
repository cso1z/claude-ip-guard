#!/bin/bash
# ip-guard-lib.sh
# 共享库：由 check-ip-on-start.sh 和 check-ip-on-prompt.sh 引用
# 包含所有核心逻辑：前置判断、直连测试、查询、缓存、历史、拦截

# ─── 配置常量 ────────────────────────────────────────────────────────────────

ANTHROPIC_DIRECT="https://api.anthropic.com"
CACHE_DIR="$HOME/.cache/claude-ip-guard"
CACHE_FILE="$CACHE_DIR/ip_cache"           # 格式: timestamp|country|city|ip
HISTORY_FILE="$CACHE_DIR/ip_history.jsonl" # 每行一条 JSON，记录 IP 变化
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
    "UA"  # 乌克兰（俄占区：克里米亚、顿涅茨克、赫尔松、卢甘斯克、扎波罗热，脚本无法细分，整国拦截）
)
CURL_TIMEOUT=5
RECHECK_INTERVAL=600  # UserPromptSubmit 缓存有效期（秒）
HISTORY_DAYS=30       # ip_history 保留天数

# ─── 探测 Python 解释器（兼容 Windows/macOS/Linux）────────────────────────────
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
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] [${LOG_PREFIX:-UNKNOWN}] $*" >> "$LOG_FILE"
}

# ─── 前置判断：是否原生直连 ───────────────────────────────────────────────────
# 返回 0（是原生）：ANTHROPIC_BASE_URL 未设置，或等于官方地址
# 返回 1（非原生）：用户配置了第三方代理，跳过全部检测

is_native_connection() {
    local base_url="${ANTHROPIC_BASE_URL:-}"
    if [ -z "$base_url" ] || [ "$base_url" = "$ANTHROPIC_DIRECT" ]; then
        log "原生直连（ANTHROPIC_BASE_URL=${base_url:-<未设置>}）"
        return 0
    else
        log "非原生直连（ANTHROPIC_BASE_URL=${base_url}）"
        return 1
    fi
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

# 校验 IP 格式（IPv4 或 IPv6），防止异常值拼接进 URL
_validate_ip() {
    local ip="$1"
    # IPv4
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
    # IPv6（含 ::1 短写、带 zone id 等常见形式）
    [[ "$ip" =~ ^[0-9a-fA-F:]+(%[^|]*)?$ ]] && [[ "$ip" == *:* ]] && return 0
    return 1
}

# 完整地理查询：获取 ip|country|region|city|org
# 参数 $1: 指定 IP（可选，留空则查当前出口 IP）
query_geo() {
    local target="${1:-}"
    local url result parsed

    if [ -n "$target" ] && ! _validate_ip "$target"; then
        log "IP 格式非法，跳过查询：${target}"
        return 1
    fi

    # ── 主接口：ipinfo.io（HTTPS）──
    if [ -n "$target" ]; then
        url="https://ipinfo.io/${target}/json"
    else
        url="https://ipinfo.io/json"
    fi

    log "geo 请求主接口：${url}"
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
            log "geo 主接口响应成功（ipinfo.io）"
            echo "$parsed"
            return 0
        fi
    fi
    log "geo 主接口无效，切换备用接口"

    # ── 备用接口：ip-api.com（HTTP，免费）──
    if [ -n "$target" ]; then
        url="http://ip-api.com/json/${target}"
    else
        url="http://ip-api.com/json/"
    fi

    log "geo 请求备用接口：${url}"
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
            log "geo 备用接口响应成功（ip-api.com）"
            echo "$parsed"
            return 0
        fi
    fi

    return 1
}

# ─── 禁止名单 ─────────────────────────────────────────────────────────────────

is_blocked() {
    local code="$1"
    for b in "${BLOCKED_COUNTRIES[@]}"; do
        [ "$code" = "$b" ] && return 0
    done
    return 1
}

# ─── IP 历史记录 ──────────────────────────────────────────────────────────────

# 检查 IP 是否已存在于历史（按 IP 去重）
is_ip_in_history() {
    local ip="$1"
    [ ! -f "$HISTORY_FILE" ] && return 1
    grep -qF "\"ip\":\"${ip}\"" "$HISTORY_FILE"
}

# 追加一条 IP 记录到历史文件
append_history() {
    local ip="$1" country="$2" region="$3" city="$4" org="$5"
    local time
    time=$(date '+%Y-%m-%d %H:%M:%S')
    printf '{"time":"%s","ip":"%s","country":"%s","region":"%s","city":"%s","org":"%s"}\n' \
        "$time" "$ip" "$country" "$region" "$city" "$org" >> "$HISTORY_FILE"
}

# 清理超过 HISTORY_DAYS 天的历史记录（原子写入，防止文件损坏）
cleanup_old_history() {
    [ ! -f "$HISTORY_FILE" ] && return
    $PYTHON - "$HISTORY_FILE" "$HISTORY_DAYS" <<'PYEOF'
import sys, json, os
from datetime import datetime, timedelta

filepath = sys.argv[1]
days     = int(sys.argv[2])
cutoff   = (datetime.now() - timedelta(days=days)).strftime('%Y-%m-%d')

lines = []
try:
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
                if d.get('time', '')[:10] >= cutoff:
                    lines.append(line)
            except json.JSONDecodeError:
                pass
except FileNotFoundError:
    sys.exit(0)

tmp = filepath + '.tmp'
try:
    with open(tmp, 'w') as f:
        for line in lines:
            f.write(line + '\n')
    os.replace(tmp, filepath)
except Exception:
    if os.path.exists(tmp):
        os.remove(tmp)
    sys.exit(1)
PYEOF
}

# 统计近 30 天不同 IP 数（去重，防多进程竞态导致重复行影响计数）
count_recent_ips() {
    [ ! -f "$HISTORY_FILE" ] && echo 0 && return
    $PYTHON - "$HISTORY_FILE" <<'PYEOF'
import sys, json

seen = set()
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
                ip = d.get('ip', '')
                if ip:
                    seen.add(ip)
            except json.JSONDecodeError:
                pass
except FileNotFoundError:
    pass
print(len(seen))
PYEOF
}

# ─── 警告文本构建 ─────────────────────────────────────────────────────────────

# 格式化历史记录为对齐表格
format_history_table() {
    [ ! -f "$HISTORY_FILE" ] && echo "  （暂无历史记录）" && return
    $PYTHON - "$HISTORY_FILE" <<'PYEOF'
import sys, json

entries = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                pass

if not entries:
    print('  （暂无历史记录）')
    sys.exit()

entries.sort(key=lambda x: x.get('time', ''), reverse=True)

print(f"  {'时间':<21} {'IP':<18} 完整地址")
print('  ' + '-' * 80)
for e in entries:
    addr = f"{e.get('country','')} · {e.get('region','')} · {e.get('city','')} ({e.get('org','')})"
    print(f"  {e.get('time',''):<21} {e.get('ip',''):<18} {addr}")
PYEOF
}

# 根据近 30 天新 IP 出现次数输出分级警告文本
build_new_ip_warning() {
    local new_ip="$1" count="$2"
    local header

    if   [ "$count" -ge 7 ]; then
        header="[严重警告] 近 30 天出现新 IP 次数过高（${count} 次），账号可能存在异常使用，强烈建议立即排查。"
    elif [ "$count" -ge 4 ]; then
        header="[警告] 近 30 天新增 IP 次数异常（${count} 次），存在账号安全风险，请确认是本人操作。"
    elif [ "$count" -ge 2 ]; then
        header="[注意] 近 30 天已出现 ${count} 个不同 IP，本次检测到新 IP（${new_ip}），请检查网络是否稳定。"
    else
        header="[提示] 检测到新的网络 IP（${new_ip}），请确认网络环境正常。重新发送消息即可继续使用。"
    fi

    local table
    table=$(format_history_table)
    printf '%s\n\n最近 30 天 IP 使用记录：\n%s\n' "$header" "$table"
}

# ─── 核心检测逻辑 ─────────────────────────────────────────────────────────────
# 参数: ip country region city org direct_ok
# direct_ok="true"  → 直连成功
# direct_ok="false" → 直连失败
#
# direct_ok=false:
#   IP 在禁用区 → exit 2 硬拦截
#   IP 不在禁用区 → exit 0 fail-safe 放行
#
# direct_ok=true:
#   IP 在禁用区 → exit 0 分流代理场景，不写缓存/历史
#   IP 不在禁用区:
#     IP 在历史中 → 仅写缓存 → exit 0
#     IP 不在历史 → 写历史 + 分级警告 → exit 2 软拦截

process_geo_result() {
    local ip="$1" country="$2" region="$3" city="$4" org="$5" direct_ok="$6"

    # ── direct_ok=false 分支 ──────────────────────────────────────────────────
    if [ "$direct_ok" != "true" ]; then
        if is_blocked "$country"; then
            log "硬拦截：IP=${ip} COUNTRY=${country}（黑名单命中，直连不通）"
            echo "[访问受限] 检测到您当前的网络 IP（${ip}）位于受限地区（${country}），无法使用 Claude。请切换网络后重试。" >&2
            exit 2
        fi
        log "放行（直连失败，COUNTRY=${country} 不在黑名单，fail-safe）：IP=${ip}"
        return
    fi

    # ── direct_ok=true 分支 ───────────────────────────────────────────────────
    if is_blocked "$country"; then
        # 分流代理场景：直连通但 geo 显示禁用区，说明直连走了代理出口
        # 放行但不写缓存/历史，避免污染合规记录
        log "分流代理场景，放行（不写缓存/历史）：IP=${ip} COUNTRY=${country}（黑名单命中，但直连可达）"
        return
    fi
    log "COUNTRY=${country} 不在黑名单（direct_ok=true）→ 进入 IP 历史检查"

    # ── IP 历史检查 ───────────────────────────────────────────────────────────
    if is_ip_in_history "$ip"; then
        log "IP 历史命中：IP=${ip}（已知 IP）"
        # 已知 IP，仅写缓存（历史已有记录，不重复写入）→ exit 0
        echo "$(date +%s)|${country}|${city}|${ip}" > "$CACHE_FILE"
        log "已知 IP，写缓存，放行：IP=${ip} COUNTRY=${country}"
    else
        log "IP 历史未命中：IP=${ip}（新 IP）"
        # 新 IP，写历史
        # count_recent_ips 对 IP 去重，防多进程竞态导致计数失真
        local count
        count=$(count_recent_ips)
        count=$((count + 1))
        append_history "$ip" "$country" "$region" "$city" "$org"
        cleanup_old_history
        if [ "$count" -eq 1 ]; then
            # 第一条 IP：建立基准，直接写缓存放行，无需提醒
            echo "$(date +%s)|${country}|${city}|${ip}" > "$CACHE_FILE"
            log "首个 IP，写历史+缓存，放行：IP=${ip} COUNTRY=${country}"
        else
            # 第二条起：出现新 IP，软拦截 + 分级警告
            log "新 IP 出现，写历史，软拦截：IP=${ip} COUNTRY=${country}（近 30 天第 ${count} 个 IP）"
            local warning
            warning=$(build_new_ip_warning "$ip" "$count")
            echo "$warning" >&2
            exit 2
        fi
    fi
}