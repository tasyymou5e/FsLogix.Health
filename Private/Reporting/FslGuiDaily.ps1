# Private helpers for Show-FslDashboard: Daily Health tab and the schedule dialog (GUI/ScheduleDialog.xaml).
# Daily commands are called only through the CONTRACT P2.4 signatures: Get-FslDailyHealthCheck, Get-FslDailyHistory,
# Invoke-FslDailyHealthCheck, Register-FslDailyHealthCheck (-At -ContainerScope -RunAs -Offline -Force) and
# Unregister-FslDailyHealthCheck; they run in the background runspace (see FslGuiRunner.ps1).
# Sources:
#   https://learn.microsoft.com/dotnet/api/system.windows.window.dialogresult (IsDefault / IsCancel behavior)
#   https://learn.microsoft.com/dotnet/api/system.windows.window.showdialog
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.management/invoke-item

function Get-FslGuiDailyStateText {
    <#
    .SYNOPSIS
        Builds display texts from a Get-FslDailyHealthCheck object (Registered, State, At, RunAs, ContainerScope,
        NextRunTime, LastRunTime, LastTaskResult). $null input means unknown.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Task
    )

    $read = { param([string] $Name) $text = Get-FslGuiPropertyText -InputObject $Task -Name $Name; if ([string]::IsNullOrWhiteSpace($text)) { '-' } else { $text } }
    if ($null -eq $Task) {
        return @{ IsRegistered = $null; Registered = 'Unknown'; State = '-'; At = '-'; Scope = '-'; Next = '-'; Last = '-'; Banner = 'Daily: unknown' }
    }
    $registeredText = Get-FslGuiPropertyText -InputObject $Task -Name 'Registered'
    if ($registeredText -ne 'True') {
        $isRegistered = if ($registeredText -eq 'False') { $false } else { $null }
        $label = if ($registeredText -eq 'False') { 'No' } else { 'Unknown' }
        $banner = if ($registeredText -eq 'False') { 'Daily: not scheduled' } else { 'Daily: unknown' }
        return @{ IsRegistered = $isRegistered; Registered = $label; State = '-'; At = '-'; Scope = '-'; Next = '-'; Last = '-'; Banner = $banner }
    }
    return @{
        IsRegistered = $true
        Registered   = 'Yes'
        State        = (& $read 'State')
        At           = '{0} as {1}' -f (& $read 'At'), (& $read 'RunAs')
        Scope        = (& $read 'ContainerScope')
        Next         = (& $read 'NextRunTime')
        Last         = '{0} (result {1})' -f (& $read 'LastRunTime'), (& $read 'LastTaskResult')
        Banner       = 'Daily: {0} {1} ({2})' -f (& $read 'At'), (& $read 'ContainerScope'), (& $read 'State')
    }
}

function Get-FslGuiDailyReportRoot {
    <#
    .SYNOPSIS
        Returns the report root used for daily reports: the registered task output folder (DailyReportRoot, set from
        Get-FslDailyHealthCheck) when known, otherwise the dashboard ReportRoot.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    if ($State.ContainsKey('DailyReportRoot') -and -not [string]::IsNullOrWhiteSpace([string]$State['DailyReportRoot'])) {
        return [string]$State['DailyReportRoot']
    }
    return [string]$State['ReportRoot']
}

function Get-FslGuiDailyFolder {
    <#
    .SYNOPSIS
        Returns <daily report root>/<Daily.FolderName> (Config/Settings.psd1, toolkit default 'Daily').
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $reportRoot = Get-FslGuiDailyReportRoot -State $State
    if ([string]::IsNullOrWhiteSpace($reportRoot)) { return $null }
    $folderName = 'Daily'
    $daily = Get-FslConfig -Section 'Daily'
    if ($daily.ContainsKey('FolderName') -and -not [string]::IsNullOrWhiteSpace([string]$daily['FolderName'])) { $folderName = [string]$daily['FolderName'] }
    return (Join-Path -Path $reportRoot -ChildPath $folderName)
}

function Sync-FslGuiDailyView {
    <#
    .SYNOPSIS
        Fills the Daily Health state panel from the last Get-FslDailyHealthCheck object.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $text = Get-FslGuiDailyStateText -Task $State['DailyTask']
    $controls = $State['Controls']
    $controls['TxtDailyRegistered'].Text = [string]$text['Registered']
    $controls['TxtDailyState'].Text = [string]$text['State']
    $controls['TxtDailyAt'].Text = [string]$text['At']
    $controls['TxtDailyScope'].Text = [string]$text['Scope']
    $controls['TxtDailyNext'].Text = [string]$text['Next']
    $controls['TxtDailyLast'].Text = [string]$text['Last']
    $controls['TxtDailyNote'].Text = "History rows: $($State['Tables']['Daily'].Rows.Count). Double-click a history row to open its HTML report. Reports folder: $(Get-FslGuiDailyFolder -State $State)"
}

function Resolve-FslGuiDailyReportPath {
    <#
    .SYNOPSIS
        Returns the HTML report path of a daily history row when the file exists under the report root; otherwise $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Path,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ReportRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($ReportRoot)) { return $null }
    if (-not (Test-FslGuiPathUnderRoot -Path $Path -Root $ReportRoot)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return [System.IO.Path]::GetFullPath($Path)
}

function Open-FslGuiDailyReport {
    <#
    .SYNOPSIS
        Opens the HTML report of the selected daily history row with Invoke-Item (only an existing file under ReportRoot).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $selected = $State['Controls']['GridDailyHistory'].SelectedItem
    if ($selected -isnot [System.Data.DataRowView]) { return 'Select a daily history row first.' }
    $htmlPath = [string]$selected.Row['HtmlReport']
    $resolved = Resolve-FslGuiDailyReportPath -Path $htmlPath -ReportRoot (Get-FslGuiDailyReportRoot -State $State)
    if ($null -eq $resolved) {
        return "No HTML report to open for this row (missing, or not under the report folder): $htmlPath"
    }
    Invoke-Item -LiteralPath $resolved -ErrorAction Stop
    return "Opened daily report: $resolved"
}

function Resolve-FslGuiScheduleRequest {
    <#
    .SYNOPSIS
        Decides how a schedule request proceeds: 'Register', or 'NeedsElevation' when RunAs System is requested from a
        session that is not elevated (CONTRACT P2.4: System requires elevation).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('System', 'CurrentUser')]
        [string] $RunAs,

        [Parameter(Mandatory)]
        [bool] $IsElevated
    )

    if ($RunAs -eq 'System' -and -not $IsElevated) { return 'NeedsElevation' }
    return 'Register'
}

function Get-FslGuiDailyOutputText {
    <#
    .SYNOPSIS
        Summarizes Register/Unregister output (Result objects or other objects) as text. Returns @{ Text; NeedsAttention }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Output
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $attention = $false
    foreach ($item in $Output) {
        if ($null -eq $item) { continue }
        $status = Get-FslGuiPropertyText -InputObject $item -Name 'Status'
        if ($status) {
            if ($status -notin @('Pass', 'Info')) { $attention = $true }
            $line = '[{0}] {1}' -f $status, (Get-FslGuiPropertyText -InputObject $item -Name 'Message')
            $recommendation = Get-FslGuiPropertyText -InputObject $item -Name 'Recommendation'
            if ($recommendation) { $line += " $recommendation" }
            $lines.Add($line)
        }
        else {
            $lines.Add([string]$item)
        }
    }
    if ($lines.Count -eq 0) { $lines.Add('No output was returned.') }
    return @{ Text = ($lines -join [System.Environment]::NewLine); NeedsAttention = $attention }
}

function Confirm-FslGuiScheduleDialog {
    <#
    .SYNOPSIS
        Click handler body for the schedule dialog OK button: validates HH:mm and closes the dialog with DialogResult $true.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $state = $script:FslGuiState
    if ($null -eq $state -or $null -eq $state['ScheduleDialog']) { return }
    $dialog = $state['ScheduleDialog']
    $timeText = ([string]$dialog['Controls']['TxtScheduleTime'].Text).Trim()
    if (-not (Test-FslGuiTimeText -Text $timeText)) {
        $dialog['Controls']['TxtScheduleError'].Text = 'Enter the time as HH:mm (24-hour), for example 06:00.'
        return
    }
    if ($dialog['Controls']['RdoRunAsSystem'].IsChecked -ne $true -and $dialog['Controls']['RdoRunAsCurrentUser'].IsChecked -ne $true) {
        $dialog['Controls']['TxtScheduleError'].Text = 'Select System or Current user.'
        return
    }
    $dialog['Window'].DialogResult = $true
}

function Show-FslGuiScheduleDialog {
    <#
    .SYNOPSIS
        Shows GUI/ScheduleDialog.xaml. Returns @{ At; RunAs; ContainerScope; Offline; Force } or $null when cancelled.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $path = Join-Path -Path ([string]$State['ModuleRoot']) -ChildPath 'GUI/ScheduleDialog.xaml'
    $window = Import-FslGuiXaml -Path $path
    $connected = Connect-FslGuiControl -Root $window -Name (Get-FslGuiScheduleControlName)
    if ($connected['Missing'].Count -gt 0) {
        throw [System.InvalidOperationException]::new("GUI/ScheduleDialog.xaml is missing control(s): $($connected['Missing'] -join ', ')")
    }
    $controls = $connected['Controls']

    # Defaults: existing task values, then Config/Settings.psd1 Daily section, then the current mode.
    $daily = Get-FslConfig -Section 'Daily'
    $time = if ($daily.ContainsKey('Time')) { [string]$daily['Time'] } else { '06:00' }
    $runAs = if ($daily.ContainsKey('RunAs') -and [string]$daily['RunAs'] -in @('System', 'CurrentUser')) { [string]$daily['RunAs'] } else { 'System' }
    $mode = [string]$State['Mode']
    $registered = $false
    if ($null -ne $State['DailyTask'] -and (Get-FslGuiPropertyText -InputObject $State['DailyTask'] -Name 'Registered') -eq 'True') {
        $registered = $true
        $taskAt = Get-FslGuiPropertyText -InputObject $State['DailyTask'] -Name 'At'
        if (Test-FslGuiTimeText -Text $taskAt) { $time = $taskAt }
        $taskRunAs = Get-FslGuiPropertyText -InputObject $State['DailyTask'] -Name 'RunAs'
        if ($taskRunAs -in @('System', 'CurrentUser')) { $runAs = $taskRunAs }
    }
    $controls['TxtScheduleTime'].Text = $time
    $controls['RdoRunAsSystem'].IsChecked = ($runAs -eq 'System')
    $controls['RdoRunAsCurrentUser'].IsChecked = ($runAs -eq 'CurrentUser')
    $modeItem = switch ($mode) { 'Profiles' { 'CmbScheduleModeProfiles' } 'Both' { 'CmbScheduleModeBoth' } default { 'CmbScheduleModeOdfc' } }
    $controls['CmbScheduleMode'].SelectedItem = $controls[$modeItem]
    $controls['ChkScheduleOffline'].IsChecked = [bool]$State['Offline']
    $controls['ChkScheduleReplace'].IsChecked = $registered
    $elevationText = 'Registering the task to run as System requires an elevated (Run as administrator) PowerShell session.'
    if ([bool]$State['IsElevated']) { $elevationText += ' This session is elevated.' } else { $elevationText += ' This session is NOT elevated: choose Current user, or restart the toolkit elevated.' }
    $controls['TxtScheduleElevation'].Text = $elevationText
    $controls['TxtScheduleError'].Text = ''

    $State['ScheduleDialog'] = @{ Window = $window; Controls = $controls }
    try {
        $controls['BtnScheduleOk'].Add_Click({
                try { Confirm-FslGuiScheduleDialog }
                catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Schedule dialog OK' }
            })
        $window.Owner = $State['Window']
        $accepted = $window.ShowDialog()
    }
    finally {
        $State['ScheduleDialog'] = $null
    }
    if ($accepted -ne $true) { return $null }

    $selectedMode = 'ODFC'
    $modeSelection = $controls['CmbScheduleMode'].SelectedItem
    if ($null -ne $modeSelection -and [string]$modeSelection.Tag -in @('ODFC', 'Profiles', 'Both')) { $selectedMode = [string]$modeSelection.Tag }
    return @{
        At             = ([string]$controls['TxtScheduleTime'].Text).Trim()
        RunAs          = $(if ($controls['RdoRunAsSystem'].IsChecked -eq $true) { 'System' } else { 'CurrentUser' })
        ContainerScope = $selectedMode
        Offline        = ($controls['ChkScheduleOffline'].IsChecked -eq $true)
        Force          = ($controls['ChkScheduleReplace'].IsChecked -eq $true)
    }
}

function Invoke-FslGuiScheduleAction {
    <#
    .SYNOPSIS
        Schedule Daily Check...: dialog, elevation check (offers CurrentUser when System is not possible), then queues
        Register-FslDailyHealthCheck in the background.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $request = Show-FslGuiScheduleDialog -State $State
    if ($null -eq $request) { return 'Schedule cancelled.' }

    $decision = Resolve-FslGuiScheduleRequest -RunAs $request['RunAs'] -IsElevated ([bool]$State['IsElevated'])
    if ($decision -eq 'NeedsElevation') {
        $text = "Registering the daily health check to run as System requires an elevated PowerShell session, and this session is not elevated.`r`n`r`nRegister it for the current user (CurrentUser) instead?`r`n`r`nChoose No to cancel; you can restart the toolkit with 'Run as administrator' to register it as System."
        $answer = Show-FslGuiMessage -State $State -Text $text -Caption 'Schedule Daily Health Check' -Button 'YesNo' -Icon 'Warning'
        if ($answer -ne 'Yes') { return 'Schedule not registered: System requires elevation.' }
        $request['RunAs'] = 'CurrentUser'
    }

    $operation = Get-FslGuiOperation -Name 'DailyRegister' -Display "Register daily check ($($request['At']), $($request['RunAs']), $($request['ContainerScope']))" -Parameter @{
        At             = [string]$request['At']
        RunAs          = [string]$request['RunAs']
        ContainerScope = [string]$request['ContainerScope']
        Offline        = [bool]$request['Offline']
        Force          = [bool]$request['Force']
    }
    Invoke-FslGuiWork -State $State -Operation @($operation) -Tab 'TabDaily'
    return "Registering the daily health check at $($request['At']) as $($request['RunAs'])..."
}

function Invoke-FslGuiRemoveScheduleAction {
    <#
    .SYNOPSIS
        Remove Daily Schedule: confirmation, then queues Unregister-FslDailyHealthCheck in the background.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $answer = Show-FslGuiMessage -State $State -Text "Remove the FSLogixToolkit daily health check scheduled task?`r`n`r`nExisting daily reports are kept." -Caption 'Remove Daily Schedule' -Button 'YesNo' -Icon 'Warning'
    if ($answer -ne 'Yes') { return 'Remove cancelled.' }
    Invoke-FslGuiWork -State $State -Operation @(Get-FslGuiOperation -Name 'DailyUnregister' -Display 'Remove daily schedule') -Tab 'TabDaily'
    return 'Removing the daily schedule...'
}
