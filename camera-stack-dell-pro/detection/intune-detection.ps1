<#
HW9TN_pr_detect.ps1 - Intune Remediations DETECTION script (exit 0/1 ONLY)

Performance design (2026-09-09): all PnP properties are read in BATCHED CIM
calls (Get-PnpDeviceProperty accepts an array of instance IDs) - one call per
property key instead of one call per device. A full-stack scan runs in seconds
and leaves the machine alone: a handful of WMI queries, no writes, no process
or service interaction.

Remediations gate: remediation runs ONLY when detection exits exactly 1.
Map:
  exit 0 + "compliant"                 -> healthy, nothing to do
  exit 0 + BROKEN-CURRENT banner       -> camera problem with current drivers:
        dependency route (Dell KB 000248760): BIOS camera enable, chipset,
        graphics, ISH, Serial I/O, ME. NOT fixed by this driver package.
        The banner is visible in the detection-output column = fleet telemetry.
  exit 1                               -> below target OR misbound -> remediate
  non-target hardware                  -> exit 0 silent (no non-compliance noise)

Output order: verdict headline FIRST (survives column-preview truncation),
then detail lines. Keep total output under 4 KB (Intune truncation limit).
#>
param([switch]$ForceScan)   # bypass the model gate (testing on non-target machines)

$ErrorActionPreference = 'SilentlyContinue'
$out = @()

# --- Layer 0: hardware gate ---
$sp = Get-CimInstance Win32_ComputerSystemProduct
$bb = Get-CimInstance Win32_BaseBoard
$cs = Get-CimInstance Win32_ComputerSystem
$sig = @($sp.Version, $sp.Name, $bb.Product, $cs.Model) -join ' '
if ($sig -notmatch 'P[AB]14250') { if ($ForceScan) { $out += "GATE-BYPASSED: [$sig]" } else { exit 0 } }

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

# --- Batched device snapshot: 1 fleet-wide call for hardware IDs ---
$devices = Get-PnpDevice -PresentOnly
$ids = @($devices | ForEach-Object { $_.InstanceId })
$hwMap = @{}
Get-PnpDeviceProperty -InstanceId $ids -KeyName 'DEVPKEY_Device_HardwareIds' |
    ForEach-Object { $hwMap[$_.InstanceId] = $_.Data }

# match devices to family rows, and collect camera + dependency devices
$matched = @(); $camIds = @(); $depIds = @()
foreach ($d in $devices) {
    if ($d.Class -in 'Camera', 'Image') { $camIds += $d.InstanceId }
    if ($d.FriendlyName -match 'Integrated Sensor Solution|Serial IO|Management Engine') { $depIds += $d.InstanceId }
    $hw = $hwMap[$d.InstanceId]
    if (-not $hw) { continue }
    $hwj = $hw -join ';'
    foreach ($t in $targets) {
        if ($hwj -match $t.re) { $matched += [pscustomobject]@{ d = $d; t = $t }; break }
    }
}
$stackIds = @($matched | ForEach-Object { $_.d.InstanceId })

# --- Batched property reads: one call per key for stack + camera + dep devices ---
$readIds = @($stackIds + $camIds + $depIds) | Select-Object -Unique
function New-Map($KeyName) {
    $m = @{}
    Get-PnpDeviceProperty -InstanceId $readIds -KeyName $KeyName -ErrorAction SilentlyContinue |
        ForEach-Object { $m[$_.InstanceId] = $_.Data }
    return $m
}
$verMap  = New-Map 'DEVPKEY_Device_DriverVersion'
$provMap = New-Map 'DEVPKEY_Device_DriverProvider'
$infMap  = New-Map 'DEVPKEY_Device_DriverInfPath'
$probMap = New-Map 'DEVPKEY_Device_ProblemCode'

# --- evaluate ---
$needs = @(); $misbound = @(); $problem = @(); $disabled = @(); $found = 0
foreach ($m in $matched) {
    $found++
    $cur = $verMap[$m.d.InstanceId]
    if (-not $cur -or [version]$cur -lt [version]$m.t.v) { $needs += "$($m.t.n): $(if ($cur) { $cur } else { 'NONE' }) -> $($m.t.v)" }
    $pc = $probMap[$m.d.InstanceId]
    if ($pc -eq 22) { $disabled += "$($m.t.n) disabled (CM_PROB_DISABLED - user/policy choice; a driver update will not enable it)" }
    elseif ($pc -and $pc -ne 0) { $problem += "$($m.t.n) code $pc" }
    if ($provMap[$m.d.InstanceId] -match 'Microsoft' -or $infMap[$m.d.InstanceId] -match 'usbvideo\.inf') { $misbound += "$($m.t.n) on inbox driver" }
}
foreach ($cid in $camIds) {
    $cpc = $probMap[$cid]
    $fname = ($devices | Where-Object InstanceId -eq $cid).FriendlyName
    if ($cpc -eq 22) { $disabled += "$fname disabled" }
    elseif ($cpc -and $cpc -ne 0) { $problem += "$fname code $cpc" }
}
$camCount = $camIds.Count
if ($camCount -eq 0 -and $disabled.Count -eq 0) { $problem += 'no camera devices present' }
$fsErr = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-MF-FrameServer/Camera_FrameServer'; Level = 1,2,3; StartTime = (Get-Date).AddDays(-7) }).Count
if ($fsErr -ge 5) { $problem += "$fsErr FrameServer errors in 7d" }

# --- RCA context (read-only; feeds the detection-output column fleet-wide) ---
$os = Get-CimInstance Win32_OperatingSystem
$firstErr = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-MF-FrameServer/Camera_FrameServer'; Level = 1,2 } -Oldest -MaxEvents 1 -ErrorAction SilentlyContinue
$delta = if ($firstErr) { [int](($firstErr.TimeCreated - $os.InstallDate).TotalHours) } else { $null }
$out += ("HW9TN|ctx|bios={0}|build={1}|os_changed={2:yyyy-MM-dd}|winold={3}" -f `
    (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion, $os.BuildNumber, $os.InstallDate, (Test-Path 'C:\Windows.old'))
$depNames = @{ 'Integrated Sensor Solution' = 'ish'; 'Serial IO' = 'serialio'; 'Management Engine' = 'me' }
$depLine = foreach ($k in $depNames.Keys) {
    $did = ($devices | Where-Object { $_.FriendlyName -match $k } | Select-Object -First 1).InstanceId
    '{0}={1}' -f $depNames[$k], $(if ($did -and $verMap[$did]) { $verMap[$did] } else { 'missing' })
}
$out += ('HW9TN|dep|' + ($depLine -join '|'))
$out += ("HW9TN|rca|first_err={0}|upgraded={1:yyyy-MM-dd HH:mm}|delta={2}" -f `
    $(if ($firstErr) { $firstErr.TimeCreated.ToString('yyyy-MM-ddTHH:mm') } else { 'none-in-retention' }),
    $os.InstallDate, $(if ($null -ne $delta) { "{0}h" -f $delta } else { 'n/a' }))

# --- firmware-payload proxy (registry layout confirmed on live hardware) ---
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
    $out += "HW9TN|fw|proxy=$fwCurrent|target>=$fwExtTarget|state=OLD"
} elseif ($fwCurrent) {
    $out += "HW9TN|fw|proxy=$fwCurrent|target>=$fwExtTarget|state=CURRENT"
}

# --- headline first (survives any column-preview truncation), then buffered detail ---
$needNames = (@($needs + $misbound) | ForEach-Object { ($_ -split ':')[0] }) -join ','
$brkNames  = (@($problem) | ForEach-Object { ($_ -split ' ')[0] }) -join ','
$headline = if ($needs.Count -or $misbound.Count) { "NEEDS($($needs.Count + $misbound.Count)): $needNames" } else { 'OK' }
if ($brkNames) { $headline += " | BROKEN: $brkNames" }
if ($disabled) { $headline += ' | disabled-by-choice' }
$headline += " | fw:$(if ($fwCurrent) { $fwCurrent } else { 'n/a' }) | upg:$($os.InstallDate.ToString('yyyy-MM-dd')) | err7d:$fsErr"
Write-Output $headline
Write-Output ''
$out | ForEach-Object { Write-Output $_ }

# --- exit map ---
if ($needs.Count -or $misbound.Count) {
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
