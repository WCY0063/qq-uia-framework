# Probe QQ's comprehensive-search panel. Opens the panel and dumps structure. Never types a message.
param([string]$TargetId = '987654321', [switch]$DoEnterSearch, [switch]$ClickSearchRow)
. "$PSScriptRoot\qq-lib.ps1"
Add-Type -AssemblyName System.Windows.Forms

$w = Get-QqWindows | Sort-Object W -Descending | Select-Object -First 1
$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
Write-Host ("window hwnd={0} pid={1}" -f $w.Hwnd, $w.Pid) -ForegroundColor Cyan
[void](Focus-Window -Hwnd ([IntPtr]$w.Hwnd))
Start-Sleep -Milliseconds 500

function Dump-Nodes {
  param($R, [string]$Stage)
  $a = $R.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  Write-Host ("`n===== [$Stage] total nodes={0} =====" -f $a.Count) -ForegroundColor Magenta
  $a | Where-Object { $_.Current.Name -ne '' } | ForEach-Object {
    $ty = $_.Current.ControlType.ProgrammaticName.Replace('ControlType.', '')
    $nm = $_.Current.Name; if ($nm.Length -gt 70) { $nm = $nm.Substring(0,70) + '..' }
    Write-Host ("   [{0,-9}] cls='{1}' name='{2}'" -f $ty, $_.Current.ClassName, $nm)
  }
}

# 1) set the search value
$a1 = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$search = @($a1 | Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Edit' } | Select-Object -First 1)
$vp = $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
$search.SetFocus(); Start-Sleep -Milliseconds 200
$vp.SetValue($TargetId); Start-Sleep -Milliseconds 800
Write-Host ("search box value now: '{0}'" -f $vp.Current.Value) -ForegroundColor Yellow

# 2) find the "comprehensive search" entry
$a2 = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$enter = @($a2 | Where-Object { $_.Current.ClassName -match 'search-result-item' } | Select-Object -First 1)
if (-not $enter) { Write-Host 'no search-result-item found' -ForegroundColor Red }
else {
  Write-Host ("entry: cls='{0}' name='{1}'" -f $enter.Current.ClassName, $enter.Current.Name) -ForegroundColor Green
  if ($ClickSearchRow) {
    $ok = $false
    try { $ip = $enter.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern); $ip.Invoke(); $ok = $true; Write-Host 'Invoke on search entry OK' }
    catch { Write-Host ('Invoke failed: ' + $_.Exception.Message) }
    if (-not $ok) {
      $enter.SetFocus(); Start-Sleep -Milliseconds 250
      [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
      Write-Host 'sent ENTER to the highlighted entry'
    }
    Start-Sleep -Seconds 4
    Dump-Nodes -R $root -Stage 'after opening comprehensive search'
  }
}

# 3) optional: type the number into the panel's own search box and press Enter
if ($DoEnterSearch) {
  $a3 = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $edits = @($a3 | Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Edit' })
  Write-Host ("`nEdit controls now: {0}" -f $edits.Count)
  $edits | ForEach-Object { $r = Get-RectOf $_; Write-Host ("   name='{0}' cls='{1}' at({2},{3}) {4}x{5}" -f $_.Current.Name, $_.Current.ClassName, $r.X, $r.Y, $r.W, $r.H) }
  $panel = $edits | Sort-Object { -1 * (Get-RectOf $_).Y } | Select-Object -First 1
  if ($panel) {
    $panel.SetFocus(); Start-Sleep -Milliseconds 300
    $pv = $panel.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $pv.SetValue($TargetId); Start-Sleep -Milliseconds 600
    Write-Host ("panel search value: '{0}'" -f $pv.Current.Value)
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Seconds 4
    Dump-Nodes -R $root -Stage 'after panel search ENTER'
  }
}
