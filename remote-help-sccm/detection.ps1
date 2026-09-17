<#
.SYNOPSIS
    Remote Help detection script - one script for both SCCM and Intune.
.DESCRIPTION
    Contract (corpus-anchored, intune-sccm-detection-script-contract):
      INSTALLED  = exit 0 AND non-empty STDOUT via Write-Output
      NOT        = exit 0, silent (SCCM reads nonzero as Unknown/script error;
                   Intune reads it as not-installed -> reinstall loop; never
                   exit 1 in an app detection script)
      Never Write-Host (Information stream, not STDOUT). Never stderr.

    Signal: RemoteHelp.exe on disk (the installer is a Burn bundle with no
    MSI inside - there is no ProductCode/UpgradeCode registry identity; the
    file anchor is the vendor-documented lane).

    Bitness: SCCM ALWAYS runs script detection in 32-bit PowerShell, where
    $env:ProgramFiles points at (x86) - all three plausible roots are probed.

    $MinimumVersion: '' (default) = existence-only; set e.g. '5.2.1040.0'
    before pasting to enforce a version floor (below floor = NOT detected,
    silent, so the platform re-offers the app). Compare is numeric per
    version segment - no [version] casts, no New-Object (CLM-proof).

    Paste into the SCCM script editor FROM FILE, never from chat/history
    (paste-mangling reads as not-detected).
#>
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false)]
    [string]$MinimumVersion = ''
)

function Test-RemoteHelpVersionAtLeast {
    Param ([string]$Installed, [string]$Floor)
    $installedParts = ($Installed -split '\.') | ForEach-Object { [int]($_ -replace '\D.*$', '0') }
    $floorParts     = ($Floor -split '\.')     | ForEach-Object { [int]($_ -replace '\D.*$', '0') }
    $maxParts = [Math]::Max($installedParts.Count, $floorParts.Count)
    For ($i = 0; $i -lt $maxParts; $i++) {
        $left  = If ($i -lt $installedParts.Count) { $installedParts[$i] } else { 0 }
        $right = If ($i -lt $floorParts.Count)     { $floorParts[$i] }     else { 0 }
        If ($left -gt $right) { return $true }
        If ($left -lt $right) { return $false }
    }
    return $true
}

$rhRoots = @(
    (Join-Path -Path $env:ProgramFiles -ChildPath 'Remote Help'),
    (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Remote Help')
)
If ($env:ProgramW6432) {
    $rhRoots += (Join-Path -Path $env:ProgramW6432 -ChildPath 'Remote Help')
}

foreach ($root in ($rhRoots | Select-Object -Unique)) {
    $exe = Join-Path -Path $root -ChildPath 'RemoteHelp.exe'
    If (Test-Path -LiteralPath $exe -PathType 'Leaf') {
        $version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
        If ([string]::IsNullOrWhiteSpace($version)) { $version = 'unknown' }
        If (-not [string]::IsNullOrWhiteSpace($MinimumVersion) -and -not (Test-RemoteHelpVersionAtLeast -Installed $version -Floor $MinimumVersion)) {
            # Below floor = NOT detected (silent) so the platform re-offers.
            exit 0
        }
        Write-Output "Remote Help $version"
        exit 0
    }
}

# Not installed: exit 0, no output - the portable absent form.
exit 0
