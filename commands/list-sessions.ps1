# =============================================================================
# commands/list-sessions.ps1 - L0 conversation list of one instance.
# Authority: docs/FRAMEWORK-DESIGN.md 4.2
#
# Read-only: reads the rendered conversation list of an instance that was named
# by pid. It never launches, restarts or stops a QQ process, never clicks, never
# focuses, never types, and never changes the selected conversation.
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
    L0 list-sessions: reads one instance's conversation list.
  .DESCRIPTION
    The instance comes from -SenderPid (which the manual requires to be a pid
    `identify` reported in the same session), from -Account, or from config.json
    defaultAccount; the resolution order lives in Get-QQInstanceContext. -Limit
    keeps the most recently active conversations, which is the order the list is
    rendered in.
  .PARAMETER Context
    Dispatcher context hashtable.
  .OUTPUTS
    Hashtable with Data (account, sessions, counts) and Pid.
  #>
  param($Context)

  $pidValue = Get-QQIntArg -Name 'SenderPid' -Default 0 -Min 1
  $accountArg = Get-QQStringArg -Name 'Account'
  $limit = Get-QQIntArg -Name 'Limit' -Default 50 -Min 1 -Max 1000

  $instance = Get-QQInstanceContext -TargetPid $pidValue -Account $accountArg -Config $Context.Config
  Write-QQLog -Text ("instance pid {0}: {1} UIA nodes, account '{2}'" -f $instance.Pid, $instance.NodeCount, $instance.Identity.Nick)

  $sessions = @(Get-QQSessionRows -Root $instance.Root -Nodes $instance.Nodes | Where-Object { -not [string]::IsNullOrEmpty([string]$_.title) })
  $total = $sessions.Count
  $selected = 0
  $unreadTotal = 0
  foreach ($s in $sessions) {
    if ([bool]$s.selected) { $selected++ }
    $unreadTotal += [int]$s.unread
  }

  # -Limit keeps the rows at the top of the list, which is the recency order QQ
  # renders them in.
  $result = @($sessions | Select-Object -First $limit)

  $data = [ordered]@{
    account     = (Get-QQAccountSummary -Instance $instance)
    sessions    = @($result)
    count       = [int]@($result).Count
    totalInList = [int]$total
    selectedCount = [int]$selected
    unreadTotal = [int]$unreadTotal
    note        = 'rows are rendered top-to-bottom in recency order; the pane is virtualized so very old conversations may be absent until scrolled'
  }

  return @{ Data = $data; Pid = [int]$instance.Pid }
}
