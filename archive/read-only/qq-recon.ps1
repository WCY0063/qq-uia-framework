# RECON ONLY - no clicks, no typing, no sends. ASCII-only source.
. (Join-Path $PSScriptRoot 'qq-lib.ps1')

# escaped CJK so this file stays pure ASCII
$CJK_friend = [string]([char]0x597D + [char]0x53CB)          # hao you
$CJK_wx     = [string]([char]0x5FAE + [char]0x4FE1)          # wei xin
$CJK_search = [string]([char]0x641C + [char]0x7D22)          # sou suo
$nameRe = '987654321|' + $CJK_friend

$wins = Get-QqWindows | Sort-Object W -Descending
Write-Host "=== visible QQ windows ===" -ForegroundColor Cyan
$wins | Format-Table Hwnd, Pid, W, H, X, Y, Title -AutoSize

foreach ($w in $wins) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  Write-Host ""
  Write-Host ("=== hwnd={0} pid={1} size={2}x{3} nodes={4} ===" -f $w.Hwnd, $w.Pid, $w.W, $w.H, $all.Count) -ForegroundColor Yellow

  $nick = Get-El -Root $root -ClassRegex 'profile-nickname'
  $sig  = Get-El -Root $root -ClassRegex 'profile_signature'
  $hdr  = Get-El -Root $root -ClassRegex 'chat-header__contact-name'
  $search = Get-El -Root $root -TypeRegex 'Edit'
  $editor = Get-El -Root $root -ClassRegex 'ExEditor-qq-msg-editor'
  $sendBtn = Get-El -Root $root -ClassRegex 'send-msg'

  $nickTxt = '<none>'; if ($nick) { $nickTxt = $nick.Current.Name }
  $sigTxt  = '<none>'; if ($sig)  { $sigTxt = $sig.Current.Name; if ($sigTxt.Length -gt 50) { $sigTxt = $sigTxt.Substring(0,50) } }
  $hdrTxt  = '<none>'; if ($hdr)  { $hdrTxt = $hdr.Current.Name }
  Write-Host ("  account nickname : '{0}'" -f $nickTxt)
  Write-Host ("  signature        : '{0}'" -f $sigTxt)
  Write-Host ("  current chat hdr : '{0}'" -f $hdrTxt)

  if ($search) {
    $r = Get-RectOf $search
    Write-Host ("  search(Edit)     : name='{0}' rect=({1},{2}) {3}x{4} center=({5},{6})" -f $search.Current.Name, $r.X, $r.Y, $r.W, $r.H, $r.CX, $r.CY)
  } else { Write-Host "  search(Edit)     : <not found>" -ForegroundColor Red }

  if ($editor) {
    $r = Get-RectOf $editor
    Write-Host ("  msg editor       : name='{0}' cls='{1}' rect=({2},{3}) {3}x{4} center=({5},{6})" -f $editor.Current.Name, $editor.Current.ClassName, $r.X, $r.Y, $r.W, $r.H, $r.CX, $r.CY)
  } else { Write-Host "  msg editor       : <not found>" -ForegroundColor Red }

  if ($sendBtn) {
    $r = Get-RectOf $sendBtn
    Write-Host ("  send button      : cls='{0}' rect=({1},{2}) {3}x{4} center=({5},{6})" -f $sendBtn.Current.ClassName, $r.X, $r.Y, $r.W, $r.H, $r.CX, $r.CY)
  } else { Write-Host "  send button      : <not found>" -ForegroundColor Red }

  $rows = @(Get-AllNamed -Root $root -NameRegex $nameRe)
  Write-Host ("  nodes matching '{0}': {1}" -f $nameRe, $rows.Count)
  $rows | Select-Object -First 8 | ForEach-Object {
    $ty = $_.Current.ControlType.ProgrammaticName.Replace('ControlType.', '')
    Write-Host ("     [{0}] cls={1} name='{2}'" -f $ty, $_.Current.ClassName, $_.Current.Name)
  }
}

Write-Host ""
Write-Host "=== scaling check ===" -ForegroundColor Cyan
Add-Type -AssemblyName System.Windows.Forms
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Write-Host ("  logical screen (WinForms): {0}x{1}" -f $b.Width, $b.Height)
$main = $wins | Select-Object -First 1
if ($main) {
  Write-Host ("  main window physical/UA rect: {0}x{1} at ({2},{3})" -f $main.W, $main.H, $main.X, $main.Y)
  Write-Host ("  ratio physical/logical width: {0}" -f [Math]::Round(($main.W / $b.Width), 3))
}
