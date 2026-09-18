function Invoke-FslDailyHealthCheck {
    <#
    .SYNOPSIS
        Runs the daily health check for the container mode, writes reports and a JSON summary, and prunes old day folders.

    .DESCRIPTION
        1. Initializes the session with -ReportRoot when given (Initialize-FslSession -ReportRoot).
        2. Runs Invoke-FslHealthCheck -ContainerScope <mode> [-Offline] (mode default: Get-FslContainerMode,
           ODFC unless changed - no Profiles-scope work runs in ODFC mode).
        3. Writes into <ReportRoot>/<Daily.FolderName>/<yyyy-MM-dd>/:
           - the report (Export-FslReport, format Daily.Formats),
           - Summary_<HHmmss>.json with Date, Time, Timestamp, ComputerName, ContainerScope, DurationSeconds,
             ToolkitVersion, Counts by Status, ScopeCounts (Scope x Status), Issues (Fail/Error/Warn checks),
             NewIssues (compared with the most recent previous summary, keyed by Category|Check|Target|Scope;
             when no previous summary exists every issue is new and BaselineSummaryPath is null), report paths,
           - the error log (Export-FslErrorLog) when errors were recorded in this session.
        4. Removes day folders (only folders named yyyy-MM-dd directly under the Daily folder) older than
           Daily.RetainDays (toolkit default 30; 0 disables pruning).
        Returns the summary object (also the content of the JSON file). Errors are recorded, not thrown.

    .PARAMETER ContainerScope
        Container mode: ODFC (Office containers only), Profiles or Both. Default: Get-FslContainerMode.

    .PARAMETER Offline
        No online lookups (passed to Invoke-FslHealthCheck).

    .PARAMETER ReportRoot
        Report root folder. Default: the session ReportRoot (Initialize-FslSession).

    .EXAMPLE
        Invoke-FslDailyHealthCheck

        Runs the daily check for the configured mode (ODFC by default) into the session report folder.

    .EXAMPLE
        Invoke-FslDailyHealthCheck -ContainerScope Both -Offline -ReportRoot 'D:\FslToolkit\Reports'

    .OUTPUTS
        FSLogixToolkit.DailySummary

    .NOTES
        RequiresElevation: No (individual checks return Skipped results when elevation is required)
        Retention days, folder name and formats: Toolkit default (Config/Settings.psd1 Daily section).
        Sources:
          https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertto-json
          https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertfrom-json
          https://learn.microsoft.com/dotnet/api/system.datetime.tryparseexact
          https://learn.microsoft.com/powershell/module/microsoft.powershell.management/remove-item
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $ContainerScope,

        [Parameter()]
        [switch] $Offline,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ReportRoot
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $started = Get-Date

    try {
        $root = Resolve-FslDailyReportRoot -ReportRoot $ReportRoot -Initialize
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Resolve report root for daily health check'
        return
    }

    $mode = 'ODFC'
    try {
        $mode = if ($PSBoundParameters.ContainsKey('ContainerScope')) { $ContainerScope } else { [string](Get-FslContainerMode) }
        if ($mode -notin @('ODFC', 'Profiles', 'Both')) { $mode = 'ODFC' }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Resolve container mode for daily health check'
    }

    $config = Get-FslDailyConfig
    $dailyRoot = Join-Path -Path $root -ChildPath ([string]$config['FolderName'])
    $dateText = $started.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $timeText = $started.ToString('HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $dayFolder = Join-Path -Path $dailyRoot -ChildPath $dateText
    try {
        if (-not (Test-Path -LiteralPath $dayFolder -PathType Container)) {
            $null = New-Item -Path $dayFolder -ItemType Directory -Force -ErrorAction Stop
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context "Create daily folder '$dayFolder'"
        return
    }
    Write-FslLog -Message "Daily health check started: mode $mode, folder $dayFolder" -Level Info -Component 'Daily'

    # Baseline = most recent previous summary (read before this run writes its own).
    $baseline = $null
    $baselinePath = $null
    try {
        foreach ($file in @(Get-FslDailySummaryFile -DailyRoot $dailyRoot)) {
            $candidate = Read-FslDailySummary -Path $file.FullName
            if ($null -ne $candidate) {
                $baseline = $candidate
                $baselinePath = $file.FullName
                break
            }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Find previous daily summary'
    }

    # Health check
    $results = @()
    try {
        $healthParams = @{ ContainerScope = $mode }
        if ($Offline) { $healthParams['Offline'] = $true }
        $results = @(Invoke-FslHealthCheck @healthParams)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Invoke-FslHealthCheck (daily)'
    }

    # Reports
    $htmlReport = $null
    $csvReport = $null
    if ($results.Count -gt 0) {
        try {
            $title = "FSLogixToolkit Daily Health Check - $mode - $dateText"
            $files = @($results | Export-FslReport -Format ([string]$config['Formats']) -Path $dayFolder -Title $title)
            foreach ($file in $files) {
                if ($file.Extension -eq '.html') { $htmlReport = $file.FullName }
                elseif ($file.Extension -eq '.csv') { $csvReport = $file.FullName }
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Export daily report'
        }
    }

    # Counts
    $statuses = @('Pass', 'Warn', 'Fail', 'Error', 'Info', 'Skipped')
    $scopeNames = @('General', 'ODFC', 'Profiles')
    $counts = [ordered]@{}
    foreach ($status in $statuses) { $counts[$status] = 0 }
    $scopeCounts = [ordered]@{}
    foreach ($scopeName in $scopeNames) {
        $scopeCounts[$scopeName] = [ordered]@{}
        foreach ($status in $statuses) { $scopeCounts[$scopeName][$status] = 0 }
    }
    $issues = [System.Collections.Generic.List[object]]::new()
    foreach ($result in $results) {
        $status = [string](Get-FslDailyJsonValue -InputObject $result -Name 'Status')
        $scope = [string](Get-FslDailyJsonValue -InputObject $result -Name 'Scope')
        if ([string]::IsNullOrWhiteSpace($scope)) { $scope = 'General' }
        if ($counts.Contains($status)) { $counts[$status]++ }
        if (-not $scopeCounts.Contains($scope)) {
            $scopeCounts[$scope] = [ordered]@{}
            foreach ($name in $statuses) { $scopeCounts[$scope][$name] = 0 }
        }
        if ($scopeCounts[$scope].Contains($status)) { $scopeCounts[$scope][$status]++ }
        if ($status -in @('Fail', 'Error', 'Warn')) {
            $issues.Add([pscustomobject][ordered]@{
                    Key      = Get-FslDailyIssueKey -InputObject $result
                    Category = [string](Get-FslDailyJsonValue -InputObject $result -Name 'Category')
                    Check    = [string](Get-FslDailyJsonValue -InputObject $result -Name 'Check')
                    Target   = [string](Get-FslDailyJsonValue -InputObject $result -Name 'Target')
                    Scope    = $scope
                    Status   = $status
                    Message  = [string](Get-FslDailyJsonValue -InputObject $result -Name 'Message')
                })
        }
    }

    # New issues vs baseline
    $baselineKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $baseline) {
        foreach ($previous in @(Get-FslDailyJsonValue -InputObject $baseline -Name 'Issues')) {
            if ($null -eq $previous) { continue }
            $previousKey = Get-FslDailyJsonValue -InputObject $previous -Name 'Key'
            if ([string]::IsNullOrEmpty([string]$previousKey)) { $previousKey = Get-FslDailyIssueKey -InputObject $previous }
            [void]$baselineKeys.Add([string]$previousKey)
        }
    }
    $newIssues = @($issues | Where-Object -FilterScript { -not $baselineKeys.Contains($_.Key) })

    # Error log export (when errors exist)
    $errorLogFiles = @()
    try {
        if (@(Get-FslErrorLog).Count -gt 0) {
            $errorLogFiles = @(Export-FslErrorLog -Path $dayFolder | ForEach-Object -Process { $_.FullName })
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Export error log (daily)'
    }

    $summaryPath = Join-Path -Path $dayFolder -ChildPath "Summary_$timeText.json"
    $suffix = 2
    while (Test-Path -LiteralPath $summaryPath) {
        $summaryPath = Join-Path -Path $dayFolder -ChildPath ("Summary_{0}_{1}.json" -f $timeText, $suffix)
        $suffix++
    }

    $stopwatch.Stop()
    $summary = [ordered]@{
        Date                = $dateText
        Time                = $started.ToString('HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        Timestamp           = $started.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        ComputerName        = [System.Environment]::MachineName
        ContainerScope      = $mode
        Offline             = [bool]$Offline
        DurationSeconds     = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        ToolkitVersion      = Get-FslDailyToolkitVersion
        ResultCount         = $results.Count
        Counts              = $counts
        ScopeCounts         = $scopeCounts
        Issues              = @($issues.ToArray())
        NewIssueCount       = $newIssues.Count
        NewIssues           = $newIssues
        BaselineSummaryPath = $baselinePath
        HtmlReport          = $htmlReport
        CsvReport           = $csvReport
        ErrorLog            = $errorLogFiles
        DailyFolder         = $dayFolder
        SummaryPath         = $summaryPath
        PrunedFolders       = @()
    }

    try {
        $json = ConvertTo-Json -InputObject $summary -Depth 6
        [System.IO.File]::WriteAllText($summaryPath, $json, [System.Text.UTF8Encoding]::new($false))
        Write-FslLog -Message "Daily summary written: $summaryPath (Fail=$($counts['Fail']), Error=$($counts['Error']), Warn=$($counts['Warn']), New issues=$($newIssues.Count))" -Level Info -Component 'Daily'
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context "Write daily summary '$summaryPath'"
    }

    try {
        $summary['PrunedFolders'] = @(Remove-FslDailyExpiredFolder -DailyRoot $dailyRoot -RetainDays ([int]$config['RetainDays']) -Confirm:$false)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Prune daily folders'
    }

    $output = [pscustomobject]$summary
    $output.PSObject.TypeNames.Insert(0, 'FSLogixToolkit.DailySummary')
    return $output
}
