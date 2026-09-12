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

    Every failure path emits a specific diagnosis (service state, access
    denied, DNS/name resolution, engine version) - never a bare error code.

    Exit codes (Intune detection contract): 0 = healthy, 1 = broken app found
    (run remediation) or infrastructure problem.

.NOTES
    Version: 1.1.0
    Part of the store-app-repair kit. See README.md for the full repair
    ladder, revert directions, and verification ledger.
#>
[CmdletBinding()]
param(
    # Restrict the scan to specific package family names. Default: all apps.
    [string[]]$FamilyName
)

function Write-Preflight {
    # Engine + infrastructure identity: makes ".NET/PS too old" and
    # "service down" visible without guessing.
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    Write-Host ("[INFO] Engine: PowerShell {0} (CLR {1}) on {2} build {3}" -f `
        $PSVersionTable.PSVersion, $PSVersionTable.CLRVersion, $os.Caption, $os.BuildNumber)
    # AppXSvc is trigger-started: 'Stopped' between deployments is its healthy
    # resting state (chaos-tested 2026-09-11 - gating on Status would fail every
    # healthy machine). The real failure is a policy that DISABLES it: then no
    # install or repair can ever run.
    $svc = Get-Service -Name AppXSvc -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "[ERR] AppX deployment service (AppXSvc) not found - Windows app infrastructure is damaged. App checks cannot run."
        return $false
    }
    if ($svc.StartType -eq 'Disabled') {
        Write-Host "[ERR] AppX deployment service (AppXSvc) is Disabled by policy - no Store app install or repair can run. Re-enable the service (hardening baseline conflict)."
        return $false
    }
    return $true
}

function Get-FailureDiagnosis {
    # Maps an exception to a specific cause. Unknown errors keep their full
    # text - the taxonomy narrows, it never hides.
    param($Exception)
    $e = "$($Exception)"
    switch -Regex ($e) {
        '0x80073D02' { return 'files in use by running apps (close the listed apps or retry later)' }
        '0x80073D06' { return 'a newer version is already registered (healthy state)' }
        '0x80073CF3' { return 'dependency conflict: the package needs components in a different state than registered' }
        '0x80070005|Access is denied|UnauthorizedAccess' { return 'access denied - file ACLs, security software, or wrong context' }
        '0x80072EE7|12007' { return 'name resolution failed - endpoint blocked by DNS, hosts file, VPN, or proxy' }
        '0x80072EFD|0x80072F8F|timeout|timed out' { return 'network unreachable or TLS blocked' }
        '0x80070424|service cannot be started' { return 'a required Windows service is not running' }
        '0x80073CF9' { return 'install rejected - possibly missing entitlement/license for this app' }
    }
    $h = $Exception.Exception.HResult
    if ($h -and $h -ne 0) { return "HRESULT 0x{0:X8}: {1}" -f $h, $e }
    return $e
}

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
            $issues += [pscustomobject]@{ Kind = 'manifest_unreadable'; App = $app.Name; Family = $app.PackageFamilyName; Version = $app.Version; Detail = Get-FailureDiagnosis $_ }
        }
    }
    # callers wrap with @(), so single-element unwrap-on-return is harmless
    # A named family that is not registered at all is only detectable when the
    # caller names apps - flag it so "missing" is never a silent healthy.
    if ($FamilyName) {
        foreach ($f in $FamilyName) {
            if (-not ($apps.PackageFamilyName -contains $f) -and -not ($issues | Where-Object Family -eq $f)) {
                $issues += [pscustomobject]@{ Kind = 'missing'; App = ($f -split '_')[0]; Family = $f; Version = ''; Detail = 'named app is not installed for this user; repair cannot create it without a download (see the one-command option)' }
            }
        }
    }
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

    if (-not (Write-Preflight)) { exit 1 }

    try {
        $issues = @(Test-AppxHealth -FamilyName $FamilyName)
    }
    catch {
        Write-Host ("[ERR] AppX query failed: {0}" -f (Get-FailureDiagnosis $_))
        exit 1
    }
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
