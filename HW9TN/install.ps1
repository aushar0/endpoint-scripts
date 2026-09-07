<#
install.ps1 - HW9TN A13 camera stack installer for Intune Win32 deployment
Payload layout expected next to this file:
    .\Drivers\x64\...        (copied from extract\16299\Drivers at package time)
Fully portable: all paths are $PSScriptRoot-relative. No user-profile paths.

Exit codes:
    0    = installed (or already current), no reboot needed
    3010 = installed, device restart required (MSI convention; Intune honors it
           when app restart behavior is configured)
    1618 = camera busy past the wait window - Intune FAST RETRY (not a failure)
#>
[CmdletBinding()]
param(
    [int]$MaxWaitMinutes = 45,    # short window: Intune's 60-min default timeout never
                                  # bites; 1618-retry carries long-term patience
    [int]$PollMinutes = 10
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP "HW9TN_install_$(Get-Date -Format yyyyMMdd_HHmmss).log"
Start-Transcript -Path $log -Force | Out-Null

try {
    # --- Layer 0: hardware gate (self-contained, no external refs) ---
    $sp = Get-CimInstance Win32_ComputerSystemProduct
    $bb = Get-CimInstance Win32_BaseBoard
    $cs = Get-CimInstance Win32_ComputerSystem
    $sig = @($sp.Version, $sp.Name, $bb.Product, $cs.Model) -join ' '
    if ($sig -notmatch 'PB14250') {
        Write-Output "Not applicable - no PB14250 SMBIOS signature [$sig]"
        Stop-Transcript | Out-Null; exit 0
    }

    # --- Patient wait: defer only while the CAMERA IS ACTUALLY STREAMING ---
    # Not "is Teams open" - tray apps idle forever; that would never finish.
    # No prompts, no closing, no UI: poll ConsentStore (LastUsedTimeStop = 0
    # = streaming) until idle, bounded by -MaxWaitMinutes; then defer to retry.
    # Lock screen / user idle are not tested - they are just moments when this
    # condition resolves; locked-on-a-call correctly reads busy.
    $camHolders = @()
    function Test-CameraStreaming {
        foreach ($hive in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
            $camRoot = "$($hive.PSPath)\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"
            if (-not (Test-Path $camRoot)) { continue }
            foreach ($app in (Get-ChildItem "$camRoot\*", "$camRoot\NonPackaged\*" -ErrorAction SilentlyContinue)) {
                $stop = (Get-ItemProperty $app.PSPath -ErrorAction SilentlyContinue).LastUsedTimeStop
                if ($stop -eq 0) { $script:camHolders = @($app.PSChildName); return $true }
            }
        }
        return $false
    }
    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    $poll = 0
    while ((Get-Date) -lt $deadline) {
        $poll++
        if (-not (Test-CameraStreaming)) {
            Write-Output "Camera idle after $poll poll(s) at $(Get-Date -Format HH:mm:ss) - proceeding"
            break
        }
        Write-Output ("Poll ${poll}: camera in use by [{0}] - waiting {1}m (deadline {2})" -f `
            ($camHolders -join ';'), $PollMinutes, (Get-Date $deadline -Format HH:mm:ss))
        Start-Sleep -Seconds ($PollMinutes * 60)
    }
    if ((Get-Date) -ge $deadline -and (Test-CameraStreaming)) {
        # 1618 = Intune "Fast retry": recorded as RETRY, not failure - the app
        # re-runs on Intune's own cadence. Patience across cycles, zero red X's.
        Write-Output "Camera still in use after ${MaxWaitMinutes}m - exiting 1618 (Intune fast-retry)"
        Stop-Transcript | Out-Null; exit 1618
    }

    # --- Install: standard PnP path, no forced reboot ---
    $drivers = Join-Path $PSScriptRoot 'Drivers\x64'
    if (-not (Test-Path "$drivers\*.inf")) {
        Write-Error "Payload missing: $drivers - package built wrong"
        Stop-Transcript | Out-Null; exit 1
    }
    Write-Output "Staging + installing drivers from $drivers"
    $pnputil = & pnputil.exe /add-driver "$drivers\*.inf" /subdirs /install 2>&1
    $pnputil | ForEach-Object { Write-Output "  $_" }
    $okCount = ($pnputil | Select-String -SimpleMatch 'Driver package added successfully').Count
    $instCount = ($pnputil | Select-String -SimpleMatch 'Driver package installed successfully').Count
    Write-Output "Added: $okCount   Installed-on-device: $instCount"

    # Trigger re-enumeration so staged drivers bind to any raw/failing devices now
    & pnputil.exe /scan-devices | Out-Null

    # --- Post-install: does anything still demand a restart? ---
    Start-Sleep -Seconds 5
    $targetRe = 'VEN_8086&DEV_(7D51|7DD1|7D41|7D67|B640|64A0|6420|64B0|7D19|645D|5A19).*INT3480|' +
                'VEN_HIMX&DEV_1092|VEN_OVTI&DEV_(05C1|08F4)|VEN_INT&DEV_(3472|346F)|' +
                'VID_8086&PID_0B63|VID_2AC1&PID_20C[19B]|VID_06CB&PID_0701|INTC10B5|INTC10B6|INTC10E0|INTC10DE'
    $needRestart = $false
    foreach ($d in (Get-PnpDevice -PresentOnly)) {
        $hw = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds').Data
        if (-not $hw -or (($hw -join ';') -notmatch $targetRe)) { continue }
        $pc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
        Write-Output "Post-install: $($d.FriendlyName) problem code = $pc"
        if ($pc -eq 14 -or $pc -eq 25) { $needRestart = $true }   # NEED_RESTART / device-assigned-failure
    }

    if ($needRestart) {
        # NO forced restart, ever (unsaved-work rule). Device keeps running on the
        # old driver until the user's next natural reboot; new stack activates then.
        # Estate visibility for this state = PR monitor seeing problem code 14.
        Write-Output 'PENDING-RESTART (user-paced) - restart required to finish initialization'
        Write-Output 'Intune app restart behavior MUST be set to: Nothing'
        Stop-Transcript | Out-Null; exit 3010
    }
    Write-Output 'Exit 0 - installed, no restart required'
    Stop-Transcript | Out-Null; exit 0
}
catch {
    Write-Output "INSTALL-ERROR: $($_.Exception.Message)"
    Stop-Transcript | Out-Null
    exit 1
}
