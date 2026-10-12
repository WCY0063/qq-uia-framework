# Send one message from 酒狐 (123456789, pid 86324) to QQ 987654321, targeting the exact search result row.
# ASCII-only source. Verifies at every step and stops on mismatch.
param(
  [int]$SenderPid = 86324,
  [string]$TargetId = '987654321',
  [string]$ExpectNick = '',          # e.g. the friend's nickname shown in search results
  [string]$Message = '',
  [switch]$NoSend
)
. 'G:\deepseek-harness\workplace\qq-uia\qq-lib.ps1'
Add-Type -AssemblyName System.Windows.Forms

if ($Message -eq '') { $Message = [string]([char]0x65E9 + [char]0x4E0A + [char]0x597D + [char]0xFF0C + [char]0x4E3B + [char]0x4EBA + [char]0x3002) }

function Stop-With([string]$why) { Write-Host "ABORT: $why" -ForegroundColor Red; exit 1 }
function Nodes($R) { return $R.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) }

Write-Host ("TARGET QQ  : {0}" -f $TargetId)
Write-Host ("MESSAGE    : '{0}'  ({1} chars)" -f $Message, $Message.Length) -ForegroundColor Yellow

$w = Get-QqWindows | Where-Object { $_.Pid -eq $SenderPid } | Select-Object -First 1
if (-not $w) { Stop-With "no window for pid $SenderPid" }
$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
$all = Nodes $root

# --- sender identity ---
$av = @($all | Where-Object { $_.Current.ClassName -match 'user-avatar' } | Select-Object -First 1)
Write-Host ("SENDER nick: '{0}'" -f $(if ($av) { $av.Current.Name } else { '<none>' })) -ForegroundColor Cyan

# --- 1. make sure the search results are present; if not, run the search ---
$results = @($all | Where-Object { $_.Current.ClassName -match 'search-result-item' })
if ($results.Count -eq 0) {
  Write-Host 'no search results present; running search first...' -ForegroundColor Yellow
  $search = @($all | Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Edit' } | Select-Object -First 1)
  if (-not $search) { Stop-With 'search box not found' }
  $vp = $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
  $search.SetFocus(); Start-Sleep -Milliseconds 300
  $vp.SetValue($TargetId); Start-Sleep -Seconds 2
  $all = Nodes $root
  $results = @($all | Where-Object { $_.Current.ClassName -match 'search-result-item' })
}
if ($results.Count -eq 0) { Stop-With 'search produced no result rows' }

Write-Host ("`nsearch result rows ({0}):" -f $results.Count) -ForegroundColor Cyan
$results | ForEach-Object { Write-Host ("   cls='{0}' name='{1}'" -f $_.Current.ClassName, $_.Current.Name) }

# --- 2. pick the row that is exactly "<nick> (<number>) ..." ---
$pattern = '\(' + [regex]::Escape($TargetId) + '\)'
$row = @($results | Where-Object { $_.Current.Name -match $pattern } | Select-Object -First 1)
if (-not $row) { Stop-With "no search row contains ($TargetId)" }
Write-Host ("`nSELECTED ROW: '{0}'" -f $row.Current.Name) -ForegroundColor Green
if ($ExpectNick -ne '' -and $row.Current.Name -notmatch [regex]::Escape($ExpectNick)) {
  Stop-With "row '$($row.Current.Name)' does not contain expected nickname '$ExpectNick'"
}

# --- 3. open the chat by invoking the row ---
$opened = $false
try {
  $sep = $row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
  Write-Host 'row exposes SelectionItemPattern'
} catch { Write-Host 'row has no SelectionItemPattern' }
try {
  $ip = $row.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  $ip.Invoke(); $opened = $true; Write-Host 'InvokePattern.Invoke() on row OK'
} catch {
  Write-Host ("Invoke unavailable: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
  $row.SetFocus(); Start-Sleep -Milliseconds 300
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Write-Host 'sent ENTER to the focused row'; $opened = $true
}
Start-Sleep -Seconds 4

# --- 4. verify the chat opened and the header matches ---
$all2 = Nodes $root
$hdr = @($all2 | Where-Object { $_.Current.ClassName -match 'chat-header__contact-name' } | Select-Object -First 1)
$hdrName = if ($hdr) { $hdr.Current.Name } else { '<none>' }
Write-Host ("`nOPENED CHAT HEADER: '{0}'" -f $hdrName) -ForegroundColor Green
$editor = @($all2 | Where-Object { $_.Current.ClassName -match 'ExEditor-qq-msg-editor' } | Select-Object -First 1)
$sendBtn = @($all2 | Where-Object { $_.Current.ClassName -match 'send-msg' } | Select-Object -First 1)
Write-Host ("editor found: {0}   send button: {1}" -f ($editor -ne $null), ($sendBtn -ne $null))
if (-not $editor) { Stop-With 'chat did not open (no message editor)' }
if ($ExpectNick -ne '' -and $hdrName -notmatch [regex]::Escape($ExpectNick)) {
  Stop-With "opened chat is '$hdrName', not the expected '$ExpectNick'"
}

if ($NoSend) { Write-Host "`nNoSend: verified everything, stopping before typing." -ForegroundColor Yellow; exit 0 }

# --- 5. focus the editor and type with real keyboard input ---
[void]$editor.SetFocus()
Start-Sleep -Milliseconds 500
$focused = [System.Windows.Automation.AutomationElement]::FocusedElement
Write-Host ("focused element: [{0}] cls='{1}'" -f $focused.Current.ControlType.ProgrammaticName, $focused.Current.ClassName)

Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,int e);' -Name MM2 -Namespace Qq2 -ErrorAction SilentlyContinue
$er = Get-RectOf $editor
Write-Host ("editor UIA rect ({0},{1}) {2}x{3}  (physical px)" -f $er.X, $er.Y, $er.W, $er.H)
if ($er.CX -gt 0 -and $er.CY -gt 0) {
  [void][QqWin]::SetCursorPos([int]($er.CX/1.5), [int]($er.CY/1.5))
  Start-Sleep -Milliseconds 200
  [Qq2.MM2]::mouse_event(0x02,0,0,0,0); [Qq2.MM2]::mouse_event(0x04,0,0,0,0)
  Start-Sleep -Milliseconds 400
}

Write-Host ("typing '{0}' via SendInput..." -f $Message) -ForegroundColor Yellow
[System.Windows.Forms.SendKeys]::SendWait($Message)
Start-Sleep -Milliseconds 800

# --- 6. verify the text landed ---
$all3 = Nodes $root
$editor2 = @($all3 | Where-Object { $_.Current.ClassName -match 'ExEditor-qq-msg-editor' } | Select-Object -First 1)
$txt = ''
if ($editor2) { try { $txt = $editor2.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(200) } catch { $txt = "<err>" } }
Write-Host ("editor now: '{0}'" -f ($txt -replace "`r?`n",' / ')) -ForegroundColor Yellow
Write-Host ("editor classes: '{0}'" -f $(if ($editor2) { $editor2.Current.ClassName } else { '-' }))
$sendBtn2 = @($all3 | Where-Object { $_.Current.ClassName -match 'send-msg' } | Select-Object -First 1)
Write-Host ("send button classes: '{0}'" -f $(if ($sendBtn2) { $sendBtn2.Current.ClassName } else { '-' }))
if ($txt -notmatch [regex]::Escape($Message)) { Stop-With 'typed text did not land in the editor - not sending' }

# --- 7. send with ENTER ---
Write-Host '`n>>> SENDING (ENTER) <<<' -ForegroundColor Red
[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
Start-Sleep -Seconds 4

$all4 = Nodes $root
$editor3 = @($all4 | Where-Object { $_.Current.ClassName -match 'ExEditor-qq-msg-editor' } | Select-Object -First 1)
$after = ''
if ($editor3) { try { $after = $editor3.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(120) } catch {} }
Write-Host ("editor after send: '{0}'  -> emptied: {1}" -f ($after -replace "`r?`n",' / '), ($after.Trim() -eq ''))

$myMsgs = @($all4 | Where-Object { $_.Current.ClassName -match 'message-container--self' })
Write-Host ("self-message containers now in view: {0}" -f $myMsgs.Count)
$texts = @($all4 | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.Text' -and $_.Current.Name -ne '' })
$match = @($texts | Where-Object { $_.Current.Name -match [regex]::Escape($Message) })
Write-Host ("nodes containing the sent text: {0}" -f $match.Count) -ForegroundColor Green
$match | Select-Object -First 5 | ForEach-Object { Write-Host ("   '{0}'" -f $_.Current.Name) }
Write-Host 'DONE' -ForegroundColor Green
