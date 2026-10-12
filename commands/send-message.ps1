# =============================================================================
# commands/send-message.ps1 - L2 outward write (IRREVERSIBLE).
# Authority: docs/FRAMEWORK-DESIGN.md 4.2, 4.3 and 6; docs/AGENT-MANUAL.md 4.1
#
# This is the only command that changes state outside this machine. It sends ONE
# text message, and every guard in lib\qq-guards.ps1 runs before the first
# keystroke. There is no switch that skips a guard; -DryRun only stops earlier.
#
# Guard order, which is the order the code actually runs them in:
#   1. message is sendable           -> reject empty / multiline / unrepresentable
#                                       first: it costs nothing and must fire even
#                                       when the window lookup would fail later
#   2. -ExpectNick supplied          -> without it there is no destination claim
#   3. instance resolved             -> -SenderPid, -Account or defaultAccount
#   4. account matches expectation   -> multi-instance protection; the expectation
#                                       is -ExpectAccountNick, or the configured
#                                       Nick behind -Account/defaultAccount
#   5. send cooldown                 -> guards.minSendIntervalMs, recovered from
#                                       evidence\audit.jsonl so it survives a
#                                       fresh process
#   6. header equals -ExpectNick     -> exact destination proof
#   7. not a group chat              -> default refusal, no bypass
#   8. editor present / not empty    -> never send on top of the user's draft
#   9. read-back after typing        -> the text really reached the editor
#  10. header re-read before Enter   -> the destination did not drift mid-send
#  11. post-send confirmation        -> editor emptied and the message is visible
# -DryRun stops after step 8, before the first keystroke.
# Each attempt is appended to evidence\audit.jsonl (FRAMEWORK-DESIGN 6.8), and a
# screenshot is taken even if the caller asked for none: an L2 action always
# leaves visual evidence.
# -TimeoutSec (timeouts.defaultSec unless overridden) caps every stage wait.
#
# Contract with the dispatcher: defines functions only, defines
# Invoke-QQCommand -Context <hashtable>, returns @{ Data; Pid }, writes nothing to
# stdout.
#
# ASCII-ONLY SOURCE. run-tests.ps1 enforces this rule.
# =============================================================================

function Get-QQSendAuditRecord {
  <#
  .SYNOPSIS
    Builds one audit record for a send attempt.
  .PARAMETER Stage
    'attempt' before typing, 'send' at the moment Enter is pressed, 'result' once
    the outcome is known.
  .PARAMETER Instance
    Instance hashtable from Get-QQInstanceContext.
  .PARAMETER Header
    Conversation title observed at this stage.
  .PARAMETER ExpectNick
    Requested destination.
  .PARAMETER Message
    Payload descriptor hashtable from Get-QQMessageTextArg plus Hash/Length.
  .PARAMETER Extra
    Additional stage-specific fields.
  .OUTPUTS
    [ordered] hashtable ready for JSONL serialization.
  #>
  param(
    [Parameter(Mandatory)][string]$Stage,
    [Parameter(Mandatory)]$Instance,
    [string]$Header = '',
    [string]$ExpectNick = '',
    $Message = $null,
    $Extra = $null
  )
  $record = [ordered]@{
    time       = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    # Unix seconds as int64, written the same way Assert-QQRateLimit reads them.
    # The previous -UFormat %s round trip went through a culture-dependent
    # [double]::Parse, which is what made the cooldown wrong on a host whose
    # decimal separator is a comma.
    unix       = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    stage      = [string]$Stage
    command    = 'send-message'
    version    = [string]$script:QQ_FRAMEWORK_VERSION
    pid        = [int]$Instance.Pid
    hwnd       = [int64]$Instance.Window.Hwnd
    account    = [string]$Instance.Identity.Nick
    target     = [string]$Header
    expectNick = [string]$ExpectNick
    isGroup    = [bool](Test-QQIsGroupChat -Root $Instance.Root)
  }
  if ($null -ne $Message) {
    $record['messageHash'] = [string]$Message.Hash
    $record['messageLength'] = [int]$Message.Length
    $record['messageSource'] = [string]$Message.Source
    $record['messageFile'] = [string]$Message.File
  }
  if ($null -ne $Extra) {
    foreach ($key in $Extra.Keys) { $record[[string]$key] = $Extra[$key] }
  }
  return $record
}

function Invoke-QQCommand {
  <#
  .SYNOPSIS
    L2 send-message: sends one text message after the guard chain passes.
  .DESCRIPTION
    -DryRun runs every guard and stops before the first keystroke, which is the
    supported way to validate a destination without sending. Without -DryRun the
    command types the payload, verifies it landed, re-verifies the destination, and
    presses Enter once.

    When the instance was selected with -Account or defaultAccount, the resolved
    account entry's Nick is fed to the account guard automatically, so addressing
    the instance by account also guards the sending account. data.accountGuard
    reports which of the two happened.
  .PARAMETER Context
    Dispatcher context hashtable.
  .OUTPUTS
    Hashtable with Data (account, target, sent, verification fields, auditLog) and Pid.
  #>
  param($Context)

  $pidValue = Get-QQIntArg -Name 'SenderPid' -Default 0 -Min 1
  $accountArg = Get-QQStringArg -Name 'Account'
  $expectNick = Get-QQStringArg -Name 'ExpectNick' -Required
  $expectAccount = Get-QQStringArg -Name 'ExpectAccountNick'
  $dryRun = [bool]$Context.DryRun
  $config = $Context.Config
  $evidenceDir = [string]$Context.EvidenceDir
  # -TimeoutSec (timeouts.defaultSec from config.json unless the caller overrides
  # it) caps every stage wait below.
  $timeouts = Get-QQEffectiveTimeouts -Timeouts $Context.Timeouts -TimeoutSec ([int]$Context.TimeoutSec)

  $payload = Get-QQMessageTextArg
  $message = Assert-QQSendableMessage -Text ([string]$payload.Text)
  $message['Source'] = [string]$payload.Source
  $message['File'] = [string]$payload.File

  # Destination claim next: it costs nothing and makes every later error clearer.
  # The payload guard deliberately runs before it, so an unsendable message aborts
  # without touching a window.
  [void](Assert-QQExpectNickPresent -ExpectNick $expectNick)

  $instance = Get-QQInstanceContext -TargetPid $pidValue -Account $accountArg -Config $config
  $script:QQ_PID = [int]$instance.Pid
  Write-QQLog -Text ("instance pid {0}: account '{1}'" -f $instance.Pid, $instance.Identity.Nick)

  # -Account (or defaultAccount) already named the sending account, so the guard
  # the caller was going to state by hand is stated here instead. An explicit
  # -ExpectAccountNick always wins: it is the caller's own claim, and it is the
  # one Assert-QQAccountExpected must compare against.
  $accountGuard = 'none'
  if (-not [string]::IsNullOrWhiteSpace($expectAccount)) {
    $accountGuard = 'explicit'
  } elseif ($null -ne $instance.Account -and -not [string]::IsNullOrWhiteSpace([string]$instance.Account.Nick)) {
    $expectAccount = [string]$instance.Account.Nick
    $accountGuard = 'from-account'
    Write-QQLog -Text ("-ExpectAccountNick derived from the resolved account: '{0}'" -f $expectAccount)
  }
  Assert-QQAccountExpected -Instance $instance -ExpectAccountNick $expectAccount -Config $config

  $auditPath = Join-Path $evidenceDir 'audit.jsonl'
  $minInterval = 0
  if ($config.ContainsKey('MinSendIntervalMs')) { $minInterval = [int]$config['MinSendIntervalMs'] }
  [void](Assert-QQRateLimit -AuditPath $auditPath -MinIntervalMs $minInterval)

  $state = Get-QQOpenChatState -Instance $instance
  Write-QQLog -Text ("open conversation '{0}' (group={1}, editor={2})" -f $state.Header, $state.IsGroup, $state.EditorPresent)

  # Guard chain, evaluated before anything is typed.
  [void](Assert-QQHeaderMatches -Header ([string]$state.Header) -ExpectNick $expectNick)
  [void](Assert-QQNotGroupChat -IsGroup ([bool]$state.IsGroup) -Header ([string]$state.Header))
  [void](Assert-QQEditorPresent -EditorPresent ([bool]$state.EditorPresent) -Header ([string]$state.Header))

  $editorText = ''
  if ([bool]$state.EditorPresent) { $editorText = Get-QQTextPatternText -Element $state.EditorElement -MaxChars 500 }
  [void](Assert-QQEditorWritable -EditorText $editorText)

  $notes = New-Object System.Collections.ArrayList
  [void]$notes.Add('destination verified by exact header match against the open conversation')

  if ($dryRun) {
    $data = [ordered]@{
      dryRun           = $true
      sent             = $false
      account          = (Get-QQAccountSummary -Instance $instance)
      accountGuard     = [string]$accountGuard
      header           = [string]$state.Header
      expectNick       = [string]$expectNick
      headerMatches    = [bool]($state.Header -ceq $expectNick)
      isGroup          = [bool]$state.IsGroup
      editorPresent    = [bool]$state.EditorPresent
      editorWasEmpty   = [bool]([string]::IsNullOrWhiteSpace($editorText))
      messageLength    = [int]$message.Length
      messageHash      = [string]$message.Hash
      messageSource    = [string]$message.Source
      guardsPassed     = @('messageSendable', 'expectNick', 'account', 'rateLimit', 'headerMatch', 'notGroup', 'editorPresent', 'editorEmpty')
      auditLog         = [string]$auditPath
      notes            = @($notes) + @('-DryRun: stopped after the guard chain; nothing was typed and nothing was sent')
    }
    Write-QQLog -Text 'DryRun: guard chain passed, nothing typed or sent'
    return @{ Data = $data; Pid = [int]$instance.Pid }
  }

  $writeAudit = $true
  if ($config.ContainsKey('WriteAudit')) { $writeAudit = [bool]$config['WriteAudit'] }
  $includeText = $true
  if ($config.ContainsKey('AuditIncludeText')) { $includeText = [bool]$config['AuditIncludeText'] }
  $auditMessage = @{
    Hash   = [string]$message.Hash
    Length = [int]$message.Length
    Source = [string]$message.Source
    File   = [string]$message.File
  }

  if ($writeAudit) {
    [void](Write-QQAuditRecord -Dir $evidenceDir -Record (Get-QQSendAuditRecord -Stage 'attempt' -Instance $instance -Header ([string]$state.Header) -ExpectNick $expectNick -Message $auditMessage))
  }

  # ---- type ----
  [void](Invoke-QQWindowFocus -Hwnd $instance.Window.Hwnd)
  Start-Sleep -Milliseconds ([int]$timeouts.afterFocusMs)
  if (-not (Set-QQElementFocus -Element $state.EditorElement)) {
    throw (New-QQErrorRecord -Code 'TIMEOUT' -Message 'the message editor did not take focus, so typing would go elsewhere' -Details @{ pid = $instance.Pid })
  }
  $delay = Get-QQTypingDelayMs -Config $config
  [void](Send-QQText -Text ([string]$message.Text) -DelayMs $delay)
  Start-Sleep -Milliseconds ([int]$timeouts.afterTypeMs)

  # ---- read-back: the text really reached the editor ----
  $afterType = Get-QQOpenChatState -Instance $instance
  $readBack = Get-QQTextPatternText -Element $afterType.EditorElement -MaxChars 1000
  Write-QQLog -Text ("read-back length {0} against typed length {1}" -f $readBack.Trim().Length, $message.Length)
  [void](Assert-QQTextLanded -EditorText $readBack -Expected ([string]$message.Text))

  # ---- destination re-check at the last possible moment ----
  $beforeSend = Get-QQOpenChatState -Instance $instance
  if ([string]$beforeSend.Header -cne $expectNick) {
    throw (New-QQErrorRecord -Code 'GUARD_HEADER_DRIFT' -Message ("refusing to send: the conversation changed to '{0}' while typing" -f $beforeSend.Header) -Details @{ pid = $instance.Pid; header = [string]$beforeSend.Header; expected = $expectNick })
  }
  if ([bool]$beforeSend.IsGroup) {
    throw (New-QQErrorRecord -Code 'GUARD_GROUP_REJECTED' -Message 'refusing to send: the conversation became a group while typing' -Details @{ pid = $instance.Pid; header = [string]$beforeSend.Header })
  }

  $selfBefore = @(Get-QQNodes -Root $instance.Root -Section 'Chat' -Name 'MsgSelf').Count

  # ---- send exactly one message ----
  Write-QQLog -Text 'pressing Enter once'
  [void](Send-QQEnter)
  Start-Sleep -Milliseconds ([int]$timeouts.afterSendMs)

  $after = Get-QQOpenChatState -Instance $instance
  $editorAfter = Get-QQTextPatternText -Element $after.EditorElement -MaxChars 500
  $editorEmptied = [string]::IsNullOrWhiteSpace($editorAfter)
  $selfAfter = @(Get-QQNodes -Root $instance.Root -Section 'Chat' -Name 'MsgSelf')
  $selfCount = $selfAfter.Count

  # ---- is the message actually on screen? ----
  # Look for the typed text by Name inside the message area's own subtree. The
  # previous check matched the message text against a ClassName, which can never
  # hit: a message's text is the element's automation Name. The rendered container
  # count remains as the fallback for a build that renders no readable text node.
  $newSelfMessage = 0
  $msgArea = Get-QQNode -Root $instance.Root -Section 'Chat' -Name 'MsgArea'
  if ($null -ne $msgArea) {
    # Max is raised here because the walk is in document order, oldest first: with
    # the default cap a busy message area would be cut off exactly where the just
    # sent message is.
    $newSelfMessage = @(Get-QQDescendantsByName -Element $msgArea -Name ([string]$message.Text) -Max 1500).Count
  }
  if ($newSelfMessage -eq 0 -and $selfCount -gt $selfBefore) { $newSelfMessage = 1 }

  $screenshot = $null
  $keepAlias = $true
  if ($config.ContainsKey('KeepLatestAliases')) { $keepAlias = [bool]$config['KeepLatestAliases'] }
  $shot = Save-QQWindowScreenshot -Hwnd $instance.Window.Hwnd -Dir $evidenceDir -Kind 'after-send' -TargetPid $instance.Pid -Alias 'last-send' -KeepAlias $keepAlias
  if ([string]::IsNullOrEmpty([string]$shot.Error)) {
    $screenshot = [ordered]@{ path = [string]$shot.Path; aliasPath = [string]$shot.AliasPath; width = [int]$shot.Width; height = [int]$shot.Height; error = '' }
  } else {
    $screenshot = [ordered]@{ path = ''; aliasPath = ''; width = 0; height = 0; error = [string]$shot.Error }
    Write-QQLog -Text ("post-send screenshot failed: {0}" -f $shot.Error)
  }

  $sent = [bool]($editorEmptied -or $selfCount -gt $selfBefore)
  $confirmed = [bool]($editorEmptied -and ($selfCount -gt $selfBefore -or $newSelfMessage -gt 0))
  if (-not $editorEmptied) {
    [void]$notes.Add('the editor was not empty after pressing Enter: confirm in QQ before reporting success')
  }
  if ($selfCount -le $selfBefore) {
    [void]$notes.Add('no additional outgoing message container was detected; QQ may not have rendered it yet')
  }
  if ($newSelfMessage -gt 0 -and $selfCount -le $selfBefore) {
    [void]$notes.Add('the message text was found in the message area while the outgoing container count stayed the same: an identical earlier message reads the same way, so verify the conversation if this matters')
  }
  if (-not $confirmed) {
    [void]$notes.Add('send confirmation is weak: treat this result as unverified and check QQ manually')
  }

  $auditFields = [ordered]@{
    header        = [string]$after.Header
    editorEmptied = [bool]$editorEmptied
    selfBefore    = [int]$selfBefore
    selfAfter     = [int]$selfCount
    sent          = [bool]$sent
    confirmed     = [bool]$confirmed
    screenshot    = [string]$shot.Path
  }
  if ($includeText) { $auditFields['messageText'] = [string]$message.Text }

  $auditLog = ''
  if ($writeAudit) {
    $auditLog = Write-QQAuditRecord -Dir $evidenceDir -Record (Get-QQSendAuditRecord -Stage 'result' -Instance $instance -Header ([string]$after.Header) -ExpectNick $expectNick -Message $auditMessage -Extra $auditFields)
  }

  $data = [ordered]@{
    dryRun            = $false
    sent              = [bool]$sent
    confirmed         = [bool]$confirmed
    account           = (Get-QQAccountSummary -Instance $instance)
    accountGuard      = [string]$accountGuard
    header            = [string]$after.Header
    expectNick        = [string]$expectNick
    isGroup           = [bool]$after.IsGroup
    editorPresent     = [bool]$after.EditorPresent
    editorEmptied     = [bool]$editorEmptied
    selfMsgVisible    = [bool]($selfCount -gt 0)
    selfMsgCount      = [int]$selfCount
    selfMsgDelta      = [int]($selfCount - $selfBefore)
    messageLength     = [int]$message.Length
    messageHash       = [string]$message.Hash
    messageSource     = [string]$message.Source
    messagePreview    = $(if ($includeText) { [string]$message.Text } else { '' })
    screenshot        = $screenshot
    auditLog          = [string]$auditLog
    notes             = @($notes)
  }

  Write-QQLog -Text ("send finished: sent={0} confirmed={1} editorEmptied={2} selfDelta={3}" -f $sent, $confirmed, $editorEmptied, ($selfCount - $selfBefore))
  return @{ Data = $data; Pid = [int]$instance.Pid }
}
