# =============================================================================
# commands/accounts.ps1 - L0 account registry report.
# Authority: docs/FRAMEWORK-DESIGN.md 4.2; docs/AGENT-MANUAL.md 4.3
#
# Answers "which account is actually usable right now" from the two halves the
# framework keeps apart by design: the alias table in config.json accounts[] (what
# the operator calls an account) and the live instances' own avatar nicknames (who
# is really signed in). Neither half alone can be trusted for a send, so this
# command reports the binding and never resolves an instance itself.
#
# Read-only: one window enumeration for the whole report. It never launches,
# restarts or stops a QQ process, never clicks, never focuses, never types.
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
    L0 accounts: lists the configured accounts and how each one is bound live.
  .DESCRIPTION
    Every entry of config.json accounts[] is reported, including disabled ones, and
    every entry is bound against ONE enumeration of the visible QQ windows, so the
    report cannot mix two snapshots.

    status is the whole answer for a caller choosing -Account:
      ok          exactly one live instance is signed in as the entry's Nick
      ambiguous   more than one is: -Account would refuse this entry, pass -SenderPid
      not-running no live instance is signed in as it (not logged in, or its
                  accessibility tree is not activated)
      disabled    enabled=false: excluded from -Account resolution entirely

    live.found means "bound to exactly one instance"; for ambiguous it is false and
    live.candidates carries the instances that collided. unbound lists the live
    instances that no enabled entry describes, which is what an operator needs in
    order to write the accounts[] block in the first place.
  .PARAMETER Context
    Dispatcher context hashtable.
  .OUTPUTS
    Hashtable with Data (accounts, count, defaultAccount, unbound) and Pid = null:
    this is not a single-instance command.
  #>
  param($Context)

  $config = $Context.Config
  $filter = Get-QQStringArg -Name 'Account'

  $entries = @(Get-QQConfigAccounts -Config $config)
  $defaultAccount = ''
  if ($null -ne $config -and $config.ContainsKey('DefaultAccount')) { $defaultAccount = [string]$config['DefaultAccount'] }
  $warning = ''
  if ($null -ne $config -and $config.ContainsKey('AccountsWarning')) { $warning = [string]$config['AccountsWarning'] }

  $selected = @($entries)
  if (-not [string]::IsNullOrEmpty($filter)) {
    $selected = @($entries | Where-Object { Test-QQAccountEntryMatches -Entry $_ -Value $filter })
    if (@($selected).Count -eq 0) {
      $available = @($entries | ForEach-Object { [string]$_['Alias'] })
      throw (New-QQErrorRecord -Code 'NOT_FOUND' -Message ("-Account '{0}' matches no configured account" -f $filter) -Details @{ account = [string]$filter; availableAliases = @($available); fix = 'run accounts without -Account to list every configured account' })
    }
  }

  $live = @(Get-QQLiveInstances -Config $config)

  $report = New-Object System.Collections.ArrayList
  foreach ($entry in $selected) {
    $enabled = [bool]$entry['Enabled']
    $status = 'disabled'
    $liveBlock = $null
    if ($enabled) {
      $hits = @($live | Where-Object { -not [string]::IsNullOrEmpty([string]$_.nick) -and [string]$_.nick -ceq [string]$entry['Nick'] })
      if ($hits.Count -eq 1) {
        $status = 'ok'
        $liveBlock = [ordered]@{
          found      = $true
          pid        = [int]$hits[0].pid
          hwnd       = [int64]$hits[0].hwnd
          liveNick   = [string]$hits[0].nick
          online     = [bool]$hits[0].online
          a11yActive = [bool]$hits[0].a11yActive
          nodeCount  = [int]$hits[0].nodeCount
          candidates = @()
        }
      } elseif ($hits.Count -eq 0) {
        $status = 'not-running'
        $liveBlock = [ordered]@{
          found      = $false
          pid        = $null
          hwnd       = $null
          liveNick   = ''
          online     = $false
          a11yActive = $false
          nodeCount  = 0
          candidates = @()
        }
      } else {
        $status = 'ambiguous'
        $liveBlock = [ordered]@{
          found      = $false
          pid        = $null
          hwnd       = $null
          liveNick   = ''
          online     = $false
          a11yActive = $false
          nodeCount  = 0
          candidates = @($hits | ForEach-Object { [ordered]@{ pid = [int]$_.pid; hwnd = [int64]$_.hwnd; nick = [string]$_.nick } })
        }
        Write-QQLog -Text ("account '{0}' is ambiguous: {1} instances are signed in as '{2}'" -f [string]$entry['Alias'], $hits.Count, [string]$entry['Nick'])
      }
    }

    [void]$report.Add([ordered]@{
      alias     = [string]$entry['Alias']
      nick      = [string]$entry['Nick']
      qqId      = [string]$entry['QqId']
      enabled   = [bool]$enabled
      note      = [string]$entry['Note']
      isDefault = [bool](Test-QQAccountEntryMatches -Entry $entry -Value $defaultAccount)
      live      = $liveBlock
      status    = [string]$status
    })
  }

  $unbound = New-Object System.Collections.ArrayList
  foreach ($instance in $live) {
    if ([string]::IsNullOrEmpty([string]$instance.nick)) { continue }
    $bind = Find-QQConfiguredAccountForNick -Config $config -Nick ([string]$instance.nick)
    if ($null -ne $bind.Entry) { continue }
    [void]$unbound.Add([ordered]@{ pid = [int]$instance.pid; nick = [string]$instance.nick })
  }

  $okCount = 0
  foreach ($row in $report) { if ([string]$row['status'] -eq 'ok') { $okCount++ } }

  $data = [ordered]@{
    accounts        = @($report)
    count           = [int]@($report).Count
    okCount         = [int]$okCount
    defaultAccount  = [string]$defaultAccount
    accountsWarning = [string]$warning
    unbound         = @($unbound)
    note            = 'status ok = -Account resolves cleanly; ambiguous = more than one instance is signed in as that nick, use -SenderPid; not-running = the account is not signed in or its accessibility tree is inactive; disabled = excluded from -Account resolution'
  }

  Write-QQLog -Text ("{0} configured account(s) reported, {1} resolvable by -Account, {2} unbound instance(s)" -f @($report).Count, $okCount, @($unbound).Count)

  # Not a single-instance command: no pid is claimed, because the report covers
  # every configured account at once.
  return @{ Data = $data; Pid = $null }
}
