param(
  [int]$TargetPid = 72440,
  [int]$MaxDepth = 8,
  [int]$MaxNodes = 400,
  [switch]$IncludeAll,
  [string]$PidFilter = 'QQ.exe'
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase

$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class QQWin {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public static string Text(IntPtr h){ var sb=new StringBuilder(512); GetWindowTextW(h,sb,512); return sb.ToString(); }
  public static string Cls(IntPtr h){ var sb=new StringBuilder(512); GetClassNameW(h,sb,512); return sb.ToString(); }
}
'@
if (-not ('QQWin' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp }

function Get-TopWindows {
  param([string]$NameMatch = 'QQ')
  $list = New-Object System.Collections.ArrayList
  $cb = [QQWin+EnumProc]{
    param($h, $p)
    $pid2 = 0
    [void][QQWin]::GetWindowThreadProcessId($h, [ref]$pid2)
    $proc = Get-Process -Id $pid2 -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -match $NameMatch) {
      $r = New-Object QQWin+RECT
      [void][QQWin]::GetWindowRect($h, [ref]$r)
      [void]$list.Add([pscustomobject]@{
        Hwnd    = $h
        Pid     = $pid2
        Proc    = $proc.ProcessName
        Class   = [QQWin]::Cls($h)
        Title   = [QQWin]::Text($h)
        Visible = [QQWin]::IsWindowVisible($h)
        W       = $r.Right - $r.Left
        H       = $r.Bottom - $r.Top
        X       = $r.Left
        Y       = $r.Top
      })
    }
    return $true
  }
  [void][QQWin]::EnumWindows($cb, [IntPtr]::Zero)
  return $list
}

if ($TargetPid -eq 0) {
  Write-Host "=== TOP-LEVEL WINDOWS ($PidFilter) ===" -ForegroundColor Cyan
  Get-TopWindows -NameMatch ([System.IO.Path]::GetFileNameWithoutExtension($PidFilter)) |
    Sort-Object Pid, X | Format-Table Pid, Hwnd, Class, Visible, W, H, X, Y, Title -AutoSize
  return
}

Write-Host "=== UIA PROBE (pid $TargetPid) ===" -ForegroundColor Cyan
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $TargetPid)
$wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
Write-Host ("top-level UIA windows for pid {0}: {1}" -f $TargetPid, $wins.Count)

$view = if ($IncludeAll) { [System.Windows.Automation.TreeWalker]::RawViewWalker } else { [System.Windows.Automation.TreeWalker]::ControlViewWalker }
$script:nodeCount = 0
$script:maxNodes = $MaxNodes

function Dump-Uia {
  param($el, [int]$depth)
  if ($script:nodeCount -ge $script:maxNodes) { return }
  if ($depth -gt $MaxDepth) { return }
  $script:nodeCount++
  $ci = $el.Current
  $rect = $ci.BoundingRectangle
  $pats = @()
  $val = ''
  try { $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); $val = $vp.Current.Value; $pats += 'Value' } catch {}
  try { $ip = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern); $pats += 'Invoke' } catch {}
  try { $tp = $el.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern); $pats += 'Text' } catch {}
  try { $sp = $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern); $pats += 'SelItem' } catch {}
  try { $ep = $el.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern); $pats += 'Expand' } catch {}
  try { $lp = $el.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern); $pats += 'Legacy' } catch {}
  $pad = ' ' * ($depth * 2)
  $name = $ci.Name
  if ($name.Length -gt 90) { $name = $name.Substring(0, 90) + '...' }
  Write-Host ("{0}[{1}] `"{2}`"  cls=`"{3}`"  rect=({4},{5},{6},{7})  pats={8} val=`"{9}`"" -f `
      $pad, $ci.ControlType.ProgrammaticName.Replace('ControlType.',''), $name, $ci.ClassName,
      [int]$rect.X, [int]$rect.Y, [int]$rect.Width, [int]$rect.Height, ($pats -join '+'), $val)
  $child = $view.GetFirstChild($el)
  while ($child -ne $null -and $script:nodeCount -lt $script:maxNodes) {
    Dump-Uia -el $child -depth ($depth + 1)
    $child = $view.GetNextSibling($child)
  }
  if ($child -ne $null) { Write-Host ("{0}... TRUNCATED at {1} nodes" -f $pad, $script:maxNodes) }
}

$i = 0
foreach ($w in $wins) {
  $i++
  $ci = $w.Current
  $r = $ci.BoundingRectangle
  Write-Host ("`n--- window {0}/{1}: `"{2}`" pid={3} cls=`"{4}`" rect=({5},{6},{7},{8}) ---" -f `
      $i, $wins.Count, $ci.Name, $ci.ProcessId, $ci.ClassName, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height) -ForegroundColor Yellow
  $script:nodeCount = 0
  Dump-Uia -el $w -depth 0
  Write-Host ("  (nodes visited: {0})" -f $script:nodeCount)
}

