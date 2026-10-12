# DO NOT USE ANYTHING IN THIS DIRECTORY

These files are **quarantined historical scripts**. They are kept only so the
record of what was tried stays traceable. Nothing here is part of the framework,
nothing here is maintained, and no command in the framework can reach it.

Authority: `docs\FRAMEWORK-DESIGN.md` section 6 ("archive 目录下全部脚本物理移入框架的 archive/"),
`docs\AGENT-MANUAL.md` rule 5 ("禁止调用 archive/ 目录下的任何脚本").

If you are an agent: **do not read these files for guidance and never execute
them.** Their behaviour is superseded by the commands in `..\commands\`, and the
live documentation is `..\docs\`.

## unsafe-no-guards/

Send-path scripts from before the framework. Running any of them can put a
message in the wrong conversation. The recorded incidents and defects:

| Defect | File | Consequence |
|---|---|---|
| Hardcoded `$SenderPid = 86324` | `qq-step2-send.ps1`, `qq-step1-open.ps1` | On any other machine or account the send targets a different instance |
| Built-in fallback text when `-Message` was empty | `qq-step2-send.ps1` | A forgotten argument still sent a real message |
| No header/group/read-back verification | `qq-send.ps1`, `qq-send2.ps1`, `qq-send3.ps1`, `qq-open-chat.ps1` | Documented cause of messages reaching the wrong conversation |
| No account check, no audit trail | all files here | A wrong-account or wrong-target send left no evidence |

The framework replaces every one of these with the guard chain in
`..\lib\qq-guards.ps1`, which no command can bypass.

## probe-era/

One-off reconnaissance scripts that answered the questions in
`..\docs\FRAMEWORK-DESIGN.md` section 10. They print human-readable dumps, not
the JSON envelope, and they hardcode pids. Superseded by
`..\commands\doctor.ps1`, which performs the same probes and reports selector
health as JSON.

## read-only/

Read-only helpers from the probe era, including the original `qq-lib.ps1` that
`..\lib\qq-core.ps1` was hardened from. They never sent anything, but they select
their target by **largest window**, which `..\docs\AGENT-MANUAL.md` forbids: one
QQ process can own several visible top-level windows (a small toast next to the
main window), so "largest" is not a safe selector. `..\lib\qq-core.ps1` filters
by window class and width floor instead.

## cdp-blocked/

Chrome DevTools Protocol attempts. QQNT 9.9.35 strips `--remote-debugging-port`
in its launcher, so the port never opens. Kept to document a dead end that should
not be re-attempted; the live decision is recorded in
`..\docs\FRAMEWORK-DESIGN.md` section 2 ("不触碰 CDP").
