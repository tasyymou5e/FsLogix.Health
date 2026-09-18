# Private helpers for repair run context, repair logs and retention (Agent P3-4, prefix *-FslFix*).
#
# Readable copies: <ReportRoot>/<Repair.FolderName>/<yyyy-MM-dd>/Repair_<HHmmss>_<RunId8>.log | .json | .csv
# Authoritative rollback store: see FslFixState.ps1 (never written to ReportRoot, never included in diagnostic bundles).
# All text written to .log/.json/.csv is passed through ConvertTo-FslCoreRedactedText.
#
# Sources:
#   https://learn.microsoft.com/dotnet/api/system.security.principal.windowsidentity.getcurrent
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertto-csv
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/import-powershelldatafile

# FSLogixToolkit.RepairRecord property order (contract P3.3).
$script:FslFixRecordProperties = @(
    'Timestamp', 'RunId', 'Sequence', 'ComputerName', 'ActionId', 'Title', 'Scope', 'RiskTier', 'Mode', 'Target',
    'BeforeState', 'AfterState', 'ExpectedState', 'Status', 'VerificationStatus', 'Message', 'Operator', 'IsElevated',
    'ChangeReference', 'RollbackAvailable', 'RollbackRef', 'Source'
)
$script:FslFixRecordModes = @('WhatIf', 'Executed', 'Declined', 'Blocked', 'Undo')
$script:FslFixRecordStatuses = @('Pass', 'Fail', 'Skipped', 'Error', 'Info')
$script:FslFixSchemaVersion = 1

function Get-FslFixValue {
    <#
    .SYNOPSIS
        StrictMode-safe property/key read from a hashtable or object. Returns $null when missing.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return , $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return , $property.Value }
    return $null
}

function ConvertTo-FslFixText {
    <#
    .SYNOPSIS
        Converts a state value to redacted flat text: dictionaries/objects -> compact JSON (keys sorted), arrays joined.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) { return '' }
    $text = $null
    if ($InputObject -is [string]) { $text = $InputObject }
    elseif ($InputObject -is [System.Collections.IDictionary]) {
        $sorted = [ordered]@{}
        foreach ($key in @($InputObject.Keys | Sort-Object)) { $sorted[[string]$key] = $InputObject[$key] }
        $text = ConvertTo-FslFixJson -InputObject $sorted -Compress
    }
    elseif ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $text = ConvertTo-FslFixJson -InputObject $InputObject -Compress
    }
    else { $text = ConvertTo-FslCoreResultString -InputObject $InputObject }
    return [string](ConvertTo-FslCoreRedactedText -Text $text)
}

function Get-FslFixToolkitVersion {
    <#
    .SYNOPSIS
        Returns ModuleVersion from FSLogixToolkit.psd1, or 'Unknown'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $manifest = Join-Path -Path $script:FslSession['ModuleRoot'] -ChildPath 'FSLogixToolkit.psd1'
        $data = Import-PowerShellDataFile -LiteralPath $manifest -ErrorAction Stop
        if ($data.ContainsKey('ModuleVersion')) { return [string]$data['ModuleVersion'] }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Read toolkit version'
    }
    return 'Unknown'
}

function Get-FslFixOperator {
    <#
    .SYNOPSIS
        Returns [ordered]@{ Name; Sid } for the account running the process (Windows identity; non-Windows user name, Sid $null).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    if (Test-FslIsWindows) {
        $identity = $null
        try {
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            return [ordered]@{ Name = [string]$identity.Name; Sid = [string]$identity.User.Value }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Read operator identity'
        }
        finally {
            if ($null -ne $identity) { $identity.Dispose() }
        }
    }
    return [ordered]@{ Name = [string][Environment]::UserName; Sid = $null }
}

function Resolve-FslFixReportRoot {
    <#
    .SYNOPSIS
        Returns the repair report folder root: <ReportRoot>/<Repair.FolderName>. -ReportRoot overrides the session root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ReportRoot
    )

    if ([string]::IsNullOrWhiteSpace($ReportRoot)) {
        if (-not $script:FslSession['Initialized']) { $null = Initialize-FslSession }
        $ReportRoot = [string]$script:FslSession['ReportRoot']
    }
    if ([string]::IsNullOrWhiteSpace($ReportRoot)) { throw 'No report root available: pass -ReportRoot or run Initialize-FslSession.' }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportRoot)
    return (Join-Path -Path $full -ChildPath ([string](Get-FslFixConfig)['FolderName']))
}

function Write-FslFixLogLine {
    <#
    .SYNOPSIS
        Appends redacted lines to the run's human-readable .log (UTF-8 without BOM). Never throws.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [object] $Run,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Section,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Line
    )

    try {
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture)
        $builder = [System.Text.StringBuilder]::new()
        foreach ($text in $Line) {
            $formatted = '{0} [{1}] {2}' -f $stamp, $Section, (ConvertTo-FslCoreRedactedText -Text $text)
            $null = $builder.AppendLine($formatted)
            $Run.LogLines.Add($formatted)
        }
        [System.IO.File]::AppendAllText($Run.LogPath, $builder.ToString(), [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Write repair log line'
    }
}

function New-FslFixRun {
    <#
    .SYNOPSIS
        Creates a repair run context and (Apply/Undo) verifies/creates the admin-only StateRoot, takes the single-run lock and
        creates the run's rollback store.
    .DESCRIPTION
        Returns [pscustomobject] FSLogixToolkit.RepairRun: RunId, Mode, StartedAt, EndedAt, ComputerName, Operator{Name,Sid},
        IsElevated, ProcessId, InvocationSource, PSVersion, ToolkitVersion, FSLogixVersion, ContainerMode, ChangeReference,
        RollbackOfRunId, StateRoot, StatePath, StateRootProtected, ReportFolder, LogPath, JsonPath, CsvPath, Preflight
        (List), Records (List), LogLines (List), LockHandle, Completed, Summary.
        WhatIf runs make no changes: no StateRoot, no lock, StatePath $null; they still write readable logs.
        Throws when an Apply/Undo run cannot get a trusted StateRoot or the lock (another run is active).
        FSLogixVersion (Find-FslInstallation) and ContainerMode (Get-FslContainerMode) are filled when available; the engine
        may overwrite both before Complete-FslFixRun.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal toolkit state/log write inside an already confirmed repair run; must not be skipped by an inherited WhatIf/Confirm preference.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('WhatIf', 'Apply', 'Undo')]
        [string] $Mode,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $ChangeReference,

        [Nullable[guid]] $RollbackOfRunId,

        [ValidateNotNullOrEmpty()]
        [string] $InvocationSource = 'PowerShell',

        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $ContainerMode
    )

    if ($Mode -eq 'Undo' -and $null -eq $RollbackOfRunId) { throw 'Undo runs require -RollbackOfRunId.' }

    $runId = [guid]::NewGuid()
    $started = Get-Date
    $reportFolder = Join-Path -Path (Resolve-FslFixReportRoot) -ChildPath $started.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $baseName = 'Repair_{0}_{1}' -f $started.ToString('HHmmss', [System.Globalization.CultureInfo]::InvariantCulture), $runId.ToString('N').Substring(0, 8)

    $fslVersion = $null
    if (Test-FslIsWindows) {
        try {
            $installation = Find-FslInstallation
            if ($null -ne $installation -and $null -ne $installation.PSObject.Properties['Version'] -and $null -ne $installation.Version) {
                $fslVersion = [string]$installation.Version
            }
        }
        catch { Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Read FSLogix version for repair run' }
    }
    if ([string]::IsNullOrEmpty($ContainerMode)) {
        try { $ContainerMode = [string](Get-FslContainerMode) } catch { Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Resolve container mode for repair run' }
    }

    $run = [pscustomobject]@{
        PSTypeName         = 'FSLogixToolkit.RepairRun'
        RunId              = $runId.ToString('D')
        Mode               = $Mode
        StartedAt          = $started.ToString('o')
        EndedAt            = $null
        ComputerName       = [Environment]::MachineName
        Operator           = Get-FslFixOperator
        IsElevated         = [bool](Test-FslElevation)
        ProcessId          = $PID
        InvocationSource   = $InvocationSource
        PSVersion          = $PSVersionTable.PSVersion.ToString()
        ToolkitVersion     = Get-FslFixToolkitVersion
        FSLogixVersion     = $fslVersion
        ContainerMode      = if ([string]::IsNullOrEmpty($ContainerMode)) { $null } else { $ContainerMode }
        ChangeReference    = if ([string]::IsNullOrWhiteSpace($ChangeReference)) { $null } else { [string](ConvertTo-FslCoreRedactedText -Text $ChangeReference) }
        RollbackOfRunId    = if ($null -ne $RollbackOfRunId) { ([guid]$RollbackOfRunId).ToString('D') } else { $null }
        StateRoot          = $null
        StatePath          = $null
        StateRootProtected = $false
        ReportFolder       = $reportFolder
        LogPath            = Join-Path -Path $reportFolder -ChildPath "$baseName.log"
        JsonPath           = Join-Path -Path $reportFolder -ChildPath "$baseName.json"
        CsvPath            = Join-Path -Path $reportFolder -ChildPath "$baseName.csv"
        Preflight          = [System.Collections.Generic.List[object]]::new()
        Records            = [System.Collections.Generic.List[object]]::new()
        LogLines           = [System.Collections.Generic.List[string]]::new()
        LockHandle         = $null
        Completed          = $false
        Summary            = $null
        StateRootMessage   = $null
    }

    if (-not [System.IO.Directory]::Exists($reportFolder)) {
        $null = New-Item -Path $reportFolder -ItemType Directory -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
    }

    if ($Mode -ne 'WhatIf') {
        $rootCheck = Test-FslFixStateRoot -Create
        $run.StateRootMessage = [string]$rootCheck['Message']
        if (-not $rootCheck['Ok']) {
            Write-FslFixLogLine -Run $run -Section 'HEADER' -Line @("RunId $($run.RunId) Mode $Mode refused: $($rootCheck['Message'])")
            throw "Repair run refused: $($rootCheck['Message'])"
        }
        $run.StateRoot = [string]$rootCheck['Path']
        $run.StateRootProtected = [bool]$rootCheck['IsProtected']
        $run.LockHandle = Enter-FslFixRunLock -StateRoot $run.StateRoot -RunId $runId
        try {
            $run.StatePath = Join-Path -Path $run.StateRoot -ChildPath $run.RunId
            $null = New-Item -Path $run.StatePath -ItemType Directory -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
            $null = New-FslFixRollbackDocument -Run $run
        }
        catch {
            Exit-FslFixRunLock -Run $run
            throw
        }
    }

    $header = @(
        "FSLogixToolkit repair run $($run.RunId)",
        "Mode: $Mode; Computer: $($run.ComputerName); Operator: $($run.Operator.Name) ($($run.Operator.Sid)); Elevated: $($run.IsElevated); ProcessId: $PID",
        "Invocation: $InvocationSource; PowerShell: $($run.PSVersion); Toolkit: $($run.ToolkitVersion); FSLogix: $($run.FSLogixVersion); ContainerMode: $($run.ContainerMode)",
        "ChangeReference: $($run.ChangeReference); RollbackOfRunId: $($run.RollbackOfRunId); Started: $($run.StartedAt)"
    )
    if ($Mode -eq 'WhatIf') { $header += 'Rollback store: none (WhatIf preview makes no changes).' }
    else { $header += "Rollback store: $($run.StatePath) - $($run.StateRootMessage)" }
    Write-FslFixLogLine -Run $run -Section 'HEADER' -Line $header
    Write-FslLog -Message "Repair run $($run.RunId) started (mode $Mode)" -Level Info -Component 'Repair'
    return $run
}

function Add-FslFixPreflight {
    <#
    .SYNOPSIS
        Adds pre-flight Result objects (Category Repair, Check Preflight:<Gate>) to the run and the human log.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [object] $Run,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result
    )

    $lines = foreach ($item in $Result) {
        if ($null -eq $item) { continue }
        $Run.Preflight.Add($item)
        '{0} {1} {2}: {3}' -f (Get-FslFixValue -InputObject $item -Name 'Status'), (Get-FslFixValue -InputObject $item -Name 'Check'),
        (Get-FslFixValue -InputObject $item -Name 'Target'), (Get-FslFixValue -InputObject $item -Name 'Message')
    }
    if (@($lines).Count -gt 0) { Write-FslFixLogLine -Run $Run -Section 'PREFLIGHT' -Line @($lines) }
}

function ConvertTo-FslFixRecord {
    <#
    .SYNOPSIS
        Normalizes a hashtable/object into FSLogixToolkit.RepairRecord (contract P3.3 order), filling run defaults and redacting text.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Run,

        [Parameter(Mandatory)]
        [object] $Record,

        [Parameter(Mandatory)]
        [int] $Sequence
    )

    $defaultMode = switch ($Run.Mode) { 'WhatIf' { 'WhatIf' } 'Undo' { 'Undo' } default { 'Executed' } }
    $mode = [string](Get-FslFixValue -InputObject $Record -Name 'Mode')
    if ($script:FslFixRecordModes -notcontains $mode) { $mode = $defaultMode }
    $mode = @($script:FslFixRecordModes | Where-Object -FilterScript { $_ -eq $mode })[0]
    $status = [string](Get-FslFixValue -InputObject $Record -Name 'Status')
    if ($script:FslFixRecordStatuses -notcontains $status) {
        Write-FslLog -Message "Repair record status '$status' is not valid - recorded as Error." -Level Warning -Component 'Repair'
        $status = 'Error'
    }
    $status = @($script:FslFixRecordStatuses | Where-Object -FilterScript { $_ -eq $status })[0]

    $scope = [string](Get-FslFixValue -InputObject $Record -Name 'Scope')
    $scope = switch ($scope) { 'ODFC' { 'ODFC' } 'Profiles' { 'Profiles' } default { 'General' } }
    $tierValue = Get-FslFixValue -InputObject $Record -Name 'RiskTier'
    $tier = $null
    if ($null -ne $tierValue -and "$tierValue" -match '^[0-3]$') { $tier = [int]"$tierValue" }
    $rollbackAvailable = [bool](Get-FslFixValue -InputObject $Record -Name 'RollbackAvailable')
    $actionId = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $Record -Name 'ActionId')
    $rollbackRef = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $Record -Name 'RollbackRef')
    if ([string]::IsNullOrEmpty($rollbackRef) -and $rollbackAvailable -and -not [string]::IsNullOrEmpty($actionId)) {
        $rollbackRef = '{0}/{1}' -f $Run.RunId, $actionId
    }
    $timestamp = [string](Get-FslFixValue -InputObject $Record -Name 'Timestamp')
    if ([string]::IsNullOrWhiteSpace($timestamp)) { $timestamp = (Get-Date).ToString('o') }
    $changeReference = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $Record -Name 'ChangeReference')
    if ([string]::IsNullOrEmpty($changeReference) -and $null -ne $Run.ChangeReference) { $changeReference = [string]$Run.ChangeReference }

    [pscustomobject][ordered]@{
        PSTypeName         = 'FSLogixToolkit.RepairRecord'
        Timestamp          = $timestamp
        RunId              = [string]$Run.RunId
        Sequence           = $Sequence
        ComputerName       = [string]$Run.ComputerName
        ActionId           = $actionId
        Title              = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $Record -Name 'Title')
        Scope              = $scope
        RiskTier           = $tier
        Mode               = $mode
        Target             = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $Record -Name 'Target')
        BeforeState        = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $Record -Name 'BeforeState')
        AfterState         = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $Record -Name 'AfterState')
        ExpectedState      = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $Record -Name 'ExpectedState')
        Status             = $status
        VerificationStatus = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $Record -Name 'VerificationStatus')
        Message            = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $Record -Name 'Message')
        Operator           = [string](ConvertTo-FslCoreRedactedText -Text ([string]$Run.Operator.Name))
        IsElevated         = [bool]$Run.IsElevated
        ChangeReference    = $changeReference
        RollbackAvailable  = $rollbackAvailable
        RollbackRef        = $rollbackRef
        Source             = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $Record -Name 'Source')
    }
}

function Add-FslFixRecord {
    <#
    .SYNOPSIS
        Appends a RepairRecord to the run and writes the per-action human log block
        (Condition / Before / Action / After / Verification / Rollback ref). Returns the normalized record.
    .PARAMETER Condition
        Optional condition text for the human log (a 'Condition' key/property on -Record is used when not given).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Run,

        [Parameter(Mandatory)]
        [object] $Record,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Condition
    )

    if ($Run.Completed) { throw "Repair run $($Run.RunId) is already completed." }
    $normalized = ConvertTo-FslFixRecord -Run $Run -Record $Record -Sequence ($Run.Records.Count + 1)
    $Run.Records.Add($normalized)

    if ([string]::IsNullOrEmpty($Condition)) { $Condition = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $Record -Name 'Condition') }
    $rollbackText = if ($normalized.RollbackAvailable) { $normalized.RollbackRef } else { 'not available' }
    $lines = @(
        ('#{0} {1} - {2} [Scope {3}, Tier {4}] Mode {5} Status {6}' -f $normalized.Sequence, $normalized.ActionId, $normalized.Title, $normalized.Scope, $normalized.RiskTier, $normalized.Mode, $normalized.Status),
        ('  Target: {0}' -f $normalized.Target),
        ('  Condition: {0}' -f $Condition),
        ('  Before: {0}' -f $normalized.BeforeState),
        ('  Action: {0} (expected {1})' -f $normalized.Mode, $normalized.ExpectedState),
        ('  After: {0}' -f $normalized.AfterState),
        ('  Verification: {0}' -f $normalized.VerificationStatus),
        ('  Message: {0}' -f $normalized.Message),
        ('  Rollback ref: {0}' -f $rollbackText),
        ('  Source: {0}' -f $normalized.Source)
    )
    Write-FslFixLogLine -Run $Run -Section 'ACTION' -Line $lines
    return $normalized
}

function Get-FslFixRunSummary {
    <#
    .SYNOPSIS
        Builds the run summary (counts by Status and Mode, paths).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Run
    )

    $records = @($Run.Records)
    $summary = [ordered]@{
        PSTypeName        = 'FSLogixToolkit.RepairRunSummary'
        RunId             = $Run.RunId
        Mode              = $Run.Mode
        RollbackOfRunId   = $Run.RollbackOfRunId
        StartedAt         = $Run.StartedAt
        EndedAt           = $Run.EndedAt
        Total             = $records.Count
    }
    foreach ($status in $script:FslFixRecordStatuses) { $summary[$status] = @($records | Where-Object -FilterScript { $_.Status -eq $status }).Count }
    foreach ($mode in $script:FslFixRecordModes) { $summary["Mode$mode"] = @($records | Where-Object -FilterScript { $_.Mode -eq $mode }).Count }
    $summary['PreflightFailed'] = @($Run.Preflight | Where-Object -FilterScript { @('Fail', 'Error') -contains [string](Get-FslFixValue -InputObject $_ -Name 'Status') }).Count
    $summary['LogPath'] = $Run.LogPath
    $summary['JsonPath'] = $Run.JsonPath
    $summary['CsvPath'] = $Run.CsvPath
    $summary['RollbackStorePath'] = $Run.StatePath
    return [pscustomobject]$summary
}

function Complete-FslFixRun {
    <#
    .SYNOPSIS
        Finishes a repair run: writes .log (header, preflight, actions, summary), .json run envelope and .csv records,
        marks successfully undone actions as reverted in the original run's rollback store (Undo), applies retention
        (Apply/Undo), releases the lock and returns the summary. Idempotent.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal toolkit state/log write inside an already confirmed repair run; must not be skipped by an inherited WhatIf/Confirm preference.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Run
    )

    if ($Run.Completed) { return $Run.Summary }
    try {
        $Run.EndedAt = (Get-Date).ToString('o')

        if ($Run.Mode -eq 'Undo' -and $null -ne $Run.RollbackOfRunId) {
            $undone = @($Run.Records | Where-Object -FilterScript { $_.Mode -eq 'Undo' -and $_.Status -eq 'Pass' -and -not [string]::IsNullOrEmpty($_.ActionId) } |
                    ForEach-Object -Process { $_.ActionId } | Select-Object -Unique)
            if ($undone.Count -gt 0) {
                try {
                    $marked = Set-FslFixRollbackReverted -RunId ([guid]$Run.RollbackOfRunId) -ActionId $undone -UndoRunId ([guid]$Run.RunId)
                    Write-FslFixLogLine -Run $Run -Section 'SUMMARY' -Line @("Marked $marked action(s) reverted in run $($Run.RollbackOfRunId): $($undone -join ', ')")
                }
                catch { Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Mark reverted actions in run $($Run.RollbackOfRunId)" }
            }
        }

        $summary = Get-FslFixRunSummary -Run $Run
        $Run.Summary = $summary

        # Human log in canonical order (header, preflight, actions, summary); incremental lines are replaced.
        $summaryValues = @($summary.Total, $summary.Pass, $summary.Fail, $summary.Error, $summary.Skipped, $summary.Info, $summary.ModeExecuted,
            $summary.ModeWhatIf, $summary.ModeBlocked, $summary.ModeDeclined, $summary.ModeUndo, $summary.PreflightFailed, $Run.EndedAt)
        $summaryLine = 'Total {0}; Pass {1}; Fail {2}; Error {3}; Skipped {4}; Info {5}; Executed {6}; WhatIf {7}; Blocked {8}; Declined {9}; Undo {10}; Preflight failures {11}; Ended {12}' -f $summaryValues
        Write-FslFixLogLine -Run $Run -Section 'SUMMARY' -Line @($summaryLine)
        $ordered = [System.Collections.Generic.List[string]]::new()
        foreach ($section in @('[HEADER]', '[PREFLIGHT]', '[ACTION]', '[SUMMARY]')) {
            foreach ($line in $Run.LogLines) { if ($line.Contains(" $section ")) { $ordered.Add($line) } }
        }
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($Run.LogPath, (($ordered -join [Environment]::NewLine) + [Environment]::NewLine), $utf8)

        # JSON run envelope.
        $preflight = foreach ($item in $Run.Preflight) {
            $flat = [ordered]@{}
            foreach ($property in $item.PSObject.Properties) { $flat[$property.Name] = ConvertTo-FslFixText -InputObject $property.Value }
            $flat
        }
        $envelope = [ordered]@{
            SchemaVersion     = $script:FslFixSchemaVersion
            RunId             = $Run.RunId
            ComputerName      = $Run.ComputerName
            Operator          = [ordered]@{ Name = [string](ConvertTo-FslCoreRedactedText -Text ([string]$Run.Operator.Name)); Sid = $Run.Operator.Sid }
            IsElevated        = $Run.IsElevated
            ProcessId         = $Run.ProcessId
            InvocationSource  = [string](ConvertTo-FslCoreRedactedText -Text ([string]$Run.InvocationSource))
            PSVersion         = $Run.PSVersion
            ToolkitVersion    = $Run.ToolkitVersion
            FSLogixVersion    = $Run.FSLogixVersion
            ContainerMode     = $Run.ContainerMode
            Mode              = $Run.Mode
            RollbackOfRunId   = $Run.RollbackOfRunId
            ChangeReference   = if ($null -ne $Run.ChangeReference) { [string](ConvertTo-FslCoreRedactedText -Text ([string]$Run.ChangeReference)) } else { $null }
            StartedAt         = $Run.StartedAt
            EndedAt           = $Run.EndedAt
            Preflight         = @($preflight)
            Actions           = @($Run.Records)
            Summary           = $summary
            RollbackStorePath = $Run.StatePath
        }
        [System.IO.File]::WriteAllText($Run.JsonPath, (ConvertTo-FslFixJson -InputObject $envelope), $utf8)

        # CSV records (contract order; header written even when there are no records).
        $csvLines = [System.Collections.Generic.List[string]]::new()
        if ($Run.Records.Count -gt 0) {
            foreach ($line in @($Run.Records | Select-Object -Property $script:FslFixRecordProperties | ConvertTo-Csv -NoTypeInformation)) { $csvLines.Add($line) }
        }
        else {
            $csvLines.Add((@($script:FslFixRecordProperties | ForEach-Object -Process { '"{0}"' -f $_ }) -join ','))
        }
        [System.IO.File]::WriteAllText($Run.CsvPath, (($csvLines -join [Environment]::NewLine) + [Environment]::NewLine), $utf8)

        $Run.Completed = $true
        Write-FslLog -Message "Repair run $($Run.RunId) completed: $summaryLine" -Level Info -Component 'Repair'

        if ($Run.Mode -ne 'WhatIf') {
            try { $null = Remove-FslFixOldRun -ExcludeRunId ([guid]$Run.RunId) -WhatIf:$false -Confirm:$false }
            catch { Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Apply repair log retention' }
        }
        return $summary
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Complete repair run $($Run.RunId)"
        throw
    }
    finally {
        Exit-FslFixRunLock -Run $Run
    }
}

function Get-FslFixProtectedRunId {
    <#
    .SYNOPSIS
        Returns RunIds (string 'D') whose rollback store holds a temporary change that was not reverted, or whose store
        cannot be read/verified (kept as evidence).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StateRoot
    )

    if (-not [System.IO.Directory]::Exists($StateRoot)) { return }
    foreach ($folder in [System.IO.Directory]::GetDirectories($StateRoot)) {
        $name = [System.IO.Path]::GetFileName($folder)
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($name, [ref]$parsed)) { continue }
        $rollbackPath = Join-Path -Path $folder -ChildPath $script:FslFixRollbackFileName
        if (-not [System.IO.File]::Exists($rollbackPath)) { continue }
        $document = Read-FslFixRollbackDocument -RunId $parsed
        if ($null -eq $document) { $parsed.ToString('D'); continue }
        if ($null -eq $document['Entries']) { continue }
        foreach ($key in @($document['Entries'].Keys)) {
            $entry = $document['Entries'][$key]
            if ([bool]$entry['Temporary'] -and -not [bool]$entry['Reverted']) { $parsed.ToString('D'); break }
        }
    }
}

function Test-FslFixReparsePoint {
    <#
    .SYNOPSIS
        Returns $true when a folder is a reparse point (junction / symbolic link). Never throws ($true when unreadable).
    .DESCRIPTION
        Retention deletes folders recursively. learn.microsoft.com does not document how Remove-Item -Recurse treats a
        directory reparse point, so the toolkit does not rely on it: a day or state folder that somebody replaced with a
        junction is skipped instead of deleted (the repair report root is not required to be admin-only).
        Source: https://learn.microsoft.com/dotnet/api/system.io.fileattributes
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    try {
        $info = [System.IO.DirectoryInfo]::new($Path)
        if (-not $info.Exists) { return $false }
        return (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Check reparse point '$Path'"
        return $true
    }
}

function Remove-FslFixOldRun {
    <#
    .SYNOPSIS
        Retention: removes repair report day folders (<ReportRoot>/Repair/yyyy-MM-dd) and rollback state folders
        (<StateRoot>/<RunId>) older than Repair.RetainDays. Returns removed paths.
    .DESCRIPTION
        Never prunes a run with an unreverted temporary change (rollback entry Temporary = $true and Reverted = $false),
        never prunes a state folder whose store fails integrity (kept as evidence), never prunes -ExcludeRunId, and keeps a
        day folder that contains a log of a protected run. Only yyyy-MM-dd day folders and GUID-named state folders are
        considered. RetainDays <= 0 disables pruning. Age of a state folder = rollback.json StartedAt (fallback: folder
        last write time).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param(
        [int] $RetainDays,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $ReportRoot,

        [Nullable[guid]] $ExcludeRunId
    )

    if (-not $PSBoundParameters.ContainsKey('RetainDays')) { $RetainDays = [int](Get-FslFixConfig)['RetainDays'] }
    if ($RetainDays -le 0) { return }
    $cutoff = (Get-Date).Date.AddDays(-$RetainDays)
    $excluded = if ($null -ne $ExcludeRunId) { ([guid]$ExcludeRunId).ToString('D') } else { $null }

    $stateRoot = $null
    try { $stateRoot = Resolve-FslFixStateRoot } catch { Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Resolve StateRoot for retention' }
    $stateRootUsable = $false
    if ($null -ne $stateRoot -and [System.IO.Directory]::Exists($stateRoot)) {
        $check = Test-FslFixStateRoot
        $stateRootUsable = [bool]$check['Ok']
        if (-not $stateRootUsable) { Write-FslLog -Message "Retention: StateRoot skipped ($($check['Message']))" -Level Warning -Component 'Repair' }
    }
    $protected = @()
    if ($stateRootUsable) { $protected = @(Get-FslFixProtectedRunId -StateRoot $stateRoot) }
    if ($null -ne $excluded) { $protected += $excluded }
    $protectedShort = @($protected | ForEach-Object -Process { ([guid]$_).ToString('N').Substring(0, 8) })

    # State folders.
    if ($stateRootUsable) {
        foreach ($folder in [System.IO.Directory]::GetDirectories($stateRoot)) {
            $parsed = [guid]::Empty
            if (-not [guid]::TryParse([System.IO.Path]::GetFileName($folder), [ref]$parsed)) { continue }
            $id = $parsed.ToString('D')
            if ($protected -contains $id) { continue }
            if (Test-FslFixReparsePoint -Path $folder) {
                Write-FslLog -Message "Repair retention: skipped $folder (reparse point; never deleted recursively)" -Level Warning -Component 'Repair'
                continue
            }
            $age = [System.IO.Directory]::GetLastWriteTime($folder)
            $rollbackPath = Join-Path -Path $folder -ChildPath $script:FslFixRollbackFileName
            if ([System.IO.File]::Exists($rollbackPath)) {
                $document = Read-FslFixRollbackDocument -RunId $parsed
                if ($null -eq $document) { continue }
                $started = [datetime]::MinValue
                if ($document.Contains('StartedAt') -and [datetime]::TryParse([string]$document['StartedAt'], [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$started)) { $age = $started }
            }
            if ($age -ge $cutoff) { continue }
            if ($PSCmdlet.ShouldProcess($folder, 'Remove expired repair rollback state')) {
                try {
                    Remove-Item -LiteralPath $folder -Recurse -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
                    Write-FslLog -Message "Repair retention: removed state folder $folder" -Level Info -Component 'Repair'
                    $folder
                }
                catch { Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Remove expired state folder '$folder'" }
            }
        }
    }

    # Report day folders.
    try {
        $repairReportRoot = Resolve-FslFixReportRoot -ReportRoot $ReportRoot
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Resolve repair report folder for retention'
        return
    }
    if (-not [System.IO.Directory]::Exists($repairReportRoot)) { return }
    foreach ($folder in [System.IO.Directory]::GetDirectories($repairReportRoot)) {
        $date = [datetime]::MinValue
        if (-not [datetime]::TryParseExact([System.IO.Path]::GetFileName($folder), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref]$date)) { continue }
        if ($date -ge $cutoff) { continue }
        if (Test-FslFixReparsePoint -Path $folder) {
            Write-FslLog -Message "Repair retention: skipped $folder (reparse point; never deleted recursively)" -Level Warning -Component 'Repair'
            continue
        }
        $holdsProtected = $false
        foreach ($file in [System.IO.Directory]::GetFiles($folder, 'Repair_*')) {
            $match = [regex]::Match([System.IO.Path]::GetFileName($file), '^Repair_\d{6}_(?<id>[0-9a-fA-F]{8})\.')
            if ($match.Success -and $protectedShort -contains $match.Groups['id'].Value.ToLowerInvariant()) { $holdsProtected = $true; break }
        }
        if ($holdsProtected) {
            Write-FslLog -Message "Repair retention: kept $folder (run with unreverted temporary change)" -Level Info -Component 'Repair'
            continue
        }
        if ($PSCmdlet.ShouldProcess($folder, 'Remove expired repair log folder')) {
            try {
                Remove-Item -LiteralPath $folder -Recurse -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
                Write-FslLog -Message "Repair retention: removed log folder $folder" -Level Info -Component 'Repair'
                $folder
            }
            catch { Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Remove expired repair log folder '$folder'" }
        }
    }
}
