<#
HW9TN_pr_detect.ps1 - Intune Remediations DETECTION script (exit 0/1 ONLY)

Data layer (2026-09-09): device inventory comes from two CIM classes, correctly
keyed by PNPDeviceID - Win32_PnPEntity (hardware IDs, problem codes, class,
name) and Win32_PnPSignedDriver (driver version/provider/INF). Bulk
Get-PnpDeviceProperty is NOT used: it stamps every result with the first
device's InstanceId (verified live), which silently collapses per-device maps.
Full scan runs in ~2s; read-only; no writes, no process or service interaction.

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
    @{ n = 'hm1092-PB';         re = 'VEN_HIMX&DEV_1092&SUBSYS_0C(DC|F8|E8|F7)1028';                         v = '70.26100.2.21770' }
    @{ n = 'ov05c10-PB';        re = 'VEN_OVTI&DEV_05C1&SUBSYS_0C(DC|F8|E8|F7)1028';                         v = '70.26100.2.21770' }
    @{ n = 'ov08x40-PB';        re = 'VEN_OVTI&DEV_08F4&SUBSYS_0C(DC|F8|E8|F7)1028';                         v = '70.26100.2.21770' }
    @{ n = 'iactrllogic-PB';    re = 'VEN_INT&DEV_(3472|346F)&SUBSYS_0C(DC|F8|E8|F7)1028';                   v = '70.26100.2.21770' }
    @{ n = 'usbbridge';         re = 'VID_8086&PID_0B63|VID_2AC1&PID_20C[19B]|VID_06CB&PID_0701';  v = '4.0.1.586' }
    @{ n = 'UsbGpio';           re = 'INTC10B5';                                                     v = '1.0.2.739' }
    @{ n = 'usbi2c';            re = 'INTC10B6';                                                     v = '1.0.2.418' }
    @{ n = 'Vision-LNL';        re = 'INTC10DE';                                                     v = '3.2.6.2087' }
    @{ n = 'Vision-ARL';        re = 'INTC10E0';                                                     v = '41.3.10000.40' }
)

# --- Fleet snapshot: two CIM queries, keyed by PNPDeviceID ---
$entities = Get-CimInstance Win32_PnPEntity -Property PNPDeviceID, HardwareID, ConfigManagerErrorCode, PNPClass, Name
$drvMap = @{}   # populated after $matched (fallback needs the matched id set)

# match entities to family rows; collect camera + dependency entities
$matched = @(); $cams = @(); $deps = @()
foreach ($e in $entities) {
    if ($e.PNPClass -in 'Camera', 'Image') { $cams += $e }
    if ($e.Name -match 'Integrated Sensor Solution|Serial IO|Management Engine') { $deps += $e }
    $hw = $e.HardwareID
    if (-not $hw) { continue }
    $hwj = $hw -join ';'
    foreach ($t in $targets) {
        if ($hwj -match $t.re) { $matched += [pscustomobject]@{ e = $e; t = $t }; break }
    }
}

$readIds = @(($matched | ForEach-Object { $_.e.PNPDeviceID }) + ($cams | ForEach-Object { $_.PNPDeviceID }) + ($deps | ForEach-Object { $_.PNPDeviceID })) | Select-Object -Unique
# Win32_PnPSignedDriver quirks (verified live 2026-09-10): rejects -Property and
# -Filter WQL forms ("Invalid query") and returns ZERO rows under EAP
# SilentlyContinue - scope Continue around it, fall back to per-device reads
# (the always-reliable path) when the map comes back thin.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Get-CimInstance Win32_PnPSignedDriver |
    Select-Object PNPDeviceID, DriverVersion, DriverProviderName, InfName |
    Where-Object { $_.PNPDeviceID } |
    ForEach-Object { $drvMap[$_.PNPDeviceID] = $_ }
$ErrorActionPreference = $prevEap
$missingIds = @($readIds | Where-Object { -not $drvMap[$_] })
if ($missingIds.Count -gt 0) {
    foreach ($id in $missingIds) {
        $v = (Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction SilentlyContinue).Data
        $p = (Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_DriverProvider' -ErrorAction SilentlyContinue).Data
        $i = (Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue).Data
        if ($v -or $p -or $i) { $drvMap[$id] = [pscustomobject]@{ PNPDeviceID = $id; DriverVersion = $v; DriverProviderName = $p; InfName = $i } }
    }
}

# --- evaluate ---
$needs = @(); $misbound = @(); $problem = @(); $disabled = @(); $found = 0
foreach ($m in $matched) {
    $found++
    $id = $m.e.PNPDeviceID
    $drv = $drvMap[$id]
    $cur = if ($drv) { $drv.DriverVersion } else { $null }
    if (-not $cur -or [version]$cur -lt [version]$m.t.v) { $needs += "$($m.t.n): $(if ($cur) { $cur } else { 'NONE' }) -> $($m.t.v)" }
    $pc = $m.e.ConfigManagerErrorCode
    if ($pc -eq 22) { $disabled += "$($m.t.n) disabled (CM_PROB_DISABLED - user/policy choice; a driver update will not enable it)" }
    elseif ($pc -and $pc -ne 0) { $problem += "$($m.t.n) code $pc" }
    if ($drv -and ($drv.DriverProviderName -match 'Microsoft' -or $drv.InfName -match 'usbvideo\.inf')) { $misbound += "$($m.t.n) on inbox driver" }
}
foreach ($c in $cams) {
    $cpc = $c.ConfigManagerErrorCode
    if ($cpc -eq 22) { $disabled += "$($c.Name) disabled" }
    elseif ($cpc -and $cpc -ne 0) { $problem += "$($c.Name) code $cpc" }
}
$camCount = $cams.Count
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
    $de = ($deps | Where-Object { $_.Name -match $k } | Select-Object -First 1)
    $dv = if ($de) { $drvMap[$de.PNPDeviceID].DriverVersion } else { $null }
    '{0}={1}' -f $depNames[$k], $(if ($dv) { $dv } else { 'missing' })
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
        if ($p.CurrentFWVersion) { $fwCurrent = $p.CurrentFWVersion }
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
