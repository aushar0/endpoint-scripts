# Camera Stack Kit — Dell Pro (Intel MIPI)

![Platform](https://img.shields.io/badge/Platform-Windows%2011-lightgrey)
![Intune](https://img.shields.io/badge/Intune-Win32%20%7C%20Remediations-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Package](https://img.shields.io/badge/Package-HW9TN%20A13-informational)

*"Camera can't start." "We can't find your camera." "Teams doesn't see my camera."*

On Dell Pro laptops, the Intel MIPI camera stack breaks in ways a version check
can't see: the Intel ISP (Image Signal Processor) wedges during a power-state
transition, causing the camera device to stop enumerating entirely. The camera
disappears from Device Manager, Teams reports no camera found, and Event Viewer
shows nothing at all once the device is gone.

This kit detects and repairs that stack. Detection is read-only, runs in ~2
seconds, and is safe at any time including during video calls. Remediation runs
the Dell driver installer silently, waits for an idle camera and microphone,
and never forces a restart.

## Quick start

```powershell
# Read-only health check — safe during calls, exits in seconds
powershell -File .\detection\detect.ps1
```

## Detection exit codes

The Intune Remediations detection script (`intune-detection.ps1`) uses a
simple two-way exit code driven by **camera health**, not driver versions:

| Exit | Meaning | Action |
|---|---|---|
| 0 | Camera healthy (or machine not a Dell Pro) | Leave alone |
| 1 | Camera broken — device problem codes, missing camera, or both | Remediate |

Driver version information, firmware state, dependency versions, and upgrade
correlation appear in the output as **context only** — they do not affect the
exit code. This matches the operational need: find machines whose cameras
don't work, not machines whose drivers are theoretically old.

## What's in the box

| Path | Purpose |
|---|---|
| `detection/detect.ps1` | Standalone diagnostic with full verbose output. Run manually on any machine. |
| `detection/intune-detection.ps1` | Intune Remediations detection. Single-line output, camera-health exit code. |
| `detection/intune-remediation.ps1` | Intune Remediations remediation. Downloads, verifies, and runs the Dell installer silently. |
| `deployment/psadt-toolkit/` | Complete PSAppDeployToolkit 3.10.2 for SCCM or Win32 app deployment. |

## Detection output format

A single dense line (under 2,048 characters — the Intune Remediations limit),
designed so every field is a commonality data point for fleet-wide analysis:

```
CAMERA_BROKEN(5):iaisp64,iacamera64,hm1092,Integrated Webcam,Himax|iaisp64=10(device_cannot_start) iacamera64=10(device_cannot_start)|drv:current|dep:ish=5.8.52,serialio=30.100.2524,me=2546.9.2|fw:133.152.66.0|bld:26200|upg:2026-08-14|ntstatus:0xC00000E5
```

Fields (pipe-delimited):

| Field | What it tells you |
|---|---|
| `CAMERA_BROKEN(n):names` | Verdict + which components are failing |
| `component=code(meaning)` | Per-device problem code with readable cause |
| `ntstatus:0x...` | NTSTATUS from setupapi logs (the deeper "why") |
| `drv:current` or `drv:N_old` | Driver currency (context, not the trigger) |
| `dep:ish=version,serialio=version,me=version` | Dependency versions (KB 000248760 route) |
| `fw:version` | Synaptics bridge firmware proxy |
| `bld:number` | Windows build |
| `upg:date` | Last feature-update date |
| `err:date(+hours)` | First Frame Server error (when present) |

Healthy machine: `CAMERA_OK|drv:current|dep:ish=5.8.52,...|fw:133.152.66.0|bld:26200|upg:2026-09-01`

## How detection works

1. **Hardware gate.** SMBIOS model check for PB14250/PA14250. Everything
   else exits silently.
2. **Device inventory.** `Win32_PnPEntity` (reliable, ~0.1s) for hardware
   IDs, problem codes, device class, and name.
3. **Driver binding.** `Win32_PnPSignedDriver` for installed versions,
   with per-device `Get-PnpDeviceProperty` fallback when the cached class
   returns incomplete data.
4. **Health evaluation.** Problem codes (10 = cannot start, 14 = needs
   restart, 28 = no driver, 43 = device reported problems). Camera-class
   device count. Disabled devices (code 22) are reported separately and
   never treated as a fault.
5. **Root cause lookup.** When problems are found, the Windows setupapi
   driver-install history is searched for NTSTATUS codes (0xC00000E5 =
   power failure, 0xC0000094 = driver error, etc.).
6. **Output.** Single line, verdict first, context and causes after.

Frame Server error events (7-day window) appear as diagnostic context but
are **excluded from the exit code** — they are a lagging indicator that
persists for up to 7 days after a camera has been fixed, causing false
positives on remediated machines.

## How remediation works

The remediation script runs only when detection exits 1 (camera broken).
It uses the Dell Update Package installer directly — the same method that
has fixed 100+ ticket machines:

1. **Camera and microphone idle check.** Polls the Windows consent store
   (`LastUsedTimeStop = 0` means an app is streaming). Catches Teams,
   Zoom, WebEx, Chrome, Edge, Discord, and anything else. Audio-only calls
   are detected via the microphone consent store.
2. **Package download.** Fallback chain: HttpClient → Invoke-WebRequest →
   BITS. Verified: Authenticode signature from Dell + SHA-256 when published.
   Cached in `C:\ProgramData\DellCamera\` after first download.
3. **Dell silent install.** Runs the package EXE with `/s` (the proven
   method). The installer handles driver staging, binding, and cleanup
   internally. No extraction, no pnputil, no manual driver-store management.
4. **Device rescan.** `pnputil /scan-devices` triggers re-enumeration of
   any devices that can recover without a restart.
5. **Verification.** Checks whether the camera is now present and healthy.
   Captures `setupapi_camera_slice.log` as forensic evidence if problems
   persist.
6. **Toast notification** (optional, `-ShowToast`). Windows toast with
   customizable banner image, circular icon, title, and message. Shows via
   a scheduled task in the user's session (required because Intune/Nexthink
   runs as SYSTEM).

Exit codes: `0` success · `3010` success, restart pending (the reboot
belongs to the user; never forced) · `1` download or install failed.

## The root cause (from fleet evidence)

The Intel ISP (`PCI\VEN_8086&DEV_7D19`) freezes during a power-state
transition (`0xC00000E5 STATUS_DEVICE_POWER_FAILURE`). When the ISP wedges,
the downstream camera device stops enumerating — it disappears from Device
Manager entirely. Teams and the Windows Camera app report "no camera found."

The fix requires two things: the driver package staged (so it binds when
the device re-enumerates) and a reboot (which power-cycles the wedged ISP).
The Dell installer + reboot has fixed 100% of reported cases.

Machines with outdated drivers but working cameras are **not** flagged by
this detection — version currency is informational context, not the trigger.

## Deploying

### Intune Remediations (recommended)

1. Create a Remediations package:
   - Detection script: `detection/intune-detection.ps1`
   - Remediation script: `detection/intune-remediation.ps1`
   - Run as SYSTEM
2. Schedule daily. Detection runs in ~2 seconds (read-only). Remediation
   only fires on detection exit 1 and is idempotent on re-runs.
3. Optional toast: add `-ShowToast` to the remediation script parameters.
   Add `-ToastBanner <path>` and `-ToastIcon <path>` for branded images.

### SCCM / Intune Win32

Use the `deployment/psadt-toolkit/` folder with the full PSAppDeployToolkit.
See the [PSADT documentation](https://psappdeploytoolkit.com) for packaging.

## Driver packages

| Models | Package | Version | Download |
|---|---|---|---|
| Dell Pro 14 **Plus** (PB14250) | HW9TN | A13 (80.26100.0.29) | [direct link](https://dl.dell.com/FOLDER14812487M/1/Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera_HW9TN_WIN64_80.26100.0.29_A13.EXE) · [driver page](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=hw9tn) |

Driver binaries are not redistributed in this repository. Downloads are
verified before use: the Authenticcode signer must be Dell, plus SHA-256
when a hash is published. For air-gapped machines, pass `-LocalPackage <path>`.

## References

- [Dell KB 000248760 — MIPI camera may not work under Windows](https://www.dell.com/support/kbdoc/en-us/000248760/laptop-mipi-camera-may-not-work-under-windows)
- [How the packages were analyzed](docs/installer-analysis.md) — the full decomposition case study
- [PSAppDeployToolkit](https://psappdeploytoolkit.com) (bundled under LGPL-3.0)
