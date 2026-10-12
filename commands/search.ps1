# =============================================================================
# commands/search.ps1 - L1 global search.
# Authority: G:\work\FRAMEWORK-DESIGN.md 4.2; G:\work\AGENT-MANUAL.md 5
#
# Side effects: focuses the window, takes focus in the search box and writes the
# keyword. It does not open a conversation and does not change the selected chat.
# With -Activate 1 it also clicks the umbrella entry to open the comprehensive
# search panel, and unless -KeepOpen is passed it dismisses that panel / dropdown
# with Escape before returning. An open-chat step is always required before any
# send.
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
    L1 search: searches contacts, groups and chat history in one instance.
  .DESCRIPTION
    The umbrella search entry (the "search everything" row) is reported as its own
    entry when present, because selecting it is a different action from selecting a
    contact result. A contact row whose Name is empty is kept: QQ renders the first
    contact result before its label, and dropping it would hide the intended
    target. -ExpectAccountNick is enforced here as well as on the L1/L2 commands,
    so a search cannot run against the wrong instance either.

    Rows are deduplicated on kind + name + QQ id and ordered contact, group,
    history, so a target rendered by two surfaces cannot look like two hits.

    -Activate 1 clicks the umbrella entry to open the comprehensive-search panel and
    then reads that panel. It deliberately does NOT type the keyword a second time:
    the panel carries its own input box, so the window would hold two Edit controls
    and the Nav.SearchInput lookup ("the only Edit in the window") could land in the
    panel's box instead of the global one. When the panel container is not
    recognised, the inline dropdown rows are reported and a note says the panel was
    never read.

    The dropdown / panel is dismissed with Escape before returning unless -KeepOpen
    is passed: it floats over the conversation list, so a leftover overlay makes the
    next physical click land on it.
  .PARAMETER Context
    Dispatcher context hashtable.
  .OUTPUTS
    Hashtable with Data (account, keyword, results, umbrellaEntry, panelUsed,
    duplicatesRemoved, closed, note, notes) and Pid.
  #>
  param($Context)

  $pidValue = Get-QQIntArg -Name 'SenderPid' -Default 0 -Min 1
  $accountArg = Get-QQStringArg -Name 'Account'
  $keyword = Get-QQStringArg -Name 'Keyword' -Required
  $limit = Get-QQIntArg -Name 'Limit' -Default 30 -Min 1 -Max 200
  $activate = Get-QQIntArg -Name 'Activate' -Default 0 -Min 0 -Max 1
  $expectAccount = Get-QQStringArg -Name 'ExpectAccountNick'
  $keepOpen = Test-QQArgSwitch -Name 'keepOpen'

  $instance = Get-QQInstanceContext -TargetPid $pidValue -Account $accountArg -Config $Context.Config
  # Search opens nothing and types no message, but it does write the keyword into
  # the search box of the account it picked, so the same account check applies.
  Assert-QQAccountExpected -Instance $instance -ExpectAccountNick $expectAccount -Config $Context.Config
  Write-QQLog -Text ("instance pid {0}: account '{1}'" -f $instance.Pid, $instance.Identity.Nick)

  # -TimeoutSec (timeouts.defaultSec from config.json unless overridden) caps the
  # result wait and every other stage wait below.
  $timeouts = Get-QQEffectiveTimeouts -Timeouts $Context.Timeouts -TimeoutSec ([int]$Context.TimeoutSec)
  $searchResult = Set-QQSearchKeyword -Instance $instance -Keyword $keyword -Timeouts $timeouts -Config $Context.Config

  $notes = New-Object System.Collections.ArrayList
  if (-not [string]::IsNullOrEmpty([string]$searchResult.SearchValueNote)) {
    [void]$notes.Add([string]$searchResult.SearchValueNote)
  }

  # Activate=1 additionally opens the umbrella entry, because on a build that
  # renders no inline hits the dropdown only ever holds that one row. The panel is
  # then the only place real hits can appear.
  $rows = @($searchResult.Rows)
  $activated = $false
  $panelUsed = $false
  if ($activate -eq 1) {
    # The umbrella row is found by name, not by position: when a build renders real
    # inline hits beside it, it is not necessarily the first row, and the row
    # clicked here has to be the umbrella entry and never a contact.
    $umbrellaRow = $null
    foreach ($candidate in @($searchResult.AllRows)) {
      if (Test-QQComprehensiveSearchRow -Element $candidate) { $umbrellaRow = $candidate; break }
    }
    if ($null -ne $umbrellaRow) {
      $inv = Invoke-QQElementClick -Element $umbrellaRow -Scale $instance.Scale
      $activated = $true
      Write-QQLog -Text ("umbrella search entry activated via {0}" -f $inv.Via)
      Start-Sleep -Milliseconds 2500
      $panel = Wait-QQSearchPanel -Instance $instance -Timeouts $timeouts
      if ([bool]$panel.Found) {
        $panelRows = @($panel.Rows | Where-Object { -not (Test-QQComprehensiveSearchRow -Element $_) })
        if ($panelRows.Count -gt 0) {
          $rows = @($panelRows)
          $panelUsed = $true
        } else {
          [void]$notes.Add('the comprehensive search panel was found but rendered no result rows; the inline dropdown rows are reported instead')
        }
      } else {
        [void]$notes.Add([string]$panel.Note)
      }
    } else {
      Write-QQLog -Text 'Activate was requested but the umbrella entry was not present'
      [void]$notes.Add('Activate was requested but the umbrella entry was not present')
    }
  }

  $umbrella = $null
  if ($null -ne $searchResult.UmbrellaRow) {
    $umbrella = Get-QQSearchResultRecord -Element $searchResult.UmbrellaRow -Index -1
  }
  Write-QQLog -Text ("search '{0}' produced {1} result rows (umbrella entry present: {2}, panel read: {3})" -f $keyword, $rows.Count, ($null -ne $umbrella), $panelUsed)

  # Every row is parsed before the limit is applied, so the limit counts distinct
  # results rather than render positions.
  $records = New-Object System.Collections.ArrayList
  $renderIndex = 0
  foreach ($row in $rows) {
    [void]$records.Add((Get-QQSearchResultRecord -Element $row -Index $renderIndex))
    $renderIndex++
  }
  $merged = Merge-QQSearchResultRecords -Records @($records) -Limit $limit
  $results = @($merged.Results)

  $note = ''
  if ($rows.Count -eq 0) {
    $note = 'no selectable result rows: on this QQ build the dropdown may render only the umbrella entry, which is reported separately in umbrellaEntry. Use list-sessions to enumerate reachable conversations, or retry with -Activate 1 to open the search panel.'
    [void]$notes.Add([string]$note)
  } elseif ($results.Count -gt 0 -and [string]::IsNullOrEmpty([string]$results[0].name)) {
    $note = 'the first result row has an empty Name (QQ render timing); it is still the first result, so select it by position rather than by name'
    [void]$notes.Add([string]$note)
  }

  $closed = $false
  if ($keepOpen) {
    [void]$notes.Add('-KeepOpen was used: the search dropdown / panel is still open and may cover the conversation list until it is dismissed')
  } else {
    $surface = Close-QQSearchSurface -Instance $instance
    $closed = [bool]$surface.Closed
    if (-not $closed) {
      [void]$notes.Add(('the search dropdown / panel could not be dismissed ({0}); an overlay may still cover the conversation list' -f [string]$surface.Error))
    }
  }

  $data = [ordered]@{
    account           = (Get-QQAccountSummary -Instance $instance)
    keyword           = [string]$keyword
    searchValue       = [string]$searchResult.SearchValue
    searchValueNote   = [string]$searchResult.SearchValueNote
    settled           = [bool]$searchResult.Settled
    activated         = [bool]$activated
    panelUsed         = [bool]$panelUsed
    results           = @($results)
    count             = [int]@($results).Count
    duplicatesRemoved = [int]$merged.DuplicatesRemoved
    closed            = [bool]$closed
    umbrellaEntry     = $(if ($null -ne $umbrella) { $umbrella } else { $null })
    note              = [string]$note
    notes             = @($notes)
  }

  return @{ Data = $data; Pid = [int]$instance.Pid }
}
