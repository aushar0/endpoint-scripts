<#
.SYNOPSIS
    Sample v3-style deployment script for the PSAppDeployToolkit 4.1.8 v3-compatibility template.

.DESCRIPTION
    Drop-in shape for existing v3 Deploy-Application.ps1 scripts. Replace the
    Application variables and the Install/Uninstall/Repair bodies with your own;
    the v4 compatibility engine runs v3 function names (Execute-MSI,
    Execute-Process, Write-Log, Exit-Script, Show-InstallationWelcome, ...)
    unchanged.

    This sample performs no real installation. Install writes a marker file,
    Uninstall removes it, Repair rewrites it, so the template can be exercised
    end-to-end on a test machine without a payload.

    Custom functions live in AppDeployToolkit\AppDeployToolkitExtensions.ps1.

.PARAMETER DeploymentType
    The type of deployment to perform: Install, Uninstall, or Repair.

.PARAMETER DeployMode
    Interactive, Silent, or NonInteractive.

.PARAMETER AllowRebootPassThru
    Passes exit code 3010 back to the parent process (e.g. SCCM).

.PARAMETER TerminalServerMode
    Changes to user install mode and back for RDS/Citrix servers.

.PARAMETER DisableLogging
    Disables logging to file.

.EXAMPLE
    .\Deploy-Application.ps1 -DeploymentType Install -DeployMode Silent

.NOTES
    PSAppDeployToolkit is licensed under the GNU LGPLv3 - (C) 2026 PSAppDeployToolkit Team.
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
    [String]$appVendor = ''
    [String]$appName = 'PSADT4 Migration Sample'
    [String]$appVersion = '1.0.0'
    [String]$appArch = ''
    [String]$appLang = 'EN'
    [String]$appRevision = '01'
    [String]$appScriptVersion = '1.0.0'
    [String]$appScriptDate = '09/15/2026'
    [String]$appScriptAuthor = ''

    ## Variables: Install Titles (only set here to override toolkit defaults)
    [String]$installName = ''
    [String]$installTitle = ''

    ##* Do not modify section below
    #region DoNotModify

    ## Variables: Exit Code
    [Int32]$mainExitCode = 0

    ## Variables: Script
    [String]$deployAppScriptFriendlyName = 'Deploy Application'
    [Version]$deployAppScriptVersion = [Version]'3.10.2'
    [String]$deployAppScriptDate = '09/15/2026'
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

    ## Resolve the toolkit log folder on both engine generations:
    ## v3 exposed $configToolkitLogDir from AppDeployToolkitConfig.xml
    ## (<Toolkit_LogPath>); the v4 engine resolves the same setting from
    ## Config\config.psd1 (Toolkit.LogPath) onto the session object.
    If (Get-Command -Name Get-ADTSession -ErrorAction SilentlyContinue) {
        [String]$configToolkitLogDir = (Get-ADTSession).LogPath
    }

    ## Per-package log subfolder convention:
    ## <log root>\<app name>-<app version>-<deployment type>
    [String]$safeAppName = ($appName -replace '[\\/:*?"<>|]', '' -replace '\s+', ' ').Trim()
    [String]$evidenceDir = Join-Path $configToolkitLogDir ("{0}-{1}-{2}" -f $safeAppName, $appVersion, $DeploymentType)
    [String]$markerFile = Join-Path $evidenceDir 'sample.marker'

    ##*===============================================
    #region INSTALLATION
    ##*===============================================
    If ($DeploymentType -eq 'Install') {
        $installPhase = 'Pre-Installation'

        ## Sample proof that v3 function names run under the v4 compat engine.
        Execute-Process -Path "$env:SystemRoot\System32\cmd.exe" -Parameters '/c exit 0' -ErrorAction SilentlyContinue

        $installPhase = 'Installation'
        New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
        Set-Content -Path $markerFile -Value ("{0} | {1} | {2}" -f $appName, $appVersion, (Get-Date -Format 'o'))

        ## Sample call into AppDeployToolkitExtensions.ps1.
        Write-DeploymentSummary -DeploymentType $DeploymentType -Result 'installed'

        $installPhase = 'Post-Installation'
    }
    #endregion
    ##*===============================================

    ##*===============================================
    #region UNINSTALLATION
    ##*===============================================
    If ($DeploymentType -eq 'Uninstall') {
        $installPhase = 'Pre-Uninstallation'

        ## The log subfolder is suffixed per deployment type, so sweep the
        ## marker from every type variant of this package's subfolder.
        Get-ChildItem -Path $configToolkitLogDir -Directory -Filter ("{0}-{1}-*" -f $safeAppName, $appVersion) -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -LiteralPath (Join-Path $_.FullName 'sample.marker') -Force -ErrorAction SilentlyContinue
        }

        $installPhase = 'Uninstallation'
        Write-DeploymentSummary -DeploymentType $DeploymentType -Result 'uninstalled'

        $installPhase = 'Post-Uninstallation'
    }
    #endregion
    ##*===============================================

    ##*===============================================
    #region REPAIR
    ##*===============================================
    If ($DeploymentType -eq 'Repair') {
        $installPhase = 'Pre-Repair'

        New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
        Set-Content -Path $markerFile -Value ("{0} | {1} | repaired | {2}" -f $appName, $appVersion, (Get-Date -Format 'o'))

        $installPhase = 'Repair'
        Write-DeploymentSummary -DeploymentType $DeploymentType -Result 'repaired'

        $installPhase = 'Post-Repair'
    }
    #endregion
    ##*===============================================

    ##*===============================================
    #region CLEANUP
    ##*===============================================
    Exit-Script -ExitCode $mainExitCode
    #endregion
    ##*===============================================
}
Catch {
    [Int32]$mainExitCode = 60001
    [String]$mainErrorMessage = "$(Resolve-Error)"
    Write-Log -Message $mainErrorMessage -LogLevel 3 -ScriptSection 'Main'
    Exit-Script -ExitCode $mainExitCode
}
