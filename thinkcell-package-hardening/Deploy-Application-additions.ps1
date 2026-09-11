<#
.SYNOPSIS
    Paste-ready additions for a think-cell PSADT Deploy-Application.ps1:
    MSI-derived ProductCode/version, ARP-entry insurance for Post-Install /
    Repair, entry cleanup for Post-Uninstall.

.DESCRIPTION
    v2 (Sep 11 2026): ProductCode and version are now DERIVED at runtime from
    the single .msi in $dirFiles (ANY filename - rename-proof; validated by
    the MSI's own ProductName metadata, and it throws loudly on zero/multiple
    MSIs or a non-think-cell file) - version bumps become "swap the MSI file
    in Files", no GUID lookups, no stale hard-coded codes (the checklist-#1
    failure class). The MSI Property table is read via the Windows Installer
    COM object (same reader Invoke-ThinkCellPackageTest.ps1 uses; read-only,
    no elevation needed).

    Uninstall bonus: Execute-MSI -Action Uninstall accepts the MSI FILE PATH
    and resolves the ProductCode itself, so no GUID is needed anywhere:
      Execute-MSI -Action Uninstall -Path $msiPath -ExitCodes 0,1605,3010,1641
    (1605 = "not installed on this machine" - makes uninstall idempotent.)

    WHY the ARP insurance: the think-cell MSI is 32-bit, so Windows Installer
    publishes its Uninstall entry under HKLM\SOFTWARE\WOW6432Node (live-verified
    Sep 11 2026). If an install/repair completes without that entry (or anything
    later strips it), registry-based inventory and Apps & Features go blind.
    Set-ThinkCellArpEntry re-creates it - idempotent, and deliberately writes
    ONLY the WOW6432Node location (where the MSI itself publishes; a native-hive
    mirror would duplicate the Apps & Features listing).

    PASTE TARGETS in Deploy-Application.ps1:
      1. Everything from "MSI-derived variables" down through the Set-ThinkCellArpEntry
         function AFTER the template's `$dirFiles` definition (end of the
         VARIABLE DECLARATION block - $dirFiles must exist first).
      2. Optionally set `$appVersion = $script:appDisplayVersion` right after
         the template's $appVersion line (stops the hand-bumped version string).
      3. Post-Install:  call  Set-ThinkCellArpEntry  after Execute-MSI.
      4. Repair-Title:  call  Set-ThinkCellArpEntry  after the repair action.
      5. Post-Uninstall: the small cleanup loop (removes the entry if the
         MSI uninstall somehow left it behind).

    DISCIPLINE: keep exactly ONE .msi in Files (any filename) - the
    discovery block throws otherwise (deliberately loud, so a stale MSI can
    never silently win).
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
# $appVersion = $script:appDisplayVersion   # <- optional: stop hand-bumping the version string

# --- 2. ARP-entry insurance function ---
function Set-ThinkCellArpEntry {
    $arpPaths = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$script:appProductCode",
                  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$script:appProductCode")
    if (Get-ItemProperty -Path $arpPaths -ErrorAction SilentlyContinue) {
        Write-Log -Message 'think-cell ARP entry already present - no action.'
        return
    }
    $key = $arpPaths[1]  # WOW6432Node: where the 32-bit MSI itself publishes
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
    New-ItemProperty -Path $key -Name EstimatedSize    -Value 410786                                        -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $key -Name WindowsInstaller -Value 1                                             -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $key -Name NoModify         -Value 1                                             -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $key -Name NoRepair         -Value 1                                             -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $key -Name VersionMajor     -Value ([int]$script:appDisplayVersion.Split('.')[0]) -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name VersionMinor     -Value ([int]$script:appDisplayVersion.Split('.')[1]) -PropertyType DWord -Force | Out-Null
    Write-Log -Message "Re-created missing think-cell ARP registry entry (WOW6432Node) for $script:appProductCode v$script:appDisplayVersion."
}

# --- 3/4. Post-Install AND Repair-Title: after the MSI action ---
# Set-ThinkCellArpEntry

# --- 5. Post-Uninstall: remove the entry if the uninstall left it behind ---
<#
foreach ($p in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$appProductCode",
                 "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$appProductCode")) {
    if (Test-Path $p) { Remove-Item $p -Recurse -Force }
}
#>
