[CmdletBinding()]
param(
    [switch]$Revert,
    [switch]$LaunchTest
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$taskKey = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\MSTeams_8wekyb3d8bbwe\TeamsTfwStartupTask'
$saKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$backup  = Join-Path $PSScriptRoot 'autostart_backup.json'

if ($Revert) {
    $b = Get-Content -Raw -LiteralPath $backup | ConvertFrom-Json
    Set-ItemProperty -LiteralPath $taskKey -Name State -Value ([int]$b.taskState) -Type DWord
    Set-ItemProperty -LiteralPath $saKey -Name Teams -Value ([byte[]]($b.runApprovedBytes)) -Type Binary
    Write-Output ("REVERTED: TeamsTfwStartupTask State -> {0}; StartupApproved Teams bytes restored" -f $b.taskState)
    exit 0
}

# --- backup originals ---
$curState = (Get-ItemProperty -LiteralPath $taskKey).State
$curBytes = (Get-ItemProperty -LiteralPath $saKey).Teams
$backupObj = [pscustomobject]@{
    capturedAt       = (Get-Date -Format 'o')
    taskState        = $curState
    runApprovedBytes = @($curBytes)
} | ConvertTo-Json
Set-Content -LiteralPath $backup -Value $backupObj -Encoding ascii
Write-Output ("BACKUP -> {0}" -f $backup)
Write-Output $backupObj

# --- disable vector 1: packaged startup task (State 1 = DisabledByUser) ---
Set-ItemProperty -LiteralPath $taskKey -Name State -Value 1 -Type DWord
$newState = (Get-ItemProperty -LiteralPath $taskKey).State
Write-Output ("VECTOR1 TeamsTfwStartupTask State: {0} -> {1}" -f $curState, $newState)

# --- disable vector 2: Run entry via StartupApproved flag (Task Manager format) ---
$curSa = (Get-ItemProperty -LiteralPath $saKey).Teams
$ft = [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())
$disabledBytes = [byte[]]([byte[]](3, 0, 0, 0) + $ft)
Set-ItemProperty -LiteralPath $saKey -Name Teams -Value $disabledBytes -Type Binary
$newBytes = (Get-ItemProperty -LiteralPath $saKey).Teams
Write-Output ("VECTOR2 StartupApproved Teams: ({0}) -> ({1})" -f
    (($curBytes | ForEach-Object { $_.ToString('X2') }) -join ' '),
    (($newBytes | ForEach-Object { $_.ToString('X2') }) -join ' '))

# --- optional: launch Teams via AUMID, wait, re-read for re-enable behavior ---
if ($LaunchTest) {
    Write-Output ''
    Write-Output 'LAUNCH TEST: explorer.exe shell:AppsFolder\MSTeams_8wekyb3d8bbwe!MSTeams'
    Start-Process explorer.exe 'shell:AppsFolder\MSTeams_8wekyb3d8bbwe!MSTeams'
    Write-Output 'sleeping 75s before durability re-read...'
    Start-Sleep -Seconds 75
    $chkState = (Get-ItemProperty -LiteralPath $taskKey).State
    $chkBytes = (Get-ItemProperty -LiteralPath $saKey).Teams
    Write-Output ("POST-LAUNCH TeamsTfwStartupTask State = {0}" -f $chkState)
    Write-Output ("POST-LAUNCH StartupApproved Teams = ({0})" -f (($chkBytes | ForEach-Object { $_.ToString('X2') }) -join ' '))
    $procs = Get-Process -Name 'ms-teams*','msedgewebview2' -ErrorAction SilentlyContinue
    if ($procs) {
        foreach ($g in ($procs | Group-Object Name)) {
            Write-Output ("  process {0} x{1}" -f $g.Name, $g.Count)
        }
    } else {
        Write-Output '  (no teams processes running after AUMID launch!)'
    }
}

Write-Output ''
Write-Output '=== TEST COMPLETE (run with -Revert to restore originals from backup json) ==='
