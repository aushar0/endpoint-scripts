<#
.SYNOPSIS
    Intune Proactive Remediations detection script for the teams-autostart kit.
    Exit 0 (+ stdout) = compliant; exit 1 = remediation needed.

.DESCRIPTION
    Mode-aware: reads the mode marker written by deploy_teams_autostart.ps1
    (%LOCALAPPDATA%\teams-autostart\mode.txt). No marker = Disable behavior
    (backward compatible).

    Always required: TeamsTfwStartupTask State = 1 (DisabledByUser); Run
    'Teams' value absent or its StartupApproved flag byte odd (disabled).

    Delay mode additionally requires: the 'Teams Delayed Start' task present.

    Runs in user context (Intune: "Run this script using the logged-on credentials").
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$taskKey = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\MSTeams_8wekyb3d8bbwe\TeamsTfwStartupTask'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$sakKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$taskName = 'Teams Delayed Start'
$kitDir = Join-Path $env:LOCALAPPDATA 'teams-autostart'

function Get-RegProp([string]$path, [string]$name) {
    # null-safe: StrictMode + missing registry property = terminating error
    $props = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
    if ($props -and ($props.PSObject.Properties.Name -contains $name)) { return $props.$name }
    return $null
}

$mode = 'Disable'
$modeFile = Join-Path $kitDir 'mode.txt'
if (Test-Path $modeFile) {
    $m = Get-Content -LiteralPath $modeFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { $mode = $m.Trim() }
}

$state = Get-RegProp $taskKey 'State'
if ($state -ne 1) { Write-Output "non-compliant: TeamsTfwStartupTask State=$state (want 1)"; exit 1 }

$run = Get-RegProp $runKey 'Teams'
if ($run) {
    $flag = Get-RegProp $sakKey 'Teams'
    if (-not $flag -or ($flag[0] % 2 -eq 0)) {
        Write-Output "non-compliant: Run 'Teams' value present and not flag-disabled"
        exit 1
    }
}

if ($mode -eq 'Delay') {
    $task = Get-ScheduledTask -TaskName $taskName
    if (-not $task) { Write-Output "non-compliant: mode=Delay but '$taskName' task missing"; exit 1 }
}

Write-Output "compliant: vectors disabled, mode=$mode"
exit 0
