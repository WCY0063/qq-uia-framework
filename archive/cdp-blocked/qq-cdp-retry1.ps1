# CDP retry attempt 1: launch with the debug port + Chromium verbose logging, then gather
# hard evidence (effective command line, DevToolsActivePort file, listening ports, devtools log lines).
# Uses a throwaway profile so the user's running QQ is untouched.
param([int]$Port = 9222, [string]$Tag = 'r1')
$ErrorActionPreference = 'Continue'

$profile = Join-Path $env:TEMP "qq-cdp-$Tag"
$logfile = Join-Path $env:TEMP "qq-cdp-$Tag-chromium.log"
Remove-Item $profile -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $logfile -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $profile | Out-Null

$before = @(Get-Process QQ -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

$argSets = @(
  @{ Label = 'A: --remote-debugging-port=N + logging'
     Args  = @("--user-data-dir=$profile", "--remote-debugging-port=$Port", '--remote-allow-origins=*', '--enable-logging', '--v=1', "--log-file=$logfile") },
  @{ Label = 'B: port before user-data-dir'
     Args  = @("--remote-debugging-port=$Port", '--remote-allow-origins=*', "--user-data-dir=$profile") },
  @{ Label = 'C: --debug-devtools + remote-debugging-port'
     Args  = @("--user-data-dir=$profile", "--remote-debugging-port=$Port", '--debug-devtools') }
)

foreach ($set in $argSets) {
  Write-Host "`n============================== $($set.Label) ==============================" -ForegroundColor Magenta
  Write-Host ("args: {0}" -f ($set.Args -join ' '))
  $t0 = Get-Date
  $p = Start-Process -FilePath 'D:\QQ\QQ.exe' -ArgumentList $set.Args -PassThru
  Start-Sleep -Seconds 35
  $new = @(Get-Process QQ -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id } | Select-Object -ExpandProperty Id)
  Write-Host ("new pids: {0}" -f ($new -join ', '))

  # effective command lines
  foreach ($np in $new) {
    $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$np" -ErrorAction SilentlyContinue
    if ($ci) {
      $isBrowser = $ci.CommandLine -notmatch '--type='
      $hasFlag = $ci.CommandLine -match 'remote-debugging'
      Write-Host ("  pid {0} browser={1} hasDebugFlag={2}" -f $np, $isBrowser, $hasFlag)
      if ($isBrowser -or $hasFlag) { Write-Host ("     cmd: {0}" -f $ci.CommandLine) }
    }
  }

  # listening ports owned by these pids
  $ports = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -in $new } | Select-Object -ExpandProperty LocalPort
  Write-Host ("  listening ports: [{0}]" -f ($ports -join ', '))

  # HTTP probe
  try { $v = Invoke-RestMethod "http://127.0.0.1:$Port/json/version" -TimeoutSec 3 -ErrorAction Stop; Write-Host "  CDP HTTP OK -> $($v.Browser)" -ForegroundColor Green }
  catch { Write-Host "  CDP HTTP: $($_.Exception.Message.Split([char]10)[0])" }

  # DevToolsActivePort
  $dap = Get-ChildItem $profile -Filter 'DevToolsActivePort' -Recurse -ErrorAction SilentlyContinue
  if ($dap) { Write-Host ("  DevToolsActivePort FOUND: {0} => {1}" -f $dap[0].FullName, ((Get-Content $dap[0].FullName) -join '|')) -ForegroundColor Green }
  else { Write-Host '  DevToolsActivePort: absent' }

  # chromium log
  if (Test-Path $logfile) {
    $lines = Get-Content $logfile -ErrorAction SilentlyContinue
    Write-Host ("  chromium log lines: {0}" -f $lines.Count)
    $hits = $lines | Select-String -Pattern 'devtools|DevTools|remote.debug|RemoteDebug|automation' -SimpleMatch:$false
    if ($hits) { $hits | Select-Object -First 12 | ForEach-Object { Write-Host ("     " + $_.Line) } }
    else { Write-Host '     (no devtools-related log lines)'; $lines | Select-Object -First 6 | ForEach-Object { Write-Host ("     | " + $_) } }
  } else { Write-Host '  chromium log: not written' }

  foreach ($np in $new) { try { Stop-Process -Id $np -Force -ErrorAction Stop } catch {} }
  Start-Sleep -Seconds 4
  Write-Host ("  cleaned up; survived: [{0}]" -f ((Get-Process QQ -ErrorAction SilentlyContinue | Where-Object { $new -contains $_.Id } | ForEach-Object { $_.Id }) -join ', '))
}
