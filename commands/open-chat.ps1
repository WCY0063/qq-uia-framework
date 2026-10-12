# =============================================================================
# commands/open-chat.ps1 - L1 stage one of the send SOP.
# Authority: docs/FRAMEWORK-DESIGN.md 4.2 and 6.4; docs/AGENT-MANUAL.md 4.1
#
# This command TYPES NOTHING AND SENDS NOTHING. Its whole purpose is to make the
# destination verifiable before any send: switch the conversation, prove the
# switch took effect, and leave a screenshot the agent must actually look at.
#
# It is also the only place a conversation switch is allowed to happen in the send
# path, so send-message never navigates.
#
# Contract with the dispatcher: defines functions only, defines
# Invoke-QQCommand -Context <hashtable>, returns @{ Data; Pid }, writes nothing to
# stdout.
#
# ASCII-ONLY SOURCE. run-tests.ps1 enforces this rule.
# =============================================================================

function Invoke-QQCommand {
  <#
  .SYNOPSIS
    L1 open-chat: opens a conversation, verifies it, and captures evidence.
  .DESCRIPTION
    Every field the send SOP checks is produced here: header (must equal
    -ExpectNick exactly, which is also what headerMatches reports), isGroup (must
    be false), editorPresent (must be true), and screenshot (must be opened and
    compared against the expected nickname by the agent before it calls
    send-message).

    headerChanged is evidence, not a requirement. It is false when the requested
    conversation was already open, and that is a successful, verified open - which
    is exactly why the field to judge destination by is headerMatches. Read
    headerChanged only to see whether this call actually switched anything.
  .PARAMETER Context
    Dispatcher context hashtable.
  .OUTPUTS
    Hashtable with Data (account, header, verification fields, screenshot) and Pid.
  #>
  param($Context)

  $pidValue = Get-QQIntArg -Name 'SenderPid' -Default 0 -Min 1
  $accountArg = Get-QQStringArg -Name 'Account'
  $expectNick = Get-QQStringArg -Name 'ExpectNick' -Required
  $targetId = Get-QQStringArg -Name 'TargetId'
  $searchId = Get-QQStringArg -Name 'SearchId'
  $expectAccount = Get-QQStringArg -Name 'ExpectAccountNick'
  $allowSameHeader = Test-QQArgSwitch -Name 'AllowSameHeader'
  $noScreenshot = Test-QQArgSwitch -Name 'noScreenshot'

  $instance = Get-QQInstanceContext -TargetPid $pidValue -Account $accountArg -Config $Context.Config
  $script:QQ_PID = [int]$instance.Pid
  Assert-QQAccountExpected -Instance $instance -ExpectAccountNick $expectAccount -Config $Context.Config
  Write-QQLog -Text ("instance pid {0}: account '{1}'" -f $instance.Pid, $instance.Identity.Nick)

  # -TimeoutSec (timeouts.defaultSec from config.json unless the caller overrides
  # it) caps every stage wait below.
  $timeouts = Get-QQEffectiveTimeouts -Timeouts $Context.Timeouts -TimeoutSec ([int]$Context.TimeoutSec)
  $open = Open-QQConversation -Instance $instance -ExpectNick $expectNick -TargetId $targetId -SearchId $searchId -Timeouts $timeouts -Config $Context.Config -AllowSameHeader:$allowSameHeader
  $state = Get-QQOpenChatState -Instance $instance
  # The header is deliberately NOT re-asserted here: Open-QQConversation returns
  # only when the header equals -ExpectNick (it requires the switch plus the exact
  # match, and its already-open short circuit matches before returning), so a
  # second Assert-QQHeaderMatches would re-test the same fact against a re-read
  # node list and report it as if it were an independent check.

  $warnings = New-Object System.Collections.ArrayList
  foreach ($n in @($open.Notes)) { [void]$warnings.Add([string]$n) }
  if ([bool]$state.IsGroup) {
    [void]$warnings.Add('this is a group conversation: send-message will refuse it (FRAMEWORK-DESIGN 6.3)')
  }
  if (-not [bool]$state.EditorPresent) {
    [void]$warnings.Add('no message editor in this conversation: send-message will refuse it')
  }

  $screenshot = $null
  if (-not $noScreenshot) {
    Start-Sleep -Milliseconds 300
    $dir = [string]$Context.EvidenceDir
    # evidence.keepLatestAliases controls the fixed-name copy the agent reads as
    # "the newest evidence"; false keeps only the timestamped file.
    $keepAlias = $true
    if ($Context.Config.ContainsKey('KeepLatestAliases')) { $keepAlias = [bool]$Context.Config['KeepLatestAliases'] }
    $shot = Save-QQWindowScreenshot -Hwnd $instance.Window.Hwnd -Dir $dir -Kind 'open-chat' -TargetPid $instance.Pid -Alias 'last-open-chat' -KeepAlias $keepAlias
    if (-not [string]::IsNullOrEmpty([string]$shot.Error)) {
      [void]$warnings.Add(('screenshot failed: {0}' -f $shot.Error))
      Write-QQLog -Text ("screenshot failed: {0}" -f $shot.Error)
    }
    $screenshot = [ordered]@{
      path      = [string]$shot.Path
      aliasPath = [string]$shot.AliasPath
      width     = [int]$shot.Width
      height    = [int]$shot.Height
      error     = [string]$shot.Error
    }
  } else {
    [void]$warnings.Add('-noScreenshot was used: no visual evidence was captured, so the destination is verified by JSON fields only')
  }

  $data = [ordered]@{
    account        = (Get-QQAccountSummary -Instance $instance)
    header         = [string]$state.Header
    headerBefore   = [string]$open.HeaderBefore
    headerChanged  = [bool]$open.HeaderChanged
    expectNick     = [string]$expectNick
    headerMatches  = [bool]($state.Header -ceq $expectNick)
    openedVia      = [string]$open.OpenedVia
    rowLabel       = [string]$open.RowLabel
    isGroup        = [bool]$state.IsGroup
    editorPresent  = [bool]$state.EditorPresent
    sendButtonPresent = [bool]$state.SendButtonPresent
    screenshot     = $screenshot
    sent           = $false
    warnings       = @($warnings)
    nextStep       = 'open data.screenshot, confirm the title and the counterpart, then call send-message with the same -ExpectNick'
  }

  return @{ Data = $data; Pid = [int]$instance.Pid }
}
