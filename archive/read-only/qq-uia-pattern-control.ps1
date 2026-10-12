Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$PIDS = [ordered]@{ Invoke=10000; Value=10002; Text=10014; ScrollItem=10018; Scroll=10004; Selection=10001; SelectionItem=10010; ExpandCollapse=10005; Toggle=10015; Legacy=10020; Window=10017; RangeValue=10003 }
$PAT = [ordered]@{}
foreach ($k in $PIDS.Keys) { $PAT[$k] = [System.Windows.Automation.AutomationPattern]::LookupById($PIDS[$k]) }

function Get-Patterns {
  param($el)
  $got = @{}
  foreach ($k in $PAT.Keys) {
    $obj = $null
    try { if ($el.TryGetCurrentPattern($PAT[$k], [ref]$obj)) { $got[$k] = $obj } } catch { }
  }
  return $got
}

function Invoke-Button($pidTarget, $buttonText, $outputName, [int]$waitSec = 12) {
  $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $pidTarget)
  $win = $null
  for ($i = 0; $i -lt $waitSec * 2; $i++) {
    $wins = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    foreach ($w in $wins) { if ($w.Current.Name -eq $outputName) { $win = $w; break } }
    if ($win) { break }
    Start-Sleep -Milliseconds 500
  }
  if (-not $win) { Write-Host "  [$outputName] window not found" -ForegroundColor Red; return $null }
  Write-Host "  [$outputName] window found: $($win.Current.ClassName)" -ForegroundColor Green

  $btnCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $buttonText)
  $btn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
  if (-not $btn) { Write-Host "  [$outputName] button '$buttonText' not found" -ForegroundColor Red; return $null }
  Write-Host ("  [$outputName] button found: type={0} cls={1} enabled={2} focusable={3}" -f $btn.Current.ControlType.ProgrammaticName, $btn.Current.ClassName, $btn.Current.IsEnabled, $btn.Current.IsKeyboardFocusable)

  $inv = $null
  $ok = $false
  try { $ok = $btn.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$inv) } catch { Write-Host "  [$outputName] TryGetCurrentPattern threw: $($_.Exception.Message)" }
  Write-Host ("  [$outputName] InvokePattern available: {0}" -f $ok) -ForegroundColor Yellow
  if ($ok -and $inv) {
    try { $inv.Invoke(); Write-Host "  [$outputName] Invoke() SUCCEEDED -> result window should be '$outputName'" -ForegroundColor Green; return $true }
    catch { Write-Host "  [$outputName] Invoke() failed: $($_.Exception.Message)" -ForegroundColor Red; return $false }
  }
  return $false
}

Write-Host "=== LIVE QQ patterns at window level (no launch, default state) ===" -ForegroundColor Cyan
foreach ($qpid in @(11004, 72440)) {
  $cq = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $qpid)
  $i = 0
  foreach ($qw in [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cq)) {
    $i++
    $qa = $qw.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $cnt = @{}
    $err = 0
    foreach ($e in $qa) {
      try {
        foreach ($k in $PAT.Keys) { $o = $null; if ($e.TryGetCurrentPattern($PAT[$k], [ref]$o)) { $cnt[$k] = 1 + [int]$cnt[$k] } }
      } catch { $err++ }
    }
    Write-Host ("  pid {0} win#{1} `"{2}`" cls={3}: {4} descendants; patternCounts=[{5}] errors={6}" -f `
      $qpid, $i, $qw.Current.Name, $qw.Current.ClassName, $qa.Count, (($cnt.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ','), $err)
  }
}

Write-Host "`n=== CONTROL: MessageBox button (same UIA client process) ===" -ForegroundColor Cyan
$msgPid = $PID
$btnText = 'UIA-CONTROL-BUTTON-' + (Get-Random)
Add-Type -AssemblyName System.Windows.Forms
$job = Start-Job -ScriptBlock {
  param($bt)
  Add-Type -AssemblyName System.Windows.Forms
  [void][System.Windows.Forms.MessageBox]::Show('uia control', $bt)
} -ArgumentList $btnText
$found = Invoke-Button -pidTarget $msgPid -buttonText $btnText -outputName $btnText
Start-Sleep -Milliseconds 800
# dismiss the messagebox by clicking OK if still up
$condM = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $msgPid)
foreach ($w in [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $condM)) {
  if ($w.Current.Name -eq $btnText) {
    $okc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'OK')
    $okb = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $okc)
    if ($okb) { try { $okb.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } catch {} }
  }
}
Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue
Write-Host "control Invoke result: $found" -ForegroundColor Magenta

Write-Host "`n=== CONTROL 2: WinForms button in a SEPARATE process ===" -ForegroundColor Cyan
$ctrlScript = Join-Path $env:TEMP 'dsh_uia_ctrl.ps1'
@'
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.Form
$f.Text = 'DSH-CTRL2'
$b = New-Object System.Windows.Forms.Button
$b.Text = 'CTRL2-BUTTON'; $b.Left = 20; $b.Top = 20; $b.Width = 200; $b.Height = 50
$f.Controls.Add($b); $f.Show()
[System.Windows.Forms.Application]::Run($f)
'@ | Set-Content $ctrlScript -Encoding UTF8
$cp = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $ctrlScript) -PassThru
Start-Sleep -Seconds 3
$res2 = Invoke-Button -pidTarget $cp.Id -buttonText 'CTRL2-BUTTON' -outputName 'DSH-CTRL2'
Write-Host "control2 Invoke result: $res2" -ForegroundColor Magenta
try { Stop-Process -Id $cp.Id -Force -ErrorAction Stop } catch {}
Remove-Item $ctrlScript -Force -ErrorAction SilentlyContinue
