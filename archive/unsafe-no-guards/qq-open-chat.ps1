# Step A: bring the 閰掔嫄 instance forward, drive its search, open the target chat.
# Types no message. ASCII-only source.
param([int]$SenderPid = 86324, [string]$TargetId = '987654321', [switch]$NoEnter)

. (Join-Path $PSScriptRoot 'qq-lib.ps1')
Add-Type -AssemblyName System.Windows.Forms

function Show-Fg { $h = [QqWin]::GetForegroundWindow(); return ("{0} ('{1}')" -f $h, [QqWin]::Text($h)) }

$w = Get-QqWindows | Where-Object { $_.Pid -eq $SenderPid } | Select-Object -First 1
if (-not $w) { Write-Host "no visible QQ window for pid $SenderPid" -ForegroundColor Red; exit 1 }
$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
Write-Host ("sender window hwnd={0} pid={1} {2}x{3} UIA-rect=({4},{5})" -f $w.Hwnd, $w.Pid, $w.W, $w.H, $w.X, $w.Y) -ForegroundColor Cyan
Write-Host ("foreground BEFORE: " + (Show-Fg))

# ---- robust focus: click the window's title area, then SetForegroundWindow ----
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,int e);' -Name MM -Namespace Qq -ErrorAction SilentlyContinue
function Qq-Click([int]$x, [int]$y) {
  [void][QqWin]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 150
  [Qq.MM]::mouse_event(0x02, 0, 0, 0, 0); [Qq.MM]::mouse_event(0x04, 0, 0, 0, 0)
}
[void][QqWin]::ShowWindow([IntPtr]$w.Hwnd, 9)
[void][QqWin]::SetForegroundWindow([IntPtr]$w.Hwnd)
Start-Sleep -Milliseconds 400
# UIA rects here are 1.5x physical: convert to logical screen coords
$titleX = [int](($w.X + $w.W / 2) / 1.5)
$titleY = [int](($w.Y + 20) / 1.5)
Write-Host ("clicking title bar at logical ({0},{1}) to force activation" -f $titleX, $titleY)
Qq-Click $titleX $titleY
Start-Sleep -Milliseconds 600
Write-Host ("foreground AFTER : " + (Show-Fg))

# ---- locate the search Edit ----
$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$search = @($all | Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Edit' } | Select-Object -First 1)
if (-not $search) { Write-Host 'search Edit not found' -ForegroundColor Red; exit 1 }
$sr = Get-RectOf $search
Write-Host ("search rect (UIA) ({0},{1}) {2}x{3} -> logical click ({4},{5})" -f $sr.X, $sr.Y, $sr.W, $sr.H, [int]($sr.CX/1.5), [int]($sr.CY/1.5))
Qq-Click ([int]($sr.CX/1.5)) ([int]($sr.CY/1.5))
Start-Sleep -Milliseconds 500

$search.SetFocus()
Start-Sleep -Milliseconds 300
$vp = $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
$vp.SetValue($TargetId)
Start-Sleep -Milliseconds 1200
Write-Host ("search value now: '{0}'" -f $vp.Current.Value) -ForegroundColor Yellow

$focused = [System.Windows.Automation.AutomationElement]::FocusedElement
Write-Host ("UIA focused element: [{0}] cls='{1}' name='{2}'" -f $focused.Current.ControlType.ProgrammaticName, $focused.Current.ClassName, $focused.Current.Name)

function Snapshot([string]$stage) {
  $a = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  Write-Host ("`n===== [$stage] nodes={0} =====" -f $a.Count) -ForegroundColor Magenta
  $a | Where-Object { $_.Current.Name -ne '' -and ($_.Current.ClassName -match 'search|result|list-item|user|friend|contact-item|panel' -or $_.Current.Name -match [regex]::Escape($TargetId)) } |
    Select-Object -First 40 | ForEach-Object {
      $ty = $_.Current.ControlType.ProgrammaticName.Replace('ControlType.','')
      Write-Host ("   [{0,-9}] cls='{1}' name='{2}'" -f $ty, $_.Current.ClassName, $_.Current.Name)
    }
  return $a
}

$null = Snapshot 'after SetValue (pre-Enter)'

if (-not $NoEnter) {
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Write-Host 'sent ENTER'
  Start-Sleep -Seconds 3
  $a2 = Snapshot 'after ENTER'
  Write-Host ("`nnew top-level UIA windows across desktop (search panel may be a separate window):")
  foreach ($qw in (Get-QqWindows)) { Write-Host ("   hwnd={0} pid={1} {2}x{3} title='{4}'" -f $qw.Hwnd, $qw.Pid, $qw.W, $qw.H, $qw.Title) }
}
