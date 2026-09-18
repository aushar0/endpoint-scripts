# _test_toast_user.ps1 - test toast notification from current user context
# Uses PowerShell's built-in AUMID (no custom registration needed)
# If you see a notification pop up, this method works.

Write-Output 'Attempting toast notification from user context...'
Write-Output 'Look for a notification in the bottom-right corner.'

try {
    # Load the WinRT types
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    # Use PowerShell's built-in AUMID (the Start Menu shortcut)
    # This is already registered and works for showing toasts
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

    $toastXml = @"
<toast scenario="reminder">
    <visual>
        <binding template="ToastGeneric">
            <text>Camera Driver Update</text>
            <text>Your camera driver has been installed. Please restart when convenient to finish.</text>
        </binding>
    </visual>
    <actions>
        <action content="OK" arguments="dismiss" activationType="system"/>
    </actions>
</toast>
"@

    $xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xmlDoc.LoadXml($toastXml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xmlDoc)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    Write-Output 'Toast sent. Check your screen.'
} catch {
    Write-Output "FAILED: $($_.Exception.Message)"
}
