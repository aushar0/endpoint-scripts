<#
REMEDIATION: disable the "clabp" HKLM Run entry via StartupApproved (REG_BINARY,
12 bytes, first byte 03 = disabled, 02 = enabled; odd = disabled, even = enabled).
The value itself is left in place on purpose: the writer service only checks the
value's existence, so a present-but-disabled entry keeps the persistence gate
closed while Explorer skips the launch at logon. Fully reversible (flip to 02).
Exit codes: 0 flag written and verified, 1 verify failed.
#>
New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name clabp -PropertyType Binary -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -Force | Out-Null
$f = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run').clabp
if ($f -and $f[0] -eq 3) { Write-Output 'clabp flag set (disabled), verified'; exit 0 }
Write-Output 'flag verify failed'; exit 1
