# Camera Stack Kit — Dell Pro (Intel MIPI)

This kit detects and repairs the integrated camera stack on Dell Pro 13/14
laptops: the Intel MIPI camera drivers, the USB bridge, and the presence-sensor
(Vision) firmware — the components that Windows feature updates commonly break.
Detection is read-only and safe to run at any time, including during video
calls. Installation waits for the camera to be idle, never prompts the user,
never closes applications, and never forces a restart.

For the problem statement and a 30-second overview, see the
[repository README](../README.md).

## What's in the box

| Path | Purpose |
|---|---|
| `detection/detect.ps1` | Standalone health check. Classifies the machine (see below) and returns a verdict as an exit code. Run it on any machine, any time. |
| `detection/intune-detection.ps1` | Detection script for an Intune Remediations package. Exits `1` only when remediation can help; surfaces other findings as text in the detection-output column. |
| `detection/intune-remediation.ps1` | Remediation script for the same package: downloads, verifies, extracts, waits for an idle camera, installs, cleans up. Fits the 60-minute remediation budget. |
| `deployment/install.ps1` | Standalone installer for Intune Win32 apps or manual (admin console) runs. Same behavior, longer wait window. |
| `deployment/app-detection-rule.ps1` | Detection rule script for the Intune Win32 app ("is the driver at target version?"). |
| `deployment/psadt-toolkit/` | A complete, unmodified PSAppDeployToolkit 3.10.2 with the install wrapper already in place as `Toolkit\Deploy-Application.ps1`. Add the driver files (below), wrap, deploy. |

## How detection classifies a machine

Two independent questions — **is the driver stack current?** and **is the
camera healthy?** — produce one verdict:

| | Camera healthy | Camera broken |
|---|---|---|
| **Driver below target** | `1` — routine update | `3` — update should fix it; prioritize |
| **Driver current** | `0` — nothing to do | `2` — a dependency is missing, not this driver |

- "Below target" includes a driver bound to a Microsoft inbox driver
  (`usbvideo.inf`) instead of the Intel stack — the signature of a feature
  update rebinding the camera.
- Firmware is checked through a registry proxy: `CurrentFWVersion` carries the
  Synaptics vision-extension INF version, where `>= 133.152.66.0` corresponds
  to firmware family `>= 8.5.98.42` (the level both current packages ship).
  `TargetVersion`/`UpdateVersion` are always `0.0.0.0` and are not signals.
- A device disabled on purpose (problem code 22) is reported separately and
  never treated as a fault — a driver update does not enable a disabled device.
- Exit `2` points at the dependency route in
  [Dell KB 000248760](https://www.dell.com/support/kbdoc/en-us/000248760/laptop-mipi-camera-may-not-work-under-windows):
  enable the camera in BIOS, then update chipset, graphics, ISH, Serial I/O,
  and ME. The detector prints the installed versions of those dependencies so
  the gap is visible immediately.

## How installation behaves

1. **Waits for an idle camera.** The installer polls the Windows camera
   consent store (`LastUsedTimeStop = 0` means an app is streaming). A laptop
   on a call waits; a locked-but-on-a-call laptop also waits; tray-idle Teams
   does not.
2. **Installs via standard PnP** (`pnputil /add-driver /install`) and triggers
   re-enumeration, so most machines finish live with no restart.
3. **Cleans the driver store.** Superseded camera-family packages are deleted
   once no device uses them (version-guarded; the active driver is never
   eligible). This removes the multi-generation residue that feature updates
   leave behind — the condition Dell's KB identifies as the root cause of
   these camera failures.
4. **Leaves restarts to the user.** If a device needs a restart to finish,
   the installer exits `3010` (success + pending). The old driver keeps the
   camera working until the user reboots whenever they choose. Nothing is
   ever forced.

Installer exit codes: `0` success · `3010` success, restart pending ·
`1618` camera busy past the wait window (Intune fast-retry).

## Deploying

### Intune Remediations (recommended)

1. Create a Remediations package with `detection/intune-detection.ps1` and
   `detection/intune-remediation.ps1`, running as SYSTEM.
2. Schedule daily (local time; missed runs execute when the device is next
   online). Use a weekly cadence for non-urgent sweeps.
3. The daily schedule is also the retry mechanism: a machine whose camera
   stayed busy simply gets the next day's run.

### Intune Win32 app

1. Copy the extracted Dell driver tree into
   `deployment/psadt-toolkit/Toolkit/Files/Drivers/`.
2. Wrap the `Toolkit` folder with IntuneWinAppUtil.
3. App settings:
   - Install command: `Deploy-Application.exe -DeploymentType Install -DeployMode Silent`
   - Detection rule: script `deployment/app-detection-rule.ps1`
   - Installation time required: **1440** (the maximum) — the wrapper waits
     up to 1380 minutes for an idle camera, so delivery and patience happen
     in a single run
   - Return codes: `0` / `3010` success; restart behavior **Nothing**;
     `1618` fast-retry
4. Assign as Required to a dynamic device group scoped to the hardware model.

### SCCM

Use the same toolkit folder as a package. The wrapper runs on PSADT 3.10.x
and v4 (all functions it calls have v4 compatibility wrappers).

## Driver packages

| Models | Package | Version | Download |
|---|---|---|---|
| Dell Pro 14 **Plus** (PB14250) | HW9TN | A13 (80.26100.0.29) | [direct link](https://dl.dell.com/FOLDER14812487M/1/Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera_HW9TN_WIN64_80.26100.0.29_A13.EXE) |
| Dell Pro 13/14 **Premium** (PA13250/PA14250) | 845M5 | A12 (80.25982.6.32) | [driver page](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=845m5) |

Driver binaries are not redistributed in this repository. Downloads are
verified before use: Authenticode signer must be Dell, plus SHA-256 when
published (845M5:
`D96D301FF7092C4F172EDB2F713BC2626FC3C5FB77C52D1560586DA901FFDB66`).
For air-gapped or test machines, `intune-remediation.ps1 -LocalPackage <path>`
uses a local copy of the package instead of downloading.

## Logs

| Location | Audience | Format |
|---|---|---|
| `C:\Windows\Logs\Software\...CameraStack...log` (PSADT log) | people | plain-English narrative, problem codes translated to text |
| `C:\ProgramData\DellCamera\<package>\machine.log` | tools / grep / fleet analysis | strict `key=value` lines, one per event |
| `C:\ProgramData\DellCamera\<package>\last_run.json` | tooling / support | full pre/post snapshot of the run |
| stdout | Intune / Remediations reporting | machine lines |

When the post-install check finds problems, a `setupapi_camera_slice.log`
(Windows driver-install history, filtered to the camera INFs) is captured
automatically — the forensic record of what the OS did to the camera stack.

## Testing summary

- **Package boot test (VM):** the toolkit + wrapper, assembled from this
  repository and run silently, initializes cleanly and exits through the
  hardware gate. Three packaging defects were found and fixed by this test.
- **Live hardware (Dell Pro 14 Premium):** model gating, version tables,
  problem codes, idle-camera detection, firmware registry layout, and the
  failure-history baseline all verified on target silicon.
- **Missing-camera experiment (controlled):** a camera removed while in use
  generates vetoed-removal warnings (Kernel-PnP event 1000) and **no
  events at all** afterward — establishing that a missing camera is only
  detectable through device enumeration, which is what the detector reads.

## References

- [Dell KB 000248760 — MIPI camera may not work under Windows](https://www.dell.com/support/kbdoc/en-us/000248760/laptop-mipi-camera-may-not-work-under-windows)
- [PSAppDeployToolkit](https://psappdeploytoolkit.com) (bundled under LGPL-3.0)
- Dell driver pages: [HW9TN](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=hw9tn) · [845M5](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=845m5)
