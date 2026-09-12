# Synthetic AppX objects shared by the test files. Dot-source from BeforeAll -
# Pester 5 does not carry discovery-time definitions into run-phase scopes.
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
