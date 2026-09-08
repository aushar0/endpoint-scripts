<#
Deploy-Application.ps1 - HW9TN/845M5 camera stack, PSADT v3.8/3.9 wrapper
PRIMARY entry point for Intune (intunewin of the PSADT package folder) and SCCM.

RCA-GRADE LOGGING: every line is `HW9TN|phase=...|key=value` - greppable
per-machine, aggregable fleet-wide (one rg over logs = the RCA report), plus a
JSON twin at C:\ProgramData\DellCamera\<pkg>\last_run.json for diffing and
support. Decision points are logged WITH reasons at decision time.

Phases: PRE (forensic snapshot) -> WAIT (camera idle) -> DL (obtain+verify+extract)
        -> INSTALL -> CLEANUP (unbound superseded only) -> POST (verify+diff)
        -> EXIT. setupapi.dev.log camera slice captured on POST problems.

Doctrine: no prompts, no kills, no forced reboots. Patient wait bounded by the
Intune remediations/script cap (60 min) or the Win32 app timeout; restarts ride
the user's natural reboot (exit 3010). Payload: .\Files\ or downloaded via
manifest below. PSADT syntax verified against psadt_docs 3.10.2 reference.
#>
[CmdletBinding()]
param(
    [ValidateSet('Silent', 'Interactive', 'NonInteractive')]
    [string]$DeployMode = 'Silent',
    [int]$MaxWaitMinutes = 45,
    [int]$PollMinutes = 10,
    [string]$LocalPackage = '',      # optional local EXE override (testing)
    [switch]$AllowRebootPassThru,
    [switch]$TerminalServerMode,
    [switch]$DisableLogging
)

Try { Set-ExecutionPolicy -ExecutionPolicy 'Bypass' -Scope 'Process' -Force -ErrorAction 'Stop' } Catch {}

[string]$appVendor = 'Intel/Dell'
[string]$appName = 'Camera Stack (2D Imaging/USB IO/Vision)'
[string]$appVersion = '80.26100.0.29-A13 / 80.25982.6.32-A12'
[string]$appScriptVersion = '2.0.0'
[string]$appScriptDate = '2026-09-08'

#region --- RCA logging --------------------------------------------------------
$rca = [ordered]@{ started = (Get-Date -Format s); phases = @() }
function Write-Rca {
    param([string]$Phase, [string]$Body, [switch]$Record)
    $line = "HW9TN|phase=$Phase|$Body"
    Write-Log -Message $line -Source 'HW9TN'
    Write-Output $line
    if ($Record) { $rca[$Phase] = $Body }
}
function Save-RcaJson {
    param([string]$StageDir)
    $rca['finished'] = Get-Date -Format s
    try {
        New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
        $rca | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $StageDir 'last_run.json') -Encoding UTF8
    } catch { Write-Output "HW9TN|phase=JSON|status=save-failed|$($_.Exception.Message)" }
}
#endregion ---------------------------------------------------------------------

#region --- helpers --------------------------------------------------------------
function Test-CameraStreaming {
    foreach ($hive in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        $root = "$($hive.PSPath)\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"
        if (-not (Test-Path $root)) { continue }
        foreach ($app in (Get-ChildItem "$root\*", "$root\NonPackaged\*" -ErrorAction SilentlyContinue)) {
            if ((Get-ItemProperty $app.PSPath -ErrorAction SilentlyContinue).LastUsedTimeStop -eq 0) {
                $script:camHolder = $app.PSChildName; return $true
            }
        }
    }
    return $false
}
function Get-Prop($InstanceId, $Key) {
    (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $Key).Data
}
function Get-DepVer($Pattern) {
    $d = Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match $Pattern } | Select-Object -First 1
    if ($d) { $v = Get-Prop $d.InstanceId 'DEVPKEY_Device_DriverVersion'; if ($v) { return $v } }
    return 'missing'
}
#endregion ----------------------------------------------------------------------

# Import the AppDeployToolkit (ACTIVE - this file is the complete template)
. "$PSScriptRoot\AppDeployToolkit\AppDeployToolkitMain.ps1"

# --- family package manifest ---
$manifest = @{
    PB = @{ id = 'HW9TN'; version = '80.26100.0.29-A13'
            url  = 'https://dl.dell.com/FOLDER14812487M/1/Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera_HW9TN_WIN64_80.26100.0.29_A13.EXE'
            exe  = 'Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera_HW9TN_WIN64_80.26100.0.29_A13.EXE'
            sha256 = $null }
    PA = @{ id = '845M5'; version = '80.25982.6.32-A12'
            url  = ''   # TODO: direct dl.dell.com link from browser download when PA fleet matters
            exe  = 'Intel-2D-Imaging-Vision-USB-Bridge-Driver-for-Camera_845M5_WIN64_80.25982.6.32_A12.EXE'
            sha256 = 'D96D301FF7092C4F172EDB2F713BC2626FC3C5FB77C52D1560586DA901FFDB66' }
}
$familyInfs = 'iacamera64.inf','hm1092.inf','ov05c10.inf','ov08x40.inf','iactrllogic64.inf',
              'iaisp64.inf','usbbridge.inf','usbgpio.inf','usbi2c.inf','vision.inf','visionextension.inf'
$stackRe = 'VEN_8086&DEV_(7D51|7DD1|7D41|7D67|B640|64A0|6420|64B0|7D19|645D|5A19).*INT3480|VEN_HIMX&DEV_1092|VEN_OVTI&DEV_(05C1|08F4)|VEN_INT&DEV_(3472|346F)|VID_8086&PID_0B63|VID_2AC1&PID_20C[19B]|VID_06CB&PID_0701|INTC10B5|INTC10B6|INTC10E0|INTC10DE'

[string]$deploymentType = 'Install'
Try {
    Set-Variable -Name 'installPhase' -Value 'Pre-Install'

    ## ===== gate + family =====
    $sp = Get-CimInstance Win32_ComputerSystemProduct
    $bb = Get-CimInstance Win32_BaseBoard
    $cs = Get-CimInstance Win32_ComputerSystem
    $sig = @($sp.Version, $sp.Name, $bb.Product, $cs.Model) -join ' '
    if ($sig -notmatch 'P[AB]14250') {
        Write-Log -Message "not a target machine [$sig] - not applicable" -Source 'HW9TN'
        Exit-Script -ExitCode 0
    }
    $family = if ($sig -match 'PA14250') { 'PA' } else { 'PB' }
    $pkg = $manifest[$family]
    $stage = "C:\ProgramData\DellCamera\$($pkg.id)\v$($pkg.version)"
    Write-Rca 'PRE' "family=$family|pkg=$($pkg.id)|ver=$($pkg.version)|stage=$stage" -Record

    ## ===== PRE: forensic snapshot (the RCA evidence) =====
    $os = Get-CimInstance Win32_OperatingSystem
    $bios = (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
    $dcu = if (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'Dell Command' }) { 'present' } else { 'absent' }
    Write-Rca 'ctx' ("bios=$bios|build={0}|os_changed={1:yyyy-MM-dd}|winold={2}|dcu={3}" -f `
        $os.BuildNumber, $os.InstallDate, (Test-Path 'C:\Windows.old'), $dcu) -Record

    $gfxDev = Get-PnpDevice -Class Display -PresentOnly | Where-Object { (Get-Prop $_.InstanceId 'DEVPKEY_Device_DriverProvider') -match 'Intel' } | Select-Object -First 1
    $gfxVer = if ($gfxDev) { Get-Prop $gfxDev.InstanceId 'DEVPKEY_Device_DriverVersion' } else { 'missing' }
    Write-Rca 'dep' ("ish={0}|serialio={1}|me={2}|gfx={3}" -f `
        (Get-DepVer 'Integrated Sensor Solution'), (Get-DepVer 'Serial IO'),
        (Get-DepVer 'Management Engine'), $gfxVer) -Record

    $preState = @{}
    foreach ($d in (Get-PnpDevice -PresentOnly)) {
        $hw = Get-Prop $d.InstanceId 'DEVPKEY_Device_HardwareIds'
        if (-not $hw -or (($hw -join ';') -notmatch $stackRe)) { continue }
        $name = ($hw -join ';')
        $cur  = Get-Prop $d.InstanceId 'DEVPKEY_Device_DriverVersion'
        $inf  = Get-Prop $d.InstanceId 'DEVPKEY_Device_DriverInfPath'
        $prov = Get-Prop $d.InstanceId 'DEVPKEY_Device_DriverProvider'
        $prob = Get-Prop $d.InstanceId 'DEVPKEY_Device_ProblemCode'
        $key = $d.InstanceId
        $preState[$key] = @{ drv = $cur; inf = $inf; prov = $prov; prob = $prob }
        $short = ($hw[0] -replace '^.*\\', '')
        Write-Rca 'dev' ("$short|drv=$(if ($cur) { $cur } else { 'NONE' })|inf=$(if ($inf) { $inf } else { '-' })|prov=$(if ($prov) { $prov } else { '-' })|prob=$prob")
    }

    $fwLine = @()
    foreach ($root in 'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\INTC10E0', 'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\INTC10DE', 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_06CB&PID_0701') {
        Get-ChildItem $root -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath
            foreach ($n in 'CurrentFWVersion', 'TargetVersion', 'UpdateVersion') {
                if ($p.$n) { $fwLine += "$n=$($p.$n)" }
            }
        }
    }
    Write-Rca 'fw' ($(if ($fwLine) { $fwLine -join '|' } else { 'values=none-found' })) -Record

    $firstErr = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-MF-FrameServer/Camera_FrameServer'; Level = 1, 2 } -Oldest -ErrorAction SilentlyContinue | Select-Object -First 1
    $delta = if ($firstErr) { [int](($firstErr.TimeCreated - $os.InstallDate).TotalHours) } else { $null }
    Write-Rca 'rca' ("first_err={0}|upgraded={1:yyyy-MM-dd HH:mm}|delta={2}" -f `
        $(if ($firstErr) { $firstErr.TimeCreated.ToString('yyyy-MM-ddTHH:mm') } else { 'none-in-retention' }),
        $os.InstallDate, $(if ($null -ne $delta) { "{0}h" -f $delta } else { 'n/a' })) -Record
    Save-RcaJson $stage

    ## ===== WAIT: patient, camera-idle only =====
    Set-Variable -Name 'installPhase' -Value 'Installation'
    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes); $poll = 0
    while ((Get-Date) -lt $deadline -and (Test-CameraStreaming)) {
        $poll++
        Write-Rca 'WAIT' ("camera=busy|app=$($script:camHolder)|poll=$poll|wait=${PollMinutes}m")
        Start-Sleep -Seconds ($PollMinutes * 60)
    }
    if (Test-CameraStreaming) {
        Write-Rca 'WAIT' "camera=busy|result=gave-up-after-${MaxWaitMinutes}m" -Record
        Save-RcaJson $stage
        Exit-Script -ExitCode 3010   # next scheduled run carries patience
    }
    Write-Rca 'WAIT' "camera=idle|polls=$poll" -Record

    ## ===== DL: obtain + verify + extract =====
    $exePath = Join-Path $stage $pkg.exe
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    if (-not (Test-Path $exePath) -and $LocalPackage -and (Test-Path $LocalPackage)) {
        Copy-Item $LocalPackage $exePath -Force
        Write-Rca 'DL' "src=local-override|file=$LocalPackage" -Record
    }
    if (-not (Test-Path $exePath)) {
        if (-not $pkg.url) { Write-Rca 'DL' 'src=none|status=no-url-configured' -Record; Save-RcaJson $stage; Exit-Script -ExitCode 1 }
        Write-Rca 'DL' "src=dl.dell.com|file=$($pkg.exe)"
        try { Start-BitsTransfer -Source $pkg.url -Destination $exePath -ErrorAction Stop }
        catch { Write-Rca 'DL' "status=failed|$($_.Exception.Message)" -Record; Save-RcaJson $stage; Exit-Script -ExitCode 1 }
    }
    $sigChk = Get-AuthenticodeSignature $exePath
    if ($sigChk.Status -ne 'Valid' -or $sigChk.SignerCertificate.Subject -notmatch 'Dell') {
        Write-Rca 'DL' "sig=INVALID|$($sigChk.Status)" -Record; Save-RcaJson $stage; Exit-Script -ExitCode 1
    }
    $shaNote = 'unchecked'
    if ($pkg.sha256) {
        $shaNote = if ((Get-FileHash $exePath -Algorithm SHA256).Hash -eq $pkg.sha256) { 'match' } else { 'MISMATCH' }
        if ($shaNote -eq 'MISMATCH') { Write-Rca 'DL' 'sha256=MISMATCH' -Record; Save-RcaJson $stage; Exit-Script -ExitCode 1 }
    }
    Write-Rca 'DL' ("sig=Dell-valid|sha256={0}|bytes={1}" -f $shaNote, (Get-Item $exePath).Length) -Record

    $exDir = Join-Path $stage 'extract'
    if (-not (Test-Path "$exDir\16299")) {
        New-Item -ItemType Directory -Force -Path $exDir | Out-Null
        $p = Execute-Process -Path $exePath -Parameters "/s /e /f=`"$exDir`"" -CreateNoWindow -PassThru -IgnoreExitCodes '*'
        Write-Rca 'DL' "extract=done|exit=$($p.ExitCode)" -Record
    }
    $infs = @(Get-ChildItem "$exDir\16299\Drivers" -Recurse -Filter *.inf)
    if ($infs.Count -eq 0) { Write-Rca 'DL' 'extract=no-infs-found' -Record; Save-RcaJson $stage; Exit-Script -ExitCode 1 }
    Write-Rca 'DL' "infs=$($infs.Count)|payload=ready" -Record

    ## ===== INSTALL =====
    $installed = 0
    foreach ($inf in $infs) {
        $r = Execute-Process -Path 'pnputil.exe' -Parameters "/add-driver `"$($inf.FullName)`" /install" -CreateNoWindow -PassThru -IgnoreExitCodes '*'
        if (($r.StdOut | Select-String -SimpleMatch 'success') -or $r.ExitCode -eq 0) { $installed++ }
    }
    Execute-Process -Path 'pnputil.exe' -Parameters '/scan-devices' -CreateNoWindow -PassThru -IgnoreExitCodes '*' -ContinueOnError $true | Out-Null
    Start-Sleep -Seconds 5
    Write-Rca 'INSTALL' "infs=$($infs.Count)|ok=$installed" -Record

    ## ===== CLEANUP: unbound superseded family packages only =====
    $deleted = @(); $skipped = @()
    try {
        $drivers = Get-WindowsDriver -Online -ErrorAction Stop |
            Where-Object { $_.OriginalFileName -and ($familyInfs -contains $_.OriginalFileName.ToLower()) }
        if ($drivers) {
            $boundInfs = @(Get-PnpDevice -PresentOnly | ForEach-Object { Get-Prop $_.InstanceId 'DEVPKEY_Device_DriverInfPath' } | Where-Object { $_ })
            foreach ($origName in ($drivers | Select-Object -ExpandProperty OriginalFileName -Unique)) {
                $set  = $drivers | Where-Object OriginalFileName -eq $origName
                $keep = $set | Sort-Object Version -Descending | Select-Object -First 1
                foreach ($p in ($set | Where-Object Driver -ne $keep.Driver)) {
                    if ($boundInfs -contains $p.Driver) { $skipped += "$($p.Driver)($origName)" }
                    else {
                        Execute-Process -Path 'pnputil.exe' -Parameters "/delete-driver $($p.Driver)" -CreateNoWindow -PassThru -IgnoreExitCodes '*' | Out-Null
                        $deleted += "$($p.Driver)($origName)"
                    }
                }
            }
        }
    } catch { Write-Rca 'CLEANUP' "status=enum-failed|not=fatal" }
    Write-Rca 'CLEANUP' ("deleted={0}|skipped_bound={1}" -f `
        $(if ($deleted) { $deleted -join ',' } else { 'none' }),
        $(if ($skipped) { $skipped -join ',' } else { 'none' })) -Record

    ## ===== POST: verify + diff + (on problems) setupapi slice =====
    Set-Variable -Name 'installPhase' -Value 'Post-Install'
    $camCount = @(Get-PnpDevice -Class Camera,Image -PresentOnly).Count
    $pending = 0; $postProblems = 0; $changed = 0
    foreach ($d in (Get-PnpDevice -PresentOnly)) {
        $hw = Get-Prop $d.InstanceId 'DEVPKEY_Device_HardwareIds'
        if (-not $hw -or (($hw -join ';') -notmatch $stackRe)) { continue }
        $prob = Get-Prop $d.InstanceId 'DEVPKEY_Device_ProblemCode'
        if ($prob -eq 14) { $pending++ }
        if ($prob -and $prob -ne 0 -and $prob -ne 14) { $postProblems++ }
        if ($preState.ContainsKey($d.InstanceId)) {
            if ($preState[$d.InstanceId].drv -ne (Get-Prop $d.InstanceId 'DEVPKEY_Device_DriverVersion')) { $changed++ }
        } else { $changed++ }
    }
    Write-Rca 'POST' ("camera=$camCount|prob_nonzero=$postProblems|pending14=$pending|stack_changed=$changed") -Record

    if ($postProblems -gt 0 -or $camCount -eq 0) {
        $slice = Join-Path $stage 'setupapi_camera_slice.log'
        Select-String -Path 'C:\Windows\INF\setupapi.dev.log' -Pattern 'iacamera|hm1092|ov08x40|ov05c10|iactrllogic|iaisp|usbbridge|Vision\.inf' -ErrorAction SilentlyContinue |
            ForEach-Object { "{0}: {1}" -f $_.LineNumber, $_.Line } | Set-Content $slice -Encoding UTF8
        Write-Rca 'POST' "setupapi_slice=$slice"
    }

    Save-RcaJson $stage
    if ($pending -gt 0 -or $postProblems -gt 0) {
        Write-Rca 'EXIT' "code=3010|verdict=installed-pending-user-reboot|pending=$pending|problems=$postProblems" -Record
        Save-RcaJson $stage
        Exit-Script -ExitCode 3010
    }
    Write-Rca 'EXIT' 'code=0|verdict=installed-live-no-restart-needed' -Record
    Save-RcaJson $stage
    Exit-Script -ExitCode 0
}
Catch {
    Write-Log -Message "Deployment failed: $($_.Exception.Message)" -Severity 3 -Source 'HW9TN'
    Write-Output "HW9TN|phase=EXIT|code=1|error=$($_.Exception.Message)"
    Exit-Script -ExitCode 1
}
