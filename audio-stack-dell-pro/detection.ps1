<#
DETECTION (Intune remediation / Nexthink RA compatible)
One policy, both levers of the Cirrus audio stack boot cost:
  1. Services CLConfigService + CsGMMuteSrv must be Delayed-Auto
     (Manual/Disabled = compliant, left untouched by design; absent = N/A).
  2. The "clabp" Run entry (logon companion process) must be flagged disabled
     via StartupApproved (absent = N/A).
Exit codes: 0 = compliant/N-A, 1 = remediate. Output lines are report-column friendly.
#>
$ErrorActionPreference = 'SilentlyContinue'
$reasons = @(); $notes = @()
$anyService = $false

foreach ($svcName in @('CLConfigService','CsGMMuteSrv')) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$svcName'"
    if (-not $svc) { continue }
    $anyService = $true
    if ($svc.StartMode -eq 'Auto' -and $svc.DelayedAutoStart -eq 0) {
        $reasons += "$svcName=Auto-no-delay"
    } elseif ($svc.StartMode -ne 'Auto') {
        $notes += "$svcName=$($svc.StartMode) (untouched by design)"
    }
}

$run  = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).clabp
if ($run) {
    $flag = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -ErrorAction SilentlyContinue).clabp
    if (-not $flag -or (($flag[0] % 2) -eq 0)) { $reasons += 'clabp-startup-enabled' }
    else { $notes += 'clabp=disabled' }
}

if (-not $anyService -and -not $run) { Write-Output 'Compliant - N/A: no Cirrus audio stack on this device'; exit 0 }
if ($reasons.Count -gt 0) { Write-Output "Non-compliant: $($reasons -join ', ')"; if ($notes) { Write-Output "  ok: $($notes -join '; ')" }; exit 1 }
if ($notes) { Write-Output "Compliant (notes: $($notes -join '; '))" } else { Write-Output 'Compliant' }
exit 0
