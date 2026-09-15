[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$taskKey = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\MSTeams_8wekyb3d8bbwe\TeamsTfwStartupTask'
$saKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'

$state = (Get-ItemProperty -LiteralPath $taskKey -ErrorAction SilentlyContinue).State
$stateName = switch ($state) {
    0 { 'Disabled' }
    1 { 'DisabledByUser' }
    2 { 'Enabled' }
    3 { 'DisabledByPolicy' }
    4 { 'EnabledByPolicy' }
    default { 'UNKNOWN' }
}
Write-Output ("TeamsTfwStartupTask State = {0} ({1})" -f $state, $stateName)

$bytes = (Get-ItemProperty -LiteralPath $saKey -ErrorAction SilentlyContinue).Teams
if ($null -ne $bytes) {
    $flag = $bytes[0]
    $flagName = if ($flag % 2 -eq 0) { 'ENABLED' } else { 'DISABLED' }
    Write-Output ("Run 'Teams' StartupApproved = {0} ({1})" -f $flag, $flagName)
} else {
    Write-Output "Run 'Teams' StartupApproved = (absent -> default ENABLED)"
}

$procs = Get-Process -Name 'ms-teams*','msedgewebview2' -ErrorAction SilentlyContinue
if ($procs) {
    foreach ($g in ($procs | Group-Object Name)) {
        Write-Output ("process {0} x{1} ws={2:N0}MB" -f $g.Name, $g.Count, (($g.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB))
    }
} else {
    Write-Output 'no teams processes running'
}
