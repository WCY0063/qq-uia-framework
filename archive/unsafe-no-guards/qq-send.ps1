# UIA end-to-end send test: account 123456789 (nickname 渐行渐远, pid 11004) -> 987654321
# ASCII-only source. Prints every step; aborts if any verification fails.
param(
  [string]$TargetId = '987654321',
  [string]$Message  = '',
  [string]$ExpectNick = '',      # nickname to expect on the opened chat header
  [switch]$NoSend
)
. "$PSScriptRoot\..\read-only\qq-lib.ps1"
Add-Type -AssemblyName System.Windows.Forms

if ($Message -eq '') { $Message = [string]([char]0x65E9 + [char]0x4E0A + [char]0x597D + [char]0xFF0C + [char]0x4E3B + [char]0x4EBA + [char]0x3002) }  # morning, master.

Write-Host ("message to send: '{0}' ({1} chars)" -f $Message, $Message.Length) -ForegroundColor Yellow

function Stop-With([string]$why) { Write-Host "ABORT: $why" -ForegroundColor Red; exit 1 }

# ---------- 1. pick the sender window (largest visible QQ window = main instance) ----------
$w = Get-QqWindows | Sort-Object W -Descending | Select-Object -First 1
if (-not $w) { Stop-With 'no visible QQ window' }
Write-Host ("sender window: hwnd={0} pid={1} {2}x{3} at ({4},{5})" -f $w.Hwnd, $w.Pid, $w.W, $w.H, $w.X, $w.Y) -ForegroundColor Cyan
$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)

# ---------- 2. verify account ----------
$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$avatar = @($all | Where-Object { $_.Current.ClassName -match 'user-avatar' } | Select-Object -First 1)
$sig = @($all | Where-Object { $_.Current.ClassName -match 'profile_signature' } | Select-Object -First 1)
$nickText = @($all | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.Text' -and $_.Current.Name -ne '' } | Select-Object -First 1)
Write-Host ("account avatar name : '{0}'" -f $(if ($avatar) { $avatar.Current.Name } else { '<none>' }))
Write-Host ("account signature   : '{0}'" -f $(if ($sig) { $sig.Current.Name } else { '<none>' }))
Write-Host ("account nickname    : '{0}'" -f $(if ($nickText) { $nickText.Current.Name } else { '<none>' }))

# ---------- 3. bring window to front ----------
$fg = Focus-Window -Hwnd ([IntPtr]$w.Hwnd)
Write-Host ("SetForegroundWindow ok={0}; icon? {1}" -f $fg, [QqWin]::IsIconic([IntPtr]$w.Hwnd))
Start-Sleep -Milliseconds 500

# ---------- 4. drive the global search box (real Edit -> ValuePattern) ----------
$search = $null
foreach ($e in $all) { if ($e.Current.ControlType.ProgrammaticName -match 'Edit') { $search = $e; break } }
if (-not $search) { Stop-With 'search Edit not found' }
$vp = $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
Write-Host ("search box: name='{0}' current='{1}'" -f $search.Current.Name, $vp.Current.Value) -ForegroundColor Cyan

$search.SetFocus()
Start-Sleep -Milliseconds 300
$vp.SetValue($TargetId)
Start-Sleep -Seconds 1
Write-Host ("after SetValue -> '{0}'" -f $vp.Current.Value)

# Enter to run the search
[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
Write-Host 'sent ENTER to run search; waiting for results...'
Start-Sleep -Seconds 3

# ---------- 5. collect result rows ----------
$all2 = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$cands = @($all2 | Where-Object {
  $_.Current.IsKeyboardFocusable -or ($_.Current.ClassName -match 'search|result|contact|friend|item') -or ($_.Current.Name -match [regex]::Escape($TargetId))
})
Write-Host ("nodes mentioning target or looking like result rows: {0}" -f $cands.Count) -ForegroundColor Cyan
$cands | Select-Object -First 25 | ForEach-Object {
  $ty = $_.Current.ControlType.ProgrammaticName.Replace('ControlType.', '')
  Write-Host ("   [{0,-9}] cls='{1}' name='{2}' focusable={3}" -f $ty, $_.Current.ClassName, $_.Current.Name, $_.Current.IsKeyboardFocusable)
}

# ---------- 6. try to open the matching row ----------
$row = @($all2 | Where-Object { $_.Current.Name -match ('^' + [regex]::Escape($TargetId) + '$') -or $_.Current.Name -match ('[^0-9]' + [regex]::Escape($TargetId) + '[^0-9]') } | Select-Object -First 1)
if (-not $row) {
  Write-Host 'no exact node carrying the QQ number; showing all named nodes that appeared after search:' -ForegroundColor Yellow
  $all2 | Where-Object { $_.Current.Name -ne '' } | Select-Object -First 40 | ForEach-Object {
    $ty = $_.Current.ControlType.ProgrammaticName.Replace('ControlType.', '')
    Write-Host ("   [{0,-9}] cls='{1}' name='{2}'" -f $ty, $_.Current.ClassName, $_.Current.Name)
  }
  Stop-With 'could not identify a result row for the target number'
}
Write-Host ("result row: [{0}] cls='{1}' name='{2}'" -f $row.Current.ControlType.ProgrammaticName, $row.Current.ClassName, $row.Current.Name) -ForegroundColor Green

# prefer Invoke, else click its center with the mouse
$opened = $false
try {
  $ip = $row.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  $ip.Invoke(); $opened = $true; Write-Host 'InvokePattern.Invoke() on result row succeeded'
} catch {
  Write-Host ("Invoke unavailable ({0}); falling back to a real mouse click" -f $_.Exception.Message)
  $r = Get-RectOf $row
  Write-Host ("   clicking at ({0},{1})" -f $r.CX, $r.CY)
  [void][QqWin]::SetCursorPos($r.CX, $r.CY)
  Start-Sleep -Milliseconds 200
  Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,int e);' -Name M -Namespace Q -ErrorAction SilentlyContinue
  [Q.M]::mouse_event(0x02, 0, 0, 0, 0); [Q.M]::mouse_event(0x04, 0, 0, 0, 0)
  $opened = $true
}
Start-Sleep -Seconds 3

# ---------- 7. verify the opened chat ----------
$all3 = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$hdr = @($all3 | Where-Object { $_.Current.ClassName -match 'chat-header__contact-name' } | Select-Object -First 1)
$hdrName = if ($hdr) { $hdr.Current.Name } else { '<none>' }
Write-Host ("opened chat header: '{0}'" -f $hdrName) -ForegroundColor Green
if ($ExpectNick -ne '' -and $hdrName -notmatch [regex]::Escape($ExpectNick)) { Stop-With "header '$hdrName' does not match expected '$ExpectNick'" }

$editor = @($all3 | Where-Object { $_.Current.ClassName -match 'ExEditor-qq-msg-editor' } | Select-Object -First 1)
$sendBtn = @($all3 | Where-Object { $_.Current.ClassName -match 'send-msg' } | Select-Object -First 1)
if (-not $editor) { Stop-With 'message editor not found' }
Write-Host ("editor cls='{0}'" -f $editor.Current.ClassName)
Write-Host ("send button cls='{0}'" -f $(if ($sendBtn) { $sendBtn.Current.ClassName } else { '<none>' }))

if ($NoSend) { Write-Host 'NoSend set: stopping before typing.' -ForegroundColor Yellow; exit 0 }

# ---------- 8. focus the editor and type via real keyboard input ----------
$ok = $editor.SetFocus()
Start-Sleep -Milliseconds 400
$focused = [System.Windows.Automation.AutomationElement]::FocusedElement
Write-Host ("SetFocus returned {0}; UIA focused element now: [{1}] cls='{2}'" -f $ok, $focused.Current.ControlType.ProgrammaticName, $focused.Current.ClassName) -ForegroundColor Cyan

# click the editor center too, so ProseMirror really owns focus
$er = Get-RectOf $editor
Write-Host ("editor rect ({0},{1}) {2}x{3} -> click ({4},{5})" -f $er.X, $er.Y, $er.W, $er.H, $er.CX, $er.CY)
if ($er.CX -gt 0 -and $er.CY -gt 0 -and $er.CX -lt 5000 -and $er.CY -lt 5000) {
  [void][QqWin]::SetCursorPos($er.CX, $er.CY)
  Start-Sleep -Milliseconds 150
  try { [Q.M]::mouse_event(0x02, 0, 0, 0, 0); [Q.M]::mouse_event(0x04, 0, 0, 0, 0) } catch {}
  Start-Sleep -Milliseconds 300
}

Write-Host 'typing message via SendInput...' -ForegroundColor Yellow
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.SendKeys]::SendWait($Message)
Start-Sleep -Milliseconds 800

# ---------- 9. verify the editor now holds the text ----------
$all4 = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$editor2 = @($all4 | Where-Object { $_.Current.ClassName -match 'ExEditor-qq-msg-editor' } | Select-Object -First 1)
$txt = ''
if ($editor2) {
  try { $tp = $editor2.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern); $txt = $tp.DocumentRange.GetText(200) } catch { $txt = "<TextPattern failed: $($_.Exception.Message)>" }
  Write-Host ("editor classes now: '{0}'" -f $editor2.Current.ClassName)
}
Write-Host ("editor text now: '{0}'" -f ($txt -replace "`r?`n", ' / ')) -ForegroundColor Yellow
if ($txt -notmatch [regex]::Escape($Message)) { Stop-With 'typed text did not land in the editor' }

$sendBtn2 = @($all4 | Where-Object { $_.Current.ClassName -match 'send-msg' } | Select-Object -First 1)
Write-Host ("send button classes now: '{0}'" -f $(if ($sendBtn2) { $sendBtn2.Current.ClassName } else { '<none>' }))

# ---------- 10. send ----------
Write-Host 'pressing ENTER to send...' -ForegroundColor Yellow
[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
Start-Sleep -Seconds 3

$all5 = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$editor3 = @($all5 | Where-Object { $_.Current.ClassName -match 'ExEditor-qq-msg-editor' } | Select-Object -First 1)
$after = ''
if ($editor3) { try { $tp2 = $editor3.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern); $after = $tp2.DocumentRange.GetText(120) } catch {} }
Write-Host ("editor after send: '{0}' (empty means send fired: {1})" -f ($after -replace "`r?`n", ' / '), ($after.Trim() -eq ''))

$mine = @($all5 | Where-Object { $_.Current.ClassName -match 'message-container--self' })
$tail = @($all5 | Where-Object { $_.Current.ClassName -match 'msg-content-container' } | Select-Object -Last 3)
Write-Host ("self-message containers in view: {0}" -f $mine.Count)
$tail | ForEach-Object {
  Write-Host ("   last msg cls='{0}' text='{1}'" -f $_.Current.ClassName, (($_.Current.Name) -replace "`r?`n", ' / '))
}
Write-Host 'DONE' -ForegroundColor Green
