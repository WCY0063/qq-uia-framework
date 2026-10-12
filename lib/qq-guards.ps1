# =============================================================================
# qq-guards.ps1 - send guards (framework-level invariants).
# Authority: G:\work\FRAMEWORK-DESIGN.md section 6
#
# Every send path must pass every guard below. There is no switch that disables
# them: a guard that can be turned off is a guard that will be off when it
# matters. The only knob the deployment may set is guards.requireAccountMatch,
# which makes the account check MANDATORY (it is additive, never subtractive).
#
# Guard failures throw with a GUARD_* code. Resolve-QQExitCodeName maps those to
# GUARD_ABORT (exit 4), which AGENT-MANUAL section 7 tells the agent to treat as
# "stop and report" - never as "retry with different parameters".
#
# ASCII-ONLY SOURCE. PowerShell 5.1 decodes a BOM-less file as ANSI, so CJK in a
# comment or string literal corrupts parsing. CJK text is built at runtime from
# [char]0x.... escapes. run-tests.ps1 enforces this rule.
# =============================================================================

function Assert-QQSendableMessage {
  <#
  .SYNOPSIS
    Rejects a message payload the framework must not type.
  .DESCRIPTION
    FRAMEWORK-DESIGN 6 and the pre-framework defect list: an empty -Message must
    never fall back to a built-in phrase, and a payload that cannot survive the
    keyboard path must never be partially typed. Both cases abort before QQ is
    touched, so a rejected send leaves no trace in the conversation.
  .PARAMETER Text
    The resolved message text (already decoded from file, base64 or literal).
  .PARAMETER MaxLength
    Maximum accepted length in characters.
  .OUTPUTS
    [hashtable] Normalized text, Length, Hash.
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
    [int]$MaxLength = 2000
  )
  if ([string]::IsNullOrWhiteSpace($Text)) {
    throw (New-QQErrorRecord -Code 'GUARD_MESSAGE_EMPTY' -Message 'refusing to send: the message text is empty or whitespace-only' -Details @{ length = $Text.Length })
  }
  if ($Text.Length -gt $MaxLength) {
    throw (New-QQErrorRecord -Code 'GUARD_MESSAGE_TOO_LONG' -Message ("refusing to send: message is {0} characters, limit is {1}" -f $Text.Length, $MaxLength) -Details @{ length = $Text.Length; maxLength = $MaxLength })
  }
  # Replace CRLF/CR with LF first so one rule covers every line break: QQ's editor
  # treats Enter as "send", so a multi-line payload would fire mid-message.
  $normalized = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
  if ($normalized.Contains("`n")) {
    throw (New-QQErrorRecord -Code 'GUARD_MESSAGE_MULTILINE' -Message 'refusing to send: this framework sends single-line text only; remove line breaks from the message' -Details @{ lines = ($normalized.Split("`n").Count) })
  }
  foreach ($ch in $normalized.ToCharArray()) {
    $code = [int]$ch
    if ($code -ge 0xD800 -and $code -le 0xDFFF) {
      throw (New-QQErrorRecord -Code 'GUARD_MESSAGE_UNREPRESENTABLE' -Message 'refusing to send: the message contains a surrogate code unit (emoji outside the BMP or a broken pair) that this keyboard path cannot reproduce' -Details @{ codePoint = $code })
    }
    if ($code -lt 0x20 -and $code -ne 0x09) {
      throw (New-QQErrorRecord -Code 'GUARD_MESSAGE_UNREPRESENTABLE' -Message ("refusing to send: the message contains a control character U+{0:X4}" -f $code) -Details @{ codePoint = $code })
    }
  }
  return @{
    Text   = [string]$normalized
    Length = [int]$normalized.Length
    Hash   = (Get-QQStringHash -Text $normalized)
  }
}

function Assert-QQHeaderMatches {
  <#
  .SYNOPSIS
    Requires the open conversation title to equal the expected nickname exactly.
  .DESCRIPTION
    Exact equality, not a substring or regex match: "equal" is the check that
    caught the wrong-conversation sends, and a prefix match would have accepted
    the very titles that caused them.
  .PARAMETER Header
    Title read from chat-header__contact-name.
  .PARAMETER ExpectNick
    -ExpectNick as supplied by the caller.
  .OUTPUTS
    [bool] true when the titles match.
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Header,
    [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectNick
  )
  if ($Header -ceq $ExpectNick) { return $true }
  throw (New-QQErrorRecord -Code 'GUARD_HEADER_MISMATCH' -Message ("refusing to send: the open conversation is '{0}' but '{1}' was expected" -f $Header, $ExpectNick) -Details @{ header = $Header; expected = $ExpectNick })
}

function Assert-QQNotGroupChat {
  <#
  .SYNOPSIS
    Refuses to send into a group conversation.
  .DESCRIPTION
    The group member panel's presence is the discriminator. A group send needs an
    explicit opt-in that this version does not expose (FRAMEWORK-DESIGN 6.3), so
    detection is always a refusal.
  .PARAMETER IsGroup
    Result of the group-member-list probe.
  .PARAMETER Header
    Conversation title, reported so the operator can see which group was refused.
  .OUTPUTS
    [bool] true when the conversation is not a group.
  #>
  param(
    [Parameter(Mandatory)][bool]$IsGroup,
    [string]$Header = ''
  )
  if (-not $IsGroup) { return $true }
  throw (New-QQErrorRecord -Code 'GUARD_GROUP_REJECTED' -Message ("refusing to send: '{0}' is a group conversation" -f $Header) -Details @{ header = $Header; groupMemberPanel = $true })
}

function Assert-QQEditorPresent {
  <#
  .SYNOPSIS
    Requires the message editor to exist before typing.
  .PARAMETER EditorPresent
    Whether the editor element resolved.
  .PARAMETER Header
    Conversation title, reported for context.
  .OUTPUTS
    [bool] true when the editor is present.
  #>
  param(
    [Parameter(Mandatory)][bool]$EditorPresent,
    [string]$Header = ''
  )
  if ($EditorPresent) { return $true }
  throw (New-QQErrorRecord -Code 'GUARD_EDITOR_MISSING' -Message ("refusing to send: no message editor in '{0}'; the conversation may not accept text" -f $Header) -Details @{ header = $Header })
}

function Assert-QQEditorWritable {
  <#
  .SYNOPSIS
    Requires the editor to contain only the text this call typed.
  .DESCRIPTION
    A contenteditable editor can already hold text the user was composing. Typing
    on top of it and pressing Enter would send their draft plus ours, so a
    non-empty editor aborts the send instead of being cleared.
  .PARAMETER EditorText
    Text read back from the editor before typing.
  .OUTPUTS
    [bool] true when the editor was empty.
  #>
  param([AllowEmptyString()][string]$EditorText = '')
  if ([string]::IsNullOrWhiteSpace($EditorText)) { return $true }
  throw (New-QQErrorRecord -Code 'GUARD_EDITOR_NOT_EMPTY' -Message 'refusing to send: the message editor already contains text; clear it and retry so a draft is never sent by accident' -Details @{ length = $EditorText.Length })
}

function Assert-QQTextLanded {
  <#
  .SYNOPSIS
    Requires the typed text to be readable back from the editor.
  .DESCRIPTION
    The editor is contenteditable and has no ValuePattern, so read-back through
    TextPattern is the only proof that the keystrokes reached it. Comparison is
    case-sensitive and ignores surrounding whitespace, because QQ may add a
    trailing line break.
  .PARAMETER EditorText
    Text read back after typing.
  .PARAMETER Expected
    The message that was typed.
  .OUTPUTS
    [bool] true when the text landed.
  #>
  param(
    [AllowEmptyString()][string]$EditorText = '',
    [Parameter(Mandatory)][AllowEmptyString()][string]$Expected
  )
  $got = ([string]$EditorText).Trim()
  if ($got -ceq $Expected.Trim()) { return $true }
  throw (New-QQErrorRecord -Code 'GUARD_READBACK_FAILED' -Message 'refusing to send: the typed text could not be read back from the editor, so it did not land' -Details @{ editorLength = $got.Length; expectedLength = $Expected.Length })
}

function Assert-QQAccountMatches {
  <#
  .SYNOPSIS
    Requires the instance's logged-in account to match the expected nickname.
  .DESCRIPTION
    Multi-instance protection (FRAMEWORK-DESIGN 6.1): a correct conversation title
    on the wrong account still sends from the wrong person. Enforced whenever the
    caller passes -ExpectAccountNick, and mandatory when guards.requireAccountMatch
    is set in config.json.
  .PARAMETER AccountNick
    Nickname read from the instance's own avatar element.
  .PARAMETER ExpectAccountNick
    -ExpectAccountNick as supplied by the caller, or '' to skip the check.
  .OUTPUTS
    [bool] true when the account matches or the check was skipped.
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$AccountNick,
    [AllowEmptyString()][string]$ExpectAccountNick = ''
  )
  if ([string]::IsNullOrEmpty($ExpectAccountNick)) { return $true }
  if ($AccountNick -ceq $ExpectAccountNick) { return $true }
  throw (New-QQErrorRecord -Code 'GUARD_ACCOUNT_MISMATCH' -Message ("refusing to send: instance pid is signed in as '{0}' but '{1}' was expected" -f $AccountNick, $ExpectAccountNick) -Details @{ account = $AccountNick; expected = $ExpectAccountNick })
}

function Assert-QQRateLimit {
  <#
  .SYNOPSIS
    Refuses a send that arrives sooner than the configured cooldown after the
    previous one.
  .DESCRIPTION
    FRAMEWORK-DESIGN 6.9 delegates pacing to the calling agent and the framework
    keeps no cross-call state, but one thing an agent loop can do wrong is call
    send-message repeatedly within seconds. Last-send time is therefore recovered
    from evidence\audit.jsonl, which is the framework's own durable record and
    survives a fresh process: a cooldown that only lived in memory would not.

    Only a record carrying stage='result' AND sent=true starts a cooldown. Those
    are the fields send-message writes once QQ confirmed the message left the
    editor; an 'attempt' record is written before typing, so counting it would
    also cool down after a send that a later guard aborted.

    Timestamps are Unix seconds handled as int64 end to end. Formatting a date
    with -UFormat %s and parsing it with [double]::Parse under the current culture
    produced 17581800005 instead of 1758180000.5 on a comma-decimal host, which
    made the cooldown either permanent or ineffective. A record whose unix field
    does not parse as an integer is skipped, and skipping never releases the
    cooldown on its own.

    The audit file is read without a lock. FRAMEWORK-DESIGN forbids concurrent
    framework calls, so two sends cannot interleave here, and a lock would only
    add a failure mode of its own. Known limit, not an oversight.
  .PARAMETER AuditPath
    Path to audit.jsonl ('' disables the check).
  .PARAMETER MinIntervalMs
    Minimum accepted gap between two sends (0 disables the check).
  .OUTPUTS
    [hashtable] Enforced, LastSendUnix, ElapsedMs.
  #>
  param(
    [string]$AuditPath = '',
    [int]$MinIntervalMs = 0
  )
  $result = @{ Enforced = $false; LastSendUnix = 0; ElapsedMs = 0 }
  if ($MinIntervalMs -le 0) { return $result }
  if ([string]::IsNullOrEmpty($AuditPath) -or -not (Test-Path -LiteralPath $AuditPath)) { return $result }

  $lastUnix = [long]0
  try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $lines = [System.IO.File]::ReadAllLines($AuditPath, $utf8)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
      $line = [string]$lines[$i]
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $rec = $null
      try { $rec = $line | ConvertFrom-Json } catch { continue }
      if ($null -eq $rec) { continue }
      $props = @($rec.PSObject.Properties.Name)
      if ($props -notcontains 'stage' -or $props -notcontains 'sent' -or $props -notcontains 'unix') { continue }
      # Only a completed, confirmed send counts; a guard abort or an unconfirmed
      # attempt never proved that a message left the machine.
      if ([string]$rec.stage -ne 'result') { continue }
      $sent = $false
      if ($rec.sent -is [bool]) { $sent = [bool]$rec.sent }
      else { $sent = (([string]$rec.sent).Trim().ToLowerInvariant() -eq 'true') }
      if (-not $sent) { continue }
      $candidate = [long]0
      $style = [System.Globalization.NumberStyles]::Integer
      if (-not [long]::TryParse([string]$rec.unix, $style, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$candidate)) {
        # Keep looking: a malformed record must neither stop the search nor
        # quietly release the cooldown.
        Write-QQLog -Text ("rate limit: skipping an audit record whose unix field is not an integer: '{0}'" -f [string]$rec.unix)
        continue
      }
      if ($candidate -gt 0) { $lastUnix = $candidate }
      break
    }
  } catch {
    Write-QQLog -Text ("rate limit: audit log unreadable, cooldown not enforced: {0}" -f $_.Exception.Message)
    return $result
  }

  if ($lastUnix -le 0) { return $result }
  $nowUnix = [DateTimeOffset]::Now.ToUnixTimeSeconds()
  $elapsedMs = ($nowUnix - $lastUnix) * 1000
  $result.Enforced = $true
  $result.LastSendUnix = $lastUnix
  $result.ElapsedMs = [int]$elapsedMs
  if ($elapsedMs -lt $MinIntervalMs) {
    throw (New-QQErrorRecord -Code 'GUARD_RATE_LIMIT' -Message ("refusing to send: the previous send was {0} ms ago and the cooldown is {1} ms" -f [int]$elapsedMs, $MinIntervalMs) -Details @{ elapsedMs = [int]$elapsedMs; minIntervalMs = $MinIntervalMs })
  }
  return $result
}

function Assert-QQExpectNickPresent {
  <#
  .SYNOPSIS
    Requires -ExpectNick to be supplied.
  .DESCRIPTION
    The pre-framework send script treated a missing -ExpectNick as "no check to
    run". It is now a hard argument, because the check is the send's only proof
    of destination (AGENT-MANUAL section 1.2).
  .PARAMETER ExpectNick
    The supplied value.
  .OUTPUTS
    [bool] true when supplied.
  #>
  param([AllowEmptyString()][string]$ExpectNick = '')
  if (-not [string]::IsNullOrWhiteSpace($ExpectNick)) { return $true }
  throw (New-QQErrorRecord -Code 'GUARD_EXPECT_NICK_MISSING' -Message 'refusing to send: -ExpectNick is required and must be the exact conversation title' -Details @{ parameter = 'ExpectNick' })
}
