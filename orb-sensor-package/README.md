# Orb sensor — PSADT 3.10.1 package (headless service)

![PowerShell](https://img.shields.io/badge/PowerShell-5.1-blue) ![PSADT](https://img.shields.io/badge/PSAppDeployToolkit-3.10.1-purple) ![tested](https://img.shields.io/badge/lab--tested-install%2Frepair%2Funinstall%2FSYSTEM-brightgreen)

Purpose: deploy the **Orb sensor** (orb.net's headless network measurement
service) per-machine and silently via SCCM/Intune. The vendor's own
`install.ps1` cannot be used unattended — its uninstall/reinstall paths
prompt via `Read-Host`, which cannot read piped stdin and hangs hidden
sessions forever (reproduced, not assumed). This wrapper performs the
vendor steps NATIVELY: stage binary → create/configure/start the service
→ firewall → verify.

**Companion kit: [`orb-app-package/`](../orb-app-package/)** — the desktop
app flavor. The two flavors share `C:\Program Files\Orb\Orb.exe`, so each
package REFUSES to install on top of the other (exit 60012, live-tested
both directions). Deploy to disjoint device collections.

## Contents

| File | Role |
|---|---|
| `Deploy-Application.ps1` | PSADT 3.10.1 wrapper (install / repair / uninstall), native service management |
| `detection-sensor.ps1` | One detection script for SCCM Deployment-Type + Intune Win32 custom detection |

The payload zip is NOT in this repo (vendor URL below, hash-pinned).

## What the package creates (measured)

- `C:\Program Files\Orb\Orb.exe` — extracted from the pinned vendor zip
- Service **"Orb"** — `Orb.exe windowsservice`, Automatic, LocalSystem,
  failure-recovery restart ×3 @60s, reset 86400 (vendor parity,
  `sc qfailure`-verified)
- Inbound firewall rule **"Orb"** for the exe (knob `$createFirewallRule`)
- `C:\ProgramData\Orb` — data dir the service creates on first start
- Service Environment: `ORB_MEASURE_SERVER_ENABLED=0` — this package
  DISABLES the vendor's default inbound TCP 7443 measure listener
  (posture default; `$measureServerEnabled = $true` restores vendor
  parity) plus optional `ORB_DEPLOYMENT_TOKEN` (`$deployToken`, EMPTY in
  the repo — set at deploy to link the device to an Orb Cloud space)
- **NO ARP entry, NO scheduled task, NO auto-updater, NO shortcuts** — the
  service IS the autorun; version moves only by redeploying a newer
  pinned zip. Uninstall removes all of the above (measured zero residue).

## Knobs (top of the wrapper)

| Variable | Default | Notes |
|---|---|---|
| `$zipSha256` | pinned | Re-pin on version swap; empty = skip check (do not ship that way) |
| `$deployToken` | `''` | Orb Cloud linking token; credential — never commit filled |
| `$measureServerEnabled` | `$false` | Vendor default is ON (inbound TCP 7443 listener on every device) |
| `$createFirewallRule` | `$true` | Inbound allow rule for the exe |

## Detection

Anchor = SCM service `Orb` with the `windowsservice` binary path.
Detected = exit 0 AND stdout; absent = exit 0, silent. Deliberately NOT
state-gated on Running (a stopped service is still installed — Running-
gated detection causes reinstall waves). Services are not registry-
redirected, so the 32-bit SCCM script host and the 64-bit Intune host get
identical answers. No version floor: the binary carries no FileVersion
and invoking its version CLI from detection would spawn the service
binary — existence-only on rollout 1.

## SCCM shape

- Deployment Type: Script Installer. Install program: `Deploy-Application.exe`;
  uninstall: `Deploy-Application.exe -DeploymentType Uninstall`.
- Install behavior: Install for system. Detection: paste
  `detection-sensor.ps1` from file. Deployment: **Available** to a device
  collection (Software Center). Return codes 0/3010/1641/1618 standard;
  wrapper failures 60001-60014 (60012 = the desktop-app flavor is
  installed).

## Payload sourcing

| Artifact | URL | SHA-256 (pinned in wrapper) |
|---|---|---|
| Sensor binary zip | `https://pkgs.orb.net/stable/generic/latest/orb-windows-amd64.exe.zip` | `3df467cb5adf8d9f6abd75ba92e18fe63c9c88b94a38ab16d9abf2e2676887ce` (v1.5.5; inner exe `7a7e4314…47ce`, unsigned, version CLI `v1.5.5`) |

Re-pin on every version swap. Note: the sensor binary is **unsigned** —
if application-control policy gates unsigned binaries, decide this BEFORE
the pilot, not after.

## Verification status

Win11 lab VM: install (elevated + SYSTEM), idempotent rerun, repair,
SYSTEM uninstall (zero residue), SYSTEM install — all exit 0 with the
service Running/Auto; detection true-positive from both the 64-bit and
32-bit script hosts on an installed machine, true-negative on a clean
one; collision guard (60012) proven against the desktop-app flavor in
both directions; locked-binary incident during testing produced the
process-kill-before-staging step. Cloud-linking (token) not exercised —
no cloud tenant in the lab.
