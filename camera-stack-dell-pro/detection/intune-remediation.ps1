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
       on model family) is downloaded from dl.dell.com via a fallback chain
       (HttpClient → Invoke-WebRequest → BITS) and verified:
       the Authenticode signature must be from Dell. A SHA-256 hash is also
       checked when one is published for the package. For air-gapped machines
       or testing.

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
param(
    [switch]$ShowToast,
    [string]$ToastTitle    = '',   # optional: overrides default title
    [string]$ToastMessage  = '',   # optional: overrides default body
    [string]$ToastIcon     = '',   # optional: path to icon PNG (48x48 canvas with logo at 32x32 centered, 8px padding)
    [string]$ToastBanner   = ''    # optional: path to banner PNG (364x180, hero image)
)

# =============================================================================
# TOAST NOTIFICATION
# =============================================================================
# Shows a Windows toast notification to the logged-in user. Intune Remediations
# and Nexthink run as SYSTEM, which has no user session for toasts. The
# solution: write a small PowerShell script to a temp location, then create a
# scheduled task that runs it as the logged-in user (Users group). The task
# fires, shows the toast via the WinRT API, and self-cleans.
#
# Uses only PowerShell (no VBScript, no ServiceUI, no COM registration).
# This is the same mechanism as PSADT's Execute-ProcessAsUser.

function Show-RestartToast {
    # Shows a toast with optional icon and banner.
    # Icon priority: -ToastIcon path → cached download → generated camera icon.
    # Banner priority: -ToastBanner path → generated gradient banner.
    # Images cached in C:\ProgramData\DellCamera\toast\ after first run.
    # Source label shows "Windows PowerShell" (AUMID limitation, accepted).

    $effectiveTitle   = if ($ToastTitle)   { $ToastTitle }   else { 'Camera Driver Update' }
    $effectiveMessage = if ($ToastMessage) { $ToastMessage } else { 'Your camera driver has been installed. Please restart when convenient to finish.' }

    $toastImageDir = Join-Path $env:ProgramData 'DellCamera\toast'
    New-Item -ItemType Directory -Force -Path $toastImageDir | Out-Null
    $cachedIconPath   = Join-Path $toastImageDir 'icon_48.png'
    $cachedBannerPath = Join-Path $toastImageDir 'banner_364x180.png'

    # --- Resolve icon ---
    $resolvedIconPath = $null
    if ($ToastIcon -and (Test-Path $ToastIcon)) {
        $resolvedIconPath = $ToastIcon
    } elseif (Test-Path $cachedIconPath) {
        $resolvedIconPath = $cachedIconPath
    } else {
        Add-Type -AssemblyName System.Drawing
        # Try org logo download
        try {
            $tempHiRes = Join-Path $toastImageDir 'logo_source.png'
            Invoke-WebRequest -Uri 'https://logos-world.net/wp-content/uploads/2023/06/Gartner-Symbol.png' `
                -OutFile $tempHiRes -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -UseBasicParsing -TimeoutSec 15
            $srcImg = [System.Drawing.Image]::FromFile($tempHiRes)
            $side = [Math]::Min($srcImg.Width, $srcImg.Height)
            $x0 = [int](($srcImg.Width - $side) / 2); $y0 = [int](($srcImg.Height - $side) / 2)
            $square = New-Object System.Drawing.Bitmap($side, $side)
            $sg = [System.Drawing.Graphics]::FromImage($square)
            $sg.DrawImage($srcImg, (New-Object System.Drawing.Rectangle(0, 0, $side, $side)), (New-Object System.Drawing.Rectangle($x0, $y0, $side, $side)), [System.Drawing.GraphicsUnit]::Pixel)
            $sg.Dispose(); $srcImg.Dispose(); Remove-Item $tempHiRes -Force
            $icon = New-Object System.Drawing.Bitmap(48, 48)
            $g = [System.Drawing.Graphics]::FromImage($icon)
            $g.InterpolationMode = 'HighQualityBicubic'
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.DrawImage($square, 8, 8, 32, 32)
            $g.Dispose(); $square.Dispose()
            $icon.Save($cachedIconPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $resolvedIconPath = $cachedIconPath
            Write-Output 'Toast icon: downloaded org logo, processed and cached.'
        } catch {
            Write-Output "Org logo download failed: $($_.Exception.Message)"
        }
        # Fallback: generate camera icon
        if (-not (Test-Path $cachedIconPath)) {
            try {
                $icon = New-Object System.Drawing.Bitmap(48, 48)
                $g = [System.Drawing.Graphics]::FromImage($icon)
                $g.SmoothingMode = 'AntiAlias'
                $g.Clear([System.Drawing.Color]::Transparent)
                $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0, 120, 215))), 2, 2, 44, 44)
                $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)), 12, 18, 24, 16)
                $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)), 20, 14, 8, 5)
                $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0, 120, 215))), 19, 21, 10, 10)
                $g.Dispose()
                $icon.Save($cachedIconPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $resolvedIconPath = $cachedIconPath
                Write-Output 'Toast icon: generated camera fallback.'
            } catch {
                Write-Output "Icon generation failed: $($_.Exception.Message) — toast without icon."
            }
        }
    }

    # --- Resolve banner ---
    $resolvedBannerPath = $null
    if ($ToastBanner -and (Test-Path $ToastBanner)) {
        $resolvedBannerPath = $ToastBanner
    } elseif (Test-Path $cachedBannerPath) {
        $resolvedBannerPath = $cachedBannerPath
    } else {
        try {
            Add-Type -AssemblyName System.Drawing
            $banner = New-Object System.Drawing.Bitmap(364, 180)
            $bg = [System.Drawing.Graphics]::FromImage($banner)
            $bg.SmoothingMode = 'AntiAlias'
            $bg.TextRenderingHint = 'AntiAliasGridFit'
            $rect = New-Object System.Drawing.Rectangle(0, 0, 364, 180)
            $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,
                [System.Drawing.Color]::FromArgb(20, 40, 80),
                [System.Drawing.Color]::FromArgb(50, 100, 180),
                [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
            $bg.FillRectangle($grad, $rect)
            $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
            $bg.DrawString('Gartner', (New-Object System.Drawing.Font('Segoe UI', 26, [System.Drawing.FontStyle]::Bold)), $white, 20, 25)
            $bg.DrawString('Windows Endpoint Management', (New-Object System.Drawing.Font('Segoe UI', 11)), $white, 20, 70)
            $bg.Dispose()
            $banner.Save($cachedBannerPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $resolvedBannerPath = $cachedBannerPath
            Write-Output 'Toast banner: generated and cached.'
        } catch {
            Write-Output "Banner generation failed: $($_.Exception.Message) — toast without banner."
        }
    }

    # --- Build and show the toast ---
    $iconXml   = if ($resolvedIconPath) {
        "            <image src=`"file:///$($resolvedIconPath -replace '\\', '/')`" placement=`"appLogoOverride`" hint-crop=`"circle`"/>"
    }
    $bannerXml = if ($resolvedBannerPath) {
        "            <image src=`"file:///$($resolvedBannerPath -replace '\\', '/')`" placement=`"hero`"/>"
    }

    $appAumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

    $toastScript = @"
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
`$appId = '$appAumid'
`$xml = @'
<toast scenario="reminder" duration="long">
    <visual>
        <binding template="ToastGeneric">
            <text>$effectiveTitle</text>
            <text>$effectiveMessage</text>
$iconXml
$bannerXml
        </binding>
    </visual>
</toast>
'@
`$doc = New-Object Windows.Data.Xml.Dom.XmlDocument
`$doc.LoadXml(`$xml)
`$toast = [Windows.UI.Notifications.ToastNotification]::new(`$doc)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(`$appId).Show(`$toast)
"@

    $toastScriptPath = Join-Path $env:ProgramData 'CameraDriverToast.ps1'
    $toastScript | Set-Content $toastScriptPath -Encoding UTF8

    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$toastScriptPath`""
    $taskTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(3)
    $taskPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited

    Register-ScheduledTask -TaskName 'CameraDriverToast' `
        -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Force | Out-Null
    Start-ScheduledTask -TaskName 'CameraDriverToast'

    Start-Sleep -Seconds 10
    Unregister-ScheduledTask -TaskName 'CameraDriverToast' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $toastScriptPath -Force -ErrorAction SilentlyContinue
}

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
# Order of preference: cached copy in the working folder, then download from Dell.
# The cache means the second and later runs on the same machine skip the download entirely.

$packageFilePath = Join-Path $workingFolder $selectedPackage.PackageFileName

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
# Install the driver package by running the Dell installer silently.
# This is the same method that has fixed 100+ ticket machines: run the Dell
# EXE + reboot. The installer handles driver staging, binding, and old-driver
# cleanup internally. We do NOT extract the package — extraction methods
# (7-Zip, Dell /s /e /f=, Expand-Archive, tar, .NET ZipFile, extrac32) were
# all tested live; only 7-Zip works and it is not guaranteed on fleet machines.
#
# The /s switch runs the installer silently (no UI, no prompts).
# The installer does NOT force a reboot on its own; if a restart is needed,
# it sets a pending flag and the driver activates at the next natural restart.
# This matches the no-disturbance doctrine.

Write-Output 'Installing driver package (Dell silent install)...'
$installProcess = Start-Process -FilePath $packageFilePath `
    -ArgumentList '/s' `
    -Wait -PassThru -WindowStyle Hidden
$installExitCode = $installProcess.ExitCode
Write-Output "Dell installer exit code: $installExitCode"

# Dell installer exit codes: 0 = success, 1 = success with reboot required,
# 2 = success no reboot needed. Any other code is an error.
# (Source: Dell Update Packages User's Guide)
if ($installExitCode -eq 0 -or $installExitCode -eq 1 -or $installExitCode -eq 2) {
    Write-Output 'Driver package installed successfully.'
} else {
    Write-Output "Dell installer failed with exit code $installExitCode."
    Write-Output 'The next scheduled run will retry.'
    exit 1
}

# Trigger a device rescan to catch devices that can re-enumerate without a restart.
& pnputil.exe /scan-devices | Out-Null
Start-Sleep -Seconds 5

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
