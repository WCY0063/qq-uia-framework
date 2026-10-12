# =============================================================================
# qq-uia.ps1 - the ONLY entry point of the QQ UIA automation framework.
# Authority: G:\work\FRAMEWORK-DESIGN.md sections 4 and 5
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File qq-uia.ps1 <command> [params]
#
# Contract:
#   stdout = exactly one JSON envelope (FRAMEWORK-DESIGN 5.2)
#   stderr = human-readable diagnostics
#   exit   = FRAMEWORK-DESIGN 5.3 code (0 OK, 2 BAD_ARGS, 3 NOT_FOUND,
#            4 GUARD_ABORT, 5 ENV_NOT_READY, 6 TIMEOUT, 1 ERROR)
#
# Command files are dot-sourced into this scope and must define
# Invoke-QQCommand -Context <hashtable>, returning @{ Data = <payload>; Pid = <int|null> }.
# They must write nothing to stdout; the dispatcher owns that channel.
#
# ASCII-ONLY SOURCE. PowerShell 5.1 decodes a BOM-less file as ANSI, so CJK in a
# comment or string literal corrupts parsing. CJK text is built at runtime from
# [char]0x.... escapes. run-tests.ps1 enforces this rule.
# =============================================================================

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [AllowEmptyString()]
  [string]$Command = '',

  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
  [AllowEmptyCollection()]
  [string[]]$Args = @(),

  [switch]$Help,
  [switch]$Version,
  [switch]$ListCommands
)

$ErrorActionPreference = 'Stop'

$script:QQ_LIB_DIR = Join-Path $PSScriptRoot 'lib'
$script:QQ_CMD_DIR = Join-Path $PSScriptRoot 'commands'

. (Join-Path $script:QQ_LIB_DIR 'qq-json.ps1')
. (Join-Path $script:QQ_LIB_DIR 'qq-core.ps1')
. (Join-Path $script:QQ_LIB_DIR 'qq-guards.ps1')

function Get-QQCommandRegistry {
  <#
  .SYNOPSIS
    Declares the command surface: file, danger level and accepted parameters.
  .DESCRIPTION
    This registry is the single description of what the agent may call. A command
    absent here cannot be invoked, which is what keeps archive/ unreachable: no
    command path points at it.
  .OUTPUTS
    [ordered] hashtable keyed by command name.
  #>
  return [ordered]@{
    'doctor' = @{
      File     = 'doctor.ps1'
      Level    = 'L0'
      Summary  = 'environment check: instances, a11y activation, selector health'
      Params   = @()
      Switches = @('verbose')
    }
    'identify' = @{
      File     = 'identify.ps1'
      Level    = 'L0'
      Summary  = 'enumerate every QQ instance and the account signed in to it'
      Params   = @()
      Switches = @('verbose')
    }
    'accounts' = @{
      File     = 'accounts.ps1'
      Level    = 'L0'
      Summary  = 'list configured accounts and their live binding status'
      Params   = @()
      Optional = @('Account')
      Switches = @('verbose')
    }
    'config-ui' = @{
      File     = 'config-ui.ps1'
      Level    = 'L0'
      Summary  = 'launch the graphical account configuration UI'
      Params   = @()
      Optional = @()
      Switches = @()
    }
    'list-sessions' = @{
      File     = 'list-sessions.ps1'
      Level    = 'L0'
      Summary  = 'read the conversation list of one instance'
      Params   = @()
      Optional = @('SenderPid', 'Account', 'Limit')
      Switches = @('verbose')
    }
    'read-chat' = @{
      File     = 'read-chat.ps1'
      Level    = 'L1'
      Summary  = 'open a conversation and read its rendered messages'
      Params   = @('OpenNick')
      Optional = @('SenderPid', 'Account', 'Limit', 'TargetId', 'SearchId', 'ExpectAccountNick', 'TimeoutSec')
      Switches = @('verbose')
    }
    'search' = @{
      File     = 'search.ps1'
      Level    = 'L1'
      Summary  = 'global search for a contact, group or chat history entry'
      Params   = @('Keyword')
      Optional = @('SenderPid', 'Account', 'Limit', 'Activate', 'ExpectAccountNick', 'TimeoutSec')
      Switches = @('verbose', 'keepOpen')
    }
    'open-chat' = @{
      File     = 'open-chat.ps1'
      Level    = 'L1'
      Summary  = 'open a conversation, verify the switch took effect, capture evidence'
      Params   = @('ExpectNick')
      Optional = @('SenderPid', 'Account', 'TargetId', 'SearchId', 'ExpectAccountNick', 'AllowSameHeader', 'TimeoutSec')
      Switches = @('verbose', 'noScreenshot')
    }
    'send-message' = @{
      File     = 'send-message.ps1'
      Level    = 'L2'
      Summary  = 'send ONE text message after the guard chain passes (irreversible)'
      Params   = @('ExpectNick')
      Optional = @('SenderPid', 'Account', 'MessageText', 'MessageFile', 'MessageBase64', 'ExpectAccountNick', 'TimeoutSec')
      Switches = @('dryRun', 'verbose')
      Usage    = '-ExpectNick (-SenderPid N | -Account X) (-MessageFile | -MessageBase64 | -MessageText) [-ExpectAccountNick] [-TimeoutSec N] [-DryRun]'
    }
  }
}

function Write-QQUsage {
  <#
  .SYNOPSIS
    Writes usage text to stderr.
  .PARAMETER IncludeCommands
    Whether to list every command with its level, summary and parameters.
  #>
  param([bool]$IncludeCommands = $true)
  Write-QQLog -Text 'QQ UIA automation framework (FRAMEWORK-DESIGN v0.2)'
  Write-QQLog -Text 'Usage: qq-uia.ps1 <command> [parameters]'
  Write-QQLog -Text 'Output: one JSON envelope on stdout; diagnostics on stderr.'
  Write-QQLog -Text ''
  if ($IncludeCommands) {
    $registry = Get-QQCommandRegistry
    foreach ($name in $registry.Keys) {
      $spec = $registry[$name]
      Write-QQLog -Text ("  {0}  [{1}] {2}" -f $name, $spec.Level, $spec.Summary)
      # A command with alternatives the mechanical join cannot express (send-message
      # takes exactly one of three payload forms) states its own Usage line.
      if ($spec.ContainsKey('Usage')) {
        Write-QQLog -Text ('      {0}' -f [string]$spec.Usage)
        continue
      }
      $parts = @()
      foreach ($p in @($spec.Params)) { $parts += ('-' + $p) }
      $optional = @()
      if ($spec.ContainsKey('Optional')) { $optional = @($spec.Optional) }
      foreach ($p in $optional) { $optionalLine = ('-{0}' -f $p); $parts += ('[' + $optionalLine + ']') }
      foreach ($p in @($spec.Switches)) { $parts += ('[-' + $p + ']') }
      Write-QQLog -Text ('      {0}' -f ($parts -join ' '))
    }
    Write-QQLog -Text ''
    Write-QQLog -Text 'Rules: every window command selects its instance with -SenderPid or -Account (config.json defaultAccount fills in when both are absent).'
    Write-QQLog -Text '       -ExpectNick is mandatory for send-message and open-chat; it must match exactly.'
    Write-QQLog -Text 'Exit codes: 0 ok, 1 error, 2 bad args, 3 not found, 4 guard abort, 5 env not ready, 6 timeout'
  }
  Write-QQLog -Text 'Read docs/AGENT-MANUAL.md before driving this framework.'
}

function Assert-QQSpecifiedParams {
  <#
  .SYNOPSIS
    Validates the supplied arguments against the command registry.
  .DESCRIPTION
    An unknown or missing parameter aborts with BAD_ARGS before any UIA call, so
    a typo costs one process start instead of a partially executed UI action. This
    is the check that makes "-ExpecNick" impossible to run by accident.
  .PARAMETER Spec
    Registry entry for the command.
  .PARAMETER Command
    Command name, for the error payload.
  .PARAMETER Allowed
    Every parameter name the command accepts, including switches. The dispatcher
    computes it once so validation and its error text cannot disagree about what
    was acceptable.
  .PARAMETER Supplied
    Parameter names the caller actually provided. A command that takes none
    supplies an empty collection, so this is bound as an optional array rather
    than a mandatory parameter (a null or empty value is a valid, common case).
  .OUTPUTS
    [string[]] the validated parameter name list.
  #>
  param(
    [Parameter(Mandatory)]$Spec,
    [Parameter(Mandatory)][string]$Command,
    [string[]]$Allowed = @(),
    [string[]]$Supplied = @()
  )
  if ($null -eq $Supplied) { $Supplied = @() }
  $Supplied = @($Supplied)
  $allowed = @($Allowed)
  $required = @($Spec.Params)
  $unknown = @($Supplied | Where-Object { $allowed -notcontains $_ })
  if ($unknown.Count -gt 0) {
    throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message ("unknown parameter(s) for '{0}': {1}" -f $Command, (($unknown | ForEach-Object { '-' + $_ }) -join ', ')) -Details @{ command = $Command; unknown = @($unknown | ForEach-Object { '-' + $_ }); allowed = @($allowed | Sort-Object) })
  }
  $missing = @($required | Where-Object { $Supplied -notcontains $_ })
  if ($missing.Count -gt 0) {
    throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message ("missing required parameter(s) for '{0}': {1}" -f $Command, (($missing | ForEach-Object { '-' + $_ }) -join ', ')) -Details @{ command = $Command; missing = @($missing | ForEach-Object { '-' + $_ }) })
  }
  return $Supplied
}

function Get-QQArgValue {
  <#
  .SYNOPSIS
    Reads a named argument from the remaining-arguments array.
  .DESCRIPTION
    Accepts '-Name value' and '-Name=value'. Everything after the first
    '=' is the value, so a message containing '=' survives the round trip.
  .PARAMETER Name
    Parameter name without the leading dash.
  .PARAMETER Source
    Argument array to scan.
  .OUTPUTS
    [string] value, or $null when absent.
  #>
  param(
    [Parameter(Mandatory)][string]$Name,
    [string[]]$Source = $null
  )
  $src = $(if ($null -ne $Source) { $Source } else { $script:QQ_REMAINING_ARGS })
  if ($null -eq $src) { return $null }
  $found = $null
  for ($i = 0; $i -lt $src.Count; $i++) {
    $a = [string]$src[$i]
    if ($a -match ('^-' + [regex]::Escape($Name) + '=(.*)$')) { $found = $Matches[1]; continue }
    if ($a -ieq ('-' + $Name)) {
      if ($i + 1 -lt $src.Count) { $found = [string]$src[$i + 1] }
      else { $found = '' }
    }
  }
  return $found
}

function Test-QQArgSwitch {
  <#
  .SYNOPSIS
    Reports whether a switch flag is present.
  .PARAMETER Name
    Switch name without the leading dash.
  .PARAMETER Source
    Argument array to scan.
  .OUTPUTS
    [bool].
  #>
  param(
    [Parameter(Mandatory)][string]$Name,
    [string[]]$Source = $null
  )
  $src = $(if ($null -ne $Source) { $Source } else { $script:QQ_REMAINING_ARGS })
  if ($null -eq $src) { return $false }
  foreach ($a in $src) { if ([string]$a -ieq ('-' + $Name)) { return $true } }
  return $false
}

function Get-QQIntArg {
  <#
  .SYNOPSIS
    Reads an integer argument, failing with BAD_ARGS when absent, empty or invalid.
  .PARAMETER Name
    Parameter name without the leading dash.
  .PARAMETER Required
    When set, an absent or empty value is BAD_ARGS rather than the default.
  .PARAMETER Default
    Value returned when the argument is optional and absent.
  .PARAMETER Min
    Inclusive lower bound.
  .PARAMETER Max
    Inclusive upper bound.
  .OUTPUTS
    [int] the parsed value.
  #>
  param(
    [Parameter(Mandatory)][string]$Name,
    [switch]$Required,
    [int]$Default = 0,
    [int]$Min = [int]::MinValue,
    [int]$Max = [int]::MaxValue
  )
  $v = Get-QQArgValue -Name $Name
  if ($null -eq $v -or $v -eq '') {
    if ($Required) {
      throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message ("missing required parameter -{0}" -f $Name) -Details @{ parameter = $Name })
    }
    return $Default
  }
  $parsed = 0
  if (-not [int]::TryParse([string]$v, [ref]$parsed)) {
    throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message ("parameter -{0} must be an integer, got '{1}'" -f $Name, $v) -Details @{ parameter = $Name; value = [string]$v })
  }
  if ($parsed -lt $Min -or $parsed -gt $Max) {
    throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message ("parameter -{0} must be between {1} and {2}, got {3}" -f $Name, $Min, $Max, $parsed) -Details @{ parameter = $Name; value = $parsed; min = $Min; max = $Max })
  }
  return $parsed
}

function Get-QQStringArg {
  <#
  .SYNOPSIS
    Reads a string argument, failing with BAD_ARGS when required and absent.
  .PARAMETER Name
    Parameter name without the leading dash.
  .PARAMETER Required
    When set, an absent or empty value is BAD_ARGS.
  .OUTPUTS
    [string] the value, or '' when optional and absent.
  #>
  param(
    [Parameter(Mandatory)][string]$Name,
    [switch]$Required
  )
  $v = Get-QQArgValue -Name $Name
  if ($null -eq $v -or $v -eq '') {
    if ($Required) {
      throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message ("missing required parameter -{0}" -f $Name) -Details @{ parameter = $Name })
    }
    return ''
  }
  return [string]$v
}

function Get-QQMessageTextArg {
  <#
  .SYNOPSIS
    Resolves the message payload from -MessageFile, -MessageBase64 or -Message.
  .DESCRIPTION
    FRAMEWORK-DESIGN 4.3 precedence: a UTF-8 file beats base64 beats a literal,
    because a literal is the form most likely to arrive mangled by the shell's
    code page. There is NO default text: an absent payload is BAD_ARGS, never a
    built-in phrase (the pre-framework script shipped one and sent it when the
    argument was forgotten).
  .PARAMETER MaxLength
    Maximum accepted length in characters.
  .OUTPUTS
    [hashtable] Text, Source ('file'|'base64'|'literal'), File.
  #>
  param([int]$MaxLength = 2000)
  $file = Get-QQStringArg -Name 'MessageFile'
  if (-not [string]::IsNullOrEmpty($file)) {
    if (-not (Test-Path -LiteralPath $file)) {
      throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message ("-MessageFile not found: {0}" -f $file) -Details @{ file = $file })
    }
    $text = ''
    try {
      $text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
    } catch {
      throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message ("-MessageFile could not be read as UTF-8: {0}" -f $_.Exception.Message) -Details @{ file = $file })
    }
    return @{ Text = ([string]$text).TrimEnd("`r", "`n"); Source = 'file'; File = $file }
  }

  $b64 = Get-QQStringArg -Name 'MessageBase64'
  if (-not [string]::IsNullOrEmpty($b64)) {
    try {
      $bytes = [Convert]::FromBase64String($b64)
      return @{ Text = [System.Text.Encoding]::UTF8.GetString($bytes); Source = 'base64'; File = '' }
    } catch {
      throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message '-MessageBase64 is not valid base64' -Details @{ parameter = 'MessageBase64' })
    }
  }

  $literal = Get-QQArgValue -Name 'MessageText'
  if ($null -ne $literal -and $literal -ne '') {
    return @{ Text = [string]$literal; Source = 'literal'; File = '' }
  }

  throw (New-QQErrorRecord -Code 'BAD_ARGS' -Message 'no message text supplied: pass -MessageFile <utf8 path>, -MessageBase64 <b64> or -MessageText <text> (an empty message is rejected)' -Details @{ parameters = @('MessageFile', 'MessageBase64', 'MessageText') })
}

function Get-QQSuppliedParamNames {
  <#
  .SYNOPSIS
    Lists the parameter names the caller actually supplied.
  .DESCRIPTION
    Messages may contain spaces and dashes, so a token that follows a value-taking
    parameter is skipped rather than inspected. Only recognised parameter switches
    are reported, which keeps a message body from looking like a parameter name.
  .PARAMETER Known
    Every parameter name the command accepts.
  .PARAMETER ValueParams
    The subset of Known that takes a following value. Any other recognised name
    is a switch, so the token after it is left alone. Without this distinction a
    switch followed by a value such as '-DryRun -MessageText hello' would treat
    'hello' as a parameter position and quietly mis-parse.
  .PARAMETER Source
    Argument array to scan.
  .OUTPUTS
    [string[]] supplied parameter names.
  #>
  param(
    [Parameter(Mandatory)]$Known,
    [string[]]$ValueParams = @(),
    [string[]]$Source = $null
  )
  $src = $(if ($null -ne $Source) { $Source } else { $script:QQ_REMAINING_ARGS })
  $supplied = New-Object System.Collections.ArrayList
  if ($null -eq $src) { return @() }
  for ($i = 0; $i -lt $src.Count; $i++) {
    $a = [string]$src[$i]
    if ($a -notmatch '^-([A-Za-z][A-Za-z0-9]*)(=.*)?$') { continue }
    $name = $Matches[1]
    $match = @($Known | Where-Object { $_ -ieq $name })
    if ($match.Count -eq 0) {
      # Report unknown switches so validation can name them, but never treat a
      # value that merely starts with '-' as a parameter.
      [void]$supplied.Add([string]$name)
      continue
    }
    # Report the registry's own spelling so case-insensitive callers are accepted
    # ("-DryRun" and "-dryrun" both resolve to the registered switch).
    [void]$supplied.Add([string]$match[0])
    $takesValue = $false
    foreach ($vp in @($ValueParams)) { if ($vp -ieq $match[0]) { $takesValue = $true; break } }
    if ($takesValue -and $null -eq $Matches[2] -and ($i + 1) -lt $src.Count) { $i++ }
  }
  return @($supplied | Select-Object -Unique)
}

function Write-QQVersion {
  <#
  .SYNOPSIS
    Writes framework and host version diagnostics to stderr.
  #>
  Write-QQLog -Text ("qq-uia framework {0}" -f $script:QQ_FRAMEWORK_VERSION)
  Write-QQLog -Text ("powershell {0}" -f $PSVersionTable.PSVersion.ToString())
  $sel = Get-QQSelector
  if ($null -ne $sel) {
    Write-QQLog -Text ("selectors {0} verified on {1}" -f $sel.Version, $sel.VerifiedOn)
  }
  Write-QQLog -Text 'authority: G:\work\FRAMEWORK-DESIGN.md and G:\work\AGENT-MANUAL.md'
}

# ---------------------------------------------------------------------------
# bootstrap: help, version and command validation all happen before any UIA call
# ---------------------------------------------------------------------------

if ($Version) {
  Write-QQVersion
  exit (Get-QQExitCode -Name 'OK')
}

$registry = Get-QQCommandRegistry

if ($Help -or $ListCommands -or [string]::IsNullOrEmpty($Command)) {
  Write-QQUsage -IncludeCommands $true
  if ($Help -or $ListCommands) { exit (Get-QQExitCode -Name 'OK') }
  $code = Write-QQEnvelope -Ok $false -Command '' -ErrorCode 'BAD_ARGS' -Text 'no command given; usage was written to stderr'
  exit $code
}

if (-not $registry.Contains($Command)) {
  $known = @($registry.Keys)
  Write-QQLog -Text ("unknown command '{0}'; known commands: {1}" -f $Command, ($known -join ', '))
  $code = Write-QQEnvelope -Ok $false -Command $Command -ErrorCode 'BAD_ARGS' -Text ("unknown command '{0}'" -f $Command) -Details @{ known = $known }
  exit $code
}

$spec = $registry[$Command]
$cmdFile = Join-Path $script:QQ_CMD_DIR $spec.File

$script:QQ_REMAINING_ARGS = $Args
$script:QQ_CONFIG = $null
$script:QQ_PID = $null

try {
  if (-not (Test-Path -LiteralPath $cmdFile)) {
    throw (New-QQErrorRecord -Code 'ERROR' -Message ("command '{0}' is registered but {1} is missing" -f $Command, $spec.File) -Details @{ command = $Command; file = [string]$spec.File })
  }

  $script:QQ_CONFIG = Get-QQConfig -Root $PSScriptRoot
  if (-not $script:QQ_CONFIG.Valid) {
    Write-QQLog -Text ("config.json is not usable ({0}); defaults apply" -f $script:QQ_CONFIG.ParseError)
  }

  # Validate arguments before dot-sourcing the command, so a typo cannot reach UIA.
  $allowedNames = @($spec.Params) + @($spec.Optional) + @($spec.Switches)
  $valueNames = @($spec.Params) + @($spec.Optional)
  $supplied = Get-QQSuppliedParamNames -Known $allowedNames -ValueParams $valueNames
  [void](Assert-QQSpecifiedParams -Spec $spec -Command $Command -Allowed $allowedNames -Supplied $supplied)

  # -TimeoutSec is an Optional on the L1/L2 window commands (FRAMEWORK-DESIGN 4.3).
  # It is resolved once, here: the caller's value wins, otherwise
  # timeouts.defaultSec applies. 0 means "no ceiling" and is what a deployment sets
  # to turn the cap off entirely.
  $timeoutSec = Get-QQIntArg -Name 'TimeoutSec' -Default 0 -Min 0 -Max 3600
  if ($timeoutSec -le 0) {
    $timeoutSec = 0
    if ($script:QQ_CONFIG.ContainsKey('DefaultTimeoutSec')) { $timeoutSec = [int]$script:QQ_CONFIG['DefaultTimeoutSec'] }
  }

  $context = @{
    Command     = $Command
    Spec        = $spec
    Root        = $PSScriptRoot
    LibDir      = $script:QQ_LIB_DIR
    CmdDir      = $script:QQ_CMD_DIR
    Config      = $script:QQ_CONFIG
    Timeouts    = (Get-QQTimeouts -Config $script:QQ_CONFIG)
    TimeoutSec  = [int]$timeoutSec
    EvidenceDir = (Get-QQEvidenceDir -Config $script:QQ_CONFIG -Root $PSScriptRoot)
    Args        = $Args
    DryRun      = (Test-QQArgSwitch -Name 'dryRun')
    Verbose     = (Test-QQArgSwitch -Name 'verbose')
    SysLog      = { param([string]$t) Write-QQLog -Text $t }
  }
  $script:QQ_CONTEXT = $context

  # Shared command helpers; command files themselves are loaded one at a time so a
  # broken command cannot affect an unrelated one.
  $commonFile = Join-Path $script:QQ_CMD_DIR '_common.ps1'
  if (Test-Path -LiteralPath $commonFile) { . $commonFile }
  $openFile = Join-Path $script:QQ_CMD_DIR '_open.ps1'
  if (Test-Path -LiteralPath $openFile) { . $openFile }

  . $cmdFile
  if (-not (Get-Command -Name 'Invoke-QQCommand' -CommandType Function -ErrorAction SilentlyContinue)) {
    throw (New-QQErrorRecord -Code 'ERROR' -Message ("commands/{0} does not define Invoke-QQCommand" -f $spec.File) -Details @{ file = [string]$spec.File })
  }

  # Anything a command writes to the output stream would share stdout with the
  # envelope and corrupt the JSON. The wrapper script block returns ONLY the
  # command's result, so the array below holds the result when a command behaves
  # and any stray items alongside it when it does not; strays go to stderr.
  $emitted = @(& { return (Invoke-QQCommand -Context $context) })
  $result = $null
  $strays = New-Object System.Collections.ArrayList
  foreach ($item in $emitted) {
    if ($null -eq $item) { continue }
    if ($null -eq $result -and $item -is [System.Collections.IDictionary] -and $item.Contains('Data')) {
      $result = $item
    } else {
      [void]$strays.Add($item)
    }
  }
  foreach ($item in $strays) {
    Write-QQLog -Text ("command wrote unexpected output to the pipeline: {0}" -f [string]$item)
  }

  if ($null -eq $result) {
    throw (New-QQErrorRecord -Code 'ERROR' -Message ("command '{0}' returned nothing" -f $Command))
  }
  $data = $null
  if ($result -is [System.Collections.IDictionary] -and $result.Contains('Data')) { $data = $result['Data'] }
  if ($result -is [System.Collections.IDictionary] -and $result.Contains('Pid') -and $null -ne $result['Pid']) { $script:QQ_PID = [int]$result['Pid'] }

  $code = Write-QQEnvelope -Ok $true -Command $Command -Data $data -TargetPid $script:QQ_PID
  exit $code
} catch {
  $ex = $_.Exception
  $detailCode = 'ERROR'
  $details = $null
  $text = $ex.Message
  $probe = $ex
  while ($null -ne $probe) {
    try {
      if ($probe.Data.Contains('QQCode')) { $detailCode = [string]$probe.Data['QQCode'] }
      if ($probe.Data.Contains('QQDetails')) { $details = $probe.Data['QQDetails'] }
    } catch { }
    $probe = $probe.InnerException
  }
  # The detailed code (GUARD_MESSAGE_EMPTY, GUARD_HEADER_MISMATCH, ...) names the
  # exact rule that fired, but the envelope's error.code must be one of the
  # FRAMEWORK-DESIGN 5.3 names: a guard code maps to GUARD_ABORT so the exit code
  # is 4, which the manual tells the agent to treat as "stop, do not retry".
  $codeName = Resolve-QQExitCodeName -Code $detailCode
  if ($codeName -ne $detailCode) {
    if ($null -eq $details) { $details = @{} }
    if ($details -is [System.Collections.IDictionary]) { $details['guard'] = $detailCode }
  }
  $exitCode = Write-QQEnvelope -Ok $false -Command $Command -ErrorCode $codeName -Text $text -Details $details -TargetPid $script:QQ_PID
  Write-QQLog -Text ("[{0}] {1}" -f $detailCode, $text)
  exit $exitCode
}
