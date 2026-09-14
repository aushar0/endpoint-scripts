<#
REMEDIATION: set Cirrus audio services to Delayed-Auto (boot-smoothing).
Design notes:
- Exact service names matter: CLConfigService (APO config service, binary
  EnhanceCS.exe) and CsGMMuteSrv (hardware mic-mute key/LED service). A
  near-miss name does not error - it silently skips, which pairs badly with
  a detection that keeps flagging the real name. (VM-proven failure mode.)
- Manual/Disabled services are SKIPPED, never flipped back to Auto. Resurrecting
  non-Auto services is a policy decision, not a side effect. (VM-proven mode.)
- Verify-after-apply: re-reads SCM state one second after sc.exe config.
Exit codes: 0 applied/skipped cleanly, 1 any failure.
#>
$ErrorActionPreference = 'Stop'
$targetServices = @('CLConfigService','CsGMMuteSrv')
$failures=@(); $skipped=@(); $applied=@()
foreach ($svcName in $targetServices) {
  try {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Output "$svcName not found - skipping"; $skipped += $svcName; continue }
    if ($svc.StartMode -eq 'Auto' -and $svc.DelayedAutoStart -eq 1) { continue }
    if ($svc.StartMode -ne 'Auto') { Write-Output "$svcName is $($svc.StartMode) - leaving untouched (by design)"; $skipped += $svcName; continue }
    $dependents = (Get-Service -Name $svcName -ErrorAction SilentlyContinue).DependentServices | Where-Object { $_.Status -ne 'Stopped' }
    if ($dependents.Count -gt 0) { Write-Output "$svcName active dependents ($($dependents.Name -join ',')) - skipping"; $skipped += $svcName; continue }
    $null = & sc.exe config $svcName start= delayed-auto 2>&1
    if ($LASTEXITCODE -ne 0) { $failures += "$svcName (sc.exe exit $LASTEXITCODE)"; continue }
    Start-Sleep -Seconds 1
    $verify = Get-CimInstance Win32_Service -Filter "Name='$svcName'"
    if ($verify.StartMode -eq 'Auto' -and $verify.DelayedAutoStart -eq 1) { $applied += $svcName }
    else { $failures += "$svcName (verify failed)" }
  } catch { $failures += "$svcName (exception: $($_.Exception.Message))" }
}
if ($applied.Count  -gt 0) { Write-Output "Applied: $($applied -join ', ')" }
if ($skipped.Count  -gt 0) { Write-Output "Skipped: $($skipped -join ', ')" }
if ($failures.Count -gt 0) { Write-Output "Failed: $($failures -join '; ')"; exit 1 }
exit 0
