<!-- doc-review 2026-09-15: three-lens gate (hiring-manager / principal-engineer / editor) + deslop pass. REDs fixed: evidence screenshots shipped (evidence/), mechanism claim downgraded to observed behavior, "not achievable" hedged to tested result, boot->sign-in normalized, glossary+TOC+file tree added. -->
# teams-autostart

> Stop Microsoft Teams from starting itself when users sign in to Windows —
> reversibly, with the test evidence for why every piece of the recipe is there.

![Platform](https://img.shields.io/badge/Platform-Windows%2011-lightgrey)
![Intune](https://img.shields.io/badge/Intune-Remediations%20(user%20scope)-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)

## What is this? (plain English)

When people sign in to Windows, Microsoft Teams starts by itself, quietly, and
sits in the notification area (the tray, by the clock). On many machines that
automatic start is one of the heaviest things happening right after sign-in.
This kit stops that automatic start — reversibly, using the same two switches
Windows itself uses. Teams is not removed or broken; anyone can still open it
normally, and it can be switched back at any time.

The kit also answers the question this investigation started with: **can you
delay the automatic start instead of stopping it?** Short answer: not quietly.
The long answer, with test evidence, is in the
[case study](CASE_STUDY.md).

| Goal | Verdict |
|---|---|
| No Teams at sign-in | ✅ **Works** — zero Teams processes, zero windows, proven across real reboots |
| Delayed start, quiet (tray only) | ❌ **No reliable mechanism** — 6 tested attempts documented; the app's own helper refuses to run once the native autostart is disabled |
| Delayed start that shows a Teams window | ⚠️ **Works, with a visible side effect** — a Teams window appears on screen (and takes focus) N minutes after sign-in |

## Who this is for

- **Intune / ConfigMgr admins** who want Teams out of the sign-in path across a
  fleet, or need to answer the "can we delay it?" question with evidence.
- **Anyone with one Windows 11 PC** who wants the same result locally. Every
  command runs in the logged-in user's context. No admin rights required.

## What you need

- Windows 10 or 11 with the current ("new") Teams installed — the app whose
  package name starts with `MSTeams_` (check with the probe scripts below)
- Windows PowerShell 5.1 or later (built into Windows)
- For the Intune deployment: a tenant where you can create Remediations
  (previously "Proactive remediations")

## Quick start

Copy the kit folder to the machine (or run from a share). Then:

```powershell
# 1. Look before touching - read-only report of how Teams starts itself here
powershell -ExecutionPolicy Bypass -File .\probe_teams_autostart.ps1
powershell -ExecutionPolicy Bypass -File .\probe_teams_run_vector.ps1

# 2a. RECOMMENDED - stop the automatic start (reversible)
powershell -ExecutionPolicy Bypass -File .\deploy_teams_autostart.ps1 -Mode Disable

# 2b. ALTERNATIVE - start Teams 5 minutes after sign-in instead.
#     Heads-up: a Teams window will appear on screen and take focus. There is
#     no way to do a delayed start quietly - CASE_STUDY.md section 3 explains
#     why, with screenshots.
powershell -ExecutionPolicy Bypass -File .\deploy_teams_autostart.ps1 -Mode Delay -DelayMinutes 5 -SmokeTest

# 3. Check the state any time (mode-aware; also valid after a reboot)
powershell -ExecutionPolicy Bypass -File .\detect_delay_drift.ps1

# 4. Undo
powershell -ExecutionPolicy Bypass -File .\deploy_teams_autostart.ps1 -Undo
powershell -ExecutionPolicy Bypass -File .\test_disable_teams_autostart.ps1 -Revert
```

What to expect: step 2a prints the two disabled vectors and finishes in under a
second. Step 2b also registers a scheduled task and (with `-SmokeTest`) starts
Teams once so you can see the task working. Step 3 prints
`compliant: vectors disabled, mode=...` and exits 0 when everything matches.

## How it works (the short version)

New Teams registers **two independent autostart vectors** (a "vector" here means
one self-start mechanism):

1. A packaged startup task named `TeamsTfwStartupTask`, controlled by a `State`
   value in the user's registry (`HKCU` — the part of the Windows registry that
   belongs to the logged-in user).
2. A classic `Run` registry entry that launches `ms-teams.exe` with a special
   argument, gated by a `StartupApproved` flag — the same bytes Task Manager
   writes when you toggle an app off.

Nearly every guide disables only the first one. Our testing showed Teams still
launches through the second. The deploy script disables **both**, using the
same values Task Manager writes, so nothing is deleted and the user can undo
it. Full mechanics, receipts, and the traps that break naive scripts:
[CASE_STUDY.md](CASE_STUDY.md).

## Files in this kit

```text
teams-autostart/
├── README.md                        <- you are here
├── CASE_STUDY.md                    <- the full investigation and evidence
├── deploy_teams_autostart.ps1       <- the deployer (-Mode Disable | Delay)
├── detect_delay_drift.ps1           <- Intune detection script (exit 0 = compliant)
├── probe_teams_autostart.ps1        <- read-only: how Teams starts itself here
├── probe_teams_run_vector.ps1       <- read-only: Run entry + flag details
├── test_disable_teams_autostart.ps1 <- manual disable, with -Revert
├── readback_teams_autostart.ps1     <- post-reboot state check
└── evidence/                        <- screenshots behind the case study claims
    ├── keyframe_6s_white_window.png     (+6 s: Teams window materializing)
    ├── keyframe_60s_signin_window.png   (+60 s: sign-in window, foreground)
    └── keyframe_180s_signin_window.png  (+180 s: still there, still focused)
```

## FAQ

**Will users still be able to open Teams?**
Yes. Nothing is removed or blocked. Teams opens normally when clicked; the kit
only stops the automatic start.

**Can this be undone?**
Yes, two ways: the `-Undo` / `-Revert` switches in this kit, or the user simply
re-enables "Microsoft Teams" under Settings → Apps → Startup (and inside Teams:
Settings → General → Auto-start). The deploy script's changes are the same
values those toggles write.

**Does it survive Teams updates?**
The disable state held across reboots and app launches in testing; Teams
*updates* were not exercised (stated in the case study §6). The daily
remediation cadence re-applies the state, which makes the unknown irrelevant.

**Can we delay it instead of stopping it?**
Only with a visible side effect: the delayed task works on a precise timer, but
Teams appears as a window on screen and takes focus (screenshots in
`evidence/`). A quiet delayed start — tray only, like the native behavior — is
the one thing this investigation could not achieve; section 3 of the case
study documents six attempts and why each failed.

**Why not just use a Group Policy?**
There is no per-app policy for packaged-app startup tasks. The machine-wide
policy that exists (`EnableFullTrustStartupTasks`) turns off autostart for
*every* packaged desktop app, not just Teams — documented but not tested in
this kit.

## Intune deployment

Remediations (user context, daily schedule):

- **Detection script:** `detect_delay_drift.ps1` — exits 0 when the device
  matches the deployed mode; exit 1 triggers remediation.
- **Remediation script:** `deploy_teams_autostart.ps1` with your chosen `-Mode`.
  Daily re-runs re-apply the state after Teams updates and keep the mode
  marker fresh.

Before/after, measure — don't assert: Task Manager → Startup apps impact, or
your endpoint analytics tool.

## Limitations

Stated in full in the case study (§6). Headline: the delayed-start
investigation ran with Teams unsigned-in (a signed-in pilot is the clean next
step), Teams *updates* were not exercised, and one machine-wide policy lever is
documented but not lab-tested.

## Conventions

- User-scope registry only (`HKCU`); nothing deleted — disabled by flag, the
  same reversible format Task Manager writes.
- Every command in this README was executed on Windows 11 (24H2 production
  device and 25H2 lab VM) before being documented.
- No vendor binaries; nothing tenant-identifying. Kit scripts: license not yet
  declared.
