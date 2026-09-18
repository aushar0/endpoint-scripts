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
    its VersionInfo (lab-proven) - version bumps are "swap the EXE + bump
    $appVersion + re-pin $expectedSha256".

    Payload acquisition (Lenovo pattern): Files\Download\ = download lane
    target + re-run cache (exists-check first, no re-download);
    Files\Fallback\ = pre-staged pin-guarded copy (legacy bare
    Files\Orb-installer.exe still accepted). 'download-first' (default)
    curl.exe-fetches at deploy time, gated by Authenticode (signer must be
    Orb Forge - the vendor URL rotates, so a hash cannot pre-pin the
    download). The staged fallback is gated by the SHA-256 pin instead.
    No trusted lane = fail-closed. Never installs unverified bytes.

    COLLISION GUARD: the Orb SENSOR flavor installs a service named "Orb"
    and shares C:\Program Files\Orb\Orb.exe with this app - this package
    ABORTS (exit 60012) if the sensor service is present. The sensor
    package carries the mirror guard. Deploy to disjoint collections.

    Known constraints (lab-proven): no auto-updater (versions move only by
    redeploy); NO autorun materializes until a user first launches the app
    (the LAUNCH_AT_STARTUP switch writes HKLM\SOFTWARE\Orb\MDM only);
    Public Desktop + Start Menu shortcuts are delivered by default - set
    $suppressDesktopShortcut to $true to remove the desktop one
    post-install.

    No Show-InstallationWelcome: nothing to close (new app), silent-mode
    Welcome still closes apps un-prompted - deliberately omitted.

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
##*===============================================
Try {
    ## Variables: Application
    [string]$appVendor        = 'Orb Forge Inc.'
    [string]$appName          = 'Orb'
    [string]$appVersion       = '1.5.5'      # constant - Orb.exe has no FileVersion; bump on payload swap
    [string]$appArch          = 'x64'
    [string]$appLang          = 'EN'
    [string]$appRevision      = '01'
    [string]$appScriptVersion = '1.2.0'
    [string]$appScriptDate    = '2026-09-18'
    [string]$appScriptAuthor  = 'endpoint engineering'

    ## Orb Cloud linking token. EMPTY in every repo copy (credential
    ## treatment: set at deploy). Format from vendor docs: orb-dt1-...
    [string]$deployToken = ''

    ## Desktop shortcut stance: $true removes the Public Desktop shortcut
    ## post-install (Start Menu shortcut always stays).
    [bool]$suppressDesktopShortcut = $false

    ## Payload pin - SHA-256 of Orb-installer.exe. Guards the STAGED
    ## fallback copy; update on version swap; '' skips verification.
    ## The download lane is Authenticode-gated instead (URL rotates).
    [string]$expectedSha256 = '6AC4670B43CAB2AA7D3513E0FDACA599F1AA094EB037E76A579F97F733BE9709'

    ## Payload acquisition stance: 'download-first' (default - curl.exe at
    ## deploy time, staged copy as pinned fallback), 'local-first',
    ## 'local-only'.
    [string]$downloadStance = 'download-first'
    [string]$orbDownloadUrl = 'https://pkgs.orb.net/earlyaccess/windows/Orb-installer.exe'

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
    ##* CUSTOM FUNCTIONS - ORB PACKAGE
    ##* (everything in this block is package-specific; the phases below
    ##*  call into these - nothing else here is custom)
    ##*===============================================

    ## Lenovo pattern: Files\Download\ = download lane target + re-run cache
    ## (exists-check first, no re-download); Files\Fallback\ = pre-staged
    ## pin-guarded copy. Legacy bare Files\Orb-installer.exe still accepted.
    [string]$script:dirDownload = Join-Path -Path $script:dirFiles -ChildPath 'Download'
    [string]$script:dirFallback = Join-Path -Path $script:dirFiles -ChildPath 'Fallback'
    [string]$script:dlTarget    = Join-Path -Path $script:dirDownload -ChildPath 'Orb-installer.exe'
    [string]$script:fbTarget    = Join-Path -Path $script:dirFallback -ChildPath 'Orb-installer.exe'
    [string]$script:orbInstaller = Join-Path -Path $script:dirFiles -ChildPath 'Orb-installer.exe'

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

    function Test-OrbInstallerSig ([string]$Path) {
        ## Authenticode gate: the vendor URL rotates, so the download lane
        ## trusts the SIGNER, not a hash.
        $sig = Get-AuthenticodeSignature -FilePath $Path
        If ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike '*Orb Forge*') {
            Throw "payload failed the Authenticode gate (status=$($sig.Status) signer=[$($sig.SignerCertificate.Subject)]) [$Path]"
        }
    }

    function Test-OrbInstallerPin ([string]$Path) {
        If ($expectedSha256) {
            $h = (Get-FileHash -LiteralPath $Path -Algorithm 'SHA256').Hash
            If ($h -ne $expectedSha256.ToUpper()) {
                Write-Log -Message "ORB_PAYLOAD hash DRIFT vs pin (got $($h.Substring(0,12))..) [$Path] - acceptable for the download lane (signature-gated), fatal for the staged fallback."
            }
            Return ($h -eq $expectedSha256.ToUpper())
        }
        Return $true
    }

    function Get-OrbPayload {
        ## Resolves [$script:orbInstaller] to a TRUSTED payload path.
        $staged = @($script:fbTarget, $script:orbInstaller) | Where-Object { Test-Path -LiteralPath $_ -PathType 'Leaf' }
        $stagedOk = $null
        Foreach ($s in $staged) {
            If (Test-OrbInstallerPin $s) { $stagedOk = $s; break }
        }

        If ($downloadStance -in @('download-first', 'download-only')) {
            New-Item -Path $script:dirDownload -ItemType Directory -Force | Out-Null
            Try {
                If (Test-Path -LiteralPath $script:dlTarget) {
                    ## Re-run cache: exists-check - gate and reuse.
                    Test-OrbInstallerSig $script:dlTarget
                    Write-Log -Message "ORB_PAYLOAD source=download-cache [$($script:dlTarget)] (signature gate passed)."
                    $script:orbInstaller = $script:dlTarget
                    Return
                }
                $curl = Join-Path -Path $env:SystemRoot -ChildPath 'System32\curl.exe'
                If (-not (Test-Path -LiteralPath $curl)) { Throw "curl.exe not found at [$curl] (inbox on Windows 10 1803+)" }
                Write-Log -Message "Orb: download lane - fetching [$orbDownloadUrl] via curl.exe..."
                $null = & $curl -sSL --fail --retry 2 --connect-timeout 20 --max-time 300 -o $script:dlTarget $orbDownloadUrl
                If ($LASTEXITCODE -ne 0) { Throw "curl.exe exit $LASTEXITCODE" }
                If ((Get-Item -LiteralPath $script:dlTarget).Length -eq 0) { Throw 'downloaded payload is ZERO bytes' }
                Test-OrbInstallerSig $script:dlTarget
                $null = Test-OrbInstallerPin $script:dlTarget   # drift = logged, signature already passed
                Write-Log -Message 'ORB_PAYLOAD source=download (Authenticode gate passed).'
                $script:orbInstaller = $script:dlTarget
                Return
            }
            Catch {
                Write-Log -Message "ORB_PAYLOAD download FAILED: $($_.Exception.Message)"
                Remove-Item -LiteralPath $script:dlTarget -Force -ErrorAction SilentlyContinue
                If ($downloadStance -eq 'download-only') {
                    Throw "download-only stance: download failed - $($_.Exception.Message)"
                }
            }
        }

        If ($stagedOk) {
            Write-Log -Message "ORB_PAYLOAD source=staged-fallback [$stagedOk] (matches pin)."
            $script:orbInstaller = $stagedOk
            Return
        }
        If ($staged.Count -gt 0) {
            Throw "staged Orb-installer.exe does NOT match the SHA-256 pin and no trusted download was available - refusing to install unverified bytes; re-pin or re-stage a known-good copy."
        }
        Throw "Orb-installer.exe not found in [$script:dirFallback] or [$script:dirFiles] and the download lane produced nothing trusted - stage the exe or fix client internet access (stance=[$downloadStance])."
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
##* PRE-INSTALLATION
##*===============================================
[string]$installPhase = 'Pre-Installation'

## > Perform pre-installation tasks here >

## Collision guard: the sensor flavor shares C:\Program Files\Orb\Orb.exe.
If (Test-SensorFlavorPresent) {
    [int32]$mainExitCode = 60012
    Write-OrbSummary "failed-$mainExitCode"
    Write-Log -Message "Orb: SENSOR flavor detected (service 'Orb') - ABORTING (exit $mainExitCode). The two flavors share C:\Program Files\Orb\Orb.exe; uninstall the sensor first or retarget collections."
    Exit-Script -ExitCode $mainExitCode
}


##*===============================================
##* INSTALLATION
##*===============================================
[string]$installPhase = 'Installation'
Try {
    ## > Perform installation tasks here >

    ## Payload: download lane (curl.exe, Authenticode-gated) with the staged
    ## pin-guarded fallback. No Show-InstallationWelcome: nothing to close.
    Get-OrbPayload

    Write-Log -Message "Starting installation of [$appVendor $appName $appVersion] via [$script:orbInstaller] with params [$orbInstallParams]..."
    Execute-Process -Path $script:orbInstaller -Parameters $orbInstallParams -IgnoreExitCodes '3010,1641'
}
Catch {
    [int32]$mainExitCode = 60002
    Write-OrbSummary "failed-$mainExitCode"
    Write-Log -Message "Installation of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
}


##*===============================================
##* POST-INSTALLATION
##*===============================================
[string]$installPhase = 'Post-Installation'
Try {
    ## > Perform post-installation tasks here >

    ## Ground truth: binary AND ARP entry must exist (NSIS exit-0 lie guard).
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
    Write-Log -Message "Post-installation of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
}


##*===============================================
##* PRE-REPAIR
##*===============================================
[string]$installPhase = 'Pre-Repair'

## > Perform pre-repair tasks here >

## Collision guard: never repair across flavors.
If (Test-SensorFlavorPresent) {
    [int32]$mainExitCode = 60012
    Write-OrbSummary "failed-$mainExitCode"
    Write-Log -Message "Orb: SENSOR flavor detected (service 'Orb') - ABORTING repair (exit $mainExitCode)."
    Exit-Script -ExitCode $mainExitCode
}


##*===============================================
##* REPAIR (vendor documents no distinct repair; repair = in-place reinstall)
##*===============================================
[string]$installPhase = 'Repair'
Try {
    ## > Perform repair tasks here >

    Write-Log -Message "Starting repair (in-place reinstall) of [$appName $appVersion]..."
    Get-OrbPayload
    Execute-Process -Path $script:orbInstaller -Parameters $orbInstallParams -IgnoreExitCodes '3010,1641'
}
Catch {
    [int32]$mainExitCode = 60003
    Write-OrbSummary "failed-$mainExitCode"
    Write-Log -Message "Repair of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
}


##*===============================================
##* POST-REPAIR
##*===============================================
[string]$installPhase = 'Post-Repair'
Try {
    ## > Perform post-repair tasks here >

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
    Write-Log -Message "Post-repair of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
}


##*===============================================
##* PRE-UNINSTALLATION
##*===============================================
[string]$installPhase = 'Pre-Uninstallation'

## > Perform pre-uninstallation tasks here >


##*===============================================
##* UNINSTALLATION
##*===============================================
[string]$installPhase = 'Uninstallation'
Try {
    ## > Perform uninstallation tasks here >

    ## Idempotent uninstall: nothing on disk, nothing to remove.
    If (-not (Test-Path -LiteralPath $script:orbInstalledExe)) {
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
    ## while silently leaving the binary (lab-proven). Kill first - kill
    ## != removal, this is access-for-the-uninstaller.
    Get-Process -Name 'Orb' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Write-Log -Message "Starting uninstall of [$appName $appVersion]..."
    Execute-Process -Path $script:orbUninstallExe -Parameters '/S' -IgnoreExitCodes '3010,1641'
}
Catch {
    [int32]$mainExitCode = 60004
    Write-OrbSummary "failed-$mainExitCode"
    Write-Log -Message "Uninstallation of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
}


##*===============================================
##* POST-UNINSTALLATION
##*===============================================
[string]$installPhase = 'Post-Uninstallation'
Try {
    ## > Perform post-uninstallation tasks here >

    ## Grace-poll the async NSIS uninstaller, then fail loud on leftovers.
    [int32]$graceSeconds = 0
    While ((Test-Path -LiteralPath $script:orbInstalledExe) -and $graceSeconds -lt 60) {
        Start-Sleep -Seconds 5
        $graceSeconds += 5
    }
    If (Test-Path -LiteralPath $script:orbInstalledExe) {
        [int32]$mainExitCode = 60015
        Write-OrbSummary "failed-$mainExitCode"
        Write-Log -Message "Orb: Orb.exe STILL present after uninstall + ${graceSeconds}s grace (exit $mainExitCode) - locked files or failed cleanup; retry should succeed now that processes are killed first."
        Exit-Script -ExitCode $mainExitCode
    }
    Write-Log -Message "Orb: Orb.exe confirmed removed (grace wait ${graceSeconds}s)."

    ## Residue census (log-only; lab result = vendor uninstall is zero-residue).
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
    Write-Log -Message "Post-uninstallation of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
}


##*===============================================
##* END OF SCRIPT
##*===============================================
Exit-Script -ExitCode $mainExitCode
