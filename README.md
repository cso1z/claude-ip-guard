# claude-ip-guard

English | [中文](./README.zh.md)

A Claude Code hook plugin that blocks access based on IP geolocation. Intercepts user prompts when the current IP is located in a restricted country or region, and warns users when frequent city switching is detected.

## Features

- **Country blocking** — Blocks access for IPs in restricted countries (exit 2, user-visible message)
- **City-switch detection** — Warns users when network location changes, with graded alerts based on 30-day switch history
- **Smart caching** — Lightweight IP check on every prompt; full geo query only when IP changes or every 10 minutes
- **30-day IP history** — Records all IP changes with full geo info; deduplicates by IP
- **Fail-safe** — API failures always allow access (no false blocking due to network issues)
- **Dual API** — `ipinfo.io` (HTTPS, primary), `ip-api.com` (HTTP, fallback)
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
SessionStart (every session)
└── Read old cache → get previous city (old_city)
└── Full geo query: ip / country / region / city / org
└── Write new cache → for reuse by PROMPT hook
└── Country blocked?  → exit 2 (not visible in Claude Code UI*)
└── City changed?     → exit 2 (not visible in Claude Code UI*)

    * Real user-visible blocking happens on the first UserPromptSubmit

UserPromptSubmit (every prompt)
└── Lightweight query: get current public IP only
    │
    ├── IP same + cache < 10min
    │   └── Reuse cache → check blocked list → exit 2 if blocked (visible)
    │
    ├── IP changed
    │   └── Immediate full geo query → update cache
    │   └── Check blocked + city change → exit 2 if triggered (visible)
    │
    └── IP same + cache >= 10min
        └── Full geo query → update cache
        └── Check blocked + city change → exit 2 if triggered (visible)
```

> **Note:** Claude Code does not display `stderr` from `SessionStart` hooks, and `exit 2` does not prevent the session from starting. All user-visible blocking is handled by the `UserPromptSubmit` hook.

## City-Switch Alerts

When a city change is detected and the IP is not in history, a graded warning is shown (via exit 2 — the current prompt is blocked; the user can resend to continue):

| Switches (last 30 days) | Level | Message prefix |
|-------------------------|-------|----------------|
| 1 | Info | `[提示]` |
| 2 – 3 | Notice | `[注意]` |
| 4 – 6 | Warning | `[警告]` |
| 7+ | Critical | `[严重警告]` |

Each alert includes a formatted table of the last 30 days of IP history.

## Requirements

- `bash`
- `curl`
- `python3`

Supported platforms: macOS, Linux, WSL. Native Windows (CMD/PowerShell) is not supported.

## Installation

### Global install (applies to all projects on this machine)

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
| `api.ipify.org` | Lightweight IP lookup (every prompt) | HTTPS |
| `ipinfo.io` | Full geo query — primary | HTTPS |
| `ip-api.com` | Full geo query — fallback | HTTP |

## License

MIT