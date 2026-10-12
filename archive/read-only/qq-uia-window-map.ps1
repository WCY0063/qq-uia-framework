Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase

$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WEnum {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public static string Text(IntPtr h){ var sb=new StringBuilder(512); GetWindowTextW(h,sb,512); return sb.ToString(); }
  public static string Cls(IntPtr h){ var sb=new StringBuilder(512); GetClassNameW(h,sb,512); return sb.ToString(); }
  public static uint WinPid(IntPtr h){ uint p; GetWindowThreadProcessId(h, out p); return p; }
}
'@
if (-not ('WEnum' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp }

Write-Host "=== renderer processes and their HWNDs (renderers own the web content) ===" -ForegroundColor Cyan
$renderers = Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" |
  Where-Object { $_.CommandLine -match '--type=renderer' } |
  Select-Object -ExpandProperty ProcessId

$tree = @{}
$cb = [WEnum+EnumProc]{
  param($h, $p)
  $pw = [WEnum]::WinPid($h)
  if (-not $tree.ContainsKey($pw)) { $tree[$pw] = New-Object System.Collections.ArrayList }
  $r = New-Object WEnum+RECT
  [void][WEnum]::GetWindowRect($h, [ref]$r)
  [void]$tree[$pw].Add([pscustomobject]@{
    Hwnd = $h; Class = [WEnum]::Cls($h); Title = [WEnum]::Text($h)
    Vis = [WEnum]::IsWindowVisible($h); W = $r.Right - $r.Left; H = $r.Bottom - $r.Top
    X = $r.Left; Y = $r.Top
  })
  return $true
}
[void][WEnum]::EnumWindows($cb, [IntPtr]::Zero)

foreach ($pidx in $renderers) {
  $w = $tree[$pidx]
  if ($w) {
    "PID $pidx :"
    $w | Where-Object { $_.Class -notmatch 'IME|MSCTF|PowerMessage' } |
      Format-Table Hwnd, Class, Vis, W, H, X, Y, Title -AutoSize
  } else {
    "PID $pidx : (no top-level HWND - renders into parent's HWND)"
  }
}

Write-Host "`n=== UIA tree saturation test on VISIBLE main window (pid 11004 / hwnd 18681668) ===" -ForegroundColor Cyan
$el = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]18681668)
$all = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants,
  [System.Windows.Automation.Condition]::TrueCondition)
Write-Host ("Descendants (raw view) total = {0}" -f $all.Count)
$el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Select-Object -First 40 | ForEach-Object {
  $r = $_.Current.BoundingRectangle
  "   [{0}] `"{1}`" cls={2} rect=({3},{4},{5},{6})" -f $_.Current.ControlType.ProgrammaticName.Replace('ControlType.',''), $_.Current.Name, $_.Current.ClassName, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height
}

Write-Host "`n=== Same test on pid 72440 window 397664 (visible offscreen 'QQ') ===" -ForegroundColor Cyan
$el2 = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]397664)
$a2 = $el2.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
Write-Host ("Descendants total = {0}" -f $a2.Count)
$a2 | Select-Object -First 40 | ForEach-Object {
  $r = $_.Current.BoundingRectangle
  "   [{0}] `"{1}`" cls={2} rect=({3},{4},{5},{6})" -f $_.Current.ControlType.ProgrammaticName.Replace('ControlType.',''), $_.Current.Name, $_.Current.ClassName, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height
}

Write-Host "`n=== Global UIA inventory: all Chromium/Electron windows on the desktop ===" -ForegroundColor Cyan
[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
  $p = Get-Process -Id $_.Current.ProcessId -ErrorAction SilentlyContinue
  if ($_.Current.ClassName -match 'Chrome_WidgetWin') {
    $d = $_.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition).Count
    "   {0,-30} pid={1,-6} win=`"{2}`" descendants={3}" -f $_.Current.ClassName, $_.Current.ProcessId, $_.Current.Name, $d
  }
}
