# Regression suite for the generated Repair-MsStoreApp.ps1 (Pester 3.4 syntax).
# Run: powershell -File (Invoke-Pester ...) or via tests/run_tests.ps1
# Scope: static contract + healthy-box behavior. Break/fix cycles stay manual
# (they remove apps) - see kit README verification ledger.

# Paths resolve relative to this file so the suite runs on any clone.
$script:tool  = Join-Path $PSScriptRoot '..\Repair-MsStoreApp.ps1'
$script:raw   = Get-Content $script:tool -Raw

Describe 'Generated script - static contract' {

    It 'parses clean' {
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize($script:raw, [ref]$errs) | Out-Null
        $errs.Count | Should Be 0
    }

    It 'has comment-based help with synopsis, examples, and notes' {
        $script:raw | Should Match '\.SYNOPSIS'
        $script:raw | Should Match '\.EXAMPLE'
        $script:raw | Should Match '\.NOTES'
    }

    It 'carries version and generator provenance' {
        $script:raw | Should Match 'Generated: \d{4}-\d{2}-\d{2}'
        $script:raw | Should Match 'SHA-256 [0-9A-F]{64}'
        $script:raw | Should Match 'Version:\s+3\.'
    }

    It 'logs in CMTrace format' {
        $marker = [regex]::Escape('<![LOG[')
        $component = [regex]::Escape('component="StoreAppRepair"')
        $script:raw | Should Match $marker
        $script:raw | Should Match $component
    }

    It 'pins both known apps to ProductId + family name' {
        $script:raw | Should Match "9WZDNCRFHVN5"
        $script:raw | Should Match 'Microsoft\.WindowsCalculator_8wekyb3d8bbwe'
        $script:raw | Should Match "9MZ95KL8MR0L"
        $script:raw | Should Match 'Microsoft\.ScreenSketch_8wekyb3d8bbwe'
    }

    It 'requires a family-name pin for arbitrary ProductIds (fuzzy-match guard)' {
        $script:raw | Should Match 'ExpectedFamilyName'
        $script:raw | Should Match 'fuzzy'
    }

    It 'has no narrative-tone or stripped-feature regressions' {
        $script:raw | Should Not Match 'FINDING:'
        $script:raw | Should Not Match 'Write-Ra'
        $script:raw | Should Not Match 'NEXTHINK'
        $script:raw | Should Not Match 'plain.English'
    }

    It 'declares exit codes 0/1/2/3/4 in help' {
        $script:raw | Should Match 'Exit codes'
    }
}

Describe 'Healthy-box behavior (both apps present)' {

    It '-DetectOnly exits 0 and reports healthy' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:tool -App calc,snip -DetectOnly 2>&1
        $LASTEXITCODE | Should Be 0
        ($out -join ' ') | Should Match 'Calculator healthy'
        ($out -join ' ') | Should Match 'Snipping Tool healthy'
    }

    It 'repair mode is a no-op on a healthy box (exit 0, "No action needed")' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:tool -App calc,snip 2>&1
        $LASTEXITCODE | Should Be 0
        ($out -join ' ') | Should Match 'No action needed'
        ($out -join ' ') | Should Match 'SUMMARY:'
    }

    It 'writes a CMTrace-format log' {
        $log = Get-ChildItem "$env:TEMP\MsStoreRepair" -Filter 'Microsoft_StoreAppRepair_*.log' |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $log | Should Not BeNullOrEmpty
        $first = (Get-Content $log.FullName -TotalCount 1)
        $first | Should Match '^<!\[LOG\['
        $first | Should Match 'type="1"'
    }

    It 'rejects unknown app shortcuts with exit 1' {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:tool -App nosuchapp 2>$null
        $LASTEXITCODE | Should Be 1
    }

    It 'rejects bare -ProductId without a family-name pin with exit 1' {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:tool -ProductId 9WZDNCRFHVN5 2>$null
        $LASTEXITCODE | Should Be 1
    }
}
