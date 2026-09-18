# Phase 3 review — results (run `wf_05a414e3-d4d`, 2026-09-17)

Five agents: security / Windows-semantics review, GUI runtime bug hunt, integration tester, requirements critic, fixer.
Build waves A/B/C were already complete; their reports were replayed from run `wf_e92d304b-60f`.

Final state: `Validated 98 file(s). BLOCKING: none` · module imports · 40/40 commands exported.

## Security / Windows semantics review — confidence 85

| Severity | Fixed | Location | Problem |
|---|---|---|---|
| high | yes | `Private/Repair/FslFixService.ps1:272` | FIX-SVC-03 always reported Fail whenever frxsvc was not Running. Detect planned 'start the stopped service' for any non-Disabled stopped service, but Set-FslFixServiceStartTypeState deliberately refuses to start frxccds until the documented dependency frxsvc is Running. The post-change re-detect the… |
| high | **no** | `Start-FSLogixToolkit.ps1:291` | Privilege-escalation window that the toolkit-path warning does not close: the launcher creates and prepends <root>\Modules to the process PSModulePath (line 263) and then Import-Module dot-sources every .ps1 under Private/ and Public/ (line 291) BEFORE Test-FslToolkitPathSecurity runs (line 334). Wh… |
| medium | yes | `Private/Repair/FslFixPreflight.ps1:398` | Pre-flight gates took Scope, RiskTier, Kind and RequiresChangeReference from the caller-supplied FSLogixToolkit.RepairAction object instead of from Config/Repairs.psd1, so a stale or hand-built -Action object steered which gates ran. Invoke-FslRepair already re-derives the tier and the change-refere… |
| medium | yes | `Private/Core/SecurityHelpers.ps1:333` | Test-FslToolkitPathSecurity checked only the IMMEDIATE parent of the module root with the 'Replace' right set, so the stated protection ("a principal that can delete or rename the toolkit folder from its parent can replace every file in it") stopped one level up. FILE_DELETE_CHILD is documented as "… |
| medium | yes | `Private/Repair/FslFixService.ps1:27` | Registry repairs are pinned to an allow-list (contract P3.4), but service repairs had none: Set-FslFixServiceStartTypeEntry, Start-FslFixServiceEntry and Set-FslFixServiceStartTypeDisabled acted on whatever name came out of Config/Repairs.psd1 or out of the rollback store. The contract rules "only D… |
| medium | yes | `Private/Repair/FslFixLog.ps1:612` | Remove-FslFixOldRun deleted expired repair-report day folders and rollback state folders with Remove-Item -Recurse -Force without checking for reparse points. The repair report root is NOT required to be admin-only (it can be %LOCALAPPDATA%\FSLogixToolkit\Reports or any operator -OutputPath), so a f… |
| low | yes | `Private/Core/RelaunchHelpers.ps1:21` | The run-as user-name regex was anchored with '$', which in .NET also matches immediately before a trailing newline, so "CONTOSO\admin\n" passed Test-FslCoreRunAsUserName and the launcher's -RunAsUserName ValidatePattern. Confirmed: New-FslCoreRunAsArgumentString then emitted a raw LF inside /user:CO… |
| low | yes | `Private/Repair/FslFixState.ps1:673` | The secret-refusal message thrown by Save-FslFixRollbackEntry contained the literal marker names "(AccountKey=/SharedAccessSignature=/sig=)", which the message then hit on its own way through ConvertTo-FslCoreRedactedText. The operator-facing refusal read "contains secret patterns (AccountKey=***RED… |
| low | yes | `Private/Repair/FslFixContainer.ps1:947` | On its two failure paths Invoke-FslFixContainerReset returned the list of paths it could NOT clean up in the handler contract's 'Created' field, whose documented meaning is "items this action created, so Undo removes them again". Those values are written into the rollback store's Created array, so a… |
| low | **no** | `Public/Repair/Undo-FslRepair.ps1:177` | Undo-FslRepair does not re-check Group Policy provenance before restoring a registry value. If a GPO started delivering that value between the apply and the undo, and its winning value happens to equal the recorded AfterState, the undo writes the pre-repair value and the next policy refresh silently… |

Left unfixed, with the reviewer's reasoning:

- **`Start-FSLogixToolkit.ps1:291` (high)**
  NOT changed - contract P3.1 item 3 explicitly requires the launcher to warn and continue ("health checks continue;
  repairs refuse"), and any real mitigation means refusing to load, which would change documented startup behaviour.
  Recommended follow-up for the owner: deploy under an admin-only path (C:\Program Files\FSLogixToolkit) as REPAIR-
  PLAN open question Q2 already asks, and consider a small self-contained owner/ACL check inside the launcher that
  runs before the PSModulePath change and Import-Module and refuses to continue when elevated.
- **`Public/Repair/Undo-FslRepair.ps1:177` (low)**
  NOT changed. The existing state-match gate already blocks the common case (a GPO that applies a different value
  makes the current state differ from the recorded AfterState, so the undo is refused as drift), and adding a
  provenance gate to Undo is a behaviour change the contract does not specify. Flagged for the owner; it is also
  covered by the inherited lab item on whether Local Group Policy rows appear in RSoP at all.

Unresolved / needs a Windows host:

- Windows-only runtime behaviour could not be exercised on macOS: real NTFS ACL reads (FileSystemAclExtensions on
Program Files/C:\ with inherited generic bits), Set-Service/Start-Service, registry 64-bit view
SetValue/DeleteValue, the G4 Zone.Identifier scan, runas.exe /smartcard including the nested \" quoting and the
1024-character program-string limit, and Start-Process -Verb RunAs. Every one of these is behind a mock seam that
was exercised, but the seam itself needs one Windows lab pass.
- Whether FSLogix values delivered by Local Group Policy appear as winning RSOP_RegistryPolicySetting rows. The
whole three-state provenance design (and therefore whether registry repairs come back GuidanceOnly or Registry on
the golden image) hangs on this. Inherited from Wave A and still unverified; one elevated Get-FslEffectiveSetting
-Scope Logging on the golden image settles it.
- The new ancestor walk in Test-FslToolkitPathSecurity was reasoned against the documented default ACLs of C:\ and
C:\Program Files (Authenticated Users Modify on C:\ is inherit-only and Modify does not contain
FILE_DELETE_CHILD/WRITE_DAC/WRITE_OWNER, so it is not flagged) but was only executed with POSIX paths. Confirm with
icacls on the real host that the chain above the install path reports Pass before relying on gate G3.
- Remove-Item -Recurse behaviour on directory reparse points is not documented on learn.microsoft.com. The retention
code now refuses to delete such folders rather than depending on it; if the owner wants expired junction-shaped
folders cleaned up, that needs a deliberate decision.
- Not re-reviewed (out of the assigned non-GUI scope): Private/Reporting/FslGui*.ps1 and GUI/*.xaml. Two of my
changes are additive but visible there - Test-FslToolkitPathSecurity now emits extra
ToolkitPathSecurity:ModuleRootAncestor rows, and FIX-SVC-03 can now report NotNeeded where it previously reported
Ready. Neither changes a signature, but the GUI owner should confirm the Repair grid and the Core results view
handle them.
- The default C:\ProgramData ACL is still undocumented by Microsoft, so Test-FslFixStateRoot still judges
%ProgramData%\FSLogixToolkit but not %ProgramData% itself (pre-existing, unchanged). Confirm with icacls on the
host, as REPAIR-PLAN section 9 already lists.

## GUI runtime review — confidence 86

| Severity | Fixed | Location | Problem |
|---|---|---|---|
| critical | yes | `Private/Reporting/FslGuiRunner.ps1:323` | The dashboard window could become impossible to close for the rest of the session. Invoke-FslGuiRepairDialog / Invoke-FslGuiRepairUndoAction / Invoke-FslGuiContainerResetDialog raise $State['Repair']['Applying'] BEFORE the operation is queued, and only Complete-FslGuiOperation lowers it. A queued Re… |
| high | yes | `Private/Reporting/FslGuiRepair.ps1:1276` | Preview-then-apply gating hole: the Apply confirmation MessageBox in Invoke-FslGuiRepairDialogAction lists only $applyState['Applicable'] (the ticked actions the preview reported as applicable, 'Apply {n} repair action(s) ... A, B'), but Invoke-FslGuiRepairDialog built the RepairApply operation from… |
| medium | yes | `Private/Reporting/FslGuiMenus.ps1:355` | Re-entrancy during the cancelled close. Close-FslGuiDashboardState sets CancelEventArgs.Cancel = $true and then shows a MessageBox from inside the Window.Closing handler. A MessageBox runs a nested dispatcher loop, so the 400 ms poll DispatcherTimer keeps firing while it is up and $state['Closing'] … |
| medium | yes | `Private/Reporting/FslGuiRelaunch.ps1:352` | Same nested-dispatcher hazard on the two new P3.7 File menu items. Get-FslGuiActionDefinition gives MnuRelaunchElevated and MnuRelaunchUser Kind 'View', so they stay enabled while background checks run. Invoke-FslGuiRelaunchAction then shows a modal MessageBox (Elevate) or the RunAs dialog (Differen… |
| medium | yes | `Private/Reporting/FslGuiRunner.ps1:733` | Complete-FslGuiOperation returns early for Status 'Cancelled', before the repair switch branch. A cancelled RepairApply/RepairUndo/ContainerReset therefore did NOT clear $State['Repair']['PreviewHash'] / PreviewActionId / PreviewAt, even though the run may have applied part of the selection before i… |
| low | yes | `Private/Reporting/FslGuiRunner.ps1:812` | The dialog-reopen flags were only consumed on a successful run: Complete-FslGuiOperation required $status -eq 'Completed' before setting Dialog = 'Repair' (RepairPlan, RepairPreview) or 'ContainerReset' (ContainerList). When one of those read-only operations failed (broken background runspace, Get-F… |

Unresolved / needs a Windows host:

- The build report's stated invariant 'No repair command runs while a dialog is open ... a dialog is only opened
when the operation queue is empty' is not actually true, and WPF does not guarantee it. Complete-FslGuiOperation
queues the RepairLog follow-up BEFORE Sync-FslGuiAfterOperation reopens the repair dialog, so the queue is non-empty
when the modal dialog appears; the WPF dispatcher keeps pumping during ShowDialog, so the only thing that stops that
queued operation from running behind the dialog is the $State['InTick'] re-entrancy guard in Invoke-FslGuiTimerTick
(dialogs reopened from Sync-FslGuiAfterOperation are already inside a tick). Behaviour is safe, but the documented
reasoning in FslGuiRepair.ps1's header and in Show-FslDashboard .NOTES should be corrected to name the InTick guard
as the real mechanism. Not changed here because it is documentation, not behaviour.
- Everything that only exists at WPF runtime is still untested - macOS has no PresentationFramework. Specifically
unverified by execution: XamlReader.Load of MainWindow/RepairDialog/ContainerResetDialog/RunAsDialog, FindName for
all 245 names (verified only by XML x:Name parity), the DataGridCheckBoxColumn two-way binding to the DataTable bool
column 'Selected', whether DataGrid.CommitEdit twice really commits a freshly clicked checkbox before Get-
FslGuiRepairTableSelection reads it, ToolTipService.ShowOnDisabled rendering on a disabled MenuItem, Window.Owner +
CenterOwner placement, and the Closing cancel itself. One Windows lab pass is still required: open the dashboard as
a standard user (Repair menu greyed with the tooltip), relaunch elevated, tick a plan row, Preview, Apply, then
click X during the apply and confirm the window refuses to close and becomes closable again as soon as the run ends.
- Start-FslCoreRelaunch actually starting an elevated (UAC) or runas /smartcard session from the GUI, and the
relaunched session writing to the passed -OutputPath, remain inherited Wave A lab items. The GUI only builds
-Arguments @{ContainerScope; OutputPath; Offline} and reports $false as a status-bar message.
- Get-FslRepairPlan is still called without -MaxRiskTier, so Settings Repair.MaxRiskTierDefault (2) applies and no
tier 3 action can appear in the plan dialog with the shipped defaults. The typed computer-name confirmation path is
implemented and unit tested but cannot engage unless the owner raises MaxRiskTierDefault. Left as the build agent
designed it (already listed in contractIssues).
- FIX-LOG-02 (temporary verbose logging, tier 1, OperatorSelected) still has no GUI entry point; it can only be run
from the launcher. P3.7 does not list a menu item for it, so this is an owner decision, not a defect.

## Integration tester

Module imports; exported functions **40**, matching the manifest. Confidence 88.

**Static checks**

Import-Module /Users/tastym0uz3/Downloads/_Software/POWERSHELL/FSLogixToolkit/FSLogixToolkit.psd1 -Force
-ErrorAction Stop succeeds on macOS/pwsh 7.5.2; ExportedFunctions = 40 and FunctionsToExport = 40 with an empty
symmetric difference. AST scans (scripts in /private/tmp/claude-501/-Users-tastym0uz3-Downloads--Software-
POWERSHELL-FSLogixToolkit/1726cb32-6b7d-4506-8107-0232d706f13b/scratchpad/it/ast1..ast7.ps1), all re-run after my
edits: (1) 497 function definitions across Private/ + Public/, zero duplicate names; (2) every literal -Parameter on
a call to Invoke-FslRepair, Undo-FslRepair, Get-FslRepairPlan, Test-FslRepairPrerequisite, Get-FslRepairLog, Test-
FslToolkitPathSecurity, Start-FslCoreRelaunch, New-FslFixRun, Save-FslFixRollbackEntry and every
Detect/Apply/Rollback handler named in Config/Repairs.psd1 exists as a real parameter, is a full name (no alias, no
prefix abbreviation) - 13 static call sites, 0 problems; (3) the GUI runner invokes those functions by name through
$invokeDeclared, so I resolved each of the 17 call sites' argument keys out of the AST ($arguments hashtable
literals plus index assignments, scoped by the last whole-hashtable reset) and checked them against the real
signatures - Get-FslRepairPlan(ContainerScope,ActionId,MaxRiskTier,Parameters), Test-FslRepairPrerequisite(Action),
Invoke-FslRepair(ActionId,ContainerScope,MaxRiskTier,AllowDisruptive,UserSignedOutConfirmed,ChangeReference,Paramete
rs,WhatIf,Confirm), Undo-FslRepair(RunId,Confirm,ActionId), Get-FslRepairLog(IncludeRecords,Days), Get-
FslContainer(Scope) - 0 problems; (4) Config/Repairs.psd1 has DataVerifiedOn 2026-09-17 and 10 actions (FIX-
SVC-01..04, FIX-LOG-01..04, FIX-ODFC-01, FIX-ODFC-02) and every Detect/Apply/Rollback name resolves to a function
inside the module session state; (5) 309 New-FslResult call sites - every literal -Category/-Status/-Scope is inside
the ValidateSets (Category adds Repair, Status Pass|Warn|Fail|Info|Skipped|Error, Scope General|ODFC|Profiles); the
369 dynamic Category/Status/Scope arguments were covered at runtime instead (no runtime ValidateSet error in any of
the 83 behaviour checks); (6) module-wide command resolution: every command invoked anywhere in Private/, Public/
and Start-FSLogixToolkit.ps1 resolves inside the module session state except 21 Windows-only inbox cmdlets (Get-
Service, Set-Service, Start-Service, Get-WinEvent, Get-CimInstance, Get-Counter, the
ScheduledTasks/Storage/SmbShare/Hyper-V sets) that are absent on macOS by design - no Fsl* name is unresolved. Shape
checks at runtime: FSLogixToolkit.RepairAction carries all 19 contract properties with a 64-hex SHA256 Fingerprint,
and FSLogixToolkit.RepairRecord carries all 22 contract properties.

**Regression**

Invoke-FslHealthCheck -Offline with the default ODFC container mode: 58 results, Scope General=52 / ODFC=6,
Profiles-scope = 0, Repair-category = 0 (categories BestPractice, Containers, Diagnostics, Discovery, Environment,
Network, Performance, Policy). In a temp copy of the whole project (/private/tmp/.../scratchpad/it/clean) with a
temp preference path and -OutputPath: Start-FSLogixToolkit.ps1 -NoGui -Offline exits 0 (CSV + HTML written) and
-Daily -Offline exits 0 (day folder with CSV, HTML and Summary_*.json). Daily writes no Repair records: no
Reports/Repair folder is created, the daily CSV has 0 ',Repair,' rows, and no rollback StateRoot is created. -Daily
-Offline -Repair -ActionId FIX-LOG-01 exits 0 and prints "The daily health check never runs repairs: -RepairPlan,
-Repair and -UndoRunId are ignored with -Daily." with still no Repair folder. Get-Help on the edited launcher still
parses fully. All of this was re-run after my fixes with identical results.

**Repair flow**

Behavioural testing ran on macOS against a temp copy of the module, with the Windows seams replaced inside the
module session state and a temp FSLOGIXTOOLKIT_REPAIR_STATEROOT + ReportRoot + FSLOGIXTOOLKIT_PREFERENCE_PATH per
test. IMPORTANT harness note for whoever repeats this: `& (Get-Module FSLogixToolkit) { function X {} }` does NOT
install a mock - the ampersand call gives the scriptblock its own scope, so the definition is discarded (probed:
"after & : False"). The dot-source form `. (Get-Module FSLogixToolkit) { function X {} }` is what lands the
definition in the module scope ("after . : True"); the harness at /private/tmp/.../scratchpad/it/common.ps1 uses
that. Mocked: Test-FslIsWindows, Test-FslElevation, Assert-FslElevation, Find-FslInstallation, Test-
FslCoreToolkitPathSecure, Get-FslFixBlockedFile, Get-FslFixFreeSpaceMB, Test-FslFixFolderSecurity, New-
FslFixProtectedDirectory (so the real Test-FslFixStateRoot logic still runs), Get-FslPolRsopState, Get-
FslEffectiveSetting, the four registry wrappers, the four service wrappers (all enforcing the real Test-
FslFixRegistryTarget / Test-FslFixServiceTarget allow-lists), and Get-FslContainer (enumerating, so a removed file
disappears from the list as the real one would). Test-FslMntFileInUse is deliberately NOT mocked - it is platform-
independent, so "container in use" was simulated with a real FileShare.None handle. 83 assertions across 8 scripts
(it/r1..r8.ps1), all green after the fixes: PLAN - 8 planned actions with statuses only from
Ready|Blocked|NotNeeded|GuidanceOnly, no wrapper write during planning, OperatorSelected FIX-LOG-02 and FIX-ODFC-02
absent from an unfiltered plan and FIX-LOG-02 present when named, ODFC scope filter yields no Profiles action, 48
pre-flight Results all Category Repair / Check Preflight:<Gate> covering G1-G8, G10, G12-G18, G21. WHATIF - Invoke-
FslRepair -WhatIf over 3 actions performs zero wrapper writes, creates no StateRoot, leaves the registry and service
state byte-identical, marks each action "WhatIf: would apply ..." and emits one RepairRun summary. APPLY+UNDO - FIX-
LOG-01 and FIX-SVC-04 applied (LoggingEnabled removed, defragsvc and smphost Disabled->Manual), rollback.json +
manifest.sha256 written and integrity-verified, then Undo-FslRepair restored the value, its DWord kind and both
start types back to Disabled with no Fail/Error. PROVENANCE - RSoP Failed -> plan Blocked and Invoke-FslRepair
refuses with "Blocked: ..." and zero writes; GroupPolicy provenance -> plan GuidanceOnly, apply is Warn "Guidance
only: ..." naming the winning GPO, zero writes, value unchanged. INTEGRITY - editing one number in rollback.json
makes Test-FslFixRollbackIntegrity fail, Undo refuses with nothing changed; independently, changing the value behind
the toolkit's back makes Undo refuse on drift with nothing changed. LOGS - Get-FslRepairLog lists the session's
runs, -RunId narrows to one, -IncludeRecords returns full RepairRecord rows. CONTAINER (FIX-ODFC-02) - with a temp
share folder, a 64 KB VHDX, a sibling metadata file and a temp archive: Ready with both attestations, Blocked
without -UserSignedOutConfirmed/-ChangeReference, Blocked while a real exclusive handle is held (and the apply then
archives nothing and leaves the source), apply copies + SHA256-verifies + removes the source while keeping the per-
user folder and the sibling file, Undo refuses while a new container exists at the original path (leaving both files
alone) and then restores the exact bytes and removes the archive copy once the path is free. LAUNCHER - -RepairPlan
exits 0 and prints the 8-row plan; -Repair refused by gate G3 exits 3 with "Blocked: the repair run was refused by
the pre-flight gates"; -Repair -Confirm:false exits 0 and applies; -Repair -WhatIf exits 0. EXTRA - Test-
FslToolkitPathSecurity returns exactly one Skipped Core result on a non-Windows host; a RobocopyLogPath value
containing sig=<token> is refused by the rollback store, the change is not applied and the raw token appears in zero
files under the whole test tree; Export-FslDiagnosticBundle includes Reports/Repair (7 entries) and nothing from the
rollback StateRoot (no rollback.json, manifest.sha256 or repair.lock).

**Fixes applied**

- /Users/tastym0uz3/Downloads/_Software/POWERSHELL/FSLogixToolkit/Private/Repair/FslFixContainer.ps1 (Get-
FslFixContainerResetState): HIGH - a successful Office container reset always reported Fail. Get-
FslFixContainerResetState set Needed = $true as soon as a user was selected and, when no container matched, only
added the reason 'No Office container was found ...' to BlockReason. That is exactly the state a successful reset
leaves behind, so the engine's G21 re-check (verified = Success -and -not Needed -and no BlockReason) could never
pass: a perfect, attested, tier-3 run produced Status Fail, VerificationStatus Failed, the message 'The change did
not verify ... Now: .' and the recommendation to run Undo-FslRepair - which at that moment would have copied the
archived container straight back, undoing the reset. The run summary became Fail and the launcher would exit 2. FIX:
when no candidate container exists AND no hard prerequisite reason was collected (platform, elevation,
ODFC/Profiles/CloudCache gates), the handler now returns Needed = $false with CurrentValue '(no Office container for
<selection>)' and an explanatory Message and no BlockReason. Re-tested: apply is now Pass 'Applied and verified'; a
user with no container plans as NotNeeded instead of Blocked; a non-elevated session with no container still plans
as Blocked and the reason still names both the elevation gate and the missing container.
- /Users/tastym0uz3/Downloads/_Software/POWERSHELL/FSLogixToolkit/Public/Repair/Invoke-FslRepair.ps1: HIGH - one
unanswerable confirmation prompt aborted the whole repair run. In a session that cannot show a prompt (redirected
stdin: a CI step, a remote invocation, a scheduled task) $PSCmdlet.ShouldProcess($target, $operation) throws
NullReferenceException, and the try/catch wrapped the entire action loop, so the first action killed the run: 0
actions attempted, every later -ActionId silently skipped, and two contradictory RepairRun Results (Error 'the
repair run stopped with an error' plus Pass '0 action(s), Pass 0, Fail 0'). Reproduced with `pwsh -NoProfile -File
... < /dev/null`. FIX: the ShouldProcess call is now in its own try/catch inside the loop - a prompt that cannot be
shown records that action as Mode Blocked / Status Fail with a Result that says to re-run with -Confirm:$false, and
the loop continues with the remaining actions; a new $runFaulted flag makes the run summary report Error instead of
Pass when the run really did stop with an exception, and the Undo recommendation is now also attached to an Error
summary. Re-tested: three actions each report the reason, the summary reads 'Fail 3' and the launcher exits 2 (not 3
- this is not a pre-flight refusal).
- /Users/tastym0uz3/Downloads/_Software/POWERSHELL/FSLogixToolkit/Public/Repair/Undo-FslRepair.ps1: the same
ShouldProcess hazard and the same 'crashed run summarises as Pass' hole in the undo path, fixed the same way (per-
entry try/catch recording Mode Blocked / Status Fail, plus $runFaulted in the summary).
- /Users/tastym0uz3/Downloads/_Software/POWERSHELL/FSLogixToolkit/Private/Repair/FslFixService.ps1 (Restore-
FslFixServiceStartType): LOW - every service undo appended the unconditional sentence 'A service that was started by
the repair is left running: the toolkit never stops services.', which is untrue for FIX-SVC-04 (defragsvc/smphost
are never started) and for FIX-SVC-01 when the service was already running. Reworded to 'If the repair started a
service, it is left running: the toolkit never stops services.' No behaviour change.
- /Users/tastym0uz3/Downloads/_Software/POWERSHELL/FSLogixToolkit/Start-FSLogixToolkit.ps1: LOW - the launcher help
documents '-Confirm:$false to skip the per-action confirmation prompt', but `pwsh -File Start-FSLogixToolkit.ps1 ...
-Confirm:$false` silently drops it (verified on the local pwsh 7.5.2: with -File the token is not bound at all,
$PSBoundParameters is empty and $ConfirmPreference stays High, while -Confirm:false binds correctly). Combined with
the defect above that meant the documented non-interactive invocation crashed the run. The help now says to write
-Confirm:false when the launcher is started with pwsh -File, and explains why.

**Unresolved**

- Nothing Windows-only was executed for real: registry SetValue/DeleteValue in the 64-bit view, Set-Service/Start-
Service, NTFS ACL reads (FileSystemAclExtensions) behind Test-FslToolkitPathSecurity and Test-FslFixStateRoot, the
G4 Zone.Identifier scan, Get-DiskImage attachment detection, runas.exe /smartcard and Start-Process -Verb RunAs.
Every one sits behind a seam I exercised, but the seams themselves still need one Windows lab pass (inherited from
the build and security agents).
- The GUI was not executed - macOS has no PresentationFramework, so no XAML was loaded and no dialog rendered. My
changes touch no GUI file, but two of them are visible there: a repair Result can now carry the message 'The
confirmation prompt could not be shown in this session ...' (the GUI always passes -Confirm:$false, so it should not
occur), and FIX-ODFC-02 can now come back NotNeeded, which the container-reset dialog must show sensibly. Worth one
look during the Windows GUI pass.
- My prompt-failure Result message deliberately does NOT start with 'Blocked: ', so the launcher maps it to exit 2
rather than the pre-flight exit 3. That is the reading I judged correct (nothing was refused by a gate), but it is a
judgement the owner may want to confirm, as is the choice to record it as Mode 'Blocked' / Status 'Fail' rather than
reusing the operator-declined Mode 'Declined' / Status 'Skipped'.
- Making 'no Office container for this user' a NotNeeded instead of a Blocked action is a visible plan-status change
for FIX-ODFC-02 (for example a mistyped -RepairUserName now reads NotNeeded with an explanation instead of Blocked).
It is the only way the G21 verification can pass, but the owner should be aware of the wording change in the GUI
dialog and in the launcher plan table.
- Whether FSLogix values delivered by Local Group Policy appear as winning RSOP_RegistryPolicySetting rows is still
the open lab item inherited from Wave A. I exercised both branches through the mocked provenance (GroupPolicy ->
GuidanceOnly, Unknown -> Blocked, Registry -> Ready), but which branch a real golden image takes is unverified.
- Retention (Remove-FslFixOldRun), the cross-session single-run lock under Windows, and the temporary-change expiry
of FIX-LOG-02 were not re-exercised here; the P3-4 and security agents covered them and nothing I changed touches
that code.
- The 12 remaining PSScriptAnalyzer advisories are pre-existing PSUseCompatibleTypes/PSUseCompatibleCommands entries
measured against the PowerShell 7.0 profile (Environment.ProcessPath,
RuntimeInformation.OSDescription/OSArchitecture, Convert.ToHexString, SHA256.HashData, Invoke-RestMethod/Invoke-
WebRequest timeout parameters). All are available on the 7.4+ target, none is in a file I edited.

## Requirements critic — confidence 88

| Requirement | Met | Severity |
|---|---|---|
| Allow a prompt to relaunch/run the toolkit as a selected user with a smart card (because an elevated session is a different profile) | yes | none |
| Problem 1 - three-state Group Policy provenance (GroupPolicy \| Registry \| Unknown), with Unknown blocking registry writes | yes | none |
| Problem 2 - elevated-from-a-user-writable-folder risk (warn in the launcher, refuse repairs) | yes | none |
| Problem 3 - smphost added next to defragsvc in the compaction check | yes | none |
| Problem 4 - wrong Diagnostics comment about the ODFC component log / LoggingEnabled default | yes | none |
| Build the undo store (authoritative, admin-only, hash-verified, backup before change) | yes | none |
| Build the repair logs (readable + structured copies, records, run envelope, retention) | yes | none |
| Command-line repairs: FSLogix services | yes | none |
| Command-line repairs: compaction services | yes | none |
| Command-line repairs: logging settings | yes | none |
| Command-line repairs: Office container refresh-policy setting | yes | none |
| Command-line surface for repairs (plan, apply, undo) with the daily task never repairing | yes | none |
| GUI Repair menu (disabled unless elevated; existing views stay read-only) | yes | none |
| GUI Office container reset (archive, verify, undo) | yes | none |
| Nothing from the plan's 'Later' list was built (installer repair, Defender exclusions, VHD dismount, SizeInMBs, frx start-agent, naming fix, CleanupInvalidSessions, ODFC retry values, Cloud Cache, maintenance wrappers) | yes | none |
| No code handles passwords or PINs | yes | none |
| Everything else only after testing on a Windows VM | partial | medium |
| Owner fact: FSLogix settings are delivered by Local Group Policy - registry repairs must not fight the GPO | partial | medium |

**Gaps**

- **Everything else only after testing on a Windows VM**
  All Windows seams remain lab-unverified, as the owner's condition anticipated - this is the sign-off that is still
  owed, not a build gap. Worth one Windows VM pass over: registry write/undo, service start-type write/undo, the
  ACL/owner checks on C:\ProgramData and the toolkit folder, the Zone.Identifier gate, runas /smartcard, and the
  Repair + Container Reset dialogs.
- **Owner fact: FSLogix settings are delivered by Local Group Policy - registry repairs must not fight the GPO**
  Residual risk in one mixed case: if the host has any GPO at all (GpoCount > 0 -> status Ok) but the Local-GPO-
  delivered FSLogix rows do NOT surface in RSOP_RegistryPolicySetting, provenance resolves to Registry and the
  repair writes - and the G8 Pass message asserts flatly 'The value is not delivered by Group Policy'
  (FslFixPreflight.ps1:448) while the Registry detail text (FslPolicyHelpers.ps1:386) lists 'set locally, by other
  tooling or left behind by a removed GPO' without naming Local Group Policy as a possibility. Values under
  HKLM\SOFTWARE\FSLogix are ADMX preferences, so a local GPO would silently re-apply them at the next refresh.
  Either confirm in the lab that local GPO rows appear, or soften the Registry/G8 wording to say Local Group Policy
  delivery could not be confirmed.

**Out-of-scope check**

- Nothing outside the owner's request was found in the module surface: FSLogixToolkit.psd1:9-36 exports the five
contract repair functions plus Test-FslToolkitPathSecurity and no other new public function, and Config/Repairs.psd1
holds only the 10 approved R2/R3 actions.
- Borderline (not a violation, worth the owner's eye): Config/Repairs.psd1:118-139 FIX-SVC-03 sets frxccds (the
FSLogix Cloud Caching service) start type to Automatic and, uniquely among the service actions, carries
StartIfStopped = $true - on a host the owner says has no Cloud Cache. It is OperatorSelected = $false, so it appears
in an unfiltered plan, although -Repair still requires it to be named with -ActionId (Start-
FSLogixToolkit.ps1:511-514). The catalog guidance at :138 acknowledges the host has no Cloud Cache and frames the
action as restoring documented service configuration only. If frxccds is deliberately disabled as hardening on the
image, this action would undo that; consider flipping it to OperatorSelected = $true.

**Credential handling check**

- No credential handling exists anywhere in the codebase: zero hits for Get-Credential, -Credential, PSCredential,
SecureString, ConvertTo-SecureString or PasswordBox across Private/, Public/, GUI/ and Start-FSLogixToolkit.ps1.
- Smart-card sign-in is delegated entirely to Windows: Private/Core/RelaunchHelpers.ps1:166-227 builds only
`[/smartcard] /user:<name> "<program>"` and RelaunchHelpers.ps1:432-448 launches runas.exe, which collects the PIN
in its own console (comment at :447). /savecred and /netonly are documented as never used (:175) and appear nowhere
in the code.
- Command-line injection surface is closed rather than merely documented: New-FslCoreRunAsArgumentString rejects any
program argument that is not a simple switch or Base64 (RelaunchHelpers.ps1:204-210), rejects a quote in the
executable path (:201-203), and validates the user name against a DOMAIN\user / UPN pattern that excludes
whitespace, quotes and % (:21, :198-200); the launcher repeats the same pattern as a ValidatePattern (Start-
FSLogixToolkit.ps1:215-217).
- The GUI run-as dialog collects only a user name and an 'elevate after sign-in' checkbox
(GUI/RunAsDialog.xaml:32,34) and states in its own comment and on-screen text that Windows asks for the smart card
and PIN (:12-13,:39).
- Adjacent, pre-existing and still password-free: the daily scheduled task is registered without a stored password
(Public/Daily/Register-FslDailyHealthCheck.ps1:15).
- Secret hygiene beyond credentials: the rollback store refuses to persist a value containing a secret token
(Private/Repair/FslFixState.ps1:486-502) and all repair log text passes through ConvertTo-FslCoreRedactedText
(Private/Repair/FslFixLog.ps1:5).

## Fixer

**Fixed**

- **G8 pre-flight Pass message asserted flatly that the value is not delivered by Group Policy (Private/Repair/FslFixPreflight.ps1)**
  FslFixPreflight.ps1:445-454 - the Registry branch of gate G8 now reports what RSoP actually proved: Message is "No
  winning Group Policy entry was found for this value in computer RSoP, so the registry value is written: <detail>",
  and a new Recommendation says Group Policy delivery could not be ruled out completely and tells the operator to
  confirm in gpedit.msc (script:FslFixGroupPolicyPath) that the setting is Not Configured, otherwise the next
  refresh re-applies the policy value over the repair. A comment above the branch records why (local-GPO RSoP rows
  are an open lab item). The Warn (GroupPolicy) and Fail (Unknown) branches are untouched.
- **Registry provenance detail text did not name Local Group Policy as a possibility (Private/Policy/FslPolicyHelpers.ps1)**
  FslPolicyHelpers.ps1:394 - SourceDetail for Source='Registry' now reads '... no winning Group Policy entry for
  this value (set locally, by Local Group Policy if its registry entries are not listed in RSoP, by other tooling,
  or left behind by a removed GPO; MDM delivery is not detected)'. The Get-FslPolProvenance comment block (:335-345)
  now states explicitly that 'Registry' means "no winning RSoP row", not a proven absence of Group Policy, and
  cross-references the open lab item in Get-FslPolRsopData.
- **Same flat claim in the Discovery/GPO report (Public/Policy/Get-FslGpoReport.ps1)**
  Get-FslGpoReport.ps1:183 - the Info finding's parenthetical now includes 'by Local Group Policy if its registry
  entries are not listed in RSoP' alongside the existing possibilities. The Check name and Result shape are
  unchanged so report consumers are unaffected.
- **Operator-facing documentation of the Registry provenance state (README.md)**
  README.md:184-189 - new paragraph in the 'Group Policy on this image' section: Registry means no winning RSoP
  entry was found, not proven not to be Group Policy; whether Local Group Policy surfaces as RSoP registry entries
  is still a lab item on this image; check gpedit.msc for Not Configured before relying on a registry repair.
- **Borderline finding: FIX-SVC-03 (frxccds, Cloud Caching service) was planned automatically with StartIfStopped on a host the owner says has no Cloud Cache**
  Config/Repairs.psd1:132 - OperatorSelected flipped from $false to $true, so FIX-SVC-03 is never planned
  automatically and cannot be swept up by a pipeline apply (Get-FslRepairPlan | Invoke-FslRepair); it still runs
  normally when named in -ActionId, like FIX-LOG-02 and FIX-ODFC-02. Guidance text (:138) explains why: a disabled
  frxccds on this image may be deliberate hardening. Docs updated to match: README.md:160 and the comment-based help
  in Public/Repair/Get-FslRepairPlan.ps1:18. Revert is a one-word change back to $false if the owner prefers it
  visible by default.
- **Launcher toolkit-path warning implied the elevated session was still safe (Start-FSLogixToolkit.ps1)**
  Start-FSLogixToolkit.ps1:348 - the SECURITY WARNING block now states that the check runs after the module import,
  so toolkit code from that folder has ALREADY run with administrator rights, and tells the operator to treat the
  session as untrusted (close it, verify the files, restart from an admin-only folder). A comment above Import-
  Module (:291-295) records that folder integrity is a deployment precondition the launcher cannot enforce, because
  the launcher itself lives in the same folder. README.md:47-52 documents the same limitation in the Security
  section. No behaviour change: contract P3.1 item 3 (warn, health checks continue, gate G3 refuses repairs) is
  preserved.
- **Windows VM sign-off items were spread across three docs with no actionable list**
  Docs/SESSION-STATE.md:64-90 - new 'Windows VM sign-off checklist (Phase 3 - nothing below has ever executed)' with
  the nine seams named in the requirement gap: Registry64 SetValue/DeleteValue + undo, Set-Service/Start-Service +
  undo, the NTFS ACL reads behind Test-FslToolkitPathSecurity and Test-FslFixStateRoot, the G4 Zone.Identifier gate,
  the local-GPO RSoP question, the container reset (Get-DiskImage, exclusive-open, SHA256, MoveBack), runas
  /smartcard and Start-Process -Verb RunAs, the GUI pass (including FIX-ODFC-02 NotNeeded and the 'confirmation
  prompt could not be shown' message), and retention/single-run lock/FIX-LOG-02 expiry.

**Not fixed**

- **Requirement gap 1 - 'Everything else only after testing on a Windows VM': registry writes in the Registry64 view, Set-Service/Start-Service, the NTFS ACL reads, the G4 Zone.Identifier scan, Get-DiskImage, runas.exe /smartcard, Start-Process -Verb RunAs and the entire GUI have still never executed.**
  Not fixable from this environment: the host is macOS (darwin 25.6.0) with no Windows registry, no service control
  manager, no NTFS ACLs and no PresentationFramework, so no Windows-only path can be executed and no XAML can be
  rendered. This is the owner's own condition (a lab sign-off owed), not a build defect. What I could do instead I
  did: the nine outstanding seams are now an ordered checklist in Docs/SESSION-STATE.md:64-90, including the two
  GUI-visible Phase 3 changes (FIX-ODFC-02 NotNeeded, the 'confirmation prompt could not be shown' Result message).
- **Requirement gap 2 - residual risk that FSLogix values delivered by Local Group Policy do not surface as RSOP_RegistryPolicySetting rows, so provenance resolves to Registry and a repair writes over a value the GPO re-applies.**
  The underlying question can only be answered on a Windows host with the golden image's local GPO, so I took the
  second option the gap offered and softened the wording everywhere the claim appeared (G8 Pass message, Registry
  SourceDetail, the Discovery report finding, README). The detection logic is deliberately unchanged: making
  Registry behave like Unknown would block every registry repair on a host with any GPO, which is not what the owner
  asked for. Checklist item 5 in Docs/SESSION-STATE.md is the lab test that settles it.
- **High finding at Start-FSLogixToolkit.ps1:291 - the module is imported (dot-sourcing every .ps1 under Private/ and Public/) before Test-FslToolkitPathSecurity runs, so planted code has already executed with administrator rights by the time the warning is printed.**
  Left unfixed in code, for two reasons. (1) Contract P3.1 item 3 is explicit: when elevated and insecure the
  launcher warns and health checks continue, repairs refuse at gate G3 - refusing to load would change documented
  startup behaviour. (2) More importantly, the recommended in-launcher check would not close the hole: Start-
  FSLogixToolkit.ps1, FSLogixToolkit.psd1/.psm1 and every dot-sourced file live in the same folder, so any principal
  who can plant a .ps1 there can equally replace the launcher (including the check itself). It would only cover the
  narrow case of a protected root with a writable subfolder, at the cost of ~60 lines of Windows-only ACL code that
  cannot be exercised before the VM pass and that could refuse startup on a false positive. The real mitigation is
  deployment: an admin-only path (REPAIR-PLAN Q2, still unanswered). What I changed is the accuracy of the warning -
  it now says the code has already run elevated and the session must be treated as untrusted - plus the same
  statement in README.md:47-52 and the comment at Start-FSLogixToolkit.ps1:291-295.
- **Out-of-scope / credential-handling review findings**
  Nothing to fix: the reviewer found no out-of-scope public surface (the manifest exports only the five contract
  repair functions plus Test-FslToolkitPathSecurity, and Config/Repairs.psd1 holds only the 10 approved actions) and
  no credential handling anywhere. The single borderline item, FIX-SVC-03, is listed under fixed. I re-verified the
  catalog after the edit: 10 entries, ids unchanged, OperatorSelected true only for FIX-SVC-03, FIX-LOG-02 and FIX-
  ODFC-02.

Validation after the fixer: Full validation clean on the real tree: FSL_PSSA_PATH=<scratchpad>/psmodules/PSScriptAnalyzer/1.25.0/PSScriptAnalyzer.psd1 pwsh -NoProfile -File Tests/Invoke-FslValidation.ps1 -> "Validated 98 file(s). BLOCKING: none." The same 12 pre-existing PSUseCompatibleTypes/PSUseCompatibleCommands advisories against the PowerShell 7.0 profile remain (Environment.ProcessPath, RuntimeInformation.OSDescription/OSArchitecture, Convert.ToHexString, SHA256.HashData, Invoke-RestMethod/Invoke-WebRequest timeout parameters) - unchanged in count and location from the baseline, none in a file I edited. Targeted tests ran against a TEMP copy of the whole tree at <scratchpad>/fixcopy via <scratchpad>/fixtest.ps1: 14/14 checks pass - Registry provenance still resolves to Registry and its SourceDetail now names Local Group Policy; Unknown and GroupPolicy branches unchanged (GroupPolicy still returns PolicyName); FIX-SVC-03 absent from an unfiltered Get-FslRepairPlan and present when named in -ActionId, FIX-SVC-01 still present; with provenance overridden to Registry inside the module scope, gate G8 still emits Status Pass, the message no longer contains "is not delivered by Group Policy", it now reads "No winning Group Policy entry ...", and the new Recommendation names Local Group Policy. Catalog integrity re-checked directly: 10 definitions, ids unchanged, OperatorSelected true only for FIX-SVC-03/FIX-LOG-02/FIX-ODFC-02. FIX-ODFC-02 produces no plan entry on macOS (it needs a real ODFC container) - pre-existing, unrelated to these edits. Start-FSLogixToolkit.ps1 parses with 0 errors. Logs/, Reports/ and Modules/ still contain only their placeholder files. Files changed: Private/Repair/FslFixPreflight.ps1, Private/Policy/FslPolicyHelpers.ps1, Public/Policy/Get-FslGpoReport.ps1, Public/Repair/Get-FslRepairPlan.ps1, Config/Repairs.psd1, Start-FSLogixToolkit.ps1, README.md, Docs/SESSION-STATE.md.

