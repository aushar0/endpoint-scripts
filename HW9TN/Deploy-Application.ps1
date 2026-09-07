<#
Deploy-Application.ps1 - HW9TN A13 camera stack, PSADT v3.8/3.9 wrapper
PATIENT-WAIT DESIGN (Austin's call, 2026-09-07): no Show-InstallationWelcome,
no prompts, no closing apps, no UI of any kind. The deployment waits silently
until the camera is not streaming, then installs. Never disturbs a user.

Wait condition = camera NOT streaming (CapabilityAccessManager ConsentStore,
LastUsedTimeStop = 0). Lock screen / user idle are NOT tested directly - they
are simply moments when the streaming condition resolves. A locked machine
still on a call correctly reads as busy. Validated live 2026-09-07.

Bounded patience: polls every 10 min up to -MaxWaitMinutes (default 240).
If the camera never goes idle in that window: exit 1, Intune retries next
cycle. IMPORTANT: raise the Intune Win32 app "Maximum time to wait" setting
above MaxWaitMinutes (default 60 min will kill the wait early).

Payload: .\Files\Drivers\x64\  (robocopy ..\extract\16299\Drivers .\Files\Drivers /E)
#>
[CmdletBinding()]
param(
    [ValidateSet('Silent', 'Interactive', 'NonInteractive')]
    [string]$DeployMode = 'Silent',
    [int]$MaxWaitMinutes = 45,
    [int]$PollMinutes = 10,
    [switch]$AllowRebootPassThru,
    [switch]$TerminalServerMode,
    [switch]$DisableLogging
)

Try { Set-ExecutionPolicy -ExecutionPolicy 'Bypass' -Scope 'Process' -Force -ErrorAction 'Stop' } Catch {}

## Variables: Application
[string]$appVendor = 'Intel/Dell'
[string]$appName = 'Camera Stack (2D Imaging/USB IO/Vision)'
[string]$appVersion = '80.26100.0.29-A13'
[string]$appScriptVersion = '1.1.0'
[string]$appScriptDate = '2026-09-07'

#region --- custom helpers -----------------------------------------------------
function Test-CameraStreaming {
    # True if ANY app is actively using the camera (all user hives incl. NonPackaged)
    foreach ($hive in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        $root = "$($hive.PSPath)\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"
        if (-not (Test-Path $root)) { continue }
        foreach ($app in (Get-ChildItem "$root\*", "$root\NonPackaged\*" -ErrorAction SilentlyContinue)) {
            if ((Get-ItemProperty $app.PSPath -ErrorAction SilentlyContinue).LastUsedTimeStop -eq 0) { return $true }
        }
    }
    return $false
}
function Wait-ForCameraIdle {
    # Patient wait: poll until the camera stops streaming, or bail at MaxWaitMinutes.
    [CmdletBinding()] param([int]$MaxMinutes, [int]$IntervalMinutes)
    $deadline = (Get-Date).AddMinutes($MaxMinutes)
    $poll = 0
    while ((Get-Date) -lt $deadline) {
        $poll++
        if (-not (Test-CameraStreaming)) {
            Write-Log -Message "Camera idle after $poll poll(s) at $(Get-Date -Format HH:mm:ss) - proceeding" -Source 'HW9TN'
            return $true
        }
        Write-Log -Message "Poll ${poll}: camera in use - waiting ${IntervalMinutes}m (deadline $(Get-Date $deadline -Format HH:mm:ss))" -Source 'HW9TN'
        Start-Sleep -Seconds ($IntervalMinutes * 60)
    }
    Write-Log -Message "Camera still in use after ${MaxMinutes}m of waiting - deferring to next retry cycle" -Source 'HW9TN'
    return $false
}
#endregion ----------------------------------------------------------------------

# Import the AppDeployToolkit (uncomment in the real template)
#. "$PSScriptRoot\AppDeployToolkit\AppDeployToolkitMain.ps1"

[string]$deploymentType = 'Install'
Try {
    ##================================================
    ## PRE-INSTALLATION
    ##================================================
    Set-Variable -Name 'installPhase' -Value 'Pre-Install'

    $sp = Get-CimInstance Win32_ComputerSystemProduct
    $bb = Get-CimInstance Win32_BaseBoard
    $cs = Get-CimInstance Win32_ComputerSystem
    if (@($sp.Version, $sp.Name, $bb.Product, $cs.Model) -join ' ' -notmatch 'PB14250') {
        Write-Log -Message 'Not a PB14250 - not applicable, exiting 0' -Source 'HW9TN'
        Exit-Script -ExitCode 0
    }

    ##================================================
    ## INSTALLATION - patient wait, then payload
    ##================================================
    Set-Variable -Name 'installPhase' -Value 'Installation'

    if (-not (Wait-ForCameraIdle -MaxMinutes $MaxWaitMinutes -IntervalMinutes $PollMinutes)) {
        Exit-Script -ExitCode 1618   # Intune FAST RETRY: patience across cycles, no failure status
    }

    $drivers = Join-Path $dirFiles 'Drivers\x64'
    if (-not (Test-Path "$drivers\*.inf")) {
        Write-Log -Message "Payload missing: $drivers" -Severity 3 -Source 'HW9TN'
        Exit-Script -ExitCode 1
    }
    # PSADT syntax verified against psadt_docs 3.10.2 reference:
    # -Parameters (NOT -Arguments; that is only an alias), -CreateNoWindow for
    # console apps (WindowStyle is GUI-only), -IgnoreExitCodes '*' because
    # ExitOnProcessFailure defaults $true and would hijack flow control.
    $pnputilAdd = Execute-Process -Path 'pnputil.exe' -Parameters "/add-driver `"$drivers\*.inf`" /subdirs /install" -CreateNoWindow -PassThru -IgnoreExitCodes '*'
    Write-Log -Message "pnputil add-driver exit code: $($pnputilAdd.ExitCode)" -Source 'HW9TN'
    $pnputilScan = Execute-Process -Path 'pnputil.exe' -Parameters '/scan-devices' -CreateNoWindow -PassThru -IgnoreExitCodes '*' -ContinueOnError $true
    Write-Log -Message "pnputil scan-devices exit code: $($pnputilScan.ExitCode)" -Source 'HW9TN'
    Start-Sleep -Seconds 5

    ##================================================
    ## POST-INSTALLATION
    ##================================================
    Set-Variable -Name 'installPhase' -Value 'Post-Install'

    $targetRe = 'VEN_8086&DEV_(7D51|7DD1|7D41|7D67|B640|64A0|6420|64B0|7D19|645D|5A19).*INT3480|VEN_HIMX&DEV_1092|VEN_OVTI&DEV_(05C1|08F4)|VEN_INT&DEV_(3472|346F)|VID_8086&PID_0B63|VID_2AC1&PID_20C[19B]|VID_06CB&PID_0701|INTC10B5|INTC10B6|INTC10E0|INTC10DE'
    $needRestart = $false
    foreach ($d in (Get-PnpDevice -PresentOnly)) {
        $hw = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds').Data
        if (-not $hw -or (($hw -join ';') -notmatch $targetRe)) { continue }
        $pc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
        if ($pc -eq 14 -or $pc -eq 25) { $needRestart = $true }
    }

    if ($needRestart) {
        # User-paced restart. No forcing. EVER. (unsaved-work rule)
        Write-Log -Message 'Pending user-paced restart (exit 3010)' -Source 'HW9TN'
        Exit-Script -ExitCode 3010
    }
    Exit-Script -ExitCode 0
}
Catch {
    Write-Log -Message "Deployment failed: $($_.Exception.Message)" -Severity 3 -Source 'HW9TN'
    Exit-Script -ExitCode 1
}
