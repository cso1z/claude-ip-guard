# IP 地理位置访问控制 - 方案设计

## 需求概述

在 Claude Code 使用过程中，通过检测用户当前 IP 的地理位置，若 IP 归属于禁止国家列表，则拦截用户的所有输入任务，阻止其使用 Claude。

---

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

> 后续如需扩展，在 `ip-guard-lib.sh` 的 `BLOCKED_COUNTRIES` 变量中追加 ISO 代码即可。

---

## 前置判断（两个 Hook 共用）

每个 Hook 执行的第一步：

```
ANTHROPIC_BASE_URL 已设置 且 ≠ "https://api.anthropic.com"？
  └── YES → exit 0，跳过全部检查（用户使用第三方代理，无需保护）
  └── NO  → 继续执行（原生直连场景，需要检测）
```

> `ANTHROPIC_BASE_URL` 未设置，或显式设为 `https://api.anthropic.com`，均视为原生直连。

---

## 触发逻辑

```
SessionStart（会话启动，每次必检）
    └── 前置判断：非原生直连 → exit 0
    └── 直连测试：curl api.anthropic.com
         ├── 可达 → 写入缓存（timestamp|ip）→ exit 0
         │    ※ 可达说明出口 IP 未被封，无需进一步地理查询
         └── 不可达 → 调用完整 IP 地理查询（ipinfo.io 主 → ip-api.com 备）
               ├── 查询失败      → fail-safe，exit 0（不写缓存）
               ├── IP 在禁用区   → exit 2，输出拦截提示（不写缓存）
               └── IP 不在禁用区 → fail-safe，exit 0（不写缓存）
         ※ Claude Code 不展示 SessionStart 的 stderr，exit 2 也不阻断会话启动
         ※ 真正对用户可见的拦截发生在 UserPromptSubmit（用户发第一条消息时）

UserPromptSubmit（每次用户发送消息前）
    └── 前置判断：非原生直连 → exit 0
    └── 轻量查询：仅获取当前公网 IP（api.ipify.org，开销极小）
         └── 查询失败 → fail-safe，exit 0
    │
    ├── IP 与缓存相同 且 缓存未过期（< 10min）
    │   └── exit 0（缓存中的 IP 即已验证通过，无需重查）
    │
    └── IP 变化 或 缓存过期（>= 10min）或 无缓存
        └── 直连测试：curl api.anthropic.com
             ├── 可达 → 写入缓存（timestamp|ip）→ exit 0
             └── 不可达 → 调用完整 IP 地理查询
                   ├── 查询失败      → fail-safe，exit 0（不写缓存）
                   ├── IP 在禁用区   → exit 2，输出拦截提示（不写缓存）
                   └── IP 不在禁用区 → fail-safe，exit 0（不写缓存）
```

### 关键设计点

- **非原生直连跳过**：用户配置了第三方代理时，跳过全部检查，不干预其网络选择
- **直连优先**：直连可达即放行，无需地理查询；直连不可达才触发 geo 作为辅助判断
- **可达即安全**：`api.anthropic.com` 可达说明出口 IP 未被封禁，地理查询在此场景下冗余
- **缓存即白名单**：缓存只在直连成功时写入，缓存中的 IP 即已验证通过，复用时无需再查
- **IP 变化或超期重检**：IP 一旦变化立即重走完整流程；即使 IP 未变，10min 后也强制重检
- **Fail-safe**：地理查询接口不可用，或查询结果显示 IP 不在禁用区，均放行
- **SessionStart 缓存联动**：SessionStart 直连成功时写缓存；UserPromptSubmit 复用，实现会话内快速放行

---

## 拦截行为

- **拦截方式**：Hook 脚本返回 `exit code 2`，Claude Code 将 stderr 内容展示给用户
- **国家拦截提示**：

  ```
  [访问受限] 检测到您当前的网络 IP（{IP}）位于受限地区（{COUNTRY_CODE}），
  无法使用 Claude。请切换网络后重试。
  ```

- **不拦截时**：脚本正常退出（exit 0），用户无感知

---

## IP 查询接口

使用公共免费接口，无需 API Key。

### 接口验证结果（2026-03-20）

| 接口 | 类型 | 验证结果 | 说明 |
|------|------|----------|------|
| `https://api.ipify.org?format=json` | 轻量（仅 IP） | ✅ 可用 | 返回 `{"ip":"..."}` |
| `https://ipapi.co/json/` | 完整地理 | ❌ 不可用 | 免费版频繁触发 RateLimit |
| `https://ip-api.com/json/`（HTTPS） | 完整地理 | ❌ 不可用 | HTTPS 需付费 key |
| `http://ip-api.com/json/`（HTTP） | 完整地理 | ✅ 可用 | 免费但无 HTTPS，45次/分钟 |
| `https://ipinfo.io/json` | 完整地理 | ✅ 可用 | 支持 HTTPS，返回 `country` 字段 |
| `https://freeipapi.com/api/json` | 完整地理 | ❌ 不稳定 | 响应超时 |

### 最终选型

- **轻量查询**（每次 prompt 获取当前 IP）：`https://api.ipify.org?format=json`
  - 返回字段：`ip`
- **完整地理查询**（IP 变化或超时时触发）：`https://ipinfo.io/json`（主）
  - 返回字段：`ip`、`country`（ISO 代码）、`region`、`city`、`org`
  - Fallback：`http://ip-api.com/json/`，对应字段 `query`、`countryCode`、`regionName`、`city`、`isp`

---

## 缓存机制

- **缓存文件路径**：`~/.cache/claude-ip-guard/ip_cache`
- **文件内容格式**（管道分隔，4 字段）：

  ```
  1742380000|US|Salt Lake City|192.168.1.1
  [Unix时间戳]|[country_code]|[city]|[ip]
  ```

  > 直连成功时 country/city 为空（未做地理查询）：`1742380000|||192.168.1.1`

- **写入时机**：仅在直连 `api.anthropic.com` 成功时写入；拦截路径（exit 2）和 fail-safe 路径均不写缓存
- **缓存即白名单**：缓存中的 IP 代表已通过直连验证，`UserPromptSubmit` 命中时无需重查，直接放行
- **缓存有效期**：10 分钟（600 秒）；IP 变化或过期时，重走完整检测流程
- **异常处理**：地理查询接口失败时**放行**用户（fail-safe），不因网络故障误拦截

---


## 文件结构

```
claude-ip-guard/
├── install.sh                     # 安装脚本（复制到目标项目）
├── doc/
│   └── ip-access-control-design.md
└── .claude/
    ├── settings.json              # Hook 配置（团队共享，提交至仓库）
    └── scripts/
        ├── ip-guard-lib.sh        # 共享库：查询、缓存、历史、拦截逻辑
        ├── check-ip-on-start.sh   # SessionStart hook：每次会话必检
        └── check-ip-on-prompt.sh  # UserPromptSubmit hook：轻量比对 + 按需重检
```

**运行时缓存目录**（本地，不提交）：

```
~/.cache/claude-ip-guard/
├── ip_cache                   # 当前 IP 缓存（timestamp|country|city|ip）
├── ip_history.jsonl           # IP 变化历史（最近 30 天，JSONL 格式）
├── ip-guard-2026-03-20.log    # 当日运行日志（按天分割）
└── ...
```

---

## Hook 配置

**团队共享**，配置写入项目根目录 `.claude/settings.json`，所有拉取该仓库的成员自动生效：

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/scripts/check-ip-on-start.sh",
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
            "command": "bash .claude/scripts/check-ip-on-prompt.sh",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

> 成员可在 `.claude/settings.local.json` 中覆盖配置（不提交至仓库）。

---

## 安装方式

```bash
# 克隆 claude-ip-guard
git clone https://github.com/your-org/claude-ip-guard.git
```

### 项目级安装（仅对当前项目生效）

```bash
# 安装到指定项目
bash claude-ip-guard/install.sh /path/to/your-project

# 安装到当前目录
bash claude-ip-guard/install.sh
```

脚本写入 `.claude/scripts/`，Hook 命令使用相对路径 `bash .claude/scripts/check-ip-on-start.sh`。

### 全局安装（对所有项目生效）

```bash
bash claude-ip-guard/install.sh --global
```

脚本写入 `~/.claude/scripts/`，Hook 命令使用绝对路径 `bash ~/.claude/scripts/check-ip-on-start.sh`，无需在每个项目中重复安装。

---

`install.sh` 会：
1. 复制三个脚本（`ip-guard-lib.sh` / `check-ip-on-start.sh` / `check-ip-on-prompt.sh`）到目标 `.claude/scripts/`
2. 按安装模式生成对应路径的 Hook 配置
3. 若目标 `settings.json` 不存在，自动创建；若已存在，用 python3 自动合并 hooks（保留原有配置不变，相同命令不重复写入）
4. 重启 Claude Code 后生效

---

## 风险与注意事项

| 风险 | 应对策略 |
|------|---------|
| 直连测试超时影响体验 | 设置 5s connect-timeout，最坏等待 5s 后进入 geo 查询 |
| IP 接口超时/不可用 | 设置 5s 超时，失败时 fail-safe 放行，避免误拦截 |
| 用户配置了第三方代理但仍是原生地址 | 前置判断仅跳过明确非 Anthropic 的地址，原生地址仍受保护 |
| 缓存文件损坏 | 时间戳格式校验，异常时强制重走完整流程 |
| SessionStart exit 2 不可见 | SessionStart 负责写缓存；PROMPT hook 负责可见拦截（用户发第一条消息时生效） |
| 脚本权限问题 | `install.sh` 自动执行 `chmod +x`，手动安装需确保有执行权限 |
| 团队成员本地覆盖 | 可在 `settings.local.json` 中覆盖（该文件不提交仓库） |
| Windows 兼容性 | 脚本依赖 bash + python3，支持 macOS / Linux / WSL / Git Bash；纯 Windows CMD 不支持 |

---

## 实现清单

- [x] `ip-guard-lib.sh` 共享库（查询、缓存、拦截）
- [x] `check-ip-on-start.sh` SessionStart hook
- [x] `check-ip-on-prompt.sh` UserPromptSubmit hook
- [x] `.claude/settings.json` Hook 配置
- [x] `install.sh` 安装脚本
- [x] 按天分割日志（`~/.cache/claude-ip-guard/ip-guard-YYYY-MM-DD.log`）
- [ ] 前置判断：`ANTHROPIC_BASE_URL` 非原生时跳过检查
- [ ] 直连测试：`api.anthropic.com` 可达时直接放行
- [ ] 缓存写入时机收窄：仅直连成功时写入
- [ ] `UserPromptSubmit` 缓存命中逻辑简化：IP 相同即放行，无需禁用区二次判断
- [ ] 移除城市切换检测相关逻辑（`ip_history.jsonl`、`process_geo_result` 城市部分）