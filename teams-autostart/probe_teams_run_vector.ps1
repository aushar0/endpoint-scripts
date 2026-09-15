[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Write-Output '=== A. HKCU Run "Teams" VALUE DATA ==='
$k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$rp = Get-ItemProperty -LiteralPath $k
Write-Output ("Teams = {0}" -f $rp.Teams)

Write-Output ''
Write-Output '=== B. StartupApproved "Teams" FLAG BYTES (first byte: even=enabled, odd=disabled) ==='
$k2 = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$sa = Get-ItemProperty -LiteralPath $k2
$b = $sa.Teams
if ($null -ne $b) {
    Write-Output ("bytes = ({0})" -f (($b | ForEach-Object { $_.ToString('X2') }) -join ' '))
    $flag = $b[0]
    $state = if ($flag % 2 -eq 0) { 'ENABLED' } else { 'DISABLED' }
    $ft = [DateTime]::FromFileTime([BitConverter]::ToInt64($b, 4))
    Write-Output ("first byte = {0} -> {1}; last-toggle FILETIME = {2}" -f $flag, $state, $ft)
} else {
    Write-Output '(no StartupApproved value for Teams -> default = ENABLED)'
}

Write-Output ''
Write-Output '=== C. ms-teams.exe APP EXECUTION ALIAS ==='
$alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\ms-teams.exe'
if (Test-Path $alias) {
    Write-Output ("exists: {0}" -f $alias)
    $item = Get-Item -LiteralPath $alias -Force
    Write-Output ("target: {0}" -f $item.Target)
} else {
    Write-Output ("not found: {0}" -f $alias)
}

Write-Output ''
Write-Output '=== D. FIND desktop-config.json UNDER PACKAGE FOLDER ==='
$pkgDir = Join-Path $env:LOCALAPPDATA 'Packages\MSTeams_8wekyb3d8bbwe'
$hits = Get-ChildItem -LiteralPath $pkgDir -Recurse -Filter 'desktop-config.json' -ErrorAction SilentlyContinue
if ($hits) {
    foreach ($h in $hits) {
        Write-Output ("found: {0}" -f $h.FullName)
        $raw = Get-Content -Raw -LiteralPath $h.FullName
        $auto = [regex]::Matches($raw, '"[a-zA-Z_\-]*[Aa]uto[a-zA-Z_\-]*"\s*:\s*[^,}]{1,60}')
        foreach ($m in $auto) { Write-Output ("  {0}" -f $m.Value) }
    }
} else {
    Write-Output '(desktop-config.json not found under package dir - Teams may not be signed in on this user)'
}

Write-Output ''
Write-Output '=== PROBE2 COMPLETE ==='
