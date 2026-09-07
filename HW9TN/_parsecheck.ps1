foreach ($f in 'install.ps1', 'Deploy-Application.ps1', 'detection_rule.ps1') {
    $p = Join-Path $PSScriptRoot $f
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e) | Out-Null
    if ($e) { "$f : $($e.Count) ERROR(S)"; $e | ForEach-Object { "  line $($_.Extent.StartLineNumber): $($_.Message)" } }
    else { "$f : PARSE-CLEAN" }
}
