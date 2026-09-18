# remote-help-sccm

> Microsoft Remote Help (attended support client) as a ConfigMgr / Software
> Center application — PSADT wrapper + one detection script that serves both
> SCCM and Intune.

PSAppDeployToolkit 3.10.x wrapper for the silent vendor bootstrapper, with a
SHA-256 payload pin, a post-install ground-truth check, an idempotent
uninstall, and a bitness-safe detection script with an optional version
floor. The deployment shape below targets an **Available** Software Center
deployment so machines only carry the client once a user opts in — matches
fleets that keep remote-assistance clients off endpoints by default.

**Status:** lab battery FULL PASS 2026-09-13 (install x2, repair, uninstall
x2, SYSTEM context — all exit 0, zero uninstall residue; detection
true-positive x3, true-negative x4). v1.1.x (2026-09-18): two-lane
installer acquire in the Lenovo-style folder layout (`Files\Download\`
runtime fetch + `Files\Fallback\` staged copy) — download-lane live probe
plus a 6-check acquire harness, all green (no install executed in that
pass; see [Test ledger](#test-ledger)). v1.2.0: readability pass — the
wrapper follows the stock 3.10.1 template layout (phase banners,
`## <Perform X tasks here>` markers, helpers in one section); zero
behavior change, harness re-run 6/6. Not lab-testable: tenant
authentication, licensing, and session behavior.

## Contents

| File | Role |
|---|---|
| `Deploy-Application.ps1` | PSADT 3.10.1 wrapper — install / repair / uninstall |
| `detection.ps1` | One detection script, portable across SCCM and Intune |
| `README.md` | This file |

No vendor binary is committed (repo convention). The installer is fetched
from Microsoft at package time — see below.

## Requirements

- A PSAppDeployToolkit 3.10.x toolkit tree (the `camera-stack-dell-pro`
  kit in this repo ships one, and `psadt-v4-migration` documents the v4
  route). This wrapper is the `Deploy-Application.ps1` that sits at the
  toolkit root.
- `remotehelpinstaller.exe` from <https://aka.ms/downloadremotehelp>
  (public, evergreen) — **either staged in the package's
  `Files\Fallback\` folder (offline-deterministic) or omitted entirely**:
  the download lane fetches it from the same link at deploy time into
  `Files\Download\`. The filename is coupled to the vendor-documented
  commands and must not change.
- Outbound HTTPS to `aka.ms` at deploy time, unless you stage the
  installer (see acquire lanes below).
- WebView2 Runtime — bundled by the installer when missing (and left
  behind on uninstall, by design).

## Build the package

```
<toolkit root>\
    Deploy-Application.ps1        <- this wrapper
    AppDeployToolkit\             <- stock PSADT 3.10.x
    Files\
        Download\                 <- created by the wrapper at deploy time
        Fallback\                 <- OPTIONAL staged copy (unarmed when empty)
            remotehelpinstaller.exe
```

If you stage the installer, verify the download against the pin in the
wrapper and update it if the evergreen link served a newer build:

```powershell
(Get-FileHash .\Files\remotehelpinstaller.exe -Algorithm SHA256).Hash
# wrapper pin: 9464BE6A86CFF2DB3548A298C2ED9979BECC343CB3C55A920E95D86B91D8147B
#              (5.2.1040.0, fetched 2026-09-13 — bump $expectedSha256 on swap)
```

The wrapper derives app version from the EXE at runtime; a version bump is
"swap the file, update the pin", nothing else to edit.

## Installer acquire — two lanes, two gates (Lenovo-style folders)

`$acquireStance` in the wrapper picks the lane order. Both lanes work out
of the package's `Files\` tree — `Download\` (created at runtime, where the
fetch lands, so the acquire evidence stays with the package in ccmcache)
and `Fallback\` (your staged copy; unarmed when empty):

- **`download-first` (default)** — fetch the current build from
  <https://aka.ms/downloadremotehelp> at deploy time with the OS-inbox
  `curl.exe`, landing it in `Files\Download\`. The gate is the
  **Authenticode signature** (status Valid and
  signer Microsoft Corporation), because the link rotates and a hash
  cannot pre-pin a rotating target. On any failure (network, proxy,
  signature) it falls back to the staged copy.
- **`local-first`** — the staged `Files\Fallback\` copy wins (gate =
  SHA-256 pin); download only when nothing is staged.
- **`local-only`** — never touches the network (air-gapped fleets).

Both lanes dead → exit **60005** (distinct from 60001 for triage), reason
in the PSADT log. The `RH_SUMMARY` digest line records which lane every
install used (`lane=download|local|local-fallback|download-fallback`).
Live-probed 2026-09-18: the link still served the pinned 5.2.1040.0 build
byte-identically, so both lanes currently converge on the same binary.

## ConfigMgr application shape

- **Application > Deployment Type:** Script Installer.
- **Install program:** `Deploy-Application.exe` (content = toolkit root;
  runs from ccmcache, no installation source path needed).
- **Uninstall program:** `Deploy-Application.exe -DeploymentType Uninstall`.
- **Detection method:** PowerShell script — paste the contents of
  `detection.ps1`. Paste from file, never from chat history
  (paste-mangling reads as not-detected).
- **Install behavior:** Install for system — runs as SYSTEM. Return codes
  0 / 1707 / 3010 / 1641 / 1618 map as success/reboot; wrapper failures
  surface as 60001-60009.
- **Deployment purpose:** Available (Software Center), device collection,
  no deadline. Users install on demand; rerun-if-failed is safe (the
  install is idempotent — in-place reinstall heals a stripped install).
- **Intune reuse:** wrap the same folder with IntuneWinAppUtil
  (setup file = `Deploy-Application.exe`), same detection script.

Required vs Available: the install itself is silent either way — the
policy question is whether every machine carries the client. This kit
defaults to Available because sessions are user-consented anyway and
uninstall is clean; a Required deployment to support-staff devices (the
helper side) plus Available for everyone is a working middle ground.

## Detection contract

`detection.ps1` — one script, both platforms:

- **INSTALLED** = exit 0 **and** stdout (`Remote Help <version>`) — stdout
  doubles as fleet version inventory.
- **ABSENT** = exit 0, silent. Never exit nonzero (SCCM reads it as
  script error; Intune reads it as reinstall-loop fuel).
- Anchor = `RemoteHelp.exe` on disk. The installer is a WiX Burn bundle
  with no MSI inside — no ProductCode/UpgradeCode identity exists, the
  file lane is the vendor-documented one.
- Bitness-safe: SCCM always runs script detection in 32-bit PowerShell
  (where `$env:ProgramFiles` = x86) — all three roots are probed.
- `$MinimumVersion` (default `''` = existence-only): set before pasting to
  enforce a floor. Numeric per-segment compare, no `[version]` casts
  (Constrained Language Mode safe). If you set a floor, use the installed
  EXE's 10.x series (see version split below), not the installer's 5.2.x.

## Vendor commands (case-sensitive)

```
remotehelpinstaller.exe /quiet acceptTerms=1                       # install
remotehelpinstaller.exe /uninstall /quiet acceptTerms=1            # uninstall
remotehelpinstaller.exe /quiet acceptTerms=1 enableAutoUpdates=0   # no self-update
```

The wrapper's `$updateStance` knob: `''` (default) = app-managed
self-update — recommended for a support tool that must stay current
enough to connect; `'disable'` = append `enableAutoUpdates=0` so the
deploy pipeline owns versions instead. Device-side evidence self-update
is on: the "Remote Help Automatic Updates" scheduled task ships Ready
after install.

## What the wrapper adds over the raw commands

- Two-lane installer acquire with per-lane gates (see above) — always
  installs the publisher's current build without package maintenance, or
  a pinned staged copy when the network lane is unavailable.
- Runtime identity: version derived from the EXE, zero edits on version
  swaps.
- Post-install ground-truth check: Burn bootstrappers are an
  exit-0-after-failure family — the wrapper exits 60008 if
  `RemoteHelp.exe` did not land despite a success code.
- Idempotent uninstall: absent binary = clean no-op exit 0; 60s
  grace-poll for the async Burn stub; WebView2 survival is logged, not
  chased.
- `RH_SUMMARY` log line per phase: one greppable line with
  deploymenttype / phase / version / lane / exepresent / service / arp /
  result.

## Attended vs unattended — different products

This package is the **attended** Remote Help client: helper and sharer
each sign in with organizational Entra accounts, sessions stay inside the
tenant, and the sharer consents. Unattended remote sign-in to Windows is
a different Microsoft stack (AVD agent + bootloader MSIs plus a Remote
Desktop settings profile and a custom RBAC role) — not a switch on this
package.

Tenant-side prerequisites (not install-time, and not in this kit):
enable Remote Help under Tenant administration (off by default), license
helpers **and** sharers (new licenses take 30 min - 8 h to activate — day-1
"app is broken" reports are usually this), RBAC for helpers (built-in
Help Desk Operator covers attended), optional Conditional Access via the
`RemoteAssistanceService` principal
(AppId `1dee7b72-b80d-4e56-933d-8b6b04f9a3e2`).

## Measured install surface (lab, 2026-09-13)

- Files: `C:\Program Files\Remote Help` — RemoteHelp.exe,
  RemoteHelpRDP.exe, RemoteHelpUpdater.exe, RHLogOff.exe, RhService.exe.
- Service: "Remote Help" (RhService.exe) — Running, StartType Auto,
  LocalSystem. It is resident after install; sessions still require both
  parties signed in and the tenant toggle enabled.
- Scheduled task: "Remote Help Automatic Updates" (Ready).
- ARP: Burn bundle entry in WOW6432Node, DisplayVersion 5.2.1040.0, with
  a working QuietUninstallString via the Package Cache bootstrapper.
- Run keys: none. No local config surface — configuration is
  tenant-side.
- **Version split:** installer/ARP say 5.2.1040.0 but the installed
  RemoteHelp.exe FileVersion reports 10.4.10008.1000 — detection stdout
  prints the 10.x series; set any `$MinimumVersion` floor in that series.
- Uninstall residue: none measured (files, service, task, ARP all
  clear).

## Caveats

1. Burn exit-0 lies — the #1 failure class; the wrapper's post-install
   binary check is the backstop. If SCCM shows success but the app is
   missing, read the PSADT log (`C:\Windows\Logs\Software`) `RH_SUMMARY`
   lines.
2. Flag case sensitivity — `acceptTerms` / `enableAutoUpdates` must be
   exact.
3. Filename coupling — must remain `remotehelpinstaller.exe`.
4. Two gates, one per lane — the download lane trusts the publisher's
   **signer** because the link rotates; the staged lane trusts the
   SHA-256 pin. Never mix them. Re-pin only a known-good download.
5. WebView2 residue after uninstall is by design.
6. Version floor re-offers the app on every version bump if set too
   tight — existence-only on rollout 1.
7. Intune route: device groups only; on co-managed fleets confirm the
   Client Apps workload actually delivers Win32 apps to the targets.
8. License activation lag (30 min - 8 h) masquerades as "app broken" on
   day 1.
9. A later unattended requirement = new build (AVD agent pair), not a
   switch here.
10. URL-filtered or proxied segments: a blocked download lane falls back
    to the staged copy; with nothing staged the wrapper exits 60005 with
    the reason in the log — expected on locked-down segments, not a
    package bug.

## Test ledger

- **STATIC 2026-09-13:** fingerprint = WiX Burn bootstrapper (`.wixburn`
  PE section), no embedded MSI, Authenticode signature Valid (Microsoft
  Corporation), FileVersion 5.2.1040.0, SHA-256
  `9464be6a86cff2db3548a298c2ed9979becc343cb3c55a920e95d86b91d8147b`.
- **STATIC:** both scripts AST-parse clean; PSADT function references
  validated against the local v3.10.2 reference (`Execute-Process` has
  no `-ExitCodes` parameter — the primitive is `-IgnoreExitCodes`).
- **DYN:** detection true-negative on a clean box (exit 0, empty
  stdout); version-compare unit tests 6/6 (including the 5.2.9 < 5.2.10
  trap).
- **DYN battery 2026-09-13, lab VM:** FULL PASS — preclean-uninstall →
  install → second install (idempotent) → repair (in-place heal) →
  uninstall (zero residue) → SYSTEM-context install, all exit 0;
  detection true-positive x3 (stdout `Remote Help 10.4.10008.1000`),
  true-negative x4. Environment label: lab VM, no EDR/WDAC, no tenant
  registration — install/uninstall/detection mechanics proven;
  app-auth/tenant behavior not testable in lab.
- **DYN 2026-09-18, acquire lanes (workstation, live network, no install
  executed):** download-lane probe against the evergreen link — 7,836,392
  bytes, Authenticode Valid / CN=Microsoft Corporation, SHA-256 identical
  to the staged pin, FileVersion 5.2.1040.0. Acquire-logic harness 6/6
  (the harness AST-extracts the shipped functions from the wrapper, so it
  executes this file's code, not a copy): download happy path, staged
  happy path with pin verified, tampered staged copy rejected by the pin,
  tampered download rejected by the signer gate and deleted, both lanes
  dead returns null (the 60005 path).

## Sources

- learn.microsoft.com/en-us/intune/remote-help/ (+ /deploy), fetched
  2026-09-13 (doc updated 2026-08-25).
- aka.ms/downloadremotehelp — served 5.2.1040.0 on 2026-09-13 (docs
  referenced 5.2.1037.0 from 2026-08-13; the link rotates).
- winget `Microsoft.RemoteHelp` exists but its manifest pins a 2025-03
  build — do not use it for current deployments.

## License

Wrapper derived from the PSAppDeployToolkit 3.10.1 Deploy-Application
template (LGPLv3, (C) 2024 PSAppDeployToolkit Team). Detection script:
[MIT](../LICENSE), same as the rest of this repository.
