function Show-FslDashboard {
    <#
    .SYNOPSIS
        Opens the read-only, menu-driven FSLogixToolkit WPF dashboard (Windows only). Office Containers (ODFC) mode by default.

    .DESCRIPTION
        Loads GUI/MainWindow.xaml (System.Windows.Markup.XamlReader via XmlNodeReader) and shows:
          - Menu bar: File (export current view / all results to CSV or HTML, diagnostic bundle, open reports/logs
            folders, relaunch elevated or as a different user with a smart card, exit), Discovery, Office Containers,
            Profile Containers, Health Check (full check, Daily submenu), Repair (repair plan preview, Office container
            reset, undo a repair run, repair history, open repair logs folder), Tools (prerequisites, environment and
            versions, error log, debug logging, offline mode), Options (container mode, startup discovery / health
            check, auto refresh) and Help.
          - Header banner (computer, OS and version name, FSLogix version, Microsoft 365 Apps, elevation, the account
            this window runs as, container-mode badge, last check time, daily schedule state) and tabs: Overview,
            Discovery, Office Containers, Profile Containers, Environment & Policy, Daily Health, Repair,
            Errors & Log; filter bar (status + search), details panel and a status bar with a progress indicator and
            Cancel.
          - Repairs (CONTRACT P3.7): the Repair menu needs an elevated session - only Repair History and Open Repair
            Logs Folder stay enabled for a standard user, and the menu tooltip points at File > Relaunch... The repair
            dialog (GUI/RepairDialog.xaml) shows Get-FslRepairPlan with a checkbox per action, a detail pane and a
            change reference box; Preview runs Invoke-FslRepair -WhatIf and Apply becomes available only after a
            preview of the IDENTICAL selection that reported applicable actions (no drift), after a confirmation
            dialog, and for risk tier 3 only after the computer name is typed. The Office container reset dialog
            (GUI/ContainerResetDialog.xaml) lists Get-FslContainer -Scope ODFC and needs the archive folder, the
            signed-out attestation, a change reference and the typed user name before it runs
            Invoke-FslRepair -ActionId FIX-ODFC-02. While a repair is applied the auto refresh is suspended, the window
            refuses to close and Cancel lets the run finish its current action instead of stopping the pipeline.
        Container mode: -ContainerScope, otherwise Get-FslContainerMode (preference file, Settings.psd1, default ODFC).
        In ODFC mode the Profile Containers items are disabled (except 'Enable Profile Container Checks...') and the
        Profile tab shows 'Profile container checks are off (Office containers only)'; no Profiles-scope work is started.
        Changing Options > Container Mode is saved with Set-FslPreference and offers to run the checks of a newly
        included scope.
        Automatic checks when the window is loaded: daily schedule state, then Discovery (Get-FslDiscovery +
        Get-FslDiscoveryReport) when the AutoDiscoverOnStartup preference is on, then Invoke-FslHealthCheck
        -ContainerScope <mode> when AutoRunHealthCheckOnStartup is on and -NoAutoRun is not set. AutoRefreshMinutes > 0
        re-runs the health check periodically.
        All checks run one at a time in ONE persistent background runspace that imports the module manifest and calls
        Initialize-FslSession with the same LogRoot/ReportRoot; a DispatcherTimer polls for completion on the UI thread,
        so the window stays responsive. Results of a run replace earlier rows with the same Category and Scope. Office and
        Profile tabs show results of their scope plus General results of the same category. No maintenance actions.
        On non-Windows a Skipped Result is returned; when the thread is not STA, or the XAML cannot be loaded or lacks a
        named control, an Error Result is returned (listing all missing control names).

    .PARAMETER ContainerScope
        Container mode for this dashboard session: ODFC (Office containers), Profiles or Both. Not saved; use
        Options > Container Mode to change and save the preference.

    .PARAMETER NoAutoRun
        Do not run the health check automatically when the window opens (discovery still follows the
        AutoDiscoverOnStartup preference).

    .EXAMPLE
        Show-FslDashboard

        Opens the dashboard in the saved container mode (Office Containers only by default).

    .EXAMPLE
        Show-FslDashboard -ContainerScope Both -NoAutoRun

        Opens the dashboard with Office and Profile container sections enabled, without the automatic health check.

    .OUTPUTS
        FSLogixToolkit.Result (only when the dashboard cannot be shown)

    .NOTES
        RequiresElevation: No for checks (they return Skipped results) - YES for every item of the Repair menu except
        Repair History and Open Repair Logs Folder; scheduling the daily task as System also needs elevation.
        WPF requires an STA thread; pwsh on Windows starts in STA by default (about_Pwsh -STA / -MTA).
        Event handlers are script blocks created inside this module (bound to its session state) that reach the GUI
        state through a module-scoped variable; ScriptBlock.GetNewClosure() is not used because it binds the script block
        to a new dynamic module.
        Sources:
          https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_pwsh
          https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_scopes
          https://learn.microsoft.com/dotnet/api/system.management.automation.scriptblock.getnewclosure
          https://learn.microsoft.com/dotnet/api/system.windows.markup.xamlreader.load
          https://learn.microsoft.com/dotnet/api/system.windows.frameworkelement.findname
          https://learn.microsoft.com/dotnet/api/system.windows.threading.dispatchertimer
          https://learn.microsoft.com/dotnet/desktop/wpf/controls/menu
          https://learn.microsoft.com/dotnet/api/system.windows.controls.primitives.selector.selectionchanged
          https://learn.microsoft.com/dotnet/api/system.windows.messagebox.show
          https://learn.microsoft.com/dotnet/api/microsoft.win32.commondialog.showdialog
          https://learn.microsoft.com/dotnet/api/system.windows.window.dialogresult
          https://learn.microsoft.com/dotnet/api/system.data.dataview
          https://learn.microsoft.com/dotnet/api/system.data.datacolumn.expression
          https://learn.microsoft.com/dotnet/api/system.management.automation.runspaces.runspacefactory.createrunspace
          https://learn.microsoft.com/dotnet/api/system.management.automation.runspaces.initialsessionstate.importpsmodule
          https://learn.microsoft.com/dotnet/api/system.management.automation.powershell.begininvoke
          https://learn.microsoft.com/dotnet/api/system.management.automation.powershell.beginstop
          https://learn.microsoft.com/powershell/module/microsoft.powershell.management/start-process
          https://learn.microsoft.com/powershell/module/microsoft.powershell.management/invoke-item
          https://learn.microsoft.com/dotnet/api/system.windows.window.closing (CancelEventArgs.Cancel)
          https://learn.microsoft.com/dotnet/api/system.windows.controls.datagrid.isreadonly
          https://learn.microsoft.com/dotnet/api/system.windows.controls.datagridcheckboxcolumn
          https://learn.microsoft.com/dotnet/api/system.windows.controls.tooltipservice.showondisabled
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $ContainerScope,

        [Parameter()]
        [switch] $NoAutoRun
    )

    if (-not (Test-FslIsWindows)) {
        $message = 'The WPF dashboard requires Windows. Use: Invoke-FslHealthCheck -ContainerScope ODFC | Export-FslReport'
        Write-FslLog -Message $message -Level Warning -Component 'GUI'
        New-FslResult -Category 'Core' -Check 'Dashboard' -Status 'Skipped' -Message $message `
            -Recommendation 'Run Start-FSLogixToolkit.ps1 -NoGui or use Invoke-FslHealthCheck | Export-FslReport.' -Source 'Toolkit default'
        return
    }

    $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($apartment -ne [System.Threading.ApartmentState]::STA) {
        $message = "The WPF dashboard requires a single-threaded apartment (STA) thread; current thread is $apartment."
        Write-FslLog -Message $message -Level Error -Component 'GUI'
        New-FslResult -Category 'Core' -Check 'Dashboard' -Status 'Error' -Value ([string]$apartment) -Expected 'STA' -Message $message `
            -Recommendation 'Start pwsh without -MTA (STA is the default on Windows) or run: pwsh -STA -File Start-FSLogixToolkit.ps1' `
            -Source 'https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_pwsh'
        return
    }

    if ($null -ne $script:FslGuiState -and -not [bool]$script:FslGuiState['Closing']) {
        $message = 'The dashboard is already open in this PowerShell session.'
        Write-FslLog -Message $message -Level Warning -Component 'GUI'
        New-FslResult -Category 'Core' -Check 'Dashboard' -Status 'Skipped' -Message $message `
            -Recommendation 'Close the open dashboard window first.' -Source 'Toolkit default'
        return
    }

    if (-not $script:FslSession['Initialized']) {
        try { $null = Initialize-FslSession }
        catch { Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Initialize-FslSession for dashboard' }
    }

    # Load WPF and the main window.
    $window = $null
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        $xamlPath = Join-Path -Path $script:FslSession['ModuleRoot'] -ChildPath 'GUI/MainWindow.xaml'
        $window = Import-FslGuiXaml -Path $xamlPath
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Load WPF assemblies and GUI/MainWindow.xaml'
        New-FslResult -Category 'Core' -Check 'Dashboard' -Status 'Error' -Message "Unable to load the dashboard: $($_.Exception.Message)" `
            -Recommendation 'Verify GUI/MainWindow.xaml exists and PowerShell 7 is running on Windows.' -Source 'Toolkit default'
        return
    }

    $connected = Connect-FslGuiControl -Root $window -Name (Get-FslGuiControlNameList)
    if ($connected['Missing'].Count -gt 0) {
        $message = "GUI/MainWindow.xaml is missing $($connected['Missing'].Count) named control(s): $($connected['Missing'] -join ', ')"
        Write-FslLog -Message $message -Level Error -Component 'GUI'
        New-FslResult -Category 'Core' -Check 'Dashboard' -Status 'Error' -Target 'GUI/MainWindow.xaml' -Value ($connected['Missing'] -join ', ') -Message $message `
            -Recommendation 'Restore GUI/MainWindow.xaml from the module package.' -Source 'Toolkit default'
        return
    }

    # Container mode and preferences (explicit parameter > preference file > Settings.psd1 > ODFC).
    $mode = 'ODFC'
    try {
        $mode = if ($PSBoundParameters.ContainsKey('ContainerScope')) { [string](Get-FslContainerMode -Mode $ContainerScope) } else { [string](Get-FslContainerMode) }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Resolve container mode'
        $mode = if ($PSBoundParameters.ContainsKey('ContainerScope')) { $ContainerScope } else { 'ODFC' }
    }
    if ($mode -notin @('ODFC', 'Profiles', 'Both')) { $mode = 'ODFC' }

    $preference = @{}
    try {
        $value = Get-FslPreference
        if ($value -is [System.Collections.IDictionary]) {
            foreach ($key in @($value.Keys)) { $preference[[string]$key] = $value[$key] }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Read preferences (Get-FslPreference); using Settings.psd1 Toolkit values'
        $toolkit = Get-FslConfig -Section 'Toolkit'
        if ($toolkit -is [hashtable]) { $preference = $toolkit }
    }

    $state = Initialize-FslGuiState -Mode $mode -Preference $preference -NoAutoRun ([bool]$NoAutoRun) -ModuleRoot ([string]$script:FslSession['ModuleRoot']) `
        -LogRoot ([string]$script:FslSession['LogRoot']) -ReportRoot ([string]$script:FslSession['ReportRoot']) -DebugLogging ([bool]$script:FslSession['DebugLogging'])
    $state['Window'] = $window
    $state['Controls'] = $connected['Controls']
    try { $state['IsElevated'] = [bool](Test-FslElevation) }
    catch { Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Test-FslElevation for dashboard' }
    $script:FslGuiState = $state

    try {
        Register-FslGuiEventHandler -State $state
        Sync-FslGuiModeView -State $state
        Sync-FslGuiBanner -State $state
        Sync-FslGuiDiscoveryPanel -State $state
        Sync-FslGuiDailyView -State $state
        Sync-FslGuiRepairView -State $state
        Sync-FslGuiErrorView -State $state
        Sync-FslGuiBusyView -State $state
        Sync-FslGuiActiveView -State $state

        Write-FslLog -Message "Dashboard opened (mode $mode, NoAutoRun=$([bool]$NoAutoRun))." -Level Info -Component 'GUI'
        $null = $window.ShowDialog()
        Write-FslLog -Message 'Dashboard closed.' -Level Info -Component 'GUI'
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Show dashboard window'
        New-FslResult -Category 'Core' -Check 'Dashboard' -Status 'Error' -Message "Dashboard failed: $($_.Exception.Message)" `
            -Recommendation 'Review the error log (Get-FslErrorLog) and the toolkit log file.' -Source 'Toolkit default'
    }
    finally {
        try { Close-FslGuiDashboardState }
        catch { Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Dispose dashboard state' }
        $script:FslGuiState = $null
    }
}
