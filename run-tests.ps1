# =============================================================================
# run-tests.ps1 - framework self-check. Run it after any edit.
# Authority: docs/FRAMEWORK-DESIGN.md 5 and 9
#
# Two test classes:
#   static  - no QQ needed and no UI action (nothing is clicked, focused, typed or
#             sent; a running QQ is only ever read). Source purity, registry and
#             selector integrity, archive isolation, guard behaviour on synthetic
#             input, and one live dispatcher invocation for each failure path plus
#             the read-only `accounts` report.
#   live    - needs a running, signed-in QQ with an activated accessibility tree.
#             Exercises the read-only commands and the send guard chain in -DryRun
#             mode. It NEVER sends a message.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-tests.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-tests.ps1 -StaticOnly
#
# ASCII-ONLY SOURCE.
# =============================================================================

[CmdletBinding()]
param(
  [switch]$StaticOnly,
  [int]$SenderPid = 0
)

$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object System.Collections.ArrayList

function Test-Case {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][scriptblock]$Body
  )
  try {
    $result = & $Body
    if ($result -eq $false) {
      $script:Failed++
      [void]$script:Failures.Add($Name)
      Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red
    } else {
      $script:Passed++
      Write-Host ("  ok    {0}" -f $Name) -ForegroundColor Green
    }
  } catch {
    $script:Failed++
    [void]$script:Failures.Add(("{0} ({1})" -f $Name, $_.Exception.Message))
    Write-Host ("  FAIL  {0}: {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
  }
}

function Invoke-Framework {
  <#
  .SYNOPSIS
    Runs the dispatcher in a child PowerShell and returns stdout, stderr, exit code.
  .PARAMETER Arguments
    Full argument tail, for example @('doctor').
  .OUTPUTS
    [hashtable] ExitCode, Stdout, Stderr, Json.
  #>
  param([string[]]$Arguments = @())
  $scriptPath = Join-Path $script:Root 'qq-uia.ps1'
  $outFile = [System.IO.Path]::GetTempFileName()
  $errFile = [System.IO.Path]::GetTempFileName()
  try {
    # Direct argument list, never a joined command line: CJK values (a nickname in
    # -ExpectNick) survive this path and are mangled by a shell round trip.
    $p = Start-Process -FilePath 'powershell' -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $Arguments) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $stdout = ''
    $stderr = ''
    try { $stdout = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8) } catch { $stdout = '' }
    try { $stderr = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8) } catch { $stderr = '' }
    $json = $null
    $trimmed = $stdout.Trim()
    if (-not [string]::IsNullOrEmpty($trimmed)) {
      try { $json = $trimmed | ConvertFrom-Json } catch { $json = $null }
    }
    return @{ ExitCode = [int]$p.ExitCode; Stdout = $stdout; Stderr = $stderr; Json = $json }
  } finally {
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}

function Get-ShippedFiles {
  <#
  .SYNOPSIS
    Lists every source file the framework ships.
  .OUTPUTS
    [object[]] FileInfo records.
  #>
  $files = @()
  foreach ($ext in @('*.ps1', '*.psd1', '*.json')) {
    $files += @(Get-ChildItem -Path $script:Root -Recurse -Filter $ext -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\archive\\' -and $_.FullName -notmatch '\\evidence\\' })
  }
  return @($files)
}

Write-Host ''
Write-Host ('QQ UIA framework self-check - {0}' -f $script:Root) -ForegroundColor Cyan
Write-Host ''

Write-Host '[static] source contract' -ForegroundColor Cyan

Test-Case -Name 'every shipped script is pure ASCII with no BOM' -Body {
  $bad = @()
  foreach ($f in (Get-ShippedFiles)) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $nonAscii = 0
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++ } }
    if ($nonAscii -gt 0) { $bad += ('{0} ({1} bytes)' -f $f.Name, $nonAscii) }
  }
  if ($bad.Count -gt 0) {
    Write-Host ('        non-ASCII in: {0}' -f ($bad -join ', ')) -ForegroundColor Yellow
    return $false
  }
  return $true
}

Test-Case -Name 'every shipped file ends with exactly one newline' -Body {
  $bad = @()
  foreach ($f in (Get-ShippedFiles)) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -eq 0) { $bad += $f.Name; continue }
    if ($bytes[$bytes.Length - 1] -ne 10) { $bad += $f.Name; continue }
    if ($bytes.Length -ge 2 -and $bytes[$bytes.Length - 2] -eq 10) { $bad += $f.Name }
  }
  if ($bad.Count -gt 0) { Write-Host ('        offenders: {0}' -f ($bad -join ', ')) -ForegroundColor Yellow; return $false }
  return $true
}

Test-Case -Name 'every script parses' -Body {
  $errs = $null
  foreach ($f in (Get-ChildItem -Path $script:Root -Recurse -Filter '*.ps1' -File | Where-Object { $_.FullName -notmatch '\\archive\\' })) {
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) { Write-Host ('        {0}: {1}' -f $f.Name, $errs[0].Message) -ForegroundColor Yellow; return $false }
  }
  return $true
}

Test-Case -Name 'the config UI resolves only controls the xaml declares' -Body {
  # ui/config-ui.xaml is the ONE file of the framework that is not ASCII (it is
  # UTF-8 with a BOM and carries the Chinese interface copy), and qq-config-ui.ps1
  # resolves every control by name. Two things can go wrong silently: the xaml stops
  # parsing, or one of the names the script looks up disappears from it. The second
  # is caught here by reading the script's own name list instead of trusting a
  # copied one.
  $uiScript = Join-Path $script:Root 'qq-config-ui.ps1'
  $xamlPath = Join-Path $script:Root 'ui\config-ui.xaml'
  if (-not (Test-Path -LiteralPath $uiScript)) { Write-Host '        qq-config-ui.ps1 is missing' -ForegroundColor Yellow; return $false }
  if (-not (Test-Path -LiteralPath $xamlPath)) { Write-Host '        ui/config-ui.xaml is missing' -ForegroundColor Yellow; return $false }

  $bytes = [System.IO.File]::ReadAllBytes($xamlPath)
  if ($bytes.Length -lt 4 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
    Write-Host '        ui/config-ui.xaml does not start with a UTF-8 BOM' -ForegroundColor Yellow
    return $false
  }
  try { [void](Add-Type -AssemblyName PresentationFramework -ErrorAction Stop) } catch {
    Write-Host ('        PresentationFramework could not be loaded: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    return $false
  }
  $xamlText = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
  $window = $null
  try {
    $window = [Windows.Markup.XamlReader]::Parse($xamlText)
  } catch {
    Write-Host ('        the xaml did not parse: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    return $false
  }

  $scriptText = [System.IO.File]::ReadAllText($uiScript, [System.Text.Encoding]::UTF8)
  $block = [regex]::Match($scriptText, '\$script:UiControlNames\s*=\s*@\((?<body>[^)]*)\)')
  if (-not $block.Success) {
    Write-Host '        the UI script no longer declares $script:UiControlNames' -ForegroundColor Yellow
    return $false
  }
  $names = @([regex]::Matches($block.Groups['body'].Value, "'([A-Za-z0-9_]+)'") | ForEach-Object { $_.Groups[1].Value })
  if (@($names).Count -lt 20) { Write-Host ('        only {0} control names were read' -f @($names).Count) -ForegroundColor Yellow; return $false }
  $missing = @()
  foreach ($name in $names) { if ($null -eq $window.FindName($name)) { $missing += $name } }
  if ($missing.Count -gt 0) {
    Write-Host ('        the xaml has no control named: {0}' -f ($missing -join ', ')) -ForegroundColor Yellow
    return $false
  }
  Write-Host ('        {0} named controls resolved from the xaml' -f @($names).Count) -ForegroundColor DarkGray
  return $true
}

Test-Case -Name 'the config UI defines no function the libraries already define' -Body {
  # qq-config-ui.ps1 dot-sources lib/*.ps1, so a helper whose name a library already
  # uses would be silently REPLACED by the library version: the first version of
  # this window defined Get-QQUiText, which lib/qq-core.ps1 already owns, and every
  # label came back as ''. Comparing the definition lists is what makes that class
  # of mistake visible in the self-check instead of in a UI screenshot.
  $rx = [regex]'(?m)^function\s+([A-Za-z0-9_-]+)'
  $libNames = @{}
  foreach ($file in @(Get-ChildItem -Path (Join-Path $script:Root 'lib') -Filter '*.ps1' -File)) {
    foreach ($m in $rx.Matches([System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8))) {
      $libNames[[string]$m.Groups[1].Value] = $file.Name
    }
  }
  Write-Host ('        {0} library functions on file' -f $libNames.Count) -ForegroundColor DarkGray
  $uiText = [System.IO.File]::ReadAllText((Join-Path $script:Root 'qq-config-ui.ps1'), [System.Text.Encoding]::UTF8)
  $clashes = @()
  foreach ($m in $rx.Matches($uiText)) {
    $name = [string]$m.Groups[1].Value
    if ($libNames.ContainsKey($name)) { $clashes += ('{0} (also in {1})' -f $name, $libNames[$name]) }
  }
  if ($clashes.Count -gt 0) {
    Write-Host ('        name clash: {0}' -f ($clashes -join ', ')) -ForegroundColor Yellow
    return $false
  }
  return $true
}

Test-Case -Name 'no command file writes to stdout' -Body {
  $offenders = @()
  foreach ($f in (Get-ChildItem -Path (Join-Path $script:Root 'commands') -Filter '*.ps1' -File)) {
    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    if ($text -match 'Write-Output|Write-Host|\[Console\]::Out') { $offenders += $f.Name }
  }
  if ($offenders.Count -gt 0) { Write-Host ('        offenders: {0}' -f ($offenders -join ', ')) -ForegroundColor Yellow; return $false }
  return $true
}

Test-Case -Name 'selectors load and every entry has Class and Type' -Body {
  $sel = Import-PowerShellDataFile -Path (Join-Path $script:Root 'lib\selectors.psd1')
  $skip = @('Version', 'TargetApp', 'VerifiedOn', 'Window', 'MessageKinds')
  $count = 0
  foreach ($section in @($sel.Keys)) {
    if ($skip -contains $section) { continue }
    foreach ($name in @($sel[$section].Keys)) {
      $entry = $sel[$section][$name]
      if (-not $entry.ContainsKey('Class') -or -not $entry.ContainsKey('Type')) {
        Write-Host ('        {0}.{1} lacks Class/Type' -f $section, $name) -ForegroundColor Yellow
        return $false
      }
      if ($entry.ContainsKey('Class') -and [string]$entry['Class'] -eq '' -and [string]$entry['Type'] -eq '') {
        Write-Host ('        {0}.{1} matches everything' -f $section, $name) -ForegroundColor Yellow
        return $false
      }
      $count++
    }
  }
  Write-Host ('        probed {0} selector entries' -f $count) -ForegroundColor DarkGray
  return ($count -gt 20)
}

Test-Case -Name 'the command registry matches the command files on disk' -Body {
  $src = [System.IO.File]::ReadAllText((Join-Path $script:Root 'qq-uia.ps1'), [System.Text.Encoding]::UTF8)
  $s1 = $src.IndexOf('function Get-QQCommandRegistry')
  $e1 = $src.IndexOf('function Write-QQUsage')
  if ($s1 -lt 0 -or $e1 -lt 0) { return $false }
  Invoke-Expression $src.Substring($s1, $e1 - $s1)
  $registry = Get-QQCommandRegistry
  foreach ($name in $registry.Keys) {
    $file = Join-Path $script:Root ('commands\{0}' -f $registry[$name].File)
    if (-not (Test-Path -LiteralPath $file)) {
      Write-Host ('        registry lists {0} but {1} is missing' -f $name, $registry[$name].File) -ForegroundColor Yellow
      return $false
    }
    $body = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
    if ($body -notmatch 'function Invoke-QQCommand') {
      Write-Host ('        {0} does not define Invoke-QQCommand' -f $registry[$name].File) -ForegroundColor Yellow
      return $false
    }
    if ($body -match '(?m)^\s*param\s*\(') {
      # A top-level param block would bind the dispatcher's own parameters.
      $topLevel = [regex]::IsMatch($body, '(?m)^param\s*\(')
      if ($topLevel) { Write-Host ('        {0} has a top-level param block' -f $registry[$name].File) -ForegroundColor Yellow; return $false }
    }
  }
  Write-Host ('        {0} commands registered' -f @($registry.Keys).Count) -ForegroundColor DarkGray
  return $true
}

Test-Case -Name '-TimeoutSec is registered wherever a command applies it' -Body {
  # The parameter is only real if all three halves agree: the registry accepts it,
  # the dispatcher resolves it into the context, and the command caps its stage
  # waits with it. A command that registers -TimeoutSec and ignores it would look
  # supported while silently running on the configured defaults.
  $src = [System.IO.File]::ReadAllText((Join-Path $script:Root 'qq-uia.ps1'), [System.Text.Encoding]::UTF8)
  $s1 = $src.IndexOf('function Get-QQCommandRegistry')
  $e1 = $src.IndexOf('function Write-QQUsage')
  if ($s1 -lt 0 -or $e1 -lt 0) { return $false }
  Invoke-Expression $src.Substring($s1, $e1 - $s1)
  $registry = Get-QQCommandRegistry
  $withBudget = @('read-chat', 'search', 'open-chat', 'send-message')
  foreach ($name in $withBudget) {
    if (-not $registry.Contains($name)) { Write-Host ('        {0} is not registered' -f $name) -ForegroundColor Yellow; return $false }
    if (@($registry[$name].Optional) -notcontains 'TimeoutSec') {
      Write-Host ('        {0} does not accept -TimeoutSec' -f $name) -ForegroundColor Yellow
      return $false
    }
  }
  if ($src -notmatch 'TimeoutSec\s*=\s*\[int\]\$timeoutSec') {
    Write-Host '        the dispatcher does not resolve -TimeoutSec into the context' -ForegroundColor Yellow
    return $false
  }
  foreach ($name in $withBudget) {
    $file = Join-Path $script:Root ('commands\{0}' -f $registry[$name].File)
    $body = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
    if ($body -notmatch 'Get-QQEffectiveTimeouts') {
      Write-Host ('        {0} accepts -TimeoutSec but never applies it' -f $registry[$name].File) -ForegroundColor Yellow
      return $false
    }
  }
  Write-Host ('        {0} commands apply the -TimeoutSec budget' -f @($withBudget).Count) -ForegroundColor DarkGray
  return $true
}

Test-Case -Name 'no registered command can reach archive/' -Body {
  $src = [System.IO.File]::ReadAllText((Join-Path $script:Root 'qq-uia.ps1'), [System.Text.Encoding]::UTF8)
  if ($src -match "(Join-Path|Get-ChildItem|Get-Content|\.)\s+[^\r\n]*\barchive\b") {
    Write-Host '        the dispatcher resolves a path under archive/' -ForegroundColor Yellow
    return $false
  }
  foreach ($f in (Get-ChildItem -Path $script:Root -Recurse -Filter '*.ps1' -File | Where-Object { $_.FullName -notmatch '\\archive\\' })) {
    if ($f.Name -eq 'run-tests.ps1') { continue }
    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    if ($text -match "(Join-Path|Get-ChildItem|Get-Content|\s\.\s)\s*[^\r\n]*\barchive\b") {
      Write-Host ('        {0} resolves a path under archive/' -f $f.Name) -ForegroundColor Yellow
      return $false
    }
  }
  return $true
}

Test-Case -Name 'archive/ is fully quarantined with a README' -Body {
  $archive = Join-Path $script:Root 'archive'
  if (-not (Test-Path -LiteralPath $archive)) { Write-Host '        archive/ does not exist yet' -ForegroundColor DarkGray; return $true }
  if (-not (Test-Path -LiteralPath (Join-Path $archive 'README.md'))) { Write-Host '        archive/README.md is missing' -ForegroundColor Yellow; return $false }
  $text = [System.IO.File]::ReadAllText((Join-Path $archive 'README.md'), [System.Text.Encoding]::UTF8)
  if ($text -notmatch 'DO NOT') { Write-Host '        archive/README.md does not warn against use' -ForegroundColor Yellow; return $false }
  return $true
}

Write-Host ''
Write-Host '[static] dispatcher behaviour (child process, no QQ interaction for failure paths)' -ForegroundColor Cyan

Test-Case -Name 'no command exits 2 with a JSON envelope on stdout and nothing else' -Body {
  $r = Invoke-Framework -Arguments @()
  if ($r.ExitCode -ne 2) { Write-Host ('        exit={0}' -f $r.ExitCode) -ForegroundColor Yellow; return $false }
  if ($null -eq $r.Json) { Write-Host '        stdout was not JSON' -ForegroundColor Yellow; return $false }
  if ($r.Json.ok -ne $false) { return $false }
  $lines = @($r.Stdout.Trim() -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
  if ($lines.Count -ne 1) { Write-Host ('        stdout had {0} lines' -f $lines.Count) -ForegroundColor Yellow; return $false }
  return ($r.Json.error.code -eq 'BAD_ARGS' -and $r.Json.error.exitCode -eq 2)
}

Test-Case -Name 'unknown command exits 2 and lists the known commands' -Body {
  $r = Invoke-Framework -Arguments @('definitely-not-a-command')
  if ($r.ExitCode -ne 2) { return $false }
  if ($null -eq $r.Json) { return $false }
  if ($r.Json.error.code -ne 'BAD_ARGS') { return $false }
  return (@($r.Json.error.details.known).Count -ge 7)
}

Test-Case -Name 'a mistyped parameter is rejected before any UIA access' -Body {
  $r = Invoke-Framework -Arguments @('identify', '-SenderPid', '1')
  if ($r.ExitCode -ne 2) { Write-Host ('        exit={0}' -f $r.ExitCode) -ForegroundColor Yellow; return $false }
  if ($null -eq $r.Json) { return $false }
  return ($r.Json.error.code -eq 'BAD_ARGS' -and ([string]$r.Json.error.message) -match 'unknown parameter')
}

Test-Case -Name 'a missing instance selector is rejected' -Body {
  # -SenderPid is not a dispatcher-level requirement any more: the instance may also
  # be named by -Account or by config.json defaultAccount. Supplying NONE of them is
  # what must fail, before any UIA access, and the message must name both ways out.
  $r = Invoke-Framework -Arguments @('list-sessions')
  if ($r.ExitCode -ne 2) { Write-Host ('        exit={0}' -f $r.ExitCode) -ForegroundColor Yellow; return $false }
  if ($null -eq $r.Json) { return $false }
  if ($r.Json.error.code -ne 'BAD_ARGS') { return $false }
  $message = [string]$r.Json.error.message
  if ($message -notmatch 'SenderPid') { Write-Host ('        message does not mention -SenderPid: {0}' -f $message) -ForegroundColor Yellow; return $false }
  return ($message -match 'Account')
}

Test-Case -Name 'accounts reports the configured accounts without claiming a pid' -Body {
  # Read-only L0: one window enumeration, no click, no focus, no typing. It must
  # answer with a valid envelope even when no QQ is running (an empty registry).
  $r = Invoke-Framework -Arguments @('accounts')
  if ($r.ExitCode -ne 0) { Write-Host ('        exit={0}' -f $r.ExitCode) -ForegroundColor Yellow; return $false }
  if ($null -eq $r.Json -or $r.Json.ok -ne $true) { return $false }
  $rows = @($r.Json.data.accounts)
  if ($rows.Count -ne [int]$r.Json.data.count) { Write-Host '        count does not match accounts[]' -ForegroundColor Yellow; return $false }
  foreach ($row in $rows) {
    if ([string]::IsNullOrEmpty([string]$row.alias)) { Write-Host '        an account was reported without an alias' -ForegroundColor Yellow; return $false }
    if (@('ok', 'not-running', 'ambiguous', 'disabled') -notcontains [string]$row.status) {
      Write-Host ('        unexpected status: {0}' -f $row.status) -ForegroundColor Yellow
      return $false
    }
  }
  if ($null -ne $r.Json.pid) { Write-Host '        accounts claimed a pid for a multi-instance report' -ForegroundColor Yellow; return $false }
  Write-Host ('        {0} configured account(s), {1} unbound instance(s)' -f @($rows).Count, @($r.Json.data.unbound).Count) -ForegroundColor DarkGray
  return $true
}

Test-Case -Name 'send-message with no payload is rejected, never defaulted' -Body {
  $r = Invoke-Framework -Arguments @('send-message', '-SenderPid', '1', '-ExpectNick', 'nobody')
  if ($r.ExitCode -ne 2) { Write-Host ('        exit={0}' -f $r.ExitCode) -ForegroundColor Yellow; return $false }
  if ($null -eq $r.Json) { return $false }
  return ($r.Json.error.code -eq 'BAD_ARGS' -and ([string]$r.Json.error.message) -match 'no message text supplied')
}

Test-Case -Name 'guard: a missing -ExpectNick is rejected' -Body {
  $r = Invoke-Framework -Arguments @('send-message', '-SenderPid', '1', '-MessageText', 'x')
  if ($r.ExitCode -ne 2) { return $false }
  if ($null -eq $r.Json) { return $false }
  return (([string]$r.Json.error.message) -match 'ExpectNick')
}

Test-Case -Name 'guard: an empty -MessageFile is rejected before any window lookup' -Body {
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    [System.IO.File]::WriteAllText($tmp, '   ', (New-Object System.Text.UTF8Encoding($false)))
    # A deliberately non-existent pid: the payload guard must fire first, so the
    # exit code is GUARD_ABORT rather than NOT_FOUND for the missing window.
    $r = Invoke-Framework -Arguments @('send-message', '-SenderPid', '999999', '-ExpectNick', 'nobody', '-MessageFile', $tmp)
    if ($r.ExitCode -ne 4) { Write-Host ('        exit={0} (expected 4)' -f $r.ExitCode) -ForegroundColor Yellow; return $false }
    if ($null -eq $r.Json) { return $false }
    # error.code is the FRAMEWORK-DESIGN 5.3 name (GUARD_ABORT); details.guard
    # carries the exact rule that fired.
    if ($r.Json.error.code -ne 'GUARD_ABORT' -or $r.Json.error.exitCode -ne 4) { return $false }
    return ([string]$r.Json.error.details.guard -eq 'GUARD_MESSAGE_EMPTY')
  } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

Test-Case -Name 'guard: a multi-line message is rejected before any window lookup' -Body {
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    [System.IO.File]::WriteAllText($tmp, "line one`nline two", (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Framework -Arguments @('send-message', '-SenderPid', '999999', '-ExpectNick', 'nobody', '-MessageFile', $tmp)
    if ($r.ExitCode -ne 4) { Write-Host ('        exit={0} (expected 4)' -f $r.ExitCode) -ForegroundColor Yellow; return $false }
    if ($null -eq $r.Json) { return $false }
    if ($r.Json.error.code -ne 'GUARD_ABORT') { return $false }
    return ([string]$r.Json.error.details.guard -eq 'GUARD_MESSAGE_MULTILINE')
  } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

Test-Case -Name 'guard: an unknown pid is reported as NOT_FOUND once the payload is valid' -Body {
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    [System.IO.File]::WriteAllText($tmp, 'valid payload', (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Framework -Arguments @('send-message', '-SenderPid', '999999', '-ExpectNick', 'nobody', '-MessageFile', $tmp)
    if ($r.ExitCode -ne 3) { Write-Host ('        exit={0} (expected 3)' -f $r.ExitCode) -ForegroundColor Yellow; return $false }
    if ($null -eq $r.Json) { return $false }
    return ($r.Json.error.code -eq 'NOT_FOUND')
  } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

Test-Case -Name 'guard helpers reject directly (no process needed)' -Body {
  . (Join-Path $script:Root 'lib\qq-json.ps1')
  . (Join-Path $script:Root 'lib\qq-core.ps1')
  . (Join-Path $script:Root 'lib\qq-guards.ps1')

  $checks = @()
  try { [void](Assert-QQHeaderMatches -Header 'a' -ExpectNick 'b'); $checks += 'header-match-did-not-throw' } catch { $checks += ([string]$_.Exception.Data['QQCode']) }
  try { [void](Assert-QQNotGroupChat -IsGroup $true -Header 'g'); $checks += 'group-did-not-throw' } catch { $checks += ([string]$_.Exception.Data['QQCode']) }
  try { [void](Assert-QQEditorPresent -EditorPresent $false -Header 'h'); $checks += 'editor-did-not-throw' } catch { $checks += ([string]$_.Exception.Data['QQCode']) }
  try { [void](Assert-QQEditorWritable -EditorText 'draft'); $checks += 'draft-did-not-throw' } catch { $checks += ([string]$_.Exception.Data['QQCode']) }
  try { [void](Assert-QQTextLanded -EditorText 'x' -Expected 'y'); $checks += 'readback-did-not-throw' } catch { $checks += ([string]$_.Exception.Data['QQCode']) }
  try { [void](Assert-QQAccountMatches -AccountNick 'a' -ExpectAccountNick 'b'); $checks += 'account-did-not-throw' } catch { $checks += ([string]$_.Exception.Data['QQCode']) }
  try { [void](Assert-QQExpectNickPresent -ExpectNick ''); $checks += 'expectnick-did-not-throw' } catch { $checks += ([string]$_.Exception.Data['QQCode']) }

  $expected = @('GUARD_HEADER_MISMATCH', 'GUARD_GROUP_REJECTED', 'GUARD_EDITOR_MISSING', 'GUARD_EDITOR_NOT_EMPTY', 'GUARD_READBACK_FAILED', 'GUARD_ACCOUNT_MISMATCH', 'GUARD_EXPECT_NICK_MISSING')
  $i = 0
  foreach ($e in $expected) {
    if ($checks[$i] -ne $e) { Write-Host ('        expected {0}, got {1}' -f $e, $checks[$i]) -ForegroundColor Yellow; return $false }
    $i++
  }
  # Every guard code must map onto GUARD_ABORT (exit 4).
  foreach ($code in $expected) {
    if ((Resolve-QQExitCodeName -Code $code) -ne 'GUARD_ABORT') { Write-Host ('        {0} does not map to GUARD_ABORT' -f $code) -ForegroundColor Yellow; return $false }
  }
  # Positive paths must pass.
  if (-not (Assert-QQHeaderMatches -Header 'same' -ExpectNick 'same')) { return $false }
  if (-not (Assert-QQNotGroupChat -IsGroup $false -Header 'h')) { return $false }
  if (-not (Assert-QQEditorWritable -EditorText '   ')) { return $false }
  if (-not (Assert-QQTextLanded -EditorText "hello`n" -Expected 'hello')) { return $false }
  return $true
}

Test-Case -Name 'envelope keeps empty arrays as arrays and null pid as null' -Body {
  . (Join-Path $script:Root 'lib\qq-json.ps1')
  $env = Get-QQEnvelopeObject -Ok $true -Command 'x' -Data ([ordered]@{ empty = @(); one = @('a'); zero = 0; flag = $false })
  $json = $env | ConvertTo-Json -Depth 6 -Compress
  if ($json -notmatch '"empty":\[\]') { Write-Host ('        empty array rendered as: {0}' -f $json) -ForegroundColor Yellow; return $false }
  if ($json -notmatch '"one":\["a"\]') { Write-Host ('        single-element array rendered as: {0}' -f $json) -ForegroundColor Yellow; return $false }
  if ($json -notmatch '"pid":null') { Write-Host '        pid was not null' -ForegroundColor Yellow; return $false }
  if ($json -notmatch '"flag":false') { return $false }
  # Round-trip: a consumer must be able to enumerate an empty list.
  $back = $json | ConvertFrom-Json
  if (@($back.data.empty).Count -ne 0) { Write-Host '        empty array did not round-trip' -ForegroundColor Yellow; return $false }
  $withPid = Get-QQEnvelopeObject -Ok $true -Command 'x' -Data @{} -TargetPid 4242
  if (($withPid | ConvertTo-Json -Depth 6 -Compress) -notmatch '"pid":4242') { return $false }
  return $true
}

Write-Host ''
Write-Host '[live] read-only commands and the send guard chain' -ForegroundColor Cyan

$livePid = $SenderPid
$script:LivePid = 0
$script:LiveHeader = ''

if (-not $StaticOnly) {
  Test-Case -Name 'doctor reports a ready instance with no selector drift' -Body {
    $r = Invoke-Framework -Arguments @('doctor')
    if ($r.ExitCode -ne 0) { Write-Host ('        exit={0}' -f $r.ExitCode) -ForegroundColor Yellow; return $false }
    if ($null -eq $r.Json -or $r.Json.ok -ne $true) { return $false }
    if (@($r.Json.data.selectorDrift).Count -gt 0) {
      Write-Host ('        selector drift: {0}' -f (@($r.Json.data.selectorDrift) -join ', ')) -ForegroundColor Yellow
      return $false
    }
    if (@($r.Json.data.instances).Count -lt 1) { Write-Host '        no QQ instance' -ForegroundColor Yellow; return $false }
    $first = @($r.Json.data.instances)[0]
    if ($livePid -gt 0 -and [int]$first.pid -ne $livePid) {
      # Prefer the instance the caller pinned.
      foreach ($inst in @($r.Json.data.instances)) { if ([int]$inst.pid -eq $livePid) { $first = $inst } }
    }
    $script:LivePid = [int]$first.pid
    $script:LiveAccount = [string]$first.nick
    Write-Host ('        pid {0}, account {1}, {2} nodes, ready={3}' -f $script:LivePid, $script:LiveAccount, $r.Json.data.nodeCount, $r.Json.data.ready) -ForegroundColor DarkGray
    return ($r.Json.data.ready -eq $true)
  }

  Test-Case -Name 'identify returns an account nickname read from the avatar' -Body {
    $r = Invoke-Framework -Arguments @('identify')
    if ($r.ExitCode -ne 0) { return $false }
    if ($null -eq $r.Json -or $r.Json.ok -ne $true) { return $false }
    foreach ($inst in @($r.Json.data.instances)) {
      if ([int]$inst.pid -ne $script:LivePid) { continue }
      if ([string]::IsNullOrEmpty([string]$inst.nick)) { Write-Host '        nickname was empty' -ForegroundColor Yellow; return $false }
      return ([string]$inst.identitySource -eq 'user-avatar')
    }
    Write-Host '        pinned pid was not enumerated' -ForegroundColor Yellow
    return $false
  }

  Test-Case -Name 'list-sessions reads rows that carry a title' -Body {
    if ($script:LivePid -le 0) { return $false }
    $r = Invoke-Framework -Arguments @('list-sessions', '-SenderPid', [string]$script:LivePid, '-Limit', '5')
    if ($r.ExitCode -ne 0) { Write-Host ('        exit={0}' -f $r.ExitCode) -ForegroundColor Yellow; return $false }
    if ($null -eq $r.Json -or $r.Json.ok -ne $true) { return $false }
    $rows = @($r.Json.data.sessions)
    if ($rows.Count -lt 1) { return $false }
    foreach ($row in $rows) { if ([string]::IsNullOrEmpty([string]$row.title)) { return $false } }
    # The selected row names the open conversation, which the next test reuses.
    foreach ($row in $rows) { if ([bool]$row.selected) { $script:LiveHeader = [string]$row.title } }
    if ([string]::IsNullOrEmpty($script:LiveHeader)) { $script:LiveHeader = [string]@($rows)[0].title }
    Write-Host ('        {0} rows read of {1} rendered; open conversation is {2}' -f $r.Json.data.count, $r.Json.data.totalInList, $script:LiveHeader) -ForegroundColor DarkGray
    return $true
  }

  Test-Case -Name 'read-chat reports self messages with a consistent sender' -Body {
    if ($script:LivePid -le 0 -or [string]::IsNullOrEmpty($script:LiveHeader)) { return $false }
    $r = Invoke-Framework -Arguments @('read-chat', '-SenderPid', [string]$script:LivePid, '-OpenNick', $script:LiveHeader, '-Limit', '8')
    if ($r.ExitCode -ne 0) { Write-Host ('        exit={0}: {1}' -f $r.ExitCode, $r.Json.error.message) -ForegroundColor Yellow; return $false }
    if ($null -eq $r.Json -or $r.Json.ok -ne $true) { return $false }
    $msgs = @($r.Json.data.messages)
    if ($msgs.Count -lt 1) { Write-Host '        no messages returned' -ForegroundColor Yellow; return $false }
    foreach ($m in $msgs) {
      if ([string]::IsNullOrEmpty([string]$m.kind)) { return $false }
      if ([bool]$m.self -and [string]$m.sender -ne 'self' -and [string]$m.sender -ne [string]$script:LiveAccount) {
        Write-Host ('        self message reported sender {0}' -f $m.sender) -ForegroundColor Yellow
        return $false
      }
    }
    Write-Host ('        {0} messages, {1} unreadable' -f $r.Json.data.count, $r.Json.data.unreadableCount) -ForegroundColor DarkGray
    return $true
  }

  Test-Case -Name 'send-message -DryRun passes the guard chain and sends nothing' -Body {
    if ($script:LivePid -le 0 -or [string]::IsNullOrEmpty($script:LiveHeader)) { return $false }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
      [System.IO.File]::WriteAllText($tmp, 'framework self-check payload', (New-Object System.Text.UTF8Encoding($false)))
      $r = Invoke-Framework -Arguments @('send-message', '-SenderPid', [string]$script:LivePid, '-ExpectNick', $script:LiveHeader, '-MessageFile', $tmp, '-DryRun')
      if ($r.ExitCode -ne 0) { Write-Host ('        exit={0}: {1}' -f $r.ExitCode, $r.Json.error.message) -ForegroundColor Yellow; return $false }
      if ($null -eq $r.Json -or $r.Json.ok -ne $true) { return $false }
      if ($r.Json.data.dryRun -ne $true -or $r.Json.data.sent -ne $false) { return $false }
      if ($r.Json.data.headerMatches -ne $true) { return $false }
      if (@($r.Json.data.guardsPassed).Count -ne 8) { Write-Host ('        guards reported: {0}' -f (@($r.Json.data.guardsPassed) -join ',')) -ForegroundColor Yellow; return $false }
      return $true
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }

  Test-Case -Name 'send-message refuses a mismatched ExpectNick with exit 4' -Body {
    if ($script:LivePid -le 0) { return $false }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
      [System.IO.File]::WriteAllText($tmp, 'framework self-check payload', (New-Object System.Text.UTF8Encoding($false)))
      $r = Invoke-Framework -Arguments @('send-message', '-SenderPid', [string]$script:LivePid, '-ExpectNick', 'not-the-open-conversation-42', '-MessageFile', $tmp)
      if ($r.ExitCode -ne 4) { Write-Host ('        exit={0} (expected 4)' -f $r.ExitCode) -ForegroundColor Yellow; return $false }
      if ($null -eq $r.Json) { return $false }
      if ($r.Json.error.exitCode -ne 4) { return $false }
      return ($r.Json.error.code -eq 'GUARD_ABORT' -and [string]$r.Json.error.details.guard -eq 'GUARD_HEADER_MISMATCH')
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
}

Write-Host ''
if ($script:Failed -eq 0) {
  Write-Host ('PASS: {0} checks' -f $script:Passed) -ForegroundColor Green
  exit 0
}
Write-Host ('FAIL: {0} passed, {1} failed' -f $script:Passed, $script:Failed) -ForegroundColor Red
foreach ($f in $script:Failures) { Write-Host ('  - {0}' -f $f) -ForegroundColor Red }
exit 1
