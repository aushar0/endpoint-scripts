# endpoint-scripts

> Windows endpoint engineering kits — detect, classify, and remediate driver faults
> **without disturbing a single user.**

![Platform](https://img.shields.io/badge/Platform-Windows%2011-lightgrey)
![Intune](https://img.shields.io/badge/Intune-Win32%20%7C%20Remediations-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)

A home for self-contained endpoint engineering kits. Each kit is independent —
scripts, documentation, and packaging scaffolding together — and each kit's
README is its complete story: the problem it solves, how to run it, how to
deploy it, and the evidence behind its claims.

## Kits

### [camera-stack-dell-pro](camera-stack-dell-pro/)

Repair for the Intel camera stack on Dell Pro laptops — the components that
Windows feature updates quietly break. One read-only check names the failing
component and the reason; remediation waits for the camera to be idle, fixes
the stack without a single prompt or forced reboot, and cleans up the driver
residue the update left behind.

*Start with the [case study](camera-stack-dell-pro/README.md#case-study-camera-dead-after-a-windows-feature-update):
a camera that died 11 hours after a feature update, diagnosed from PnP state
Event Viewer can't even see.*

## Conventions

- One folder per kit; the kit's README is the front door.
- **README commands are executed and verified before shipping** — the same
  standard as code. A command that hasn't run doesn't get documented.
- **One evidence folder per package** (`<log root>\<app>-<version>-<deployment
  type>`): the kit's structured records plus every log the deployment
  generates — MSI logs, EXE installer logs, InstallShield response files
  (`.iss`) where used — alongside PSADT's own log.
- No vendor binaries committed — packages are fetched from the publisher at
  deploy time and verified (Authenticode signer + published hash).
- Dual-surface logging wherever a kit acts on a machine: a readable narrative
  log alongside machine-readable `key=value` lines and a JSON snapshot.
- Vendor scaffolding stays unmodified in its own subtree with license intact.

## License

Kit scripts: license not yet declared. Bundled components carry their own
licenses (see each kit's credits).
