# Case Study: Decomposing the Dell Camera Driver Package
## Intel 2D Imaging / USB IO / Vision — HW9TN A13 (and sibling 845M5 A12)

*Investigation record, 2026-09-07/08. Chronological. Approaches that did not
work are included where they save future effort. Findings state their basis:
read directly from an artifact, observed on live hardware, or inferred and
later confirmed.*

## Summary of findings

| # | Finding | Basis |
|---|---|---|
| 1 | The reboot demand is three layers: DUP metadata (`rebootRequired="true"` in package.xml), installer problem-code checks (codes 14/15), and the Synaptics bridge firmware flash (200 s maximum). | Package XML, installer strings, extension INF |
| 2 | None of the 14 driver INFs contain reboot directives. Windows itself does not require a restart for this stack. | Search across all INFs; zero matches |
| 3 | The DUP's real sequence is: SSID applicability check, old-driver removal utility, install, reboot prompt. The removal utility ships inside a PyInstaller bundle alongside the SSID check. | Binary strings, embedded filenames |
| 4 | Old-driver removal is not required for the fix. A newer, more hardware-specific package wins rank on re-enumeration; removal prevents recurrence. | Driver ranking mechanics; INF specificity |
| 5 | Packages are subsystem-locked. HW9TN A13 binds only SUBSYS 0CDC/0CF8 (Lunar Lake) and 0CE8/0CF7 (Arrow Lake), matching the Dell Pro 14 Plus. 845M5 A12 binds 0CE3/0CE4, matching the Pro 13/14 Premium. No generic IDs exist in either package. | INF hardware-ID lists; Dell's compatibility page |
| 6 | Registry `CurrentFWVersion` carries the vision-extension INF version: at or above 133.152.66.0 corresponds to firmware family 8.5.98.42 or later. `TargetVersion` and `UpdateVersion` are always 0.0.0.0 and are never populated. | Live registry values on target hardware |
| 7 | A missing camera leaves no Event Viewer evidence at any level. Detection is only possible through PnP enumeration. Pre-mortem signals exist: Kernel-PnP warning 1000 (removal vetoed while in use) and Frame Server activation history. | Controlled experiment on live hardware |
| 8 | A deleted camera devnode with a jammed configuration queue cannot be restored live. Scan, restart, disable/enable, and remove were all refused; only a reboot clears it. | Exhaustive method test on live hardware |
| 9 | Dell KB 000248760 covers this ticket class. Its dependency list (BIOS camera enable, chipset, graphics, ISH, Serial I/O, ME) defines the route for machines whose drivers are current but whose camera is broken. | Vendor article, read in full |
| 10 | `package.xml` is UTF-16, as are several INFs. Text tooling must detect encoding before parsing. | Extraction failures, then successful decode |

## 0. The question under investigation

Why does the installer require a restart to finish, and can the camera be
brought up without one?

Subject: `Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera_HW9TN_WIN64_80.26100.0.29_A13.exe`
(95 MB, Dell Update Package format). The question later expanded into a full
detection and remediation program, but the reboot question is where everything
started.

## 1. Extraction

7-Zip opens the executable directly; no installation run was needed.

```
7z x Intel-...A13.EXE   →   241 files, 415 MB uncompressed
```

The layout recovered:

```
16299/Drivers/x64/
├── MIPI_Camera/     Intel ISP stack: iacamera64, iaisp64, sensor drivers,
│                    extensions, per-board tuning (.aiqb/.cpf/graph_settings)
├── USBIO/           usbbridge, UsbGpio, usbi2c
├── Vision/          Vision.inf (ARL + LNL variants), visionextension.inf,
│                    fw/06CB0701.bin
DellInstaller_x64.exe
mup.xml              installer manifest (UTF-8)
package.xml          Dell DUP metadata (UTF-16)
2026-05-28_..._SSID_check_PB14250.exe   applicability gate
```

The first read of `package.xml` failed as "binary/unsupported encoding." It is
UTF-16LE, and several INFs are likewise. Every text extractor in this lane now
detects encoding before parsing; anyone re-extracting these packages will hit
the same wall without that step.

## 2. What the metadata says

`package.xml` carries `rebootRequired="true"` as a static attribute, set before
any hardware is touched. That one attribute is most of the answer to the
original question. The file also declares criticality "Urgent" (value 2), a
revision note reading in part: "Fixed the issue where a green screen is
displayed on the user's camera window on a Microsoft Teams call... when the
Dell Dock D6000 or UD22 is connected," and a prerequisite: the Intel
Integrated Sensor Solution driver must be installed first. That prerequisite
later became an entire classification branch.

`mup.xml` scopes the package to "Dell Pro Laptops," runs the SSID check as a
pre-install step (exit 0 proceeds, exit 1 aborts), and maps every hardware ID
to its component version. Extension INFs install two seconds after their base
INFs.

## 3. The reboot verdict: three stacked causes

First, DUP policy. The `rebootRequired` attribute is hardcoded.

Second, installer behavior. Strings extracted from `DellInstaller_x64.exe`
include `REBOOT_REQUIRED`, `needReboot`, `rebootFlag`, `RebootBypass`, and the
Windows problem-code lookup text for code 14 ("This device cannot work
properly until you restart your computer") and code 15 (re-enumeration
problem). The installer calls `DiInstallDriver`, then checks the resulting
problem codes; any device landing in code 14 triggers the reboot demand.

Third, the firmware flash. `visionextension.inf` stages `fw/06CB0701.bin`,
Synaptics Sabre USB-bridge firmware, configured with `FWUpdateRetries=5`,
`MaxFlashTimeMs=200000`, and `FWAntiRollback=1`. A flashed bridge chip expects
a power cycle.

The counter-finding matters more than the three causes. A search across all
fourteen INFs for reboot-related directives, including file-in-use copy flags,
returns nothing. Every driver is DriverStore-resident (`%13%`,
`PnpLockdown=1`) with demand-start services. Windows does not need this
reboot; Dell's policy, in-use device nodes, and the firmware flash do. That
distinction is what made a deployment lane without forced restarts credible.

## 4. Component map of the stack

| Layer | Components | Hardware IDs |
|---|---|---|
| Camera controller | iacamera64 (ARL + LNL variants) | `VIDEO\VEN_8086&DEV_7Dxx/B640/64xx...&INT3480` |
| ISP | iaisp64 | `PCI\VEN_8086&DEV_7D19` (ARL), `645D` (LNL) |
| Sensors | hm1092 (Himax), ov05c10, ov08x40 (OmniVision) | `ACPI\VEN_HIMX/OVTI&DEV_xxxx&SUBSYS_...` |
| Control logic | iactrllogic64 | `ACPI\VEN_INT&DEV_3472/346F` |
| USB bridge | usbbridge | `USB\VID_06CB&PID_0701` (Synaptics Sabre), `VID_2AC1` (Lattice), `VID_8086&PID_0B63` |
| USB IO | UsbGpio, usbi2c | `ACPI\INTC10B5`, `ACPI\INTC10B6` |
| Presence sensor | Vision | `ACPI\INTC10E0` (ARL), `ACPI\INTC10DE` (LNL) |

The Vision driver handles presence detection (Walk Away Lock, Wake on
Approach, Adaptive Dimming, per Dell's description). The full stack spans
roughly fourteen interdependent device nodes.

## 5. The SSID gate and the PyInstaller bundle

The SSID check is a 7.3 MB executable. Its strings include `python312.dll`,
`pyi_rth_inspect`, and `pyi-contents-directory`: a PyInstaller bundle. The
embedded file list names `bSupportSSID.json`, `IPU_uninstall_v3.py`, and
`Uninstall_driver_v3.py`. That last name answers the install-order question
before the knowledge base article does: the DUP's real sequence is SSID check,
uninstall-scrub of old driver packages, install, reboot prompt. The removal
utility referenced in Dell's documentation lives inside this bundle.

Do not retry parsing the CArchive for `bSupportSSID.json`. It is unnecessary
(support scope is answered three ways: Dell's page, the manifest, the INF
subsystems), and the embedded script list drifts between revisions;
`IPU_uninstall_v3.py` is present in A12 and absent in A13.

## 6. Subsystem scoping: the PA/PB wall

Every sensor and camera INF lists hardware IDs with Dell subsystem IDs only:

- HW9TN A13: `SUBSYS_0CDC1028` and `SUBSYS_0CF81028` (Lunar Lake),
  `SUBSYS_0CE81028` and `SUBSYS_0CF71028` (Arrow Lake). No generic fallback
  IDs appear anywhere in the package.
- A device-manager paste from a Dell Pro 14 Premium showed
  `VIDEO\VEN_8086&DEV_64A0&SUBSYS_0CE41028&INT3480`. Subsystem 0CE4 appears
  nowhere in HW9TN.

Three independent sources agree: Dell's compatible-systems page lists only the
Pro 14 Plus (PB14250), the manifest scopes to its subsystems, and the INFs
carry no others. HW9TN drivers would stage on a Premium machine but never
bind. The Premium line needs its own package, 845M5.

Extracted the same way, 845M5 A12 scopes to subsystems 0CE3/0CE4, Lunar Lake
only, with MIPI versions one build older (70.26100.2.21086 against .21770).
The USB IO trio carries identical versions in both packages: a shared
component family. The vision extension is likewise identical (133.152.66.0).
Its SSID check names PA13250 and PA14250, and its manifest still says
"Latitude" in the applies-to field, stale template metadata that the binary
ignores. Its changelog reads: "fixed a Windows error message after resume
from sleep," which is relevant to any fleet of machines that sleep
constantly.

## 7. Firmware state: from binary strings to live semantics

`Vision.sys` contains the string `CurrentFWVersion`; `usbbridge.sys` contains
`TargetVersion` and `UpdateVersion`, and its INF writes `TargetVersion=0.0.0.0`
with the comment "to be provided by an extension inf." The firmware blob
itself contains no readable version strings.

On live target hardware the registry read:

```
CurrentFWVersion = 133.152.66.0
TargetVersion    = 0.0.0.0
UpdateVersion    = 0.0.0.0
```

`CurrentFWVersion` carries the Synaptics vision-extension INF version, not
chip firmware. The value 133.152.66.0 is exactly the extension INF version
shipping in both current packages, whose folder name in 845M5
(`VisionExtension_v85_98_42_00`) discloses the firmware family 8.5.98.42. The
value therefore works as a firmware-payload proxy: 133.152.66.0 or later
means firmware family 8.5.98.42 or later. `TargetVersion` and `UpdateVersion`
are never populated by any shipped component and carry no signal.

The same machine showed a current firmware layer over below-target MIPI
drivers: a mixed stack, and a live example of the incomplete-update failure
mode Dell's article names as the root cause.

## 8. Detection engineering: what was built, and how each piece was verified

| Signal | Verification |
|---|---|
| PnP property keys (`DEVPKEY_Device_ProblemCode`, `_DriverVersion`, `_DriverProvider`, `_DriverInfPath`) | Executed against a healthy USB camera before use; `_DriverInf` does not exist and was probed rather than assumed |
| Four-way verdict (exit 0/1/2/3) | Healthy machine returned 0; camera-less VMs returned 2 twice; a below-target live machine returned 1 |
| Disabled is not broken (problem code 22) | Found via a deliberately disabled test device; classified separately, since a driver update does not enable a disabled device |
| Upgrade context (install date resets at feature update; Windows.old expires) | Built from documented Windows behavior; printed beside broken verdicts as correlation |
| Misbound signature (matching Intel hardware ID on a Microsoft provider or `usbvideo.inf`) | Property keys verified live; the fingerprint of a feature update rebinding the camera |
| Frame Server error baseline | Healthy machine shows zero error-level events in the channel |
| Camera-in-use check (consent store `LastUsedTimeStop = 0`) | Validated live during an active camera stream; replaced an earlier process-name approach that would have deferred forever on tray-idle Teams |

## 9. The Event Viewer experiment

The question: what does Event Viewer record when applications try a missing
camera? A controlled run, with the camera uninstalled while an application
held it open:

| Time | Event | Source |
|---|---|---|
| 12:00:01 | Teams using the camera (640x360, information level only) | Frame Server FsProxy events 6/7 |
| 12:23:32, 12:24:06 | Uninstall vetoed, device in use (warning 1000) | Kernel-PnP Device Management |
| 12:24:06 | Device deleted (event 420) | Kernel-PnP Configuration |
| after 12:24 | Nothing, at any level, in any channel | — |

A missing camera is forensically invisible. Applications attempting it
generate no events at all, which is why this ticket class is only detectable
through device enumeration. The two pre-mortem signals worth watching:
vetoed-removal warnings, indicating something pulled a camera device while an
application held it, and Frame Server activation history, showing the camera
worked until a specific moment.

The restore attempt that followed exhausted every live method. With the
camera's device node deleted but its USB composite parent healthy, `scan`
did not rebuild the node; `restart-device` was refused; disable/enable failed
with a generic error; and removing the parent outright for a simulated replug
was also refused. All four returned the same message: "System reboot is
needed to complete configuration operations." The pending-configuration queue
behind a vetoed removal blocks everything until boot. After the reboot the
camera returned on its own, fresh node, inbox driver, problem code zero. One
more detail from the diagnostics: the internal webcam shares its USB root hub
with the Intel Bluetooth adapter, so any hub-level reset would have taken
both down.

## 10. Install order: Dell's sequence against the kit's

Dell KB 000248760 covers this ticket class; its symptom list matches the
support tickets word for word, including the 0xA00F4244 error in its search
keywords, and both the Plus and Premium models appear in its affected list.

Dell's sequence: enable the camera in BIOS, install the camera driver by
running the executable (because it contains the old-driver removal utility),
reboot, and if the camera still fails, update the dependency stack (chipset,
graphics, ISH, Serial I/O, ME) and reboot again. The stated cause: Windows
Update and similar tools push incorrect or incomplete drivers, and the
components depend on a specific install order.

The kit's sequence differs in one respect. The new packages install first;
devices rebind live when the camera is idle; superseded family packages are
deleted from the store only once nothing uses them, guarded so the
just-installed package is never eligible even while unbound during a pending
restart. Removal happens when unused: immediately if devices rebind live, at
the user's natural restart otherwise. Same hygiene, no ceremony, and the
camera keeps working throughout.
