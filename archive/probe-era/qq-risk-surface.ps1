# Non-invasive: look for QQ's own anti-automation / integrity UI in the live accessibility tree.
# ASCII-only source. Launches/stops nothing.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$cn = @{
  verify  = [string]([char]0x9A8C + [char]0x8BC1)
  safe    = [string]([char]0x5B89 + [char]0x5168)
  risk    = [string]([char]0x98CE + [char]0x9669)
  forbid  = [string]([char]0x5C01 + [char]0x7981)
  slider  = [string]([char]0x6ED1 + [char]0x5757)
  human   = [string]([char]0x4EBA + [char]0x673A)
  plugin  = [string]([char]0x63D2 + [char]0x4EF6)
  auto    = [string]([char]0x81EA + [char]0x52A8 + [char]0x5316)
}
$patList = @(
  ($cn.verify + '|' + $cn.safe + '|' + $cn.risk + '|' + $cn.forbid + '|' + $cn.slider + '|' + $cn.human),
  ($cn.plugin + '|' + $cn.auto),
  'debug|inspect|devtools|automat|webdriver|cdp|robot'
)
$patterns = $patList -join '|'

$targets = @(
  @{ Id = 11004; Tag = 'USER MAIN' },
  @{ Id = 86324; Tag = 'TEMP instance (cmdline carries --remote-debugging-port)' }
)

foreach ($t in $targets) {
  Write-Host "`n=========== $($t.Tag) (pid $($t.Id)) ===========" -ForegroundColor Cyan
  $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$t.Id)
  $wins = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
  foreach ($w in $wins) {
    $all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    Write-Host "  window '$($w.Current.Name)' nodes=$($all.Count)"

    $hits = @($all | Where-Object { $_.Current.Name -match $patterns -or $_.Current.ClassName -match $patterns })
    if ($hits.Count -gt 0) {
      Write-Host "  -- security/automation-labelled nodes --" -ForegroundColor Yellow
      $hits | Select-Object -First 15 | ForEach-Object {
        $ty = $_.Current.ControlType.ProgrammaticName.Replace('ControlType.', '')
        Write-Host ("     [{0}] cls={1} name='{2}'" -f $ty, $_.Current.ClassName, $_.Current.Name)
      }
    } else {
      Write-Host "  -- no security/automation-labelled UI present --" -ForegroundColor DarkGray
    }

    $native = @($all | Where-Object { $_.Current.ClassName -match 'native|ipc|node|electron|wrapper|bridge|major' })
    if ($native.Count -gt 0) {
      Write-Host ("  -- native/ipc-looking classes: " + (($native | Select-Object -First 8 | ForEach-Object { $_.Current.ClassName }) -join ' | '))
    } else {
      Write-Host "  -- no native/ipc-looking class names --" -ForegroundColor DarkGray
    }
  }
}
