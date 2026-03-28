# claude-ip-guard

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL%20%7C%20Windows%20(Git%20Bash)-blue)](#安装)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Hook%20Plugin-blueviolet)](https://claude.ai/code)

防止 Claude Code 因 IP 地理位置异常导致账号被封的 Hook 插件。

自动检测每次请求的出口 IP — 受限国家直接拦截，新 IP 给出分级警告。

> 如果这个项目对你有帮助，欢迎点个 ⭐ Star — Star 后可及时收到更新通知，我们会持续根据 Anthropic 政策变化和用户反馈迭代优化。

## 功能特性

- **受限国家拦截** — IP 位于受限国家时阻断请求，附带可见提示
- **新 IP 分级警告** — 首次出现的 IP 触发软拦截并给出警告，重新发送即可继续
- **代理场景兼容** — 第三方中转 API 或 VPN 分流时自动识别，不误拦
- **网络故障不误拦** — 任何检测失败均放行，不因网络问题阻断正常使用

![拦截效果](./doc/screenshots/blocked.png)

## 安装

**环境要求**：`bash`、`curl`、`python3`（或 `python`）。支持 macOS、Linux、WSL、Windows（Git Bash）。

**全局安装**（推荐，对本机所有项目生效）：

```bash
git clone https://github.com/cso1z/claude-ip-guard.git
bash claude-ip-guard/install.sh
```

**项目级安装**（仅对当前项目生效）：

```bash
bash claude-ip-guard/install.sh --project
# 或指定路径
bash claude-ip-guard/install.sh --project /path/to/your/project
```

**手动安装**：将 `.claude/scripts/` 复制到项目目录，授权执行后将以下配置合并到 `.claude/settings.json`：

```json
{
  "hooks": {
    "SessionStart": [
      {
        "_ip_guard": true,
        "matcher": "startup|resume",
        "hooks": [{ "type": "command", "command": "bash .claude/scripts/check-ip-on-start.sh", "timeout": 15 }]
      }
    ],
    "UserPromptSubmit": [
      {
        "_ip_guard": true,
        "hooks": [{ "type": "command", "command": "bash .claude/scripts/check-ip-on-prompt.sh", "timeout": 15 }]
      }
    ]
  }
}
```

## 工作原理

挂载 `SessionStart` 和 `UserPromptSubmit` 两个 Hook，在会话启动和每次发送消息前自动检测当前网络环境（直连可达性 + 出口 IP 地理位置），根据结果决定放行或拦截。

## 新 IP 分级警告

出现新 IP 时触发软拦截，根据近 30 天累计出现的不同 IP 数给出分级提示：

| 近 30 天不同 IP 数 | 等级 | 提示前缀 |
|-------------------|------|---------|
| 第 1 个 | — | 直接放行，建立基准，不提示 |
| 第 2～3 个 | 注意 | `[注意]` |
| 第 4～6 个 | 警告 | `[警告]` |
| 第 7 个及以上 | 严重 | `[严重警告]` |

软拦截仅阻止当次消息，**重新发送即可继续**。

> 频繁切换 IP 本身也是封号风险因素之一。分级警告的目的是提醒你关注网络环境的稳定性，而不仅仅是拦截受限地区。等级越高，说明近期 IP 变动越频繁，建议排查原因。

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
| 乌克兰 | `UA` | 俄占区受限，因无法识别具体省份，按整国处理 |

## 验证是否生效

关闭 VPN，直接运行检测脚本，通过日志查看检测结果：

```bash
bash ~/.claude/scripts/check-ip-on-start.sh
cat ~/.cache/claude-ip-guard/ip-guard-$(date '+%Y-%m-%d').log
```

## 常见问题

**Q：会影响 Claude Code 的响应速度吗？**

每次 prompt 先做轻量 IP 比对，命中缓存（IP 相同且 < 10 分钟）直接放行，无网络请求。仅 IP 变化或缓存过期时才发起地理位置查询，正常使用几乎无感知。

**Q：我使用第三方代理（如中转 API），会被误拦吗？**

不会。检测到 `ANTHROPIC_BASE_URL` 指向非官方地址时，自动跳过全部检测，不干预第三方代理用户。

**Q：VPN 分流场景（直连通但地理位置显示受限国家）会怎样？**

会被识别为分流代理场景，正常放行，不写缓存和历史。适用于代理只转发 Anthropic 流量、本地其他流量走直连的情况。

**Q：出现误拦（正常 IP 被拦截）怎么办？**

1. 检查日志确认 IP 和国家代码：`cat ~/.cache/claude-ip-guard/ip-guard-$(date '+%Y-%m-%d').log`
2. 若国家代码有误，可提 Issue 反馈
3. 临时解决：删除 `~/.cache/claude-ip-guard/ip_cache` 清除缓存后重试

**Q：新 IP 软拦截后必须等多久才能继续？**

不需要等待。软拦截仅阻止当次 prompt，**直接重新发送**同一条消息即可继续——第二次发送时 IP 已记入历史，正常放行。

**Q：如何自定义拦截国家？**

编辑 `~/.claude/scripts/ip-guard-lib.sh`（项目级安装则是 `.claude/scripts/ip-guard-lib.sh`），在 `BLOCKED_COUNTRIES` 数组中增减 ISO 代码即可，无需重新安装。

## 贡献

欢迎提交 Issue 和 Pull Request。

- **Bug 报告**：请附上日志文件内容和 `bash --version` 输出
- **新增受限国家**：在 Issue 中说明国家代码和依据，维护者会更新 `ip-guard-lib.sh`
- **其他改进**：建议先开 Issue 讨论方案，再提 PR

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
Claude Code 插件 Claude 中国大陆 IP 地理位置检测 IP 访问控制 账号保护 城市切换 IP 异常
-->