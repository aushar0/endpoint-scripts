<#
.SYNOPSIS
    think-cell detection script - one file for SCCM and Intune custom script
    detection methods.
.DESCRIPTION
    DETECTED = exit 0 WITH stdout. Both platforms require this contract:
    Intune treats exit 0 with EMPTY stdout as NOT detected, so the Write-Output
    on the success path is functional, not decorative. Not detected = exit 1
    with no output.

    Signal choice (Sep 11 2026, live-verified lane):
    - Anchors on the think-cell UPGRADE CODE (stable across releases) via
      Windows Installer's own product registration - NOT the ARP/Uninstall
      registry key (the 32-bit MSI publishes it under WOW6432Node and it can
      go missing while the product is healthy) and NOT a hard-coded
      ProductCode (think-cell rotates it every release).
    - Optional version floor: set $minimumVersion (e.g. '14.0.38.764') to
      fail detection when only an OLDER release is installed - protects
      against a failed upgrade leaving the old version behind and the
      deployment reporting compliant. Leave empty for "any think-cell".

    SCCM: Deployment Type > Detection Method > "Use a custom PowerShell
    script" (runs as SYSTEM). Intune: Win32 app > Detection rules > "Use a
    custom detection script" (runs as SYSTEM). Same file, unmodified.

    Bump discipline: on version swaps, optionally update $minimumVersion.
    Nothing else to touch.
#>

# Stable think-cell UpgradeCode (how their upgrades chain; verified against
# setup 38764 / 14.0.38.764 on Sep 11 2026).
[string]$upgradeCode = '{E202304D-BA30-4EDA-9905-7459004CFFD1}'

# Optional minimum version gate. Empty = any installed release detected.
[string]$minimumVersion = ''

$ErrorActionPreference = 'SilentlyContinue'

$detected = $false
$details = @()
try {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    foreach ($product in $installer.RelatedProducts($upgradeCode)) {
        [string]$code = "$product"
        [string]$version = $installer.ProductInfo($code, 'VersionString')
        if (-not $version) { $version = 'unknown' }
        if ($minimumVersion) {
            try {
                if ([version]$version -ge [version]$minimumVersion) { $detected = $true; $details += "productcode=$code version=$version" }
                else { $details += "below-minimum productcode=$code version=$version minimum=$minimumVersion" }
            } catch { $details += "unparseable-version productcode=$code version=$version" ; $detected = $true }
        }
        else {
            $detected = $true
            $details += "productcode=$code version=$version"
        }
    }
}
catch {
    # COM failure = cannot determine; report not detected, keep silent stdout
    exit 1
}

if ($detected) {
    # stdout is REQUIRED (Intune: exit 0 + empty stdout = NOT detected)
    Write-Output "think-cell detected: $($details -join '; ')"
    exit 0
}
exit 1
