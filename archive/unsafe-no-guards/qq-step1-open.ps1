# STEP 1: open the target conversation and screenshot it for human verification.
# TYPES NOTHING / SENDS NOTHING. ASCII-only source.
param([int]$SenderPid = 86324, [string]$TargetId = '987654321', [string]$ExpectNick = '')
. (Join-Path $PSScriptRoot 'qq-lib.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Nodes($R) { return @($R.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) }
function Hdr($a) { $h = @($a | Where-Object { $_.Current.ClassName -match 'chat-header__contact-name' } | Select-Object -First 1); if ($h) { return $h.Current.Name } else { return '(none)' } }
function RowNames($R) { return @($R.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.ClassName -match 'search-result-item' }) }

$w = Get-QqWindows | Where-Object { $_.Pid -eq $SenderPid } | Select-Object -First 1
if (-not $w) { Write-Host "no window for pid $SenderPid"; exit 1 }
[void][QqWin]::ShowWindow([IntPtr]$w.Hwnd, 9)
[void][QqWin]::SetForegroundWindow([IntPtr]$w.Hwnd)
Start-Sleep -Milliseconds 600
$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)

$all = Nodes $root
Write-Host ("SENDER  : '{0}'" -f (@($all | Where-Object { $_.Current.ClassName -match 'user-avatar' } | Select-Object -First 1).Current.Name))
Write-Host ("BEFORE  : '{0}'" -f (Hdr $all))

# --- search ---
$search = @($all | Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Edit' } | Select-Object -First 1)
$search.SetFocus(); Start-Sleep -Milliseconds 400
$vp = $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
$vp.SetValue(''); Start-Sleep -Milliseconds 400
$vp.SetValue($TargetId); Start-Sleep -Milliseconds 800
Write-Host ("search  : '{0}'" -f $vp.Current.Value)

# --- pick result row: prefer a named contact row containing the number, else the first row ---
$row = $null; $rowLabel = ''
for ($i = 0; $i -lt 12; $i++) {
  Start-Sleep -Milliseconds 700
  $rows = RowNames $root
  foreach ($r in $rows) {
    $n = $r.Current.Name
    if ($n -match ('\(' + [regex]::Escape($TargetId) + '\)') -and $n -notmatch '鍖呭惈') { $row = $r; $rowLabel = $n; break }
  }
  if ($row) { break }
  if ($rows.Count -gt 0 -and $i -ge 4) { $row = $rows[0]; $rowLabel = "<first row, name='$($rows[0].Current.Name)'>"; break }
}
if (-not $row) { Write-Host 'no search rows at all'; exit 1 }
Write-Host ("ROW     : {0}" -f $rowLabel) -ForegroundColor Yellow
$r2 = Get-RectOf $row
Write-Host ("row rect (UIA): ({0},{1}) {2}x{3}" -f $r2.X, $r2.Y, $r2.W, $r2.H)

# --- open ---
$before = Hdr (Nodes $root)
try { $row.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Write-Host 'row invoked' } catch { Write-Host ("invoke failed: {0}" -f $_.Exception.Message) }
$after = ''
for ($i = 0; $i -lt 20; $i++) {
  Start-Sleep -Milliseconds 500
  $after = Hdr (Nodes $root)
  if ($after -ne $before -and $after -ne '(none)') { break }
}
Start-Sleep -Seconds 2
$all2 = Nodes $root
$after = Hdr $all2
$isGroup = @($all2 | Where-Object { $_.Current.ClassName -match 'group-member-list' }).Count -gt 0
$editor = @($all2 | Where-Object { $_.Current.ClassName -match 'ExEditor-qq-msg-editor' } | Select-Object -First 1)

Write-Host "`n========== RESULT ==========" -ForegroundColor Magenta
Write-Host ("chat BEFORE : '{0}'" -f $before)
Write-Host ("chat AFTER  : '{0}'" -f $after) -ForegroundColor Green
Write-Host ("is GROUP    : {0}" -f $isGroup)
Write-Host ("editor      : {0}" -f ($editor -ne $null))
if ($ExpectNick -ne '') {
  Write-Host ("nick match  : {0}" -f ($after -match [regex]::Escape($ExpectNick))) -ForegroundColor $(if ($after -match [regex]::Escape($ExpectNick)) { 'Green' } else { 'Red' })
}

# --- screenshot ---
Start-Sleep -Milliseconds 700
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$full = 'G:\deepseek-harness\workplace\qq-uia\verify-full.png'
$bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

$rx = [Math]::Max(0, [int]($w.X / 1.5)); $ry = [Math]::Max(0, [int]($w.Y / 1.5))
$rw = [int]($w.W / 1.5); $rh = [int]($w.H / 1.5)
if ($rx + $rw -gt $b.Width) { $rw = $b.Width - $rx }
if ($ry + $rh -gt $b.Height) { $rh = $b.Height - $ry }
$crop = 'G:\deepseek-harness\workplace\qq-uia\verify-window.png'
$src = [System.Drawing.Image]::FromFile($full)
$rect = New-Object System.Drawing.Rectangle($rx, $ry, $rw, $rh)
$dst = New-Object System.Drawing.Bitmap($rect.Width, $rect.Height)
$g2 = [System.Drawing.Graphics]::FromImage($dst)
$g2.DrawImage($src, (New-Object System.Drawing.Rectangle(0,0,$rect.Width,$rect.Height)), $rect, [System.Drawing.GraphicsUnit]::Pixel)
$dst.Save($crop, [System.Drawing.Imaging.ImageFormat]::Png)
$g2.Dispose(); $dst.Dispose(); $src.Dispose()
Write-Host ("screenshot : {0}" -f $crop) -ForegroundColor Yellow
Write-Host 'NOTHING TYPED OR SENT.' -ForegroundColor Yellow
