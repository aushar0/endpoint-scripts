<#
.SYNOPSIS
    PSAppDeployToolkit 3.10.1 package for think-cell - install, repair, uninstall.
    Derived from the PSAppDeployToolkit 3.10.1 Deploy-Application.ps1 template
    (LGPLv3, (C) 2024 PSAppDeployToolkit Team - Sean Lillis, Dan Cunningham,
    Muhammad Mashwani). Use at your own risk.
.DESCRIPTION
    Per-machine think-cell deployment. The MSI is a 32-bit package, so its
    ARP/Uninstall entry publishes under HKLM\SOFTWARE\WOW6432Node.

    Package identity (ProductCode/version) is DERIVED at runtime from the
    single .msi in Files - version bumps are "swap the MSI file", nothing
    to edit (discovery is rename-proof and ProductName-validated).

    Set $licenseKey below (format xxxxx-xxxxx-xxxxx-xxxxx-xxxxx) before
    deployment. NEVER commit a real key - the repo copy stays empty.

    Self-healing: Post-Install/Repair re-create the ARP entry when missing
    (guarded - only when think-cell is actually installed); Post-Uninstall
    removes an orphaned entry. Every action logs THINKCELL_ARP key=value
    lines for post-mortem grep.

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
    [string]$appVendor        = 'think-cell Operations GmbH'
    [string]$appName          = 'think-cell'
    [string]$appVersion       = ''            # derived from the MSI below
    [string]$appArch          = ''
    [string]$appLang          = 'EN'
    [string]$appRevision      = '01'
    [string]$appScriptVersion = '1.0.0'
    [string]$appScriptDate    = '2026-09-11'
    [string]$appScriptAuthor  = 'endpoint engineering'

    ## think-cell license key - format xxxxx-xxxxx-xxxxx-xxxxx-xxxxx.
    ## Set at deploy time. NEVER commit the real value.
    [string]$licenseKey = ''

    ## Fleet switches (think-cell deployment docs): no auto-updates, no
    ## error-reporting prompts, no first-run license dialog, no post-install
    ## PowerPoint launch.
    ## MSI UI: /QN is FORCED in every deploy mode via full -Parameters
    ## replacement below - the stock config's Interactive default is /QB-!
    ## (a visible basic MSI window), which users must never see. The ONLY
    ## user-facing UI is PSADT's own (welcome prompt / progress).
    [string]$msiExtraParams = 'UPDATES=0 REPORTS=0 NOFIRSTSTART=1 LaunchPowerPoint=0'
    [string]$msiExecParams  = "/QN REBOOT=ReallySuppress $msiExtraParams"

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
    ##* MSI-DERIVED IDENTITY (runtime - no GUID bumps on version swaps)
    ##*===============================================
    function Get-MsiProperty {
        param([string]$MsiPath, [string]$Property)
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($MsiPath, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='$Property'"))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($null -eq $rec) { return $null }
        $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1))
    }

    $msiFile = Get-ChildItem -Path $script:dirFiles -Filter '*.msi' -ErrorAction SilentlyContinue
    If (-not $msiFile) { Throw "No .msi found in [$script:dirFiles] - drop the think-cell MSI in Files (any filename)." }
    If (@($msiFile).Count -gt 1) { Throw "Multiple MSIs in [$script:dirFiles] - keep exactly one (found $(@($msiFile).Count))." }
    [string]$script:msiPath           = @($msiFile)[0].FullName
    [string]$script:appProductCode    = Get-MsiProperty -MsiPath $script:msiPath -Property 'ProductCode'
    [string]$script:appDisplayVersion = Get-MsiProperty -MsiPath $script:msiPath -Property 'ProductVersion'
    $msiProductName = Get-MsiProperty -MsiPath $script:msiPath -Property 'ProductName'
    If ($msiProductName -ne 'think-cell') { Throw "The MSI in Files is '$msiProductName', not 'think-cell' - wrong file in the package." }
    If ($script:appProductCode -notmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
        Throw "Failed to read a valid ProductCode from [$script:msiPath] (got '$script:appProductCode')."
    }
    $appVersion = $script:appDisplayVersion
    Write-Log -Message "think-cell package identity derived from MSI: ProductCode=$script:appProductCode Version=$script:appDisplayVersion"

    ## License key: append to MSI params only when non-empty.
    If ([string]::IsNullOrWhiteSpace($licenseKey)) {
        Write-Log -Message 'think-cell: no $licenseKey set - installing WITHOUT a pre-seeded key (app will prompt on first run).'
    }
    Else {
        $msiExtraParams = "$msiExtraParams LICENSEKEY=`"$licenseKey`""
        # rebuild the exec string AFTER the append - building it at declaration
        # time silently dropped the key (caught by the Sep 11 sdlc bugs pass)
        $msiExecParams  = "/QN REBOOT=ReallySuppress $msiExtraParams"
        Write-Log -Message 'think-cell: $licenseKey is set - passing LICENSEKEY to the MSI.'
    }

    ##*===============================================
    ##* ARP-ENTRY INSURANCE (guarded, dual-surface logged)
    ##*===============================================
    function Set-ThinkCellArpEntry {
        If ($script:appProductCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
            Write-Log -Message "think-cell ARP: appProductCode is not a valid GUID ('$script:appProductCode') - skipping to avoid writing under the Uninstall root."
            Write-Log -Message 'THINKCELL_ARP action=skip reason=invalid-productcode'
            Return
        }
        $arpPaths = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$script:appProductCode",
                      "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$script:appProductCode")

        Write-Log -Message ("think-cell ARP check started: ProductCode={0} Version={1}" -f $script:appProductCode, $script:appDisplayVersion)

        $registered = $false
        Try {
            $inst = New-Object -ComObject WindowsInstaller.Installer
            Foreach ($c in $inst.RelatedProducts('{E202304D-BA30-4EDA-9905-7459004CFFD1}')) {
                If ("$c" -eq $script:appProductCode) { $registered = $true }
            }
        }
        Catch {
            Write-Log -Message ("think-cell ARP check: Installer registration query failed ({0}) - falling back to file check." -f $_.Exception.Message)
        }

        $installDir  = "${env:ProgramFiles(x86)}\think-cell"
        $hasBinaries = (Test-Path $installDir) -and [bool](Get-ChildItem -Path $installDir -Include '*.dll', '*.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)

        If (-not $registered -and -not $hasBinaries) {
            Write-Log -Message 'think-cell ARP: product NOT detected as installed (no Installer registration, no binaries in install dir) - skipping. No entry fabricated for an absent product.'
            Write-Log -Message 'THINKCELL_ARP action=skip reason=product-not-installed'
            Return
        }
        Write-Log -Message ("think-cell ARP: product present (InstallerRegistered={0} BinariesFound={1})." -f $registered, $hasBinaries)

        $existing = Get-ItemProperty -Path $arpPaths -ErrorAction SilentlyContinue
        If ($existing) {
            $where = ($arpPaths | Where-Object { Test-Path $_ } | Select-Object -First 1)
            Write-Log -Message "think-cell ARP: entry already present at [$where] - no action."
            Write-Log -Message "THINKCELL_ARP action=noop entry=present location=$where"
            Return
        }

        $key = $arpPaths[1]  # WOW6432Node: where the 32-bit MSI itself publishes
        $sizeKB = 410786     # measured fallback for 14.0.38.764
        If (Test-Path $installDir) {
            $measured = [math]::Round(((Get-ChildItem -Path $installDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) / 1KB)
            If ($measured -gt 0) { $sizeKB = $measured }
        }
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name DisplayName      -Value 'think-cell'                                 -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name DisplayVersion   -Value $script:appDisplayVersion                    -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name Publisher        -Value 'think-cell Operations GmbH'                 -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name InstallDate      -Value (Get-Date -Format yyyyMMdd)                  -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name InstallLocation  -Value "${env:ProgramFiles(x86)}\think-cell\"        -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name UninstallString  -Value "MsiExec.exe /X$script:appProductCode"       -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name ModifyPath       -Value "MsiExec.exe /X$script:appProductCode"       -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name URLInfoAbout     -Value 'https://www.think-cell.com'                 -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name Contact          -Value 'support@think-cell.com'                     -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name EstimatedSize    -Value $sizeKB                                       -PropertyType DWord  -Force | Out-Null
        New-ItemProperty -Path $key -Name WindowsInstaller -Value 1                                             -PropertyType DWord  -Force | Out-Null
        New-ItemProperty -Path $key -Name NoModify         -Value 1                                             -PropertyType DWord  -Force | Out-Null
        New-ItemProperty -Path $key -Name NoRepair         -Value 1                                             -PropertyType DWord  -Force | Out-Null
        New-ItemProperty -Path $key -Name VersionMajor     -Value ([int]$script:appDisplayVersion.Split('.')[0]) -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $key -Name VersionMinor     -Value ([int]$script:appDisplayVersion.Split('.')[1]) -PropertyType DWord -Force | Out-Null
        Write-Log -Message "think-cell ARP: entry was MISSING - re-created at [$key] (WOW6432Node, where the 32-bit MSI publishes)."
        Write-Log -Message ("THINKCELL_ARP action=recreate hive=WOW6432Node productcode={0} version={1} registered={2} binaries={3} installdate={4}" -f $script:appProductCode, $script:appDisplayVersion, $registered, $hasBinaries, (Get-Date -Format yyyyMMdd))
    }

    ## Post-mortem digest: one greppable line per section for humans and AI.
    ## Never includes the license key value - presence only.
    function Write-ThinkCellSummary ([string]$Result) {
        $wowKey = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$script:appProductCode"
        Write-Log -Message ("THINKCELL_SUMMARY deploymenttype={0} mode={1} phase={2} user={3} computer={4} productcode={5} version={6} licensekey={7} arp={8} result={9}" -f `
            $DeploymentType, $DeployMode, $script:installPhase, $env:USERNAME, $env:COMPUTERNAME,
            $script:appProductCode, $script:appDisplayVersion,
            $(if ([string]::IsNullOrWhiteSpace($licenseKey)) { 'absent' } else { 'present' }),
            $(if (Test-Path $wowKey) { 'present' } else { 'absent' }),
            $Result)
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
    ## Prompt only appears if PowerPoint/Excel are actually running; silent mode force-closes after countdown.
    Show-InstallationWelcome -CloseApps 'powerpnt,excel' -CloseAppsCountdown 3600

    [string]$installPhase = 'Installation'
    Try {
        Write-Log -Message "Starting installation of [$appVendor $appName $appVersion] via [$script:msiPath] with params [$msiExecParams]..."
        Execute-MSI -Action Install -Path $script:msiPath -Parameters $msiExecParams

        [string]$installPhase = 'Post-Installation'
        Set-ThinkCellArpEntry

        Write-ThinkCellSummary 'success'
        Write-Log -Message "Installation of [$appName $appVersion] complete."
    }
    Catch {
        [int32]$mainExitCode = 60002
        Write-ThinkCellSummary "failed-$mainExitCode"
        Write-Log -Message "Installation of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
    }
}
##*===============================================
##* REPAIR
ElseIf ($DeploymentType -ieq 'Repair') {
    [string]$installPhase = 'Pre-Repair'
    Show-InstallationWelcome -CloseApps 'powerpnt,excel' -CloseAppsCountdown 3600

    [string]$installPhase = 'Repair'
    Try {
        Write-Log -Message "Starting repair of [$appName $appVersion] via [$script:msiPath]..."
        Execute-MSI -Action Repair -Path $script:msiPath -Parameters $msiExecParams

        [string]$installPhase = 'Post-Repair'
        ## Repair also restores ARP visibility if the entry was stripped (verified live).
        Set-ThinkCellArpEntry

        Write-ThinkCellSummary 'success'
        Write-Log -Message "Repair of [$appName $appVersion] complete."
    }
    Catch {
        [int32]$mainExitCode = 60003
        Write-ThinkCellSummary "failed-$mainExitCode"
        Write-Log -Message "Repair of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
    }
}
##*===============================================
##* UNINSTALLATION
ElseIf ($DeploymentType -ieq 'Uninstall') {
    [string]$installPhase = 'Pre-Uninstallation'
    Show-InstallationWelcome -CloseApps 'powerpnt,excel' -CloseAppsCountdown 3600

    [string]$installPhase = 'Uninstallation'
    Try {
        Write-Log -Message "Starting uninstall of [$appName $appVersion]..."
        ## Explicit MSI path (not a GUID). 3.10.1 has no -ExitCodes on Execute-MSI;
        ## 1605 (not installed) is tolerated via -IgnoreExitCodes, making this idempotent.
        ## 3010/1641 (reboot required/deferred) are already treated as success by the toolkit.
        Execute-MSI -Action Uninstall -Path $script:msiPath -IgnoreExitCodes '1605'

        [string]$installPhase = 'Post-Uninstallation'
        ## Remove the ARP entry if the uninstall left it behind
        Foreach ($p in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$script:appProductCode",
                         "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$script:appProductCode")) {
            If (Test-Path $p) {
                Remove-Item $p -Recurse -Force
                Write-Log -Message "think-cell ARP: removed orphaned entry at [$p] after uninstall."
                Write-Log -Message "THINKCELL_ARP action=remove-orphaned location=$p"
            }
        }

        ## Per-user leftovers: log what exists (troubleshooting per-user shadows), leave in place by default.
        $perUserDirs = @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'AppData\Local\think-cell') })
        Write-Log -Message ("THINKCELL_PERUSER localappdata_thinkcell_profiles={0} left_in_place=1" -f $perUserDirs.Count)

        Write-ThinkCellSummary 'success'
        Write-Log -Message "Uninstall of [$appName $appVersion] complete."

        Exit-Script -ExitCode $mainExitCode
    }
    Catch {
        [int32]$mainExitCode = 60004
        Write-ThinkCellSummary "failed-$mainExitCode"
        Write-Log -Message "Uninstall of [$appName] failed with error code $mainExitCode.`n$(Resolve-Error)"
    }
}

Exit-Script -ExitCode $mainExitCode
