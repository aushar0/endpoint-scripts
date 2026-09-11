<#
.SYNOPSIS
    Uninstall think-cell via Windows Installer product registration (UpgradeCode),
    independent of the ARP/Uninstall registry keys that Remove-MSIApplications
    relies on. Works for any installed think-cell release; safe when nothing
    is installed (exits 0).

.DESCRIPTION
    v2 (Sep 11 2026): ensures the log directory exists (C:\Windows\Logs\Software
    is NOT present on clean Windows - PSADT normally creates it, a standalone
    run would fail msiexec /l*v), takes -LogPath for testability, and retries
    once with a 30s backoff on msiexec 1618 (another installation in progress -
    the classic fleet transient when running without an orchestrator to retry).

    Why this exists: the think-cell MSI is 32-bit, so its ARP entry lives in
    HKLM\SOFTWARE\WOW6432Node\...\Uninstall (not the native hive), and PSADT
    Remove-MSIApplications can find nothing on machines where that key is
    missing. msiexec /x only needs the product registration, which this
    script enumerates via Installer.RelatedProducts(upgradeCode).

    Standalone (no PSADT dependency) - usable from an elevated prompt,
    SCCM Run Scripts, or an Intune remediation.

    Exit codes: 0 = clean / nothing to do, 1 = an uninstall failed or
    residue remains.

    -CleanUserData additionally removes per-user think-cell data dirs
    (%APPDATA%\think-cell, %LOCALAPPDATA%\think-cell) for every local
    profile. Default leaves them (README checklist #7: sweep vs leave).
#>
param(
    [switch]$CleanUserData,
    [string]$LogPath = 'C:\Windows\Logs\Software\thinkcell_uninstall.log'
)

# UpgradeCode from the MSI Property table (verified setup 38764 / 14.0.38.764;
# think-cell keeps it stable across releases - it is how their upgrades chain).
$upgradeCode  = '{E202304D-BA30-4EDA-9905-7459004CFFD1}'
# Explicit fallback for the 38764 release in case COM enumeration fails.
$knownCodes   = @('{569E51D7-73C3-435C-8A04-ABE3FA38DCC2}')

$ErrorActionPreference = 'Continue'
$exitOk = @{ 0 = 'OK'; 1605 = 'not installed (treated as OK)'; 3010 = 'OK, reboot required'; 1641 = 'OK, reboot initiated' }

# msiexec /l*v fails on a missing log directory - create it (PSADT normally does).
if ($LogPath) { New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null }

function Invoke-MsiexecX ([string]$ProductCode) {
    $args_ = "/x $ProductCode /qn /norestart /l*v `"$LogPath`""
    $p = Start-Process msiexec.exe -ArgumentList $args_ -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -eq 1618) {
        Write-Output '  msiexec returned 1618 (another installation in progress) - retrying once in 30s...'
        Start-Sleep -Seconds 30
        $p = Start-Process msiexec.exe -ArgumentList $args_ -Wait -PassThru -WindowStyle Hidden
    }
    return $p.ExitCode
}

# --- 1. collect installed product codes (normal GUID form, no registry keys) ---
$codes = @()
try {
    $inst = New-Object -ComObject WindowsInstaller.Installer
    foreach ($c in $inst.RelatedProducts($upgradeCode)) { $codes += "$c" }
} catch {
    Write-Output "RelatedProducts enumeration failed ($($_.Exception.Message)); falling back to known codes."
}
foreach ($k in $knownCodes) { if ($codes -notcontains $k) { $codes += $k } }

if (-not ($codes | Where-Object { $_ })) {
    Write-Output 'think-cell: no products registered with Windows Installer. Nothing to uninstall.'
    exit 0
}

# --- 2. uninstall each ---
$failed = 0
foreach ($code in ($codes | Where-Object { $_ })) {
    Write-Output "Uninstalling think-cell product $code ..."
    $ec = Invoke-MsiexecX $code
    if ($exitOk.ContainsKey($ec)) {
        Write-Output "  msiexec exit $ec = $($exitOk[$ec])"
    } else {
        Write-Output "  msiexec exit $ec = FAILED (see $LogPath)"
        $failed = 1
    }
}

Start-Sleep -Seconds 2

# --- 3. catch any leftover think-cell ARP entry from releases with a different UpgradeCode ---
$leftovers = Get-ItemProperty @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -like 'think-cell*' -and $_.PSChildName -like '{*}' }
foreach ($lo in $leftovers) {
    $pc = $lo.PSChildName
    Write-Output "Leftover entry '$($lo.DisplayName)' $pc - uninstalling by its ProductCode..."
    $ec = Invoke-MsiexecX $pc
    if (-not $exitOk.ContainsKey($ec)) { Write-Output "  msiexec exit $ec = FAILED"; $failed = 1 }
}

# --- 4. verify ---
$residue = @()
foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
    foreach ($code in $codes) { if (Test-Path "$root\$code") { $residue += "$root\$code" } }
}
if (Test-Path 'C:\Program Files (x86)\think-cell') { $residue += 'C:\Program Files (x86)\think-cell' }
if ($residue) {
    Write-Output 'RESIDUE after uninstall:'
    $residue | ForEach-Object { Write-Output "  $_" }
    $failed = 1
} else {
    Write-Output 'Verified clean: no ARP keys (both hives), no install dir.'
}

# --- 5. optional per-user sweep ---
if ($CleanUserData) {
    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($sub in "$($_.FullName)\AppData\Roaming\think-cell", "$($_.FullName)\AppData\Local\think-cell") {
            if (Test-Path $sub) {
                Remove-Item $sub -Recurse -Force -ErrorAction SilentlyContinue
                Write-Output "removed $sub"
            }
        }
    }
}

exit $failed
