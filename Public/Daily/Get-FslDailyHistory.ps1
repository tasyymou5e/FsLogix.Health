function Get-FslDailyHistory {
    <#
    .SYNOPSIS
        Returns the daily health check history from the Summary_*.json files, newest first.

    .DESCRIPTION
        Reads <ReportRoot>/<Daily.FolderName>/<yyyy-MM-dd>/Summary_*.json written by Invoke-FslDailyHealthCheck
        and returns one object per run: Date, Time, ContainerScope, Pass, Warn, Fail, Error, Info, Skipped,
        NewIssueCount, HtmlReport, CsvReport, SummaryPath (newest first). Unreadable summary files are skipped
        and recorded in the error log. Only day folders named yyyy-MM-dd are read.

    .PARAMETER Days
        Number of days to include, counting back from today (today included). Default: Daily.RetainDays
        (toolkit default 30).

    .PARAMETER ReportRoot
        Report root folder. Default: the session ReportRoot (Initialize-FslSession).

    .EXAMPLE
        Get-FslDailyHistory -Days 7 | Format-Table Date, Time, ContainerScope, Fail, Warn, NewIssueCount

    .EXAMPLE
        Get-FslDailyHistory -ReportRoot 'D:\FslToolkit\Reports'

    .OUTPUTS
        FSLogixToolkit.DailyHistory

    .NOTES
        RequiresElevation: No (the SYSTEM task writes to the ReportRoot passed on its command line)
        Sources:
          https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertfrom-json
          https://learn.microsoft.com/powershell/module/microsoft.powershell.management/get-childitem
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateRange(1, 3650)]
        [int] $Days,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ReportRoot
    )

    try {
        $root = Resolve-FslDailyReportRoot -ReportRoot $ReportRoot
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Resolve report root for daily history'
        return
    }

    $config = Get-FslDailyConfig
    if (-not $PSBoundParameters.ContainsKey('Days')) {
        $Days = if ([int]$config['RetainDays'] -gt 0) { [int]$config['RetainDays'] } else { 30 }
    }
    $since = (Get-Date).Date.AddDays( - ($Days - 1))
    $dailyRoot = Join-Path -Path $root -ChildPath ([string]$config['FolderName'])

    try {
        $files = @(Get-FslDailySummaryFile -DailyRoot $dailyRoot -Since $since)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context "List daily summaries under '$dailyRoot'"
        return
    }

    foreach ($file in $files) {
        $summary = Read-FslDailySummary -Path $file.FullName
        if ($null -eq $summary) { continue }

        $dateValue = Get-FslDailyJsonValue -InputObject $summary -Name 'Date'
        $timeValue = Get-FslDailyJsonValue -InputObject $summary -Name 'Time'
        # ConvertFrom-Json may convert date-like strings to DateTime; normalize back to the written format.
        $dateText = if ($dateValue -is [datetime]) { $dateValue.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$dateValue }
        $timeText = if ($timeValue -is [datetime]) { $timeValue.ToString('HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } elseif ($timeValue -is [timespan]) { $timeValue.ToString('hh\:mm\:ss') } else { [string]$timeValue }

        $row = [ordered]@{
            Date           = $dateText
            Time           = $timeText
            ContainerScope = [string](Get-FslDailyJsonValue -InputObject $summary -Name 'ContainerScope')
        }
        foreach ($status in @('Pass', 'Warn', 'Fail', 'Error', 'Info', 'Skipped')) {
            $value = Get-FslDailyJsonValue -InputObject $summary -Name 'Counts', $status
            $row[$status] = if ($null -eq $value) { 0 } else { [int]$value }
        }
        $newIssueCount = Get-FslDailyJsonValue -InputObject $summary -Name 'NewIssueCount'
        $row['NewIssueCount'] = if ($null -eq $newIssueCount) { 0 } else { [int]$newIssueCount }
        $row['HtmlReport'] = Get-FslDailyJsonValue -InputObject $summary -Name 'HtmlReport'
        $row['CsvReport'] = Get-FslDailyJsonValue -InputObject $summary -Name 'CsvReport'
        $row['SummaryPath'] = $file.FullName

        $output = [pscustomobject]$row
        $output.PSObject.TypeNames.Insert(0, 'FSLogixToolkit.DailyHistory')
        $output
    }
}
