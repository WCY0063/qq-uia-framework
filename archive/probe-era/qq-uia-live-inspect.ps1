# NON-INVASIVE: read the currently running QQ via UI Automation only. No process is launched or stopped.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# Pattern objects must come from the static properties (AutomationPattern.LookupById does not exist).
$PAT = [ordered]@{
  Invoke         = [System.Windows.Automation.InvokePattern]::Pattern
  Value          = [System.Windows.Automation.ValuePattern]::Pattern
  Text           = [System.Windows.Automation.TextPattern]::Pattern
  Scroll         = [System.Windows.Automation.ScrollPattern]::Pattern
  ScrollItem     = [System.Windows.Automation.ScrollItemPattern]::Pattern
  Selection      = [System.Windows.Automation.SelectionPattern]::Pattern
  SelectionItem  = [System.Windows.Automation.SelectionItemPattern]::Pattern
  ExpandCollapse = [System.Windows.Automation.ExpandCollapsePattern]::Pattern
  Toggle         = [System.Windows.Automation.TogglePattern]::Pattern
  RangeValue     = [System.Windows.Automation.RangeValuePattern]::Pattern
  Window         = [System.Windows.Automation.WindowPattern]::Pattern
  Transform      = [System.Windows.Automation.TransformPattern]::Pattern
}

function Get-Patterns {
  param($el)
  $got = @{}
  foreach ($k in $PAT.Keys) {
    $obj = $null
    try { if ($el.TryGetCurrentPattern($PAT[$k], [ref]$obj)) { $got[$k] = $obj } } catch {}
  }
  return $got
}

$pids = @(Get-Process QQ -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Write-Host "live QQ pids: $($pids -join ', ')" -ForegroundColor Cyan

foreach ($qpid in $pids) {
  $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$qpid)
  $wins = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
  foreach ($w in $wins) {
    $all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    if ($all.Count -le 10) { continue }   # skip empty shells

    $name = ''; $cls = ''
    try { $name = $w.Current.Name; $cls = $w.Current.ClassName } catch {}
    Write-Host "`n############ pid $qpid  window `"$name`" cls=$cls  NODES=$($all.Count) ############" -ForegroundColor Magenta

    $typeCount = @{}; $patCount = @{}; $patSample = @{}
    $editNodes = @(); $docNodes = @()
    foreach ($e in $all) {
      $t = '?'; try { $t = $e.Current.ControlType.ProgrammaticName.Replace('ControlType.','') } catch {}
      $typeCount[$t] = 1 + [int]$typeCount[$t]
      $g = Get-Patterns -el $e
      foreach ($k in $g.Keys) {
        $patCount[$k] = 1 + [int]$patCount[$k]
        if (-not $patSample.ContainsKey($k)) {
          $nm = ''; try { $nm = $e.Current.Name } catch {}
          if ($nm.Length -gt 45) { $nm = $nm.Substring(0,45) + '...' }
          $patSample[$k] = "[$t] `"$nm`""
        }
      }
      if ($t -eq 'Edit') { $editNodes += ,@{ El = $e; Pats = $g } }
      if ($t -eq 'Document') { $docNodes += ,@{ El = $e; Pats = $g } }
    }

    Write-Host ("control types : " + (($typeCount.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
    Write-Host ("patterns      : " + (($patCount.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')) -ForegroundColor Green
    foreach ($k in ($patCount.Keys | Sort-Object)) { Write-Host ("      {0,-15} {1}" -f $k, $patSample[$k]) }

    foreach ($d in $docNodes) {
      $txt = ''
      if ($d.Pats.ContainsKey('Text')) { try { $txt = $d.Pats['Text'].DocumentRange.GetText(160) } catch { $txt = '<GetText failed>' } }
      $txt = ($txt -replace "`r?`n", ' / '); if ($txt.Length -gt 150) { $txt = $txt.Substring(0,150) + '...' }
      Write-Host ("  [Document] patterns=[{0}] text=`"{1}`"" -f (($d.Pats.Keys) -join ','), $txt) -ForegroundColor Yellow
    }
    foreach ($d in $editNodes) {
      $ro = ''; $val = ''
      if ($d.Pats.ContainsKey('Value')) { try { $ro = $d.Pats['Value'].Current.IsReadOnly; $val = $d.Pats['Value'].Current.Value } catch {} }
      Write-Host ("  [Edit] name=`"{0}`" patterns=[{1}] readOnly={2} value=`"{3}`"" -f $d.El.Current.Name, (($d.Pats.Keys) -join ','), $ro, $val) -ForegroundColor Yellow
    }
  }
}
