param([int]$Port = 9222, [int]$WaitSec = 120)

# Launch QQ bound to the already-logged-in account 123456789 (same arguments the running
# instance uses, plus the debugging port) and wait until the CDP HTTP endpoint answers.
$before = @(Get-Process QQ -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$before | Set-Content "$env:TEMP\qq-baseline-pids.txt"
"baseline QQ pids ($($before.Count)): $($before -join ', ')"

$appArgs = @(
  'C:\Program Files\Tencent\QQNT\versions\9.9.35-52892\resources\app\application.asar\background.js'
  '--from-multiple-login'
  '123456789'
  '""'
  '--hide-login-window'
  "--remote-debugging-port=$Port"
  '--force-renderer-accessibility'
  '--remote-allow-origins=*'
)
"launching: C:\Program Files\Tencent\QQNT\QQ.exe $($appArgs -join ' ')"
$p = Start-Process -FilePath 'C:\Program Files\Tencent\QQNT\QQ.exe' -ArgumentList $appArgs -PassThru
"launcher pid: $($p.Id)"

$reachable = $false
$deadline = (Get-Date).AddSeconds($WaitSec)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
  try {
    $v = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 -ErrorAction Stop
    $reachable = $true
    break
  } catch {}
}

$after = @(Get-Process QQ -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$new = @($after | Where-Object { $before -notcontains $_ })
$new | Set-Content "$env:TEMP\qq-test-pids.txt"
"new QQ pids ($($new.Count)): $($new -join ', ')"
"CDP reachable on $Port : $reachable"

if ($reachable) {
  "--- /json/version ---"
  $v | Select-Object Browser,'Protocol-Version','User-Agent','webSocketDebuggerUrl' | Format-List
  "--- /json/list summaries ---"
  $list = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 5
  "target count: $($list.Count)"
  $list | Select-Object -First 25 type,title,@{n='url';e={ if ($_.url.Length -gt 90) { $_.url.Substring(0,90) } else { $_.url } }} | Format-Table -AutoSize
} else {
  "CDP endpoint did not appear; the instance is still running with pid list above."
}
