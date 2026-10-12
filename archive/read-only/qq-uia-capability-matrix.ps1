Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase

$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class CWin2 {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public static string Text(IntPtr h){ var sb=new StringBuilder(512); GetWindowTextW(h,sb,512); return sb.ToString(); }
  public static string Cls(IntPtr h){ var sb=new StringBuilder(512); GetClassNameW(h,sb,512); return sb.ToString(); }
  public static uint WinPid(IntPtr h){ uint p; GetWindowThreadProcessId(h, out p); return p; }
}
'@
if (-not ('CWin2' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp }

# Pattern ids from System.Windows.Automation.PatternId (works for every pattern, incl. LegacyIAccessible)
$PIDS = [ordered]@{
  Invoke = 10000; Selection = 10001; Value = 10002; RangeValue = 10003; Scroll = 10004
  ExpandCollapse = 10005; Grid = 10006; GridItem = 10007; Selection2 = 10010; SelectionItem = 10010
  Dock = 10011; Table = 10012; TableItem = 10013; Text = 10014; Toggle = 10015
  MultipleView = 10016; Window = 10017; ScrollItem = 10018; LegacyIAccessible = 10020
}
$PAT = [ordered]@{}
foreach ($k in $PIDS.Keys) { $PAT[$k] = [System.Windows.Automation.AutomationPattern]::LookupById($PIDS[$k]) }

function Get-Patterns {
  param($el)
  $got = @{}
  foreach ($k in $PAT.Keys) {
    $obj = $null
    try { if ($el.TryGetCurrentPattern($PAT[$k], [ref]$obj)) { $got[$k] = $obj } } catch {}
  }
  return $got
}

$exe = 'C:\Program Files\Tencent\QQNT\QQ.exe'
$existing = @(Get-Process QQ -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Write-Host "Launching probe instance (--force-renderer-accessibility)..." -ForegroundColor Yellow
[void](Start-Process -FilePath $exe -ArgumentList @('--force-renderer-accessibility') -PassThru)
Start-Sleep -Seconds 40

$newPids = @(Get-Process QQ -ErrorAction SilentlyContinue | Where-Object { $existing -notcontains $_.Id } | Select-Object -ExpandProperty Id)
Write-Host "test pids: $($newPids -join ', ')"

$wins = New-Object System.Collections.ArrayList
$cb = [CWin2+EnumProc]{
  param($h, $p2)
  if ($newPids -contains [CWin2]::WinPid($h) -and [CWin2]::IsWindowVisible($h) -and ([CWin2]::Cls($h) -eq 'Chrome_WidgetWin_1')) {
    $r = New-Object CWin2+RECT; [void][CWin2]::GetWindowRect($h, [ref]$r)
    if (($r.Right - $r.Left) -gt 200) {
      [void]$wins.Add([pscustomobject]@{ Hwnd = $h; Title = [CWin2]::Text($h); W = $r.Right - $r.Left; H = $r.Bottom - $r.Top })
    }
  }
  return $true
}
[void][CWin2]::EnumWindows($cb, [IntPtr]::Zero)
Write-Host "visible QQ windows found: $($wins.Count)"
$wins | Format-Table Hwnd, Title, W, H -AutoSize

try {
  foreach ($w in ($wins | Sort-Object W -Descending)) {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    Write-Host "`n################ hwnd=$($w.Hwnd) title=`"$($w.Title)`" size=$($w.W)x$($w.H)  NODES=$($all.Count) ################" -ForegroundColor Magenta
    if ($all.Count -le 20) { continue }

    $byType = @{}
    $byPat = @{}
    $patSample = @{}
    foreach ($e in $all) {
      $t = $e.Current.ControlType.ProgrammaticName.Replace('ControlType.','')
      if ($byType.ContainsKey($t)) { $byType[$t]++ } else { $byType[$t] = 1 }
      $got = Get-Patterns -el $e
      foreach ($k in $got.Keys) {
        if ($byPat.ContainsKey($k)) { $byPat[$k]++ } else { $byPat[$k] = 1 }
        if (-not $patSample.ContainsKey($k)) {
          $patSample[$k] = "{0} `"{1}`" cls={2}" -f $t, $e.Current.Name, $e.Current.ClassName
        }
      }
    }
    Write-Host "Control types: " ((($byType.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')) -ForegroundColor Green
    Write-Host "Patterns (count) :" -ForegroundColor Cyan
    foreach ($k in $byPat.Keys) { Write-Host ("   {0,-18} {1,4}  e.g. {2}" -f $k, $byPat[$k], $patSample[$k]) }

    Write-Host "`n-- Edit / input elements --" -ForegroundColor Cyan
    foreach ($e in $all) {
      if ($e.Current.ControlType.ProgrammaticName -match 'Edit') {
        $got = Get-Patterns -el $e
        $val = ''; $ro = ''
        if ($got.ContainsKey('Value')) { try { $val = $got['Value'].Current.Value; $ro = $got['Value'].Current.IsReadOnly } catch {} }
        Write-Host ("   [{0}] cls={1} name=`"{2}`" patterns={3} readOnly={4} value=`"{5}`"" -f `
          $e.Current.ControlType.ProgrammaticName.Replace('ControlType.',''), $e.Current.ClassName, $e.Current.Name, (($got.Keys) -join '+'), $ro, $val) -ForegroundColor Yellow
        try { Write-Host ("      IsEnabled={0} IsKeyboardFocusable={1}" -f $e.Current.IsEnabled, $e.Current.IsKeyboardFocusable) } catch {}
      }
    }

    Write-Host "`n-- Document text (message area readable?) --" -ForegroundColor Cyan
    foreach ($e in $all) {
      if ($e.Current.ControlType.ProgrammaticName -notmatch 'Document') { continue }
      $got = Get-Patterns -el $e
      Write-Host ("   [Document] cls=`"{0}`" name=`"{1}`" patterns={2}" -f $e.Current.ClassName, $e.Current.Name, (($got.Keys) -join '+'))
      if ($got.ContainsKey('Text')) {
        try {
          $dt = $got['Text'].DocumentRange.GetText(300)
          $dt = ($dt -replace "`r?`n", ' ⏎ ')
          Write-Host ("      documentRange text (300 chars): `"{0}`"" -f $dt) -ForegroundColor Green
        } catch { Write-Host "      GetText failed: $($_.Exception.Message)" }
      }
    }

    Write-Host "`n-- Sample of named elements (32) --" -ForegroundColor Cyan
    $all | Where-Object { $_.Current.Name -ne '' } | Select-Object -First 32 | ForEach-Object {
      $t = $_.Current.ControlType.ProgrammaticName.Replace('ControlType.','')
      $nm = $_.Current.Name; if ($nm.Length -gt 62) { $nm = $nm.Substring(0,62) + '...' }
      $g = Get-Patterns -el $_
      Write-Host ("   [{0,-9}] `"{1}`" cls={2}  [{3}]" -f $t, $nm, $_.Current.ClassName, (($g.Keys) -join ','))
    }
  }
} finally {
  Write-Host "`n=== cleanup ===" -ForegroundColor Cyan
  foreach ($pp in $newPids) { try { Stop-Process -Id $pp -Force -ErrorAction Stop } catch {} }
  Start-Sleep -Seconds 3
  $left = @(Get-Process QQ -ErrorAction SilentlyContinue | Where-Object { $existing -notcontains $_.Id } | ForEach-Object { $_.Id })
  Write-Host ("  surviving test pids: [{0}]" -f ($left -join ', '))
}
