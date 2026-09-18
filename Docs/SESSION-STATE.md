# Session state — updated 2026-09-17 17:20 (America/New_York)

Project: `~/Downloads/_Software/POWERSHELL/FSLogixToolkit` (module **0.3.0**, 40 exported commands, 98 files).
Tree state at pause: **validation clean** (`BLOCKING: none`; 12 advisories, all verified false positives), module imports, `Logs/`, `Reports/` and
`Modules/` hold only their placeholder files.

## Where we are
| Phase | State |
|---|---|
| Phase 1 — core toolkit (containers, best practice, policy/GPO, performance, network, diagnostics, maintenance, reporting) | done |
| Phase 2 — ODFC-first menu GUI, auto checks, discovery, daily health checks | done |
| Modules folder + inbox-module loading fix (`-DownloadModules`, Windows module folder fallback, prerequisite cleanup) | done |
| Phase 3 build — waves A/B/C: three-state GP provenance, folder-security check, run-as (UAC + `runas /smartcard`), undo store + repair logs, CLI repair engine (FIX-SVC-01..04, FIX-LOG-01..04, FIX-ODFC-01), Office container reset (FIX-ODFC-02), GUI Repair menu + 3 dialogs + Repair tab | **done** (agent confidence 86–95) |
| Phase 3 review — security review, GUI runtime review | **done** (`wf_05a414e3-d4d`): 16 findings, 14 fixed |
| Phase 3 — integration tests, requirements critic, fixer | **done**: import 40/40, 83 behaviour checks, 16/18 requirements met, 5 fixer edits |

## Resume the Phase 3 review/integration
Resumed 2026-09-17 16:15 as a **review-only** run: the original script re-ran every build agent on resume (the cache key
includes the prompt, and the PSScriptAnalyzer path had changed when the scratchpad moved), so the build waves were
dropped and their cached reports inlined instead.

Script: `workflows/scripts/fslogix-toolkit-phase3-review.js` (generated from the original; run id `wf_05a414e3-d4d`).
Original build run: `wf_e92d304b-60f` - its journal holds the seven Wave A/B/C agent reports.
Args: `{ root: <project>, pssa: <PSScriptAnalyzer.psd1> }` - both must be passed or the script fails on `args.root`.

## Validate / smoke test locally (macOS, PowerShell 7.5.2)
```bash
FSL_PSSA_PATH="$HOME/.../scratchpad/psmodules/PSScriptAnalyzer/1.25.0/PSScriptAnalyzer.psd1" \
  pwsh -NoProfile -File ./Tests/Invoke-FslValidation.ps1
```
PSScriptAnalyzer lives in the session scratchpad and does **not** survive a scratchpad move; re-fetch it with
`Save-PSResource -Name PSScriptAnalyzer -Version 1.25.0 -Path <dir> -TrustRepository`, or run
`./Start-FSLogixToolkit.ps1 -DownloadModules` to put it in `Modules/`.
Baseline 2026-09-17 16:10: `Validated 98 file(s). BLOCKING: none.` 12 advisories, all verified false positives against
the PS 7.0 compatibility profile (the module requires 7.4).

## Next actions
Everything that can be done without Windows is done. What remains:

1. Answer the two review decisions below (launcher load order; Undo vs Group Policy).
2. Refresh the VM copy: `C:\Temp\FSLogixToolkit\FSLogixToolkit` predates the Modules fix and all of Phase 3.
   **Install to an admin-only folder** (e.g. `C:\Program Files\FSLogixToolkit`) — repairs refuse to run from a folder
   non-admins can write to, and running elevated from `C:\Temp` is itself a privilege-escalation risk.
3. On the VM: run the read-only module-path diagnostic in `README.md` → Troubleshooting (explains the earlier
   "Storage / SmbShare not found" warnings), then `.\Start-FSLogixToolkit.ps1`.
4. Work the Windows VM sign-off checklist below, and `Docs/REPAIR-PLAN.md` §7, before trusting any repair action.

## Owner decisions on record
ODFC (Office containers) only, no profile containers · FSLogix settings delivered by **local Group Policy** in the golden
image · no Cloud Cache · FSLogix upgraded in place in the golden image · repairs allowed in the GUI · Office container
reset allowed in the GUI · admins use separate smart-card accounts, so relaunch offers UAC **and** `runas /smartcard`
(the toolkit never handles PINs or passwords).

## Decisions the Phase 3 review put to the owner
1. **Launcher load order** (`Start-FSLogixToolkit.ps1:291`, high, left unfixed). The module is imported — dot-sourcing
   every `.ps1` under `Private/` and `Public/` — *before* `Test-FslToolkitPathSecurity` runs, so when the toolkit is
   started elevated from a folder non-admins can write to, planted code has already run as administrator by the time the
   warning prints. Contract P3.1 item 3 says the launcher warns and continues, so the reviewer did not change it.
   Options: (a) deploy to `C:\Program Files\FSLogixToolkit`, which closes it entirely; (b) additionally add a small
   self-contained owner/ACL check before the `PSModulePath` change and `Import-Module` that refuses to start when
   elevated from an insecure folder — a documented startup-behaviour change.
2. **`Undo-FslRepair` and Group Policy** (`Public/Repair/Undo-FslRepair.ps1:177`, low, left unfixed). Undo does not
   re-check provenance before restoring a registry value. The state-match gate already blocks the common case; adding a
   provenance gate is a behaviour change the contract does not specify.

## Still open (asked, not answered)
Toolkit install location on the hosts · whether Microsoft Defender is centrally managed (local exclusions may be ignored) ·
repair-log/undo retention (default 180 days) · whether a change reference is required for all tiers or only tier 3
(default: tier 3) · pooled vs personal host pools / drain attestation · whether user names may appear in repair logs.

## Biggest untested areas (need a Windows VM)
WPF dashboard and the three new dialogs · scheduled daily task · performance counters, event logs, CIM discovery ·
RSoP/GPO provenance incl. whether **local** Group Policy shows as GroupPolicy · repair engine against the real registry and
services · Office container reset against a real share · `runas /smartcard` relaunch and its quoting/length limits ·
inbox module loading from the Windows module folder.

## Windows VM sign-off checklist (Phase 3 — nothing below has ever executed)
Every item is a Windows-only seam that was exercised only through a mock on macOS. Snapshot the VM first, install to an
admin-only folder, and work top to bottom.

1. **Registry** — `-RepairPlan`, then `-Repair -ActionId FIX-LOG-03 -WhatIf`, then apply and `-UndoRunId`: confirm the
   SetValue/DeleteValue writes land in the **Registry64** view (`Private/Repair/FslFixRegistry.ps1`) and undo restores.
2. **Services** — FIX-SVC-01/04 apply + undo: `Set-Service` start-type write and `Restore-FslFixServiceStartType`;
   FIX-SVC-02 `Start-Service` on a stopped `frxsvc` (never stopped by the toolkit). FIX-SVC-03 is operator-selected now.
3. **ACLs** — `Test-FslToolkitPathSecurity` on an admin-only folder (expect Pass) and on `C:\Temp\...` (expect Fail with
   the principals listed); `Test-FslFixStateRoot -Create` against `C:\ProgramData\FSLogixToolkit\RepairState`, then a
   second run over the existing folder (owner/ACL verification path).
4. **G4 Zone.Identifier** — copy a downloaded (blocked) file into the tree and confirm the gate fails, then
   `Get-ChildItem -Recurse | Unblock-File` and confirm it passes.
5. **Group Policy provenance (the open Wave A item)** — set one FSLogix value in `gpedit.msc`, `GPUPDATE
   /Target:Computer /force`, then `Get-FslEffectiveSetting` and `Get-FslRepairPlan`: does **Local** Group Policy surface
   as `Source = GroupPolicy` (GuidanceOnly), or as `Registry`? Until this is answered, `Registry` only means "no winning
   RSoP row" — the G8 Pass message, the Registry `SourceDetail` and `README.md` all say so.
6. **Container reset** — FIX-ODFC-02 dry run against a copied test container: `Get-DiskImage` attachment detection,
   exclusive-open test, archive + SHA256 verify, MoveBack rollback.
7. **Relaunch** — `-RunAsDifferentUser` (`runas.exe /smartcard`, `seclogon` running) and `-RequestElevation`
   (`Start-Process -Verb RunAs`); confirm no PIN/password ever reaches the toolkit.
8. **GUI** (never rendered — macOS has no PresentationFramework) — Repair menu enabled only when elevated, the plan
   dialog, and specifically: FIX-ODFC-02 showing **NotNeeded** with its explanation when the user has no Office
   container (previously Blocked), and the "confirmation prompt could not be shown" Result message, which should never
   appear because the GUI always passes `-Confirm:$false`.
9. **Retention / lock** — `Remove-FslFixOldRun` and the cross-session single-run lock (G18) under Windows, plus the
   FIX-LOG-02 temporary-change expiry.

## Out of scope until the lab pass (do not build)
Installer repair/upgrade, Defender exclusion writes, VHD dismount, SizeInMBs changes, `frx start-agent`, naming-mismatch
repair, CleanupInvalidSessions, ODFC retry-value changes, Cloud Cache actions, maintenance wrappers
(`Docs/REPAIR-PLAN.md` "Later" list).
