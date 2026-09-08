# endpoint-scripts

> Windows endpoint engineering kits — detect, classify, and remediate driver faults
> **without disturbing a single user.**

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Platform](https://img.shields.io/badge/Platform-Windows%2011-lightgrey)
![Intune](https://img.shields.io/badge/Intune-Win32%20%7C%20Remediations-0078D4)
![License](https://img.shields.io/badge/toolkit-LGPL--3.0-green)

Current kit: **[camera-stack-dell-pro](camera-stack-dell-pro/)** — everything
below describes it. Additional kits will be listed here as they land.

## 🎯 The problem

*"Camera can't start." "We can't find your camera." "Teams doesn't see my camera."*

On Dell Pro laptops, the Intel MIPI camera stack breaks in ways a version check
can't see: Windows feature updates rebind devices to inbox drivers, leave
mixed-generation driver stacks behind, or strand firmware half-updated — and
once the camera device is gone, **Event Viewer records nothing at all**. The
only reliable evidence lives in PnP state, and by the time a ticket arrives,
nobody knows which layer failed.

## ✨ What this kit does

| Capability | How |
|---|---|
| **Detect** | Reads live PnP state: device problem codes, driver versions vs. target, firmware payload level, missing cameras, Frame Server errors — never event logs for the missing-device class (proven invisible). |
| **Classify** | A four-way verdict that separates *driver-outdated* from *camera-broken* from *disabled-by-choice* — because they have different fixes. |
| **Remediate** | Installs only when the camera is idle (consent-store streaming check), never prompts, never kills processes, never forces reboots. Restarts ride the user's own reboot; the old driver keeps the camera working until then. |
| **Clean up** | After binding, removes superseded driver packages from the store — the residue Windows feature updates leave behind and Dell's KB 000248760 blames for these tickets. |
| **Explain** | Dual-surface logging: a readable narrative log alongside machine-readable `key=value` lines, plus a per-machine JSON snapshot with pre/post diff. |

## 🚀 Quick start

```powershell
# Read-only health check — safe during calls, exits in seconds
powershell -File .\camera-stack-dell-pro\detection\detect.ps1
```

| Exit | Meaning | Action |
|---|---|---|
| 0 | healthy + current | leave alone |
| 1 | needs update | routine — next maintenance window |
| 2 | camera problem, drivers current | **not** this driver — dependency route (KB 000248760) |
| 3 | needs update AND broken | prime candidate — remediate now |

Deep-dive deployment (Intune Win32, Proactive Remediations, PSADT): see
**[camera-stack-dell-pro/README.md](camera-stack-dell-pro/README.md)** —
including a [case study](camera-stack-dell-pro/README.md#case-study-camera-dead-after-a-windows-feature-update)
of a camera broken by a feature update: which component was missing, why, when
it failed relative to the upgrade, and how remediation repaired it without
interrupting the user's Teams call.

## 📦 Repository layout

```
camera-stack-dell-pro/
├── detection/
│   ├── detect.ps1              Full diagnostic — the 2×2 verdict (exit 0–3)
│   ├── intune-detection.ps1    Intune Remediations detection script (exit 0/1)
│   └── intune-remediation.ps1  Intune Remediations remediation script
├── deployment/
│   ├── install.ps1             Bare installer (Intune Win32 / manual)
│   ├── app-detection-rule.ps1  Intune Win32 app detection rule
│   └── psadt-toolkit/          Complete PSAppDeployToolkit 3.10.2 with the
│                                wrapper installed (drop drivers in Files\,
│                                deploy via IntuneWinAppUtil or SCCM)
└── README.md                   Kit documentation: architecture, config, matrices
```

## 🖥️ Supported hardware

| Package | Models | Silicon |
|---|---|---|
| HW9TN A13 | Dell Pro 14 **Plus** (PB14250) | Arrow Lake + Lunar Lake |

Additional Dell Pro packages follow the same pattern — extending the kit is a
version-table swap in the detection scripts.

## ✅ Verification bar

Every claim above is anchored: healthy-camera and missing-camera branches run
on live hardware; the PSADT package boot-tested end-to-end in a VM via the
exact public-artifact path (three real packaging bugs caught that way); the
missing-camera-is-log-invisible finding established by controlled experiment.
Details and evidence in the kit README.

## 🧰 Requirements

- Windows 11 (build 26100+), PowerShell 5.1+
- Detection: any context (read-only). Installation: admin/SYSTEM.
- Driver payload from Dell's site (never committed here).

## 📄 License & credits

- Kit scripts: license not yet declared.
- `psadt-toolkit/` bundles [PSAppDeployToolkit](https://psappdeploytoolkit.com)
  3.10.2 unmodified (LGPL-3.0; see `COPYING.Lesser` inside the toolkit).
- Driver packages referenced: Dell HW9TN — property of Dell/Intel,
  distributed by Dell only.
