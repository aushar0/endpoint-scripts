# HW9TN A13 camera stack - deployment package

Kit staged 2026-09-07; lives in the ausharCloud `endpoint-scripts` repo.

## What you are deploying (3 artifacts, 3 jobs)

| Artifact | Vehicle | Carries payload? | Job |
|---|---|---|---|
| `Drivers\` + `install.ps1` + `detection_rule.ps1` | Intune **Win32 app** (.intunewin) | YES (~400 MB tree, compresses to ~100 MB) | Installs the driver stack; re-runs are no-ops |
| `HW9TN_detect.ps1` (parent folder) | Intune **Proactive Remediation** (detection only) | no | Estate-wide camera-HEALTH monitor: the 2x2 (needs/broken) truth table, exit 0/1/2/3 |
| nothing | Nexthink RA (optional) | no | Instant "who needs it / who's broken" inventory via `[Nxt]::WriteOutputString` |

The Win32 app answers "is the driver current?" (its detection rule).
The Proactive Remediation answers "is the camera HEALTHY?" - including the
broken-but-current quadrant (ISH prerequisite / BIOS / hardware), which the
app can never catch. They are deliberately separate.

## Build steps (at package time)

1. `robocopy ..\extract\16299\Drivers .\Drivers /E`   (payload: x64\MIPI_Camera + USBIO + Vision, both ARL/LNL variants)
2. Wrap folder with Microsoft Content Prep Tool:
   `IntuneWinAppUtil.exe -c . -s install.ps1 -o . -a`
3. Intune Win32 app:
   - Install cmd: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1`
   - Uninstall cmd: none (driver rollback = `pnputil /delete-driver oem##.inf` per-driver; document if needed)
   - Detection rule: use script `detection_rule.ps1`
   - Return codes: 0 success; 3010 success + pending restart (**set restart
     behavior to "Nothing"** - the restart belongs to the user, never to us);
     1 = retryable (busy guard)
   - Install behavior: System
4. Assignment: Entra dynamic device group on the hardware model, e.g.
   `(device.deviceModel -eq "<exact model string>")` - pull the exact string
   from Intune > Devices > a PB14250 > Hardware > Model (do not guess).
   Schedule as Required; off-hours timing is only a first-pass-success
   optimization (busy guard makes daytime installs safe either way).

## Design decisions baked in

- **No forced reboot anywhere - restarts are user-paced, always.** The
  unsaved-work rule (Austin, 2026-09-07): nothing in this chain ever forces,
  schedules, or requests a machine restart on its own. If a device genuinely
  needs restart, install.ps1 exits 3010 with app restart behavior = "Nothing":
  the machine shows pending-restart in the Company Portal, the OLD driver keeps
  the camera working, and the new stack activates at the user's next natural
  reboot. The PR monitor is the aging queue: machines carrying problem code 14
  = pending restart population; anything stuck there for weeks = helpdesk
  nudge material, not a forced reboot. Installing during the day is safe for
  the same reason - busy guard defers, nothing user-visible happens.
- **No process killing, ever** (Austin's call, 2026-09-07): conferencing apps
  detected -> exit 1 -> Intune retries next cycle. Overnight schedule makes
  this a non-issue in practice.
- **Pre-extracted tree, not the Dell EXE**: full control, no DUP reboot
  ceremony, no SSID precheck binary (our detection rule already gates by model
  + version). Alternative lane (vendor-blessed): Dell Command catalog sync via
  Dell Command | Integration Suite in SCCM - zero custom packaging, less
  reboot control. Custom lane chosen for control + portfolio value.
- **Both ARL and LNL driver variants shipped** - pnputil stages all, Windows
  binds only matching HWIDs. Trim per-platform only if your estate is confirmed
  single-silicon.
- All scripts self-contained, $PSScriptRoot-relative; verified no
  profile-absolute paths.

## PSADT variant (Deploy-Application.ps1) - PATIENT-WAIT design

Final doctrine (Austin's call, 2026-09-07): **no Show-InstallationWelcome, no
prompts, no closing apps, no UI of any kind.** The deployment waits silently
for the camera to stop streaming, then installs. Both the PSADT wrapper and
bare install.ps1 use the same loop:

- Wait condition = camera NOT streaming (consent-store check). Lock screen /
  idle are not tested - they are just moments when the condition resolves;
  locked-on-a-call correctly reads busy.
- Poll every 10 min, short 45-min wait window (fits under Intune's DEFAULT
  60-min install timeout - no timeout-config dependency). Past the window:
  **exit 1618 = Intune "Fast retry"** - recorded as retry, never as failure;
  Intune's own cadence carries the long-term patience. (Alternative: keep any
  exit code and map it to Retry in the app's Return Codes table.)
- User-paced restart doctrine unchanged: 3010 + Company Portal pending, never
  forced. Payload at `.\Files\Drivers\x64\` (robocopy from the extraction).

## Model coverage (verified 2026-09-07)

HW9TN A13 = **Dell Pro 14 Plus PB14250 only**. Proven three ways: Dell's
compatible-systems page; mup.xml manifest (subsys 0CDC/0CF8 LNL, 0CE8/0CF7
ARL); the actual INFs (LNL iacamera64.inf lists ONLY SUBSYS_0CDC/0CF8, no
generic DEV_64A0 entry, no 0CE4 anywhere in the package). A Dell Pro 14
Premium PA14250 (LNL, SUBSYS_0CE41028 - verified from a live device) will
NOT bind these drivers: it needs its own sibling package. The whole
framework (detection / patient-wait install / health monitor) transfers to
it by swapping the version table - the Layer-1 regexes already match its
hardware IDs regardless of subsystem.

## GitHub transport (home -> work computer)

GitHub is the approved pipe (pastebin = blocked file-sharing). Setup is TWO
browser steps, then syncing is one command:

1. Create PRIVATE repo `endpoint-scripts` under mibu919 (office-safe name). DONE.
2. Auth = DEPLOY KEY (chosen over PAT: repo-scoped, no bearer token on disk, no
   expiration). Public key (generated 2026-09-07, comment endpoint-scripts-sync)
   added in repo Settings > Deploy keys - **"Allow write access" MUST be checked**
   (default is read-only; pushes fail with permission denied otherwise).
   Private key: ~/.ssh/id_ed25519_endpoint_scripts (dedicated, passphrase-less
   by design - opens exactly this repo, nothing else).
3. First sync: `powershell -File ..\sync_to_github.ps1 -Init`; after every
   script-editing session: same command without -Init. Commit history = the
   changelog Austin wants for "we change scripts all the time."

Work-machine retrieval (nothing installed, no token on the work box):
- Browser (github.com is approved): open repo > HW9TN > copy file contents, or
  Code > Download ZIP. Private repo + his normal browser login = fine.
- Or `git clone` if git exists there (auth via his GitHub browser login).

Rules baked in: this is the ausharCloud public tool repo — **no employer-specific
info ever** (org names, ticket refs, internal paths, environment details).
Hardware model names and public driver versions are fine — public knowledge,
no employer linkage. The sync script ENFORCES this with a pre-push OE guard
(fails the sync if employer strings appear). Scripts ONLY in the repo - never
the 415 MB Dell driver payload (Dell's copyrighted binaries; target machines
pull HW9TN from Dell directly); mirror lives at ~\repos\endpoint-scripts
OUTSIDE the zCode tree so zCode's local-only-git rule stays untouched.

## Open items

- [ ] Run detection + install once on a live PB14250: pins SSID SMBIOS field,
      firmware registry layout (CurrentFWVersion/TargetVersion/UpdateVersion),
      and exercises the problem-code branch no lab fixture can simulate.
- [ ] After that, add firmware-current check to detection_rule.ps1.
- [ ] ISH prerequisite check (package ImportantInfo requires Intel ISH driver
      installed first) - consider adding to detection as a pre-condition.
