# Definitive experiment: compare UIA visibility of a COLD QQNT launch with vs without the
# standard Chromium switch --force-renderer-accessibility. Both test instances are temporary.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class ExpWin {
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
if (-not ('ExpWin' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp }

function Measure-QqInstance {
  param([string]$Label, [string]$Switch, [int[]]$BaselinePids)

  Write-Host "`n==================== $Label ====================" -ForegroundColor Magenta
  Write-Host ("switch: '{0}'" -f $Switch)

  if ($Switch) { [void](Start-Process -FilePath 'D:\QQ\QQ.exe' -ArgumentList @($Switch) -PassThru) }
  else { [void](Start-Process -FilePath 'D:\QQ\QQ.exe' -PassThru) }

  $newPids = @()
  $deadline = (Get-Date).AddSeconds(100)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $newPids = @(Get-Process QQ -ErrorAction SilentlyContinue | Where-Object { $BaselinePids -notcontains $_.Id } | Select-Object -ExpandProperty Id)
    $anyWin = $false
    foreach ($p in $newPids) { $pr = Get-Process -Id $p -ErrorAction SilentlyContinue; if ($pr -and $pr.MainWindowHandle -ne 0) { $anyWin = $true; break } }
    if ($anyWin) { break }
  }
  Start-Sleep -Seconds 3
  $newPids = @(Get-Process QQ -ErrorAction SilentlyContinue | Where-Object { $BaselinePids -notcontains $_.Id } | Select-Object -ExpandProperty Id)
  Write-Host ("new pids ({0}): {1}" -f $newPids.Count, ($newPids -join ', '))

  $wins = New-Object System.Collections.ArrayList
  $cb = [ExpWin+EnumProc]{
    param($h, $p2)
    if ($newPids -contains [ExpWin]::WinPid($h) -and [ExpWin]::IsWindowVisible($h) -and ([ExpWin]::Cls($h) -eq 'Chrome_WidgetWin_1')) {
      $r = New-Object ExpWin+RECT; [void][ExpWin]::GetWindowRect($h, [ref]$r)
      if (($r.Right - $r.Left) -gt 200) {
        [void]$wins.Add([pscustomobject]@{ Hwnd = $h; Pid = [ExpWin]::WinPid($h); Title = [ExpWin]::Text($h); W = $r.Right - $r.Left; H = $r.Bottom - $r.Top })
      }
    }
    return $true
  }
  [void][ExpWin]::EnumWindows($cb, [IntPtr]::Zero)
  Write-Host ("visible QQ windows for test instance: {0}" -f $wins.Count)

  $out = @()
  foreach ($w in ($wins | Sort-Object W -Descending)) {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
    $a1 = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    Start-Sleep -Seconds 6
    $el2 = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
    $a2 = $el2.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $named = @($a2 | Where-Object { $_.Current.Name -ne '' }).Count
    $edits = @($a2 | Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Edit' }).Count
    $docs = @($a2 | Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Document' }).Count
    $btns = @($a2 | Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Button' }).Count
    Write-Host ("  win `"{0}`" pid={1} {2}x{3}: first={4} settled={5} named={6} Button={7} Edit={8} Document={9}" -f `
      $w.Title, $w.Pid, $w.W, $w.H, $a1.Count, $a2.Count, $named, $btns, $edits, $docs) -ForegroundColor Green
    $out += [pscustomobject]@{ Scenario = $Label; Descendants = $a2.Count; Named = $named; Buttons = $btns; Edit = $edits; Document = $docs }
  }

  Write-Host "cleanup:" -ForegroundColor Cyan
  foreach ($pp in $newPids) { try { Stop-Process -Id $pp -Force -ErrorAction Stop } catch {} }
  Start-Sleep -Seconds 5
  $left = @(Get-Process QQ -ErrorAction SilentlyContinue | Where-Object { $newPids -contains $_.Id } | ForEach-Object { $_.Id })
  Write-Host ("  surviving test pids: [{0}]" -f ($left -join ', '))
  return $out
}

$baseline = @(Get-Process QQ -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Write-Host "baseline QQ pids ($($baseline.Count)): $($baseline -join ', ')"

$r1 = Measure-QqInstance -Label 'A: COLD LAUNCH, NO SWITCH' -Switch '' -BaselinePids $baseline
$r2 = Measure-QqInstance -Label 'B: COLD LAUNCH + --force-renderer-accessibility' -Switch '--force-renderer-accessibility' -BaselinePids $baseline

Write-Host "`n==================== SUMMARY ====================" -ForegroundColor Magenta
$r1 + $r2 | Format-Table -AutoSize
$alive = @(Get-Process QQ -ErrorAction SilentlyContinue | Where-Object { $baseline -contains $_.Id }).Count
Write-Host "baseline restored: $alive/$($baseline.Count) original pids alive"
