# =============================================================================
# commands/doctor.ps1 - L0 environment check.
# Authority: docs/FRAMEWORK-DESIGN.md 4.2; docs/AGENT-MANUAL.md 3
#
# Read-only: enumerates QQ processes and windows and walks their UIA trees. It
# never launches, restarts or stops a QQ process, never clicks, never focuses,
# never types.
#
# Contract with the dispatcher: defines functions only (no param block), defines
# Invoke-QQCommand -Context <hashtable>, returns @{ Data = <payload>; Pid = <int|null> },
# writes nothing to stdout.
#
# ASCII-ONLY SOURCE. run-tests.ps1 enforces this rule.
# =============================================================================

function Get-QQSelectorSectionNames {
  <#
  .SYNOPSIS
    Lists the selectors.psd1 sections that hold probeable selector entries.
  .DESCRIPTION
    The registry mixes provenance metadata (Version, TargetApp, VerifiedOn) with
    real selectors, and Window is a single settings block rather than a list.
    Only sections whose entries carry Class and Type are probeable.
  .OUTPUTS
    [string[]] section names in registry order.
  #>
  $skip = @('Version', 'TargetApp', 'VerifiedOn', 'Window', 'MessageKinds')
  $sections = New-Object System.Collections.ArrayList
  $sel = Get-QQSelector
  if ($null -eq $sel) { return @() }
  foreach ($section in @($sel.Keys)) {
    if ($skip -contains $section) { continue }
    $candidate = $sel[$section]
    if (-not ($candidate -is [System.Collections.IDictionary])) { continue }
    $probeable = $false
    foreach ($name in @($candidate.Keys)) {
      $entry = $candidate[$name]
      if (-not ($entry -is [System.Collections.IDictionary])) { continue }
      if ($entry.ContainsKey('Class') -and $entry.ContainsKey('Type')) { $probeable = $true; break }
    }
    if ($probeable) { [void]$sections.Add([string]$section) }
  }
  return @($sections)
}

function Get-QQSelectorHealth {
  <#
  .SYNOPSIS
    Probes every selector in lib\selectors.psd1 against one live QQ window.
  .DESCRIPTION
    QQ version drift moves class names, and a drifted selector fails silently at
    the point of use (a search that finds nothing, a send that cannot verify its
    target). Probing all of them here turns that into an explicit report. Every
    miss is attributed: a selector whose RequiredFor list contains any missed
    surface is a drift candidate, while an optional entry is reported but does not
    fail the check.
  .PARAMETER Root
    UIA root element of the QQ window.
  .PARAMETER Nodes
    Precomputed descendant list of Root.
  .OUTPUTS
    [hashtable] Entries (ordered), Drifted (authoritative misses), OptionalMissing.
  #>
  param(
    [Parameter(Mandatory)]$Root,
    [Parameter(Mandatory)]$Nodes
  )
  $entries = New-Object System.Collections.ArrayList
  $drifted = New-Object System.Collections.ArrayList
  $optionalMissing = New-Object System.Collections.ArrayList

  # The registry is fetched once for the whole probe: it is a script-scope
  # hashtable, but fetching it per section was one avoidable call per iteration
  # and the entry lookups below already read the same object.
  $sel = Get-QQSelector
  if ($null -eq $sel) { return @{ Entries = @(); Drifted = @(); OptionalMissing = @() } }

  foreach ($section in (Get-QQSelectorSectionNames)) {
    if (-not $sel.ContainsKey($section)) { continue }
    $sectionEntries = $sel[$section]
    foreach ($name in @($sectionEntries.Keys)) {
      $entry = Get-QQSelectorEntry -Section $section -Name $name
      $hits = @(Get-QQNodes -Root $Root -Section $section -Name $name -Nodes $Nodes)
      $found = ($hits.Count -gt 0)
      $row = [ordered]@{
        section  = [string]$section
        name     = [string]$name
        required = [bool]$entry.Required
        stable   = [bool]$entry.Stable
        found    = [bool]$found
        count    = [int]$hits.Count
      }
      if ($entry.Required -and -not $found) {
        $row['drift'] = $true
        [void]$drifted.Add(('{0}.{1}' -f $section, $name))
      } elseif (-not $entry.Required -and -not $found) {
        # Optional selectors legitimately resolve to nothing on the current view
        # (no outgoing message on screen, no group member panel in a direct chat).
        $row['optionalMiss'] = $true
        [void]$optionalMissing.Add(('{0}.{1}' -f $section, $name))
      }
      [void]$entries.Add([pscustomobject]$row)
    }
  }
  return @{
    Entries         = @($entries)
    Drifted         = @($drifted)
    OptionalMissing = @($optionalMissing)
  }
}

function Invoke-QQCommand {
  <#
  .SYNOPSIS
    L0 doctor: environment check for the QQ UIA framework.
  .DESCRIPTION
    Reports the three things AGENT-MANUAL section 3 gates a task on: at least one
    QQ instance, an activated accessibility tree (node count above the threshold),
    and a healthy selector set. Zero instances is not an error here: the doctor
    reports it and the agent decides whether to stop.
  .PARAMETER Context
    Dispatcher context hashtable.
  .OUTPUTS
    Hashtable with Data (config, instances, a11y, selectorHealth) and Pid.
  #>
  param($Context)

  $config = $Context.Config
  $minNodes = Get-QQA11yMinNodes -Config $config
  # a11y.nodeCountTimeoutMs bounds the wait for a lazily activated tree. The wait
  # is the whole point of the key: QQ exposes 9 skeleton nodes until a UIA client
  # wakes it, so a single immediate read calls an instance inactive that activates
  # a second later.
  $nodeWaitMs = 8000
  if ($config.ContainsKey('NodeCountTimeoutMs') -and [int]$config['NodeCountTimeoutMs'] -ge 0) { $nodeWaitMs = [int]$config['NodeCountTimeoutMs'] }

  $windows = @(Get-QQWindowList -Config $config | Sort-Object Pid)
  Write-QQLog -Text ("visible QQ windows: {0}" -f $windows.Count)

  # Every process with the QQ image name: a renderer without a visible window is
  # still worth reporting, because it explains a missing entry in `identify`.
  $procIds = @()
  foreach ($p in @(Get-Process -Name 'QQ' -ErrorAction SilentlyContinue)) { $procIds += [int]$p.Id }
  Write-QQLog -Text ("QQ processes: {0}" -f $procIds.Count)

  $instances = New-Object System.Collections.ArrayList
  $maxNodes = 0
  $probeRoot = $null
  $probeNodes = @()
  $probePid = 0

  foreach ($win in $windows) {
    $nodeCount = 0
    $nodes = @()
    $rootEl = $null
    try {
      $rootEl = [System.Windows.Automation.AutomationElement]::FromHandle($win.Hwnd)
      if ($null -ne $rootEl) {
        $nodes = @(Get-QQAllNodes -Root $rootEl)
        $firstCount = $nodes.Count
        if ($nodeWaitMs -gt 0 -and -not (Test-QQA11yActive -NodeCount $firstCount -MinNodes $minNodes)) {
          $nodes = @(Wait-QQNodeCount -Root $rootEl -MinNodes $minNodes -TimeoutMs $nodeWaitMs -Nodes $nodes)
          if ($nodes.Count -ne $firstCount) {
            Write-QQLog -Text ("pid {0}: the accessibility tree went from {1} to {2} nodes while waiting" -f $win.Pid, $firstCount, $nodes.Count)
          }
        }
      }
      $nodeCount = $nodes.Count
    } catch {
      Write-QQLog -Text ("UIA walk failed for pid {0}: {1}" -f $win.Pid, $_.Exception.Message)
    }

    $nick = ''
    $online = $false
    $signature = ''
    if (Test-QQA11yActive -NodeCount $nodeCount -MinNodes $minNodes) {
      try {
        $identity = Get-QQAccountIdentity -Root $rootEl -Nodes $nodes
        $nick = [string]$identity.Nick
        $online = [bool]$identity.Online
        $signature = [string]$identity.Signature
      } catch {
        Write-QQLog -Text ("identity read failed for pid {0}: {1}" -f $win.Pid, $_.Exception.Message)
      }
    }

    [void]$instances.Add([ordered]@{
      pid        = [int]$win.Pid
      hwnd       = [int64]$win.Hwnd
      title      = [string]$win.Title
      width      = [int]$win.Width
      height     = [int]$win.Height
      scale      = [double]$win.Scale
      nodeCount  = [int]$nodeCount
      nick       = [string]$nick
      signature  = [string]$signature
      online     = [bool]$online
      loggedIn   = [bool](-not [string]::IsNullOrEmpty($nick))
    })

    if ($nodeCount -gt $maxNodes) { $maxNodes = $nodeCount }
    if ((Test-QQA11yActive -NodeCount $nodeCount -MinNodes $minNodes) -and ($null -eq $probeRoot -or $nodeCount -gt $probeNodes.Count)) {
      $probeRoot = $rootEl
      $probeNodes = $nodes
      $probePid = [int]$win.Pid
    }
  }

  $a11yActive = Test-QQA11yActive -NodeCount $maxNodes -MinNodes $minNodes
  $health = $null
  if ($null -ne $probeRoot) {
    $health = Get-QQSelectorHealth -Root $probeRoot -Nodes $probeNodes
    Write-QQLog -Text ("selector probe on pid {0}: {1} entries, {2} drifted" -f $probePid, @($health.Entries).Count, @($health.Drifted).Count)
  } else {
    Write-QQLog -Text 'no QQ window with a readable UIA tree: selector health not probed'
  }

  # Configuration combinations that disable a safety net. Reported as a structured
  # list so an agent can act on the warning itself, and prepended to the human hint
  # because a disabled guard outranks an environment remark.
  $configWarnings = New-Object System.Collections.ArrayList
  $auditEnabled = $true
  if ($config.ContainsKey('WriteAudit')) { $auditEnabled = [bool]$config['WriteAudit'] }
  $sendIntervalMs = 0
  if ($config.ContainsKey('MinSendIntervalMs')) { $sendIntervalMs = [int]$config['MinSendIntervalMs'] }
  if (-not $auditEnabled -and $sendIntervalMs -gt 0) {
    [void]$configWarnings.Add(('evidence.writeAudit is false while guards.minSendIntervalMs is {0}: the send cooldown is recovered from evidence/audit.jsonl, so with no audit record written the cooldown can never fire' -f $sendIntervalMs))
  }
  # typing.engine is normalized into the config but only 'sendinput' is implemented
  # (lib/qq-core.ps1 Send-QQText). Say so instead of letting the setting read as a
  # choice that was honored.
  $typingEngine = 'sendinput'
  if ($config.ContainsKey('TypingEngine') -and -not [string]::IsNullOrEmpty([string]$config['TypingEngine'])) { $typingEngine = [string]$config['TypingEngine'] }
  if ($typingEngine -ne 'sendinput') {
    [void]$configWarnings.Add(("typing.engine is '{0}' but only 'sendinput' is implemented; the value is ignored and every keystroke is sent through SendInput" -f $typingEngine))
  }

  $hint = ''
  if ($instances.Count -eq 0) {
    $hint = 'No visible QQ window. Start QQ and sign in, then run doctor again. This framework never starts QQ itself.'
  } elseif (-not $a11yActive) {
    $hint = 'QQ accessibility tree looks inactive (few nodes). Restart QQ with the --force-renderer-accessibility switch, or attach a UIA client and wait for lazy activation.'
  } elseif ($null -ne $health -and @($health.Drifted).Count -gt 0) {
    $hint = 'Selector drift detected. Report it and stop: update lib/selectors.psd1 from a fresh UIA probe instead of guessing class names.'
  }
  if ($configWarnings.Count -gt 0) { $hint = (($configWarnings -join ' ') + ' ' + $hint).Trim() }

  $data = [ordered]@{
    framework         = [ordered]@{
      version       = [string]$script:QQ_FRAMEWORK_VERSION
      root          = [string]$Context.Root
      configPath    = [string]$config['Path']
      configValid   = [bool]$config['Valid']
      configError   = [string]$config['ParseError']
      evidenceDir   = [string]$Context.EvidenceDir
      powershell    = [string]$PSVersionTable.PSVersion.ToString()
      selectorsFile = [ordered]@{
        version    = $(if ($null -ne (Get-QQSelector)) { [string](Get-QQSelector)['Version'] } else { '' })
        verifiedOn = $(if ($null -ne (Get-QQSelector)) { [string](Get-QQSelector)['VerifiedOn'] } else { '' })
      }
    }
    qqProcessCount    = [int]$procIds.Count
    qqProcessIds      = @($procIds)
    instances         = @($instances)
    instanceCount     = [int]$instances.Count
    a11yActive        = [bool]$a11yActive
    nodeCount         = [int]$maxNodes
    a11yMinNodes      = [int]$minNodes
    nodeCountTimeoutMs = [int]$nodeWaitMs
    selectorProbedPid = [int]$probePid
    # Wrapped in @(): assigning a bare empty collection through a hashtable
    # literal lets PowerShell unroll it, and the envelope would then report
    # selectorDrift as null instead of [] (FRAMEWORK-DESIGN 5.2).
    selectorHealth    = @($(if ($null -ne $health) { @($health.Entries) } else { @() }))
    selectorDrift     = @($(if ($null -ne $health) { @($health.Drifted) } else { @() }))
    selectorOptionalMiss = @($(if ($null -ne $health) { @($health.OptionalMissing) } else { @() }))
    configWarnings    = @($configWarnings)
    ready             = [bool]($instances.Count -gt 0 -and $a11yActive -and ($null -eq $health -or @($health.Drifted).Count -eq 0))
    hint              = [string]$hint
  }

  $reportPid = $null
  if ($probePid -gt 0) { $reportPid = $probePid }
  elseif ($instances.Count -gt 0) { $reportPid = [int]$instances[0].pid }

  return @{ Data = $data; Pid = $reportPid }
}
