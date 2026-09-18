# Private helpers for Show-FslDashboard: the Repair menu, the repair plan dialog (GUI/RepairDialog.xaml), the Office
# container reset dialog (GUI/ContainerResetDialog.xaml) and the Repair tab (repair run history, repair results).
#
# Repair commands are called only through the CONTRACT P3.5/P3.6 public signatures - Get-FslRepairPlan,
# Test-FslRepairPrerequisite, Invoke-FslRepair, Undo-FslRepair and Get-FslRepairLog - and always in the shared
# background runspace (see FslGuiRunner.ps1). No repair command is ever started while a dialog is open: a dialog
# collects the operator's decision, closes, the work is queued, and the dialog is reopened with the outcome. That
# keeps the single-operation queue, the status bar and the Cancel button working exactly as for every other check
# and needs no assumption about what the dispatcher does while a modal window is shown.
#
# Safety rules implemented here (CONTRACT P3.7, REPAIR-PLAN section 5):
#   - Preview (Invoke-FslRepair -WhatIf) is always taken first; Apply is enabled only after a preview of the
#     IDENTICAL selection that reported at least one action as applicable (no drift).
#   - Apply and the container reset run Invoke-FslRepair -Confirm:$false only after the GUI confirmation dialog,
#     because a background runspace cannot answer a ShouldProcess prompt.
#   - Risk tier 3 needs the computer name typed in the dialog; the Office container reset needs the user name typed,
#     the signed-out attestation and a change reference.
#   - The toolkit never prompts for, reads, passes, logs or stores a password or PIN.
#
# Sources:
#   https://learn.microsoft.com/dotnet/api/system.windows.controls.datagrid.isreadonly
#     (a value of true at DataGrid, column or cell level takes precedence over a value of false)
#   https://learn.microsoft.com/dotnet/api/system.windows.controls.datagridcheckboxcolumn
#   https://learn.microsoft.com/dotnet/api/system.windows.window.showdialog
#   https://learn.microsoft.com/dotnet/api/system.windows.window.dialogresult
#   https://learn.microsoft.com/dotnet/api/system.security.cryptography.sha256
#   https://learn.microsoft.com/dotnet/api/system.data.dataview
#   https://learn.microsoft.com/en-us/fslogix/concepts-container-types

function Get-FslGuiRepairElevatedActionName {
    <#
    .SYNOPSIS
        Returns the dashboard actions that need an elevated session (CONTRACT P3.7).
    .DESCRIPTION
        Repair History and Open Repair Logs Folder are deliberately NOT in this list: reading past repair runs stays
        available for a standard user.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return , [string[]]@('MnuRepairPlan', 'MnuRepairContainer', 'MnuRepairUndo')
}

function Get-FslGuiRepairMenuTooltip {
    <#
    .SYNOPSIS
        Returns the Repair menu tooltip text for the current elevation state.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [bool] $IsElevated,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Account
    )

    $who = if ([string]::IsNullOrWhiteSpace($Account)) { 'this account' } else { $Account }
    if ($IsElevated) {
        return "Repairs are available: running elevated as $who. Every change is previewed first, recorded and can be undone (Undo a Repair Run...)."
    }
    return "Repairs need an elevated session (running as $who, not elevated). Use File > Relaunch Elevated (UAC)... or File > Relaunch as Different User (Smart Card)... Repair History and Open Repair Logs Folder stay available."
}

function Get-FslGuiRepairControlName {
    <#
    .SYNOPSIS
        Returns every x:Name referenced in GUI/RepairDialog.xaml.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return , [string[]]@(
        'WndRepair', 'TxtRepairInfo', 'GridRepairPlan', 'BtnRepairSelectReady', 'BtnRepairSelectNone',
        'TxtRepairPreviewState', 'TxtRepairDetailTitle', 'TxtRepairDetailBody', 'TxtRepairDetailGuidance',
        'TxtRepairDetailSource', 'BtnRepairOpenSource', 'TxtRepairChangeReference', 'TxtRepairTypedPrompt',
        'TxtRepairTypedConfirm', 'TxtRepairResult', 'TxtRepairError', 'BtnRepairPreview', 'BtnRepairApply', 'BtnRepairClose'
    )
}

function Get-FslGuiContainerResetControlName {
    <#
    .SYNOPSIS
        Returns every x:Name referenced in GUI/ContainerResetDialog.xaml.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return , [string[]]@(
        'WndContainerReset', 'TxtResetWarning', 'TxtResetInfo', 'GridResetContainers', 'TxtResetSelected',
        'TxtResetArchivePath', 'TxtResetChangeReference', 'TxtResetTypedPrompt', 'TxtResetTypedUser',
        'ChkResetSignedOut', 'TxtResetError', 'BtnResetStart', 'BtnResetCancel'
    )
}

function Initialize-FslGuiRepairState {
    <#
    .SYNOPSIS
        Creates the repair section of the dashboard state (plan, preview, results, dialogs). No WPF objects.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        Plan            = @()
        Preflight       = @()
        PlanAt          = $null
        Selection       = [string[]]@()
        ChangeReference = ''
        TypedConfirm    = ''
        PreviewHash     = ''
        PreviewAt       = $null
        PreviewActionId = [string[]]@()
        LastResult      = @()
        LastRunId       = ''
        LastMode        = ''
        Reopen          = $false
        ReopenContainer = $false
        Applying        = $false
        Dialog          = $null
        ContainerDialog = $null
        RunAsDialog     = $null
        Container       = @()
        ContainerAt     = $null
        ArchivePath     = ''
        SelectedRunId   = ''
        HistoryLoaded   = $false
    }
}

function Get-FslGuiRepairChangeOperationName {
    <#
    .SYNOPSIS
        Returns the background operations that change the machine and must never be interrupted (CONTRACT P3.7).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return , [string[]]@('RepairApply', 'RepairUndo', 'ContainerReset')
}

function Test-FslGuiRepairInProgress {
    <#
    .SYNOPSIS
        Returns $true only while a repair run that changes the machine is really running or still queued.
    .DESCRIPTION
        The Repair 'Applying' flag is raised BEFORE the operation is queued and cleared by Complete-FslGuiOperation
        when the run is over. A queued run can disappear before it ever starts (Cancel clears the queue, a failed
        background Initialize clears it, Invoke-FslGuiWork can throw between the flag and the queue), so the flag on
        its own is not proof that a change is in flight. This also inspects the runner and clears a stale flag,
        otherwise the window would refuse to close for the rest of the session (Window.Closing is cancelled while a
        repair applies).
        Sources: https://learn.microsoft.com/dotnet/api/system.windows.window.closing
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    if (-not [bool]$State['Repair']['Applying']) { return $false }
    $names = Get-FslGuiRepairChangeOperationName
    $runner = $State['Runner']
    $current = $runner['Current']
    if ($null -ne $current -and ([string]$current['Name']) -in $names) { return $true }
    foreach ($operation in $runner['Queue']) {
        if ($null -ne $operation -and ([string]$operation['Name']) -in $names) { return $true }
    }
    # Nothing is running and nothing is queued: the flag is stale, release the close / auto-refresh block.
    $State['Repair']['Applying'] = $false
    Write-FslLog -Message 'Repair in-progress flag released: no repair run is running or queued.' -Level Verbose -Component 'GUI'
    return $false
}

function Initialize-FslGuiRepairRunTable {
    <#
    .SYNOPSIS
        Creates the repair run history DataTable (Get-FslRepairLog output shape, CONTRACT P3.4).
    #>
    [CmdletBinding()]
    [OutputType([System.Data.DataTable])]
    param()

    $table = [System.Data.DataTable]::new('RepairRuns')
    foreach ($column in @('StartedAt', 'Mode', 'RunId', 'ComputerName', 'Operator', 'ChangeReference')) { [void]$table.Columns.Add($column, [string]) }
    foreach ($column in @('ActionCount', 'Pass', 'Fail', 'Error', 'Skipped', 'Info', 'PreflightFailed')) { [void]$table.Columns.Add($column, [int]) }
    foreach ($column in @('EndedAt', 'IsElevated', 'RollbackOfRunId', 'InvocationSource', 'ToolkitVersion', 'FSLogixVersion',
            'ContainerMode', 'LogPath', 'JsonPath', 'CsvPath', 'RollbackStorePath')) { [void]$table.Columns.Add($column, [string]) }
    Write-Output -InputObject $table -NoEnumerate
}

function Initialize-FslGuiRepairPlanTable {
    <#
    .SYNOPSIS
        Creates the repair plan DataTable bound to the plan grid of GUI/RepairDialog.xaml.
    .DESCRIPTION
        'Selected' is the only writable column (DataGridCheckBoxColumn); every other column is shown read-only.
    #>
    [CmdletBinding()]
    [OutputType([System.Data.DataTable])]
    param()

    $table = [System.Data.DataTable]::new('RepairPlan')
    [void]$table.Columns.Add('Selected', [bool])
    foreach ($column in @('ActionId', 'Title', 'Scope')) { [void]$table.Columns.Add($column, [string]) }
    [void]$table.Columns.Add('RiskTier', [int])
    foreach ($column in @('Status', 'Reason', 'Condition', 'Target', 'CurrentValue', 'ProposedValue', 'BlockReason',
            'Guidance', 'RollbackMethod', 'EffectiveWhen', 'Message', 'Source')) { [void]$table.Columns.Add($column, [string]) }
    [void]$table.Columns.Add('RequiresChangeReference', [bool])
    Write-Output -InputObject $table -NoEnumerate
}

function Initialize-FslGuiContainerTable {
    <#
    .SYNOPSIS
        Creates the Office container DataTable bound to GUI/ContainerResetDialog.xaml (CONTRACT 5.4 Container shape).
    #>
    [CmdletBinding()]
    [OutputType([System.Data.DataTable])]
    param()

    $table = [System.Data.DataTable]::new('OdfcContainers')
    foreach ($column in @('UserName', 'SID', 'SizeGB', 'LastWriteTime', 'IsLocked', 'AccountStatus', 'FullName',
            'FolderPath', 'FileName', 'StorageLocation', 'Scope')) { [void]$table.Columns.Add($column, [string]) }
    Write-Output -InputObject $table -NoEnumerate
}

function Get-FslGuiRepairPlanReason {
    <#
    .SYNOPSIS
        Returns the short 'reason / condition' text of a repair action for the plan grid.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Action
    )

    foreach ($name in @('BlockReason', 'Guidance', 'Message', 'Condition')) {
        $text = Get-FslGuiPropertyText -InputObject $Action -Name $name
        if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
    }
    return ''
}

function Sync-FslGuiRepairPlanTable {
    <#
    .SYNOPSIS
        Fills the plan DataTable from FSLogixToolkit.RepairAction objects and restores the given selection.
    .DESCRIPTION
        Returns the action ids that are in the table, in grid order. Data only (no WPF).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Data.DataTable] $Table,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Action,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $Selection = @()
    )

    $selected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Selection)) { if (-not [string]::IsNullOrWhiteSpace($item)) { [void]$selected.Add($item.Trim()) } }
    $ids = [System.Collections.Generic.List[string]]::new()

    $Table.BeginLoadData()
    try {
        $Table.Rows.Clear()
        foreach ($item in @($Action)) {
            if ($null -eq $item) { continue }
            $actionId = Get-FslGuiPropertyText -InputObject $item -Name 'ActionId'
            if ([string]::IsNullOrWhiteSpace($actionId)) { continue }
            $row = $Table.NewRow()
            $row['Selected'] = $selected.Contains($actionId)
            $row['ActionId'] = $actionId
            $row['Reason'] = Get-FslGuiRepairPlanReason -Action $item
            $tier = 0
            [void][int]::TryParse((Get-FslGuiPropertyText -InputObject $item -Name 'RiskTier'), [ref]$tier)
            $row['RiskTier'] = $tier
            $row['RequiresChangeReference'] = ((Get-FslGuiPropertyText -InputObject $item -Name 'RequiresChangeReference') -eq 'True')
            foreach ($name in @('Title', 'Scope', 'Status', 'Condition', 'Target', 'CurrentValue', 'ProposedValue',
                    'BlockReason', 'Guidance', 'RollbackMethod', 'EffectiveWhen', 'Message', 'Source')) {
                $row[$name] = Get-FslGuiPropertyText -InputObject $item -Name $name
            }
            $Table.Rows.Add($row)
            $ids.Add($actionId)
        }
    }
    finally {
        $Table.EndLoadData()
    }
    $Table.AcceptChanges()
    return , [string[]]$ids.ToArray()
}

function Get-FslGuiRepairTableSelection {
    <#
    .SYNOPSIS
        Returns the action ids whose 'Selected' checkbox is ticked, in grid order.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Data.DataTable] $Table
    )

    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($row in $Table.Rows) {
        $value = $row['Selected']
        if ($value -is [bool] -and $value) { $ids.Add([string]$row['ActionId']) }
    }
    return , [string[]]$ids.ToArray()
}

function Get-FslGuiRepairSelectionHash {
    <#
    .SYNOPSIS
        Returns a stable SHA256 token (hex) for a set of repair action ids; '' for an empty set.
    .DESCRIPTION
        Ids are trimmed, upper-cased (invariant), de-duplicated and sorted, so the token depends only on WHICH actions
        are selected, never on the order in which they were ticked. The token is compared to decide whether the Apply
        button may be enabled after a preview (CONTRACT P3.7).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $ActionId
    )

    $names = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in @($ActionId)) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        [void]$names.Add($item.Trim().ToUpperInvariant())
    }
    if ($names.Count -eq 0) { return '' }
    $text = ($names -join '|')
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $algorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
        return [System.BitConverter]::ToString($bytes).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Test-FslGuiTypedConfirmation {
    <#
    .SYNOPSIS
        Returns $true when the operator typed the expected confirmation text (trimmed, case-insensitive).
    .DESCRIPTION
        Used for the risk tier 3 computer-name confirmation and the Office container user-name confirmation. An empty
        expected value never confirms.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Expected,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    if ([string]::IsNullOrWhiteSpace($Expected) -or [string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [string]::Equals($Expected.Trim(), $Text.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-FslGuiRepairPreviewOutcome {
    <#
    .SYNOPSIS
        Reads the per-action outcome of a preview run (Invoke-FslRepair -WhatIf) from its Result objects.
    .DESCRIPTION
        Invoke-FslRepair emits one Result per action with Check 'Repair:<ActionId>'. A preview marks an action that
        would really be applied with Status Info and the message prefix 'WhatIf: would apply'; a refusal starts with
        'Blocked: ', guidance with 'Guidance only: ', and 'nothing to do' is reported as Pass. Returns one object per
        action id: ActionId, Status, Message, CanApply.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $ActionId
    )

    foreach ($id in @($ActionId)) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $check = 'Repair:{0}' -f $id
        $status = ''
        $message = ''
        foreach ($item in @($Result)) {
            if ($null -eq $item) { continue }
            if (-not [string]::Equals((Get-FslGuiPropertyText -InputObject $item -Name 'Check'), $check, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $status = Get-FslGuiPropertyText -InputObject $item -Name 'Status'
            $message = Get-FslGuiPropertyText -InputObject $item -Name 'Message'
            break
        }
        [pscustomobject]@{
            ActionId = $id
            Status   = $status
            Message  = $message
            CanApply = ($status -eq 'Info' -and $message.StartsWith('WhatIf:', [System.StringComparison]::OrdinalIgnoreCase))
        }
    }
}

function Get-FslGuiRepairApplyState {
    <#
    .SYNOPSIS
        Decides whether Apply may be enabled in the repair dialog. Pure function.
    .DESCRIPTION
        Apply is allowed only when the session is elevated, actions are selected, a preview was taken for exactly the
        same selection (selection hash equality - CONTRACT P3.7), that preview reported at least one applicable action
        (so a drift or gate refusal blocks Apply), a change reference is present when any selected action requires one,
        and the typed confirmation matches when a risk tier 3 action is selected.
        Returns @{ CanApply; Reason; SelectionHash; Applicable }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $Selection,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $PreviewHash,

        [Parameter()]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $PreviewActionId = @(),

        [Parameter()]
        [bool] $IsElevated = $false,

        [Parameter()]
        [bool] $RequiresChangeReference = $false,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ChangeReference,

        [Parameter()]
        [bool] $RequiresTypedConfirmation = $false,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TypedConfirmationExpected,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TypedConfirmationText
    )

    $selected = @(@($Selection) | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) })
    $hash = Get-FslGuiRepairSelectionHash -ActionId $selected
    $applicable = @(@($PreviewActionId) | Where-Object -FilterScript { $_ -in $selected })
    $state = @{ CanApply = $false; Reason = ''; SelectionHash = $hash; Applicable = [string[]]$applicable }

    if (-not $IsElevated) {
        $state['Reason'] = 'Repairs need an elevated session. Use File > Relaunch Elevated (UAC)... or File > Relaunch as Different User (Smart Card)...'
        return $state
    }
    if ($selected.Count -eq 0) {
        $state['Reason'] = 'Tick at least one action in the Apply column.'
        return $state
    }
    if ([string]::IsNullOrWhiteSpace($PreviewHash)) {
        $state['Reason'] = 'Take a preview (WhatIf) of this selection first.'
        return $state
    }
    if (-not [string]::Equals($PreviewHash, $hash, [System.StringComparison]::OrdinalIgnoreCase)) {
        $state['Reason'] = 'The selection changed since the preview. Preview this selection again before applying.'
        return $state
    }
    if ($RequiresChangeReference -and [string]::IsNullOrWhiteSpace($ChangeReference)) {
        $state['Reason'] = 'A change reference is required for the selected risk tier. Enter the change record reference.'
        return $state
    }
    if ($RequiresTypedConfirmation -and -not (Test-FslGuiTypedConfirmation -Expected $TypedConfirmationExpected -Text $TypedConfirmationText)) {
        $state['Reason'] = "A risk tier 3 action is selected: type the computer name '$TypedConfirmationExpected' to confirm."
        return $state
    }
    if ($applicable.Count -eq 0) {
        $state['Reason'] = 'The preview found no action that can be applied (every selected action was blocked, guidance only or already in the documented state).'
        return $state
    }
    $state['CanApply'] = $true
    $state['Reason'] = 'Preview taken for this selection: {0} action(s) can be applied.' -f $applicable.Count
    return $state
}

function Get-FslGuiRepairActionDetailText {
    <#
    .SYNOPSIS
        Builds the repair dialog detail pane texts for a plan row. Returns Title, Body, Guidance, Source, CanOpenSource.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Row
    )

    if ($null -eq $Row) {
        return @{ Title = 'Select a row to see its details.'; Body = ''; Guidance = ''; Source = ''; CanOpenSource = $false }
    }
    $read = { param([string] $Name) Get-FslGuiPropertyText -InputObject $Row -Name $Name }
    $title = '[{0}] {1} - {2} (scope {3}, risk tier {4})' -f (& $read 'Status'), (& $read 'ActionId'), (& $read 'Title'), (& $read 'Scope'), (& $read 'RiskTier')
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Target: $(& $read 'Target')")
    $lines.Add("Condition: $(& $read 'Condition')")
    $lines.Add("Current value: $(& $read 'CurrentValue')")
    $lines.Add("Proposed value: $(& $read 'ProposedValue')")
    $lines.Add("Rollback: $(& $read 'RollbackMethod')")
    $lines.Add("Effective when: $(& $read 'EffectiveWhen')")
    $lines.Add("Change reference required: $(& $read 'RequiresChangeReference')")
    $message = & $read 'Message'
    if ($message) { $lines.Add(''); $lines.Add($message) }

    $guidanceLines = [System.Collections.Generic.List[string]]::new()
    $blockReason = & $read 'BlockReason'
    if ($blockReason) { $guidanceLines.Add('Blocked because:'); $guidanceLines.Add($blockReason); $guidanceLines.Add('') }
    $guidance = & $read 'Guidance'
    if ($guidance) { $guidanceLines.Add('Guidance:'); $guidanceLines.Add($guidance) }
    if ($guidanceLines.Count -eq 0) { $guidanceLines.Add('No block reason or extra guidance for this action.') }

    $source = & $read 'Source'
    return @{
        Title         = $title
        Body          = ($lines -join [System.Environment]::NewLine)
        Guidance      = ($guidanceLines -join [System.Environment]::NewLine)
        Source        = $source
        CanOpenSource = (Test-FslGuiHttpsUrl -Text $source)
    }
}

function Get-FslGuiRepairPlanText {
    <#
    .SYNOPSIS
        Builds the repair dialog header text from the plan, the pre-flight results and the session facts.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Action,

        [Parameter()]
        [AllowEmptyCollection()]
        [object[]] $Preflight = @(),

        [Parameter()]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $Mode = 'ODFC',

        [Parameter()]
        [bool] $IsElevated = $false,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Account
    )

    $counts = [ordered]@{}
    foreach ($item in @($Action)) {
        $status = Get-FslGuiPropertyText -InputObject $item -Name 'Status'
        if ([string]::IsNullOrWhiteSpace($status)) { $status = 'Unknown' }
        if (-not $counts.Contains($status)) { $counts[$status] = 0 }
        $counts[$status] = [int]$counts[$status] + 1
    }
    $countText = if ($counts.Count -gt 0) { (@(foreach ($key in $counts.Keys) { '{0} {1}' -f $key, $counts[$key] }) -join ', ') } else { 'none' }
    $blocking = @(@($Preflight) | Where-Object -FilterScript {
            (Get-FslGuiPropertyText -InputObject $_ -Name 'Status') -in @('Fail', 'Error')
        })

    $lines = [System.Collections.Generic.List[string]]::new()
    $accountText = if ([string]::IsNullOrWhiteSpace($Account)) { 'this account' } else { $Account }
    $elevationText = if ($IsElevated) { 'elevated' } else { 'NOT elevated - repairs are refused' }
    $lines.Add(('Repair plan for {0} - container mode {1} - running as {2} ({3}).' -f [System.Environment]::MachineName, $Mode, $accountText, $elevationText))
    $lines.Add(('{0} action(s): {1}. Tick the actions to repair, take a Preview (WhatIf), then Apply the same selection.' -f @($Action).Count, $countText))
    if ($blocking.Count -gt 0) {
        $gateText = (@($blocking | ForEach-Object -Process {
                    '{0} ({1})' -f (Get-FslGuiPropertyText -InputObject $_ -Name 'Check'), (Get-FslGuiPropertyText -InputObject $_ -Name 'Status')
                }) | Select-Object -Unique) -join ', '
        $lines.Add(('Pre-flight gates reporting a problem: {0}.' -f $gateText))
    }
    return ($lines -join [System.Environment]::NewLine)
}

function Get-FslGuiRepairResultSummary {
    <#
    .SYNOPSIS
        Summarizes the Result objects of a repair run for the dialog and the status bar.
    .DESCRIPTION
        Returns @{ Text; RunId; Counts; NeedsAttention }. The RunId is read from the summary Result
        (Check 'RepairRun', Target = RunId).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result,

        [Parameter()]
        [ValidateSet('Preview', 'Apply', 'Undo', 'ContainerReset')]
        [string] $Mode = 'Apply'
    )

    $counts = [ordered]@{}
    $runId = ''
    $lines = [System.Collections.Generic.List[string]]::new()
    $attention = $false
    foreach ($item in @($Result)) {
        if ($null -eq $item) { continue }
        $status = Get-FslGuiPropertyText -InputObject $item -Name 'Status'
        if (-not $counts.Contains($status)) { $counts[$status] = 0 }
        $counts[$status] = [int]$counts[$status] + 1
        if ($status -in @('Fail', 'Error')) { $attention = $true }
        $check = Get-FslGuiPropertyText -InputObject $item -Name 'Check'
        if ($check -eq 'RepairRun') {
            $target = Get-FslGuiPropertyText -InputObject $item -Name 'Target'
            if (-not [string]::IsNullOrWhiteSpace($target)) { $runId = $target }
        }
        $lines.Add(('[{0}] {1}: {2}' -f $status, $check, (Get-FslGuiPropertyText -InputObject $item -Name 'Message')))
    }
    $label = switch ($Mode) {
        'Preview' { 'Preview (WhatIf) - nothing was changed' }
        'Undo' { 'Undo run' }
        'ContainerReset' { 'Office container reset' }
        default { 'Repair run' }
    }
    $header = if ($counts.Count -gt 0) {
        '{0}: {1}.' -f $label, ((@(foreach ($key in $counts.Keys) { '{0} {1}' -f $key, $counts[$key] })) -join ', ')
    }
    else {
        '{0}: no result was returned.' -f $label
    }
    if (-not [string]::IsNullOrWhiteSpace($runId)) { $header += " RunId: $runId" }
    if ($lines.Count -gt 0) { $lines.Insert(0, '') }
    $lines.Insert(0, $header)
    return @{
        Text           = ($lines -join [System.Environment]::NewLine)
        RunId          = $runId
        Counts         = $counts
        NeedsAttention = $attention
    }
}

function Get-FslGuiRepairRunDetailText {
    <#
    .SYNOPSIS
        Builds the 'Selected repair run' text of the Repair tab from a repair log row (Get-FslRepairLog).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Row
    )

    if ($null -eq $Row) { return 'Select a repair run to see its details.' }
    $read = { param([string] $Name) Get-FslGuiPropertyText -InputObject $Row -Name $Name }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(('RunId: {0} ({1})' -f (& $read 'RunId'), (& $read 'Mode')))
    $lines.Add(('Started: {0}   Ended: {1}   Computer: {2}' -f (& $read 'StartedAt'), (& $read 'EndedAt'), (& $read 'ComputerName')))
    $lines.Add(('Operator: {0}   Elevated: {1}   Change reference: {2}' -f (& $read 'Operator'), (& $read 'IsElevated'), (& $read 'ChangeReference')))
    $lines.Add(('Actions: {0}   Pass {1}, Fail {2}, Error {3}, Skipped {4}, Info {5}, pre-flight failed {6}' -f (& $read 'ActionCount'),
            (& $read 'Pass'), (& $read 'Fail'), (& $read 'Error'), (& $read 'Skipped'), (& $read 'Info'), (& $read 'PreflightFailed')))
    $rollbackOf = & $read 'RollbackOfRunId'
    if ($rollbackOf) { $lines.Add("This run undid run: $rollbackOf") }
    $lines.Add(('Log: {0}' -f (& $read 'LogPath')))
    return ($lines -join [System.Environment]::NewLine)
}

function Get-FslGuiRepairFolder {
    <#
    .SYNOPSIS
        Returns <ReportRoot>/<Repair.FolderName> (Config/Settings.psd1, toolkit default 'Repair').
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $reportRoot = [string]$State['ReportRoot']
    if ([string]::IsNullOrWhiteSpace($reportRoot)) { return $null }
    $folderName = 'Repair'
    try {
        $repair = Get-FslConfig -Section 'Repair'
        if ($repair -is [hashtable] -and $repair.ContainsKey('FolderName') -and -not [string]::IsNullOrWhiteSpace([string]$repair['FolderName'])) {
            $folderName = [string]$repair['FolderName']
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Read the Repair settings section'
    }
    return (Join-Path -Path $reportRoot -ChildPath $folderName)
}

function Get-FslGuiRepairOperation {
    <#
    .SYNOPSIS
        Builds the background operation for a repair command (CONTRACT P3.5/P3.6 signatures). Pure function.
    .DESCRIPTION
        Kind: Plan (Get-FslRepairPlan + Test-FslRepairPrerequisite), Preview (Invoke-FslRepair -WhatIf),
        Apply (Invoke-FslRepair -Confirm:$false), Undo (Undo-FslRepair -Confirm:$false), Log (Get-FslRepairLog),
        ContainerList (Get-FslContainer -Scope ODFC) and ContainerReset (Invoke-FslRepair -ActionId FIX-ODFC-02).
        Operations that produce Result rows replace the Repair category rows of the container mode's scopes.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Plan', 'Preview', 'Apply', 'Undo', 'Log', 'ContainerList', 'ContainerReset')]
        [string] $Kind,

        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $ContainerScope,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $ActionId = @(),

        [Parameter()]
        [ValidateRange(-1, 3)]
        [int] $MaxRiskTier = -1,

        [Parameter()]
        [bool] $AllowDisruptive = $false,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ChangeReference,

        [Parameter()]
        [bool] $UserSignedOutConfirmed = $false,

        [Parameter()]
        [hashtable] $Parameters = @{},

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $RunId,

        [Parameter()]
        [ValidateRange(0, 3650)]
        [int] $Days = 0
    )

    $scopes = [System.Collections.Generic.List[string]]::new()
    foreach ($item in (Get-FslGuiScopeList -Mode $ContainerScope)) { $scopes.Add($item) }
    $ids = [string[]]@(@($ActionId) | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) })
    # PowerShell variable names are case-insensitive: this must NOT be called $parameters (that is the -Parameters input).
    $operationParameter = @{ ContainerScope = $ContainerScope }
    if ($ids.Count -gt 0) { $operationParameter['ActionId'] = $ids }
    if ($MaxRiskTier -ge 0) { $operationParameter['MaxRiskTier'] = $MaxRiskTier }
    if ($AllowDisruptive) { $operationParameter['AllowDisruptive'] = $true }
    if ($UserSignedOutConfirmed) { $operationParameter['UserSignedOutConfirmed'] = $true }
    if (-not [string]::IsNullOrWhiteSpace($ChangeReference)) { $operationParameter['ChangeReference'] = $ChangeReference.Trim() }
    if ($Parameters.Count -gt 0) { $operationParameter['Parameters'] = $Parameters.Clone() }
    if (-not [string]::IsNullOrWhiteSpace($RunId)) { $operationParameter['RunId'] = $RunId.Trim() }
    if ($Days -gt 0) { $operationParameter['Days'] = $Days }

    switch ($Kind) {
        'Plan' {
            return (Get-FslGuiOperation -Name 'RepairPlan' -Display 'Repair plan (read-only)' -Parameter $operationParameter)
        }
        'Preview' {
            return (Get-FslGuiOperation -Name 'RepairPreview' -Display ('Repair preview - WhatIf ({0})' -f ($ids -join ', ')) `
                    -Parameter $operationParameter -Category 'Repair' -Scope $scopes.ToArray())
        }
        'Apply' {
            return (Get-FslGuiOperation -Name 'RepairApply' -Display ('Repair apply ({0})' -f ($ids -join ', ')) `
                    -Parameter $operationParameter -Category 'Repair' -Scope $scopes.ToArray())
        }
        'Undo' {
            return (Get-FslGuiOperation -Name 'RepairUndo' -Display ('Undo repair run {0}' -f $RunId) `
                    -Parameter $operationParameter -Category 'Repair' -Scope $scopes.ToArray())
        }
        'Log' {
            return (Get-FslGuiOperation -Name 'RepairLog' -Display 'Repair history' -Parameter $operationParameter)
        }
        'ContainerList' {
            return (Get-FslGuiOperation -Name 'ContainerList' -Display 'Office containers (ODFC)' -Parameter $operationParameter)
        }
        default {
            return (Get-FslGuiOperation -Name 'ContainerReset' -Display 'Office container reset (FIX-ODFC-02)' `
                    -Parameter $operationParameter -Category 'Repair' -Scope $scopes.ToArray())
        }
    }
}

function Test-FslGuiContainerResetRequest {
    <#
    .SYNOPSIS
        Validates the Office container reset dialog input (CONTRACT P3.6 gates the operator controls). Pure function.
    .DESCRIPTION
        Returns @{ IsValid; Message }. Every gate the handler itself re-checks (elevation, locks, provenance, free
        space) is deliberately NOT repeated here: this only refuses input the operator can still correct.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $UserName,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ArchivePath,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ChangeReference,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TypedUserName,

        [Parameter()]
        [bool] $SignedOutConfirmed = $false,

        [Parameter()]
        [bool] $IsElevated = $false
    )

    if (-not $IsElevated) {
        return @{ IsValid = $false; Message = 'Repairs need an elevated session. Use File > Relaunch Elevated (UAC)... or File > Relaunch as Different User (Smart Card)...' }
    }
    if ([string]::IsNullOrWhiteSpace($UserName)) {
        return @{ IsValid = $false; Message = 'Select the Office container to reset.' }
    }
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
        return @{ IsValid = $false; Message = 'Enter the archive folder the container is moved to (Settings Repair.ContainerArchivePath is the default).' }
    }
    if ([string]::IsNullOrWhiteSpace($ChangeReference)) {
        return @{ IsValid = $false; Message = 'A change reference is required for this risk tier 3 action.' }
    }
    if (-not $SignedOutConfirmed) {
        return @{ IsValid = $false; Message = 'Confirm that the user is signed out of every session host.' }
    }
    if (-not (Test-FslGuiTypedConfirmation -Expected $UserName -Text $TypedUserName)) {
        return @{ IsValid = $false; Message = "Type the user name '$UserName' to confirm which container is archived." }
    }
    return @{ IsValid = $true; Message = '' }
}

function Get-FslGuiContainerWarningText {
    <#
    .SYNOPSIS
        Returns the data warning shown in the Office container reset dialog.
    .NOTES
        Sources: https://learn.microsoft.com/en-us/fslogix/concepts-container-types
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return @'
The user's Office container file is COPIED to the archive folder (length and SHA256 verified) and then removed from the storage location. FSLogix creates a new, empty Office container at the user's next sign-in.

Microsoft documents that most of the data an Office container holds is re-synced from Microsoft 365 (for example the Outlook cache, OneDrive and Teams caches). Anything in the container that is local-only or not yet synced - for example a local OneNote notebook - will NOT be in the new container until the archive is restored.

The user must be signed out of EVERY session host before this runs. The change is recorded and can be undone (Undo a Repair Run...) as long as no new container exists at the original path.
'@
}

function Sync-FslGuiRepairView {
    <#
    .SYNOPSIS
        Updates the Repair tab: the elevation / history note and the details of the selected repair run.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $controls = $State['Controls']
    $repair = $State['Repair']
    $account = Get-FslGuiCurrentAccountText
    $notes = [System.Collections.Generic.List[string]]::new()
    $notes.Add((Get-FslGuiRepairMenuTooltip -IsElevated ([bool]$State['IsElevated']) -Account $account))
    $notes.Add(('Repair runs: {0}. Repair logs folder: {1}' -f $State['Tables']['Repair'].Rows.Count, (Get-FslGuiRepairFolder -State $State)))
    if (-not [bool]$repair['HistoryLoaded']) { $notes.Add('History not read yet - use Refresh History.') }
    $controls['TxtRepairTabNote'].Text = ($notes -join ' ')

    $row = $null
    $grid = $controls['GridRepairHistory']
    if ($grid.SelectedItem -is [System.Data.DataRowView] -and
        $grid.SelectedItem.Row.RowState -notin @([System.Data.DataRowState]::Detached, [System.Data.DataRowState]::Deleted)) {
        $row = ConvertFrom-FslGuiDataRow -Row $grid.SelectedItem
    }
    $repair['SelectedRunId'] = if ($null -ne $row) { Get-FslGuiPropertyText -InputObject $row -Name 'RunId' } else { '' }
    $controls['TxtRepairRunDetail'].Text = Get-FslGuiRepairRunDetailText -Row $row
}

function Sync-FslGuiRepairDialogState {
    <#
    .SYNOPSIS
        Recomputes the repair dialog texts and button states from the current selection and the last preview.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $dialog = $State['Repair']['Dialog']
    if ($null -eq $dialog) { return }
    $controls = $dialog['Controls']
    $table = $dialog['Table']
    $selection = Get-FslGuiRepairTableSelection -Table $table

    $requiresReference = $false
    $maxTier = 0
    foreach ($row in $table.Rows) {
        if (-not ($row['Selected'] -is [bool] -and $row['Selected'])) { continue }
        if ($row['RequiresChangeReference'] -is [bool] -and $row['RequiresChangeReference']) { $requiresReference = $true }
        if ([int]$row['RiskTier'] -gt $maxTier) { $maxTier = [int]$row['RiskTier'] }
    }
    $computer = [System.Environment]::MachineName
    $needsTyped = ($maxTier -ge 3)
    $controls['TxtRepairTypedPrompt'].Text = if ($needsTyped) { "Type '$computer' to confirm tier 3:" } else { 'Tier 3 confirmation (not needed):' }
    $controls['TxtRepairTypedConfirm'].IsEnabled = $needsTyped

    $applyState = Get-FslGuiRepairApplyState -Selection $selection -PreviewHash ([string]$State['Repair']['PreviewHash']) `
        -PreviewActionId ([string[]]$State['Repair']['PreviewActionId']) -IsElevated ([bool]$State['IsElevated']) `
        -RequiresChangeReference $requiresReference -ChangeReference ([string]$controls['TxtRepairChangeReference'].Text) `
        -RequiresTypedConfirmation $needsTyped -TypedConfirmationExpected $computer -TypedConfirmationText ([string]$controls['TxtRepairTypedConfirm'].Text)

    $dialog['ApplyState'] = $applyState
    $dialog['Selection'] = [string[]]$selection
    $dialog['RequiresChangeReference'] = $requiresReference
    $dialog['MaxRiskTier'] = $maxTier
    $controls['BtnRepairApply'].IsEnabled = [bool]$applyState['CanApply']
    $controls['BtnRepairPreview'].IsEnabled = ($selection.Count -gt 0)

    $previewText = if ([string]::IsNullOrWhiteSpace([string]$State['Repair']['PreviewHash'])) {
        'No preview taken yet.'
    }
    elseif ($null -ne $State['Repair']['PreviewAt']) {
        'Preview taken at {0}. {1}' -f ([datetime]$State['Repair']['PreviewAt']).ToString('HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture), [string]$applyState['Reason']
    }
    else {
        [string]$applyState['Reason']
    }
    $controls['TxtRepairPreviewState'].Text = $previewText
    $controls['TxtRepairError'].Text = if ($applyState['CanApply']) { '' } else { [string]$applyState['Reason'] }
}

function Sync-FslGuiRepairDialogDetail {
    <#
    .SYNOPSIS
        Shows the selected plan row in the repair dialog detail pane.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $dialog = $State['Repair']['Dialog']
    if ($null -eq $dialog) { return }
    $controls = $dialog['Controls']
    $row = $null
    $selected = $controls['GridRepairPlan'].SelectedItem
    if ($selected -is [System.Data.DataRowView] -and
        $selected.Row.RowState -notin @([System.Data.DataRowState]::Detached, [System.Data.DataRowState]::Deleted)) {
        $row = ConvertFrom-FslGuiDataRow -Row $selected
    }
    $detail = Get-FslGuiRepairActionDetailText -Row $row
    $controls['TxtRepairDetailTitle'].Text = [string]$detail['Title']
    $controls['TxtRepairDetailBody'].Text = [string]$detail['Body']
    $controls['TxtRepairDetailGuidance'].Text = [string]$detail['Guidance']
    $controls['TxtRepairDetailSource'].Text = [string]$detail['Source']
    $controls['BtnRepairOpenSource'].IsEnabled = [bool]$detail['CanOpenSource']
}

function Invoke-FslGuiRepairDialogAction {
    <#
    .SYNOPSIS
        Click handler body of the repair dialog buttons (select, preview, apply, open source).
    .DESCRIPTION
        Preview and Apply store the intent and close the dialog: the work is queued by Invoke-FslGuiRepairDialog and
        runs in the shared background runspace, then the dialog is reopened with the outcome.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('SelectReady', 'SelectNone', 'Preview', 'Apply', 'OpenSource')]
        [string] $Name
    )

    $state = $script:FslGuiState
    if ($null -eq $state -or $null -eq $state['Repair']['Dialog']) { return }
    $dialog = $state['Repair']['Dialog']
    $controls = $dialog['Controls']
    $table = $dialog['Table']
    # A checkbox cell only reaches the DataTable when its edit is committed: the first CommitEdit commits the cell,
    # the second the pending row (https://learn.microsoft.com/dotnet/api/system.windows.controls.datagrid.commitedit).
    try {
        [void]$controls['GridRepairPlan'].CommitEdit()
        [void]$controls['GridRepairPlan'].CommitEdit()
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Commit the repair plan grid edit'
    }

    switch ($Name) {
        'SelectReady' {
            foreach ($row in $table.Rows) { $row['Selected'] = ([string]$row['Status'] -eq 'Ready') }
            $table.AcceptChanges()
            Sync-FslGuiRepairDialogState -State $state
        }
        'SelectNone' {
            foreach ($row in $table.Rows) { $row['Selected'] = $false }
            $table.AcceptChanges()
            Sync-FslGuiRepairDialogState -State $state
        }
        'OpenSource' {
            $text = [string]$controls['TxtRepairDetailSource'].Text
            if (-not (Test-FslGuiHttpsUrl -Text $text)) {
                $controls['TxtRepairError'].Text = 'Only https sources can be opened.'
                return
            }
            Start-Process -FilePath ([System.Uri]::new($text.Trim())).AbsoluteUri -ErrorAction Stop
        }
        'Preview' {
            Sync-FslGuiRepairDialogState -State $state
            $selection = [string[]]$dialog['Selection']
            if ($selection.Count -eq 0) {
                $controls['TxtRepairError'].Text = 'Tick at least one action in the Apply column.'
                return
            }
            $dialog['Intent'] = 'Preview'
            $dialog['Window'].DialogResult = $true
        }
        'Apply' {
            Sync-FslGuiRepairDialogState -State $state
            $applyState = $dialog['ApplyState']
            if (-not [bool]$applyState['CanApply']) {
                $controls['TxtRepairError'].Text = [string]$applyState['Reason']
                return
            }
            $applicable = [string[]]$applyState['Applicable']
            $text = "Apply {0} repair action(s) on {1} now?`r`n`r`n{2}`r`n`r`nThe state before each change is recorded first, so the run can be undone with Repair > Undo a Repair Run... Nothing else is changed." -f `
                $applicable.Count, [System.Environment]::MachineName, ($applicable -join ', ')
            $answer = [string][System.Windows.MessageBox]::Show($dialog['Window'], $text, 'Apply Repairs',
                [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($answer -ne 'Yes') {
                $controls['TxtRepairError'].Text = 'Apply cancelled; nothing was changed.'
                return
            }
            $dialog['Intent'] = 'Apply'
            $dialog['Window'].DialogResult = $true
        }
    }
}

function Show-FslGuiRepairDialog {
    <#
    .SYNOPSIS
        Shows GUI/RepairDialog.xaml with the current plan. Returns @{ Intent; ActionId; ChangeReference; MaxRiskTier }
        or $null when the operator closed it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $path = Join-Path -Path ([string]$State['ModuleRoot']) -ChildPath 'GUI/RepairDialog.xaml'
    $window = Import-FslGuiXaml -Path $path
    $connected = Connect-FslGuiControl -Root $window -Name (Get-FslGuiRepairControlName)
    if ($connected['Missing'].Count -gt 0) {
        throw [System.InvalidOperationException]::new("GUI/RepairDialog.xaml is missing control(s): $($connected['Missing'] -join ', ')")
    }
    $controls = $connected['Controls']
    $repair = $State['Repair']

    $table = Initialize-FslGuiRepairPlanTable
    $null = Sync-FslGuiRepairPlanTable -Table $table -Action @($repair['Plan']) -Selection ([string[]]$repair['Selection'])
    $controls['GridRepairPlan'].ItemsSource = $table.DefaultView
    $controls['TxtRepairInfo'].Text = Get-FslGuiRepairPlanText -Action @($repair['Plan']) -Preflight @($repair['Preflight']) `
        -Mode ([string]$State['Mode']) -IsElevated ([bool]$State['IsElevated']) -Account (Get-FslGuiCurrentAccountText)
    $controls['TxtRepairChangeReference'].Text = [string]$repair['ChangeReference']
    $controls['TxtRepairTypedConfirm'].Text = [string]$repair['TypedConfirm']
    $controls['TxtRepairResult'].Text = if (@($repair['LastResult']).Count -gt 0) {
        $summaryMode = if ([string]$repair['LastMode'] -eq 'Preview') { 'Preview' } else { 'Apply' }
        [string]((Get-FslGuiRepairResultSummary -Result @($repair['LastResult']) -Mode $summaryMode)['Text'])
    }
    else { 'No repair run in this dashboard session yet.' }
    $controls['TxtRepairError'].Text = ''

    $repair['Dialog'] = @{
        Window                  = $window
        Controls                = $controls
        Table                   = $table
        Intent                  = 'Close'
        Selection               = [string[]]@()
        ApplyState              = @{ CanApply = $false; Reason = ''; SelectionHash = ''; Applicable = [string[]]@() }
        RequiresChangeReference = $false
        MaxRiskTier             = 0
    }
    try {
        $controls['BtnRepairSelectReady'].Add_Click({
                try { Invoke-FslGuiRepairDialogAction -Name 'SelectReady' } catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Repair dialog select ready' }
            })
        $controls['BtnRepairSelectNone'].Add_Click({
                try { Invoke-FslGuiRepairDialogAction -Name 'SelectNone' } catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Repair dialog clear selection' }
            })
        $controls['BtnRepairPreview'].Add_Click({
                try { Invoke-FslGuiRepairDialogAction -Name 'Preview' } catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Repair dialog preview' }
            })
        $controls['BtnRepairApply'].Add_Click({
                try { Invoke-FslGuiRepairDialogAction -Name 'Apply' } catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Repair dialog apply' }
            })
        $controls['BtnRepairOpenSource'].Add_Click({
                try { Invoke-FslGuiRepairDialogAction -Name 'OpenSource' } catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Repair dialog open source' }
            })
        $controls['GridRepairPlan'].Add_SelectionChanged({
                try {
                    $current = $script:FslGuiState
                    if ($null -ne $current) { Sync-FslGuiRepairDialogDetail -State $current }
                }
                catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Repair dialog row selection' }
            })
        # DataTable.RowChanged fires when a ticked checkbox is committed to the row, so the Apply button follows the
        # selection. The authoritative check still runs when Apply is pressed (Invoke-FslGuiRepairDialogAction).
        # https://learn.microsoft.com/dotnet/api/system.data.datatable.rowchanged
        $table.add_RowChanged({
                try {
                    $current = $script:FslGuiState
                    if ($null -ne $current) { Sync-FslGuiRepairDialogState -State $current }
                }
                catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Repair dialog selection change' }
            })
        $controls['TxtRepairChangeReference'].Add_TextChanged({
                try {
                    $current = $script:FslGuiState
                    if ($null -ne $current) { Sync-FslGuiRepairDialogState -State $current }
                }
                catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Repair dialog change reference' }
            })
        $controls['TxtRepairTypedConfirm'].Add_TextChanged({
                try {
                    $current = $script:FslGuiState
                    if ($null -ne $current) { Sync-FslGuiRepairDialogState -State $current }
                }
                catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Repair dialog typed confirmation' }
            })

        Sync-FslGuiRepairDialogState -State $State
        Sync-FslGuiRepairDialogDetail -State $State
        $window.Owner = $State['Window']
        $accepted = $window.ShowDialog()
        $intent = [string]$repair['Dialog']['Intent']
        # Get-FslGuiRepairTableSelection returns its array as ONE pipeline object (unary comma): cast it, never wrap
        # it in @() - that would produce a single element holding the whole array.
        $selection = [string[]](Get-FslGuiRepairTableSelection -Table $table)
        $repair['Selection'] = $selection
        $repair['ChangeReference'] = ([string]$controls['TxtRepairChangeReference'].Text).Trim()
        $repair['TypedConfirm'] = ([string]$controls['TxtRepairTypedConfirm'].Text).Trim()
        $maxTier = [int]$repair['Dialog']['MaxRiskTier']
        # The actions the operator was shown (and confirmed) in the Apply message box: exactly the previewed
        # selection the preview reported as applicable. Apply must not run anything else.
        $applicable = [string[]]@($repair['Dialog']['ApplyState']['Applicable'])
    }
    finally {
        $repair['Dialog'] = $null
    }
    if ($accepted -ne $true -or $intent -notin @('Preview', 'Apply')) { return $null }
    return @{
        Intent          = $intent
        ActionId        = $selection
        Applicable      = $applicable
        ChangeReference = [string]$repair['ChangeReference']
        MaxRiskTier     = $maxTier
    }
}

function Invoke-FslGuiRepairDialog {
    <#
    .SYNOPSIS
        Shows the repair dialog and queues the preview or apply the operator confirmed. Returns a status text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $repair = $State['Repair']
    if (@($repair['Plan']).Count -eq 0) {
        $repair['Reopen'] = $false
        return 'The repair plan is empty: there is nothing to repair on this computer for the current container mode.'
    }
    $request = Show-FslGuiRepairDialog -State $State
    if ($null -eq $request) {
        $repair['Reopen'] = $false
        return 'Repair dialog closed; nothing was changed.'
    }

    $ids = [string[]]$request['ActionId']
    $tier = [int]$request['MaxRiskTier']
    $repair['Reopen'] = $true
    if ($request['Intent'] -eq 'Preview') {
        $repair['PreviewHash'] = ''
        $repair['PreviewActionId'] = [string[]]@()
        $repair['PreviewAt'] = $null
        $operation = Get-FslGuiRepairOperation -Kind 'Preview' -ContainerScope ([string]$State['Mode']) -ActionId $ids `
            -MaxRiskTier ([math]::Max($tier, 2)) -AllowDisruptive ($tier -ge 3) -ChangeReference ([string]$request['ChangeReference']) `
            -UserSignedOutConfirmed $false
        Invoke-FslGuiWork -State $State -Operation @($operation) -Tab 'TabRepair' -InnerTab 'TabRepairResults'
        return "Previewing $($ids.Count) repair action(s) (WhatIf); nothing is changed."
    }

    # Apply exactly the actions the confirmation dialog listed - the previewed selection that the preview reported
    # as applicable. Sending the whole ticked selection could apply an action that was Blocked or Guidance only in
    # the preview (and therefore never confirmed) if its condition cleared in the meantime.
    $applyIds = [string[]]@($request['Applicable'])
    if ($applyIds.Count -eq 0) {
        return 'The preview found no action that can be applied; nothing was started.'
    }
    $repair['Applying'] = $true
    Suspend-FslGuiAutoRefresh -State $State
    $operation = Get-FslGuiRepairOperation -Kind 'Apply' -ContainerScope ([string]$State['Mode']) -ActionId $applyIds `
        -MaxRiskTier ([math]::Max($tier, 2)) -AllowDisruptive ($tier -ge 3) -ChangeReference ([string]$request['ChangeReference']) `
        -UserSignedOutConfirmed $false
    Invoke-FslGuiWork -State $State -Operation @($operation) -Tab 'TabRepair' -InnerTab 'TabRepairResults'
    return "Applying $($applyIds.Count) repair action(s). The window cannot be closed until the run finishes."
}

function Invoke-FslGuiRepairPlanAction {
    <#
    .SYNOPSIS
        Repair > Repair Plan (Preview)...: queues Get-FslRepairPlan + Test-FslRepairPrerequisite; the dialog opens
        when the plan is available.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    if (-not [bool]$State['IsElevated']) {
        [void](Show-FslGuiMessage -State $State -Text (Get-FslGuiRepairMenuTooltip -IsElevated $false -Account (Get-FslGuiCurrentAccountText)) `
                -Caption 'Repair Plan' -Icon 'Warning')
        return 'Repairs need an elevated session.'
    }
    $repair = $State['Repair']
    $repair['PreviewHash'] = ''
    $repair['PreviewActionId'] = [string[]]@()
    $repair['PreviewAt'] = $null
    $repair['Reopen'] = $true
    Invoke-FslGuiWork -State $State -Operation @(Get-FslGuiRepairOperation -Kind 'Plan' -ContainerScope ([string]$State['Mode'])) `
        -Tab 'TabRepair' -InnerTab 'TabRepairResults'
    return 'Building the repair plan (read-only)...'
}

function Invoke-FslGuiRepairHistoryAction {
    <#
    .SYNOPSIS
        Repair > Repair History... / Refresh History: queues Get-FslRepairLog. Stays available for a standard user.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    Invoke-FslGuiWork -State $State -Operation @(Get-FslGuiRepairOperation -Kind 'Log' -ContainerScope ([string]$State['Mode'])) `
        -Tab 'TabRepair' -InnerTab 'TabRepairRuns'
    return 'Reading the repair history...'
}

function Invoke-FslGuiRepairUndoAction {
    <#
    .SYNOPSIS
        Repair > Undo a Repair Run...: confirms the selected run of the Repair tab and queues Undo-FslRepair.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    if (-not [bool]$State['IsElevated']) {
        [void](Show-FslGuiMessage -State $State -Text (Get-FslGuiRepairMenuTooltip -IsElevated $false -Account (Get-FslGuiCurrentAccountText)) `
                -Caption 'Undo a Repair Run' -Icon 'Warning')
        return 'Repairs need an elevated session.'
    }
    Select-FslGuiTab -State $State -Tab 'TabRepair' -InnerTab 'TabRepairRuns'
    Sync-FslGuiRepairView -State $State
    $runId = [string]$State['Repair']['SelectedRunId']
    if ([string]::IsNullOrWhiteSpace($runId)) {
        if (-not [bool]$State['Repair']['HistoryLoaded']) { return Invoke-FslGuiRepairHistoryAction -State $State }
        return 'Select the repair run to undo in the Repair Runs grid first.'
    }
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($runId, [ref]$parsed)) {
        return "The selected row does not carry a valid RunId ('$runId')."
    }
    $detail = Get-FslGuiRepairRunDetailText -Row (ConvertFrom-FslGuiDataRow -Row $State['Controls']['GridRepairHistory'].SelectedItem)
    $text = "Undo this repair run?`r`n`r`n$detail`r`n`r`nThe recorded state before each change is restored. The undo refuses any action whose state changed since the repair (drift) and any run whose rollback store fails its integrity check."
    $answer = Show-FslGuiMessage -State $State -Text $text -Caption 'Undo a Repair Run' -Button 'YesNo' -Icon 'Warning'
    if ($answer -ne 'Yes') { return 'Undo cancelled; nothing was changed.' }

    $State['Repair']['Applying'] = $true
    Suspend-FslGuiAutoRefresh -State $State
    Invoke-FslGuiWork -State $State -Operation @(Get-FslGuiRepairOperation -Kind 'Undo' -ContainerScope ([string]$State['Mode']) -RunId $parsed.ToString('D')) `
        -Tab 'TabRepair' -InnerTab 'TabRepairResults'
    return "Undoing repair run $($parsed.ToString('D')). The window cannot be closed until the run finishes."
}

function Sync-FslGuiContainerResetDialogState {
    <#
    .SYNOPSIS
        Recomputes the Office container reset dialog texts and the Start button state from the current input.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $dialog = $State['Repair']['ContainerDialog']
    if ($null -eq $dialog) { return }
    $controls = $dialog['Controls']
    $row = $null
    $selected = $controls['GridResetContainers'].SelectedItem
    if ($selected -is [System.Data.DataRowView] -and
        $selected.Row.RowState -notin @([System.Data.DataRowState]::Detached, [System.Data.DataRowState]::Deleted)) {
        $row = ConvertFrom-FslGuiDataRow -Row $selected
    }
    $userName = if ($null -ne $row) { Get-FslGuiPropertyText -InputObject $row -Name 'UserName' } else { '' }
    $sid = if ($null -ne $row) { Get-FslGuiPropertyText -InputObject $row -Name 'SID' } else { '' }
    $dialog['UserName'] = $userName
    $dialog['UserSid'] = $sid

    $controls['TxtResetSelected'].Text = if ($null -eq $row) { 'No container selected.' }
    else {
        'Selected: {0} (SID {1}) - {2} GB, last write {3}, locked {4} - {5}' -f $userName, $sid,
        (Get-FslGuiPropertyText -InputObject $row -Name 'SizeGB'), (Get-FslGuiPropertyText -InputObject $row -Name 'LastWriteTime'),
        (Get-FslGuiPropertyText -InputObject $row -Name 'IsLocked'), (Get-FslGuiPropertyText -InputObject $row -Name 'FullName')
    }
    $controls['TxtResetTypedPrompt'].Text = if ([string]::IsNullOrWhiteSpace($userName)) { 'Type the user name to confirm:' } else { "Type '$userName' to confirm:" }

    $check = Test-FslGuiContainerResetRequest -UserName $userName -ArchivePath ([string]$controls['TxtResetArchivePath'].Text) `
        -ChangeReference ([string]$controls['TxtResetChangeReference'].Text) -TypedUserName ([string]$controls['TxtResetTypedUser'].Text) `
        -SignedOutConfirmed ($controls['ChkResetSignedOut'].IsChecked -eq $true) -IsElevated ([bool]$State['IsElevated'])
    $dialog['Check'] = $check
    $controls['BtnResetStart'].IsEnabled = [bool]$check['IsValid']
    $controls['TxtResetError'].Text = [string]$check['Message']
}

function Invoke-FslGuiContainerResetDialogAction {
    <#
    .SYNOPSIS
        Click handler body of the Office container reset dialog Start button: final confirmation, then close with the intent.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $state = $script:FslGuiState
    if ($null -eq $state -or $null -eq $state['Repair']['ContainerDialog']) { return }
    $dialog = $state['Repair']['ContainerDialog']
    Sync-FslGuiContainerResetDialogState -State $state
    $check = $dialog['Check']
    if (-not [bool]$check['IsValid']) {
        $dialog['Controls']['TxtResetError'].Text = [string]$check['Message']
        return
    }
    $text = "Archive and reset the Office container of {0} on {1}?`r`n`r`nArchive folder: {2}`r`n`r`n{3}" -f `
        [string]$dialog['UserName'], [System.Environment]::MachineName, ([string]$dialog['Controls']['TxtResetArchivePath'].Text).Trim(), (Get-FslGuiContainerWarningText)
    $answer = [string][System.Windows.MessageBox]::Show($dialog['Window'], $text, 'Reset Office Container',
        [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($answer -ne 'Yes') {
        $dialog['Controls']['TxtResetError'].Text = 'Reset cancelled; nothing was changed.'
        return
    }
    $dialog['Intent'] = 'Reset'
    $dialog['Window'].DialogResult = $true
}

function Show-FslGuiContainerResetDialog {
    <#
    .SYNOPSIS
        Shows GUI/ContainerResetDialog.xaml. Returns @{ UserName; UserSid; ArchivePath; ChangeReference } or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $path = Join-Path -Path ([string]$State['ModuleRoot']) -ChildPath 'GUI/ContainerResetDialog.xaml'
    $window = Import-FslGuiXaml -Path $path
    $connected = Connect-FslGuiControl -Root $window -Name (Get-FslGuiContainerResetControlName)
    if ($connected['Missing'].Count -gt 0) {
        throw [System.InvalidOperationException]::new("GUI/ContainerResetDialog.xaml is missing control(s): $($connected['Missing'] -join ', ')")
    }
    $controls = $connected['Controls']
    $repair = $State['Repair']

    $table = Initialize-FslGuiContainerTable
    Sync-FslGuiObjectTable -Table $table -InputObject @($repair['Container'])
    $controls['GridResetContainers'].ItemsSource = $table.DefaultView
    $controls['TxtResetWarning'].Text = Get-FslGuiContainerWarningText
    $controls['TxtResetInfo'].Text = '{0} Office container(s) found at {1}. Select the user whose container must be replaced (FIX-ODFC-02, risk tier 3).' -f `
        $table.Rows.Count, $(if ($null -ne $repair['ContainerAt']) { ([datetime]$repair['ContainerAt']).ToString('HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } else { 'now' })
    $controls['TxtResetArchivePath'].Text = [string]$repair['ArchivePath']
    $controls['TxtResetChangeReference'].Text = [string]$repair['ChangeReference']
    $controls['TxtResetTypedUser'].Text = ''
    $controls['ChkResetSignedOut'].IsChecked = $false
    $controls['TxtResetError'].Text = ''

    $repair['ContainerDialog'] = @{
        Window   = $window
        Controls = $controls
        Table    = $table
        Intent   = 'Cancel'
        UserName = ''
        UserSid  = ''
        Check    = @{ IsValid = $false; Message = '' }
    }
    try {
        $syncHandler = {
            try {
                $current = $script:FslGuiState
                if ($null -ne $current) { Sync-FslGuiContainerResetDialogState -State $current }
            }
            catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Container reset dialog input' }
        }
        $controls['GridResetContainers'].Add_SelectionChanged($syncHandler)
        $controls['TxtResetArchivePath'].Add_TextChanged($syncHandler)
        $controls['TxtResetChangeReference'].Add_TextChanged($syncHandler)
        $controls['TxtResetTypedUser'].Add_TextChanged($syncHandler)
        $controls['ChkResetSignedOut'].Add_Checked($syncHandler)
        $controls['ChkResetSignedOut'].Add_Unchecked($syncHandler)
        $controls['BtnResetStart'].Add_Click({
                try { Invoke-FslGuiContainerResetDialogAction }
                catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Container reset dialog start' }
            })

        Sync-FslGuiContainerResetDialogState -State $State
        $window.Owner = $State['Window']
        $accepted = $window.ShowDialog()
        $intent = [string]$repair['ContainerDialog']['Intent']
        $request = @{
            UserName        = [string]$repair['ContainerDialog']['UserName']
            UserSid         = [string]$repair['ContainerDialog']['UserSid']
            ArchivePath     = ([string]$controls['TxtResetArchivePath'].Text).Trim()
            ChangeReference = ([string]$controls['TxtResetChangeReference'].Text).Trim()
        }
        $repair['ArchivePath'] = [string]$request['ArchivePath']
        $repair['ChangeReference'] = [string]$request['ChangeReference']
    }
    finally {
        $repair['ContainerDialog'] = $null
    }
    if ($accepted -ne $true -or $intent -ne 'Reset') { return $null }
    return $request
}

function Invoke-FslGuiContainerResetDialog {
    <#
    .SYNOPSIS
        Shows the Office container reset dialog and queues the confirmed FIX-ODFC-02 run. Returns a status text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $repair = $State['Repair']
    $repair['ReopenContainer'] = $false
    if (@($repair['Container']).Count -eq 0) {
        return 'No Office container was found at the configured storage locations; there is nothing to reset.'
    }
    $request = Show-FslGuiContainerResetDialog -State $State
    if ($null -eq $request) { return 'Office container reset cancelled; nothing was changed.' }

    $parameters = @{ ArchivePath = [string]$request['ArchivePath'] }
    if (-not [string]::IsNullOrWhiteSpace([string]$request['UserSid'])) { $parameters['UserSid'] = [string]$request['UserSid'] }
    if (-not [string]::IsNullOrWhiteSpace([string]$request['UserName'])) { $parameters['UserName'] = [string]$request['UserName'] }

    $repair['Applying'] = $true
    Suspend-FslGuiAutoRefresh -State $State
    $operation = Get-FslGuiRepairOperation -Kind 'ContainerReset' -ContainerScope ([string]$State['Mode']) -ActionId @('FIX-ODFC-02') `
        -MaxRiskTier 3 -AllowDisruptive $true -UserSignedOutConfirmed $true -ChangeReference ([string]$request['ChangeReference']) -Parameters $parameters
    Invoke-FslGuiWork -State $State -Operation @($operation) -Tab 'TabRepair' -InnerTab 'TabRepairResults'
    return "Archiving and resetting the Office container of $($request['UserName']). The window cannot be closed until the run finishes."
}

function Invoke-FslGuiContainerResetAction {
    <#
    .SYNOPSIS
        Repair > Reset Office Container...: queues Get-FslContainer -Scope ODFC; the dialog opens with the list.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    if (-not [bool]$State['IsElevated']) {
        [void](Show-FslGuiMessage -State $State -Text (Get-FslGuiRepairMenuTooltip -IsElevated $false -Account (Get-FslGuiCurrentAccountText)) `
                -Caption 'Reset Office Container' -Icon 'Warning')
        return 'Repairs need an elevated session.'
    }
    $repair = $State['Repair']
    if ([string]::IsNullOrWhiteSpace([string]$repair['ArchivePath'])) {
        try {
            $config = Get-FslConfig -Section 'Repair'
            if ($config -is [hashtable] -and $config.ContainsKey('ContainerArchivePath')) { $repair['ArchivePath'] = [string]$config['ContainerArchivePath'] }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Read Repair.ContainerArchivePath'
        }
    }
    $repair['ReopenContainer'] = $true
    Invoke-FslGuiWork -State $State -Operation @(Get-FslGuiRepairOperation -Kind 'ContainerList' -ContainerScope 'ODFC') `
        -Tab 'TabRepair' -InnerTab 'TabRepairResults'
    return 'Reading the Office containers (read-only)...'
}
