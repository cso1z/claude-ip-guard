#!/bin/bash
# ip-guard-lib.sh
# 共享库：由 check-ip-on-start.sh 和 check-ip-on-prompt.sh 引用
# 包含所有核心逻辑：查询、缓存、历史、拦截

# ─── 配置常量 ────────────────────────────────────────────────────────────────

CACHE_DIR="$HOME/.cache/claude-ip-guard"
CACHE_FILE="$CACHE_DIR/ip_cache"           # 格式: timestamp|country|city|ip
HISTORY_FILE="$CACHE_DIR/ip_history.jsonl" # 每行一条 JSON，记录城市变化
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

# ─── 初始化缓存目录 ───────────────────────────────────────────────────────────

if ! mkdir -p "$CACHE_DIR"; then
    echo "[ip-guard] 错误：无法创建缓存目录 $CACHE_DIR" >&2
    exit 1
fi

# 日志文件按天分割，LOG_PREFIX 由调用脚本设置（START 或 PROMPT）
LOG_FILE="$CACHE_DIR/ip-guard-$(date '+%Y-%m-%d').log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${LOG_PREFIX:-UNKNOWN}] $*" >> "$LOG_FILE"
}

# ─── IP 查询 ──────────────────────────────────────────────────────────────────

# 轻量查询：仅获取当前公网 IP，不含地理信息
# 用于 UserPromptSubmit 的快速比对，开销极小
query_current_ip() {
    curl -s --max-time "$CURL_TIMEOUT" "https://api.ipify.org?format=json" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ip',''))" 2>/dev/null
}

# 简单校验 IPv4 格式，防止异常值拼接进 URL
_validate_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# 完整地理查询：单次 python3 解析所有字段，避免多次启动解释器
# 参数 $1: 指定 IP（可选，留空则查当前出口 IP）
# 输出: ip|country|region|city|org（竖线分隔）
query_geo() {
    local target="${1:-}"
    local url result parsed
    local ip country region city org

    # 若指定 IP，先校验格式再拼接 URL
    if [ -n "$target" ] && ! _validate_ipv4 "$target"; then
        log "IP 格式非法，跳过查询：${target}"
        return 1
    fi

    # ── 主接口: ipinfo.io（HTTPS，稳定）──
    if [ -n "$target" ]; then
        url="https://ipinfo.io/${target}/json"
    else
        url="https://ipinfo.io/json"
    fi

    result=$(curl -s --max-time "$CURL_TIMEOUT" "$url" 2>/dev/null)
    if [ -n "$result" ]; then
        # 单次 python3 调用解析所有字段
        parsed=$(echo "$result" | python3 -c "
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

    # ── 备用接口: ip-api.com（HTTP，免费）──
    if [ -n "$target" ]; then
        url="http://ip-api.com/json/${target}"
    else
        url="http://ip-api.com/json/"
    fi

    result=$(curl -s --max-time "$CURL_TIMEOUT" "$url" 2>/dev/null)
    if [ -n "$result" ]; then
        parsed=$(echo "$result" | python3 -c "
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

# ─── 禁止名单 ─────────────────────────────────────────────────────────────────

is_blocked() {
    local code="$1"
    for b in "${BLOCKED_COUNTRIES[@]}"; do
        [ "$code" = "$b" ] && return 0
    done
    return 1
}

# ─── IP 历史记录 ──────────────────────────────────────────────────────────────

# 检查 IP 是否已存在于历史（全量匹配，防止重复写入）
is_ip_in_history() {
    local ip="$1"
    [ ! -f "$HISTORY_FILE" ] && return 1
    grep -qF "\"ip\":\"${ip}\"" "$HISTORY_FILE"
}

# 追加一条城市变化记录到历史文件
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
    python3 - "$HISTORY_FILE" "$HISTORY_DAYS" <<'PYEOF'
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
                # 字符串日期比较（格式固定为 YYYY-MM-DD，lexicographic 即时序）
                if d.get('time', '')[:10] >= cutoff:
                    lines.append(line)
            except json.JSONDecodeError:
                pass  # 跳过格式损坏的行
except FileNotFoundError:
    sys.exit(0)

# 原子写入：先写临时文件再重命名，防止中途中断导致文件损坏
tmp = filepath + '.tmp'
try:
    with open(tmp, 'w') as f:
        for line in lines:
            f.write(line + '\n')
    os.replace(tmp, filepath)  # os.replace 在同一文件系统上是原子操作
except Exception:
    if os.path.exists(tmp):
        os.remove(tmp)
    sys.exit(1)
PYEOF
}

# 统计近 30 天城市切换次数（ip_history 本身只保留 30 天，直接统计总行数）
count_recent_switches() {
    [ ! -f "$HISTORY_FILE" ] && echo 0 && return
    grep -c '"ip"' "$HISTORY_FILE" 2>/dev/null || echo 0
}

# ─── 警告文本构建 ─────────────────────────────────────────────────────────────

# 格式化历史记录为对齐表格
format_history_table() {
    [ ! -f "$HISTORY_FILE" ] && echo "  （暂无历史记录）" && return
    python3 - "$HISTORY_FILE" <<'PYEOF'
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

# 根据近 30 天切换次数输出分级警告文本
build_city_change_warning() {
    local old_city="$1" new_city="$2" count="$3"
    local header

    if   [ "$count" -ge 7 ]; then
        header="[严重警告] 近 30 天城市切换次数过高（${count} 次），账号可能存在异常使用，强烈建议立即排查。"
    elif [ "$count" -ge 4 ]; then
        header="[警告] 近 30 天城市切换次数异常（${count} 次），存在账号安全风险，请确认是本人操作。"
    elif [ "$count" -ge 2 ]; then
        header="[注意] 近 30 天已发生 ${count} 次城市切换（${old_city} → ${new_city}），请检查网络是否稳定。"
    else
        header="[提示] 检测到网络城市发生变化（${old_city} → ${new_city}），请确认网络环境正常。"
    fi

    local table
    table=$(format_history_table)
    printf '%s\n\n最近 30 天 IP 使用记录：\n%s\n' "$header" "$table"
}

# ─── 核心检测逻辑（两个脚本共用）────────────────────────────────────────────

# 处理完整地理查询结果：禁止名单检查 + 城市变化检测
# 参数: ip country region city org old_city
# 拦截时直接 exit 2（不返回，终止整个脚本）
process_geo_result() {
    local ip="$1" country="$2" region="$3" city="$4" org="$5" old_city="$6"

    # ── 1. 禁止名单检查 ──
    if is_blocked "$country"; then
        log "拦截：IP=${ip} COUNTRY=${country}"
        echo "[访问受限] 检测到您当前的网络 IP（${ip}）位于受限地区（${country}），无法使用 Claude。请切换网络后重试。" >&2
        exit 2
    fi

    # ── 2. 城市变化检测 ──
    if [ -n "$old_city" ] && [ "$city" != "$old_city" ]; then
        if ! is_ip_in_history "$ip"; then
            # 先获取计数（写入前 +1），确保提示中的次数准确
            local count
            count=$(count_recent_switches)
            count=$((count + 1))

            append_history "$ip" "$country" "$region" "$city" "$org"
            cleanup_old_history

            log "城市变化：${old_city} → ${city}，今日第 ${count} 次切换，拦截提示"
            local warning
            warning=$(build_city_change_warning "$old_city" "$city" "$count")
            echo "$warning" >&2
            exit 2
        else
            # IP 已在历史中（曾经使用过该网络），不重复记录
            log "城市变化（${old_city} → ${city}）但 IP=${ip} 已在历史中，跳过写入"
        fi
    else
        # ── 3. 城市未变：若为新 IP 则首次记录 ──
        if ! is_ip_in_history "$ip"; then
            append_history "$ip" "$country" "$region" "$city" "$org"
            log "新 IP 首次记录：IP=${ip} CITY=${city}"
        else
            log "放行：IP=${ip} CITY=${city}（无变化）"
        fi
    fi
}
