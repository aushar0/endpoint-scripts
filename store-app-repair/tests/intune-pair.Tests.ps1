# Tests for detection.ps1 / remediation.ps1 (Pester 5+).
# The health-check logic is exercised via synthetic packages: a real broken
# app is hard to stage (the OS guards framework removal), so the detection
# classes are covered with mocks of the AppX cmdlets.

Describe 'Test-AppxHealth (synthetic packages)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\detection.ps1')

        function New-FakePkg {
            param($Name, $Pfn, $Version, $Status = 'Ok', $IsFramework = $false, $Dependencies = @())
            [pscustomobject]@{
                Name = $Name; PackageFamilyName = $Pfn; Version = $Version; Status = $Status
                IsFramework = $IsFramework; Dependencies = $Dependencies
                InstallLocation = 'C:\Fake\Location'
            }
        }
        function New-FakeManifest {
            param([string]$DepName, [string]$MinVersion)
            $dep = @()
            if ($DepName) {
                $dep = @([pscustomobject]@{ Name = $DepName; MinVersion = $MinVersion })
            }
            [pscustomobject]@{ Package = [pscustomobject]@{ Dependencies = [pscustomobject]@{ PackageDependency = $dep } } }
        }
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
        Mock Get-AppxPackage {
            @((New-FakePkg 'App.B' 'B_1' '1.0.0.0' -Status 'Modified'))
        }
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
        Mock Get-AppxPackage {
            @((New-FakePkg 'Comp.X' 'X_1' '1.0.0.0' -Status 'Modified' -IsFramework $true))
        }
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
        Mock Get-AppxPackage {
            @((New-FakePkg 'App.F' 'F_1' '1.0.0.0' -Status 'Modified'), (New-FakePkg 'App.G' 'G_1' '1.0.0.0' -Status 'Modified'))
        }
        Mock Get-AppxPackageManifest { New-FakeManifest }
        $issues = Test-AppxHealth -FamilyName 'G_1'
        @($issues).Count | Should -Be 1
        $issues[0].App | Should -Be 'App.G'
    }
}

Describe 'Dot-source safety' {
    It 'detection.ps1 dot-sources without running the scan (remediation dependency)' {
        { . (Join-Path $PSScriptRoot '..\detection.ps1') } | Should -Not -Throw
    }
}
