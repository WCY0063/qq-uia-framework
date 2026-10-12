# Diagnostic: inspect a specific open conversation and report its exact identity + the last messages.
# READ-ONLY. Types nothing, sends nothing.
param([int]$SenderPid = 86324, [string]$OpenNick = '')
. (Join-Path $PSScriptRoot 'qq-lib.ps1')
Add-Type -AssemblyName System.Windows.Forms

function Nodes($R) { return @($R.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) }

$w = Get-QqWindows | Where-Object { $_.Pid -eq $SenderPid } | Select-Object -First 1
if (-not $w) { "window for pid $SenderPid not found"; exit 1 }
$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker

if ($OpenNick -ne '') {
  $nick = $OpenNick
  $anchor = @((Nodes $root) | Where-Object { $_.Current.Name -eq $nick } | Select-Object -First 1)[0]
  if (-not $anchor) { "no node named '$nick' to anchor on"; exit 1 }
  $row = $anchor
  for ($i=0; $i -lt 6; $i++) {
    $p = $walker.GetParent($row, [System.Windows.Automation.CacheRequest]::Current)
    if ($p -eq $null) { break }
    $row = $p
    if ($row.Current.ClassName -match 'recent-contact-item') { break }
  }
  if ($row.Current.ClassName -notmatch 'recent-contact-item') { "climb failed (landed on '$($row.Current.ClassName)')"; exit 1 }
  Write-Host "opening session row for '$nick' ..." -ForegroundColor Yellow
  [void]$row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
  try { $row.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } catch { Write-Host "invoke failed: $($_.Exception.Message)" }
  Start-Sleep -Seconds 4
}

$all = Nodes $root
# identity evidence
$hdr  = @($all | Where-Object { $_.Current.ClassName -match 'chat-header__contact-name' } | Select-Object -First 1)
$hbar = @($all | Where-Object { $_.Current.ClassName -match 'chat-header' } | ForEach-Object { $_.Current.ClassName }) | Select-Object -Unique
$memberCount = @($all | Where-Object { $_.Current.ClassName -match 'group-member-list' })
$editor = @($all | Where-Object { $_.Current.ClassName -match 'ExEditor-qq-msg-editor' } | Select-Object -First 1)
$selfMsg = @($all | Where-Object { $_.Current.ClassName -match 'message-container--self' })
$peerMsg = @($all | Where-Object { $_.Current.ClassName -match 'message-container--others' })

Write-Host "`n================ CONVERSATION IDENTITY ================" -ForegroundColor Magenta
Write-Host ("chat header name : '{0}'" -f $(if($hdr){$hdr.Current.Name}else{'<none>'}))
Write-Host ("chat-header* classes present: {0}" -f ($hbar -join ', '))
Write-Host ("group member list present   : {0}" -f ($memberCount.Count -gt 0))
Write-Host ("editor present              : {0}" -f ($editor -ne $null))
Write-Host ("self message containers     : {0}" -f $selfMsg.Count)
Write-Host ("peer message containers     : {0}" -f $peerMsg.Count)

Write-Host "`n================ LAST MESSAGES (document order) ================" -ForegroundColor Magenta
$msgs = @($all | Where-Object { $_.Current.ClassName -match '^message$' })
Write-Host (".message nodes: {0}" -f $msgs.Count)
$n = 0
foreach ($m in $msgs) {
  $n++
  if ($n -lt ($msgs.Count - 9)) { continue }
  $parts=@(); $isSelf=$false; $ts=$null
  $c=$walker.GetFirstChild($m)
  while ($c -ne $null) {
    if ($c.Current.ClassName -match '--self') { $isSelf=$true }
    if ($c.Current.ClassName -match 'message__timestamp') { $ts = $c.Current.Name }
    if ($c.Current.Name -ne '' -and $c.Current.Name -notmatch '^LV$') { $parts += $c.Current.Name }
    $g=$walker.GetFirstChild($c)
    while ($g -ne $null) {
      if ($g.Current.ClassName -match '--self') { $isSelf=$true }
      if ($g.Current.Name -ne '' -and $g.Current.Name -notmatch '^LV$') { $parts += $g.Current.Name }
      $g=$walker.GetNextSibling($g)
    }
    $c=$walker.GetNextSibling($c)
  }
  $line = ($parts -join ' | ')
  if ($line.Length -gt 150) { $line = $line.Substring(0,150) + '...' }
  Write-Host ("  [{0}] {1} {2} :: {3}" -f $n, $(if($isSelf){'SELF'}else{'PEER'}), $(if($ts){"ts=$ts"}else{''}), $line)
}
