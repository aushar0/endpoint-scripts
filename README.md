# endpoint-scripts

> A collection of Windows endpoint engineering kits — detection, deployment,
> and remediation tooling built for real fleets.

![Platform](https://img.shields.io/badge/Platform-Windows%2011-lightgrey)
![Intune](https://img.shields.io/badge/Intune-Win32%20%7C%20Remediations-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)

Each kit in this repository is self-contained: scripts, documentation, and any
packaging scaffolding needed to deploy it. Kits are independent — nothing in
one kit depends on another.

## Kits

| Kit | Purpose |
|---|---|
| **[camera-stack-dell-pro](camera-stack-dell-pro/)** | Detect and repair the Intel camera stack on Dell Pro laptops — post-feature-update breakage, misbound drivers, stale firmware — without disturbing users. Includes fleet-wide root-cause telemetry. |

(New kits are added as top-level folders and listed here.)

## Repository conventions

- **One folder per kit**, with the kit's README as its front door — problem,
  capabilities, quick start, deployment recipes, verification evidence.
- **README standard** (every kit, in reading order): tagline-first → badge
  row → problem statement before features → capability table with bold
  lead-ins → runnable quick start with exit-code table → annotated layout →
  prerequisites checklist → license/credits last.
- **No vendor binaries committed.** Driver packages and other redistributables
  are fetched from their publisher at deploy time and verified (Authenticate
  signer + hash where published).
- **Dual-surface logging** wherever a kit acts on a machine: plain-English
  narrative for operators, strict `key=value` lines for tooling, plus a
  per-machine JSON snapshot.
- **Vendor scaffolding** (e.g., the bundled PSAppDeployToolkit) stays
  unmodified in its own subtree with license intact.

## License

Kit scripts: license not yet declared. Bundled third-party components carry
their own licenses (see each kit's credits).
