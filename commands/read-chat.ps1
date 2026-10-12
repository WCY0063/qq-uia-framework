# =============================================================================
# commands/read-chat.ps1 - L1 open a conversation and read its messages.
# Authority: G:\work\FRAMEWORK-DESIGN.md 4.2; G:\work\AGENT-MANUAL.md 4.2
#
# Side effects: switches the selected conversation and captures one screenshot as
# evidence. It types nothing and sends nothing.
#
# Opening strategy, strongest signal first:
#   1. an exact title match in the conversation list (no search round trip)
#   2. a global search for -TargetId, or for -OpenNick when no id was given
# The header is always verified through the same change-then-match rule the send
# path uses, so a read never reports the wrong conversation as the target.
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
    L1 read-chat: opens a conversation and reads its rendered messages.
  .DESCRIPTION
    Returns the conversation header, whether it is a group, and the last -Limit
    messages in document order. The message list is virtualized, so the count
    reflects what is rendered; older history needs scrolling, which this version
    does not do.
  .PARAMETER Context
    Dispatcher context hashtable.
  .OUTPUTS
    Hashtable with Data (account, header, isGroup, messages) and Pid.
  #>
  param($Context)

  $pidValue = Get-QQIntArg -Name 'SenderPid' -Default 0 -Min 1
  $accountArg = Get-QQStringArg -Name 'Account'
  $openNick = Get-QQStringArg -Name 'OpenNick' -Required
  $targetId = Get-QQStringArg -Name 'TargetId'
  $searchId = Get-QQStringArg -Name 'SearchId'
  $expectAccount = Get-QQStringArg -Name 'ExpectAccountNick'
  $limit = Get-QQIntArg -Name 'Limit' -Default 50 -Min 1 -Max 1000

  $instance = Get-QQInstanceContext -TargetPid $pidValue -Account $accountArg -Config $Context.Config
  $script:QQ_PID = [int]$instance.Pid
  Assert-QQAccountExpected -Instance $instance -ExpectAccountNick $expectAccount -Config $Context.Config
  Write-QQLog -Text ("instance pid {0}: account '{1}'" -f $instance.Pid, $instance.Identity.Nick)

  # -TimeoutSec (timeouts.defaultSec from config.json unless overridden) caps the
  # conversation-switch wait inside the open.
  $timeouts = Get-QQEffectiveTimeouts -Timeouts $Context.Timeouts -TimeoutSec ([int]$Context.TimeoutSec)
  $open = Open-QQConversation -Instance $instance -ExpectNick $openNick -TargetId $targetId -SearchId $searchId -Timeouts $timeouts -Config $Context.Config -AllowSameHeader:$true
  Write-QQLog -Text ("open conversation '{0}' (changed={1}, via {2})" -f $open.Header, $open.HeaderChanged, $open.OpenedVia)

  $state = Get-QQOpenChatState -Instance $instance
  # The node list is re-read here rather than reused: the conversation switch
  # replaced most of the message pane's elements.
  $messages = Get-QQMessages -Root $instance.Root -Limit $limit -SelfNick ([string]$instance.Identity.Nick)

  $unreadable = 0
  foreach ($m in @($messages.Messages)) { if ([bool]$m.unreadable) { $unreadable++ } }

  $data = [ordered]@{
    account        = (Get-QQAccountSummary -Instance $instance)
    header         = [string]$state.Header
    headerBefore   = [string]$open.HeaderBefore
    headerChanged  = [bool]$open.HeaderChanged
    openedVia      = [string]$open.OpenedVia
    isGroup        = [bool]$state.IsGroup
    editorPresent  = [bool]$state.EditorPresent
    messages       = @($messages.Messages)
    count          = [int]@($messages.Messages).Count
    renderedTotal  = [int]$messages.Total
    unreadableCount = [int]$unreadable
    notes          = @($open.Notes) + @('messages are the rows QQ currently renders; the pane is virtualized, so older history is absent until scrolled')
  }

  return @{ Data = $data; Pid = [int]$instance.Pid }
}
