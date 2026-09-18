<#
.SYNOPSIS
    Portable detection for the Orb SENSOR service - one script for SCCM
    Deployment-Type detection method AND Intune Win32 custom detection.
    Run context: SYSTEM on both platforms (services are not registry-
    redirected, so both script hosts see the same SCM).
.DESCRIPTION
    Contract (packaging skill references/detection.md):
      detected = exit 0 AND non-empty stdout.
      absent   = exit 0, SILENT. Never exit 1 (SCCM reads nonzero as
      Unknown; Intune as not-installed -> 24h reinstall loop for Required).
      Never stderr, never Write-Host.
    CLM-proof: no [version] casts, no non-primitive .NET types.

    Anchor: SCM service named 'Orb' whose binaryPath is the windowsservice
    flavor. Presence-anchored, DELIBERATELY NOT state-gated (a stopped
    service is still installed; gating on Running causes reinstall waves -
    house doctrine). The desktop-app flavor creates NO service, so this
    detection is collision-free from that side.

    Version floor NOT implemented (v1): the sensor binary carries no
    FileVersion and its version CLI ('Orb.exe version' -> 'v1.5.5') is not
    safe to invoke from a detection pass (spawns the service binary).
    Existence-only on rollout 1 per doctrine; add a floor via a Remediations
    script that runs the version CLI with a timeout if a ceiling is ever
    needed.
#>
[CmdletBinding()]
Param ()

$svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='Orb'" -ErrorAction SilentlyContinue

if (-not $svc) { exit 0 }
if ($svc.PathName -notlike '*Orb.exe*windowsservice*') { exit 0 }

Write-Output "Orb Sensor (service present)"
exit 0
