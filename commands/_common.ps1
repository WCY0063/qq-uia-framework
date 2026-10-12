# =============================================================================
# commands/_common.ps1 - shared command helpers (dot-sourced by qq-uia.ps1).
# Authority: docs/FRAMEWORK-DESIGN.md 4.3
#
# Every window-scoped command needs the same preamble: resolve the instance (by
# -SenderPid, by -Account, or by the configured defaultAccount), refuse to proceed
# when the accessibility tree is not activated, and read the account identity so
# the caller can see which account it is about to act on. Keeping it here means
# instance selection cannot drift between commands.
#
# ASCII-ONLY SOURCE. run-tests.ps1 enforces this rule.
# =============================================================================

function Get-QQConfigAccounts {
  <#
  .SYNOPSIS
    Returns the accounts[] entries from config.json.
  .DESCRIPTION
    Get-QQConfig normalizes entries into a fixed shape (Alias, Nick, QqId,
    Enabled, Note) and drops malformed ones. Callers go through this wrapper so
    none of them has to know that shape's provenance.
  .PARAMETER Config
    Framework config hashtable, or null.
  .PARAMETER EnabledOnly
    Return only entries whose Enabled flag is true. An entry that is disabled is
    excluded from alias/nick/id resolution but is still listed by `accounts`.
  .OUTPUTS
    [object[]] account entries, in config.json order.
  #>
  param(
    $Config = $null,
    [switch]$EnabledOnly
  )
  $all = @()
  if ($null -ne $Config -and $Config -is [System.Collections.IDictionary] -and $Config.ContainsKey('Accounts')) {
    $all = @($Config['Accounts'])
  }
  if ($EnabledOnly) { $all = @($all | Where-Object { [bool]$_['Enabled'] }) }
  return @($all)
}

function Test-QQAccountEntryMatches {
  <#
  .SYNOPSIS
    Reports whether an accounts[] entry answers to a caller-supplied name.
  .DESCRIPTION
    Alias is compared case-insensitively (it is an identifier the operator types),
    Nick is compared exactly with -ceq (it is the nickname QQ itself reports, and
    the same exactness the send guard uses), QqId is compared exactly. An empty
    field never matches: an entry that omits its Nick must not match an empty
    nickname.
  .PARAMETER Entry
    Normalized account entry.
  .PARAMETER Value
    Alias, nickname or QQ id supplied by the caller.
  .OUTPUTS
    [bool].
  #>
  param(
    $Entry = $null,
    [AllowEmptyString()][string]$Value = ''
  )
  if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace($Value)) { return $false }
  if ([string]$Entry['Alias'] -ieq $Value) { return $true }
  if (-not [string]::IsNullOrEmpty([string]$Entry['Nick']) -and [string]$Entry['Nick'] -ceq $Value) { return $true }
  if (-not [string]::IsNullOrEmpty([string]$Entry['QqId']) -and [string]$Entry['QqId'] -eq $Value) { return $true }
  return $false
}

function Find-QQConfiguredAccountForNick {
  <#
  .SYNOPSIS
    Binds a live instance nickname to a configured account entry.
  .DESCRIPTION
    Two steps, strongest signal first: an entry whose Nick equals the live
    nickname exactly (MatchedBy='nick'), then an entry whose Alias equals it
    (MatchedBy='alias'), which keeps an alias-only entry usable. MatchedBy=''
    means the instance is not bound to any enabled entry.
  .PARAMETER Config
    Framework config hashtable, or null.
  .PARAMETER Nick
    Nickname read from a live instance's avatar element.
  .OUTPUTS
    [hashtable] Entry (or $null) and MatchedBy ('nick'|'alias'|'').
  #>
  param(
    $Config = $null,
    [AllowEmptyString()][string]$Nick = ''
  )
  if ([string]::IsNullOrEmpty($Nick)) { return @{ Entry = $null; MatchedBy = '' } }
  $entries = @(Get-QQConfigAccounts -Config $Config -EnabledOnly)
  foreach ($entry in $entries) {
    if (Test-QQAccountEntryMatches -Entry $entry -Value $Nick) {
      $byNick = (-not [string]::IsNullOrEmpty([string]$entry['Nick']) -and [string]$entry['Nick'] -ceq $Nick)
      return @{ Entry = $entry; MatchedBy = $(if ($byNick) { 'nick' } else { 'alias' }) }
    }
  }
  return @{ Entry = $null; MatchedBy = '' }
}

function Get-QQLiveInstances {
  <#
  .SYNOPSIS
    Enumerates every visible QQ window and reads the account signed in to it.
  .DESCRIPTION
    One EnumWindows pass for the whole caller: -Account resolution, `identify` and
    `accounts` all need the same list, and a per-account pass would read the same
    windows once per name and could mix two snapshots. Each window's UIA tree is
    read inside its own try/catch, so one unreadable instance is reported (stderr)
    rather than failing the enumeration.
  .PARAMETER Config
    Framework config hashtable, or null.
  .OUTPUTS
    [object[]] records sorted by pid: pid, hwnd, title, width, height, scale,
    nodeCount, nick, signature, online, a11yActive, identitySource.
  #>
  param($Config = $null)
  $windows = @(Get-QQWindowList -Config $Config | Sort-Object Pid)
  Write-QQLog -Text ("visible QQ windows: {0}" -f $windows.Count)

  # One threshold for the whole enumeration, from a11y.minNodes: the same value
  # doctor uses for its readiness verdict, so "doctor says ready" and "identify
  # read the account" can no longer disagree (they used to hardcode 10 and 100 in
  # different places).
  $minNodes = Get-QQA11yMinNodes -Config $Config

  $records = New-Object System.Collections.ArrayList
  foreach ($win in $windows) {
    $nodeCount = 0
    $nick = ''
    $signature = ''
    $online = $false
    $identitySource = ''

    try {
      $root = [System.Windows.Automation.AutomationElement]::FromHandle($win.Hwnd)
      if ($null -ne $root) {
        $nodes = @(Get-QQAllNodes -Root $root)
        $nodeCount = $nodes.Count
        if (Test-QQA11yActive -NodeCount $nodeCount -MinNodes $minNodes) {
          $identity = Get-QQAccountIdentity -Root $root -Nodes $nodes
          $nick = [string]$identity.Nick
          $signature = [string]$identity.Signature
          $online = [bool]$identity.Online
          $identitySource = 'user-avatar'
          if ([string]::IsNullOrEmpty($nick)) { $identitySource = '' }
        }
      }
    } catch {
      # One unreadable instance must not fail the whole enumeration, but it is
      # reported so a missing account is not mistaken for "not signed in".
      Write-QQLog -Text ("instance pid {0} could not be read: {1}" -f $win.Pid, $_.Exception.Message)
    }

    [void]$records.Add([pscustomobject]@{
      pid            = [int]$win.Pid
      hwnd           = [int64]$win.Hwnd
      title          = [string]$win.Title
      width          = [int]$win.Width
      height         = [int]$win.Height
      scale          = [double]$win.Scale
      nodeCount      = [int]$nodeCount
      nick           = [string]$nick
      signature      = [string]$signature
      online         = [bool]$online
      a11yActive     = [bool](Test-QQA11yActive -NodeCount $nodeCount -MinNodes $minNodes)
      identitySource = [string]$identitySource
    })
  }
  return @($records)
}

function Resolve-QQAccountPid {
  <#
  .SYNOPSIS
    Resolves -Account to the pid of the instance signed in as that account.
  .DESCRIPTION
    Step 1 looks the name up in config.json accounts[]: Alias case-insensitively,
    Nick exactly, QqId exactly (enabled entries only). Step 2 enumerates the live
    instances ONCE and binds the configured Nick to the nickname the instance's own
    avatar reports, with -ceq, so a near-miss nickname cannot select an instance.

    A name that matches no configured entry is not an error: it is treated as a
    live nickname, which lets a caller that configured no accounts still address an
    instance by the nickname `identify` prints (then Account is $null). An entry
    with no Nick falls back to the caller's own value for the live comparison, so
    an alias-only entry stays usable.

    Never guesses: zero matches and more than one match are both NOT_FOUND, because
    sending from the wrong instance is worse than not sending.
  .PARAMETER Account
    Configured alias, nickname or QQ id.
  .PARAMETER Config
    Framework config hashtable, or null.
  .OUTPUTS
    [hashtable] Pid, Account (config entry or $null), Nick (live nickname).
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Account,
    $Config = $null
  )
  if ([string]::IsNullOrWhiteSpace($Account)) {
    throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message '-Account is empty: pass a configured alias, a nickname or a QQ id' -Details @{ parameter = 'Account' })
  }

  $entry = $null
  foreach ($candidate in @(Get-QQConfigAccounts -Config $Config -EnabledOnly)) {
    if (Test-QQAccountEntryMatches -Entry $candidate -Value $Account) { $entry = $candidate; break }
  }
  $targetNick = [string]$Account
  if ($null -ne $entry) {
    if (-not [string]::IsNullOrEmpty([string]$entry['Nick'])) { $targetNick = [string]$entry['Nick'] }
  } else {
    Write-QQLog -Text ("-Account '{0}' matches no configured account; treating it as a live nickname" -f $Account)
  }

  $available = @(Get-QQConfigAccounts -Config $Config -EnabledOnly | ForEach-Object { [string]$_['Alias'] })
  $hits = New-Object System.Collections.ArrayList
  foreach ($live in @(Get-QQLiveInstances -Config $Config)) {
    if ([string]::IsNullOrEmpty([string]$live.nick)) { continue }
    if ([string]$live.nick -ceq $targetNick) { [void]$hits.Add($live) }
  }

  if ($hits.Count -eq 1) {
    Write-QQLog -Text ("-Account '{0}' resolved to pid {1} (live nick '{2}')" -f $Account, [int]$hits[0].pid, [string]$hits[0].nick)
    return @{
      Pid     = [int]$hits[0].pid
      Account = $entry
      Nick    = [string]$hits[0].nick
    }
  }

  if ($hits.Count -eq 0) {
    throw (New-QQErrorRecord -Code 'NOT_FOUND' -Message ("no visible QQ instance is signed in as '{0}': the account is not logged in, or its accessibility tree is not activated (run doctor)" -f $targetNick) -Details @{ account = [string]$Account; matchedNick = [string]$targetNick; configured = ($null -ne $entry); availableAliases = @($available); fix = 'run identify to list the instances that are signed in right now' })
  }

  $candidates = @($hits | ForEach-Object { @{ pid = [int]$_.pid; hwnd = [int64]$_.hwnd; nick = [string]$_.nick } })
  throw (New-QQErrorRecord -Code 'NOT_FOUND' -Message ("{0} instances are signed in as '{1}': -Account is ambiguous, pass -SenderPid to pick one of the candidates" -f $hits.Count, $targetNick) -Details @{ account = [string]$Account; matchedNick = [string]$targetNick; candidates = @($candidates); availableAliases = @($available) })
}

function Get-QQInstanceContext {
  <#
  .SYNOPSIS
    Resolves the target instance into everything the window-scoped commands need.
  .DESCRIPTION
    The instance is selected by explicit -SenderPid first, then -Account, then
    config.json defaultAccount: a pid the caller pinned always wins, so a
    configured default can never redirect an explicitly addressed command. When
    none of the three is available the call is BAD_ARGS before any UIA access.

    Fails with NOT_FOUND when the pid has no visible QQ window and with
    ENV_NOT_READY when the window exists but its accessibility tree has fewer than
    a11y.minNodes nodes, so the agent can tell "wrong pid" from "QQ needs a restart
    to expose its tree" - and the refusal threshold is the same one doctor reports
    readiness with.
  .PARAMETER TargetPid
    The pid from -SenderPid, which must have come from `identify`; 0 means it was
    not supplied.
  .PARAMETER Account
    The -Account value: a configured alias, a nickname or a QQ id.
  .PARAMETER Config
    Framework config hashtable.
  .OUTPUTS
    [hashtable] Pid, Window, Root, Nodes, NodeCount, Scale, Identity (the live
    account read from the instance), Account (config entry, or $null) and
    AccountResolvedBy ('pid'|'account'|'default').
  #>
  param(
    [int]$TargetPid = 0,
    [AllowEmptyString()][string]$Account = '',
    $Config = $null
  )

  $resolvedPid = 0
  $resolvedBy = ''
  $entry = $null
  if ($TargetPid -gt 0) {
    $resolvedPid = [int]$TargetPid
    $resolvedBy = 'pid'
  } else {
    $requested = [string]$Account
    $viaDefault = $false
    if ([string]::IsNullOrWhiteSpace($requested)) {
      $configuredDefault = ''
      if ($null -ne $Config -and $Config.ContainsKey('DefaultAccount')) { $configuredDefault = [string]$Config['DefaultAccount'] }
      if (-not [string]::IsNullOrWhiteSpace($configuredDefault)) {
        $requested = $configuredDefault
        $viaDefault = $true
      }
    }
    if ([string]::IsNullOrWhiteSpace($requested)) {
      throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message 'no target instance: pass -SenderPid <pid from identify> or -Account <alias or nickname> (config.json defaultAccount fills this in when both are absent)' -Details @{ parameters = @('SenderPid', 'Account'); fix = 'run identify (or accounts) to list the pids and the accounts that are signed in' })
    }
    $resolved = Resolve-QQAccountPid -Account $requested -Config $Config
    $resolvedPid = [int]$resolved.Pid
    $entry = $resolved.Account
    $resolvedBy = $(if ($viaDefault) { 'default' } else { 'account' })
  }

  $win = Get-QQWindowInfo -TargetPid $resolvedPid -Config $Config
  $root = Get-QQRootElement -TargetPid $resolvedPid -Config $Config
  $nodes = @(Get-QQAllNodes -Root $root)
  # One threshold, a11y.minNodes, shared with doctor's readiness verdict: an
  # instance doctor calls ready must not be refused here, and the other way round.
  # This used to be a hardcoded 10 while doctor required 100.
  $minNodes = Get-QQA11yMinNodes -Config $Config
  if (-not (Test-QQA11yActive -NodeCount $nodes.Count -MinNodes $minNodes)) {
    throw (New-QQErrorRecord -Code 'ENV_NOT_READY' -Message ("pid {0} exposes only {1} UIA nodes, below the {2} that a11y.minNodes requires for an activated tree" -f $resolvedPid, $nodes.Count, $minNodes) -Details @{ pid = $resolvedPid; nodeCount = $nodes.Count; minNodes = $minNodes; fix = 'restart QQ with --force-renderer-accessibility, then rerun doctor' })
  }
  $scale = Get-QQScaleForPid -TargetPid $resolvedPid -Config $Config
  $identity = Get-QQAccountIdentity -Root $root -Nodes $nodes
  return @{
    Pid               = [int]$resolvedPid
    Window            = $win
    Root              = $root
    Nodes             = $nodes
    NodeCount         = [int]$nodes.Count
    Scale             = [double]$scale
    Identity          = $identity
    Account           = $entry
    AccountResolvedBy = [string]$resolvedBy
  }
}

function Get-QQAccountSummary {
  <#
  .SYNOPSIS
    Builds the account block embedded in every command payload.
  .PARAMETER Instance
    Instance hashtable from Get-QQInstanceContext.
  .OUTPUTS
    [ordered] hashtable: pid, hwnd, nick, signature, online.
  #>
  param([Parameter(Mandatory)]$Instance)
  return [ordered]@{
    pid       = [int]$Instance.Pid
    hwnd      = [int64]$Instance.Window.Hwnd
    nick      = [string]$Instance.Identity.Nick
    signature = [string]$Instance.Identity.Signature
    online    = [bool]$Instance.Identity.Online
  }
}

function Assert-QQAccountExpected {
  <#
  .SYNOPSIS
    Enforces -ExpectAccountNick, and the mandatory form of that check.
  .DESCRIPTION
    guards.requireAccountMatch in config.json makes -ExpectAccountNick required
    rather than optional for every L1/L2 command, which is the deployment-level
    switch for multi-instance environments. The check itself lives in
    lib\qq-guards.ps1; this wrapper only decides whether it runs.
  .PARAMETER Instance
    Instance hashtable from Get-QQInstanceContext.
  .PARAMETER ExpectAccountNick
    Caller-supplied nickname, possibly ''.
  .PARAMETER Config
    Framework config hashtable.
  #>
  param(
    [Parameter(Mandatory)]$Instance,
    [AllowEmptyString()][string]$ExpectAccountNick = '',
    $Config = $null
  )
  $required = $false
  if ($null -ne $Config -and $Config.ContainsKey('RequireAccountMatch')) { $required = [bool]$Config['RequireAccountMatch'] }
  if ($required -and [string]::IsNullOrWhiteSpace($ExpectAccountNick)) {
    throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message 'config guards.requireAccountMatch is on: -ExpectAccountNick is required for this command' -Details @{ parameter = 'ExpectAccountNick' })
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectAccountNick)) {
    [void](Assert-QQAccountMatches -AccountNick ([string]$Instance.Identity.Nick) -ExpectAccountNick $ExpectAccountNick)
  }
}

function Test-QQComprehensiveSearchRow {
  <#
  .SYNOPSIS
    Reports whether a search result row is the "search everything" entry.
  .DESCRIPTION
    QQ renders an umbrella entry as the first result for any keyword. It is not a
    contact, group or history hit, so it is reported separately and never mixed
    into the result list, which would otherwise make the first real result look
    like a duplicate of nothing.

    The marker is assembled in exactly one place, Get-QQUiText key
    'comprehensiveSearch'. The Name-prefix test stays even though selectors.psd1
    now anchors Search.ResultItem: the anchor keeps the umbrella row out of the
    result set, and this test keeps the umbrella row recognisable if a build
    changes the class spelling.
  .PARAMETER Element
    Result row element.
  .OUTPUTS
    [bool] true when the row is the umbrella entry.
  #>
  param([Parameter(Mandatory)]$Element)
  $name = ''
  try { $name = [string]$Element.Current.Name } catch { return $false }
  $marker = Get-QQUiText -Key 'comprehensiveSearch'
  if ([string]::IsNullOrEmpty($name) -or [string]::IsNullOrEmpty($marker)) { return $false }
  return $name.StartsWith($marker)
}

function Set-QQSearchKeyword {
  <#
  .SYNOPSIS
    Writes a keyword into the global search box and waits for real result rows.
  .DESCRIPTION
    The search box is a real input with a ValuePattern, but it does not trigger a
    search until it has focus, so the window is foregrounded and the box focused
    first. The wait requires at least one row that is NOT the umbrella entry: QQ
    paints that entry immediately and the real hits only after its own remote
    lookup, so stopping at the first row would report a search as settled while it
    is still empty.

    The keyword must be TYPED. Clearing through the pattern is fine, but writing the
    keyword straight into the element renders only the umbrella row, so a failed
    read-back is a TIMEOUT: the old value-pattern fallback made the box look right
    while QQ rendered no hits, and the caller then waited out the whole budget and
    reported an empty search as a real answer.

    The quiet period is measured from the last time the real-row count CHANGED, so a
    batched, slow render is not truncated at a fixed delay after its first row. The
    whole wait still stops at timeouts.searchResultsMs.
  .PARAMETER Instance
    Instance hashtable from Get-QQInstanceContext.
  .PARAMETER Keyword
    Text to search for.
  .PARAMETER Timeouts
    Timeout table from the dispatcher context.
  .PARAMETER Config
    Framework config hashtable, used for the per-character typing delay.
  .PARAMETER QuietMs
    Time to keep polling after the real-row count last changed, so a multi-hit
    search is not truncated to its first hit.
  .OUTPUTS
    [hashtable] Rows (real result rows, umbrella row excluded), AllRows (every row
    read, umbrella row included, in render order), UmbrellaRow, SearchValue,
    SearchValueNote, Settled.
  #>
  param(
    [Parameter(Mandatory)]$Instance,
    [Parameter(Mandatory)][string]$Keyword,
    [Parameter(Mandatory)]$Timeouts,
    $Config = $null,
    [int]$QuietMs = 3000
  )
  [void](Invoke-QQWindowFocus -Hwnd $Instance.Window.Hwnd)
  Start-Sleep -Milliseconds ([int]$Timeouts.afterFocusMs)

  $search = Get-QQNode -Root $Instance.Root -Section 'Nav' -Name 'SearchInput'
  if ($null -eq $search) {
    throw (New-QQErrorRecord -Code 'NOT_FOUND' -Message 'the global search box was not found in this QQ window' -Details @{ pid = $Instance.Pid })
  }
  if (-not (Set-QQElementFocus -Element $search)) {
    throw (New-QQErrorRecord -Code 'TIMEOUT' -Message 'the global search box could not be focused; keyboard and value writes would not reach it' -Details @{ pid = $Instance.Pid })
  }

  $value = $null
  try {
    $value = $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($value.Current.IsReadOnly) {
      throw (New-QQErrorRecord -Code 'ENV_NOT_READY' -Message 'the global search box reports read-only' -Details @{ pid = $Instance.Pid })
    }
    # Clearing through the pattern is fine, but the keyword must be TYPED: QQ
    # renders only the umbrella row when the value is written straight into the
    # element, and real results appear once real keystrokes reach it.
    $value.SetValue('')
    Start-Sleep -Milliseconds 250
  } catch {
    if ($_.Exception.Data.Contains('QQCode')) { throw }
    throw (New-QQErrorRecord -Code 'ERROR' -Message ("preparing the search box failed: {0}" -f $_.Exception.Message) -Details @{ pid = $Instance.Pid; keyword = $Keyword })
  }

  [void](Send-QQText -Text $Keyword -DelayMs (Get-QQTypingDelayMs -Config $Config))
  Start-Sleep -Milliseconds 400
  $typed = ''
  try { $typed = [string]$value.Current.Value } catch { $typed = '' }
  if ($typed -ne $Keyword) {
    # The keystrokes were dropped (the box lost focus mid-typing). There is no
    # fallback that produces real results: a value-pattern write renders only the
    # umbrella row, so reporting an empty search would be a false negative.
    throw (New-QQErrorRecord -Code 'TIMEOUT' -Message ("the typed keyword did not land in the search box: expected '{0}', the box reads '{1}'" -f $Keyword, $typed) -Details @{ pid = $Instance.Pid; keyword = $Keyword; readback = [string]$typed; fix = 'make sure the QQ window can take focus and nothing is typing into it, then retry' })
  }

  $deadline = (Get-Date).AddMilliseconds([int]$Timeouts.searchResultsMs)
  $rows = @()
  $real = @()
  $lastRealCount = -1
  $lastChangeAt = $null
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $fresh = @(Get-QQAllNodes -Root $Instance.Root)
    # Two reads on purpose. Search.ResultItem is anchored, so it yields real rows
    # only; the umbrella row has its own selector, and merging both is what keeps
    # umbrellaEntry populated and -Activate 1 clickable. The Name-prefix filter
    # below is still what decides who is the umbrella row. The umbrella rows are
    # listed first because that is where QQ renders that entry; AllRows is handed
    # back in render order.
    $rows = @(Get-QQNodes -Root $Instance.Root -Section 'Search' -Name 'UmbrellaRow' -Nodes $fresh)
    $rows += @(Get-QQNodes -Root $Instance.Root -Section 'Search' -Name 'ResultItem' -Nodes $fresh)
    $real = @($rows | Where-Object { -not (Test-QQComprehensiveSearchRow -Element $_) })
    if ($real.Count -gt 0) {
      if ($real.Count -ne $lastRealCount) {
        $lastRealCount = $real.Count
        $lastChangeAt = Get-Date
      }
      if (((Get-Date) - $lastChangeAt).TotalMilliseconds -ge $QuietMs) { break }
    }
  }

  $umbrella = $null
  foreach ($row in $rows) {
    if (Test-QQComprehensiveSearchRow -Element $row) { $umbrella = $row; break }
  }

  # A failed read-back is reported as empty, never as the keyword the caller asked
  # for: echoing the request back would say "the box carries your keyword" while the
  # search on screen may say something else.
  $currentValue = ''
  $valueNote = ''
  try {
    $currentValue = [string]$value.Current.Value
  } catch {
    $currentValue = ''
    $valueNote = 'the search box value could not be read back after the search; searchValue is reported as empty rather than as the requested keyword'
  }
  return @{
    Rows            = @($real)
    AllRows         = @($rows)
    UmbrellaRow     = $umbrella
    SearchValue     = [string]$currentValue
    SearchValueNote = [string]$valueNote
    Settled         = [bool]($real.Count -gt 0)
  }
}

function Wait-QQSearchPanel {
  <#
  .SYNOPSIS
    Waits for the comprehensive-search panel and reads the rows it renders.
  .DESCRIPTION
    Clicking the umbrella entry is the only way to reach real hits on a build whose
    dropdown renders nothing else, and the panel is a separate surface from the
    dropdown. Its container class is NOT verified on QQNT 9.9.35 (the tested
    keywords only ever rendered the umbrella row), which is why Search.Panel is
    Stable=$false: when the container is never seen, Found stays false and the
    caller reports the dropdown rows it already has instead of presenting rows it
    never read.

    The rows are read from inside the container only. The panel and the dropdown
    share a class family, so scoping the read to the container is what keeps the two
    surfaces from being merged by accident.
  .PARAMETER Instance
    Instance hashtable from Get-QQInstanceContext.
  .PARAMETER Timeouts
    Timeout table from the dispatcher context; searchResultsMs bounds the wait.
  .OUTPUTS
    [hashtable] Found, Panel, Rows, Note.
  #>
  param(
    [Parameter(Mandatory)]$Instance,
    [Parameter(Mandatory)]$Timeouts
  )
  $deadline = (Get-Date).AddMilliseconds([int]$Timeouts.searchResultsMs)
  $panel = $null
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $nodes = @(Get-QQAllNodes -Root $Instance.Root)
    $panel = Get-QQNode -Root $Instance.Root -Section 'Search' -Name 'Panel' -Nodes $nodes
    if ($null -ne $panel) { break }
  }
  if ($null -eq $panel) {
    return @{
      Found = $false
      Panel = $null
      Rows  = @()
      Note  = 'the comprehensive search panel was not found before the wait expired (Search.Panel is Stable=false and unverified on this build); the inline dropdown rows are reported instead'
    }
  }
  $panelNodes = @(Get-QQAllNodes -Root $panel)
  $rows = @(Get-QQNodes -Root $panel -Section 'Search' -Name 'PanelItem' -Nodes $panelNodes)
  return @{ Found = $true; Panel = $panel; Rows = @($rows); Note = '' }
}

function Close-QQSearchSurface {
  <#
  .SYNOPSIS
    Dismisses the search dropdown / comprehensive-search panel with Escape.
  .DESCRIPTION
    Both surfaces float over the conversation list, so leaving one open makes the
    next physical click (a session row, the send button) land on the overlay instead
    of on its target. Escape dismisses them without reverting a selection a click has
    already made, which is why the open path may call this right after choosing a
    conversation.

    A failed Escape is never fatal: it is logged and reported as Closed=false. The
    command already has its answer, and a cleanup failure must not replace it with an
    error.

    When an instance is supplied, Closed means the surface was observed to be gone
    (no result rows rendered), not merely that the key was injected. The judgement is
    made on the ROWS, never on the panel container: the container class is a guess
    that may match a permanent element, while a row only exists while a search is on
    screen.
  .PARAMETER Instance
    Instance hashtable from Get-QQInstanceContext, or $null to skip confirmation.
  .PARAMETER SettleMs
    Time to let the click or the search settle before the key is injected, so the
    Escape is not swallowed by a pending UI transition.
  .PARAMETER VerifyMs
    How long to keep re-reading the tree while waiting for the rows to disappear.
  .OUTPUTS
    [hashtable] Closed, Error.
  #>
  param(
    $Instance = $null,
    [int]$SettleMs = 300,
    [int]$VerifyMs = 900
  )
  try {
    if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }
    $events = Send-QQEscape
    if ([int]$events -le 0) {
      Write-QQLog -Text 'Escape could not be injected to dismiss the search surface'
      return @{ Closed = $false; Error = 'the Escape key could not be injected' }
    }
  } catch {
    $message = $_.Exception.Message
    Write-QQLog -Text ("Escape could not be sent to dismiss the search surface: {0}" -f $message)
    return @{ Closed = $false; Error = [string]$message }
  }
  if ($null -eq $Instance) { return @{ Closed = $true; Error = '' } }

  $deadline = (Get-Date).AddMilliseconds([math]::Max(0, $VerifyMs))
  while ($true) {
    Start-Sleep -Milliseconds 300
    $nodes = @(Get-QQAllNodes -Root $Instance.Root)
    $rows = @(Get-QQNodes -Root $Instance.Root -Section 'Search' -Name 'ResultItem' -Nodes $nodes)
    $panelRows = @(Get-QQNodes -Root $Instance.Root -Section 'Search' -Name 'PanelItem' -Nodes $nodes)
    if ($rows.Count -eq 0 -and $panelRows.Count -eq 0) { return @{ Closed = $true; Error = '' } }
    if ((Get-Date) -ge $deadline) { break }
  }
  return @{ Closed = $false; Error = 'the search surface is still rendered after Escape' }
}

function Get-QQSearchResultRecord {
  <#
  .SYNOPSIS
    Parses a search result row into kind/name/detail/qqId.
  .DESCRIPTION
    QQ encodes the result identity and its context in the row's Name, in one of
    three shapes:
      contact      '<nick> (<QQ id>) <source label> ...'
      group        '<group> (N <member unit>) <contains label> <QQ id>'
      chat history '<nick> N <records label>'
    Classification reads those shapes. The history shape additionally requires the
    localized records marker (Get-QQUiText 'historyUnit'): a "<name> <number>" Name
    is not enough, because ordinary rows carry trailing numbers too and the loose
    regex used to misclassify them as chat history.

    The Name is also sometimes empty for the first contact row (a render-timing
    artifact), so position is preserved and an empty name is reported rather than
    the row being dropped.

    qqId carries the id only when the row states one unambiguously (the contact
    shape). It is the identity half of the dedupe key, so inventing one from a
    looser match would merge two different targets.
  .PARAMETER Element
    Result row element.
  .PARAMETER Index
    Zero-based position in the result list (render order, which is also the order
    the rows can be clicked in).
  .OUTPUTS
    [ordered] hashtable: index, kind, name, detail, qqId, raw.
  #>
  param(
    [Parameter(Mandatory)]$Element,
    [int]$Index = 0
  )
  $raw = ''
  try { $raw = [string]$Element.Current.Name } catch { $raw = '' }

  $kind = 'unknown'
  $name = $raw
  $detail = ''
  $qqId = ''

  $contact = [regex]::Match($raw, '^(?<name>.*?)\s*\((?<id>\d+)\)\s*(?<detail>.*)$')
  if ($contact.Success -and $contact.Groups['id'].Value -ne '') {
    $qqId = [string]$contact.Groups['id'].Value
    $name = $contact.Groups['name'].Value.Trim()
    $detail = ($qqId + ' ' + [string]$contact.Groups['detail'].Value).Trim()
    return [ordered]@{ index = [int]$Index; kind = 'contact'; name = [string]$name; detail = [string]$detail; qqId = [string]$qqId; raw = [string]$raw }
  }

  $group = [regex]::Match($raw, '^(?<name>.*?)\s*\((?<count>\d+)(?<unit>[^)]*)\)\s*(?<detail>.*)$')
  if ($group.Success) {
    $name = $group.Groups['name'].Value.Trim()
    $detail = ((([string]$group.Groups['count'].Value + [string]$group.Groups['unit'].Value).Trim()) + ' ' + [string]$group.Groups['detail'].Value).Trim()
    return [ordered]@{ index = [int]$Index; kind = 'group'; name = [string]$name; detail = [string]$detail; qqId = ''; raw = [string]$raw }
  }

  $historyUnit = Get-QQUiText -Key 'historyUnit'
  if (-not [string]::IsNullOrEmpty($historyUnit) -and $raw.Contains($historyUnit)) {
    $history = [regex]::Match($raw, '^(?<name>.+?)\s+(?<count>\d+)\s*(?<unit>.*)$')
    if ($history.Success -and $history.Groups['count'].Value -ne '' -and
        $history.Groups['name'].Value.Trim() -ne '' -and
        $history.Groups['unit'].Value.Contains($historyUnit)) {
      $name = $history.Groups['name'].Value.Trim()
      $detail = (([string]$history.Groups['count'].Value + ' ' + [string]$history.Groups['unit'].Value).Trim())
      return [ordered]@{ index = [int]$Index; kind = 'history'; name = [string]$name; detail = [string]$detail; qqId = ''; raw = [string]$raw }
    }
  }

  return [ordered]@{ index = [int]$Index; kind = [string]$kind; name = [string]$name; detail = [string]$detail; qqId = [string]$qqId; raw = [string]$raw }
}

function Merge-QQSearchResultRecords {
  <#
  .SYNOPSIS
    Deduplicates parsed result records and orders them by kind.
  .DESCRIPTION
    One search can report the same target twice: the dropdown and the comprehensive
    panel can both render it, and QQ re-renders a row while its list stabilizes. The
    dedupe key is kind + name + qqId, so a contact found through two surfaces
    collapses into one entry.

    A record with neither a name nor a QQ id is never merged: every unreadable row
    shares the empty key, and collapsing those would silently drop hits (an empty
    Name on the first contact row is a known QQ render-timing artifact, and every
    unmatched row is kept as kind 'unknown').

    The order is contact, group, history, then anything unrecognised, and stable
    inside a kind. Sort-Object is not guaranteed stable on PowerShell 5.1, so the
    buckets are built by hand. Every record keeps its original render position in
    'index', which is also the position a click has to use, so ordering here cannot
    break a caller that navigates by position.
  .PARAMETER Records
    Records from Get-QQSearchResultRecord, in render order.
  .PARAMETER Limit
    Maximum number of records to return, or 0 for no limit. It is applied AFTER
    dedupe and ordering, so the limit counts distinct results.
  .OUTPUTS
    [hashtable] Results (ordered records), DuplicatesRemoved (int).
  #>
  param(
    $Records = $null,
    [int]$Limit = 0
  )
  $list = @($Records)
  $kinds = @('contact', 'group', 'history', 'unknown')
  $seen = @{}
  $kept = New-Object System.Collections.ArrayList
  $removed = 0
  foreach ($record in $list) {
    $name = [string]$record['name']
    $id = [string]$record['qqId']
    if (-not [string]::IsNullOrEmpty($name) -or -not [string]::IsNullOrEmpty($id)) {
      $key = ('{0}|{1}|{2}' -f [string]$record['kind'], $name, $id)
      if ($seen.ContainsKey($key)) { $removed++; continue }
      $seen[$key] = $true
    }
    [void]$kept.Add($record)
  }

  $ordered = New-Object System.Collections.ArrayList
  foreach ($kind in $kinds) {
    foreach ($record in $kept) {
      if ([string]$record['kind'] -ne $kind) { continue }
      if ($Limit -gt 0 -and $ordered.Count -ge $Limit) { break }
      [void]$ordered.Add($record)
    }
    if ($Limit -gt 0 -and $ordered.Count -ge $Limit) { break }
  }
  # A kind added to Get-QQSearchResultRecord later must not disappear from the
  # report just because it is missing from the order list above.
  if ($Limit -le 0 -or $ordered.Count -lt $Limit) {
    foreach ($record in $kept) {
      if ($kinds -contains [string]$record['kind']) { continue }
      if ($Limit -gt 0 -and $ordered.Count -ge $Limit) { break }
      [void]$ordered.Add($record)
    }
  }
  return @{ Results = @($ordered); DuplicatesRemoved = [int]$removed }
}

function Select-QQSearchRow {
  <#
  .SYNOPSIS
    Picks the search result row that matches a target QQ id or an expected
    nickname, falling back to the first row.
  .DESCRIPTION
    Three grades, strongest signal first:
      qqid      the row's Name carries '(<TargetId>)', an exact identity match
      nick      the name parsed out of the row equals -ExpectNick exactly
      first-row nothing matched, so position decides
    The position fallback exists because QQ sometimes leaves the first contact row's
    Name empty (AGENT-MANUAL section 8): dropping it would make the intended target
    unreachable, so it is used and its weakness is reported through matchQuality and
    Notes. The caller decides what a weak match is worth - the open path still
    verifies the header afterwards.

    -ExpectNick is compared with -ceq against the parsed name, never as a substring
    and never case-insensitively: picking the wrong conversation is worse than
    picking none.
  .PARAMETER Rows
    Result row elements, in render order.
  .PARAMETER TargetId
    QQ id to prefer, or '' to skip the identity grade.
  .PARAMETER ExpectNick
    Expected conversation name, or '' to skip the nickname grade.
  .OUTPUTS
    [hashtable] Element, Label, MatchedById, MatchQuality ('qqid'|'nick'|'first-row'
    or '' when there were no rows), Notes.
  #>
  param(
    [Parameter(Mandatory)]$Rows,
    [AllowEmptyString()][string]$TargetId = '',
    [AllowEmptyString()][string]$ExpectNick = ''
  )
  $list = @($Rows)
  if ($list.Count -eq 0) {
    return @{ Element = $null; Label = ''; MatchedById = $false; MatchQuality = ''; Notes = @('no search result rows') }
  }

  if (-not [string]::IsNullOrEmpty($TargetId)) {
    foreach ($row in $list) {
      $name = ''
      try { $name = [string]$row.Current.Name } catch { $name = '' }
      if ($name -match ('\(' + [regex]::Escape($TargetId) + '\)')) {
        return @{ Element = $row; Label = $name; MatchedById = $true; MatchQuality = 'qqid'; Notes = @() }
      }
    }
  }

  if (-not [string]::IsNullOrEmpty($ExpectNick)) {
    $index = 0
    foreach ($row in $list) {
      $parsed = Get-QQSearchResultRecord -Element $row -Index $index
      $index++
      if ([string]$parsed.name -ceq $ExpectNick) {
        return @{ Element = $row; Label = [string]$parsed.raw; MatchedById = $false; MatchQuality = 'nick'; Notes = @('the row was selected because its parsed name equals the expected nickname') }
      }
    }
  }

  $first = $list[0]
  $firstName = ''
  try { $firstName = [string]$first.Current.Name } catch { $firstName = '' }
  $weak = New-Object System.Collections.ArrayList
  if (-not [string]::IsNullOrEmpty($ExpectNick)) {
    [void]$weak.Add(("no result row's parsed name equals '{0}' exactly" -f $ExpectNick))
  }
  if ([string]::IsNullOrEmpty($firstName)) {
    [void]$weak.Add('the first result row has an empty Name (QQ render timing); it was selected by position')
  } else {
    [void]$weak.Add('the first result row was selected by position')
  }
  return @{ Element = $first; Label = $firstName; MatchedById = $false; MatchQuality = 'first-row'; Notes = @($weak) }
}

function Get-QQOpenChatState {
  <#
  .SYNOPSIS
    Reads the identity of the conversation currently open in an instance.
  .PARAMETER Instance
    Instance hashtable from Get-QQInstanceContext.
  .OUTPUTS
    [hashtable] Header, IsGroup, EditorPresent, EditorElement, SendButtonPresent.
  #>
  param([Parameter(Mandatory)]$Instance)
  $nodes = @(Get-QQAllNodes -Root $Instance.Root)
  $header = Get-QQCurrentChatName -Root $Instance.Root -Nodes $nodes
  $isGroup = Test-QQIsGroupChat -Root $Instance.Root -Nodes $nodes
  $editor = Get-QQNode -Root $Instance.Root -Section 'Editor' -Name 'Editor' -Nodes $nodes
  $sendBtn = Get-QQNode -Root $Instance.Root -Section 'Editor' -Name 'SendButton' -Nodes $nodes
  return @{
    Header            = [string]$header
    IsGroup           = [bool]$isGroup
    EditorPresent     = ($null -ne $editor)
    EditorElement     = $editor
    SendButtonPresent = ($null -ne $sendBtn)
    NodeCount         = [int]$nodes.Count
  }
}

function Get-QQTypingDelayMs {
  <#
  .SYNOPSIS
    Resolves the per-character typing delay from config.
  .PARAMETER Config
    Framework config hashtable.
  .OUTPUTS
    [int] milliseconds per character.
  #>
  param($Config = $null)
  if ($null -ne $Config -and $Config.ContainsKey('TypingDelayMs') -and [int]$Config['TypingDelayMs'] -ge 0) {
    return [int]$Config['TypingDelayMs']
  }
  return 12
}
