Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class MsaaBoot {
  [DllImport("oleacc.dll")]
  public static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint dwId, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppvObject);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);

  public static object GetAccessible(IntPtr hwnd, uint objId) {
    Guid iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71"); // IID_IAccessible
    object o = null;
    int hr = AccessibleObjectFromWindow(hwnd, objId, ref iid, out o);
    if (hr != 0) throw new COMException("AccessibleObjectFromWindow HRESULT=0x" + hr.ToString("X8"), hr);
    return o;
  }
}
'@
if (-not ('MsaaBoot' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp }

$OBJID_CLIENT = [uint32]::MaxValue - 3   # 0xFFFFFFFC = OBJID_CLIENT (PowerShell 5.1 parses 0xFFFFFFFC as -4)

function Show-Msaa {
  param([IntPtr]$Hwnd, [string]$Label, [int]$MaxDepth = 3)
  Write-Host "`n=========== MSAA probe: $Label (hwnd $Hwnd) ===========" -ForegroundColor Cyan
  try {
    $acc = [MsaaBoot]::GetAccessible($Hwnd, $OBJID_CLIENT)
    Write-Host ("AccessibleObjectFromWindow OK -> COM type: {0}" -f $acc.GetType().FullName)
    $name = $acc.accName(0); $role = $acc.accRole(0); $childCount = $acc.accChildCount
    Write-Host ("  accName(0) = '{0}'   accRole(0) = '{1}'   accChildCount = {2}" -f $name, $role, $childCount)
    if ($childCount -gt 0) {
      for ($i = 1; $i -le [Math]::Min($childCount, 40); $i++) {
        try {
          $cn = $acc.accName($i); $cr = $acc.accRole($i)
          $cs = $acc.accState($i)
          Write-Host ("    child[{0}] role={1} name='{2}' state={3}" -f $i, $cr, $cn, $cs)
        } catch { Write-Host ("    child[{0}] <error: {1}>" -f $i, $_.Exception.Message) }
      }
    } else {
      Write-Host "  (no MSAA children exposed by the renderer)" -ForegroundColor Yellow
    }
  } catch {
    Write-Host ("  AccessibleObjectFromWindow FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
  }
}

# 1) QQ main visible window
Show-Msaa -Hwnd ([IntPtr]18681668) -Label 'QQ main window (pid 11004, 680x440)'
# 2) The shell window that DID expose a Document earlier
Show-Msaa -Hwnd ([IntPtr]1774836) -Label 'QQ hidden window (pid 72440, 800x600)'
# 3) Control: Edge (known-working Chromium with a11y active)
$edge = (Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1)
if ($edge) { Show-Msaa -Hwnd $edge.MainWindowHandle -Label "CONTROL Edge (pid $($edge.Id))" }

Write-Host "`n=== Registry: AT / accessibility activation state ===" -ForegroundColor Cyan
foreach ($k in @(
    'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Accessibility',
    'HKCU:\Control Panel\Accessibility',
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Accessibility')) {
  if (Test-Path $k) {
    Write-Host "  [$k]"
    Get-ItemProperty $k | Select-Object -Property * -ExcludeProperty PS* | Format-List | Out-String | ForEach-Object { $_.Trim() -split "`n" | ForEach-Object { "    $($_.Trim())" } }
  }
}
Write-Host "  Running screen readers / UIA clients:"
Get-Process | Where-Object { $_.ProcessName -match 'nvda|narrator|JAWS|inspect|acc|mag' } | Select-Object Id, ProcessName | Format-Table -AutoSize
