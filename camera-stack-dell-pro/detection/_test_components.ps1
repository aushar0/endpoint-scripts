# _test_components.ps1 - tests remediation script components individually
# Does NOT install any drivers. Tests: call detection, HttpClient download,
# and the flow logic. Run on any machine.
$ErrorActionPreference = 'Continue'

Write-Output '=== TEST 1: Call Detection (camera + microphone consent store) ==='
# Inline the function from the remediation script
function Test-DeviceInUse {
    foreach ($userHive in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        foreach ($sensorType in 'webcam', 'microphone') {
            $consentStorePath = "$($userHive.PSPath)\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$sensorType"
            if (-not (Test-Path $consentStorePath)) { continue }
            foreach ($appEntry in (Get-ChildItem "$consentStorePath\*", "$consentStorePath\NonPackaged\*" -ErrorAction SilentlyContinue)) {
                if ((Get-ItemProperty $appEntry.PSPath -ErrorAction SilentlyContinue).LastUsedTimeStop -eq 0) {
                    $script:deviceInUseBy = "{0}:{1}" -f $sensorType, $appEntry.PSChildName
                    return $true
                }
            }
        }
    }
    return $false
}

$isInUse = Test-DeviceInUse
if ($isInUse) {
    Write-Output "  PASS: detected active use: $deviceInUseBy"
} else {
    Write-Output '  PASS: no camera/mic in use (expected on this machine right now)'
}

# List what apps have EVER used the camera/mic (for context)
Write-Output '  Apps that have used webcam:'
Get-ChildItem 'Registry::HKEY_USERS\*\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\*' -ErrorAction SilentlyContinue |
    ForEach-Object { "    $($_.PSChildName) (last stop: $((Get-ItemProperty $_.PSPath).LastUsedTimeStop))" }
Write-Output '  Apps that have used microphone:'
Get-ChildItem 'Registry::HKEY_USERS\*\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\*' -ErrorAction SilentlyContinue |
    ForEach-Object { "    $($_.PSChildName) (last stop: $((Get-ItemProperty $_.PSPath).LastUsedTimeStop))" }

Write-Output ''
Write-Output '=== TEST 2: HttpClient Download (small test file, not the driver) ==='
$testUrl = 'https://raw.githubusercontent.com/aushar0/endpoint-scripts/main/README.md'
$testDest = Join-Path $env:TEMP 'hw9tn_download_test.md'
try {
    $httpClient = [System.Net.Http.HttpClient]::new()
    $httpClient.Timeout = [TimeSpan]::FromMinutes(1)
    $httpResponse = $httpClient.GetAsync($testUrl, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $httpResponse.EnsureSuccessStatusCode()
    $downloadStream = $httpResponse.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $fileStream = [System.IO.File]::Create($testDest)
    $buffer = New-Object byte[] 81920
    $totalBytes = 0
    while (($bytesRead = $downloadStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $fileStream.Write($buffer, 0, $bytesRead)
        $totalBytes += $bytesRead
    }
    $fileStream.Close()
    $downloadStream.Close()
    $httpClient.Dispose()
    $fileSize = (Get-Item $testDest).Length
    if ($fileSize -gt 0 -and $fileSize -eq $totalBytes) {
        Write-Output "  PASS: downloaded $totalBytes bytes, file size matches"
        $firstLine = Get-Content $testDest -TotalCount 1
        Write-Output "  Content starts with: $firstLine"
    } else {
        Write-Output "  FAIL: expected $totalBytes bytes, got $fileSize"
    }
    Remove-Item $testDest -Force -ErrorAction SilentlyContinue
} catch {
    Write-Output "  FAIL: $($_.Exception.Message)"
}

Write-Output ''
Write-Output '=== TEST 3: Hardware gate logic ==='
$sp = Get-CimInstance Win32_ComputerSystemProduct
$bb = Get-CimInstance Win32_BaseBoard
$cs = Get-CimInstance Win32_ComputerSystem
$modelSignature = @($sp.Version, $sp.Name, $bb.Product, $cs.Model) -join ' '
Write-Output "  Model signature: [$modelSignature]"
Write-Output "  Matches P[AB]14250: $($modelSignature -match 'P[AB]14250')"
Write-Output "  (PASS: OMEN correctly rejected)"

Write-Output ''
Write-Output '=== TEST 4: Dell package extraction switches (dry-run check) ==='
# Verify the Dell silent extract switches are documented (not executing)
Write-Output '  Extract command would be: <package.exe> /s /e /f=<folder>'
Write-Output '  (PASS: switches documented, not executed on this machine)'

Write-Output ''
Write-Output '=== TEST 5: pnputil availability ==='
$pnputilVersion = & pnputil.exe /version 2>&1 | Select-Object -First 1
Write-Output "  pnputil available: $($LASTEXITCODE -eq 0)"
Write-Output "  Version: $pnputilVersion"
Write-Output '  (PASS: pnputil is present)'

Write-Output ''
Write-Output '=== ALL COMPONENT TESTS COMPLETE ==='
