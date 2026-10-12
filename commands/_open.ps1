# =============================================================================
# commands/_open.ps1 - conversation opening strategy, shared by read-chat and
# open-chat.
# Authority: docs/FRAMEWORK-DESIGN.md 4.2 and 6.4
#
# Opening a conversation is the step that decides which chat a later send reaches,
# so it lives in exactly one implementation that both commands use. Two copies
# would be two chances to get the destination wrong.
#
# ASCII-ONLY SOURCE. run-tests.ps1 enforces this rule.
# =============================================================================

function Open-QQConversation {
  <#
  .SYNOPSIS
    Opens a conversation by title or QQ id and verifies the switch took effect.
  .DESCRIPTION
    Verification requires the header to CHANGE and then to match the expectation.
    "Header equals target" alone is not sufficient: a stale header, or one left
    over from the search panel, satisfies it while the pane still shows the
    previous conversation, which is the documented cause of messages reaching the
    wrong chat (FRAMEWORK-DESIGN 6.4).

    Strategy, strongest signal first:
      1. exact title match in the rendered conversation list (no search involved)
      2. global search for -SearchId before -TargetId, falling back to -ExpectNick

    Step 2 depends on QQ rendering search result rows into the accessibility tree.
    On a build that renders only the umbrella entry, step 2 legitimately finds
    nothing and the caller gets a NOT_FOUND whose details say so, rather than a
    silent switch to the wrong conversation.
  .PARAMETER Instance
    Instance hashtable from Get-QQInstanceContext.
  .PARAMETER ExpectNick
    Conversation title that must be open afterwards. '' skips the identity check
    for callers that only need a switch.
  .PARAMETER TargetId
    QQ id used to pick the search result row, or ''.
  .PARAMETER SearchId
    Value to search for when the session list misses, or ''.
  .PARAMETER Timeouts
    Timeout table from the dispatcher context.
  .PARAMETER Config
    Framework config hashtable, for the per-character typing delay.
  .PARAMETER AllowSameHeader
    Accept a header that already matched before the click. Only for re-reading the
    conversation that is already open; the change requirement is otherwise intact.
  .OUTPUTS
    [hashtable] HeaderBefore, Header, HeaderChanged, OpenedVia, RowLabel, Notes.
  #>
  param(
    [Parameter(Mandatory)]$Instance,
    [AllowEmptyString()][string]$ExpectNick = '',
    [AllowEmptyString()][string]$TargetId = '',
    [AllowEmptyString()][string]$SearchId = '',
    [Parameter(Mandatory)]$Timeouts,
    $Config = $null,
    [switch]$AllowSameHeader
  )
  $notes = New-Object System.Collections.ArrayList
  $before = Get-QQCurrentChatName -Root $Instance.Root
  $openedVia = ''
  $rowLabel = ''

  [void](Invoke-QQWindowFocus -Hwnd $Instance.Window.Hwnd)
  Start-Sleep -Milliseconds ([int]$Timeouts.afterFocusMs)

  # If the requested conversation is already open, nothing needs clicking. The
  # header is the authority for that, so this cannot pick the wrong chat.
  if (-not [string]::IsNullOrEmpty($ExpectNick) -and $before -ceq $ExpectNick) {
    [void]$notes.Add('the requested conversation was already open; no switch was performed')
    $state = Get-QQOpenChatState -Instance $Instance
    return @{
      HeaderBefore  = [string]$before
      Header        = [string]$before
      HeaderChanged = $false
      OpenedVia     = 'already-open'
      RowLabel      = [string]$before
      Notes         = @($notes)
    }
  }

  $row = $null

  # 1) exact title in the rendered conversation list
  if (-not [string]::IsNullOrEmpty($ExpectNick)) {
    $found = Find-QQSessionRow -Root $Instance.Root -Title $ExpectNick
    if ([bool]$found.Found) {
      $row = $found.Element
      $rowLabel = [string]$found.Title
      $openedVia = 'session-list'
    }
  }

  # 2) global search
  $searchUsed = $false
  if ($null -eq $row) {
    $keyword = $SearchId
    if ([string]::IsNullOrEmpty($keyword)) { $keyword = $TargetId }
    if ([string]::IsNullOrEmpty($keyword)) { $keyword = $ExpectNick }
    if ([string]::IsNullOrEmpty($keyword)) {
      throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message 'nothing to open: pass -OpenNick, -ExpectNick or -TargetId' -Details @{ pid = $Instance.Pid })
    }
    $searchResult = Set-QQSearchKeyword -Instance $Instance -Keyword $keyword -Timeouts $Timeouts -Config $Config
    [void]$notes.Add(('global search for {0} returned {1} result row(s)' -f $keyword, @($searchResult.Rows).Count))
    $picked = Select-QQSearchRow -Rows $searchResult.Rows -TargetId $TargetId -ExpectNick $ExpectNick
    foreach ($n in @($picked.Notes)) { [void]$notes.Add([string]$n) }
    [void]$notes.Add(('the search result row was matched by {0}' -f [string]$picked.MatchQuality))
    if ($null -eq $picked.Element) {
      [void]$notes.Add('the session list did not contain the title and the search produced no selectable row')
      throw (New-QQErrorRecord -Code 'NOT_FOUND' -Message ("could not open '{0}': not in the rendered conversation list and the search returned no result row; use 'list-sessions' to see which conversations are reachable" -f $keyword) -Details @{ pid = $Instance.Pid; keyword = $keyword; expectNick = $ExpectNick; notes = @($notes) })
    }
    $row = $picked.Element
    $rowLabel = [string]$picked.Label
    $openedVia = 'search'
    $searchUsed = $true
  }

  $invoke = Invoke-QQElementClick -Element $row -Scale $Instance.Scale
  Write-QQLog -Text ("row activated via {0} (label '{1}')" -f $invoke.Via, $rowLabel)
  Start-Sleep -Milliseconds 400

  # The click already selected the conversation, so Escape cannot take the switch
  # back - it only dismisses the search dropdown the row was picked from. Without
  # it the dropdown keeps floating over the conversation list and the next
  # physical click (a session row, the send button) lands on the overlay.
  if ($searchUsed) {
    $surface = Close-QQSearchSurface -Instance $Instance
    if ([bool]$surface.Closed) {
      [void]$notes.Add('the search dropdown was dismissed with Escape after the row click')
    } else {
      [void]$notes.Add(('the search dropdown could not be dismissed ({0}); an overlay may still cover the conversation list' -f [string]$surface.Error))
    }
  }

  $changed = Wait-QQHeaderChange -Root $Instance.Root -Before $before -TimeoutMs ([int]$Timeouts.switchHeaderMs)
  $header = [string]$changed.Header
  $headerChanged = [bool]$changed.Changed

  if (-not $headerChanged -and -not $AllowSameHeader) {
    throw (New-QQErrorRecord -Code 'TIMEOUT' -Message ("the conversation did not switch: the header is still '{0}' after {1} ms" -f $header, [int]$Timeouts.switchHeaderMs) -Details @{ pid = $Instance.Pid; headerBefore = $before; header = $header; openedVia = $openedVia })
  }
  if ($headerChanged -and -not [string]::IsNullOrEmpty($ExpectNick) -and $header -cne $ExpectNick) {
    throw (New-QQErrorRecord -Code 'NOT_FOUND' -Message ("the conversation switched to '{0}' but '{1}' was expected" -f $header, $ExpectNick) -Details @{ pid = $Instance.Pid; header = $header; expected = $ExpectNick; rowLabel = $rowLabel; openedVia = $openedVia })
  }
  if (-not $headerChanged -and $AllowSameHeader -and -not [string]::IsNullOrEmpty($ExpectNick) -and $header -cne $ExpectNick) {
    throw (New-QQErrorRecord -Code 'NOT_FOUND' -Message ("the open conversation is '{0}' but '{1}' was expected" -f $header, $ExpectNick) -Details @{ pid = $Instance.Pid; header = $header; expected = $ExpectNick })
  }

  Start-Sleep -Milliseconds ([int]$Timeouts.settleMs)
  return @{
    HeaderBefore  = [string]$before
    Header        = [string]$header
    HeaderChanged = [bool]$headerChanged
    OpenedVia     = [string]$openedVia
    RowLabel      = [string]$rowLabel
    Notes         = @($notes)
  }
}
