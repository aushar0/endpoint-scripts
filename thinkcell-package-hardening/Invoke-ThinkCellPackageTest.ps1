<#
.SYNOPSIS
    One-shot think-cell package test: MSI metadata -> silent install
    (fleet switches) -> evidence capture -> silent uninstall -> cleanliness.

.DESCRIPTION
    Usage:
      .\Invoke-ThinkCellPackageTest.ps1 -MsiPath C:\path\to\setup.msi            (full test, self-elevates)
      .\Invoke-ThinkCellPackageTest.ps1 -MsiPath C:\path\to\setup.msi -ExtractOnly (properties only, no elevation)
    Results are written to thinkcell_test_results.txt next to the MSI.
    Exit codes: 0 = all phases passed, 1 = one or more phases failed,
    2 = MSI not found.
#>

param(
    [Parameter(Mandatory = $true)][string]$MsiPath,
    [switch]$ExtractOnly,
    [string]$LicenseKey
)

$ErrorActionPreference = 'Stop'
$MsiPath = (Resolve-Path $MsiPath -ErrorAction SilentlyContinue).Path
if (-not $MsiPath -or -not (Test-Path -LiteralPath $MsiPath)) {
    Write-Host "MSI not found: $MsiPath"
    exit 2
}
$ResultFile = Join-Path (Split-Path -Parent $MsiPath) 'thinkcell_test_results.txt'

# ---- self-elevate (single UAC fire; everything happens in the elevated run) ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $ExtractOnly) {
    Write-Host 'Elevating (single UAC prompt for the full install/uninstall cycle)...'
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -MsiPath `"$MsiPath`""
    if ($LicenseKey) { $arg += " -LicenseKey `"$LicenseKey`"" }
    $p = Start-Process powershell.exe -ArgumentList $arg -Verb RunAs -Wait -PassThru
    if (Test-Path $ResultFile) { Get-Content $ResultFile | Write-Host }
    exit $p.ExitCode
}

function Write-Result ([string]$Text) {
    $Text | Tee-Object -FilePath $ResultFile -Append
}

function Get-MsiProperty ([string]$Path, [string]$Property) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db,
        @("SELECT Value FROM Property WHERE Property='$Property'"))
    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
    $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
    if ($null -eq $rec) { return $null }
    $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1))
}

function Invoke-Msiexec ([string]$Arguments) {
    $p = Start-Process msiexec.exe -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    return $p.ExitCode
}

$failures = 0
"=== think-cell package test - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Set-Content $ResultFile
"MSI: $MsiPath" | Out-File $ResultFile -Append

# ---- phase 1: MSI properties ----
$productCode = Get-MsiProperty $MsiPath 'ProductCode'
$productVersion = Get-MsiProperty $MsiPath 'ProductVersion'
$upgradeCode = Get-MsiProperty $MsiPath 'UpgradeCode'
$productName = Get-MsiProperty $MsiPath 'ProductName'
Write-Result "`n--- Phase 1: MSI properties ---"
Write-Result ("ProductName={0}" -f $productName)
Write-Result ("ProductVersion={0}" -f $productVersion)
Write-Result ("ProductCode={0}" -f $productCode)
Write-Result ("UpgradeCode={0}" -f $upgradeCode)

if ($ExtractOnly) {
    Write-Host 'ExtractOnly mode - done.'
    exit 0
}

$fleetSwitches = @('/qn', '/norestart', 'UPDATES=0', 'REPORTS=0', 'NOFIRSTSTART=1', 'LaunchPowerPoint=0')
if ($LicenseKey) { $fleetSwitches += "LICENSEKEY=$LicenseKey" }

# ---- phase 2: silent install ----
Write-Result "`n--- Phase 2: silent install (msiexec /i /qn UPDATES=0 REPORTS=0 NOFIRSTSTART=1) ---"
$msiLog = Join-Path $env:TEMP 'thinkcell_install.log'
$installArgs = @('/i', "`"$MsiPath`"", "/l*v `"$msiLog`"") + $fleetSwitches
$installExit = Invoke-Msiexec ($installArgs -join ' ')
Write-Result ("msiexec install exit code: {0}  (0 = success)" -f $installExit)
if ($installExit -ne 0) { $failures++ }

Start-Sleep -Seconds 3

# ---- phase 3: evidence ----
Write-Result "`n--- Phase 3: post-install evidence ---"
$arpKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"
$arpWow = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"
$arp = Get-ItemProperty -Path $arpKey -ErrorAction SilentlyContinue
if (-not $arp) {
    $arp = Get-ItemProperty -Path $arpWow -ErrorAction SilentlyContinue
    if ($arp) { $arpKey = $arpWow }
}
if ($arp) {
    Write-Result ("ARP entry present at {0}: DisplayName='{1}' DisplayVersion='{2}'" -f $arpKey, $arp.DisplayName, $arp.DisplayVersion)
    Write-Result ("ARP UninstallString: {0}" -f $arp.UninstallString)
} else {
    Write-Result 'ARP entry: MISSING (fail)'
    $failures++
}

$installDir = "${env:ProgramFiles(x86)}\think-cell"
if (-not (Test-Path $installDir)) { $installDir = "$env:ProgramFiles\think-cell" }
if (Test-Path $installDir) {
    Write-Result ("Install dir: {0}" -f $installDir)
    Get-ChildItem $installDir -Recurse -Include *.dll, *.exe -ErrorAction SilentlyContinue |
        Select-Object -First 8 | ForEach-Object {
            Write-Result ("  {0}  v={1}" -f $_.FullName.Replace($installDir, ''), $_.VersionInfo.FileVersion)
        }
} else {
    Write-Result 'Install dir: MISSING (fail)'
    $failures++
}

foreach ($hive in 'HKLM:', 'HKLM:\SOFTWARE\WOW6432Node') {
    foreach ($officeApp in 'PowerPoint', 'Excel') {
        $key = "$hive\SOFTWARE\Microsoft\Office\$officeApp\Addins\thinkcell.addin"
        if (Test-Path $key) {
            $loadBehavior = (Get-ItemProperty $key -ErrorAction SilentlyContinue).LoadBehavior
            Write-Result ("Office add-in key: $officeApp @ $hive (LoadBehavior=$loadBehavior)")
        }
    }
}

# ---- phase 4: silent uninstall ----
Write-Result "`n--- Phase 4: silent uninstall (msiexec /x $productCode /qn) ---"
$uninstallExit = Invoke-Msiexec ("/x `"$productCode`" /qn /l*v `"$env:TEMP\thinkcell_uninstall.log`"")
Write-Result ("msiexec uninstall exit code: {0}" -f $uninstallExit)
if ($uninstallExit -ne 0) { $failures++ }

Start-Sleep -Seconds 3

# ---- phase 5: cleanliness ----
Write-Result "`n--- Phase 5: post-uninstall cleanliness ---"
if (Test-Path $arpKey) { Write-Result 'ARP entry still present (fail)'; $failures++ } else { Write-Result 'ARP entry removed' }
if (Test-Path $installDir) { Write-Result "Install dir remains: $installDir (residue - list contents)"; Get-ChildItem $installDir -Recurse -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { Write-Result ("  left: {0}" -f $_.FullName) } }
else { Write-Result 'Install dir removed' }

# ---- verdict ----
Write-Result ("`n=== VERDICT: {0} ===" -f $(if ($failures -eq 0) { 'PASS - install/uninstall cycle clean' } else { "FAIL - $failures failure(s); see phases above + %TEMP%\thinkcell_install.log / thinkcell_uninstall.log" }))
exit $(if ($failures -eq 0) { 0 } else { 1 })
