# endpoint-scripts

Endpoint engineering toolkit — detection, deployment, and health monitoring
for driver remediation. Current kit: **Intel camera stack (Dell package
HW9TN A13, v80.26100.0.29), worked example: Dell Pro 14 Plus (PB14250).**

## HW9TN camera stack kit (`HW9TN/`)

| File | Job |
|---|---|
| `HW9TN_detect.ps1` | Read-only health monitor + needs-update detection. Run on any machine — self-gates by model. Safe during calls (nothing is closed or stopped). |
| `install.ps1` | Bare Intune Win32 installer: pnputil-based, patient-wait, no forced reboot. |
| `Deploy-Application.ps1` | PSADT v3.8/3.9 wrapper — same payload, same doctrine (syntax verified against PSADT 3.10.2 reference docs). |
| `detection_rule.ps1` | Intune Win32 app detection rule ("driver at target version?"). |
| `readme.md` | Full deployment notes: package build, Intune app settings, return codes, design doctrine. |

### Quick start — detection

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File HW9TN_detect.ps1
# on a lab machine / non-target model: add -ForceScan to bypass the model gate
```

| Exit | Meaning | Action |
|---|---|---|
| 0 | healthy + current | leave alone |
| 1 | needs update | routine — overnight/next-cycle install |
| 2 | camera problem, driver current | NOT this driver — check Intel ISH prerequisite, BIOS, hardware |
| 3 | needs update AND broken | prime candidate — remediate now |

The detector reads real device state: camera-class devices and PnP problem
codes (10 = cannot start, 14 = needs restart, 28 = no driver), zero-camera
signature, Frame Server error events (7d), stack driver versions vs target,
and Synaptics bridge firmware registry state.

### Installer behavior (both installers)

- **Patient wait**: polls the camera-streaming state (CapabilityAccessManager
  consent store) every 10 min up to 45 min; installs the moment the camera is
  idle. Locked-on-a-call correctly reads as busy; tray-idle Teams does not.
- **Never prompts, never closes apps, never kills processes.**
- Installs via `pnputil /add-driver /subdirs /install` + live re-enumeration.
- **Restarts are user-paced, always** — exit 3010 (pending restart) rides the
  user's natural reboot; the old driver keeps the camera working meanwhile.
  No forced reboot with unsaved work, ever.
- Exit codes: `0` success · `3010` success + pending restart · `1618` camera
  busy → Intune fast-retry (not a failure).

### Model coverage (verified from package INFs)

Two package families, both covered by the detector via subsystem-scoped target
tables:

- **HW9TN A13** — Dell Pro 14 Plus (PB14250): subsystems 0CDC/0CF8 (Lunar Lake)
  and 0CE8/0CF7 (Arrow Lake)
- **845M5 A12** — Dell Pro 13/14 Premium (PA13250/PA14250): subsystems
  0CE3/0CE4, Lunar Lake

Each family binds only its own package (subsystem matching is strict in the
INFs); shared components (USB bridge / GPIO / I2C / Vision-LNL) carry the same
versions in both. The installers here are built from the HW9TN package — build
the 845M5 payload identically for Premium devices.

Prerequisite per Dell: Intel Integrated Sensor Solution (ISH) driver must be
installed before this stack.

Source package: "Intel 2D Imaging/USB IO/Vision Driver for Camera", A13
(80.26100.0.29), Dell driver ID HW9TN.
