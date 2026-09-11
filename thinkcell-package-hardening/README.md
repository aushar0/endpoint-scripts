# thinkcell-package-hardening

> Robust uninstall and a self-healing Add/Remove-Programs entry for the
> **think-cell** MSI — for fleets that package it with PS App Deploy Toolkit.

![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-lightgrey)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)

## The problem

Two behaviors of the think-cell MSI surprise packaging teams:

1. **Its ARP entry lives in WOW6432Node.** The MSI is a 32-bit package, so
   Windows Installer publishes the Uninstall key under
   `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{ProductCode}`
   — not the native 64-bit hive. Apps & Features shows it fine, but any
   inventory query or check that greps only the native path reports the app
   as missing.
2. **Registry-discovery uninstallers go blind without that key.** PSADT's
   `Remove-MSIApplications` finds products via the Uninstall keys; on a
   machine where the entry is absent (stripped, corrupted, or the install
   never completed), it reports nothing to remove — even though
   `msiexec /x` would work fine, because Windows Installer's own product
   registration is independent of the ARP hive.

## What's in the kit

- **`Uninstall-ThinkCell.ps1`** — standalone uninstaller anchored on the
  think-cell **UpgradeCode** (`Installer.RelatedProducts`), not the ARP keys
  or a version-specific ProductCode. Idempotent: `1605` ("not installed") is
  treated as success, so it's safe on machines that never got the app.
  Catches leftover ARP entries from releases with other ProductCodes,
  verifies both hives + the install dir afterwards, and optionally sweeps
  per-user data (`-CleanUserData`). Runs elevated. Log path resolution:
  explicit `-LogPath` wins; otherwise the PSADT toolkit's configured log
  folder (`configToolkitLogPath`) is picked up from scope when running
  inside a package — fleets that customize the PSADT log location get this
  log in their folder, where their log collection looks; stock
  `C:\Windows\Logs\Software` default only when standalone (and the
  directory is created if missing — it does not exist on clean Windows).
  Retries once after 30s on msiexec 1618 (installation-in-progress).
- **`Deploy-Application-additions.ps1`** — paste-ready block for the
  package's `Deploy-Application.ps1`:
  - ProductCode and ProductVersion are **derived at runtime from the single
    `.msi`** in `$dirFiles` (any filename — rename-proof; validated against
    the MSI's own `ProductName`; throws loudly on zero/multiple/wrong MSI).
    Version bumps become "swap the MSI in Files" — no GUID lookups, no
    stale hard-coded codes.
  - `Set-ThinkCellArpEntry` — ARP-entry insurance called from Post-Install
    and Repair: if the entry is missing from both hives it re-creates the
    full WOW6432Node entry, so registry-based inventory stays truthful.
    Idempotent, deliberately single-location (a native-hive mirror would
    duplicate the Apps & Features listing), **guarded** (skips unless the
    product is Installer-registered or binaries exist in the install dir —
    no ghost entries), and **dual-surface logged** (narrative lines plus
    `THINKCELL_ARP` key=value lines for post-mortem grep, all through PSADT
    `Write-Log` only, so toolkit-configured log locations just work).
  - Post-Uninstall cleanup loop for an entry the MSI uninstall might orphan.
- **`Invoke-ThinkCellPackageTest.ps1`** — one-shot elevated verification
  harness: extracts MSI properties, installs `/qn`, captures evidence
  (ARP entry in either hive, install dir, Office add-in keys, file versions),
  uninstalls, verifies cleanliness, and writes a paste-ready results file.

## Quick start

```powershell
# Uninstall on any machine (elevated), any installed release:
.\Uninstall-ThinkCell.ps1                 # add -CleanUserData for per-user dirs

# In the PSADT package (after $dirFiles is defined), paste the additions block,
# then in Post-Install / Repair-Title:
Set-ThinkCellArpEntry

# GUID-free idempotent uninstall line for the package itself (PSADT 3.10.1):
Execute-MSI -Action Uninstall -Path $msiPath -IgnoreExitCodes '1605'
```

## The complete package

`Deploy-Application.ps1` is the full PSADT 3.10.1 package script — ready to
drop into a standard toolkit scaffold (AppDeployToolkit/ + Files/ + the exe):
`$licenseKey` variable near the top (empty here; set at deploy time; format
`xxxxx-xxxxx-xxxxx-xxxxx-xxxxx`, passed to the MSI as `LICENSEKEY=`, accepted
at install time, validated in-app), MSI-derived identity, `Set-ThinkCellArpEntry`
insurance in Install/Repair, orphan cleanup in Uninstall,
`Show-InstallationWelcome -CloseApps 'powerpnt,excel'` in all three sections.

**PSADT 3.10.1 traps baked into this kit (each cost a live test to learn):**

- `Execute-MSI -Parameters` **replaces** the config's mode switches — including
  `/QN`. Passing custom MSI properties via `-Parameters` makes the MSI run
  **full UI even in Silent mode**. Custom properties go through
  `-AddParameters` (appends to the mode-appropriate defaults).
- The stock config's **Interactive default is `/QB-!` — a visible basic MSI
  window** on the user's desktop. This package forces `/QN` in EVERY mode via
  a deliberate full `-Parameters` replacement
  (`/QN REBOOT=ReallySuppress <fleet props>`), so the only user-facing UI is
  PSADT's own (welcome prompt); the raw msiexec window never appears.
- `Execute-MSI` has **no `-ExitCodes` parameter** in 3.10.1 (that's
  `Execute-Process`). Tolerating "not installed" (1605) on uninstall is
  `-IgnoreExitCodes '1605'`; 3010/1641 are already success-with-reboot.

Live-tested full cycle (Silent, elevated admin): install exit 0 with `/QN`
verified on the msiexec line, LICENSEKEY verified reaching the MSI
(`Property(S): LICENSEKEY`), repair exit 0 with the ARP entry intact,
uninstall exit 0 clean, and a second uninstall exit 0 (1605 ignored —
idempotent on machines where it never installed).

**NT AUTHORITY\SYSTEM tested** (PsExec `-s`, the SCCM context — not just
elevated admin): install / repair / uninstall / second-uninstall all exit 0,
log carries `context="NT AUTHORITY\SYSTEM"`, session-0 detection flipped the
run to NonInteractive exactly as under SCCM, and an Interactive-mode run
confirmed `/QN` on its msiexec line (no MSI window in any deploy mode).

**Post-mortem logging** (designed for handing the PSADT log to a human or an
AI as proof of what happened on the machine):

- Proper **phase prefixes** on every line — `[Pre-Installation]`,
  `[Installation]`, `[Post-Installation]`, same for Repair/Uninstallation —
  via the template's `$installPhase` convention (a compact script that omits
  them logs everything as `[Execution]`, which is what this kit originally
  did wrong).
- **`THINKCELL_SUMMARY`** — one greppable digest line per section:
  `deploymenttype= mode= phase= user= computer= productcode= version=
  licensekey=present|absent arp=present|absent result=success|failed-<code>`.
  The license key VALUE is never logged — presence only.
- **`THINKCELL_ARP`** decision lines (`action=recreate/noop/skip/
  remove-orphaned` with reasons) and **`THINKCELL_PERUSER
  localappdata_thinkcell_profiles=N`** census on uninstall (flags per-user
  shadow installs).
- Execute-MSI logs the full msiexec command line (proof of `/QN` and the
  fleet properties reaching the installer) and writes the MSI verbose log
  beside the PSADT log in the toolkit-configured folder.

## Evidence

All three pieces live-tested (Sep 2026, think-cell 14.0.38.764 / build 38764):
full install→uninstall cycles verified clean across both registry hives and
the install dir; MSI-derived ProductCode/version exact-matched the Property
table including from a renamed file; the ARP-insurance block passed
write-when-missing / no-op-when-present / no-native-duplicate /
exactly-one-enumeration / clean-removal checks.

Break-recovery matrix (the "installed but ARP entry deleted" state, recreated
live): maintenance reinstall from the same MSI restores the entry; `msiexec
/f {ProductCode}` repair restores it; the UpgradeCode uninstaller works with
no ARP key present (exit 0, fully clean); and the ARP-insurance block
re-creates it with vars derived from a single-MSI `$dirFiles`. Every recovery
path exits 0 — the broken state is self-correcting on the next install or
repair deployment.

## Notes

- **Office-open handling:** `Show-InstallationWelcome -CloseApps 'powerpnt,excel' -CloseAppsCountdown 3600`
  at the top of the Install, Uninstall, and Repair sections. The prompt only
  appears when those apps are actually running (silent otherwise), the MSI
  stays `/qn`, and the countdown lets required deployments complete on
  unattended machines. Keep the MSI's `SHUTDOWNPPT`/`SHUTDOWNXL` at their 0
  default so PSADT's prompt is the single closing mechanism.
- think-cell rotates its **ProductCode every release** but keeps a stable
  UpgradeCode — everything in this kit anchors on the stable side (UpgradeCode
  or runtime derivation), so nothing here needs bumping on a version swap.
- Per-user think-cell installs (user ran the vendor's EXE/portal installer)
  land in that user's `HKCU` + `%LOCALAPPDATA%` and **shadow** a per-machine
  install; SYSTEM-context tools cannot see or remove them. Those need a
  user-context uninstall.
