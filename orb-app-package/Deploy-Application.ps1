<#
.SYNOPSIS
    PSAppDeployToolkit 3.10.1 package for Orb - install, repair, uninstall.
    Derived from the PSAppDeployToolkit 3.10.1 Deploy-Application.ps1 template
    (LGPLv3, (C) 2024 PSAppDeployToolkit Team - Sean Lillis, Dan Cunningham,
    Muhammad Mashwani). Use at your own risk.
.DESCRIPTION
    Per-machine Orb desktop-app deployment (network-experience sensor app,
    orb.net). The installer is an NSIS bootstrapper: package identity is a
    CONSTANT below, because Orb.exe carries NO FileVersion/ProductVersion in
    its VersionInfo (lab-proven 2026-09-15) - version bumps are "swap the
    EXE + bump $appVersion + re-pin $expectedSha256".

    Ground-truth rule: Post-Install verifies C:\Program Files\Orb\Orb.exe
    landed AND the ARP entry exists before claiming success.

    Vendor-documented switches (orb.net Intune guide): /S
    /LAUNCH_AT_STARTUP=1 /START_IN_BACKGROUND=1 [/ORB_DEPLOYMENT_TOKEN=...].
    The token links the app to an Orb Cloud Space; empty = install unlinked.

    Known constraints (lab-proven): no auto-updater (versions move only via
    redeploy); NO autorun materializes until a user first launches the app
    (the LAUNCH_AT_STARTUP switch writes HKLM\SOFTWARE\Orb\MDM only); Public
    Desktop + Start Menu shortcuts are delivered by default - set
    $suppressDesktopShortcut to $true to remove the desktop one post-install.

    $expectedSha256 pins the payload; update on version swap, '' skips.

    No Show-InstallationWelcome: nothing to close (new app), silent-mode
    Welcome force-closes apps un-prompted - deliberately omitted.

.PARAMETER DeploymentType
    The type of deployment to perform. Default is: Install. Options: Install, Repair, Uninstall.
.PARAMETER DeployMode
    Interactive = Shows dialogs, Silent = No dialogs, NonInteractive = very silent.
#>
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [string]$DeploymentType = 'Install',
    [Parameter(Mandatory = $false)]
    [ValidateSet('Interactive', 'Silent', 'NonInteractive')]
    [string]$DeployMode = 'Interactive',
    [Parameter(Mandatory = $false)]
    [switch]$AllowRebootPassThru = $false,
    [Parameter(Mandatory = $false)]
    [switch]$TerminalServerMode = $false,
    [Parameter(Mandatory = $false)]
    [switch]$DisableLogging = $false
)

##*===============================================
##* VARIABLE DECLARATION
Try {
    ## Variables: Application
    [string]$appVendor        = 'Orb Forge Inc.'
    [string]$appName          = 'Orb'
    [string]$appVersion       = '1.5.5'      # constant - Orb.exe has no FileVersion; bump on payload swap
    [string]$appArch          = 'x64'
    [string]$appLang          = 'EN'
    [string]$appRevision      = '01'
    [string]$appScriptVersion = '1.0.0'
    [string]$appScriptDate    = '2026-09-15'
    [string]$appScriptAuthor  = 'endpoint engineering'

    ## Orb Cloud linking token. EMPTY in every repo copy (credential
    ## treatment: set at deploy). Format from vendor docs: orb-dt1-...
    [string]$deployToken = ''

    ## Desktop shortcut stance: $true removes the Public Desktop shortcut
    ## post-install (Start Menu shortcut always stays).
    [bool]$suppressDesktopShortcut = $false

    ## Payload pin - SHA-256 of Orb-installer.exe. Update on version swap;
    ## '' skips verification.
    [string]$expectedSha256 = '6AC4670B43CAB2AA7D3513E0FDACA599F1AA094EB037E76A579F97F733BE9709'

    ## Vendor-documented silent switches. App flavor only (sensor service is
    ## a different product on the same path - do not mix).
    [string]$orbInstallParams = '/S /LAUNCH_AT_STARTUP=1 /START_IN_BACKGROUND=1'
    If ($deployToken) { $orbInstallParams = "$orbInstallParams /ORB_DEPLOYMENT_TOKEN=$deployToken" }

    ## Variables: Script
    [int32]$mainExitCode    = 0
    [string]$scriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent

    ## Dot-source the App Deploy Toolkit
    Try {
        $modulePath = Join-Path -Path $scriptDirectory -ChildPath 'AppDeployToolkit\AppDeployToolkitMain.ps1'
        If (-not (Test-Path -LiteralPath $modulePath -PathType 'Leaf')) { Throw "Module file does not exist [$modulePath]." }
        . $modulePath
    }
    Catch [System.Management.Automation.CommandNotFoundException] {
        [int32]$mainExitCode = 60001
        Write-Output "Error failed to load the App Deploy Toolkit Module, `$mainExitCode = [$mainExitCode]"
        Exit $mainExitCode
    }
    Catch {
        [int32]$mainExitCode = 60001
        Write-Output "Error failed to load the App Deploy Toolkit Module, `$mainExitCode = [$mainExitCode]"
        Exit $mainExitCode
    }

    [string]$script:dirFiles = Join-Path -Path $scriptDirectory -ChildPath 'Files'

    ##*===============================================
    ##* PAYLOAD PIN + GROUND-TRUTH ANCHORS (runtime)
    ##*===============================================
    [string]$script:orbInstaller = Join-Path -Path $script:dirFiles -ChildPath 'Orb-installer.exe'
    If (-not (Test-Path -LiteralPath $script:orbInstaller -PathType 'Leaf')) {
        Throw "Orb-installer.exe not found in [$script:dirFiles] - keep the vendor-documented filename."
    }
    If ((Get-Item -LiteralPath $script:orbInstaller).Length -eq 0) {
        Throw "Orb-installer.exe in [$script:dirFiles] is ZERO bytes - bad copy."
    }
    If ($expectedSha256) {
        $actualHash = (Get-FileHash -Path $script:orbInstaller -Algorithm 'SHA256').Hash
        If ($actualHash -ne $expectedSha256.ToUpper()) {
            Throw "SHA-256 mismatch on Orb-installer.exe (expected [$expectedSha256], got [$actualHash]) - wrong or tampered payload; re-pin only after a known-good download."
        }
        Write-Log -Message "Orb: payload SHA-256 verified against pin."
    }
    Else {
        Write-Log -Message 'Orb: $expectedSha256 empty - payload hash NOT verified.'
    }

    ## Ground truth: installed binary + ARP entry (version lives ONLY there).
    [string]$script:orbInstalledExe = Join-Path -Path $env:ProgramFiles -ChildPath 'Orb\Orb.exe'
    [string]$script:orbUninstallExe = Join-Path -Path $env:ProgramFiles -ChildPath 'Orb\uninstall.exe'

    function Get-OrbArpEntry {
        $views = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
        Foreach ($v in $views) {
            $hit = Get-ChildItem -Path $v -ErrorAction SilentlyContinue |
                Where-Object { (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).DisplayName -eq 'Orb' } |
                Select-Object -First 1
            If ($hit) {
                $p = Get-ItemProperty -Path $hit.PSPath
                return "key=$($hit.PSChildName) version=$($p.DisplayVersion)"
            }
        }
        return 'none'
    }

    function Get-OrbMdmState {
        $k = 'HKLM:\SOFTWARE\Orb\MDM'
        If (-not (Test-Path -LiteralPath $k)) { return 'absent' }
        $p = Get-ItemProperty -Path $k
        return ("LaunchAtStartup={0} StartInBackground={1} token_set={2}" -f $p.LaunchAtStartup, $p.StartInBackground, [bool]$p.OrbDeploymentToken)
    }

    function Test-SensorFlavorPresent {
        ## Sensor flavor = service 'Orb' (the desktop app installs no service).
        If (Get-Service -Name 'Orb' -ErrorAction SilentlyContinue) { return $true }
        return $false
    }

    ## Post-mortem digest: one greppable line per phase for humans and AI.
    function Write-OrbSummary ([string]$Result) {
        Write-Log -Message ("ORB_SUMMARY deploymenttype={0} mode={1} phase={2} user={3} computer={4} version={5} exepresent={6} arp={7} mdm={8} token_in_package={9} result={10}" -f `
            $DeploymentType, $DeployMode, $script:installPhase, $env:USERNAME, $env:COMPUTERNAME, $appVersion,
            $(If (Test-Path -LiteralPath $script:orbInstalledExe) { 'present' } else { 'absent' }),
            (Get-OrbArpEntry), (Get-OrbMdmState), [bool]$deployToken, $Result)
    }
}
Catch {
    [int32]$mainExitCode = 60001
    Write-Output "Error in variable declaration: $($_.Exception.Message)"
    Exit $mainExitCode
}

##*===============================================
##* INSTALLATION
If ($DeploymentType -ieq 'Install') {
    [string]$installPhase = 'Pre-Installation'
    If (Test-SensorFlavorPresent) {
        [int32]$mainExitCode = 60012
        Write-OrbSummary "failed-$mainExitCode"
        Write-Log -Message "Orb: SENSOR flavor detected (service 'Orb') - ABORTING (exit $mainExitCode). The two flavors share C:\Program Files\Orb\Orb.exe; uninstall the sensor first or retarget collections."
        Exit-Script -ExitCode $mainExitCode
    }
    ## No Show-InstallationWelcome: nothing to close for a new install.

    [string]$installPhase = 'Installation'
    Try {
        Write-Log -Message "Starting installation of [$appVendor $appName $appVersion] via [$script:orbInstaller] with params [$orbInstallParams]..."
        Execute-Process -Path $script:orbInstaller -Parameters $orbInstallParams -IgnoreExitCodes '3010,1641'

        [string]$installPhase = 'Post-Installation'
        If (-not (Test-Path -LiteralPath $script:orbInstalledExe)) {
            [int32]$mainExitCode = 60008
            Write-OrbSummary "failed-$mainExitCode"
            Write-Log -Message "Orb: installer returned success but [$script:orbInstalledExe] is MISSING - treating as failed install (exit $mainExitCode)."
            Exit-Script -ExitCode $mainExitCode
        }
        If ((Get-OrbArpEntry) -eq 'none') {
            [int32]$mainExitCode = 60010
            Write-OrbSummary "failed-$mainExitCode"
            Write-Log -Message "Orb: binary present but ARP entry MISSING - treating as failed install (exit $mainExitCode)."
            Exit-Script -ExitCode $mainExitCode
        }
        If ($suppressDesktopShortcut) {
            $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
            Remove-File -Path (Join-Path -Path $publicDesktop -ChildPath 'Orb.lnk')
            Write-Log -Message "Orb: desktop shortcut suppression requested - removed [$publicDesktop\Orb.lnk] if present."
        }
        Write-Log -Message "Orb: install verified - exe=[$script:orbInstalledExe] arp=[$(Get-OrbArpEntry)] mdm=[$(Get-OrbMdmState)] NOTE=no-autorun-until-first-user-launch"

        Write-OrbSummary 'success'
        Write-Log -Message "Installation of [$appName $appVersion] complete."
    }
    Catch {
        [int32]$mainExitCode = 60002
        Write-OrbSummary "failed-$mainExitCode"
        Write-Log -Message "Installation of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
    }
}
##*===============================================
##* REPAIR (vendor documents no distinct repair; repair = in-place reinstall)
ElseIf ($DeploymentType -ieq 'Repair') {
    [string]$installPhase = 'Pre-Repair'
    If (Test-SensorFlavorPresent) {
        [int32]$mainExitCode = 60012
        Write-OrbSummary "failed-$mainExitCode"
        Write-Log -Message "Orb: SENSOR flavor detected (service 'Orb') - ABORTING repair (exit $mainExitCode)."
        Exit-Script -ExitCode $mainExitCode
    }

    [string]$installPhase = 'Repair'
    Try {
        Write-Log -Message "Starting repair (in-place reinstall) of [$appName $appVersion]..."
        Execute-Process -Path $script:orbInstaller -Parameters $orbInstallParams -IgnoreExitCodes '3010,1641'

        [string]$installPhase = 'Post-Repair'
        If (-not (Test-Path -LiteralPath $script:orbInstalledExe)) {
            [int32]$mainExitCode = 60009
            Write-OrbSummary "failed-$mainExitCode"
            Write-Log -Message "Orb: repair left [$script:orbInstalledExe] MISSING (exit $mainExitCode)."
            Exit-Script -ExitCode $mainExitCode
        }
        Write-Log -Message "Orb: repair verified - arp=[$(Get-OrbArpEntry)]"

        Write-OrbSummary 'success'
        Write-Log -Message "Repair of [$appName $appVersion] complete."
    }
    Catch {
        [int32]$mainExitCode = 60003
        Write-OrbSummary "failed-$mainExitCode"
        Write-Log -Message "Repair of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
    }
}
##*===============================================
##* UNINSTALLATION
ElseIf ($DeploymentType -ieq 'Uninstall') {
    [string]$installPhase = 'Pre-Uninstallation'

    [string]$installPhase = 'Uninstallation'
    Try {
        If (-not (Test-Path -LiteralPath $script:orbInstalledExe)) {
            ## Idempotent uninstall: nothing on disk, nothing to remove.
            Write-Log -Message 'Orb: installed binary absent - uninstall is a no-op (already clean).'
            Write-OrbSummary 'success-noop'
            Exit-Script -ExitCode 0
        }
        If (-not (Test-Path -LiteralPath $script:orbUninstallExe)) {
            [int32]$mainExitCode = 60011
            Write-OrbSummary "failed-$mainExitCode"
            Write-Log -Message "Orb: Orb.exe present but uninstall.exe MISSING - cannot uninstall safely (exit $mainExitCode)."
            Exit-Script -ExitCode $mainExitCode
        }
        ## A RUNNING Orb holds Orb.exe open: the NSIS uninstaller then exits 0
        ## while silently leaving the binary (lab-proven 2026-09-17, lab VM).
        ## Kill first - kill != removal, this is access-for-the-uninstaller.
        Get-Process -Name 'Orb' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Log -Message "Starting uninstall of [$appName $appVersion]..."
        Execute-Process -Path $script:orbUninstallExe -Parameters '/S' -IgnoreExitCodes '3010,1641'

        [string]$installPhase = 'Post-Uninstallation'
        [int32]$graceSeconds = 0
        While ((Test-Path -LiteralPath $script:orbInstalledExe) -and $graceSeconds -lt 60) {
            Start-Sleep -Seconds 5
            $graceSeconds += 5
        }
        If (Test-Path -LiteralPath $script:orbInstalledExe) {
            [int32]$mainExitCode = 60015
            Write-OrbSummary "failed-$mainExitCode"
            Write-Log -Message "Orb: Orb.exe STILL present after uninstall + ${graceSeconds}s grace (exit $mainExitCode) - locked files or failed cleanup; SCCM retry should succeed now that processes are killed first."
            Exit-Script -ExitCode $mainExitCode
        }
        Else {
            Write-Log -Message "Orb: Orb.exe confirmed removed (grace wait ${graceSeconds}s)."
        }

        ## Residue census (log-only; round-1 lab result = vendor uninstall is zero-residue).
        $installDir = Join-Path -Path $env:ProgramFiles -ChildPath 'Orb'
        Write-Log -Message ("ORB_RESIDUE installdir={0} arp={1} mdm={2}" -f `
            $(If (Test-Path -LiteralPath $installDir) { 'present' } else { 'absent' }), (Get-OrbArpEntry), (Get-OrbMdmState))

        Write-OrbSummary 'success'
        Write-Log -Message "Uninstall of [$appName $appVersion] complete."
        Exit-Script -ExitCode $mainExitCode
    }
    Catch {
        [int32]$mainExitCode = 60004
        Write-OrbSummary "failed-$mainExitCode"
        Write-Log -Message "Uninstall of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
    }
}

Exit-Script -ExitCode $mainExitCode
