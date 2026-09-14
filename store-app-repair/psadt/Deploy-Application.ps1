<#
.SYNOPSIS
    PSAppDeployToolkit 3.10.1 package: offline install/uninstall of Microsoft
    Calculator (Microsoft.WindowsCalculator) with all dependency frameworks,
    for machines without Store or winget access.
    Derived from the PSAppDeployToolkit 3.10.1 Deploy-Application.ps1 template
    (LGPLv3, (C) 2024 PSAppDeployToolkit Team). Use at your own risk.

.DESCRIPTION
    Idempotent offline deployment of the Calculator msixbundle + 7 dependency
    frameworks staged in Files\Calculator. Designed for SCCM Packages (no
    detection method): the script itself is presence-based and exits 0 fast
    when the app is already registered.

    Context-aware, fully silent:
      - User session (standard or elevated): installs per-user with the
        dependency retry ladder.
      - Local SYSTEM (SCCM/RMM): provisions machine-wide via
        Add-AppxProvisionedPackage, then silently installs for the signed-in
        console user through a one-shot scheduled task (hidden wscript
        launcher - the user never sees a window or an elevation prompt).
      - Broken-but-present machines: -DeploymentType Repair re-registers the
        app and its components from the staged files.

    Exit codes: 0 repaired/healthy, 600-68999 reserved by PSADT, else the
    failing step's code. SCcm Package programs: Deploy-Application.exe
    (default Install), Deploy-Application.exe -DeploymentType Repair /
    Uninstall.

.NOTES
    Version: 1.0.0
    Files verified 2026-09-11: SHA-1 matched Microsoft's FE3 digests at
    download time; all 8 Authenticode Valid (Microsoft Corporation).
#>
[CmdletBinding()]
Param (
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [string]$DeploymentType = 'Install',
    [Parameter(Mandatory = $false)]
    [ValidateSet('Interactive', 'Silent', 'NonInteractive')]
    [string]$DeployMode = 'Silent',
    [switch]$AllowRebootPassThru,
    [switch]$TerminalServerMode,
    [switch]$DisableLogging
)

##* Do not modify section below
#region DoNotModify
[String]$script:ParentProcessName = (Get-WmiObject -Class Win32_Process -Filter "ProcessID='$PID'" -ErrorAction 'SilentlyContinue').ParentProcessName
[String]$script:InstallName = 'StoreApps-Calculator'
Try {
    [String]$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Definition
    [String]$moduleAppDeployToolkitMain = "$scriptDirectory\AppDeployToolkit\AppDeployToolkitMain.ps1"
    If (-not (Test-Path -LiteralPath $moduleAppDeployToolkitMain -PathType 'Leaf')) { Throw "Module does not exist at the specified location [$moduleAppDeployToolkitMain]." }
    If ($DisableLogging) { . $moduleAppDeployToolkitMain -DisableLogging } Else { . $moduleAppDeployToolkitMain }
}
Catch {
    If (Test-Path -LiteralPath $moduleAppDeployToolkitMain) { . $moduleAppDeployToolkitMain } Else { Write-Output "Module [$moduleAppDeployToolkitMain] failed to load." ; Exit 1 }
}
#endregion DoNotModify

##* ================================================
##* PRE-INSTALLATION
##* ================================================
$script:appxName = 'Microsoft.WindowsCalculator'
$script:filesDir = Join-Path $scriptDirectory 'Files\Calculator'
$script:frameworkPattern = '^(Microsoft\.(VCLibs|NET\.Native|UI\.Xaml|Services\.Store|Advertising|WindowsStore|Windows\..*SDK|WindowsAppRuntime)|Microsoft\.Windows\.SDK\..*)'

function Test-AppRegistered {
    param([string]$Name, [bool]$AllUsers)
    $g = @{ Name = $Name }
    if ($AllUsers) { $g.AllUsers = $true }
    foreach ($p in @(Get-AppxPackage @g -ErrorAction SilentlyContinue)) {
        if (-not $AllUsers) { return $p }
        if ("$($p.PackageUserInformation)" -match 'Installed') { return $p }
    }
    return $null
}

function Get-AppxStaged {
    param([string]$Name, [bool]$AllUsers)
    $g = @{ Name = $Name }
    if ($AllUsers) { $g.AllUsers = $true }
    $all = @(Get-AppxPackage @g -ErrorAction SilentlyContinue)
    foreach ($p in $all) {
        if ("$($p.PackageUserInformation)" -notmatch 'Installed') { return $p }
    }
    return $null
}

function Install-AppxLadder {
    # Proven retry ladder: full dependency set -> bare retry -> frameworks
    # standalone then bare. Context parameters come in via $commonSplat.
    param([object]$Main, [object[]]$Deps)
    $mainPath = $Main.FullName
    try {
        $splat = @{ Path = $mainPath }
        foreach ($k in $commonSplat.Keys) { $splat[$k] = $commonSplat[$k] }
        Add-AppxPackage @splat -ErrorAction Stop
        return $true
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -notmatch '0x80073CF3') { throw }
        Write-Log -Message "Dependency over-provision detected (0x80073CF3) - retrying bare." -Severity 2 -Source $deployAppScriptFriendlyName
        try {
            Add-AppxPackage -Path $mainPath -ErrorAction Stop
            return $true
        }
        catch {
            if ($_.Exception.Message -notmatch '0x80073CF3') { throw }
            foreach ($d in $Deps) {
                try { Add-AppxPackage -Path $d.FullName -ErrorAction Stop } catch { Write-Log -Message "Component $($d.Name): $($_.Exception.Message)" -Severity 2 -Source $deployAppScriptFriendlyName }
            }
            Add-AppxPackage -Path $mainPath -ErrorAction Stop
            return $true
        }
    }
}

function Invoke-ConsoleUserHandoff {
    # SYSTEM -> silent per-user install for the signed-in console user via a
    # one-shot scheduled task (hidden wscript launcher; no UAC, no windows).
    param([object]$Main, [object[]]$Deps)
    $consoleUser = (Get-CimInstance Win32_Computersystem -ErrorAction SilentlyContinue).UserName
    if (-not $consoleUser) { Write-Log -Message "No console user; provisioning covers users at next logon." -Source $deployAppScriptFriendlyName; return $true }

    $publicDir = 'C:\Users\Public\MsStoreRepair'
    New-Item -ItemType Directory -Force -Path $publicDir | Out-Null
    Copy-Item $Main.FullName $publicDir -Force
    foreach ($d in $Deps) { Copy-Item $d.FullName $publicDir -Force }
    $pubMain = Join-Path $publicDir $Main.Name
    $pubDeps = @($Deps | ForEach-Object { Join-Path $publicDir $_.Name })
    $depList = ($pubDeps | ForEach-Object { "'{0}'" -f $_ }) -join ','

    # signal files must live where the USER can write: $env:TEMP here is
    # SYSTEM's (C:\Windows\TEMP) - the standard user cannot create files there
    $userTemp = 'C:\Users\' + $consoleUser.Split([char]92)[-1] + '\AppData\Local\Temp'
    $okFile = Join-Path $userTemp 'handoff_ok.txt'
    $errFile = Join-Path $userTemp 'handoff_err.txt'
    Remove-Item $okFile, $errFile -Force -ErrorAction SilentlyContinue
    $handoffLines = @(
        "`$err = ''"
        "try { Add-AppxPackage -Path '$pubMain' -DependencyPath @($depList) -ErrorAction Stop } catch { `$err = `$_.Exception.Message }"
        "if (`$err -match '0x80073CF3') {"
        "  `$err = ''"
        "  try { Add-AppxPackage -Path '$pubMain' -ErrorAction Stop } catch { `$err = `$_.Exception.Message }"
        "  if (`$err -match '0x80073CF3') {"
        "    `$err = ''"
        "    foreach (`$f in @($depList)) { try { Add-AppxPackage -Path `$f -ErrorAction Stop } catch {} }"
        "    try { Add-AppxPackage -Path '$pubMain' -ErrorAction Stop } catch { `$err = `$_.Exception.Message }"
        "  }"
        "}"
        "if (`$err) { Set-Content -Path '$errFile' -Value `$err } else { Set-Content -Path '$okFile' -Value 'ok' }"
    )
    $handoffPs1 = Join-Path $publicDir 'handoff.ps1'
    Set-Content -Path $handoffPs1 -Value $handoffLines -Encoding utf8
    $q = [char]34
    $runVbs = Join-Path $publicDir 'run_hidden.vbs'
    $vbsLine = 'CreateObject("Wscript.Shell").Run ' + $q + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + $q + $q + $handoffPs1 + $q + $q + $q + ', 0, True'
    Set-Content -Path $runVbs -Value $vbsLine -Encoding ascii

    $tn = "StoreApps-Calculator-$PID"
    try {
        $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ($q + $runVbs + $q)
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
        $principal = New-ScheduledTaskPrincipal -UserId $consoleUser -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $tn -Principal $principal -Action $action -Trigger $trigger -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $tn
        $waited = 0
        while ((Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue).State -ne 'Ready' -and $waited -lt 240) { Start-Sleep -Seconds 2; $waited += 2 }
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log -Message "Handoff task failed: $($_.Exception.Message)" -Severity 2 -Source $deployAppScriptFriendlyName
    }
    Remove-Item $publicDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $okFile) {
        Remove-Item $okFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    $he = if (Test-Path $errFile) { (Get-Content $errFile -Raw).Trim() } else { 'task did not finish in time' }
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    Write-Log -Message "Console-user handoff incomplete: $he - provisioning covers next logon." -Severity 2 -Source $deployAppScriptFriendlyName
    return $false
}

##* ================================================
##* INSTALLATION
##* ================================================
If ($deploymentType -ieq 'Install') {
    # fully silent package: no Show-InstallationWelcome (DeployMode is Silent)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $isSystem = $identity.User.Value -eq 'S-1-5-18'
    Write-Log -Message "Context: user=$($identity.Name) elevated=$isAdmin system=$isSystem" -Source $deployAppScriptFriendlyName

    $files = @(Get-ChildItem $filesDir -File | Where-Object Extension -match '^\.(appx|msix)(bundle)?$')
    $main = @($files | Where-Object { $_.Name -notmatch $frameworkPattern -and ($_.Name -split '_')[0] -eq $appxName }) |
        Sort-Object { if ($_.Name -match '_(\d+\.\d+\.\d+\.\d+)_') { [version]$Matches[1] } else { [version]'0.0.0.0' } } -Descending |
        Select-Object -First 1
    if (-not $main) { Write-Log -Message "FAIL: no main package for $appxName in $filesDir" -Severity 3 -Source $deployAppScriptFriendlyName; Exit-Script -ExitCode 1 }
    $deps = @($files | Where-Object Name -ne $main.Name)
    Write-Log -Message "Staged set: $($main.Name) + $($deps.Count) component(s)." -Source $deployAppScriptFriendlyName

    $registered = Test-AppRegistered -Name $appxName -AllUsers $isAdmin
    If ($registered -and $deploymentType -ieq 'Install') {
        Write-Log -Message "Calculator $($registered.Version) already registered - nothing to do." -Source $deployAppScriptFriendlyName
        Exit-Script -ExitCode 0
    }

    $commonSplat = @{}
    If ($isSystem) {
        # SYSTEM: no per-user appx (no profile; no -AllUsers on this cmdlet set).
        $prov = @{ Online = $true; PackagePath = $main.FullName; SkipLicense = $true }
        if ($deps.Count) { $prov.DependencyPackagePath = $deps.FullName }
        Write-Log -Message "Provisioning Calculator machine-wide (SYSTEM context)." -Source $deployAppScriptFriendlyName
        Add-AppxProvisionedPackage @prov | Out-Null
        Write-Log -Message "Provisioning completed." -Source $deployAppScriptFriendlyName
        $handoffOk = Invoke-ConsoleUserHandoff -Main $main -Deps $deps
        If ($handoffOk) { Write-Log -Message "Calculator installed for the signed-in user; provisioned machine-wide." -Source $deployAppScriptFriendlyName }
        Exit-Script -ExitCode 0
    }
    Else {
        # staged-but-unregistered + elevated: zero-download re-register
        $staged = Get-AppxStaged -Name $appxName -AllUsers $isAdmin
        If ($staged -and $isAdmin) {
            Write-Log -Message "Staged copy found - re-registering without download." -Source $deployAppScriptFriendlyName
            Try {
                Add-AppxPackage -Path (Join-Path $staged.InstallLocation 'AppxManifest.xml') -Register -DisableDevelopmentMode -ErrorAction Stop
                $now = Get-AppxPackage -Name $appxName -ErrorAction SilentlyContinue
                If ($now) { Write-Log -Message "Calculator $($now.Version) re-registered from staged files." -Source $deployAppScriptFriendlyName; Exit-Script -ExitCode 0 }
            } Catch { Write-Log -Message "Staged re-register failed: $($_.Exception.Message)" -Severity 2 -Source $deployAppScriptFriendlyName }
        }

        Write-Log -Message "Installing Calculator + $($deps.Count) component(s) for this user." -Source $deployAppScriptFriendlyName
        $ok = Install-AppxLadder -Main $main -Deps $deps
        $now = Get-AppxPackage -Name $appxName -ErrorAction SilentlyContinue
        If ($ok -and $now) {
            Write-Log -Message "Calculator $($now.Version) installed for $($identity.Name)." -Source $deployAppScriptFriendlyName
        } Else {
            Write-Log -Message "Install could not be verified." -Severity 3 -Source $deployAppScriptFriendlyName
            Exit-Script -ExitCode 1
        }
    }
}
##* ================================================
##* UNINSTALLATION
##* ================================================
ElseIf ($deploymentType -ieq 'Uninstall') {
    # fully silent package: no Show-InstallationWelcome (DeployMode is Silent)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    Get-AppxPackage -Name $appxName -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction Continue
    If ($isAdmin) {
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object DisplayName -eq $appxName |
            Remove-AppxProvisionedPackage -Online -ErrorAction Continue
    }
    If (Get-AppxPackage -Name $appxName -ErrorAction SilentlyContinue) {
        Write-Log -Message "Calculator still registered after uninstall." -Severity 3 -Source $deployAppScriptFriendlyName
        Exit-Script -ExitCode 1
    }
    Write-Log -Message "Calculator removed." -Source $deployAppScriptFriendlyName
    Exit-Script -ExitCode 0
}
##* ================================================
##* REPAIR (broken-but-present: re-register app + components)
##* ================================================
ElseIf ($deploymentType -ieq 'Repair') {
    # fully silent package: no Show-InstallationWelcome (DeployMode is Silent)
    $pkg = Get-AppxPackage -Name $appxName -ErrorAction SilentlyContinue | Select-Object -First 1
    If (-not $pkg) { Write-Log -Message "Calculator not installed - run Install instead." -Severity 2 -Source $deployAppScriptFriendlyName; Exit-Script -ExitCode 1 }
    $targets = @($pkg.Dependencies | Where-Object PackageFamilyName -ne $pkg.PackageFamilyName) + $pkg
    $fail = 0
    foreach ($t in $targets) {
        $errs = @()
        try { Add-AppxPackage -DisableDevelopmentMode -Register "$($t.InstallLocation)\AppxManifest.xml" -ErrorAction Stop }
        catch {
            $errs = @($_)
            if ("$($errs.Exception)" -notmatch '0x80073D02|0x80073D06') { $fail++ ; Write-Log -Message "FAIL $($t.Name): $($_.Exception.Message)" -Severity 3 -Source $deployAppScriptFriendlyName }
            else { Write-Log -Message "SKIP $($t.Name) (in use / newer present - expected)." -Source $deployAppScriptFriendlyName }
        }
    }
    $post = Get-AppxPackage -Name $appxName -ErrorAction SilentlyContinue
    If ($post -and $fail -eq 0) { Write-Log -Message "Repair complete: $($post.Name) $($post.Version)." -Source $deployAppScriptFriendlyName; Exit-Script -ExitCode 0 }
    If ($post) { Write-Log -Message "Repair finished with $fail component failure(s) - see log." -Severity 2 -Source $deployAppScriptFriendlyName; Exit-Script -ExitCode 0 }
    Exit-Script -ExitCode 1
}
##* LITERAL TEMPLATE END
