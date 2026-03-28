#!/bin/bash
# install.sh - 将 claude-ip-guard 安装到全局或指定项目
# 用法:
#   bash install.sh                        # 安装到全局 ~/.claude（默认）
#   bash install.sh --global               # 同上
#   bash install.sh --project              # 安装到当前目录（项目级）
#   bash install.sh --project /path/to/p   # 安装到指定项目（项目级）

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${TMPDIR:-/tmp}/claude-ip-guard-install.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}
log_err() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"
    echo "$msg" >&2
    echo "$msg" >> "$LOG_FILE"
}

log "===== claude-ip-guard 安装开始 ====="
log "脚本目录：$SCRIPT_DIR"
log "日志文件：$LOG_FILE"

# ── 探测 Python 解释器（兼容 Windows Git Bash / macOS / Linux）───────────────
# Windows Git Bash 中 python3 指向 Windows Store 别名，实际不可用
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
    log_err "未找到可用的 Python 解释器（需要 Python 3）"
    exit 1
fi
log "Python 解释器：$PYTHON（$(${PYTHON} --version 2>&1)）"

# ── 解析参数 ──────────────────────────────────────────────────────────────────
PROJECT=false
TARGET_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --global)
            log "--global 已是默认行为，等同于不传参数"
            shift
            ;;
        --project)
            PROJECT=true
            shift
            ;;
        --*)
            log_err "未知参数：$1"
            log_err "用法：bash install.sh [--global] | [--project [path]]"
            exit 1
            ;;
        *)
            if [ -n "$TARGET_DIR" ]; then
                log_err "检测到多个目标路径参数：\"$TARGET_DIR\" 和 \"$1\""
                log_err "请只提供一个项目路径"
                exit 1
            fi
            TARGET_DIR="$1"
            shift
            ;;
    esac
done

# ── 确定安装目标和 Hook 命令路径 ──────────────────────────────────────────────
if ! $PROJECT; then
    TARGET_CLAUDE_DIR="$HOME/.claude"
    TARGET_SCRIPTS_DIR="$TARGET_CLAUDE_DIR/scripts"
    TARGET_SETTINGS="$TARGET_CLAUDE_DIR/settings.json"
    # 全局安装使用绝对路径，不依赖项目工作目录；路径加引号以兼容空格目录
    START_CMD="bash \"$TARGET_SCRIPTS_DIR/check-ip-on-start.sh\""
    PROMPT_CMD="bash \"$TARGET_SCRIPTS_DIR/check-ip-on-prompt.sh\""
    log "安装模式：全局（$TARGET_CLAUDE_DIR）"
else
    TARGET_DIR="${TARGET_DIR:-$(pwd)}"
    if [ ! -d "$TARGET_DIR" ]; then
        log_err "项目目录不存在：$TARGET_DIR"
        exit 1
    fi
    TARGET_CLAUDE_DIR="$TARGET_DIR/.claude"
    TARGET_SCRIPTS_DIR="$TARGET_CLAUDE_DIR/scripts"
    TARGET_SETTINGS="$TARGET_CLAUDE_DIR/settings.json"
    # 项目安装使用相对路径，相对于项目根目录
    START_CMD="bash .claude/scripts/check-ip-on-start.sh"
    PROMPT_CMD="bash .claude/scripts/check-ip-on-prompt.sh"
    log "安装模式：项目级（$TARGET_DIR）"
fi
log "目标 settings：$TARGET_SETTINGS"

# ── 复制脚本 ──────────────────────────────────────────────────────────────────
mkdir -p "$TARGET_SCRIPTS_DIR"

for script in ip-guard-lib.sh check-ip-on-start.sh check-ip-on-prompt.sh; do
    cp "$SCRIPT_DIR/.claude/scripts/$script" "$TARGET_SCRIPTS_DIR/"
    chmod +x "$TARGET_SCRIPTS_DIR/$script"
    log "已复制：$script"
done
log "脚本目录：$TARGET_SCRIPTS_DIR"

# ── 写入或自动合并 settings.json ─────────────────────────────────────────────
# Hook 结构从项目自身的 .claude/settings.json 读取，command 替换为目标路径
SOURCE_SETTINGS="$SCRIPT_DIR/.claude/settings.json"

if [ ! -f "$TARGET_SETTINGS" ]; then
    log "settings.json 不存在，从源模板新建..."
    merge_output=$(PYTHONUTF8=1 $PYTHON - "$SOURCE_SETTINGS" "$TARGET_SETTINGS" "$START_CMD" "$PROMPT_CMD" <<'PYEOF'
import sys, json, os, copy

source_path   = sys.argv[1]
target_path   = sys.argv[2]
start_cmd     = sys.argv[3]
prompt_cmd    = sys.argv[4]

with open(source_path) as f:
    source = json.load(f)

def extract_entry(source_list, new_cmd):
    tmpl = next((g for g in source_list if g.get("_ip_guard")), None)
    if not tmpl:
        return None
    entry = copy.deepcopy(tmpl)
    for h in entry.get("hooks", []):
        h["command"] = new_cmd
    return entry

source_hooks = source.get("hooks", {})
settings = {"hooks": {}}
hooks = settings["hooks"]

for event, cmd, keyword in [
    ("SessionStart",    start_cmd,  "check-ip-on-start"),
    ("UserPromptSubmit", prompt_cmd, "check-ip-on-prompt"),
]:
    entry = extract_entry(source_hooks.get(event, []), cmd)
    if entry:
        hooks[event] = [entry]
        print(f"  {event}: 写入 command=\"{cmd}\"")

os.makedirs(os.path.dirname(target_path), exist_ok=True)
tmp = target_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, target_path)
PYEOF
)
    while IFS= read -r line; do log "$line"; done <<< "$merge_output"
    log "settings.json 已新建：$TARGET_SETTINGS"
else
    log "settings.json 已存在，执行合并..."
    merge_output=$(PYTHONUTF8=1 $PYTHON - "$SOURCE_SETTINGS" "$TARGET_SETTINGS" "$START_CMD" "$PROMPT_CMD" <<'PYEOF'
import sys, json, os, copy

source_path   = sys.argv[1]
settings_path = sys.argv[2]
start_cmd     = sys.argv[3]
prompt_cmd    = sys.argv[4]

def extract_entry(source_list, new_cmd):
    tmpl = next((g for g in source_list if g.get("_ip_guard")), None)
    if not tmpl:
        return None
    entry = copy.deepcopy(tmpl)
    for h in entry.get("hooks", []):
        h["command"] = new_cmd
    return entry

def is_ip_guard_entry(group, keyword):
    """兼容旧版（无 _ip_guard 标记）：按标记或脚本名识别"""
    if group.get("_ip_guard"):
        return True
    return any(keyword in h.get("command", "") for h in group.get("hooks", []))

def apply_hook(hook_list, new_entry, keyword, event_name):
    before = len(hook_list)
    hook_list[:] = [g for g in hook_list if not is_ip_guard_entry(g, keyword)]
    removed = before - len(hook_list)
    hook_list.append(new_entry)
    cmd = next((h.get("command","") for h in new_entry.get("hooks",[])), "")
    print(f"  {event_name}: 删除 {removed} 条旧记录，追加 command=\"{cmd}\"")

with open(source_path) as f:
    source = json.load(f)
with open(settings_path) as f:
    settings = json.load(f)

source_hooks = source.get("hooks", {})
hooks = settings.setdefault("hooks", {})

for event, cmd, keyword in [
    ("SessionStart",     start_cmd,  "check-ip-on-start"),
    ("UserPromptSubmit", prompt_cmd, "check-ip-on-prompt"),
]:
    entry = extract_entry(source_hooks.get(event, []), cmd)
    if entry:
        apply_hook(hooks.setdefault(event, []), entry, keyword, event)

tmp = settings_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, settings_path)
PYEOF
)
    while IFS= read -r line; do log "$line"; done <<< "$merge_output"
    log "settings.json 合并完成：$TARGET_SETTINGS"
fi

log "===== 安装完成，重启 Claude Code 后生效 ====="