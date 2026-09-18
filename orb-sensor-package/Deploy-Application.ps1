<#
.SYNOPSIS
    PSAppDeployToolkit 3.10.1 package for the Orb SENSOR (headless service)
    - install, repair, uninstall.
    Derived from the PSAppDeployToolkit 3.10.1 Deploy-Application.ps1 template
    (LGPLv3, (C) 2024 PSAppDeployToolkit Team - Sean Lillis, Dan Cunningham,
    Muhammad Mashwani). Use at your own risk.
.DESCRIPTION
    Per-machine Orb sensor deployment (network measurement service, orb.net).
    This wrapper performs the vendor install.ps1 steps NATIVELY - it does
    NOT invoke install.ps1, because its -Uninstall/-reinstall paths prompt
    via Read-Host, which cannot read piped stdin and hangs any unattended
    session (lab-proven 2026-09-15, lab VM).

    Surface created (vendor-parity, lab-verified):
      - C:\Program Files\Orb\Orb.exe           (extracted from the pinned zip)
      - Service "Orb"   - "Orb.exe windowsservice", Auto, LocalSystem,
                          failure-recovery restart x3 @60s, reset 86400
      - Inbound firewall rule "Orb" for the exe (knob: $createFirewallRule)
      - C:\ProgramData\Orb data dir (created by the service at first start)
      - Optional service Environment vars (deployment token, measure server)

    NO ARP entry, NO scheduled task, NO auto-updater (updates = redeploy a
    new pinned zip), NO shortcuts. The service is the autorun.

    COLLISION GUARD: the Orb desktop-app flavor installs an ARP entry
    (DisplayName 'Orb') and shares C:\Program Files\Orb\Orb.exe with this
    sensor - installing one on top of the other clobbers the binary. This
    package ABORTS (exit 60012) if the app flavor's ARP entry is present.
    The app package carries the mirror guard (aborts if service 'Orb'
    exists). Deploy the two packages to mutually exclusive collections.

    $zipSha256 pins the payload zip; update on version swap, '' skips.
    $deployToken is EMPTY in every repo copy (credential treatment: set at
    deploy; links the sensor to an Orb Cloud Space - token format
    orb-dt1-...). Config reaches the service via the registry Environment
    multistring (HKLM\SYSTEM\CurrentControlSet\Services\Orb\Environment).

    $measureServerEnabled: vendor default is ON (every Orb >=1.5 listens on
    TCP 7443 for inbound speed/responsiveness tests). This package DEFAULTS
    TO DISABLED (fleet security posture) via service Environment
    ORB_MEASURE_SERVER_ENABLED=0; set $true for vendor parity.

    No Show-InstallationWelcome: nothing to close (new install), silent-mode
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
    [string]$appName          = 'Orb Sensor'
    [string]$appVersion       = '1.5.5'      # constant - binary has no FileVersion; bump on payload swap
    [string]$appArch          = 'x64'
    [string]$appLang          = 'EN'
    [string]$appRevision      = '01'
    [string]$appScriptVersion = '1.0.0'
    [string]$appScriptDate    = '2026-09-17'
    [string]$appScriptAuthor  = 'endpoint engineering'

    ## Orb Cloud linking token. EMPTY in every repo copy (credential
    ## treatment: set at deploy). Reaches the service as registry
    ## Environment ORB_DEPLOYMENT_TOKEN.
    [string]$deployToken = ''

    ## Inbound firewall rule for the exe (vendor-parity; the measure server
    ## and being a test target need it).
    [bool]$createFirewallRule = $true

    ## Built-in measure server (inbound TCP 7443 listener): DISABLED by
    ## default in this package (fleet posture); $true = vendor parity.
    [bool]$measureServerEnabled = $false

    ## Payload pin - SHA-256 of orb-windows-amd64.exe.zip. Update on
    ## version swap; '' skips verification.
    [string]$zipSha256 = '3DF467CB5ADF8D9F6ABD75BA92E18FE63C9C88B94A38AB16D9ABF2E2676887CE'

    ## Payload acquisition stance: 'download-first' (default - curl.exe at
    ## deploy time, staged copy as pinned fallback), 'local-first',
    ## 'local-only'. The pin gates BOTH lanes (binary is unsigned).
    [string]$downloadStance = 'download-first'
    [string]$orbDownloadUrl = 'https://pkgs.orb.net/stable/generic/latest/orb-windows-amd64.exe.zip'

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
    ##* PAYLOAD ACQUIRE + PIN + GROUND-TRUTH ANCHORS (runtime)
    ##*===============================================
    ## Lenovo pattern: Files\Download\ = download lane target + re-run cache
    ## (exists-check first); Files\Fallback\ = pre-staged pin-guarded copy.
    ## Legacy bare Files\orb-windows-amd64.exe.zip still accepted.
    [string]$script:dirDownload = Join-Path -Path $script:dirFiles -ChildPath 'Download'
    [string]$script:dirFallback = Join-Path -Path $script:dirFiles -ChildPath 'Fallback'
    [string]$script:dlTarget    = Join-Path -Path $script:dirDownload -ChildPath 'orb-windows-amd64.exe.zip'
    [string]$script:fbTarget    = Join-Path -Path $script:dirFallback -ChildPath 'orb-windows-amd64.exe.zip'
    [string]$script:orbZip      = Join-Path -Path $script:dirFiles -ChildPath 'orb-windows-amd64.exe.zip'

    ## Payload acquisition: 'download-first' (default - curl.exe at deploy
    ## time, staged copy as pinned fallback), 'local-first', 'local-only'.
    ## The sensor binary is UNSIGNED (no Authenticode gate possible), so
    ## the SHA-256 pin gates BOTH lanes: a drifted download is refused,
    ## never adopted.
    [string]$downloadStance = 'download-first'
    [string]$orbDownloadUrl = 'https://pkgs.orb.net/stable/generic/latest/orb-windows-amd64.exe.zip'

    function Test-OrbZipPin ([string]$Path) {
        If (-not $zipSha256) { return $true }
        return ((Get-FileHash -LiteralPath $Path -Algorithm 'SHA256').Hash -eq $zipSha256.ToUpper())
    }

    function Get-OrbSensorZip {
        ## Resolves [$script:orbZip] to a PIN-TRUSTED payload path.
        $staged = @($script:fbTarget, $script:orbZip) | Where-Object { Test-Path -LiteralPath $_ -PathType 'Leaf' }
        $stagedOk = $null
        Foreach ($s in $staged) {
            If (Test-OrbZipPin $s) { $stagedOk = $s; break }
        }

        If ($downloadStance -in @('download-first', 'download-only')) {
            New-Item -Path $script:dirDownload -ItemType Directory -Force | Out-Null
            Try {
                If (Test-Path -LiteralPath $script:dlTarget) {
                    ## Re-run cache: Lenovo exists-check - pin and reuse.
                    If (-not (Test-OrbZipPin $script:dlTarget)) { Throw 'cached download zip no longer matches the pin' }
                    Write-Log -Message "ORBSENSOR_PAYLOAD source=download-cache [$($script:dlTarget)] (matches pin)."
                    $script:orbZip = $script:dlTarget
                    Return
                }
                $curl = Join-Path -Path $env:SystemRoot -ChildPath 'System32\curl.exe'
                If (-not (Test-Path -LiteralPath $curl)) { Throw "curl.exe not found at [$curl] (inbox on Windows 10 1803+)" }
                Write-Log -Message "Orb Sensor: download lane - fetching [$orbDownloadUrl] via curl.exe..."
                $null = & $curl -sSL --fail --retry 2 --connect-timeout 20 --max-time 300 -o $script:dlTarget $orbDownloadUrl
                If ($LASTEXITCODE -ne 0) { Throw "curl.exe exit $LASTEXITCODE" }
                If ((Get-Item -LiteralPath $script:dlTarget).Length -eq 0) { Throw 'downloaded payload is ZERO bytes' }
                If (-not (Test-OrbZipPin $script:dlTarget)) {
                    ## Unsigned product: the pin IS the gate - never adopt
                    ## drifted bytes. Remove the bad cache, use staged.
                    $dlHash = (Get-FileHash -LiteralPath $script:dlTarget -Algorithm 'SHA256').Hash
                    Write-Log -Message "ORBSENSOR_PAYLOAD download hash DRIFT (got $($dlHash.Substring(0,12)).. vs pin $($zipSha256.Substring(0,12))..) - unsigned product, pin is the gate; NOT adopting."
                    Remove-Item -LiteralPath $script:dlTarget -Force -ErrorAction SilentlyContinue
                    If ($stagedOk) {
                        Write-Log -Message "ORBSENSOR_PAYLOAD source=staged-fallback [$stagedOk] (download drifted, staged copy matches pin)."
                        $script:orbZip = $stagedOk
                        Return
                    }
                    Throw "download drifted from the pin and no staged fallback exists - refusing unverified bytes (re-pin after a known-good download, or stage the zip)."
                }
                Write-Log -Message 'ORBSENSOR_PAYLOAD source=download (hash matches pin).'
                $script:orbZip = $script:dlTarget
                Return
            }
            Catch {
                Write-Log -Message "ORBSENSOR_PAYLOAD download FAILED: $($_.Exception.Message)"
                Remove-Item -LiteralPath $script:dlTarget -Force -ErrorAction SilentlyContinue
                If ($downloadStance -eq 'download-only') {
                    Throw "download-only stance: download failed - $($_.Exception.Message)"
                }
            }
        }

        If ($stagedOk) {
            Write-Log -Message "ORBSENSOR_PAYLOAD source=staged-fallback [$stagedOk] (matches pin)."
            $script:orbZip = $stagedOk
            Return
        }
        If ($staged.Count -gt 0) {
            Throw "staged orb-windows-amd64.exe.zip does NOT match the SHA-256 pin and no trusted download was available - refusing to install unverified bytes."
        }
        Throw "orb-windows-amd64.exe.zip not found in [$script:dirFallback] or [$script:dirFiles] and the download lane produced nothing trusted - stage the zip or fix client internet access (stance=[$downloadStance])."
    }
    Switch ($downloadStance) {
        'download-first' { Get-OrbSensorZip }
        'download-only'  { Get-OrbSensorZip }
        'local-first'    { Get-OrbSensorZip }
        'local-only'     {
            If (-not (Test-Path -LiteralPath $script:orbZip -PathType 'Leaf')) {
                Throw "orb-windows-amd64.exe.zip not found in [$script:dirFiles] and stance=local-only - stage the payload."
            }
        }
        Default { Throw "invalid `$downloadStance [$downloadStance] - use download-first / download-only / local-first / local-only" }
    }

    If ((Get-Item -LiteralPath $script:orbZip).Length -eq 0) {
        Throw "orb-windows-amd64.exe.zip [$script:orbZip] is ZERO bytes - bad copy."
    }
    If ($zipSha256) {
        $actualHash = (Get-FileHash -Path $script:orbZip -Algorithm 'SHA256').Hash
        If ($actualHash -ne $zipSha256.ToUpper()) {
            Throw "SHA-256 mismatch on orb-windows-amd64.exe.zip (expected [$zipSha256], got [$actualHash]) - wrong or tampered payload; re-pin only after a known-good download."
        }
        Write-Log -Message "Orb Sensor: payload zip SHA-256 verified against pin."
    }
    Else {
        Write-Log -Message 'Orb Sensor: $zipSha256 empty - payload hash NOT verified.'
    }

    ## Ground truth: service + binary.
    [string]$script:orbInstalledExe = Join-Path -Path $env:ProgramFiles -ChildPath 'Orb\Orb.exe'
    [string]$script:svcName = 'Orb'

    function Get-OrbSvcState {
        $svc = Get-Service -Name $script:svcName -ErrorAction SilentlyContinue
        If ($svc) {
            $mode = (Get-CimInstance Win32_Service -Filter "Name='Orb'" -ErrorAction SilentlyContinue).StartMode
            return "$($svc.Name)=$($svc.Status)/$mode"
        }
        return 'none'
    }

    function Test-AppFlavorPresent {
        ## Desktop-app ARP entry (DisplayName exactly 'Orb') in either view.
        $views = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
        Foreach ($v in $views) {
            $hit = Get-ChildItem -Path $v -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue } |
                Where-Object { $_.DisplayName -eq 'Orb' } |
                Select-Object -First 1
            If ($hit) { return $true }
        }
        return $false
    }

    ## Post-mortem digest: one greppable line per phase for humans and AI.
    function Write-OrbSummary ([string]$Result) {
        Write-Log -Message ("ORBSVC_SUMMARY deploymenttype={0} mode={1} phase={2} user={3} computer={4} version={5} exepresent={6} service={7} firewall={8} measure_server={9} token_in_package={10} result={11}" -f `
            $DeploymentType, $DeployMode, $script:installPhase, $env:USERNAME, $env:COMPUTERNAME, $appVersion,
            $(If (Test-Path -LiteralPath $script:orbInstalledExe) { 'present' } else { 'absent' }),
            (Get-OrbSvcState),
            $(If (Get-NetFirewallRule -DisplayName 'Orb' -ErrorAction SilentlyContinue) { 'present' } else { 'absent' }),
            $measureServerEnabled, [bool]$deployToken, $Result)
    }
}
Catch {
    [int32]$mainExitCode = 60001
    Write-Output "Error in variable declaration: $($_.Exception.Message)"
    Exit $mainExitCode
}

##*===============================================
##* SHARED SERVICE STEPS
##*===============================================
function Install-OrbSensorBits {
    ## Extract + stage the binary, create/configure/start the service.
    [string]$stage = Join-Path -Path $env:Temp -ChildPath ("OrbSensor_{0}" -f [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -Path $stage -ItemType Directory -Force | Out-Null
    Try {
        Write-Log -Message "Orb Sensor: extracting payload to [$stage]..."
        Expand-Archive -Path $script:orbZip -DestinationPath $stage -Force
        $srcExe = Get-ChildItem -Path $stage -Filter '*.exe' -Recurse | Select-Object -First 1
        If (-not $srcExe) { Throw 'no .exe found inside the payload zip' }

        New-Item -Path (Join-Path -Path $env:ProgramFiles -ChildPath 'Orb') -ItemType Directory -Force | Out-Null
        ## A running Orb (either flavor) holds Orb.exe open - kill before copy
        ## or Copy-Item throws on the locked file (lab-proven 2026-09-17).
        Get-Process -Name 'Orb' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Copy-Item -Path $srcExe.FullName -Destination $script:orbInstalledExe -Force
        Write-Log -Message "Orb Sensor: binary staged to [$script:orbInstalledExe] ($((Get-Item -LiteralPath $script:orbInstalledExe).Length) bytes)."
    }
    Finally {
        Remove-Item -Path $stage -Recurse -Force -ErrorAction SilentlyContinue
    }

    If (-not (Get-Service -Name $script:svcName -ErrorAction SilentlyContinue)) {
        New-Service -Name $script:svcName `
            -BinaryPathName "$script:orbInstalledExe windowsservice" `
            -DisplayName 'Orb Service' `
            -Description 'Orb network monitoring and performance measurement service' `
            -StartupType Automatic -ErrorAction Stop | Out-Null
        Write-Log -Message 'Orb Sensor: service created.'
    }
    ## Vendor-parity failure recovery: restart x3 @60s, reset 86400.
    $null = & sc.exe failure $script:svcName reset= 86400 actions= restart/60000/restart/60000/restart/60000
    If ($LASTEXITCODE -ne 0) { Write-Log -Message "Orb Sensor: sc.exe failure returned $LASTEXITCODE (non-fatal)." }

    ## Service-scope environment (token + measure server) via registry
    ## multistring - the documented service-config method.
    $envValues = @()
    If ($deployToken) { $envValues += "ORB_DEPLOYMENT_TOKEN=$deployToken" }
    If (-not $measureServerEnabled) { $envValues += 'ORB_MEASURE_SERVER_ENABLED=0' }
    If ($envValues.Count -gt 0) {
        $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Orb'
        If (-not (Test-Path -LiteralPath $regPath)) { Throw "service registry key [$regPath] missing - service creation failed" }
        New-ItemProperty -Path $regPath -Name 'Environment' -Value $envValues -PropertyType MultiString -Force | Out-Null
        Write-Log -Message ("Orb Sensor: service Environment set (keys count {0}, token_set {1})." -f $envValues.Count, [bool]$deployToken)
    }

    If ($createFirewallRule) {
        If (-not (Get-NetFirewallRule -DisplayName 'Orb' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName 'Orb' -Direction Inbound -Program $script:orbInstalledExe -Action Allow -Profile Any -ErrorAction Stop | Out-Null
            Write-Log -Message 'Orb Sensor: inbound firewall rule created.'
        }
    }

    Start-Service -Name $script:svcName -ErrorAction Stop
}

##*===============================================
##* INSTALLATION
If ($DeploymentType -ieq 'Install') {
    [string]$installPhase = 'Pre-Installation'
    If (Test-AppFlavorPresent) {
        [int32]$mainExitCode = 60012
        Write-OrbSummary "failed-$mainExitCode"
        Write-Log -Message "Orb Sensor: desktop-app flavor detected (ARP DisplayName 'Orb') - ABORTING (exit $mainExitCode). The two flavors share C:\Program Files\Orb\Orb.exe; uninstall the app first or retarget collections."
        Exit-Script -ExitCode $mainExitCode
    }

    [string]$installPhase = 'Installation'
    Try {
        Write-Log -Message "Starting installation of [$appVendor $appName $appVersion]..."
        Install-OrbSensorBits

        [string]$installPhase = 'Post-Installation'
        If (-not (Test-Path -LiteralPath $script:orbInstalledExe)) {
            [int32]$mainExitCode = 60008
            Write-OrbSummary "failed-$mainExitCode"
            Write-Log -Message "Orb Sensor: install returned success but [$script:orbInstalledExe] is MISSING (exit $mainExitCode)."
            Exit-Script -ExitCode $mainExitCode
        }
        $svc = Get-Service -Name $script:svcName -ErrorAction SilentlyContinue
        If (-not $svc -or $svc.Status -ne 'Running') {
            [int32]$mainExitCode = 60013
            Write-OrbSummary "failed-$mainExitCode"
            Write-Log -Message "Orb Sensor: service [$script:svcName] not Running after install (exit $mainExitCode)."
            Exit-Script -ExitCode $mainExitCode
        }
        Write-Log -Message "Orb Sensor: install verified - exe=[$script:orbInstalledExe] service=[$(Get-OrbSvcState)]"
        Write-Log -Message 'Orb Sensor: NOTE - no ARP entry exists for this flavor; detection anchors on the service.'

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
##* REPAIR (stop service, re-stage binary, restart; rebuilds a stripped install)
ElseIf ($DeploymentType -ieq 'Repair') {
    [string]$installPhase = 'Pre-Repair'
    If (Test-AppFlavorPresent) {
        [int32]$mainExitCode = 60012
        Write-OrbSummary "failed-$mainExitCode"
        Write-Log -Message "Orb Sensor: desktop-app flavor detected - ABORTING repair (exit $mainExitCode)."
        Exit-Script -ExitCode $mainExitCode
    }

    [string]$installPhase = 'Repair'
    Try {
        Write-Log -Message "Starting repair of [$appName $appVersion] (stop service, re-stage binary, restart)..."
        Stop-Service -Name $script:svcName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Install-OrbSensorBits

        [string]$installPhase = 'Post-Repair'
        $svc = Get-Service -Name $script:svcName -ErrorAction SilentlyContinue
        If (-not $svc -or $svc.Status -ne 'Running') {
            [int32]$mainExitCode = 60013
            Write-OrbSummary "failed-$mainExitCode"
            Write-Log -Message "Orb Sensor: service not Running after repair (exit $mainExitCode)."
            Exit-Script -ExitCode $mainExitCode
        }
        Write-Log -Message "Orb Sensor: repair verified - service=[$(Get-OrbSvcState)]"

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
        If (-not (Test-Path -LiteralPath $script:orbInstalledExe) -and
            -not (Get-Service -Name $script:svcName -ErrorAction SilentlyContinue)) {
            ## Idempotent uninstall: nothing on disk, nothing in SCM.
            Write-Log -Message 'Orb Sensor: binary and service absent - uninstall is a no-op (already clean).'
            Write-OrbSummary 'success-noop'
            Exit-Script -ExitCode 0
        }
        Write-Log -Message "Starting uninstall of [$appName $appVersion] (native teardown - install.ps1 -Uninstall is unusable unattended: Read-Host hang, lab-proven)..."

        $svc = Get-Service -Name $script:svcName -ErrorAction SilentlyContinue
        If ($svc) {
            If ($svc.Status -eq 'Running') { Stop-Service -Name $script:svcName -Force -ErrorAction SilentlyContinue }
            $null = & sc.exe delete $script:svcName
            If ($LASTEXITCODE -ne 0) { Write-Log -Message "Orb Sensor: sc.exe delete returned $LASTEXITCODE." }
            Else { Write-Log -Message 'Orb Sensor: service deleted.' }
        }
        Get-Process -Name 'Orb' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        If (Get-NetFirewallRule -DisplayName 'Orb' -ErrorAction SilentlyContinue) {
            Remove-NetFirewallRule -DisplayName 'Orb' -ErrorAction SilentlyContinue
            Write-Log -Message 'Orb Sensor: firewall rule removed.'
        }
        Foreach ($dir in @((Join-Path -Path $env:ProgramFiles -ChildPath 'Orb'), (Join-Path -Path $env:ProgramData -ChildPath 'Orb'))) {
            If (Test-Path -LiteralPath $dir) {
                Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
                If (Test-Path -LiteralPath $dir) { Write-Log -Message "Orb Sensor: [$dir] STILL present after removal attempt." }
                Else { Write-Log -Message "Orb Sensor: [$dir] removed." }
            }
        }

        [string]$installPhase = 'Post-Uninstallation'
        If ((Test-Path -LiteralPath $script:orbInstalledExe) -or (Get-Service -Name $script:svcName -ErrorAction SilentlyContinue)) {
            [int32]$mainExitCode = 60014
            Write-OrbSummary "failed-$mainExitCode"
            Write-Log -Message "Orb Sensor: service or binary STILL present after uninstall (exit $mainExitCode)."
            Exit-Script -ExitCode $mainExitCode
        }

        Write-OrbSummary 'success'
        Write-Log -Message "Uninstall of [$appName $appVersion] complete (zero-residue design: service, firewall, files, ProgramData all removed)."
        Exit-Script -ExitCode $mainExitCode
    }
    Catch {
        [int32]$mainExitCode = 60004
        Write-OrbSummary "failed-$mainExitCode"
        Write-Log -Message "Uninstall of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
    }
}

Exit-Script -ExitCode $mainExitCode
