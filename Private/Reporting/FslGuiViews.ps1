# Private helpers for Show-FslDashboard: XAML loading and view updates (WPF controls; Windows only, UI thread only).
# Pure text helpers (Get-FslGui*Text / *Summary) have no WPF dependency and are unit tested on any platform.
# Sources:
#   https://learn.microsoft.com/dotnet/api/system.windows.markup.xamlreader.load
#   https://learn.microsoft.com/dotnet/api/system.windows.frameworkelement.findname
#   https://learn.microsoft.com/dotnet/api/system.windows.messagebox.show
#   https://learn.microsoft.com/dotnet/api/microsoft.win32.commondialog.showdialog
#   https://learn.microsoft.com/dotnet/api/microsoft.win32.savefiledialog
#   https://learn.microsoft.com/dotnet/api/system.windows.controls.primitives.selector.selectionchanged (bubbling)
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.management/invoke-item
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.management/start-process
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_automatic_variables ($PSVersionTable.OS)

function Write-FslGuiHandlerError {
    <#
    .SYNOPSIS
        Records an exception raised in a WPF event handler (Add-FslError) and shows it in the status bar. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Context
    )

    try { Add-FslError -ErrorRecord $ErrorRecord -Component 'GUI' -Context "Dashboard: $Context" } catch { $null = $_ }
    try {
        $state = $script:FslGuiState
        if ($null -ne $state -and $state['Controls'].ContainsKey('TxtStatus')) {
            $state['Controls']['TxtStatus'].Text = "Error ($Context): $($ErrorRecord.Exception.Message) - see Errors & Log."
        }
    }
    catch { $null = $_ }
}

function Import-FslGuiXaml {
    <#
    .SYNOPSIS
        Loads a XAML file with System.Windows.Markup.XamlReader via XmlNodeReader and returns the root object.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    [xml]$xaml = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    try {
        return [System.Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        $reader.Dispose()
    }
}

function Connect-FslGuiControl {
    <#
    .SYNOPSIS
        Resolves every named control with FindName. Returns @{ Controls = hashtable; Missing = string[] }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object] $Root,

        [Parameter(Mandatory)]
        [string[]] $Name
    )

    $controls = @{}
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Name) {
        $control = $null
        if ($item -eq [string]$Root.Name) { $control = $Root } else { $control = $Root.FindName($item) }
        if ($null -eq $control) { $missing.Add($item) } else { $controls[$item] = $control }
    }
    return @{ Controls = $controls; Missing = [string[]]$missing.ToArray() }
}

function Write-FslGuiStatus {
    <#
    .SYNOPSIS
        Shows a message in the status bar and writes it to the toolkit log (Verbose).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    if ($State['Controls'].ContainsKey('TxtStatus')) { $State['Controls']['TxtStatus'].Text = $Text }
    if (-not [string]::IsNullOrWhiteSpace($Text)) { Write-FslLog -Message "Dashboard: $Text" -Level Verbose -Component 'GUI' }
}

function Show-FslGuiMessage {
    <#
    .SYNOPSIS
        Shows a MessageBox owned by the dashboard window. Returns the MessageBoxResult name (OK, Cancel, Yes, No).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Text,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Caption = 'FSLogixToolkit',

        [Parameter()]
        [ValidateSet('OK', 'OKCancel', 'YesNo', 'YesNoCancel')]
        [string] $Button = 'OK',

        [Parameter()]
        [ValidateSet('None', 'Information', 'Warning', 'Error')]
        [string] $Icon = 'Information'
    )

    $buttonValue = [System.Windows.MessageBoxButton]$Button
    $iconValue = [System.Windows.MessageBoxImage]$Icon
    $result = if ($null -ne $State['Window']) {
        [System.Windows.MessageBox]::Show($State['Window'], $Text, $Caption, $buttonValue, $iconValue)
    }
    else {
        [System.Windows.MessageBox]::Show($Text, $Caption, $buttonValue, $iconValue)
    }
    return [string]$result
}

function Select-FslGuiTab {
    <#
    .SYNOPSIS
        Selects a main tab and optionally an inner tab.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Tab,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $InnerTab
    )

    $controls = $State['Controls']
    if (-not [string]::IsNullOrEmpty($Tab) -and $controls.ContainsKey($Tab)) { $controls[$Tab].IsSelected = $true }
    if (-not [string]::IsNullOrEmpty($InnerTab) -and $controls.ContainsKey($InnerTab)) { $controls[$InnerTab].IsSelected = $true }
}

function Get-FslGuiActiveViewKey {
    <#
    .SYNOPSIS
        Returns the key of the grid view that is currently visible (selected main tab and inner tab), or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $controls = $State['Controls']
    $mainItem = $controls['TabMain'].SelectedItem
    if ($null -eq $mainItem) { return $null }
    $mainName = [string]$mainItem.Name
    # A container section that is off for the current mode shows only its off message: no visible grid.
    $modeText = Get-FslGuiModeText -Mode $State['Mode']
    if (($mainName -eq 'TabOffice' -and -not $modeText['OfficeEnabled']) -or ($mainName -eq 'TabProfiles' -and -not $modeText['ProfilesEnabled'])) {
        return $null
    }
    $tabMap = Get-FslGuiTabMap
    $innerName = $null
    if ($tabMap.ContainsKey($mainName) -and $null -ne $tabMap[$mainName]) {
        $innerItem = $controls[$tabMap[$mainName]].SelectedItem
        if ($null -ne $innerItem) { $innerName = [string]$innerItem.Name }
    }
    foreach ($key in $State['Views'].Keys) {
        $definition = $State['Views'][$key]['Definition']
        if ($definition['Tab'] -ne $mainName) { continue }
        if ($null -eq $definition['InnerTab'] -or $definition['InnerTab'] -eq $innerName) { return [string]$key }
    }
    return $null
}

function Sync-FslGuiFilter {
    <#
    .SYNOPSIS
        Applies the filter bar (status + search) to the visible grid's DataView and updates the row count text.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $controls = $State['Controls']
    $key = Get-FslGuiActiveViewKey -State $State
    if ($null -eq $key) {
        $controls['TxtViewCount'].Text = ''
        return
    }
    $entry = $State['Views'][$key]
    $view = $entry['View']
    $selected = $controls['CmbStatusFilter'].SelectedItem
    $status = if ($null -ne $selected) { [string]$selected.Content } else { 'All' }
    $filter = Get-FslGuiRowFilter -Table $view.Table -BaseFilter ([string]$entry['Definition']['BaseFilter']) -Status $status -SearchText ([string]$controls['TxtSearch'].Text)
    try {
        if ($view.RowFilter -ne $filter) { $view.RowFilter = $filter }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Apply filter bar'
        $view.RowFilter = [string]$entry['Definition']['BaseFilter']
        Write-FslGuiStatus -State $State -Text "The filter could not be applied: $($_.Exception.Message)"
    }
    $total = $view.Table.Rows.Count
    $controls['TxtViewCount'].Text = "Showing $($view.Count) row(s) in this view ($total in table)."
}

function Get-FslGuiDetailText {
    <#
    .SYNOPSIS
        Builds the details panel texts (Title, Message, Recommendation, Source, CanOpenSource) for a row object.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Row
    )

    if ($null -eq $Row) {
        return @{ Title = 'Select a row to see its details.'; Message = ''; Recommendation = ''; Source = ''; CanOpenSource = $false }
    }
    $isResult = ($null -ne $Row.PSObject.Properties['Check'] -and $null -ne $Row.PSObject.Properties['Status'])
    if ($isResult) {
        $read = { param([string] $Name) Get-FslGuiPropertyText -InputObject $Row -Name $Name }
        $title = '[{0}] {1} / {2}: {3}' -f (& $read 'Status'), (& $read 'Category'), (& $read 'Scope'), (& $read 'Check')
        $target = & $read 'Target'
        if ($target) { $title += " - $target" }
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('Message:')
        $lines.Add((& $read 'Message'))
        $lines.Add('')
        $lines.Add("Value: $(& $read 'Value')")
        $lines.Add("Expected: $(& $read 'Expected')")
        $lines.Add("Requires elevation: $(& $read 'RequiresElevation')")
        $lines.Add("Timestamp: $(& $read 'Timestamp')")
        $source = & $read 'Source'
        return @{
            Title          = $title
            Message        = ($lines -join [System.Environment]::NewLine)
            Recommendation = "Recommendation:$([System.Environment]::NewLine)$(& $read 'Recommendation')"
            Source         = $source
            CanOpenSource  = (Test-FslGuiHttpsUrl -Text $source)
        }
    }
    $pairs = foreach ($property in $Row.PSObject.Properties) {
        '{0}: {1}' -f $property.Name, (Get-FslGuiPropertyText -InputObject $Row -Name $property.Name)
    }
    return @{ Title = 'Selected row'; Message = (@($pairs) -join [System.Environment]::NewLine); Recommendation = ''; Source = ''; CanOpenSource = $false }
}

function Sync-FslGuiDetail {
    <#
    .SYNOPSIS
        Shows the selected row of a grid in the details panel ('Open Source' enabled only for https URLs).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter()]
        [AllowNull()]
        [object] $Grid
    )

    $row = $null
    # A selected row removed by a later run (Detached) has no data: reading it throws RowNotInTableException.
    if ($null -ne $Grid -and $Grid.SelectedItem -is [System.Data.DataRowView] -and
        $Grid.SelectedItem.Row.RowState -notin @([System.Data.DataRowState]::Detached, [System.Data.DataRowState]::Deleted)) {
        $row = ConvertFrom-FslGuiDataRow -Row $Grid.SelectedItem
    }
    $detail = Get-FslGuiDetailText -Row $row
    $controls = $State['Controls']
    $controls['TxtDetailTitle'].Text = [string]$detail['Title']
    $controls['TxtDetailMessage'].Text = [string]$detail['Message']
    $controls['TxtDetailRecommendation'].Text = [string]$detail['Recommendation']
    $controls['TxtDetailSource'].Text = [string]$detail['Source']
    $controls['BtnOpenSource'].IsEnabled = [bool]$detail['CanOpenSource']
}

function Sync-FslGuiActiveView {
    <#
    .SYNOPSIS
        Re-applies the filter bar and refreshes the details panel for the visible grid (after a tab change).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    Sync-FslGuiFilter -State $State
    $key = Get-FslGuiActiveViewKey -State $State
    $grid = $null
    if ($null -ne $key) { $grid = $State['Controls'][[string]$State['Views'][$key]['Definition']['Grid']] }
    Sync-FslGuiDetail -State $State -Grid $grid
}

function Open-FslGuiSource {
    <#
    .SYNOPSIS
        Opens the Source URL of the selected row with Start-Process, only when it is an absolute https URL.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $text = [string]$State['Controls']['TxtDetailSource'].Text
    if (-not (Test-FslGuiHttpsUrl -Text $text)) { return 'Only https sources can be opened.' }
    $uri = [System.Uri]::new($text.Trim())
    Start-Process -FilePath $uri.AbsoluteUri -ErrorAction Stop
    return "Opened $($uri.AbsoluteUri)"
}

function Open-FslGuiFolder {
    <#
    .SYNOPSIS
        Opens an existing folder with Invoke-Item. Returns a status text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Label
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return "$Label is not available yet: $Path"
    }
    Invoke-Item -LiteralPath $Path -ErrorAction Stop
    return "Opened $($Label): $Path"
}

function Sync-FslGuiMenuState {
    <#
    .SYNOPSIS
        Applies Get-FslGuiMenuState (enabled / checked) to the menu items and buttons.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $registered = $null
    if ($null -ne $State['DailyTask']) {
        $registeredText = Get-FslGuiPropertyText -InputObject $State['DailyTask'] -Name 'Registered'
        if ($registeredText -eq 'True') { $registered = $true } elseif ($registeredText -eq 'False') { $registered = $false }
    }
    $menuState = Get-FslGuiMenuState -Mode $State['Mode'] -IsBusy (Test-FslGuiBusy -State $State) -Offline ([bool]$State['Offline']) `
        -DebugLogging ([bool]$State['DebugLogging']) -AutoDiscover ([bool]$State['AutoDiscover']) -AutoHealthCheck ([bool]$State['AutoHealthCheck']) `
        -AutoRefreshMinutes ([int]$State['AutoRefreshMinutes']) -DailyRegistered $registered -IsElevated ([bool]$State['IsElevated'])
    $controls = $State['Controls']
    foreach ($name in $menuState.Keys) {
        if (-not $controls.ContainsKey($name)) { continue }
        $control = $controls[$name]
        $entry = $menuState[$name]
        if ($control.IsEnabled -ne [bool]$entry['IsEnabled']) { $control.IsEnabled = [bool]$entry['IsEnabled'] }
        if ($null -ne $entry['IsChecked'] -and $control.IsChecked -ne [bool]$entry['IsChecked']) { $control.IsChecked = [bool]$entry['IsChecked'] }
    }
    # The Repair menu explains WHY it is disabled (CONTRACT P3.7: point at File > Relaunch...).
    $tooltip = Get-FslGuiRepairMenuTooltip -IsElevated ([bool]$State['IsElevated']) -Account (Get-FslGuiCurrentAccountText)
    # Get-FslGuiRepairElevatedActionName returns its array as ONE pipeline object (unary comma): concatenate it, do
    # not wrap it in @(), or the loop would walk over the array object itself.
    foreach ($name in @('MnuRepairRoot') + (Get-FslGuiRepairElevatedActionName)) {
        if ($controls.ContainsKey($name)) { $controls[$name].ToolTip = $tooltip }
    }
    # The Open Source button also depends on the selected row.
    $controls['BtnOpenSource'].IsEnabled = (Test-FslGuiHttpsUrl -Text ([string]$controls['TxtDetailSource'].Text))
}

function Sync-FslGuiBusyView {
    <#
    .SYNOPSIS
        Shows or hides the progress indicator and Cancel button, updates the queue text and the menu enabled state.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $controls = $State['Controls']
    $runner = $State['Runner']
    $busy = Test-FslGuiBusy -State $State
    $visibility = if ($busy) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $controls['PrgBusy'].Visibility = $visibility
    $controls['BtnCancel'].Visibility = $visibility
    $text = ''
    if ($null -ne $runner['Current']) {
        $elapsed = 0
        if ($null -ne $runner['Current']['StartedAt']) { $elapsed = [int]([datetime]::Now - [datetime]$runner['Current']['StartedAt']).TotalSeconds }
        $verb = if ($runner['Cancelling']) { 'Cancelling' } else { 'Running' }
        $text = "${verb}: $($runner['Current']['Display']) ($elapsed s)"
    }
    elseif ($busy) {
        $text = 'Starting background session...'
    }
    if ($runner['Queue'].Count -gt 0) { $text += " - $($runner['Queue'].Count) queued" }
    $controls['TxtQueue'].Text = $text
    Sync-FslGuiMenuState -State $State
}

function Get-FslGuiDiscoverySummary {
    <#
    .SYNOPSIS
        Builds display texts from a FSLogixToolkit.Discovery object (Get-FslDiscovery). Missing values show as 'Unknown'.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Discovery
    )

    $unknown = 'Unknown'
    $pick = { param([object] $InputObject, [string] $Name) $text = Get-FslGuiPropertyText -InputObject $InputObject -Name $Name; if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text } }
    if ($null -eq $Discovery) {
        return @{ HasData = $false; DiscoveredAt = 'Not run yet'; Elevated = '-'; Os = $null; Fslogix = $null; Office = $null; Mode = '-'; Mismatch = $false; MismatchText = '' }
    }

    $image = $null; $fslogix = $null; $office = $null
    if ($null -ne $Discovery.PSObject.Properties['Image']) { $image = $Discovery.Image }
    if ($null -ne $Discovery.PSObject.Properties['FSLogix']) { $fslogix = $Discovery.FSLogix }
    if ($null -ne $Discovery.PSObject.Properties['Office']) { $office = $Discovery.Office }

    $osParts = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('OSCaption', 'WindowsVersionName')) { $value = & $pick $image $name; if ($value) { $osParts.Add($value) } }
    $build = & $pick $image 'FullBuild'
    if ($build) { $osParts.Add("build $build") }
    if ((& $pick $image 'IsMultiSession') -eq 'True') { $osParts.Add('multi-session') }
    $osText = if ($osParts.Count -gt 0) { $osParts -join ' ' } else { $unknown }

    $fslText = $unknown
    $installed = & $pick $fslogix 'IsInstalled'
    $fslVersion = & $pick $fslogix 'Version'
    if ($installed -eq 'False') { $fslText = 'Not installed' }
    elseif ($fslVersion) { $fslText = $fslVersion }
    elseif ($installed -eq 'True') { $fslText = 'Installed (version unknown)' }

    $officeText = $unknown
    $officeInstalled = & $pick $office 'Installed'
    $officeVersion = & $pick $office 'Version'
    $channel = & $pick $office 'UpdateChannelName'
    if ($officeVersion) { $officeText = $officeVersion }
    elseif ($officeInstalled -eq 'True') { $officeText = 'Installed (version not reported)' }
    elseif ($officeInstalled -eq 'False') { $officeText = 'Not installed' }
    if ($channel) { $officeText += " - $channel" }
    if ((& $pick $office 'SharedComputerActivation') -eq 'True') { $officeText += ' - shared computer activation' }

    $detected = & $pick $Discovery 'DetectedMode'
    $configured = & $pick $Discovery 'ConfiguredMode'
    $modeText = '{0} detected / {1} configured' -f $(if ($detected) { $detected } else { $unknown }), $(if ($configured) { $configured } else { $unknown })
    $mismatch = ((& $pick $Discovery 'ModeMismatch') -eq 'True')
    $mismatchText = if ($mismatch) { "Container mode mismatch: FSLogix on this image is configured for '$detected' but the toolkit mode is '$configured'. See the Mode section." } else { '' }

    $elevated = & $pick $Discovery 'IsElevated'
    return @{
        HasData      = $true
        DiscoveredAt = $(if (& $pick $Discovery 'DiscoveredAt') { & $pick $Discovery 'DiscoveredAt' } else { $unknown })
        Elevated     = $(if ($elevated -eq 'True') { 'Yes' } elseif ($elevated -eq 'False') { 'No' } else { $unknown })
        Os           = $osText
        Fslogix      = $fslText
        Office       = $officeText
        Mode         = $modeText
        Mismatch     = $mismatch
        MismatchText = $mismatchText
    }
}

function Sync-FslGuiDiscoveryPanel {
    <#
    .SYNOPSIS
        Fills the Discovery tab banner from the last Discovery object.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $summary = Get-FslGuiDiscoverySummary -Discovery $State['Discovery']
    $controls = $State['Controls']
    $controls['TxtDiscAt'].Text = [string]$summary['DiscoveredAt']
    $controls['TxtDiscElevated'].Text = [string]$summary['Elevated']
    $controls['TxtDiscImage'].Text = if ($summary['HasData']) { [string]$summary['Os'] } else { '-' }
    $controls['TxtDiscFslogix'].Text = if ($summary['HasData']) { [string]$summary['Fslogix'] } else { '-' }
    $controls['TxtDiscOffice'].Text = if ($summary['HasData']) { [string]$summary['Office'] } else { '-' }
    $controls['TxtDiscMode'].Text = [string]$summary['Mode']
    $controls['TxtDiscMismatch'].Text = [string]$summary['MismatchText']
}

function Sync-FslGuiBanner {
    <#
    .SYNOPSIS
        Updates the header banner: computer, OS, FSLogix, Microsoft 365 Apps, elevation, mode badge, last check, daily schedule.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $controls = $State['Controls']
    $summary = Get-FslGuiDiscoverySummary -Discovery $State['Discovery']
    $modeText = Get-FslGuiModeText -Mode $State['Mode']
    $controls['TxtBannerComputer'].Text = "Computer: $([System.Environment]::MachineName)"
    $osText = if ($summary['HasData']) { [string]$summary['Os'] } else { [string]$PSVersionTable.OS }
    $controls['TxtBannerOs'].Text = "OS: $osText"
    $controls['TxtBannerFslogix'].Text = if ($summary['HasData']) { "FSLogix: $($summary['Fslogix'])" } else { 'FSLogix: (discovery not run)' }
    $controls['TxtBannerOffice'].Text = if ($summary['HasData']) { "Microsoft 365 Apps: $($summary['Office'])" } else { 'Microsoft 365 Apps: (discovery not run)' }
    $controls['TxtBannerElevated'].Text = if ([bool]$State['IsElevated']) { 'Elevated: Yes' } else { 'Elevated: No' }
    # CONTRACT P3.2: show which account runs this window - the admin accounts on this image are separate accounts.
    $controls['TxtBannerAccount'].Text = 'Running as: ' + (Get-FslGuiCurrentAccountText)
    $controls['TxtModeBadge'].Text = [string]$modeText['Badge']
    $controls['TxtBannerLastCheck'].Text = if ($null -ne $State['LastCheck']) { 'Last check: ' + ([datetime]$State['LastCheck']).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } else { 'Last check: never' }
    $daily = Get-FslGuiDailyStateText -Task $State['DailyTask']
    $controls['TxtBannerDaily'].Text = [string]$daily['Banner']
    $notes = [System.Collections.Generic.List[string]]::new()
    if (-not [bool]$State['IsElevated']) { $notes.Add('Not elevated: some checks return Skipped and repairs are disabled (File > Relaunch...).') }
    if ($summary['Mismatch']) { $notes.Add('Container mode mismatch - see Discovery > Mode.') }
    if ([bool]$State['Offline']) { $notes.Add('Offline mode.') }
    if (Test-FslGuiRepairInProgress -State $State) { $notes.Add('Repair run in progress: this window cannot be closed.') }
    $controls['TxtBannerNote'].Text = $notes -join ' '
}

function Sync-FslGuiModeView {
    <#
    .SYNOPSIS
        Applies the container mode: window title, badge, Office/Profile tab off messages, menus.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $controls = $State['Controls']
    $modeText = Get-FslGuiModeText -Mode $State['Mode']
    $State['Window'].Title = [string]$modeText['Title']
    $controls['TxtModeBadge'].Text = [string]$modeText['Badge']
    $visible = [System.Windows.Visibility]::Visible
    $collapsed = [System.Windows.Visibility]::Collapsed

    $controls['TxtOfficeOff'].Text = [string]$modeText['OfficeOff']
    $controls['TxtOfficeOff'].Visibility = if ($modeText['OfficeEnabled']) { $collapsed } else { $visible }
    $controls['PnlOffice'].Visibility = if ($modeText['OfficeEnabled']) { $visible } else { $collapsed }

    $controls['TxtProfilesOff'].Text = [string]$modeText['ProfilesOff']
    $controls['PnlProfilesOff'].Visibility = if ($modeText['ProfilesEnabled']) { $collapsed } else { $visible }
    $controls['PnlProfiles'].Visibility = if ($modeText['ProfilesEnabled']) { $visible } else { $collapsed }

    $controls['TxtOverviewInfo'].Text = "Summary by Scope and Category. Container mode: $($modeText['Badge'])."
    Sync-FslGuiMenuState -State $State
}

function Sync-FslGuiErrorView {
    <#
    .SYNOPSIS
        Rebuilds the Errors grid (dashboard session, background session, background runner) and the log tail.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $local = @()
    try { $local = @(Get-FslErrorLog) } catch { Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Read dashboard error log' }
    $set = [ordered]@{
        'Dashboard session'  = $local
        'Background session' = $State['BackgroundErrors'].ToArray()
        'Background runner'  = $State['RunnerErrors'].ToArray()
    }
    Sync-FslGuiErrorTable -Table $State['Tables']['Errors'] -ErrorSet $set

    $paths = [System.Collections.Generic.List[string]]::new()
    $uiLog = [string]$script:FslSession['LogPath']
    if (-not [string]::IsNullOrWhiteSpace($uiLog)) { $paths.Add($uiLog) }
    $backgroundLog = [string]$State['BackgroundLogPath']
    if (-not [string]::IsNullOrWhiteSpace($backgroundLog) -and -not $paths.Contains($backgroundLog)) { $paths.Add($backgroundLog) }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($path in $paths) {
        [void]$builder.AppendLine("==== $path (last 200 lines) ====")
        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                foreach ($line in @(Get-Content -LiteralPath $path -Tail 200 -ErrorAction Stop)) { [void]$builder.AppendLine([string]$line) }
            }
            else { [void]$builder.AppendLine('(not created yet)') }
        }
        catch {
            [void]$builder.AppendLine("(unable to read: $($_.Exception.Message))")
        }
    }
    $controls = $State['Controls']
    $controls['TxtLogPath'].Text = if ($paths.Count -gt 0) { 'Log files: ' + ($paths -join ' | ') } else { 'No log file for this session.' }
    $controls['TxtLogTail'].Text = $builder.ToString()
}

function Export-FslGuiReport {
    <#
    .SYNOPSIS
        Exports the visible view (-CurrentView) or all results to CSV or HTML (SaveFileDialog + Export-FslReport).
    .DESCRIPTION
        Export-FslReport writes FSLogixToolkit_Report_<timestamp>.<ext> into the chosen folder; the file is then renamed
        to the file name chosen in the dialog. Returns a status text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [ValidateSet('Csv', 'Html')]
        [string] $Format,

        [Parameter()]
        [switch] $CurrentView
    )

    $objects = @()
    $title = 'FSLogixToolkit Health Report'
    if ($CurrentView) {
        $key = Get-FslGuiActiveViewKey -State $State
        if ($null -eq $key) { return 'The current tab has no exportable grid.' }
        $entry = $State['Views'][$key]
        $objects = @(Get-FslGuiViewObject -View $entry['View'] -AsResult:([bool]$entry['Definition']['IsResult']))
        $title = "FSLogixToolkit - $key"
    }
    else {
        $allView = [System.Data.DataView]::new($State['Tables']['Results'])
        try { $objects = @(Get-FslGuiViewObject -View $allView -AsResult) } finally { $allView.Dispose() }
        $title = "FSLogixToolkit Health Report ($((Get-FslGuiModeText -Mode $State['Mode'])['Badge']))"
    }
    if ($objects.Count -eq 0) { return 'No rows to export. Run checks first or clear the filter.' }

    $extension = $Format.ToLowerInvariant()
    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Title = "Export $Format"
    $dialog.FileName = 'FSLogixToolkit_{0}_{1}.{2}' -f $(if ($CurrentView) { 'View' } else { 'Report' }), (Get-Date -Format 'yyyyMMdd_HHmmss'), $extension
    $dialog.DefaultExt = ".$extension"
    $dialog.AddExtension = $true
    $dialog.OverwritePrompt = $true
    $dialog.Filter = if ($Format -eq 'Csv') { 'CSV files (*.csv)|*.csv' } else { 'HTML files (*.html)|*.html' }
    $reportRoot = [string]$State['ReportRoot']
    if (-not [string]::IsNullOrWhiteSpace($reportRoot) -and (Test-Path -LiteralPath $reportRoot -PathType Container)) {
        $dialog.InitialDirectory = $reportRoot
    }
    if ($dialog.ShowDialog($State['Window']) -ne $true) { return 'Export cancelled.' }

    $target = $dialog.FileName
    $folder = Split-Path -Path $target -Parent
    $files = @($objects | Export-FslReport -Format $Format -Path $folder -Title $title)
    if ($files.Count -eq 0) { return 'Export failed. See Errors & Log.' }
    $written = $files[0].FullName
    if ($written -ne $target) {
        try {
            Move-Item -LiteralPath $written -Destination $target -Force -ErrorAction Stop
            $written = $target
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'GUI' -Context "Rename exported report to '$target'"
        }
    }
    return "Exported $($objects.Count) row(s) to $written"
}

function Get-FslGuiAboutText {
    <#
    .SYNOPSIS
        Returns the Help > About text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $Mode
    )

    $version = 'unknown'
    $module = $ExecutionContext.SessionState.Module
    if ($null -ne $module) { $version = [string]$module.Version }
    $badge = (Get-FslGuiModeText -Mode $Mode)['Badge']
    $account = Get-FslGuiCurrentAccountText
    return @"
FSLogixToolkit $version - dashboard

Running as: $account
Container mode: $badge
Default mode is Office Containers (ODFC) only: profile container checks run only when the mode is Profile Containers only or Both (Options > Container Mode).

Checks run one at a time in a background PowerShell runspace so this window stays responsive. Some checks need an elevated session and return Skipped results for a standard user.

Repair menu (elevated only): preview first (Invoke-FslRepair -WhatIf), then apply the same selection. Every change records the state before it in an admin-only rollback store and can be reverted with Repair > Undo a Repair Run... Repair History and Open Repair Logs Folder stay available for a standard user. Use File > Relaunch Elevated (UAC)... or File > Relaunch as Different User (Smart Card)... to get an elevated session; Windows asks for the smart card and PIN, the toolkit never sees them.

Maintenance (container shrink or removal) is intentionally not available here. Review the reports first, then use Invoke-FslContainerShrink or Remove-FslStaleContainer from an elevated PowerShell session (both support -WhatIf).

Thresholds labelled 'Toolkit default' are toolkit defaults from Config/Settings.psd1, not Microsoft guidance.
"@
}

function Get-FslGuiUsageText {
    <#
    .SYNOPSIS
        Returns the Help > Command-line Usage text (CONTRACT P2.4 signatures).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return @'
Launcher (module folder):
  pwsh -File Start-FSLogixToolkit.ps1                           Dashboard (Windows)
  pwsh -File Start-FSLogixToolkit.ps1 -ContainerScope Both      Dashboard with Office and Profile container checks
  pwsh -File Start-FSLogixToolkit.ps1 -NoGui -ContainerScope ODFC -Offline
  pwsh -File Start-FSLogixToolkit.ps1 -Daily -ContainerScope ODFC   (exit code 0, or 2 when Fail/Error results)

Module commands:
  Show-FslDashboard [-ContainerScope ODFC|Profiles|Both] [-NoAutoRun]
  Invoke-FslHealthCheck -ContainerScope ODFC | Export-FslReport -Format Both
  Invoke-FslHealthCheck -Category Network -ContainerScope ODFC
  Get-FslDiscoveryReport -Discovery (Get-FslDiscovery)
  Get-FslContainerMode
  Set-FslPreference -Name ContainerMode -Value Both
  Register-FslDailyHealthCheck -At 06:00 -RunAs System -ContainerScope ODFC   (System requires elevation)
  Get-FslDailyHealthCheck
  Get-FslDailyHistory -Days 7
  Unregister-FslDailyHealthCheck
  Export-FslDiagnosticBundle

Repairs (elevated session; preview first, every change is recorded and can be undone):
  Get-FslRepairPlan -ContainerScope ODFC
  Get-FslRepairPlan | Test-FslRepairPrerequisite
  Invoke-FslRepair -ActionId FIX-SVC-01 -WhatIf
  Invoke-FslRepair -ActionId FIX-SVC-01 -ChangeReference 'CHG0012345'
  Undo-FslRepair -RunId <guid>
  Get-FslRepairLog -Days 7 -IncludeRecords

Run as another account (Windows asks for the smart card / PIN; the toolkit never sees it):
  pwsh -File Start-FSLogixToolkit.ps1 -RequestElevation
  pwsh -File Start-FSLogixToolkit.ps1 -RunAsDifferentUser -RunAsUserName DOMAIN\adminuser
'@
}
