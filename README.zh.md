# claude-ip-guard

[English](./README.md) | 中文

基于 IP 地理位置和直连检测的 Claude Code 访问控制插件。当 IP 处于受限国家且直连不通时硬拦截；当出现从未见过的新 IP 时软拦截。

## 功能特性

- **代理感知** — `ANTHROPIC_BASE_URL` 指向第三方代理时自动跳过全部检测，不干预用户网络选择
- **直连检测** — 每次检测都测试 `api.anthropic.com` 可达性，记录 `direct_ok`，由此决定后续策略
- **国家硬拦截** — 直连不通且 IP 在受限国家时，exit 2 拦截（用户可见提示）
- **分流代理识别** — 直连通但 geo 显示受限国家时，视为分流代理场景放行，不写缓存/历史
- **新 IP 软拦截** — 直连通且 IP 合规但为首次出现时，exit 2 软拦截并附分级警告；用户重发即可继续
- **30 天 IP 历史** — 按 IP 去重，每个 IP 只记录一次，保留近 30 天
- **智能缓存** — 每次 prompt 做轻量 IP 比对；缓存命中（IP 相同且 < 10 分钟）跳过所有网络检测
- **Fail-safe** — 任何查询失败均放行，避免网络故障导致误拦截
- **双 geo 接口** — `ipinfo.io`（HTTPS，主）、`ip-api.com`（HTTP，备）
- **共享库** — 核心逻辑集中在 `ip-guard-lib.sh`，两个 hook 脚本共同引用
- **全局或项目安装** — 一条命令安装到单个项目或机器上所有项目

## 禁止国家列表

基于 [Anthropic 官方支持地区](https://www.anthropic.com/supported-countries) 及美国 OFAC 出口管制规定：

| 国家/地区 | ISO 代码 | 原因 |
|-----------|----------|------|
| 中国大陆 | `CN` | 监管/地缘政治 |
| 俄罗斯 | `RU` | 美国制裁 |
| 朝鲜 | `KP` | OFAC 制裁 |
| 伊朗 | `IR` | OFAC 制裁 |
| 叙利亚 | `SY` | OFAC 制裁 |
| 古巴 | `CU` | OFAC 制裁 |
| 白俄罗斯 | `BY` | 制裁相关 |
| 委内瑞拉 | `VE` | 未列入支持名单 |
| 缅甸 | `MM` | 未列入支持名单 |
| 利比亚 | `LY` | 未列入支持名单 |
| 索马里 | `SO` | 未列入支持名单 |
| 也门 | `YE` | 未列入支持名单 |
| 马里 | `ML` | 未列入支持名单 |
| 中非共和国 | `CF` | 未列入支持名单 |
| 南苏丹 | `SS` | 未列入支持名单 |
| 刚果民主共和国 | `CD` | 未列入支持名单 |
| 厄立特里亚 | `ER` | 未列入支持名单 |
| 阿富汗 | `AF` | 未列入支持名单 |
| 乌克兰 | `UA` | 俄占区受限，脚本无法细分省级，整国拦截 |

如需调整，在 `ip-guard-lib.sh` 的 `BLOCKED_COUNTRIES` 变量中增减 ISO 代码即可。

## 工作原理

```
两个 Hook 共同前置判断
└── ANTHROPIC_BASE_URL 已设置 且 ≠ "https://api.anthropic.com"？
    └── YES → 跳过全部检测（第三方代理，不干预）
    └── NO  → 继续执行（原生 Anthropic 直连场景）

SessionStart（每次会话启动）
└── 直连测试 api.anthropic.com → 记录 direct_ok
└── Geo 查询（ipinfo.io 主 → ip-api.com 备）— 始终执行
    └── 查询失败    → fail-safe，exit 0
    └── direct_ok=false + IP 在禁用区 → exit 2 硬拦截
    └── direct_ok=false + IP 不在禁用区 → fail-safe，exit 0
    └── direct_ok=true  + IP 在禁用区 → 分流代理场景，exit 0（不写缓存/历史）
    └── direct_ok=true  + IP 不在禁用区 → 检查 IP 历史
        ├── IP 已知 → 写缓存 → exit 0
        └── IP 新出现 → 写历史 + 分级警告 → exit 2 软拦截

UserPromptSubmit（每次用户发送消息前）
└── 轻量查询：获取当前公网 IP
    └── 失败 → fail-safe，exit 0
└── 缓存命中：IP 相同且 < 10min → exit 0（已验证通过）
└── 否则 → 直连测试 + Geo 查询 → 同 SessionStart 逻辑
```

> **说明**：Claude Code 不展示 SessionStart hook 的 stderr，且 exit 2 不阻断会话启动。所有对用户可见的拦截均由 UserPromptSubmit hook 完成（用户发第一条消息时触发）。

## 新 IP 出现警告

直连通且 IP 合规时，若该 IP 为首次出现，触发分级软拦截（exit 2 阻止当前 prompt，用户**重新发送**即可继续——第二次发送时 IP 已在历史中，正常放行）：

| 近 30 天不同 IP 数 | 等级 | 提示前缀 |
|-------------------|------|---------|
| 第 1 个 | 信息 | `[提示]` |
| 第 2～3 个 | 注意 | `[注意]` |
| 第 4～6 个 | 警告 | `[警告]` |
| 第 7 个及以上 | 严重 | `[严重警告]` |

每次警告附带近 30 天 IP 历史记录表格。

## 环境要求

- `bash`
- `curl`
- `python3` 或 `python`

支持平台：macOS、Linux、WSL、**Windows（Git Bash）**。不支持纯 Windows CMD/PowerShell。

### Windows — 使用 Git Bash 运行

脚本需要 bash 环境。在 Windows 上，[Git for Windows](https://git-scm.com/download/win) 自带 Git Bash，内置 `bash`、`curl`、`grep`，无需安装 WSL。

**第一步 — 安装 Git for Windows**

下载并运行安装程序。在 "Adjusting your PATH environment" 步骤中，选择 **"Git from the command line and also from 3rd-party software"**，使 `bash` 加入系统 PATH。

**第二步 — 安装 Python**

从 [python.org](https://www.python.org/downloads/windows/) 下载 Python 安装包，安装时勾选 **"Add Python to PATH"**。

> 脚本会自动检测使用 `python3` 还是 `python`，两种命名均可正常工作。

**第三步 — 打开 Git Bash 执行安装**

在任意文件夹右键，选择 **"Git Bash Here"** 打开 Git Bash，然后运行：

```bash
git clone https://github.com/your-username/claude-ip-guard.git
bash claude-ip-guard/install.sh
```

**第四步 — 验证是否正常运行**

```bash
bash ~/.claude/scripts/check-ip-on-prompt.sh
# 预期：脚本正常退出（exit code 0）

cat ~/.cache/claude-ip-guard/ip-guard-$(date '+%Y-%m-%d').log
# 预期：看到包含 IP 和国家代码的"放行"日志
```

> 本文档中所有 `bash` 和 `git clone` 命令均需在 Git Bash 中执行，不要在 CMD 或 PowerShell 中运行。

## 安装方式

### 全局安装（对本机所有项目生效，默认）

> **Windows 用户**：以下命令需在 **Git Bash** 中执行，不能使用 CMD 或 PowerShell。右键任意文件夹选择 "Git Bash Here" 即可打开。

```bash
git clone https://github.com/your-username/claude-ip-guard.git
bash claude-ip-guard/install.sh          # 不传参数即为全局（推荐）
# 或显式指定
bash claude-ip-guard/install.sh --global
```

脚本安装至 `~/.claude/scripts/`，hook 命令使用绝对路径。

### 项目级安装（仅对指定项目生效）

```bash
# 安装到当前目录
bash claude-ip-guard/install.sh --project

# 安装到指定项目
bash claude-ip-guard/install.sh --project /path/to/your/project
```

脚本安装至 `.claude/scripts/`，hook 命令使用相对路径。

安装脚本会自动：
1. 复制 `ip-guard-lib.sh`、`check-ip-on-start.sh`、`check-ip-on-prompt.sh` 到目标目录
2. 按安装模式生成对应路径的 hook 配置
3. 若 `settings.json` 不存在则自动创建；若已存在则自动合并 hooks（保留原有配置不变）
4. 重启 Claude Code 后生效

### 手动安装

1. 将 `.claude/scripts/` 复制到项目的 `.claude/scripts/`
2. 授权执行：
   ```bash
   chmod +x .claude/scripts/*.sh
   ```
3. 将以下 hook 配置合并到 `.claude/settings.json`：
   ```json
   {
     "hooks": {
       "SessionStart": [
         {
           "matcher": "startup",
           "hooks": [{ "type": "command", "command": "bash .claude/scripts/check-ip-on-start.sh", "timeout": 15 }]
         }
       ],
       "UserPromptSubmit": [
         {
           "hooks": [{ "type": "command", "command": "bash .claude/scripts/check-ip-on-prompt.sh", "timeout": 15 }]
         }
       ]
     }
   }
   ```
4. 重启 Claude Code

## 文件结构

```
claude-ip-guard/
├── install.sh                       # 安装脚本（默认全局，--project 指定项目级）
├── doc/
│   └── ip-access-control-design.md  # 完整设计文档
└── .claude/
    ├── settings.json                 # Hook 配置模板
    └── scripts/
        ├── ip-guard-lib.sh           # 共享库：查询、缓存、历史、拦截
        ├── check-ip-on-start.sh      # SessionStart hook
        └── check-ip-on-prompt.sh     # UserPromptSubmit hook
```

**运行时缓存目录**（本地，不提交仓库）：

```
~/.cache/claude-ip-guard/
├── ip_cache                         # 当前 IP 缓存（timestamp|country|city|ip）
├── ip_history.jsonl                 # IP 变化历史（近 30 天，JSONL 格式）
└── ip-guard-YYYY-MM-DD.log          # 按天分割的运行日志
```

## 验证是否生效

按以下步骤确认 hook 已正常工作。

**第一步 — 查询当前网络的国家代码**

访问 [https://ipinfo.io/json](https://ipinfo.io/json)，找到 `country` 字段，例如 `"country": "SG"`。

**第二步 — 临时将其加入禁止名单**

打开 `.claude/scripts/ip-guard-lib.sh`（全局安装则是 `~/.claude/scripts/ip-guard-lib.sh`），追加你的国家代码：

```bash
BLOCKED_COUNTRIES=(
    "CN"
    "RU"
    # ... 已有条目 ...
    "SG"  # ← 此处填入你的国家代码，仅用于测试
)
```

**第三步 — 重启 Claude Code，随意发送一条消息**

提交 prompt 时应看到如下拦截提示：

![拦截效果截图](./doc/screenshots/blocked.png)

**第四步 — 删除测试条目**

删除第二步添加的那行代码并保存文件，下次 prompt 立即恢复正常。

---

## 团队共享

将 `.claude/settings.json` 和 `.claude/scripts/` 提交到仓库，团队成员拉取后自动生效。

成员可通过 `.claude/settings.local.json` 在本地覆盖配置（该文件不提交仓库）。

## 使用的接口

| 接口 | 用途 | 协议 |
|------|------|------|
| `api.anthropic.com` | 直连检测（主判断门） | HTTPS |
| `api.ipify.org` | 轻量 IP 查询（每次 prompt） | HTTPS |
| `ipinfo.io` | 完整地理查询（主） | HTTPS |
| `ip-api.com` | 完整地理查询（备） | HTTP |

## License

MIT
