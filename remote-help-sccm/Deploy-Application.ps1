<#
.SYNOPSIS
    PSAppDeployToolkit 3.10.1 package for Microsoft Remote Help - install, repair, uninstall.
    Derived from the PSAppDeployToolkit 3.10.1 Deploy-Application.ps1 template
    (LGPLv3, (C) 2024 PSAppDeployToolkit Team - Sean Lillis, Dan Cunningham,
    Muhammad Mashwani). Use at your own risk.
.DESCRIPTION
    Per-machine Remote Help deployment (attended support client). The
    installer is a WiX Burn bootstrapper (no MSI inside), so there is no
    ProductCode/UpgradeCode identity: package identity is DERIVED at runtime
    from remotehelpinstaller.exe's FileVersion - version bumps are "swap the
    EXE file", nothing to edit.

    Ground-truth rule: Burn bootstrappers are an exit-0-after-failure family,
    so Post-Install verifies RemoteHelp.exe actually landed in
    C:\Program Files\Remote Help before claiming success (exit 60008 when
    the binary is missing despite a success exit code).

    The installer filename MUST stay remotehelpinstaller.exe (vendor-
    documented commands are name-coupled).

    $updateStance: 'default' (empty) = app-managed self-update, recommended
    for a support tool that must stay current enough to connect.
    'disable' = append enableAutoUpdates=0 so Intune/SCCM redeploy owns
    versions instead. acceptTerms/enableAutoUpdates are CASE SENSITIVE.

    Installer acquire is two-lane. $acquireStance 'download-first' (default)
    fetches the current build from aka.ms at deploy time - the gate is the
    Authenticode signature (signer must be Microsoft Corporation), because
    the link rotates and a hash cannot pre-pin a rotating target - with
    fallback to the staged copy in Files\Fallback\remotehelpinstaller.exe,
    which the
    $expectedSha256 pin guards instead. 'local-first' prefers the staged
    copy; 'local-only' never touches the network. Exit 60005 = no installer
    obtainable from any lane.

    No Show-InstallationWelcome: nothing to close (new app), and silent-mode
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
Try {
    ## Variables: Application
    [string]$appVendor        = 'Microsoft Corporation'
    [string]$appName          = 'Remote Help'
    [string]$appVersion       = ''            # derived from the EXE below
    [string]$appArch          = 'x64'
    [string]$appLang          = 'EN'
    [string]$appRevision      = '01'
    [string]$appScriptVersion = '1.1.1'
    [string]$appScriptDate    = '2026-09-18'
    [string]$appScriptAuthor  = 'endpoint engineering'

    ## Update stance: '' = app-managed self-update (default); 'disable' =
    ## enableAutoUpdates=0 (deploy pipeline owns versions).
    [string]$updateStance = ''

    ## Payload pin - guards the STAGED COPY in Files\ only (the download lane
    ## is gated by Authenticode signer instead, because aka.ms rotates).
    ## Update on version swap; '' skips verification.
    [string]$expectedSha256 = '9464BE6A86CFF2DB3548A298C2ED9979BECC343CB3C55A920E95D86B91D8147B'

    ## Acquire stance: 'download-first' (default) = fetch current build from
    ## aka.ms now, staged copy as fallback; 'local-first' = staged copy now,
    ## download only when absent; 'local-only' = never touch the network.
    [string]$acquireStance = 'download-first'
    [string]$rhDownloadUrl = 'https://aka.ms/downloadremotehelp'

    ## Vendor-documented silent switches (deploy.md). CASE SENSITIVE.
    [string]$rhInstallParams   = '/quiet acceptTerms=1'
    [string]$rhUninstallParams = '/uninstall /quiet acceptTerms=1'
    If ($updateStance -eq 'disable') { $rhInstallParams = "$rhInstallParams enableAutoUpdates=0" }

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
    [string]$script:dirSupportFiles = Join-Path -Path $scriptDirectory -ChildPath 'SupportFiles'

    ##*===============================================
    ##* INSTALLER ACQUIRE - two lanes, two gates (Lenovo Commercial Vantage
    ##* lineage: download-at-deploy + optional staged fallback; the download lane
    ##* gated by Authenticode signer because aka.ms rotates - a hash cannot
    ##* pre-pin a rotating target; the staged copy is gated by the SHA-256 pin).
    ##*===============================================
    # Lenovo Commercial Vantage folder convention: acquire artifacts live in
    # package subfolders - Files\Fallback\ = staged pinned copy (unarmed when
    # absent), Files\Download\ = where the runtime fetch lands.
    [string]$script:rhLocalCopy = Join-Path -Path $script:dirFiles -ChildPath 'Fallback\remotehelpinstaller.exe'
    [string]$script:rhInstaller = $null
    [string]$script:rhAcquireLane = 'none'

    Function Get-RhDownloadedInstaller {
        # Download lane: aka.ms -> TEMP; gates = file exists, non-zero,
        # Authenticode Valid + signer Microsoft Corporation. Returns path or $null.
        # Lenovo-style: the fetch lands INSIDE the package folder (Download\),
        # not %TEMP% - the acquire evidence stays with the package in ccmcache
        # (%TEMP% gets cleaned and hides the trail).
        [string]$dlDir  = Join-Path -Path $script:dirFiles -ChildPath 'Download'
        [string]$dlPath = Join-Path -Path $dlDir -ChildPath 'remotehelpinstaller.exe'
        Try {
            New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
            Remove-Item -LiteralPath $dlPath -Force -ErrorAction SilentlyContinue
            [string]$curlExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\curl.exe'
            If (-not (Test-Path -LiteralPath $curlExe -PathType 'Leaf')) { Throw "curl.exe not found at [$curlExe] (inbox on Windows 10 1803+)." }
            Write-Log -Message "Remote Help: download lane - fetching [$rhDownloadUrl] ..."
            # -IgnoreExitCodes '*': curl's nonzero exits must NOT Exit-Script the
            # deployment - the real gates are the file + signature checks below.
            Execute-Process -Path $curlExe -Parameters "-L --fail --silent --show-error --connect-timeout 20 --max-time 300 -o `"$dlPath`" `"$rhDownloadUrl`"" -WindowStyle Hidden -IgnoreExitCodes '*'
            If (-not (Test-Path -LiteralPath $dlPath -PathType 'Leaf')) { Throw 'download produced no file' }
            If ((Get-Item -LiteralPath $dlPath).Length -eq 0) { Throw 'downloaded file is ZERO bytes' }
            $sig = Get-AuthenticodeSignature -LiteralPath $dlPath
            [string]$rhSigner = If ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } Else { '(no signer certificate)' }
            If ($sig.Status -ne 'Valid' -or $rhSigner -notlike '*Microsoft Corporation*') {
                Throw "Authenticode gate FAILED (status=$($sig.Status), signer=$rhSigner) - tampered or intercepted payload; not installing it."
            }
            Write-Log -Message "Remote Help: download lane OK - signer Microsoft Corporation, size=$((Get-Item -LiteralPath $dlPath).Length) bytes, path=[$dlPath]."
            Return $dlPath
        }
        Catch {
            Write-Log -Message "Remote Help: download lane FAILED - $($_.Exception.Message)"
            Remove-Item -LiteralPath $dlPath -Force -ErrorAction SilentlyContinue
            Return $null
        }
    }

    Function Get-RhLocalInstaller {
        # Local lane: staged copy in Files\Fallback\; gates = exists, non-zero,
        # SHA-256 pin. Absent folder = unarmed (download lane covers it).
        # The vendor-documented commands are name-coupled - keep the exact filename.
        Try {
            If (-not (Test-Path -LiteralPath $script:rhLocalCopy -PathType 'Leaf')) { Throw "no staged copy at [$script:rhLocalCopy] (Fallback\ lane unarmed - fine when the download lane is available)" }
            If ((Get-Item -LiteralPath $script:rhLocalCopy).Length -eq 0) { Throw 'staged copy is ZERO bytes - bad copy' }
            If ($expectedSha256) {
                [string]$actualHash = (Get-FileHash -Path $script:rhLocalCopy -Algorithm 'SHA256').Hash
                If ($actualHash -ne $expectedSha256.ToUpper()) {
                    Throw "SHA-256 pin mismatch (expected [$expectedSha256], got [$actualHash]) - update `$expectedSha256 only after re-pinning a known-good download."
                }
            }
            Else { Write-Log -Message 'Remote Help: $expectedSha256 empty - staged copy hash NOT verified.' }
            Return $script:rhLocalCopy
        }
        Catch {
            Write-Log -Message "Remote Help: local lane FAILED - $($_.Exception.Message)"
            Return $null
        }
    }

    Switch ($acquireStance) {
        'download-first' {
            $script:rhInstaller = Get-RhDownloadedInstaller
            If ($script:rhInstaller) { $script:rhAcquireLane = 'download' }
            Else {
                $script:rhInstaller = Get-RhLocalInstaller
                If ($script:rhInstaller) { $script:rhAcquireLane = 'local-fallback' }
            }
        }
        'local-first' {
            $script:rhInstaller = Get-RhLocalInstaller
            If ($script:rhInstaller) { $script:rhAcquireLane = 'local' }
            Else {
                $script:rhInstaller = Get-RhDownloadedInstaller
                If ($script:rhInstaller) { $script:rhAcquireLane = 'download-fallback' }
            }
        }
        'local-only' {
            $script:rhInstaller = Get-RhLocalInstaller
            If ($script:rhInstaller) { $script:rhAcquireLane = 'local' }
        }
    }
    If (-not $script:rhInstaller) {
        # 60005 = no installer obtainable: stance exhausted both lanes (or
        # local-only with nothing staged). Distinct from 60001 for triage.
        [int32]$mainExitCode = 60005
        Write-Log -Message "Remote Help: NO installer obtainable (stance=$acquireStance) - exiting $mainExitCode."
        Exit $mainExitCode
    }
    Write-Log -Message "Remote Help: installer acquired via [$script:rhAcquireLane] lane - [$script:rhInstaller]"

    $appVersion = (Get-Item -LiteralPath $script:rhInstaller).VersionInfo.FileVersion
    If ([string]::IsNullOrWhiteSpace($appVersion)) { $appVersion = 'unknown' }
    Write-Log -Message "Remote Help package identity derived from EXE: FileVersion=$appVersion Path=$script:rhInstaller Lane=$script:rhAcquireLane"

    ## Ground-truth anchor: the installed binary (not the exit code).
    [string]$script:rhInstalledExe = Join-Path -Path $env:ProgramFiles -ChildPath 'Remote Help\RemoteHelp.exe'

    function Get-RhServiceState {
        $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'RHService' -or $_.DisplayName -like '*Remote Help*' }
        If ($svc) { return ($svc | ForEach-Object { "$($_.Name)=$($_.Status)/$($_.StartType)" }) -join ',' }
        return 'none'
    }

    function Get-RhArpEntry {
        $views = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
        Foreach ($v in $views) {
            $hit = Get-ChildItem -Path $v -ErrorAction SilentlyContinue |
                Where-Object { (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).DisplayName -like 'Remote Help*' } |
                Select-Object -First 1
            If ($hit) {
                $p = Get-ItemProperty -Path $hit.PSPath
                return "key=$($hit.PSChildName) version=$($p.DisplayVersion) uninstall=$($p.QuietUninstallString)"
            }
        }
        return 'none'
    }

    ## Post-mortem digest: one greppable line per phase for triage.
    function Write-RhSummary ([string]$Result) {
        Write-Log -Message ("RH_SUMMARY deploymenttype={0} mode={1} phase={2} user={3} computer={4} version={5} exepresent={6} service={7} arp={8} updatestance={9} lane={10} result={11}" -f `
            $DeploymentType, $DeployMode, $script:installPhase, $env:USERNAME, $env:COMPUTERNAME, $appVersion,
            $(If (Test-Path -LiteralPath $script:rhInstalledExe) { 'present' } else { 'absent' }),
            (Get-RhServiceState), (Get-RhArpEntry),
            $(If ($updateStance -eq 'disable') { 'disable' } else { 'default' }),
            $script:rhAcquireLane, $Result)
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
    ## No Show-InstallationWelcome: nothing to close for a new install, and
    ## silent-mode Welcome force-closes apps un-prompted - intentionally omitted.

    [string]$installPhase = 'Installation'
    Try {
        Write-Log -Message "Starting installation of [$appVendor $appName $appVersion] via [$script:rhInstaller] with params [$rhInstallParams]..."
        Execute-Process -Path $script:rhInstaller -Parameters $rhInstallParams -IgnoreExitCodes '3010,1641'

        [string]$installPhase = 'Post-Installation'
        ## Burn ground truth: the bootstrapper can exit 0 without installing.
        If (-not (Test-Path -LiteralPath $script:rhInstalledExe)) {
            [int32]$mainExitCode = 60008
            Write-RhSummary "failed-$mainExitCode"
            Write-Log -Message "Remote Help: installer returned success but [$script:rhInstalledExe] is MISSING - treating as failed install (exit $mainExitCode)."
            Exit-Script -ExitCode $mainExitCode
        }
        $installedVersion = (Get-Item -LiteralPath $script:rhInstalledExe).VersionInfo.FileVersion
        Write-Log -Message "Remote Help: install verified on disk - RemoteHelp.exe FileVersion=$installedVersion service=[$(Get-RhServiceState)] arp=[$(Get-RhArpEntry)]"

        Write-RhSummary 'success'
        Write-Log -Message "Installation of [$appName $appVersion] complete."
    }
    Catch {
        [int32]$mainExitCode = 60002
        Write-RhSummary "failed-$mainExitCode"
        Write-Log -Message "Installation of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
    }
}
##*===============================================
##* REPAIR (vendor documents no distinct repair; repair = in-place reinstall,
## which also re-lands a stripped install - the same heal think-cell repair provides)
ElseIf ($DeploymentType -ieq 'Repair') {
    [string]$installPhase = 'Pre-Repair'

    [string]$installPhase = 'Repair'
    Try {
        Write-Log -Message "Starting repair (in-place reinstall) of [$appName $appVersion]..."
        Execute-Process -Path $script:rhInstaller -Parameters $rhInstallParams -IgnoreExitCodes '3010,1641'

        [string]$installPhase = 'Post-Repair'
        If (-not (Test-Path -LiteralPath $script:rhInstalledExe)) {
            [int32]$mainExitCode = 60009
            Write-RhSummary "failed-$mainExitCode"
            Write-Log -Message "Remote Help: repair left [$script:rhInstalledExe] MISSING (exit $mainExitCode)."
            Exit-Script -ExitCode $mainExitCode
        }
        Write-Log -Message "Remote Help: repair verified on disk - RemoteHelp.exe FileVersion=$((Get-Item -LiteralPath $script:rhInstalledExe).VersionInfo.FileVersion)"

        Write-RhSummary 'success'
        Write-Log -Message "Repair of [$appName $appVersion] complete."
    }
    Catch {
        [int32]$mainExitCode = 60003
        Write-RhSummary "failed-$mainExitCode"
        Write-Log -Message "Repair of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
    }
}
##*===============================================
##* UNINSTALLATION
ElseIf ($DeploymentType -ieq 'Uninstall') {
    [string]$installPhase = 'Pre-Uninstallation'

    [string]$installPhase = 'Uninstallation'
    Try {
        If (-not (Test-Path -LiteralPath $script:rhInstalledExe)) {
            ## Idempotent uninstall: nothing on disk, nothing to remove.
            Write-Log -Message 'Remote Help: installed binary absent - uninstall is a no-op (already clean).'
            Write-RhSummary 'success-noop'
            Exit-Script -ExitCode 0
        }
        Write-Log -Message "Starting uninstall of [$appName $appVersion]..."
        ## Burn stub can exit before cleanup finishes - grace-poll below.
        Execute-Process -Path $script:rhInstaller -Parameters $rhUninstallParams -IgnoreExitCodes '3010,1641'

        [string]$installPhase = 'Post-Uninstallation'
        [int32]$graceSeconds = 0
        While ((Test-Path -LiteralPath $script:rhInstalledExe) -and $graceSeconds -lt 60) {
            Start-Sleep -Seconds 5
            $graceSeconds += 5
        }
        If (Test-Path -LiteralPath $script:rhInstalledExe) {
            Write-Log -Message "Remote Help: RemoteHelp.exe STILL present after uninstall + ${graceSeconds}s grace - async uninstaller race or failed cleanup."
        }
        Else {
            Write-Log -Message "Remote Help: RemoteHelp.exe confirmed removed (grace wait ${graceSeconds}s)."
        }

        ## Residue census (log-only; WebView2 surviving is documented behavior).
        $installDir = Join-Path -Path $env:ProgramFiles -ChildPath 'Remote Help'
        $webview2 = Test-Path -LiteralPath (Join-Path -Path $env:ProgramFiles -ChildPath 'Microsoft\EdgeWebView')
        Write-Log -Message ("RH_RESIDUE installdir={0} arp={1} webview2runtime={2} webview2_note=survives-by-design" -f `
            $(If (Test-Path -LiteralPath $installDir) { 'present' } else { 'absent' }), (Get-RhArpEntry), $(If ($webview2) { 'present' } else { 'absent' }))

        Write-RhSummary 'success'
        Write-Log -Message "Uninstall of [$appName $appVersion] complete."
        Exit-Script -ExitCode $mainExitCode
    }
    Catch {
        [int32]$mainExitCode = 60004
        Write-RhSummary "failed-$mainExitCode"
        Write-Log -Message "Uninstall of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
    }
}

Exit-Script -ExitCode $mainExitCode
