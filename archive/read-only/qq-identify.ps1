# Identify the logged-in account per QQ instance + locate the search entry point. Read-only.
. (Join-Path $PSScriptRoot 'qq-lib.ps1')

$wins = Get-QqWindows | Sort-Object W -Descending
foreach ($w in $wins) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
  Write-Host ""
  Write-Host ("############ hwnd={0} pid={1} {2}x{3} ############" -f $w.Hwnd, $w.Pid, $w.W, $w.H) -ForegroundColor Magenta

  # every node whose CLASS hints at identity, plus their name
  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $idNodes = @($all | Where-Object { $_.Current.ClassName -match 'nickname|avatar|profile|user-name|account' })
  Write-Host ("-- identity-ish nodes ({0}) --" -f $idNodes.Count) -ForegroundColor Cyan
  $idNodes | Select-Object -First 20 | ForEach-Object {
    $r = Get-RectOf $_
    Write-Host ("   cls='{0}' name='{1}' at({2},{3}) {4}x{5}" -f $_.Current.ClassName, $_.Current.Name, $r.X, $r.Y, $r.W, $r.H)
  }

  # first 30 named nodes in document order (topbar comes first)
  Write-Host "-- first 26 named nodes (document order) --" -ForegroundColor Cyan
  $all | Where-Object { $_.Current.Name -ne '' } | Select-Object -First 26 | ForEach-Object {
    $ty = $_.Current.ControlType.ProgrammaticName.Replace('ControlType.', '')
    Write-Host ("   [{0,-9}] cls='{1}' name='{2}'" -f $ty, $_.Current.ClassName, $_.Current.Name)
  }

  # the Edit (search) control with its surrounding container
  $ed = Get-El -Root $root -TypeRegex 'Edit'
  if ($ed) {
    Write-Host "-- search Edit + ancestors --" -ForegroundColor Cyan
    $r = Get-RectOf $ed
    Write-Host ("   [Edit] name='{0}' at({1},{2}) {3}x{4}" -f $ed.Current.Name, $r.X, $r.Y, $r.W, $r.H)
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $p = $walker.GetParent($ed)
    $depth = 0
    while ($p -ne $null -and $depth -lt 6) {
      $pr = Get-RectOf $p
      Write-Host ("   ^ cls='{0}' name='{1}' at({2},{3}) {4}x{5}" -f $p.Current.ClassName, $p.Current.Name, $pr.X, $pr.Y, $pr.W, $pr.H)
      $p = $walker.GetParent($p); $depth++
    }
  }
}
