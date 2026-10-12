# QQ UIA 自动化框架 — 设计文档

> 版本：v0.2　日期：2026-09-18
> v0.2 落地内容：账号体系（`accounts` 命令 + `-Account` 寻址）、配置 UI（`qq-config-ui.ps1`）、
> search 重构（综合搜索面板 / 去重 / Escape 收尾）、缺陷修复（DPI 双重换算、限频时间戳文化 bug、
> 选择器锚定、quiet-period 截断）。v0.1 的规划稿内容保留在 §9 路线图里作为对照。
> 实测依据：旧项目文档 `README-QQNT-UIA.md`（QQNT 9.9.35-52892，Windows 11 / PowerShell 5.1；该文档为历史资料，未收入本仓库）
> 现有资产：13 个历史脚本，已封存于本仓库 `archive/`

---

## 1. 背景与现状

QQNT 9.9.x 是 Electron/Chromium 应用，UIA 支持呈两种状态：默认惰性（无障碍树仅 9 个空骨架节点），激活后（`--force-renderer-accessibility` 或 UIA 客户端连接后等待）可达 557+ 节点，能力覆盖读会话列表、读消息、点击、滚动、搜索框写入。CDP 路线已被 QQ 明确封锁（启动器剥离 `--remote-debugging-port`），**UIA + SendInput 是唯一可用且未被拦截的自动化通道**。

现有 13 个 PowerShell 脚本已完成技术验证，但处于"探查期"形态，直接暴露给 agent 使用存在结构性风险：

| 现状问题 | 后果 | 框架对策（本文档） |
|---|---|---|
| 入口分散，13 个脚本各自为政 | agent 选错脚本、用错参数 | 单一入口 dispatcher + 子命令（§4） |
| 输出为人类可读文本（`Write-Host` 表格） | agent 只能靠正则猜结果 | 统一 JSON 输出契约（§5） |
| `qq-step2-send.ps1` 硬编码 `SenderPid = 86324` | 换机器/换账号即发错人 | SenderPid 运行时发现，禁止默认值（§6） |
| `qq-step2-send.ps1` 中 `-Message` 为空时**默认发送"早上好，主人。"** | 参数漏传照样发车 | Message 必填，空值即拒绝（§6） |
| 护栏只存在于 step2 一个脚本 | 未来新命令可能漏护栏 | 护栏上收到核心层，不可绕过（§6） |
| `archive/` 下保留有无护栏旧脚本，曾致误发 | agent 误调用 | 封存隔离 + 手册明令禁止（§8） |
| CSS class 选择器散落在各脚本 | QQ 升级后逐文件修改 | 选择器集中外置（§7） |

## 2. 设计目标与非目标

**目标**

1. **单一入口**：agent 只调用 `qq-uia.ps1 <command>`，不关心内部脚本布局。
2. **机器可读**：所有命令 stdout 输出单个 JSON 对象，退出码语义化（§5）。
3. **护栏内建**：发送安全校验在框架核心层强制，任何命令路径不可绕过（§6）。
4. **只读/写入分级**：命令按副作用分级，agent 手册按级别规定使用规则（§4）。
5. **agent 零样本上手**：配套《Agent 任务手册》自包含全部 SOP、错误码与陷阱（见 `AGENT-MANUAL.md`）。

**非目标（本期不做）**

- 不做新消息推送/监听（`StructureChanged` 事件订阅未实测，列为后续里程碑）。
- 不做图片/文件/红包等非纯文本消息的发送。
- 不触碰 CDP、QQ 内部 IPC（9210–9212 端口）、任何注入式手段。
- 不做多账号并发操作（多开场景仅支持"显式指定一个实例"）。
- 不做反风控对抗：不模拟打字速度抖动、不伪造任何客户端特征，仅通过手册约束操作频率。

## 3. 总体架构

三层结构，自上而下依赖，反向禁止：

```
┌─────────────────────────────────────────────────┐
│ Agent 层（Kimi Code 等）                          │
│   通过 Bash 调用 qq-uia.ps1，解析 JSON，           │
│   流程与安全红线遵循 AGENT-MANUAL.md               │
├─────────────────────────────────────────────────┤
│ 命令层  qq-uia.ps1 <command> [params]            │
│   参数校验 → 分发 commands/<command>.ps1          │
│   → 统一 JSON 封装与退出码                         │
├─────────────────────────────────────────────────┤
│ 核心层  lib/                                     │
│   qq-core.ps1     UIA 枚举/定位/DPI 换算/聚焦/等待  │
│   qq-guards.ps1   发送护栏（Assert-* 系列）         │
│   qq-json.ps1     JSON 契约序列化                  │
│   selectors.psd1  全部 CSS class 选择器（外置数据） │
└─────────────────────────────────────────────────┘
运行环境：Windows + PowerShell 5.1 + .NET UIAutomation + QQNT 9.9.x
```

关键决策：

- **继续用 PowerShell 5.1 + .NET UIA**，不引入 Python/C# 编译层。实测脚本全部基于该栈，UIA COM/.NET 绑定在 PS 5.1 下已验证可用，重写无任何收益。
- **dispatcher 与子命令同进程执行**（`. ` dot-source），避免每次调用重复加载程序集的开销；子命令文件只定义函数，dispatcher 统一调用。
- **选择器外置**为 `selectors.psd1`（PowerShell 数据文件），QQ 版本升级导致 class 漂移时只改一个文件，`doctor` 命令负责校验选择器健康度（§4）。

## 4. 命令面设计（v1 命令面 + v0.2 增量）

### 4.1 副作用分级

| 级别 | 定义 | agent 使用规则 |
|---|---|---|
| L0 只读 | 不改变 QQ 任何 UI 状态 | 自由调用 |
| L1 界面变更 | 切换窗口/触发搜索/截图，不产生对外消息 | 确认目标后调用 |
| L2 对外写入 | 发送消息，**不可撤销** | 必须走两阶段 SOP（见手册 §4） |

### 4.2 命令清单

| 子命令 | 级别 | 来源脚本 | 功能 | 关键返回字段（data） |
|---|---|---|---|---|
| `doctor` | L0 | qq-uia-live-inspect + qq-recon | 环境体检：QQ 进程、登录态、a11y 激活度（节点数）、选择器健康度、配置告警 | `instances[]`, `a11yActive`, `nodeCount`, `selectorHealth`, `selectorDrift`, `selectorOptionalMiss`, `configWarnings[]`, `ready` |
| `identify` | L0 | qq-identify | 枚举全部 QQ 实例的账号身份 | `instances[]: {pid, hwnd, nick, online, nodeCount, alias, matchedBy}` |
| `accounts` | L0 | 新增（v0.2） | 列出 `config.json` 的 `accounts[]` 与各条目的实时绑定状态，并列出没有配置条目的活体实例（unbound） | `accounts[]: {alias, nick, qqId, enabled, note, isDefault, status, live}`, `count`, `okCount`, `defaultAccount`, `accountsWarning`, `unbound[]` |
| `config-ui` | L0 | 新增（v0.2） | 打开图形化配置界面（唯一会启动进程的命令，启动的是框架自身的 UI） | `launched`, `path` |
| `list-sessions` | L0 | qq-structure-dump（拆分） | 当前会话列表 | `sessions[]: {title, preview, time, unread, selected}` |
| `read-chat` | L1 | qq-inspect-chat | 打开指定会话并读取消息列表 | `header`, `isGroup`, `messages[]: {sender, self, time, type, text}` |
| `search` | L1 | explore/qq-search-probe（转正） | 全局搜索联系人/群/聊天记录 | `results[]: {kind, name, detail, qqId}`, `umbrellaEntry`, `panelUsed`, `duplicatesRemoved`, `closed`, `searchValue`, `searchValueNote`, `notes[]` |
| `open-chat` | L1 | qq-step1-open | 打开指定会话 + 切换校验 + 截图留证 | `header`, `headerMatches`, `headerChanged`, `isGroup`, `editorPresent`, `openedVia`, `screenshot` |
| `send-message` | **L2** | qq-step2-send | 五道护栏后发送一条文本消息 | `sent`, `confirmed`, `editorEmptied`, `selfMsgVisible`, `accountGuard`, `auditLog` |

### 4.3 命令参数规范

通用规则：

- **实例选择（v0.2 修订）**：窗口类命令（`list-sessions` / `read-chat` / `search` / `open-chat` / `send-message`）不再要求 `-SenderPid`，改为三选一，解析顺序固定：
  1. `-SenderPid <int>`：显式 pid，优先级最高，来自本次会话的 `identify`；
  2. `-Account <别名|昵称|QQ号>`：按配置别名表解析（见下）；
  3. `config.json` 的 `defaultAccount`：前两者都没有时的兜底；
  4. 三者皆无 → `BAD_ARGS`（exit 2），在任何 UIA 访问之前失败。

  显式 pid 永远压过配置的默认账号，因此一个 `defaultAccount` 不可能把"点名要发的那个实例"改道。
- `-Account` 语义：先在 `config.json` 的 `accounts[]` 里匹配 **enabled** 条目——`alias` 忽略大小写、`nick` 精确（`-ceq`）、`qqId` 精确；命中条目后用它自己的 `nick` 去活体实例里找。
  - 一个 `-Account` 值在配置表里**没命中不是错误**：它被当作活体昵称直接匹配（这样没配任何账号的部署也能用 `identify` 打出来的昵称寻址）。
  - 活体命中 1 个 → 解析成功，`data.account` 与 Envelope 的 `pid` 都带上实际实例；
  - 命中 0 个 → `NOT_FOUND`（exit 3），含义是"该账号没登录，或它的无障碍树没激活"；
  - 命中 ≥2 个 → `NOT_FOUND`，含义是"歧义"，改用 `-SenderPid` 指定其中一个候选。**任何情况下不猜**。
- `-ExpectNick <string>`：`send-message` 与 `open-chat` 必填，精确匹配会话标题。
- `-ExpectAccountNick <string>`：可选，多实例防护；`guards.requireAccountMatch=true` 时对所有 L1/L2 命令变成必填。用 `-Account` / `defaultAccount` 选实例时，`send-message` 会自动把配置条目的 `nick` 填进这个位置（见 §6.10）。
- `-Message`：`send-message` 必填，禁止空值与内置默认文案。
- 中文文本传递优先级：`-MessageFile <utf8路径>` > `-MessageBase64 <b64>` > `-Message <字面量>`。前两者用于规避 Git Bash → powershell.exe 的 ANSI 码页转换导致的中文乱码；字面量形式仅在已验证编码正常的调用链中使用。
- `-TimeoutSec <int>`：`read-chat` / `search` / `open-chat` / `send-message` 支持，作为**各阶段等待的上限**（`timeouts.defaultSec` 提供默认值，0 表示不设上限），由 `Get-QQEffectiveTimeouts` 统一套用。
- 所有命令支持 `-DryRun`（L2 命令必支持）。

## 5. 统一输出契约

### 5.1 通道分离

- **stdout**：仅输出一个 JSON 对象（Envelope），供 agent 解析。
- **stderr**：人类可读日志（原 `Write-Host` 内容降级到此），agent 可忽略。

### 5.2 Envelope 结构

```json
{
  "ok": true,
  "command": "send-message",
  "version": "0.2.0",
  "timestamp": "2026-09-18T13:00:00+08:00",
  "pid": 86324,
  "data": { },
  "error": null
}
```

失败时：

```json
{
  "ok": false,
  "command": "send-message",
  "version": "0.2.0",
  "timestamp": "2026-09-18T13:00:00+08:00",
  "pid": 86324,
  "data": null,
  "error": {
    "code": "GUARD_HEADER_MISMATCH",
    "exitCode": 4,
    "message": "header '文件传输助手' != expected '渐行渐远'",
    "details": { "header": "文件传输助手", "expected": "渐行渐远" }
  }
}
```

PowerShell 5.1 序列化注意事项（`qq-json.ps1` 负责规避）：`ConvertTo-Json` 必须显式 `-Depth 6`；空数组需强制 `@(...)` 防 `null` 坍缩；非 ASCII 字符会被转义为 `\uXXXX`，对标准 JSON 解析器透明，不做特殊处理；输出前 `[Console]::OutputEncoding` 置为 UTF-8。

### 5.3 退出码

| 码 | 常量 | 含义 | agent 对策 |
|---|---|---|---|
| 0 | OK | 成功 | 读 data |
| 1 | ERROR | 未分类错误 | 读 error.message，人工介入 |
| 2 | BAD_ARGS | 参数缺失/非法 | 修正调用参数重试 |
| 3 | NOT_FOUND | 进程/会话/控件未找到 | 重新 identify 或 open-chat |
| 4 | GUARD_ABORT | 护栏拒绝（标题不符/群聊/输入框缺失/回读失败） | **禁止重试**，从头走 SOP |
| 5 | ENV_NOT_READY | QQ 未运行/未登录/a11y 未激活 | 按 doctor 提示处理 |
| 6 | TIMEOUT | 等待超时（会话切换未生效等） | 可重试一次，再失败则人工介入 |

## 6. 安全模型（框架级不变量）

以下规则实现在 `lib/qq-guards.ps1`，**任何 L2 命令必须经过全部护栏，无开关可关闭**：

1. **身份确认**：发送前读取 `user-avatar` 的 Name，确认当前实例账号与预期一致（多开防护）。
2. **标题精确匹配**：`chat-header__contact-name` 必须**精确等于** `-ExpectNick`。
3. **群聊拒绝**：检出 `group-member-list` 即拒绝发送。未来如需支持群聊，增加显式 `-AllowGroup` 开关，默认关闭。
4. **切换生效校验**：`open-chat` 后必须等到标题**发生变化**且等于预期（不是仅相等），防止旧标题骗过校验。
5. **键入回读**：SendKeys 后用 `TextPattern.DocumentRange.GetText()` 回读输入框，确认文字真实落入。
6. **发送前再校验**：键入后、按回车前再读一次标题，漂移即中止。
7. **发送确认**：发送后校验输入框清空 + 出现 `message-container--self`，结果写入返回 JSON。
8. **审计日志**：每次 L2 操作追加 `evidence/audit.jsonl`（时间、pid、账号、目标、消息哈希、结果、截图路径），open-chat 的截图同时落盘 `evidence/`。审计记录带 `stage`（`attempt` 在键入之前、`result` 在 QQ 确认之后）与 unix 秒时间戳。
9. **频次约束**：`guards.minSendIntervalMs`（默认 60000ms）实现为跨进程冷却，从 `evidence/audit.jsonl` 恢复上次发送时间。**只认 `stage='result'` 且 `sent=true` 的记录**——`attempt` 记录写在键入之前，算进去会把"被护栏中止的发送"也变成一次冷却。时间戳端到端用 `[DateTimeOffset]::Now.ToUnixTimeSeconds()` 的 int64 秒，避免文化相关的小数点解析。冷却触发即 `GUARD_RATE_LIMIT`（exit 4），手册仍要求"一次任务一条消息"。
10. **账号解析即护栏**：实例由 `-Account` 或 `defaultAccount` 选出时，`send-message` 自动把解析到的配置条目 `nick` 当作 `-ExpectAccountNick` 交给 §6.1 的身份确认（`data.accountGuard = 'from-account'`）；调用方显式传了 `-ExpectAccountNick` 则它优先（`'explicit'`）；两者都没有是 `'none'`。也就是说"按账号寻址"与"校验账号"不再需要调用方分两步表达。

对现有脚本的三处**必须修复**的危险点：

- 删除 `qq-step2-send.ps1` 的 `SenderPid = 86324` 默认值 → 改为 §4.3 的"`-SenderPid` / `-Account` / `defaultAccount` 三选一"，**无默认 pid**。
- 删除 `qq-step2-send.ps1` 的 Message 空值兜底文案（`早上好，主人。`）→ 改为必填，空值 exit 2。
- `archive/` 下全部脚本物理移入框架的 `archive/` 并在手册中明令禁止调用；不在 dispatcher 注册任何指向它们的命令。

## 7. 配置与选择器

`config.json`（框架根目录，首次运行由 `doctor` 校验）：

```json
{
  "qqPath": "C:\\Program Files\\Tencent\\QQNT",
  "evidence": { "dir": "evidence", "keepLatestAliases": true, "writeAudit": true },
  "timeouts": { "defaultSec": 30, "switchHeaderMs": 10000, "afterTypeMs": 1000, "afterSendMs": 5000 },
  "dpi": { "mode": "auto", "scale": 1.5 },
  "a11y": { "minNodes": 100, "nodeCountTimeoutMs": 8000 },
  "instances": { "minWindowWidth": 400, "ignorePids": [] },
  "accounts": [ { "alias": "master", "nick": "...", "qqId": "...", "enabled": true, "note": "" } ],
  "defaultAccount": "master",
  "guards": { "requireAccountMatch": false, "minSendIntervalMs": 60000 }
}
```

配置的边界（v0.2 修订）：**账号名进配置，pid 不进配置**。

- `accounts[]` 落**别名表**：`alias`（调用方使用的名字）、`nick`（QQ 自身报告的昵称，`-Account` 与账号护栏用它做精确匹配）、`qqId`、`enabled`、`note`。别名映射（如"主人 → 渐行渐远/987654321"）不再是调用方的私有知识，而是框架数据；`accounts` 命令负责把每条记录与活体实例对账。
- **pid 仍然运行时发现**：配置里不落任何 pid，`-SenderPid` 必须来自本次 `identify`。`qqId` 只是账号的一个字段（用于 `-Account` 匹配与结果去重），不代表"某 pid 一定在线"。
- `defaultAccount` 指向一个 enabled 别名，只在"`-SenderPid` 与 `-Account` 都没传"时生效，不会覆盖显式寻址（§4.3）。
- 陈旧数据不会被静默信任：`accounts` 报 `not-running` / `unbound`，`-Account` 解析不到实例即 `NOT_FOUND`，能解析时 `send-message` 还会把解析出的 `nick` 交给账号护栏再验一次（§6.10）。

`selectors.psd1` 集中存放全部 class 选择器（`chat-header__contact-name`、`ExEditor-qq-msg-editor`、`recent-contact-item`、`send-msg`、`group-member-list`、`user-avatar` 等，完整清单见实测文档 §3）。`doctor` 对关键选择器做存在性探测，任一落空即在 `selectorHealth` 中报告，提示 QQ 版本漂移。条目带 `Stable` / `Required` / `Note` 三个属性：`Required=$true` 的落空进 `selectorDrift`（阻塞任务），`Required=$false` 的落空只进 `selectorOptionalMiss`（当前视图本就不存在的可选控件）。v0.2 起 `Search.ResultItem` 锚定为 `^search-result-item$`（否则会把"进入综合搜索"入口也收进结果行），未验证的 `Search.Panel` / `Search.PanelItem` 一律 `Stable=$false`、`Required=$false`，不得作为任何任务的闸门。

### 7.1 图形化配置界面（v0.2 新增）

入口：`qq-uia.ps1 config-ui`（等价于 `powershell -STA -NoProfile -ExecutionPolicy Bypass -File qq-config-ui.ps1`）。

定位：**给人用的配置界面，不是 agent 的接口**。agent 读账号一律走 `accounts`（L0，只读，返回 JSON）；UI 只负责把配置写正确。

- 界面分区：运行实例区（刷新 / doctor 自检）、账号配置区（增删改 / 设为默认 / 从选中实例绑定昵称）、基本设置区（dpi / timeouts / a11y / instances / guards / evidence）、操作区（保存 / 重新加载 / 打开 evidence / 复制无障碍启动命令）。
- 保存：先做完整校验（别名唯一非空、昵称非空、QQ 号纯数字、`defaultAccount` 必须是已启用别名、`dpi.scale` 在 0.5–5.0、数值字段为正整数），校验不通过**只弹对话框、不写文件**；写入前把原文件复制为 `config.json.bak`；中文经 `ConvertTo-Json` 转义为 `\uXXXX`，`config.json` 始终保持纯 ASCII。
- 进程契约：`config-ui` 是框架里唯一会启动进程的**命令**，启动的是 `powershell.exe -STA`（WPF 需要 STA 消息循环；在 MTA 线程上启动时脚本会以同一组参数自重启为 STA），窗口是独立进程，命令立即返回。界面自身还会拉起两个只读子进程：`qq-uia.ps1 doctor`（自检）与 `explorer.exe`（打开 evidence 目录）。"**禁止操作 QQ.exe**"这条铁律不变并收窄到 QQ 进程：UI 从不聚焦、点击、输入、发送，也从不启动、重启、结束 QQ 进程；运行实例区是只读的 UIA 枚举。"复制无障碍启动命令"只把 `& '<qqPath>' --force-renderer-accessibility` 放进剪贴板——**只复制，不执行**，是否运行由人决定。

## 8. 目录结构

```
qq-uia-framework/
├── README.md                 框架简介与安装
├── docs/
│   ├── FRAMEWORK-DESIGN.md   本文档
│   ├── AGENT-MANUAL.md       Agent 任务手册（框架对 agent 的契约）
│   ├── PREFLIGHT-CHECKLIST.md 发送前逐项核对清单
│   └── IMPLEMENTATION.md     实现说明与实测记录
├── qq-uia.ps1                唯一入口 dispatcher
├── qq-config-ui.ps1          图形化配置界面（WPF，由 config-ui 命令以 powershell -STA 启动）
├── ui/
│   └── config-ui.xaml        界面布局与中文文案（框架内唯一非 ASCII 文件）
├── config.json
├── run-tests.ps1             框架自检（静态 + 只读实测）
├── qq-behavior.tests.ps1     无需 QQ 的细粒度行为断言
├── lib/
│   ├── qq-core.ps1           由 qq-lib.ps1 强化而来
│   ├── qq-guards.ps1         发送护栏
│   ├── qq-json.ps1           JSON Envelope 序列化
│   └── selectors.psd1        选择器外置数据
├── commands/                 每子命令一个文件：doctor/identify/accounts/config-ui/
│                             list-sessions/read-chat/search/open-chat/send-message
├── evidence/                 截图 + audit.jsonl（gitignore）
└── archive/                  历史脚本封存（只读，不注册命令）
```

## 9. 实施路线图

| 里程碑 | 内容 | 验收标准 |
|---|---|---|
| M1 迁移收敛 | 脚本迁入新结构；修复 §6 三处危险点；archive 封存 | 新结构下原有两步式发送流程可用 |
| M2 输出契约 | dispatcher + JSON Envelope + 退出码 + stderr 降级 | 全部命令输出可被 `ConvertFrom-Json` 解析 |
| M3 只读命令补齐 | list-sessions、search 转正；doctor 增加选择器体检 | `doctor` 能报出 a11y 未激活与选择器漂移 |
| M4 手册与端到端验收 | AGENT-MANUAL.md 定稿；agent 按手册完成一次真实发送演练 | agent 零人工提示完成 identify→open→send 全流程 |
| **v0.2（已落地）** | 账号体系（`accounts` + `-Account`）、配置 UI（`qq-config-ui.ps1`）、search 重构（综合搜索面板 / 去重 / Escape 收尾）、缺陷修复（DPI 双重换算、限频文化 bug、选择器锚定、quiet 截断） | 两个测试套件全绿（23 静态 + 168 行为断言）；`doctor` 在本机真实 QQ 上 `ready=true`、`selectorDrift=[]` |
| M5 后续（排期未定） | StructureChanged 新消息监听；`-AllowGroup`；多账号干扰验证；综合搜索面板选择器活体验证（见 §10） | 单独立项 |

## 10. 风险与未决项

继承自实测文档 §8，并作为框架的验证清单管理：

- [ ] `--force-renderer-accessibility` 激活状态的跨重启持久性未验证 → `doctor` 必须每次检查节点数（`a11y.nodeCountTimeoutMs` 内允许惰性激活），未激活时给出明确提示（用该参数重启 QQ）。
- [ ] 图片消息 `pic-element` 的随机类名稳定性未验证 → 图片相关选择器标记为 unstable，不进命令面。
- [ ] `StructureChanged` 事件订阅未实测 → M5 前置验证。
- [ ] 多账号同时操作的互相干扰未验证 → 手册直接禁止并发调用；多开场景只支持"解析到一个实例"。
- [ ] QQ 版本升级导致 class 漂移 → 由 selectors.psd1 集中应对，漂移后修改单文件即可，但需建立"升级后先跑 doctor"的习惯。
- [ ] **综合搜索面板选择器待活体验证（v0.2 遗留）**：`Search.Panel` / `Search.PanelItem` 的容器与行类名在测试过的关键词下从未渲染出来，故为猜测值并标 `Stable=$false` / `Required=$false`；`-Activate 1` 读不到面板时回落下拉结果并在 `data.notes` 说明，绝不把没读到的行当成结果。
- [ ] **`Search.UmbrellaRow` / `Search.ResultItem` 的真实类名待复核**：本机实测只见过 `global search-result-item`（进入综合搜索入口），真实下拉行与面板行的类名需在有结果行时复核。
- [ ] **Escape 收尾行为待验证**：`Send-QQEscape` 是否既能关掉下拉/综合搜索面板，又不影响已经点击切换过的会话（`data.closed` 是"观察到结果行消失"而非"按键已注入"）。
- [ ] **quiet-period 取值待验证**：`Set-QQSearchKeyword` 的 3000ms 静默期是否适合分批渲染的真实下拉（行数变化会重置计时，但总等待仍受 `timeouts.searchResultsMs` 约束）。
- [ ] **`historyUnit` 本地化单位词待复核**：聊天记录行判定要求 Name 里含该词（`Get-QQUiText 'historyUnit'`），真实文案拼写需在有聊天记录结果时确认。
- [ ] **去重是否在真实"下拉 + 面板"之间发生待验证**：`Merge-QQSearchResultRecords` 的去重键是 `kind|name|qqId`，实际重复场景（同一目标被两个界面各渲染一次）尚未在真机观察到。
- [ ] **open 路径的 `nick` 档匹配待验证**：`Select-QQSearchRow` 的 `matchQuality` 三级（`qqid` / `nick` / `first-row`）中只有 `first-row` 在真机走过，`nick` 档需要有真实搜索结果行时复核。
- [ ] **DPI 感知级别只在单机验证过**：本机实测为 `per-monitor-v2`（坐标不再换算）。100% 缩放主机与混合 DPI 多屏主机的行为未验证；`dpi.scale` 仅在"进程未感知"分支起作用。
