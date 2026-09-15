# sign-context-menu

> Right-click any `.ps1` → **Sign with code-signing cert** — per-user, no admin,
> with the cert picked from your own Personal store.

![Platform](https://img.shields.io/badge/Platform-Windows%2011-lightgrey)
![Scope](https://img.shields.io/badge/Scope-Per--user%20registry-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)

A context-menu verb that runs `Set-AuthenticodeSignature` with full chain and an
RFC3161 timestamp, then verifies the result and refuses to call it success unless
the signature status is `Valid`. Built for engineers who sign scripts regularly
and are tired of pasting the same four lines.

## Files

| File | Role |
|---|---|
| `Install-SignContextMenu.ps1` | Registers the verb (HKCU, no admin). `-Uninstall` removes it. |
| `Invoke-SignPs1.ps1` | The worker the menu calls. `-Channel` picks the cert by Subject keyword (default `release`); single-cert fallback if nothing matches. |
| `monitoring_surface_check.ps1` | Optional pre-flight: read-only sweep of what a device enforces (execution policy, CLM, script-block logging, AppLocker, WDAC/SAC, EDR services). Run this FIRST on managed hardware. |

## Quick start

```powershell
# 1. (managed device?) see what policy actually enforces before installing
powershell -File .\monitoring_surface_check.ps1

# 2. install the verb
powershell -File .\Install-SignContextMenu.ps1

# 3. right-click a .ps1 -> Show more options -> "Sign with code-signing cert"
```

Multi-select works (one window per file). Windows 11 keeps custom verbs under
"Show more options" (Shift+F10).

## Verdicts

| Situation | Verdict |
|---|---|
| Cert in `CurrentUser\My`, no policy lock | ✅ Works as-is |
| AllSigned at MachinePolicy | ⚠️ Sign `Invoke-SignPs1.ps1` itself once from a console first, then the menu works |
| Constrained Language Mode | ❌ Worker breaks — the pre-flight will tell you |
| AppLocker script rules enforcing user paths | ❌ Blocked at policy level, no menu can fix that |

## Notes

- The verb registers at three points; the load-bearing one is
  `SystemFileAssociations\.ps1` (survives "Open with" re-associations, works
  even when .ps1 is associated to a Store app).
- Re-signing overwrites the old signature block (worker warns first).
- Sign LAST — editing the file after signing strips the block.
- Registry command embeds this folder's path; moving the folder = re-run the installer.
