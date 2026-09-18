# _toast_elevated.job.ps1 - elevated test of toast via scheduled task
$toastScript = @'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$xml = @"
<toast scenario="reminder">
    <visual>
        <binding template="ToastGeneric">
            <text>Camera Driver Update (elevated test)</text>
            <text>This toast was shown via scheduled task from an elevated process.</text>
        </binding>
    </visual>
    <actions>
        <action content="OK" arguments="dismiss" activationType="system"/>
    </actions>
</toast>
"@
$doc = New-Object Windows.Data.Xml.Dom.XmlDocument
$doc.LoadXml($xml)
$toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
'@

$toastScriptPath = "$env:ProgramData\camera_toast_test.ps1"
$toastScript | Set-Content $toastScriptPath -Encoding UTF8

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$toastScriptPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(2)
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited

$taskName = 'CameraDriverToast_Elevated'
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
Write-Output "Task registered: $taskName"
Start-ScheduledTask -TaskName $taskName
Write-Output 'Task fired.'

Start-Sleep -Seconds 8

$info = Get-ScheduledTaskInfo -TaskName $taskName
Write-Output "LastRunTime: $($info.LastRunTime)"
Write-Output "LastTaskResult: $($info.LastTaskResult) (0 = success)"

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item $toastScriptPath -Force -ErrorAction SilentlyContinue
Write-Output 'Cleaned up. Look for the toast notification.'
