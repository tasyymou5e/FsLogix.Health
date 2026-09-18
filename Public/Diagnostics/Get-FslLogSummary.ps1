function Get-FslLogSummary {
    <#
    .SYNOPSIS
        Summarizes errors and warnings from FSLogix text log files and FSLogix event logs.
    .DESCRIPTION
        Scans FSLogix text log files (*.log under Logging\LogDir, default %ProgramData%\FSLogix\Logs) modified
        within -Days for lines carrying the documented [ERROR:xxxxxx] and [WARN:xxxxxx] prefixes, and reads
        Critical/Error/Warning events (Level 1,2,3) from the FSLogix event logs. Emits one Result per log file
        with matches, one per event log, and a text-log summary. Messages are grouped and the most frequent
        (max 20) are listed. Log content is kept as written by FSLogix (it can include user names); Azure storage
        secrets are redacted.
    .PARAMETER Days
        Only log files modified and events created within this many days are analysed. Toolkit default: Settings.psd1 Diagnostics.LogDays.
    .PARAMETER MaxEvents
        Maximum number of events read per event log. Toolkit default: Settings.psd1 Diagnostics.MaxEvents.
    .PARAMETER Scope
        Container scopes to include: Profiles, ODFC (default both). Text log files would be mapped to a scope by their
        subfolder under the log folder only when Microsoft Learn documents that the subfolder is limited to one
        container type. The Profile subfolder (Logs\Profile\Profile_%date%.log) is documented as the most common log
        for troubleshooting, not as profile-container-only, so it is General and always included (also with
        -Scope ODFC). No ODFC or Cloud Cache subfolder name is documented, so all text log files are General.
        Event log results and summaries are General.
    .EXAMPLE
        Get-FslLogSummary -Days 3 | Where-Object Status -ne 'Pass'
    .EXAMPLE
        Get-FslLogSummary -Scope ODFC
    .NOTES
        RequiresElevation: No for text logs. Event logs that deny access return a Skipped result with RequiresElevation = true.
        Sources:
          https://learn.microsoft.com/en-us/fslogix/troubleshooting-events-logs-diagnostics (log folder C:\ProgramData\FSLogix\Logs, Profile\Profile_%date%.log, [INFO]/[WARN:xxxxxx]/[ERROR:xxxxxx] prefixes, event logs under Applications and Services Logs > FSLogix: Apps and CloudCache Admin/Operational)
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings (Logging: LogDir default %ProgramData%\FSLogix\Logs)
          https://learn.microsoft.com/en-us/fslogix/troubleshooting-vhd-disk-compaction (log path C:\ProgramData\FSLogix\Logs\Profile\Profile-yyyyMMdd.log)
          https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues (event log name Microsoft-FSLogix-Apps/Operational)
          https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-winevent (FilterHashtable LogName/StartTime/Level, -ListLog wildcards, -MaxEvents)
          https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.eventing.reader.standardeventlevel (Critical=1, Error=2, Warning=3)
          https://github.com/PowerShell/PowerShell/blob/master/src/Microsoft.PowerShell.Commands.Diagnostics/GetEventCommand.cs (non-terminating error ids NoMatchingEventsFound, NoMatchingLogsFound, LogInfoUnavailable)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateRange(1, 365)]
        [int] $Days,

        [Parameter()]
        [ValidateRange(1, 100000)]
        [int] $MaxEvents,

        [Parameter()]
        [ValidateSet('Profiles', 'ODFC')]
        [string[]] $Scope = @('Profiles', 'ODFC')
    )

    $category = 'Diagnostics'
    $sourceLogs = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-events-logs-diagnostics'
    $sourceGetWinEvent = 'https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-winevent'

    try {
        $config = Get-FslConfig -Section 'Diagnostics'
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component $category -Context 'Loading Diagnostics settings'
        $config = @{}
    }
    if (-not $PSBoundParameters.ContainsKey('Days')) {
        $Days = if ($config -and $config['LogDays']) { [int]$config['LogDays'] } else { 7 }
    }
    if (-not $PSBoundParameters.ContainsKey('MaxEvents')) {
        $MaxEvents = if ($config -and $config['MaxEvents']) { [int]$config['MaxEvents'] } else { 500 }
    }

    if (-not (Test-FslIsWindows)) {
        New-FslResult -Category $category -Check 'FSLogix log summary' -Status 'Skipped' -Target 'Local computer' `
            -Message 'FSLogix logs and event logs are only available on Windows.' -Source $sourceLogs -Scope 'General'
        return
    }

    $startTime = (Get-Date).AddDays(-$Days)
    Write-FslLog -Message "Summarizing FSLogix logs since $($startTime.ToString('s')) (MaxEvents $MaxEvents)." -Level Info -Component $category

    # ---- Text log files ----
    try {
        $logDir = Get-FslDiagLogDirectory
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
            New-FslResult -Category $category -Check 'FSLogix text logs' -Status 'Info' -Target $logDir `
                -Message 'FSLogix log folder not found. Logging may be disabled (Logging\LoggingEnabled) or FSLogix is not installed.' `
                -Source $sourceLogs -Scope 'General'
        }
        else {
            $allowedLogScopes = @('General') + @($Scope)
            $files = @(Get-ChildItem -LiteralPath $logDir -Filter '*.log' -File -Recurse -ErrorAction SilentlyContinue -ErrorVariable listErrors |
                    Where-Object -FilterScript { $_.LastWriteTime -ge $startTime } |
                    Where-Object -FilterScript { (Get-FslDiagLogFileScope -FilePath $_.FullName -LogDirectory $logDir) -in $allowedLogScopes } |
                    Sort-Object -Property LastWriteTime -Descending)
            foreach ($listError in @($listErrors)) {
                if ($null -ne $listError) { Add-FslError -ErrorRecord $listError -Component $category -Context "Listing $logDir" }
            }

            $totalErrors = 0
            $totalWarnings = 0
            foreach ($file in $files) {
                $fileScope = ConvertTo-FslDiagResultScope -Scope (Get-FslDiagLogFileScope -FilePath $file.FullName -LogDirectory $logDir)
                try {
                    $summary = Get-FslDiagLogFileSummary -File $file -SampleSize 20
                    $totalErrors += $summary.ErrorCount
                    $totalWarnings += $summary.WarningCount
                    if (($summary.ErrorCount + $summary.WarningCount) -gt 0) {
                        New-FslResult -Category $category -Check 'FSLogix text log' -Status 'Warn' -Target $file.FullName `
                            -Value ('Errors={0}; Warnings={1}' -f $summary.ErrorCount, $summary.WarningCount) -Expected 'Errors=0; Warnings=0' `
                            -Message ('Most frequent: ' + ($summary.TopMessages -join ' | ')) `
                            -Recommendation 'Review the log around the listed messages; WARN and ERROR entries carry an error code.' `
                            -Source $sourceLogs -Scope $fileScope
                    }
                }
                catch [System.UnauthorizedAccessException] {
                    Add-FslError -ErrorRecord $_ -Component $category -Context "Reading $($file.FullName)"
                    New-FslResult -Category $category -Check 'FSLogix text log' -Status 'Skipped' -Target $file.FullName `
                        -Message 'Access denied reading the log file.' -Recommendation 'Run the toolkit elevated.' `
                        -Source $sourceLogs -RequiresElevation $true -Scope $fileScope
                }
                catch {
                    Add-FslError -ErrorRecord $_ -Component $category -Context "Reading $($file.FullName)"
                    New-FslResult -Category $category -Check 'FSLogix text log' -Status 'Error' -Target $file.FullName `
                        -Message $_.Exception.Message -Source $sourceLogs -Scope $fileScope
                }
            }

            $status = if (($totalErrors + $totalWarnings) -gt 0) { 'Warn' } elseif ($files.Count -eq 0) { 'Info' } else { 'Pass' }
            New-FslResult -Category $category -Check 'FSLogix text logs summary' -Status $status -Target $logDir `
                -Value ('Files={0}; Errors={1}; Warnings={2}' -f $files.Count, $totalErrors, $totalWarnings) `
                -Message ("{0} log file(s) modified in the last {1} day(s) scanned for [ERROR:] and [WARN:] entries (scope(s) {2} plus General; the Profile subfolder is General and always included)." -f $files.Count, $Days, ($Scope -join ', ')) `
                -Source $sourceLogs -Scope 'General'
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component $category -Context 'Scanning FSLogix text logs'
        New-FslResult -Category $category -Check 'FSLogix text logs summary' -Status 'Error' -Message $_.Exception.Message -Source $sourceLogs -Scope 'General'
    }

    # ---- Event logs ----
    $logNames = [System.Collections.Generic.List[string]]::new()
    $logNames.Add($script:FslDiagVerifiedEventLog)
    try {
        $listed = @(Get-WinEvent -ListLog $script:FslDiagEventLogPattern -ErrorAction SilentlyContinue -ErrorVariable listLogErrors)
        foreach ($log in $listed) {
            if ($null -ne $log -and -not $logNames.Contains([string]$log.LogName)) { $logNames.Add([string]$log.LogName) }
        }
        foreach ($listLogError in @($listLogErrors)) {
            if ($null -ne $listLogError -and $listLogError.FullyQualifiedErrorId -notlike 'NoMatchingLogsFound*') {
                Add-FslError -ErrorRecord $listLogError -Component $category -Context 'Enumerating FSLogix event logs'
            }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component $category -Context 'Enumerating FSLogix event logs'
    }

    foreach ($logName in $logNames) {
        try {
            $filter = @{ LogName = $logName; StartTime = $startTime; Level = @(1, 2, 3) }
            $readErrors = $null
            $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction SilentlyContinue -ErrorVariable readErrors)

            $noEvents = $false
            $notFound = $false
            $denied = $false
            foreach ($readError in @($readErrors)) {
                if ($null -eq $readError) { continue }
                $errorId = [string]$readError.FullyQualifiedErrorId
                if ($errorId -like 'NoMatchingEventsFound*') { $noEvents = $true }
                elseif ($errorId -like 'NoMatchingLogsFound*') { $notFound = $true }
                elseif ($errorId -like 'LogInfoUnavailable*' -or $errorId -like 'LogInfoNoAccess*' -or
                    $readError.Exception -is [System.UnauthorizedAccessException] -or
                    $readError.Exception.InnerException -is [System.UnauthorizedAccessException]) { $denied = $true }
                else { Add-FslError -ErrorRecord $readError -Component $category -Context "Reading event log $logName" }
            }

            if ($denied -and $events.Count -eq 0) {
                New-FslResult -Category $category -Check 'FSLogix event log' -Status 'Skipped' -Target $logName `
                    -Message 'Access to the event log was denied.' -Recommendation 'Run the toolkit elevated to read this event log.' `
                    -Source $sourceGetWinEvent -RequiresElevation $true -Scope 'General'
                continue
            }
            if ($notFound -and $events.Count -eq 0) {
                New-FslResult -Category $category -Check 'FSLogix event log' -Status 'Info' -Target $logName `
                    -Message 'Event log not present on this computer (FSLogix may not be installed).' -Source $sourceLogs -Scope 'General'
                continue
            }
            if ($events.Count -eq 0) {
                $message = if ($noEvents) { "No critical, error or warning events in the last $Days day(s)." } else { 'No events returned.' }
                New-FslResult -Category $category -Check 'FSLogix event log' -Status 'Pass' -Target $logName `
                    -Value 'Critical=0; Error=0; Warning=0' -Message $message -Source $sourceLogs -Scope 'General'
                continue
            }

            $critical = @($events | Where-Object -FilterScript { $_.Level -eq 1 }).Count
            $errorsFound = @($events | Where-Object -FilterScript { $_.Level -eq 2 }).Count
            $warnings = @($events | Where-Object -FilterScript { $_.Level -eq 3 }).Count
            $top = @($events | ForEach-Object -Process {
                    $text = [string]$_.Message
                    if ([string]::IsNullOrWhiteSpace($text)) { $text = '(no message)' }
                    $firstLine = ($text -split '\r?\n')[0].Trim()
                    if ($firstLine.Length -gt 300) { $firstLine = $firstLine.Substring(0, 300) }
                    'Id {0}: {1}' -f $_.Id, (ConvertTo-FslDiagRedactedText -Text $firstLine)
                } | Group-Object -NoElement | Sort-Object -Property Count -Descending | Select-Object -First 20 |
                ForEach-Object -Process { '{0}x {1}' -f $_.Count, $_.Name })

            $status = if (($critical + $errorsFound) -gt 0) { 'Warn' } else { 'Info' }
            $capNote = if ($events.Count -ge $MaxEvents) { " Result capped at MaxEvents ($MaxEvents)." } else { '' }
            New-FslResult -Category $category -Check 'FSLogix event log' -Status $status -Target $logName `
                -Value ('Critical={0}; Error={1}; Warning={2}' -f $critical, $errorsFound, $warnings) -Expected 'Critical=0; Error=0' `
                -Message ("Most frequent in the last {0} day(s):{1} {2}" -f $Days, $capNote, ($top -join ' | ')) `
                -Recommendation 'Review the listed event IDs; check Get-FslKnownIssue for documented expected errors (for example Event ID 26 on Entra-only joined devices).' `
                -Source $sourceLogs -Scope 'General'
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $category -Context "Reading event log $logName"
            New-FslResult -Category $category -Check 'FSLogix event log' -Status 'Error' -Target $logName -Message $_.Exception.Message -Source $sourceGetWinEvent -Scope 'General'
        }
    }
}
