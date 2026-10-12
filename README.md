# QQ UIA 自动化框架

> [!WARNING]
> **声明：本项目代码完全由 AI 开发（对话式"vibe coding"产物），未经逐行人工审查；完成度为半成品，作者本人亦视其为 "trash"。公开仅作存档与记录，不构成任何质量保证与维护承诺，请勿用于生产环境。**
>
> **Disclaimer: This project's code was written entirely by AI ("vibe coding"). It is a half-finished work that the author personally considers "trash". Published for archival purposes only — no warranty, no maintenance commitment, do not use in production.**

把本机 QQ（QQNT 9.9.x）的 UI 自动化封装成**一条命令行**，供 agent 调用：

```
powershell -NoProfile -ExecutionPolicy Bypass -File qq-uia.ps1 <子命令> [参数...]
```

- **stdout 只有一个 JSON 对象**（Envelope），供程序解析。
- **stderr 是人类日志**，可忽略。
- **退出码语义化**：`0` 成功 / `1` 未分类 / `2` 参数错误 / `3` 目标未找到 / `4` 护栏拒绝 / `5` 环境未就绪 / `6` 超时。

能做什么：枚举 QQ 实例与账号、读会话列表、打开会话、读消息记录、发**纯文本**消息、全局搜索。
不能做什么：发图片/文件/红包、撤回、监听新消息推送、操作 CDP 或 QQ 内部接口、多账号并发操作。

---

## 1. 文档地图

| 文档 | 作用 |
|---|---|
| [`docs/FRAMEWORK-DESIGN.md`](docs/FRAMEWORK-DESIGN.md) | **设计权威**：架构、命令面、输出契约、安全模型 |
| [`docs/AGENT-MANUAL.md`](docs/AGENT-MANUAL.md) | **agent 契约**：铁律、SOP、退出码对策、已知陷阱 |
| [`docs/PREFLIGHT-CHECKLIST.md`](docs/PREFLIGHT-CHECKLIST.md) | 发送前核对清单：把 JSON 字段与截图变成可逐项打勾的证据 |
| [`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md) | 实现说明：与设计的对应、超出设计的加法、真实 QQ 实测记录、v0.2 改动摘要与缺陷根因、待活体验证清单 |
| [`archive/README.md`](archive/README.md) | 历史脚本封存说明（**禁止使用**） |

前两份是**逐字节副本**（SHA-256 与上游一致）。要改设计，先改上游再同步过来。

---

## 2. 环境要求

| 项 | 要求 |
|---|---|
| 系统 | Windows 10/11 |
| PowerShell | **5.1**（Windows 自带；不要在 PowerShell 7 下运行，UIA 程序集与 `SendKeys` 行为未验证） |
| QQ | QQNT 9.9.x（实测 9.9.35-52892） |
| 无障碍树 | 必须激活（见下） |

### 激活 QQ 的无障碍树

QQ 是 Electron 应用，默认只暴露 9 个空骨架节点。两种激活方式：

1. `QQ.exe --force-renderer-accessibility`（立即生效）
2. 让任意 UIA 客户端连接并等待（惰性激活，可能要到 557+ 节点）

框架**从不启动、重启或结束任何 QQ 进程**，只连接已运行的实例。
`doctor` 每次都会检查节点数，未激活时给明确提示。

---

## 3. 安装与自检

本框架无依赖、无需安装：目录可整体复制到任意位置（路径含空格也可以）。

```
cd qq-uia-framework
powershell -NoProfile -ExecutionPolicy Bypass -File run-tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File qq-behavior.tests.ps1   # 可选的细粒度断言
```

`run-tests.ps1` 分两类：

- **静态**（不需要 QQ）：源码纯 ASCII、文件结尾、语法、命令注册表与磁盘一致、
  `archive/` 隔离、退出码与 Envelope 行为、`-TimeoutSec` 注册与套用一致、护栏拒绝行为、
  配置界面（`ui/config-ui.xaml` 可解析且控件名与脚本一致、`qq-config-ui.ps1` 不与库函数重名）。共 23 项。
- **实测**（需要 QQ 已登录且无障碍树激活）：`doctor`/`identify`/`list-sessions`/`read-chat`、
  `send-message -DryRun`、以及「`-ExpectNick` 不匹配必须 exit 4」。共 6 项。
  **实测部分永不发送消息。**

只想跑静态：`run-tests.ps1 -StaticOnly`。

`qq-behavior.tests.ps1` 是不需要 QQ、也不需要 UIA 的细粒度断言（168 项）：
进程契约（不启动/结束**任何**进程、更不允许启动 QQ 进程）、配置界面已注册且文件齐备、
命令面（`accounts`/`config-ui` 的注册与 `-Account` 注册状态）与 `config.json` 的
`accounts[]`/`defaultAccount`、stdout 契约、退出码映射、
13 条护栏码全部映射到 exit 4、消息载荷校验、DPI 感知/未感知两分支换算、发送冷却的
审计语义与时间戳文化安全、`-TimeoutSec` 上限、宽度下限与 a11y 阈值解析、doctor 配置警告、
JSON 深度守卫、选择器注册表完整性、搜索行解析/去重/匹配分级。

---

## 4. 快速上手（只读）

```powershell
cd qq-uia-framework
$qq = { param($a) powershell -NoProfile -ExecutionPolicy Bypass -File .\qq-uia.ps1 @a }

# 1) 环境体检
& $qq doctor

# 2) 有哪些实例、我配了哪些账号
& $qq identify
& $qq accounts

# 3) 读会话列表（二选一：-Account 别名，或 identify 给出的 -SenderPid）
& $qq list-sessions -Account master -Limit 10
# 没配账号时直接用 pid：
& $qq list-sessions -SenderPid 11004 -Limit 10

# 4) 读某个会话的最近消息
& $qq read-chat -Account master -OpenNick "酒狐" -Limit 20
```

> `-Account` 接受 `config.json` 里 `accounts[]` 的别名（忽略大小写）、昵称（精确）或 QQ 号；
> 没命中配置表时按昵称直接匹配活体实例。解析到 0 个或 ≥2 个实例都会以 `NOT_FOUND` 失败——
> 歧义时用 `accounts` 返回的 `live.candidates[].pid` 配合 `-SenderPid`。

---

## 5. 发送一条消息（两步式，不可撤销）

**A. 先打开会话并核对**

```powershell
& $qq open-chat -Account master -ExpectNick "酒狐"
# 没有配置账号时：& $qq open-chat -SenderPid 11004 -ExpectNick "酒狐"
```

检查返回的 `data`：

- `headerMatches == true`（标题精确等于 `-ExpectNick`，**判目的地只看这一项**）
- `isGroup == false`、`editorPresent == true`
- `screenshot.error == ""`，然后**真的打开 `screenshot.path` 看一眼**确认是目标会话
- `headerChanged` 只作参考：`true` = 这次调用真的切换了会话，`false` = 目标会话本来就开着（也是成功）

逐项核对的完整清单见 [`docs/PREFLIGHT-CHECKLIST.md`](docs/PREFLIGHT-CHECKLIST.md)。

**B. 再发送**

中文消息先写 UTF-8 文件，避免命令行码页转换乱码：

```powershell
$msg = Join-Path $env:TEMP 'qq-msg.txt'
[System.IO.File]::WriteAllText($msg, "早上好，主人。", (New-Object System.Text.UTF8Encoding($false)))

& $qq send-message -Account master -ExpectNick "酒狐" -MessageFile $msg -DryRun   # 先干跑
& $qq send-message -Account master -ExpectNick "酒狐" -MessageFile $msg           # 确认无误再真发
```

用 `-Account` 寻址时，框架会把解析出的配置昵称自动交给账号护栏（`data.accountGuard == "from-account"`），
不需要你另传 `-ExpectAccountNick`；显式传入时它优先（`"explicit"`）。

成功判据：`exit 0` 且 `data.sent == true` 且 `data.confirmed == true`。
`exit 4` 表示护栏拒绝：**停止并报告，禁止换参数重试**（`error.details.guard` 说明是哪条护栏）。

> ⚠️ 中文不要用 `-MessageText` 字面量传：`powershell -File` 会在参数到达脚本前损坏非 ASCII 字符。
> `-MessageFile`（UTF-8 无 BOM）是唯一可靠通道。

---

## 6. 命令一览

| 子命令 | 级别 | 作用 | 必填参数 |
|---|---|---|---|
| `doctor` | L0 只读 | 环境体检：实例、无障碍激活度、选择器健康度、配置告警 | — |
| `identify` | L0 只读 | 枚举实例与各实例登录的账号（含 `alias`/`matchedBy`） | — |
| `accounts` | L0 只读 | 列出配置的账号与其实时绑定状态（含 unbound 实例） | — |
| `config-ui` | L0 只读 | 打开图形化配置界面（唯一会启动进程的命令，启动的是框架自己的 UI） | — |
| `list-sessions` | L0 只读 | 读会话列表（标题/预览/时间/未读/免打扰/选中） | 实例寻址（见下） |
| `read-chat` | L1 界面变更 | 打开会话并读已渲染的消息 | 实例寻址 + `-OpenNick` |
| `search` | L1 界面变更 | 全局搜索联系人/群/聊天记录（去重排序，默认 Escape 收尾） | 实例寻址 + `-Keyword` |
| `open-chat` | L1 界面变更 | 打开会话 + 切换校验 + 截图留证（**不发送**） | 实例寻址 + `-ExpectNick` |
| `send-message` | **L2 对外写入** | 五道护栏后发送一条文本（**不可撤销**） | 实例寻址 + `-ExpectNick` + 消息三者之一 |

**实例寻址**：窗口类命令用 `-SenderPid <pid>`（来自本次 `identify`）或 `-Account <别名|昵称|QQ号>`，
解析顺序 `-SenderPid` > `-Account` > `config.json` 的 `defaultAccount`；三者皆无是 `BAD_ARGS`。
`-Account` 匹配 `accounts[]` 的启用条目（别名忽略大小写、昵称/QQ号精确），未命中则按活体昵称匹配，
命中 0 或 ≥2 个实例一律 `NOT_FOUND`（不猜）。

常用可选参数：`-Limit`、`-TargetId`、`-SearchId`、`-Activate`、`-KeepOpen`、`-ExpectAccountNick`、`-TimeoutSec`、`-DryRun`（L2 专用）。

完整的参数与字段见 `docs/AGENT-MANUAL.md` §5，以及 `qq-uia.ps1 -Help`。

---

## 7. 目录结构

```
qq-uia-framework/
├── qq-uia.ps1          唯一入口 dispatcher（参数校验 → 分发 → JSON 封装 → 退出码）
├── qq-config-ui.ps1    图形化配置界面（WPF，纯 ASCII 源码，由 config-ui 命令启动的独立进程）
├── ui/
│   └── config-ui.xaml  界面布局与中文文案（本框架唯一允许的非 ASCII 文件，UTF-8 带 BOM）
├── config.example.json 配置模板（克隆后复制为 config.json 再填本机账号）
├── config.json         唯一配置（含账号别名表 accounts[]，不含任何 pid；含账号信息，不入库）
├── run-tests.ps1       框架自检
├── lib/
│   ├── qq-core.ps1     UIA 枚举/定位/DPI 换算/聚焦/等待/键盘注入/截图/消息解析
│   ├── qq-guards.ps1   发送护栏（不可绕过）
│   ├── qq-json.ps1     JSON Envelope + 退出码 + stdout/stderr 通道分离
│   └── selectors.psd1  全部选择器（单一来源）
├── commands/           每个子命令一个文件
├── docs/               设计与手册
├── evidence/           截图 + audit.jsonl（运行时产物）
└── archive/            历史脚本封存（只读，未注册任何命令）
```

---

## 8. 配置

`config.json` 是唯一配置，**账号名进配置、pid 不进配置**（账号别名表是数据，pid 一律运行时发现）。

> 仓库不包含 `config.json`（含本机账号信息，已 gitignore）。克隆后先 `Copy-Item config.example.json config.json`，再填入自己的 `accounts[]` 与 `qqPath`。

| 键 | 默认 | 说明 |
|---|---|---|
| `evidence.dir` | `evidence` | 截图与审计日志目录 |
| `evidence.auditIncludeMessageText` | `true` | 审计日志是否记录消息正文（哈希始终记录） |
| `evidence.keepLatestAliases` | `true` | 是否保留 `evidence/last-open-chat.png` 这类固定名副本 |
| `timeouts.*` | 见文件 | 各阶段等待上限（毫秒） |
| `dpi.mode` / `dpi.scale` | `auto` / `1.5` | `auto` 用窗口自身 DPI；非 auto 时用固定比例（仅在进程未感知 DPI 时参与换算） |
| `a11y.minNodes` | `100` | 判定「无障碍树已激活」的节点数下限（doctor 与各命令共用同一阈值） |
| `a11y.nodeCountTimeoutMs` | `8000` | doctor 等待惰性激活的上限 |
| `instances.minWindowWidth` | `400` | 排除同进程的小窗（提示气泡），避免定位到错误窗口 |
| `typing.delayMs` | `12` | 逐字符注入间隔 |
| `guards.requireAccountMatch` | `false` | 置 true 则所有 L1/L2 命令**必须**传 `-ExpectAccountNick` |
| `guards.minSendIntervalMs` | `60000` | 两次发送的最小间隔，从审计日志恢复，跨进程有效 |
| `accounts[]` | `[]` | 账号别名表：`alias`/`nick`/`qqId`/`enabled`/`note`，供 `-Account` 解析 |
| `defaultAccount` | `""` | 未传 `-SenderPid`/`-Account` 时使用的别名（必须是某个 enabled 别名） |
| `qqPath` | 无 | QQ 可执行文件路径，仅配置界面用它生成无障碍启动命令 |

配置里**不落任何 pid**：`-SenderPid` 必须来自本次 `identify`。`qqId` 只是账号表的一个字段
（用于 `-Account` 匹配与搜索结果去重），不代表"某个 pid 一定在线"。

### 图形化配置界面

```
powershell -NoProfile -ExecutionPolicy Bypass -File qq-uia.ps1 config-ui
```

左侧列出当前正在运行的 QQ 实例（只读，UIA 枚举：pid/昵称/签名/在线/节点数/窗口尺寸/缩放/绑定别名），
右侧直接编辑 `accounts[]`，下方是上表的常用设置。保存会先做校验（别名唯一非空、昵称非空、
QQ 号纯数字、`defaultAccount` 必须是已启用别名、`dpi.scale` 在 0.5–5.0、数值字段为正整数），
**校验不通过就只弹对话框、不写文件**；写入前先把原文件复制为 `config.json.bak`。
中文写入时转义为 `\uXXXX`，`config.json` 始终保持纯 ASCII。

界面守同一条铁律：**从不聚焦、点击、输入、发送，也从不启动/重启/结束 QQ 进程**。
「复制无障碍启动命令」只把 `& '<qqPath>' --force-renderer-accessibility` 放进剪贴板，
是否执行由人决定。`config-ui` 是唯一会启动进程的命令，启动的是框架自己的界面脚本（`powershell.exe -STA`）。

---

## 9. 维护：QQ 升级后怎么办

QQ 升级可能改变控件 class 名。此时：

1. 跑 `doctor`，读 `data.selectorDrift` —— 它列出**没命中且被标记为必需**的选择器。
2. **不要猜新 class 名**。用 `archive/probe-era/` 里的只读探针（或自写只读脚本）对真实窗口做 UIA 探测。
3. 只改 `lib/selectors.psd1` 一个文件（条目带 `Stable`/`Required`/`Note` 说明）。
4. 重跑 `run-tests.ps1` 确认全绿。

`data.selectorOptionalMiss` 是当前视图下本就不存在的可选控件（没有自己发的消息、输入框未聚焦、
搜索面板未打开），**不表示漂移**。
