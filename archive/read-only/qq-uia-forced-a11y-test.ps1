Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase

$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class TWin {
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
if (-not ('TWin' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp }

$exe = 'D:\QQ\QQ.exe'
$existingPids = @(Get-Process QQ -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

Write-Host "=== BEFORE: QQ pids = $($existingPids -join ', ') ===" -ForegroundColor Cyan

$launchArgs = @('--force-renderer-accessibility')
Write-Host "Launching: $exe $($launchArgs -join ' ')" -ForegroundColor Yellow
$p = Start-Process -FilePath $exe -ArgumentList $launchArgs -PassThru
Write-Host "started launcher pid=$($p.Id); waiting 45s for startup..." -ForegroundColor Yellow
Start-Sleep -Seconds 45

$newPids = @(Get-Process QQ -ErrorAction SilentlyContinue | Where-Object { $existingPids -notcontains $_.Id } | Select-Object -ExpandProperty Id)
Write-Host "NEW QQ pids: $($newPids -join ', ')" -ForegroundColor Cyan

# collect new top-level windows
$newWins = New-Object System.Collections.ArrayList
$cb = [TWin+EnumProc]{
  param($h, $p2)
  $wpid = [TWin]::WinPid($h)
  if ($newPids -contains $wpid) {
    if ([TWin]::IsWindowVisible($h)) {
      $r = New-Object TWin+RECT
      [void][TWin]::GetWindowRect($h, [ref]$r)
      [void]$newWins.Add([pscustomobject]@{
        Hwnd = $h; Pid = $wpid; Class = [TWin]::Cls($h); Title = [TWin]::Text($h)
        W = $r.Right - $r.Left; H = $r.Bottom - $r.Top; X = $r.Left; Y = $r.Top
      })
    }
  }
  return $true
}
[void][TWin]::EnumWindows($cb, [IntPtr]::Zero)

Write-Host "`nNew visible top-level windows:" -ForegroundColor Green
$newWins | Sort-Object W -Descending | Format-Table Pid, Hwnd, Class, W, H, X, Y, Title -AutoSize

Write-Host "`n=== UIA content inspection of each new window ===" -ForegroundColor Cyan
foreach ($w in ($newWins | Sort-Object W -Descending)) {
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
    $all = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    Write-Host ("`n--- hwnd {0} pid {1} `"{2}`" {3}x{4}: {5} descendants ---" -f $w.Hwnd, $w.Pid, $w.Title, $w.W, $w.H, $all.Count) -ForegroundColor Yellow
    $shown = 0
    foreach ($d in $all) {
      if ($shown -ge 45) { Write-Host "    ... (truncated)"; break }
      $shown++
      $r = $d.Current.BoundingRectangle
      $rw = if ([double]::IsInfinity($r.Width)) { 'inf' } else { [string][int]$r.Width }
      $rh = if ([double]::IsInfinity($r.Height)) { 'inf' } else { [string][int]$r.Height }
      $nm = $d.Current.Name; if ($nm.Length -gt 60) { $nm = $nm.Substring(0,60) + '...' }
      Write-Host ("    [{0}] `"{1}`" cls={2} {3}x{4}" -f $d.Current.ControlType.ProgrammaticName.Replace('ControlType.',''), $nm, $d.Current.ClassName, $rw, $rh)
    }
  } catch { Write-Host ("    error: {0}" -f $_.Exception.Message) -ForegroundColor Red }
}

Write-Host "`n=== cleanup: terminating test instance ===" -ForegroundColor Cyan
foreach ($wpid in $newPids) {
  try { Stop-Process -Id $wpid -Force -ErrorAction Stop; Write-Host "  killed pid $wpid" } catch { Write-Host "  could not kill $wpid : $($_.Exception.Message)" }
}

