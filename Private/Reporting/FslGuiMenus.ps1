# Private helpers for Show-FslDashboard: event wiring, menu/button action dispatch, timers, container mode switching.
# Every WPF handler script block is created inside a function of this module (so it is bound to the module session
# state), reaches the dashboard through $script:FslGuiState, never uses GetNewClosure(), and wraps its body in
# try/catch -> Write-FslGuiHandlerError (Add-FslError + status bar), because an unhandled exception inside a WPF
# event handler can terminate the host.
# Sources:
#   https://learn.microsoft.com/dotnet/api/system.management.automation.scriptblock.getnewclosure
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_scopes
#   https://learn.microsoft.com/dotnet/desktop/wpf/controls/menu (MenuItem Header access keys, IsCheckable, Click)
#   https://learn.microsoft.com/dotnet/api/system.windows.threading.dispatchertimer (Tick runs on the UI thread)
#   https://learn.microsoft.com/dotnet/api/system.windows.controls.primitives.selector.selectionchanged (bubbling)

function Get-FslGuiActionName {
    <#
    .SYNOPSIS
        Maps an event source (MenuItem or Button) to its action name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Source
    )

    if ($null -eq $Source) { return '' }
    $name = [string]$Source.Name
    $map = Get-FslGuiButtonActionMap
    if ($map.ContainsKey($name)) { return [string]$map[$name] }
    return $name
}

function Save-FslGuiPreference {
    <#
    .SYNOPSIS
        Persists a dashboard preference with Set-FslPreference (CONTRACT P2.4). Returns $true when saved.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ContainerMode', 'AutoDiscoverOnStartup', 'AutoRunHealthCheckOnStartup', 'AutoRefreshMinutes', 'Offline', 'RunAsUserName')]
        [string] $Name,

        [Parameter(Mandatory)]
        [object] $Value
    )

    $command = Get-Command -Name 'Set-FslPreference' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        Write-FslLog -Message "Set-FslPreference is not available; preference '$Name' was not saved." -Level Warning -Component 'GUI'
        return $false
    }
    $splat = @{ Name = $Name; Value = $Value; ErrorAction = 'Stop' }
    if ($command.Parameters.ContainsKey('Confirm')) { $splat['Confirm'] = $false }
    try {
        $null = & $command @splat
        Write-FslLog -Message "Dashboard preference saved: $Name = $Value" -Level Info -Component 'GUI'
        return $true
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context "Save preference $Name"
        return $false
    }
}

function Invoke-FslGuiWork {
    <#
    .SYNOPSIS
        Queues background operations, optionally navigates to a tab, starts the poll timer and refreshes the busy view.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]] $Operation,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Tab,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $InnerTab
    )

    if ($Operation.Count -eq 0) { return }
    Add-FslGuiOperation -State $State -Operation $Operation
    Select-FslGuiTab -State $State -Tab $Tab -InnerTab $InnerTab
    $pollTimer = $State['Timers']['Poll']
    if ($null -ne $pollTimer -and -not $pollTimer.IsEnabled) { $pollTimer.Start() }
    Invoke-FslGuiTimerTick
}

function Sync-FslGuiAfterOperation {
    <#
    .SYNOPSIS
        Refreshes the views named by Complete-FslGuiOperation and shows the outcome (status bar, dialogs for schedule changes).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [hashtable] $Envelope,

        [Parameter(Mandatory)]
        [hashtable] $Outcome
    )

    $refresh = @($Outcome['Refresh'])
    if ('Discovery' -in $refresh) { Sync-FslGuiDiscoveryPanel -State $State }
    if ('Daily' -in $refresh) { Sync-FslGuiDailyView -State $State }
    if ('Repair' -in $refresh) { Sync-FslGuiRepairView -State $State }
    if ('Errors' -in $refresh) { Sync-FslGuiErrorView -State $State }
    if ($refresh.Count -gt 0) { Sync-FslGuiBanner -State $State }
    Sync-FslGuiFilter -State $State
    Write-FslGuiStatus -State $State -Text ([string]$Outcome['StatusText'])

    $name = ''
    if ($null -ne $Envelope['Operation']) { $name = [string]$Envelope['Operation']['Name'] }
    if ($name -in @('DailyRegister', 'DailyUnregister') -and $Envelope['Status'] -ne 'Cancelled') {
        $summary = Get-FslGuiDailyOutputText -Output @($Outcome['Output'])
        $caption = if ($name -eq 'DailyRegister') { 'Schedule Daily Health Check' } else { 'Remove Daily Schedule' }
        $icon = if ($summary['NeedsAttention'] -or $Envelope['Status'] -eq 'Failed') { 'Warning' } else { 'Information' }
        [void](Show-FslGuiMessage -State $State -Text ([string]$summary['Text']) -Caption $caption -Icon $icon)
    }

    # Repair (CONTRACT P3.7): the auto-refresh timer is released, the outcome of a run that changed something is
    # shown, and the dialog the operator was working in is reopened with the fresh plan / preview / result.
    if ($name -in @('RepairApply', 'RepairUndo', 'ContainerReset')) {
        Resume-FslGuiAutoRefresh -State $State
    }
    if ($name -in @('RepairUndo', 'ContainerReset') -and $Envelope['Status'] -ne 'Cancelled') {
        $repairSummary = @($Outcome['Output'])
        if ($repairSummary.Count -gt 0 -and $repairSummary[0] -is [hashtable]) {
            $caption = if ($name -eq 'RepairUndo') { 'Undo a Repair Run' } else { 'Reset Office Container' }
            $icon = if ([bool]$repairSummary[0]['NeedsAttention'] -or $Envelope['Status'] -eq 'Failed') { 'Warning' } else { 'Information' }
            [void](Show-FslGuiMessage -State $State -Text ([string]$repairSummary[0]['Text']) -Caption $caption -Icon $icon)
        }
    }
    $dialog = if ($Outcome.ContainsKey('Dialog')) { [string]$Outcome['Dialog'] } else { '' }
    if (-not [string]::IsNullOrEmpty($dialog) -and -not [bool]$State['Closing']) {
        $status = switch ($dialog) {
            'Repair' { Invoke-FslGuiRepairDialog -State $State }
            'ContainerReset' { Invoke-FslGuiContainerResetDialog -State $State }
            default { '' }
        }
        if (-not [string]::IsNullOrEmpty($status)) { Write-FslGuiStatus -State $State -Text $status }
    }
}

function Invoke-FslGuiTimerTick {
    <#
    .SYNOPSIS
        Poll timer body: advances the runner, applies finished operations, stops the timer when idle. Not re-entrant.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $state = $script:FslGuiState
    if ($null -eq $state -or $state['Closing'] -or $state['InTick']) { return }
    $state['InTick'] = $true
    try {
        for ($step = 0; $step -lt 25; $step++) {
            $envelope = Step-FslGuiRunner -State $state
            if ($null -eq $envelope) { break }
            $outcome = Complete-FslGuiOperation -State $state -Envelope $envelope
            Sync-FslGuiAfterOperation -State $state -Envelope $envelope -Outcome $outcome
            if ($state['Closing']) { return }
        }
        if (-not (Test-FslGuiBusy -State $state) -and $null -ne $state['Timers']['Poll']) { $state['Timers']['Poll'].Stop() }
        Sync-FslGuiBusyView -State $state
    }
    finally {
        $state['InTick'] = $false
    }
}

function Suspend-FslGuiOperationPump {
    <#
    .SYNOPSIS
        Blocks Invoke-FslGuiTimerTick for the duration of a modal window and returns the previous flag value.
    .DESCRIPTION
        MessageBox.Show and Window.ShowDialog run a nested dispatcher loop, so the poll DispatcherTimer keeps
        ticking while they are up. Without this, a background operation can finish inside that loop and
        Sync-FslGuiAfterOperation can open a second modal window on top of the first - or call ShowDialog while the
        dashboard is closing, which raises InvalidOperationException
        (https://learn.microsoft.com/dotnet/api/system.windows.window.closing). The tick already refuses to run
        re-entrantly, so raising the same flag around a modal window is enough. Always paired with
        Resume-FslGuiOperationPump in a finally block.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $previous = [bool]$State['InTick']
    $State['InTick'] = $true
    return $previous
}

function Resume-FslGuiOperationPump {
    <#
    .SYNOPSIS
        Restores the value Suspend-FslGuiOperationPump returned once the modal window is closed.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [bool] $Previous
    )

    $State['InTick'] = $Previous
}

function Sync-FslGuiAutoRefresh {
    <#
    .SYNOPSIS
        Starts (AutoRefreshMinutes > 0) or stops the auto refresh DispatcherTimer.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $timer = $State['Timers']['Refresh']
    if ($null -eq $timer) { return }
    $timer.Stop()
    $minutes = [int]$State['AutoRefreshMinutes']
    if ($minutes -gt 0) {
        $timer.Interval = [timespan]::FromMinutes($minutes)
        $timer.Start()
    }
}

function Suspend-FslGuiAutoRefresh {
    <#
    .SYNOPSIS
        Stops the auto refresh timer while a repair is applied (CONTRACT P3.7): no check may start during a change.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $timer = $State['Timers']['Refresh']
    if ($null -ne $timer -and $timer.IsEnabled) {
        $timer.Stop()
        Write-FslLog -Message 'Auto refresh suspended while a repair run is in progress.' -Level Verbose -Component 'GUI'
    }
}

function Resume-FslGuiAutoRefresh {
    <#
    .SYNOPSIS
        Restarts the auto refresh timer after a repair run (no-op when AutoRefreshMinutes is 0 or a repair still runs).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    if (Test-FslGuiRepairInProgress -State $State) { return }
    Sync-FslGuiAutoRefresh -State $State
}

function Invoke-FslGuiAutoRefreshTick {
    <#
    .SYNOPSIS
        Auto refresh timer body: queues a health check for the current mode unless work is already running.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $state = $script:FslGuiState
    if ($null -eq $state -or $state['Closing']) { return }
    if (Test-FslGuiRepairInProgress -State $state) {
        Write-FslGuiStatus -State $state -Text 'Auto refresh skipped: a repair run is in progress.'
        return
    }
    if (Test-FslGuiBusy -State $state) {
        Write-FslGuiStatus -State $state -Text 'Auto refresh skipped: checks are already running.'
        return
    }
    $operation = Get-FslGuiHealthCheckOperation -Category (Get-FslGuiHealthCategory) -ContainerScope $state['Mode'] -Offline ([bool]$state['Offline']) -Display "Auto refresh health check ($($state['Mode']))"
    Invoke-FslGuiWork -State $state -Operation @($operation)
}

function Invoke-FslGuiStartup {
    <#
    .SYNOPSIS
        Window Loaded body: queues the automatic startup operations and starts auto refresh.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $state = $script:FslGuiState
    if ($null -eq $state) { return }
    $operations = @(Get-FslGuiStartupOperation -Mode $state['Mode'] -AutoDiscover ([bool]$state['AutoDiscover']) -AutoHealthCheck ([bool]$state['AutoHealthCheck']) -NoAutoRun ([bool]$state['NoAutoRun']) -Offline ([bool]$state['Offline']))
    $names = @($operations | ForEach-Object -Process { $_['Display'] }) -join ', '
    Write-FslGuiStatus -State $state -Text "Starting: $names"
    Invoke-FslGuiWork -State $state -Operation $operations
    Sync-FslGuiAutoRefresh -State $state
}

function Close-FslGuiDashboardState {
    <#
    .SYNOPSIS
        Window Closing body (also used by Show-FslDashboard finally): stops timers and disposes the background runner.
    .DESCRIPTION
        While a repair run is applying a change the window must not close: the background runspace would be disposed
        between the rollback entry and the change, or between the change and its verification (CONTRACT P3.7). With a
        -CancelEvent (System.ComponentModel.CancelEventArgs) the close is then cancelled and the operator is told why.
    .PARAMETER CancelEvent
        The CancelEventArgs of the Window.Closing event. Omitted when the dashboard tears itself down.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.ComponentModel.CancelEventArgs] $CancelEvent
    )

    $state = $script:FslGuiState
    if ($null -eq $state) { return }
    if ($null -ne $CancelEvent -and -not $state['Closing'] -and (Test-FslGuiRepairInProgress -State $state)) {
        $CancelEvent.Cancel = $true
        $text = "A repair run is in progress on $([System.Environment]::MachineName).`r`n`r`nThe window stays open until the run finishes so the change and its rollback record are written completely. Cancel stops the run after the current action."
        Write-FslLog -Message 'Dashboard close refused: a repair run is in progress.' -Level Warning -Component 'GUI'
        # The message box runs a nested dispatcher loop: the poll timer must not finish an operation (and open
        # another window with ShowDialog) while this window is closing.
        $pump = Suspend-FslGuiOperationPump -State $state
        try { [void](Show-FslGuiMessage -State $state -Text $text -Caption 'Repair in Progress' -Icon 'Warning') }
        finally { Resume-FslGuiOperationPump -State $state -Previous $pump }
        return
    }
    $state['Closing'] = $true
    foreach ($key in @('Poll', 'Refresh')) {
        $timer = $state['Timers'][$key]
        if ($null -ne $timer) {
            try { $timer.Stop() } catch { Add-FslError -ErrorRecord $_ -Component 'GUI' -Context "Stop $key timer" }
        }
    }
    Close-FslGuiRunner -State $state
    Write-FslLog -Message 'Dashboard closing: timers stopped and background runspace disposed.' -Level Verbose -Component 'GUI'
}

function Switch-FslGuiContainerMode {
    <#
    .SYNOPSIS
        Changes the container mode: persists it (Set-FslPreference), updates menus/tabs and offers to run the checks of a
        newly included scope.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $Mode
    )

    $previous = [string]$State['Mode']
    if ($Mode -eq $previous) {
        Sync-FslGuiModeView -State $State
        return "Container mode is already $((Get-FslGuiModeText -Mode $Mode)['Badge'])."
    }
    $saved = Save-FslGuiPreference -Name 'ContainerMode' -Value $Mode
    $State['Mode'] = $Mode
    Sync-FslGuiModeView -State $State
    Sync-FslGuiBanner -State $State
    Sync-FslGuiActiveView -State $State
    $badge = (Get-FslGuiModeText -Mode $Mode)['Badge']
    $status = if ($saved) { "Container mode: $badge (saved to preferences)." } else { "Container mode: $badge (not saved - see Errors & Log)." }

    $previousScopes = Get-FslGuiScopeList -Mode $previous
    # Get-FslGuiScopeList returns its array as ONE pipeline object (unary comma): enumerate it with foreach, not a pipeline.
    $added = @(foreach ($scopeName in (Get-FslGuiScopeList -Mode $Mode)) { if ($scopeName -notin $previousScopes) { $scopeName } })
    if ($added.Count -gt 0) {
        $labels = @($added | ForEach-Object -Process { if ($_ -eq 'ODFC') { 'Office container' } else { 'Profile container' } }) -join ' and '
        $answer = Show-FslGuiMessage -State $State -Text "Container mode is now '$badge'.`r`n`r`nRun the $labels checks now?" -Caption 'Container Mode' -Button 'YesNo' -Icon 'Information'
        if ($answer -eq 'Yes') {
            $operations = foreach ($scope in $added) {
                $label = if ($scope -eq 'ODFC') { 'Office' } else { 'Profile' }
                Get-FslGuiHealthCheckOperation -Category (Get-FslGuiCheckCategory) -ContainerScope $scope -Offline ([bool]$State['Offline']) -Display "All $label container checks"
            }
            $tab = if ($added[0] -eq 'ODFC') { 'TabOffice' } else { 'TabProfiles' }
            Invoke-FslGuiWork -State $State -Operation @($operations) -Tab $tab
        }
    }
    return $status
}

function Invoke-FslGuiDebugToggle {
    <#
    .SYNOPSIS
        Tools > Debug Logging: re-initializes the dashboard session with or without -EnableDebugLogging (same LogRoot and
        ReportRoot) and queues the same change for the background session.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $enable = -not [bool]$State['DebugLogging']
    $init = @{ Force = $true }
    if (-not [string]::IsNullOrWhiteSpace([string]$State['LogRoot'])) { $init['LogRoot'] = [string]$State['LogRoot'] }
    if (-not [string]::IsNullOrWhiteSpace([string]$State['ReportRoot'])) { $init['ReportRoot'] = [string]$State['ReportRoot'] }
    if ($enable) { $init['EnableDebugLogging'] = $true }
    $info = Initialize-FslSession @init
    $State['DebugLogging'] = ((Get-FslGuiPropertyText -InputObject $info -Name 'DebugLogging') -eq 'True')
    $State['LogRoot'] = [string]$script:FslSession['LogRoot']
    if ($null -ne $State['Runner']['Runspace']) {
        $operation = Get-FslGuiOperation -Name 'Debug' -Display 'Background debug logging' -Parameter @{
            LogRoot      = [string]$State['LogRoot']
            ReportRoot   = [string]$State['ReportRoot']
            DebugLogging = [bool]$State['DebugLogging']
        }
        Invoke-FslGuiWork -State $State -Operation @($operation)
    }
    Sync-FslGuiErrorView -State $State
    if ($enable -and -not $State['DebugLogging']) { return 'Debug logging could not be enabled. See Errors & Log.' }
    if (-not $enable -and $State['DebugLogging']) { return 'Debug logging stays on because Logging.DebugLogging is enabled in Config/Settings.psd1.' }
    $word = if ($State['DebugLogging']) { 'enabled' } else { 'disabled' }
    return "Debug logging $word (new log file started)."
}

function Test-FslGuiHasResult {
    <#
    .SYNOPSIS
        Returns $true when the result table contains at least one row of the category.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Category
    )

    foreach ($row in $State['Tables']['Results'].Rows) {
        if ([string]$row['Category'] -eq $Category) { return $true }
    }
    return $false
}

function Invoke-FslGuiAction {
    <#
    .SYNOPSIS
        Dispatches a menu item or button action (see Get-FslGuiActionDefinition).
    .DESCRIPTION
        Work actions are refused while busy; actions that require a container scope are refused when the mode does not
        include that scope (so no Profiles-scope work runs in ODFC mode even if a disabled control were invoked).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Name
    )

    $state = $script:FslGuiState
    if ($null -eq $state -or [string]::IsNullOrEmpty($Name)) { return }
    $definition = Get-FslGuiActionDefinition -Name $Name -Mode $state['Mode'] -Offline ([bool]$state['Offline'])

    if ($definition['Kind'] -eq 'Work' -and (Test-FslGuiBusy -State $state)) {
        Write-FslGuiStatus -State $state -Text 'Please wait: checks are running (use Cancel to stop them).'
        return
    }
    if ($null -ne $definition['RequiresScope'] -and $definition['RequiresScope'] -notin (Get-FslGuiScopeList -Mode $state['Mode'])) {
        $modeText = Get-FslGuiModeText -Mode $state['Mode']
        $message = if ($definition['RequiresScope'] -eq 'Profiles') { $modeText['ProfilesOff'] } else { $modeText['OfficeOff'] }
        Write-FslGuiStatus -State $state -Text $message
        Select-FslGuiTab -State $state -Tab $definition['Tab']
        return
    }
    if (@($definition['Operations']).Count -gt 0) {
        Write-FslGuiStatus -State $state -Text "Queued: $((@($definition['Operations']) | ForEach-Object -Process { $_['Display'] }) -join ', ')"
        Invoke-FslGuiWork -State $state -Operation @($definition['Operations']) -Tab $definition['Tab'] -InnerTab $definition['InnerTab']
        return
    }

    $status = $null
    switch ($Name) {
        'MnuExportViewCsv' { $status = Export-FslGuiReport -State $state -Format 'Csv' -CurrentView }
        'MnuExportViewHtml' { $status = Export-FslGuiReport -State $state -Format 'Html' -CurrentView }
        'MnuExportAllCsv' { $status = Export-FslGuiReport -State $state -Format 'Csv' }
        'MnuExportAllHtml' { $status = Export-FslGuiReport -State $state -Format 'Html' }
        'MnuOpenReports' { $status = Open-FslGuiFolder -Path ([string]$state['ReportRoot']) -Label 'Reports folder' }
        'MnuOpenLogs' { $status = Open-FslGuiFolder -Path ([string]$state['LogRoot']) -Label 'Logs folder' }
        'MnuExit' { $state['Window'].Close() }
        { $_ -in @('MnuDiscImage', 'MnuDiscFslogix', 'MnuDiscOffice', 'MnuDiscRegistry', 'MnuDiscGpo', 'MnuDiscStorage') } {
            Select-FslGuiTab -State $state -Tab $definition['Tab'] -InnerTab $definition['InnerTab']
            if (-not (Test-FslGuiHasResult -State $state -Category 'Discovery') -and -not (Test-FslGuiBusy -State $state)) {
                $discovery = Get-FslGuiActionDefinition -Name 'MnuDiscRun' -Mode $state['Mode'] -Offline ([bool]$state['Offline'])
                Invoke-FslGuiWork -State $state -Operation @($discovery['Operations'])
                $status = 'No discovery data yet: running discovery.'
            }
        }
        'MnuDailySchedule' { $status = Invoke-FslGuiScheduleAction -State $state }
        'MnuDailyRemove' { $status = Invoke-FslGuiRemoveScheduleAction -State $state }
        'MnuDailyOpenFolder' { $status = Open-FslGuiFolder -Path (Get-FslGuiDailyFolder -State $state) -Label 'Daily reports folder' }
        'MnuRepairPlan' { $status = Invoke-FslGuiRepairPlanAction -State $state }
        'MnuRepairContainer' { $status = Invoke-FslGuiContainerResetAction -State $state }
        'MnuRepairUndo' { $status = Invoke-FslGuiRepairUndoAction -State $state }
        'MnuRepairHistory' { $status = Invoke-FslGuiRepairHistoryAction -State $state }
        'MnuRepairOpenLogs' { $status = Open-FslGuiFolder -Path (Get-FslGuiRepairFolder -State $state) -Label 'Repair logs folder' }
        'MnuRelaunchElevated' { $status = Invoke-FslGuiRelaunchAction -State $state -Mode 'Elevate' }
        'MnuRelaunchUser' { $status = Invoke-FslGuiRelaunchAction -State $state -Mode 'DifferentUser' }
        'MnuToolsErrorLog' {
            Select-FslGuiTab -State $state -Tab 'TabErrors'
            Sync-FslGuiErrorView -State $state
            $status = 'Error log refreshed (dashboard session).'
            if ($null -ne $state['Runner']['Runspace'] -and -not (Test-FslGuiBusy -State $state)) {
                Invoke-FslGuiWork -State $state -Operation @(Get-FslGuiOperation -Name 'ErrorLog' -Display 'Background error log')
                $status = 'Refreshing the error log from the dashboard and background sessions...'
            }
        }
        'MnuToolsDebug' { $status = Invoke-FslGuiDebugToggle -State $state }
        'MnuToolsOffline' {
            $state['Offline'] = -not [bool]$state['Offline']
            $saved = Save-FslGuiPreference -Name 'Offline' -Value ([bool]$state['Offline'])
            $status = 'Offline mode {0}{1}.' -f $(if ($state['Offline']) { 'on' } else { 'off' }), $(if ($saved) { ' (saved)' } else { ' (not saved)' })
            Sync-FslGuiBanner -State $state
        }
        'MnuModeOdfc' { $status = Switch-FslGuiContainerMode -State $state -Mode 'ODFC' }
        'MnuModeProfiles' { $status = Switch-FslGuiContainerMode -State $state -Mode 'Profiles' }
        'MnuModeBoth' { $status = Switch-FslGuiContainerMode -State $state -Mode 'Both' }
        'MnuProfEnable' {
            if ($state['Mode'] -ne 'ODFC') {
                $status = 'Profile container checks are already enabled.'
            }
            else {
                $text = "Profile container checks are off because the toolkit is in 'Office Containers only' mode (the default for this computer).`r`n`r`nSwitch the container mode to Both (Office and Profile containers)? The choice is saved to your toolkit preferences."
                $answer = Show-FslGuiMessage -State $state -Text $text -Caption 'Enable Profile Container Checks' -Button 'OKCancel' -Icon 'Information'
                $status = if ($answer -eq 'OK') { Switch-FslGuiContainerMode -State $state -Mode 'Both' } else { 'Container mode unchanged.' }
            }
        }
        'MnuOptDiscoverStartup' {
            $state['AutoDiscover'] = -not [bool]$state['AutoDiscover']
            $saved = Save-FslGuiPreference -Name 'AutoDiscoverOnStartup' -Value ([bool]$state['AutoDiscover'])
            $status = 'Run Discovery at Startup: {0}{1}.' -f $(if ($state['AutoDiscover']) { 'on' } else { 'off' }), $(if ($saved) { ' (saved)' } else { ' (not saved)' })
        }
        'MnuOptHealthStartup' {
            $state['AutoHealthCheck'] = -not [bool]$state['AutoHealthCheck']
            $saved = Save-FslGuiPreference -Name 'AutoRunHealthCheckOnStartup' -Value ([bool]$state['AutoHealthCheck'])
            $status = 'Run Health Check at Startup: {0}{1}.' -f $(if ($state['AutoHealthCheck']) { 'on' } else { 'off' }), $(if ($saved) { ' (saved)' } else { ' (not saved)' })
        }
        { $_ -in @('MnuRefreshOff', 'MnuRefresh15', 'MnuRefresh30', 'MnuRefresh60') } {
            $minutes = switch ($Name) { 'MnuRefresh15' { 15 } 'MnuRefresh30' { 30 } 'MnuRefresh60' { 60 } default { 0 } }
            $state['AutoRefreshMinutes'] = $minutes
            $saved = Save-FslGuiPreference -Name 'AutoRefreshMinutes' -Value $minutes
            Sync-FslGuiAutoRefresh -State $state
            $status = 'Auto refresh: {0}{1}.' -f $(if ($minutes -gt 0) { "every $minutes min" } else { 'off' }), $(if ($saved) { ' (saved)' } else { ' (not saved)' })
        }
        'MnuHelpAbout' { [void](Show-FslGuiMessage -State $state -Text (Get-FslGuiAboutText -Mode $state['Mode']) -Caption 'About FSLogixToolkit') }
        'MnuHelpUsage' { [void](Show-FslGuiMessage -State $state -Text (Get-FslGuiUsageText) -Caption 'Command-line Usage') }
        'ActCancel' {
            $status = Request-FslGuiCancel -State $state
            # Cancel clears the queue: a repair run that was still waiting there never starts, so the close and
            # auto-refresh block it reserved has to be released (Clear-FslGuiOperationQueue lowers the flag).
            Resume-FslGuiAutoRefresh -State $state
            Sync-FslGuiBusyView -State $state
        }
        'ActClearFilter' {
            $state['Controls']['CmbStatusFilter'].SelectedIndex = 0
            $state['Controls']['TxtSearch'].Text = ''
            Sync-FslGuiFilter -State $state
            $status = 'Filter cleared.'
        }
        'ActOpenSource' { $status = Open-FslGuiSource -State $state }
        default { $status = "Action '$Name' is not available." }
    }
    if ($null -ne $script:FslGuiState -and -not $state['Closing']) {
        Sync-FslGuiMenuState -State $state
        if (-not [string]::IsNullOrEmpty($status)) { Write-FslGuiStatus -State $state -Text $status }
    }
}

function Register-FslGuiEventHandler {
    <#
    .SYNOPSIS
        Attaches all WPF event handlers (menus, buttons, grids, tabs, filter bar, window, timers) and creates the timers.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $controls = $State['Controls']

    $clickHandler = {
        try { Invoke-FslGuiAction -Name (Get-FslGuiActionName -Source $args[0]) }
        catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Menu or button' }
    }
    foreach ($name in (Get-FslGuiMenuItemName)) { $controls[$name].Add_Click($clickHandler) }
    foreach ($name in (Get-FslGuiButtonActionMap).Keys) { $controls[[string]$name].Add_Click($clickHandler) }

    $gridSelectionHandler = {
        try {
            $state = $script:FslGuiState
            if ($null -eq $state) { return }
            $key = Get-FslGuiActiveViewKey -State $state
            if ($null -ne $key -and [string]$state['Views'][$key]['Definition']['Grid'] -eq [string]$args[0].Name) {
                Sync-FslGuiDetail -State $state -Grid $args[0]
            }
        }
        catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Grid selection' }
    }
    foreach ($key in $State['Views'].Keys) {
        $definition = $State['Views'][$key]['Definition']
        $grid = $controls[[string]$definition['Grid']]
        $grid.ItemsSource = $State['Views'][$key]['View']
        $grid.Add_SelectionChanged($gridSelectionHandler)
    }
    $controls['GridSummary'].ItemsSource = $State['Tables']['Summary'].DefaultView

    $tabHandler = {
        try {
            # SelectionChanged bubbles from inner selectors (grids, inner tabs): react only to this TabControl's own change.
            if (-not [object]::ReferenceEquals($args[1].OriginalSource, $args[0])) { return }
            $state = $script:FslGuiState
            if ($null -eq $state) { return }
            Sync-FslGuiActiveView -State $state
            if ([string]$args[0].Name -eq 'TabMain' -and $null -ne $args[0].SelectedItem -and [string]$args[0].SelectedItem.Name -eq 'TabErrors') {
                Sync-FslGuiErrorView -State $state
            }
        }
        catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Tab change' }
    }
    $controls['TabMain'].Add_SelectionChanged($tabHandler)
    $tabMap = Get-FslGuiTabMap
    foreach ($tab in $tabMap.Keys) {
        if ($null -ne $tabMap[$tab]) { $controls[[string]$tabMap[$tab]].Add_SelectionChanged($tabHandler) }
    }

    $filterHandler = {
        try {
            $state = $script:FslGuiState
            if ($null -ne $state) { Sync-FslGuiFilter -State $state }
        }
        catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Filter' }
    }
    $controls['CmbStatusFilter'].Add_SelectionChanged($filterHandler)
    $controls['TxtSearch'].Add_TextChanged($filterHandler)

    $controls['GridDailyHistory'].Add_MouseDoubleClick({
            try {
                $state = $script:FslGuiState
                if ($null -ne $state) { Write-FslGuiStatus -State $state -Text (Open-FslGuiDailyReport -State $state) }
            }
            catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Open daily report' }
        })

    $controls['GridRepairHistory'].Add_SelectionChanged({
            try {
                $state = $script:FslGuiState
                if ($null -ne $state) { Sync-FslGuiRepairView -State $state }
            }
            catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Repair run selection' }
        })

    $State['Window'].Add_Loaded({
            try { Invoke-FslGuiStartup }
            catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Startup checks' }
        })
    # CancelEventArgs.Cancel = $true keeps the window open while a repair is applied
    # (https://learn.microsoft.com/dotnet/api/system.windows.window.closing).
    $State['Window'].Add_Closing({
            try { Close-FslGuiDashboardState -CancelEvent $args[1] }
            catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Close dashboard' }
        })

    $poll = [System.Windows.Threading.DispatcherTimer]::new()
    $poll.Interval = [timespan]::FromMilliseconds(400)
    $poll.Add_Tick({
            try { Invoke-FslGuiTimerTick }
            catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Background poll' }
        })
    $State['Timers']['Poll'] = $poll

    $refresh = [System.Windows.Threading.DispatcherTimer]::new()
    $refresh.Add_Tick({
            try { Invoke-FslGuiAutoRefreshTick }
            catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Auto refresh' }
        })
    $State['Timers']['Refresh'] = $refresh
}
