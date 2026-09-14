<#
DETECTION: the Cirrus audio companion autostart entry (Run value "clabp") must be
flagged disabled via Windows' own StartupApproved mechanism.
Compliant     = no clabp entry (nothing to do), or entry flagged disabled (odd first byte).
Non-compliant = entry present and enabled (flag missing or even first byte).
Why flag, not delete: the vendor service that writes this entry re-creates a missing
value (its own run-once gate); the disable flag is honored by Explorer at logon and is
not re-enabled by the writer. Deleting the value is the one action the persistence
mechanism responds to.
Exit codes: 0 compliant, 1 remediate.
VM-validated end-to-end (detect -> remediate -> re-detect).
#>
$run = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).clabp
if (-not $run) { Write-Output 'N/A: no clabp Run entry'; exit 0 }
$flag = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -ErrorAction SilentlyContinue).clabp
if ($flag -and (($flag[0] % 2) -eq 1)) { Write-Output 'Compliant: clabp entry flagged disabled'; exit 0 }
Write-Output 'Non-compliant: clabp present, not flagged'; exit 1
