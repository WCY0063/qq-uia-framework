param([int]$Pid2 = 0, [string]$WindowName = 'DSH-CTRL2', [string]$ButtonName = 'CTRL2-BUTTON')
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# Pattern objects MUST come from the static properties (AutomationPattern.LookupById does not exist).
$PAT = [ordered]@{
  Invoke  = [System.Windows.Automation.InvokePattern]::Pattern
  Value   = [System.Windows.Automation.ValuePattern]::Pattern
  Text    = [System.Windows.Automation.TextPattern]::Pattern
  ScrollItem = [System.Windows.Automation.ScrollItemPattern]::Pattern
  Scroll  = [System.Windows.Automation.ScrollPattern]::Pattern
  Selection = [System.Windows.Automation.SelectionPattern]::Pattern
  SelectionItem = [System.Windows.Automation.SelectionItemPattern]::Pattern
  ExpandCollapse = [System.Windows.Automation.ExpandCollapsePattern]::Pattern
  Toggle  = [System.Windows.Automation.TogglePattern]::Pattern
  RangeValue = [System.Windows.Automation.RangeValuePattern]::Pattern
  Window  = [System.Windows.Automation.WindowPattern]::Pattern
  Transform = [System.Windows.Automation.TransformPattern]::Pattern
}
"pattern objects loaded: " + (($PAT.GetEnumerator() | Where-Object { $_.Value -ne $null } | ForEach-Object { $_.Key }) -join ', ')

function Get-Patterns {
  param($el)
  $got = @{}
  foreach ($k in $PAT.Keys) {
    if ($PAT[$k] -eq $null) { continue }
    $obj = $null
    try { if ($el.TryGetCurrentPattern($PAT[$k], [ref]$obj)) { $got[$k] = $obj } } catch {}
  }
  return $got
}

Write-Host "`n=== PROBE: pid $Pid2 window '$WindowName' ===" -ForegroundColor Cyan
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$Pid2)
$wins = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
Write-Host "top-level windows: $($wins.Count)"
foreach ($w in $wins) {
  Write-Host ("  win `"{0}`" cls={1}" -f $w.Current.Name, $w.Current.ClassName)
  $all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  Write-Host "  descendants: $($all.Count)"
  $counts = @{}
  foreach ($e in $all) {
    $g = Get-Patterns -el $e
    foreach ($k in $g.Keys) { $counts[$k] = 1 + [int]$counts[$k] }
    Write-Host ("    [{0,-9}] `"{1}`" cls={2} patterns=[{3}]" -f `
      $e.Current.ControlType.ProgrammaticName.Replace('ControlType.',''), $e.Current.Name, $e.Current.ClassName, (($g.Keys) -join ','))
  }
  Write-Host ("  >> aggregated: " + (($counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
  if ($ButtonName) {
    $bc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $ButtonName)
    $b = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $bc)
    if ($b) {
      try {
        $ip = $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $ip.Invoke()
        Write-Host "  Invoke('$ButtonName') SUCCEEDED" -ForegroundColor Green
      } catch { Write-Host "  Invoke FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    } else { Write-Host "  button '$ButtonName' not found" -ForegroundColor Red }
  }
}
