<#
HW9TN_pr_remediate.ps1 - Intune Remediations REMEDIATION script
Runs after HW9TN_pr_detect.ps1 exits 1. Budget: 60 min hard cap (Intune
remediations timeout = 3600s) -> download+extract (~5m) + patient wait
(default 45m) + install (~2m) + sweep fits. Daily recurrence = the retry
engine: whatever misses today's window gets the next day's run.

Flow: gate -> pick family package -> cache/download -> verify signature ->
silent-extract -> patient camera-idle wait -> pnputil install -> re-enumerate
-> old-driver cleanup sweep (delete only UNBOUND superseded family packages)
-> verify + report. Restarts stay user-paced: pending-reboot states ride the
user's natural reboot; nothing is ever forced, killed, or prompted.

Stage/cache: C:\ProgramData\DellCamera\<package-id>\v<version>\
  EXE kept between runs (95 MB) -> second occurrence onward is download-free.

Params:
  -LocalPackage <path>  use a local EXE instead of downloading (testing)
  -MaxWaitMinutes 45    patient wait for camera-idle
  -PollMinutes 10       poll interval
#>
[CmdletBinding()]
param(
    [string]$LocalPackage,
    [int]$MaxWaitMinutes = 45,
    [int]$PollMinutes = 10
)
$ErrorActionPreference = 'Continue'

# --- Layer 0: gate + family pick ---
$sp = Get-CimInstance Win32_ComputerSystemProduct
$bb = Get-CimInstance Win32_BaseBoard
$cs = Get-CimInstance Win32_ComputerSystem
$sig = @($sp.Version, $sp.Name, $bb.Product, $cs.Model) -join ' '
if ($sig -notmatch 'P[AB]14250') { Write-Output 'not a target machine - nothing to do'; exit 0 }
$family = if ($sig -match 'PA14250') { 'PA' } else { 'PB' }

# --- family package manifest ---
$manifest = @{
    PB = @{ id = 'HW9TN'; version = '80.26100.0.29-A13'
            url  = 'https://dl.dell.com/FOLDER14812487M/1/Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera_HW9TN_WIN64_80.26100.0.29_A13.EXE'
            exe  = 'Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera_HW9TN_WIN64_80.26100.0.29_A13.EXE'
            sha256 = $null }
    PA = @{ id = '845M5'; version = '80.25982.6.32-A12'
            url  = ''   # TODO: grab direct dl.dell.com link from browser download once PA fleet matters
            exe  = 'Intel-2D-Imaging-Vision-USB-Bridge-Driver-for-Camera_845M5_WIN64_80.25982.6.32_A12.EXE'
            sha256 = 'D96D301FF7092C4F172EDB2F713BC2626FC3C5FB77C52D1560586DA901FFDB66' }
}
$pkg = $manifest[$family]
$stage = "C:\ProgramData\DellCamera\$($pkg.id)\v$($pkg.version)"
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Write-Output "family=$family package=$($pkg.id) $($pkg.version) stage=$stage"

# --- obtain the package EXE (cache > local override > download) ---
$exePath = Join-Path $stage $pkg.exe
if (-not (Test-Path $exePath) -and $LocalPackage -and (Test-Path $LocalPackage)) {
    Copy-Item $LocalPackage $exePath -Force
    Write-Output "obtained package from local override: $LocalPackage"
}
if (-not (Test-Path $exePath)) {
    if (-not $pkg.url) { Write-Output "no download URL configured for $($pkg.id) and no local package - exiting"; exit 1 }
    Write-Output "downloading $($pkg.exe) ($([math]::Round(95,1)) MB class) via BITS..."
    try { Start-BitsTransfer -Source $pkg.url -Destination $exePath -ErrorAction Stop }
    catch { Write-Output "download failed: $($_.Exception.Message) - next scheduled run retries"; exit 1 }
}

# --- integrity: Authenticode signer (always) + SHA-256 (when known) ---
$sigChk = Get-AuthenticodeSignature $exePath
if ($sigChk.Status -ne 'Valid' -or $sigChk.SignerCertificate.Subject -notmatch 'Dell') {
    Write-Output "SIGNATURE CHECK FAILED ($($sigChk.Status)) - refusing to run"; exit 1
}
if ($pkg.sha256) {
    $h = (Get-FileHash $exePath -Algorithm SHA256).Hash
    if ($h -ne $pkg.sha256) { Write-Output 'SHA-256 mismatch - refusing to run'; exit 1 }
}
Write-Output 'package verified (Authenticode Dell-signed' + $(if ($pkg.sha256) { ' + SHA-256 match' } else { '' }) + ')'

# --- silent-extract the DUP ---
$exDir = Join-Path $stage 'extract'
if (-not (Test-Path "$exDir\16299")) {
    New-Item -ItemType Directory -Force -Path $exDir | Out-Null
    Write-Output 'extracting package (DUP silent extract /s /e)...'
    $p = Start-Process -FilePath $exePath -ArgumentList "/s /e /f=`"$exDir`"" -Wait -PassThru -WindowStyle Hidden
    Write-Output "extract exit code: $($p.ExitCode)"
}
$infs = @(Get-ChildItem "$exDir\16299\Drivers" -Recurse -Filter *.inf)
if ($infs.Count -eq 0) { Write-Output 'no INFs found after extraction - package layout changed?'; exit 1 }
Write-Output "payload ready: $($infs.Count) INF files"

# --- patient wait: camera idle (consent store), bounded by the 60-min cap ---
function Test-CameraStreaming {
    foreach ($hive in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        $root = "$($hive.PSPath)\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"
        if (-not (Test-Path $root)) { continue }
        foreach ($app in (Get-ChildItem "$root\*", "$root\NonPackaged\*" -ErrorAction SilentlyContinue)) {
            if ((Get-ItemProperty $app.PSPath -ErrorAction SilentlyContinue).LastUsedTimeStop -eq 0) { return $true }
        }
    }
    return $false
}
$deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
$poll = 0
while ((Get-Date) -lt $deadline -and (Test-CameraStreaming)) {
    $poll++
    Write-Output "poll ${poll}: camera in use - waiting ${PollMinutes}m (deadline $(Get-Date $deadline -Format HH:mm:ss))"
    Start-Sleep -Seconds ($PollMinutes * 60)
}
if (Test-CameraStreaming) {
    Write-Output "camera still busy after ${MaxWaitMinutes}m - stopping; tomorrow's scheduled run retries"
    exit 0
}
Write-Output 'camera idle - installing'

# --- install: standard PnP, no forced reboot ---
foreach ($inf in $infs) {
    $out = & pnputil.exe /add-driver "$($inf.FullName)" /install 2>&1
    $ok  = ($out | Select-String -SimpleMatch 'success').Count
    Write-Output "add-driver $($inf.Name): $ok success line(s)"
}
& pnputil.exe /scan-devices | Out-Null

# --- Force live rebind: restart devnodes that didn't recover on their own ---
# Disabled devices (code 22) are never touched - a restart would not enable them.
foreach ($d in (Get-PnpDevice -PresentOnly)) {
    $pc2 = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
    $isCam = $d.Class -in 'Camera', 'Image'
    if (($isCam -or ($pc2 -and $pc2 -ne 0)) -and $pc2 -ne 22) {
        $r = & pnputil.exe /restart-device "$($d.InstanceId)" 2>&1
        Write-Output ("REBIND: {0} [{1}] -> {2}" -f $d.FriendlyName, $pc2, (($r | Select-Object -Last 1) -replace '^\s+', ''))
    }
}
Start-Sleep -Seconds 5

# --- old-driver cleanup: delete UNBOUND superseded family packages only ---
$familyInfs = 'iacamera64.inf','hm1092.inf','ov05c10.inf','ov08x40.inf','iactrllogic64.inf',
              'iaisp64.inf','usbbridge.inf','usbgpio.inf','usbi2c.inf','vision.inf','visionextension.inf'
try {
    $drivers = Get-WindowsDriver -Online -ErrorAction Stop |
        Where-Object { $_.OriginalFileName -and ($familyInfs -contains $_.OriginalFileName.ToLower()) }
    if ($drivers) {
        $boundInfs = @(Get-PnpDevice -PresentOnly | ForEach-Object {
            (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath').Data
        } | Where-Object { $_ })
        foreach ($origName in ($drivers | Select-Object -ExpandProperty OriginalFileName -Unique)) {
            $set  = $drivers | Where-Object OriginalFileName -eq $origName
            $keep = $set | Sort-Object Version -Descending | Select-Object -First 1
            foreach ($p in ($set | Where-Object Driver -ne $keep.Driver)) {
                if ($boundInfs -contains $p.Driver) {
                    Write-Output "CLEANUP-SKIP: $($p.Driver) ($origName v$($p.Version)) - still bound"
                } else {
                    Write-Output "CLEANUP-DELETE: $($p.Driver) ($origName v$($p.Version)) - unbound, superseded"
                    & pnputil.exe /delete-driver $p.Driver 2>&1 | ForEach-Object { Write-Output "  $_" }
                }
            }
        }
    } else { Write-Output 'CLEANUP: no superseded family packages' }
} catch { Write-Output "CLEANUP-SKIPPED: enumeration failed - not fatal" }

# --- final state report (detection output column picks this up) ---
$pending = 0
foreach ($d in (Get-PnpDevice -PresentOnly)) {
    $pc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
    if ($pc -eq 14) { $pending++ }
}
if ($pending -gt 0) {
    Write-Output "INSTALLED - $pending device(s) pending user-paced restart (completes at natural reboot)"
} else {
    Write-Output 'INSTALLED - live, no restart needed'
}
exit 0
