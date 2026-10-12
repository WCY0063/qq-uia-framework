# =============================================================================
# qq-config-ui.ps1 - the framework's graphical configuration surface (WPF).
# Authority: docs/FRAMEWORK-DESIGN.md (configuration); README.md section 8.
#
# Why it exists: config.json is the only configuration, and until now every edit
# was a hand-written JSON patch with no feedback. This window shows the RUNNING QQ
# instances beside the accounts[] table that `-Account` resolves against, so a
# mistyped alias is visible immediately instead of failing a send minutes later.
#
# The rules the rest of the framework obeys, obeyed here too:
#   * It NEVER starts, restarts or stops a QQ process. "Copy launch command"
#     puts the --force-renderer-accessibility command line on the clipboard and
#     stops there; running it stays the operator's decision.
#   * It NEVER focuses, clicks or types into a QQ window. The instance list is
#     read through UIA only (EnumWindows + AutomationElement.FromHandle) and is
#     display-only.
#   * It never sends a message and never touches evidence/.
#   * config.json is written only after the form validates, and only after the
#     previous file is copied to config.json.bak.
#
# This is the ONLY file in the framework that starts a process of its own: a WPF
# window needs an STA thread, so a start on an MTA thread re-runs this same script
# under -STA. The process it starts is powershell.exe, never QQ.
#
# Usage:
#   powershell -STA -NoProfile -ExecutionPolicy Bypass -File qq-config-ui.ps1
#   (equivalently: qq-uia.ps1 config-ui)
#
# ASCII-ONLY SOURCE. PowerShell 5.1 decodes a BOM-less file as ANSI, so CJK in a
# literal would corrupt parsing. Interface copy lives in ui/config-ui.xaml (UTF-8
# by design); runtime strings are assembled from [char] codes below. run-tests.ps1
# enforces this rule.
# =============================================================================

param(
  [switch]$NoWindow
)

$ErrorActionPreference = 'Stop'

# $PSCommandPath and $PSScriptRoot both resolve to THIS file, also when it is
# dot-sourced for the self-check, which is how the -NoWindow path gets its paths.
$script:SelfPath = $PSCommandPath
if ([string]::IsNullOrEmpty($script:SelfPath)) { $script:SelfPath = $MyInvocation.MyCommand.Definition }
$script:Root = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:Root)) { $script:Root = Split-Path -Parent $script:SelfPath }

$script:XamlPath    = Join-Path $script:Root 'ui\config-ui.xaml'
$script:ConfigPath  = Join-Path $script:Root 'config.json'
$script:Dispatcher  = Join-Path $script:Root 'qq-uia.ps1'
$script:DefaultQQPath = 'C:\Program Files\Tencent\QQNT\QQ.exe'

# Every control the script touches. run-tests.ps1 reads THIS list and asserts
# ui/config-ui.xaml can resolve all of it, so a rename on either side is caught
# by the self-check instead of by a crash at start-up.
$script:UiControlNames = @(
  'InstancesGrid', 'AccountsGrid',
  'BtnRefresh', 'BtnDoctor',
  'BtnAddAccount', 'BtnRemoveAccount', 'BtnSetDefault', 'BtnUp', 'BtnDown', 'BtnBindFromInstance',
  'DpiModeCombo', 'DpiScaleBox', 'DefaultSecBox', 'MinNodesBox', 'MinWidthBox', 'MinSendIntervalBox',
  'RequireAccountMatchCheck', 'WriteAuditCheck',
  'QQPathBox',
  'BtnSave', 'BtnReload', 'BtnOpenEvidence', 'BtnCopyLaunch',
  'StatusText'
)

# ---------------------------------------------------------------------------
# framework libraries
# ---------------------------------------------------------------------------
# Loaded BEFORE the helpers below, so a name this file defines can never be the
# one that accidentally wins: dot-sourcing a library after a definition would
# silently replace it (lib/qq-core.ps1 already owns Get-QQUiText, which is why the
# label helper here is called Get-QQUiLabel). run-tests.ps1 asserts that no
# function in this file has the same name as one the libraries define.
. (Join-Path $script:Root 'lib\qq-json.ps1')
. (Join-Path $script:Root 'lib\qq-core.ps1')
. (Join-Path $script:Root 'lib\qq-guards.ps1')

# ---------------------------------------------------------------------------
# runtime strings: kept out of the source as literals (ASCII-only rule) and
# assembled from character codes, the same way lib/qq-core.ps1 builds the
# localized QQ labels it matches.
# ---------------------------------------------------------------------------

function New-QQUiString {
  <#
  .SYNOPSIS
    Builds a string from character codes and ASCII fragments.
  .DESCRIPTION
    Integer items are appended as the character with that code, string items are
    appended literally. Mixing the two keeps ASCII words (a config key, a path)
    readable in the source while CJK stays in code-point form.
  .PARAMETER Codes
    Character codes and / or literal fragments.
  .OUTPUTS
    [string].
  #>
  param([object[]]$Codes = @())
  $sb = New-Object System.Text.StringBuilder
  foreach ($item in @($Codes)) {
    if ($item -is [string]) { [void]$sb.Append([string]$item); continue }
    if ($item -is [char]) { [void]$sb.Append([char]$item); continue }
    if ($item -is [int] -or $item -is [long]) { [void]$sb.Append([char][int]$item) }
  }
  return $sb.ToString()
}

function Get-QQUiLabel {
  <#
  .SYNOPSIS
    Returns a localized UI string by key.
  .DESCRIPTION
    Only the strings that cannot live in ui/config-ui.xaml are here: the static
    labels are XAML, while every status line, dialog and validation message is
    produced at run time. An unknown key returns '' rather than a placeholder.
  .PARAMETER Key
    Message key.
  .OUTPUTS
    [string].
  #>
  param([Parameter(Mandatory)][string]$Key)
  switch ($Key) {
    'unsaved'            { return (New-QQUiString -Codes @(0x672A, 0x4FDD, 0x5B58, 0x4FEE, 0x6539)) }
    'clean'              { return (New-QQUiString -Codes @(0x65E0, 0x6539, 0x52A8)) }
    'refreshed'          { return (New-QQUiString -Codes @(0x5DF2, 0x5237, 0x65B0)) }
    'doctorRunning'      { return (New-QQUiString -Codes @('doctor ', 0x81EA, 0x68C0, 0x4E2D, 0xFF0C, 0x8BF7, 0x7A0D, 0x5019, 0x2026)) }
    'doctorDone'         { return (New-QQUiString -Codes @(0x81EA, 0x68C0, 0x7ED3, 0x679C)) }
    'validationFailed'   { return (New-QQUiString -Codes @(0x914D, 0x7F6E, 0x6821, 0x9A8C, 0x5931, 0x8D25)) }
    'saveFailed'         { return (New-QQUiString -Codes @(0x4FDD, 0x5B58, 0x5931, 0x8D25)) }
    'savedOk'            { return (New-QQUiString -Codes @(0x914D, 0x7F6E, 0x5DF2, 0x4FDD, 0x5B58)) }
    'reloaded'           { return (New-QQUiString -Codes @(0x5DF2, 0x91CD, 0x65B0, 0x52A0, 0x8F7D, 0x914D, 0x7F6E)) }
    'clipboardOk'        { return (New-QQUiString -Codes @(0x542F, 0x52A8, 0x547D, 0x4EE4, 0x5DF2, 0x590D, 0x5236, 0x5230, 0x526A, 0x8D34, 0x677F, 0xFF08, 0x4E0D, 0x4F1A, 0x81EA, 0x52A8, 0x6267, 0x884C, 0xFF09)) }
    'clipboardFailed'    { return (New-QQUiString -Codes @(0x590D, 0x5236, 0x5230, 0x526A, 0x8D34, 0x677F, 0x5931, 0x8D25)) }
    'evidenceOpened'     { return (New-QQUiString -Codes @(0x5DF2, 0x6253, 0x5F00, 0x8BC1, 0x636E, 0x76EE, 0x5F55)) }
    'evidenceFailed'     { return (New-QQUiString -Codes @(0x6253, 0x5F00, 0x8BC1, 0x636E, 0x76EE, 0x5F55, 0x5931, 0x8D25)) }
    'needAccountRow'     { return (New-QQUiString -Codes @(0x8BF7, 0x5148, 0x5728, 0x53F3, 0x4FA7, 0x9009, 0x4E2D, 0x4E00, 0x4E2A, 0x8D26, 0x53F7, 0x884C)) }
    'needInstanceRow'    { return (New-QQUiString -Codes @(0x8BF7, 0x5148, 0x5728, 0x4E0A, 0x65B9, 0x9009, 0x4E2D, 0x4E00, 0x4E2A, 0x8FD0, 0x884C, 0x5B9E, 0x4F8B)) }
    'boundFromInstance'  { return (New-QQUiString -Codes @(0x5DF2, 0x4ECE, 0x9009, 0x4E2D, 0x5B9E, 0x4F8B, 0x586B, 0x5165, 0x6635, 0x79F0)) }
    'addedAccount'       { return (New-QQUiString -Codes @(0x5DF2, 0x6DFB, 0x52A0, 0x8D26, 0x53F7, 0x884C)) }
    'defaultSet'         { return (New-QQUiString -Codes @(0x5DF2, 0x8BBE, 0x4E3A, 0x9ED8, 0x8BA4, 0x8D26, 0x53F7)) }
    'removedAccount'     { return (New-QQUiString -Codes @(0x5DF2, 0x5220, 0x9664, 0x8D26, 0x53F7)) }
    'confirmDeleteTitle' { return (New-QQUiString -Codes @(0x5220, 0x9664, 0x8D26, 0x53F7)) }
    'confirmDeleteText'  { return (New-QQUiString -Codes @(0x786E, 0x5B9A, 0x5220, 0x9664, 0x9009, 0x4E2D, 0x7684, 0x8D26, 0x53F7, 0x884C, 0xFF1F)) }
    'confirmReloadTitle' { return (New-QQUiString -Codes @(0x91CD, 0x65B0, 0x52A0, 0x8F7D)) }
    'confirmReloadText'  { return (New-QQUiString -Codes @(0x6709, 0x672A, 0x4FDD, 0x5B58, 0x7684, 0x6539, 0x52A8, 0xFF0C, 0x786E, 0x5B9A, 0x4E22, 0x5F03, 0x5E76, 0x91CD, 0x65B0, 0x52A0, 0x8F7D, 0xFF1F)) }
    'unsavedCloseWarning' { return (New-QQUiString -Codes @(0x6709, 0x672A, 0x4FDD, 0x5B58, 0x7684, 0x6539, 0x52A8, 0xFF1A, 0x518D, 0x6B21, 0x5173, 0x95ED, 0x5C06, 0x653E, 0x5F03, 0x6539, 0x52A8, 0xFF0C, 0x6216, 0x5148, 0x70B9, 0x4FDD, 0x5B58)) }
    'aliasEmpty'         { return (New-QQUiString -Codes @(0x522B, 0x540D, 0x4E3A, 0x7A7A)) }
    'aliasDupe'          { return (New-QQUiString -Codes @(0x522B, 0x540D, 0x91CD, 0x590D, 0xFF08, 0x5FFD, 0x7565, 0x5927, 0x5C0F, 0x5199, 0xFF09)) }
    'nickEmpty'          { return (New-QQUiString -Codes @(0x6635, 0x79F0, 0x4E3A, 0x7A7A)) }
    'qqIdInvalid'        { return (New-QQUiString -Codes @('QQ ', 0x53F7, 0x5FC5, 0x987B, 0x662F, 0x7EAF, 0x6570, 0x5B57)) }
    'defaultInvalid'     { return (New-QQUiString -Codes @(0x9ED8, 0x8BA4, 0x8D26, 0x53F7, 0x5FC5, 0x987B, 0x662F, 0x67D0, 0x4E2A, 0x5DF2, 0x542F, 0x7528, 0x8D26, 0x53F7, 0x7684, 0x522B, 0x540D)) }
    'scaleRange'         { return (New-QQUiString -Codes @('dpi.scale ', 0x5FC5, 0x987B, 0x5728, ' 0.5 ', 0x5230, ' 5.0 ', 0x4E4B, 0x95F4)) }
    'positiveInt'        { return (New-QQUiString -Codes @(0x5FC5, 0x987B, 0x662F, 0x6B63, 0x6574, 0x6570)) }
    'nonNegativeInt'     { return (New-QQUiString -Codes @(0x5FC5, 0x987B, 0x662F, 0x975E, 0x8D1F, 0x6574, 0x6570)) }
    'rowPrefix'          { return (New-QQUiString -Codes @(0x7B2C)) }
    'rowSuffix'          { return (New-QQUiString -Codes @(0x884C, 0xFF1A)) }
    'configLoadFailed'   { return (New-QQUiString -Codes @('config.json ', 0x8BFB, 0x53D6, 0x5931, 0x8D25, 0xFF0C, 0x4FDD, 0x5B58, 0x5DF2, 0x7981, 0x7528)) }
    'xamlMissing'        { return (New-QQUiString -Codes @(0x627E, 0x4E0D, 0x5230, 0x754C, 0x9762, 0x6587, 0x4EF6)) }
    'needInteger'        { return (New-QQUiString -Codes @(0x5FC5, 0x987B, 0x662F, 0x6574, 0x6570)) }
    'needNumber'         { return (New-QQUiString -Codes @(0x5FC5, 0x987B, 0x662F, 0x6570, 0x5B57)) }
    default              { return '' }
  }
}

$script:Document       = $null
$script:AccountsTable  = $null
$script:DefaultAccount = ''
$script:Dirty          = $false
$script:Message        = ''
$script:DoctorText     = ''
$script:Loading        = $false
$script:CloseRequested = $false
$script:Window         = $null
$script:Ui             = @{}

# ---------------------------------------------------------------------------
# config.json access
# ---------------------------------------------------------------------------

function Get-QQUiConfigDocument {
  <#
  .SYNOPSIS
    Reads config.json into a JSON object graph.
  .DESCRIPTION
    The document is kept as parsed and mutated in place on save, so every key the
    UI does not own (typing, evidence.keepLatestAliases, ...) survives a save
    unchanged. A file that cannot be read is an error, never a fresh default
    document: writing a default over an unreadable config would silently drop the
    operator's settings.
  .PARAMETER Path
    config.json path.
  .OUTPUTS
    The parsed document.
  #>
  param([string]$Path = $script:ConfigPath)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw (New-QQErrorRecord -Code 'NOT_FOUND' -Message ("config.json not found: {0}" -f $Path) -Details @{ path = $Path })
  }
  $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($text)) {
    throw (New-QQErrorRecord -Code 'ERROR' -Message ("config.json is empty: {0}" -f $Path) -Details @{ path = $Path })
  }
  try {
    return ($text | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    throw (New-QQErrorRecord -Code 'ERROR' -Message ("config.json is not valid JSON: {0}" -f $_.Exception.Message) -Details @{ path = $Path })
  }
}

function Get-QQUiNodeValue {
  <#
  .SYNOPSIS
    Reads one field of a JSON node, tolerating hashtables and missing keys.
  .PARAMETER Node
    Parsed JSON node (PSObject or hashtable), or $null.
  .PARAMETER Name
    Field name.
  .PARAMETER Default
    Value returned when the field is absent or null.
  .OUTPUTS
    The value, or Default.
  #>
  param($Node, [Parameter(Mandatory)][string]$Name, $Default = '')
  if ($null -eq $Node) { return $Default }
  if ($Node -is [System.Collections.IDictionary]) {
    if ($Node.Contains($Name) -and $null -ne $Node[$Name]) { return $Node[$Name] }
    return $Default
  }
  $names = @()
  try { $names = @($Node.PSObject.Properties.Name) } catch { return $Default }
  if ($names -notcontains $Name) { return $Default }
  $value = $Node.$Name
  if ($null -eq $value) { return $Default }
  return $value
}

function Get-QQUiConfigValue {
  <#
  .SYNOPSIS
    Reads a dotted config path.
  .PARAMETER Document
    Parsed config document.
  .PARAMETER Path
    Path segments, for example @('guards', 'minSendIntervalMs').
  .PARAMETER Default
    Value returned when any segment is missing.
  .OUTPUTS
    The value, or Default.
  #>
  param($Document, [Parameter(Mandatory)][string[]]$Path, $Default = '')
  $node = $Document
  foreach ($segment in $Path) {
    if ($null -eq $node) { return $Default }
    $value = Get-QQUiNodeValue -Node $node -Name $segment -Default $null
    if ($null -eq $value) { return $Default }
    $node = $value
  }
  if ($null -eq $node) { return $Default }
  return $node
}

function Set-QQUiConfigValue {
  <#
  .SYNOPSIS
    Writes a dotted config path, creating missing sections.
  .DESCRIPTION
    A section the file omitted is created as an empty PSObject so the written
    document keeps object nesting instead of collapsing into a scalar. An existing
    property is assigned in place, which preserves the file's own key order.
  .PARAMETER Document
    Parsed config document, mutated in place.
  .PARAMETER Path
    Path segments.
  .PARAMETER Value
    Value to store.
  #>
  param(
    [Parameter(Mandatory)]$Document,
    [Parameter(Mandatory)][string[]]$Path,
    $Value = $null
  )
  $node = $Document
  for ($i = 0; $i -lt ($Path.Count - 1); $i++) {
    $segment = $Path[$i]
    $child = Get-QQUiNodeValue -Node $node -Name $segment -Default $null
    if ($null -eq $child) {
      $child = New-Object System.Management.Automation.PSObject
      if ($node -is [System.Collections.IDictionary]) {
        $node[$segment] = $child
      } elseif (@($node.PSObject.Properties.Name) -contains $segment) {
        $node.$segment = $child
      } else {
        $node | Add-Member -NotePropertyName $segment -NotePropertyValue $child -Force
      }
    }
    $node = $child
  }
  $last = $Path[$Path.Count - 1]
  if ($node -is [System.Collections.IDictionary]) {
    $node[$last] = $Value
    return
  }
  if (@($node.PSObject.Properties.Name) -contains $last) {
    $node.$last = $Value
    return
  }
  $node | Add-Member -NotePropertyName $last -NotePropertyValue $Value -Force
}

# ---------------------------------------------------------------------------
# live instances (read-only: EnumWindows + a UIA read of the account avatar)
# ---------------------------------------------------------------------------

function Get-QQUiLiveInstanceRows {
  <#
  .SYNOPSIS
    Enumerates the visible QQ windows and reads each one's account identity.
  .DESCRIPTION
    The same two reads the `identify` command performs (Get-QQWindowList then
    Get-QQAccountIdentity), kept here instead of dot-sourcing commands/_common.ps1
    so the window never depends on the dispatcher's context. Nothing is focused,
    clicked or typed; an unreadable instance is reported on stderr and still
    listed, because "no nickname" and "no window" are different answers.
  .PARAMETER Config
    Framework config hashtable (from Get-QQConfig), or $null for defaults.
  .OUTPUTS
    [object[]] one ordered hashtable per instance.
  #>
  param($Config = $null)
  $minNodes = Get-QQA11yMinNodes -Config $Config
  $windows = @(Get-QQWindowList -Config $Config | Sort-Object Pid)
  $rows = New-Object System.Collections.ArrayList
  foreach ($win in $windows) {
    $nodeCount = 0
    $nick = ''
    $signature = ''
    $online = $false
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
        }
      }
    } catch {
      Write-QQLog -Text ("config-ui: instance pid {0} could not be read: {1}" -f $win.Pid, $_.Exception.Message)
    }
    [void]$rows.Add([ordered]@{
      pid        = [string]$win.Pid
      nick       = [string]$nick
      signature  = [string]$signature
      online     = [bool]$online
      a11yActive = [bool](Test-QQA11yActive -NodeCount $nodeCount -MinNodes $minNodes)
      nodeCount  = [string]$nodeCount
      width      = [string]$win.Width
      height     = [string]$win.Height
      scale      = ([double]$win.Scale).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
      alias      = ''
    })
  }
  return @($rows)
}

function New-QQUiInstancesTable {
  <#
  .SYNOPSIS
    Builds the read-only DataTable behind the instance grid.
  .DESCRIPTION
    A DataTable is used rather than a list of PSCustomObjects because WPF can bind
    AND two-way edit a DataView without any code-behind: the account grid is
    editable, and an edited cell must land somewhere the save path can read.
  .OUTPUTS
    [System.Data.DataTable].
  #>
  $table = New-Object System.Data.DataTable
  foreach ($name in @('pid', 'nick', 'signature', 'nodeCount', 'width', 'height', 'scale', 'alias')) {
    [void]$table.Columns.Add($name, [string])
  }
  foreach ($name in @('online', 'a11yActive')) { [void]$table.Columns.Add($name, [bool]) }
  # The unary comma is required: PowerShell's pipeline tears a DataTable apart
  # looking for items to enumerate (it exposes IListSource) and a bare `return`
  # therefore arrives as $null. Wrapping it keeps the table itself as the value.
  return ,$table
}

function New-QQUiAccountsTable {
  <#
  .SYNOPSIS
    Builds the editable DataTable behind the account grid from config accounts[].
  .DESCRIPTION
    Every entry is kept, including one with an empty alias: Get-QQConfig drops
    those silently at load time, and an operator has to be able to SEE and FIX a
    broken entry in the editor rather than have it vanish. Save refuses to write
    such a row (see Test-QQUiAccountTable).
  .PARAMETER Document
    Parsed config document, or $null.
  .OUTPUTS
    [System.Data.DataTable] with isDefault/alias/nick/qqId/enabled/note columns.
  #>
  param($Document = $null)
  $table = New-Object System.Data.DataTable
  [void]$table.Columns.Add('isDefault', [string])
  [void]$table.Columns.Add('alias', [string])
  [void]$table.Columns.Add('nick', [string])
  [void]$table.Columns.Add('qqId', [string])
  [void]$table.Columns.Add('enabled', [bool])
  [void]$table.Columns.Add('note', [string])

  $entries = @()
  $raw = Get-QQUiConfigValue -Document $Document -Path @('accounts') -Default $null
  if ($null -ne $raw) { $entries = @($raw) }
  foreach ($entry in $entries) {
    if ($null -eq $entry) { continue }
    $enabled = $true
    $rawEnabled = Get-QQUiNodeValue -Node $entry -Name 'enabled' -Default $null
    if ($null -ne $rawEnabled) {
      if ($rawEnabled -is [bool]) { $enabled = [bool]$rawEnabled }
      else { $enabled = (([string]$rawEnabled).Trim().ToLowerInvariant() -ne 'false') }
    }
    [void]$table.Rows.Add(@(
      '',
      [string](Get-QQUiNodeValue -Node $entry -Name 'alias' -Default ''),
      [string](Get-QQUiNodeValue -Node $entry -Name 'nick' -Default ''),
      [string](Get-QQUiNodeValue -Node $entry -Name 'qqId' -Default ''),
      [bool]$enabled,
      [string](Get-QQUiNodeValue -Node $entry -Name 'note' -Default '')
    ))
  }
  # See New-QQUiInstancesTable: a bare DataTable return is torn apart by the
  # pipeline and arrives as $null.
  return ,$table
}

# ---------------------------------------------------------------------------
# serialization and writing
# ---------------------------------------------------------------------------

function ConvertTo-QQUiJsonText {
  <#
  .SYNOPSIS
    Serializes the config document to indented, pure-ASCII JSON text.
  .DESCRIPTION
    ConvertTo-Json does the escaping that matters for correctness (quotes,
    backslashes, control characters) in one compressed pass; two things are still
    done here:

      * ASCII. PowerShell 5.1 does NOT escape non-ASCII characters, so a Chinese
        alias would be written as raw UTF-8 bytes and config.json would stop being
        ASCII - which the framework's own source check rejects. Every character
        outside printable ASCII is rewritten as \\uXXXX, which ConvertFrom-Json
        restores losslessly.
      * Layout. The compressed form is re-indented two spaces per level (and an
        empty array or object stays on one line), so the file this window writes
        looks like the file it replaced.
  .PARAMETER Document
    Parsed config document.
  .OUTPUTS
    [string] JSON text without a trailing newline.
  #>
  param([Parameter(Mandatory)]$Document)
  $compact = $Document | ConvertTo-Json -Depth 12 -Compress
  if ([string]::IsNullOrEmpty($compact)) { return '' }
  $chars = $compact.ToCharArray()
  $sb = New-Object System.Text.StringBuilder
  $indent = 0
  $inString = $false
  $escaped = $false
  for ($i = 0; $i -lt $chars.Length; $i++) {
    $ch = $chars[$i]
    $code = [int]$ch
    if ($inString) {
      if ($escaped) { [void]$sb.Append($ch); $escaped = $false; continue }
      if ($ch -eq '\') { [void]$sb.Append($ch); $escaped = $true; continue }
      if ($ch -eq '"') { [void]$sb.Append($ch); $inString = $false; continue }
      if ($code -lt 0x20 -or $code -gt 0x7E) { [void]$sb.AppendFormat('\u{0:x4}', $code); continue }
      [void]$sb.Append($ch)
      continue
    }
    if ($ch -eq '"') { [void]$sb.Append($ch); $inString = $true; continue }
    if ($ch -eq '{' -or $ch -eq '[') {
      [void]$sb.Append($ch)
      $closer = $(if ($ch -eq '{') { '}' } else { ']' })
      if (($i + 1) -lt $chars.Length -and $chars[$i + 1] -eq $closer) { continue }
      $indent++
      [void]$sb.Append("`n").Append(' ' * (2 * $indent))
      continue
    }
    if ($ch -eq '}' -or $ch -eq ']') {
      $opener = $(if ($ch -eq '}') { '{' } else { '[' })
      if ($i -gt 0 -and $chars[$i - 1] -eq $opener) { [void]$sb.Append($ch); continue }
      $indent--
      if ($indent -lt 0) { $indent = 0 }
      [void]$sb.Append("`n").Append(' ' * (2 * $indent)).Append($ch)
      continue
    }
    if ($ch -eq ',') { [void]$sb.Append($ch).Append("`n").Append(' ' * (2 * $indent)); continue }
    if ($ch -eq ':') { [void]$sb.Append(': '); continue }
    [void]$sb.Append($ch)
  }
  return $sb.ToString()
}

function Save-QQUiConfigFile {
  <#
  .SYNOPSIS
    Writes the config document to disk, after backing the old file up.
  .DESCRIPTION
    The previous file is copied to config.json.bak first, and the text is verified
    to be pure ASCII before anything is written: the framework ships config.json
    as ASCII source (run-tests.ps1 checks it), so a serialization that leaked a
    non-escaped character must fail loudly instead of corrupting the file.
  .PARAMETER Path
    config.json path.
  .PARAMETER Document
    Parsed config document.
  .OUTPUTS
    [string] the text that was written.
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)]$Document
  )
  $text = ConvertTo-QQUiJsonText -Document $Document
  if ($text -match '[^\x00-\x7E]') {
    throw (New-QQErrorRecord -Code 'ERROR' -Message 'the serialized configuration is not pure ASCII; refusing to write it' -Details @{ path = $Path })
  }
  if (Test-Path -LiteralPath $Path) {
    Copy-Item -LiteralPath $Path -Destination ($Path + '.bak') -Force
  }
  [System.IO.File]::WriteAllText($Path, ($text + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  Write-QQLog -Text ("config-ui: wrote {0} bytes to {1}" -f $text.Length, $Path)
  return $text
}

# ---------------------------------------------------------------------------
# form validation
# ---------------------------------------------------------------------------

function Read-QQUiSettings {
  <#
  .SYNOPSIS
    Reads the settings widgets into typed values, collecting validation errors.
  .DESCRIPTION
    A malformed number and an out-of-range number are reported together with the
    account-row problems, so one Save click lists everything that is wrong rather
    than one error per attempt.
  .OUTPUTS
    [hashtable] Values (hashtable of typed values) and Errors (string[]).
  #>
  $errors = New-Object System.Collections.ArrayList
  $values = @{}

  $scaleText = ([string]$script:Ui['DpiScaleBox'].Text).Trim()
  $scale = 0.0
  if (-not [double]::TryParse($scaleText, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$scale)) {
    [void]$errors.Add(('dpi.scale ' + (Get-QQUiLabel 'needNumber')))
  } elseif ($scale -lt 0.5 -or $scale -gt 5.0) {
    [void]$errors.Add((Get-QQUiLabel 'scaleRange'))
  } else {
    $values['DpiScale'] = [double]$scale
  }

  # name / minimum / message key. defaultSec, minNodes and minWindowWidth must be
  # at least 1 (0 nodes or a 0-pixel window floor is not a usable setting);
  # minSendIntervalMs accepts 0, which is the documented way to switch the send
  # cooldown off, so it is checked against 0 rather than 1.
  foreach ($spec in @(
      @{ Key = 'DefaultSecBox';      Name = 'timeouts.defaultSec';      Min = 1; Text = 'positiveInt' },
      @{ Key = 'MinNodesBox';        Name = 'a11y.minNodes';            Min = 1; Text = 'positiveInt' },
      @{ Key = 'MinWidthBox';        Name = 'instances.minWindowWidth'; Min = 1; Text = 'positiveInt' },
      @{ Key = 'MinSendIntervalBox'; Name = 'guards.minSendIntervalMs'; Min = 0; Text = 'nonNegativeInt' }
    )) {
    $raw = ([string]$script:Ui[$spec.Key].Text).Trim()
    $parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed)) {
      [void]$errors.Add(('{0} {1}' -f $spec.Name, (Get-QQUiLabel 'needInteger')))
      continue
    }
    if ($parsed -lt [int]$spec.Min) {
      [void]$errors.Add(('{0} {1}' -f $spec.Name, (Get-QQUiLabel ([string]$spec.Text))))
      continue
    }
    $values[$spec.Name] = [int]$parsed
  }

  $mode = ''
  $selected = $script:Ui['DpiModeCombo'].SelectedItem
  if ($null -ne $selected) { $mode = ([string]$selected.Content).Trim() }
  if ([string]::IsNullOrEmpty($mode)) { $mode = 'auto' }
  $values['dpi.mode'] = $mode
  $values['guards.requireAccountMatch'] = [bool]$script:Ui['RequireAccountMatchCheck'].IsChecked
  $values['evidence.writeAudit'] = [bool]$script:Ui['WriteAuditCheck'].IsChecked
  $values['qqPath'] = ([string]$script:Ui['QQPathBox'].Text).Trim()

  return @{ Values = $values; Errors = @($errors) }
}

function Test-QQUiAccountTable {
  <#
  .SYNOPSIS
    Validates the account table, returning one message per problem.
  .DESCRIPTION
    The rules the resolver depends on: an alias is required and unique (compared
    case-insensitively, which is how -Account matches), a nickname is required
    (identity is bound by exact nickname), a QQ id is optional but numeric, and
    defaultAccount must name an ENABLED alias - a default pointing at a disabled
    or unknown alias would silently send nothing.
  .PARAMETER Table
    Account DataTable, as edited in the grid.
  .PARAMETER DefaultAccount
    Alias currently marked as default, or ''.
  .OUTPUTS
    [string[]] validation messages, empty when the table is valid.
  #>
  param(
    [Parameter(Mandatory)]$Table,
    [AllowEmptyString()][string]$DefaultAccount = ''
  )
  $errors = New-Object System.Collections.ArrayList
  $seen = @{}
  $index = 0
  foreach ($row in $Table.Rows) {
    $index++
    $label = ((Get-QQUiLabel 'rowPrefix') + [string]$index + (Get-QQUiLabel 'rowSuffix'))
    $alias = ([string]$row['alias']).Trim()
    $nick = ([string]$row['nick']).Trim()
    $qqId = ([string]$row['qqId']).Trim()
    if ([string]::IsNullOrEmpty($alias)) {
      [void]$errors.Add(($label + (Get-QQUiLabel 'aliasEmpty')))
    } else {
      $key = $alias.ToLowerInvariant()
      if ($seen.ContainsKey($key)) { [void]$errors.Add(($label + (Get-QQUiLabel 'aliasDupe'))) }
      else { $seen[$key] = $true }
    }
    if ([string]::IsNullOrEmpty($nick)) { [void]$errors.Add(($label + (Get-QQUiLabel 'nickEmpty'))) }
    if (-not [string]::IsNullOrEmpty($qqId) -and $qqId -notmatch '^[0-9]+$') {
      [void]$errors.Add(($label + (Get-QQUiLabel 'qqIdInvalid')))
    }
  }
  if (-not [string]::IsNullOrEmpty($DefaultAccount)) {
    $found = $false
    foreach ($row in $Table.Rows) {
      if (-not [bool]$row['enabled']) { continue }
      if (([string]$row['alias']).Trim() -ieq $DefaultAccount) { $found = $true; break }
    }
    if (-not $found) { [void]$errors.Add((Get-QQUiLabel 'defaultInvalid')) }
  }
  return @($errors)
}

# ---------------------------------------------------------------------------
# small UI helpers
# ---------------------------------------------------------------------------

function Sync-QQUiPaint {
  <#
  .SYNOPSIS
    Flushes the render queue so a status line is visible before a blocking call.
  .DESCRIPTION
    The doctor button blocks the dispatcher thread for seconds; without this the
    "running" status would only appear after the run it describes.
  #>
  try {
    $script:Window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [System.Action]{ })
  } catch { }
}

function Show-QQUiMessage {
  <#
  .SYNOPSIS
    Shows a modal message box owned by the configuration window.
  .PARAMETER Text
    Message body.
  .PARAMETER Title
    Window title.
  .PARAMETER Kind
    'info', 'error' or 'question'.
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
    [AllowEmptyString()][string]$Title = '',
    [string]$Kind = 'info'
  )
  $image = [System.Windows.MessageBoxImage]::Information
  if ($Kind -eq 'error') { $image = [System.Windows.MessageBoxImage]::Error }
  elseif ($Kind -eq 'question') { $image = [System.Windows.MessageBoxImage]::Question }
  $button = [System.Windows.MessageBoxButton]::OK
  # The button labels come from the OS (localized), which is why no CJK label for
  # "OK" is built here.
  if ($null -ne $script:Window) {
    [void][System.Windows.MessageBox]::Show($script:Window, $Text, $Title, $button, $image)
  } else {
    [void][System.Windows.MessageBox]::Show($Text, $Title, $button, $image)
  }
}

function Confirm-QQUiAction {
  <#
  .SYNOPSIS
    Asks a Yes/No question and reports the answer.
  .PARAMETER Text
    Question body.
  .PARAMETER Title
    Window title.
  .OUTPUTS
    [bool] true when the operator chose Yes.
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
    [AllowEmptyString()][string]$Title = ''
  )
  $answer = [System.Windows.MessageBox]::Show($script:Window, $Text, $Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
  return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
}

function Update-QQUiStatus {
  <#
  .SYNOPSIS
    Renders the status bar: config path, unsaved marker, last action, doctor.
  #>
  $parts = New-Object System.Collections.ArrayList
  [void]$parts.Add($script:ConfigPath)
  [void]$parts.Add($(if ($script:Dirty) { Get-QQUiLabel 'unsaved' } else { Get-QQUiLabel 'clean' }))
  if (-not [string]::IsNullOrEmpty($script:Message)) { [void]$parts.Add($script:Message) }
  if (-not [string]::IsNullOrEmpty($script:DoctorText)) {
    [void]$parts.Add(((Get-QQUiLabel 'doctorDone') + ': ' + $script:DoctorText))
  }
  $script:Ui['StatusText'].Text = ($parts -join '   |   ')
  $script:Window.Title = $(if ($script:Dirty) { '*' } else { '' }) + 'QQ ' + (New-QQUiString -Codes @(0x8D26, 0x53F7, 0x914D, 0x7F6E)) + ' - qq-uia'
}

function Set-QQUiMessage {
  <#
  .SYNOPSIS
    Sets the transient status message and re-renders the status bar.
  .PARAMETER Text
    Message, or '' to clear it.
  #>
  param([AllowEmptyString()][string]$Text = '')
  $script:Message = [string]$Text
  Update-QQUiStatus
}

function Set-QQUiDirty {
  <#
  .SYNOPSIS
    Marks the form as edited and re-renders the status bar.
  .DESCRIPTION
    A new edit also clears the "close was already asked for once" flag, so the
    warning on close has to be seen again for the edit that follows it.
  #>
  $script:CloseRequested = $false
  if ($script:Dirty) { return }
  $script:Dirty = $true
  Update-QQUiStatus
}

function Update-QQUiDefaultColumn {
  <#
  .SYNOPSIS
    Recomputes the default-account marker column from $script:DefaultAccount.
  .DESCRIPTION
    The marker is derived, never edited: the operator sets the default with the
    button, and the column only shows which row that is. Keeping it derived is
    what makes an alias edit and the marker impossible to disagree.
  #>
  if ($null -eq $script:AccountsTable) { return }
  foreach ($row in $script:AccountsTable.Rows) {
    $alias = ([string]$row['alias']).Trim()
    $isDefault = (-not [string]::IsNullOrEmpty($script:DefaultAccount) -and $alias -ieq $script:DefaultAccount)
    $row['isDefault'] = $(if ($isDefault) { '*' } else { '' })
  }
}

function Get-QQUiSelectedAccountRow {
  <#
  .SYNOPSIS
    Returns the DataRow behind the grid's current selection, or $null.
  .OUTPUTS
    [System.Data.DataRow] or $null.
  #>
  $item = $script:Ui['AccountsGrid'].SelectedItem
  if ($null -eq $item) { return $null }
  if ($item -is [System.Data.DataRowView]) { return $item.Row }
  return $null
}

function Get-QQUiSelectedInstanceNick {
  <#
  .SYNOPSIS
    Returns the nickname of the selected live instance, or ''.
  .OUTPUTS
    [string].
  #>
  $item = $script:Ui['InstancesGrid'].SelectedItem
  if ($null -eq $item) { return '' }
  if ($item -is [System.Data.DataRowView]) { return ([string]$item.Row['nick']) }
  return ''
}

function Update-QQUiInstanceGrid {
  <#
  .SYNOPSIS
    Re-reads the live instances and rebinds the instance grid.
  #>
  $config = $null
  try { $config = Get-QQConfig -Root $script:Root } catch { $config = $null }
  $rows = @(Get-QQUiLiveInstanceRows -Config $config)
  $table = New-QQUiInstancesTable
  foreach ($row in $rows) {
    $alias = Get-QQUiBoundAlias -Nick ([string]$row['nick'])
    [void]$table.Rows.Add(@(
      [string]$row['pid'], [string]$row['nick'], [string]$row['signature'],
      [string]$row['nodeCount'], [string]$row['width'], [string]$row['height'], [string]$row['scale'], [string]$alias,
      [bool]$row['online'], [bool]$row['a11yActive']
    ))
  }
  $script:Ui['InstancesGrid'].ItemsSource = $table.DefaultView
  Write-QQLog -Text ("config-ui: {0} visible QQ instance(s)" -f @($rows).Count)
}

function Get-QQUiBoundAlias {
  <#
  .SYNOPSIS
    Binds a live nickname to the alias of the account row that describes it.
  .DESCRIPTION
    Nickname first (exact, the same comparison the send guard uses), then alias
    (case-insensitive). Disabled rows are skipped: they are excluded from
    -Account resolution, so showing them as the binding would promise something
    the framework will refuse to do.
  .PARAMETER Nick
    Live nickname read from an instance.
  .OUTPUTS
    [string] alias, or '' when no enabled row describes the instance.
  #>
  param([AllowEmptyString()][string]$Nick = '')
  if ($null -eq $script:AccountsTable -or [string]::IsNullOrEmpty($Nick)) { return '' }
  foreach ($row in $script:AccountsTable.Rows) {
    if (-not [bool]$row['enabled']) { continue }
    $rowNick = [string]$row['nick']
    if (-not [string]::IsNullOrEmpty($rowNick) -and $rowNick -ceq $Nick) { return ([string]$row['alias']).Trim() }
  }
  foreach ($row in $script:AccountsTable.Rows) {
    if (-not [bool]$row['enabled']) { continue }
    $rowAlias = ([string]$row['alias']).Trim()
    if (-not [string]::IsNullOrEmpty($rowAlias) -and $rowAlias -ieq $Nick) { return $rowAlias }
  }
  return ''
}

function Update-QQUiAccountGrid {
  <#
  .SYNOPSIS
    Rebinds the account grid to the current table.
  #>
  $script:Ui['AccountsGrid'].ItemsSource = $script:AccountsTable.DefaultView
}

function Commit-QQUiGridEdits {
  <#
  .SYNOPSIS
    Commits a cell or row still being edited, so the buttons read what is on screen.
  .DESCRIPTION
    DataGrid commits on focus loss, which a click on a button does - but the save
    path is also reachable from the window's Closing handler, where no click
    happened. Committing explicitly keeps the two paths identical.
  #>
  $grid = $script:Ui['AccountsGrid']
  try { [void]$grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Cell, $true) } catch { }
  try { [void]$grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true) } catch { }
}

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------

function Invoke-QQUiDoctorCommand {
  <#
  .SYNOPSIS
    Runs `qq-uia.ps1 doctor` in a child process and summarizes the envelope.
  .DESCRIPTION
    A child process rather than an in-process call: doctor walks the whole UIA tree
    and probes every selector, and its own try/catch, console encoding and exit
    code are already the tested path. Sharing this process with it would also mean
    sharing its failures.
  .OUTPUTS
    [string] one-line summary for the status bar.
  #>
  $outFile = [System.IO.Path]::GetTempFileName()
  $errFile = [System.IO.Path]::GetTempFileName()
  try {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" doctor' -f $script:Dispatcher
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $stdout = ''
    try { $stdout = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8) } catch { $stdout = '' }
    $report = $null
    try { $report = ($stdout.Trim() | ConvertFrom-Json -ErrorAction Stop) } catch { $report = $null }
    if ($null -eq $report -or $null -eq $report.data) {
      return ('exit={0} (no json envelope on stdout)' -f $process.ExitCode)
    }
    $data = $report.data
    $drift = @($data.selectorDrift).Count
    return ('ready={0} instances={1} a11y={2} nodes={3} drift={4} exit={5}' -f `
      [string]$data.ready, [string]$data.instanceCount, [string]$data.a11yActive, [string]$data.nodeCount, [string]$drift, [string]$process.ExitCode)
  } catch {
    return ('failed: {0}' -f $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-QQUiRefresh {
  <#
  .SYNOPSIS
    Refreshes the live instance list.
  #>
  Set-QQUiMessage -Text ''
  Update-QQUiInstanceGrid
  Update-QQUiDefaultColumn
  Set-QQUiMessage -Text (Get-QQUiLabel 'refreshed')
}

function Invoke-QQUiDoctorClick {
  <#
  .SYNOPSIS
    Runs the doctor self-check and shows the summary in the status bar.
  #>
  Set-QQUiMessage -Text (Get-QQUiLabel 'doctorRunning')
  Sync-QQUiPaint
  $script:Ui['BtnDoctor'].IsEnabled = $false
  try {
    $script:DoctorText = Invoke-QQUiDoctorCommand
  } finally {
    $script:Ui['BtnDoctor'].IsEnabled = $true
  }
  Set-QQUiMessage -Text ''
}

function Invoke-QQUiAddAccount {
  <#
  .SYNOPSIS
    Appends an empty account row.
  #>
  [void]$script:AccountsTable.Rows.Add(@('', '', '', '', $true, ''))
  $grid = $script:Ui['AccountsGrid']
  $grid.SelectedIndex = $script:AccountsTable.Rows.Count - 1
  $grid.ScrollIntoView($grid.SelectedItem)
  Set-QQUiDirty
  Set-QQUiMessage -Text (Get-QQUiLabel 'addedAccount')
}

function Invoke-QQUiRemoveAccount {
  <#
  .SYNOPSIS
    Removes the selected account row after confirmation.
  #>
  $row = Get-QQUiSelectedAccountRow
  if ($null -eq $row) {
    Show-QQUiMessage -Title (Get-QQUiLabel 'confirmDeleteTitle') -Text (Get-QQUiLabel 'needAccountRow') -Kind 'info'
    return
  }
  if (-not (Confirm-QQUiAction -Title (Get-QQUiLabel 'confirmDeleteTitle') -Text (Get-QQUiLabel 'confirmDeleteText'))) { return }
  if (([string]$row['alias']).Trim() -ieq $script:DefaultAccount) {
    # The default is a reference to an alias this row is about to lose; clearing it
    # here keeps the document consistent instead of failing validation on save.
    $script:DefaultAccount = ''
  }
  $script:AccountsTable.Rows.Remove($row)
  Update-QQUiDefaultColumn
  Set-QQUiDirty
  Set-QQUiMessage -Text (Get-QQUiLabel 'removedAccount')
}

function Invoke-QQUiSetDefault {
  <#
  .SYNOPSIS
    Marks the selected account as config.json defaultAccount.
  #>
  $row = Get-QQUiSelectedAccountRow
  if ($null -eq $row) {
    Show-QQUiMessage -Title (Get-QQUiLabel 'defaultSet') -Text (Get-QQUiLabel 'needAccountRow') -Kind 'info'
    return
  }
  $script:DefaultAccount = ([string]$row['alias']).Trim()
  Update-QQUiDefaultColumn
  Set-QQUiDirty
  Set-QQUiMessage -Text (Get-QQUiLabel 'defaultSet')
}

function Invoke-QQUiMoveAccount {
  <#
  .SYNOPSIS
    Moves the selected account row one position up or down.
  .DESCRIPTION
    The row order in the table is the order written to accounts[]. Two adjacent
    rows exchange their values rather than a row being deleted and re-inserted:
    the row objects stay put, so the grid's selection follows the row that moved
    instead of jumping to the one that took its index.
  .PARAMETER Delta
    -1 for up, +1 for down.
  #>
  param([Parameter(Mandatory)][int]$Delta)
  $row = Get-QQUiSelectedAccountRow
  if ($null -eq $row) {
    Set-QQUiMessage -Text (Get-QQUiLabel 'needAccountRow')
    return
  }
  $index = $script:AccountsTable.Rows.IndexOf($row)
  $target = $index + $Delta
  if ($target -lt 0 -or $target -ge $script:AccountsTable.Rows.Count) { return }
  $other = $script:AccountsTable.Rows[$target]
  foreach ($column in @('alias', 'nick', 'qqId', 'enabled', 'note')) {
    $swap = $other[$column]
    $other[$column] = $row[$column]
    $row[$column] = $swap
  }
  Set-QQUiDirty
}

function Invoke-QQUiBindFromInstance {
  <#
  .SYNOPSIS
    Copies the selected instance's nickname into an account row.
  .DESCRIPTION
    Writes into the selected account row, or appends a new one when nothing is
    selected: the common case is "I see an instance that no account describes", and
    forcing a manual "add a row first" step there is exactly the friction this
    window exists to remove.
  #>
  $nick = Get-QQUiSelectedInstanceNick
  if ([string]::IsNullOrEmpty($nick)) {
    Set-QQUiMessage -Text (Get-QQUiLabel 'needInstanceRow')
    return
  }
  $row = Get-QQUiSelectedAccountRow
  if ($null -eq $row) {
    [void]$script:AccountsTable.Rows.Add(@('', $nick, $nick, '', $true, ''))
    $grid = $script:Ui['AccountsGrid']
    $grid.SelectedIndex = $script:AccountsTable.Rows.Count - 1
  } else {
    $row['nick'] = $nick
    if ([string]::IsNullOrEmpty(([string]$row['alias']).Trim())) { $row['alias'] = $nick }
  }
  Set-QQUiDirty
  Set-QQUiMessage -Text (Get-QQUiLabel 'boundFromInstance')
}

function Invoke-QQUiCopyLaunch {
  <#
  .SYNOPSIS
    Copies the accessibility launch command to the clipboard. It is NEVER run.
  #>
  $qqPath = ([string]$script:Ui['QQPathBox'].Text).Trim()
  if ([string]::IsNullOrEmpty($qqPath)) { $qqPath = $script:DefaultQQPath }
  $command = ('& ''{0}'' --force-renderer-accessibility' -f $qqPath)
  try {
    Set-Clipboard -Value $command
    Set-QQUiMessage -Text (Get-QQUiLabel 'clipboardOk')
  } catch {
    Set-QQUiMessage -Text ((Get-QQUiLabel 'clipboardFailed') + ': ' + $_.Exception.Message)
  }
}

function Invoke-QQUiOpenEvidence {
  <#
  .SYNOPSIS
    Opens the evidence directory in Explorer.
  #>
  $dir = Join-Path $script:Root 'evidence'
  try {
    $config = Get-QQConfig -Root $script:Root
    $configured = [string]$config['EvidenceDir']
    if (-not [string]::IsNullOrEmpty($configured)) { $dir = $configured }
  } catch { }
  try {
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [void](Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $dir))
    Set-QQUiMessage -Text (Get-QQUiLabel 'evidenceOpened')
  } catch {
    Set-QQUiMessage -Text ((Get-QQUiLabel 'evidenceFailed') + ': ' + $_.Exception.Message)
  }
}

function Invoke-QQUiSave {
  <#
  .SYNOPSIS
    Validates the form and writes config.json.
  .DESCRIPTION
    Nothing is written when validation fails: the errors are listed in a dialog and
    the file on disk stays as it was. On success the previous file is copied to
    config.json.bak by Save-QQUiConfigFile.
  .OUTPUTS
    [bool] true when config.json was written.
  #>
  if ($null -eq $script:Document) {
    Show-QQUiMessage -Title (Get-QQUiLabel 'saveFailed') -Text (Get-QQUiLabel 'configLoadFailed') -Kind 'error'
    return $false
  }
  Commit-QQUiGridEdits
  $settings = Read-QQUiSettings
  $errors = @($settings.Errors)
  $errors += @(Test-QQUiAccountTable -Table $script:AccountsTable -DefaultAccount $script:DefaultAccount)
  if (@($errors).Count -gt 0) {
    Show-QQUiMessage -Title (Get-QQUiLabel 'validationFailed') -Text (@($errors) -join "`r`n") -Kind 'error'
    return $false
  }

  try {
    $values = $settings.Values
    $document = $script:Document
    Set-QQUiConfigValue -Document $document -Path @('dpi', 'mode') -Value ([string]$values['dpi.mode'])
    Set-QQUiConfigValue -Document $document -Path @('dpi', 'scale') -Value ([double]$values['DpiScale'])
    Set-QQUiConfigValue -Document $document -Path @('timeouts', 'defaultSec') -Value ([int]$values['timeouts.defaultSec'])
    Set-QQUiConfigValue -Document $document -Path @('a11y', 'minNodes') -Value ([int]$values['a11y.minNodes'])
    Set-QQUiConfigValue -Document $document -Path @('instances', 'minWindowWidth') -Value ([int]$values['instances.minWindowWidth'])
    Set-QQUiConfigValue -Document $document -Path @('guards', 'minSendIntervalMs') -Value ([int]$values['guards.minSendIntervalMs'])
    Set-QQUiConfigValue -Document $document -Path @('guards', 'requireAccountMatch') -Value ([bool]$values['guards.requireAccountMatch'])
    Set-QQUiConfigValue -Document $document -Path @('evidence', 'writeAudit') -Value ([bool]$values['evidence.writeAudit'])
    Set-QQUiConfigValue -Document $document -Path @('qqPath') -Value ([string]$values['qqPath'])

    $accounts = New-Object System.Collections.ArrayList
    foreach ($row in $script:AccountsTable.Rows) {
      [void]$accounts.Add([ordered]@{
        alias   = ([string]$row['alias']).Trim()
        nick    = ([string]$row['nick']).Trim()
        qqId    = ([string]$row['qqId']).Trim()
        enabled = [bool]$row['enabled']
        note    = [string]$row['note']
      })
    }
    Set-QQUiConfigValue -Document $document -Path @('accounts') -Value @($accounts)
    Set-QQUiConfigValue -Document $document -Path @('defaultAccount') -Value ([string]$script:DefaultAccount)

    [void](Save-QQUiConfigFile -Path $script:ConfigPath -Document $document)
  } catch {
    Show-QQUiMessage -Title (Get-QQUiLabel 'saveFailed') -Text $_.Exception.Message -Kind 'error'
    return $false
  }

  $script:Dirty = $false
  Update-QQUiDefaultColumn
  Set-QQUiMessage -Text (Get-QQUiLabel 'savedOk')
  return $true
}

function Invoke-QQUiReload {
  <#
  .SYNOPSIS
    Re-reads config.json, discarding unsaved edits.
  #>
  if ($script:Dirty -and -not (Confirm-QQUiAction -Title (Get-QQUiLabel 'confirmReloadTitle') -Text (Get-QQUiLabel 'confirmReloadText'))) { return }
  Update-QQUiFromConfig -Message (Get-QQUiLabel 'reloaded')
}

# ---------------------------------------------------------------------------
# loading the form
# ---------------------------------------------------------------------------

function Update-QQUiFromConfig {
  <#
  .SYNOPSIS
    Loads config.json into every widget.
  .DESCRIPTION
    A config.json that cannot be read leaves the window usable for inspection but
    disables Save: the alternative (writing a default document) would silently
    replace whatever the unreadable file actually held.
  .PARAMETER Message
    Status message to show when the load succeeded.
  #>
  param([AllowEmptyString()][string]$Message = '')

  $script:Loading = $true
  try {
    $document = $null
    $loadError = ''
    try { $document = Get-QQUiConfigDocument } catch { $loadError = $_.Exception.Message }
    $script:Document = $document

    $script:AccountsTable = New-QQUiAccountsTable -Document $document
    Update-QQUiAccountGrid

    $script:DefaultAccount = ''
    if ($null -ne $document) {
      $script:DefaultAccount = ([string](Get-QQUiConfigValue -Document $document -Path @('defaultAccount') -Default '')).Trim()
    }
    Update-QQUiDefaultColumn

    $mode = 'auto'
    $scale = 1.5
    $defaultSec = 30
    $minNodes = 100
    $minWidth = 400
    $minSendIntervalMs = 60000
    $requireAccountMatch = $false
    $writeAudit = $true
    $qqPath = $script:DefaultQQPath
    if ($null -ne $document) {
      $mode = [string](Get-QQUiConfigValue -Document $document -Path @('dpi', 'mode') -Default $mode)
      $scale = [double](Get-QQUiConfigValue -Document $document -Path @('dpi', 'scale') -Default $scale)
      $defaultSec = [int](Get-QQUiConfigValue -Document $document -Path @('timeouts', 'defaultSec') -Default $defaultSec)
      $minNodes = [int](Get-QQUiConfigValue -Document $document -Path @('a11y', 'minNodes') -Default $minNodes)
      $minWidth = [int](Get-QQUiConfigValue -Document $document -Path @('instances', 'minWindowWidth') -Default $minWidth)
      $minSendIntervalMs = [int](Get-QQUiConfigValue -Document $document -Path @('guards', 'minSendIntervalMs') -Default $minSendIntervalMs)
      $requireAccountMatch = [bool](Get-QQUiConfigValue -Document $document -Path @('guards', 'requireAccountMatch') -Default $false)
      $writeAudit = [bool](Get-QQUiConfigValue -Document $document -Path @('evidence', 'writeAudit') -Default $true)
      $qqPath = [string](Get-QQUiConfigValue -Document $document -Path @('qqPath') -Default $script:DefaultQQPath)
    }

    $combo = $script:Ui['DpiModeCombo']
    $combo.SelectedIndex = 0
    $index = 0
    foreach ($item in @($combo.Items)) {
      $content = ''
      try { $content = [string]$item.Content } catch { $content = '' }
      if ($content -ieq $mode) { $combo.SelectedIndex = $index }
      $index++
    }
    $script:Ui['DpiScaleBox'].Text = ([double]$scale).ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
    $script:Ui['DefaultSecBox'].Text = [string][int]$defaultSec
    $script:Ui['MinNodesBox'].Text = [string][int]$minNodes
    $script:Ui['MinWidthBox'].Text = [string][int]$minWidth
    $script:Ui['MinSendIntervalBox'].Text = [string][int]$minSendIntervalMs
    $script:Ui['RequireAccountMatchCheck'].IsChecked = [bool]$requireAccountMatch
    $script:Ui['WriteAuditCheck'].IsChecked = [bool]$writeAudit
    $script:Ui['QQPathBox'].Text = [string]$qqPath

    $script:Ui['BtnSave'].IsEnabled = ($null -ne $document)
    $script:DoctorText = ''
  } finally {
    $script:Loading = $false
  }

  Update-QQUiInstanceGrid
  $script:Dirty = $false
  if (-not [string]::IsNullOrEmpty($loadError)) {
    Set-QQUiMessage -Text ((Get-QQUiLabel 'configLoadFailed') + ': ' + $loadError)
    Show-QQUiMessage -Title (Get-QQUiLabel 'saveFailed') -Text ((Get-QQUiLabel 'configLoadFailed') + "`r`n" + $loadError) -Kind 'error'
    return
  }
  Set-QQUiMessage -Text $Message
}

# ---------------------------------------------------------------------------
# window start-up
# ---------------------------------------------------------------------------

function Start-QQUiWindow {
  <#
  .SYNOPSIS
    Loads the XAML, wires the handlers and shows the configuration window.
  .DESCRIPTION
    A WPF window needs an STA thread. When this script is started on an MTA thread
    it re-runs ITSELF under -STA and returns immediately; the process started is
    powershell.exe, never QQ, and nothing else in this framework starts processes
    of its own at all.
  .OUTPUTS
    [bool] true when a window was shown.
  #>
  $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
  if ($apartment -ne [System.Threading.ApartmentState]::STA) {
    Write-QQLog -Text ("config-ui: not an STA thread ({0}); relaunching under -STA" -f $apartment)
    $arguments = '-STA -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script:SelfPath
    [void](Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments)
    return $false
  }

  foreach ($assembly in @('PresentationFramework', 'PresentationCore', 'WindowsBase')) {
    try { [void](Add-Type -AssemblyName $assembly -ErrorAction Stop) } catch { }
  }

  if (-not (Test-Path -LiteralPath $script:XamlPath)) {
    throw (New-QQErrorRecord -Code 'NOT_FOUND' -Message ("{0}: {1}" -f (Get-QQUiLabel 'xamlMissing'), $script:XamlPath) -Details @{ path = $script:XamlPath })
  }
  $xaml = [System.IO.File]::ReadAllText($script:XamlPath, [System.Text.Encoding]::UTF8)
  $window = $null
  try {
    $xml = New-Object System.Xml.XmlDocument
    $xml.LoadXml($xaml)
    $reader = New-Object System.Xml.XmlNodeReader $xml
    $window = [Windows.Markup.XamlReader]::Load($reader)
  } catch {
    throw (New-QQErrorRecord -Code 'ERROR' -Message ("ui/config-ui.xaml could not be loaded: {0}" -f $_.Exception.Message) -Details @{ path = $script:XamlPath })
  }
  $script:Window = $window

  $missing = New-Object System.Collections.ArrayList
  foreach ($name in $script:UiControlNames) {
    $control = $window.FindName($name)
    if ($null -eq $control) { [void]$missing.Add($name) }
    $script:Ui[$name] = $control
  }
  if ($missing.Count -gt 0) {
    throw (New-QQErrorRecord -Code 'ERROR' -Message ("ui/config-ui.xaml is missing control(s): {0}" -f (@($missing) -join ', ')) -Details @{ missing = @($missing) })
  }

  # The live read happens after the widgets exist, because the binding column of
  # the instance grid is derived from the account table loaded above.
  Update-QQUiFromConfig

  $script:Ui['BtnRefresh'].Add_Click({ Invoke-QQUiRefresh })
  $script:Ui['BtnDoctor'].Add_Click({ Invoke-QQUiDoctorClick })
  $script:Ui['BtnAddAccount'].Add_Click({ Invoke-QQUiAddAccount })
  $script:Ui['BtnRemoveAccount'].Add_Click({ Invoke-QQUiRemoveAccount })
  $script:Ui['BtnSetDefault'].Add_Click({ Invoke-QQUiSetDefault })
  $script:Ui['BtnUp'].Add_Click({ Invoke-QQUiMoveAccount -Delta -1 })
  $script:Ui['BtnDown'].Add_Click({ Invoke-QQUiMoveAccount -Delta 1 })
  $script:Ui['BtnBindFromInstance'].Add_Click({ Invoke-QQUiBindFromInstance })
  $script:Ui['BtnSave'].Add_Click({ [void](Invoke-QQUiSave) })
  $script:Ui['BtnReload'].Add_Click({ Invoke-QQUiReload })
  $script:Ui['BtnOpenEvidence'].Add_Click({ Invoke-QQUiOpenEvidence })
  $script:Ui['BtnCopyLaunch'].Add_Click({ Invoke-QQUiCopyLaunch })

  # Any edit from here on is an unsaved change. The guard on $script:Loading is
  # what keeps the programmatic population in Update-QQUiFromConfig from marking
  # the freshly loaded form as dirty.
  $script:Ui['DpiModeCombo'].Add_SelectionChanged({ if (-not $script:Loading) { Set-QQUiDirty } })
  foreach ($name in @('DpiScaleBox', 'DefaultSecBox', 'MinNodesBox', 'MinWidthBox', 'MinSendIntervalBox', 'QQPathBox')) {
    $script:Ui[$name].Add_TextChanged({ if (-not $script:Loading) { Set-QQUiDirty } })
  }
  foreach ($name in @('RequireAccountMatchCheck', 'WriteAuditCheck')) {
    $script:Ui[$name].Add_Click({ if (-not $script:Loading) { Set-QQUiDirty } })
  }
  $script:Ui['AccountsGrid'].Add_CellEditEnding({ if (-not $script:Loading) { Set-QQUiDirty } })
  # CurrentCellChanged fires after the edit is committed, which is when the
  # derived default marker can be recomputed from the new alias.
  $script:Ui['AccountsGrid'].Add_CurrentCellChanged({
    if ($script:Loading) { return }
    Update-QQUiDefaultColumn
    Update-QQUiStatus
  })

  # Closing with unsaved edits takes two attempts, and the first one is answered in
  # the status bar rather than by a modal dialog. A question asked from inside the
  # Closing pass is the one dialog this host does not deliver reliably (a
  # MessageBox opened there was dismissed with its default button and left the
  # window refusing to close), and a window that cannot be closed is a worse
  # failure than an edit the status bar already marks as unsaved.
  $window.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:Dirty) { return }
    if ($script:CloseRequested) { return }
    $script:CloseRequested = $true
    $eventArgs.Cancel = $true
    Set-QQUiMessage -Text (Get-QQUiLabel 'unsavedCloseWarning')
  })

  Update-QQUiStatus
  Write-QQLog -Text ("config-ui: window shown, config {0}" -f $script:ConfigPath)
  [void]$window.ShowDialog()
  return $true
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

if (-not $NoWindow) {
  try {
    [void](Start-QQUiWindow)
  } catch {
    Write-QQLog -Text ("config-ui: {0}" -f $_.Exception.Message)
    exit 1
  }
}
