# claude-ip-guard

[English](./README.md) | 中文

基于 IP 地理位置的 Claude Code 访问控制插件。当检测到当前 IP 位于受限国家时，拦截用户输入，防止账号因 IP 异常被封。

## 功能特性

- **直连优先检测** — 优先测试能否直连 `api.anthropic.com`；可达则说明出口 IP 未被封，直接放行（无需地理查询）
- **国家拦截** — 直连不可达时，通过 geo 查询判断 IP 所在地；位于受限地区则 exit 2 拦截（用户可见提示）
- **代理感知** — 当 `ANTHROPIC_BASE_URL` 指向第三方代理时，自动跳过全部检测；仅对原生 Anthropic 直连生效
- **智能缓存** — 每次 prompt 仅做轻量 IP 比对；IP 变化或超过 10 分钟时才重新完整检测
- **Fail-safe** — 接口不可用时一律放行，避免网络故障导致误拦截
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
| 乌克兰 | `UA` | 俄占区受限（克里米亚、顿涅茨克等），脚本无法细分省级，整国拦截 |

如需调整，在 `ip-guard-lib.sh` 的 `BLOCKED_COUNTRIES` 变量中增减 ISO 代码即可。

## 工作原理

```
两个 Hook 共同前置判断
└── ANTHROPIC_BASE_URL 已设置 且 ≠ "https://api.anthropic.com"？
    └── YES → 跳过全部检测（第三方代理，不干预）
    └── NO  → 继续执行（原生 Anthropic 直连场景）

SessionStart（每次会话启动）
└── 测试直连 api.anthropic.com
    ├── 可达 → 写入缓存（timestamp|||ip）→ exit 0
    │   （可达说明出口 IP 未被封，无需 geo 查询）
    └── 不可达 → 完整 geo 查询（ipinfo.io 主 → ip-api.com 备）
          ├── 查询失败    → fail-safe，exit 0（不写缓存）
          ├── IP 在禁用区 → exit 2，展示拦截提示（不写缓存）
          └── IP 不在禁用区 → fail-safe，exit 0（不写缓存）

UserPromptSubmit（每次用户发送消息前）
└── 轻量查询：仅获取当前公网 IP
    └── 查询失败 → fail-safe，exit 0
└── 读取缓存
    ├── IP 相同 且 缓存 < 10min → exit 0（缓存中的 IP 即已验证通过）
    └── IP 变化 或 缓存过期 → 重新完整检测（流程同 SessionStart）
```

> **说明**：Claude Code 不展示 SessionStart hook 的 stderr，且 exit 2 不阻断会话启动。所有对用户可见的拦截均由 UserPromptSubmit hook 完成（用户发第一条消息时触发）。

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
bash claude-ip-guard/install.sh --global
```

**第四步 — 验证是否正常运行**

```bash
bash ~/.claude/scripts/check-ip-on-prompt.sh
# 预期：脚本正常退出（exit code 0）

cat ~/.cache/claude-ip-guard/ip-guard-$(date '+%Y-%m-%d').log
# 预期：看到"直连可达"或"放行"日志
```

> 本文档中所有 `bash` 和 `git clone` 命令均需在 Git Bash 中执行，不要在 CMD 或 PowerShell 中运行。

## 安装方式

### 全局安装（对本机所有项目生效）

> **Windows 用户**：以下命令需在 **Git Bash** 中执行，不能使用 CMD 或 PowerShell。右键任意文件夹选择 "Git Bash Here" 即可打开。

```bash
git clone https://github.com/your-username/claude-ip-guard.git
bash claude-ip-guard/install.sh --global
```

脚本安装至 `~/.claude/scripts/`，hook 命令使用绝对路径。

### 项目级安装（仅对指定项目生效）

```bash
# 安装到指定项目
bash claude-ip-guard/install.sh /path/to/your/project

# 安装到当前目录
bash claude-ip-guard/install.sh
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
├── install.sh                       # 安装脚本（支持 --global）
├── doc/
│   └── ip-access-control-design.md  # 完整设计文档
└── .claude/
    ├── settings.json                 # Hook 配置模板
    └── scripts/
        ├── ip-guard-lib.sh           # 共享库：直连检测、geo 查询、缓存、拦截
        ├── check-ip-on-start.sh      # SessionStart hook
        └── check-ip-on-prompt.sh     # UserPromptSubmit hook
```

**运行时缓存目录**（本地，不提交仓库）：

```
~/.cache/claude-ip-guard/
├── ip_cache                         # 当前 IP 缓存（timestamp|country|city|ip）
└── ip-guard-YYYY-MM-DD.log          # 按天分割的运行日志
```

## 验证是否生效

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

<!-- keywords
Claude account ban Claude Code plugin Claude IP restriction Claude geolocation block
Claude access control Claude Code hooks Anthropic export control OFAC compliance
Claude banned Claude suspended IP-based blocking developer security tool
Claude 403 Claude Code 403 China Claude Code
Claude 封号 Claude Code 封号 Claude 账号安全 Claude 账号被封 Claude 访问受限
Claude 封号原因 Claude 封号解决方案 Claude 防封号 Claude 国内使用 Claude 无法使用
Claude Code 插件 Claude 中国大陆 IP 地理位置检测 IP 访问控制 账号保护
-->