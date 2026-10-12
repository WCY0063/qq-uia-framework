param([int]$TargetPidToUse, [string]$WindowName, [switch]$ForceA11y, [int]$WaitSec = 40, [switch]$KeepAlive)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$PIDS = [ordered]@{ Invoke=10000; Value=10002; Text=10014; ScrollItem=10018; Scroll=10004; Selection=10001; SelectionItem=10010; ExpandCollapse=10005; Toggle=10015; LegacyIAccessible=10020; Window=10017; RangeValue=10003 }
$PAT = [ordered]@{}
foreach ($k in $PIDS.Keys) { $PAT[$k] = [System.Windows.Automation.AutomationPattern]::LookupById($PIDS[$k]) }

function Get-Patterns {
  param($el)
  $got = @{}
  $errs = @()
  foreach ($k in $PAT.Keys) {
    $obj = $null
    try { if ($el.TryGetCurrentPattern($PAT[$k], [ref]$obj)) { $got[$k] = $obj } }
    catch { $errs += $k }
  }
  return @{ Pats = $got; Errs = $errs }
}

$launched = @()
if ($ForceA11y -and $TargetPidToUse -eq 0) {
  $existing = @(Get-Process QQ -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  Write-Host "launching QQ with --force-renderer-accessibility" -ForegroundColor Yellow
  [void](Start-Process -FilePath 'D:\QQ\QQ.exe' -ArgumentList @('--force-renderer-accessibility') -PassThru)
  Start-Sleep -Seconds $WaitSec
  $launched = @(Get-Process QQ -ErrorAction SilentlyContinue | Where-Object { $existing -notcontains $_.Id } | Select-Object -ExpandProperty Id)
  Write-Host "test pids: $($launched -join ', ')"
}

$targets = @()
if ($TargetPidToUse -gt 0) { $targets = @($TargetPidToUse) } else { $targets = $launched }

try {
  foreach ($tp in $targets) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$tp)
    $wins = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    Write-Host "`n############ pid $tp : $($wins.Count) UIA top-level windows ############" -ForegroundColor Magenta
    foreach ($w in $wins) {
      $name = ''; $cls = ''
      try { $name = $w.Current.Name; $cls = $w.Current.ClassName } catch {}
      $all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
      Write-Host ("`n--- `"{0}`" cls={1} : {2} descendants ---" -f $name, $cls, $all.Count) -ForegroundColor Cyan
      if ($all.Count -eq 0) { continue }

      $patCount = @{}
      $patSample = @{}
      $errCount = 0
      $typeCount = @{}
      foreach ($e in $all) {
        $t = '?'; try { $t = $e.Current.ControlType.ProgrammaticName.Replace('ControlType.','') } catch {}
        $typeCount[$t] = 1 + [int]$typeCount[$t]
        $r = Get-Patterns -el $e
        if ($r.Errs.Count -gt 0) { $errCount++ }
        foreach ($k in $r.Pats.Keys) {
          $patCount[$k] = 1 + [int]$patCount[$k]
          if (-not $patSample.ContainsKey($k)) {
            $nm = ''; try { $nm = $e.Current.Name } catch {}
            $patSample[$k] = "[$t] `"$nm`""
          }
        }
      }
      Write-Host ("control types: {0}" -f (($typeCount.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
      if ($patCount.Count -eq 0) {
        Write-Host "PATTERN SUPPORT: NONE (0 of $($all.Count) nodes expose any UIA pattern)  [pattern-query errors: $errCount]" -ForegroundColor Red
      } else {
        Write-Host "PATTERN SUPPORT:" -ForegroundColor Green
        foreach ($k in ($patCount.Keys | Sort-Object)) { Write-Host ("   {0,-18} {1,4} nodes   e.g. {2}" -f $k, $patCount[$k], $patSample[$k]) }
        Write-Host ("   (pattern-query errors: $errCount)")
      }

      # highlight input + message area specifics
      foreach ($e in $all) {
        $t = ''; try { $t = $e.Current.ControlType.ProgrammaticName.Replace('ControlType.','') } catch {}
        if ($t -notin @('Edit','Document')) { continue }
        $r = Get-Patterns -el $e
        $nm = ''; $cl = ''; $ro = ''; $val = ''
        try { $nm = $e.Current.Name; $cl = $e.Current.ClassName } catch {}
        if ($r.Pats.ContainsKey('Value')) { try { $val = $r.Pats['Value'].Current.Value; $ro = $r.Pats['Value'].Current.IsReadOnly } catch {} }
        $txt = ''
        if ($r.Pats.ContainsKey('Text')) { try { $txt = $r.Pats['Text'].DocumentRange.GetText(200) } catch { $txt = '<GetText failed>' } }
        Write-Host ("   >> [{0}] name=`"{1}`" cls=`"{2}`" patterns=[{3}] readOnly={4} value=`"{5}`"" -f $t, $nm, $cl, (($r.Pats.Keys) -join ','), $ro, $val) -ForegroundColor Yellow
        if ($txt) { $txt = ($txt -replace "`r?`n", ' ⏎ '); if ($txt.Length -gt 160) { $txt = $txt.Substring(0,160) + '...' }; Write-Host ("      text=`"{0}`"" -f $txt) -ForegroundColor DarkYellow }
      }
    }
  }
} finally {
  if ($launched.Count -gt 0 -and -not $KeepAlive) {
    Write-Host "`n=== cleanup: killing test instance ===" -ForegroundColor Cyan
    foreach ($pp in $launched) { try { Stop-Process -Id $pp -Force -ErrorAction Stop } catch {} }
    Start-Sleep -Seconds 3
    $left = @(Get-Process QQ -ErrorAction SilentlyContinue | Where-Object { $launched -contains $_.Id } | ForEach-Object { $_.Id })
    Write-Host ("  surviving: [{0}]" -f ($left -join ', '))
  }
}
