# Orb desktop app — PSADT 3.10.1 package

![PowerShell](https://img.shields.io/badge/PowerShell-5.1-blue) ![PSADT](https://img.shields.io/badge/PSAppDeployToolkit-3.10.1-purple) ![tested](https://img.shields.io/badge/lab--tested-install%2Frepair%2Funinstall%2FSYSTEM-brightgreen)

Purpose: deploy the **Orb desktop app** (orb.net network-experience client)
per-machine and silently via SCCM/Intune, with vendor-verified switches,
payload hash-pinning, ground-truth post-conditions, and a detection script
that works identically on both platforms.

**Companion kit: [`orb-sensor-package/`](../orb-sensor-package/)** — the
headless service flavor of the same product. The two flavors share
`C:\Program Files\Orb\Orb.exe`, so each package REFUSES to install on top
of the other (exit 60012, live-tested both directions). Deploy them to
disjoint device collections.

## Contents

| File | Role |
|---|---|
| `Deploy-Application.ps1` | PSADT 3.10.1 wrapper (install / repair / uninstall) |
| `detection.ps1` | One detection script for SCCM Deployment-Type + Intune Win32 custom detection |

Payload binaries are NOT in this repo (distribution = vendor URLs below,
hash-pinned in the wrapper).

## Install commands (vendor-documented, case-sensitive flags)

    Orb-installer.exe /S /LAUNCH_AT_STARTUP=1 /START_IN_BACKGROUND=1
    Orb-installer.exe /S /LAUNCH_AT_STARTUP=1 /START_IN_BACKGROUND=1 /ORB_DEPLOYMENT_TOKEN=<token>
    "C:\Program Files\Orb\uninstall.exe" /S

The wrapper adds: payload SHA-256 pin (`$expectedSha256`), a version
constant (`$appVersion` — the Orb binary carries **no FileVersion**, so
bump the constant on every payload swap), post-install ground truth
(binary AND ARP entry checked; NSIS success-without-install fails
60008/60010), process-kill before uninstall (a running Orb locks the exe
and the NSIS uninstaller exits 0 while silently leaving files — fails
loud 60015 instead), idempotent uninstall, 60s grace-poll, desktop-
shortcut suppression knob (`$suppressDesktopShortcut`), optional Orb
Cloud linking token (`$deployToken`, EMPTY in the repo — set at deploy),
and `ORB_SUMMARY` digest lines per phase in the PSADT log.

## What the installer creates (measured)

- `C:\Program Files\Orb\` — `Orb.exe` + `uninstall.exe` only
- `HKLM\SOFTWARE\Orb\MDM` — `LaunchAtStartup`, `StartInBackground`,
  `OrbDeploymentToken` (values from the switches)
- ARP entry DisplayName exactly `Orb` (key name `Orb Forge Inc.Orb`),
  `QuietUninstallString = "C:\Program Files\Orb\uninstall.exe" /S`
- Shortcuts: Start Menu (all users) + Public Desktop
- NO service, NO scheduled task, NO Run key — **a silent install
  auto-starts nothing**; the LAUNCH_AT_STARTUP switch writes registry
  values consumed at first user launch. Uninstall removes all of the
  above (measured zero residue).

## Deployment notes worth knowing (measured, not guessed)

- **No auto-updater** in this flavor — versions move only by redeploying
  a newer pinned payload.
- The NSIS ARP key lives in the **native 64-bit registry view only** —
  invisible to the 32-bit SCCM script host. `detection.ps1` handles this
  with a `Sysnative\reg.exe` native-view leg (a plain two-view registry
  scan returns not-detected on fully installed machines; that bug shipped
  in v1 of this kit and was caught by an install-state A/B test).
- `Orb.exe` has no FileVersion and no version CLI verb — the ARP
  `DisplayVersion` is the only version source.
- MSIX/winget distributions of the same app exist but are NOT
  standalone: the MSIX requires the `Microsoft.WindowsAppRuntime.1.4`
  framework and fails without it.

## Detection

`detected` = exit 0 AND stdout `Orb <version>`; `absent` = exit 0, silent
(never exit 1: SCCM reads nonzero as Unknown, Intune as reinstall fuel).
CLM-safe (no `[version]` casts; per-segment numeric `$minimumVersion`
floor, leave empty on rollout 1). Anchors the ARP `DisplayName` in both
views + the Sysnative leg under WOW64.

## SCCM shape

- Deployment Type: Script Installer. Install program: `Deploy-Application.exe`;
  uninstall: `Deploy-Application.exe -DeploymentType Uninstall`.
- Install behavior: Install for system. Detection: paste `detection.ps1`
  from file. Deployment: **Available** to a device collection (Software
  Center). Return codes 0/3010/1641/1618 standard; wrapper failures
  60001-60015.

## Payload sourcing

| Artifact | URL | SHA-256 (pinned in wrapper) |
|---|---|---|
| Installer | `https://pkgs.orb.net/earlyaccess/windows/Orb-installer.exe` | `6ac4670b43cab2aa7d3513e0fdaca599f1aa094eb037e76a579f97f733be9709` (v1.5.5) |

Re-pin on every version swap (supply-chain gate; never blind-clear).

## Verification status

Win11 lab VM: install ×2 (elevated + SYSTEM), idempotent rerun, repair,
uninstall (zero residue), SYSTEM uninstall — all exit 0; detection
true-positive from both the 64-bit and 32-bit script hosts on an
installed machine, true-negative on a clean one; collision guard (60012)
proven against the sensor flavor in both directions. Cloud-linking
behavior (token) not exercised — no cloud tenant in the lab.
