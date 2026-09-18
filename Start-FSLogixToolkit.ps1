#Requires -Version 7.4
<#
.SYNOPSIS
    Launches FSLogixToolkit: WPF dashboard on Windows, or a console health check with CSV/HTML reports.

.DESCRIPTION
    Adds the project Modules folder (<this folder>\Modules, created when missing and writable) to the front of the
    process PSModulePath BEFORE importing the module, so modules saved there (PowerShell Gallery modules, layout
    <Name>\<Version>\) are found first. Then imports the FSLogixToolkit module from this folder, initializes the
    session and prerequisites (no download unless -AllowInstall or -DownloadModules), shows the elevation state and then:
      - on Windows without -NoGui: opens the read-only dashboard (Show-FslDashboard);
      - with -NoGui or on non-Windows: runs Invoke-FslHealthCheck, exports reports with
        Export-FslReport and prints summary counts and report paths;
      - with -Daily: runs Invoke-FslDailyHealthCheck (daily report folder, JSON summary, new issues,
        retention) - this is what the scheduled task registered by Register-FslDailyHealthCheck runs.
    -ContainerScope (ODFC | Profiles | Both) selects the container mode for the dashboard, the console health
    check and the daily run; when omitted the saved preference / Settings.psd1 value is used (default ODFC,
    Office containers only).
    At startup the launcher prints the account running it (DOMAIN\User) and whether the session is elevated. When
    elevated on Windows it runs Test-FslToolkitPathSecurity and prints a prominent warning when the toolkit folder can
    be changed by non-administrators (health checks continue; repairs refuse).
    With -RequestElevation on Windows, when the session is not elevated, PowerShell is relaunched with
    Start-Process -Verb RunAs passing the same parameters (Start-FslCoreRelaunch -Mode Elevate), and this instance exits.
    With -RunAsDifferentUser on Windows, the launcher is relaunched as -RunAsUserName (or the saved RunAsUserName
    preference) with runas.exe /smartcard (Start-FslCoreRelaunch -Mode DifferentUser): runas opens its own console and
    asks for the smart card PIN - the toolkit never sees, stores or logs a PIN or password. The relaunch receives the
    same parameters plus -ContainerScope <resolved mode> and -OutputPath <current report folder> (Settings
    RunAs.PassReportRoot), because the other account has a different profile; with -RequestElevation as well, the new
    instance elevates (UAC) after sign-in. This instance exits with 0 after the relaunch was started.
    Repairs (elevated only, never from -Daily):
      -RepairPlan                  prints the repair plan (Get-FslRepairPlan) as a table and exits with 0;
      -Repair -ActionId <id[]>     applies those repair actions (Invoke-FslRepair); add -WhatIf for a preview that
                                   changes nothing and -Confirm:$false to skip the per-action confirmation prompt
                                   (started with "pwsh -File", write it as -Confirm:false - pwsh -File does not
                                   interpret $false, so -Confirm:$false would be dropped and the run would stop at
                                   the first prompt in a session that cannot answer one);
      -UndoRunId <guid>            restores the state a repair run recorded (Undo-FslRepair).
    -MaxRiskTier, -AllowDisruptive, -ChangeReference, -RepairUserName, -ArchivePath and -UserSignedOutConfirmed are
    passed to the repair functions. The daily scheduled task never runs repairs: with -Daily the repair switches are
    ignored with a warning.
    The error log is exported (Export-FslErrorLog) at the end when errors were recorded (the daily run
    exports it into its day folder instead).
    Exit codes: 0 = completed, 1 = module/session/dashboard could not start, 2 = console or daily health
    check completed with Fail or Error results (toolkit convention), 3 = a requested repair was refused by the
    pre-flight gates (nothing was changed).

.PARAMETER NoGui
    Run the console health check and export reports instead of opening the dashboard.

.PARAMETER Daily
    Run the daily health check (Invoke-FslDailyHealthCheck) instead of the dashboard or console check.

.PARAMETER ContainerScope
    Container mode: ODFC (Office containers only), Profiles or Both. Passed to the dashboard (when it
    supports it), the console health check and the daily run. Default: saved preference (ODFC).

.PARAMETER Category
    Categories for the console health check. Default: all read-only categories.

.PARAMETER Format
    Report format for the console health check: Csv, Html or Both (default).

.PARAMETER OutputPath
    Report folder. Used as the session ReportRoot (also for dashboard exports and the daily run).

.PARAMETER AllowInstall
    Allow Initialize-FslPrerequisites to download missing PowerShell Gallery modules (saved to the Modules folder; for
    the current user when the Modules folder is not writable).

.PARAMETER DownloadModules
    Save the PowerShell Gallery modules listed in Config\Prerequisites.psd1 (Source PSGallery) that are missing into the
    Modules folder (Initialize-FslPrerequisites -AllowInstall -Destination LocalModules), then continue. Windows inbox
    modules (Storage, SmbShare, ScheduledTasks, ...) and Windows feature modules (Hyper-V) are never downloaded - they
    are not on the PowerShell Gallery.

.PARAMETER EnableDebugLogging
    Write Debug-level lines to the toolkit log file.

.PARAMETER Offline
    Do not perform the online latest-version lookup in the console health check.

.PARAMETER RequestElevation
    On Windows, relaunch elevated (UAC prompt) when the current session is not elevated. Combined with
    -RunAsDifferentUser: the instance started as the other user elevates after sign-in.

.PARAMETER RunAsDifferentUser
    On Windows, relaunch the toolkit as another account (for example a separate smart-card admin account) with
    runas.exe /smartcard. Requires the Secondary Logon service (seclogon) not to be Disabled.

.PARAMETER RunAsUserName
    Account for -RunAsDifferentUser: DOMAIN\user or user@domain.tld (no spaces, quotes or %). Default: the saved
    RunAsUserName preference.

.PARAMETER RepairPlan
    Print the repair plan (Get-FslRepairPlan) for the current container mode and exit. Read-only.

.PARAMETER Repair
    Apply the repair actions named with -ActionId (Invoke-FslRepair). Requires an elevated session.

.PARAMETER ActionId
    Repair action ids for -Repair (for example FIX-SVC-01) or the subset of a run to undo with -UndoRunId.

.PARAMETER UndoRunId
    RunId of a repair run to undo (Undo-FslRepair).

.PARAMETER MaxRiskTier
    Highest repair risk tier to plan or apply (0-3). Default: Config\Settings.psd1 Repair.MaxRiskTierDefault.

.PARAMETER AllowDisruptive
    Allow risk tier 3 (disruptive) repair actions, such as the Office container reset.

.PARAMETER ChangeReference
    Change record reference for the repair run; required for the risk tiers in Repair.RequireChangeReferenceTier.

.PARAMETER ArchivePath
    Archive folder for the Office container reset (passed to the repair handlers as Parameters.ArchivePath).

.PARAMETER RepairUserName
    FSLogix user whose Office container is reset (passed to the repair handlers as Parameters.UserName). This is the
    affected end user, not the account that runs the toolkit (see -RunAsUserName).

.PARAMETER UserSignedOutConfirmed
    Operator attestation that the affected user is signed out of every session host (required by the Office container reset).

.EXAMPLE
    ./Start-FSLogixToolkit.ps1

.EXAMPLE
    ./Start-FSLogixToolkit.ps1 -NoGui -Category Environment, Containers -Format Html -OutputPath C:\Temp\FslReports

.EXAMPLE
    ./Start-FSLogixToolkit.ps1 -RequestElevation

.EXAMPLE
    ./Start-FSLogixToolkit.ps1 -RunAsDifferentUser -RunAsUserName 'CONTOSO\adm-jdoe' -RequestElevation

    Opens a runas console that asks for the smart card PIN of CONTOSO\adm-jdoe, then starts the toolkit as that account
    (elevated after sign-in) with the same container mode and report folder.

.EXAMPLE
    ./Start-FSLogixToolkit.ps1 -RepairPlan

.EXAMPLE
    ./Start-FSLogixToolkit.ps1 -Repair -ActionId FIX-SVC-01 -WhatIf

    Previews the repair: nothing is changed and the run is logged with Mode WhatIf.

.EXAMPLE
    ./Start-FSLogixToolkit.ps1 -Repair -ActionId FIX-LOG-01 -ChangeReference 'CHG0012345' -Confirm:$false

.EXAMPLE
    ./Start-FSLogixToolkit.ps1 -UndoRunId 'd2f1a0c4-6b0e-4a51-9d7e-2b1f0e7c9a11'

.EXAMPLE
    ./Start-FSLogixToolkit.ps1 -DownloadModules -NoGui

.EXAMPLE
    pwsh -NoProfile -NonInteractive -File .\Start-FSLogixToolkit.ps1 -Daily -ContainerScope ODFC -OutputPath 'D:\FslToolkit\Reports'

.NOTES
    RequiresElevation: No (some checks return Skipped without elevation)
    Sources:
      https://learn.microsoft.com/powershell/module/microsoft.powershell.management/start-process
      https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_pwsh
      https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_requires
      https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_psmodulepath
      https://learn.microsoft.com/powershell/module/microsoft.powershell.psresourceget/save-psresource
      https://learn.microsoft.com/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/cc771525(v=ws.11)
      https://learn.microsoft.com/troubleshoot/windows-server/shell-experience/use-run-as-feature
      https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [switch] $NoGui,

    [Parameter()]
    [switch] $Daily,

    [Parameter()]
    [ValidateSet('ODFC', 'Profiles', 'Both')]
    [string] $ContainerScope,

    [Parameter()]
    [ValidateSet('Discovery', 'Environment', 'Policy', 'BestPractice', 'Containers', 'Performance', 'Network', 'Diagnostics')]
    [string[]] $Category = @('Discovery', 'Environment', 'Policy', 'BestPractice', 'Containers', 'Performance', 'Network', 'Diagnostics'),

    [Parameter()]
    [ValidateSet('Csv', 'Html', 'Both')]
    [string] $Format = 'Both',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath,

    [Parameter()]
    [switch] $AllowInstall,

    [Parameter()]
    [switch] $DownloadModules,

    [Parameter()]
    [switch] $EnableDebugLogging,

    [Parameter()]
    [switch] $Offline,

    [Parameter()]
    [switch] $RequestElevation,

    [Parameter()]
    [switch] $RunAsDifferentUser,

    [Parameter()]
    [ValidateLength(3, 512)]
    [ValidatePattern('^(?:[A-Za-z0-9][A-Za-z0-9.\-]{0,254}\\[^\\/"\[\]:;|=,+*?<>@%\s]{1,256}|[^\\/"\[\]:;|=,+*?<>@%\s]{1,256}@[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)+)\z')]
    [string] $RunAsUserName,

    [Parameter()]
    [switch] $RepairPlan,

    [Parameter()]
    [switch] $Repair,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]] $ActionId,

    [Parameter()]
    [guid] $UndoRunId,

    [Parameter()]
    [ValidateRange(0, 3)]
    [int] $MaxRiskTier,

    [Parameter()]
    [switch] $AllowDisruptive,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ChangeReference,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ArchivePath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $RepairUserName,

    [Parameter()]
    [switch] $UserSignedOutConfirmed
)

Set-StrictMode -Version Latest
$InformationPreference = 'Continue'

if ($PSBoundParameters.ContainsKey('OutputPath')) {
    # Absolute path so an elevated relaunch (different working directory) writes to the same folder.
    $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $PSBoundParameters['OutputPath'] = $OutputPath
}

# Project Modules folder: prepend to the PROCESS PSModulePath before importing the module (about_PSModulePath).
# Never fails startup; the registry/User/Machine PSModulePath is not changed.
$modulesFolder = Join-Path -Path $PSScriptRoot -ChildPath 'Modules'
$modulesFolderNote = ''
try {
    if (-not (Test-Path -LiteralPath $modulesFolder -PathType Container)) {
        $null = New-Item -Path $modulesFolder -ItemType Directory -Force -ErrorAction Stop
    }
    $pathSeparator = [System.IO.Path]::PathSeparator
    $trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $currentModulePath = [System.Environment]::GetEnvironmentVariable('PSModulePath')
    $alreadyOnPath = $false
    if (-not [string]::IsNullOrEmpty($currentModulePath)) {
        foreach ($entry in $currentModulePath.Split($pathSeparator)) {
            if ([string]::Equals($entry.Trim().TrimEnd($trimChars), $modulesFolder.TrimEnd($trimChars), [System.StringComparison]::OrdinalIgnoreCase)) { $alreadyOnPath = $true; break }
        }
    }
    if (-not $alreadyOnPath) {
        $env:PSModulePath = if ([string]::IsNullOrEmpty($currentModulePath)) { $modulesFolder } else { $modulesFolder + $pathSeparator + $currentModulePath }
    }
}
catch {
    $modulesFolderNote = " (not available: $($_.Exception.Message))"
}
Write-Information -MessageData "Modules folder: $modulesFolder$modulesFolderNote"
Write-Verbose -Message "PSModulePath: $env:PSModulePath"

# Folder integrity is a DEPLOYMENT precondition, not something this script can enforce: the launcher, the manifest and
# every file the module dot-sources live in the same folder, so a principal who can write here can equally replace this
# script. The toolkit folder security check therefore runs after the import (it needs the module) and only reports -
# install the toolkit in an admin-only folder such as C:\Program Files\FSLogixToolkit (contract P3.1 item 3: warn and
# continue for health checks; gate G3 refuses repairs).
$manifestPath = Join-Path -Path $PSScriptRoot -ChildPath 'FSLogixToolkit.psd1'
$toolkitModule = $null
try {
    $toolkitModule = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop | Where-Object -FilterScript { $_.Name -eq 'FSLogixToolkit' } | Select-Object -First 1
}
catch {
    Write-Error -Message "Unable to import FSLogixToolkit from '$manifestPath': $($_.Exception.Message)"
    exit 1
}

# Session
$sessionParams = @{}
if ($OutputPath) { $sessionParams['ReportRoot'] = $OutputPath }
if ($EnableDebugLogging) { $sessionParams['EnableDebugLogging'] = $true }
try {
    $session = Initialize-FslSession @sessionParams
    Write-Information -MessageData "FSLogixToolkit session initialized. Logs: $($session.LogRoot)  Reports: $($session.ReportRoot)"
}
catch {
    Write-Error -Message "Initialize-FslSession failed: $($_.Exception.Message)"
    exit 1
}

# Account + elevation
$isWindowsHost = $IsWindows
$isElevated = $false
try {
    $isElevated = [bool](Test-FslElevation)
}
catch {
    Write-Warning -Message "Unable to determine elevation state: $($_.Exception.Message)"
}
$accountName = '<unknown>'
if ($null -ne $toolkitModule) {
    try { $accountName = [string](& $toolkitModule { Get-FslCoreCurrentAccount }) } catch { $accountName = '<unknown>' }
}
if ($isElevated) {
    Write-Information -MessageData "Running as: $accountName  Elevated: Yes"
}
else {
    Write-Information -MessageData "Running as: $accountName  Elevated: No - some checks are skipped without elevation."
}

# Toolkit folder security (elevated only): code in a folder that non-admins can change would run as administrator.
if ($isElevated -and $isWindowsHost) {
    try {
        $pathResults = @(Test-FslToolkitPathSecurity -Path $PSScriptRoot)
        $insecure = @($pathResults | Where-Object -FilterScript { $_.Status -in @('Fail', 'Error') })
        if ($insecure.Count -gt 0) {
            Write-Warning -Message '=================================================================================='
            Write-Warning -Message "SECURITY WARNING: FSLogixToolkit is running ELEVATED from a folder that non-administrators can change: $PSScriptRoot"
            Write-Warning -Message 'Running elevated from a folder writable by non-admins is unsafe: anyone with write access could plant code that runs as administrator.'
            Write-Warning -Message 'This check runs AFTER the module is imported, so toolkit code from this folder has ALREADY been loaded with administrator rights in this session. Treat the session as untrusted: close it, verify the files, and start again from an admin-only folder.'
            Write-Warning -Message 'Install the toolkit in an admin-only folder such as C:\Program Files\FSLogixToolkit. Health checks continue; repairs are refused.'
            foreach ($item in $insecure) {
                Write-Warning -Message ("  [{0}] {1}: {2}" -f $item.Status, $item.Target, $item.Message)
            }
            Write-Warning -Message '=================================================================================='
        }
        else {
            Write-Information -MessageData 'Toolkit folder security: only administrators can change the toolkit files.'
        }
    }
    catch {
        Write-Warning -Message "Test-FslToolkitPathSecurity failed: $($_.Exception.Message)"
    }
}

# Launcher parameters to pass on a relaunch (switches and values as bound).
$relaunchArguments = @{}
foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    if ($entry.Key -in @('RequestElevation', 'RunAsDifferentUser', 'RunAsUserName')) { continue }
    $relaunchArguments[$entry.Key] = $entry.Value
}

if ($RunAsDifferentUser) {
    if (-not $isWindowsHost) {
        Write-Warning -Message '-RunAsDifferentUser is only supported on Windows. Continuing as the current user.'
    }
    elseif ($null -eq $toolkitModule) {
        Write-Warning -Message 'The FSLogixToolkit module object is unavailable; cannot relaunch as a different user. Continuing as the current user.'
    }
    else {
        $relaunchParams = @{ Mode = 'DifferentUser'; Arguments = $relaunchArguments }
        if ($RunAsUserName) { $relaunchParams['UserName'] = $RunAsUserName }
        if ($RequestElevation) { $relaunchParams['ElevateAfterSignIn'] = $true }
        $started = $false
        try {
            $started = [bool](& $toolkitModule { param($p) Start-FslCoreRelaunch @p } $relaunchParams)
        }
        catch {
            Write-Warning -Message "Relaunch as a different user failed: $($_.Exception.Message)"
        }
        if ($started) {
            Write-Information -MessageData 'A runas console was opened: insert the smart card and enter the PIN there (Windows handles it). This instance will exit.'
            exit 0
        }
        Write-Warning -Message 'Relaunch as a different user was not started (see the warning above and the toolkit log). Continuing as the current user.'
    }
}
elseif ($RequestElevation -and -not $isElevated) {
    if (-not $isWindowsHost) {
        Write-Warning -Message '-RequestElevation is only supported on Windows. Continuing as the current user.'
    }
    elseif ($null -eq $toolkitModule) {
        Write-Warning -Message 'The FSLogixToolkit module object is unavailable; cannot relaunch elevated. Continuing as the current user.'
    }
    else {
        # Rebuilds the bound parameters (without -RequestElevation) as a PowerShell command passed with -EncodedCommand
        # (UTF-16LE Base64, about_Pwsh) to avoid quoting and array issues with -File.
        $started = $false
        try {
            $started = [bool](& $toolkitModule { param($p) Start-FslCoreRelaunch @p } @{ Mode = 'Elevate'; Arguments = $relaunchArguments })
        }
        catch {
            Write-Warning -Message "Elevation failed: $($_.Exception.Message)"
        }
        if ($started) {
            Write-Information -MessageData 'Relaunched FSLogixToolkit elevated. This instance will exit.'
            exit 0
        }
        Write-Warning -Message 'Elevation was not granted or failed. Continuing as the current user.'
    }
}

# Prerequisites (never downloads unless -AllowInstall or -DownloadModules). Results are printed once by the launcher,
# so the per-module warning stream is silenced (-WarningAction SilentlyContinue); details stay in the toolkit log.
$prereqResults = @()
try {
    $downloadResults = @()
    if ($DownloadModules) {
        $galleryNames = @()
        try {
            $prereqData = Import-PowerShellDataFile -LiteralPath (Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Config') -ChildPath 'Prerequisites.psd1') -ErrorAction Stop
            $galleryNames = @($prereqData['Modules'] | Where-Object -FilterScript { $_['Source'] -eq 'PSGallery' } | ForEach-Object -Process { [string]$_['Name'] })
        }
        catch {
            Write-Warning -Message "Unable to read Config\Prerequisites.psd1: $($_.Exception.Message)"
        }
        if ($galleryNames.Count -gt 0) {
            Write-Information -MessageData "Downloading missing PowerShell Gallery modules to the Modules folder: $($galleryNames -join ', ')"
            $downloadResults = @(Initialize-FslPrerequisites -Name $galleryNames -AllowInstall -Destination 'LocalModules' -WarningAction SilentlyContinue)
        }
        else {
            Write-Information -MessageData 'No PowerShell Gallery modules are listed in Config\Prerequisites.psd1.'
        }
    }

    $prereqParams = @{ WarningAction = 'SilentlyContinue' }
    if ($AllowInstall) { $prereqParams['AllowInstall'] = $true }
    $checkedResults = @(Initialize-FslPrerequisites @prereqParams)
    $downloadedTargets = @($downloadResults | ForEach-Object -Process { [string]$_.Target })
    $prereqResults = @(
        foreach ($item in $checkedResults) {
            if ($downloadedTargets -contains [string]$item.Target) { $downloadResults | Where-Object -FilterScript { [string]$_.Target -eq [string]$item.Target } }
            else { $item }
        }
    )

    $passed = @($prereqResults | Where-Object -FilterScript { $_.Status -eq 'Pass' })
    if ($passed.Count -gt 0) {
        $passText = @(foreach ($item in $passed) {
                $where = if ([string]$item.Message -match 'Loaded from: ([^(]+?) \(') { ", $($Matches[1])" } else { '' }
                '{0} {1}{2}' -f $item.Target, $item.Value, $where
            }) -join '; '
        Write-Information -MessageData ("Prerequisites OK ({0}): {1}" -f $passed.Count, $passText)
    }
    $compact = @($prereqResults | Where-Object -FilterScript { $_.Status -in @('Info', 'Skipped') })
    if ($compact.Count -gt 0) {
        Write-Information -MessageData ("Prerequisites not loaded (optional / not applicable): {0}" -f ((@($compact | ForEach-Object -Process { '{0} [{1}]' -f $_.Target, $_.Status })) -join ', '))
    }
    foreach ($prereq in @($prereqResults | Where-Object -FilterScript { $_.Status -in @('Warn', 'Fail', 'Error') })) {
        Write-Information -MessageData ("Prerequisite [{0}] {1}: {2}" -f $prereq.Status, $prereq.Target, $prereq.Message)
        if (-not [string]::IsNullOrWhiteSpace([string]$prereq.Recommendation)) {
            Write-Information -MessageData "    Recommendation: $($prereq.Recommendation)"
        }
    }
}
catch {
    Write-Warning -Message "Initialize-FslPrerequisites failed: $($_.Exception.Message)"
}

# Repairs. The daily scheduled task is read-only by design and never runs repairs.
$repairRequested = ($RepairPlan -or $Repair -or $PSBoundParameters.ContainsKey('UndoRunId'))
if ($Daily -and $repairRequested) {
    Write-Warning -Message 'The daily health check never runs repairs: -RepairPlan, -Repair and -UndoRunId are ignored with -Daily.'
    $repairRequested = $false
}

$exitCode = 0
if ($repairRequested) {
    $repairParameters = @{}
    if ($RepairUserName) { $repairParameters['UserName'] = $RepairUserName }
    if ($ArchivePath) { $repairParameters['ArchivePath'] = $ArchivePath }

    if ($RepairPlan) {
        $planParams = @{}
        if ($ContainerScope) { $planParams['ContainerScope'] = $ContainerScope }
        if ($ActionId) { $planParams['ActionId'] = $ActionId }
        if ($PSBoundParameters.ContainsKey('MaxRiskTier')) { $planParams['MaxRiskTier'] = $MaxRiskTier }
        if ($repairParameters.Count -gt 0) { $planParams['Parameters'] = $repairParameters }
        $plan = @()
        try {
            $plan = @(Get-FslRepairPlan @planParams)
        }
        catch {
            Write-Warning -Message "Get-FslRepairPlan failed: $($_.Exception.Message)"
            exit 1
        }
        Write-Information -MessageData ''
        Write-Information -MessageData ("Repair plan ({0} action(s)); nothing is changed by this command." -f $plan.Count)
        Write-Information -MessageData ("{0,-13} {1,-12} {2,-4} {3,-44} {4}" -f 'ActionId', 'Status', 'Tier', 'Target', 'Current -> Proposed')
        foreach ($item in $plan) {
            Write-Information -MessageData ("{0,-13} {1,-12} {2,-4} {3,-44} {4} -> {5}" -f $item.ActionId, $item.Status, $item.RiskTier, $item.Target, $item.CurrentValue, $item.ProposedValue)
            foreach ($line in @($item.Message, $item.BlockReason, $item.Guidance)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$line)) { Write-Information -MessageData "    $line" }
            }
        }
        if ($plan.Count -eq 0) {
            Write-Information -MessageData 'No repair action is in scope for the current container mode and risk tier.'
        }
        exit 0
    }

    $repairResults = @()
    $passThrough = @{}
    if ($PSBoundParameters.ContainsKey('WhatIf')) { $passThrough['WhatIf'] = [bool]$PSBoundParameters['WhatIf'] }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $passThrough['Confirm'] = [bool]$PSBoundParameters['Confirm'] }
    try {
        if ($Repair) {
            if (-not $ActionId) {
                Write-Warning -Message 'Use -Repair together with -ActionId <id[]>. Run -RepairPlan to see the available actions.'
                exit 1
            }
            $repairParams = @{ ActionId = $ActionId }
            if ($ContainerScope) { $repairParams['ContainerScope'] = $ContainerScope }
            if ($PSBoundParameters.ContainsKey('MaxRiskTier')) { $repairParams['MaxRiskTier'] = $MaxRiskTier }
            if ($AllowDisruptive) { $repairParams['AllowDisruptive'] = $true }
            if ($UserSignedOutConfirmed) { $repairParams['UserSignedOutConfirmed'] = $true }
            if ($ChangeReference) { $repairParams['ChangeReference'] = $ChangeReference }
            if ($repairParameters.Count -gt 0) { $repairParams['Parameters'] = $repairParameters }
            Write-Information -MessageData ("Running repair actions: {0}" -f ($ActionId -join ', '))
            $repairResults = @(Invoke-FslRepair @repairParams @passThrough)
        }
        else {
            $undoParams = @{ RunId = $UndoRunId }
            if ($ActionId) { $undoParams['ActionId'] = $ActionId }
            Write-Information -MessageData ("Undoing repair run {0}" -f $UndoRunId)
            $repairResults = @(Undo-FslRepair @undoParams @passThrough)
        }
    }
    catch {
        Write-Warning -Message "The repair command failed: $($_.Exception.Message)"
        $exitCode = 1
    }

    foreach ($item in $repairResults) {
        Write-Information -MessageData ("[{0,-7}] {1} ({2}): {3}" -f $item.Status, $item.Check, $item.Target, $item.Message)
        if (-not [string]::IsNullOrWhiteSpace([string]$item.Recommendation)) {
            Write-Information -MessageData "    Recommendation: $($item.Recommendation)"
        }
    }
    if ($exitCode -eq 0) {
        $blockedResults = @($repairResults | Where-Object -FilterScript {
                ([string]$_.Check).StartsWith('Preflight:') -and $_.Status -in @('Fail', 'Error')
            })
        $blockedResults += @($repairResults | Where-Object -FilterScript { ([string]$_.Message).StartsWith('Blocked: ') })
        $failedResults = @($repairResults | Where-Object -FilterScript { $_.Status -in @('Fail', 'Error') })
        if ($blockedResults.Count -gt 0) {
            Write-Warning -Message ("The repair was refused by the pre-flight gates ({0} finding(s)); nothing was changed." -f $blockedResults.Count)
            $exitCode = 3
        }
        elseif ($failedResults.Count -gt 0) {
            $exitCode = 2
        }
    }
}
elseif ($Daily) {
    $dailyParams = @{}
    if ($ContainerScope) { $dailyParams['ContainerScope'] = $ContainerScope }
    if ($Offline) { $dailyParams['Offline'] = $true }
    if ($OutputPath) { $dailyParams['ReportRoot'] = $OutputPath }
    $modeText = if ($ContainerScope) { $ContainerScope } else { 'saved preference' }
    Write-Information -MessageData "Running daily health check (container mode: $modeText)"
    $summary = $null
    try {
        $summary = Invoke-FslDailyHealthCheck @dailyParams
    }
    catch {
        Write-Warning -Message "Invoke-FslDailyHealthCheck failed: $($_.Exception.Message)"
    }
    if ($null -eq $summary) {
        Write-Warning -Message 'The daily health check did not produce a summary. See the toolkit log and error log.'
        $exitCode = 2
    }
    else {
        Write-Information -MessageData ("Container mode: {0}  Results: {1}  Duration: {2}s" -f $summary.ContainerScope, $summary.ResultCount, $summary.DurationSeconds)
        foreach ($entry in $summary.Counts.GetEnumerator()) {
            Write-Information -MessageData ("  {0,-8} {1}" -f $entry.Key, $entry.Value)
        }
        Write-Information -MessageData "New issues since previous run: $($summary.NewIssueCount)"
        foreach ($issue in @($summary.NewIssues)) {
            Write-Information -MessageData ("  [{0}] {1} / {2} ({3}) {4}" -f $issue.Status, $issue.Category, $issue.Check, $issue.Scope, $issue.Target)
        }
        foreach ($path in @($summary.HtmlReport, $summary.CsvReport, $summary.SummaryPath)) {
            if ($path) { Write-Information -MessageData "  $path" }
        }
        if (([int]$summary.Counts['Fail'] + [int]$summary.Counts['Error']) -gt 0) { $exitCode = 2 }
    }
    exit $exitCode
}
elseif (-not $NoGui -and $isWindowsHost) {
    $dashboardParams = @{}
    if ($ContainerScope) {
        $dashboardCommand = Get-Command -Name 'Show-FslDashboard' -ErrorAction SilentlyContinue
        if ($null -ne $dashboardCommand -and $dashboardCommand.Parameters.ContainsKey('ContainerScope')) {
            $dashboardParams['ContainerScope'] = $ContainerScope
        }
        else {
            Write-Warning -Message 'Show-FslDashboard in this module build does not support -ContainerScope; using the saved container mode.'
        }
    }
    $dashboardOutput = @(Show-FslDashboard @dashboardParams)
    foreach ($item in $dashboardOutput) {
        if ($item.Status -eq 'Error') {
            Write-Warning -Message "Dashboard: $($item.Message) $($item.Recommendation)"
            $exitCode = 1
        }
    }
}
else {
    if (-not $NoGui) {
        Write-Information -MessageData 'The dashboard requires Windows; running the console health check instead.'
    }
    $healthParams = @{ Category = $Category }
    if ($ContainerScope) { $healthParams['ContainerScope'] = $ContainerScope }
    if ($Offline) { $healthParams['Offline'] = $true }
    Write-Information -MessageData "Running health check: $($Category -join ', ')"
    $results = @(Invoke-FslHealthCheck @healthParams)

    $exportParams = @{ Format = $Format }
    if ($OutputPath) { $exportParams['Path'] = $OutputPath }
    $files = @()
    if ($results.Count -gt 0) {
        $files = @($results | Export-FslReport @exportParams)
    }

    Write-Information -MessageData ''
    Write-Information -MessageData "Results: $($results.Count)"
    foreach ($group in ($results | Group-Object -Property Status | Sort-Object -Property Name)) {
        Write-Information -MessageData ("  {0,-8} {1}" -f $group.Name, $group.Count)
    }
    foreach ($group in ($results | Group-Object -Property Category | Sort-Object -Property Name)) {
        $counts = ($group.Group | Group-Object -Property Status | Sort-Object -Property Name | ForEach-Object -Process { "$($_.Name)=$($_.Count)" }) -join ', '
        Write-Information -MessageData ("  {0,-13} {1}" -f $group.Name, $counts)
    }
    if ($files.Count -gt 0) {
        Write-Information -MessageData 'Reports:'
        foreach ($file in $files) { Write-Information -MessageData "  $($file.FullName)" }
    }
    else {
        Write-Information -MessageData 'No report files were written.'
    }
    if (@($results | Where-Object -FilterScript { $_.Status -in @('Fail', 'Error') }).Count -gt 0) { $exitCode = 2 }
}

# Error log
try {
    $errorLog = @(Get-FslErrorLog)
    if ($errorLog.Count -gt 0) {
        $errorFiles = @(Export-FslErrorLog)
        Write-Information -MessageData "Errors recorded: $($errorLog.Count). Error log:"
        foreach ($file in $errorFiles) { Write-Information -MessageData "  $($file.FullName)" }
    }
}
catch {
    Write-Warning -Message "Export-FslErrorLog failed: $($_.Exception.Message)"
}

exit $exitCode
