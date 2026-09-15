<#
.SYNOPSIS
    Deploys the teams-autostart policy: always disables both native Teams
    autostart vectors; optionally registers a delayed launch task.

.DESCRIPTION
    User-scope only (HKCU + per-user task); no admin required. Idempotent -
    safe to re-run daily (Intune Proactive Remediations remediation script).

    Modes:
      Disable (default)  Both native vectors off. Teams starts only when a
                         user opens it. Zero boot impact, zero disruption.
      Delay              Both native vectors off + a per-user logon task that
                         starts Teams after -DelayMinutes. TRADE-OFF: this
                         launches Teams like a user click - a Teams window
                         WILL appear and take focus at logon+N. There is no
                         quiet delayed start (see CASE_STUDY.md section 3).

    Detection counterpart: detect_delay_drift.ps1 (reads the mode marker this
    script writes).

.PARAMETER Mode
    Disable or Delay. Default Disable.

.PARAMETER DelayMinutes
    Minutes after logon before Teams starts (Delay mode). Default 2.

.PARAMETER SmokeTest
    After registration, fires the task immediately, waits up to 60 s for Teams
    processes, reports, then leaves them running.

.PARAMETER Undo
    Unregisters the task (Delay mode), removes kit files from LOCALAPPDATA.
    Native vectors are NOT restored here - use
    test_disable_teams_autostart.ps1 -Revert for that.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy_teams_autostart.ps1 -Mode Disable
    powershell -ExecutionPolicy Bypass -File .\deploy_teams_autostart.ps1 -Mode Delay -DelayMinutes 5 -SmokeTest
#>
[CmdletBinding()]
param(
    [ValidateSet('Disable', 'Delay')]
    [string]$Mode = 'Disable',
    [int]$DelayMinutes = 2,
    [switch]$SmokeTest,
    [switch]$Undo
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$taskName = 'Teams Delayed Start'
$workDir = Join-Path $env:LOCALAPPDATA 'teams-autostart'
$taskKey = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\MSTeams_8wekyb3d8bbwe\TeamsTfwStartupTask'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$sakKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'

if ($Undo) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output "UNDO: task unregistered, kit files removed from LOCALAPPDATA."
    Write-Output "Native vectors untouched - restore with test_disable_teams_autostart.ps1 -Revert if wanted."
    exit 0
}

# --- 1. disable both native vectors (Task-Manager semantics, reversible) ---
Set-ItemProperty -LiteralPath $taskKey -Name State -Value 1 -Type DWord
if (-not (Test-Path $sakKey)) { New-Item -Path $sakKey -Force | Out-Null }
$ft = [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())
Set-ItemProperty -LiteralPath $sakKey -Name Teams -Value ([byte[]]([byte[]](3, 0, 0, 0) + $ft)) -Type Binary
# null-safe read: the Run value may be absent (the app deletes it itself), and
# StrictMode turns a plain missing-property access into a terminating error
$runProps = Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue
$run = if ($runProps -and ($runProps.PSObject.Properties.Name -contains 'Teams')) { $runProps.Teams } else { $null }
Write-Output ("vector1 State = {0} (1 = DisabledByUser)" -f (Get-ItemProperty -LiteralPath $taskKey).State)
Write-Output ("vector2 Run value: {0}; StartupApproved flag = disabled" -f $(if ($run) { 'present (flagged, not deleted)' } else { 'absent (orphan flag set)' }))

# --- 2. mode marker + (Delay) task registration ---
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Set-Content -LiteralPath (Join-Path $workDir 'mode.txt') -Value $Mode -Encoding ascii

if ($Mode -eq 'Delay') {
    Write-Output ("DELAY MODE: Teams will start {0} min after logon - a Teams window WILL appear and take focus. See CASE_STUDY.md section 3." -f $DelayMinutes)
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -Command "Start-Process ''shell:AppsFolder\MSTeams_8wekyb3d8bbwe!MSTeams''"'
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$env:USERNAME"
    $trigger.Delay = ('PT{0}M' -f $DelayMinutes)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description ('Delayed Teams autostart (AUMID; native autostart disabled; teams-autostart kit, mode=Delay delay={0}min)' -f $DelayMinutes) -Force | Out-Null
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Write-Output ("task registered: state={0} delay=PT{1}M" -f $t.State, $DelayMinutes)
} else {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Output 'DISABLE MODE: no launch task. Teams starts only when a user opens it.'
}

# --- 3. optional smoke test ---
if ($SmokeTest) {
    if ($Mode -ne 'Delay') { Write-Output 'SMOKETEST applies to Delay mode only (Disable has no task to fire).'; exit 0 }
    Get-Process -Name 'ms-teams*','msteams*','msteams_autostarter' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Start-ScheduledTask -TaskName $taskName
    $ok = $false
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 5
        if (@(Get-Process -Name 'ms-teams*','msteams*','msteams_autostarter' -ErrorAction SilentlyContinue).Count -gt 0) { $ok = $true; break }
    }
    $info = Get-ScheduledTaskInfo -TaskName $taskName
    Write-Output ("SMOKETEST: teamsRunning={0} taskResult=0x{1:X8} lastRun={2}" -f $ok, $info.LastTaskResult, $info.LastRunTime)
    if (-not $ok) { Write-Output 'SMOKETEST FAILED'; exit 1 }
    Write-Output 'SMOKETEST PASSED - delayed task launches Teams (window will be visible by design)'
}
Write-Output '=== deploy complete ==='
