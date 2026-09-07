<#
detection_rule.ps1 - Intune Win32 app DETECTION RULE script for HW9TN A13
Self-contained; no external file references; no hardcoded paths.

Intune detection-rule semantics (different from Proactive Remediation!):
  detected    = exit 0 AND writes output
  not detected = nonzero exit / no output

"Detected" = this is a PB14250 AND every present camera-stack device runs
a driver at or above the A13 target version. Firmware check joins after
one live PB14250 confirms the registry layout (CurrentFWVersion etc.).
#>
$ErrorActionPreference = 'SilentlyContinue'

$sp = Get-CimInstance Win32_ComputerSystemProduct
$bb = Get-CimInstance Win32_BaseBoard
$cs = Get-CimInstance Win32_ComputerSystem
$sig = @($sp.Version, $sp.Name, $bb.Product, $cs.Model) -join ' '
if ($sig -notmatch 'PB14250') { exit 1 }   # not our hardware -> "not detected" (app NA here)

$targets = @(
    @{ re = 'VEN_8086&DEV_(7D51|7DD1|7D41|7D67|B640).*INT3480';         v = '64.26100.13.20730' }
    @{ re = 'VEN_8086&DEV_(64A0|6420|64B0).*INT3480';                   v = '70.26100.2.21770' }
    @{ re = 'VEN_8086&DEV_7D19';                                        v = '64.26100.13.20730' }
    @{ re = 'VEN_8086&DEV_(645D|5A19)';                                 v = '70.26100.2.21770' }
    @{ re = 'VEN_HIMX&DEV_1092';                                        v = '70.26100.2.21770' }
    @{ re = 'VEN_OVTI&DEV_05C1';                                        v = '70.26100.2.21770' }
    @{ re = 'VEN_OVTI&DEV_08F4';                                        v = '70.26100.2.21770' }
    @{ re = 'VEN_INT&DEV_(3472|346F)';                                  v = '70.26100.2.21770' }
    @{ re = 'VID_8086&PID_0B63|VID_2AC1&PID_20C[19B]|VID_06CB&PID_0701'; v = '4.0.1.586' }
    @{ re = 'INTC10B5';                                                 v = '1.0.2.739' }
    @{ re = 'INTC10B6';                                                 v = '1.0.2.418' }
    @{ re = 'INTC10E0';                                                 v = '41.3.10000.40' }
    @{ re = 'INTC10DE';                                                 v = '3.2.6.2087' }
)

foreach ($d in (Get-PnpDevice -PresentOnly)) {
    $hw = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds').Data
    if (-not $hw) { continue }
    $hw = $hw -join ';'
    foreach ($t in $targets) {
        if ($hw -match $t.re) {
            $cur = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion').Data
            if (-not $cur -or [version]$cur -lt [version]$t.v) { exit 1 }   # below target -> not detected
            break
        }
    }
}
Write-Output 'HW9TN-A13 camera stack at target'
exit 0
