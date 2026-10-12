# =============================================================================
# commands/identify.ps1 - L0 account enumeration.
# Authority: docs/FRAMEWORK-DESIGN.md 4.2; docs/AGENT-MANUAL.md 4.3
#
# This is the source of every valid -SenderPid. The manual forbids reusing a pid
# from an earlier session, guessing one, or picking "the largest window", because
# several accounts can be signed in at once on one machine. The `accounts` command
# reports the same instances grouped by configured account, but only identify
# reports the per-instance account card for every window it finds.
#
# Until accounts[] is configured this stays the ground truth an -Account value is
# matched against: -Account takes a configured alias, a nickname or a QQ id, and
# the nickname side of that match is exactly the nick reported here.
#
# Read-only: enumerates QQ windows and reads each instance's own account card. It
# never launches, restarts or stops a QQ process, never clicks, never focuses,
# never types.
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
    L0 identify: enumerates every QQ instance and its signed-in account.
  .DESCRIPTION
    One entry per visible QQ window. The nickname comes from the instance's own
    avatar element, which is the only per-instance identity evidence; window size
    and start order are never used (AGENT-MANUAL 4.3). An instance whose UIA tree
    is not activated still appears, with nodeCount reported, so "no account found"
    is distinguishable from "accessibility is off".
    alias/matchedBy say which config.json account the instance answers to, so a
    caller can check its own alias table against reality; '' means the instance is
    not bound to any enabled account entry.
  .PARAMETER Context
    Dispatcher context hashtable.
  .OUTPUTS
    Hashtable with Data (instances, count, activeCount) and Pid (set only when
    exactly one instance is signed in).
  #>
  param($Context)

  $config = $Context.Config
  $instances = New-Object System.Collections.ArrayList
  $active = New-Object System.Collections.ArrayList

  foreach ($live in @(Get-QQLiveInstances -Config $config)) {
    $bind = Find-QQConfiguredAccountForNick -Config $config -Nick ([string]$live.nick)
    $record = [ordered]@{
      pid            = [int]$live.pid
      hwnd           = [int64]$live.hwnd
      title          = [string]$live.title
      width          = [int]$live.width
      height         = [int]$live.height
      scale          = [double]$live.scale
      nodeCount      = [int]$live.nodeCount
      nick           = [string]$live.nick
      signature      = [string]$live.signature
      online         = [bool]$live.online
      a11yActive     = [bool]$live.a11yActive
      identitySource = [string]$live.identitySource
      alias          = $(if ($null -ne $bind.Entry) { [string]$bind.Entry['Alias'] } else { '' })
      matchedBy      = [string]$bind.MatchedBy
    }
    [void]$instances.Add($record)
    if (-not [string]::IsNullOrEmpty([string]$live.nick)) { [void]$active.Add($record) }
  }

  $warning = ''
  if ($instances.Count -eq 0) {
    $warning = 'No visible QQ window found.'
  } elseif ($active.Count -eq 0) {
    $warning = 'A QQ window exists but no account could be read. Its accessibility tree may be inactive; run doctor.'
  } elseif ($active.Count -gt 1) {
    $warning = 'More than one account is signed in. Pick the pid by nickname before any send; never by window size or start order.'
  }

  $data = [ordered]@{
    instances   = @($instances)
    count       = [int]$instances.Count
    activeCount = [int]$active.Count
    warning     = [string]$warning
  }

  # A pid is reported only for an unambiguous single account: the envelope's pid
  # field is then itself the answer to "which instance".
  $reportPid = $null
  if ($active.Count -eq 1) { $reportPid = [int]$active[0].pid }

  return @{ Data = $data; Pid = $reportPid }
}
