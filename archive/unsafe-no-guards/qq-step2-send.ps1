# STEP 2: re-verify the open window, then send ONE message. ASCII-only source.
# Hard guard: refuses to type unless the header equals -ExpectNick and it is not a group.
param(
  [int]$SenderPid = 86324,
  [string]$ExpectNick = '',      # required: exact nickname the header must show
  [string]$Message = '',
  [switch]$DryRun
)
. (Join-Path $PSScriptRoot 'qq-lib.ps1')
Add-Type -AssemblyName System.Windows.Forms
if ($Message -eq '') { $Message = [string]([char]0x65E9+[char]0x4E0A+[char]0x597D+[char]0xFF0C+[char]0x4E3B+[char]0x4EBA+[char]0x3002) }
if ($ExpectNick -eq '') { Write-Host 'ABORT: -ExpectNick is required' -ForegroundColor Red; exit 1 }

function Nodes($R) { return @($R.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) }
function Stop-With([string]$why) { Write-Host "ABORT: $why" -ForegroundColor Red; exit 1 }

$w = Get-QqWindows | Where-Object { $_.Pid -eq $SenderPid } | Select-Object -First 1
if (-not $w) { Stop-With "no window for pid $SenderPid" }
$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)

# ---------- PRE-SEND VERIFICATION ----------
$all = Nodes $root
$sender = (@($all | Where-Object { $_.Current.ClassName -match 'user-avatar' } | Select-Object -First 1)).Current.Name
$hdrEl = @($all | Where-Object { $_.Current.ClassName -match 'chat-header__contact-name' } | Select-Object -First 1)
$hdr = if ($hdrEl) { $hdrEl.Current.Name } else { '' }
$isGroup = @($all | Where-Object { $_.Current.ClassName -match 'group-member-list' }).Count -gt 0
$editor = @($all | Where-Object { $_.Current.ClassName -match 'ExEditor-qq-msg-editor' } | Select-Object -First 1)
$sendBtn = @($all | Where-Object { $_.Current.ClassName -match 'send-msg' } | Select-Object -First 1)

Write-Host "===== PRE-SEND VERIFICATION =====" -ForegroundColor Magenta
Write-Host ("sender account : '{0}'" -f $sender)
Write-Host ("window header  : '{0}'" -f $hdr) -ForegroundColor Green
Write-Host ("is group chat  : {0}" -f $isGroup)
Write-Host ("editor present : {0}" -f ($editor -ne $null))
Write-Host ("send button    : {0}" -f ($sendBtn -ne $null))

if ($hdr -ne $ExpectNick) { Stop-With "header '$hdr' != expected '$ExpectNick' - REFUSING TO SEND" }
if ($isGroup) { Stop-With 'this is a GROUP chat - REFUSING TO SEND' }
if (-not $editor) { Stop-With 'no editor - REFUSING TO SEND' }
Write-Host "VERIFICATION PASSED" -ForegroundColor Green

if ($DryRun) { Write-Host 'DryRun: stopping.' -ForegroundColor Yellow; exit 0 }

# ---------- TYPE ----------
$editor.SetFocus(); Start-Sleep -Milliseconds 600
$focused = [System.Windows.Automation.AutomationElement]::FocusedElement
Write-Host ("`nfocused element: [{0}] cls='{1}'" -f $focused.Current.ControlType.ProgrammaticName, $focused.Current.ClassName)

Write-Host ("typing: '{0}'" -f $Message) -ForegroundColor Yellow
[System.Windows.Forms.SendKeys]::SendWait($Message)
Start-Sleep -Milliseconds 1000

# ---------- VERIFY TEXT LANDED ----------
$all2 = Nodes $root
$e2 = @($all2 | Where-Object { $_.Current.ClassName -match 'ExEditor-qq-msg-editor' } | Select-Object -First 1)
$txt = ''
if ($e2) { try { $txt = $e2.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(200) } catch { $txt = '<err>' } }
$clean = ($txt -replace "`r?`n", '')
Write-Host ("editor content : '{0}'" -f $clean) -ForegroundColor Yellow
$hdr2 = (@($all2 | Where-Object { $_.Current.ClassName -match 'chat-header__contact-name' } | Select-Object -First 1)).Current.Name
Write-Host ("header before send: '{0}' (must still be '{1}')" -f $hdr2, $ExpectNick)
if ($hdr2 -ne $ExpectNick) { Stop-With 'header changed while typing - REFUSING TO SEND' }
if ($clean -notmatch [regex]::Escape($Message)) { Stop-With 'text not in editor - REFUSING TO SEND' }

# ---------- SEND ----------
Write-Host "`n>>> SENDING ONE MESSAGE <<<" -ForegroundColor Red
[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
Start-Sleep -Seconds 4

$all3 = Nodes $root
$e3 = @($all3 | Where-Object { $_.Current.ClassName -match 'ExEditor-qq-msg-editor' } | Select-Object -First 1)
$after = ''
if ($e3) { try { $after = $e3.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(120) } catch {} }
$hdr3 = (@($all3 | Where-Object { $_.Current.ClassName -match 'chat-header__contact-name' } | Select-Object -First 1)).Current.Name
Write-Host ("editor after   : '{0}' -> emptied={1}" -f (($after -replace "`r?`n",'')), ($after.Trim() -eq '')) -ForegroundColor Green
Write-Host ("header after   : '{0}'" -f $hdr3)
$self = @($all3 | Where-Object { $_.Current.ClassName -match 'message-container--self' })
Write-Host ("self msgs view : {0}" -f $self.Count)
$hits = @($all3 | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.Text' -and $_.Current.Name -match [regex]::Escape($Message) })
Write-Host ("text nodes w/ message: {0}" -f $hits.Count)
Write-Host 'SENT (once)' -ForegroundColor Green
