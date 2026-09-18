<#
.SYNOPSIS
    Portable detection for the Orb desktop app - one script for SCCM
    Deployment-Type detection method AND Intune Win32 custom detection.
    Run context: SYSTEM on both platforms (SCCM script host = 32-bit
    PowerShell ALWAYS; Intune = 64-bit).
.DESCRIPTION
    Contract (packaging skill references/detection.md):
      detected = exit 0 AND non-empty stdout (Write-Output "Orb <version>" -
      stdout doubles as device version inventory).
      absent   = exit 0, SILENT. Never exit 1 (SCCM reads nonzero as
      Unknown; Intune as not-installed -> 24h reinstall loop for Required).
      Never stderr, never Write-Host.
    CLM-proof: no [version] casts, no non-primitive .NET types, no
    New-Object - the floor compare is per-segment numeric on Split('.').

    BITNESS TRAP (lab-proven 2026-09-15, lab VM): the NSIS ARP key
    ("Orb Forge Inc.Orb", DisplayName exactly "Orb") lands in the NATIVE
    64-bit Uninstall view ONLY. From the 32-bit SCCM script host the plain
    HKLM:\SOFTWARE drive is redirected to WOW6432Node and the key is
    INVISIBLE - the x86 battery leg returned empty on an installed box.
    Fix: when running under WOW64, scan the native view via
    Sysnative\reg.exe (Sysnative exists only from a 32-bit process, so the
    64-bit host never takes this leg). The WOW6432Node view is still
    scanned via the PS drives from both hosts (the redirected read from the
    32-bit host covers it for free).

    NOT Orb.exe FileVersion - the binary carries none (lab-proven). Floor
    compare is optional; empty = existence-only on first rollout (house
    doctrine). Unparsable version/floor reads not-detected (fail-closed to
    redeploy). Detects the DESKTOP APP flavor only; the headless sensor
    service writes no ARP entry (detect via service query instead).
.PARAMETER minimumVersion
    Optional floor, e.g. '1.5.5'.
#>
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false)]
    [string]$minimumVersion = ''
)

$displayName = 'Orb'
$version = $null

## Leg 1: PS registry drives - WOW6432Node view from both hosts (from the
## 32-bit host the HKLM:\SOFTWARE read is redirected there automatically).
$driveViews = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
foreach ($v in $driveViews) {
    $entry = Get-ChildItem -Path $v -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue } |
        Where-Object { $_.DisplayName -eq $displayName } |
        Select-Object -First 1
    if ($entry) { $version = [string]$entry.DisplayVersion; break }
}

## Leg 2: native view from a 32-bit host - Sysnative\reg.exe (no redirection).
## 64-bit hosts skip this (PROCESSOR_ARCHITEW6432 is set only under WOW64).
if (-not $version -and $env:PROCESSOR_ARCHITEW6432) {
    $sysnative = Join-Path $env:SystemRoot 'Sysnative\reg.exe'
    if (Test-Path -LiteralPath $sysnative) {
        $lines = & $sysnative QUERY 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' /S /V DisplayName 2>$null
        $key = $null
        foreach ($line in $lines) {
            if ($line -match '^HKEY_') { $key = $line.Trim(); continue }
            if ($key -and $line -match '^\s*DisplayName\s+REG_SZ\s+Orb\s*$') {
                $vout = & $sysnative QUERY $key /V DisplayVersion 2>$null
                foreach ($vl in $vout) {
                    if ($vl -match '^\s*DisplayVersion\s+REG_SZ\s+(\S+)') { $version = $Matches[1]; break }
                }
                break
            }
        }
    }
}

if (-not $version -or [string]::IsNullOrWhiteSpace($version)) { exit 0 }

if (-not [string]::IsNullOrWhiteSpace($minimumVersion)) {
    $haveSegs = $version.Split('.')
    $floorSegs = $minimumVersion.Split('.')
    $max = $haveSegs.Count
    if ($floorSegs.Count -gt $max) { $max = $floorSegs.Count }
    for ($i = 0; $i -lt $max; $i++) {
        $havePart = 0
        $floorPart = 0
        if ($i -lt $haveSegs.Count) {
            try { $havePart = [int]$haveSegs[$i] } catch { exit 0 }
        }
        if ($i -lt $floorSegs.Count) {
            try { $floorPart = [int]$floorSegs[$i] } catch { exit 0 }
        }
        if ($havePart -lt $floorPart) { exit 0 }
        if ($havePart -gt $floorPart) { break }
    }
}

Write-Output "Orb $version"
exit 0
