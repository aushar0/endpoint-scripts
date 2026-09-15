[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$family = 'MSTeams_8wekyb3d8bbwe'

Write-Output '=== 1. APPX PACKAGE ==='
$pkg = Get-AppxPackage -Name MSTeams -ErrorAction SilentlyContinue
if (-not $pkg) {
    Write-Output 'MSTeams package: NOT FOUND for current user'
} else {
    Write-Output ("Name       : {0}" -f $pkg.Name)
    Write-Output ("Version    : {0}" -f $pkg.Version)
    Write-Output ("InstallLoc : {0}" -f $pkg.InstallLocation)
    Write-Output ("Status     : {0}" -f $pkg.Status)
}

Write-Output ''
Write-Output '=== 2. MANIFEST STARTUPTASK ELEMENTS ==='
if ($pkg) {
    try {
        $raw = Get-Content -Raw -LiteralPath (Join-Path $pkg.InstallLocation 'AppxManifest.xml') -ErrorAction Stop
        $mt = [regex]::Matches($raw, '<[a-zA-Z0-9:]*StartupTask[^>]*>')
        if ($mt.Count -eq 0) { Write-Output '(no StartupTask elements found)' }
        foreach ($m in $mt) { Write-Output ("  {0}" -f $m.Value) }
    } catch {
        Write-Output ("direct manifest read failed: {0}" -f $_.Exception.Message)
        Write-Output 'fallback: Get-AppxPackageManifest extension scan'
        try {
            $mx = Get-AppxPackageManifest -Package $pkg
            $apps = $mx.Package.Applications.Application
            foreach ($a in $apps) {
                if ($null -ne $a.Extensions) {
                    foreach ($e in $a.Extensions.Extension) {
                        $xo = $e.OuterXml
                        if ($xo -match 'StartupTask') { Write-Output ("  {0}" -f $xo) }
                    }
                }
            }
        } catch { Write-Output ("Get-AppxPackageManifest failed: {0}" -f $_.Exception.Message) }
    }
} else {
    Write-Output '(skipped - package not found)'
}

Write-Output ''
Write-Output '=== 3. STARTUPTASK STATE KEYS (SystemAppData) ==='
$base = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
$pkgBase = Join-Path $base $family
if (Test-Path $pkgBase) {
    Get-ChildItem -LiteralPath $pkgBase | ForEach-Object {
        Write-Output ("Subkey : {0}" -f $_.PSChildName)
        $props = Get-ItemProperty -LiteralPath $_.PSPath
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -notlike 'PS*') {
                if ($p.Value -is [byte[]]) {
                    Write-Output ("  {0} = [byte[]] ({1})" -f $p.Name, (($p.Value | ForEach-Object { $_.ToString() }) -join ','))
                } else {
                    Write-Output ("  {0} = {1}" -f $p.Name, $p.Value)
                }
            }
        }
    }
} else {
    Write-Output ("no SystemAppData key for {0}" -f $family)
}

Write-Output ''
Write-Output '=== 4. CLASSIC RUN + STARTUPAPPROVED (expect none for MSIX) ==='
foreach ($k in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
)) {
    if (Test-Path $k) {
        $rp = Get-ItemProperty -LiteralPath $k
        $names = $rp.PSObject.Properties.Name | Where-Object { $_ -match 'team' }
        if ($names) { Write-Output ("{0} -> {1}" -f $k, ($names -join ', ')) }
        else { Write-Output ("{0} -> (no teams values)" -f $k) }
    }
}
foreach ($k in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
)) {
    if (Test-Path $k) {
        $sa = Get-ItemProperty -LiteralPath $k
        $names = $sa.PSObject.Properties.Name | Where-Object { $_ -match 'team' }
        if ($names) { Write-Output ("{0} -> {1}" -f $k, ($names -join ', ')) }
        else { Write-Output ("{0} -> (no teams values)" -f $k) }
    }
}

Write-Output ''
Write-Output '=== 5. SCHEDULED TASKS matching teams ==='
$st = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'team' }
if (-not $st) { Write-Output '(none)' }
foreach ($t in $st) { Write-Output ("{0}{1} State={2}" -f $t.TaskPath, $t.TaskName, $t.State) }

Write-Output ''
Write-Output '=== 6. TEAMS-RELATED PROCESSES NOW ==='
$procs = Get-Process -Name 'ms-teams*','msteams*','msedgewebview2' -ErrorAction SilentlyContinue
if (-not $procs) {
    Write-Output '(none running)'
} else {
    foreach ($g in ($procs | Group-Object Name)) {
        Write-Output ("{0} x{1} totalWS={2:N0}MB" -f $g.Name, $g.Count, (($g.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB))
    }
}

Write-Output ''
Write-Output '=== 7. START APPS (AUMID) ==='
foreach ($sa in (Get-StartApps | Where-Object { $_.AppID -like ("*{0}*" -f $family) -or $_.Name -like '*Teams*' })) {
    Write-Output ("{0}  ->  {1}" -f $sa.Name, $sa.AppID)
}

Write-Output ''
Write-Output '=== 8. TEAMS INTERNAL CONFIG (app-side autostart setting) ==='
$cfg = Join-Path $env:LOCALAPPDATA "Packages\$family\LocalCache\Microsoft\MSTeams\desktop-config.json"
if (Test-Path $cfg) {
    Write-Output ("config found: {0}" -f $cfg)
    $raw = Get-Content -Raw -LiteralPath $cfg
    $auto = [regex]::Matches($raw, '"[a-zA-Z_-]*auto[a-zA-Z_-]*"\s*:\s*[^,}]{1,60}')
    if ($auto.Count -gt 0) {
        foreach ($m in $auto) { Write-Output ("  {0}" -f $m.Value) }
    } else {
        Write-Output '  (no *auto* key matched in config)'
    }
} else {
    Write-Output ("config not found: {0}" -f $cfg)
}

Write-Output ''
Write-Output '=== PROBE COMPLETE ==='
