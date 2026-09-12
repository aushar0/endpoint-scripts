# endpoint-scripts

> Windows endpoint engineering kits — diagnostics, repair, and deployment.
> Every kit carries its own tests, evidence, and revert path.

![Platform](https://img.shields.io/badge/Platform-Windows%2011-lightgrey)
![Enterprise](https://img.shields.io/badge/Enterprise-ConfigMgr%20%7C%20Intune%20%7C%20RMM-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)

A home for self-contained endpoint engineering kits. Each kit is independent —
scripts, documentation, and packaging scaffolding together — and each kit's
README is its complete story: the problem it solves, how to run it, how to
deploy it, and the evidence behind its claims.

## Kits

### [thinkcell-package-hardening](thinkcell-package-hardening/)

Robust uninstall + self-healing Add/Remove-Programs entry for the think-cell
MSI. Covers the two traps that bite packaging teams: the 32-bit MSI publishes
its ARP entry under WOW6432Node (native-hive-only inventory sees nothing), and
registry-discovery uninstallers go blind without that key. The uninstaller
anchors on the UpgradeCode so it needs no ARP keys and no version-specific
GUID; the PSADT additions derive ProductCode/version from the MSI at runtime,
so version bumps are just a file swap.

### [camera-stack-dell-pro](camera-stack-dell-pro/)

Repair for the Intel camera stack on Dell Pro laptops — the components that
Windows feature updates quietly break. One read-only check names the failing
component and the reason; remediation waits for the camera to be idle, fixes
the stack without a single prompt or forced reboot, and cleans up the driver
residue the update left behind.

*Start with the [case study](camera-stack-dell-pro/README.md#case-study-camera-dead-after-a-windows-feature-update):
a camera that died 11 hours after a feature update, diagnosed from PnP state
Event Viewer can't even see.*

### [cloudpc-autopilot-group-audit](cloudpc-autopilot-group-audit/)

Why some Windows 365 Cloud PCs never land in a ZTDID-based Autopilot dynamic
group: the stamp is written at registration time and never backfilled, so a
Cloud PC provisioned by a different path (older policy, hybrid join, or
device preparation) has nothing for the rule to match. Ranks the four
causes with the evidence that decides between them, and includes a Graph
audit script that reports the deciding attribute for every missing device.

*Start with the [case study](cloudpc-autopilot-group-audit/CASE-STUDY.md):
a subset of Cloud PCs whose Entra objects carry no ZTDID stamp at all,
walked through the differential with the tenant evidence that decides
between the two remaining causes.*

### [store-app-repair](store-app-repair/)

Repair Store apps (Calculator, Snipping Tool, any free Store app) when
*"This app can't open"* survives a correct winget uninstall/reinstall. The
winget dance only replaces the app registration; the frameworks and user
state it depends on are untouched. Three paste-ready blocks fix it as the
affected user with no admin rights, plus a self-contained one-command
repair script that fetches signed packages straight from Microsoft's own
update channel at run time — no Store, no winget, nothing pre-staged.

*Every command and script path in the kit README was executed and verified
on a live machine before shipping, including the no-Store reproduction
(hosts-blocked, winget dead, repair channel still working).*

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

Kit scripts: [MIT](LICENSE). Bundled components carry their own licenses
(see each kit's credits).
