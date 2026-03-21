# claude-ip-guard

English | [中文](./README.zh.md)

A Claude Code hook plugin that blocks access based on IP geolocation. When the current IP is in a restricted country, user prompts are intercepted to prevent account bans.

> Prevent Claude account bans caused by IP geolocation issues · 防止因 IP 地理位置异常导致的 Claude 封号问题

## Features

- **Direct connectivity check** — Tests `api.anthropic.com` first; if reachable, the IP is not blocked and access is granted immediately (no geo query needed)
- **Country blocking** — When direct connection fails, geo lookup determines if the IP is in a restricted country; if so, access is blocked (exit 2, user-visible message)
- **Proxy-aware** — Automatically skips all checks when `ANTHROPIC_BASE_URL` points to a third-party proxy; only native Anthropic connections are inspected
- **Smart caching** — Lightweight IP check on every prompt; full re-check only when IP changes or every 10 minutes
- **Fail-safe** — API failures always allow access (no false blocking due to network issues)
- **Dual geo API** — `ipinfo.io` (HTTPS, primary), `ip-api.com` (HTTP, fallback)
- **Shared library** — Core logic in `ip-guard-lib.sh`, sourced by both hook scripts
- **Global or per-project install** — One command installs to a single project or all projects on the machine

## Blocked Countries

Based on [Anthropic's supported regions](https://www.anthropic.com/supported-countries) and U.S. OFAC export controls:

| Country / Region | ISO Code | Reason |
|------------------|----------|--------|
| China (mainland) | `CN` | Regulatory / geopolitical |
| Russia | `RU` | U.S. sanctions |
| North Korea | `KP` | OFAC sanctions |
| Iran | `IR` | OFAC sanctions |
| Syria | `SY` | OFAC sanctions |
| Cuba | `CU` | OFAC sanctions |
| Belarus | `BY` | Sanctions-related |
| Venezuela | `VE` | Not in supported list |
| Myanmar | `MM` | Not in supported list |
| Libya | `LY` | Not in supported list |
| Somalia | `SO` | Not in supported list |
| Yemen | `YE` | Not in supported list |
| Mali | `ML` | Not in supported list |
| Central African Republic | `CF` | Not in supported list |
| South Sudan | `SS` | Not in supported list |
| DR Congo | `CD` | Not in supported list |
| Eritrea | `ER` | Not in supported list |
| Afghanistan | `AF` | Not in supported list |
| Ukraine | `UA` | Russian-occupied regions restricted; full-country blocked (script cannot filter sub-regions) |

To customize, edit `BLOCKED_COUNTRIES` in `ip-guard-lib.sh`.

## How It Works

```
Both hooks — Precondition
└── ANTHROPIC_BASE_URL set and ≠ "https://api.anthropic.com"?
    └── YES → skip all checks (third-party proxy, no intervention needed)
    └── NO  → continue (native Anthropic connection)

SessionStart (every session)
└── Test direct connection to api.anthropic.com
    ├── Reachable → write cache (timestamp|||ip) → exit 0
    │   (reachable = outbound IP is not blocked, no geo query needed)
    └── Not reachable → full geo query (ipinfo.io → ip-api.com fallback)
          ├── Query failed    → fail-safe, exit 0 (no cache written)
          ├── IP in blocklist → exit 2, show block message (no cache written)
          └── IP not blocked  → fail-safe, exit 0 (no cache written)

UserPromptSubmit (every prompt)
└── Lightweight query: get current public IP only
    └── Query failed → fail-safe, exit 0
└── Read cache
    ├── IP same + cache < 10min → exit 0 (cached IP = already validated)
    └── IP changed or cache expired → re-run full check (same as SessionStart)
```

> **Note:** Claude Code does not display `stderr` from `SessionStart` hooks, and `exit 2` does not prevent the session from starting. All user-visible blocking is handled by the `UserPromptSubmit` hook (triggered when the user sends their first message).

## Requirements

- `bash`
- `curl`
- `python3` or `python`

Supported platforms: macOS, Linux, WSL, **Windows (Git Bash)**. Native Windows CMD/PowerShell is not supported.

### Windows — Git Bash setup

The scripts require a bash environment. On Windows, [Git for Windows](https://git-scm.com/download/win) provides Git Bash, which includes `bash`, `curl`, and `grep` — no WSL needed.

**Step 1 — Install Git for Windows**

Download and run the installer. On the "Adjusting your PATH environment" screen, select **"Git from the command line and also from 3rd-party software"** to add `bash` to PATH.

**Step 2 — Install Python**

Download Python from [python.org](https://www.python.org/downloads/windows/) and run the installer. Check **"Add Python to PATH"** before clicking Install.

> The scripts auto-detect whether to use `python3` or `python`, so both naming conventions work.

**Step 3 — Open Git Bash and run the installer**

Right-click any folder in Explorer and select **"Git Bash Here"**, then run:

```bash
git clone https://github.com/your-username/claude-ip-guard.git
bash claude-ip-guard/install.sh --global
```

**Step 4 — Verify**

```bash
bash ~/.claude/scripts/check-ip-on-prompt.sh
# Expected: exits cleanly (code 0)

cat ~/.cache/claude-ip-guard/ip-guard-$(date '+%Y-%m-%d').log
# Expected: a "直连可达" or "放行" log line with your IP
```

> All subsequent `bash` and `git clone` commands in this README should be run inside Git Bash, not CMD or PowerShell.

## Installation

### Global install (applies to all projects on this machine)

> **Windows users**: Run the commands below in **Git Bash**, not CMD or PowerShell. Right-click any folder and select "Git Bash Here" to open it.

```bash
git clone https://github.com/your-username/claude-ip-guard.git
bash claude-ip-guard/install.sh --global
```

Scripts are copied to `~/.claude/scripts/` and hooks use absolute paths.

### Project install (applies to one project only)

```bash
bash claude-ip-guard/install.sh /path/to/your/project

# or install into the current directory
bash claude-ip-guard/install.sh
```

Scripts are copied to `.claude/scripts/` and hooks use relative paths.

The installer will:
1. Copy `ip-guard-lib.sh`, `check-ip-on-start.sh`, `check-ip-on-prompt.sh` to the target scripts directory
2. Generate the correct hook config with matching paths
3. Create `settings.json` if it doesn't exist, or automatically merge hooks into the existing file (existing config is preserved)
4. Restart Claude Code to apply

### Manual install

1. Copy `.claude/scripts/` to your project's `.claude/scripts/`
2. Grant execute permissions:
   ```bash
   chmod +x .claude/scripts/*.sh
   ```
3. Merge the hook config into `.claude/settings.json`:
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
4. Restart Claude Code

## File Structure

```
claude-ip-guard/
├── install.sh                      # Installer (--global or project)
├── doc/
│   └── ip-access-control-design.md # Full design document
└── .claude/
    ├── settings.json               # Hook configuration template
    └── scripts/
        ├── ip-guard-lib.sh         # Shared library: connectivity, geo, cache, blocking
        ├── check-ip-on-start.sh    # SessionStart hook
        └── check-ip-on-prompt.sh   # UserPromptSubmit hook
```

**Runtime cache** (local, not committed):

```
~/.cache/claude-ip-guard/
├── ip_cache                        # Current IP cache (timestamp|country|city|ip)
└── ip-guard-YYYY-MM-DD.log         # Daily log files
```

## Verify Installation

**Step 1 — Find your current country code**

Check [https://ipinfo.io/json](https://ipinfo.io/json) and note the `country` field, e.g. `"country": "SG"`.

**Step 2 — Temporarily add it to the block list**

Open `.claude/scripts/ip-guard-lib.sh` (or `~/.claude/scripts/ip-guard-lib.sh` for global install) and add your country code:

```bash
BLOCKED_COUNTRIES=(
    "CN"
    "RU"
    # ... existing entries ...
    "SG"  # ← add your country code here for testing
)
```

**Step 3 — Restart Claude Code and send any message**

You should see the following block message when submitting a prompt:

![Block message screenshot](./doc/screenshots/blocked.png)

**Step 4 — Remove the test entry**

Delete the line you added in Step 2 and save. The block is lifted immediately on the next prompt.

---

## Team Sharing

Commit `.claude/settings.json` and `.claude/scripts/` to your repository. All team members who pull the repo will have the hooks automatically applied.

Members can override locally via `.claude/settings.local.json` (not committed).

## APIs Used

| API | Purpose | Protocol |
|-----|---------|----------|
| `api.anthropic.com` | Direct connectivity check (primary gate) | HTTPS |
| `api.ipify.org` | Lightweight IP lookup (every prompt) | HTTPS |
| `ipinfo.io` | Full geo query — primary | HTTPS |
| `ip-api.com` | Full geo query — fallback | HTTP |

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