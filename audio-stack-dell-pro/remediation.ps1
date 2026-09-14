<#
REMEDIATION: fixes everything the paired detection flags, in one run.
  Services -> Delayed-Auto (exact names matter; a near-miss name silently skips
  while detection keeps flagging = infinite loop. Manual/Disabled are SKIPPED,
  never resurrected. Skips services with active dependents. Verifies after apply.)
  clabp Run entry -> StartupApproved disable flag (03 = disabled). The value is
  left in place on purpose: the vendor writer service only checks existence, so
  present-but-disabled keeps its persistence gate closed while Explorer skips
  the launch. Reversible (flip first byte to 02).
Exit codes: 0 = clean (applied/skipped), 1 = any failure.
#>
$ErrorActionPreference = 'Stop'
$failures=@(); $applied=@(); $skipped=@()

foreach ($svcName in @('CLConfigService','CsGMMuteSrv')) {
  try {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
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

try {
    $run = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).clabp
    if ($run) {
        $flag = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -ErrorAction SilentlyContinue).clabp
        if (-not $flag -or (($flag[0] % 2) -eq 0)) {
            New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name clabp `
                -PropertyType Binary -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -Force | Out-Null
            $f = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run').clabp
            if ($f -and $f[0] -eq 3) { $applied += 'clabp-flag' } else { $failures += 'clabp-flag (verify failed)' }
        }
    }
} catch { $failures += "clabp (exception: $($_.Exception.Message))" }

if ($applied.Count -gt 0) { Write-Output "Applied: $($applied -join ', ')" }
if ($skipped.Count -gt 0) { Write-Output "Skipped: $($skipped -join ', ')" }
if ($failures.Count -gt 0) { Write-Output "Failed: $($failures -join '; ')"; exit 1 }
exit 0
