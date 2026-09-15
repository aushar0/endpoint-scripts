# Invoke-SignPs1.ps1 — worker behind the "Sign with code-signing cert" context-menu verb.
# Cleans up + parameterizes the org's signing recipe:
#   cert from Cert:\CurrentUser\My filtered by Subject channel keyword ('release' default, 'preview' alt),
#   full chain + DigiCert RFC3161 timestamp, then verify.
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [string]$Channel = 'release',
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

function Find-SigningCert {
    $all = @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return $null }
    $match = @($all | Where-Object { $_.Subject -match $Channel })
    if ($match.Count -eq 1) { return $match[0] }
    if ($match.Count -gt 1) {
        Write-Host "Ambiguous certs matching channel '$Channel':" -ForegroundColor Yellow
        $match | ForEach-Object { Write-Host "  $($_.Subject) ($($_.Thumbprint))" }
        return $null
    }
    # No channel match: if exactly one code-signing cert exists overall, use it.
    if ($all.Count -eq 1) { return $all[0] }
    Write-Host "Multiple code-signing certs but none match channel '$Channel':" -ForegroundColor Yellow
    $all | ForEach-Object { Write-Host "  $($_.Subject) ($($_.Thumbprint))" }
    return $null
}

try {
    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }

    $cert = Find-SigningCert
    if (-not $cert) { throw "No usable code-signing cert in CurrentUser\My (channel '$Channel'). Import the cert first." }

    $existing = Get-AuthenticodeSignature -FilePath $Path
    if ($existing.Status -eq 'Valid') {
        Write-Host "Already signed by $($existing.SignerCertificate.Subject) - re-signing (overwrites signature block)." -ForegroundColor DarkYellow
    }

    $sig = Set-AuthenticodeSignature -FilePath $Path -Certificate $cert `
        -IncludeChain All -TimestampServer 'http://timestamp.digicert.com'

    if ($sig.Status -eq 'Valid') {
        Write-Host "SIGNED: $Path" -ForegroundColor Green
        Write-Host "  Signer : $($sig.SignerCertificate.Subject)"
        Write-Host "  Time   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    } else {
        throw "Signature status $($sig.Status): $($sig.StatusMessage)"
    }
} catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if (-not $NoPause -and $Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
}
