# =============================================================================
# qq-json.ps1 - JSON envelope serialization, exit codes, logging channel split.
# Authority: G:\work\FRAMEWORK-DESIGN.md section 5
#
# Channel contract (the reason this module exists):
#   stdout = exactly one JSON object per invocation, machine parsed by the agent
#   stderr = human-readable diagnostics, safely ignorable
# Every diagnostic in this framework goes through Write-QQLog (stderr). Nothing
# else may write to stdout.
#
# ASCII-ONLY SOURCE. PowerShell 5.1 decodes a BOM-less file as ANSI, so CJK in a
# comment or string literal corrupts parsing. CJK text is built at runtime from
# [char]0x.... escapes. run-tests.ps1 enforces this rule.
# =============================================================================

$script:QQ_FRAMEWORK_VERSION = '0.2.0'

# FRAMEWORK-DESIGN 5.3. The agent keys its recovery strategy off these codes.
$script:QQ_EXIT = [ordered]@{
  'OK'            = 0
  'ERROR'         = 1
  'BAD_ARGS'      = 2
  'NOT_FOUND'     = 3
  'GUARD_ABORT'   = 4
  'ENV_NOT_READY' = 5
  'TIMEOUT'       = 6
}

function Get-QQExitCode {
  <#
  .SYNOPSIS
    Maps an exit-code name to its numeric code.
  .PARAMETER Name
    One of OK, ERROR, BAD_ARGS, NOT_FOUND, GUARD_ABORT, ENV_NOT_READY, TIMEOUT.
  .OUTPUTS
    [int] numeric process exit code.
  #>
  param([Parameter(Mandatory)][string]$Name)
  if (-not $script:QQ_EXIT.Contains($Name)) {
    throw ("unknown exit code name: {0}; valid: {1}" -f $Name, (($script:QQ_EXIT.Keys) -join ', '))
  }
  return [int]$script:QQ_EXIT[$Name]
}

function Get-QQExitCodeList {
  <#
  .SYNOPSIS
    Returns the validated exit-code table as name/value pairs.
  .OUTPUTS
    [hashtable] name -> numeric code.
  #>
  $table = @{}
  foreach ($k in $script:QQ_EXIT.Keys) { $table[$k] = [int]$script:QQ_EXIT[$k] }
  return $table
}

function Test-QQIsExitCodeName {
  <#
  .SYNOPSIS
    Reports whether a name is a valid exit-code name.
  .PARAMETER Name
    Candidate name.
  .OUTPUTS
    [bool].
  #>
  param([string]$Name)
  if ([string]::IsNullOrEmpty($Name)) { return $false }
  return $script:QQ_EXIT.Contains($Name)
}

function Initialize-QQConsole {
  <#
  .SYNOPSIS
    Forces UTF-8 on stdout/stderr so CJK inside the JSON envelope survives.
  .DESCRIPTION
    Best effort, and the failure is reported rather than swallowed: a host whose
    console encoding cannot be replaced (a redirected legacy handle) still gets
    the envelope, because the envelope goes through [Console]::Out, but it does
    not get a guarantee that CJK was encoded as UTF-8. That is a silent
    corruption of the payload, so it is announced on stderr.
  #>
  try {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $enc
    $global:OutputEncoding = $enc
  } catch {
    Write-QQLog -Text ("console encoding could not be set to UTF-8 ({0}); non-ASCII text in the envelope may be encoded with the process code page" -f $_.Exception.Message)
  }
}

function Test-QQArray {
  <#
  .SYNOPSIS
    Reports whether a value is an array (including the empty array).
  .PARAMETER Value
    Any value.
  .OUTPUTS
    [bool].
  #>
  param($Value)
  return ($Value -is [System.Array])
}

function Write-QQLog {
  <#
  .SYNOPSIS
    Writes one human-readable line to stderr.
  .DESCRIPTION
    stdout must stay reserved for the JSON envelope, so every diagnostic uses
    this function instead of Write-Host or Write-Output.
  .PARAMETER Text
    Log text. Deliberately not named Message: a pipeline parameter named
    Message collides with the harness-supplied request Message.
  #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
  try { [Console]::Error.WriteLine($Text) } catch { }
}

function ConvertTo-QQJsonSafe {
  <#
  .SYNOPSIS
    Normalizes a value so ConvertTo-Json renders its intended JSON type.
  .DESCRIPTION
    ConvertTo-Json already renders an empty ArrayList as [] and a one-item
    ArrayList as ["x"], so collections pass through with their items normalized.
    The normalization expends its effort on the case that is NOT free: a
    PSCustomObject or a hashtable nested inside the payload, and a DateTime, which
    is rendered as an ISO-8601 string so the envelope is stable across locales.

    FRAMEWORK-DESIGN 5.2 requires that no collection collapse to null. Every
    collection the envelope carries is a real CLR array or ArrayList; this
    function never returns a bare element in place of one, and `run-tests.ps1`
    asserts the round trip for the empty and single-item cases.

    Depth is bounded. A payload that references itself (a collection holding
    itself, an element graph reached twice) would otherwise recurse until the
    stack overflows, and a stack overflow kills the process before any envelope
    is written: the agent would get an empty stdout instead of an error object.
    At the limit the recursion stops, reports the cut on stderr, and returns null
    for that subtree so the rest of the envelope is still delivered.
  .PARAMETER Value
    Any value, at any depth of the payload.
  .PARAMETER Depth
    Recursion depth. Callers never pass it; the recursion increments it.
  .OUTPUTS
    A value ConvertTo-Json renders with the intended JSON type.
  #>
  param(
    $Value,
    [int]$Depth = 0
  )
  if ($null -eq $Value) { return $null }
  # Deeper than any payload this framework builds (the deepest is a message row's
  # nested parts), so passing this point means a cycle or a foreign object graph.
  if ($Depth -gt 12) {
    Write-QQLog -Text ("json normalization stopped at depth {0}: the payload is deeper than 12 levels, so this subtree is reported as null (a cyclic reference is the usual cause)" -f $Depth)
    return $null
  }
  if ($Value -is [bool] -or $Value -is [string] -or $Value -is [char] -or $Value.GetType().IsEnum) { return $Value }
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) { return $Value }
  if ($Value -is [System.DateTime]) { return $Value.ToString('yyyy-MM-ddTHH:mm:sszzz') }
  if ($Value -is [System.Collections.IDictionary]) {
    $obj = [ordered]@{}
    foreach ($key in $Value.Keys) { $obj[[string]$key] = ConvertTo-QQJsonSafe -Value $Value[$key] -Depth ($Depth + 1) }
    return $obj
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    $items = New-Object System.Collections.ArrayList
    foreach ($item in $Value) { [void]$items.Add((ConvertTo-QQJsonSafe -Value $item -Depth ($Depth + 1))) }
    # Returned as a single element through a no-enumerate write: returning the
    # ArrayList on the pipeline would let PowerShell unroll it, which turns a
    # one-item list into its bare element and an empty list into $null, and that
    # null then serializes as {} instead of [].
    Write-Output -NoEnumerate $items
    return
  }
  # PSCustomObject and any remaining CLR object: keep its public properties.
  $props = @()
  try { $props = @($Value.PSObject.Properties | Where-Object { $_.MemberType -match 'Property|NoteProperty' }) } catch { $props = @() }
  if ($props.Count -eq 0) { return [string]$Value }
  $obj = [ordered]@{}
  foreach ($p in $props) { $obj[[string]$p.Name] = ConvertTo-QQJsonSafe $p.Value }
  return $obj
}

function Get-QQEnvelopeObject {
  <#
  .SYNOPSIS
    Builds the envelope object described in FRAMEWORK-DESIGN 5.2.
  .PARAMETER Ok
    Success flag.
  .PARAMETER Command
    Subcommand name.
  .PARAMETER Data
    Payload on success; ignored when Ok is false.
  .PARAMETER ErrorCode
    Exit-code name (see Get-QQExitCode) when Ok is false.
  .PARAMETER Text
    Human-readable failure message.
  .PARAMETER Details
    Structured failure details, or null.
  .PARAMETER TargetPid
    QQ process id the call acted on, or -1 when no single instance applies.
    A plain int with a sentinel is used because [Nullable[int]] does not report
    HasValue reliably on PowerShell 5.1, which silently produced pid: null.
  .OUTPUTS
    [ordered] hashtable ready for ConvertTo-Json.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][bool]$Ok,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
    $Data = $null,
    [string]$ErrorCode = '',
    [AllowEmptyString()][string]$Text = '',
    $Details = $null,
    [int]$TargetPid = -1
  )

  $errorObj = $null
  if (-not $Ok) {
    if ([string]::IsNullOrEmpty($ErrorCode)) { $ErrorCode = 'ERROR' }
    $errorObj = [ordered]@{
      code     = $ErrorCode
      exitCode = (Get-QQExitCode -Name $ErrorCode)
      message  = $Text
    }
    if ($null -ne $Details) { $errorObj['details'] = ConvertTo-QQJsonSafe $Details }
  }

  return [ordered]@{
    ok        = $Ok
    command   = $Command
    version   = $script:QQ_FRAMEWORK_VERSION
    timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    pid       = $(if ($TargetPid -gt 0) { [int]$TargetPid } else { $null })
    data      = $(if ($Ok) { ConvertTo-QQJsonSafe $Data } else { $null })
    error     = $errorObj
  }
}

function Get-QQEnvelopeJson {
  <#
  .SYNOPSIS
    Serializes the envelope to one compact JSON line.
  .PARAMETER Ok
    Success flag.
  .PARAMETER Command
    Subcommand name.
  .PARAMETER Data
    Payload on success.
  .PARAMETER ErrorCode
    Exit-code name when Ok is false.
  .PARAMETER Text
    Human-readable failure message.
  .PARAMETER Details
    Structured failure details.
  .PARAMETER TargetPid
    QQ process id the call acted on.
  .OUTPUTS
    [string] compact single-line JSON.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][bool]$Ok,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
    $Data = $null,
    [string]$ErrorCode = '',
    [AllowEmptyString()][string]$Text = '',
    $Details = $null,
    [int]$TargetPid = -1
  )
  $env = Get-QQEnvelopeObject -Ok $Ok -Command $Command -Data $Data -ErrorCode $ErrorCode -Text $Text -Details $Details -TargetPid $TargetPid
  # -Depth 6 per FRAMEWORK-DESIGN 5.2; deeper payloads are flattened by the
  # framework's own payload builders rather than silently truncated here.
  return ($env | ConvertTo-Json -Depth 6 -Compress)
}

function Get-QQEnvelopeExitCode {
  <#
  .SYNOPSIS
    Resolves the numeric exit code for a success flag plus error-code name.
  .PARAMETER Ok
    Success flag.
  .PARAMETER ErrorCode
    Exit-code name when Ok is false.
  .OUTPUTS
    [int] exit code.
  #>
  param(
    [Parameter(Mandatory)][bool]$Ok,
    [string]$ErrorCode = ''
  )
  if ($Ok) { return 0 }
  if (-not (Test-QQIsExitCodeName -Name $ErrorCode)) { return (Get-QQExitCode -Name 'ERROR') }
  return (Get-QQExitCode -Name $ErrorCode)
}

function Write-QQStdoutLine {
  <#
  .SYNOPSIS
    Writes one line to the process stdout stream and flushes it.
  .DESCRIPTION
    Uses [Console]::Out rather than Write-Output because every caller finishes
    with `exit`, which discards unconsumed pipeline output: an agent running this
    through bash would otherwise receive an empty stdout.
  .PARAMETER Text
    Line to write.
  #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
  [Console]::Out.WriteLine($Text)
  [Console]::Out.Flush()
}

function Write-QQEnvelope {
  <#
  .SYNOPSIS
    Emits the single JSON envelope to stdout and returns the process exit code.
  .PARAMETER Ok
    Success flag.
  .PARAMETER Command
    Subcommand name.
  .PARAMETER Data
    Payload on success.
  .PARAMETER ErrorCode
    Exit-code name when Ok is false.
  .PARAMETER Text
    Human-readable failure message.
  .PARAMETER Details
    Structured failure details.
  .PARAMETER TargetPid
    QQ process id the call acted on.
  .OUTPUTS
    [int] exit code for the caller's `exit`.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][bool]$Ok,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
    $Data = $null,
    [string]$ErrorCode = '',
    [AllowEmptyString()][string]$Text = '',
    $Details = $null,
    [int]$TargetPid = -1
  )
  Initialize-QQConsole
  $json = Get-QQEnvelopeJson -Ok $Ok -Command $Command -Data $Data -ErrorCode $ErrorCode -Text $Text -Details $Details -TargetPid $TargetPid
  Write-QQStdoutLine -Text $json
  return (Get-QQEnvelopeExitCode -Ok $Ok -ErrorCode $ErrorCode)
}
