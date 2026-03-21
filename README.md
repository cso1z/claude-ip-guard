# claude-ip-guard

English | [中文](./README.zh.md)

A Claude Code hook plugin that blocks access based on IP geolocation and direct connectivity. Intercepts user prompts when the current IP is in a restricted country, and soft-blocks on new unrecognized IPs.

> Prevent Claude account bans caused by IP geolocation issues · 防止因 IP 地理位置异常导致的 Claude 封号、账号被封问题

## Features

- **Proxy-aware** — Automatically skips all checks when `ANTHROPIC_BASE_URL` points to a third-party proxy; only native Anthropic connections are inspected
- **Direct connectivity check** — Tests `api.anthropic.com` on every check; result (`direct_ok`) determines the blocking strategy
- **Country blocking** — When direct connection fails and IP is in a restricted country, access is hard-blocked (exit 2, user-visible message)
- **Split-tunnel detection** — When direct connection succeeds but geo shows a restricted country, treats it as a split-tunnel proxy and allows access without writing cache/history
- **New IP soft-block** — When direct connection succeeds and a new unrecognized IP appears, soft-blocks with a graded warning; user can resend to continue
- **30-day IP history** — Records each unique IP once; deduplicates by IP address
- **Smart caching** — Lightweight IP check on every prompt; cache hit (same IP, < 10 min) skips all network checks
- **Fail-safe** — Any query failure always allows access (no false blocking due to network issues)
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
└── Direct connectivity test → api.anthropic.com → record direct_ok
└── Geo query (ipinfo.io → ip-api.com fallback) — always runs
    └── Failed → fail-safe, exit 0
    └── direct_ok=false + IP in blocklist → exit 2 hard-block
    └── direct_ok=false + IP not blocked  → fail-safe, exit 0
    └── direct_ok=true  + IP in blocklist → split-tunnel, exit 0 (no cache/history)
    └── direct_ok=true  + IP not blocked  → check IP history
        ├── IP known → write cache → exit 0
        └── IP new   → write history + graded warning → exit 2 soft-block

UserPromptSubmit (every prompt)
└── Lightweight query: get current public IP
    └── Failed → fail-safe, exit 0
└── Cache check: IP same + cache < 10min → exit 0 (already validated)
└── Otherwise → direct test + geo query → same logic as SessionStart
```

> **Note:** Claude Code does not display `stderr` from `SessionStart` hooks, and `exit 2` does not prevent the session from starting. All user-visible blocking is handled by the `UserPromptSubmit` hook (triggered on the user's first message).

## New IP Alerts

When a new unrecognized IP appears (direct connection succeeds, IP not in restricted countries), a graded warning is shown via exit 2. The current prompt is blocked; the user can **resend to continue** (on resend the IP is already in history and passes through):

| Unique IPs (last 30 days) | Level | Message prefix |
|---------------------------|-------|----------------|
| 1st | Info | `[提示]` |
| 2nd – 3rd | Notice | `[注意]` |
| 4th – 6th | Warning | `[警告]` |
| 7th+ | Critical | `[严重警告]` |

Each alert includes a formatted table of the last 30 days of IP history.

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
bash claude-ip-guard/install.sh
```

**Step 4 — Verify**

```bash
bash ~/.claude/scripts/check-ip-on-prompt.sh
# Expected: exits cleanly (code 0)

cat ~/.cache/claude-ip-guard/ip-guard-$(date '+%Y-%m-%d').log
# Expected: a "放行" (allowed) log line with your IP and country
```

> All subsequent `bash` and `git clone` commands in this README should be run inside Git Bash, not CMD or PowerShell.

## Installation

### Global install (applies to all projects on this machine, default)

> **Windows users**: Run the commands below in **Git Bash**, not CMD or PowerShell. Right-click any folder and select "Git Bash Here" to open it.

```bash
git clone https://github.com/your-username/claude-ip-guard.git
bash claude-ip-guard/install.sh          # no flag = global (recommended)
# or explicitly
bash claude-ip-guard/install.sh --global
```

Scripts are copied to `~/.claude/scripts/` and hooks use absolute paths.

### Project install (applies to one project only)

```bash
# install into the current directory
bash claude-ip-guard/install.sh --project

# install into a specific project
bash claude-ip-guard/install.sh --project /path/to/your/project
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
├── install.sh                      # Installer (global by default, --project for per-project)
├── doc/
│   └── ip-access-control-design.md # Full design document
└── .claude/
    ├── settings.json               # Hook configuration template
    └── scripts/
        ├── ip-guard-lib.sh         # Shared library: queries, cache, history, blocking
        ├── check-ip-on-start.sh    # SessionStart hook
        └── check-ip-on-prompt.sh   # UserPromptSubmit hook
```

**Runtime cache** (local, not committed):

```
~/.cache/claude-ip-guard/
├── ip_cache                        # Current IP cache (timestamp|country|city|ip)
├── ip_history.jsonl                # IP change history (30-day retention, JSONL)
└── ip-guard-YYYY-MM-DD.log         # Daily log files
```

## Verify Installation

Follow these steps to confirm the hooks are working correctly.

**Step 1 — Find your current country code**

Check your current IP's country code at [https://ipinfo.io/json](https://ipinfo.io/json). Look for the `country` field, e.g. `"country": "SG"`.

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

Delete the line you added in Step 2, save the file. The block is lifted immediately on the next prompt.

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
Claude Code 插件 Claude 中国大陆 IP 地理位置检测 IP 访问控制 账号保护 城市切换 IP 异常
-->