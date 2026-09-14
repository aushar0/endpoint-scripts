# audio-stack-dell-pro

Two drop-in detection/remediation pairs that reduce boot/logon cost from the
Cirrus Logic audio stack shipped with Dell Pro laptops (PB14250 generation,
SoundWire codec generation CS42L43): defer the vendor's background services,
and stop its logon companion process from launching, using mechanisms the
vendor's own package cannot undo.

Derived from static analysis of the vendor's public driver package (Dell
"Cirrus Audio Driver" 1.2.43 A06): every behavior claim below traces to the
package's own binaries, INFs, and MSI tables.

## Why this kit exists

The stack installs auto-start services and a machine-wide Run entry
(`clabp`) that launches a .NET companion process at every logon. Users get no
visible feature from that launch. Two properties of the vendor design shape
the whole kit:

1. **Deleting the Run entry is futile.** One of the services re-creates a
   missing entry (its binary carries the Run path, the entry name `clabp`, and
   a run-once gate). Windows' native disable mechanism - the
   `StartupApproved\Run` flag Task Manager uses - is honored at logon and is
   *not* re-enabled by the writer, because the writer only checks that the
   value exists. Flag, don't delete.
2. **Deferring CLConfigService is safe and useful.** It applies
   audio-processing configuration; nothing at boot depends on it, so
   Delayed-Auto removes it from the boot-critical window with no visible
   effect. The hardware mic-mute service (CsGMMuteSrv) is deliberately NOT
   deferred: it is a hotkey/LED handler with negligible start cost, and
   delaying it would only make the mute key unresponsive early after boot.

## The one policy

`detection.ps1` + `remediation.ps1` - a single Intune remediation covering both
levers. Detection collects every reason in one pass (services not delayed,
startup entry enabled) and exits 1 with a combined report-column line;
remediation fixes everything it can in one run and summarizes what it applied,
skipped, and failed. Exit 0 = compliant/N-A, 1 = remediate/failed - works
equally as a Nexthink remote-action payload.

## Design decisions worth knowing

- **Exact names, exact spellings.** A near-miss service name does not error -
  the remediation silently skips while detection keeps flagging the real
  service: an infinite remediation loop that reports success. Proven in a lab
  VM (the original two-service form's `CsMuteSrv` typo); test log ships in the
  kit's source workspace.
- **Manual/Disabled means compliant-and-untouchable.** A remediation that
  flips a Manual service back to Auto (delayed) resurrects things other
  tooling deliberately turned off. If your policy is "delayed-auto is the
  mandatory end state," change detection to flag non-Auto too - the pair
  must agree either way.
- **Dependent-service guard.** Remediation skips a service that has active
  dependents rather than deferring something in use.
- **Verify-after-apply.** Both remediations re-read actual state after the
  change and fail loudly if it did not take.

## Verification status (honest labels)

| What | Status |
|---|---|
| combined pair: all logic branches (stub services + stub Run entry, lab VM) | services loop + clabp loop validated individually; combined single-file form pending one staged probe |
| services pair: name-typo loop + Manual-resurrection failure modes | reproduced (original), fixed (this kit), fix branch re-validated pending one staged probe |
| startup pair: detect -> flag -> re-detect (byte-level flag check) | validated end-to-end |
| startup pair: entry stays disabled across reboots with writer service running | validated on target hardware (n=1) |

## Usage (Intune)

Create one remediation (Devices -> Remediations): upload `detection.ps1` and
`remediation.ps1`, run as SYSTEM, schedule as needed. On non-target hardware
detection exits 0 (N/A) by design.

## Credits

Vendor behavior documented here was established from the public Dell package
(Cirrus Audio Driver, ReleaseID 6RTMN) via static analysis only - no vendor
code was executed in producing this kit.
