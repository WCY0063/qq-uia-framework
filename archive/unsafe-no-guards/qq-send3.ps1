# Send one message from 酒狐 (pid 86324) to QQ 987654321.
# Idempotent: if the target chat is already open, skip search entirely.
# ASCII-only source.
param(
  [int]$SenderPid = 86324,
  [string]$TargetId = '987654321',
  [string]$ExpectNick = '',       # nickname expected in the chat header / result row
  [string]$Message = '',
  [switch]$NoSend
)
. "$PSScriptRoot\..\read-only\qq-lib.ps1"
Add-Type -AssemblyName System.Windows.Forms
if ($Message -eq '') { $Message = [string]([char]0x65E9+[char]0x4E0A+[char]0x597D+[char]0xFF0C+[char]0x4E3B+[char]0x4EBA+[char]0x3002) }

function Stop-With([string]$why) { Write-Host "ABORT: $why" -ForegroundColor Red; exit 1 }
function Nodes($R) { return @($R.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) }
function HeaderOf($a) { $h = @($a | Where-Object { $_.Current.ClassName -match 'chat-header__contact-name' } | Select-Object -First 1); if ($h) { return $h.Current.Name } else { return '' } }
function EditorOf($a) { return @($a | Where-Object { $_.Current.ClassName -match 'ExEditor-qq-msg-editor' } | Select-Object -First 1) }

$w = Get-QqWindows | Where-Object { $_.Pid -eq $SenderPid } | Select-Object -First 1
if (-not $w) { Stop-With "no window for pid $SenderPid" }
$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
$all = Nodes $root
$av = @($all | Where-Object { $_.Current.ClassName -match 'user-avatar' } | Select-Object -First 1)
Write-Host ("SENDER: '{0}'   WINDOW hwnd={1} {2}x{3}" -f $(if($av){$av.Current.Name}else{'?'}), $w.Hwnd, $w.W, $w.H) -ForegroundColor Cyan

$hdr = HeaderOf $all
$editor = EditorOf $all
Write-Host ("current chat header: '{0}'   editor present: {1}" -f $hdr, ($editor -ne $null))

# ---------- 1. ensure the right chat is open ----------
$needOpen = $true
if ($hdr -ne '' -and $ExpectNick -ne '' -and $hdr -match [regex]::Escape($ExpectNick)) {
  Write-Host 'target chat already open - skipping search' -ForegroundColor Green
  $needOpen = $false
}

if ($needOpen) {
  Write-Host 'searching for the target...' -ForegroundColor Yellow
  $search = @($all | Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Edit' } | Select-Object -First 1)
  if (-not $search) { Stop-With 'search box not found' }
  $search.SetFocus(); Start-Sleep -Milliseconds 250
  # clear then type the number
  $vp = $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
  $vp.SetValue(''); Start-Sleep -Milliseconds 200
  $vp.SetValue($TargetId)
  Write-Host ("search value: '{0}'" -f $vp.Current.Value)

  # wait for a result row whose name carries "(987654321)"
  $numPat = '\(' + [regex]::Escape($TargetId) + '\)'
  $row = $null
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 600
    $a = Nodes $root
    $cands = @($a | Where-Object { $_.Current.ClassName -match 'search-result-item' -and $_.Current.Name -match $numPat })
    if ($cands.Count -gt 0) { $row = $cands[0]; break }
  }
  if (-not $row) {
    Write-Host 'rows seen while waiting:' -ForegroundColor Yellow
    Nodes $root | Where-Object { $_.Current.ClassName -match 'search-result-item' } | ForEach-Object {
      Write-Host ("   cls='{0}' name='{1}'" -f $_.Current.ClassName, $_.Current.Name)
    }
    Stop-With "never saw a result row containing ($TargetId)"
  }
  Write-Host ("ROW: '{0}'" -f $row.Current.Name) -ForegroundColor Green
  if ($ExpectNick -ne '' -and $row.Current.Name -notmatch [regex]::Escape($ExpectNick)) { Stop-With 'row nickname mismatch' }

  $done = $false
  try { $row.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); $done = $true; Write-Host 'Invoke OK' } catch { Write-Host ("Invoke failed: {0}" -f $_.Exception.Message) }
  if (-not $done) {
    Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,int e);' -Name MM3 -Namespace Qq3 -ErrorAction SilentlyContinue
    $r2 = Get-RectOf $row
    [void][QqWin]::SetCursorPos([int]($r2.CX/1.5), [int]($r2.CY/1.5)); Start-Sleep -Milliseconds 200
    [Qq3.MM3]::mouse_event(0x02,0,0,0,0); [Qq3.MM3]::mouse_event(0x04,0,0,0,0)
    Write-Host ("clicked row at logical ({0},{1})" -f [int]($r2.CX/1.5), [int]($r2.CY/1.5))
  }
  Start-Sleep -Seconds 4
  $all = Nodes $root
  $hdr = HeaderOf $all
  $editor = EditorOf $all
  Write-Host ("HEADER AFTER OPEN: '{0}'  editor={1}" -f $hdr, ($editor -ne $null)) -ForegroundColor Green
}

if ($hdr -eq '') { Stop-With 'no chat header - chat did not open' }
if ($ExpectNick -ne '' -and $hdr -notmatch [regex]::Escape($ExpectNick)) { Stop-With "header '$hdr' != expected '$ExpectNick'" }
if (-not $editor) { Stop-With 'no message editor' }
if ($NoSend) { Write-Host 'NoSend: stopping before typing.' -ForegroundColor Yellow; exit 0 }

# ---------- 2. focus editor, type, verify, send ----------
Write-Host ("`nMESSAGE: '{0}' ({1} chars)" -f $Message, $Message.Length) -ForegroundColor Yellow
[void]$editor.SetFocus(); Start-Sleep -Milliseconds 500
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,int e);' -Name MM4 -Namespace Qq4 -ErrorAction SilentlyContinue
$er = Get-RectOf $editor
if ($er.CX -gt 0 -and $er.CY -gt 0 -and $er.CX -lt 8000) {
  [void][QqWin]::SetCursorPos([int]($er.CX/1.5), [int]($er.CY/1.5)); Start-Sleep -Milliseconds 200
  [Qq4.MM4]::mouse_event(0x02,0,0,0,0); [Qq4.MM4]::mouse_event(0x04,0,0,0,0); Start-Sleep -Milliseconds 400
}
[System.Windows.Forms.SendKeys]::SendWait($Message)
Start-Sleep -Milliseconds 900

$all2 = Nodes $root
$e2 = EditorOf $all2
$txt = ''
if ($e2) { try { $txt = $e2.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(200) } catch { $txt = '<err>' } }
Write-Host ("editor contains: '{0}'" -f ($txt -replace "`r?`n",' / ')) -ForegroundColor Yellow
$sb = @($all2 | Where-Object { $_.Current.ClassName -match 'send-msg' } | Select-Object -First 1)
Write-Host ("send button: '{0}'" -f $(if($sb){$sb.Current.ClassName}else{'-'}))
if ($txt -notmatch [regex]::Escape($Message)) { Stop-With 'text not in editor - refusing to send' }

Write-Host "`n>>> SENDING <<<" -ForegroundColor Red
[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
Start-Sleep -Seconds 4

$all3 = Nodes $root
$e3 = EditorOf $all3
$after = ''
if ($e3) { try { $after = $e3.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(120) } catch {} }
Write-Host ("editor after send: '{0}' -> emptied={1}" -f ($after -replace "`r?`n",' / '), ($after.Trim() -eq '')) -ForegroundColor Green
$hits = @($all3 | Where-Object { $_.Current.Name -match [regex]::Escape($Message) })
Write-Host ("nodes containing sent text: {0}" -f $hits.Count) -ForegroundColor Green
$hits | Select-Object -First 4 | ForEach-Object { Write-Host ("   [{0}] '{1}'" -f $_.Current.ControlType.ProgrammaticName.Replace('ControlType.',''), $_.Current.Name) }
$self = @($all3 | Where-Object { $_.Current.ClassName -match 'message-container--self' })
Write-Host ("self-message containers: {0}" -f $self.Count)
Write-Host 'DONE' -ForegroundColor Green
