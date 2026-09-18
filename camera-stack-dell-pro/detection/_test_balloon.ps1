# _test_balloon.ps1 - show what a balloon tip notification looks like
# This is the same visual as PSADT's Show-BalloonTip (uses the same .NET API)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Write-Output 'Showing balloon tip... look near the system tray (bottom-right).'

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$notifyIcon.Visible = $true
$notifyIcon.BalloonTipIcon = 'Info'
$notifyIcon.BalloonTipTitle = 'IT Support'
$notifyIcon.BalloonTipText = 'Camera driver installed. Please restart when convenient to finish.'
$notifyIcon.ShowBalloonTip(10000)

Write-Output 'Balloon tip shown. It will disappear after ~10 seconds.'
Write-Output 'The source shows as "IT Support" (the NotifyIcon title).'
Start-Sleep -Seconds 12
$notifyIcon.Dispose()
Write-Output 'Cleaned up.'
