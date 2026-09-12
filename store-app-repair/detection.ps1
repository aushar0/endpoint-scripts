<#
.SYNOPSIS
    Detect broken modern (AppX/MSIX) apps for the current signed-in user.

.DESCRIPTION
    Intune remediation detection script. Scans every non-framework package
    registered for the current user and flags two failure classes:
      1. Unhealthy registration: package Status is not Ok.
      2. Missing components: the manifest declares a dependency whose name is
         not registered, or whose installed version is below the manifest's
         minimum. This is the usual cause of "This app can't open".

    Pair with remediation.ps1 (same folder). Both scripts must run in the
    signed-in user's context: AppX registration is per-user, and the SYSTEM
    account has no user profile to inspect. Configure the Intune remediation
    to "Run this script using the logged on credentials".

    Exit codes (Intune detection contract): 0 = healthy, 1 = broken app found
    (run remediation), 1 = wrong context (SYSTEM).

.NOTES
    Version: 1.0.0
    Part of the store-app-repair kit. See README.md for the full repair
    ladder, revert directions, and verification ledger.
#>
[CmdletBinding()]
param(
    # Restrict the scan to specific package family names. Default: all apps.
    [string[]]$FamilyName
)

function Test-AppxHealth {
    # Returns one issue object per broken app. App-centric: frameworks are
    # only interesting through their dependents (verified: the OS refuses to
    # remove a framework while apps depend on it, so framework "breakage"
    # surfaces here as an app-side component gap).
    param([string[]]$FamilyName)

    $issues = @()
    $apps = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework })
    if ($FamilyName) { $apps = @($apps | Where-Object { $_.PackageFamilyName -in $FamilyName }) }

    foreach ($app in $apps) {
        if ($app.Status -ne 'Ok') {
            $issues += [pscustomobject]@{ Kind = 'status'; App = $app.Name; Family = $app.PackageFamilyName; Version = $app.Version; Detail = "Status $($app.Status)" }
            continue
        }
        try {
            $manifest = Get-AppxPackageManifest -Package $app -ErrorAction Stop
            # manifests without PackageDependency entries yield @($null) here -
            # the null element must be filtered or every such app false-flags
            $declared = @($manifest.Package.Dependencies.PackageDependency) | Where-Object { $_ }
            foreach ($d in $declared) {
                # frameworks register per-architecture: the floor is met when the
                # BEST-installed package of the name satisfies it (checked across
                # all registered copies, not the first arbitrary one)
                $have = @(Get-AppxPackage -Name $d.Name -ErrorAction SilentlyContinue)
                $best = $have | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
                if (-not $best) {
                    $issues += [pscustomobject]@{ Kind = 'missing_component'; App = $app.Name; Family = $app.PackageFamilyName; Version = $app.Version; Detail = "{0} requires version {1}, found nothing" -f $d.Name, $d.MinVersion }
                }
                elseif ([version]$best.Version -lt [version]$d.MinVersion) {
                    $issues += [pscustomobject]@{ Kind = 'component_too_old'; App = $app.Name; Family = $app.PackageFamilyName; Version = $app.Version; Detail = "{0} requires version {1}, found {2}" -f $d.Name, $d.MinVersion, $best.Version }
                }
            }
        }
        catch {
            $issues += [pscustomobject]@{ Kind = 'manifest_unreadable'; App = $app.Name; Family = $app.PackageFamilyName; Version = $app.Version; Detail = $_.Exception.Message }
        }
    }
    # callers wrap with @(), so single-element unwrap-on-return is harmless
    return @($issues)
}

# Main runs only on direct invocation; remediation.ps1 dot-sources this file
# for Test-AppxHealth and must not trigger the scan or its exit codes.
if ($MyInvocation.InvocationName -ne '.') {
    # SYSTEM has no user profile: per-user AppX inspection is meaningless there.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -eq 'S-1-5-18') {
        Write-Host "Wrong context: this detection must run as the signed-in user (Intune: 'Run this script using the logged on credentials')."
        exit 1
    }

    $issues = @(Test-AppxHealth -FamilyName $FamilyName)
    if ($issues.Count) {
        foreach ($i in $issues) {
            Write-Host ("[WARN] {0} {1}: {2} - {3}" -f $i.App, $i.Version, $i.Kind, $i.Detail)
        }
        Write-Host ("Found {0} broken app(s). Run remediation.ps1." -f $issues.Count)
        exit 1
    }

    Write-Host "All registered apps healthy."
    exit 0
}
