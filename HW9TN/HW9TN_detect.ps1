<#
HW9TN_detect.ps1 v2 - READ-ONLY detection for Dell HW9TN A13
(Intel 2D Imaging / USB IO / Vision camera stack, PB14250 Dell Pro laptops)

Detects BOTH:
  - NEEDS  : one or more stack components below the A13 target version (from mup.xml)
  - BROKEN : live camera problem state - the "camera can't start" / "can't find your
             camera" / "Teams can't see the camera" ticket class:
               * any camera-class device with a nonzero PnP problem code
                 (code 10 = cannot start, 14 = needs restart, 28 = no driver, 43...)
               * zero camera-class devices present on a machine that must have one
               * Frame Server error-level events in the last 7 days

Exit codes (truth table):
  0 = healthy + current        -> leave alone
  1 = NEEDS only               -> routine update, schedule overnight window
  2 = BROKEN only              -> NOT this driver (check ISH prerequisite, BIOS, hw)
  3 = NEEDS + BROKEN           -> prime remediation candidate - this package now
  (Intune Proactive Remediation: any nonzero = non-compliant; remediation can
   re-run this script internally and branch on the code.)

Nothing is modified. No processes or services are touched.

Validation: PnP query syntax + healthy baseline verified on real hardware
(HP USB camera -> CM_PROB_NONE / DEVPKEY_Device_ProblemCode=0) 2026-09-07.

Run: powershell -NoProfile -ExecutionPolicy Bypass -File HW9TN_detect.ps1 [-ForceScan] [-DeferIfBusy]
  -ForceScan  : skip the PB14250 SMBIOS gate (testing on any machine, e.g. lab VMs)
  -DeferIfBusy: informational only - reports running conferencing apps (READ, never killed)
#>
param(
    [switch]$ForceScan,    # bypass SSID gate (for lab VM / non-PB14250 testing)
    [switch]$DeferIfBusy   # informational busy guard
)

$ErrorActionPreference = 'SilentlyContinue'

# --- Layer 0: is this a target machine? (Dell SSID PB14250) ---
$sp   = Get-CimInstance Win32_ComputerSystemProduct
$bb   = Get-CimInstance Win32_BaseBoard
$cs   = Get-CimInstance Win32_ComputerSystem
$sigg = @($sp.Version, $sp.Name, $bb.Product, $cs.Model) -join ' '
if ($sigg -notmatch 'PB14250') {
    if ($ForceScan) { Write-Output "GATE-BYPASSED (-ForceScan): machine is [$sigg]" }
    else { Write-Output "NOT-TARGET: no PB14250 signature in SMBIOS fields (got: $sigg)"; exit 0 }
}

# --- Target table - transcribed from mup.xml (HW9TN A13) ---
# re = regex tested against device HARDWARE IDs; v = minimum acceptable driver version
$targets = @(
    @{ n = 'iacamera64-ARL';  re = 'VEN_8086&DEV_(7D51|7DD1|7D41|7D67|B640).*INT3480';            v = '64.26100.13.20730' }
    @{ n = 'iacamera64-LNL';  re = 'VEN_8086&DEV_(64A0|6420|64B0).*INT3480';                       v = '70.26100.2.21770' }
    @{ n = 'iaisp64-ARL';     re = 'VEN_8086&DEV_7D19';                                            v = '64.26100.13.20730' }
    @{ n = 'iaisp64-LNL';     re = 'VEN_8086&DEV_(645D|5A19)';                                     v = '70.26100.2.21770' }
    @{ n = 'hm1092-sensor';   re = 'VEN_HIMX&DEV_1092';                                            v = '70.26100.2.21770' }
    @{ n = 'ov05c10-sensor';  re = 'VEN_OVTI&DEV_05C1';                                            v = '70.26100.2.21770' }
    @{ n = 'ov08x40-sensor';  re = 'VEN_OVTI&DEV_08F4';                                            v = '70.26100.2.21770' }
    @{ n = 'iactrllogic64';   re = 'VEN_INT&DEV_(3472|346F)';                                      v = '70.26100.2.21770' }
    @{ n = 'usbbridge';       re = 'VID_8086&PID_0B63|VID_2AC1&PID_20C[19B]|VID_06CB&PID_0701';    v = '4.0.1.586' }
    @{ n = 'UsbGpio';         re = 'INTC10B5';                                                     v = '1.0.2.739' }
    @{ n = 'usbi2c';          re = 'INTC10B6';                                                     v = '1.0.2.418' }
    @{ n = 'Vision-ARL';      re = 'INTC10E0';                                                     v = '41.3.10000.40' }
    @{ n = 'Vision-LNL';      re = 'INTC10DE';                                                     v = '3.2.6.2087' }
)

function Get-ProblemCode($instanceId) {
    (Get-PnpDeviceProperty -InstanceId $instanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
}

# --- Layer 1: driver versions vs targets (present devices only) ---
$needs   = @()
$stackProblem = @()
$Device  = Get-PnpDevice -PresentOnly
foreach ($d in $Device) {
    $hw = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds').Data
    if (-not $hw) { continue }
    $hw = $hw -join ';'
    foreach ($t in $targets) {
        if ($hw -match $t.re) {
            $cur = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion').Data
            $ok  = $cur -and ([version]$cur -ge [version]$t.v)
            $curTxt = if ($cur) { $cur } else { 'NO-DRIVER' }
            Write-Output ("{0,-18} status={1,-10} installed={2,-20} target={3,-20} {4}" -f `
                $t.n, $d.Status, $curTxt, $t.v, $(if ($ok) { 'OK' } else { 'OLD' }))
            if (-not $ok) { $needs += "$($t.n): $curTxt -> $($t.v)" }
            # Layer 3a: problem codes on any stack devnode
            $pc = Get-ProblemCode $d.InstanceId
            if ($pc -and $pc -ne 0) { $stackProblem += "$($t.n) problem code $pc ($($d.Problem))" }
            break
        }
    }
}

# --- Layer 2: Synaptics bridge firmware state ---
# Value names confirmed in driver binaries (Vision.sys: CurrentFWVersion; usbbridge.sys:
# TargetVersion, UpdateVersion). Key layout confirmed on one live PB14250 = authoritative
# "firmware already updated?" check; until then this dump is the discovery pass.
$fwRoots = 'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\INTC10E0',
           'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\INTC10DE',
           'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_06CB&PID_0701'
$fwNames = 'CurrentFWVersion', 'TargetVersion', 'UpdateVersion', 'FwImagePathVer2', 'FWVendor'
$fwSeen  = 0
foreach ($root in $fwRoots) {
    Get-ChildItem $root -Recurse | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        foreach ($n in $fwNames) {
            if ($p.$n) {
                Write-Output "FW: $($_.Name.Replace('HKEY_LOCAL_MACHINE\SYSTEM\',''))\$n = $($p.$n)"
                $fwSeen++
            }
        }
    }
}
if ($fwSeen -eq 0) { Write-Output 'FW: no version values found under Vision/usbbridge Enum keys (confirm key layout on a live device)' }

# --- Layer 3: camera health (the ticket states) ---
$camDevices = Get-PnpDevice -Class Camera,Image -PresentOnly
$camProblem = @()
foreach ($c in $camDevices) {
    $pc = Get-ProblemCode $c.InstanceId
    Write-Output ("CAMERA: {0} [{1}] problem={2}" -f $c.FriendlyName, $c.Status, $pc)
    if ($pc -and $pc -ne 0) { $camProblem += "$($c.FriendlyName) problem code $pc ($($c.Problem))" }
}
if ($camDevices.Count -eq 0) {
    Write-Output 'CAMERA: NONE PRESENT - zero camera-class devices = "we can''t find your camera" ticket state'
}

# Frame Server error-level events, trailing 7 days (healthy baseline = 0, verified 2026-09-07)
$fsErr = @(Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-MF-FrameServer/Camera_FrameServer'
        Level   = 1, 2, 3
        StartTime = (Get-Date).AddDays(-7)
    } -ErrorAction SilentlyContinue)
Write-Output ("CAMERA: FrameServer error/warning events (7d): {0}" -f $fsErr.Count)
$fsErr | Select-Object -First 3 | ForEach-Object {
    Write-Output ("  evt {0} [{1}] {2}" -f $_.Id, $_.TimeCreated, (($_.Message -split "`n")[0]))
}

$broken = @()
if ($camDevices.Count -eq 0) { $broken += 'no camera devices present' }
$broken += $camProblem
$broken += $stackProblem
if ($fsErr.Count -ge 5) { $broken += "$($fsErr.Count) FrameServer error events in 7d" }

# --- Optional: busy guard (purely informational - NOTHING is stopped) ---
# Reports apps ACTIVELY STREAMING the camera (ConsentStore LastUsedTimeStop = 0),
# not merely open/running - Teams idling in the tray does not count.
if ($DeferIfBusy) {
    $camHolders = @()
    foreach ($hive in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        $camRoot = "$($hive.PSPath)\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"
        if (-not (Test-Path $camRoot)) { continue }
        foreach ($app in (Get-ChildItem "$camRoot\*", "$camRoot\NonPackaged\*" -ErrorAction SilentlyContinue)) {
            $stop = (Get-ItemProperty $app.PSPath -ErrorAction SilentlyContinue).LastUsedTimeStop
            if ($stop -eq 0) { $camHolders += $app.PSChildName }
        }
    }
    if ($camHolders) { Write-Output "BUSY: camera actively in use by: $($camHolders -join ', ') - defer remediation" }
    else             { Write-Output 'IDLE: camera not in use by any app' }
}

# --- Verdict (truth table) ---
$needFlag = $needs.Count  -gt 0
$brkFlag  = $broken.Count -gt 0
Write-Output ("NEEDS-UPDATE: {0}   CAMERA-BROKEN: {1}" -f $needFlag, $brkFlag)
if ($brkFlag)   { $broken | ForEach-Object { Write-Output "  BROKEN: $_" } }
if ($needFlag)  { $needs  | ForEach-Object { Write-Output "  OLD:    $_" } }

if     ($needFlag -and $brkFlag) { Write-Output 'VERDICT: NEEDS+BROKEN - prime candidate: remediate with HW9TN A13 (exit 3)'; exit 3 }
elseif ($brkFlag)                { Write-Output 'VERDICT: BROKEN only - driver is current, look elsewhere: ISH prerequisite, BIOS, hardware (exit 2)'; exit 2 }
elseif ($needFlag)               { Write-Output 'VERDICT: NEEDS only - routine update, use overnight window (exit 1)'; exit 1 }
else                             { Write-Output 'VERDICT: HEALTHY+CURRENT - leave alone (exit 0)'; exit 0 }
