# QQ UIA 发送前核对清单（Pre-flight Checklist）

> 本文件是 `AGENT-MANUAL.md` §4.1 第 3 步「核对」的操作化版本。
> 用途：把 **open-chat 的 JSON 字段 + 截图** 变成可逐项打勾的证据，防止发错会话。
> 权威文档：`FRAMEWORK-DESIGN.md`（框架契约）、`AGENT-MANUAL.md`（agent 契约）。

---

## 为什么需要这份清单

历史上发生过**消息发到错误会话**的事故，根因是只看「标题等于目标」就发送。
旧标题、搜索结果里的残留值都能满足「等于」，而聊天区实际还停在上一个会话。
本清单把「看起来对」换成「有证据」。

**任何一项无法打勾 → 停止，向用户报告，禁止进入 send-message。**

---

## 第 1 步：环境（doctor）

```
qq-uia.ps1 doctor
```

| # | 检查项 | 通过条件 | 不通过怎么办 |
|---|---|---|---|
| 1.1 | `ok` | `true` | 读 `error.message` 报告用户 |
| 1.2 | `data.instanceCount` | ≥ 1 | QQ 未运行 → 告知用户启动并登录，停止 |
| 1.3 | `data.a11yActive` | `true` | 提示用户以 `QQ.exe --force-renderer-accessibility` 重启 QQ，停止 |
| 1.4 | `data.selectorDrift` | 空数组 `[]` | 选择器漂移 → 报告用户，等 `lib/selectors.psd1` 更新，停止 |
| 1.5 | `data.configWarnings` | 空数组 `[]` | 配置关掉了安全网（如 `writeAudit=false` 却开着发送冷却）→ 先报告用户再继续 |
| 1.6 | `data.ready` | `true` | 以上各项的综合结论，为 false 即停止 |

`data.selectorOptionalMiss` **不必**为空：它是当前视图下本来就不存在的可选控件
（没有自己发的消息、输入框未聚焦、搜索面板未打开）。只报告，不阻塞。

---

## 第 2 步：确认「我是谁」与用哪个实例

```
qq-uia.ps1 accounts     # 有配置账号时：每个别名现在绑定到哪个实例
qq-uia.ps1 identify     # 没有配置账号时：每个实例登录的账号
```

| # | 检查项 | 通过条件 |
|---|---|---|
| 2.1 | 账号可解析 | 按用户指定的**账号**取 `accounts[]` 里的该条：`status == "ok"` 才用 `-Account <别名>`；`ambiguous` 时用 `live.candidates[].pid` 配合 `-SenderPid`；`not-running` / `disabled` → 停止并问用户 |
| 2.2 | 或按昵称定位实例 | 按用户指定的**昵称**在 `identify` 的 `instances[]` 里定位 `pid` |
| 2.3 | 目标唯一 | 找不到、或同名多条 → **停下来问用户，不要猜** |
| 2.4 | 账号来源可信 | 该项 `identitySource == "user-avatar"`，`nodeCount > 100`（或 `a11yActive == true`） |
| 2.5 | 只用本次会话的 pid | 禁止沿用历史 pid、禁止取最大窗口、禁止按启动顺序推断 |

两种寻址方式都可以，但**一次任务里保持一致**：用 `-Account` 就一路 `-Account`（框架每次重新解析到活体实例），
用 `-SenderPid` 就一路用第 2.2 步读到的那个 pid。

---

## 第 3 步：打开会话并核对（open-chat）

```
qq-uia.ps1 open-chat (-SenderPid <pid> | -Account <别名>) -ExpectNick <昵称> [-TargetId <QQ号>] [-SearchId <QQ号>]
```

### 3A JSON 字段核对（除 3A.3 外逐项必须成立）

| # | 字段 | 通过条件 | 含义 |
|---|---|---|---|
| 3A.1 | `data.expectNick` | 与用户指定的昵称**逐字相同** | 你的意图被原样传递 |
| 3A.2 | `data.header` | **精确等于** `expectNick` | 当前打开的会话就是目标 |
| 3A.3 | `data.headerChanged` | 仅作参考，**不作为通过条件** | `true` = 这次调用真的切换了会话；`false` = 目标会话本来就开着，也是成功 |
| 3A.4 | `data.isGroup` | `false` | 非群聊；群聊会被 send-message 拒绝 |
| 3A.5 | `data.editorPresent` | `true` | 输入框存在，能打字 |
| 3A.6 | `data.headerMatches` | `true` | **判目的地只看这一项**，3A.2 的布尔形式 |
| 3A.7 | `data.screenshot.error` | 空字符串 `""` | 截图真的拍到了目标窗口 |

`data.openedVia` 说明走了哪条路径：`session-list`（会话列表命中，最可靠）、
`search`（搜索命中）、`already-open`（本来就是这个会话，没有切换）。

### 3B 截图核对（**必须真的读图**，不能只看 JSON）

读 `data.screenshot.path`（或固定别名 `evidence/last-open-chat.png`），确认：

| # | 画面内容 | 通过条件 |
|---|---|---|
| 3B.1 | 聊天区标题 | 与被发消息的昵称一致 |
| 3B.2 | 会话主体 | 是用户指定的联系人/群本身，不是相似昵称 |
| 3B.3 | 窗口身份 | 顶栏账号 = 第 2 步确认的发送方账号 |
| 3B.4 | 无遮挡 | 画面是 QQ 聊天窗口，不是别的应用 |

> 若 `data.screenshot.error` 非空，或 `warnings` 里出现截图相关提示：**禁止发送**。
> 截图核对的目的是发现「JSON 说对了但画面是别人」这类情况。

### 3C 警告字段

`data.warnings` **非空时必须逐条读完**。出现下面任何一条即停止：

- `this is a group conversation: send-message will refuse it`
- `no message editor in this conversation: send-message will refuse it`
- `screenshot failed: ...`
- `-noScreenshot was used: ...`

---

## 第 4 步：发送（send-message）

```
qq-uia.ps1 send-message (-SenderPid <pid> | -Account <别名>) -ExpectNick <同一个昵称> -MessageFile <utf8文件>
```

| # | 检查项 | 通过条件 |
|---|---|---|
| 4.1 | `-ExpectNick` 与第 3 步**完全一致** | 不得改写、不得省略 |
| 4.2 | 实例寻址与第 3 步一致 | 用 `-Account` 就继续用 `-Account`，用 pid 就继续用同一个 pid |
| 4.3 | 消息用 `-MessageFile` 传中文 | 先写一个 UTF-8 无 BOM 文件，避免命令行码页转换乱码 |
| 4.4 | 发送前先跑一次 `-DryRun` | 可选但推荐：护栏全过、不键入不发送 |
| 4.5 | `exit == 0` 且 `data.sent == true` | 唯一成功判据 |
| 4.6 | `data.editorEmptied == true` | 输入框被清空 |
| 4.7 | `data.selfMsgCount` 比预期多 1 | 出现了新的自己发的消息 |
| 4.8 | `data.confirmed == true` | 4.6 与 4.7 的综合结论 |
| 4.9 | `data.accountGuard` | `explicit`（你传了 `-ExpectAccountNick`）或 `from-account`（框架用 `-Account` 解析出的昵称自动校验）；只有单实例环境才可接受 `none` |
| 4.10 | `data.auditLog` | 记录下来，报告时附上 |

### exit 4（GUARD_ABORT）的处理

**禁止**换参数重试、禁止绕过护栏（例如自己去 Invoke 发送按钮）。
读 `error.details.guard` 得到具体护栏名，停止任务并向用户报告：

| `details.guard` | 含义 | 用户需要做什么 |
|---|---|---|
| `GUARD_HEADER_MISMATCH` | 打开的会话不是目标 | 重新 open-chat，确认到底要发给谁 |
| `GUARD_GROUP_REJECTED` | 目标是群聊 | 本框架默认不发群；需用户明确改变需求 |
| `GUARD_EDITOR_MISSING` | 该会话没有输入框 | 可能不是可发消息的会话 |
| `GUARD_EDITOR_NOT_EMPTY` | 输入框里有未发出的草稿 | **不替你发送草稿**；让用户清理后再来 |
| `GUARD_READBACK_FAILED` | 键入内容没进输入框 | 重跑 open-chat 后重试一次，仍失败则人工介入 |
| `GUARD_MESSAGE_EMPTY` | 消息为空 | 补上消息内容 |
| `GUARD_MESSAGE_MULTILINE` | 消息含换行 | 本框架只发单行；改成一行 |
| `GUARD_MESSAGE_UNREPRESENTABLE` | 含代理对（BMP 外 emoji）或控制字符 | 去掉这些字符 |
| `GUARD_ACCOUNT_MISMATCH` | 实例账号与预期不符 | 多开环境；回到第 2 步重新确认 pid |
| `GUARD_RATE_LIMIT` | 距上次发送太近 | 等待冷却时间，或由用户确认后调整配置 |
| `GUARD_EXPECT_NICK_MISSING` | 没传 `-ExpectNick` | 补上目标昵称 |

---

## 第 5 步：汇报

向用户报告以下内容，缺一不可：

1. 发送方账号（`data.account.nick`）与实例 pid
2. 接收方昵称（`data.header`）
3. 消息内容
4. 结果：`sent` / `confirmed` / `editorEmptied` / `selfMsgCount` 的变化
5. 审计日志路径（`data.auditLog`）与截图路径
6. 过程中的任何 `notes` / `warnings`

---

## 附：清晰度不足时的替代路径

| 情况 | 做法 |
|---|---|
| 会话不在可见列表、搜索也没有结果行 | 停止并告知用户：该会话在当前视图不可达，需要用户在 QQ 里先打开一次或用 `list-sessions` 确认可达范围 |
| 需要确认「某昵称是否就是某 QQ 号」 | 用 `search` 看结果行，或请用户确认；**不要靠昵称相似度猜** |
| 只想看消息不想发 | 用 `read-chat`，它不键入任何内容 |
| 需要连发多条 | **拒绝**；逐条走本清单，每条发送前单独向用户确认 |
