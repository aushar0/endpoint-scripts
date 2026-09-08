<#
HW9TN_pr_detect.ps1 - Intune Remediations DETECTION script (exit 0/1 ONLY)

Remediations gate: remediation runs ONLY when detection exits exactly 1.
Map:
  exit 0 + "compliant"                 -> healthy, nothing to do
  exit 0 + "BROKEN-CURRENT" banner     -> camera problem with current drivers:
        dependency route (Dell KB 000248760): BIOS camera enable, chipset,
        graphics, ISH, Serial I/O, ME. NOT fixed by this driver package.
        Banner is visible in the detection-output column = fleet telemetry.
  exit 1                               -> below target OR misbound -> remediate
  non-target hardware                  -> exit 0 silent (no non-compliance noise)

Read-only, no waits, runs in seconds. Schedule: daily, e.g. 19:00 local.
#>
$ErrorActionPreference = 'SilentlyContinue'

# --- Layer 0: hardware gate ---
$sp = Get-CimInstance Win32_ComputerSystemProduct
$bb = Get-CimInstance Win32_BaseBoard
$cs = Get-CimInstance Win32_ComputerSystem
$sig = @($sp.Version, $sp.Name, $bb.Product, $cs.Model) -join ' '
if ($sig -notmatch 'P[AB]14250') { exit 0 }

# --- Family target tables (subsys-scoped; PA = 845M5 A12, PB = HW9TN A13) ---
$targets = @(
    @{ n = 'iacamera64-PA';     re = 'VEN_8086&DEV_64A0&SUBSYS_0CE[34]1028.*INT3480';              v = '70.26100.2.21086' }
    @{ n = 'iaisp64-PA';        re = 'VEN_8086&DEV_645D&SUBSYS_0CE[34]1028';                        v = '70.26100.2.21086' }
    @{ n = 'hm1092-PA';         re = 'VEN_HIMX&DEV_1092&SUBSYS_0CE[34]1028';                        v = '70.26100.2.21086' }
    @{ n = 'ov08x40-PA';        re = 'VEN_OVTI&DEV_08F4&SUBSYS_0CE[34]1028';                        v = '70.26100.2.21086' }
    @{ n = 'iactrllogic-PA';    re = 'VEN_INT&DEV_3472&SUBSYS_0CE[34]1028';                         v = '70.26100.2.21086' }
    @{ n = 'iacamera64-PB-ARL'; re = 'VEN_8086&DEV_(7D51|7DD1|7D41|7D67|B640)&SUBSYS_0C(E8|F7)1028.*INT3480'; v = '64.26100.13.20730' }
    @{ n = 'iacamera64-PB-LNL'; re = 'VEN_8086&DEV_(64A0|6420|64B0)&SUBSYS_0C(DC|F8)1028.*INT3480';           v = '70.26100.2.21770' }
    @{ n = 'iaisp64-PB-ARL';    re = 'VEN_8086&DEV_7D19&SUBSYS_0C(E8|F7)1028';                                 v = '64.26100.13.20730' }
    @{ n = 'iaisp64-PB-LNL';    re = 'VEN_8086&DEV_(645D|5A19)&SUBSYS_0C(DC|F8)1028';                          v = '70.26100.2.21770' }
    @{ n = 'hm1092-PB';         re = 'VEN_HIMX&DEV_1092&SUBSYS_0C(DC|F8|CE8|F7)1028';                         v = '70.26100.2.21770' }
    @{ n = 'ov05c10-PB';        re = 'VEN_OVTI&DEV_05C1&SUBSYS_0C(DC|F8|CE8|F7)1028';                         v = '70.26100.2.21770' }
    @{ n = 'ov08x40-PB';        re = 'VEN_OVTI&DEV_08F4&SUBSYS_0C(DC|F8|CE8|F7)1028';                         v = '70.26100.2.21770' }
    @{ n = 'iactrllogic-PB';    re = 'VEN_INT&DEV_(3472|346F)&SUBSYS_0C(DC|F8|CE8|F7)1028';                   v = '70.26100.2.21770' }
    @{ n = 'usbbridge';         re = 'VID_8086&PID_0B63|VID_2AC1&PID_20C[19B]|VID_06CB&PID_0701';  v = '4.0.1.586' }
    @{ n = 'UsbGpio';           re = 'INTC10B5';                                                     v = '1.0.2.739' }
    @{ n = 'usbi2c';            re = 'INTC10B6';                                                     v = '1.0.2.418' }
    @{ n = 'Vision-LNL';        re = 'INTC10DE';                                                     v = '3.2.6.2087' }
    @{ n = 'Vision-ARL';        re = 'INTC10E0';                                                     v = '41.3.10000.40' }
)

$needs = @(); $misbound = @(); $problem = @(); $disabled = @(); $found = 0
foreach ($d in (Get-PnpDevice -PresentOnly)) {
    $hw = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds').Data
    if (-not $hw) { continue }
    $hw = $hw -join ';'
    foreach ($t in $targets) {
        if ($hw -match $t.re) {
            $found++
            $cur = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion').Data
            if (-not $cur -or [version]$cur -lt [version]$t.v) { $needs += "$($t.n): $(if ($cur) { $cur } else { 'NONE' }) -> $($t.v)" }
            $pc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
            if ($pc -eq 22) { $disabled += "$($t.n) disabled (CM_PROB_DISABLED - user/policy choice; a driver update will not enable it)" }
            elseif ($pc -and $pc -ne 0) { $problem += "$($t.n) code $pc" }
            $prov = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverProvider').Data
            $infP = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath').Data
            if ($prov -match 'Microsoft' -or $infP -match 'usbvideo\.inf') { $misbound += "$($t.n) on inbox driver" }
            break
        }
    }
}
$camCount = @(Get-PnpDevice -Class Camera,Image -PresentOnly).Count
if ($camCount -eq 0 -and $disabled.Count -eq 0) { $problem += 'no camera devices present' }
foreach ($c in (Get-PnpDevice -Class Camera,Image -PresentOnly)) {
    $cpc = (Get-PnpDeviceProperty -InstanceId $c.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
    if ($cpc -eq 22) { $disabled += "$($c.FriendlyName) disabled" }
    elseif ($cpc -and $cpc -ne 0) { $problem += "$($c.FriendlyName) code $cpc" }
}
$fsErr = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-MF-FrameServer/Camera_FrameServer'; Level = 1,2,3; StartTime = (Get-Date).AddDays(-7) }).Count
if ($fsErr -ge 5) { $problem += "$fsErr FrameServer errors in 7d" }

# --- RCA context (read-only; feeds the detection-output column fleet-wide) ---
$os = Get-CimInstance Win32_OperatingSystem
$firstErr = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-MF-FrameServer/Camera_FrameServer'; Level = 1,2 } -Oldest -ErrorAction SilentlyContinue | Select-Object -First 1
$delta = if ($firstErr) { [int](($firstErr.TimeCreated - $os.InstallDate).TotalHours) } else { $null }
Write-Output ("HW9TN|ctx|bios={0}|build={1}|os_changed={2:yyyy-MM-dd}|winold={3}" -f `
    (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion, $os.BuildNumber, $os.InstallDate, (Test-Path 'C:\Windows.old'))
function Get-DepVer($Pattern) {
    $d = Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match $Pattern } | Select-Object -First 1
    if ($d) { $v = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion').Data; if ($v) { return $v } }
    return 'missing'
}
Write-Output ("HW9TN|dep|ish={0}|serialio={1}|me={2}" -f `
    (Get-DepVer 'Integrated Sensor Solution'), (Get-DepVer 'Serial IO'), (Get-DepVer 'Management Engine'))
Write-Output ("HW9TN|rca|first_err={0}|upgraded={1:yyyy-MM-dd HH:mm}|delta={2}" -f `
    $(if ($firstErr) { $firstErr.TimeCreated.ToString('yyyy-MM-ddTHH:mm') } else { 'none-in-retention' }),
    $os.InstallDate, $(if ($null -ne $delta) { "{0}h" -f $delta } else { 'n/a' }))

# --- firmware-payload proxy (registry layout confirmed on live hardware) ---
# CurrentFWVersion carries the Synaptics vision-extension INF version; >= 133.152.66.0
# <=> firmware family >= 8.5.98.42 (shipped in both current packages). Target/Update
# stay 0.0.0.0 by design - never a signal.
$fwExtTarget = '133.152.66.0'
$fwCurrent = $null
foreach ($root in 'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\INTC10E0',
                  'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\INTC10DE',
                  'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_06CB&PID_0701') {
    Get-ChildItem $root -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        if ($p.CurrentFWVersion) { $script:fwCurrent = $p.CurrentFWVersion }
    }
}
if ($fwCurrent -and ([version]$fwCurrent -lt [version]$fwExtTarget)) {
    $needs += "vision-firmware-extension: $fwCurrent -> $fwExtTarget"
    Write-Output "HW9TN|fw|proxy=$fwCurrent|target>=$fwExtTarget|state=OLD"
} elseif ($fwCurrent) {
    Write-Output "HW9TN|fw|proxy=$fwCurrent|target>=$fwExtTarget|state=CURRENT"
}

# --- exit map ---
if ($needs.Count -or $misbound.Count) {
    Write-Output "NEEDS-REMEDIATION: $($needs.Count + $misbound.Count) finding(s)"
    $needs + $misbound | ForEach-Object { Write-Output "  $_" }
    if ($problem) { Write-Output "also-broken-now: $($problem -join '; ')" }
    if ($disabled) { Write-Output "also-disabled (NOT a fault - user/policy choice): $($disabled -join '; ')" }
    exit 1
}
if ($problem.Count) {
    Write-Output 'BROKEN-CURRENT: drivers at target but camera problems present -'
    Write-Output 'dependency route (Dell KB 000248760): BIOS camera enable, chipset, graphics, ISH, Serial I/O, ME'
    $problem | ForEach-Object { Write-Output "  $_" }
    if ($disabled) { Write-Output "also-disabled (NOT a fault): $($disabled -join '; ')" }
    exit 0
}
if ($disabled.Count) {
    Write-Output "compliant ($found stack components at target); camera devices disabled by choice: $($disabled -join '; ')"
    exit 0
}
Write-Output "compliant ($found stack components at target)"
exit 0
