<#
.SYNOPSIS
    Paste-ready additions for a think-cell PSADT Deploy-Application.ps1:
    MSI-derived ProductCode/version, guarded ARP-entry insurance for
    Post-Install / Repair, entry cleanup for Post-Uninstall.

.DESCRIPTION
    v4 (Sep 11 2026): GUID-shape checks (derivation throws on a malformed
    ProductCode; the function itself refuses to touch registry without a real
    GUID - closes the write-under-Uninstall-root edge) and EstimatedSize now
    measured from the actual install dir (self-maintaining across versions).

    v3 (Sep 11 2026): added an install-presence guard (never fabricates an ARP
    entry for a product that is not actually installed) and dual-surface
    logging (narrative lines for humans + THINKCELL_ARP key=value lines for
    grep/AI post-mortem). All logging goes through PSADT Write-Log ONLY, so it
    lands in whatever per-app / per-installtype log location the toolkit is
    configured for - nothing here hardcodes a log path.

    v2: ProductCode and version DERIVED at runtime from the single .msi in
    $dirFiles (ANY filename - rename-proof; validated against the MSI's own
    ProductName metadata; throws loudly on zero/multiple MSIs or a
    non-think-cell file). Version bumps = "swap the MSI in Files".

    Uninstall bonus: Execute-MSI -Action Uninstall accepts the MSI FILE PATH
    and resolves the ProductCode itself:
      Execute-MSI -Action Uninstall -Path $msiPath -ExitCodes 0,1605,3010,1641

    WHY the ARP insurance: the think-cell MSI is 32-bit, so Windows Installer
    publishes its Uninstall entry under HKLM\SOFTWARE\WOW6432Node (live-verified
    Sep 11 2026). If an install/repair completes without that entry (or anything
    later strips it), registry-based inventory and Apps & Features go blind.
    Set-ThinkCellArpEntry re-creates it - guarded, idempotent, deliberately
    single-location (no native-hive mirror = no duplicate Apps listing).

    PASTE TARGETS in Deploy-Application.ps1:
      1. Everything from "MSI-derived variables" down through the
         Set-ThinkCellArpEntry function AFTER the template's `$dirFiles`
         definition (end of the VARIABLE DECLARATION block).
      2. Optionally set `$appVersion = $script:appDisplayVersion` right after
         the template's $appVersion line (stops the hand-bumped version string).
      3. Post-Install:  call  Set-ThinkCellArpEntry  after Execute-MSI.
      4. Repair-Title:  call  Set-ThinkCellArpEntry  after the repair action.
      5. Post-Uninstall: the small cleanup loop (removes the entry if the
         MSI uninstall somehow left it behind).

    DISCIPLINE: keep exactly ONE .msi in Files (any filename).
#>

# --- 1. MSI-derived variables (runs inside Deploy-Application.ps1) ---
function Get-MsiProperty {
    # Read a property from an MSI's Property table (read-only, no elevation).
    param([string]$MsiPath, [string]$Property)
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$installer,@($MsiPath,0))
    $view = $db.GetType().InvokeMember('OpenView','InvokeMethod',$null,$db,@("SELECT Value FROM Property WHERE Property='$Property'"))
    $view.GetType().InvokeMember('Execute','InvokeMethod',$null,$view,$null) | Out-Null
    $rec = $view.GetType().InvokeMember('Fetch','InvokeMethod',$null,$view,$null)
    if ($null -eq $rec) { return $null }
    $rec.GetType().InvokeMember('StringData','GetProperty',$null,$rec,@(1))
}

$msiFile = Get-ChildItem -Path $script:dirFiles -Filter '*.msi' -ErrorAction SilentlyContinue
if (-not $msiFile) { throw "No .msi found in $script:dirFiles - drop the think-cell MSI in Files (any filename)." }
if (@($msiFile).Count -gt 1) { throw "Multiple MSIs in $script:dirFiles - keep exactly one (found $(@($msiFile).Count))." }
[string]$script:msiPath           = @($msiFile)[0].FullName
[string]$script:appProductCode    = Get-MsiProperty -MsiPath $script:msiPath -Property 'ProductCode'
[string]$script:appDisplayVersion = Get-MsiProperty -MsiPath $script:msiPath -Property 'ProductVersion'
$msiProductName = Get-MsiProperty -MsiPath $script:msiPath -Property 'ProductName'
if ($msiProductName -ne 'think-cell') { throw "The MSI in Files is '$msiProductName', not 'think-cell' - wrong file in the package." }
if ($script:appProductCode -notmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
    throw "Failed to read a valid ProductCode from $script:msiPath (got '$script:appProductCode') - Windows Installer may be having a problem."
}
# $appVersion = $script:appDisplayVersion   # <- optional: stop hand-bumping the version string

# --- 2. Guarded, logged ARP-entry insurance function ---
function Set-ThinkCellArpEntry {
    # Defensive: never touch registry unless we hold a real GUID (protects against
    # a hand-pasted copy in an old package where the derivation block is absent).
    if ($script:appProductCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
        Write-Log -Message "think-cell ARP: appProductCode is not a valid GUID ('$script:appProductCode') - skipping to avoid writing under the Uninstall root."
        Write-Log -Message 'THINKCELL_ARP action=skip reason=invalid-productcode'
        return
    }
    $arpPaths = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$script:appProductCode",
                  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$script:appProductCode")

    Write-Log -Message ("think-cell ARP check started: ProductCode={0} Version={1}" -f $script:appProductCode, $script:appDisplayVersion)

    # GUARD 1 - product registered with Windows Installer (strongest signal)?
    $registered = $false
    try {
        $inst = New-Object -ComObject WindowsInstaller.Installer
        foreach ($c in $inst.RelatedProducts('{E202304D-BA30-4EDA-9905-7459004CFFD1}')) {
            if ("$c" -eq $script:appProductCode) { $registered = $true }
        }
    } catch {
        Write-Log -Message ("think-cell ARP check: Installer registration query failed ({0}) - falling back to file check." -f $_.Exception.Message)
    }

    # GUARD 2 - install dir actually contains binaries?
    $installDir  = "${env:ProgramFiles(x86)}\think-cell"
    $hasBinaries = (Test-Path $installDir) -and [bool](Get-ChildItem -Path $installDir -Include '*.dll','*.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)

    if (-not $registered -and -not $hasBinaries) {
        Write-Log -Message 'think-cell ARP: product NOT detected as installed (no Installer registration, no binaries in install dir) - skipping. No entry fabricated for an absent product.'
        Write-Log -Message 'THINKCELL_ARP action=skip reason=product-not-installed'
        return
    }
    Write-Log -Message ("think-cell ARP: product present (InstallerRegistered={0} BinariesFound={1})." -f $registered, $hasBinaries)

    # Already published in either hive?
    $existing = Get-ItemProperty -Path $arpPaths -ErrorAction SilentlyContinue
    if ($existing) {
        $where = ($arpPaths | Where-Object { Test-Path $_ } | Select-Object -First 1)
        Write-Log -Message "think-cell ARP: entry already present at $where - no action."
        Write-Log -Message "THINKCELL_ARP action=noop entry=present location=$where"
        return
    }

    # Recreate - WOW6432Node, where the 32-bit MSI itself publishes.
    $key = $arpPaths[1]
    # EstimatedSize: measure the real install dir when present (self-maintaining
    # across versions); 410786 is the measured fallback for 14.0.38.764.
    $sizeKB = 410786
    if (Test-Path $installDir) {
        $measured = [math]::Round(((Get-ChildItem -Path $installDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) / 1KB)
        if ($measured -gt 0) { $sizeKB = $measured }
    }
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name DisplayName      -Value 'think-cell'                                 -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name DisplayVersion   -Value $script:appDisplayVersion                    -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name Publisher        -Value 'think-cell Operations GmbH'                 -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name InstallDate      -Value (Get-Date -Format yyyyMMdd)                  -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name InstallLocation  -Value "${env:ProgramFiles(x86)}\think-cell\"        -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name UninstallString  -Value "MsiExec.exe /X$script:appProductCode"       -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name ModifyPath       -Value "MsiExec.exe /X$script:appProductCode"       -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name URLInfoAbout     -Value 'https://www.think-cell.com'                 -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name Contact          -Value 'support@think-cell.com'                     -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name EstimatedSize    -Value $sizeKB                                        -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $key -Name WindowsInstaller -Value 1                                             -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $key -Name NoModify         -Value 1                                             -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $key -Name NoRepair         -Value 1                                             -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $key -Name VersionMajor     -Value ([int]$script:appDisplayVersion.Split('.')[0]) -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name VersionMinor     -Value ([int]$script:appDisplayVersion.Split('.')[1]) -PropertyType DWord -Force | Out-Null
    Write-Log -Message "think-cell ARP: entry was MISSING - re-created at $key (WOW6432Node, where the 32-bit MSI publishes)."
    Write-Log -Message ("THINKCELL_ARP action=recreate hive=WOW6432Node productcode={0} version={1} registered={2} binaries={3} installdate={4}" -f $script:appProductCode, $script:appDisplayVersion, $registered, $hasBinaries, (Get-Date -Format yyyyMMdd))
}

# --- 3/4. Post-Install AND Repair-Title: after the MSI action ---
# Set-ThinkCellArpEntry

# --- 5. Post-Uninstall: remove the entry if the uninstall left it behind ---
<#
foreach ($p in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$appProductCode",
                 "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$appProductCode")) {
    if (Test-Path $p) {
        Remove-Item $p -Recurse -Force
        Write-Log -Message "think-cell ARP: removed orphaned entry at $p after uninstall."
        Write-Log -Message "THINKCELL_ARP action=remove-orphaned location=$p"
    }
}
#>
