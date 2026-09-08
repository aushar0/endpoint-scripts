# Camera Stack Kit — Dell Pro (Intel MIPI)

Detection, classification, and no-disturbance remediation for the Intel camera
stack on Dell Pro 13/14 laptops. Start with the [repo README](../README.md)
for the problem statement and quick start.

## How it decides

Every run classifies the machine two ways — **driver state** (at/below target,
misbound to an inbox driver, firmware payload level) and **camera health**
(problem codes, missing devices, Frame Server errors) — and maps them to one
verdict:

| | Camera healthy | Camera broken |
|---|---|---|
| **Driver below target** | routine update (exit 1) | prime candidate — remediate (exit 3) |
| **Driver current** | leave alone (exit 0) | dependency route, not this package (exit 2) |

Also classified separately: **disabled-by-choice** (problem code 22) — surfaced
as telemetry, never treated as a fault, because a driver update will not enable
a disabled device.

## Architecture

```
detection/detect.ps1              the 2×2 monitor (standalone, read-only)
detection/intune-detection.ps1    Intune Remediations gate (exit 1 = remediate;
                                  broken-but-current exits 0 with a telemetry banner
                                  visible in the detection-output column)
detection/intune-remediation.ps1  download → verify → extract → wait-for-idle →
                                  install → cleanup sweep (fits the 60-min cap)
deployment/install.ps1            same flow for Intune Win32 (24h-timeout variant)
deployment/app-detection-rule.ps1 Win32 app detection ("driver at target?")
deployment/psadt-toolkit/         complete PSAppDeployToolkit 3.10.2 with the
                                  wrapper as Toolkit\Deploy-Application.ps1
```

### The no-disturbance doctrine (every install path)

- **Waits for camera-idle** — polls the CapabilityAccessManager consent store
  (`LastUsedTimeStop = 0` = streaming). Tray-idle Teams proceeds;
  locked-but-on-a-call waits.
- **Never prompts, never closes apps, never kills processes.**
- **Restarts are user-paced** — pending states ride the user's natural reboot;
  the old driver keeps the camera working until then. Exit 3010 = success +
  pending, never a forced reboot.
- **Old-driver cleanup** — superseded family packages are deleted from the
  store only when unbound (version-guarded; the just-installed package is
  never eligible). This is Dell's removal-utility step, deferred until safe.

## Deploying

### Intune Remediations (recommended)

1. Package `intune-detection.ps1` + `intune-remediation.ps1` as a Remediations
   script package (run as SYSTEM).
2. Schedule daily (19:00 local works well; missed runs catch up when online).
   Non-time-critical sweeps can be weekly.
3. Remediation budget: 60 min hard cap — download (~5m) + wait (45m default)
   + install + sweep fits. Daily recurrence is the retry engine: a busy camera
   today gets tomorrow's run.

### Intune Win32 app

- Content: `deployment/psadt-toolkit` (drop the extracted Dell driver tree into
  `Toolkit\Files\Drivers\` first), wrapped with IntuneWinAppUtil.
- Install command: `Deploy-Application.exe -DeploymentType Install -DeployMode Silent`
- Detection rule: script `app-detection-rule.ps1`
- **Installation time required: 1440** (the max) — the script waits up to 1380
  min for camera-idle, so delivery and patience happen in one run.
- Return codes: 0 / 3010 success (**restart behavior: Nothing** — the restart
  belongs to the user); 1618 = busy → Intune fast-retry, each retry with a
  fresh wait window.
- Scope: Entra dynamic device group on the hardware model (pull the exact
  string from Intune > device > Hardware).

### SCCM

Same toolkit folder as a package; the PSADT wrapper is version-safe for both
PSADT 3.10.x and v4 (all wrapper functions carry v4 compatibility wrappers;
slot the logic into a v4 Template_v3 when adopting the newer engine).

## Package manifest

| Family | Package | Version | Direct download |
|---|---|---|---|
| PB14250 (Pro 14 Plus) | HW9TN | A13 (80.26100.0.29) | [dl.dell.com](https://dl.dell.com/FOLDER14812487M/1/Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera_HW9TN_WIN64_80.26100.0.29_A13.EXE) |
| PA13250/PA14250 (Pro 13/14 Premium) | 845M5 | A12 (80.25982.6.32) | grab from the [845M5 driver page](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=845m5) (JS-loaded link) |

Remediation verifies every download: Authenticode **Dell-signed** + SHA-256
where published (845M5:
`D96D301FF7092C4F172EDB2F713BC2626FC3C5FB77C52D1560586DA901FFDB66`).
The `remediation.ps1` accepts `-LocalPackage <path>` for offline/testing.

## Logging

Three surfaces, one event stream:

| Surface | Audience | Format |
|---|---|---|
| PSADT log (`C:\Windows\Logs\Software`) | humans | plain-English narrative with glossed problem codes |
| `machine.log` + `last_run.json` (`C:\ProgramData\DellCamera\<pkg>\`) | grep/AI/fleet | strict `key=value` lines + JSON pre/post diff |
| stdout | Intune/Remediations reporting | machine lines |

On post-install problems, a `setupapi_camera_slice.log` (Windows driver-install
history, camera INFs only) is captured automatically — the forensic record of
what the OS upgrade did to the bindings.

## Verification evidence

- **Boot test (VM):** full toolkit + wrapper assembled from the public repo,
  run silent — clean init, gate exit 0, our log source confirmed in the PSADT
  log. Three packaging bugs caught and fixed by this test (commented import,
  CDN-cache masking, missing `-DeploymentType` parameter).
- **Live target run (PA14250):** model gate, family version tables, problem
  codes, consent-store idle check, firmware registry layout, and the RCA
  first-error baseline all validated on real silicon. That machine also
  exhibited a mixed stack (current firmware on stale MIPI drivers) — the
  exact incomplete-update failure Dell's KB 000248760 describes.
- **Missing-camera experiment (controlled):** a camera uninstalled while in
  use leaves vetoed-removal warnings (Kernel-PnP id=1000) and *zero* events
  afterward — proving the missing-device class is only detectable via PnP
  enumeration, which is what the detector reads.

## Firmware check

`CurrentFWVersion` (registry, per device) carries the Synaptics
vision-extension INF version — a firmware-payload proxy:
`>= 133.152.66.0` ⇔ firmware family `>= 8.5.98.42` (both current packages).
`TargetVersion`/`UpdateVersion` remain `0.0.0.0` by design (unpopulated
placeholders) and are never treated as signals.

## Prerequisite

Per Dell KB 000248760: the Intel Integrated Sensor Solution (ISH) driver must
be present before this stack. The detectors report ISH / Serial IO / ME /
graphics versions as context so dependency gaps are visible at a glance.
