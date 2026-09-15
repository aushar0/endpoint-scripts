$ErrorActionPreference = 'SilentlyContinue'
Write-Output '=== 1. Execution policy (per scope) ==='
Get-ExecutionPolicy -List | Format-Table -AutoSize | Out-String | Write-Output

Write-Output '=== 2. PowerShell logging GPO (script block / transcription / module) ==='
$keys = @(
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging',
    'HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'
)
$found = $false
foreach ($k in $keys) {
    $p = Get-ItemProperty $k
    if ($p) { $found = $true; Write-Output ("{0} -> {1}" -f $k, ($p | Out-String).Trim()) }
}
if (-not $found) { Write-Output 'No PowerShell logging GPO keys present' }

Write-Output '=== 3. Language mode (Constrained = worker breaks) ==='
Write-Output ("SessionState LanguageMode: {0}" -f $ExecutionContext.SessionState.LanguageMode)

Write-Output '=== 4. AppLocker ==='
Write-Output ("AppIDSvc (needs running for enforcement): {0}" -f (Get-Service AppIDSvc).Status)
$alLog = Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -MaxEvents 3
if ($alLog) { $alLog | ForEach-Object { Write-Output ("  {0} {1}" -f $_.TimeCreated, $_.Message.Split("`n")[0]) } } else { Write-Output '  AppLocker EXE/DLL log empty/absent (no enforcement events)' }

Write-Output '=== 5. WDAC / Smart App Control ==='
$sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy').VerifiedAndReputablePolicyState
$sacTxt = switch ($sac) { 0 {'OFF'} 1 {'ON (enforcing)'} 2 {'Evaluation mode'} default {"state=$sac"} }
Write-Output ("Smart App Control: {0}" -f $sacTxt)
$ci = Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 5
if ($ci) { $ci | ForEach-Object { Write-Output ("  {0} id={1} {2}" -f $_.TimeCreated, $_.Id, $_.Message.Split("`n")[0]) } } else { Write-Output '  CodeIntegrity log: no recent events' }

Write-Output '=== 6. EDR presence ==='
foreach ($svc in 'CSFalconService','CSFalconContainer','Sense','WdNisSvc','WinDefend') {
    $s = Get-Service $svc
    if ($s) { Write-Output ("  {0}: {1}" -f $svc, $s.Status) }
}
Write-Output '=== 7. Nexthink Collector ==='
Get-Service *nxt* | ForEach-Object { Write-Output ("  {0}: {1}" -f $_.Name, $_.Status) }
Get-Process | Where-Object { $_.Name -match '^nxt' } | Select-Object -First 3 | ForEach-Object { Write-Output ("  proc: {0}" -f $_.Name) }
