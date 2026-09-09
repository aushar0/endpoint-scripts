<#
.SYNOPSIS

PSApppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION

- Installs, reinstalls (Repair), or removes (Uninstall) the Intel camera stack
  driver packages for Dell Pro laptops (package HW9TN).
- The install deployment type is broken down into 3 main sections/phases: Pre-Install, Install, and Post-Install.
- Install behavior: waits for an idle camera, installs via PnP, removes superseded
  packages once unbound, never prompts, never closes applications, never forces a restart.

The script dot-sources the AppDeployToolkitMain.ps1 script which contains the logic and functions required to install or uninstall an application.

PSApppDeployToolkit is licensed under the GNU LGPLv3 License - (C) 2024 PSAppDeployToolkit Team (Sean Lillis, Dan Cunningham and Muhammad Mashwani).

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Lesser General Public License as published by the
Free Software Foundation, either version 3 of the License, or any later version. This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
for more details. You should have received a copy of the GNU Lesser General Public License along with this program. If not, see <http://www.gnu.org/licenses/>.

.PARAMETER DeploymentType

The type of deployment to perform. Default is: Install.

.PARAMETER DeployMode

Specifies whether the installation should be run in Interactive, Silent, or NonInteractive mode. Default is: Interactive. Options: Interactive = Shows dialogs, Silent = No dialogs, NonInteractive = Very silent, i.e. no blocking apps. NonInteractive mode is automatically set if it is detected that the process is not user interactive.

.PARAMETER MaxWaitMinutes

Minutes to wait for an idle camera before deferring (Install and Repair). Default 45; the Intune Remediations cap is 60.

.PARAMETER PollMinutes

Camera idle-check interval in minutes. Default 10.

.PARAMETER LocalPackage

Optional path to a local copy of the driver package EXE, used instead of downloading (air-gapped machines or testing).

.PARAMETER AllowRebootPassThru

Allows the 3010 return code (requires restart) to be passed back to the parent process (e.g. SCCM) if detected from an installation. If 3010 is passed back to SCCM, a reboot prompt will be triggered.

.PARAMETER TerminalServerMode

Changes to "user install mode" and back to "user execute mode" for installing/uninstalling applications for Remote Desktop Session Hosts/Citrix servers.

.PARAMETER DisableLogging

Disables logging to file for the script. Default is: $false.

.EXAMPLE

Deploy-Application.exe -DeploymentType "Install" -DeployMode "Silent"

.EXAMPLE

powershell.exe -Command "& { & '.\Deploy-Application.ps1' -DeploymentType 'Uninstall'; Exit $LastExitCode }"

.INPUTS

None

You cannot pipe objects to this script.

.OUTPUTS

None

This script does not generate any output.

.NOTES

Toolkit Exit Code Ranges:
- 60000 - 68999: Reserved for built-in exit codes in Deploy-Application.ps1, Deploy-Application.exe, and AppDeployToolkitMain.ps1
- 69000 - 69999: Recommended for user customized exit codes in Deploy-Application.ps1
- 70000 - 79999: Recommended for user customized exit codes in AppDeployToolkitExtensions.ps1

This deployment additionally returns: 3010 (success, restart pending - the restart
belongs to the user and is never forced) and 1618 (camera busy past the wait
window; Intune fast-retry).

.LINK

https://psappdeploytoolkit.com
#>


[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [String]$DeploymentType = 'Install',
    [Parameter(Mandatory = $false)]
    [ValidateSet('Interactive', 'Silent', 'NonInteractive')]
    [String]$DeployMode = 'Interactive',
    [Parameter(Mandatory = $false)]
    [Int]$MaxWaitMinutes = 45,
    [Parameter(Mandatory = $false)]
    [Int]$PollMinutes = 10,
    [Parameter(Mandatory = $false)]
    [String]$LocalPackage = '',
    [Parameter(Mandatory = $false)]
    [switch]$AllowRebootPassThru = $false,
    [Parameter(Mandatory = $false)]
    [switch]$TerminalServerMode = $false,
    [Parameter(Mandatory = $false)]
    [switch]$DisableLogging = $false
)

Try {
    ## Set the script execution policy for this process
    Try {
        Set-ExecutionPolicy -ExecutionPolicy 'ByPass' -Scope 'Process' -Force -ErrorAction 'Stop'
    } Catch {
    }

    ##*===============================================
    #region VARIABLE DECLARATION
    ##*===============================================
    ## Variables: Application
    [String]$appVendor = 'Intel/Dell'
    [String]$appName = 'Camera Stack (2D Imaging/USB IO/Vision)'
    [String]$appVersion = '80.26100.0.29-A13'
    [String]$appArch = ''
    [String]$appLang = 'EN'
    [String]$appRevision = '01'
    [String]$appScriptVersion = '3.0.0'
    [String]$appScriptDate = '09/09/2026'
    [String]$appScriptAuthor = ''
    ##*===============================================
    ## Variables: Install Titles (Only set here to override defaults set by the toolkit)
    [String]$installName = ''
    [String]$installTitle = ''

    ##* Do not modify section below
    #region DoNotModify

    ## Variables: Exit Code
    [Int32]$mainExitCode = 0

    ## Variables: Script
    [String]$deployAppScriptFriendlyName = 'Deploy Application'
    [Version]$deployAppScriptVersion = [Version]'3.10.2'
    [String]$deployAppScriptDate = '08/13/2024'
    [Hashtable]$deployAppScriptParameters = $PsBoundParameters

    ## Variables: Environment
    If (Test-Path -LiteralPath 'variable:HostInvocation') {
        $InvocationInfo = $HostInvocation
    }
    Else {
        $InvocationInfo = $MyInvocation
    }
    [String]$scriptDirectory = Split-Path -Path $InvocationInfo.MyCommand.Definition -Parent

    ## Dot source the required App Deploy Toolkit Functions
    Try {
        [String]$moduleAppDeployToolkitMain = "$scriptDirectory\AppDeployToolkit\AppDeployToolkitMain.ps1"
        If (-not (Test-Path -LiteralPath $moduleAppDeployToolkitMain -PathType 'Leaf')) {
            Throw "Module does not exist at the specified location [$moduleAppDeployToolkitMain]."
        }
        If ($DisableLogging) {
            . $moduleAppDeployToolkitMain -DisableLogging
        }
        Else {
            . $moduleAppDeployToolkitMain
        }
    }
    Catch {
        If ($mainExitCode -eq 0) {
            [Int32]$mainExitCode = 60008
        }
        Write-Error -Message "Module [$moduleAppDeployToolkitMain] failed to load: `n$($_.Exception.Message)`n `n$($_.InvocationInfo.PositionMessage)" -ErrorAction 'Continue'
        ## Exit the script, returning the exit code to SCCM
        If (Test-Path -LiteralPath 'variable:HostInvocation') {
            $script:ExitCode = $mainExitCode; Exit
        }
        Else {
            Exit $mainExitCode
        }
    }

    #endregion
    ##* Do not modify section above
    ##*===============================================
    #endregion END VARIABLE DECLARATION
    ##*===============================================

    #region CAMERA STACK KIT
    ## Package manifest and helpers. Logging is dual-surface: readable narrative
    ## lines in the PSADT log, strict key=value lines to machine.log plus a
    ## last_run.json snapshot, all under C:\ProgramData\DellCamera\<package>\.

    $manifest = @{
        PB = @{ id = 'HW9TN'; version = '80.26100.0.29-A13'
                url  = 'https://dl.dell.com/FOLDER14812487M/1/Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera_HW9TN_WIN64_80.26100.0.29_A13.EXE'
                exe  = 'Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera_HW9TN_WIN64_80.26100.0.29_A13.EXE' }
    }
    $familyInfs = 'iacamera64.inf','hm1092.inf','ov05c10.inf','ov08x40.inf','iactrllogic64.inf',
                  'iaisp64.inf','usbbridge.inf','usbgpio.inf','usbi2c.inf','vision.inf','visionextension.inf'
    $stackRe = 'VEN_8086&DEV_(7D51|7DD1|7D41|7D67|B640|64A0|6420|64B0|7D19|645D|5A19).*INT3480|VEN_HIMX&DEV_1092|VEN_OVTI&DEV_(05C1|08F4)|VEN_INT&DEV_(3472|346F)|VID_8086&PID_0B63|VID_2AC1&PID_20C[19B]|VID_06CB&PID_0701|INTC10B5|INTC10B6|INTC10E0|INTC10DE'
    $probGloss = @{
        1  = 'config problem'; 10 = 'CANNOT START'; 12 = 'not enough resources'; 14 = 'needs restart';
        18 = 'reinstall drivers'; 22 = 'DISABLED (by choice)'; 28 = 'NO DRIVER';
        31 = 'not working properly'; 43 = 'reported a problem'; 45 = 'not connected'; 52 = 'unsigned/corrupt driver'
    }

    function Get-Prop($InstanceId, $Key) {
        (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $Key).Data
    }
    function Test-CameraStreaming {
        foreach ($hive in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
            $root = "$($hive.PSPath)\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"
            If (-not (Test-Path $root)) { continue }
            foreach ($app in (Get-ChildItem "$root\*", "$root\NonPackaged\*" -ErrorAction SilentlyContinue)) {
                If ((Get-ItemProperty $app.PSPath -ErrorAction SilentlyContinue).LastUsedTimeStop -eq 0) {
                    $script:camHolder = $app.PSChildName; return $true
                }
            }
        }
        return $false
    }
    function Write-Rca {
        param([string]$Phase, [string]$Body, [string]$Message, [switch]$Record)
        $machine = "HW9TN|phase=$Phase|$Body"
        Write-Log -Message $(if ($Message) { $Message } else { $machine }) -Source 'HW9TN'
        Write-Output $machine
        If ($script:machineLog) { Add-Content -Path $script:machineLog -Value $machine -Encoding UTF8 }
    }
    function Save-RcaJson {
        $script:rca['finished'] = Get-Date -Format s
        try {
            New-Item -ItemType Directory -Force -Path $script:stageDir | Out-Null
            $script:rca | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $script:stageDir 'last_run.json') -Encoding UTF8
        } catch { Write-Output "HW9TN|phase=JSON|status=save-failed|$($_.Exception.Message)" }
    }
    function Write-RunSummary {
        ## Outcome-first run summary: what was run, what the result was. Written to
        ## the PSADT log (readable) and stored in last_run.json for automated support.
        param([int]$Code)
        $d = $script:rca; $m = $d['meta']
        $result = switch ($Code) {
            0       { 'COMPLETED - no restart required' }
            3010    { "COMPLETED - restart pending at the user's discretion (finalizes at the next restart)" }
            1618    { 'DEFERRED - camera in use throughout the wait window; no changes were made' }
            default { "FAILED (exit $Code)" + $(if ($d['errors']) { ' - ' + ($d['errors'] -join '; ') } else { '' }) }
        }
        $lines = @(
            '==============================================================',
            ' DEPLOYMENT SUMMARY',
            '==============================================================',
            " Product:    Intel Camera Stack Driver Package ($($m['package']), $($m['version']))",
            " Machine:    family $($m['family']), BIOS $($m['bios']), Windows build $($m['build'])",
            " Operation:  $($d['type'])",
            " Result:     $result"
        )
        If ($d.Contains('install')) {
            $lines += " Components: $($d['install']['ok']) of $($d['install']['total']) driver packages installed on matching devices"
        }
        If ($d.Contains('post_state')) {
            $lines += " Camera:     $($d['post_state'])"
        }
        If ($d.Contains('cleanup')) {
            $lines += " Cleanup:    $($d['cleanup']['deleted'].Count) superseded package(s) removed; $($d['cleanup']['skipped'].Count) retained (in use)"
        }
        $dur = [int]((Get-Date) - $script:runStart).TotalMinutes
        $lines += " Duration:   $dur minute(s) | Log folder: $($script:stageDir)"
        $lines += '=============================================================='
        $lines | ForEach-Object { Write-Log -Message $_ -Source 'HW9TN' }
        $d['exit_code'] = $Code; $d['result'] = $result; $d['summary'] = $lines -join "`n"
    }

    function Invoke-CameraStackInstall {
        ## Gate + family
        $sp = Get-CimInstance Win32_ComputerSystemProduct
        $bb = Get-CimInstance Win32_BaseBoard
        $cs = Get-CimInstance Win32_ComputerSystem
        $sig = @($sp.Version, $sp.Name, $bb.Product, $cs.Model) -join ' '
        If ($sig -notmatch 'P[AB]14250') {
            Write-Log -Message "not a target machine [$sig] - not applicable" -Source 'HW9TN'
            return 0
        }
        $family = if ($sig -match 'PA14250') { 'PA' } else { 'PB' }
        $pkg = $manifest[$family]
        If (-not $pkg) {
            Write-Rca 'PRE' "family=$family|status=no-package-configured" -Message "No package configured for family $family on this machine."
            return 1
        }
        $script:stageDir = "C:\ProgramData\DellCamera\$($pkg.id)\v$($pkg.version)"
        $script:machineLog = Join-Path $script:stageDir 'machine.log'
        $script:rca = [ordered]@{ started = (Get-Date -Format s); type = $DeploymentType }
        $script:runStart = Get-Date
        $script:rca['meta'] = @{ family = $family; package = $pkg.id; version = $pkg.version }
        $script:rca['pre_devices'] = @(); $script:rca['post_devices'] = @()
        $script:rca['rebinds'] = @(); $script:rca['errors'] = @()
        New-Item -ItemType Directory -Force -Path $script:stageDir | Out-Null
        Add-Content -Path $script:machineLog -Value "HW9TN|run-start|$(Get-Date -Format s)|type=$DeploymentType" -Encoding UTF8
        Write-Rca 'PRE' "family=$family|pkg=$($pkg.id)|ver=$($pkg.version)" `
            -Message "Target confirmed (family $family): package $($pkg.id) v$($pkg.version). Working folder: $($script:stageDir)"

        ## PRE snapshot
        $os = Get-CimInstance Win32_OperatingSystem
        $bios = (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
        $dcu = if (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                           'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -match 'Dell Command' }) { 'present' } else { 'absent' }
        $script:rca['meta']['bios'] = $bios; $script:rca['meta']['build'] = $os.BuildNumber
        Write-Rca 'ctx' ("bios=$bios|build={0}|os_changed={1:yyyy-MM-dd}|winold={2}|dcu={3}" -f `
            $os.BuildNumber, $os.InstallDate, (Test-Path 'C:\Windows.old'), $dcu) `
            -Message ("System: BIOS {0}, build {1}, last feature update {2:yyyy-MM-dd}, Dell Command Update {3}." -f `
                $bios, $os.BuildNumber, $os.InstallDate, $dcu)
        $preState = @{}
        foreach ($d in (Get-PnpDevice -PresentOnly)) {
            $hw = Get-Prop $d.InstanceId 'DEVPKEY_Device_HardwareIds'
            If (-not $hw -or (($hw -join ';') -notmatch $stackRe)) { continue }
            $cur = Get-Prop $d.InstanceId 'DEVPKEY_Device_DriverVersion'
            $inf = Get-Prop $d.InstanceId 'DEVPKEY_Device_DriverInfPath'
            $prov = Get-Prop $d.InstanceId 'DEVPKEY_Device_DriverProvider'
            $prob = Get-Prop $d.InstanceId 'DEVPKEY_Device_ProblemCode'
            $preState[$d.InstanceId] = @{ drv = $cur; inf = $inf; prov = $prov; prob = $prob }
            $short = $hw[0] -replace '^.*\\', ''
            $gloss = if ($prob -and $prob -ne 0 -and $probGloss[[int]$prob]) { " $($probGloss[[int]$prob])" } else { '' }
            $script:rca['pre_devices'] += [pscustomobject]@{ id = $short; drv = $cur; inf = $inf; prov = $prov; prob = $prob }
            Write-Rca 'dev' ("$short|drv=$(if ($cur) { $cur } else { 'NONE' })|prob=$prob") `
                -Message ("  $short : driver $(if ($cur) { $cur } else { 'NONE' }), provider $(if ($prov) { $prov } else { '?' })$(if ($prob -and $prob -ne 0) { ", problem $prob -$gloss" } else { '' })")
        }
        Save-RcaJson

        ## WAIT: patient, camera-idle only
        $deadline = (Get-Date).AddMinutes($MaxWaitMinutes); $poll = 0
        while ((Get-Date) -lt $deadline -and (Test-CameraStreaming)) {
            $poll++
            Write-Rca 'WAIT' ("camera=busy|app=$($script:camHolder)|poll=$poll") `
                -Message "Camera in use (by $($script:camHolder)) - not touching anything; next check in ${PollMinutes}m ($poll)."
            Start-Sleep -Seconds ($PollMinutes * 60)
        }
        If (Test-CameraStreaming) {
            Write-Rca 'WAIT' "camera=busy|result=gave-up-after-${MaxWaitMinutes}m" `
                -Message "Camera stayed in use the whole ${MaxWaitMinutes}m - stopping quietly; the next scheduled run tries again."
            Write-RunSummary 1618; Save-RcaJson
            return 1618
        }
        $script:rca['wait'] = @{ polls = $poll; result = 'idle' }
        Write-Rca 'WAIT' "camera=idle|polls=$poll" -Message "Camera is idle - proceeding."

        ## Obtain + verify + extract
        $exePath = Join-Path $script:stageDir $pkg.exe
        If (-not (Test-Path $exePath) -and $LocalPackage -and (Test-Path $LocalPackage)) {
            Copy-Item $LocalPackage $exePath -Force
            Write-Rca 'DL' "src=local-override" -Message "Using local package copy: $LocalPackage"
        }
        If (-not (Test-Path $exePath)) {
            If (-not $pkg.url) { $script:rca['errors'] += 'no download URL configured'; Write-Rca 'DL' 'src=none|status=no-url' -Message "No download URL configured for this package."; Write-RunSummary 1; Save-RcaJson; return 1 }
            Write-Rca 'DL' "src=dl.dell.com" -Message "Downloading $($pkg.exe) via BITS..."
            try { Start-BitsTransfer -Source $pkg.url -Destination $exePath -ErrorAction Stop }
            catch { $script:rca['errors'] += "download failed"; Write-Rca 'DL' "status=failed|$($_.Exception.Message)" -Message "Download failed: $($_.Exception.Message)"; Write-RunSummary 1; Save-RcaJson; return 1 }
        }
        $sigChk = Get-AuthenticodeSignature $exePath
        If ($sigChk.Status -ne 'Valid' -or $sigChk.SignerCertificate.Subject -notmatch 'Dell') {
            Write-Rca 'DL' "sig=INVALID|$($sigChk.Status)" -Message "Package signature check failed ($($sigChk.Status)) - refusing to run."
            $script:rca['errors'] += "package signature invalid"
            Write-RunSummary 1; Save-RcaJson; return 1
        }
        $script:rca['download'] = @{ verified = $true; bytes = (Get-Item $exePath).Length }
        Write-Rca 'DL' "sig=Dell-valid|bytes=$((Get-Item $exePath).Length)" -Message "Package verified (Dell-signed)."
        $exDir = Join-Path $script:stageDir 'extract'
        If (-not (Test-Path "$exDir\16299")) {
            New-Item -ItemType Directory -Force -Path $exDir | Out-Null
            $p = Start-Process -FilePath $exePath -ArgumentList "/s /e /f=`"$exDir`"" -Wait -PassThru -WindowStyle Hidden
            Write-Rca 'DL' "extract=done|exit=$($p.ExitCode)" -Message "Package extracted."
        }
        $infs = @(Get-ChildItem "$exDir\16299\Drivers" -Recurse -Filter *.inf)
        If ($infs.Count -eq 0) { $script:rca['errors'] += 'no INFs found after extraction'; Write-Rca 'DL' 'extract=no-infs' -Message 'No INFs found after extraction.'; Write-RunSummary 1; Save-RcaJson; return 1 }

        ## INSTALL
        $installed = 0
        foreach ($inf in $infs) {
            $r = Execute-Process -Path 'pnputil.exe' -Parameters "/add-driver `"$($inf.FullName)`" /install" -CreateNoWindow -PassThru -IgnoreExitCodes '*'
            If (($r.StdOut | Select-String -SimpleMatch 'success') -or $r.ExitCode -eq 0) { $installed++ }
        }
        Execute-Process -Path 'pnputil.exe' -Parameters '/scan-devices' -CreateNoWindow -PassThru -IgnoreExitCodes '*' -ContinueOnError $true | Out-Null
        Start-Sleep -Seconds 5
        ## Forced rebind for devices that did not recover on their own (never code 22: disabled is deliberate)
        foreach ($d in (Get-PnpDevice -PresentOnly)) {
            $pc2 = Get-Prop $d.InstanceId 'DEVPKEY_Device_ProblemCode'
            $isCam = $d.Class -in 'Camera', 'Image'
            If (($isCam -or ($pc2 -and $pc2 -ne 0)) -and $pc2 -ne 22) {
                $script:rca['rebinds'] += $d.InstanceId
                Execute-Process -Path 'pnputil.exe' -Parameters "/restart-device `"$($d.InstanceId)`"" -CreateNoWindow -PassThru -IgnoreExitCodes '*' -ContinueOnError $true | Out-Null
            }
        }
        $script:rca['install'] = @{ total = $infs.Count; ok = $installed }
        Write-Rca 'INSTALL' "infs=$($infs.Count)|ok=$installed" -Message "Installed $installed of $($infs.Count) driver packages."

        ## CLEANUP: delete unbound superseded family packages only
        $deleted = @(); $skipped = @()
        try {
            $drivers = Get-WindowsDriver -Online -ErrorAction Stop |
                Where-Object { $_.OriginalFileName -and ($familyInfs -contains $_.OriginalFileName.ToLower()) }
            If ($drivers) {
                $boundInfs = @(Get-PnpDevice -PresentOnly | ForEach-Object { Get-Prop $_.InstanceId 'DEVPKEY_Device_DriverInfPath' } | Where-Object { $_ })
                foreach ($origName in ($drivers | Select-Object -ExpandProperty OriginalFileName -Unique)) {
                    $set  = $drivers | Where-Object OriginalFileName -eq $origName
                    $keep = $set | Sort-Object Version -Descending | Select-Object -First 1
                    foreach ($p in ($set | Where-Object Driver -ne $keep.Driver)) {
                        If ($boundInfs -contains $p.Driver) { $skipped += "$($p.Driver)($origName)" }
                        Else {
                            Execute-Process -Path 'pnputil.exe' -Parameters "/delete-driver $($p.Driver)" -CreateNoWindow -PassThru -IgnoreExitCodes '*' | Out-Null
                            $deleted += "$($p.Driver)($origName)"
                        }
                    }
                }
            }
        } catch { Write-Rca 'CLEANUP' "status=enum-failed" -Message "Driver store enumeration failed; cleanup skipped (not fatal)." }
        $script:rca['cleanup'] = @{ deleted = $deleted; skipped = $skipped }
        Write-Rca 'CLEANUP' ("deleted={0}|skipped_bound={1}" -f `
            $(if ($deleted) { $deleted -join ',' } else { 'none' }),
            $(if ($skipped) { $skipped -join ',' } else { 'none' })) `
            -Message ("Old-driver cleanup: $(if ($deleted) { "removed $($deleted.Count) superseded package(s)" } else { 'nothing stale to remove' })$(if ($skipped) { "; kept $($skipped.Count) still in use (they clear at the next restart)" } else { '' }).")

        ## POST verify + evidence on failure
        $camCount = @(Get-PnpDevice -Class Camera,Image -PresentOnly).Count
        $pending = 0; $postProblems = 0; $changed = 0
        foreach ($d in (Get-PnpDevice -PresentOnly)) {
            $hw = Get-Prop $d.InstanceId 'DEVPKEY_Device_HardwareIds'
            If (-not $hw -or (($hw -join ';') -notmatch $stackRe)) { continue }
            $prob = Get-Prop $d.InstanceId 'DEVPKEY_Device_ProblemCode'
            If ($prob -eq 14) { $pending++ }
            If ($prob -and $prob -ne 0 -and $prob -ne 14) { $postProblems++ }
            $pcur = Get-Prop $d.InstanceId 'DEVPKEY_Device_DriverVersion'
            $script:rca['post_devices'] += [pscustomobject]@{ id = (($hw -join ';') -replace '^.*\\', ''); drv = $pcur; prob = $prob }
            If ($preState.ContainsKey($d.InstanceId)) {
                If ($preState[$d.InstanceId].drv -ne $pcur) { $changed++ }
            } Else { $changed++ }
        }
        Write-Rca 'POST' ("camera=$camCount|prob_nonzero=$postProblems|pending14=$pending|stack_changed=$changed") `
            -Message ("Result: $(if ($camCount -gt 0 -and $postProblems -eq 0 -and $pending -eq 0) { 'camera present and healthy - no restart needed' } elseif ($pending -gt 0) { "installed - $pending device(s) finish at the user's next restart" } elseif ($camCount -eq 0) { 'PROBLEM: no camera visible after install - capturing evidence' } else { "installed but $postProblems device(s) still report problems - capturing evidence" }).")
        If ($postProblems -gt 0 -or $camCount -eq 0) {
            $slice = Join-Path $script:stageDir 'setupapi_camera_slice.log'
            Select-String -Path 'C:\Windows\INF\setupapi.dev.log' -Pattern 'iacamera|hm1092|ov08x40|ov05c10|iactrllogic|iaisp|usbbridge|Vision\.inf' -ErrorAction SilentlyContinue |
                ForEach-Object { "{0}: {1}" -f $_.LineNumber, $_.Line } | Set-Content $slice -Encoding UTF8
            Write-Rca 'POST' "setupapi_slice=$slice" -Message "  Driver-install history saved to $slice."
        }
        $script:rca['post_state'] = "$(if ($camCount -gt 0) { "present ($camCount device(s)), $(if ($pending -gt 0) { "$pending finalize at next restart" } elseif ($postProblems -eq 0) { 'operating normally' } else { "$postProblems still reporting problems" })" } else { 'not present' })"
        $exitCode = If ($pending -gt 0 -or $postProblems -gt 0) { 3010 } else { 0 }
        Write-RunSummary $exitCode
        Save-RcaJson
        return $exitCode
    }

    function Invoke-CameraStackUninstall {
        ## Rollback: remove ALL camera-family driver packages (bound ones via
        ## /uninstall /force so devices fall back), then re-enumerate. Devices may
        ## land on an inbox driver or drop until a package is reinstalled; logged.
        $removed = 0
        try {
            $drivers = Get-WindowsDriver -Online -ErrorAction Stop |
                Where-Object { $_.OriginalFileName -and ($familyInfs -contains $_.OriginalFileName.ToLower()) }
            foreach ($p in $drivers) {
                Write-Log -Message "removing driver package $($p.Driver) ($($p.OriginalFileName) v$($p.Version))" -Source 'HW9TN'
                Execute-Process -Path 'pnputil.exe' -Parameters "/delete-driver $($p.Driver) /uninstall /force" -CreateNoWindow -PassThru -IgnoreExitCodes '*' | Out-Null
                $removed++
            }
        } catch { Write-Log -Message "driver store enumeration failed: $($_.Exception.Message)" -Severity 3 -Source 'HW9TN' }
        Execute-Process -Path 'pnputil.exe' -Parameters '/scan-devices' -CreateNoWindow -PassThru -IgnoreExitCodes '*' -ContinueOnError $true | Out-Null
        $camCount = @(Get-PnpDevice -Class Camera,Image -PresentOnly).Count
        Write-Log -Message "rollback complete: $removed package(s) removed; camera devices present: $camCount" -Source 'HW9TN'
        return 0
    }
    #endregion

    If ($deploymentType -ine 'Uninstall' -and $deploymentType -ine 'Repair') {
        ##*===============================================
        ##* MARK: PRE-INSTALLATION
        ##*===============================================
        [String]$installPhase = 'Pre-Installation'

        ## No Show-InstallationWelcome: in Silent mode its -CloseApps path closes
        ## applications without prompting, which this deployment never does.

        ##*===============================================
        ##* MARK: INSTALLATION
        ##*===============================================
        [String]$installPhase = 'Installation'

        $mainExitCode = Invoke-CameraStackInstall

        ##*===============================================
        ##* MARK: POST-INSTALLATION
        ##*===============================================
        [String]$installPhase = 'Post-Installation'

    }
    ElseIf ($deploymentType -ieq 'Uninstall') {
        ##*===============================================
        ##* MARK: PRE-UNINSTALLATION
        ##*===============================================
        [String]$installPhase = 'Pre-Uninstallation'

        ##*===============================================
        ##* MARK: UNINSTALLATION
        ##*===============================================
        [String]$installPhase = 'Uninstallation'

        $mainExitCode = Invoke-CameraStackUninstall

        ##*===============================================
        ##* MARK: POST-UNINSTALLATION
        ##*===============================================
        [String]$installPhase = 'Post-Uninstallation'

    }
    ElseIf ($deploymentType -ieq 'Repair') {
        ##*===============================================
        ##* MARK: PRE-REPAIR
        ##*===============================================
        [String]$installPhase = 'Pre-Repair'

        ##*===============================================
        ##* MARK: REPAIR
        ##*===============================================
        [String]$installPhase = 'Repair'

        ## Install is idempotent (staging + rebind only what needs it), so repair
        ## re-runs it; the forced-rebind step recovers any ailing device.
        $mainExitCode = Invoke-CameraStackInstall

        ##*===============================================
        ##* MARK: POST-REPAIR
        ##*===============================================
        [String]$installPhase = 'Post-Repair'

    }

    ## Call the Exit-Script function to perform final cleanup operations
    Exit-Script -ExitCode $mainExitCode
}
Catch {
    [Int32]$mainExitCode = 60001
    [String]$mainErrorMessage = "$(Resolve-Error)"
    Write-Log -Message $mainErrorMessage -Severity 3 -Source $deployAppScriptFriendlyName
    Show-DialogBox -Text $mainErrorMessage -Icon 'Stop'
    Exit-Script -ExitCode $mainExitCode
}
