Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$PIDS = [ordered]@{ Invoke=10000; Value=10002; Text=10014; ScrollItem=10018; LegacyIAccessible=10020; Window=10017; Selection=10001; SelectionItem=10010 }
$PAT = [ordered]@{}
foreach ($k in $PIDS.Keys) { $PAT[$k] = [System.Windows.Automation.AutomationPattern]::LookupById($PIDS[$k]) }

function Get-Patterns {
  param($el)
  $got = @{}
  foreach ($k in $PAT.Keys) {
    $obj = $null
    try { if ($el.TryGetCurrentPattern($PAT[$k], [ref]$obj)) { $got[$k] = $obj } } catch { $got["$k!ERR"] = $_.Exception.Message }
  }
  return $got
}

# Build a known-good control window
$form = New-Object System.Windows.Forms.Form
$form.Text = 'DSH-UIA-CTRL'
$form.Width = 420; $form.Height = 220
$form.StartPosition = 'Manual'; $form.Left = 30; $form.Top = 30
$btn = New-Object System.Windows.Forms.Button
$btn.Text = 'PROBE-BUTTON'; $btn.Left = 20; $btn.Top = 20; $btn.Width = 180; $btn.Height = 40
$txt = New-Object System.Windows.Forms.TextBox
$txt.Text = 'probe-value-123'; $txt.Left = 20; $txt.Top = 80; $txt.Width = 300
$chk = New-Object System.Windows.Forms.CheckBox
$chk.Text = 'PROBE-CHECK'; $chk.Left = 20; $chk.Top = 120
$form.Controls.AddRange(@($btn, $txt, $chk))
$form.Show()
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 1200

Write-Host "=== POSITIVE CONTROL: WinForms button/textbox ===" -ForegroundColor Cyan
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, '')
$root = [System.Windows.Automation.AutomationElement]::RootElement
$myPid = $PID
$condP = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $myPid)
$w = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condP) | Where-Object { $_.Current.Name -eq 'DSH-UIA-CTRL' }
Write-Host "control window found: $($w -ne $null)"
if ($w) {
  $all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  Write-Host "descendants = $($all.Count)"
  foreach ($e in $all) {
    $g = Get-Patterns -el $e
    $nm = $e.Current.Name; if ($nm.Length -gt 40) { $nm = $nm.Substring(0,40) }
    Write-Host ("  [{0,-9}] `"{1}`" patterns=[{2}]" -f $e.Current.ControlType.ProgrammaticName.Replace('ControlType.',''), $nm, (($g.Keys) -join ','))
  }
}
$form.Close(); $form.Dispose()

Write-Host "`n=== REAL TARGET: QQ's live windows (no launch) ===" -ForegroundColor Cyan
foreach ($qpid in @(11004, 72440)) {
  $cq = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $qpid)
  foreach ($qw in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cq)) {
    $qa = $qw.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $counts = @{}
    foreach ($e in $qa) {
      $g = Get-Patterns -el $e
      foreach ($k in $g.Keys) { if ($k -notmatch '!ERR') { $counts[$k] = 1 + [int]$counts[$k] } }
    }
    Write-Host ("  pid {0} win `"{1}`": {2} desclendants; patterns present: {3}" -f $qpid, $qw.Current.Name, $qa.Count, (($counts.Keys) -join ', '))
  }
}
