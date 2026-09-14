<#
.SYNOPSIS
    PSAppDeployToolkit 3.10.1 package for Microsoft Calculator - offline
    install, repair, uninstall with all dependency frameworks.
    Derived from the PSAppDeployToolkit 3.10.1 Deploy-Application.ps1 template
    and the Examples\VLC reference script (LGPLv3, (C) 2024 PSAppDeployToolkit
    Team - Sean Lillis, Dan Cunningham, Muhammad Mashwani). Use at your own
    risk.
.DESCRIPTION
    Per-machine and per-user deployment of the Calculator msixbundle with its
    7 dependency frameworks staged in Files\Calculator. Designed for
    machines without Store or winget access; idempotent for SCCM Packages
    (no detection method needed - the script exits 0 fast when the app is
    already registered).

    Context-aware and fully silent:
      - SYSTEM (SCCM default): provisions machine-wide via
        Add-AppxProvisionedPackage. Windows registers logged-on users within
        minutes (AppReadiness) and new users at first logon.
      - User session (standard or elevated): installs per-user with the
        dependency retry ladder.
      - -DeploymentType Repair: re-registers a broken-but-present app and its
        components from the staged files.
      - -DeploymentType Uninstall: removes per-user (+ deprovisions when
        elevated).

    Staged files verified 2026-09-11: SHA-1 matched Microsoft's FE3 digests
    at download time; all 8 Authenticode Valid (Microsoft Corporation).
#>
[CmdletBinding()]
Param (
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [string]$DeploymentType = 'Install',
    [Parameter(Mandatory = $false)]
    [ValidateSet('Interactive', 'Silent', 'NonInteractive')]
    [string]$DeployMode = 'Silent',
    [switch]$AllowRebootPassThru,
    [switch]$TerminalServerMode,
    [switch]$DisableLogging
)

##* Do not modify section below
#region DoNotModify

## Variables: Exit Code
[Int32]$mainExitCode = 0

## Variables: Application
[String]$appVendor = 'Microsoft'
[String]$appName = 'Windows Calculator'
[String]$appVersion = '11.2607.0.0'
[String]$appArch = 'x64'
[String]$appLang = 'EN'
[String]$appRevision = '01'
[String]$appScriptVersion = '1.1.0'
[String]$appScriptDate = '09/14/2026'
[String]$appScriptAuthor = 'aushar0'
## Variables: Package
[String]$appxName = 'Microsoft.WindowsCalculator'
[String]$installName = 'StoreApps-Calculator'
[String]$installTitle = 'Windows Calculator'

## Variables: Script
[String]$deployAppScriptFriendlyName = 'Deploy Application'
[Version]$deployAppScriptVersion = [Version]'3.10.1'
[String]$deployAppScriptDate = '03/05/2024'
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
##* END VARIABLE DECLARATION
##*===============================================

## AppX helpers (Calculator-specific; toolkit has no native appx functions)

function Test-AppxRegistered {
    param([string]$Name, [bool]$AllUsers)
    $g = @{ Name = $Name }
    if ($AllUsers) { $g.AllUsers = $true }
    foreach ($p in @(Get-AppxPackage @g -ErrorAction SilentlyContinue)) {
        if (-not $AllUsers) { return $p }
        if ("$($p.PackageUserInformation)" -match 'Installed') { return $p }
    }
    return $null
}

If ($deploymentType -ine 'Uninstall' -and $deploymentType -ine 'Repair') {
    ##*===============================================
    ##* PRE-INSTALLATION
    ##*===============================================
    [String]$installPhase = 'Pre-Installation'

    ## Close Calculator if running (Silent mode closes without prompting)
    Show-InstallationWelcome -CloseApps 'CalculatorApp' -CloseAppsCountdown 60

    ## Show Progress Message (with the default message)
    Show-InstallationProgress

    ## <Perform Pre-Installation tasks here>


    ##*===============================================
    ##* INSTALLATION
    ##*===============================================
    [String]$installPhase = 'Installation'

    ## Context and staged set
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $isSystem = $identity.User.Value -eq 'S-1-5-18'
    Write-Log -Message "Context: user=$($identity.Name) elevated=$isAdmin system=$isSystem" -Source $deployAppScriptFriendlyName

    $frameworkPattern = '^(Microsoft\.(VCLibs|NET\.Native|UI\.Xaml|Services\.Store|Advertising|WindowsStore|Windows\..*SDK|WindowsAppRuntime)|Microsoft\.Windows\.SDK\..*)'
    $files = @(Get-ChildItem "$dirFiles\Calculator" -File | Where-Object Extension -match '^\.(appx|msix)(bundle)?$')
    $mainAppx = @($files | Where-Object { $_.Name -notmatch $frameworkPattern -and ($_.Name -split '_')[0] -eq $appxName }) |
        Sort-Object { if ($_.Name -match '_(\d+\.\d+\.\d+\.\d+)_') { [version]$Matches[1] } else { [version]'0.0.0.0' } } -Descending |
        Select-Object -First 1
    $depAppx = @($files | Where-Object Name -ne $mainAppx.Name)
    Write-Log -Message "Staged set: $($mainAppx.Name) + $($depAppx.Count) component(s)." -Source $deployAppScriptFriendlyName

    ## Presence idempotency: registered at any version = nothing to do.
    ## Staged-only (unregistered) does NOT count - that is the broken state.
    $registered = Test-AppxRegistered -Name $appxName -AllUsers $isAdmin
    If ($registered) {
        Write-Log -Message "Calculator $($registered.Version) already registered - nothing to do." -Source $deployAppScriptFriendlyName
        ## <Perform Post-Installation tasks here>
        Show-InstallationProgress
        Exit-Script -ExitCode $mainExitCode
    }

    ## SYSTEM: provision machine-wide. Windows registers logged-on users
    ## within minutes (AppReadiness) and new users at first logon. Per-user
    ## Add-AppxPackage is not usable as SYSTEM (no profile, no -AllUsers on
    ## this cmdlet set - verified 2026-09-11).
    If ($isSystem) {
        $prov = @{ Online = $true; PackagePath = $mainAppx.FullName; SkipLicense = $true }
        If ($depAppx.Count) { $prov.DependencyPackagePath = $depAppx.FullName }
        Write-Log -Message "SYSTEM context: provisioning Calculator machine-wide." -Source $deployAppScriptFriendlyName
        Add-AppxProvisionedPackage @prov | Out-Null
        Write-Log -Message "Provisioning completed - Windows registers users within minutes (AppReadiness) and at first logon." -Source $deployAppScriptFriendlyName

        ## Immediate silent registration for the signed-in console user via the
        ## toolkit's Execute-ProcessAsUser (LeastPrivilege = no UAC, no window).
        ## Files are copied to a user-readable location first (SYSTEM %TEMP%
        ## is not readable by users).
        $consoleUser = (Get-CimInstance Win32_Computersystem -ErrorAction SilentlyContinue).UserName
        If ($consoleUser) {
            $publicDir = 'C:\Users\Public\MsStoreRepair'
            New-Item -ItemType Directory -Force -Path $publicDir | Out-Null
            Copy-Item $mainAppx.FullName $publicDir -Force
            foreach ($d in $depAppx) { Copy-Item $d.FullName $publicDir -Force }
            $pubMain = Join-Path $publicDir $mainAppx.Name
            $pubDeps = @($depAppx | ForEach-Object { Join-Path $publicDir $_.Name })
            $depList = ($pubDeps | ForEach-Object { "'{0}'" -f $_ }) -join ','
            $handoffPs1 = Join-Path $publicDir 'handoff.ps1'
            $handoffLines = @(
                "`$err = ''"
                "try { Add-AppxPackage -Path '$pubMain' -DependencyPath @($depList) -ErrorAction Stop } catch { `$err = `$_.Exception.Message }"
                "if (`$err -match '0x80073CF3') {"
                "  `$err = ''"
                "  try { Add-AppxPackage -Path '$pubMain' -ErrorAction Stop } catch { `$err = `$_.Exception.Message }"
                "  if (`$err -match '0x80073CF3') {"
                "    `$err = ''"
                "    foreach (`$f in @($depList)) { try { Add-AppxPackage -Path `$f -ErrorAction Stop } catch {} }"
                "    try { Add-AppxPackage -Path '$pubMain' -ErrorAction Stop } catch { `$err = `$_.Exception.Message }"
                "  }"
                "}"
                "if (`$err) { exit 1 } else { exit 0 }"
            )
            Set-Content -Path $handoffPs1 -Value $handoffLines -Encoding utf8
            $rc = Execute-ProcessAsUser -Path "$PSHOME\powershell.exe" -Parameters "-NoProfile -ExecutionPolicy Bypass -File `"$handoffPs1`"" -Wait -PassThru -RunLevel 'LeastPrivilege' -TempPath $publicDir
            Remove-Item $publicDir -Recurse -Force -ErrorAction SilentlyContinue
            # outcome witness: the task plumbing can pass back quirky codes
            # (-196608 observed on success) - registration is the verdict
            $handedOff = Test-AppxRegistered -Name $appxName -AllUsers $true
            If ($handedOff) {
                Write-Log -Message "Calculator installed for the signed-in user; provisioned machine-wide. (handoff exit: $rc)" -Source $deployAppScriptFriendlyName
            }
            Else {
                Write-Log -Message "Console-user handoff exit $rc and no registration - provisioning covers registration at next logon." -Severity 2 -Source $deployAppScriptFriendlyName
            }
        }
    }
    Else {
        ## Elevated user: a staged-but-unregistered copy re-registers with no
        ## download. Standard user: ladder install from the staged files.
        $staged = $null
        If ($isAdmin) {
            foreach ($p in @(Get-AppxPackage -Name $appxName -AllUsers -ErrorAction SilentlyContinue)) {
                If ("$($p.PackageUserInformation)" -notmatch 'Installed') { $staged = $p; break }
            }
        }
        If ($staged) {
            Write-Log -Message "Staged copy found - re-registering without download." -Source $deployAppScriptFriendlyName
            Add-AppxPackage -Path (Join-Path $staged.InstallLocation 'AppxManifest.xml') -Register -DisableDevelopmentMode -ErrorAction Stop
        }
        Else {
            ## Dependency retry ladder: full set -> bare -> components then bare.
            ## Machines already satisfying part of the graph reject the full
            ## set with 0x80073CF3 ("provided but not used").
            Write-Log -Message "Installing Calculator + $($depAppx.Count) component(s) for this user." -Source $deployAppScriptFriendlyName
            Try {
                Add-AppxPackage -Path $mainAppx.FullName -DependencyPath $depAppx.FullName -ErrorAction Stop
            }
            Catch {
                If ($_.Exception.Message -notmatch '0x80073CF3') { Throw }
                Write-Log -Message "Full dependency set rejected (0x80073CF3) - retrying bare." -Severity 2 -Source $deployAppScriptFriendlyName
                Try {
                    Add-AppxPackage -Path $mainAppx.FullName -ErrorAction Stop
                }
                Catch {
                    If ($_.Exception.Message -notmatch '0x80073CF3') { Throw }
                    foreach ($d in $depAppx) {
                        Try { Add-AppxPackage -Path $d.FullName -ErrorAction Stop } Catch { Write-Log -Message "Component $($d.Name): $($_.Exception.Message)" -Severity 2 -Source $deployAppScriptFriendlyName }
                    }
                    Add-AppxPackage -Path $mainAppx.FullName -ErrorAction Stop
                }
            }
        }
    }

    ## <Perform Post-Installation tasks here>
    Show-InstallationProgress

    ##*===============================================
    ##* POST-INSTALLATION
    ##*===============================================
    [String]$installPhase = 'Post-Installation'

    $getArgs = @{ Name = $appxName }
    If ($isAdmin) { $getArgs.AllUsers = $true }
    $post = Get-AppxPackage @getArgs -ErrorAction SilentlyContinue | Select-Object -First 1
    If ($post) {
        Write-Log -Message "Calculator $($post.Version) present ($($identity.Name))." -Source $deployAppScriptFriendlyName
    }
    Else {
        Write-Log -Message "Calculator not yet registered for this user - provisioning covers registration." -Severity 2 -Source $deployAppScriptFriendlyName
    }
}
ElseIf ($deploymentType -ieq 'Uninstall') {
    ##*===============================================
    ##* UNINSTALLATION
    ##*===============================================
    [String]$installPhase = 'Uninstallation'

    ## Close Calculator if running
    Show-InstallationWelcome -CloseApps 'CalculatorApp' -CloseAppsCountdown 60

    Show-InstallationProgress

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    Get-AppxPackage -Name $appxName -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction Continue
    If ($isAdmin) {
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object DisplayName -eq $appxName |
            Remove-AppxProvisionedPackage -Online -ErrorAction Continue
    }

    If (Get-AppxPackage -Name $appxName -ErrorAction SilentlyContinue) {
        Write-Log -Message "Calculator still registered after uninstall." -Severity 3 -Source $deployAppScriptFriendlyName
        Exit-Script -ExitCode 1
    }
    Write-Log -Message "Calculator removed." -Source $deployAppScriptFriendlyName
    Exit-Script -ExitCode $mainExitCode
}
ElseIf ($deploymentType -ieq 'Repair') {
    ##*===============================================
    ##* REPAIR (broken-but-present: re-register app + components)
    ##*===============================================
    [String]$installPhase = 'Repair'

    Show-InstallationProgress

    $pkg = Get-AppxPackage -Name $appxName -ErrorAction SilentlyContinue | Select-Object -First 1
    If (-not $pkg) {
        Write-Log -Message "Calculator not installed - run Install instead." -Severity 2 -Source $deployAppScriptFriendlyName
        Exit-Script -ExitCode 1
    }
    $targets = @($pkg.Dependencies | Where-Object PackageFamilyName -ne $pkg.PackageFamilyName) + $pkg
    $fail = 0
    foreach ($t in $targets) {
        Try {
            Add-AppxPackage -DisableDevelopmentMode -Register "$($t.InstallLocation)\AppxManifest.xml" -ErrorAction Stop
        }
        Catch {
            If ("$($_.Exception)" -match '0x80073D02|0x80073D06') {
                Write-Log -Message "SKIP $($t.Name) (in use / newer present - expected)." -Source $deployAppScriptFriendlyName
            }
            Else {
                $fail++
                Write-Log -Message "FAIL $($t.Name): $($_.Exception.Message)" -Severity 3 -Source $deployAppScriptFriendlyName
            }
        }
    }
    $post = Get-AppxPackage -Name $appxName -ErrorAction SilentlyContinue
    If ($post) {
        Write-Log -Message "Repair complete: $($post.Name) $($post.Version) ($fail component failure(s))." -Source $deployAppScriptFriendlyName
        Exit-Script -ExitCode $mainExitCode
    }
    Exit-Script -ExitCode 1
}
##* LITERAL TEMPLATE END
