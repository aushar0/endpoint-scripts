# store-app-repair

**Purpose:** restore Store-app functionality on any Windows machine - no Store
access, no winget, no admin rights, and no pre-packaged files required.

Repair Windows Store apps (Calculator, Snipping Tool, and any free Store app) when
the app won't open or is missing and the standard fixes have already failed. The
typical case: *"This app can't open - check the Store for more info"*, the
standard `winget uninstall` / `winget install -s msstore` cycle has already run,
and the error persists.

## Why the winget reinstall didn't fix it

`winget uninstall` + `winget install` replaces the app's registration and removes
its data folder (re-created empty on reinstall). It never touches the framework
packages the app depends on (VCLibs, UI.Xaml, .NET Native, WindowsAppRuntime) -
those survive the reinstall. So if a framework is what's broken, the error
survives too. And if the app's own data was the problem, the winget cycle already
fixed it - persistence of the error after a reinstall points at the frameworks or
at something outside the app entirely. Windows also
refuses to remove a framework while apps still depend on it (`0x80073CF3` on
remove, listing the dependents), so "app present but broken" usually means a
corrupt registration, a per-user registration gap, or a version floor the installed
framework no longer meets - not a cleanly removed dependency.

## The manual fix (standard user, no admin required)

**Step 1 - read the real error.** The dialog is generic; the actual failure is in
the event logs. Event 628 in AppxDeployment-Server names a missing framework
directly:

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-AppxDeploymentServer/Operational' -MaxEvents 50 |
  Where-Object Message -match 'Calculator|ScreenSketch' | Format-List TimeCreated, Id, Message

Get-WinEvent -LogName 'Microsoft-Windows-TwinUI/Operational' -MaxEvents 20 |
  Where-Object Message -match 'Calculator|ScreenSketch' | Format-List TimeCreated, Message
```

Both logs are readable by a standard user.

**Step 2 - re-register the app and every dependency it currently resolves.** No
download, no package, uses the files already staged on disk. Expected hiccups
print as quiet `SKIP` lines (full error text still lands in a `%TEMP%` log for
escalation) - a red wall of `Add-AppxPackage` errors is not part of this block:

```powershell
$log = Join-Path $env:TEMP ("store-app-repair-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
"store-app-repair $(Get-Date) user=$env:USERNAME" | Out-File $log -Encoding utf8
foreach ($n in 'Microsoft.WindowsCalculator','Microsoft.ScreenSketch') {
  $p = Get-AppxPackage -Name $n -ErrorAction SilentlyContinue
  if (-not $p) { "SKIP   $n (not installed for this user)"; continue }
  $targets = @($p.Dependencies | Where-Object PackageFamilyName -ne $p.PackageFamilyName) + $p
  foreach ($pkg in $targets) {
    $errs = @()
    try {
      Add-AppxPackage -DisableDevelopmentMode -Register "$($pkg.InstallLocation)\AppxManifest.xml" -ErrorAction Stop
    }
    catch { $errs = @($_) }
    if (-not $errs) { "OK     $($pkg.Name) $($pkg.Version)" }
    elseif ("$($errs.Exception)" -match '0x80073D02|0x80073D06') {
      "SKIP   $($pkg.Name) (in use / newer already present - expected, harmless)"
      $errs.Exception.Message | Out-File $log -Append -Encoding utf8
    }
    else {
      "FAIL   $($pkg.Name) - details: $log"
      $errs.Exception.Message | Out-File $log -Append -Encoding utf8
    }
  }
}
"Details log: $log"
```

`SKIP` = the framework is in use by other running apps (`0x80073D02`) or a newer
copy is already registered (`0x80073D06`) - both are healthy states, not
failures. Only `FAIL` lines matter; those carry the real error in the log file.
Works for any Store app: swap the package names.

**Step 3 - if it still won't open:** reset the app's per-user state (settings and
cache), then re-check:

```powershell
Get-AppxPackage -Name Microsoft.WindowsCalculator | Reset-AppxPackage
Get-AppxPackage -Name Microsoft.ScreenSketch  | Reset-AppxPackage
```

**If Step 1 showed a truly MISSING framework:** VCLibs (UWPDesktop) has a
permanent Microsoft permalink that `Add-AppxPackage` will download directly:

```powershell
Add-AppxPackage -Path 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
```

There are no aka.ms permalinks for the other frameworks. For those, use the
repair script below, which fetches any missing framework from Microsoft's own
update channel at run time.

## Intune remediation pair

`detection.ps1` + `remediation.ps1` generalize the manual fix to any modern
app, as an Intune remediation (or any script runner):

```text
detection.ps1   scans every non-framework package registered for the signed-in
                user: unhealthy Status, or manifest-declared components that
                are missing / below the manifest's minimum version.
                Exit 0 healthy, 1 broken found.
remediation.ps1 same scan, then the no-download repair ladder: re-register
                app + components from staged files, Microsoft permalink for a
                missing VCLibs UWPDesktop, then re-check.
                Exit 0 repaired/healthy, 1 still broken (escalate to
                "The one-command option" for the download path).
```

Requirements: run in the **signed-in user's context** (Intune: "Run this
script using the logged on credentials") - AppX registration is per-user and
SYSTEM has no user profile to inspect. Optional `-FamilyName` parameter
restricts the scan to specific apps (e.g. the two shortcut apps). Detail log:
`%TEMP%\store-app-repair-remediation.log`.

Scan coverage notes: missing apps cannot be detected generically (nothing
defines what should be installed - use the one-command option for named
apps); framework packages are only evaluated through their dependents; the
version floor is checked against the best-installed copy of a component
(frameworks register per-architecture).

## Chaos matrix and failure taxonomy

The pair was chaos-tested: each failure class below was deliberately created
and the scripts' response verified. Every failure path names its cause -
never a bare error code.

| Chaos injected | Result | Verified |
|---|---|---|
| AppXSvc disabled by policy (registry) | Detection: `[ERR] AppXSvc is Disabled by policy - no Store app install or repair can run`, exit 1. (Trigger-started `Stopped` is the healthy resting state - gating on it would fail every healthy machine.) | yes |
| Exclusive lock on the remediation log | Remediation completes, exit 0 (log write loss accepted; stdout is the primary surface) | yes |
| Two remediations running concurrently | Named-mutex serializes; second instance waits 30s then fails loudly, never interleaved | yes |
| Named app absent but expected (`-FamilyName`) | Flagged `missing` with the no-download caveat instead of a silent healthy | yes |
| Component missing / below manifest floor | Synthetic-package tests cover both (the OS guards real framework removal) | yes (mock) |
| Unreadable manifest | Flagged `manifest_unreadable` with the diagnosis, never swallowed | yes (mock) |

Failure output taxonomy (applies to every FAIL/WARN/ERR line):
in-use by running apps (0x80073D02) - newer version already present (0x80073D06)
- dependency conflict (0x80073CF3) - access denied / ACLs / security software
(0x80070005) - name resolution blocked: DNS, hosts, VPN, proxy (12007) -
network unreachable or TLS blocked - required Windows service not running -
install rejected / entitlement (0x80073CF9) - anything unknown keeps its full
text plus HRESULT. The taxonomy narrows; it never hides.

## Blast radius

Per-user app state lives in `%LOCALAPPDATA%\Packages\<PackageFamilyName>`:
settings, history, sign-in state, app caches. What each step touches:

| Step | Touches | Destructive? |
|---|---|---|
| Step 2 re-register | Registration only | No. App data untouched; safe while apps run (in-use frameworks SKIP). |
| Step 3 `Reset-AppxPackage` | That one app's per-user data | Yes - resets Calculator history/modes, Snipping Tool preferences, stored sign-in for that app. |
| Repair script | Installs / re-registers the package | No - never removes or resets; worst case is `RESULT FAIL` + exit code. |
| winget uninstall/reinstall | The registration and the app's data folder | The data folder is removed and re-created empty; frameworks are untouched. |

Nothing here touches user documents, files saved outside the app container
(e.g. Pictures\Screenshots), other apps, or Windows itself. If Step 3 is
warranted on a machine where that app's settings matter, back the container up
first:

```powershell
Copy-Item "$env:LOCALAPPDATA\Packages\Microsoft.WindowsCalculator_8wekyb3d8bbwe" "$env:TEMP\calc-state-backup" -Recurse
```

## The one-command option

Single self-contained file, no dependencies, nothing pre-staged. At run time it
pulls fresh signed URLs from Microsoft's anonymous update channel (the same
channel a Store client uses), downloads with SHA-1 verification against
Microsoft's own digest, verifies every file is Authenticode-valid and
Microsoft-signed, installs, and verifies. Built-in apps: Calculator and Snipping
Tool by shortcut; any other free Store app by ProductId + expected
PackageFamilyName.

```powershell
# from an elevated or standard-user PowerShell, as the affected user:
.\Repair-MsStoreApp.ps1 -App calc            # Calculator
.\Repair-MsStoreApp.ps1 -App snip            # Snipping Tool
.\Repair-MsStoreApp.ps1 -App calc,snip       # both

# any free Store app (pin the family name - the catalog fuzzy-matches typo'd IDs
# to unrelated apps):
.\Repair-MsStoreApp.ps1 -ProductId 9WZDNCRFHVN5 -ExpectedFamilyName Microsoft.WindowsCalculator_8wekyb3d8bbwe

# detection contract for proactive remediations (exit 0 + stdout = present):
.\Repair-MsStoreApp.ps1 -App calc -DetectOnly
```

Behavior details that matter in the field:

- **Output contract.** Clipped narrative lines (`[INFO]/[WARN]/[ERR]`):
  reachability checks, per-app status ("Calculator healthy: version ...
  registered, all required components present"), each action taken, and a
  one-line `SUMMARY:` for the case record. A full timestamped log lands in
  `%TEMP%\MsStoreRepair\<stamp>_<user>_<mode>.log`.
- **Idempotent.** App registered at any version = "nothing to do", exit 0.
- **Staged-but-unregistered is detected and repaired with zero download** when
  elevated: after an uninstall the package often remains staged machine-wide; the
  script sees that state and re-registers from the staged manifest. (A standard
  user cannot see staged-only packages, so unelevated runs use the fetch path.)
- **Dependency over-provision is handled.** Store dependency sets are a union
  across architectures, and `Add-AppxPackage -DependencyPath` fails with
  `0x80073CF3 "provided but not used"` on machines that already satisfy part of
  the graph. The script retries bare, then installs frameworks standalone.
- **No licensing needed** for free apps without entitlement checks. Never use
  `-SkipLicense`-style workarounds for paid apps; those need real licenses.
- Exit codes: `0` repaired or already present, `1` input / family-name pin
  mismatch, `2` fetch failure, `3` signature gate, `4` install failure.
  Every outcome prints a `RESULT` line (detection contract).

## Elevation requirements (verified, not assumed)

| Session | What works |
|---|---|
| Standard user, no admin | Everything above. The manual blocks and the repair script's fetch+install lane are the default support path - have the affected user run them, no credentials needed. |
| Elevated admin | Same, plus staged fast-path repair and `-AllUsers` visibility in diagnostics. |
| NT SYSTEM (RMM / ConfigMgr push) | Per-user `Add-AppxPackage` is not usable: SYSTEM has no user profile, and this cmdlet set has no `-AllUsers` parameter (both verified live). Use the provision lane instead: `Add-AppxProvisionedPackage -Online -Path <bundle> -DependencyPath <deps> -SkipLicense` (machine-wide, registers users at next logon), or hand the per-user install to the console user's session from your deployment tooling. |

winget's msstore source requires Store metadata endpoints to resolve; when they
are blocked or broken it fails with `12007 / 0x80072ee7` and no packages are
found. The repair script's channel is independent of the Store endpoints.

## Failure classes covered

| Symptom / signal | Root cause | Fix |
|---|---|---|
| App present, `Status` not `Ok` | Corrupt registration | Step 2 re-register |
| Event 628 names a framework | Framework missing | VCLibs permalink or repair script |
| `0x80073CF3` on install | Dependency graph mismatch | Repair script's retry ladder |
| App reinstalls fine, still won't open | User state corruption | Step 3 `Reset-AppxPackage` |
| App missing after uninstall/PC reset | Staged, unregistered | Repair script (elevated = zero download) |
| Machine-wide AppX repository corruption | Deep OS damage | Escalation floor: in-place repair upgrade / reimage |

## Revert

Everything this kit changes is app-registration state plus temp files - no
services, settings, or system files. Capture the before-state first, then use
the undo table.

**Before-state capture** (run before any repair; standard user for the first
block, elevated only if the provision path may run):

```powershell
Get-AppxPackage -Name Microsoft.WindowsCalculator, Microsoft.ScreenSketch |
  Select-Object Name, Version, Status | Out-File "$env:TEMP\storeapp-before.txt"
Get-AppxProvisionedPackage -Online 2>$null |
  Where-Object DisplayName -match 'WindowsCalculator|ScreenSketch' |
  Select-Object DisplayName, Version | Out-File "$env:TEMP\storeapp-provisioned-before.txt"
```

**Per-change undo:**

| What a repair changed | How to undo |
|---|---|
| App installed / re-registered per-user | `Get-AppxPackage -Name <Name> \| Remove-AppxPackage` |
| App provisioned machine-wide (SYSTEM runs) | `Get-AppxProvisionedPackage -Online \| Where-Object DisplayName -match '<App>' \| Remove-AppxProvisionedPackage -Online` (elevated), then the per-user removal above |
| Dependency frameworks installed | **Leave them.** Frameworks are shared components; the OS refuses removal while any registered app depends on them (0x80073CF3, verified). They are inert when unused and Windows manages their lifecycle. |
| Step 3 `Reset-AppxPackage` (user state) | Restore the container backup taken beforehand (`Copy-Item "$env:TEMP\calc-state-backup\*" "$env:LOCALAPPDATA\Packages\Microsoft.WindowsCalculator_8wekyb3d8bbwe\" -Recurse -Force`) |
| Working files and logs | `%TEMP%\MsStoreRepair\` - delete freely |

Removing both apps returns the machine to the pre-kit state *minus* whatever
version the Store pushed meanwhile - re-running the original winget install
(or the Store) restores the current public version. There is no downgrade
path: the OS refuses version downgrades by design (0x80073D06).

## Testing

`tests/Repair-MsStoreApp.Tests.ps1` - 13 Pester tests covering the static
contract (parse, comment-based help, CMTrace log format, family-name pins,
regression tokens), healthy-box behavior (detect and no-op exit codes,
SUMMARY line, CMTrace log file), and error paths (unknown app, unpinned
ProductId). Paths resolve relative to the test file; the suite runs on any
clone.

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path tests/
```

## Verification status (2026-09-11, Windows 11 26200, single machine)

Design is field-shaped; validation to date is lab-grade, on one daily-driver
machine. Raw artifacts in `evidence/`.

| Verified live | Evidence |
|---|---|
| Full remove -> repair cycles, both apps, standard-user session (fetch, 8 files, SHA-1 digests matched, signatures valid, dependency ladder fired) | `evidence/repair-log.log` (CMTrace) |
| Detection contract both ways (exit 0 present / 1 missing) | `evidence/pester-run.txt` |
| Re-register ladder verbatim, including in-use skips (0x80073D02 classified SKIP) | same log |
| Elevated staged fast-path repair, zero download | this session, pre-v3.1 tool |
| Store blocked via hosts: winget fails 12007/0x80072ee7, repair channel unaffected | this session |
| `Add-AppxPackage -Path <URL>` from the aka.ms VCLibs permalink | fails 0x80073D06 only when a newer version is already installed (correct) |
| Framework-removal guard: OS refuses removal with dependents (0x80073CF3) | this session |

| Not yet verified | Status |
|---|---|
| SYSTEM branch (provision + console-user handoff) | Implemented per the documented DISM lane; the script emits a loud WARN when the path runs; awaiting one elevated run |
| Real state corruption | Could not be reproduced (the app tolerated a damaged state folder); `Reset-AppxPackage` verified as a cmdlet only |
| Cross-build (Win10 22H2/24H2), multi-user, fleet scale | Pending |

## Known limitations

- No concurrency guard: two runs at once (management service + user) can race.
- The DNS reachability probe has no timeout on name resolution.
- The dependency-ladder's standalone rung installs frameworks without checking
  the manifest's minimum-version floor (the diagnosis path does check it).
- The SYSTEM scheduled-task handoff pattern is environment-sensitive; treat it
  as single-build until cross-build tested.

## Sources

- Store-app fetch protocol: Microsoft's anonymous FE3 update channel (the same
  channel store.rg-adguard.net fronts; ported from the open-source StoreLib
  envelopes).
- The staged/missing-framework failure class and the DISM provision lane:
  documented field experience from the call4cloud "missing frameworks" writeup.
