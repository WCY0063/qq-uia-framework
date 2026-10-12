# 实现说明与实测记录（IMPLEMENTATION）

> 本文件是 `G:\work\qq-uia-framework` 的 **实现侧说明**，不是设计权威。
> 设计权威是 `FRAMEWORK-DESIGN.md`；agent 契约是 `AGENT-MANUAL.md`。
> 两份权威文档在本目录内是**逐字节副本**（SHA-256 一致），改动前请改上游再同步。
>
> **版本**：v0.2（2026-09-18）。头部随框架 v0.2 改造同步：新增 §4「v0.2 复核与优化」，
> 记录账号体系、配置 UI、search 重构、缺陷修复四个工作包的改动、根因、活体验证与
> 待验证清单；§3 的 v0.1 实测记录原样保留。
>
> 本文件记录四件事：
> 1. 实现**严格对应**设计的地方（可核对）；
> 2. 实现**超出或偏离**设计的地方，以及原因；
> 3. 在**本机真实 QQ 上实测到**的事实，供后续维护参考；
> 4. v0.2 的改动摘要、缺陷根因与**尚未活体验证**的清单。

---

## 1. 交付结构（对应设计 §8）

```
qq-uia-framework/
├── README.md                     框架简介、安装、快速上手
├── config.json                   唯一配置文件（账号表进配置，pid 不进配置，对应设计 §7）
├── qq-uia.ps1                    唯一入口 dispatcher
├── qq-config-ui.ps1              图形化配置界面（WPF，唯一会启动进程的文件）
├── ui/
│   └── config-ui.xaml            界面布局与中文文案（框架内唯一非 ASCII 文件）
├── run-tests.ps1                 框架自检（23 静态 + 6 只读实测）
├── qq-behavior.tests.ps1         无需 QQ 的细粒度行为断言（168 项）
├── lib/
│   ├── qq-core.ps1               UIA 枚举/定位/DPI/聚焦/等待/键盘注入/截图/消息解析
│   ├── qq-guards.ps1             发送护栏（Assert-* 系列）
│   ├── qq-json.ps1               JSON Envelope、退出码、通道分离
│   └── selectors.psd1            全部选择器（外置数据）
├── commands/
│   ├── _common.ps1               命令共享：实例解析、账号核对、搜索、结果行解析
│   ├── _open.ps1                 打开会话（read-chat 与 open-chat 共用同一实现）
│   ├── doctor.ps1  identify.ps1  accounts.ps1  config-ui.ps1  list-sessions.ps1
│   ├── read-chat.ps1  search.ps1  open-chat.ps1  send-message.ps1
├── docs/                         本目录（含两份权威文档副本 + 核对清单）
├── evidence/                     截图 + audit.jsonl（运行时产物）
└── archive/                      历史脚本封存（只读，不注册任何命令）
```

设计与实现的对应关系：

| 设计条目 | 实现位置 |
|---|---|
| §3 三层架构（dispatcher / 命令层 / 核心层） | `qq-uia.ps1` → `commands/*.ps1` → `lib/*` |
| §4.1 副作用分级 L0/L1/L2 | 注册表 `Get-QQCommandRegistry` 的 `Level` 字段 |
| §4.2 九个子命令 | `commands/` 九个文件，与设计清单一一对应 |
| §4.3 实例寻址（`-SenderPid` / `-Account` / `defaultAccount` 三选一） | `Get-QQInstanceContext` + `Resolve-QQAccountPid`（`_common.ps1`），`Get-QQIntArg` 不再 `-Required` 于 SenderPid |
| §5.1 通道分离（stdout 仅 JSON） | `Write-QQEnvelope` 走 `[Console]::Out`；命令内禁止 `Write-Output`/`Write-Host`，由 `run-tests.ps1` 静态断言 |
| §5.2 Envelope 结构 | `Get-QQEnvelopeObject`（字段 ok/command/version/timestamp/pid/data/error） |
| §5.3 六类退出码 | `lib/qq-json.ps1` 的 `$script:QQ_EXIT` 表 + `Resolve-QQExitCodeName` |
| §6 十条安全不变量 | `lib/qq-guards.ps1`（见下表逐条映射） |
| §7 账号表进配置、pid 不进配置 | `Get-QQConfig` 归一化 `Accounts`/`DefaultAccount`/`AccountsWarning`；`Resolve-QQAccountPid` 每次运行时重新绑定活体实例 |
| §7.1 图形化配置界面 | `qq-config-ui.ps1` + `ui/config-ui.xaml`，经 `commands/config-ui.ps1` 以 `powershell.exe -STA` 启动 |
| §7 选择器外置 + doctor 体检 | `lib/selectors.psd1` + `Get-QQSelectorHealth` |
| §8 目录结构 | 本节 |

### 护栏映射（设计 §6 → 实现）

| 设计条目 | 实现函数 | 失败码（`error.details.guard`） |
|---|---|---|
| 6.1 身份确认 | `Assert-QQAccountMatches` + `Assert-QQAccountExpected` | `GUARD_ACCOUNT_MISMATCH` |
| 6.2 标题精确匹配 | `Assert-QQHeaderMatches`（`-ceq` 精确比较） | `GUARD_HEADER_MISMATCH` |
| 6.3 群聊拒绝 | `Assert-QQNotGroupChat` | `GUARD_GROUP_REJECTED` |
| 6.4 切换生效校验 | `Open-QQConversation` + `Wait-QQHeaderChange`（要求**发生变化**） | `TIMEOUT` / `NOT_FOUND` |
| 6.5 键入回读 | `Assert-QQTextLanded`（TextPattern 回读） | `GUARD_READBACK_FAILED` |
| 6.6 发送前再校验 | 键入后重读标题与群聊标记 | `GUARD_HEADER_DRIFT` / `GUARD_GROUP_REJECTED` |
| 6.7 发送确认 | `editorEmptied` + `selfMsgCount` 增量 | 结果字段 `sent` / `confirmed` |
| 6.8 审计日志 | `Write-QQAuditRecord` → `evidence/audit.jsonl` | — |
| 6.9 频次约束 | `Assert-QQRateLimit`（读审计日志，跨进程有效；只认 `stage='result'` 且 `sent=true`，时间戳走 `ToUnixTimeSeconds`） | `GUARD_RATE_LIMIT` |
| 6.10 账号解析即护栏 | `send-message`：`-Account`/`defaultAccount` 解析出的配置 Nick 自动作为 `-ExpectAccountNick` | `data.accountGuard = from-account` |

### 设计点名必须修复的三处危险点

| 设计 §6 要求 | 实现结果 |
|---|---|
| 删除 `SenderPid = 86324` 默认值 | 没有任何默认 pid：`Get-QQWindowInfo` 无默认值，`-SenderPid` 只作为 `-Account`/`defaultAccount` 之外的一种显式寻址（三选一），三者皆无即 `BAD_ARGS`（exit 2） |
| 删除 Message 空值兜底文案 | `Get-QQMessageTextArg` 无任何默认文本，三种来源都为空即 exit 2；`Assert-QQSendableMessage` 再拒空白 |
| `archive/` 封存且不注册命令 | 30 个历史脚本迁入 `archive/`（分四类），`run-tests.ps1` 断言无任何注册命令路径引用 `archive/` |

---

## 2. 超出设计的实现（都是加法，不削弱设计）

| 新增 | 原因 | 位置 |
|---|---|---|
| `accounts` 命令 + `-Account` 寻址 | 设计 v0.1 要求 agent 自己维护"昵称 → pid"的映射，且每个任务都要先 `identify` 取 pid；多账号场景里最容易错的就是这一步。把别名表搬进配置、把解析交给框架后，寻址与身份校验是同一次解析 | `commands/accounts.ps1` + `_common.ps1` 的 `Resolve-QQAccountPid` |
| `config-ui` 命令 + `qq-config-ui.ps1` | 手工编辑 `config.json` 的 `accounts[]` 没有反馈（写错别名要到发送时才炸）。给人一个能对照活体实例的界面，同时把"agent 不碰配置写入"这条边界显式化 | `commands/config-ui.ps1`、`qq-config-ui.ps1`、`ui/config-ui.xaml` |
| `-SearchId` 参数 | 场景需要「按 QQ 号打开」，而设计只有 `-TargetId`（仅用于挑搜索结果行）。同时保留 `-TargetId`，语义不冲突 | `read-chat` / `open-chat` |
| `-AllowSameHeader` | 重复读同一个已打开的会话时，「必须变化」会误判为超时。仅当调用方显式要求才接受「本来就是这个会话」 | `open-chat` / `read-chat` |
| `-Activate <0\|1>` | 实测该 QQ 版本的搜索下拉可能只渲染「进入综合搜索」入口，加一步激活尝试 | `search` |
| `-KeepOpen` | 新增的 Escape 收尾默认会收起下拉/面板；需要自己接着点结果行的调用方必须能关掉这个收尾 | `search` + `Close-QQSearchSurface` |
| 发送冷却 `guards.minSendIntervalMs` | 设计 §6.9 把限速完全交给手册；但 agent 循环里连点 send 是最现实的误用。冷却从 `audit.jsonl` 恢复，跨进程有效，默认 60000ms | `config.json` + `Assert-QQRateLimit` |
| 输入框非空拒绝 | 设计未提。输入框可能有用户未发出的草稿，键入后回车会把草稿一起发出去 | `Assert-QQEditorWritable` |
| 截图实时性校验 | 设计未提。QQ 窗口是 GPU 合成，且后台进程无法 `SetForegroundWindow`，曾有截图拍到**别的应用** | `QQUiaNative.ActivateWindow` + `WindowAtPoint` 校验 |
| `run-tests.ps1` | 设计的里程碑验收靠人工；本脚本把「源码纯 ASCII」「选择器完整」「退出码」「护栏不导通」等变成可执行断言 | 框架根目录 |
| `qq-behavior.tests.ps1` | 静态断言之外的一层：进程契约、DPI 两分支换算、冷却的时间戳文化安全、搜索解析与去重规则，都不需要 QQ 就能跑 | 框架根目录 |
| search 结果去重与排序 | 综合搜索面板与下拉可能渲染同一个目标；`kind\|name\|qqId` 去重 + contact→group→history 排序让"两次渲染"看起来仍是一个目标 | `Merge-QQSearchResultRecords` |

---

## 3. 本机实测记录（QQNT 9.9.35-52892 / Windows 11 / PowerShell 5.1）

### 3.1 环境事实

| 事实 | 数值/结论 |
|---|---|
| 主窗口 | hwnd `17172754`，pid `11004`，2570x1538 物理像素 |
| DPI | 150%（`GetDpiForWindow` = 144，scale 1.5） |
| UIA 节点数 | 激活后 430–630（随聊天区渲染量浮动），`a11yActive = true` |
| 同 pid 的其它窗口 | 存在一个 237x39 的可见小窗（提示/气泡），**必须靠宽度下限排除** |
| 屏幕 | 单屏 2560x1600，不可用 `PrimaryScreen.Bounds` 判断（见 3.3） |

### 3.2 选择器实测（34 项全部命中必需项）

设计文档 `README-QQNT-UIA.md` §3 里的一部分描述在本版本**已变化**，已按实测更新：

| 项 | 文档描述 | 9.9.35 实测 | 处理 |
|---|---|---|---|
| 消息方向 | `message-container--self` / `--others` | 方向类在**内容框**上：`msg-content-container container--self` / `container--others`；`message-container--self` 也确实存在（自带消息的行容器） | 选择器同时匹配两种拼写 |
| 图片消息 | `img.pic-element`（随机类名） | `f2vnRVay8ztZBnqxSA7L pic-element`，外层 `pic-element` 稳定 | 匹配 `pic-element`，标记 `Stable=$false` |
| 搜索下拉 | `search-result-item` 行含昵称/群名 | **只渲染一条 `进入综合搜索 查找用户、群聊等`**；输入 `酒`/`1122`/`A`/`987654321` 均如此，回车亦不改变 | `search` 把该行单列为 `umbrellaEntry`，真实 `results` 为空并给出 `note`；`open-chat` 以会话列表为主路径 |
| 会话行时间 | 未说明可空 | 24 行里 14 行 `time` 为空（时间渲染在预览行或仅有相对日期） | 用行内 Y 坐标分行，不再靠文本顺序 |

### 3.3 截图：三个必须绕开的坑

1. **窗口 DC 截图是黑的**：QQ 窗口由 GPU 合成，`GetWindowDC` + `BitBlt` 得到全黑图（约 18KB）。
   改为 `GetDC(NULL)` 抓桌面区域再裁剪，得到真实画面（约 700–830KB）。
2. **后台进程无法 `SetForegroundWindow`**：直接调用会失败且**不报错**，截图会拍到当时前台的应用
   （实测拍到过 DeepSeek Harness 窗口）。必须 `AttachThreadInput` 附加到前台线程再激活，
   并在截图前用 `WindowFromPoint` 校验目标矩形上确实是目标窗口。
3. **坐标必须按 DPI 缩放**：`GetWindowRect` 返回逻辑像素（1714x1026），截图是物理像素（2560x1600）。
   不乘 1.5 就会裁到左上角一块。实现按 `GetDpiForWindow/96` 换算。
   （v0.1 时进程**未**提升 DPI 感知，故必须乘；v0.2 改为提升感知并回读级别，此条随之修订，见 §4.2 第 1 行。）

### 3.4 中文与命令行

| 现象 | 结论 |
|---|---|
| `powershell -File x.ps1 -ExpectNick 酒狐` | 参数在到达脚本前被码页转换损坏；实测报参数错误 |
| 正确传法 | 写一个 UTF-8 无 BOM 文件，用 `-MessageFile` 传消息；中文昵称从文件读入变量后再传参（或经 `chcp 65001` 的 cmd 调用） |
| 脚本源码 | 全部保持**纯 ASCII**，中文用 `[char]0x....` 在运行时拼；`run-tests.ps1` 强制校验 |

### 3.5 端到端实测结果

| 命令 | 结果 |
|---|---|
| `doctor` | `ready=true`，1 个实例，`selectorDrift=[]`，6 个可选选择器未命中（当前视图本就没有） |
| `identify` | 账号 `渐行渐远`，`identitySource=user-avatar` |
| `list-sessions` | 25 行，标题/预览/时间/未读/免打扰/选中全部正确 |
| `read-chat` | 打开 `酒狐` 并读 18 条消息：`self` 判定正确（自己发的 `渐行渐远`，对方 `酒狐`），`unreadable=0` |
| `open-chat` | `headerMatches=true`、`headerChanged=true`、`openedVia=session-list`、截图 2557x1597 且画面正确 |
| `send-message -DryRun` | 护栏链 8 项全过，未键入未发送 |
| `send-message`（真实） | 在自己与自己的会话 `酒狐` 内实测：`sent=true`、`confirmed=true`、`editorEmptied=true`、`selfMsgDelta=+1`，消息确实出现在会话里；`audit.jsonl` 写入 attempt + result 两条 |
| `run-tests.ps1` | 29 项全过（23 静态 + 6 实测，v0.1 时为 19 + 6） |

> 发送实测**只发生在用户自己的账号与自己账号之间的会话**，未向任何第三方发送。
> 审计记录见 `evidence/audit.jsonl`。

---

## 4. v0.2 复核与优化（2026-09-18）

v0.2 是四个工作包：**A 账号体系**、**B 配置 UI**、**C search 重构**、**D 缺陷修复**。

### 4.1 四个工作包的改动摘要

**A 账号体系**

- `config.json` 新增 `accounts[]`（`alias`/`nick`/`qqId`/`enabled`/`note`）与 `defaultAccount`；
  `Get-QQConfig` 负责归一化（丢弃无别名的条目、去重别名、把问题写进 `AccountsWarning`）。
- 所有窗口命令（`list-sessions`/`read-chat`/`search`/`open-chat`/`send-message`）的 `-SenderPid` 由**必填改为可选**，
  新增 `-Account <别名|昵称|QQ号>`；解析顺序 `-SenderPid` > `-Account` > `defaultAccount` > `BAD_ARGS`，
  由 `Get-QQInstanceContext` 统一执行（`AccountResolvedBy` = `pid`/`account`/`default`）。
- `-Account` 在配置表未命中时**不报错**，改按活体昵称（`-ceq`）直接匹配；命中 0 个或 ≥2 个都是 `NOT_FOUND`
  （后者带 `candidates`），从不猜。
- 新命令 `accounts`（L0）：一次枚举同时给出「配置的账号 → 活体绑定状态」（`ok`/`ambiguous`/`not-running`/`disabled`）
  与「没被任何启用条目描述的活体实例」（`unbound`）；不声明 pid。
- `identify` 每条实例新增 `alias`/`matchedBy`（`nick`/`alias`/空），用于核对配置表与实际是否一致。
- `send-message` 经账号解析时自动注入账号护栏（`data.accountGuard` = `explicit`/`from-account`/`none`）；
  `search` 也补上了 `-ExpectAccountNick` 校验（它会往搜索框写关键词，同样不能发错实例）。

**B 配置 UI**

- 新增 `qq-config-ui.ps1`（WPF，纯 ASCII 源码，MTA 启动时以同一组参数自重启为 STA）与 `ui/config-ui.xaml`
  （UTF-8 中文界面，框架内唯一非 ASCII 文件），dispatcher 新增 `config-ui` 命令：`Start-Process powershell.exe -STA`
  后**立即返回** JSON（`launched`/`path`），窗口是独立进程。
- 界面分区：运行实例区（刷新 / doctor 自检）、账号配置区（增删改 / 设为默认 / 从选中实例绑定昵称）、
  基本设置区（dpi / timeouts / a11y / instances / guards / evidence）、操作区（保存 / 重新加载 / 打开 evidence /
  复制无障碍启动命令——**只复制不执行**）。
- 保存先把原文件复制成 `config.json.bak`，校验通过才写；`ConvertTo-Json` 把中文转义为 `\uXXXX`，
  `config.json` 始终纯 ASCII。
- 进程契约收窄为「**禁止操作 QQ.exe**」：框架自身允许启动 UI（WPF 需要 STA），
  界面自己还会拉起两个只读子进程（`qq-uia.ps1 doctor` 自检、`explorer.exe` 打开 evidence 目录）；
  `qq-behavior.tests.ps1` 断言没有任何源码能启动/结束 QQ 进程，且每个 `Start-Process` 的目标只能是
  powershell 宿主或 Explorer。

**C search 重构**

- 结果等待改为 **quiet-period 按行数变化重置**（`lastChangeAt`）：只在"真实结果行数"变化后重新计时 3000ms，
  分批渲染的下拉不再被固定延迟截断；总等待仍受 `timeouts.searchResultsMs` 约束。
- 键入后回读失败直接 `TIMEOUT`，删掉 ValuePattern 兜底——那条兜底写进去的值只让搜索框"看起来对了"，
  QQ 仍不渲染结果，最终把空搜索报成答案。
- 关键词回读失败时 `searchValue` 返回 `''` 并附 `searchValueNote`，绝不回显请求的关键词。
- `-Activate 1` 点 umbrella 入口后等综合搜索面板（`Wait-QQSearchPanel`，选择器 `Search.Panel`/`Search.PanelItem`，
  均 `Stable=$false`、未活体验证），成功则读面板行，失败回落下拉行并在 `notes[]` 说明。
- 结果按 `kind|name|qqId` 去重、按 contact→group→history 排序（`Merge-QQSearchResultRecords`），
  `Limit` 在去重之后生效；`duplicatesRemoved`、`panelUsed`、`activated`、`closed` 进入 data。
- `Select-QQSearchRow` 匹配分级 `matchQuality`（`qqid` > `nick` > `first-row`），弱匹配写进 `Notes`。
- 默认结束时 `Send-QQEscape` 收起下拉/面板（`-KeepOpen` 可保留），`closed` 表示"确认结果行已消失"
  而不是"按键已注入"。
- `selectors.psd1`：`Search.ResultItem` 锚定 `^search-result-item$`（不再把 umbrella 行收成结果行）、
  删除死选择器 `Search.Comprehensive`、新增 `Search.UmbrellaRow`、新增未验证的 `Panel`/`PanelItem`；
  history 行判定必须含本地化单位词（`Get-QQUiText 'historyUnit'`），否则"名字 + 数字"会被误判成聊天记录。

**D 缺陷修复**

- DPI 双重换算：见 §4.2 第 1 行。
- 限频时间戳：见 §4.2 第 2 行。
- `doctor` 新增 `configWarnings`（`writeAudit=false` 且 `minSendIntervalMs>0`、`typing.engine` 非 `sendinput`），
  并接上 `a11y.nodeCountTimeoutMs`（`Wait-QQNodeCount`），不再用一次立即读取判定"未激活"。
- `send-message` 的新消息确认改为按 Name 在消息区子树里匹配（`Get-QQDescendantsByName`，Max 1500），
  不再只靠 `selfMsgCount` 增量。
- 宽度下限优先级明确为 `config.instances.minWindowWidth`（显式键）> `selectors.psd1` 的 `Window.MinWidth` > 默认 400。
- a11y 阈值统一到 `Get-QQA11yMinNodes` / `Test-QQA11yActive`（doctor 与实例前置检查共用，消灭 10 vs 100 的分歧）。
- 死键接线：`evidence.keepLatestAliases` 控制截图别名副本（`KeepAlias`）；注册表级 `-TimeoutSec` 经
  `Get-QQEffectiveTimeouts` 套用到 read-chat/search/open-chat/send-message 的各阶段等待。
- 若干注释与小项修正（选择器说明、`-Account` 提示文本等）。

### 4.2 缺陷根因表

| 缺陷 | 根因 | 修法 | 位置 |
|---|---|---|---|
| 150% 缩放下坐标/截图错位（"DPI 双重换算"） | 启动时按"最强优先"提升 DPI 感知但**没回读真实级别**，代码却仍按 `dpi.scale` 乘除：感知进程里 UIA/`GetWindowRect`/GDI 已是同一物理像素空间，再乘 1.5 就把截图裁到错误区域、点击落到错误位置 | `QQUiaNative.EnableDpiAwareness` 逐级尝试并回读实际级别（本机 `per-monitor-v2`）；新增 `Test-QQIsDpiAware`，坐标收敛为 `Convert-QQPointToPhysical` / `Convert-QQWindowRectToPhysical` 两个分支函数：感知时原样透传，仅"未感知/未知"时才按 scale 换算 | `lib/qq-core.ps1` |
| 发送冷却偶发失效/报错 | 时间戳用 `Get-Date -UFormat %s`（依赖当前区域设置，某些文化下输出带小数），再用 `[double]::Parse` 按当前文化解析，解析失败即静默跳过记录，冷却被释放 | 端到端改用 `[DateTimeOffset]::Now.ToUnixTimeSeconds()` 的 int64 秒（写审计与读审计同一表示，`InvariantCulture` 整型解析）；并且只认 `stage='result'` 且 `sent=true` 的记录，避免被"键入前的 attempt"和"被护栏中止的发送"计入 | `lib/qq-guards.ps1`、`commands/send-message.ps1` |
| 搜索结果里混入"进入综合搜索"入口 | `Search.ResultItem` 用未锚定的 `search-result-item`，而 umbrella 行的类是 `global search-result-item`（正则子串命中），于是"入口"被当成第一条真实结果 | `ResultItem` 锚定 `^search-result-item$`；umbrella 行走自己的选择器 `Search.UmbrellaRow` 单独读、单独上报；`Test-QQComprehensiveSearchRow` 仍按本地化 Name 前缀过滤，类名再变也只降级为按名过滤 | `lib/selectors.psd1`、`commands/_common.ps1` |
| 搜索结果被"首行延迟"截断 | quiet-period 从**首次看到结果**起固定计时，QQ 分批渲染（先一条后一批）时第一批还没画完就返回 | 改为按"真实结果行数变化"重置计时（`lastChangeAt`），只要求"最近 3000ms 内行数没再变"，总等待仍受 `searchResultsMs` 上限 | `commands/_common.ps1` |
| 搜索看似成功但没有任何结果 | 键盘键入丢失后走 ValuePattern 兜底写入，搜索框值正确、QQ 不渲染结果，命令一路等到超时并把空结果当答案返回 | 删除兜底：回读失败即 `TIMEOUT` 并说明原因；关键词回读失败时 `searchValue=''` + `searchValueNote`，不回显请求值 | `commands/_common.ps1`、`commands/search.ps1` |
| 聊天记录行被误判（多余的结果类型） | 旧的 history 正则接受任意 `<名称> <数字>`，普通联系人行带尾随数字就被归成聊天记录 | 判定必须含本地化单位词（`Get-QQUiText 'historyUnit'`），且名称非空 | `commands/_common.ps1` |
| "发送成功"判据偏弱 | 只用 `selfMsgCount` 增量（虚拟化列表里数字会浮动），可能把"没发出去"算成成功 | 优先在消息区子树里按消息正文 Name 匹配新消息（`Get-QQDescendantsByName`），并保留计数增量作为兜底 | `commands/send-message.ps1` |
| 搜索覆盖层残留（v0.2 引入的收尾） | 下拉/综合搜索面板浮在会话列表上，`search` 返回后下一个物理点击（会话行、发送按钮）会落到覆盖层 | 返回前 `Send-QQEscape` 收起，`closed` 报告是否确认行已消失；`-KeepOpen` 保留行为；`open-chat` 搜索回落路径同样调用 | `commands/_common.ps1`、`commands/search.ps1`、`commands/_open.ps1` |
| 无障碍阈值不一致 | 一处硬编码 10、一处 100：`doctor` 报 `ready=true` 而命令以 `ENV_NOT_READY` 拒绝同一实例 | 统一 `a11y.minNodes` → `Get-QQA11yMinNodes` / `Test-QQA11yActive`，doctor 与实例前置检查共用；doctor 另外等待 `a11y.nodeCountTimeoutMs` 以适应惰性激活 | `lib/qq-core.ps1`、`commands/_common.ps1`、`commands/doctor.ps1` |

### 4.3 活体验证记录（2026-09-18，本机真实 QQ，QQNT 9.9.35-52892）

| 项 | 结果 |
|---|---|
| `doctor` | 2 个实例：pid `72192`（主账号 `渐行渐远`，`nodeCount` 548→578，`a11yActive=true`）与 pid `51976`（未激活，9 节点）；`ready=true`，`selectorDrift=[]`，`configWarnings=[]` |
| `accounts` | 用一个 `nick` 写成 `\uXXXX` 转义的配置条目验证：解析成功（`status=ok`），`unbound` 为空 |
| `list-sessions -Account master -Limit 5` | 返回 5 条真实会话（`-Account` 解析链在真实实例上可用） |
| `qq-config-ui.ps1` 启动冒烟 | 窗口标题「QQ 账号配置 - qq-uia」正常出现，正常关闭，未触碰 QQ 窗口 |
| `run-tests.ps1 -StaticOnly` | 23 项全过 |
| `qq-behavior.tests.ps1` | 168 项全过 |

> 复核时（同日 17:40）再次只读执行 `doctor`：`ready=true`、2 实例（pid 72192 主账号，`nodeCount` 553；pid 51976 未激活 9 节点）、
> `selectorDrift=[]`、`configWarnings=[]`；`accounts` 返回 `count=0`、`unbound=[{pid:72192, nick:渐行渐远}]`
> （当前 `config.json` 的 `accounts[]` 为空，与"未配置账号时按活体昵称寻址"的设计一致）。
> 本工作包只跑了只读命令（doctor/identify/accounts/list-sessions/-Help），**未执行 search / open-chat / read-chat / send-message**，
> 也没有改变任何 QQ 窗口状态。

### 4.4 待活体验证清单（需要真实 QQ 与真实搜索结果行时逐项复核）

| # | 待验证项 | 为什么还没验证 / 怎么验 |
|---|---|---|
| 1 | `Search.UmbrellaRow` / `Search.ResultItem` / `Search.Panel` / `Search.PanelItem` 的**真实类名** | 本机实测的关键词只渲染"进入综合搜索"入口，真实下拉行与面板行未曾出现。用一个一定能出结果的联系人昵称跑 `search -Activate 1`，比对 `results[]` 与 `umbrellaEntry` |
| 2 | Escape 是否能关掉下拉与面板，且**不影响已切换的会话** | `closed=true` 只证明结果行消失，未证明会话选择未回退。`search` 后接 `list-sessions` 看 `selected` 是否仍在预期会话 |
| 3 | quiet-period 3000ms 是否适合分批渲染 | 按真实下拉的渲染节奏调；现为固定 3000ms，行数变化会重置计时 |
| 4 | `historyUnit` 的真实文案拼写 | history 行判定依赖该词（`Get-QQUiText 'historyUnit'`）；用能出"聊天记录"结果的关键词验证一次 |
| 5 | 去重是否真的在"下拉 + 面板"之间发生 | `duplicatesRemoved` 在真机见过 >0 才算验证；同一目标被两个界面各渲染一次是预期场景 |
| 6 | `open-chat` 搜索回落路径的 `nick` 档匹配 | `Select-QQSearchRow` 的 `matchQuality='nick'` 尚未在真机走过（只走过 `first-row`）；需要搜索结果行存在时验证 |
| 7 | `closed` / `duplicatesRemoved` 的字段语义 | 确认：`closed` = 观察到结果行消失（不是按键注入成功）；`duplicatesRemoved` = 因 `kind\|name\|qqId` 重复被丢弃的行数 |
| 8 | 综合搜索面板的 `Panel` 容器猜测值 | `Stable=$false`、`Required=$false`，命中与否都不该阻塞任务；一旦真机确认，应更新 `selectors.psd1` 并改回 `Stable=$true` |

### 4.5 测试计数

| 套件 | v0.1 | v0.2 | 变化原因 |
|---|---|---|---|
| `run-tests.ps1` 静态 | 19 | **23** | 新增：`ui/config-ui.xaml` 可解析且控件名与脚本一致、`qq-config-ui.ps1` 不与库函数重名、`accounts`（无 pid 语义）、`-TimeoutSec` 注册/套用一致、`archive/` 隔离等 |
| `run-tests.ps1` 实测（需 QQ） | 6 | **6** | 未变（doctor/identify/list-sessions/read-chat/`-DryRun`/`ExpectNick` 不匹配 → exit 4） |
| `qq-behavior.tests.ps1` | 44 | **168** | v0.2 新增 10 项（`accounts` 注册与 schema、`config-ui` 为 L0 且不选实例、五个窗口命令的 `-Account` 注册与 `-SenderPid` 不再必填、出货 `config.json` 的 `accounts[]`/`defaultAccount` 校验）；其余为 DPI 两分支、冷却时间戳、search 解析/去重/匹配分级、命令面与选择器注册表等既有断言累积 |

最终一次运行：`run-tests.ps1 -StaticOnly` → **23 项全过**；`qq-behavior.tests.ps1` → **168 项全过**。

---

## 5. 已知限制（后续里程碑，不属于本期）

| 限制 | 说明 |
|---|---|
| 搜索下拉/面板的呈现随构建变化 | 选择器与收尾行为已按当前的观察实现，但真实下拉行与综合搜索面板尚未活体验证（见 §4.4）；会话定位仍以 `list-sessions` + `open-chat` 为主路径 |
| 消息列表是虚拟化的 | `read-chat` 只返回 QQ **当前已渲染**的消息；更早历史需要滚动，本期不实现滚动加载 |
| 非文本消息不可读 | 图片/文件/语音/卡片只能给 `kind` 与占位文案，`unreadable` 标记之 |
| 不监听新消息 | 设计 §2 非目标；`StructureChanged` 订阅未实测 |
| 不支持发群聊 | 设计 §6.3：无 `-AllowGroup`，检出群聊一律拒绝 |
| 不模拟打字速度抖动 | 设计 §2 明确不做反风控对抗；限频由手册与 `minSendIntervalMs` 约束 |
| Emoji 受限 | BMP 外字符（代理对）会被 `GUARD_MESSAGE_UNREPRESENTABLE` 拒绝，因为键盘注入通道无法可靠重现 |
| 配置界面是给人用的 | `qq-config-ui.ps1` 不做无窗口运行：`-NoWindow` 只用于自检路径；agent 读账号请用 `accounts` |
