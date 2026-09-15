<!-- doc-review pending: three-lens gate (hiring-manager / principal-engineer / editor) + deslop before team share. -->
# psadt-v4-migration

> Move PSAppDeployToolkit v3.10.x packages to the current 4.1.8 engine without
> touching your scripts: the official v3-compatibility template, pre-wired and
> verified, plus the migration map for everything that does not move by itself.

![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-lightgrey)
![PSAppDeployToolkit](https://img.shields.io/badge/PSAppDeployToolkit-4.1.8%20(v3%20compat)-8B1A1A)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%2F%207.4%2B-blue)

## What is this?

PSAppDeployToolkit 4.1.8 is the current stable release (January 2026). Its
"v3 template" is a v4 engine with a v3 compatibility layer: your existing v3
`Deploy-Application.ps1` scripts run on it unchanged, with the v3 function
names (`Execute-MSI`, `Execute-Process`, `Write-Log`, `Exit-Script`,
`Show-InstallationWelcome`, ...) translated to the v4 functions at runtime.

This kit contains that template, built from the official
[4.1.8 release](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/releases/tag/4.1.8)
asset `PSAppDeployToolkit_Template_v3.zip`, plus:

- a sample v3-style `Deploy-Application.ps1` showing the drop-in shape,
- a sample custom function inside the extensions stub,
- the config pre-set for compatibility mode (Classic dialogs).

The whole thing was exercised end-to-end on a test machine: install, custom
log path, and uninstall, all silent, 15/15 checks green (evidence below).

## The four questions

| You have (v3) | It goes (v4 compat template) | Notes |
|---|---|---|
| `Deploy-Application.ps1` | Package root, next to `Deploy-Application.exe` | Replace the shipped sample with yours. No edits required. |
| `AppDeployToolkit\AppDeployToolkitExtensions.ps1` (custom functions) | Same place: `AppDeployToolkit\AppDeployToolkitExtensions.ps1` | The template ships an empty stub with sections; paste your functions in, or overwrite the file with your v3 one. Dot-sourced automatically. |
| Banner PNG (`AppDeployToolkitBanner.png`) | `Assets\Banner.Classic.png` | Overwrite, keep the filename. PNG, 450 x 50 px. Classic dialogs only. |
| Logo ICO (`AppDeployToolkitLogo.ico`) | `Assets\AppIcon.png` | Overwrite, keep the filename. v4 consumes PNG, 256 x 256 px; export your ICO to PNG. Pointers live in `Config\config.psd1` (`Assets` section: `Logo`, `LogoDark`, `Banner`, `TaskbarIcon`; filename or Base64). |
| Custom log path (config.xml `Toolkit_LogPath`) | `Config\config.psd1` -> `Toolkit.LogPath` | Also `Toolkit.LogPathNoAdminRights` and `MSI.LogPath`. The old XML config is NOT read. |

## Custom log path in detail

v3 kept this in `AppDeployToolkit\AppDeployToolkitConfig.xml`. In v4 it lives
in `Config\config.psd1`:

```powershell
Toolkit = @{
    # Log path used for Toolkit logging.
    LogPath = '$envWinDir\Logs\Software'

    # Same as LogPath but used when RequireAdmin is False.
    LogPathNoAdminRights = '$envProgramData\Logs\Software'
}
```

Two rules:

1. **Use the toolkit's session variables, not PowerShell syntax.** The string
   is single-quoted and expanded by the toolkit: `$envWinDir`,
   `$envProgramData`, `$envSystemDrive`, `$envTemp` are valid. Writing
   `$env:WinDir` will not expand.
2. **Scripts that read `$configToolkitLogDir` need a two-line shim.** The v3
   engine defined that variable; the compat layer does not. The v4 equivalent
   is the session object:

```powershell
If (Get-Command -Name Get-ADTSession -ErrorAction SilentlyContinue) {
    [String]$configToolkitLogDir = (Get-ADTSession).LogPath
}
```

The sample `Deploy-Application.ps1` in this template uses exactly this shim,
then builds the per-package evidence subfolder
`<log root>\<AppName>-<AppVersion>-<DeploymentType>` on top of it.

Related keys: `Toolkit.LogToSubfolder` (one subfolder per package, based on
InstallName) and `Toolkit.LogToHierarchy` (`AppVendor\AppName\AppVersion`
tree) are built-in alternatives if you do not want the in-script pattern.

## Config translation map

| v3 `AppDeployToolkitConfig.xml` | v4 `Config\config.psd1` |
|---|---|
| `Toolkit_LogPath` | `Toolkit.LogPath` |
| `Toolkit_LogPath` (non-admin deployments) | `Toolkit.LogPathNoAdminRights` |
| `MSI_InstallParams` / `MSI_SilentParams` / `MSI_UninstallParams` | `MSI.InstallParams` / `MSI.SilentParams` / `MSI.UninstallParams` |
| `MSI_LogPath` | `MSI.LogPath` |
| `MSI_MutexWaitTime` | `MSI.MutexWaitTime` |
| `Toolkit_LogMaxHistory` / `Toolkit_LogMaxSize` | `Toolkit.LogMaxHistory` / `Toolkit.LogMaxSize` |
| `Toolkit_CompressLogs` | `Toolkit.CompressLogs` |
| `Toolkit_LogDebugMessage` | `Toolkit.LogDebugMessage` (verbose/debug toggles) |
| `Company` | `Toolkit.CompanyName` |
| UI dialog style | `UI.DialogStyle` (this template pins `Classic`; see below) |
| User-facing text (button labels, dialog strings) | `Strings\strings.psd1` (+ per-language subfolders) |

## Compatibility-mode facts worth knowing

- **Classic dialogs only.** The Fluent UI takes parameters (e.g. `SubTitle`)
  that v3 functions do not accept, and the banner is a Classic-only element.
  This template ships with `UI.DialogStyle = 'Classic'` for that reason.
- **Every v3 call works, and logs a deprecation notice.** The compat wrappers
  announce themselves in the log, once per call:

  ```text
  [Pre-Installation] :: The function [Execute-Process] has been replaced by
  [Start-ADTProcess]. Please migrate your scripts to use the new function.
  ```

  Harmless, but expect the log to be noisier on first runs.
- **No compat wrapper exists for:** `Get-RunningProcesses`,
  `Resolve-Parameters`, `Write-FunctionHeaderOrFooter`, `Show-WelcomePrompt`.
  **Removed entirely:** `Get-HardwarePlatform`, `Get-SchedulerTask`,
  `Set-PinnedApplication`. If a package uses these, it needs a small rewrite
  regardless of route. The full rename table is the
  [v4 function mapping](https://psappdeploytoolkit.com/docs/4.1.x/reference/v4-function-mapping).
- **`Files\` and `SupportFiles\` are unchanged** in position and behavior.
- **Version-pin discipline:** build templates only from the 4.1.8 release
  assets (`Template_v3.zip`) or `New-ADTTemplate`. The current dev branch
  (4.2.x) template pins `RequiredModules` to 4.2.0 and will mismatch a 4.1.8
  engine.

## Route 2 (later): native v4 conversion

When you are ready to drop the compat layer, the official
[PSAppDeployToolkit.Tools](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit.Tools)
module automates the rewrite:

```powershell
Test-ADTCompatibility -FilePath .\Deploy-Application.ps1 -Format Grid  # report first
Convert-ADTDeployment -Path .\PackageFolder                            # whole package
```

The converter does NOT carry over: custom variables, function declarations,
code outside the Install/Uninstall/Repair blocks, config.xml changes, or
customized assets. Extensions always move by hand. Treat its output as a
first draft and diff it.

## Quick start

1. Download this kit (or clone the repo) and take the `template` folder.
2. Drop your v3 `Deploy-Application.ps1` into the template root, replacing
   the sample.
3. Paste your custom functions into
   `AppDeployToolkit\AppDeployToolkitExtensions.ps1`.
4. Overwrite `Assets\Banner.Classic.png` and `Assets\AppIcon.png` with your
   branding (keep the filenames).
5. Set `Toolkit.LogPath` in `Config\config.psd1` if you use a custom log root.
6. Test from an elevated console:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Deploy-Application.ps1 -DeploymentType Install -DeployMode Silent
$LASTEXITCODE   # 0 = success
```

The toolkit log lands in `<LogPath>\<InstallName>_<DeploymentType>.log`
(CMTrace format). No log file at all means the script died before logging:
run the `.ps1` directly as above to surface the parse error.

## What was verified

Windows 11 (build 26200), Windows PowerShell 5.1, elevated, 2026-09-15.
Three silent runs against the exact template in this kit:

| Check | Result |
|---|---|
| Install (shipped config): exit code 0 | PASS |
| Toolkit log written to `C:\Windows\Logs\Software\` | PASS |
| Extensions stub dot-sourced (log line present) | PASS |
| Sample custom function output (`SUMMARY:` line) in log | PASS |
| v3 `Execute-Process` executed via compat wrapper | PASS |
| Per-package evidence subfolder `<App>-<Ver>-<Type>` created | PASS |
| `Toolkit.LogPath` repointed to a custom root: log + subfolder landed there | PASS |
| Uninstall: exit code 0, marker swept from all type-suffixed subfolders | PASS |

15 of 15 automated checks green. Named untested: the stock
`Deploy-Application.exe` launcher (the release binary is unsigned; the `.ps1`
path above is the local-test method, and SYSTEM contexts used by ConfigMgr /
Intune are unaffected), and Fluent dialog rendering (compat mode is
Classic-only by design).

## Kit layout

```text
psadt-v4-migration/
    README.md                     this file
    template/                     the deployable v3-compat package (PSADT 4.1.8)
        Deploy-Application.ps1    sample v3-style script; replace with yours
        Deploy-Application.exe    stock launcher
        AppDeployToolkit/         compat frontend + PSAppDeployToolkit module
            AppDeployToolkitExtensions.ps1   stub + sample custom function
        Assets/                   AppIcon.png, Banner.Classic.png (replace)
        Config/config.psd1        toolkit + UI config (DialogStyle pinned Classic)
        Strings/                  dialog text, 27 languages
        Files/                    your payload goes here
        SupportFiles/             your loose files go here
```

The template tree is the official 4.1.8 release asset with three changes:
the sample `Deploy-Application.ps1`, the sample function in the extensions
stub, and the `DialogStyle = 'Classic'` pin with its comment. Everything else
is byte-identical to the release, so future toolkit upgrades re-diff cleanly.

## License

PSAppDeployToolkit is LGPLv3; `COPYING.Lesser` ships inside
`template\AppDeployToolkit\`. Kit documentation is authored content of this
repository.
