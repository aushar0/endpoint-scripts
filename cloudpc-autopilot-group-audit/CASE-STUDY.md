# Case study: the Cloud PCs that never arrived

An incident-in-progress from a production Windows 365 estate, walked
through the differential in this kit. Findings are updated as evidence
lands; open slots are marked PENDING rather than guessed.

## The report

An Autopilot dynamic device group built on the standard ZTDID rule:

```
(device.devicePhysicalIds -any (_ -startsWith "[ZTDId]"))
```

covered most Cloud PCs but a subset never appeared, on any timescale.
Everything riding on the group (Autopilot profile assignment and the
configurations behind it) missed the same subset consistently. Physical
Autopilot devices were unaffected, which made the group rule itself look
correct: it was.

## Finding 1: the stamp is simply absent

Direct Graph inspection of the affected objects settled the first
differential immediately:

```
GET https://graph.microsoft.com/v1.0/devices?$select=id,displayName,model,trustType,enrollmentProfileName,physicalIds
```

The missing Cloud PCs have **no `[ZTDId]:` entry in `physicalIds` at
all**. Not a malformed value, not a different prefix: the attribute was
never written. That kills two causes on the spot:

- **Not processing lag.** Dynamic groups can only match on what exists;
  no amount of waiting writes a missing attribute.
- **Not a compound-rule clause.** There is no clause to fail; the primary
  ZTDID condition itself has nothing to match on.

What remains are the two registration-path causes: a provisioning-path
split (cause 1) or the Autopilot device preparation path (cause 2).

## Finding 2: which registration path, and did anything change?

The team's question was "it was working before, what changed?" That
splits into a cohort question: does the missing set correlate with a
date boundary (one change event) or with a provisioning policy (a
long-standing path difference nobody had noticed)?

Evidence being collected:

- **createdDateTime cohort split.** The audit script (v1.1) reports
  provisioning-date ranges for both cohorts and flags a clean
  before/after boundary, which is the signature of a change event such
  as a provisioning policy created or edited to use device preparation.
  Status: PENDING tenant run.
- **enrollmentProfileName mapping.** Each Cloud PC names the policy that
  provisioned it; device-preparation-linked policies are the cause-2
  fingerprint. Status: PENDING tenant run.
- **Intune audit logs** for provisioning-policy changes in the boundary
  window. Status: PENDING.

The 2026 context that makes cause 2 the leading suspect: Windows 365
rolled out Autopilot device preparation linking for Cloud PC
provisioning policies through 2025-2026, and adopting it enrolls Cloud
PCs through a grouping model (Enrollment Time Grouping into an assigned
group) where ZTDID is never written.

## Remediation direction

Whichever of the two remaining causes the evidence names, the remedy is
the same family, and the kit README carries the full options:

- widen the group rule with Microsoft's documented Cloud PC keys
  (`device.model`), accepting that every assignment on the group widens
  with it; or
- split Cloud PCs into `enrollmentProfileName`-based groups per
  provisioning policy, which also cleanly separates device-preparation
  Cloud PCs from classic ones.

Retro-stamping the missing attribute is not on the menu: registration
writes it once, at provision time, and hand-editing `physicalIds` is
unsupported.

## Status

- Confirmed: affected Cloud PCs lack `[ZTDId]` in `physicalIds`.
- Ruled out: processing lag; compound-rule clause.
- PENDING: cohort date split; enrollment-profile mapping; audit-log
  window; final cause call. This document is updated as each lands.
