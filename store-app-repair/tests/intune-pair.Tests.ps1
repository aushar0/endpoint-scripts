# Tests for detection.ps1 / remediation.ps1 (Pester 5+).
# The health-check logic is exercised via synthetic packages: a real broken
# app is hard to stage (the OS guards framework removal), so the detection
# classes are covered with mocks of the AppX cmdlets.

Describe 'Test-AppxHealth (synthetic packages)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'fakes.ps1')
        . (Join-Path $PSScriptRoot '..\detection.ps1')
    }

    It 'healthy app with present, sufficient component: no issues' {
        Mock Get-AppxPackage {
            if ($null -eq $Name -or $Name -eq 'App.A') {
                @((New-FakePkg 'App.A' 'A_1' '1.0.0.0'), (New-FakePkg 'Comp.X' 'X_1' '2.0.0.0' -IsFramework $true))
            } else {
                @((New-FakePkg 'Comp.X' 'X_1' '2.0.0.0' -IsFramework $true))
            }
        }
        Mock Get-AppxPackageManifest { New-FakeManifest -DepName 'Comp.X' -MinVersion '2.0.0.0' }
        $issues = Test-AppxHealth
        @($issues).Count | Should -Be 0
    }

    It 'unhealthy Status is flagged' {
        Mock Get-AppxPackage { @((New-FakePkg 'App.B' 'B_1' '1.0.0.0' -Status 'Modified')) }
        Mock Get-AppxPackageManifest { New-FakeManifest }
        $issues = Test-AppxHealth
        @($issues).Count | Should -Be 1
        $issues[0].Kind | Should -Be 'status'
    }

    It 'missing component is flagged with the component name' {
        Mock Get-AppxPackage {
            if ($Name -eq 'Comp.X') { @() }
            else { @((New-FakePkg 'App.C' 'C_1' '1.0.0.0')) }
        }
        Mock Get-AppxPackageManifest { New-FakeManifest -DepName 'Comp.X' -MinVersion '2.0.0.0' }
        $issues = Test-AppxHealth
        @($issues).Count | Should -Be 1
        $issues[0].Kind | Should -Be 'missing_component'
        $issues[0].Detail | Should -Match 'Comp\.X'
    }

    It 'component below manifest minimum is flagged' {
        Mock Get-AppxPackage {
            if ($Name -eq 'Comp.X') { @((New-FakePkg 'Comp.X' 'X_1' '1.5.0.0' -IsFramework $true)) }
            else { @((New-FakePkg 'App.D' 'D_1' '1.0.0.0')) }
        }
        Mock Get-AppxPackageManifest { New-FakeManifest -DepName 'Comp.X' -MinVersion '2.0.0.0' }
        $issues = Test-AppxHealth
        @($issues).Count | Should -Be 1
        $issues[0].Kind | Should -Be 'component_too_old'
    }

    It 'frameworks are not flagged directly (app-centric view)' {
        Mock Get-AppxPackage { @((New-FakePkg 'Comp.X' 'X_1' '1.0.0.0' -Status 'Modified' -IsFramework $true)) }
        Mock Get-AppxPackageManifest { New-FakeManifest }
        $issues = Test-AppxHealth
        @($issues).Count | Should -Be 0
    }

    It 'unreadable manifest is flagged, not swallowed' {
        Mock Get-AppxPackage { @((New-FakePkg 'App.E' 'E_1' '1.0.0.0')) }
        Mock Get-AppxPackageManifest { throw 'manifest corrupt' }
        $issues = Test-AppxHealth
        @($issues).Count | Should -Be 1
        $issues[0].Kind | Should -Be 'manifest_unreadable'
    }

    It 'FamilyName filter restricts the scan' {
        Mock Get-AppxPackage { @((New-FakePkg 'App.F' 'F_1' '1.0.0.0' -Status 'Modified'), (New-FakePkg 'App.G' 'G_1' '1.0.0.0' -Status 'Modified')) }
        Mock Get-AppxPackageManifest { New-FakeManifest }
        $issues = Test-AppxHealth -FamilyName 'G_1'
        @($issues).Count | Should -Be 1
        $issues[0].App | Should -Be 'App.G'
    }

    It 'named family that is not registered is flagged missing' {
        Mock Get-AppxPackage { @((New-FakePkg 'App.H' 'H_1' '1.0.0.0')) }
        Mock Get-AppxPackageManifest { New-FakeManifest }
        $issues = @(Test-AppxHealth -FamilyName 'Never.Installed_8wekyb3d8bbwe')
        $missing = @($issues | Where-Object Kind -eq 'missing')
        $missing.Count | Should -Be 1
        $missing[0].Detail | Should -Match 'without a download'
    }
}

Describe 'Failure taxonomy and infrastructure gates' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'fakes.ps1')
        . (Join-Path $PSScriptRoot '..\detection.ps1')
    }

    It 'diagnoses in-use as specific cause' {
        $msg = 'Deployment failed with HRESULT: 0x80073D02, resources in use'
        Get-FailureDiagnosis ([pscustomobject]@{ ToString = $msg }) | Should -Match 'in use'
    }

    It 'diagnoses name-resolution failure as endpoint-blocked' {
        $msg = 'WinHttpSendRequest: 12007. The server name or address could not be resolved'
        Get-FailureDiagnosis ([pscustomobject]@{ ToString = $msg }) | Should -Match 'name resolution'
    }

    It 'diagnoses access-denied as ACL or security software' {
        $msg = 'Access is denied. (Exception from HRESULT: 0x80070005)'
        Get-FailureDiagnosis ([pscustomobject]@{ ToString = $msg }) | Should -Match 'access denied'
    }

    It 'unknown failures keep their full text with HRESULT' {
        $msg = 'Weird failure 0x8A15002B occurred'
        $d = Get-FailureDiagnosis ([pscustomobject]@{ ToString = $msg })
        $d | Should -Match '0x8A15002B'
        $d | Should -Match 'Weird failure'
    }

    It 'preflight fails specifically when AppXSvc is Disabled by policy' {
        Mock Get-Service { [pscustomobject]@{ Name = 'AppXSvc'; Status = 'Stopped'; StartType = 'Disabled' } }
        Mock Get-CimInstance { [pscustomobject]@{ Caption = 'Windows 11'; BuildNumber = '26200' } }
        Write-Preflight | Should -Be $false
    }

    It 'preflight passes when AppXSvc is trigger-started Stopped (healthy resting state)' {
        Mock Get-Service { [pscustomobject]@{ Name = 'AppXSvc'; Status = 'Stopped'; StartType = 'Automatic' } }
        Mock Get-CimInstance { [pscustomobject]@{ Caption = 'Windows 11'; BuildNumber = '26200' } }
        Write-Preflight | Should -Be $true
    }
}

Describe 'Dot-source safety' {
    It 'detection.ps1 dot-sources without running the scan (remediation dependency)' {
        { . (Join-Path $PSScriptRoot '..\detection.ps1') } | Should -Not -Throw
    }
}
