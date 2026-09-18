<#
.SYNOPSIS
    Detects whether the Intel camera driver stack on a Dell Pro laptop is
    outdated, misbound, or unhealthy.

.DESCRIPTION
    This script is the detection half of an Intune Remediations package. It
    runs read-only on a schedule and returns one of two exit codes:

        Exit 0  The machine does not need remediation. This covers three cases:
                drivers are current and the camera is healthy, the camera is
                broken but the drivers are current (a dependency problem this
                package cannot fix - see NOTES below), or the machine is not
                a supported model (silent exit, no output).

        Exit 1  The machine needs remediation. At least one camera-stack
                component is below its target version, or Intel hardware is
                bound to a generic Windows inbox driver instead of the Intel
                driver. The remediation script will attempt to fix this.

    When the camera is broken but the drivers are current, the script prints
    a BROKEN-CURRENT banner in its output explaining the dependency route
    (Dell KB 000248760). This banner appears in the Intune detection-output
    column, giving support staff visibility without triggering unnecessary
    remediation cycles.

    The script never writes anything, starts anything, or stops anything.
    It is safe to run at any time, including during video calls.

.HOW IT WORKS
    1. Hardware gate. Win32_ComputerSystemProduct, Win32_BaseBoard, and
       Win32_ComputerSystem are queried for the system model signature.
       Only Dell Pro models PB14250 and PA14250 proceed; everything else
       exits silently.

    2. Device inventory. Win32_PnPEntity returns every present device with
       its hardware IDs, problem code, device class, and name. This is one
       CIM call and is fast (~0.1 seconds on typical hardware).

    3. Driver binding. Win32_PnPSignedDriver returns the installed driver
       version, provider, and INF name for each device. This class is keyed
       by its DeviceID property (not PNPDeviceID - that property does not
       exist on this class, a distinction that cost a day of debugging).
       When the class returns incomplete data, individual devices are read
       via Get-PnpDeviceProperty as a fallback.

    4. Target comparison. Each device's hardware IDs are matched against a
       table of known camera-stack components with their minimum acceptable
       versions. Components below target are collected as findings.

    5. Health evaluation. Device problem codes are checked (10 = cannot
       start, 14 = needs restart, 22 = disabled by user choice, 28 = no
       driver). Camera-class device count is verified. Frame Server error
       events from the trailing 7 days are counted.

    6. Output. A verdict headline is printed first (so it survives any
       column-preview truncation in the Intune portal), followed by
       diagnostic detail lines. Total output stays well under the 4 KB
       Intune truncation limit.

.NOTES
    File name     : intune-detection.ps1
    Requires      : Windows 11, PowerShell 5.1+
    Privileges    : Read-only; no elevation required
    Run frequency : Daily or weekly (Intune Remediations schedule)
    Paired with   : intune-remediation.ps1

    Supported hardware (verified from package INFs):
    - HW9TN A13: Dell Pro 14 Plus (PB14250), subsystems 0CDC/0CF8/0CE8/0CF7
    - 845M5 A12: Dell Pro 13/14 Premium (PA13250/PA14250), subsystems 0CE3/0CE4

    When the camera is broken but drivers are current, the fix is the
    dependency route described in Dell KB 000248760: verify BIOS camera is
    enabled, then update chipset, graphics, Intel ISH (Integrated Sensor
    Solution), Serial I/O, and Management Engine components.

.LINK
    Dell KB 000248760: https://www.dell.com/support/kbdoc/en-us/000248760/
#>

# =============================================================================
# PARAMETERS
# =============================================================================

# Bypasses the hardware model gate so the script can be tested on any machine.
# Normal scheduled runs never use this.
param([switch]$SkipModelGate)

# =============================================================================
# INITIALIZATION
# =============================================================================

# SilentlyContinue: missing registry keys, empty event logs, and absent devices
# are normal conditions on many machines, not errors. The script handles each.
$ErrorActionPreference = 'SilentlyContinue'

# Detail lines are buffered here and printed after the headline. This keeps the
# most important information first in the output, which matters because the
# Intune portal's detection-output column may truncate anything below the fold.
$detailOutputLines = @()

# =============================================================================
# HARDWARE GATE
# =============================================================================
# Only Dell Pro laptops with the Intel MIPI camera stack are relevant. Checking
# four SMBIOS fields because the model string surfaces in different fields
# depending on the OEM firmware generation.

$systemProduct  = Get-CimInstance Win32_ComputerSystemProduct
$baseBoard      = Get-CimInstance Win32_BaseBoard
$computerSystem = Get-CimInstance Win32_ComputerSystem

$modelSignature = @($systemProduct.Version, $systemProduct.Name, $baseBoard.Product, $computerSystem.Model) -join ' '

if ($modelSignature -notmatch 'P[AB]14250') {
    if ($SkipModelGate) {
        $detailOutputLines += "GATE-BYPASSED: [$modelSignature]"
    } else {
        # Not a supported model. Exit silently so the machine does not appear
        # as non-compliant in the Intune reporting.
        exit 0
    }
}

# =============================================================================
# CAMERA STACK COMPONENT TABLES
# =============================================================================
# Each row maps a hardware-ID pattern to the minimum acceptable driver version
# for that component. The patterns include Dell subsystem IDs because the
# packages are subsystem-locked (they bind only to specific Dell boards).
# Two families exist: PA (Premium, package 845M5 A12) and PB (Plus, HW9TN A13).

$cameraStackComponents = @(
    # --- PA family: Dell Pro 13/14 Premium ---
    @{ ComponentName = 'iacamera64-PA';     HardwareIdPattern = 'VEN_8086&DEV_64A0&SUBSYS_0CE[34]1028.*INT3480';              MinimumVersion = '70.26100.2.21086' }
    @{ ComponentName = 'iaisp64-PA';        HardwareIdPattern = 'VEN_8086&DEV_645D&SUBSYS_0CE[34]1028';                        MinimumVersion = '70.26100.2.21086' }
    @{ ComponentName = 'hm1092-PA';         HardwareIdPattern = 'VEN_HIMX&DEV_1092&SUBSYS_0CE[34]1028';                        MinimumVersion = '70.26100.2.21086' }
    @{ ComponentName = 'ov08x40-PA';        HardwareIdPattern = 'VEN_OVTI&DEV_08F4&SUBSYS_0CE[34]1028';                        MinimumVersion = '70.26100.2.21086' }
    @{ ComponentName = 'iactrllogic-PA';    HardwareIdPattern = 'VEN_INT&DEV_3472&SUBSYS_0CE[34]1028';                         MinimumVersion = '70.26100.2.21086' }
    # --- PB family: Dell Pro 14 Plus ---
    @{ ComponentName = 'iacamera64-PB-ARL'; HardwareIdPattern = 'VEN_8086&DEV_(7D51|7DD1|7D41|7D67|B640)&SUBSYS_0C(E8|F7)1028.*INT3480'; MinimumVersion = '64.26100.13.20730' }
    @{ ComponentName = 'iacamera64-PB-LNL'; HardwareIdPattern = 'VEN_8086&DEV_(64A0|6420|64B0)&SUBSYS_0C(DC|F8)1028.*INT3480';           MinimumVersion = '70.26100.2.21770' }
    @{ ComponentName = 'iaisp64-PB-ARL';    HardwareIdPattern = 'VEN_8086&DEV_7D19&SUBSYS_0C(E8|F7)1028';                                 MinimumVersion = '64.26100.13.20730' }
    @{ ComponentName = 'iaisp64-PB-LNL';    HardwareIdPattern = 'VEN_8086&DEV_(645D|5A19)&SUBSYS_0C(DC|F8)1028';                          MinimumVersion = '70.26100.2.21770' }
    @{ ComponentName = 'hm1092-PB';         HardwareIdPattern = 'VEN_HIMX&DEV_1092&SUBSYS_0C(DC|F8|E8|F7)1028';                         MinimumVersion = '70.26100.2.21770' }
    @{ ComponentName = 'ov05c10-PB';        HardwareIdPattern = 'VEN_OVTI&DEV_05C1&SUBSYS_0C(DC|F8|E8|F7)1028';                         MinimumVersion = '70.26100.2.21770' }
    @{ ComponentName = 'ov08x40-PB';        HardwareIdPattern = 'VEN_OVTI&DEV_08F4&SUBSYS_0C(DC|F8|E8|F7)1028';                         MinimumVersion = '70.26100.2.21770' }
    @{ ComponentName = 'iactrllogic-PB';    HardwareIdPattern = 'VEN_INT&DEV_(3472|346F)&SUBSYS_0C(DC|F8|E8|F7)1028';                   MinimumVersion = '70.26100.2.21770' }
    # --- shared components (identical version in both families) ---
    @{ ComponentName = 'usbbridge';         HardwareIdPattern = 'VID_8086&PID_0B63|VID_2AC1&PID_20C[19B]|VID_06CB&PID_0701';  MinimumVersion = '4.0.1.586' }
    @{ ComponentName = 'UsbGpio';           HardwareIdPattern = 'INTC10B5';                                                     MinimumVersion = '1.0.2.739' }
    @{ ComponentName = 'usbi2c';            HardwareIdPattern = 'INTC10B6';                                                     MinimumVersion = '1.0.2.418' }
    @{ ComponentName = 'Vision-LNL';        HardwareIdPattern = 'INTC10DE';                                                     MinimumVersion = '3.2.6.2087' }
    @{ ComponentName = 'Vision-ARL';        HardwareIdPattern = 'INTC10E0';                                                     MinimumVersion = '41.3.10000.40' }
)

# =============================================================================
# DEVICE INVENTORY
# =============================================================================
# Win32_PnPEntity provides every present device with its hardware IDs,
# problem code, device class, and name in a single fast CIM call (~0.1s).
# This is the reliable foundation; the driver class below is the flaky part.

$allDevices = Get-CimInstance Win32_PnPEntity -Property PNPDeviceID, HardwareID, ConfigManagerErrorCode, PNPClass, Name

# Win32_PnPSignedDriver provides the installed driver version, provider name,
# and INF name. This class is cached and intermittently unreliable: it rejects
# -Property and -Filter WQL forms, sometimes returns empty, and its key is
# named DeviceID (not PNPDeviceID). Treat it as an accelerator with a fallback.

$driverInfoByDeviceId = @{}
Get-CimInstance Win32_PnPSignedDriver |
    Select-Object DeviceID, DriverVersion, DriverProviderName, InfName |
    Where-Object { $_.DeviceID } |
    ForEach-Object {
        $driverInfoByDeviceId[$_.DeviceID] = [pscustomobject]@{
            PNPDeviceID        = $_.DeviceID
            DriverVersion      = $_.DriverVersion
            DriverProviderName = $_.DriverProviderName
            InfName            = $_.InfName
        }
    }

# Match each device against the camera-stack component table. Also collect
# camera-class devices and dependency devices (ISH, Serial I/O, Management
# Engine) in the same pass to avoid iterating the full device list twice.

$matchedStackDevices   = @()
$cameraDevices         = @()
$dependencyDevices     = @()

foreach ($device in $allDevices) {
    # Camera-class devices are tracked for presence and health.
    if ($device.PNPClass -in 'Camera', 'Image') { $cameraDevices += $device }

    # Dependencies are matched by device name (the KB 000248760 route).
    if ($device.Name -match 'Integrated Sensor Solution|Serial IO|Management Engine') { $dependencyDevices += $device }

    # Stack matching is by hardware-ID pattern.
    $hardwareIds = $device.HardwareID
    if (-not $hardwareIds) { continue }
    $hardwareIdString = $hardwareIds -join ';'

    foreach ($component in $cameraStackComponents) {
        if ($hardwareIdString -match $component.HardwareIdPattern) {
            $matchedStackDevices += [pscustomobject]@{ Device = $device; Component = $component }
            break   # first match wins; a device belongs to exactly one component
        }
    }
}

# If the driver class returned incomplete data for any of the devices we care
# about, read them individually via Get-PnpDeviceProperty. This is the reliable
# path (~0.4s per device) and only runs for the specific devices that need it.

$devicesNeedingDriverInfo = @(
    ($matchedStackDevices | ForEach-Object { $_.Device.PNPDeviceID }) +
    ($cameraDevices         | ForEach-Object { $_.PNPDeviceID }) +
    ($dependencyDevices     | ForEach-Object { $_.PNPDeviceID })
) | Select-Object -Unique

$devicesMissingDriverInfo = @($devicesNeedingDriverInfo | Where-Object { -not $driverInfoByDeviceId[$_] })

if ($devicesMissingDriverInfo.Count -gt 0) {
    foreach ($deviceId in $devicesMissingDriverInfo) {
        $version  = (Get-PnpDeviceProperty -InstanceId $deviceId -KeyName 'DEVPKEY_Device_DriverVersion'  -ErrorAction SilentlyContinue).Data
        $provider = (Get-PnpDeviceProperty -InstanceId $deviceId -KeyName 'DEVPKEY_Device_DriverProvider' -ErrorAction SilentlyContinue).Data
        $infName  = (Get-PnpDeviceProperty -InstanceId $deviceId -KeyName 'DEVPKEY_Device_DriverInfPath'  -ErrorAction SilentlyContinue).Data
        if ($version -or $provider -or $infName) {
            $driverInfoByDeviceId[$deviceId] = [pscustomobject]@{
                PNPDeviceID        = $deviceId
                DriverVersion      = $version
                DriverProviderName = $provider
                InfName            = $infName
            }
        }
    }
}

# =============================================================================
# EVALUATE STACK HEALTH
# =============================================================================
# Four finding categories, each triggering a different response:
#   Outdated: the installed version is below the component's target.
#   Misbound: Intel hardware running a generic Microsoft inbox driver.
#   Problem:  the device reports a nonzero problem code (but not 22).
#   Disabled: problem code 22 (CM_PROB_DISABLED). Deliberate user or policy
#             choice, not a fault. A driver update will not enable the device.

$outdatedComponents   = @()
$misboundComponents   = @()
$activeDeviceProblems = @()
$deliberatelyDisabled = @()
$stackDevicesAtTarget = 0

foreach ($match in $matchedStackDevices) {
    $stackDevicesAtTarget++
    $deviceId   = $match.Device.PNPDeviceID
    $driverInfo = $driverInfoByDeviceId[$deviceId]

    $installedVersion = if ($driverInfo) { $driverInfo.DriverVersion } else { $null }

    # Version comparison: below target or missing entirely.
    if (-not $installedVersion -or [version]$installedVersion -lt [version]$match.Component.MinimumVersion) {
        $versionText = if ($installedVersion) { $installedVersion } else { 'NONE' }
        $outdatedComponents += "$($match.Component.ComponentName): $versionText -> $($match.Component.MinimumVersion)"
    }

    # Problem code evaluation (0 = healthy, 22 = disabled, anything else = fault).
    $problemCode = $match.Device.ConfigManagerErrorCode
    if ($problemCode -eq 22) {
        $deliberatelyDisabled += "$($match.Component.ComponentName) disabled (user/policy choice; a driver update will not enable it)"
    } elseif ($problemCode -and $problemCode -ne 0) {
        $activeDeviceProblems += "$($match.Component.ComponentName) code $problemCode"
    }

    # Misbinding: our Intel hardware should never run an inbox Microsoft driver.
    if ($driverInfo -and ($driverInfo.DriverProviderName -match 'Microsoft' -or $driverInfo.InfName -match 'usbvideo\.inf')) {
        $misboundComponents += "$($match.Component.ComponentName) on inbox driver"
    }
}

# Camera-class devices: check for problem codes separately from the stack table.
foreach ($cameraDevice in $cameraDevices) {
    $cameraProblemCode = $cameraDevice.ConfigManagerErrorCode
    if ($cameraProblemCode -eq 22) {
        $deliberatelyDisabled += "$($cameraDevice.Name) disabled"
    } elseif ($cameraProblemCode -and $cameraProblemCode -ne 0) {
        $activeDeviceProblems += "$($cameraDevice.Name) code $cameraProblemCode"
    }
}

# Zero camera-class devices is the "we can't find your camera" ticket state.
# This is only flagged when nothing is disabled (a disabled camera still exists).
$cameraDeviceCount = $cameraDevices.Count
if ($cameraDeviceCount -eq 0 -and $deliberatelyDisabled.Count -eq 0) {
    $activeDeviceProblems += 'no camera devices present'
}

# Frame Server errors in the trailing week: a healthy machine shows zero.
# Five or more error-level events indicate a camera that is failing repeatedly.
$frameServerErrorCount = @(Get-WinEvent -FilterHashtable @{
    LogName   = 'Microsoft-Windows-MF-FrameServer/Camera_FrameServer'
    Level     = 1, 2, 3
    StartTime = (Get-Date).AddDays(-7)
}).Count
if ($frameServerErrorCount -ge 5) {
    $activeDeviceProblems += "$frameServerErrorCount Frame Server errors in the trailing 7 days"
}

# =============================================================================
# ROOT-CAUSE CONTEXT
# =============================================================================
# These lines appear in the detection-output column and help correlate camera
# failures with recent feature updates (the 23H2-to-25H2 upgrade casualty
# pattern). They are informational and never change the exit code.

$operatingSystem = Get-CimInstance Win32_OperatingSystem

# The oldest error-level Frame Server event, used to correlate the first
# camera failure with the feature-update date.
$firstFrameServerError = Get-WinEvent -FilterHashtable @{
    LogName   = 'Microsoft-Windows-MF-FrameServer/Camera_FrameServer'
    Level     = 1, 2
} -Oldest -MaxEvents 1 -ErrorAction SilentlyContinue

$hoursBetweenUpgradeAndFirstError = if ($firstFrameServerError) {
    [int](($firstFrameServerError.TimeCreated - $operatingSystem.InstallDate).TotalHours)
} else {
    $null
}

$detailOutputLines += ("HW9TN|ctx|bios={0}|build={1}|os_changed={2:yyyy-MM-dd}|winold={3}" -f `
    (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion,
    $operatingSystem.BuildNumber,
    $operatingSystem.InstallDate,
    (Test-Path 'C:\Windows.old'))

# Dependency versions (ISH, Serial I/O, Management Engine) - missing values
# point to the KB 000248760 dependency route.
$dependencyNameMap = @{
    'Integrated Sensor Solution' = 'ish'
    'Serial IO'                  = 'serialio'
    'Management Engine'          = 'me'
}
$dependencyLines = foreach ($searchName in $dependencyNameMap.Keys) {
    $depDevice  = ($dependencyDevices | Where-Object { $_.Name -match $searchName } | Select-Object -First 1)
    $depVersion = if ($depDevice) { $driverInfoByDeviceId[$depDevice.PNPDeviceID].DriverVersion } else { $null }
    '{0}={1}' -f $dependencyNameMap[$searchName], $(if ($depVersion) { $depVersion } else { 'missing' })
}
$detailOutputLines += ('HW9TN|dep|' + ($dependencyLines -join '|'))

$detailOutputLines += ("HW9TN|rca|first_err={0}|upgraded={1:yyyy-MM-dd HH:mm}|delta={2}" -f `
    $(if ($firstFrameServerError) { $firstFrameServerError.TimeCreated.ToString('yyyy-MM-ddTHH:mm') } else { 'none-in-retention' }),
    $operatingSystem.InstallDate,
    $(if ($null -ne $hoursBetweenUpgradeAndFirstError) { "{0}h" -f $hoursBetweenUpgradeAndFirstError } else { 'n/a' }))

# =============================================================================
# FIRMWARE PAYLOAD CHECK
# =============================================================================
# The registry value CurrentFWVersion (under the Vision device's enumeration
# key) carries the Synaptics vision-extension INF version. This is a proxy:
# 133.152.66.0 or later means firmware family 8.5.98.42 or later, which is the
# level shipped in both current packages. TargetVersion and UpdateVersion are
# always 0.0.0.0 (unpopulated placeholders) and carry no signal.

$minimumFirmwareProxyVersion = '133.152.66.0'
$currentFirmwareVersion = $null

foreach ($registryRoot in 'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\INTC10E0',
                          'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\INTC10DE',
                          'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_06CB&PID_0701') {
    Get-ChildItem $registryRoot -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $registryValues = Get-ItemProperty $_.PSPath
        if ($registryValues.CurrentFWVersion) { $currentFirmwareVersion = $registryValues.CurrentFWVersion }
    }
}

if ($currentFirmwareVersion -and ([version]$currentFirmwareVersion -lt [version]$minimumFirmwareProxyVersion)) {
    $outdatedComponents += "vision-firmware-extension: $currentFirmwareVersion -> $minimumFirmwareProxyVersion"
    $detailOutputLines += "HW9TN|fw|proxy=$currentFirmwareVersion|target>=$minimumFirmwareProxyVersion|state=OLD"
} elseif ($currentFirmwareVersion) {
    $detailOutputLines += "HW9TN|fw|proxy=$currentFirmwareVersion|target>=$minimumFirmwareProxyVersion|state=CURRENT"
}

# =============================================================================
# OUTPUT
# =============================================================================
# The headline goes first because the Intune portal's detection-output column
# may truncate. Everything a support engineer needs to triage is in this one
# line: what needs updating, what is broken, firmware state, upgrade recency,
# and the Frame Server error count.
#
# BROKEN is driven by device problem codes (10 = cannot start, 14 = needs
# restart, 28 = no driver, etc.), NOT by Frame Server errors. A dead camera
# often generates zero Frame Server events because there is nothing to connect
# to. fsErr7d is a supplementary signal that catches intermittent failures on
# cameras that otherwise report a clean problem code.

$outdatedComponentNames = (@($outdatedComponents + $misboundComponents) | ForEach-Object { ($_ -split ':')[0] }) -join ','
$brokenComponentNames   = (@($activeDeviceProblems) | ForEach-Object { ($_ -split ' ')[0] }) -join ','

$verdictHeadline = if ($outdatedComponents.Count -or $misboundComponents.Count) {
    "NEEDS($($outdatedComponents.Count + $misboundComponents.Count)): $outdatedComponentNames"
} else {
    'OK'
}
if ($brokenComponentNames)   { $verdictHeadline += " | BROKEN: $brokenComponentNames" }
if ($deliberatelyDisabled)   { $verdictHeadline += ' | disabled-by-choice' }
$verdictHeadline += " | fw:$(if ($currentFirmwareVersion) { $currentFirmwareVersion } else { 'n/a' })"
$verdictHeadline += " | upg:$($operatingSystem.InstallDate.ToString('yyyy-MM-dd'))"
$verdictHeadline += " | fsErr7d:$frameServerErrorCount"

Write-Output $verdictHeadline
Write-Output ''
$detailOutputLines | ForEach-Object { Write-Output $_ }

# =============================================================================
# EXIT CODE
# =============================================================================

$needsRemediation = ($outdatedComponents.Count -gt 0) -or ($misboundComponents.Count -gt 0)

if ($needsRemediation) {
    # Print the specific findings so the Intune detection-output column shows
    # exactly what is wrong, not just the exit code.
    Write-Output ''
    Write-Output "REMEDIATION REQUIRED - $($outdatedComponents.Count + $misboundComponents.Count) finding(s):"
    ($outdatedComponents + $misboundComponents) | ForEach-Object { Write-Output "  $_" }
    if ($activeDeviceProblems) {
        Write-Output "Also broken now: $($activeDeviceProblems -join '; ')"
    }
    if ($deliberatelyDisabled) {
        Write-Output "Disabled by choice (not a fault): $($deliberatelyDisabled -join '; ')"
    }
    exit 1
}

if ($activeDeviceProblems.Count) {
    # Drivers are current but the camera is broken. This is a dependency
    # problem (BIOS, chipset, ISH, etc.) that this package cannot fix.
    # Print the route so it appears in the detection-output column.
    Write-Output 'BROKEN-CURRENT: drivers at target but camera problems present -'
    Write-Output 'dependency route (Dell KB 000248760): BIOS camera enable, chipset, graphics, ISH, Serial I/O, ME'
    $activeDeviceProblems | ForEach-Object { Write-Output "  $_" }
    if ($deliberatelyDisabled) { Write-Output "also-disabled (NOT a fault): $($deliberatelyDisabled -join '; ')" }
    exit 0
}

if ($deliberatelyDisabled.Count) {
    Write-Output "compliant ($stackDevicesAtTarget stack components at target); camera devices disabled by choice: $($deliberatelyDisabled -join '; ')"
    exit 0
}

Write-Output "compliant ($stackDevicesAtTarget stack components at target)"
exit 0
