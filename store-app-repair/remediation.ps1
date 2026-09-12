<#
.SYNOPSIS
    Repair broken modern (AppX/MSIX) apps for the current signed-in user.

.DESCRIPTION
    Intune remediation script. Pairs with detection.ps1. For every broken app
    found (unhealthy registration or missing/too-old components), applies the
    no-download repair ladder in order:
      1. Re-register the app and each component it resolves, from the files
         already staged on disk (Add-AppxPackage -Register).
      2. Missing VCLibs UWPDesktop: install Microsoft's permalink package.
    Then re-runs the health check.

    Exit codes (Intune remediation contract): 0 = repaired or already
    healthy, 1 = still broken (escalate: see README "The one-command option"
    for the full repair script, which adds the Microsoft update-channel
    download path).

    Both scripts must run in the signed-in user's context (per-user AppX
    registration; SYSTEM has no user profile).

.NOTES
    Version: 1.0.0
    Detail log: %TEMP%\store-app-repair-remediation.log
#>
[CmdletBinding()]
param(
    [string[]]$FamilyName
)

$ErrorActionPreference = 'Continue'
$logFile = Join-Path $env:TEMP "store-app-repair-remediation.log"
"remediation run $(Get-Date) user=$env:USERNAME" | Out-File $logFile -Append -Encoding utf8

# Detect (dot-sourcing keeps one implementation of the health check).
. (Join-Path $PSScriptRoot 'detection.ps1')

if ($MyInvocation.InvocationName -ne '.') {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -eq 'S-1-5-18') {
        Write-Host "Wrong context: this remediation must run as the signed-in user."
        exit 1
    }

$issues = @(Test-AppxHealth -FamilyName $FamilyName)
if (-not $issues.Count) {
    Write-Host "All registered apps healthy. No action needed."
    exit 0
}
Write-Host ("{0} broken app(s) found. Repairing..." -f $issues.Count)

$frameworkPermalink = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
$handled = @()

foreach ($issue in ($issues | Sort-Object App -Unique)) {
    $pkg = Get-AppxPackage -Name $issue.App -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) { continue }

    # Rung 1: re-register the app + every component it resolves, from staged files.
    # In-use components (0x80073D02) and newer-already-present (0x80073D06) are
    # healthy states - logged, not failures.
    $targets = @($pkg.Dependencies | Where-Object PackageFamilyName -ne $pkg.PackageFamilyName) + $pkg
    foreach ($t in $targets) {
        $errs = @()
        try {
            Add-AppxPackage -DisableDevelopmentMode -Register "$($t.InstallLocation)\AppxManifest.xml" -ErrorAction Stop
        }
        catch { $errs = @($_) }
        if ($errs.Count) {
            if ("$($errs.Exception)" -match '0x80073D02|0x80073D06') {
                Write-Host ("  SKIP {0} (in use / newer present - expected)" -f $t.Name)
                $errs.Exception.Message | Out-File $logFile -Append -Encoding utf8
            }
            else {
                Write-Host ("  FAIL {0} - logged" -f $t.Name)
                $errs.Exception.Message | Out-File $logFile -Append -Encoding utf8
            }
        }
    }

    # Rung 2: the one component with a permanent Microsoft permalink.
    $gap = Test-AppxHealth -FamilyName $pkg.PackageFamilyName
    foreach ($g in $gap | Where-Object Kind -eq 'missing_component') {
        if ($g.Detail -match 'Microsoft\.VCLibs\.140\.00\.UWPDesktop') {
            Write-Host "  Installing VCLibs UWPDesktop from Microsoft's permalink..."
            try {
                Add-AppxPackage -Path $frameworkPermalink -ErrorAction Stop
            }
            catch {
                # 0x80073D06 = newer already registered: healthy, keep going.
                if ("$($_.Exception)" -notmatch '0x80073D06') {
                    Write-Host ("  FAIL VCLibs permalink - logged")
                    $_.Exception.Message | Out-File $logFile -Append -Encoding utf8
                }
            }
        }
    }
    $handled += $issue.App
}

# Re-check: the remediation contract is honest - only exit 0 when healthy.
$remaining = @(Test-AppxHealth -FamilyName $FamilyName)
if ($remaining.Count) {
    foreach ($i in $remaining) {
        Write-Host ("[STILL BROKEN] {0}: {1} - {2}" -f $i.App, $i.Kind, $i.Detail)
    }
    Write-Host "This pair repairs registration and missing-component cases without downloads. For the download path (fetch from Microsoft's update channel), see README 'The one-command option'."
    exit 1
}

Write-Host ("Repaired: {0}. All registered apps healthy." -f (($handled | Sort-Object -Unique) -join ', '))
exit 0
}
