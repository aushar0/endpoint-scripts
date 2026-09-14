<#
REMEDIATION: fixes everything the paired detection flags, in one run.
  Services -> Delayed-Auto (exact names matter; Manual/Disabled are SKIPPED,
  never resurrected; active dependents skip; verify after apply).
  clabp Run entry -> StartupApproved disable flag (03). Value left in place on
  purpose (writer service checks existence only). Reversible (flip to 02).
Exit codes: 0 = clean (fixed / no changes needed), 1 = any failure.
Output: line 1 = RESULT summary (applied/skipped/failed counts);
        per-item lines carry before -> after states and failure reasons.
#>
$ErrorActionPreference = 'Stop'
$failures=@(); $applied=@(); $skipped=@(); $detail=@()

foreach ($svcName in @('CLConfigService','CsGMMuteSrv')) {
  try {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    $before = "$($svc.StartMode)/delayed=$($svc.DelayedAutoStart)"
    if ($svc.StartMode -eq 'Auto' -and $svc.DelayedAutoStart -eq 1) { continue }
    if ($svc.StartMode -ne 'Auto') {
      $skipped += $svcName
      $detail += "[svc] $svcName : SKIP - currently $($svc.StartMode) (non-Auto states untouched by design)"
      continue
    }
    $dependents = (Get-Service -Name $svcName -ErrorAction SilentlyContinue).DependentServices | Where-Object { $_.Status -ne 'Stopped' }
    if ($dependents.Count -gt 0) {
      $skipped += $svcName
      $detail += "[svc] $svcName : SKIP - active dependents ($($dependents.Name -join ','))"
      continue
    }
    $null = & sc.exe config $svcName start= delayed-auto 2>&1
    if ($LASTEXITCODE -ne 0) {
      $failures += $svcName
      $detail += "[svc] $svcName : FAIL - sc.exe config exit $LASTEXITCODE ($($svc.StartMode) unchanged)"
      continue
    }
    Start-Sleep -Seconds 1
    $verify = Get-CimInstance Win32_Service -Filter "Name='$svcName'"
    if ($verify.StartMode -eq 'Auto' -and $verify.DelayedAutoStart -eq 1) {
      $applied += $svcName
      $detail += "[svc] $svcName : FIXED - $before -> Auto/delayed=True (verified)"
    } else {
      $failures += $svcName
      $detail += "[svc] $svcName : FAIL - verify mismatch after apply (was $before, now $($verify.StartMode)/delayed=$($verify.DelayedAutoStart))"
    }
  } catch {
    $failures += $svcName
    $detail += "[svc] $svcName : FAIL - exception: $($_.Exception.Message)"
  }
}

try {
    $run = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).clabp
    if ($run) {
        $flag = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -ErrorAction SilentlyContinue).clabp
        $flagBefore = if ($flag) { ($flag | ForEach-Object { $_.ToString('X2') }) -join ' ' } else { 'not-set' }
        if (-not $flag -or (($flag[0] % 2) -eq 0)) {
            New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name clabp `
                -PropertyType Binary -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -Force | Out-Null
            $f = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run').clabp
            $flagAfter = ($f | ForEach-Object { $_.ToString('X2') }) -join ' '
            if ($f -and $f[0] -eq 3) {
                $applied += 'clabp-flag'
                $detail += "[run] clabp : FIXED - StartupApproved flag $flagBefore -> $flagAfter (verified disabled)"
            } else {
                $failures += 'clabp-flag'
                $detail += "[run] clabp : FAIL - flag verify mismatch (expected 03..., got $flagAfter)"
            }
        } else {
            $detail += "[run] clabp : already disabled (flag $flagBefore)"
        }
    }
} catch {
    $failures += 'clabp'
    $detail += "[run] clabp : FAIL - exception: $($_.Exception.Message)"
}

$verdict = if ($failures.Count -gt 0) { 'PARTIAL-FAILURE' } elseif ($applied.Count -gt 0) { 'FIXED' } else { 'NO-CHANGES-NEEDED' }
Write-Output ("Result: {0} | applied={1} skipped={2} failed={3}" -f $verdict, $applied.Count, $skipped.Count, $failures.Count)
if ($applied.Count -gt 0) { Write-Output "  applied : $($applied -join ', ')" }
if ($skipped.Count -gt 0) { Write-Output "  skipped : $($skipped -join ', ') (see detail)" }
if ($failures.Count -gt 0) { Write-Output "  failed  : $($failures -join ', ') (see detail)" }
$detail | ForEach-Object { Write-Output "  $_" }
if ($failures.Count -gt 0) { exit 1 }
exit 0
