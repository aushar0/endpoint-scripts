# PSADT offline package — Calculator

`Deploy-Application.ps1` is the authored script for a PSAppDeployToolkit 3.10.1
package that installs Calculator (msixbundle + 7 dependency frameworks) fully
offline and fully silent. Assemble the package locally; the repo ships the
script, not the binaries or the toolkit.

## Assembly

1. Copy a stock PSAppDeployToolkit 3.10.1 package tree (AppDeployToolkit/,
   Deploy-Application.exe, Deploy-Application.exe.config, SupportFiles/).
2. Copy this `Deploy-Application.ps1` over the template.
3. Fetch the package set (current signed versions, SHA-1 verified at download)
   into `Files\Calculator\`:

```powershell
cd <msstore_links>
.\Get-MsStorePackageLink.ps1 9WZDNCRFHVN5 -Download -OutDirectory <package>\Files\Calculator
```

4. In `AppDeployToolkit\AppDeployToolkitConfig.xml` set
   `<Toolkit_RequireAdmin>False</Toolkit_RequireAdmin>` (the script is
   context-aware; standard-user runs are supported).

## SCCM

Create a **Package** (not Application - no detection method needed; the script
is presence-idempotent and exits 0 fast when the app is registered):

- Program: `Deploy-Application.exe -DeploymentType Install -DeployMode Silent`
- Run: whether or not a user is logged on (SYSTEM); user-context programs work
  equally (`-DeploymentType Repair` covers broken-but-present machines).

## Behavior

| Context | Install path |
|---|---|
| SYSTEM (SCCM default) | Provision machine-wide, then silently install for the signed-in console user via a hidden one-shot scheduled task (wscript launcher - no window, no UAC) |
| Elevated user | Staged fast-path (re-register without download) or ladder install |
| Standard user | Ladder install from Files |

Presence-idempotent: registered at any version = exit 0, nothing to do.
`-DeploymentType Repair`: re-register ladder for broken-but-present machines.
`-DeploymentType Uninstall`: per-user removal (+ deprovision when elevated).

Silent by design: no UAC, no windows, no dialogs in any context.

## Verification (2026-09-11/14)

Live-tested end to end: unelevated no-op / offline install / idempotent rerun;
Repair branch with in-use SKIP classification; SYSTEM via PsExec
(Deploy-Application.exe, the real SCCM invocation): provision completed +
console-user handoff repaired and registered the signed-in user, exit 0,
no visible windows. Six real bugs found and fixed across the test ladder
(RequireAdmin config, Show-InstallationWelcome parameter, provision parameter
set names, principal object, user-readable staging path, vbs quote count).
