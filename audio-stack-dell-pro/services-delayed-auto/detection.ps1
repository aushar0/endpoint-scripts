<#
DETECTION (Intune remediation format / Nexthink RA compatible)
Target: Cirrus Logic audio services on Dell Pro platforms.
Compliant   = service absent, already Delayed-Auto, or Manual/Disabled
             (non-Auto states are treated as stricter-than-delayed and left alone).
Non-compliant = service exists with StartMode=Auto and DelayedAutoStart=0.
Exit codes: 0 compliant (incl. N/A - no Cirrus services on this device), 1 remediate.
VM-validated logic; see kit README verification table.
#>
$ErrorActionPreference = 'SilentlyContinue'
$targetServices = @('CLConfigService','CsGMMuteSrv')
$nonCompliant = @(); $notFound = @(); $otherState = @()
foreach ($svcName in $targetServices) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$svcName'"
    if (-not $svc) { $notFound += $svcName; continue }
    if ($svc.StartMode -eq 'Auto' -and $svc.DelayedAutoStart -eq 0) {
        $nonCompliant += $svcName
    } elseif ($svc.StartMode -ne 'Auto') {
        $otherState += "$svcName=$($svc.StartMode)"
    }
}
if ($notFound.Count -eq $targetServices.Count) { Write-Output 'Compliant - N/A: no Cirrus audio services on this device'; exit 0 }
if ($nonCompliant.Count -gt 0) { Write-Output "Non-compliant: $($nonCompliant -join ', ') (standard Auto, not delayed)"; exit 1 }
if ($otherState) { Write-Output "Compliant: $($otherState -join ', ') (non-Auto states left untouched by design)" }
Write-Output 'Compliant: Cirrus audio services already Delayed-Auto'; exit 0
