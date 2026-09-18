# Private helpers for Show-FslDashboard: GUI state, view/tab/action definitions and menu enabled-state.
# Pure functions (no WPF types) so they can be unit tested on any platform.
# The live dashboard state is kept in the module-scoped variable $script:FslGuiState so that WPF event
# handler script blocks (which are bound to this module's session state) can reach it and call private
# functions. ScriptBlock.GetNewClosure() is deliberately NOT used for those handlers: it returns a script
# block bound to a new dynamic module, where $script: variables and module-private functions are not the
# ones of this module.
# Sources:
#   https://learn.microsoft.com/dotnet/api/system.management.automation.scriptblock.getnewclosure
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_scopes (Modules)

$script:FslGuiState = $null

function Get-FslGuiCheckCategory {
    <#
    .SYNOPSIS
        Returns the container-section check categories (inner tabs of the Office / Profile tabs).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    @('BestPractice', 'Containers', 'Performance', 'Network', 'Diagnostics')
}

function Get-FslGuiHealthCategory {
    <#
    .SYNOPSIS
        Returns the categories of a full health check run by the dashboard (Discovery runs separately).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    @('Environment', 'Policy', 'BestPractice', 'Containers', 'Performance', 'Network', 'Diagnostics')
}

function Get-FslGuiViewDefinition {
    <#
    .SYNOPSIS
        Returns the grid view definitions: Key, Grid (x:Name), Table (state table key), BaseFilter, Tab, InnerTab, IsResult.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $category = ConvertTo-FslGuiFilterColumn -Name 'Category'
    $target = ConvertTo-FslGuiFilterColumn -Name 'Target'
    $scope = ConvertTo-FslGuiFilterColumn -Name 'Scope'
    $general = ConvertTo-FslGuiFilterLiteral -Text 'General'

    @{ Key = 'Overview.All'; Grid = 'GridOverview'; Table = 'Results'; BaseFilter = ''; Tab = 'TabOverview'; InnerTab = $null; IsResult = $true }

    $discovery = [ordered]@{ Image = 'Image'; Fslogix = 'FSLogix'; Office = 'Office'; Registry = 'Registry'; Gpo = 'GroupPolicy'; Storage = 'StorageLocation'; Mode = 'Mode' }
    foreach ($suffix in $discovery.Keys) {
        $section = $discovery[$suffix]
        @{
            Key        = "Discovery.$section"
            Grid       = "GridDisc$suffix"
            Table      = 'Results'
            BaseFilter = ('{0} = {1} AND {2} = {3}' -f $category, (ConvertTo-FslGuiFilterLiteral -Text 'Discovery'), $target, (ConvertTo-FslGuiFilterLiteral -Text $section))
            Tab        = 'TabDiscovery'
            InnerTab   = "TabDisc$suffix"
            IsResult   = $true
        }
    }

    foreach ($section in @(@{ Prefix = 'Office'; Scope = 'ODFC' }, @{ Prefix = 'Profiles'; Scope = 'Profiles' })) {
        foreach ($checkCategory in (Get-FslGuiCheckCategory)) {
            @{
                Key        = '{0}.{1}' -f $section['Prefix'], $checkCategory
                Grid       = 'Grid{0}{1}' -f $section['Prefix'], $checkCategory
                Table      = 'Results'
                BaseFilter = ('{0} = {1} AND {2} IN ({3}, {4})' -f $category, (ConvertTo-FslGuiFilterLiteral -Text $checkCategory), $scope, (ConvertTo-FslGuiFilterLiteral -Text $section['Scope']), $general)
                Tab        = 'Tab{0}' -f $section['Prefix']
                InnerTab   = 'Tab{0}{1}' -f $section['Prefix'], $checkCategory
                IsResult   = $true
            }
        }
    }

    @{ Key = 'EnvPolicy.Environment'; Grid = 'GridEnvironment'; Table = 'Results'; BaseFilter = ('{0} = {1}' -f $category, (ConvertTo-FslGuiFilterLiteral -Text 'Environment')); Tab = 'TabEnvPolicy'; InnerTab = 'TabEnvItemEnvironment'; IsResult = $true }
    @{ Key = 'EnvPolicy.Policy'; Grid = 'GridPolicy'; Table = 'Results'; BaseFilter = ('{0} = {1}' -f $category, (ConvertTo-FslGuiFilterLiteral -Text 'Policy')); Tab = 'TabEnvPolicy'; InnerTab = 'TabEnvItemPolicy'; IsResult = $true }
    @{ Key = 'EnvPolicy.Prerequisites'; Grid = 'GridPrerequisites'; Table = 'Results'; BaseFilter = ('{0} = {1}' -f $category, (ConvertTo-FslGuiFilterLiteral -Text 'Core')); Tab = 'TabEnvPolicy'; InnerTab = 'TabEnvItemPrerequisites'; IsResult = $true }
    @{ Key = 'Daily.History'; Grid = 'GridDailyHistory'; Table = 'Daily'; BaseFilter = ''; Tab = 'TabDaily'; InnerTab = $null; IsResult = $false }
    @{ Key = 'Repair.Runs'; Grid = 'GridRepairHistory'; Table = 'Repair'; BaseFilter = ''; Tab = 'TabRepair'; InnerTab = 'TabRepairRuns'; IsResult = $false }
    @{ Key = 'Repair.Results'; Grid = 'GridRepairResults'; Table = 'Results'; BaseFilter = ('{0} = {1}' -f $category, (ConvertTo-FslGuiFilterLiteral -Text 'Repair')); Tab = 'TabRepair'; InnerTab = 'TabRepairResults'; IsResult = $true }
    @{ Key = 'Errors'; Grid = 'GridErrors'; Table = 'Errors'; BaseFilter = ''; Tab = 'TabErrors'; InnerTab = $null; IsResult = $false }
}

function Get-FslGuiTabMap {
    <#
    .SYNOPSIS
        Returns the main tab -> inner TabControl map (main tabs without inner tabs map to $null).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        TabOverview  = $null
        TabDiscovery = 'TabDiscoveryInner'
        TabOffice    = 'TabOfficeInner'
        TabProfiles  = 'TabProfilesInner'
        TabEnvPolicy = 'TabEnvInner'
        TabDaily     = $null
        TabRepair    = 'TabRepairInner'
        TabErrors    = $null
    }
}

function Get-FslGuiButtonActionMap {
    <#
    .SYNOPSIS
        Returns the button (x:Name) -> action name map. Buttons share the action (and enabled state) of a menu item.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        BtnOverviewFull      = 'MnuHealthFull'
        BtnOverviewDiscovery = 'MnuDiscRun'
        BtnOfficeRunAll      = 'MnuOdfcRunAll'
        BtnProfilesRunAll    = 'MnuProfRunAll'
        BtnProfilesEnable    = 'MnuProfEnable'
        BtnEnvRun            = 'MnuToolsEnvironment'
        BtnPolicyRun         = 'ActPolicyRun'
        BtnPrereqRun         = 'MnuToolsPrereq'
        BtnDailyRunNow       = 'MnuDailyRunNow'
        BtnDailySchedule     = 'MnuDailySchedule'
        BtnDailyRemove       = 'MnuDailyRemove'
        BtnDailyRefresh      = 'MnuDailyHistory'
        BtnDailyOpenFolder   = 'MnuDailyOpenFolder'
        BtnRepairPlanOpen      = 'MnuRepairPlan'
        BtnRepairContainerOpen = 'MnuRepairContainer'
        BtnRepairHistoryRefresh = 'MnuRepairHistory'
        BtnRepairUndoRun       = 'MnuRepairUndo'
        BtnRepairOpenFolder    = 'MnuRepairOpenLogs'
        BtnErrorsRefresh     = 'MnuToolsErrorLog'
        BtnOpenLogFolder     = 'MnuOpenLogs'
        BtnCancel            = 'ActCancel'
        BtnClearFilter       = 'ActClearFilter'
        BtnOpenSource        = 'ActOpenSource'
    }
}

function Get-FslGuiMenuItemName {
    <#
    .SYNOPSIS
        Returns the x:Name of every actionable MenuItem in GUI/MainWindow.xaml.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    @(
        'MnuExportViewCsv', 'MnuExportViewHtml', 'MnuExportAllCsv', 'MnuExportAllHtml', 'MnuExportBundle', 'MnuOpenReports', 'MnuOpenLogs'
        'MnuRelaunchElevated', 'MnuRelaunchUser', 'MnuExit'
        'MnuDiscRun', 'MnuDiscImage', 'MnuDiscFslogix', 'MnuDiscOffice', 'MnuDiscRegistry', 'MnuDiscGpo', 'MnuDiscStorage'
        'MnuOdfcRunAll', 'MnuOdfcBestPractice', 'MnuOdfcContainers', 'MnuOdfcPerformance', 'MnuOdfcNetwork', 'MnuOdfcLogs', 'MnuOdfcKnownIssues'
        'MnuProfEnable', 'MnuProfRunAll', 'MnuProfBestPractice', 'MnuProfContainers', 'MnuProfPerformance', 'MnuProfNetwork', 'MnuProfLogs', 'MnuProfKnownIssues'
        'MnuHealthFull', 'MnuDailyRunNow', 'MnuDailyHistory', 'MnuDailySchedule', 'MnuDailyRemove', 'MnuDailyOpenFolder'
        'MnuRepairPlan', 'MnuRepairContainer', 'MnuRepairUndo', 'MnuRepairHistory', 'MnuRepairOpenLogs'
        'MnuToolsPrereq', 'MnuToolsEnvironment', 'MnuToolsErrorLog', 'MnuToolsDebug', 'MnuToolsOffline'
        'MnuModeOdfc', 'MnuModeProfiles', 'MnuModeBoth', 'MnuOptDiscoverStartup', 'MnuOptHealthStartup'
        'MnuRefreshOff', 'MnuRefresh15', 'MnuRefresh30', 'MnuRefresh60'
        'MnuHelpAbout', 'MnuHelpUsage'
    )
}

function Get-FslGuiControlNameList {
    <#
    .SYNOPSIS
        Returns every x:Name the dashboard code references in GUI/MainWindow.xaml (checked with FindName at load).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($name in (Get-FslGuiMenuItemName)) { $names.Add($name) }
    foreach ($name in (Get-FslGuiButtonActionMap).Keys) { $names.Add([string]$name) }
    foreach ($view in (Get-FslGuiViewDefinition)) {
        $names.Add([string]$view['Grid'])
        if ($null -ne $view['InnerTab']) { $names.Add([string]$view['InnerTab']) }
    }
    $tabMap = Get-FslGuiTabMap
    foreach ($tab in $tabMap.Keys) {
        $names.Add([string]$tab)
        if ($null -ne $tabMap[$tab]) { $names.Add([string]$tabMap[$tab]) }
    }
    foreach ($name in @(
            'WndMain', 'MnuMain', 'TabMain', 'GridSummary', 'MnuRepairRoot'
            'TxtBannerComputer', 'TxtBannerOs', 'TxtBannerFslogix', 'TxtBannerOffice', 'TxtBannerElevated', 'TxtBannerAccount', 'TxtBannerLastCheck', 'TxtBannerDaily', 'TxtBannerNote', 'TxtModeBadge'
            'PrgBusy', 'TxtStatus', 'TxtQueue'
            'CmbStatusFilter', 'TxtSearch', 'TxtViewCount'
            'TxtOverviewInfo'
            'TxtDiscAt', 'TxtDiscElevated', 'TxtDiscImage', 'TxtDiscFslogix', 'TxtDiscOffice', 'TxtDiscMode', 'TxtDiscMismatch'
            'TxtOfficeOff', 'PnlOffice', 'PnlProfilesOff', 'TxtProfilesOff', 'PnlProfiles'
            'TxtDailyRegistered', 'TxtDailyState', 'TxtDailyAt', 'TxtDailyScope', 'TxtDailyNext', 'TxtDailyLast', 'TxtDailyNote'
            'TxtRepairTabNote', 'TxtRepairRunDetail'
            'TxtLogPath', 'TxtLogTail'
            'TxtDetailTitle', 'TxtDetailMessage', 'TxtDetailRecommendation', 'TxtDetailSource'
        )) { $names.Add($name) }
    return , [string[]]@($names | Select-Object -Unique)
}

function Get-FslGuiScheduleControlName {
    <#
    .SYNOPSIS
        Returns every x:Name referenced in GUI/ScheduleDialog.xaml.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    @('WndSchedule', 'TxtScheduleTime', 'RdoRunAsSystem', 'RdoRunAsCurrentUser', 'TxtScheduleElevation', 'CmbScheduleMode',
        'CmbScheduleModeOdfc', 'CmbScheduleModeProfiles', 'CmbScheduleModeBoth', 'ChkScheduleOffline', 'ChkScheduleReplace',
        'TxtScheduleError', 'BtnScheduleOk', 'BtnScheduleCancel')
}

function Get-FslGuiOperation {
    <#
    .SYNOPSIS
        Creates a background operation description (hashtable) for the dashboard queue.
    .DESCRIPTION
        Name is the background operation (see Get-FslGuiBackgroundScript). Categories/Scopes describe which
        result rows the operation replaces (Category x Scope, 'General' always included).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Initialize', 'Debug', 'Discovery', 'HealthCheck', 'Environment', 'Prerequisites', 'ErrorLog',
            'DailyRun', 'DailyState', 'DailyRegister', 'DailyUnregister', 'DiagnosticBundle',
            'RepairPlan', 'RepairPreview', 'RepairApply', 'RepairUndo', 'RepairLog', 'ContainerList', 'ContainerReset')]
        [string] $Name,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Display,

        [Parameter()]
        [hashtable] $Parameter = @{},

        [Parameter()]
        [ValidateSet('Discovery', 'Environment', 'Policy', 'BestPractice', 'Containers', 'Performance', 'Network', 'Diagnostics', 'Core', 'Repair')]
        [string[]] $Category = @(),

        [Parameter()]
        [ValidateSet('General', 'ODFC', 'Profiles')]
        [string[]] $Scope = @('General')
    )

    $scopes = [System.Collections.Generic.List[string]]::new()
    $scopes.Add('General')
    foreach ($item in $Scope) { if (-not $scopes.Contains($item)) { $scopes.Add($item) } }
    return @{
        Id         = 0
        Name       = $Name
        Display    = if ($PSBoundParameters.ContainsKey('Display')) { $Display } else { $Name }
        Parameters = $Parameter.Clone()
        Categories = [string[]]@($Category)
        Scopes     = [string[]]$scopes.ToArray()
        QueuedAt   = $null
        StartedAt  = $null
    }
}

function Get-FslGuiHealthCheckOperation {
    <#
    .SYNOPSIS
        Creates a HealthCheck operation: Invoke-FslHealthCheck -Category <Category> -ContainerScope <ContainerScope> [-Offline].
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Discovery', 'Environment', 'Policy', 'BestPractice', 'Containers', 'Performance', 'Network', 'Diagnostics')]
        [string[]] $Category,

        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $ContainerScope,

        [Parameter()]
        [bool] $Offline = $false,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Display
    )

    $scopes = [System.Collections.Generic.List[string]]::new()
    foreach ($item in (Get-FslGuiScopeList -Mode $ContainerScope)) { $scopes.Add($item) }
    # Discovery and Environment results are not container-scope limited: replace all of their scopes.
    if (@($Category | Where-Object -FilterScript { $_ -in @('Discovery', 'Environment') }).Count -gt 0) {
        foreach ($item in @('ODFC', 'Profiles')) { if (-not $scopes.Contains($item)) { $scopes.Add($item) } }
    }
    $text = if ($PSBoundParameters.ContainsKey('Display')) { $Display } else { 'Health check ({0}: {1})' -f $ContainerScope, ($Category -join ', ') }
    $parameters = @{ Category = [string[]]$Category; ContainerScope = $ContainerScope; Offline = $Offline }
    return (Get-FslGuiOperation -Name 'HealthCheck' -Display $text -Parameter $parameters -Category $Category -Scope $scopes.ToArray())
}

function Get-FslGuiActionDefinition {
    <#
    .SYNOPSIS
        Describes a dashboard action (menu item or button): Kind, required container scope, navigation target and
        background operations for the given mode.
    .DESCRIPTION
        Kind: Work (starts background work; disabled while busy), View (UI only), Toggle (preference or mode;
        allowed while busy), Cancel. RequiresScope: ODFC or Profiles when the action is only valid when the mode
        includes that scope. Operations is empty for actions whose work is decided interactively (dialogs).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $Mode,

        [Parameter()]
        [bool] $Offline = $false,

        [Parameter()]
        [switch] $SkipOperation
    )

    $definition = @{ Name = $Name; Kind = 'View'; RequiresScope = $null; Tab = $null; InnerTab = $null; Operations = @() }
    $withOperation = -not $SkipOperation

    $sectionItems = @{ BestPractice = 'BestPractice'; Containers = 'Containers'; Performance = 'Performance'; Network = 'Network'; Logs = 'Diagnostics'; KnownIssues = 'Diagnostics' }
    $sections = @{ Odfc = @{ Scope = 'ODFC'; Tab = 'TabOffice'; Prefix = 'Office' }; Prof = @{ Scope = 'Profiles'; Tab = 'TabProfiles'; Prefix = 'Profiles' } }

    if ($Name -match '^Mnu(Odfc|Prof)(RunAll|BestPractice|Containers|Performance|Network|Logs|KnownIssues)$') {
        $section = $sections[$Matches[1]]
        $item = $Matches[2]
        $definition['Kind'] = 'Work'
        $definition['RequiresScope'] = $section['Scope']
        $definition['Tab'] = $section['Tab']
        if ($item -eq 'RunAll') {
            if (-not $withOperation) { return $definition }
            $label = if ($section['Scope'] -eq 'ODFC') { 'Office' } else { 'Profile' }
            $definition['Operations'] = @(Get-FslGuiHealthCheckOperation -Category (Get-FslGuiCheckCategory) -ContainerScope $section['Scope'] -Offline $Offline -Display "All $label container checks")
        }
        else {
            $checkCategory = $sectionItems[$item]
            $definition['InnerTab'] = 'Tab{0}{1}' -f $section['Prefix'], $checkCategory
            if (-not $withOperation) { return $definition }
            $definition['Operations'] = @(Get-FslGuiHealthCheckOperation -Category $checkCategory -ContainerScope $section['Scope'] -Offline $Offline)
        }
        return $definition
    }

    $discoveryViews = @{ MnuDiscImage = 'TabDiscImage'; MnuDiscFslogix = 'TabDiscFslogix'; MnuDiscOffice = 'TabDiscOffice'; MnuDiscRegistry = 'TabDiscRegistry'; MnuDiscGpo = 'TabDiscGpo'; MnuDiscStorage = 'TabDiscStorage' }
    if ($discoveryViews.ContainsKey($Name)) {
        $definition['Tab'] = 'TabDiscovery'
        $definition['InnerTab'] = $discoveryViews[$Name]
        return $definition
    }

    $discoveryOperation = $null
    if ($withOperation) {
        $discoveryOperation = Get-FslGuiOperation -Name 'Discovery' -Display 'Discovery' -Parameter @{ Offline = $Offline; ContainerScope = $Mode } -Category 'Discovery' -Scope @('General', 'ODFC', 'Profiles')
    }
    switch ($Name) {
        'MnuDiscRun' {
            $definition['Kind'] = 'Work'; $definition['Tab'] = 'TabDiscovery'; if ($withOperation) { $definition['Operations'] = @($discoveryOperation) }
        }
        'MnuHealthFull' {
            $definition['Kind'] = 'Work'; $definition['Tab'] = 'TabOverview'
            if ($withOperation) { $definition['Operations'] = @($discoveryOperation, (Get-FslGuiHealthCheckOperation -Category (Get-FslGuiHealthCategory) -ContainerScope $Mode -Offline $Offline -Display "Full health check ($Mode)")) }
        }
        'ActPolicyRun' {
            $definition['Kind'] = 'Work'; $definition['Tab'] = 'TabEnvPolicy'; $definition['InnerTab'] = 'TabEnvItemPolicy'
            if ($withOperation) { $definition['Operations'] = @(Get-FslGuiHealthCheckOperation -Category 'Policy' -ContainerScope $Mode -Offline $Offline) }
        }
        'MnuToolsEnvironment' {
            $definition['Kind'] = 'Work'; $definition['Tab'] = 'TabEnvPolicy'; $definition['InnerTab'] = 'TabEnvItemEnvironment'
            if ($withOperation) { $definition['Operations'] = @(Get-FslGuiOperation -Name 'Environment' -Display 'Environment & versions' -Parameter @{ Offline = $Offline } -Category 'Environment' -Scope @('General', 'ODFC', 'Profiles')) }
        }
        'MnuToolsPrereq' {
            $definition['Kind'] = 'Work'; $definition['Tab'] = 'TabEnvPolicy'; $definition['InnerTab'] = 'TabEnvItemPrerequisites'
            if ($withOperation) { $definition['Operations'] = @(Get-FslGuiOperation -Name 'Prerequisites' -Display 'Prerequisites (no install)' -Category 'Core' -Scope @('General', 'ODFC', 'Profiles')) }
        }
        'MnuExportBundle' {
            $definition['Kind'] = 'Work'
            if ($withOperation) { $definition['Operations'] = @(Get-FslGuiOperation -Name 'DiagnosticBundle' -Display 'Export diagnostic bundle') }
        }
        'MnuDailyRunNow' {
            $definition['Kind'] = 'Work'; $definition['Tab'] = 'TabDaily'
            if ($withOperation) { $definition['Operations'] = @(Get-FslGuiOperation -Name 'DailyRun' -Display "Daily health check ($Mode)" -Parameter @{ ContainerScope = $Mode; Offline = $Offline }) }
        }
        'MnuDailyHistory' {
            $definition['Kind'] = 'Work'; $definition['Tab'] = 'TabDaily'
            if ($withOperation) { $definition['Operations'] = @(Get-FslGuiOperation -Name 'DailyState' -Display 'Daily schedule and history') }
        }
        'MnuDailySchedule' { $definition['Kind'] = 'Work'; $definition['Tab'] = 'TabDaily' }
        'MnuDailyRemove' { $definition['Kind'] = 'Work'; $definition['Tab'] = 'TabDaily' }
        'MnuDailyOpenFolder' { $definition['Tab'] = $null }
        # Repair (CONTRACT P3.7). The operations are built when the operator confirms a dialog, so Operations stays empty.
        'MnuRepairPlan' { $definition['Kind'] = 'Work'; $definition['Tab'] = 'TabRepair'; $definition['InnerTab'] = 'TabRepairResults' }
        'MnuRepairContainer' { $definition['Kind'] = 'Work'; $definition['RequiresScope'] = 'ODFC'; $definition['Tab'] = 'TabRepair'; $definition['InnerTab'] = 'TabRepairResults' }
        'MnuRepairUndo' { $definition['Kind'] = 'Work'; $definition['Tab'] = 'TabRepair'; $definition['InnerTab'] = 'TabRepairRuns' }
        'MnuRepairHistory' { $definition['Kind'] = 'Work'; $definition['Tab'] = 'TabRepair'; $definition['InnerTab'] = 'TabRepairRuns' }
        'MnuRepairOpenLogs' { $definition['Tab'] = $null }
        'MnuToolsDebug' { $definition['Kind'] = 'Work' }
        'MnuToolsErrorLog' { $definition['Tab'] = 'TabErrors' }
        'MnuProfEnable' { $definition['Kind'] = 'Toggle'; $definition['Tab'] = 'TabProfiles' }
        'ActCancel' { $definition['Kind'] = 'Cancel' }
        default {
            if ($Name -in @('MnuToolsOffline', 'MnuModeOdfc', 'MnuModeProfiles', 'MnuModeBoth', 'MnuOptDiscoverStartup', 'MnuOptHealthStartup', 'MnuRefreshOff', 'MnuRefresh15', 'MnuRefresh30', 'MnuRefresh60')) {
                $definition['Kind'] = 'Toggle'
            }
        }
    }
    return $definition
}

function Get-FslGuiMenuState {
    <#
    .SYNOPSIS
        Computes IsEnabled / IsChecked for every menu item and button from the mode, busy flag and preferences.
    .DESCRIPTION
        Pure function. Returns a hashtable: control name -> @{ IsEnabled = [bool]; IsChecked = [bool] or $null }.
        - Work actions are disabled while a background operation is running or queued.
        - Office Containers items require a mode that includes ODFC; Profile Containers items require a mode that
          includes Profiles. 'Enable Profile Container Checks...' is enabled only in ODFC mode.
        - Remove Daily Schedule is disabled when the task is known not to be registered.
        - Cancel is enabled only while busy.
        - Repair (CONTRACT P3.7): every item needs an elevated session except Repair History and Open Repair Logs
          Folder, which stay enabled so the operator can read past runs. 'Relaunch Elevated (UAC)' is disabled when
          the session is already elevated.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $Mode,

        [Parameter(Mandatory)]
        [bool] $IsBusy,

        [Parameter()]
        [bool] $Offline = $false,

        [Parameter()]
        [bool] $DebugLogging = $false,

        [Parameter()]
        [bool] $AutoDiscover = $true,

        [Parameter()]
        [bool] $AutoHealthCheck = $true,

        [Parameter()]
        [ValidateRange(0, 1440)]
        [int] $AutoRefreshMinutes = 0,

        [Parameter()]
        [AllowNull()]
        [object] $DailyRegistered = $null,

        [Parameter()]
        [bool] $IsElevated = $false
    )

    $scopes = Get-FslGuiScopeList -Mode $Mode
    $checked = @{
        MnuToolsDebug         = $DebugLogging
        MnuToolsOffline       = $Offline
        MnuModeOdfc           = ($Mode -eq 'ODFC')
        MnuModeProfiles       = ($Mode -eq 'Profiles')
        MnuModeBoth           = ($Mode -eq 'Both')
        MnuOptDiscoverStartup = $AutoDiscover
        MnuOptHealthStartup   = $AutoHealthCheck
        MnuRefreshOff         = ($AutoRefreshMinutes -eq 0)
        MnuRefresh15          = ($AutoRefreshMinutes -eq 15)
        MnuRefresh30          = ($AutoRefreshMinutes -eq 30)
        MnuRefresh60          = ($AutoRefreshMinutes -eq 60)
    }

    $actionEnabled = @{}
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($name in (Get-FslGuiMenuItemName)) { $names.Add($name) }
    $names.Add('ActPolicyRun'); $names.Add('ActCancel'); $names.Add('ActClearFilter'); $names.Add('ActOpenSource')
    foreach ($name in $names) {
        $definition = Get-FslGuiActionDefinition -Name $name -Mode $Mode -Offline $Offline -SkipOperation
        $enabled = $true
        switch ($definition['Kind']) {
            'Work' { if ($IsBusy) { $enabled = $false } }
            'Cancel' { $enabled = $IsBusy }
        }
        if ($null -ne $definition['RequiresScope'] -and $definition['RequiresScope'] -notin $scopes) { $enabled = $false }
        if ($name -eq 'MnuProfEnable') { $enabled = ($Mode -eq 'ODFC') }
        if ($name -eq 'MnuDailyRemove' -and $DailyRegistered -is [bool] -and -not $DailyRegistered) { $enabled = $false }
        if ($name -in (Get-FslGuiRepairElevatedActionName) -and -not $IsElevated) { $enabled = $false }
        if ($name -eq 'MnuRelaunchElevated' -and $IsElevated) { $enabled = $false }
        $actionEnabled[$name] = $enabled
    }

    $state = @{}
    foreach ($name in (Get-FslGuiMenuItemName)) {
        $isChecked = $null
        if ($checked.ContainsKey($name)) { $isChecked = [bool]$checked[$name] }
        $state[$name] = @{ IsEnabled = [bool]$actionEnabled[$name]; IsChecked = $isChecked }
    }
    $buttons = Get-FslGuiButtonActionMap
    foreach ($button in $buttons.Keys) {
        $action = $buttons[$button]
        $state[$button] = @{ IsEnabled = [bool]$actionEnabled[$action]; IsChecked = $null }
    }
    return $state
}

function Get-FslGuiStartupOperation {
    <#
    .SYNOPSIS
        Returns the operations queued when the window is loaded (CONTRACT P2.4 automatic checks).
    .DESCRIPTION
        Always: DailyState (schedule state for the banner). Discovery when AutoDiscover is $true. Health check for
        the mode (Environment, Policy, BestPractice, Containers, Performance, Network, Diagnostics) when
        AutoHealthCheck is $true and NoAutoRun is not set.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $Mode,

        [Parameter(Mandatory)]
        [bool] $AutoDiscover,

        [Parameter(Mandatory)]
        [bool] $AutoHealthCheck,

        [Parameter(Mandatory)]
        [bool] $NoAutoRun,

        [Parameter()]
        [bool] $Offline = $false
    )

    Get-FslGuiOperation -Name 'DailyState' -Display 'Daily schedule and history'
    if ($AutoDiscover) {
        Get-FslGuiOperation -Name 'Discovery' -Display 'Startup discovery' -Parameter @{ Offline = $Offline; ContainerScope = $Mode } -Category 'Discovery' -Scope @('General', 'ODFC', 'Profiles')
    }
    if ($AutoHealthCheck -and -not $NoAutoRun) {
        Get-FslGuiHealthCheckOperation -Category (Get-FslGuiHealthCategory) -ContainerScope $Mode -Offline $Offline -Display "Startup health check ($Mode)"
    }
}

function Initialize-FslGuiState {
    <#
    .SYNOPSIS
        Creates the dashboard state hashtable (tables, views, queue, preferences). No WPF objects are created here.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $Mode,

        [Parameter()]
        [hashtable] $Preference = @{},

        [Parameter()]
        [bool] $NoAutoRun = $false,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ModuleRoot,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $LogRoot,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ReportRoot,

        [Parameter()]
        [bool] $DebugLogging = $false
    )

    $readBool = {
        param([string] $Key, [bool] $Default)
        if ($Preference.ContainsKey($Key) -and $null -ne $Preference[$Key]) {
            try { return [System.Convert]::ToBoolean($Preference[$Key], [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $Default }
        }
        return $Default
    }
    $refresh = 0
    if ($Preference.ContainsKey('AutoRefreshMinutes') -and $null -ne $Preference['AutoRefreshMinutes']) {
        $parsed = 0
        if ([int]::TryParse([string]$Preference['AutoRefreshMinutes'], [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 1440) { $refresh = $parsed }
    }

    $tables = @{
        Results = Initialize-FslGuiResultTable -TableName 'Results'
        Summary = Initialize-FslGuiSummaryTable
        Errors  = Initialize-FslGuiErrorTable
        Daily   = Initialize-FslGuiDailyTable
        Repair  = Initialize-FslGuiRepairRunTable
    }
    $views = [ordered]@{}
    foreach ($definition in (Get-FslGuiViewDefinition)) {
        $view = [System.Data.DataView]::new($tables[$definition['Table']])
        $view.RowFilter = [string]$definition['BaseFilter']
        $views[$definition['Key']] = @{ Definition = $definition; View = $view }
    }

    return @{
        Window             = $null
        Controls           = @{}
        Timers             = @{ Poll = $null; Refresh = $null }
        Mode               = $Mode
        NoAutoRun          = $NoAutoRun
        Offline            = (& $readBool 'Offline' $false)
        AutoDiscover       = (& $readBool 'AutoDiscoverOnStartup' $true)
        AutoHealthCheck    = (& $readBool 'AutoRunHealthCheckOnStartup' $true)
        AutoRefreshMinutes = $refresh
        DebugLogging       = $DebugLogging
        ModuleRoot         = $ModuleRoot
        ManifestPath       = (Join-Path -Path $ModuleRoot -ChildPath 'FSLogixToolkit.psd1')
        LogRoot            = $LogRoot
        ReportRoot         = $ReportRoot
        Tables             = $tables
        Views              = $views
        IsElevated         = $false
        Discovery          = $null
        DailyTask          = $null
        DailyReportRoot    = $null
        ScheduleDialog     = $null
        Repair             = (Initialize-FslGuiRepairState)
        LastCheck          = $null
        BackgroundErrors   = [System.Collections.Generic.List[object]]::new()
        RunnerErrors       = [System.Collections.Generic.List[object]]::new()
        BackgroundLogPath  = $null
        InTick             = $false
        Closing            = $false
        Runner             = @{
            Queue       = [System.Collections.Generic.List[object]]::new()
            Current     = $null
            PowerShell  = $null
            Handle      = $null
            Runspace    = $null
            Initialized = $false
            Cancelling  = $false
            NextId      = 1
        }
    }
}
