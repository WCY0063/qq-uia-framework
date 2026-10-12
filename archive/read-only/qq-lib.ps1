# Shared UIA helpers for QQ automation. Dot-source this file.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$script:UiaSrc = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class QqWin {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public static string Text(IntPtr h){ var sb=new StringBuilder(512); GetWindowTextW(h,sb,512); return sb.ToString(); }
  public static string Cls(IntPtr h){ var sb=new StringBuilder(512); GetClassNameW(h,sb,512); return sb.ToString(); }
  public static uint WinPid(IntPtr h){ uint p; GetWindowThreadProcessId(h, out p); return p; }
}
'@
if (-not ('QqWin' -as [type])) { Add-Type -TypeDefinition $script:UiaSrc -Language CSharp }

function Get-QqWindows {
  $list = New-Object System.Collections.ArrayList
  $cb = [QqWin+EnumProc]{
    param($h, $p)
    $pr = Get-Process -Id ([QqWin]::WinPid($h)) -ErrorAction SilentlyContinue
    if ($pr -and $pr.ProcessName -eq 'QQ' -and [QqWin]::IsWindowVisible($h) -and ([QqWin]::Cls($h) -eq 'Chrome_WidgetWin_1')) {
      $r = New-Object QqWin+RECT; [void][QqWin]::GetWindowRect($h, [ref]$r)
      if (($r.Right - $r.Left) -gt 150) {
        [void]$list.Add([pscustomobject]@{ Hwnd = $h; Pid = [QqWin]::WinPid($h); Title = [QqWin]::Text($h)
          W = $r.Right-$r.Left; H = $r.Bottom-$r.Top; X = $r.Left; Y = $r.Top })
      }
    }
    return $true
  }
  [void][QqWin]::EnumWindows($cb, [IntPtr]::Zero)
  return $list
}

function Get-El {
  param($Root, [string]$ClassRegex, [string]$TypeRegex = '', [int]$Index = 0)
  $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $hits = @($all | Where-Object {
    ($_.Current.ClassName -match $ClassRegex) -and ($TypeRegex -eq '' -or $_.Current.ControlType.ProgrammaticName -match $TypeRegex)
  })
  if ($hits.Count -eq 0) { return $null }
  return $hits[[Math]::Min($Index, $hits.Count - 1)]
}

function Get-RectOf { param($El) $r = $El.Current.BoundingRectangle; return @{ X = [int]$r.X; Y = [int]$r.Y; W = [int]$r.Width; H = [int]$r.Height; CX = [int]($r.X + $r.Width/2); CY = [int]($r.Y + $r.Height/2) } }

function Get-AllNamed {
  param($Root, [string]$NameRegex)
  $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  return @($all | Where-Object { $_.Current.Name -match $NameRegex })
}

function Focus-Window {
  param([IntPtr]$Hwnd)
  if ([QqWin]::IsIconic($Hwnd)) { [void][QqWin]::ShowWindow($Hwnd, 9) }  # SW_RESTORE
  [void][QqWin]::ShowWindow($Hwnd, 5)                                   # SW_SHOW
  $ok = [QqWin]::SetForegroundWindow($Hwnd)
  Start-Sleep -Milliseconds 600
  return $ok
}
