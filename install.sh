#!/bin/bash
# install.sh - 将 claude-ip-guard 安装到全局或指定项目
# 用法:
#   bash install.sh                        # 安装到全局 ~/.claude（默认）
#   bash install.sh --global               # 同上
#   bash install.sh --project              # 安装到当前目录（项目级）
#   bash install.sh --project /path/to/p   # 安装到指定项目（项目级）

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    echo "错误：未找到可用的 Python 解释器（需要 Python 3）" >&2
    exit 1
fi

# ── 解析参数 ──────────────────────────────────────────────────────────────────
PROJECT=false
TARGET_DIR=""

for arg in "$@"; do
    case "$arg" in
        --global)  echo ">> --global 已是默认行为，等同于不传参数" ;;
        --project) PROJECT=true ;;
        *)         TARGET_DIR="$arg" ;;
    esac
done

# ── 确定安装目标和 Hook 命令路径 ──────────────────────────────────────────────
if ! $PROJECT; then
    TARGET_CLAUDE_DIR="$HOME/.claude"
    TARGET_SCRIPTS_DIR="$TARGET_CLAUDE_DIR/scripts"
    TARGET_SETTINGS="$TARGET_CLAUDE_DIR/settings.json"
    # 全局安装使用绝对路径，不依赖项目工作目录
    START_CMD="bash $TARGET_SCRIPTS_DIR/check-ip-on-start.sh"
    PROMPT_CMD="bash $TARGET_SCRIPTS_DIR/check-ip-on-prompt.sh"
    echo ">> 安装模式：全局（$TARGET_CLAUDE_DIR）"
else
    TARGET_DIR="${TARGET_DIR:-$(pwd)}"
    TARGET_CLAUDE_DIR="$TARGET_DIR/.claude"
    TARGET_SCRIPTS_DIR="$TARGET_CLAUDE_DIR/scripts"
    TARGET_SETTINGS="$TARGET_CLAUDE_DIR/settings.json"
    # 项目安装使用相对路径，相对于项目根目录
    START_CMD="bash .claude/scripts/check-ip-on-start.sh"
    PROMPT_CMD="bash .claude/scripts/check-ip-on-prompt.sh"
    echo ">> 安装模式：项目级（$TARGET_DIR）"
fi

# ── 复制脚本 ──────────────────────────────────────────────────────────────────
mkdir -p "$TARGET_SCRIPTS_DIR"

cp "$SCRIPT_DIR/.claude/scripts/ip-guard-lib.sh"        "$TARGET_SCRIPTS_DIR/"
cp "$SCRIPT_DIR/.claude/scripts/check-ip-on-start.sh"   "$TARGET_SCRIPTS_DIR/"
cp "$SCRIPT_DIR/.claude/scripts/check-ip-on-prompt.sh"  "$TARGET_SCRIPTS_DIR/"
chmod +x "$TARGET_SCRIPTS_DIR/ip-guard-lib.sh"
chmod +x "$TARGET_SCRIPTS_DIR/check-ip-on-start.sh"
chmod +x "$TARGET_SCRIPTS_DIR/check-ip-on-prompt.sh"
echo ">> 脚本已复制并授权：$TARGET_SCRIPTS_DIR"

# ── 生成 Hook 配置（按安装模式使用对应路径）─────────────────────────────────
HOOK_CONFIG=$(cat <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "$START_CMD",
            "timeout": 15
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$PROMPT_CMD",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
EOF
)

# ── 写入或自动合并 settings.json ─────────────────────────────────────────────
if [ ! -f "$TARGET_SETTINGS" ]; then
    echo "$HOOK_CONFIG" > "$TARGET_SETTINGS"
    echo ">> settings.json 已创建：$TARGET_SETTINGS"
else
    # 用 python 将 ip-guard hooks 合并进已有 settings.json，保留其他配置不变
    $PYTHON - "$TARGET_SETTINGS" "$START_CMD" "$PROMPT_CMD" <<'PYEOF'
import sys, json, os

settings_path = sys.argv[1]
start_cmd     = sys.argv[2]
prompt_cmd    = sys.argv[3]

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})

# ── SessionStart：追加（若相同命令已存在则跳过）──
session_hooks = hooks.setdefault("SessionStart", [])
start_entry = {
    "matcher": "startup",
    "hooks": [{"type": "command", "command": start_cmd, "timeout": 15}]
}
already = any(
    any(h.get("command") == start_cmd for h in g.get("hooks", []))
    for g in session_hooks
)
if not already:
    session_hooks.append(start_entry)

# ── UserPromptSubmit：追加（若相同命令已存在则跳过）──
prompt_hooks = hooks.setdefault("UserPromptSubmit", [])
prompt_entry = {
    "hooks": [{"type": "command", "command": prompt_cmd, "timeout": 15}]
}
already = any(
    any(h.get("command") == prompt_cmd for h in g.get("hooks", []))
    for g in prompt_hooks
)
if not already:
    prompt_hooks.append(prompt_entry)

# 原子写入，防止中途中断损坏文件
tmp = settings_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, settings_path)
PYEOF
    echo ">> settings.json 已自动合并：$TARGET_SETTINGS"
fi

echo ">> 安装完成！重启 Claude Code 后生效。"