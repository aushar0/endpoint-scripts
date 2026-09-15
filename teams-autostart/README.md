# teams-autostart

> Take new Microsoft Teams out of the boot path — completely, reversibly, and
> with receipts for why every other approach you've read about fails.

![Platform](https://img.shields.io/badge/Platform-Windows%2011-lightgrey)
![Intune](https://img.shields.io/badge/Intune-Remediations%20(user%20scope)-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)

New Teams (the `MSTeams_8wekyb3d8bbwe` MSIX) registers **two** autostart vectors
— the packaged startup task everyone knows and a classic `Run` entry almost
nobody mentions. Disable one and Teams still boots with the other. This kit
disables both the way Task Manager itself does, verifies the result across real
reboots, and documents — with screenshots — why the popular "delay it instead"
idea pops a Teams window in your users' faces.

**Start with the [case study](CASE_STUDY.md)** — the full mechanism, the three
findings that break naive scripts, and the launcher matrix (including the task
that reports success while doing nothing).

## Verdicts

| Goal | Verdict |
|---|---|
| No Teams at logon | ✅ **Works** — zero processes, zero windows, reboot-proven |
| Delayed launch, quiet (tray-only) | ❌ **No reliable mechanism** — the app's own autostart helper is gated on the native pipeline having run that logon (6 attempts documented); AUMID activation pops a visible window (screenshot-proven) |

## Quick start

All commands user-scope, no admin, reversible. Run on a device you're allowed
to change.

```powershell
# 1. See your current state (read-only)
powershell -ExecutionPolicy Bypass -File .\probe_teams_autostart.ps1
powershell -ExecutionPolicy Bypass -File .\probe_teams_run_vector.ps1

# 2. Disable both vectors (backs up originals to autostart_backup.json)
powershell -ExecutionPolicy Bypass -File .\test_disable_teams_autostart.ps1

# 3. Check state any time (also after a reboot)
powershell -ExecutionPolicy Bypass -File .\readback_teams_autostart.ps1

# 4. Undo — restore exactly what was there before
powershell -ExecutionPolicy Bypass -File .\test_disable_teams_autostart.ps1 -Revert
```

Fleet shape: wrap steps 2 and 3 as an Intune Proactive Remediation (user
context, daily). Detection must tolerate a missing `Run` value — Teams deletes
it itself sometimes. Case study §4 has the details.

## What's in the box

| File | Purpose |
|---|---|
| `CASE_STUDY.md` | The full investigation: mechanism, findings, receipts, limits |
| `probe_teams_autostart.ps1` | Read-only: package, manifest startup task, State key, Run/StartupApproved vectors, processes, AUMID |
| `probe_teams_run_vector.ps1` | Read-only: Run value data, StartupApproved flag bytes, alias, app config |
| `test_disable_teams_autostart.ps1` | The fix: disables both vectors Task-Manager-style; `-Revert` restores from backup; `-LaunchTest` proves the AUMID launch path |
| `readback_teams_autostart.ps1` | Post-reboot verification (State enum name, flag byte, processes) |

## How the claims were verified

Real reboot A/B arms on a checkpointed Windows 11 lab VM plus a production
Windows 11 device: vectors enabled → Teams running at logon; half-disabled →
**still running** (the single-vector trap, witnessed); both disabled → zero
Teams processes; delayed task → fired at logon+2:00 exactly and popped a
sign-in window (screenshots at +6/+60/+180 s). Console-session capture, not
window-title polling — titles miss unrendered WebView2 windows.

Known limits, stated in the case study §6: update-driven re-enable and
signed-in-user behavior were not exercised (a daily remediation cadence and a
pilot ring close both); the HKLM policy lever is doc-cited, not lab-tested.

## Conventions

- User-scope registry only (`HKCU`); nothing deleted — flag-disabled, the same
  reversible format Task Manager writes.
- Every command above was executed and its output verified before being
  documented.
- No vendor binaries; nothing tenant-identifying.
