# =============================================================================
# commands/config-ui.ps1 - L0: open the graphical configuration window.
# Authority: G:\work\FRAMEWORK-DESIGN.md (configuration); README.md section 8.
#
# This is the ONLY command in the framework that starts a process, and the process
# it starts is the framework's own UI script, hosted by powershell.exe -STA. It
# never starts, restarts or stops the QQ application: the framework attaches to a
# running instance and reads it, nothing more, and qq-behavior.tests.ps1 asserts
# that no source file can launch or kill the QQ process.
#
# The window itself is a separate process on purpose. A GUI must own its message
# loop, and this command must return immediately with an envelope, which it could
# not do if the window ran in the dispatcher's process.
#
# Contract with the dispatcher: defines functions only (no param block), defines
# Invoke-QQCommand -Context <hashtable>, returns @{ Data = <payload>; Pid = <int|null> },
# writes nothing to stdout.
#
# ASCII-ONLY SOURCE. run-tests.ps1 enforces this rule.
# =============================================================================

function Invoke-QQCommand {
  <#
  .SYNOPSIS
    L0 config-ui: launches the account configuration window as a detached process.
  .DESCRIPTION
    The launched script enforces the same rules as every other file here (no QQ
    process control, no focus, no click, no typing, no message), and it is the only
    thing that writes config.json - after validating the form and backing the old
    file up to config.json.bak.

    The command resolves the peer script by path and refuses to launch when it is
    missing, so a partial copy of the framework reports a usable error instead of
    a window that never appears.
  .PARAMETER Context
    Dispatcher context hashtable.
  .OUTPUTS
    Hashtable with Data (launched, path) and Pid = null: no QQ instance is acted
    on, so no pid is claimed.
  #>
  param($Context)

  $scriptPath = Join-Path $Context.Root 'qq-config-ui.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw (New-QQErrorRecord -Code 'NOT_FOUND' -Message ("the configuration UI script is missing: {0}" -f $scriptPath) -Details @{ path = $scriptPath; fix = 'restore qq-config-ui.ps1 and ui/config-ui.xaml from the framework copy' })
  }

  # -STA: WPF requires a single-threaded apartment. The UI re-launches itself with
  # the same switches when it is started on an MTA thread, so this is belt and
  # braces rather than the only guard.
  $arguments = '-STA -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
  [void](Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments)
  Write-QQLog -Text ("config-ui: launched {0} under powershell.exe -STA; the window is a separate process" -f $scriptPath)

  return @{
    Data = [ordered]@{
      launched = $true
      path     = [string]$scriptPath
    }
    Pid = $null
  }
}
