# QQ UIA 自动化框架 — Agent 任务手册

> 版本：v0.2（随 FRAMEWORK-DESIGN.md v0.2）　日期：2026-09-18
> 适用对象：通过本框架操作本机 QQ 的自动化 agent（Kimi Code 等）
> v0.2 变化：实例寻址改为 `-SenderPid` / `-Account` 二选一（`accounts` 命令负责对账），
> 新增 `config-ui`（给人用的配置界面，agent 不用），`search` 新增去重与 Escape 收尾，
> `doctor` 新增 `configWarnings`。
> 框架设计背景见 `FRAMEWORK-DESIGN.md`；QQ 控件实测细节见 `README-QQNT-UIA.md`

---

## 0. 这是什么

本框架把本机 QQ（QQNT 9.9.x）的 UI 自动化封装为一条命令行：`qq-uia.ps1 <子命令> [参数]`。你（agent）通过 Bash 调用它，**只解析 stdout 的 JSON**，按本手册的 SOP 组合子命令完成任务。

能做什么：枚举 QQ 实例与账号、读会话列表、打开会话、读消息记录、发送**纯文本**消息、全局搜索联系人。

不能做什么：发图片/文件/红包、撤回消息、监听新消息推送、操作 CDP 或 QQ 内部接口、多账号并发操作。

## 1. 铁律（违反任何一条 = 事故）

1. **发送必须两阶段**：先 `open-chat` 核对（返回 header 与截图路径），再 `send-message`。禁止只跑 `send-message`。
2. **`send-message` 必须带 `-ExpectNick`**，且必须精确等于目标昵称。框架护栏拒绝时（exit 4）**禁止换参数重试蒙混**，必须从头走 SOP。
3. **实例必须指明确：`-SenderPid` 或 `-Account` 二选一**。`-SenderPid` 必须来自本次会话内 `identify` 的返回，禁止沿用历史 pid、禁止猜测、禁止"取最大窗口"；`-Account` 来自 `config.json` 的 `accounts[]`（别名 / 昵称 / QQ 号）。两者都不传时框架会用 `defaultAccount` 兜底，所以**不要依赖兜底**——显式说出你要用哪个实例。用错账号等于发错人：`-Account` 解析到 0 个或 ≥2 个实例时命令直接以 `NOT_FOUND` 失败，不要自己挑一个。
4. **一次任务只发一条消息**。批量发送必须逐条人工确认。禁止在循环里调用 `send-message`。
5. **禁止调用 `archive/` 目录下的任何脚本**（无护栏历史版本，曾导致误发到错误会话）。
6. **默认不发群聊**。`send-message` 检出群聊会拒绝；不要尝试绕过（如手动 Invoke 发送按钮）。

## 2. 调用方式

统一调用模板（bash）：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File qq-uia.ps1 <子命令> [参数...]
```

- **stdout 只有一个 JSON 对象**，用 `jq` 或解析工具读取；人类日志在 stderr，可忽略。
- **退出码语义化**：0 成功；2 参数错误；3 目标未找到；4 护栏拒绝（禁止重试）；5 环境未就绪；6 超时。完整表见 §7。
- 中文消息文本优先用 `-MessageFile <UTF-8 文件路径>` 传递（先 Write 一个临时 UTF-8 文件），避免 bash → powershell.exe 的码页转换乱码；`-Message` 字面量仅在已验证编码正常时使用。

## 3. 前置检查（每个任务的第一步）

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File qq-uia.ps1 doctor
```

检查返回 JSON：

| 字段 | 期望 | 不满足时 |
|---|---|---|
| `ok` | `true` | 按 `error.message` 处理 |
| `data.instances` | 至少 1 个 | QQ 未运行 → 告知用户启动并登录 QQ，停止任务 |
| `data.a11yActive` | `true`（`nodeCount` > `data.a11yMinNodes`，默认 100） | 提示用户以 `QQ.exe --force-renderer-accessibility` 重启 QQ，停止任务 |
| `data.selectorDrift` | 空数组 `[]` | QQ 版本漂移 → 报告用户，停止任务，等待选择器更新 |
| `data.configWarnings` | 空数组 `[]` | 配置关掉了安全网（如 `writeAudit=false` 却开着发送冷却）→ 先报告用户，拿到明确答复再继续 |
| `data.ready` | `true` | 以上条件的综合结论，为 `false` 即停止 |

`data.selectorOptionalMiss` **不必**为空：它是当前视图下本来就不存在的可选控件（没有自己发的消息、输入框未聚焦、搜索面板未打开），只报告不阻塞。

`doctor` 不通过时**不要尝试任何后续命令**。

如果用户是按账号（比如"用工作号发"）下的指令，先跑 `accounts` 确认这个账号现在落在哪个实例上：`status == "ok"` 才能用 `-Account`，`ambiguous` 时用 `live.candidates` 里的 pid 配合 `-SenderPid`，`not-running` 时告诉用户该账号没登录或无障碍树没激活。

## 4. 标准任务流程（SOP）

### 4.1 发送一条消息给指定联系人

```
doctor → accounts/identify → open-chat → （核对）→ send-message → 汇报
```

1. `doctor`：确认环境（§3）。
2. **确定实例**（二选一，不要跳）：
   - 用户按**账号**下指令（"用工作号发"）：跑 `accounts`，取该账号的 `status`/`live.pid`。`ok` → 后面统一用 `-Account <别名>`；`ambiguous` → 用 `live.candidates[].pid` 配合 `-SenderPid`；`not-running` → 停下问用户。
   - 用户没有账号概念：跑 `identify`，从 `instances[]` 里按用户指定的昵称找 `pid`，后面统一用 `-SenderPid <pid>`。找不到、或同名多条 → 停下来问用户，**不要猜**。
3. `open-chat (-SenderPid <pid> | -Account <别名>) -ExpectNick <昵称> [-TargetId <QQ号>] [-SearchId <QQ号>]`：
   - 检查返回 `data.headerMatches == true`、`data.isGroup == false`、`data.editorPresent == true`；
   - `data.headerChanged` 只是证据：`true` 说明这次调用真的切换了会话，`false` 说明本来就是该会话（也是成功），**判断目的地只看 `headerMatches`**；
   - 用 `data.screenshot.path` 读截图（ReadMediaFile）肉眼核对标题、对象与发送方账号；
   - 任一不符 → 停止，向用户报告截图与 JSON，禁止进入第 4 步。
4. `send-message (-SenderPid <pid> | -Account <别名>) -ExpectNick <昵称> -MessageFile <文件>`：
   - exit 4（护栏拒绝）→ 停止并报告，**禁止重试**；
   - exit 0 且 `data.sent == true` 且 `data.editorEmptied == true` → 发送成功；
   - `data.accountGuard` 说明发送账号是怎么被校验的：`explicit`（你传了 `-ExpectAccountNick`）、`from-account`（框架用 `-Account` 解析出的昵称自动校验）、`none`（都没做，只在单实例环境可接受）。
5. 向用户汇报：发送方账号、接收方昵称、消息内容、发送结果、审计日志路径 `data.auditLog`。

### 4.2 读取某会话的最近消息

```
doctor → accounts/identify → read-chat
```

`read-chat (-SenderPid <pid> | -Account <别名>) -OpenNick <昵称> [-Limit 50]`，从 `data.messages[]` 读取（`sender`/`self`/`time`/`type`/`text`）。图片消息只能得到 `type: "image"`，内容不可读，如实告知用户。

### 4.3 确认"我是谁"（多开场景）

机器上可能同时登录多个账号，**窗口大小、启动顺序都不可作为身份依据**。

- 推荐：跑 `accounts`，每行给出配置别名与实时绑定（`status`/`live.pid`/`live.nick`），随后所有窗口命令统一用 `-Account <别名>`——框架每次都会把 `-Account` 重新解析到活体实例，账号与 pid 的对应关系不需要你记。
- 没有配置账号时：跑 `identify`，以 `instances[].nick` 为准取 `pid`，用 `-SenderPid` 寻址。`identify` 的每条记录还带 `alias`/`matchedBy`，可以用它检查配置文件与实际情况是否一致（`matchedBy` 为 `nick`/`alias`，空表示该实例没有任何启用的账号条目描述它）。
- 两种方式都不要跨会话记 pid：`-SenderPid` 必须来自本次 `identify`。

## 5. 命令参考

### doctor（L0 只读）

环境体检。无参数。返回 `instances[]`、`a11yActive`、`nodeCount`、`selectorDrift`、`selectorOptionalMiss`、`configWarnings[]`、`ready`、`hint`。

### identify（L0 只读）

枚举全部 QQ 实例。返回 `instances[]: {pid, hwnd, title, width, height, scale, nodeCount, nick, signature, online, a11yActive, identitySource, alias, matchedBy}`。多开时返回多条；`pid` 只在恰好一个实例登录时给出。

### accounts（L0 只读）

```
accounts [-Account <别名|昵称|QQ号>]
```

列出 `config.json` 的 `accounts[]` 与每条的实时绑定状态。返回 `accounts[]`（每行 `alias`/`nick`/`qqId`/`enabled`/`note`/`isDefault`/`status`/`live`）、`count`、`okCount`、`defaultAccount`、`accountsWarning`、`unbound[]`。

`status` 的四种取值就是"这个账号现在能不能用 `-Account`"的答案：

| `status` | 含义 | 你的对策 |
|---|---|---|
| `ok` | 恰好一个实例以该昵称登录 | 直接用 `-Account <别名>` |
| `ambiguous` | 多个实例同名 | `live.candidates[].pid` 里挑一个，用 `-SenderPid` |
| `not-running` | 没有实例以该昵称登录 | 账号没登录或无障碍树没激活，停下问用户 |
| `disabled` | 该条 `enabled=false` | 不参与 `-Account` 解析；需要时让用户改配置 |

`unbound[]` 是"有实例但没有启用的配置条目描述它"，也是用户补写 `accounts[]` 时的输入。

### config-ui（L0 只读）

```
config-ui
```

打开图形化配置界面（唯一会启动进程的命令，启动的是框架自己的 UI）。返回 `launched`、`path`；命令立刻返回，窗口是独立进程。**agent 不调用它**（见下方"配置 UI"）。

### list-sessions（L0 只读）

```
list-sessions (-SenderPid <pid> | -Account <别名>) [-Limit 10]
```

返回 `sessions[]: {title, preview, time, unread, selected}`（当前会话列表，含未读数）。

### read-chat（L1 界面变更）

```
read-chat (-SenderPid <pid> | -Account <别名>) -OpenNick <昵称> [-Limit 50] [-TargetId <QQ号>] [-SearchId <QQ号>] [-TimeoutSec 30]
```

打开指定会话并读消息。返回 `header`、`isGroup`、`messages[]: {sender, self, time, type, text}`。

### search（L1 界面变更）

```
search (-SenderPid <pid> | -Account <别名>) -Keyword <关键词> [-Limit 30] [-Activate 0|1] [-KeepOpen] [-TimeoutSec 30]
```

全局搜索。返回：

| 字段 | 含义 |
|---|---|
| `results[]: {index, kind, name, detail, qqId, raw}` | `kind` = `contact`/`group`/`history`/`unknown`；`index` 是渲染位置，点选按位置 |
| `count` / `duplicatesRemoved` | 去重之后的条数 / 被去重的条数（去重键 `kind|name|qqId`，排序 contact→group→history） |
| `umbrellaEntry` | "进入综合搜索"入口行（不是真实结果，单独列出），没有则 `null` |
| `panelUsed` | `-Activate 1` 是否成功读到综合搜索面板里的行 |
| `closed` | 返回前是否确认下拉/面板已被 Escape 关掉（`-KeepOpen` 时为 `false`） |
| `searchValue` / `searchValueNote` | 搜索框的当前值；回读失败时为空并附说明（绝不回显你请求的关键词） |
| `notes[]` | 逐条说明：没有结果行、面板没找到、行名称为空、覆盖层没关掉等 |

注意：联系人结果行名称可能为空字符串（QQ 渲染时序问题），此时它仍是第一条结果。默认结束时框架会按 Escape 收起下拉/面板（它会浮在会话列表上，留着的下一个点击就会落到它上面）；需要自己接着点结果行时用 `-KeepOpen`。

### open-chat（L1 界面变更，发送流程第 1 步）

```
open-chat (-SenderPid <pid> | -Account <别名>) -ExpectNick <昵称> [-TargetId <QQ号>] [-SearchId <QQ号>] [-AllowSameHeader] [-noScreenshot] [-TimeoutSec 30]
```

打开会话 + 切换生效校验 + 截图留证。返回 `header`、`headerMatches`、`headerChanged`、`headerBefore`、`expectNick`、`openedVia`、`isGroup`、`editorPresent`、`sendButtonPresent`、`screenshot`、`warnings[]`。**本命令不发送任何内容。**

- 判断目的地只看 `headerMatches`；
- `headerChanged` 是证据（这次是否真的切换了会话），重复读同一个会话时为 `false`，那也是成功；
- 打开路径优先走会话列表，必要时回落到搜索，`openedVia` 告诉你走了哪条。

### send-message（L2 对外写入，发送流程第 2 步）

```
send-message (-SenderPid <pid> | -Account <别名>) -ExpectNick <昵称> (-MessageFile <utf8路径> | -MessageBase64 <b64> | -Message <文本>) [-ExpectAccountNick <昵称>] [-TimeoutSec 30] [-DryRun]
```

五道护栏（任一不过即 exit 4，不发）：标题精确等于 ExpectNick → 非群聊 → 输入框存在 → 键入后回读确认 → 发送前再读标题。发送账号另有一道校验：显式 `-ExpectAccountNick`，或由 `-Account`/`defaultAccount` 解析出的配置昵称自动注入（`data.accountGuard` = `explicit` / `from-account` / `none`）。`-DryRun` 只跑到护栏校验为止，不键入不发送。

返回 `sent`、`confirmed`、`editorEmptied`、`selfMsgVisible`、`selfMsgCount`、`account`、`accountGuard`、`header`、`dryRun`、`auditLog`。

### 配置 UI（给人用，agent 不碰）

`config.json` 里的 `accounts[]` / `defaultAccount` 由**人**通过图形界面维护：`qq-uia.ps1 config-ui`，或直接 `powershell -STA -NoProfile -ExecutionPolicy Bypass -File qq-config-ui.ps1`。界面列出正在运行的实例，允许增删改账号、从选中实例绑定昵称、设为默认，保存前校验并备份为 `config.json.bak`。

agent 的规矩：

- **不要**为了"看看有哪些账号"去开 UI——那是给人看的，且它会启动一个窗口进程。你要读账号就调 `accounts`（L0，纯 JSON，只读）；
- **不要**直接编辑 `config.json` 里的账号表。想加账号就报告用户："需要把 <别名/昵称> 写进 config.json 的 accounts[]（可用 `config-ui`）"，然后停下；
- 界面上那个"复制无障碍启动命令"只把命令行放进剪贴板，**不会执行**。要激活无障碍树仍然只能请用户自己用 `--force-renderer-accessibility` 重启 QQ（§3）。

## 6. 常见任务速查

| 用户意图 | 你的动作 |
|---|---|
| "给某某发条消息" | SOP 4.1 |
| "用某个账号发/读" | 先 `accounts` 确认该账号 `status == "ok"`，再按 SOP 4.1/4.2 用 `-Account <别名>` |
| "某某最近说了什么" | SOP 4.2 |
| "我有哪些未读" | `list-sessions`，筛选 `unread > 0` |
| "查一下某个 QQ 号是谁" | `search -Keyword <QQ号>` |
| "现在登录的是哪个号" | `accounts`（有配置账号时）或 `identify`（SOP 4.3） |
| "把这个账号写进配置" | 你不改 `config.json`：报告用户可用 `qq-uia.ps1 config-ui` 添加 |
| "把这段话群发给……" | **拒绝循环发送**；逐条走 4.1，每条发送前向用户确认 |
| "发张图片给某某" | 不支持，告知用户框架仅支持纯文本 |

## 7. 退出码与对策

| 码 | 含义 | 你的对策 |
|---|---|---|
| 0 | 成功 | 解析 `data` 继续 |
| 1 | 未分类错误 | 读 `error.message` 报告用户 |
| 2 | 参数错误 | 检查实例寻址（`-SenderPid` 或 `-Account`）、`-ExpectNick`、消息三者之一等必填项后重试 |
| 3 | 目标未找到 | 实例解析失败 → `accounts` / `identify` 重新确认；会话未找到时先 `search` 确认关键词 |
| 4 | 护栏拒绝 | **停止，报告，禁止绕过或换参数重试** |
| 5 | 环境未就绪 | 回到 §3 前置检查 |
| 6 | 超时 | 可原样重试一次；再失败则报告用户检查 QQ 窗口状态 |

## 8. 已知陷阱速查

- **标题以 `headerMatches` 为准，`headerChanged` 只是证据**：`open-chat` 只在标题精确等于 `-ExpectNick` 时才正常返回，所以判目的地看 `data.headerMatches == true`。`data.headerChanged == false` **不是失败**——它说明你要的会话本来就开着；不要因此重试，更不要把"标题变化过"当成通过条件。
- **`-Account` 有歧义就是拒绝，不是让你挑**：`NOT_FOUND` 且 `error.details.candidates` 非空表示多个实例同名，用其中的 `pid` 配合 `-SenderPid` 重来；`candidates` 为空表示该账号没登录或无障碍树没激活，回去看 `doctor`。
- **`open-chat` 不要求"必须变化"**：见上一条。只有当你确实需要"这次一定发生了切换"时才看 `headerChanged`；重复读同一会话用 `-AllowSameHeader` 明确表达意图。
- **`search` 返回前会自己收起下拉/面板**：`data.closed == false` 表示没收干净（覆盖层可能还浮在会话列表上），此时不要接着盲点会话行或发送按钮，重跑一次 `search` 或先自行确认覆盖层已消失。需要自己接着点结果行时传 `-KeepOpen`。
- **搜索结果第一行可能名称为空**：按位置取第一条，不要按名称过滤掉空串。`-Activate 1` 时看 `data.panelUsed` 判断读到的是综合搜索面板还是下拉，`data.notes[]` 逐条说明降级原因。
- **输入框是 contenteditable**：没有 ValuePattern，框架内部用键盘输入；你不要尝试自己 SendKeys 到 QQ 窗口。
- **坐标不需要你算**：UIA 报的是物理像素，框架按自身进程的实际 DPI 感知级别决定是否换算（感知时原样使用，未感知时才按 `dpi.scale` 换算）。你不要自己点坐标、也不要自己套缩放系数——所有交互走框架命令。
- **发送判据**：以 `sent == true`、`confirmed == true` 且 `editorEmptied == true` 为准，不以"命令返回 0"为唯一依据（返回 0 时仍要检查这些字段）。`confirmed` 是"输入框清空 + 出现自己发的消息"的综合结论。
- **审计追溯**：每次发送的证据在 `data.auditLog` 指向的 `evidence/audit.jsonl`，报告时附上。

## 9. 版本漂移与维护

QQ 升级后控件 class 名可能变化。`doctor` 的 `selectorDrift` 会报出"没命中且被标记为必需"的选择器；`selectorOptionalMiss` 只是当前视图下本就不存在的可选控件，不表示漂移。出现漂移时停止任务并报告用户："QQ 版本升级导致选择器漂移，需更新 `lib/selectors.psd1`"。不要自行猜测新的 class 名——选择器必须来自对真实窗口的 UIA 探测（用 `qq-uia-probe` 类只读工具），探测与更新是维护任务，不是发送任务的一部分。
