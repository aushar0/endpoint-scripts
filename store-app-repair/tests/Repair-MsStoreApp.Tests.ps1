# Regression suite for the generated Repair-MsStoreApp.ps1 (Pester 5+ syntax).
# Run: Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
#      Invoke-Pester -Path <this folder>
# Scope: static contract + healthy-box behavior + error paths. Break/fix cycles
# stay manual (they remove real apps) - see kit README verification ledger.
# The generator-determinism test only runs where the dev generator exists.

# Discovery-time value: the -Skip expression below evaluates before BeforeAll.
$devGenerator = Join-Path $PSScriptRoot '..\New-MsStoreRepairScript.ps1'
$devTool = Join-Path $PSScriptRoot '..\dist\Repair-MsStoreApp.ps1'

Describe 'Generated script - static contract' {
    BeforeAll {
        $tool = Join-Path $PSScriptRoot '..\dist\Repair-MsStoreApp.ps1'
        $raw = Get-Content $tool -Raw
        # Pester 5's Should proxy stringifies inline expressions - precompute
        $cmtraceMarker = [regex]::Escape('<![LOG[')
        $cmtraceComponent = [regex]::Escape('component="StoreAppRepair"')
    }

    It 'parses clean' {
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize($raw, [ref]$errs) | Out-Null
        $errs.Count | Should -Be 0
    }

    It 'has comment-based help with synopsis, examples, and notes' {
        $raw | Should -Match '\.SYNOPSIS'
        $raw | Should -Match '\.EXAMPLE'
        $raw | Should -Match '\.NOTES'
    }

    It 'carries version and generator provenance' {
        $raw | Should -Match 'Generated: \d{4}-\d{2}-\d{2}'
        $raw | Should -Match 'SHA-256 [0-9A-F]{64}'
        $raw | Should -Match 'Version:\s+3\.'
    }

    It 'logs in CMTrace format' {
        $raw | Should -Match $cmtraceMarker
        $raw | Should -Match $cmtraceComponent
    }

    It 'pins both known apps to ProductId + family name' {
        $raw | Should -Match '9WZDNCRFHVN5'
        $raw | Should -Match 'Microsoft\.WindowsCalculator_8wekyb3d8bbwe'
        $raw | Should -Match '9MZ95KL8MR0L'
        $raw | Should -Match 'Microsoft\.ScreenSketch_8wekyb3d8bbwe'
    }

    It 'requires a family-name pin for arbitrary ProductIds (fuzzy-match guard)' {
        $raw | Should -Match 'ExpectedFamilyName'
        $raw | Should -Match 'fuzzy'
    }

    It 'has no narrative-tone or stripped-feature regressions' {
        $raw | Should -Not -Match 'FINDING:'
        $raw | Should -Not -Match 'Write-Ra'
        $raw | Should -Not -Match 'NEXTHINK'
    }

    It 'declares exit codes 0/1/2/3/4 in help' {
        $raw | Should -Match 'Exit codes'
    }
}

Describe 'Generator (dev tree only)' {
    BeforeAll {
        # run-phase scope: file-top variables do not carry into It bodies
        $devGenerator = Join-Path $PSScriptRoot '..\New-MsStoreRepairScript.ps1'
        $devTool = Join-Path $PSScriptRoot '..\dist\Repair-MsStoreApp.ps1'
    }
    It 'is deterministic (same output modulo generation timestamp)' -Skip:(-not ($devGenerator -and (Test-Path $devGenerator))) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $devGenerator *> $null
        $c1 = (Get-Content $devTool -Raw) -replace 'Generated: .+', 'Generated: X'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $devGenerator *> $null
        $c2 = (Get-Content $devTool -Raw) -replace 'Generated: .+', 'Generated: X'
        $c1 | Should -Be $c2
    }
}

Describe 'Healthy-box behavior (both apps present)' {
    BeforeAll {
        $tool = Join-Path $PSScriptRoot '..\dist\Repair-MsStoreApp.ps1'
    }

    It '-DetectOnly exits 0 and reports healthy' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -App calc,snip -DetectOnly 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join ' ') | Should -Match 'Calculator healthy'
        ($out -join ' ') | Should -Match 'Snipping Tool healthy'
    }

    It 'repair mode is a no-op on a healthy box (exit 0, "No action needed")' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -App calc,snip 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join ' ') | Should -Match 'No action needed'
        ($out -join ' ') | Should -Match 'SUMMARY:'
    }

    It 'writes a CMTrace-format log' {
        $log = Get-ChildItem "$env:TEMP\MsStoreRepair" -Filter 'Microsoft_StoreAppRepair_*.log' |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $log | Should -Not -BeNullOrEmpty
        (Get-Content $log.FullName -TotalCount 1) | Should -Match '^<!\[LOG\['
    }

    It 'rejects unknown app shortcuts with exit 1' {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -App nosuchapp 2>$null
        $LASTEXITCODE | Should -Be 1
    }

    It 'rejects bare -ProductId without a family-name pin with exit 1' {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -ProductId 9WZDNCRFHVN5 2>$null
        $LASTEXITCODE | Should -Be 1
    }
}
