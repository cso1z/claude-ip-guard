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

## 触发逻辑

```
SessionStart（会话启动，每次必检）
    └── 读取旧缓存，获取上次已通过的城市（old_city）
    └── 调用完整 IP 地理查询接口，获取 ip / country / region / city / org
    └── 写入新缓存（覆盖旧值，供后续 PROMPT hook 复用）
    └── 执行禁止名单检查 + 城市变化检测
         ※ 注意：Claude Code 不展示 SessionStart 的 stderr，exit 2 也不阻断会话启动
         ※ 真正对用户可见的拦截发生在 UserPromptSubmit（用户发第一条消息时）

UserPromptSubmit（每次用户发送消息前）
    └── 轻量查询：仅获取当前公网 IP（api.ipify.org，开销极小）
    │
    ├── IP 相同 且 缓存未过期（< 10min）
    │   └── 复用缓存结论，做禁止名单检查
    │   └── 命中禁止名单 → exit 2（用户可见，阻止当前 prompt）
    │   └── 通过 → exit 0
    │
    ├── IP 不同
    │   └── 立即调用完整地理查询（不等 10min）
    │   └── 更新缓存，执行禁止名单 + 城市变化检测
    │
    └── IP 相同 但 缓存已过期（>= 10min）
        └── 重新调用完整地理查询，更新缓存
        └── 执行禁止名单 + 城市变化检测
```

### 关键设计点

- **IP 变化优先**：IP 一旦变化，立即触发地理查询，不受 10min 限制
- **10min 兜底**：即使 IP 未变，每 10min 也强制重查一次，防止记录过时
- **两步查询分离**：
  - 轻量查询（仅获取当前 IP）：每次 prompt 都执行，开销极小
  - 完整查询（含地理信息）：仅在 IP 变化或超时时执行，减少接口调用
- **Fail-safe**：所有接口不可用时一律放行，避免网络故障误拦截
- **SessionStart 缓存联动**：SessionStart 负责更新缓存；由于 Claude Code 不展示 SessionStart 的 stderr 且 exit 2 不阻断会话，真正对用户可见的拦截统一在 UserPromptSubmit 阶段完成（用户发第一条消息时触发）

---

## 拦截行为

- **拦截方式**：Hook 脚本返回 `exit code 2`，Claude Code 将 stderr 内容展示给用户
- **国家拦截提示**：

  ```
  [访问受限] 检测到您当前的网络 IP（{IP}）位于受限地区（{COUNTRY_CODE}），
  无法使用 Claude。请切换网络后重试。
  ```

- **城市切换提示**（不拦截访问，仅警告，见下方分级）
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

- **缓存有效期**：10 分钟（600 秒），IP 变化时立即失效
- **异常处理**：接口请求失败时**放行**用户（不因网络问题误拦截），并记录日志

---

## IP 城市切换异常检测

### 触发条件

每次完整地理查询后执行以下逻辑：

- **城市发生变化** 且该 IP 不在历史中 → 写入历史，展示分级警告（exit 2 阻止当前 prompt，重新发送后可继续）
- **城市未变化** 且该 IP 为首次出现 → 静默写入历史（仅记录，不提示用户）
- **IP 已在历史中** → 不重复写入，不提示

### 历史记录

- 记录每次城市切换的完整信息，保留最近 **30 天**
- 存储位置：`~/.cache/claude-ip-guard/ip_history.jsonl`（每行一条 JSON）
- 记录字段：

  ```json
  {
    "time": "2026-03-20 10:00:01",
    "ip": "192.166.82.233",
    "country": "US",
    "region": "Utah",
    "city": "Salt Lake City",
    "org": "EFUsoft LLC"
  }
  ```

- **去重规则**：按 IP 去重，同一 IP 不重复写入历史（即使城市变化）

### 提示展示格式

提示内容包含两部分：

1. **等级警告语**（根据当日城市切换次数）
2. **最近 30 天 IP 历史表格**

```
[提示] 检测到网络城市发生变化（北京 → Salt Lake City），请确认网络环境正常。

最近 30 天 IP 使用记录：
  时间                  IP                 完整地址
  --------------------------------------------------------------------------------
  2026-03-20 10:00:01  192.166.82.233     US · Utah · Salt Lake City (EFUsoft LLC)
  2026-03-19 08:30:00  1.2.3.4            CN · 北京市 · 北京 (China Telecom)
```

### 切换次数与提示等级

统计范围：`ip_history.jsonl` 中的全部条目数（文件本身只保留近 30 天，因此等同于近 30 天总计）。城市变化时在写入前取值 +1 作为展示次数。

| 切换次数（近 30 天） | 等级 | 提示语 |
|---------------------|------|--------|
| 第 1 次 | 信息 | `[提示] 检测到网络城市发生变化（{旧城市} → {新城市}），请确认网络环境正常。` |
| 第 2～3 次 | 注意 | `[注意] 近 30 天已发生 {N} 次城市切换（{旧城市} → {新城市}），请检查网络是否稳定。` |
| 第 4～6 次 | 警告 | `[警告] 近 30 天城市切换次数异常（{N} 次），存在账号安全风险，请确认是本人操作。` |
| 第 7 次及以上 | 严重 | `[严重警告] 近 30 天城市切换次数过高（{N} 次），账号可能存在异常使用，强烈建议立即排查。` |

> 城市切换警告通过 exit 2 触发，当前 prompt **不会被 Claude 处理**；用户重新发送 prompt 后可正常继续使用。

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
| IP 接口超时/不可用 | 设置 5s 超时，失败时放行（fail-safe），避免误拦截 |
| VPN 导致 IP 不准确 | 属于预期行为，IP 层面无法区分 VPN |
| 缓存文件损坏 | 时间戳格式校验，异常时强制重查；历史文件原子写入（`os.replace`） |
| SessionStart exit 2 不可见 | SessionStart 负责写缓存；PROMPT hook 负责可见拦截（用户发第一条消息时生效） |
| 脚本权限问题 | `install.sh` 自动执行 `chmod +x`，手动安装需确保有执行权限 |
| 团队成员本地覆盖 | 可在 `settings.local.json` 中覆盖（该文件不提交仓库） |
| Windows 兼容性 | 脚本依赖 bash + python3，支持 macOS / Linux / WSL；纯 Windows CMD 不支持 |

---

## 实现清单

- [x] `ip-guard-lib.sh` 共享库（查询、缓存、历史、拦截）
- [x] `check-ip-on-start.sh` SessionStart hook
- [x] `check-ip-on-prompt.sh` UserPromptSubmit hook
- [x] `.claude/settings.json` Hook 配置
- [x] `install.sh` 安装脚本
- [x] 按天分割日志（`~/.cache/claude-ip-guard/ip-guard-YYYY-MM-DD.log`）
- [x] 缓存迁移至 `~/.cache/claude-ip-guard/`
- [x] IP 历史记录写入 `ip_history.jsonl`
- [x] 30 天历史清理（原子写入）
- [x] 城市切换检测与去重（按 IP 去重）
- [x] 分级提示语（1 次 / 2-3 次 / 4-6 次 / 7+ 次）
- [x] 历史记录表格格式化展示