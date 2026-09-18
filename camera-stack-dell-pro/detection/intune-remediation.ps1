<#
.SYNOPSIS
    Installs the Intel camera driver stack and attempts live device recovery.

.DESCRIPTION
    This script is the remediation half of an Intune Remediations package.
    It runs only after the detection script (intune-detection.ps1) exits 1,
    meaning the camera is broken: a device has a nonzero problem code, or
    no camera devices are present at all.

    PRIMARY SCENARIO: the camera vanished. The Intel ISP (Image Signal
    Processor) wedges during a power-state transition, causing the camera
    device to stop enumerating. The camera disappears from Device Manager;
    Teams and the Windows Camera app report no camera found. The fix
    requires the driver staged (this script installs it) plus a device
    rescan or reboot to re-enumerate the vanished node.

    The script attempts live recovery first: install the driver, rescan
    devices, restart problem devices. If the camera comes back, it is
    fixed without a restart. If not, the script exits 3010 (restart
    pending) and the camera returns at the user next reboot.

    When no camera device is present, the camera-idle wait passes
    instantly because nothing is streaming.

    Intune imposes a 60-minute hard timeout on remediation scripts. This
    script's phases are budgeted to fit within that window:

        Package download (~5 min)
        Camera idle wait (45 min default, configurable)
        Driver installation (~2 min)
        Driver-store cleanup (~1 min)

    If the camera stays in use for the entire wait window, the script exits
    without making any changes. The next scheduled run retries; the daily
    recurrence is the retry mechanism.

    The script never prompts, never closes applications, and never forces a
    restart. If a device needs a restart to finish initialization, the script
    exits with code 3010 (success, restart pending) and the restart happens
    at the user's own discretion.

.NOTES
    File name          : intune-remediation.ps1
    Requires           : Windows 11, PowerShell 5.1+, administrator (Intune
                         Remediations runs as SYSTEM by default)
    Run frequency      : Same schedule as the detection script
    Paired with        : intune-detection.ps1
    Exit code 3010     : Installed successfully; one or more devices finish
                         initialization at the next restart. The old driver
                         keeps the camera working until then.
    Driver package     : Downloaded from Dell at run time; never committed
                         to the repository.

.HOW IT WORKS
    1. Hardware gate. Same as the detection script: only Dell Pro models
       PB14250 and PA14250 proceed. Everything else exits silently.

    2. Camera idle wait. The script polls the Windows CapabilityAccessManager
       consent store (~registry) to determine whether any application is
       actively streaming the camera. A camera in use means the driver stack
       is live and must not be touched. A laptop that is on a call, locked
       while on a call, or has any camera-consuming app open will wait.
       A tray-idle Teams instance does not count (it is not streaming).

    3. Package acquisition. The Dell driver package (HW9TN or 845M5 depending
       on model family) is downloaded from dl.dell.com via HttpClient and verified:
       the Authenticode signature must be from Dell. A SHA-256 hash is also
       checked when one is published for the package. For air-gapped machines
       or testing, the -LocalPackage parameter points to a local copy.

    4. Extraction. The Dell Update Package is silently extracted using its
       built-in /s /e switches, yielding the raw driver INF files.

    5. Installation. Each INF is staged and installed via pnputil
       (/add-driver /install). This is the standard Windows PnP installation
       path; no vendor installer runs. A device rescan follows.

    6. Rebind recovery. Devices that did not recover on their own after the
       rescan are explicitly restarted via pnputil /restart-device. This
       catches devices that need a nudge to pick up the new driver without
       requiring a full restart. Devices disabled by user choice (problem
       code 22) are never touched.

    7. Cleanup. Superseded driver packages (same INF name, older version,
       no device bound to them) are removed from the driver store. This is
       the hygiene step that prevents the mixed-generation residue left by
       Windows feature updates - the condition Dell's KB 000248760 identifies
       as the root cause of these camera failures.

    8. Verification. The script checks whether the camera is now present and
       healthy. If any device still reports a problem, the Windows
       setupapi.dev.log is filtered to camera-related entries and saved as
       forensic evidence for troubleshooting.

.LINK
    Dell KB 000248760: https://www.dell.com/support/kbdoc/en-us/000248760/
#>

# =============================================================================
# PARAMETERS
# =============================================================================

# Path to a local copy of the driver package EXE, used instead of downloading.
# For air-gapped machines or manual testing.
param([string]$LocalPackage = '', [switch]$ShowToast)

# Minutes to wait for the camera to become idle before giving up.
# Default 45; the Intune Remediations 60-minute cap allows ~50 minutes
# of waiting plus ~10 minutes for the remaining phases.
[Int]$MaxWaitMinutes = 45

# Minutes between camera-in-use checks during the wait.
[Int]$PollMinutes = 10

# =============================================================================
# INITIALIZATION
# =============================================================================

$ErrorActionPreference = 'Continue'

# =============================================================================
# HARDWARE GATE
# =============================================================================

$systemProduct  = Get-CimInstance Win32_ComputerSystemProduct
$baseBoard      = Get-CimInstance Win32_BaseBoard
$computerSystem = Get-CimInstance Win32_ComputerSystem
$modelSignature = @($systemProduct.Version, $systemProduct.Name, $baseBoard.Product, $computerSystem.Model) -join ' '

if ($modelSignature -notmatch 'P[AB]14250') {
    Write-Output 'Not a supported model. Nothing to do.'
    exit 0
}

$modelFamily = if ($modelSignature -match 'PA14250') { 'PA' } else { 'PB' }

# =============================================================================
# PACKAGE MANIFEST
# =============================================================================
# Each family has one driver package. The URL is the direct Dell download link.
# SHA-256 is checked when Dell publishes one for the package.

$packageManifest = @{
    PB = @{
        PackageId      = 'HW9TN'
        PackageVersion = '80.26100.0.29-A13'
        DownloadUrl    = 'https://dl.dell.com/FOLDER14812487M/1/Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera_HW9TN_WIN64_80.26100.0.29_A13.EXE'
        PackageFileName = 'Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera_HW9TN_WIN64_80.26100.0.29_A13.EXE'
        Sha256Hash     = $null
    }
    PA = @{
        PackageId      = '845M5'
        PackageVersion = '80.25982.6.32-A12'
        DownloadUrl    = ''
        PackageFileName = 'Intel-2D-Imaging-Vision-USB-Bridge-Driver-for-Camera_845M5_WIN64_80.25982.6.32_A12.EXE'
        Sha256Hash     = 'D96D301FF7092C4F172EDB2F713BC2626FC3C5FB77C52D1560586DA901FFDB66'
    }
}

# Camera-stack INF file names - used by the cleanup phase to identify which
# driver-store packages belong to this deployment and are safe to remove.
$cameraStackInfNames = @(
    'iacamera64.inf', 'hm1092.inf', 'ov05c10.inf', 'ov08x40.inf', 'iactrllogic64.inf',
    'iaisp64.inf', 'usbbridge.inf', 'usbgpio.inf', 'usbi2c.inf', 'vision.inf', 'visionextension.inf'
)

# Hardware-ID patterns for identifying stack devices during the rebind and
# verification phases (same patterns as the detection script).
$cameraStackHardwareIdPattern = 'VEN_8086&DEV_(7D51|7DD1|7D41|7D67|B640|64A0|6420|64B0|7D19|645D|5A19).*INT3480|VEN_HIMX&DEV_1092|VEN_OVTI&DEV_(05C1|08F4)|VEN_INT&DEV_(3472|346F)|VID_8086&PID_0B63|VID_2AC1&PID_20C[19B]|VID_06CB&PID_0701|INTC10B5|INTC10B6|INTC10E0|INTC10DE'

# Working folder: the extracted package, download cache, and logs all live here.
$selectedPackage = $packageManifest[$modelFamily]
$workingFolder = "C:\ProgramData\DellCamera\$($selectedPackage.PackageId)\v$($selectedPackage.PackageVersion)"
New-Item -ItemType Directory -Force -Path $workingFolder | Out-Null
Write-Output "Model family: $modelFamily | Package: $($selectedPackage.PackageId) v$($selectedPackage.PackageVersion)"
Write-Output "Working folder: $workingFolder"

# =============================================================================
# PACKAGE ACQUISITION
# =============================================================================
# Order of preference: cached copy in the working folder, local override via
# -LocalPackage, then download from Dell. The cache means the second and later
# runs on the same machine skip the download entirely.

$packageFilePath = Join-Path $workingFolder $selectedPackage.PackageFileName

if (-not (Test-Path $packageFilePath) -and $LocalPackage -and (Test-Path $LocalPackage)) {
    Copy-Item $LocalPackage $packageFilePath -Force
    Write-Output "Using local package copy: $LocalPackage"
}

if (-not (Test-Path $packageFilePath)) {
    if (-not $selectedPackage.DownloadUrl) {
        Write-Output "No download URL configured for package $($selectedPackage.PackageId). Exiting."
        exit 1
    }
    Write-Output "Downloading $($selectedPackage.PackageFileName)..."
    # Download with fallback chain: HttpClient → Invoke-WebRequest → BITS.
    # HttpClient is preferred but corporate proxies and SSL inspection can
    # cause 403 Forbidden on some networks. Invoke-WebRequest routes through
    # the WinHTTP proxy stack. BITS routes through Windows' own transfer
    # service and handles corporate proxies, authentication, and throttling
    # automatically.
    $downloadSucceeded = $false

    # --- Method 1: HttpClient with User-Agent ---
    try {
        Add-Type -AssemblyName System.Net.Http
        $httpClient = [System.Net.Http.HttpClient]::new()
        $httpClient.Timeout = [TimeSpan]::FromMinutes(10)
        $httpClient.DefaultRequestHeaders.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
        $httpResponse = $httpClient.GetAsync($selectedPackage.DownloadUrl, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $httpResponse.EnsureSuccessStatusCode()
        $downloadStream = $httpResponse.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fileStream = [System.IO.File]::Create($packageFilePath)
        $buffer = New-Object byte[] 81920
        while (($bytesRead = $downloadStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $bytesRead)
        }
        $fileStream.Close()
        $downloadStream.Close()
        $httpClient.Dispose()
        $downloadSucceeded = $true
        Write-Output 'Download complete (HttpClient).'
    } catch {
        Write-Output "HttpClient download failed: $($_.Exception.Message)"
    }

    # --- Method 2: Invoke-WebRequest with User-Agent ---
    if (-not $downloadSucceeded) {
        Write-Output 'Trying Invoke-WebRequest...'
        try {
            Invoke-WebRequest -Uri $selectedPackage.DownloadUrl -OutFile $packageFilePath `
                -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -UseBasicParsing -TimeoutSec 600
            $downloadSucceeded = $true
            Write-Output 'Download complete (Invoke-WebRequest).'
        } catch {
            Write-Output "Invoke-WebRequest download failed: $($_.Exception.Message)"
        }
    }

    # --- Method 3: BITS (handles corporate proxies, authentication, throttling) ---
    if (-not $downloadSucceeded) {
        Write-Output 'Trying BITS transfer...'
        try {
            Start-BitsTransfer -Source $selectedPackage.DownloadUrl -Destination $packageFilePath -ErrorAction Stop
            $downloadSucceeded = $true
            Write-Output 'Download complete (BITS).'
        } catch {
            Write-Output "BITS download failed: $($_.Exception.Message)"
        }
    }

    if (-not $downloadSucceeded) {
        Write-Output 'All download methods failed. The next scheduled run will retry.'
        exit 1
    }
}

# Verify the package before running it: the Authenticode signature must be
# from Dell. When a SHA-256 hash is known, verify that too.
$signatureCheck = Get-AuthenticodeSignature $packageFilePath
if ($signatureCheck.Status -ne 'Valid' -or $signatureCheck.SignerCertificate.Subject -notmatch 'Dell') {
    Write-Output "Package signature verification FAILED ($($signatureCheck.Status)). Refusing to run."
    exit 1
}
if ($selectedPackage.Sha256Hash) {
    $actualHash = (Get-FileHash $packageFilePath -Algorithm SHA256).Hash
    if ($actualHash -ne $selectedPackage.Sha256Hash) {
        Write-Output 'Package SHA-256 hash mismatch. Refusing to run.'
        exit 1
    }
}
Write-Output 'Package verified (Dell-signed).'

# =============================================================================
# PACKAGE EXTRACTION
# =============================================================================
# Extract the driver package. The Dell /s /e /f= switch was tested live and
# produces ZERO files when run from a user context (exit code 1). 7-Zip
# reliably extracts the package (241 files, 18 INFs, verified live). The Dell
# switch is kept as a fallback because it may behave differently when Intune
# Remediations runs as SYSTEM (elevated), which we cannot test from a user
# context.

$extractionFolder = Join-Path $workingFolder 'extract'

# Check if we already have extracted INF files (cache from a previous run)
$cachedInfFiles = @(Get-ChildItem $extractionFolder -Recurse -Filter *.inf -ErrorAction SilentlyContinue)

if ($cachedInfFiles.Count -eq 0) {
    New-Item -ItemType Directory -Force -Path $extractionFolder | Out-Null
    $extractionSucceeded = $false

    # --- Method 1: 7-Zip (verified to work; available on most fleet machines) ---
    $sevenZipPath = @(
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($sevenZipPath) {
        Write-Output "Extracting via 7-Zip ($sevenZipPath)..."
        $extractResult = & $sevenZipPath x -y -o"$extractionFolder" $packageFilePath 2>&1
        $extractExit = $LASTEXITCODE
        $extractedInfs = @(Get-ChildItem $extractionFolder -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
        if ($extractExit -eq 0 -and $extractedInfs.Count -gt 0) {
            $extractionSucceeded = $true
            Write-Output "Extraction complete (7-Zip): $($extractedInfs.Count) INF files."
        } else {
            Write-Output "7-Zip extraction failed (exit $extractExit, $($extractedInfs.Count) INFs found)."
        }
    }

    # --- Method 2: Dell silent extraction (may work as SYSTEM; failed as user) ---
    if (-not $extractionSucceeded) {
        Write-Output 'Trying Dell silent extraction (/s /e /f=)...'
        $extractionProcess = Start-Process -FilePath $packageFilePath `
            -ArgumentList "/s /e /f=`"$extractionFolder`"" `
            -Wait -PassThru -WindowStyle Hidden
        $extractedInfs = @(Get-ChildItem $extractionFolder -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
        if ($extractionProcess.ExitCode -eq 0 -and $extractedInfs.Count -gt 0) {
            $extractionSucceeded = $true
            Write-Output "Extraction complete (Dell): $($extractedInfs.Count) INF files."
        } else {
            Write-Output "Dell extraction failed (exit $($extractionProcess.ExitCode), $($extractedInfs.Count) INFs found)."
        }
    }

    if (-not $extractionSucceeded) {
        Write-Output 'All extraction methods failed.'
        $topLevel = @(Get-ChildItem $extractionFolder -ErrorAction SilentlyContinue)
        if ($topLevel.Count -gt 0) {
            Write-Output 'Extraction folder contents:'
            $topLevel | Select-Object -First 10 | ForEach-Object { Write-Output "  $($_.Name)" }
        } else {
            Write-Output 'Extraction folder is empty.'
        }
        exit 1
    }
}

# Search recursively for INF files (works regardless of internal folder structure)
$driverInfFiles = @(Get-ChildItem $extractionFolder -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
if ($driverInfFiles.Count -eq 0) {
    Write-Output 'No INF files found after extraction.'
    exit 1
}
Write-Output "Driver payload ready: $($driverInfFiles.Count) INF files."


# =============================================================================
# CAMERA IDLE WAIT
# =============================================================================
# Poll the Windows CapabilityAccessManager consent store to determine whether
# any application is actively streaming the camera. The registry value
# LastUsedTimeStop is 0 while an app is streaming and a timestamp when it
# stops. This is the same mechanism Windows uses for the camera-in-use
# indicator, so it catches every application: Teams, Zoom, WebEx, Chrome,
# Edge, the Windows Camera app, and anything else.
#
# A laptop that is on a call will wait. A locked laptop that is still on a
# call will wait (the call continues at the lock screen). A laptop with Teams
# idling in the system tray will NOT wait (Teams is not streaming).
#
# This is the core of the no-disturbance design: never touch a driver stack
# that is actively serving a camera stream.

function Show-RestartToast {
    # Displays a Windows toast notification to the logged-in user suggesting
    # they restart to complete the camera driver installation. Runs in the
    # user session via a temporary scheduled task (required because Intune
    # Remediations executes as SYSTEM, and toasts must come from the user).
    $toastCommand = '[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null; '
    $toastCommand += '[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null; '
    $toastCommand += '`$xml = New-Object Windows.Data.Xml.Dom.XmlDocument; '
    $toastCommand += "`$xml.LoadXml('<toast scenario=`"reminder`"><visual><binding template=`"ToastGeneric`"><text>Camera Driver Update</text><text>Your camera driver has been installed. Please restart when convenient to finish.</text></binding></visual></toast>'); "
    $toastCommand += '`$toast = [Windows.UI.Notifications.ToastNotification]::new(`$xml); '
    $toastCommand += '[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Camera Driver").Show(`$toast)'

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `"$toastCommand`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(3)
    $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    Register-ScheduledTask -TaskName 'CameraDriverToast' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName 'CameraDriverToast'
    Start-Sleep -Seconds 10
    Unregister-ScheduledTask -TaskName 'CameraDriverToast' -Confirm:$false -ErrorAction SilentlyContinue
}

function Test-DeviceInUse {
    # Checks whether any application is actively using the camera OR microphone
    # via the Windows CapabilityAccessManager consent store. The registry value
    # LastUsedTimeStop is 0 while an app is streaming and a timestamp when it
    # stops. This catches Teams, Zoom, WebEx, Chrome, Edge, Discord, and anything
    # else that uses the camera or microphone.
    #
    # Checking the microphone catches audio-only calls (camera off) so the
    # remediation never runs during any type of call, even though camera driver
    # installation technically does not affect the audio path.
    foreach ($userHive in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        foreach ($sensorType in 'webcam', 'microphone') {
            $consentStorePath = "$($userHive.PSPath)\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$sensorType"
            if (-not (Test-Path $consentStorePath)) { continue }
            foreach ($appEntry in (Get-ChildItem "$consentStorePath\*", "$consentStorePath\NonPackaged\*" -ErrorAction SilentlyContinue)) {
                if ((Get-ItemProperty $appEntry.PSPath -ErrorAction SilentlyContinue).LastUsedTimeStop -eq 0) {
                    $script:deviceInUseBy = "{0}:{1}" -f $sensorType, $appEntry.PSChildName
                    return $true
                }
            }
        }
    }
    return $false
}

$waitDeadline = (Get-Date).AddMinutes($MaxWaitMinutes)
$pollAttempt  = 0

while ((Get-Date) -lt $waitDeadline -and (Test-DeviceInUse)) {
    $pollAttempt++
    Write-Output "Camera or microphone in use ($deviceInUseBy). Waiting ${PollMinutes} minutes (attempt $pollAttempt)."
    Start-Sleep -Seconds ($PollMinutes * 60)
}

if (Test-DeviceInUse) {
    Write-Output "Camera or microphone stayed in use for the full ${MaxWaitMinutes} minutes. No changes made."
    Write-Output 'The next scheduled run will retry.'
    exit 0
}
Write-Output 'Camera and microphone are idle. Proceeding with installation.'

# =============================================================================
# DRIVER INSTALLATION
# =============================================================================
# Stage and install every INF in the extracted package via the standard
# Windows PnP path. The /install flag attempts to bind matching present
# devices immediately; devices that cannot rebind live will be handled by
# the rebind phase below or will finalize at the next restart.

$successfullyInstalled = 0
foreach ($infFile in $driverInfFiles) {
    $installResult = & pnputil.exe /add-driver "$($infFile.FullName)" /install 2>&1
    $successLines = ($installResult | Select-String -SimpleMatch 'success').Count
    if ($successLines -gt 0 -or $LASTEXITCODE -eq 0) { $successfullyInstalled++ }
}
Write-Output "Installed $successfullyInstalled of $($driverInfFiles.Count) driver packages."

# Trigger a device rescan so newly staged drivers can bind to any raw or
# recently enumerated devices.
& pnputil.exe /scan-devices | Out-Null
Start-Sleep -Seconds 5

# =============================================================================
# REBIND RECOVERY
# =============================================================================
# Some devices do not pick up the new driver after a rescan alone. Restarting
# the device node forces a driver re-evaluation without requiring a full
# system restart. This catches the "camera present but still on old driver"
# case and converts it from "reboot required" to "fixed live."
#
# Devices disabled by user choice (problem code 22) are excluded: restarting
# them would not enable them (a driver update does not override a deliberate
# disable), and the restart would be unnecessary churn.

foreach ($presentDevice in (Get-PnpDevice -PresentOnly)) {
    $deviceProblemCode = (Get-PnpDeviceProperty -InstanceId $presentDevice.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
    $isCameraClass = $presentDevice.Class -in 'Camera', 'Image'

    if (($isCameraClass -or ($deviceProblemCode -and $deviceProblemCode -ne 0)) -and $deviceProblemCode -ne 22) {
        & pnputil.exe /restart-device "$($presentDevice.InstanceId)" 2>&1 | Out-Null
    }
}

# =============================================================================
# DRIVER-STORE CLEANUP
# =============================================================================
# Windows feature updates leave superseded driver packages in the store.
# Over time this residue creates the mixed-generation stack that Dell's
# KB 000248760 identifies as the root cause of camera failures.
#
# Safe deletion rules:
#   1. Only camera-stack INF names are considered (the list above).
#   2. Per INF name, the highest-version package is always kept; only older
#      versions are candidates for deletion. This means the just-installed
#      package is never removed, even while it is unbound during a pending
#      restart.
#   3. A package that any present device is actively using is skipped. It
#      becomes eligible at the next run after the device moves off it.

$deletedPackages  = @()
$skippedPackages  = @()

try {
    $allDriverPackages = Get-WindowsDriver -Online -ErrorAction Stop |
        Where-Object { $_.OriginalFileName -and ($cameraStackInfNames -contains $_.OriginalFileName.ToLower()) }

    if ($allDriverPackages) {
        # Build the set of INF files that present devices are currently bound to.
        $boundInfFiles = @(Get-PnpDevice -PresentOnly | ForEach-Object {
            (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath').Data
        } | Where-Object { $_ })

        foreach ($infName in ($allDriverPackages | Select-Object -ExpandProperty OriginalFileName -Unique)) {
            $packagesWithThisInf = $allDriverPackages | Where-Object OriginalFileName -eq $infName
            $newestPackage = $packagesWithThisInf | Sort-Object Version -Descending | Select-Object -First 1

            foreach ($olderPackage in ($packagesWithThisInf | Where-Object Driver -ne $newestPackage.Driver)) {
                if ($boundInfFiles -contains $olderPackage.Driver) {
                    $skippedPackages += "$($olderPackage.Driver) ($infName v$($olderPackage.Version)) - still in use"
                } else {
                    & pnputil.exe /delete-driver $olderPackage.Driver 2>&1 | Out-Null
                    $deletedPackages += "$($olderPackage.Driver) ($infName v$($olderPackage.Version))"
                }
            }
        }
    }
} catch {
    Write-Output "Driver-store enumeration failed. Cleanup skipped (not fatal)."
}

Write-Output ("Cleanup: {0} superseded package(s) removed, {1} retained (still in use)." -f `
    $deletedPackages.Count, $skippedPackages.Count)

# =============================================================================
# VERIFICATION
# =============================================================================
# Confirm the camera is now present and healthy. On problems, capture the
# camera-related entries from setupapi.dev.log as forensic evidence.

$cameraDevicesAfterInstall = @(Get-PnpDevice -Class Camera,Image -PresentOnly)
$devicesPendingRestart     = 0
$devicesStillFailing       = 0

foreach ($presentDevice in (Get-PnpDevice -PresentOnly)) {
    $hardwareIds = (Get-PnpDeviceProperty -InstanceId $presentDevice.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds').Data
    if (-not $hardwareIds -or (($hardwareIds -join ';') -notmatch $cameraStackHardwareIdPattern)) { continue }

    $problemCode = (Get-PnpDeviceProperty -InstanceId $presentDevice.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
    if ($problemCode -eq 14) { $devicesPendingRestart++ }
    if ($problemCode -and $problemCode -ne 0 -and $problemCode -ne 14) { $devicesStillFailing++ }
}

Write-Output ("Camera devices present: {0} | Pending restart: {1} | Still failing: {2}" -f `
    $cameraDevicesAfterInstall.Count, $devicesPendingRestart, $devicesStillFailing)

# If any device is still failing, capture forensic evidence from the Windows
# driver-install history log.
if ($devicesStillFailing -gt 0 -or $cameraDevicesAfterInstall.Count -eq 0) {
    $setupapiSlicePath = Join-Path $workingFolder 'setupapi_camera_slice.log'
    Select-String -Path 'C:\Windows\INF\setupapi.dev.log' `
        -Pattern 'iacamera|hm1092|ov08x40|ov05c10|iactrllogic|iaisp|usbbridge|Vision\.inf' `
        -ErrorAction SilentlyContinue |
        ForEach-Object { "{0}: {1}" -f $_.LineNumber, $_.Line } |
        Set-Content $setupapiSlicePath -Encoding UTF8
    Write-Output "Forensic evidence saved to: $setupapiSlicePath"
}

# =============================================================================
# EXIT CODE
# =============================================================================

if ($devicesPendingRestart -gt 0 -or $devicesStillFailing -gt 0) {
    Write-Output "Installed. $devicesPendingRestart device(s) finalize at the next restart."
    Write-Output 'The restart belongs to the user; it is never forced.'
    if ($ShowToast) {
        try { Show-RestartToast } catch { Write-Output "Toast notification failed: $($_.Exception.Message) (not fatal)" }
    }
    exit 3010
}

Write-Output 'Installed. Camera stack updated; no restart required.'
exit 0
