# =============================================================================
# qq-behavior.tests.ps1 - behaviour assertions that need no QQ and no UIA.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File qq-behavior.tests.ps1
#
# These cover the framework-level invariants that are cheap to prove and
# expensive to get wrong: the process contract (no QQ process control), the
# streaming contract (no stray stdout), the error-class contract, and the guard
# table's completeness. run-tests.ps1 covers the command surface and the live
# read path; this file covers the core library in isolation.
#
# ASCII-ONLY SOURCE.
# =============================================================================

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$passed = 0
$failed = 0

function Assert-True {
  param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$What)
  if ($Condition) {
    $script:passed++
    Write-Host ("  ok    {0}" -f $What) -ForegroundColor Green
  } else {
    $script:failed++
    Write-Host ("  FAIL  {0}" -f $What) -ForegroundColor Red
  }
}

Write-Host ''
Write-Host 'QQ UIA framework - behaviour assertions' -ForegroundColor Cyan

. (Join-Path $root 'lib\qq-json.ps1')
. (Join-Path $root 'lib\qq-core.ps1')
. (Join-Path $root 'lib\qq-guards.ps1')

Write-Host ''
Write-Host '[process contract]' -ForegroundColor Cyan

$coreText = [System.IO.File]::ReadAllText((Join-Path $root 'lib\qq-core.ps1'), [System.Text.Encoding]::UTF8)
$cmdText = ($(Get-ChildItem (Join-Path $root 'commands') -Filter '*.ps1' -File) | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8) }) -join "`n"
$allText = $coreText + "`n" + $cmdText

# The contract is about the QQ application, not about processes in general. The
# configuration UI has to start its own powershell.exe host (a WPF window needs an
# STA process), and run-tests.ps1 starts one for every dispatcher failure path, so
# "no Start-Process anywhere" would forbid the framework's own tooling while still
# not proving anything about QQ. What is asserted instead:
#   * no source stops or kills ANY process (Stop-Process, .Kill(), taskkill),
#     because a targeted kill is one typo away from killing the wrong one;
#   * no source can start a QQ process;
#   * and positively, every Start-Process in the shipped framework starts either a
#     powershell host or Explorer, so a new call site cannot quietly target
#     something else.
$processScopeText = $allText + "`n" +
  [System.IO.File]::ReadAllText((Join-Path $root 'qq-config-ui.ps1'), [System.Text.Encoding]::UTF8) + "`n" +
  [System.IO.File]::ReadAllText((Join-Path $root 'qq-uia.ps1'), [System.Text.Encoding]::UTF8)

Assert-True -Condition ($processScopeText -notmatch 'Stop-Process|\.Kill\(|taskkill') -What 'nothing in the framework stops or kills a process'
Assert-True -Condition ($processScopeText -notmatch "Start-Process[^\r\n]*(QQ\.exe|'QQ'|""QQ"")") -What 'no source can start a QQ process'
$startLines = @(($processScopeText -split "`n") | Where-Object { $_ -match 'Start-Process' })
$badStarts = @($startLines | Where-Object { $_ -notmatch 'powershell|explorer' })
Assert-True -Condition ($badStarts.Count -eq 0) -What ('every one of the {0} Start-Process calls starts a powershell host or Explorer' -f @($startLines).Count)

Write-Host ''
Write-Host '[config ui]' -ForegroundColor Cyan

# The registry is the only way a command becomes reachable, so the window ships
# only if the dispatcher lists it, the command file exists, AND the peer script the
# command launches is present. A registered command pointing at a missing file is
# exactly the failure a partial copy of the framework produces.
$dispatcherText = [System.IO.File]::ReadAllText((Join-Path $root 'qq-uia.ps1'), [System.Text.Encoding]::UTF8)
$regStart = $dispatcherText.IndexOf('function Get-QQCommandRegistry')
$regEnd = $dispatcherText.IndexOf('function Write-QQUsage')
$cmdRegistry = $null
if ($regStart -ge 0 -and $regEnd -gt $regStart) {
  Invoke-Expression $dispatcherText.Substring($regStart, $regEnd - $regStart)
  $cmdRegistry = Get-QQCommandRegistry
}
Assert-True -Condition ($null -ne $cmdRegistry -and $cmdRegistry.Contains('config-ui')) -What 'the dispatcher registers a config-ui command'
$uiCommandFile = ''
if ($null -ne $cmdRegistry -and $cmdRegistry.Contains('config-ui')) { $uiCommandFile = [string]$cmdRegistry['config-ui'].File }
Assert-True -Condition ($uiCommandFile -eq 'config-ui.ps1') -What 'config-ui is served by commands/config-ui.ps1'
Assert-True -Condition (-not [string]::IsNullOrEmpty($uiCommandFile) -and (Test-Path -LiteralPath (Join-Path $root ('commands\{0}' -f $uiCommandFile)))) -What 'the registered config-ui command file exists'
Assert-True -Condition ($cmdText -match 'qq-config-ui\.ps1') -What 'config-ui launches the framework UI script'
Assert-True -Condition (Test-Path -LiteralPath (Join-Path $root 'qq-config-ui.ps1')) -What 'the UI script qq-config-ui.ps1 ships with the framework'
Assert-True -Condition (Test-Path -LiteralPath (Join-Path $root 'ui\config-ui.xaml')) -What 'the UI layout ui/config-ui.xaml ships with the framework'

Write-Host ''
Write-Host '[stdout contract]' -ForegroundColor Cyan

# The framework must write the envelope through [Console]::Out and never through
# Write-Output, which a caller's pipeline could interleave with other output.
$jsonText = [System.IO.File]::ReadAllText((Join-Path $root 'lib\qq-json.ps1'), [System.Text.Encoding]::UTF8)
Assert-True -Condition ($jsonText -match '\[Console\]::Out\.WriteLine') -What 'the envelope is written through [Console]::Out'
Assert-True -Condition ($jsonText -notmatch '(?m)^\s*Write-Output\s+\$json') -What 'the envelope is never written through Write-Output'

Write-Host ''
Write-Host '[error class contract]' -ForegroundColor Cyan

$names = @('OK', 'ERROR', 'BAD_ARGS', 'NOT_FOUND', 'GUARD_ABORT', 'ENV_NOT_READY', 'TIMEOUT')
$codes = @(0, 1, 2, 3, 4, 5, 6)
$i = 0
foreach ($n in $names) {
  Assert-True -Condition ((Get-QQExitCode -Name $n) -eq $codes[$i]) -What ("exit code {0} = {1}" -f $codes[$i], $n)
  $i++
}
Assert-True -Condition ((Resolve-QQExitCodeName -Code 'GUARD_ANY_NEW_RULE') -eq 'GUARD_ABORT') -What 'an unmapped GUARD_* code still maps to GUARD_ABORT'
Assert-True -Condition ((Resolve-QQExitCodeName -Code 'NOT_FOUND') -eq 'NOT_FOUND') -What 'a base code passes through unchanged'
Assert-True -Condition ((Resolve-QQExitCodeName -Code '') -eq 'ERROR') -What 'an empty code falls back to ERROR'
Assert-True -Condition ((Resolve-QQExitCodeName -Code 'SOMETHING_ELSE') -eq 'ERROR') -What 'an unknown code falls back to ERROR'

Write-Host ''
Write-Host '[guard table completeness]' -ForegroundColor Cyan

# Every throw of a GUARD_* code must be a code the manual documents, so the
# agent's recovery table stays exhaustive.
$guardCodes = New-Object System.Collections.ArrayList
$rx = [regex]'Code\s+''(GUARD_[A-Z_]+)'''
foreach ($m in $rx.Matches($allText + "`n" + [System.IO.File]::ReadAllText((Join-Path $root 'lib\qq-guards.ps1'), [System.Text.Encoding]::UTF8))) {
  if (-not $guardCodes.Contains($m.Groups[1].Value)) { [void]$guardCodes.Add($m.Groups[1].Value) }
}
Assert-True -Condition ($guardCodes.Count -ge 10) -What ("{0} distinct guard codes are used" -f $guardCodes.Count)
foreach ($code in $guardCodes) {
  Assert-True -Condition ((Resolve-QQExitCodeName -Code $code) -eq 'GUARD_ABORT') -What ("{0} maps to exit 4" -f $code)
}

Write-Host ''
Write-Host '[payload contract]' -ForegroundColor Cyan

$sendable = Assert-QQSendableMessage -Text 'hello'
Assert-True -Condition ($sendable.Length -eq 5) -What 'a plain message normalizes to its length'
Assert-True -Condition ($sendable.Hash -match '^[0-9a-f]{64}$') -What 'the message hash is a 64-character hex digest'
Assert-True -Condition ((Assert-QQSendableMessage -Text 'x').Hash -eq (Assert-QQSendableMessage -Text 'x').Hash) -What 'the same text hashes identically'
Assert-True -Condition ((Assert-QQSendableMessage -Text 'x').Hash -ne (Assert-QQSendableMessage -Text 'y').Hash) -What 'different text hashes differently'

$crlfRejected = $false
try { [void](Assert-QQSendableMessage -Text "a`r`nb") } catch { $crlfRejected = ([string]$_.Exception.Data['QQCode'] -eq 'GUARD_MESSAGE_MULTILINE') }
Assert-True -Condition $crlfRejected -What 'a CRLF message is rejected as multiline'

$astralRejected = $false
$astral = [string][char]0xD83D + [string][char]0xDE00
try { [void](Assert-QQSendableMessage -Text $astral) } catch { $astralRejected = ([string]$_.Exception.Data['QQCode'] -eq 'GUARD_MESSAGE_UNREPRESENTABLE') }
Assert-True -Condition $astralRejected -What 'an astral (surrogate pair) character is rejected'

Write-Host ''
Write-Host '[dpi conversion]' -ForegroundColor Cyan

$p = Get-QQLogicalPoint -X 1500 -Y 900 -Scale 1.5
Assert-True -Condition ($p.X -eq 1000 -and $p.Y -eq 600) -What 'physical pixels convert to logical at 150%'
$p2 = Get-QQLogicalPoint -X 1500 -Y 900 -Scale 1.0
Assert-True -Condition ($p2.X -eq 1500 -and $p2.Y -eq 900) -What 'a 100% scale is a pass-through'
$p3 = Get-QQLogicalPoint -X 100 -Y 100 -Scale 0.5
Assert-True -Condition ($p3.X -eq 100) -What 'a scale below 1 is clamped, never enlarging coordinates'

# Awareness decides whether a conversion happens at all: an aware process reads
# physical pixels from UIA and writes physical pixels to the cursor API, so
# dividing there moves the click off the target. Both branches are forced here,
# because the host's real level is a property of the machine, not of the code.
$savedAwareness = Get-QQDpiAwareness
Assert-True -Condition (@('per-monitor-v2', 'per-monitor', 'system', 'unaware', 'unknown') -contains $savedAwareness) -What ("the process reports a dpi awareness level at load ({0})" -f $savedAwareness)

$script:QQ_DPI_AWARE = 'per-monitor-v2'
$awarePoint = Convert-QQPointToPhysical -X 1500 -Y 900 -Scale 1.5
Assert-True -Condition ($awarePoint.X -eq 1500 -and $awarePoint.Y -eq 900) -What 'a dpi-aware process passes a UIA point through unconverted'
$awareRect = Convert-QQWindowRectToPhysical -Left 100 -Top 200 -Right 1100 -Bottom 800 -Scale 1.5
Assert-True -Condition ($awareRect.X -eq 100 -and $awareRect.Y -eq 200 -and $awareRect.W -eq 1000 -and $awareRect.H -eq 600) -What 'a dpi-aware process captures the window rectangle unconverted'

$script:QQ_DPI_AWARE = 'unaware'
$unawarePoint = Convert-QQPointToPhysical -X 1500 -Y 900 -Scale 1.5
Assert-True -Condition ($unawarePoint.X -eq 1000 -and $unawarePoint.Y -eq 600) -What 'a dpi-unaware process still converts the point to logical pixels'
$unawareRect = Convert-QQWindowRectToPhysical -Left 100 -Top 200 -Right 1100 -Bottom 800 -Scale 1.5
Assert-True -Condition ($unawareRect.X -eq 150 -and $unawareRect.W -eq 1500 -and $unawareRect.H -eq 900) -What 'a dpi-unaware process still scales the window rectangle for capture'

$script:QQ_DPI_AWARE = 'unknown'
$unknownPoint = Convert-QQPointToPhysical -X 1500 -Y 900 -Scale 1.5
Assert-True -Condition ($unknownPoint.X -eq 1000) -What 'an unreadable awareness level takes the converting branch, never the aware one'
$script:QQ_DPI_AWARE = $savedAwareness

Write-Host ''
Write-Host '[rate limit]' -ForegroundColor Cyan

# The cooldown is recovered from evidence\audit.jsonl, so what counts as "the
# previous send" is a contract with the audit writer. Only a record that says
# stage=result AND sent=true may start a cooldown.
function Write-TestAuditLine {
  param([string]$Path, [string]$Line)
  [System.IO.File]::AppendAllText($Path, $Line + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

$auditFile = [System.IO.Path]::GetTempFileName()
try {
  $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()

  Write-TestAuditLine -Path $auditFile -Line ('{"stage":"attempt","sent":true,"unix":' + $now + '}')
  $attemptOnly = Assert-QQRateLimit -AuditPath $auditFile -MinIntervalMs 60000
  Assert-True -Condition (-not [bool]$attemptOnly.Enforced) -What 'an attempt record (written before typing) does not start the cooldown'

  [System.IO.File]::WriteAllText($auditFile, ('{"stage":"result","sent":false,"unix":' + $now + '}' + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $unconfirmed = Assert-QQRateLimit -AuditPath $auditFile -MinIntervalMs 60000
  Assert-True -Condition (-not [bool]$unconfirmed.Enforced) -What 'a result record with sent=false does not start the cooldown'

  [System.IO.File]::WriteAllText($auditFile, ('{"stage":"result","sent":true,"unix":' + $now + '}' + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $limitCode = ''
  try { [void](Assert-QQRateLimit -AuditPath $auditFile -MinIntervalMs 60000) } catch { $limitCode = [string]$_.Exception.Data['QQCode'] }
  Assert-True -Condition ($limitCode -eq 'GUARD_RATE_LIMIT') -What 'a confirmed send inside the cooldown is refused with GUARD_RATE_LIMIT'

  # Culture independence: the cooldown used to be formatted with -UFormat %s and
  # parsed with [double]::Parse, which mis-reads the decimal separator on a host
  # whose culture uses a comma.
  $savedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
  try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
    $cultureCode = ''
    try { [void](Assert-QQRateLimit -AuditPath $auditFile -MinIntervalMs 60000) } catch { $cultureCode = [string]$_.Exception.Data['QQCode'] }
    Assert-True -Condition ($cultureCode -eq 'GUARD_RATE_LIMIT') -What 'the cooldown still fires on a comma-decimal culture'
  } finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture
  }

  $stale = $now - 3600
  [System.IO.File]::WriteAllText($auditFile, ('{"stage":"result","sent":true,"unix":' + $stale + '}' + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $staleResult = Assert-QQRateLimit -AuditPath $auditFile -MinIntervalMs 60000
  Assert-True -Condition ([bool]$staleResult.Enforced -and [int]$staleResult.ElapsedMs -ge 3500000) -What 'a send older than the cooldown passes and reports the elapsed time'

  [System.IO.File]::WriteAllText($auditFile, ('{"stage":"result","sent":true,"unix":"1758180000.5"}' + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $badUnix = Assert-QQRateLimit -AuditPath $auditFile -MinIntervalMs 60000
  Assert-True -Condition (-not [bool]$badUnix.Enforced) -What 'a record whose unix field is not an integer is skipped, not mis-parsed'

  # A bad record must not stop the search: the newest line is broken, an older
  # confirmed send is still inside the cooldown and must still be found.
  $twoLines = ('{"stage":"result","sent":true,"unix":' + $now + '}' + "`n" + '{"stage":"result","sent":true,"unix":"broken"}' + "`n")
  [System.IO.File]::WriteAllText($auditFile, $twoLines, (New-Object System.Text.UTF8Encoding($false)))
  $skipCode = ''
  try { [void](Assert-QQRateLimit -AuditPath $auditFile -MinIntervalMs 60000) } catch { $skipCode = [string]$_.Exception.Data['QQCode'] }
  Assert-True -Condition ($skipCode -eq 'GUARD_RATE_LIMIT') -What 'a broken audit line is skipped and the search continues to an older record'
} finally {
  Remove-Item -LiteralPath $auditFile -Force -ErrorAction SilentlyContinue
}

$guardText = [System.IO.File]::ReadAllText((Join-Path $root 'lib\qq-guards.ps1'), [System.Text.Encoding]::UTF8)
$sendText = [System.IO.File]::ReadAllText((Join-Path $root 'commands\send-message.ps1'), [System.Text.Encoding]::UTF8)
Assert-True -Condition ($guardText -notmatch 'Get-Date -UFormat') -What 'the cooldown no longer formats time through -UFormat %s'
Assert-True -Condition ($guardText -match 'ToUnixTimeSeconds') -What 'the cooldown reads the current time as int64 unix seconds'
Assert-True -Condition ($sendText -notmatch 'Get-Date -UFormat' -and $sendText -match 'ToUnixTimeSeconds') -What 'the audit writer stores unix seconds as int64, matching the reader'

Write-Host ''
Write-Host '[timeout budget]' -ForegroundColor Cyan

$defaultTimeouts = Get-QQTimeouts -Config $null
Assert-True -Condition ([int]$defaultTimeouts.switchHeaderMs -eq 10000) -What 'the default switch wait is the documented 10 s'
$cappedTimeouts = Get-QQEffectiveTimeouts -Timeouts $defaultTimeouts -TimeoutSec 5
Assert-True -Condition ([int]$cappedTimeouts.switchHeaderMs -eq 5000 -and [int]$cappedTimeouts.searchResultsMs -eq 5000) -What '-TimeoutSec caps each stage wait that would outlast it'
Assert-True -Condition ([int]$cappedTimeouts.afterFocusMs -eq 600) -What 'a stage wait already under the budget is left alone'
Assert-True -Condition ([int]$defaultTimeouts.switchHeaderMs -eq 10000) -What 'the cap is applied to a copy, never to the shared table'
$uncappedTimeouts = Get-QQEffectiveTimeouts -Timeouts $defaultTimeouts -TimeoutSec 0
Assert-True -Condition ([int]$uncappedTimeouts.switchHeaderMs -eq 10000) -What 'a budget of 0 means no ceiling'

Write-Host ''
Write-Host '[configuration resolution]' -ForegroundColor Cyan

# Priority for the width floor is config.json (only when the file actually carries
# the key) > selectors.psd1 > the built-in 400. Get-QQConfig always answers
# MinWindowWidth, so without provenance tracking the built-in default would shadow
# an edited selectors.psd1.
$cfgRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('qq-cfg-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $cfgRoot)
try {
  [System.IO.File]::WriteAllText((Join-Path $cfgRoot 'config.json'), '{"evidence":{"dir":"evidence"}}', (New-Object System.Text.UTF8Encoding($false)))
  $minimalCfg = Get-QQConfig -Root $cfgRoot
  Assert-True -Condition ([int]$minimalCfg.MinWindowWidth -eq 400) -What 'the built-in width floor is 400, not 150'
  Assert-True -Condition (-not (@($minimalCfg.FileKeys) -contains 'MinWindowWidth')) -What 'a width floor that the file does not carry is not reported as explicit'
  Assert-True -Condition ([int](Get-QQSelector)['Window']['MinWidth'] -eq 400) -What 'selectors.psd1 agrees with the built-in width floor'

  [System.IO.File]::WriteAllText((Join-Path $cfgRoot 'config.json'), '{"instances":{"minWindowWidth":250},"a11y":{"minNodes":500}}', (New-Object System.Text.UTF8Encoding($false)))
  $explicitCfg = Get-QQConfig -Root $cfgRoot
  Assert-True -Condition (@($explicitCfg.FileKeys) -contains 'MinWindowWidth') -What 'an explicit instances.minWindowWidth is reported as explicit'
  Assert-True -Condition ([int]$explicitCfg.MinWindowWidth -eq 250) -What 'an explicit width floor is read from the file'

  Assert-True -Condition ((Get-QQA11yMinNodes -Config $explicitCfg) -eq 500) -What 'a11y.minNodes is resolved through the shared helper'
  Assert-True -Condition ((Get-QQA11yMinNodes -Config $null) -eq 100) -What 'the accessibility threshold falls back to 100'
  Assert-True -Condition (-not (Test-QQA11yActive -NodeCount 100 -MinNodes 100)) -What 'exactly the threshold is not yet activated, matching doctor'
  Assert-True -Condition (Test-QQA11yActive -NodeCount 101 -MinNodes 100) -What 'above the threshold is activated'
} finally {
  Remove-Item -LiteralPath $cfgRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# The instance preamble used to refuse at 10 nodes while doctor called an instance
# ready at 100: the same number now decides both.
$commonText = [System.IO.File]::ReadAllText((Join-Path $root 'commands\_common.ps1'), [System.Text.Encoding]::UTF8)
$doctorText = [System.IO.File]::ReadAllText((Join-Path $root 'commands\doctor.ps1'), [System.Text.Encoding]::UTF8)
Assert-True -Condition ($commonText -notmatch 'Count -le 10') -What 'no hardcoded 10-node threshold is left in the instance preamble'
Assert-True -Condition ($commonText -match 'Test-QQA11yActive' -and $doctorText -match 'Test-QQA11yActive') -What 'the preamble and doctor share one accessibility threshold'

Write-Host ''
Write-Host '[dead config keys]' -ForegroundColor Cyan

# A key that config.json documents but nothing consumes is a silent no-op: the
# operator sets it, nothing changes, and no output says so.
$coreText = [System.IO.File]::ReadAllText((Join-Path $root 'lib\qq-core.ps1'), [System.Text.Encoding]::UTF8)
$openChatText = [System.IO.File]::ReadAllText((Join-Path $root 'commands\open-chat.ps1'), [System.Text.Encoding]::UTF8)
$dispatcherText = [System.IO.File]::ReadAllText((Join-Path $root 'qq-uia.ps1'), [System.Text.Encoding]::UTF8)
Assert-True -Condition ($coreText -match 'KeepAlias' -and $openChatText -match 'KeepAlias' -and $sendText -match 'KeepAlias') -What 'evidence.keepLatestAliases reaches the screenshot writer from both call sites'
Assert-True -Condition ($doctorText -match 'NodeCountTimeoutMs' -and $doctorText -match 'Wait-QQNodeCount') -What 'a11y.nodeCountTimeoutMs bounds doctor node-count wait'
Assert-True -Condition ($coreText -match 'Wait-QQNodeCount') -What 'the node-count wait is implemented in the core library'
Assert-True -Condition ($dispatcherText -match 'TimeoutSec' -and $openChatText -match 'Get-QQEffectiveTimeouts') -What '-TimeoutSec is resolved by the dispatcher and applied by the commands'
foreach ($cmd in @('read-chat.ps1', 'search.ps1', 'open-chat.ps1', 'send-message.ps1')) {
  $text = [System.IO.File]::ReadAllText((Join-Path $root ('commands\{0}' -f $cmd)), [System.Text.Encoding]::UTF8)
  Assert-True -Condition ($text -match 'Get-QQEffectiveTimeouts') -What ("{0} applies the -TimeoutSec budget" -f $cmd)
}

Write-Host ''
Write-Host '[doctor config warnings]' -ForegroundColor Cyan

# A configuration that silently disables a guard must be reported, not obeyed in
# silence: with evidence.writeAudit false the send cooldown has no record to read.
# doctor is run in-process here, which also proves its read-only path survives a
# machine with no QQ at all.
. (Join-Path $root 'commands\doctor.ps1')

$warnRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('qq-doctor-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $warnRoot)
try {
  $badJson = '{"evidence":{"writeAudit":false},"guards":{"minSendIntervalMs":60000},"typing":{"engine":"sendkeys"}}'
  [System.IO.File]::WriteAllText((Join-Path $warnRoot 'config.json'), $badJson, (New-Object System.Text.UTF8Encoding($false)))
  $badCfg = Get-QQConfig -Root $warnRoot
  $badReport = Invoke-QQCommand -Context @{ Config = $badCfg; Root = $warnRoot; EvidenceDir = (Join-Path $warnRoot 'evidence') }
  $badWarnings = @($badReport.Data.configWarnings)
  Assert-True -Condition ($badWarnings.Count -eq 2) -What 'a disabled audit log beside a send cooldown is reported, and so is an unimplemented typing engine'
  Assert-True -Condition ((($badWarnings -join ' ') -match 'writeAudit')) -What 'the warning names the key that disables the cooldown'
  Assert-True -Condition ((($badWarnings -join ' ') -match 'sendinput')) -What 'the warning names the only implemented typing engine'
  Assert-True -Condition (([string]$badReport.Data.hint) -match 'writeAudit') -What 'the configuration warning is prepended to the human hint as well'
  Assert-True -Condition ($badReport.Data.instanceCount -eq @($badReport.Data.instances).Count -and $null -ne $badReport.Data.ready) -What 'doctor still reports a coherent envelope whatever the machine state (QQ may or may not be running here)'

  $goodJson = '{"evidence":{"writeAudit":true},"guards":{"minSendIntervalMs":60000},"typing":{"engine":"sendinput"}}'
  [System.IO.File]::WriteAllText((Join-Path $warnRoot 'config.json'), $goodJson, (New-Object System.Text.UTF8Encoding($false)))
  $goodCfg = Get-QQConfig -Root $warnRoot
  $goodReport = Invoke-QQCommand -Context @{ Config = $goodCfg; Root = $warnRoot; EvidenceDir = (Join-Path $warnRoot 'evidence') }
  Assert-True -Condition (@($goodReport.Data.configWarnings).Count -eq 0) -What 'a coherent configuration produces no warning'
} finally {
  Remove-Item -LiteralPath $warnRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '[json normalization]' -ForegroundColor Cyan

# The envelope must always be produced: a cyclic payload used to recurse until the
# stack overflowed, which kills the process before any JSON reaches stdout.
$cycle = [ordered]@{ tag = 'root' }
$cycle['loop'] = $cycle
$cycleTerminated = $false
try { $null = ConvertTo-QQJsonSafe -Value $cycle; $cycleTerminated = $true } catch { $cycleTerminated = $false }
Assert-True -Condition $cycleTerminated -What 'a self-referencing payload normalizes instead of recursing forever'

$deepPayload = [ordered]@{ leaf = 'bottom' }
for ($i = 0; $i -lt 20; $i++) { $deepPayload = [ordered]@{ child = $deepPayload } }
$normalized = ConvertTo-QQJsonSafe -Value $deepPayload
$walk = 0
$cursor = $normalized
while ($null -ne $cursor -and $walk -lt 40) { $cursor = $cursor['child']; $walk++ }
Assert-True -Condition ($null -eq $cursor -and $walk -le 15) -What 'a payload deeper than the limit is cut to null instead of overflowing the stack'
Assert-True -Condition ($null -ne ($normalized | ConvertTo-Json -Depth 6 -Compress)) -What 'the truncated payload still serializes'

Write-Host ''
Write-Host '[selector registry]' -ForegroundColor Cyan

$sel = Get-QQSelector
Assert-True -Condition ($null -ne $sel) -What 'selectors.psd1 loads'
Assert-True -Condition ($sel.ContainsKey('MessageKinds')) -What 'message-kind fingerprints are present'
$kinds = @($sel['MessageKinds'] | ForEach-Object { [string]$_['Kind'] })
Assert-True -Condition ($kinds -contains 'text') -What 'the text kind exists as the general fallback'
Assert-True -Condition ($kinds[-1] -eq 'text') -What 'text is the LAST fingerprint, so specific kinds win'
$entry = Get-QQSelectorEntry -Section 'Chat' -Name 'Header'
Assert-True -Condition ($entry.Class -eq 'chat-header__contact-name') -What 'the chat header selector is the documented class'
Assert-True -Condition ($entry.Required) -What 'the chat header selector is marked required'

$unknownThrew = $false
try { [void](Get-QQSelectorEntry -Section 'Chat' -Name 'NoSuchEntry') } catch { $unknownThrew = $true }
Assert-True -Condition $unknownThrew -What 'an unknown selector throws instead of returning null'

Write-Host ''
Write-Host '[account registry]' -ForegroundColor Cyan

. (Join-Path $root 'commands\_common.ps1')

# The alias table is config-side knowledge, the nickname is what QQ reports, and
# neither may be trusted alone. These assertions cover the config normalization and
# the resolution rules; the live binding itself needs a signed-in instance.
$accountRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('qq-accounts-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $accountRoot)
$masterNick = [string]([char]0x4E3B + [char]0x4EBA)
try {
  $accountJson = @'
{
  "defaultAccount": "master",
  "accounts": [
    { "alias": "master", "nick": "\u4E3B\u4EBA", "qqId": "10001", "note": "primary" },
    { "alias": "work", "nick": "worker", "qqId": "10002", "enabled": false },
    { "alias": "MASTER", "nick": "duplicate", "qqId": "10003" },
    { "nick": "no-alias", "qqId": "10004" }
  ]
}
'@
  [System.IO.File]::WriteAllText((Join-Path $accountRoot 'config.json'), $accountJson, (New-Object System.Text.UTF8Encoding($false)))
  $acctConfig = Get-QQConfig -Root $accountRoot
  Assert-True -Condition ([bool]$acctConfig.Valid) -What 'a config carrying accounts[] parses'

  $accountList = @(Get-QQConfigAccounts -Config $acctConfig)
  Assert-True -Condition ($accountList.Count -eq 2) -What 'an entry without an alias and a duplicate alias are both dropped'

  $master = $accountList[0]
  Assert-True -Condition ([string]$master.Alias -eq 'master' -and [string]$master.Nick -eq $masterNick -and [string]$master.QqId -eq '10001') -What 'an account entry is normalized to Alias/Nick/QqId'
  Assert-True -Condition ([bool]$master.Enabled -and -not [bool]$accountList[1].Enabled) -What 'enabled defaults to true and an explicit false is honored'
  Assert-True -Condition ([string]$acctConfig.DefaultAccount -eq 'master') -What 'defaultAccount is read into the config'
  Assert-True -Condition (([string]$acctConfig.AccountsWarning) -match 'defined more than once') -What 'a duplicate alias is reported in AccountsWarning'
  Assert-True -Condition (@(Get-QQConfigAccounts -Config $acctConfig -EnabledOnly).Count -eq 1) -What 'a disabled account is excluded from enabled-only resolution'

  Assert-True -Condition (Test-QQAccountEntryMatches -Entry $master -Value 'MASTER') -What 'an alias matches case-insensitively'
  Assert-True -Condition (Test-QQAccountEntryMatches -Entry $master -Value $masterNick) -What 'a nickname matches exactly'
  Assert-True -Condition (Test-QQAccountEntryMatches -Entry $master -Value '10001') -What 'a QQ id matches'
  Assert-True -Condition (-not (Test-QQAccountEntryMatches -Entry $master -Value 'nobody')) -What 'an unrelated name matches no field'

  $resolveCode = ''
  $resolveDetails = $null
  try { [void](Resolve-QQAccountPid -Account 'master' -Config $acctConfig) } catch {
    $resolveCode = [string]$_.Exception.Data['QQCode']
    $resolveDetails = $_.Exception.Data['QQDetails']
  }
  Assert-True -Condition ($resolveCode -eq 'NOT_FOUND') -What 'a configured account that is not signed in is NOT_FOUND'
  Assert-True -Condition (@($resolveDetails.availableAliases) -contains 'master') -What 'that NOT_FOUND lists the configured aliases'

  $fallbackCode = ''
  try { [void](Resolve-QQAccountPid -Account 'unconfigured-nick' -Config $acctConfig) } catch { $fallbackCode = [string]$_.Exception.Data['QQCode'] }
  Assert-True -Condition ($fallbackCode -eq 'NOT_FOUND') -What 'an unconfigured name falls through to live-nickname matching rather than BAD_ARGS'

  $defaultCode = ''
  try { [void](Get-QQInstanceContext -Config $acctConfig) } catch { $defaultCode = [string]$_.Exception.Data['QQCode'] }
  Assert-True -Condition ($defaultCode -eq 'NOT_FOUND') -What 'defaultAccount is used when neither -SenderPid nor -Account is given'

  $noSelectorCode = ''
  try { [void](Get-QQInstanceContext -Config $null) } catch { $noSelectorCode = [string]$_.Exception.Data['QQCode'] }
  Assert-True -Condition ($noSelectorCode -eq 'BAD_ARGS') -What 'no -SenderPid, no -Account and no defaultAccount is BAD_ARGS'
} finally {
  Remove-Item -LiteralPath $accountRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '[search rows and results]' -ForegroundColor Cyan

# Get-QQSearchResultRecord and Select-QQSearchRow read AutomationElement.Current.Name
# and nothing else, so a plain object of that shape exercises them without UIA.
function New-TestSearchRow {
  param([AllowEmptyString()][string]$Name = '')
  return [pscustomobject]@{ Current = [pscustomobject]@{ Name = $Name } }
}

$contactRow = Get-QQSearchResultRecord -Element (New-TestSearchRow -Name 'alice (10001) via group') -Index 0
Assert-True -Condition ($contactRow.kind -eq 'contact' -and $contactRow.name -eq 'alice' -and $contactRow.qqId -eq '10001') -What 'a contact row parses into kind/name/QQ id'

$groupRow = Get-QQSearchResultRecord -Element (New-TestSearchRow -Name 'study group (30 members) contains 10001') -Index 1
Assert-True -Condition ($groupRow.kind -eq 'group' -and $groupRow.name -eq 'study group' -and $groupRow.detail -eq '30 members contains 10001') -What 'a group row parses into kind/name/member count'

$historyUnit = Get-QQUiText -Key 'historyUnit'
Assert-True -Condition ($historyUnit.Length -eq 7) -What 'the localized chat-history unit word is assembled from 7 characters'
$historyRow = Get-QQSearchResultRecord -Element (New-TestSearchRow -Name ('alice 5 ' + $historyUnit)) -Index 2
Assert-True -Condition ($historyRow.kind -eq 'history' -and $historyRow.name -eq 'alice' -and $historyRow.detail -eq ('5 ' + $historyUnit)) -What 'a chat-history row is recognised through its records unit word'

# The old history regex accepted any "<name> <number>" tail, which made ordinary
# rows look like chat history.
$numberOnly = Get-QQSearchResultRecord -Element (New-TestSearchRow -Name 'alice 12') -Index 3
Assert-True -Condition ($numberOnly.kind -eq 'unknown') -What 'a name followed by a number is not chat history'
$numberAndWord = Get-QQSearchResultRecord -Element (New-TestSearchRow -Name 'alice 12 contacts') -Index 4
Assert-True -Condition ($numberAndWord.kind -eq 'unknown') -What 'a name followed by a number and a word is still not chat history'
$emptyRow = Get-QQSearchResultRecord -Element (New-TestSearchRow -Name '') -Index 5
Assert-True -Condition ($emptyRow.kind -eq 'unknown' -and $emptyRow.name -eq '') -What 'an empty Name is reported as an unknown row, not dropped'

$umbrellaName = (Get-QQUiText -Key 'comprehensiveSearch') + ' everything'
Assert-True -Condition (Test-QQComprehensiveSearchRow -Element (New-TestSearchRow -Name $umbrellaName)) -What 'the umbrella entry is recognised by its localized Name prefix'
Assert-True -Condition (-not (Test-QQComprehensiveSearchRow -Element (New-TestSearchRow -Name 'alice (10001)'))) -What 'an ordinary row is not the umbrella entry'

# Dedupe and ordering, on synthetic records so no UIA is involved.
$synthetic = @(
  @{ index = 0; kind = 'history'; name = 'alice'; detail = '5'; qqId = ''; raw = 'alice 5' },
  @{ index = 1; kind = 'contact'; name = 'bob'; detail = '10002'; qqId = '10002'; raw = 'bob (10002)' },
  @{ index = 2; kind = 'contact'; name = 'bob'; detail = '10002'; qqId = '10002'; raw = 'bob (10002)' },
  @{ index = 3; kind = 'group'; name = 'group x'; detail = '30 members'; qqId = ''; raw = 'group x (30 members)' },
  @{ index = 4; kind = 'unknown'; name = ''; detail = ''; qqId = ''; raw = '' },
  @{ index = 5; kind = 'unknown'; name = ''; detail = ''; qqId = ''; raw = '' }
)
$merged = Merge-QQSearchResultRecords -Records $synthetic -Limit 0
Assert-True -Condition ([int]$merged.DuplicatesRemoved -eq 1) -What 'a repeated kind+name+QQ-id record is reported as removed'
Assert-True -Condition (@($merged.Results).Count -eq 5) -What 'records that share the empty key are never merged'
$orderedKinds = @($merged.Results | ForEach-Object { [string]$_['kind'] })
Assert-True -Condition (($orderedKinds -join ',') -eq 'contact,group,history,unknown,unknown') -What 'results are ordered contact, group, history and keep render order inside a kind'
$firstKept = @($merged.Results)[0]
Assert-True -Condition ([int]$firstKept['index'] -eq 1) -What 'a reordered record keeps its original render position'
$limited = Merge-QQSearchResultRecords -Records $synthetic -Limit 2
Assert-True -Condition (@($limited.Results).Count -eq 2 -and [int]$limited.DuplicatesRemoved -eq 1) -What 'the limit is applied after dedupe, so it counts distinct results'

# matchQuality: three grades, strongest first.
$byId = Select-QQSearchRow -Rows @((New-TestSearchRow -Name 'alice (10001)'), (New-TestSearchRow -Name 'bob (10002)')) -TargetId '10002' -ExpectNick 'alice'
Assert-True -Condition ([string]$byId.MatchQuality -eq 'qqid' -and [bool]$byId.MatchedById) -What 'a row carrying (TargetId) is matched by QQ id'
$byNick = Select-QQSearchRow -Rows @((New-TestSearchRow -Name 'zzz (10009)'), (New-TestSearchRow -Name 'alice (10001)')) -ExpectNick 'alice'
Assert-True -Condition ([string]$byNick.MatchQuality -eq 'nick' -and [string]$byNick.Label -eq 'alice (10001)') -What 'a row whose parsed name equals -ExpectNick is matched by nickname'
$byNickCase = Select-QQSearchRow -Rows @((New-TestSearchRow -Name 'ALICE (10001)')) -ExpectNick 'alice'
Assert-True -Condition ([string]$byNickCase.MatchQuality -eq 'first-row') -What 'the nickname grade is exact, never case-insensitive'
$byPosition = Select-QQSearchRow -Rows @((New-TestSearchRow -Name 'zzz (10009)'), (New-TestSearchRow -Name 'alice (10001)'))
Assert-True -Condition ([string]$byPosition.MatchQuality -eq 'first-row') -What 'with no target and no expected name the first row is used and reported as position only'
Assert-True -Condition (($byPosition.Notes -join ' ') -match 'by position') -What 'the position fallback is reported in Notes'
$noRows = Select-QQSearchRow -Rows @() -TargetId '10002' -ExpectNick 'alice'
Assert-True -Condition ($null -eq $noRows.Element -and [string]$noRows.MatchQuality -eq '' -and -not [bool]$noRows.MatchedById) -What 'an empty result set reports no element and no match grade'

Write-Host ''
Write-Host '[search source contract]' -ForegroundColor Cyan

$searchText = [System.IO.File]::ReadAllText((Join-Path $root 'commands\search.ps1'), [System.Text.Encoding]::UTF8)
$openText = [System.IO.File]::ReadAllText((Join-Path $root 'commands\_open.ps1'), [System.Text.Encoding]::UTF8)
$searchSel = $sel['Search']

Assert-True -Condition ($commonText -notmatch 'SetValue\(\$Keyword\)') -What 'the value-pattern keyword fallback is gone from the search helper'
Assert-True -Condition ($commonText -match 'lastChangeAt') -What 'the result wait restarts its quiet period when the row count changes'
Assert-True -Condition ($commonText -match 'SearchValueNote') -What 'a failed search-box read-back is reported through searchValueNote'
Assert-True -Condition (@([regex]::Matches($searchText, 'Set-QQSearchKeyword')).Count -eq 1) -What '-Activate 1 no longer retypes the keyword into a second search box'
Assert-True -Condition ($searchText -match 'Wait-QQSearchPanel') -What 'the Activate path waits for the comprehensive search panel'
Assert-True -Condition ($searchText -match 'Merge-QQSearchResultRecords') -What 'search reports deduplicated, ordered results'
Assert-True -Condition ($searchText -match 'keepOpen' -and $searchText -match 'Close-QQSearchSurface') -What 'search dismisses the dropdown unless -KeepOpen was passed'
Assert-True -Condition ($openText -match 'Close-QQSearchSurface' -and $openText -match 'MatchQuality') -What 'the search fallback open path dismisses the overlay and reports the match grade'
Assert-True -Condition ($openText -match 'Set-QQSearchKeyword') -What 'the open path still uses the shared search helper'

Assert-True -Condition (-not $searchSel.ContainsKey('Comprehensive')) -What 'the dead Search.Comprehensive selector is gone'
Assert-True -Condition ([string]$searchSel['ResultItem']['Class'] -eq '^search-result-item$') -What 'Search.ResultItem is anchored'
Assert-True -Condition (-not ('global search-result-item' -match [string]$searchSel['ResultItem']['Class'])) -What 'the anchored ResultItem regex no longer collects the umbrella row class'
Assert-True -Condition ('search-result-item' -match [string]$searchSel['ResultItem']['Class']) -What 'the anchored ResultItem regex still matches a plain result row class'
Assert-True -Condition ($searchSel.ContainsKey('UmbrellaRow') -and [string]$searchSel['UmbrellaRow']['Class'] -eq 'global search-result-item') -What 'the umbrella row has its own live selector, which the anchored ResultItem cannot collect'
Assert-True -Condition ('global search-result-item' -match [string]$searchSel['UmbrellaRow']['Class']) -What 'the umbrella selector matches the observed umbrella row class'
Assert-True -Condition (-not [bool]$searchSel['UmbrellaRow']['Required']) -What 'a build rendering real inline hits still passes without the umbrella row'
Assert-True -Condition ($commonText -match "-Name 'UmbrellaRow'") -What 'the search helper reads the umbrella row through its own selector'
Assert-True -Condition ($searchText -match 'AllRows' -and $searchText -match 'Test-QQComprehensiveSearchRow') -What 'the Activate path finds the umbrella row by name, not by position'
Assert-True -Condition ($searchSel.ContainsKey('Panel') -and $searchSel.ContainsKey('PanelItem')) -What 'the comprehensive-search panel selectors exist'
Assert-True -Condition (-not [bool]$searchSel['Panel']['Stable'] -and -not [bool]$searchSel['Panel']['Required'] -and -not [bool]$searchSel['PanelItem']['Stable'] -and -not [bool]$searchSel['PanelItem']['Required']) -What 'the unverified panel selectors can never gate a task'
Assert-True -Condition (([string]$searchSel['Panel']['Note'] -match 'unverified') -and ([string]$searchSel['PanelItem']['Note'] -match 'unverified')) -What 'the panel selectors carry a Note saying they are unverified'

Write-Host ''
Write-Host '[command surface and shipped config]' -ForegroundColor Cyan

# The registry IS the command surface: an accounts command missing from it is
# unreachable however complete commands/accounts.ps1 is, and a parameter that never
# made it into the registry is rejected by the dispatcher before a window is read.
Assert-True -Condition ($null -ne $cmdRegistry -and $cmdRegistry.Contains('accounts')) -What 'the dispatcher registers an accounts command'
$accountsFile = ''
if ($null -ne $cmdRegistry -and $cmdRegistry.Contains('accounts')) { $accountsFile = [string]$cmdRegistry['accounts'].File }
Assert-True -Condition ($accountsFile -eq 'accounts.ps1' -and (Test-Path -LiteralPath (Join-Path $root 'commands\accounts.ps1'))) -What 'accounts is served by commands/accounts.ps1, which ships'
Assert-True -Condition ($null -ne $cmdRegistry -and $cmdRegistry.Contains('accounts') -and [string]$cmdRegistry['accounts'].Level -eq 'L0' -and @($cmdRegistry['accounts'].Optional) -contains 'Account' -and @($cmdRegistry['accounts'].Params) -notcontains 'SenderPid') -What 'accounts is L0, takes -Account and claims no instance'

# The report's shape is its contract with an agent choosing -Account: the four
# status values are the whole answer, and unbound is how an operator learns which
# instances still need an accounts[] entry.
$accountText = [System.IO.File]::ReadAllText((Join-Path $root 'commands\accounts.ps1'), [System.Text.Encoding]::UTF8)
Assert-True -Condition (($accountText -match 'unbound') -and ($accountText -match 'defaultAccount') -and ($accountText -match 'accountsWarning')) -What 'the accounts payload declares unbound, defaultAccount and accountsWarning'
$missingStatuses = @(foreach ($status in @('ok', 'ambiguous', 'not-running', 'disabled')) { if ($accountText -notmatch ("'" + $status + "'")) { $status } })
Assert-True -Condition (@($missingStatuses).Count -eq 0) -What 'all four binding statuses are produced by the accounts command'

# -SenderPid stopped being mandatory: every window command now also takes -Account,
# and the registry has to say so or the dispatcher rejects the parameter.
$windowCommands = @('list-sessions', 'read-chat', 'search', 'open-chat', 'send-message')
$withoutAccount = @(foreach ($name in $windowCommands) {
  if ($null -eq $cmdRegistry -or -not $cmdRegistry.Contains($name)) { $name; continue }
  if (@($cmdRegistry[$name].Optional) -notcontains 'Account') { $name; continue }
  if (@($cmdRegistry[$name].Params) -contains 'SenderPid') { $name }
})
Assert-True -Condition (@($withoutAccount).Count -eq 0) -What ('every window command takes -Account and requires no -SenderPid ({0} checked)' -f @($windowCommands).Count)

Assert-True -Condition ($null -ne $cmdRegistry -and $cmdRegistry.Contains('config-ui') -and [string]$cmdRegistry['config-ui'].Level -eq 'L0' -and @($cmdRegistry['config-ui'].Params).Count -eq 0 -and @($cmdRegistry['config-ui'].Optional).Count -eq 0) -What 'config-ui is L0 and selects no QQ instance'

# The shipped config.json must actually carry the two keys the account system
# reads: without them -Account resolves nothing and no default can apply.
$shippedConfig = Get-QQConfig -Root $root
Assert-True -Condition ([bool]$shippedConfig.Valid) -What 'the shipped config.json parses through Get-QQConfig'
Assert-True -Condition ($shippedConfig.ContainsKey('Accounts') -and $shippedConfig.ContainsKey('DefaultAccount')) -What 'the shipped config.json carries accounts[] and defaultAccount'
Assert-True -Condition (@(Get-QQConfigAccounts -Config $shippedConfig -EnabledOnly).Count -eq 0 -and [string]::IsNullOrEmpty([string]$shippedConfig.AccountsWarning)) -What 'the shipped accounts[] is empty and raises no warning'

Write-Host ''
if ($failed -eq 0) {
  Write-Host ("PASS: {0} assertions" -f $passed) -ForegroundColor Green
  exit 0
}
Write-Host ("FAIL: {0} passed, {1} failed" -f $passed, $failed) -ForegroundColor Red
exit 1
