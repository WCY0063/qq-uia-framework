Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase

$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class A11yWin {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr wp, IntPtr lp, uint flags, uint timeout, out IntPtr res);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowLongW(IntPtr h, int idx);
  // WM_GETOBJECT = 0x003D ; OBJID_CLIENT = 0xFFFFFFFC ; SMTO_ABORTIFHUNG = 0x0002
  public static string Text(IntPtr h){ var sb=new StringBuilder(512); GetWindowTextW(h,sb,512); return sb.ToString(); }
  public static string Cls(IntPtr h){ var sb=new StringBuilder(512); GetClassNameW(h,sb,512); return sb.ToString(); }
  public static uint WinPid(IntPtr h){ uint p; GetWindowThreadProcessId(h, out p); return p; }
  public static IntPtr QueryAccessibleObject(IntPtr hwnd, uint timeoutMs){
    IntPtr res = IntPtr.Zero;
    uint r = (uint)SendMessageTimeoutW(hwnd, 0x003D, IntPtr.Zero, (IntPtr)(-4), 0x0002, timeoutMs, out res);
    if (r == 0) return IntPtr.Zero;
    return res;
  }
  public static string LastError(){ return Marshal.GetLastWin32Error().ToString(); }
}
'@
if (-not ('A11yWin' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp }

$targets = @(
  @{ Pid = 11004; Hwnd = 18681668; Label = 'A: main visible "QQ" 680x440 (pid 11004)' },
  @{ Pid = 72440; Hwnd = 397664;  Label = 'B: visible "QQ" 158x26 offscreen (pid 72440)' },
  @{ Pid = 72440; Hwnd = 1774836; Label = 'C: hidden "QQ" 800x600 (pid 72440)' }
)

function Count-Tree {
  param($el, [int]$maxDepth = 6)
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $count = 0
  $types = @{}
  $queue = New-Object System.Collections.Queue
  $queue.Enqueue(@($el, 0))
  while ($queue.Count -gt 0 -and $count -lt 3000) {
    $item = $queue.Dequeue(); $node = $item[0]; $d = $item[1]
    $count++
    try {
      $t = $node.Current.ControlType.ProgrammaticName.Replace('ControlType.', '')
      if ($types.ContainsKey($t)) { $types[$t]++ } else { $types[$t] = 1 }
    } catch {}
    if ($d -ge $maxDepth) { continue }
    try {
      $c = $walker.GetFirstChild($node)
      while ($c -ne $null) { $queue.Enqueue(@($c, $d + 1)); $c = $walker.GetNextSibling($c) }
    } catch {}
  }
  return [pscustomobject]@{ Count = $count; Types = $types }
}

foreach ($t in $targets) {
  Write-Host "`n================ $($t.Label) ================" -ForegroundColor Cyan
  $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $t.Pid)
  $wins = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
  Write-Host ("UIA top-level children for pid {0}: {1}" -f $t.Pid, $wins.Count)
  foreach ($w in $wins) {
    $r = $w.Current.BoundingRectangle
    Write-Host ("   - `"{0}`" cls={1} rect=({2},{3},{4},{5})" -f $w.Current.Name, $w.Current.ClassName, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)
  }

  # BEFORE
  $hwnd = [IntPtr]$t.Hwnd
  $el0 = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $before = Count-Tree -el $el0 -maxDepth 5
  Write-Host ("BEFORE: control-view nodes(depth<=5) = {0}" -f $before.Count) -ForegroundColor Green
  Write-Host ("        types: {0}" -f (($before.Types.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))

  # poke the renderer for its accessibility object (WM_GETOBJECT / OBJID_CLIENT)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $acc = [A11yWin]::QueryAccessibleObject($hwnd, 3000)
  $sw.Stop()
  Write-Host ("WM_GETOBJECT(OBJID_CLIENT) -> returned={0} in {1} ms (err={2})" -f $acc, $sw.ElapsedMilliseconds, [A11yWin]::LastError())

  Start-Sleep -Milliseconds 1500
  $el1 = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $after = Count-Tree -el $el1 -maxDepth 5
  Write-Host ("AFTER : control-view nodes(depth<=5) = {0}" -f $after.Count) -ForegroundColor Green
  Write-Host ("        types: {0}" -f (($after.Types.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
}
