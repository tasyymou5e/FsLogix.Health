# FSLogix Repair Features — Plan (PROPOSAL ONLY, NOT APPROVED)

Status: **plan only — no repair code exists.** Prepared 2026-09-17 by a separate planning agent, fact-checked by four
adversarial verifier agents, reviewed by the master agent. Nothing below is implemented until the open questions in §8
are answered and the plan is approved.

Target: Windows 11 24H2 / Server 2025 AVD session hosts, PowerShell 7.4+, FSLogix **Office Containers (ODFC) only**.

## 0. Decisions from the owner (2026-09-17)
| Question | Answer | Effect on the plan |
|---|---|---|
| Repairs in the GUI? | **Yes** | GUI Repair menu + preview/apply dialog is in scope (R3) |
| How are FSLogix settings delivered? | **Local Group Policy baked into the image** | Registry repairs of GP-delivered values are **blocked** (the local GPO would re-apply them). For those, the repair shows the exact Local Group Policy setting to change instead of writing the registry. Programmatic local-GPO editing (e.g. LGPO.exe) is **not** planned: not inbox, would need a download. Service repairs are unaffected. |
| Cloud Cache for Office containers? | **No** | All Cloud Cache items (FIX-CCD-01/02) dropped; the "not Cloud Cache" gate becomes a simple check that `CCDLocations` is absent for ODFC |
| FSLogix upgrades? | **In place, in the golden image** | Installer repair/upgrade (FIX-INS-01/02) is an **image-maintenance** action for the golden image VM only, never run on pooled session hosts; stays "Later" |
| Office container reset in the GUI? | **Allow** | FIX-ODFC-02 moves from "Later" into scope (R3 GUI) with the gates in §2 |

Still open: toolkit install location on hosts (Q2), Defender management (Q7), rollback store/retention (Q8), change reference (Q9), host pool type/drain (Q10), user names in logs (Q11).

---

## 1. Master review verdict

The plan is **sound in approach** (documented-only repair catalog, preview first, per-value rollback, no repairs from
the daily task) but was **corrected in 8 places** after verification, and **two defects in the existing toolkit must be
fixed before any repair code is written**.

### Blockers found in the current code (verified)
| # | Issue | Evidence | Why it blocks repairs |
|---|---|---|---|
| B1 | `Get-FslEffectiveSetting` reports `Source = Registry` when **not elevated** or when the **RSoP query fails** — "not delivered by Group Policy" and "unknown" look identical | `Public/Policy/Get-FslEffectiveSetting.ps1:50-62`, `Private/Policy/FslPolicyHelpers.ps1:263-272` | A registry repair could overwrite a value your GPO delivers (and GPO re-applies it at next refresh). Provenance must become **GroupPolicy / Registry / Unknown**, and Unknown must block writes. |
| B2 | Running **elevated from a user-writable folder** (you run from `C:\Temp\FSLogixToolkit\FSLogixToolkit`) | `Start-FSLogixToolkit.ps1:139-156` prepends `<root>\Modules` to PSModulePath; `FSLogixToolkit.psm1` dot-sources every `*.ps1` under `Private`/`Public` recursively; elevated relaunch at line 235 | Any standard user who can write to that folder can plant a `.ps1` or module that runs as admin. **This is a risk today**, not only for repairs. Install the toolkit under an admin-only path (e.g. `C:\Program Files\FSLogixToolkit`). |

### Other verified defects to fix as pre-work
- `Private/Maintenance/MaintenanceHelpers.ps1:375-392` checks `defragsvc` only; Microsoft states compaction relies on **both `defragsvc` and `smphost`**.
- `Private/Diagnostics/FslDiagnosticsHelpers.ps1:286-288` comment says the ODFC component log is off by default. With the documented default `LoggingEnabled = 2` **all** logs are on (component switches only apply when `LoggingEnabled = 1`). Behaviour is already correct; the comment is wrong.

### Corrections made to the planning agent's proposal
| Item | Planner said | Verified reality | Master decision |
|---|---|---|---|
| FIX-SVC-02 start stopped `frxsvc` | cited troubleshooting-fslogix-service | That page recommends **upgrade to latest + open a support case**; it never recommends restarting | Keep *start-if-stopped* only (no stop/restart), record evidence first, show Microsoft's upgrade/support guidance; do not cite that page as supporting a restart |
| FIX-SVC-04 `defragsvc`/`smphost` | "Set to Manual", Event 60 / 00000422 | Doc accepts **Manual or Automatic**; errors are `00000422` **or** `00000102` (not mapped to a service); Event 60 (Admin log) names defragsvc only | Only change **Disabled → Manual**; keep Automatic; add smphost detection; detect and report if GPO/baseline re-disables |
| FIX-LOG-02 temporary verbose logging | "apply without restart unverified" | Only `LogDir` documents reboot/service restart; others unstated | Keep; mark `EffectiveWhen = Unknown`; never set `LoggingEnabled = 1` to "turn on" a component log (it would switch off other logs) |
| FIX-BPA-01 ODFC 3/15/3/15 retry values | Include (R3) | Confirmed "Recommended" in the ODFC how-to; they are **not defaults** (defaults 12/5/60/10) | Keep as later, operator-selected; never label as "reset to default" |
| FIX-BPA-02 ODFC VolumeType → VHDX | Include (R3), "new containers only" | Changing the container type on an existing environment can make FSLogix miss the existing container and create a new empty one (same class of risk Microsoft documents for naming settings) | **Moved to Reject** until verified in a lab |
| FIX-SIZE-01 raise SizeInMBs | "affects dynamic disks" | Doc: existing containers are **extended automatically at sign-in**; value can be increased but never decreased; no dynamic-only condition | Later; state the host-wide effect clearly |
| FIX-KI-01 / CIS-01 CleanupInvalidSessions | KI-001 gate; "KI-027 deadlock" gate | KI-001 affects only **Profiles + ODFC** on 26.01 and was fixed in **26.01 CU1 (3.26.126.19110)**; the ODFC sign-out deadlock fix is in **26.08 (3.26.826.17182)** with affected versions not stated; Microsoft says fix root causes first | KI-01 **not applicable** to ODFC-only hosts; CIS-01 later, operator-selected, conservative version gate |
| ODFC registry path | noted doc conflict | Confirmed: how-to **sample** writes `HKLM:\SOFTWARE\FSLogix\ODFC`; table and reference use `HKLM\SOFTWARE\Policies\FSLogix\ODFC` | Repairs write only the **Policies** path; stray values under the non-Policies key become an Info finding |
| Rollback via `reg export`/`reg import` | rejected | Confirmed: import only copies contents; no documented deletion of values the repair created | Per-value JSON rollback that explicitly deletes created values |
| Protected state folder via `FileSystemAclExtensions.Create` | owner check needed | Confirmed: "If the directory already exists, nothing is done" | Refuse if the folder pre-exists with a non-admin owner/ACL; verify `C:\ProgramData` ACL with `icacls` on the host (Microsoft doesn't document it) |

---

## 2. Repair catalog (after review)

Tier: 0 read-only · 1 reversible low-risk · 2 persistent config change with backup · 3 disruptive / data / not fully reversible.
All Tier ≥ 1 actions require elevation, `-WhatIf` preview, confirmation, backup, and post-check.

### Release R2 — first wave (ODFC-only relevant, all documented)
| ID | Condition | Action | Scope | Tier | Rollback | Source |
|---|---|---|---|---|---|---|
| FIX-SVC-01 | `frxsvc` start type ≠ Automatic | `Set-Service -StartupType Automatic` | General | 2 | restore previous start type | reference-service-drivers-components |
| FIX-SVC-02 | `frxsvc` Stopped (Automatic) | collect events, `Start-Service` once (no stop/restart, no loop); show upgrade/support guidance | General | 1 | n/a (recorded) | reference-service-drivers-components; troubleshooting-fslogix-service (guidance) |
| FIX-SVC-03 | `frxccds` start type/status wrong | same as 01/02, after `frxsvc` (documented dependency) | General | 1–2 | restore start type | reference-service-drivers-components |
| FIX-SVC-04 | `defragsvc` or `smphost` **Disabled** while compaction is enabled | set Disabled → Manual (Automatic left unchanged) | General | 2 | restore Disabled | troubleshooting-vhd-disk-compaction |
| FIX-LOG-01 | `LoggingEnabled = 0` | remove value (documented default 2) | General | 2 | restore 0 | reference-configuration-settings (Logging) |
| FIX-LOG-02 | operator needs troubleshooting data | temporary `LoggingLevel = 0` (verbose) with expiry; daily check warns after expiry; Undo restores | General | 1 | restore/remove | reference-configuration-settings (Logging) |
| FIX-LOG-03 | `LogFileKeepingPeriod > 180` | set 180 (documented max) | General | 2 | restore | reference-configuration-settings (Logging) |
| FIX-LOG-04 | `RobocopyLogPath` present | remove ("troubleshooting only") | General | 2 | restore | reference-configuration-settings (Logging) |
| FIX-ODFC-01 | ODFC `RefreshUserPolicy ≠ 0` | set default 0 ("revert to default after the GPO event") — Policies path only | ODFC | 2 | restore | reference-configuration-settings (ODFC) |

Registry actions (LOG-*, ODFC-01) are **blocked** whenever provenance is GroupPolicy **or Unknown** (B1).
**On this image (local GPO delivery) they will normally be Blocked → "Change in Local Group Policy"** with the policy name and
the value to set; the toolkit re-checks after the operator runs `gpupdate /force`. Needs lab confirmation that Local Group Policy
values appear in RSoP (`RSOP_RegistryPolicySetting`) so provenance reports GroupPolicy rather than Registry.

### Release R3 — GUI + Office container reset (approved in principle)
| ID | Condition | Action | Scope | Tier | Rollback | Source |
|---|---|---|---|---|---|---|
| FIX-ODFC-02 | operator selects a user whose Office container is corrupt / unusable | **Move** that user's ODFC VHD(X) (and its folder files) from the VHDLocations share to an admin-chosen archive path; FSLogix creates a new empty Office container at next sign-in | ODFC | 3 | move back **only if** no new container was created since | concepts-container-types ("easily replaced should the ODFC container become corrupted or deleted") |

Gates for FIX-ODFC-02 (all required): elevated · ODFC enabled and Profiles disabled (so the container holds only Office data) ·
`CCDLocations` absent · container file opens exclusively from this host (detects attachment by **any** host) and is not attached
locally · operator confirms the user is signed out of every session host · archive path reachable with enough free space and the
operator/computer account has write access on the share · change reference · GUI typed confirmation of the user name ·
warning text: *"Most data"* is re-synced from Microsoft 365 (Outlook cache, OneDrive, Teams); local-only or unsynced items
(e.g. local OneNote notebooks) in the container will not be in the new one until the archive is restored.
Note: Logging/Apps/Profiles values written by the FSLogix ADMX live under `SOFTWARE\FSLogix` and persist after a GPO is removed; ODFC values under `SOFTWARE\Policies` reset with the GPO (how-to-use-group-policy-templates).

### Later (needs Windows lab verification and/or your answers)
| ID | Action | Why later |
|---|---|---|
| FIX-BPA-01 | ODFC retry values 3/15/3/15 | operator decision; tutorial recommendation, not default |
| FIX-CIS-01 | enable `CleanupInvalidSessions` | symptom mitigation; version gate; Microsoft says fix root cause first |
| FIX-INS-01/02 | FSLogix installer `/repair` or `/install` with `/quiet /norestart /log`, user-supplied signed installer, no downgrade — **golden image VM only** (image-maintenance mode) | no documented exit codes; reboot required after install/upgrade; downgrade = uninstall + reboot + install; upgrades are done in the golden image |
| FIX-VHD-01 | dismount a VHD left attached with no session | attachment detection by `Get-DiskImage` unverified; prefer upgrade (26.08 fixed a stuck-provider detach issue) + drained reboot |
| FIX-AV-01 | Microsoft Defender exclusions | audit first; many FSLogix rows are not valid Defender path exclusions; `%TEMP%` expands as SYSTEM; local exclusions ignored when merge is disabled — must read back |
| FIX-SIZE-01 | raise `SizeInMBs` | increase-only; existing containers extend at next sign-in |
| FIX-DRV-01 | `frx start-agent` | documented but no usage guidance; `stop-agent` would disrupt every signed-in user — lab only |
| FIX-NAME-01 | naming-setting mismatch (revert setting + restart `frxsvc`, or rename with users signed out) | detection heuristic unverified; service restart has no documented safe procedure |
| FIX-MNT-01/02 | catalog wrappers for existing shrink / stale-container archive | reuse existing safe code |

### Rejected
Local/temp profile deletion (on ODFC-only hosts these are the users' real profiles) · profile container reset ·
ODFC `VolumeType` change (FIX-BPA-02) · `fltmc`/`sc` driver loading · closing SMB handles from the host (storage-side task;
user must be signed out of all sessions first) · DCOM permission edits · `RoamIdentity` / `redirections.xml` workarounds ·
turning on `PreventLoginWithTempProfile/Failure` (policy decision) · KI-001 CleanupInvalidSessions mitigation (not applicable to ODFC-only).

---

## 3. Pre-flight gates (must all pass; no `-Force` bypass)
G1 Windows + PS 7.4+ · G2 elevated · **G3 toolkit folder not writable by non-admins** · G4 files unblocked (Zone.Identifier) ·
G5 FSLogix installed, version parsed · G6 per-action version gates · G7 container mode scope (Profiles actions blocked in ODFC mode) ·
**G8 provenance three-state (GroupPolicy/Unknown → blocked)** · G9 no active sessions (Tier 3; locale-safe method TBD) ·
G10 container not locked/attached (recheck immediately before acting) · G11 drain attested by operator (Tier 3) ·
G12 maintenance window (optional) · G13 change reference (Tier 3 or configured) · G14 backup written and hash-verified before change ·
G15 disk space · G16 pre-repair snapshot · G17 plan freshness / no drift since preview · G18 single run lock ·
G19 installer signature/version/staging (INS only) · G20 pending reboot (INS only) · G21 post-repair verification.

---

## 4. Log output design
- **Readable + structured copies:** `Reports\Repair\<yyyy-MM-dd>\Repair_<HHmmss>_<RunId8>.log | .json | .csv`, plus `PreSnapshot_*.json` / `PostSnapshot_*.json`.
- **Per action record** (`FSLogixToolkit.RepairRecord`): Timestamp, RunId, Sequence, ComputerName, ActionId, Title, Scope, RiskTier,
  Mode (WhatIf/Executed/Declined/Blocked), Target, BeforeState, AfterState, ExpectedState, Status, VerificationStatus, Message,
  Operator, IsElevated, ChangeReference, RollbackAvailable, RollbackRef, Source.
- **Run envelope:** RunId, operator, elevation, PS/toolkit/FSLogix versions, container mode, mode (WhatIf/Apply/Undo), change reference, preflight results, snapshots, summary.
- **Rollback store (authoritative, admin-only):** `%ProgramData%\FSLogixToolkit\RepairState\<RunId>\rollback.json` + `manifest.sha256`; refuse if the folder pre-exists with a non-admin owner; Undo verifies hash and refuses on drift.
- Uses existing `Write-FslLog` / `Add-FslError` / `New-FslResult` (new Category `Repair`); all text redacted; allow-list of repairable value names (never `VHDLocations`/`CCDLocations`); retention 180 days (proposed); optional console-only `-Transcript`; repair logs (not the rollback store) added to `Export-FslDiagnosticBundle`.

## 5. Safety model
Preview (`Get-FslRepairPlan`) is always first · `Invoke-FslRepair` ConfirmImpact High · default max Tier 2 · Tier 3 needs
`-AllowDisruptive -DrainConfirmed -ChangeReference` (+ typed computer name in GUI) · no "repair all" · containers are never deleted,
only archived · every refusal shown as Blocked with a reason · **the daily scheduled task never runs repairs**.

## 6. Proposed surface
- `Get-FslRepairPlan`, `Test-FslRepairPrerequisite`, `Invoke-FslRepair`, `Undo-FslRepair`, `Get-FslRepairLog` (approved verbs verified locally); private prefix `*-FslFix*`; data in `Config/Repairs.psd1`; settings section `Repair`.
- Launcher: `-RepairPlan`, `-Repair -ActionId …`, `-UndoRunId`; exit code 3 = refused by pre-flight.
- GUI: separate **Repair** menu (disabled unless elevated) → preview dialog → apply → history/log viewer; existing views stay read-only. New control names must be added to `Get-FslGuiControlNameList` and the XAML.
- Contract changes: Category `Repair`, RepairAction/RepairRecord shapes, GUI read-only rule amended.

## 7. Delivery phases
| Phase | Content |
|---|---|
| **R0.5 pre-work** | B1 three-state provenance · B2 elevated-from-writable-folder warning/refusal · smphost check · fix diagnostics comment · Info finding for stray non-Policies ODFC values |
| R0 | contract Phase 3, `Config/Repairs.psd1`, `Repair` settings |
| R1 | protected state store, hash manifest, run lock, log writers, retention |
| R2 | repair engine + FIX-SVC-01..04, FIX-LOG-01..04, FIX-ODFC-01 (CLI; GP-delivered values → Local Group Policy guidance) |
| R3 | **GUI Repair menu, preview/apply dialog, repair log viewer, FIX-ODFC-02 Office container reset** (approved) |
| R4 | "Later" items, only after Windows lab sign-off; installer actions in golden-image mode only |

Testing: macOS = parser/PSScriptAnalyzer, Pester with stubbed Windows cmdlets, fake registry, gate matrix, WhatIf = no changes,
rollback/hash tampering, log schema/redaction. Windows lab VM (snapshot first) = services, registry vs GPO provenance, RSoP failure,
session gates, installer, container archive, Defender, GUI flow, `-Daily` writes no repair records.

## 8. Open questions for you
1. ~~Should repairs appear in the GUI?~~ **Answered: yes** (§0)
2. Where will the toolkit live on session hosts? (Repairs require an admin-only folder, not `C:\Temp`.)
3. ~~How are FSLogix settings delivered?~~ **Answered: local Group Policy in the image** (§0)
4. ~~Is Cloud Cache used for ODFC?~~ **Answered: no** (§0)
5. ~~FSLogix upgrades?~~ **Answered: in place in the golden image** (§0)
6. ~~Offer ODFC container reset?~~ **Answered: yes, in the GUI** (§0)
7. Is Microsoft Defender the AV, and is it managed by Intune/MDE with local merge disabled?
8. Rollback data in `%ProgramData%\FSLogixToolkit\RepairState` (admin-only) OK? Retention 180 days OK?
9. Change reference required for all tiers, or only disruptive (Tier 3)?
10. Pooled or personal host pools; is operator attestation of drain mode acceptable?
11. Are user names/SIDs acceptable in repair logs?

## 9. Items still below 90% confidence
Service restart safety with attached containers (no Microsoft procedure) · whether logging changes apply without restart ·
FSLogixAppsSetup exit codes / reboot signalling / signer subject · `Get-DiskImage` visibility of FSLogix-attached disks ·
locale-safe session enumeration · Intune provenance detection · RSoP completeness signal · `Microsoft.FSLogix` module under PS7 ·
Defender syntax for per-user/UNC rows · leftover lock/metadata files after ODFC archive · default `C:\ProgramData` ACL ·
pending-reboot detection · `Start-Transcript` in a GUI runspace.

## 10. Sources (learn.microsoft.com/en-us/…)
fslogix/reference-service-drivers-components · fslogix/troubleshooting-fslogix-service · fslogix/troubleshooting-vhd-disk-compaction ·
fslogix/reference-configuration-settings · fslogix/how-to-configure-odfc-containers · fslogix/troubleshooting-container-locked ·
fslogix/troubleshooting-known-issues · fslogix/overview-release-notes · fslogix/how-to-install-fslogix · fslogix/overview-faq ·
fslogix/utilities/frx/frx · fslogix/troubleshooting-old-temp-local-profiles · fslogix/concepts-container-types ·
fslogix/troubleshooting-container-size-space · fslogix/overview-prerequisites · fslogix/troubleshooting-open-file-handles ·
fslogix/how-to-use-group-policy-templates · fslogix/utilities/powershell/microsoft-fslogix ·
defender-endpoint/microsoft-defender-antivirus-exclusions-overview · defender-endpoint/configure-local-policy-overrides-microsoft-defender-antivirus ·
powershell/module/microsoft.powershell.management/set-service · powershell/module/storage/get-diskimage ·
powershell/module/microsoft.powershell.security/get-authenticodesignature · powershell/module/microsoft.powershell.host/start-transcript ·
windows-server/administration/windows-commands/reg-export · windows-server/administration/windows-commands/reg-import ·
dotnet/api/system.io.filesystemaclextensions.create
