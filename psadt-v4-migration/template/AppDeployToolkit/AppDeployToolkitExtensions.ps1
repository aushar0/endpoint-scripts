<#

.SYNOPSIS
PSAppDeployToolkit - Provides the ability to extend and customize the toolkit by adding your own functions that can be re-used.

.DESCRIPTION
This script is a template that allows you to extend the toolkit with your own custom functions.

This script is dot-sourced by the AppDeployToolkitMain.ps1 script which contains the logic and functions required to install or uninstall an application.

.INPUTS
None. You cannot pipe objects to this script.

.OUTPUTS
None. This script does not generate any output.

#>

##*===============================================
##* MARK: VARIABLE DECLARATION
##*===============================================


##*===============================================
##* MARK: FUNCTION LISTINGS
##*===============================================

## Sample custom function. Replace with the functions from your v3
## AppDeployToolkitExtensions.ps1; v3 function names called from inside
## custom functions (Write-Log, Execute-Process, ...) keep working under
## the v4 compatibility engine.
Function Write-DeploymentSummary {
    <#
    .SYNOPSIS
        Writes a one-line digest of the deployment into the toolkit log.

    .DESCRIPTION
        Companion evidence line so a log reader can see the run outcome at a
        glance without scanning the full log. Values only, no secrets.

    .PARAMETER DeploymentType
        Install, Uninstall, or Repair.

    .PARAMETER Result
        Short result token, e.g. installed, uninstalled, repaired, failed-1618.

    .EXAMPLE
        Write-DeploymentSummary -DeploymentType 'Install' -Result 'installed'
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)]
        [ValidateSet('Install', 'Uninstall', 'Repair')]
        [String]$DeploymentType = 'Install',
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [String]$Result = 'success'
    )

    Write-Log -Message ("SUMMARY: app=[{0}] version=[{1}] type=[{2}] mode=[{3}] result=[{4}] computer=[{5}] user=[{6}]" -f $appName, $appVersion, $DeploymentType, $deployMode, $Result, $env:COMPUTERNAME, $env:USERNAME) -ScriptSection 'Finalize'
}


##*===============================================
##* MARK: SCRIPT BODY
##*===============================================

if ((Test-Path -LiteralPath Microsoft.PowerShell.Core\Variable::scriptParentPath) -and $scriptParentPath)
{
    Write-ADTLogEntry -Message "Script [$($MyInvocation.MyCommand.Definition)] dot-source invoked by [$(((Get-Variable -Name MyInvocation).Value).ScriptName)]" -ScriptSection Initialization
}
else
{
    Write-ADTLogEntry -Message "Script [$($MyInvocation.MyCommand.Definition)] invoked directly" -ScriptSection Initialization
}
