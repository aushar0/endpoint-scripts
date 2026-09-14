<#
DETECTION (Intune remediation / Nexthink RA compatible)
One policy, both levers of the Cirrus audio stack boot cost:
  1. Service CLConfigService (APO config, binary EnhanceCS.exe) must be
     Delayed-Auto (Manual/Disabled = compliant, untouched by design; absent = N/A).
     The hardware mic-mute service (CsGMMuteSrv) is deliberately NOT targeted:
     it is a hotkey/LED handler with negligible start cost, and deferring it
     only delays the mute key after boot.
  2. The "clabp" Run entry (logon companion process) must be flagged disabled
     via StartupApproved (absent = N/A).
Exit codes: 0 = compliant/N-A, 1 = remediate.
Output: line 1 = one-line status summary (Intune column-friendly);
        following lines = per-item detail for troubleshooting.
#>
$ErrorActionPreference = 'SilentlyContinue'
$issues = @(); $okItems = @(); $notes = @(); $detail = @()
$anyService = $false

foreach ($svcName in @('CLConfigService')) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$svcName'"
    if (-not $svc) { $detail += "[svc] $svcName : not present"; continue }
    $anyService = $true
    $state = "StartMode=$($svc.StartMode) DelayedAutoStart=$($svc.DelayedAutoStart)"
    if ($svc.StartMode -eq 'Auto' -and $svc.DelayedAutoStart -eq 0) {
        $issues  += "$svcName=Auto-no-delay"
        $detail  += "[svc] $svcName : NON-COMPLIANT ($state) - expected Delayed-Auto"
    } elseif ($svc.StartMode -ne 'Auto') {
        $notes += "$svcName=$($svc.StartMode)"
        $detail += "[svc] $svcName : compliant-by-design ($state - non-Auto states left untouched)"
    } else {
        $okItems += "$svcName=delayed"
        $detail  += "[svc] $svcName : OK ($state)"
    }
}

$run = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).clabp
if ($run) {
    $flag = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -ErrorAction SilentlyContinue).clabp
    $flagHex = if ($flag) { ($flag | ForEach-Object { $_.ToString('X2') }) -join ' ' } else { 'not-set' }
    if (-not $flag -or (($flag[0] % 2) -eq 0)) {
        $issues += 'clabp-startup-enabled'
        $detail += "[run] clabp : NON-COMPLIANT - entry present, StartupApproved flag=$flagHex (disabled requires odd first byte, e.g. 03)"
    } else {
        $okItems += 'clabp=disabled'
        $detail  += "[run] clabp : OK - entry present, flag=$flagHex (disabled)"
    }
} else {
    $detail += '[run] clabp : not present'
}

if (-not $anyService -and -not $run) {
    Write-Output 'Compliant - N/A | no Cirrus audio stack on this device'
    exit 0
}
if ($issues.Count -gt 0) {
    Write-Output "Non-compliant - $($issues.Count) issue(s) | $($issues -join ', ')"
    if ($okItems) { Write-Output "  already-ok: $($okItems -join ', ')" }
    if ($notes)   { Write-Output "  by-design-untouched: $($notes -join ', ')" }
    $detail | ForEach-Object { Write-Output "  $_" }
    exit 1
}
Write-Output "Compliant | $($okItems -join ', ')"
if ($notes) { Write-Output "  by-design-untouched: $($notes -join ', ')" }
$detail | ForEach-Object { Write-Output "  $_" }
exit 0
