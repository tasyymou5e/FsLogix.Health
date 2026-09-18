# FSLogixToolkit

PowerShell 7 module + menu-driven WPF dashboard for FSLogix health checks. **Default mode is Office
Containers (ODFC) only** — profile-container checks run only when you switch the container mode.

Requirements: PowerShell 7.4+ (latest stable at build time 7.6.6), Windows 11 24H2 / Windows Server 2025
or later (build 26100+). Runs as a standard user; checks that need admin return `Skipped`.

## Start

```powershell
# GUI (auto-runs Discovery + Office container health check on open)
pwsh -NoProfile -File .\Start-FSLogixToolkit.ps1

# GUI, relaunch elevated (UAC) for GPO/RSoP and other admin-only checks
pwsh -NoProfile -File .\Start-FSLogixToolkit.ps1 -RequestElevation

# Console health check + CSV/HTML reports
pwsh -NoProfile -File .\Start-FSLogixToolkit.ps1 -NoGui -OutputPath C:\FslReports

# One daily run (what the scheduled task executes)
pwsh -NoProfile -File .\Start-FSLogixToolkit.ps1 -Daily -OutputPath C:\FslReports
```

Launcher parameters: `-NoGui`, `-Daily`, `-ContainerScope ODFC|Profiles|Both`, `-Category`, `-Format Csv|Html|Both`,
`-OutputPath`, `-AllowInstall`, `-DownloadModules`, `-EnableDebugLogging`, `-Offline`, `-RequestElevation`.
Exit codes: 0 completed, 1 could not start, 2 Fail/Error results.

If the files were downloaded (zip), unblock them first: `Get-ChildItem -Recurse | Unblock-File`.

## Security

Install the toolkit in a folder that **only administrators can change**, for example `C:\Program Files\FSLogixToolkit`
(not `C:\Temp` or a user profile). The module loads every `.ps1` under `Private`/`Public` and the launcher puts `Modules\`
first on `PSModulePath`; when the toolkit runs elevated from a folder that standard users can write to, anyone with write
access could plant code that runs as administrator.

`Test-FslToolkitPathSecurity [-Path]` (Windows; `Skipped` elsewhere) reads owner and ACEs **by SID** on the toolkit root,
`Modules`, `Config`, `Public`, `Private`, `GUI` (and everything below them), `Start-FSLogixToolkit.ps1`,
`FSLogixToolkit.psm1` and `FSLogixToolkit.psd1`. It fails when the owner is not Administrators / SYSTEM / TrustedInstaller,
or when any other principal has an Allow ACE with a write-type right (WriteData/CreateFiles, AppendData/CreateDirectories,
WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership, and so
Write/Modify/FullControl, GENERIC_WRITE/GENERIC_ALL). CREATOR OWNER is accepted on inherit-only ACEs; Deny ACEs are ignored;
unresolvable principals count as unsafe. Each offending principal and its rights are listed. When the launcher runs
elevated and the check fails it prints a prominent warning (health checks continue; repairs refuse).

The check **detects** an unsafe folder, it does not protect against one: the launcher, the manifest and every file the
module dot-sources live in that same folder, so the module has already been imported — and, when elevated, already run
with administrator rights — by the time the warning is printed, and a principal who can write there can equally replace
`Start-FSLogixToolkit.ps1` itself. If you see the warning, treat that elevated session as untrusted: close it, verify the
files and start again from an admin-only folder. Deploying to an admin-only path is the only real mitigation.

## Run as a different user (smart card)

| Option | What happens |
|---|---|
| `-RequestElevation` / File > Relaunch Elevated (UAC) | Same account, elevated. Windows shows the UAC prompt (its own credential UI when you are not an administrator). |
| `-RunAsDifferentUser -RunAsUserName CONTOSO\adm-jdoe` / File > Relaunch as Different User (Smart Card) | `runas.exe /smartcard /user:<name>` starts PowerShell 7 as that account in a new console, where **runas asks for the smart card PIN**. Add `-RequestElevation` to elevate after sign-in. |

```powershell
pwsh -NoProfile -File .\Start-FSLogixToolkit.ps1 -RunAsDifferentUser -RunAsUserName 'CONTOSO\adm-jdoe' -RequestElevation
```

- The toolkit **never** asks for, reads, passes, logs or stores a password or PIN (no `Get-Credential`, no `/savecred`);
  Windows/runas handle them. Only the user name is remembered (`RunAsUserName` preference).
- The admin account has a **different user profile** (other `%LOCALAPPDATA%` preferences and default report folder), so the
  relaunch passes `-ContainerScope <current mode>` and, with `RunAs.PassReportRoot` (default true), `-OutputPath <current
  report folder>`. That account needs write access to the report folder.
- User name format: `DOMAIN\user` or `user@domain.tld` (no spaces, quotes or `%`). runas needs the **Secondary Logon**
  service (`seclogon`); the toolkit refuses clearly when it is missing or Disabled.
- `RunAs.SmartCardByDefault = $false` in `Config\Settings.psd1` omits `/smartcard` (runas then prompts for the password itself).
- The launcher prints the running account (`DOMAIN\User`) and whether it is elevated at startup.

## Modules folder

`Modules\` (next to `Start-FSLogixToolkit.ps1`) is put first on the **process** `PSModulePath` before the toolkit
module is imported (the launcher creates the folder if it is missing and writable). Registry/User/Machine
`PSModulePath` values are never changed. The dashboard background runspace and the daily scheduled task (which runs
`Start-FSLogixToolkit.ps1 -Daily`) use the same folder.

- **What goes there:** PowerShell Gallery modules from `Config\Prerequisites.psd1` (`Source = 'PSGallery'`, currently
  PSScriptAnalyzer for `Tests\Invoke-FslValidation.ps1`), saved by `Save-PSResource` as `Modules\<Name>\<Version>\`.
- **Download:** `.\Start-FSLogixToolkit.ps1 -DownloadModules` (then continues normally) or
  `Initialize-FslPrerequisites -AllowInstall [-Destination LocalModules|CurrentUser]`. If the folder is not writable,
  modules are installed for the current user instead.
- **Not downloaded:** `Storage`, `SmbShare`, `ScheduledTasks` are Windows inbox modules
  (`%SystemRoot%\system32\WindowsPowerShell\v1.0\Modules`), `CimCmdlets` / `Microsoft.PowerShell.Diagnostics` ship with
  PowerShell 7, and `Hyper-V` comes with a Windows optional feature. None of them is on the PowerShell Gallery
  ([module compatibility](https://learn.microsoft.com/powershell/windows/module-compatibility)); the toolkit never
  installs Windows features.

Prerequisite resolution per module: already loaded -> `Modules\` -> `PSModulePath` -> (inbox Windows modules)
import by manifest path from the Windows PowerShell module folder. Missing modules: required -> Fail, optional with a
toolkit fallback -> Info, optional without fallback -> Warn. See `Modules\README.md`.

## GUI menus

| Menu | Items |
|---|---|
| File | Export Current View (CSV/HTML), Export All Results (CSV/HTML), Export Diagnostic Bundle, Open Reports/Logs Folder, Exit |
| Discovery | Run Discovery, Image / OS, FSLogix Installation, Microsoft 365 Apps, Registry Settings, Group Policy, Storage Locations |
| Office Containers | Run All, Settings & Best Practice, Containers (size / last used), Storage Performance, Network Health, Logs & Events, Known Issues |
| Profile Containers | Same items — disabled in Office-only mode; *Enable Profile Container Checks…* switches mode to Both |
| Health Check | Run Full Health Check (current mode); Daily ▸ Run Now, View History, Schedule…, Remove Schedule, Open Daily Reports Folder |
| Tools | Prerequisites, Environment & Versions, Error Log, Debug Logging, Offline Mode |
| Options | Container Mode (Office only default / Profiles only / Both), Run Discovery at Startup, Run Health Check at Startup, Auto Refresh (Off/15/30/60 min) |
| Help | About, Command-line Usage |

Options are saved per user in `%LOCALAPPDATA%\FSLogixToolkit\preferences.json` (defaults in `Config\Settings.psd1`).

## Daily health checks

```powershell
Import-Module .\FSLogixToolkit.psd1
Register-FslDailyHealthCheck -At '06:00' -ContainerScope ODFC -RunAs System   # System requires elevation
Get-FslDailyHealthCheck
Get-FslDailyHistory -Days 30
Unregister-FslDailyHealthCheck
```

Each run writes `Reports\Daily\yyyy-MM-dd\` (CSV, HTML, `Summary_HHmmss.json` with counts and new issues since
the previous run). Day folders older than `Daily.RetainDays` (30) are pruned.

## Repairs

Repairs are **opt-in, elevated, one run at a time** and only ever apply a state Microsoft documents. Preview first,
apply second, undo if needed. The daily scheduled task never runs repairs.

```powershell
# 1. Preview (read-only; standard user may run it, but see "Group Policy" below)
pwsh -NoProfile -File .\Start-FSLogixToolkit.ps1 -RepairPlan
Import-Module .\FSLogixToolkit.psd1; Get-FslRepairPlan | Format-Table ActionId, Status, Target, CurrentValue, ProposedValue, RiskTier

# 2. Check the gates for the actions you picked
Get-FslRepairPlan | Test-FslRepairPrerequisite | Format-Table Check, Status, Target, Message

# 3. Apply (elevated). -WhatIf changes nothing and still writes a run log
pwsh -NoProfile -File .\Start-FSLogixToolkit.ps1 -Repair -ActionId FIX-SVC-01 -WhatIf
pwsh -NoProfile -File .\Start-FSLogixToolkit.ps1 -Repair -ActionId FIX-SVC-01 -ChangeReference 'CHG0012345'

# 4. Undo a run (or one action of it)
Get-FslRepairLog -Days 7 | Format-Table StartedAt, Mode, RunId, ActionCount, Fail
pwsh -NoProfile -File .\Start-FSLogixToolkit.ps1 -UndoRunId <run id>
```

Commands: `Get-FslRepairPlan`, `Test-FslRepairPrerequisite`, `Invoke-FslRepair`, `Undo-FslRepair`, `Get-FslRepairLog`.
Launcher: `-RepairPlan`, `-Repair -ActionId <id[]>`, `-UndoRunId <guid>`, `-MaxRiskTier`, `-AllowDisruptive`,
`-ChangeReference`, `-ArchivePath`, `-RepairUserName`, `-UserSignedOutConfirmed`, plus `-WhatIf` / `-Confirm:$false`.
**Exit code 3 = refused by the pre-flight gates (nothing was changed)**; 2 = a repair failed or did not verify.

### Actions (`Config\Repairs.psd1`, every entry with its Microsoft source)

| ID | Condition | Change | Scope | Tier | Undo |
|---|---|---|---|---|---|
| FIX-SVC-01 | `frxsvc` start type is not Automatic | set Automatic | General | 2 | restore start type |
| FIX-SVC-02 | `frxsvc` Stopped while Automatic | one `Start-Service` (never stop/restart) | General | 1 | none (recorded) |
| FIX-SVC-03 | `frxccds` start type is not Automatic / stopped | set Automatic, start only after `frxsvc` is Running | General | 2 | restore start type |
| FIX-SVC-04 | `defragsvc` or `smphost` **Disabled** | Disabled → Manual only (Automatic left alone) | General | 2 | restore Disabled |
| FIX-LOG-01 | `LoggingEnabled` = 0 (all logs off) | remove the value (documented default 2) | General | 2 | restore the value |
| FIX-LOG-02 | operator needs verbose logs | `LoggingLevel` = 0 **temporarily** (expires after `Repair.TemporaryLoggingMaxHours`) | General | 1 | restore / remove |
| FIX-LOG-03 | `LogFileKeepingPeriod` > 180 | set 180 (documented maximum) | General | 2 | restore the value |
| FIX-LOG-04 | `RobocopyLogPath` present | remove ("troubleshooting only") | General | 2 | restore the value |
| FIX-ODFC-01 | ODFC `RefreshUserPolicy` ≠ 0 | set 0 under `HKLM\SOFTWARE\Policies\FSLogix\ODFC` only | ODFC | 2 | restore the value |
| FIX-ODFC-02 | operator picks a user with a corrupt Office container | archive the container file; FSLogix creates a new one at next sign-in | ODFC | 3 | move back (only if no new container exists) |

`FIX-SVC-03`, `FIX-LOG-02` and `FIX-ODFC-02` are operator-selected: they appear only when you name them in
`-ActionId`. (`FIX-SVC-03` because this host has no Cloud Cache, so a disabled `frxccds` may be deliberate.)
Risk tiers: 0 read-only · 1 reversible low risk · 2 persistent config change with backup · 3 disruptive.
Default maximum is tier 2 (`Repair.MaxRiskTierDefault`); tier 3 also needs `-AllowDisruptive`, a `-ChangeReference`
and, for the container reset, `-UserSignedOutConfirmed`.

### Group Policy on this image

FSLogix settings here come from **Local Group Policy**, so a registry repair would be undone at the next policy
refresh. The toolkit therefore never writes a value that Group Policy delivers:

* `Source = GroupPolicy` → the action is **GuidanceOnly**: change it in
  `gpedit.msc > Computer Configuration > Administrative Templates > FSLogix`, run `GPUPDATE /Target:Computer /force`
  and plan again (the registry is not touched);
* `Source = Unknown` (not elevated, or the computer RSoP query failed) → the action is **Blocked**. Run elevated so
  provenance can be checked;
* `Source = Registry` (elevated, RSoP succeeded, no winning policy entry) → the action may be applied.

`Registry` means *no winning RSoP entry was found*, not *proven not to be Group Policy*: whether values delivered by
**Local** Group Policy appear as RSoP registry entries is still a lab item on this image. Before you rely on a
registry repair, check in `gpedit.msc` that the setting is **Not Configured**; otherwise the next policy refresh
re-applies the policy value over the repair (the G8 pre-flight Pass says the same).

Service repairs are unaffected by Group Policy provenance (but a baseline that disables `defragsvc`/`smphost` will
set them back — check your baseline).

### Pre-flight gates (no `-Force` bypass)

G1 Windows + PowerShell 7.4+ · G2 elevated · G3 toolkit folder is admin-only (`Test-FslToolkitPathSecurity`) ·
G4 no file still carries `Zone.Identifier` · G5 FSLogix installed and version readable · G6 per-action version gate ·
G7 action scope fits the container mode (Profiles actions are not run in ODFC mode) · G8 Group Policy provenance ·
G10 the container file is not in use · G12 maintenance window (informational) · G13 change reference ·
G14 admin-only rollback store available · G15 free disk space · G16 before-state snapshot · G17 plan freshness and
drift · G18 single-run lock · G21 post-change verification. Session enumeration (G9) is **not** implemented: the
container reset relies on the exclusive-open test plus your `-UserSignedOutConfirmed` attestation.

### Logs, undo store and install requirements

* Readable copies: `Reports\Repair\yyyy-MM-dd\Repair_HHmmss_<RunId8>.log | .json | .csv` (redacted; kept for
  `Repair.RetainDays`, 180 by default). Read them with `Get-FslRepairLog [-IncludeRecords]`.
* Authoritative undo store: `%ProgramData%\FSLogixToolkit\RepairState\<RunId>\rollback.json` + `manifest.sha256`,
  **administrators only**. The before state is written and hash-verified *before* each change; a run whose temporary
  change was never undone is never pruned.
* Undo refuses when the store fails its hash check or when the current state is no longer the state the repair left
  behind (drift) - it never guesses.
* A change that does not verify is **never** rolled back automatically; the record tells you to run `Undo-FslRepair`.
* Repairs require the admin-only installation described under [Security](#security): the rollback store, the run lock
  and gate G3 all refuse to work from a folder that standard users can change.

## Module commands

Core: `Initialize-FslSession`, `Initialize-FslPrerequisites`, `Get-FslErrorLog`, `Export-FslErrorLog`, `Test-FslElevation`,
`Get-FslPreference`, `Set-FslPreference`, `Get-FslContainerMode` ·
Discovery: `Get-FslDiscovery`, `Get-FslDiscoveryReport` ·
Environment: `Find-FslInstallation`, `Get-FslLatestVersionInfo`, `Get-FslEnvironment` ·
Policy: `Get-FslEffectiveSetting`, `Get-FslGpoReport`, `Get-FslStorageLocation` ·
Best practice: `Invoke-FslBestPracticeAnalyzer` ·
Containers: `Get-FslContainer`, `Get-FslContainerReport` ·
Performance: `Test-FslStoragePerformance` · Network: `Test-FslNetworkHealth` ·
Maintenance (CLI only, `-WhatIf` supported): `Invoke-FslContainerShrink`, `Remove-FslStaleContainer` ·
Diagnostics: `Get-FslLogSummary`, `Get-FslKnownIssue`, `Export-FslDiagnosticBundle` ·
Reporting: `Invoke-FslHealthCheck`, `Export-FslReport`, `Show-FslDashboard` ·
Daily: `Invoke-FslDailyHealthCheck`, `Get-FslDailyHistory`, `Register-FslDailyHealthCheck`, `Unregister-FslDailyHealthCheck`, `Get-FslDailyHealthCheck`

## Folders

`Config` settings and Microsoft-sourced data (best practices, known issues, versions, prerequisites) ·
`Public` / `Private` functions per area · `GUI` XAML · `Modules` downloaded PowerShell Gallery modules · `Logs` toolkit logs · `Reports` exports and daily runs ·
`Tests` validator (`Invoke-FslValidation.ps1`, PSScriptAnalyzer) · `Docs` build contract.

## Troubleshooting

### Prerequisite "Storage / SmbShare / ScheduledTasks not found"

These are inbox Windows modules in `%SystemRoot%\system32\WindowsPowerShell\v1.0\Modules`. PowerShell 7 does not add
that folder itself; it comes from the Machine `PSModulePath` value or the environment inherited from the program that
started `pwsh` ([about_PSModulePath](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_psmodulepath)).
When the folder is missing from `PSModulePath`, the toolkit imports those modules by manifest path, appends the folder
to the process `PSModulePath` for that session and reports it in the prerequisite Message. To fix the environment
itself, restore `%SystemRoot%\system32\WindowsPowerShell\v1.0\Modules` in the Machine `PSModulePath` (REG_EXPAND_SZ,
see about_PSModulePath) or fix the launcher/agent that passes a trimmed `PSModulePath`, then start a new `pwsh`.
`Hyper-V` is only present when the Hyper-V management PowerShell feature is installed (optional; diskpart is used
otherwise).

Read-only diagnostic (changes nothing):

```powershell
# FSLogixToolkit module-path diagnostic. READ-ONLY: reads environment, registry and files; changes nothing.
$ErrorActionPreference = 'Continue'
"=== Host ==="
"PSVersion      : $($PSVersionTable.PSVersion)  Edition: $($PSVersionTable.PSEdition)  OS: $($PSVersionTable.OS)"
"PSHOME         : $PSHOME"
"Is64BitProcess : $([Environment]::Is64BitProcess)"
"LanguageMode   : $($ExecutionContext.SessionState.LanguageMode)"
"CommandLine    : $([Environment]::CommandLine)"
try { $p = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
      $pp = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction Stop
      "ParentProcess  : $($pp.Name) (PID $($pp.ProcessId)) $($pp.CommandLine)" } catch { "ParentProcess  : <unavailable> $($_.Exception.Message)" }

"`n=== PSModulePath (process, split) ==="
$sys32Modules = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\Modules'
$env:PSModulePath -split [IO.Path]::PathSeparator | ForEach-Object { '{0,-6} {1}' -f ($(if (Test-Path -LiteralPath $_) {'[ok]'} else {'[miss]'})), $_ }
"System32 modules folder : $sys32Modules"
"  exists                : $(Test-Path -LiteralPath $sys32Modules)"
"  on process PSModulePath: $([bool](($env:PSModulePath -split ';') | Where-Object { $_.TrimEnd('\') -ieq $sys32Modules.TrimEnd('\') }))"

"`n=== PSModulePath by scope (expanded) ==="
foreach ($scope in 'Process','User','Machine') { "{0,-8}: {1}" -f $scope, [Environment]::GetEnvironmentVariable('PSModulePath', $scope) }
"`n=== PSModulePath registry (unexpanded) ==="
try { $k = Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction Stop
      "HKLM: $($k.GetValue('PSModulePath', '<not set>', 'DoNotExpandEnvironmentNames'))" } catch { "HKLM: <error> $($_.Exception.Message)" }
try { $k = Get-Item -LiteralPath 'HKCU:\Environment' -ErrorAction Stop
      "HKCU: $($k.GetValue('PSModulePath', '<not set>', 'DoNotExpandEnvironmentNames'))" } catch { "HKCU: <error> $($_.Exception.Message)" }
"User==Process (PS7 appends Machine only when equal): $([Environment]::GetEnvironmentVariable('PSModulePath','User') -ceq [Environment]::GetEnvironmentVariable('PSModulePath','Process'))"

"`n=== Inbox module manifests ==="
foreach ($m in 'Storage','SmbShare','ScheduledTasks','DnsClient','NetTCPIP','Hyper-V','GroupPolicy') {
    $psd1 = Join-Path $sys32Modules "$m\$m.psd1"
    $editions = ''
    if (Test-Path -LiteralPath $psd1) {
        try { $editions = ((Import-PowerShellDataFile -LiteralPath $psd1 -ErrorAction Stop).CompatiblePSEditions -join ',') } catch { $editions = "<unreadable: $($_.Exception.Message)>" }
    }
    '{0,-15} exists={1,-5} CompatiblePSEditions={2}  {3}' -f $m, (Test-Path -LiteralPath $psd1), $editions, $psd1
}

"`n=== Get-Module -ListAvailable ==="
"-- with -SkipEditionCheck:"
Get-Module -ListAvailable -SkipEditionCheck -Name Storage, SmbShare, ScheduledTasks, Hyper-V, GroupPolicy | Format-Table -AutoSize Name, Version, CompatiblePSEditions, Path | Out-String -Width 300
"-- without -SkipEditionCheck:"
Get-Module -ListAvailable -Name Storage, SmbShare, ScheduledTasks | Format-Table -AutoSize Name, Version, CompatiblePSEditions, Path | Out-String -Width 300
"-- already loaded:"
Get-Module -Name Storage, SmbShare, ScheduledTasks | Format-Table -AutoSize Name, Version, Path | Out-String -Width 300

"`n=== powershell.config.json ==="
$cfgFiles = @((Join-Path $PSHOME 'powershell.config.json'), (Join-Path (Split-Path $PROFILE.CurrentUserCurrentHost) 'powershell.config.json'))
foreach ($f in $cfgFiles) {
    "--- $f (exists: $(Test-Path -LiteralPath $f))"
    if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw }
}
"`n=== Optional feature state (read-only query) ==="
try { Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -ErrorAction Stop | Select-Object FeatureName, State | Format-Table | Out-String } catch { "Hyper-V mgmt PS feature query: $($_.Exception.Message)" }
```

## Validation status (build 0.2.0, 2026-09-17)

- 76 files: parser + PSScriptAnalyzer 1.25.0 — **0 blocking**. 10 advisory items are PowerShell 7.0-profile
  false positives for APIs present in 7.4+.
- Built and smoke-tested on PowerShell 7.5.2 **(macOS)**: module import (34 commands), default ODFC mode produces no
  profile-scope results, reports (CSV/HTML with Scope), daily run/history, launcher `-NoGui` and `-Daily`.

### First run on Windows — not yet exercised

WPF window (XAML load, menus, dialogs, timers), scheduled task registration and run (SYSTEM and CurrentUser),
performance counters, event logs, CIM/registry discovery, RSoP/GPO report (elevated), SMB connection details,
shrink (`-WhatIf` first). Items the build left out or marked below 90% confidence include: Microsoft 365 Apps
version/platform registry values, frxdrv/frxdrvvt driver service names, multi-session detection,
Get-ScheduledTaskInfo property names, and pwsh path quoting in the scheduled task action.
