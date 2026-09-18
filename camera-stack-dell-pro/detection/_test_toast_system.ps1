# _test_toast_system.ps1 - test toast from SYSTEM context via scheduled task
# This simulates what Intune Remediations / Nexthink would do:
# SYSTEM process → scheduled task (as user) → PowerShell → toast

# Step 1: Write a small toast script to a temp location the user can access
$toastScript = @'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$xml = @"
<toast scenario="reminder">
    <visual>
        <binding template="ToastGeneric">
            <text>Camera Driver Update (SYSTEM test)</text>
            <text>This toast was triggered from SYSTEM context via scheduled task.</text>
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

$toastScriptPath = "$env:TEMP\camera_toast_notification.ps1"
$toastScript | Set-Content $toastScriptPath -Encoding UTF8

Write-Output "Toast script written to: $toastScriptPath"

# Step 2: Create a scheduled task that runs as the logged-in user (not SYSTEM)
# The -GroupId 'S-1-5-32-545' means "Users group" which includes the interactive user
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$toastScriptPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(2)
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited

# Step 3: Register and fire
$taskName = 'CameraDriverToast_Test'
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
Write-Output "Scheduled task '$taskName' registered. Firing..."

Start-ScheduledTask -TaskName $taskName
Write-Output 'Task fired. Waiting for toast to display...'

Start-Sleep -Seconds 8

# Step 4: Check if the task actually ran
$taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
Write-Output "Task last run time: $($taskInfo.LastRunTime)"
Write-Output "Task last run result: $($taskInfo.LastTaskResult)"
Write-Output "Task state: $((Get-ScheduledTask -TaskName $taskName).State)"

# Step 5: Clean up
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item $toastScriptPath -Force -ErrorAction SilentlyContinue
Write-Output 'Task cleaned up.'
Write-Output ''
Write-Output 'Did you see the second toast? (It says "SYSTEM test")'
