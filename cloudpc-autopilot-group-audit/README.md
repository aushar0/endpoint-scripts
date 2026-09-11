# cloudpc-autopilot-group-audit

Some Windows 365 Cloud PCs never appear in a ZTDID-based Autopilot dynamic
group, while other Cloud PCs and all physical Autopilot devices are members.
The working explanation, consistent with Microsoft's documentation and with
field reports: the `[ZTDId]` stamp is written to a device's Entra ID object
at registration time, and a Cloud PC whose provisioning path did not apply
the stamp has nothing for a ZTDID rule to match. The group can never pick
it up, no matter how long the membership processor runs. The most likely
split is a provisioning-path difference: a different or older provisioning
policy, hybrid join, or a provisioning policy linked to Windows Autopilot
device preparation, which uses a different grouping model entirely.

This kit is a differential diagnosis, not a single-cause verdict for a
specific tenant: it ranks the known causes, gives the evidence that
decides between them, and includes an audit script that produces the
tenant-specific answer. **Tested status: parse-checked on Windows PowerShell
5.1 and logic-tested end-to-end against mocked Graph responses (all
branches, including the hybrid and device-preparation cases); live-tenant
execution pending — run it read-only first and sanity-check the output.**

Throughout, ZTDID and `[ZTDId]` refer to the same thing: the
`[ZTDId]:<guid>` entry in a device object's `physicalIds` property.

## The kit

| File | Purpose |
|---|---|
| `README.md` | This report: analysis, verification, remediation |
| `Find-CloudPcAutopilotGroupGaps.ps1` | Graph audit: diffs every Cloud PC against a named group and reports the attributes that narrow each missing device to a ranked cause |

## Symptom

A dynamic device group scoped to Autopilot-registered devices, with a rule
like:

```
(device.devicePhysicalIds -any (_ -startsWith "[ZTDId]"))
```

behaves inconsistently across Windows 365 Cloud PCs: most are members, a
subset never appears (not after a day, not after a week). Physical Autopilot
devices are unaffected. The assignments riding on that group (deployment
profiles, ESP, configurations) therefore miss the same subset every time.

## How each property lands on the device object

| Property | Value looks like | Written when | Documented use |
|---|---|---|---|
| `physicalIds` → `[ZTDId]:…` | `[ZTDId]:6e1fa5c3-…` | Autopilot registration: hash import, or an enrollment path that registers the device | Classic Autopilot dynamic groups |
| `model` | `Cloud PC; 8 vCPU; 32 GB…` | Windows 365 provisioning | "All Cloud PCs" dynamic groups |
| `enrollmentProfileName` | provisioning policy (or device-preparation policy) name | Enrollment | Per-policy dynamic groups; assignment filters |
| (none of the above) | — | Autopilot device preparation enrollment | Devices join an **assigned** group named in the policy; dynamic rules play no role in that flow |

Two anchors from Microsoft's documentation frame the problem:

1. The documented way to build a dynamic group of Cloud PCs does not use
   ZTDID at all. It keys on `device.model` (all Cloud PCs) or
   `device.enrollmentProfileName` (per provisioning policy).
2. Autopilot device preparation (which Windows 365 provisioning policies
   can link) uses *Enrollment Time Grouping*: devices are placed into an
   **assigned** device group during enrollment. Microsoft's FAQ positions
   this explicitly as replacing the dynamic-group queries that classic
   Autopilot requires.

The registration-time/no-backfill mechanic itself is not stated verbatim in
Microsoft's docs; it is inferred from how the attribute is written and is
consistent with practitioner reports (hybrid-joined machines converted to
Autopilot, and offline "faked-profile" joins, are reported to end up with
no ZTDID). Treat it as a strong hypothesis. The audit below confirms or
kills it per device in your tenant.

## Ranked causes for a partial miss

**1. Provisioning-path split.** The missing Cloud PCs were provisioned
under a different or older provisioning policy, before a policy change, or
via hybrid join. The stamp happens once at registration; existing objects
are not retrofitted by later policy edits.
*Deciding evidence:* the missing set correlates with provisioning policy or
provisioned-before date; `physicalIds` has no `[ZTDId]:`; hybrid objects
show `trustType = ServerAd`. Fits a gap that is stable and age- or
policy-shaped.

**2. Autopilot device preparation path.** Newer provisioning policies link
a device-preparation policy. Those enrollments are grouped by Enrollment
Time Grouping (assigned group named in the policy), and the
`enrollmentProfileName` property is populated with the device-preparation
policy name. A ZTDID rule never sees them.
*Deciding evidence:* `enrollmentProfileName` names a device-preparation
policy; the provisioning policy's Configuration tab shows a linked policy.
Fits a gap that started when device preparation was adopted.

**3. Compound rule clause.** An extra `and` condition (display-name prefix,
join type) that Cloud PCs fail while physical devices pass.
*Deciding evidence:* the device has `[ZTDId]:` but is still absent; re-read
the rule text. Fits any group whose rule is not the bare ZTDID query.

**4. Membership processing lag.** Dynamic groups re-evaluate
asynchronously; hours-scale delays are routinely reported. This cause only
explains brand-new devices that resolve within a day. Since the reported
symptom is devices missing for a week or more, this cause is already ruled
out for the standing gap; the audit keeps it for completeness.
*Deciding evidence:* `[ZTDId]:` present, membership appears on its own.

## Verify in your tenant

### Manual (one Graph call, run once per device)

Pick one missing and one present Cloud PC, and for each run:

```
GET https://graph.microsoft.com/v1.0/devices?$filter=startsWith(displayName,'<name>')&$select=id,displayName,model,trustType,enrollmentProfileName,physicalIds
```

(The URL is one line; rejoin it if your client wraps it.) Read the two
objects side by side:

- `[ZTDId]:` in `physicalIds`? Present-but-not-in-group points at cause 3
  or 4; absent points at cause 1 or 2.
- `enrollmentProfileName`: names the provisioning policy or a
  device-preparation policy (cause 2).
- `trustType`: `ServerAd` means the hybrid path (cause 1).
- `model`: confirms the object is a Cloud PC at all.

### Script (whole-tenant audit)

Requires the `Microsoft.Graph.Authentication` module. Consented scopes:
`Device.Read.All`, `Group.Read.All`. Read-only: the script makes no changes.

```powershell
.\Find-CloudPcAutopilotGroupGaps.ps1 -GroupName "Autopilot Devices" -CsvPath .\gaps.csv
```

The script pages all Entra device objects, isolates Cloud PCs by `model`,
joins them against the group's member list, and prints per device: ZTDID
present, in group, join type, enrollment profile, plus a summary that
narrows each cluster to the ranked causes, and the group's actual
membership rule for reference. `-CsvPath` is optional.

Decision table for the summary output:

| Observation | Conclusion |
|---|---|
| ZTDID present, not in group | Cause 3 (rule clause) or 4 (re-check after a day) |
| ZTDID absent, profile names a device-preparation policy | Cause 2 |
| ZTDID absent, `ServerAd` | Cause 1 (hybrid path) |
| ZTDID absent, correlates with older provision dates | Cause 1 (pre-change cohort) |

## Remediation options

**A. Widen the rule with the documented Cloud PC key (smallest change):**

```
(device.devicePhysicalIds -any (_ -startsWith "[ZTDId]"))
or (device.model -startsWith "Cloud PC")
or (device.model -startsWith "Windows 365")
```

Both model clauses are Microsoft's documented recipe for "all Cloud PCs"
groups. Note the blast radius: everything assigned to the group widens
with it, so review the assignment list before saving.

**B. Per-policy precision:** `device.enrollmentProfileName -eq "<provisioning
policy name>"` groups Cloud PCs by the policy that provisioned them. Useful
when different provisioning policies need different assignments.

**C. If the group feeds a device-preparation policy:** use the assigned-group
model it was designed around. The device group must be assigned-type and
owned by the *Intune Provisioning Client* service principal (AppID
`f1346770-5b25-470b-88bd-d5744ab7952c`, per the device-preparation
troubleshooting FAQ); dynamic rules play no role on that path.

**D. What is not supported:** retro-stamping ZTDID onto existing objects.
Registration happens at provision/enrollment time. Editing a provisioning
policy does not retrofit already-provisioned Cloud PCs, and hand-patching
`physicalIds` is unsupported (the "faked-profile" hacks some deployment
frameworks use are exactly that: hacks). Only reprovisioning recreates the
device object cleanly. Prefer A or B over reprovision churn.

## References

- [Create a dynamic device group containing your Cloud PCs (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-365/enterprise/create-dynamic-device-group-all-cloudpcs)
- [Create a dynamic device group for Cloud PCs from a specific provisioning policy (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-365/enterprise/create-dynamic-device-group-from-specific-policy)
- [Use Autopilot device preparation with Cloud PCs (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-365/enterprise/autopilot-device-preparation)
- [Windows Autopilot device preparation FAQ (Enrollment Time Grouping, assigned device groups) (Microsoft Learn)](https://learn.microsoft.com/en-us/autopilot/device-preparation/faq)
- [Windows Autopilot device preparation known issues (Microsoft Learn)](https://learn.microsoft.com/en-us/autopilot/device-preparation/known-issues)
