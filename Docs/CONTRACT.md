# FSLogixToolkit — Build Contract (master agent)

This contract is binding for every build agent. Do not change signatures, output shapes, file
ownership, or folder layout. If the contract blocks correct code, implement the closest correct
behavior and report the issue in `contractIssues` — never silently diverge.

## 1. Target platform
- PowerShell **7.4+** (Core edition only). Latest stable at build time: v7.6.6 (2026-09-08,
  https://github.com/PowerShell/PowerShell/releases). Do not use Windows PowerShell 5.1-only APIs.
- Windows 11 24H2 / Windows Server 2025 and later (build >= 26100) is the supported OS target.
  Anything Windows-specific must be guarded with `Test-FslIsWindows` so the module still imports
  (and the analyzer can run) on non-Windows.
- The module must import and run as a **standard user**. Only operations that truly need admin
  check elevation (`Assert-FslElevation`) and return `Skipped` results when not elevated.

## 2. Accuracy rule (no guessing)
- Every factual claim baked into code or data (registry value names/defaults/recommendations,
  log paths, event log names, service/driver names, version numbers, known bugs, cmdlet
  parameters/behavior) must be verified in THIS run against an authoritative source:
  learn.microsoft.com, github.com/PowerShell/*, github.com/FSLogix/*, or the local PowerShell 7.5.2
  (`Get-Command`, `Get-Help`, `[type]` reflection). Record the URL in code comments / `Source`.
- Confidence >= 90% → implement. Below 90% → do NOT implement it; list it in `lowConfidenceItems`.
- Toolkit thresholds (latency ms, stale days, % full) are configurable defaults in
  `Config/Settings.psd1` and must be labelled "toolkit default", never attributed to Microsoft.

## 3. Coding standards
- One public function per file under `Public/<Area>/`, file name == function name.
  Private helpers go under `Private/<Area>/` (one or more per file is fine).
- Approved verbs only (`Get-Verb`). Full cmdlet and parameter names, no aliases.
- Every function: `[CmdletBinding()]` (add `SupportsShouldProcess` for anything that changes state),
  `[OutputType()]`, parameter validation attributes, comment-based help for public functions
  (.SYNOPSIS, .DESCRIPTION, .PARAMETER for each, .EXAMPLE, .NOTES incl. `RequiresElevation:` and
  `Sources:` URLs).
- No `Write-Host` in module code (GUI code may update controls; launcher may use Write-Host).
  Use `Write-FslLog` for logging; it also forwards to Verbose/Debug/Warning streams.
- Errors: wrap external calls in `try { } catch { Add-FslError -ErrorRecord $_ -Component '<Area>' -Context '<what>' }`.
  Check functions must not throw to the caller — emit a Result with `Status = 'Error'`.
- No network downloads except: `Initialize-FslPrerequisites` (PSGallery, only with `-AllowInstall`
  and ShouldProcess) and `Get-FslLatestVersionInfo` (read-only JSON/HTML GET, timeout, `-Offline`).
  Never download-and-execute code.
- Never output or log secrets (Azure storage keys, SAS tokens, connection strings) — redact.
- Private helper name prefixes (avoid collisions): Environment `*-FslEnv*`, Policy `*-FslPol*`,
  BestPractice `*-FslBpa*`, Containers `*-FslCtr*`, Performance `*-FslPerf*`, Network `*-FslNet*`,
  Maintenance `*-FslMnt*`, Diagnostics `*-FslDiag*`, Reporting/GUI `*-FslRpt*` / `*-FslGui*`.
- Validate your files before finishing (must be clean of parse errors and analyzer Error/Warning):
  `pwsh -NoProfile -File <root>/Tests/Invoke-FslValidation.ps1 -Path <your files/folders>`

## 4. Session state (created by FSLogixToolkit.psm1)
```powershell
$script:FslSession = [ordered]@{
    ModuleRoot   = $PSScriptRoot
    LogRoot      = $null      # set by Initialize-FslSession
    ReportRoot   = $null      # set by Initialize-FslSession
    LogPath      = $null      # current log file
    DebugLogging = $false
    Errors       = [System.Collections.Generic.List[object]]::new()
    Config       = $null      # cached Settings.psd1 hashtable
    Initialized  = $false
}
```
Functions that need LogRoot/ReportRoot call `Initialize-FslSession` implicitly if `Initialized` is false.

## 5. Shared object shapes

### 5.1 Result — `FSLogixToolkit.Result` (produced ONLY via New-FslResult)
Flat, CSV-safe properties in this order:
`Timestamp` (ISO 8601 string), `ComputerName`, `Category`, `Check`, `Status`
(`Pass|Warn|Fail|Info|Skipped|Error`), `Target`, `Value` (string), `Expected` (string), `Message`,
`Recommendation`, `Source` (URL or 'Toolkit default'), `RequiresElevation` (bool).
Category values: `Environment, Policy, BestPractice, Containers, Performance, Network, Maintenance, Diagnostics, Core`.

### 5.2 Setting — `FSLogixToolkit.Setting` (Get-FslEffectiveSetting)
`Scope` (`Profiles|ODFC|Logging|Apps`), `Name`, `Value` (object; MultiString → string[]),
`ValueKind` (`DWord|QWord|String|ExpandString|MultiString|Binary`), `RegistryPath`,
`Source` (`GroupPolicy|MDM|Registry`), `PolicyName` (GPO display name or $null), `ComputerName`.
Secrets in values are redacted.

### 5.3 StorageLocation — `FSLogixToolkit.StorageLocation` (Get-FslStorageLocation)
`Scope` (`Profiles|ODFC`), `LocationType` (`VHDLocations|CCDLocations`), `Path` (redacted),
`ProviderType` (`SMB|Local|AzurePageBlob|Unknown`), `HostName` (string or $null), `Source`.

### 5.4 Container — `FSLogixToolkit.Container` (Get-FslContainer)
`Scope` (`Profiles|ODFC|Unknown`), `UserName`, `SID`, `FolderPath`, `FileName`, `FullName`,
`Extension`, `SizeBytes` (long), `SizeGB` (double, 2dp), `MaxSizeMB` (int or $null),
`PercentOfMax` (double or $null), `LastWriteTime` (datetime), `DaysSinceLastWrite` (int),
`IsLocked` (bool or $null = unknown), `AccountStatus` (`Resolved|Orphaned|Unknown`),
`StorageLocation` (string).

## 6. Function ownership and signatures

### Agent 1 — Core (`Private/Core`, `Public/Core`, `Config/Prerequisites.psd1`)
Private:
- `Write-FslLog -Message <string> [-Level Info|Warning|Error|Debug|Verbose] [-Component <string>]`
  Line format: `yyyy-MM-dd HH:mm:ss.fff [LEVEL] [Component] Message`. Debug lines are written to
  file only when `DebugLogging` is true. Never throws.
- `Add-FslError -ErrorRecord <ErrorRecord> [-Component <string>] [-Context <string>]`
  Appends object (Timestamp, Component, Context, Message, ExceptionType, CategoryInfo, TargetObject
  (string), ScriptStackTrace, InvocationLine) to `$script:FslSession.Errors` and logs Level Error.
- `New-FslResult -Category <string> -Check <string> -Status <string> [-Target] [-Value] [-Expected] [-Message] [-Recommendation] [-Source] [-RequiresElevation <bool>]` → Result (5.1). Value/Expected converted to string (arrays joined with '; ').
- `Test-FslIsWindows` → [bool]
- `Test-FslElevation` → [bool] (public; see below)
- `Assert-FslElevation -Operation <string>` → [bool]; logs a Warning when not elevated. Never throws.
- `Get-FslConfig [-Section <string>]` → hashtable (cached from `Config/Settings.psd1`).
- `Get-FslDataFile -Name <string>` → hashtable from `Config/<Name>.psd1` (Import-PowerShellDataFile).
Public:
- `Initialize-FslSession [-LogRoot <string>] [-ReportRoot <string>] [-EnableDebugLogging] [-Force]`
  Default roots: `<ModuleRoot>/Logs` and `<ModuleRoot>/Reports` if writable, else
  `$env:LOCALAPPDATA/FSLogixToolkit/Logs|Reports` (non-Windows: `[Environment]::GetFolderPath('LocalApplicationData')`).
  Prunes logs older than `Logging.RetainDays`. Returns the session info object.
- `Initialize-FslPrerequisites [-Name <string[]>] [-AllowInstall]` (SupportsShouldProcess) → Result[]
  per module: loaded? available? import; if missing + Source PSGallery + -AllowInstall → install
  CurrentUser (Install-PSResource if available, else Install-Module). Windows features/RSAT are never
  auto-installed — report InstallHint.
- `Get-FslErrorLog` → error objects. `Export-FslErrorLog [-Path <string>]` → FileInfo[] (.json and .csv).
- `Test-FslElevation` → [bool] (Windows admin role check; $false on non-Windows).

### Agent 2 — Environment (`Public/Environment`, `Private/Environment`, `Config/KnownVersions.psd1`)
- `Find-FslInstallation` → [pscustomobject] InstallPath, Version, FrxPath, IsInstalled, Services
  (name/status/start type), Drivers (name/state), DetectionMethod.
- `Get-FslLatestVersionInfo [-Offline] [-TimeoutSec <int>]` → [pscustomobject] PowerShellLatest,
  PowerShellLatestPublished, PowerShellSource, FSLogixLatest, FSLogixSource, Retrieved (Online|Offline data file).
- `Get-FslEnvironment [-Offline]` → Result[] (Category Environment): OS build >= 26100 (24H2+),
  OS edition/build, PowerShell edition/version vs minimum + latest, FSLogix installed/version vs latest,
  services/drivers running, elevation state (Info).

### Agent 3 — Policy / GPO (`Public/Policy`, `Private/Policy`)
- `Get-FslEffectiveSetting [-Scope <string[]>]` → Setting[] (5.2). Reads FSLogix registry keys and
  determines the source (Group Policy vs MDM/Intune vs plain registry) using verified methods.
- `Get-FslGpoReport [-IncludeUserScope]` → Result[] (Category Policy): applied GPOs that configure
  FSLogix, setting-level provenance where available. Computer-scope RSoP needing admin → Skipped when
  not elevated. Must not require the GroupPolicy RSAT module (use it only if present).
- `Get-FslStorageLocation` → StorageLocation[] (5.3) from VHDLocations/CCDLocations (Profiles + ODFC).

### Agent 4 — Best Practice Analyzer (`Public/BestPractice`, `Private/BestPractice`, `Config/BestPractices.psd1`)
- `Invoke-FslBestPracticeAnalyzer [-Setting <object[]>] [-Scope <string[]>]` → Result[]
  (Category BestPractice). If -Setting not supplied, calls `Get-FslEffectiveSetting`.
  Rules are data-driven from `Config/BestPractices.psd1`; every rule has a Source URL.

### Agent 5 — Containers (`Public/Containers`, `Private/Containers`)
- `Get-FslContainer [-Path <string[]>] [-Scope <string[]>]` → Container[] (5.4). Default paths from
  `Get-FslStorageLocation` (SMB/Local only). Resolves SID→account via .NET (no AD module required).
- `Get-FslContainerReport [-Container <object[]>] [-StaleDays <int>] [-PercentOfMaxWarn <int>] [-PercentOfMaxFail <int>]`
  → Result[] (Category Containers): per-container stale/oversized/orphaned/locked flags + totals.

### Agent 6 — Storage performance (`Public/Performance`, `Private/Performance`)
- `Test-FslStoragePerformance [-Path <string[]>] [-SampleSeconds <int>] [-IncludeWriteTest]`
  → Result[] (Category Performance): IOPS and latency from performance counters (local physical disk
  and SMB client share counters for the storage locations); optional opt-in write/read test using a
  temporary file that is always removed.

### Agent 7 — Network health (`Public/Network`, `Private/Network`)
- `Test-FslNetworkHealth [-Path <string[]>] [-TimeoutMs <int>]` → Result[] (Category Network):
  DNS resolution, TCP 445 reachability + connect latency, SMB connection dialect/signing/encryption
  where readable, and (for AzurePageBlob locations) HTTPS 443 reachability. Defaults from `Get-FslStorageLocation`.

### Agent 8 — Maintenance (`Public/Maintenance`, `Private/Maintenance`)
- `Invoke-FslContainerShrink [-Path <string[]>] [-MinimumSizeGB <double>] [-DaysSinceLastWrite <int>]` (SupportsShouldProcess, ConfirmImpact High) → Result[] (Category Maintenance). Requires elevation; skips locked/in-use disks; reports before/after size.
- `Remove-FslStaleContainer [-Container <object[]>] [-StaleDays <int>] [-OrphanedOnly] [-ArchivePath <string>]` (SupportsShouldProcess, ConfirmImpact High) → Result[]. Moves to ArchivePath when given, otherwise deletes; never touches locked containers.

### Agent 9 — Diagnostics (`Public/Diagnostics`, `Private/Diagnostics`, `Config/KnownIssues.psd1`)
- `Get-FslLogSummary [-Days <int>] [-MaxEvents <int>]` → Result[] (Category Diagnostics): errors/warnings from FSLogix log files and FSLogix event logs (verified names/paths).
- `Get-FslKnownIssue [-Version <string>]` → Result[]: known issues from `Config/KnownIssues.psd1` matching installed FSLogix version (each with source URL + fixed-in version).
- `Export-FslDiagnosticBundle [-Path <string>] [-Days <int>]` → FileInfo: zip of toolkit logs, error log, recent FSLogix logs, latest reports (no secrets).

### Agent 10 — Reporting + GUI (`Public/Reporting`, `Private/Reporting`, `GUI/`, `Start-FSLogixToolkit.ps1`)
- `Invoke-FslHealthCheck [-Category <string[]>] [-IncludeWriteTest] [-Offline]` → Result[]: runs the
  category functions above, each isolated in try/catch.
- `Export-FslReport -InputObject <object[]> [-Format Csv|Html|Both] [-Path <string>] [-Title <string>]` → FileInfo[]. HTML is self-contained, HTML-encoded, summary by Category/Status.
- `Show-FslDashboard` → WPF window (`GUI/MainWindow.xaml`): elevation banner, tabs per category + Errors tab, Run/Run All, status filter, Export CSV / Export HTML buttons; UI must stay responsive.
- `Start-FSLogixToolkit.ps1` (module root): `#Requires -Version 7.4`, imports module, Initialize-FslSession, Initialize-FslPrerequisites (no install unless `-AllowInstall`), launches GUI, or `-NoGui` runs health check and exports reports.

---

# PHASE 2 — Office-container-first GUI, discovery, daily health checks (binding; extends phase 1)

## P2.1 User requirements (source of truth)
1. A GUI form (WPF) with **automatic checks** at startup and **menu-driven options**.
2. **Daily health checks** (scheduled + history).
3. **Discovery** of FSLogix from the image the toolkit runs on, from the **registry**, and from **Group Policy**.
4. **Separate menu sections**: "Office Containers" and "Profile Containers".
5. **Default = Office Container (ODFC) checks only.** This VM uses FSLogix Office containers only, no profile
   containers. Profile container checks run only when the user switches the container mode.

Phase 1 rules still apply: accuracy/90% rule, PS 7.4+, standard-user first, validator clean, no Write-Host,
no secrets, no guessing, one public function per file, approved verbs, area-prefixed private helpers
(new prefixes: Discovery `*-FslDisc*`, Daily `*-FslDaily*`, Preferences `*-FslPref*`).

## P2.2 Container mode
- Values: `ODFC` (default) | `Profiles` | `Both`.
- Resolution order: explicit parameter > user preference file > `Config/Settings.psd1` Toolkit.ContainerMode > `'ODFC'`.
- Preference file: `<LocalApplicationData>/FSLogixToolkit/<Toolkit.PreferenceFileName>` (JSON). Environment
  variable `FSLOGIXTOOLKIT_PREFERENCE_PATH` overrides the full file path (used by tests). Never write
  preferences into the module folder.
- Setting scopes map to Result scopes: `Profiles`→`Profiles`, `ODFC`→`ODFC`, `Logging`/`Apps`/everything else→`General`.

## P2.3 Result shape change (5.1 v2)
Append ONE property at the end: `Scope` (`General|ODFC|Profiles`), default `General`.
`New-FslResult` gains `[-Scope <General|ODFC|Profiles>]` (default General) and the Category ValidateSet
gains `Discovery` and `Daily`. Every producer that is scope-specific MUST pass `-Scope`.

## P2.4 New / changed signatures (additive — existing parameters keep working)

### Core (Agent P2-1)
- `New-FslResult ... [-Scope <string>]` (see P2.3).
- `Get-FslPreference [-Name <string>]` → hashtable (all Toolkit keys, merged Settings ← preference file) or single value.
- `Set-FslPreference -Name <ContainerMode|AutoDiscoverOnStartup|AutoRunHealthCheckOnStartup|AutoRefreshMinutes|Offline> -Value <object>` (SupportsShouldProcess) → merged hashtable. Validates values (ContainerMode set; AutoRefreshMinutes 0..1440 int; booleans).
- `Get-FslContainerMode [-Mode <ODFC|Profiles|Both>]` → string (resolved mode).
- Private `Resolve-FslPrefContainerScope -Mode <string>` → string[] (`ODFC`→@('ODFC'), `Profiles`→@('Profiles'), `Both`→@('ODFC','Profiles')).

### Discovery (Agent P2-2) — new `Public/Discovery`, `Private/Discovery`; also owns Environment area fixes
- `Get-FslDiscovery [-Offline]` → `FSLogixToolkit.Discovery` object:
  `ComputerName, DiscoveredAt (ISO 8601), IsElevated, Image, FSLogix, Office, Settings, StorageLocations,
  GroupPolicy, DetectedMode, ConfiguredMode, ModeMismatch`
  - `Image` (pscustomobject): OS caption, build, UBR, Windows version name (KnownVersions.psd1), install date,
    last boot, manufacturer/model, domain/workgroup, Entra/AD join state (only via a verified method, e.g.
    `dsregcmd /status` fields verified on learn.microsoft.com), multi-session indicator (only if verified),
    Azure VM + marketplace image reference via Azure Instance Metadata Service (only when not -Offline;
    link-local read-only GET with verified header/api-version, short timeout, no proxy) — unknown → $null.
  - `FSLogix` = `Find-FslInstallation` output.
  - `Office`: Microsoft 365 Apps Click-to-Run facts relevant to ODFC (installed, version, platform,
    shared computer activation) read from verified registry locations only.
  - `Settings` = `Get-FslEffectiveSetting` (all scopes). `StorageLocations` = `Get-FslStorageLocation`.
  - `GroupPolicy` = `Get-FslGpoReport` results (Skipped when not elevated).
  - `DetectedMode`: `ODFC|Profiles|Both|None` from effective `Enabled` values under the Profiles and ODFC scopes.
  - `ConfiguredMode` = `Get-FslContainerMode`; `ModeMismatch` = detected ≠ configured (None counts as mismatch only if configured includes a scope).
- `Get-FslDiscoveryReport [-Discovery <object>] [-Offline]` → Result[] Category `Discovery`, `Target` = section
  (`Image|FSLogix|Office|Registry|GroupPolicy|StorageLocation|Mode`), Scope per setting scope (P2.2). Mode
  mismatch → Warn (e.g. profile containers enabled on the image while toolkit mode is ODFC).
- Fix phase-1 claims issues in `Private/Environment/FslEnvironmentHelpers.ps1`: driver service names
  frxdrv/frxdrvvt are unverified — detect drivers without assuming service names (e.g. by verified driver
  file path/PathName) or report Unknown, never NotFound, when not verifiable; DisplayVersion is informational only.

### Scope plumbing A (Agent P2-3): Policy, Performance, Network
- `Get-FslStorageLocation [-Scope <Profiles|ODFC>[]]` (default both).
- `Get-FslGpoReport [-IncludeUserScope] [-Scope <Profiles|ODFC>[]]` — rows for other scopes filtered out; Logging/Apps rows kept as General.
- `Test-FslStoragePerformance [-Path] [-SampleSeconds] [-IncludeWriteTest] [-Scope <Profiles|ODFC>[]]` — default targets from `Get-FslStorageLocation -Scope`; local-disk counters Scope General; share results Scope of the location.
- `Test-FslNetworkHealth [-Path] [-TimeoutMs] [-Scope <Profiles|ODFC>[]]` — same pattern.
- Apply claims fixes: add the Azure Files TCP 445 source to Network; correct the Performance ACL message text to the Get-Counter documented wording.

### Scope plumbing B (Agent P2-4): Containers, Diagnostics, Maintenance
- `Get-FslContainerReport [-Container] [-StaleDays] [-PercentOfMaxWarn] [-PercentOfMaxFail] [-Scope <Profiles|ODFC>[]]` → passes Scope to `Get-FslContainer`; results carry container Scope (Unknown → General).
- Containers: support Microsoft Entra ID user SIDs (`S-1-12-1-...`) in folder names if verified on learn.microsoft.com.
- `Get-FslLogSummary [-Days] [-MaxEvents] [-Scope <Profiles|ODFC>[]]` — log subfolders mapped to scope only if the folder names are verified; event log results General.
- `Get-FslKnownIssue [-Version] [-Scope <Profiles|ODFC>[]]` — `Config/KnownIssues.psd1` entries gain `Scope` (`General|Profiles|ODFC|CloudCache`) tagged ONLY from the source text; untagged → General (always included).
- Maintenance: results carry container Scope; fix compaction version text/source per claims report (2210 / 2.9.8361.52326, troubleshooting-vhd-disk-compaction).

### Best practice ODFC (Agent P2-5)
- `Config/BestPractices.psd1`: add verified ODFC rules (learn.microsoft.com ODFC configuration guidance and
  reference-configuration-settings ODFC section). Results: Scope from rule scope (P2.2).
- `Invoke-FslBestPracticeAnalyzer [-Setting] [-Scope]` signature unchanged; with `-Scope ODFC` must not emit Profiles results; cross-checks emit per scope.

### Health check + Daily + launcher (Agent P2-6)
- `Invoke-FslHealthCheck [-Category <Discovery|Environment|Policy|BestPractice|Containers|Performance|Network|Diagnostics>[]] [-ContainerScope <ODFC|Profiles|Both>] [-IncludeWriteTest] [-Offline]`
  Default ContainerScope = `Get-FslContainerMode`. Plan: Discovery→Get-FslDiscoveryReport; Environment→Get-FslEnvironment;
  Policy→Get-FslGpoReport -Scope; BestPractice→Invoke-FslBestPracticeAnalyzer -Scope <resolved scopes + Logging,Apps>;
  Containers→Get-FslContainerReport -Scope; Performance→Test-FslStoragePerformance -Scope; Network→Test-FslNetworkHealth -Scope;
  Diagnostics→Get-FslLogSummary -Scope and Get-FslKnownIssue -Scope. Only pass parameters the callee declares. **No Profiles-scope
  work when ContainerScope is ODFC.**
- `Export-FslReport` adds the `Scope` column (CSV) and a Scope×Status summary (HTML).
- Daily (`Public/Daily`, `Private/Daily`):
  - `Invoke-FslDailyHealthCheck [-ContainerScope] [-Offline] [-ReportRoot <string>]` → summary object. Writes to
    `<ReportRoot>/<Daily.FolderName>/<yyyy-MM-dd>/`: report (Export-FslReport, Daily.Formats), `Summary_<HHmmss>.json`
    (Date, Time, ComputerName, ContainerScope, DurationSeconds, ToolkitVersion, Counts by Status, Counts by Scope×Status,
    Fail/Error/Warn check list, NewIssues vs the most recent previous summary keyed by Category|Check|Target|Scope, report paths),
    error log export when errors exist; prunes day folders older than Daily.RetainDays.
  - `Get-FslDailyHistory [-Days <int>] [-ReportRoot <string>]` → objects (Date, Time, ContainerScope, Pass, Warn, Fail, Error, Info, Skipped, NewIssueCount, HtmlReport, CsvReport, SummaryPath), newest first.
  - `Register-FslDailyHealthCheck [-At <HH:mm>] [-ContainerScope] [-RunAs <System|CurrentUser>] [-Offline] [-Force]` (SupportsShouldProcess).
    Scheduled Task running `pwsh` (current PS 7 executable path) `-NoProfile -NonInteractive -File "<ModuleRoot>\Start-FSLogixToolkit.ps1" -Daily -ContainerScope <x>`.
    System requires elevation (return Skipped Result with RequiresElevation when not elevated). Use only verified ScheduledTasks cmdlets/parameters; do not add `-ExecutionPolicy Bypass`.
  - `Unregister-FslDailyHealthCheck` (SupportsShouldProcess) → Result. `Get-FslDailyHealthCheck` → object (Registered, State, At, RunAs, ContainerScope, NextRunTime, LastRunTime, LastTaskResult, Arguments) or Registered=$false.
- `Start-FSLogixToolkit.ps1` adds `-Daily` (runs Invoke-FslDailyHealthCheck; exit 0 / 2 when Fail|Error) and `-ContainerScope <ODFC|Profiles|Both>` (passed to GUI, console and daily runs).

### GUI (Agent P2-7) — `Public/Reporting/Show-FslDashboard.ps1`, `Private/Reporting/FslGui*.ps1`, `GUI/*.xaml`
`Show-FslDashboard [-ContainerScope <ODFC|Profiles|Both>] [-NoAutoRun]`
- **Menu bar** (WPF Menu):
  - File: Export Current View ▸ CSV/HTML; Export All Results ▸ CSV/HTML; Export Diagnostic Bundle…; Open Reports Folder; Open Logs Folder; Exit.
  - Discovery: Run Discovery; Image / OS; FSLogix Installation; Microsoft 365 Apps; Registry Settings; Group Policy; Storage Locations.
  - **Office Containers**: Run All Office Container Checks; Settings & Best Practice; Containers (size / last used); Storage Performance; Network Health; Logs & Events; Known Issues.
  - **Profile Containers**: same items. When mode is ODFC these items are disabled and an "Enable Profile Container Checks…" item (confirmation) switches mode to Both (persisted with Set-FslPreference).
  - Health Check: Run Full Health Check (current mode); Daily ▸ Run Daily Check Now / View Daily History / Schedule Daily Check… / Remove Daily Schedule / Open Daily Reports Folder.
  - Tools: Prerequisites; Environment & Versions; Error Log; Debug Logging (checkable); Offline Mode (checkable).
  - Options: Container Mode ▸ Office Containers only (default) / Profile Containers only / Both (mutually exclusive checkable items, persisted); Run Discovery at Startup; Run Health Check at Startup; Auto Refresh ▸ Off/15/30/60 min.
  - Help: About; Command-line Usage.
- **Layout**: header banner (computer, OS + version name, FSLogix version, Microsoft 365 Apps version, Elevated yes/no, container-mode badge, last check time, daily schedule state); TabControl: Overview | Discovery | Office Containers | Profile Containers | Environment & Policy | Daily Health | Errors & Log. Office/Profile tabs have inner tabs per category (Best Practice, Containers, Performance, Network, Diagnostics) showing Results filtered by Scope + Category. Profile tab shows "Profile container checks are off (Office containers only)" when mode is ODFC. Filter bar: Status ComboBox + text search. Details panel for selected row (Message, Recommendation, Source; open Source only if https). Status bar with progress indicator.
- **Automatic checks**: on window Loaded → Discovery (if AutoDiscoverOnStartup) → health check for the resolved mode (if AutoRunHealthCheckOnStartup and not -NoAutoRun); DispatcherTimer auto refresh when AutoRefreshMinutes > 0.
- **Threading**: all checks in a background runspace importing the module manifest; one operation at a time; menus/buttons that start work are disabled while running; UI updates only on the dispatcher thread.
- Event handlers must be able to call module-private functions (do NOT rely on `.GetNewClosure()` inside module code for handlers that call private functions — verify scoping).
- Schedule dialog: `GUI/ScheduleDialog.xaml` (time HH:mm, RunAs System/CurrentUser, container mode; explains System needs elevation).
- Read-only: no maintenance actions in the GUI.

---

# PHASE 3 — Security pre-work, repair engine, undo store, repair logs, GUI repairs, run-as smart card (binding)

Source plan: `Docs/REPAIR-PLAN.md` (read §0–§7). Owner decisions: repairs in GUI = yes; FSLogix settings delivered by
**Local Group Policy in the image**; **no Cloud Cache**; FSLogix upgraded in the golden image; **Office container reset allowed in GUI**.
Build scope = plan steps R0.5, R0/R1, R2, R3 **only**. Everything in the plan's "Later" list is OUT OF SCOPE (not even stubs).
New owner requirement: **relaunch as a selected user with smart card** (admin accounts are separate profiles).
All phase 1/2 rules still apply (accuracy ≥ 90%, PS 7.4+, validator clean, no secrets, standard-user first, StrictMode Latest).
Private helper prefixes: Repair `*-FslFix*`, security/relaunch helpers in Core `*-FslCore*`.

## P3.1 Pre-work (R0.5)
1. **Three-state provenance.** Setting (5.2) `Source` ∈ `GroupPolicy | MDM | Registry | Unknown`; add property `SourceDetail` (string reason).
   `Registry` ONLY when elevated on Windows AND the RSoP query succeeded AND no winning row matched. Not elevated, RSoP error,
   or RSoP unavailable → `Unknown`. StorageLocation.Source follows. Local Group Policy must surface as GroupPolicy when RSoP lists it
   (lab item; do not claim beyond sources). All consumers (BPA messages, Discovery report, GUI text) must display Unknown sensibly.
2. **Discovery Info finding** for FSLogix values found under `HKLM\SOFTWARE\FSLogix\ODFC` (non-Policies key; FSLogix reads ODFC
   from `HKLM\SOFTWARE\Policies\FSLogix\ODFC` per reference-configuration-settings).
3. **Toolkit folder security.** Public `Test-FslToolkitPathSecurity [-Path <string>]` → Result[] (Category Core): checks owner and
   Allow ACEs on the module root and `Modules, Config, Public, Private, GUI` folders and `Start-FSLogixToolkit.ps1`/`FSLogixToolkit.psm1`/`.psd1`.
   Fail when any principal other than Administrators (S-1-5-32-544), SYSTEM (S-1-5-18), TrustedInstaller
   (S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464) or CREATOR OWNER (S-1-3-0, inherit-only) has write-type rights
   (verify the FileSystemRights set on learn.microsoft.com), or the owner is not one of those. Non-Windows → Skipped.
   Private `Test-FslCoreToolkitPathSecure` → [bool] used by gates. Launcher: when elevated and insecure → prominent warning
   (health checks continue); repairs refuse (gate G3).
4. `smphost` check added next to `defragsvc` in Maintenance (troubleshooting-vhd-disk-compaction); fix Diagnostics comment
   (LoggingEnabled default 2 enables all logs).

## P3.2 Relaunch / run as (owner requirement)
Private `Start-FslCoreRelaunch -Mode <Elevate|DifferentUser> [-UserName <string>] [-ElevateAfterSignIn] [-Arguments <hashtable>]` → [bool] started.
- `Elevate`: existing approach — `Start-Process <pwsh> -Verb RunAs` with `-EncodedCommand` (UAC prompt; Windows' own credential UI,
  which offers accounts/smart cards when the signed-in user is not an administrator).
- `DifferentUser`: `runas.exe /smartcard` (plus `/user:<UserName>` when given/required — verify runas syntax on learn.microsoft.com)
  launching the current PowerShell 7 executable with `-EncodedCommand`; when `-ElevateAfterSignIn`, the relaunched launcher receives
  `-RequestElevation` so it elevates as that user. Check the Secondary Logon service (`seclogon`) first and report clearly if disabled.
- **Never** prompt for, read, pass, log or store passwords/PINs; no `Get-Credential`, no `-Credential`, no `/savecred`.
- Pass explicit `-ContainerScope <resolved mode>` and, when `RunAs.PassReportRoot`, `-OutputPath <current ReportRoot>` because the
  other account has a different profile/preferences. Show in the banner/console which account is running.
- Launcher params: `-RunAsDifferentUser`, `-RunAsUserName <string>`, `-RequestElevation` (existing). Preference `RunAsUserName`
  (last user name, not secret) added to Get/Set-FslPreference.
- Launcher calls private functions via module scope: `& (Get-Module FSLogixToolkit) { param($p) Start-FslCoreRelaunch @p } $params`.

## P3.3 Shapes
- Result Category adds `Repair`.
- `FSLogixToolkit.RepairAction`: `ActionId, Title, Scope (General|ODFC|Profiles), RiskTier (0-3), Status (Ready|Blocked|NotNeeded|GuidanceOnly),
  Condition, Target, CurrentValue, ProposedValue, BlockReason, Guidance, RequiresElevation, RequiresChangeReference, RollbackMethod
  (RestoreValue|RestoreStartType|MoveBack|None), EffectiveWhen (Immediate|ServiceRestart|NextSignIn|Reboot|Unknown), Fingerprint (SHA256 of
  before-state JSON), PlannedAt (ISO 8601), Source (URL), Parameters (hashtable)`.
- `FSLogixToolkit.RepairRecord` (CSV-safe order): `Timestamp, RunId, Sequence, ComputerName, ActionId, Title, Scope, RiskTier, Mode
  (WhatIf|Executed|Declined|Blocked|Undo), Target, BeforeState, AfterState, ExpectedState, Status (Pass|Fail|Skipped|Error|Info),
  VerificationStatus, Message, Operator, IsElevated, ChangeReference, RollbackAvailable, RollbackRef, Source`.

## P3.4 Undo store + repair logs (R1) — Agent P3-4
Private (`Private/Repair/FslFixState.ps1`, `FslFixLog.ps1`):
- `Resolve-FslFixStateRoot` → path (expand `Repair.StateRoot`); `Test-FslFixStateRoot [-Create]` → @{Ok;Message}: create with
  admin-only ACL (SYSTEM + Administrators FullControl, protected from inheritance); if the folder already exists verify owner/ACL
  and refuse if a non-admin owns it or has write rights (FileSystemAclExtensions.Create does nothing if it exists).
- `New-FslFixRun -Mode <WhatIf|Apply|Undo> [-ChangeReference] [-RollbackOfRunId]` → run context (RunId, StatePath, ReportFolder,
  LogPath, JsonPath, CsvPath, StartedAt, Operator{Name,Sid}, IsElevated, InvocationSource, Records list) and takes a single-run lock.
- `Save-FslFixRollbackEntry -Run -ActionId -BeforeState <hashtable> [-AfterState <hashtable>] [-Created <string[]>]` → writes
  `rollback.json` and refreshes `manifest.sha256` BEFORE the change is applied (verify re-read).
- `Test-FslFixRollbackIntegrity -RunId` → bool; `Get-FslFixRollbackEntry -RunId [-ActionId]`.
- `Add-FslFixRecord -Run -Record` (append + human log line) ; `Complete-FslFixRun -Run` (write .log/.json/.csv under
  `<ReportRoot>/Repair/<yyyy-MM-dd>/Repair_<HHmmss>_<RunId8>.*`, release lock, returns summary) ; `Remove-FslFixOldRun` (retention;
  never prune a run with an unreverted temporary change).
- Public `Get-FslRepairLog [-Days <int>] [-RunId <guid>] [-ReportRoot <string>] [-IncludeRecords]`.
- `New-FslResult` Category `Repair`; `Export-FslDiagnosticBundle` includes `Reports/Repair` copies (never the StateRoot).
- All internal writes `-WhatIf:$false -Confirm:$false`; everything redacted; repairable registry value names are an allow-list.

## P3.5 Repair engine + CLI actions (R2) — Agent P3-5
Data `Config/Repairs.psd1`: `@{ DataVerifiedOn; Actions = @( @{ Id; Title; Scope; RiskTier; Kind ('RegistryValue'|'ServiceStartType'|'ServiceStart'|'Container');
Target (hashtable: Hive/Key/ValueName/ValueKind or ServiceName); ProposedValue; Condition (text); Detect; Apply; Rollback (private
function names); RollbackMethod; EffectiveWhen; OperatorSelected (bool); RequiresNoSessions; Source; Guidance } ) }`.
Actions in scope: FIX-SVC-01..04, FIX-LOG-01..04, FIX-ODFC-01 (engine agent) and FIX-ODFC-02 (entry by engine agent; handlers by P3-6).
Handler interface (private, prefix `*-FslFix*`):
- Detect `param([hashtable]$Definition, [hashtable]$Parameters)` → `[pscustomobject]@{ Needed; CurrentValue; ProposedValue; Target; BeforeState(hashtable); BlockReason; GuidanceOnly; Guidance; Message }`
- Apply `param([hashtable]$Definition, [pscustomobject]$Action, [hashtable]$BeforeState)` → `@{ Success; AfterState(hashtable); Created(string[]); Message }`
- Rollback `param([hashtable]$Definition, [hashtable]$BeforeState, [hashtable]$AfterState)` → `@{ Success; Message }`
Public:
- `Get-FslRepairPlan [-ContainerScope] [-ActionId <string[]>] [-MaxRiskTier <0..3>] [-Parameters <hashtable>]` → RepairAction[] (read-only; standard user OK; OperatorSelected actions appear only when named in -ActionId).
- `Test-FslRepairPrerequisite -Action <object[]>` → Result[] (Category Repair, Check `Preflight:<Gate>`), gates G1–G8, G10, G12–G18, G21 per plan (G9 session enumeration is NOT implemented: use container lock checks + operator attestation).
- `Invoke-FslRepair` (SupportsShouldProcess, ConfirmImpact High): `-Action <object[]>` (pipeline) | `-ActionId <string[]>`, `[-ContainerScope] [-MaxRiskTier] [-AllowDisruptive] [-ChangeReference <string>] [-Parameters <hashtable>] [-UserSignedOutConfirmed]` → Result[] (summary Result Target = RunId). Re-detects and compares Fingerprint (drift → Blocked). Registry values delivered by GroupPolicy → `GuidanceOnly` (tell the operator which Local Group Policy / FSLogix administrative template setting to change — only verified policy names; otherwise name the registry value); Unknown provenance → Blocked. ODFC registry writes only under `HKLM\SOFTWARE\Policies\FSLogix\ODFC`. Only Disabled→Manual for defragsvc/smphost. `frxsvc`: start only if stopped (never stop/restart).
- `Undo-FslRepair -RunId <guid> [-ActionId <string[]>]` (SupportsShouldProcess, High) → Result[]; verifies integrity; refuses on drift.
- Launcher: `-RepairPlan`, `-Repair -ActionId <string[]>`, `-UndoRunId <guid>`, `-MaxRiskTier`, `-AllowDisruptive`, `-ChangeReference`, `-ArchivePath`, `-RepairUserName`, `-UserSignedOutConfirmed`; exit code **3** = refused by pre-flight. The daily task never runs repairs.

## P3.6 Office container reset (R3 engine part) — Agent P3-6
`Private/Repair/FslFixContainer.ps1`: handlers for FIX-ODFC-02 per the interface. Parameters: `UserName` or `UserSid` (resolved via
`Get-FslContainer -Scope ODFC`), `ArchivePath`. Gates: elevated; ODFC Enabled = 1 and Profiles Enabled ≠ 1; ODFC `CCDLocations` absent;
target file is an ODFC-scope VHD/VHDX; exclusive-open test passes immediately before acting (detects use by any host) and not attached
locally (`Get-DiskImage` when available); `-UserSignedOutConfirmed`; `-ChangeReference`; archive reachable. Action: copy file to
`<ArchivePath>\<yyyyMMdd_HHmmss>_<ComputerName>_<UserFolder>\`, verify length + SHA256, then remove the source file (never the folder,
never other files). Rollback (MoveBack): only if no ODFC container exists again at the original path and the archive hash matches; copy back,
verify, then remove the archive copy. Warning text about "Most data" being re-synced (concepts-container-types).

## P3.7 GUI (R3) — Agent P3-7
- New **Repair** menu (between Health Check and Tools): Repair Plan (Preview)…, Reset Office Container…, Undo a Repair Run…,
  Repair History…, Open Repair Logs Folder. Disabled unless elevated (tooltip: use File > Relaunch…). History stays enabled.
- **File** menu adds: Relaunch Elevated (UAC)…, Relaunch as Different User (Smart Card)… (dialog: user name, "Elevate after sign-in"
  checkbox, explanation that Windows prompts for the smart card/PIN; confirm → Start-FslCoreRelaunch → close current window).
- `GUI/RepairDialog.xaml` (plan grid with checkbox/ID/title/scope/tier/status/reason, detail pane, change reference, Preview (WhatIf)
  and Apply; Apply enabled only after a preview of the identical selection with no drift; Tier 3 typed computer-name confirmation),
  `GUI/ContainerResetDialog.xaml` (pick ODFC user from Get-FslContainer -Scope ODFC, archive path, signed-out confirmation, change
  reference, typed user-name confirmation, data-loss warning), `GUI/RunAsDialog.xaml`, repair history grid (Get-FslRepairLog).
- Runner operations for plan/apply/undo/log; auto refresh suspended and window close blocked during apply; new MainWindow control names
  added to `Get-FslGuiControlNameList`; every handler wrapped in try/catch; existing tabs unchanged.
