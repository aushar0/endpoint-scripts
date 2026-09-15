# Install-SignContextMenu.ps1 — registers a per-user "Sign with code-signing cert"
# context-menu verb for .ps1 files. No admin needed (HKCU\Software\Classes).
# Usage:  powershell -File .\Install-SignContextMenu.ps1            (install)
#         powershell -File .\Install-SignContextMenu.ps1 -Uninstall (remove)
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$worker = Join-Path $PSScriptRoot 'Invoke-SignPs1.ps1'
$verbName = 'SignPS1'
$verbText = 'Sign with code-signing cert'
$command = '"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "{0}" "%1"' -f $worker

# Effective ProgID for .ps1: UserChoice override wins if the user re-associated the extension.
$progIds = @('Microsoft.PowerShellScript.1')
try {
    $userChoice = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.ps1\UserChoice' -ErrorAction Stop).ProgId
    if ($userChoice) {
        if ($progIds -notcontains $userChoice) { $progIds += $userChoice }
        Write-Output "Effective .ps1 ProgID (UserChoice): $userChoice - verb registered there too"
    }
} catch { Write-Output 'No UserChoice override for .ps1 - using base ProgID only' }

# SystemFileAssociations applies to the extension itself — survives UserChoice re-association
# and works even when .ps1 is associated to a Store (AppX) app, which ignores classic Shell verbs.
$regTargets = @()
foreach ($progId in $progIds) { $regTargets += "Classes\$progId\Shell" }
$regTargets += 'Classes\SystemFileAssociations\.ps1\Shell'

foreach ($shellPath in $regTargets) {
    $verbKey = "HKCU:\Software\$shellPath\$verbName"
    $cmdKey  = "$verbKey\command"
    if ($Uninstall) {
        Remove-Item $verbKey -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "Removed verb at $verbKey"
        continue
    }
    New-Item -Path $cmdKey -Force | Out-Null
    Set-ItemProperty -Path $verbKey -Name '(Default)' -Value $verbText
    Set-ItemProperty -Path $verbKey -Name 'Icon' -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    Set-ItemProperty -Path $cmdKey -Name '(Default)' -Value $command
    Write-Output "Registered '$verbText' at HKCU:\Software\$shellPath\$verbName"
}

if (-not $Uninstall) {
    if (-not (Test-Path $worker)) { Write-Warning "Worker script missing: $worker" }
    Write-Output ''
    Write-Output 'Note: Windows 11 hides custom verbs under "Show more options" (Shift+F10).'
    Write-Output 'Multi-select: each selected .ps1 gets its own signing window (invoked per file).'
}
