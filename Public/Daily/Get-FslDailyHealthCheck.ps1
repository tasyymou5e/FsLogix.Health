function Get-FslDailyHealthCheck {
    <#
    .SYNOPSIS
        Returns the registration state of the FSLogixToolkit daily health check scheduled task.

    .DESCRIPTION
        Looks up Daily.TaskName in Daily.TaskPath (Config/Settings.psd1) with Get-ScheduledTask (State),
        Export-ScheduledTask (task XML: Actions/Exec/Command and Arguments, Principals/Principal/UserId,
        Triggers/CalendarTrigger/StartBoundary) and Get-ScheduledTaskInfo (LastRunTime, NextRunTime, LastTaskResult).
        ContainerScope, ReportRoot and Offline are parsed from the registered arguments
        (-ContainerScope, -OutputPath, -Offline) using the Windows command-line argument rules.
        Returns an object with Registered, State, At, RunAs, ContainerScope, NextRunTime, LastRunTime,
        LastTaskResult, Arguments, ReportRoot, Offline, Execute, UserId, TaskName, TaskPath, Message.
        When no task is registered (or on non-Windows) Registered is $false. Never throws.

    .EXAMPLE
        Get-FslDailyHealthCheck

    .EXAMPLE
        Get-FslDailyHistory -ReportRoot (Get-FslDailyHealthCheck).ReportRoot -Days 7

        Shows the last 7 days of history from the folder the scheduled task writes to.

    .OUTPUTS
        FSLogixToolkit.DailyTask

    .NOTES
        RequiresElevation: No (reading a task may be denied for tasks the user cannot read; reported in Message).
        Sources:
          https://learn.microsoft.com/powershell/module/scheduledtasks/get-scheduledtask
          https://learn.microsoft.com/powershell/module/scheduledtasks/export-scheduledtask
          https://learn.microsoft.com/powershell/module/scheduledtasks/get-scheduledtaskinfo
          https://learn.microsoft.com/windows/win32/taskschd/daily-trigger-example--xml-
          https://learn.microsoft.com/windows/win32/taskschd/registeredtask-lastruntime
          https://learn.microsoft.com/windows/win32/taskschd/registeredtask-lasttaskresult
          https://learn.microsoft.com/windows-server/identity/ad-ds/manage/understand-security-identifiers (S-1-5-18 Local System)
          https://learn.microsoft.com/cpp/c-language/parsing-c-command-line-arguments
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $config = Get-FslDailyConfig
    $info = [ordered]@{
        Registered     = $false
        State          = $null
        At             = $null
        RunAs          = $null
        ContainerScope = $null
        NextRunTime    = $null
        LastRunTime    = $null
        LastTaskResult = $null
        Arguments      = $null
        ReportRoot     = $null
        Offline        = $null
        Execute        = $null
        UserId         = $null
        TaskName       = [string]$config['TaskName']
        TaskPath       = [string]$config['TaskPath']
        Message        = $null
    }
    $emit = {
        $output = [pscustomobject]$info
        $output.PSObject.TypeNames.Insert(0, 'FSLogixToolkit.DailyTask')
        $output
    }

    if (-not (Test-FslIsWindows)) {
        $info['Message'] = 'Scheduled tasks are only available on Windows.'
        return (& $emit)
    }
    if ($null -eq (Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue)) {
        $info['Message'] = 'The ScheduledTasks module is not available in this session.'
        return (& $emit)
    }

    $task = $null
    try {
        $task = Get-ScheduledTask -TaskName $info['TaskName'] -TaskPath $info['TaskPath'] -ErrorAction SilentlyContinue
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Get-ScheduledTask (daily task)'
    }
    if ($null -eq $task) {
        $info['Message'] = 'The daily health check task is not registered.'
        return (& $emit)
    }

    $info['Registered'] = $true
    $stateProperty = $task.PSObject.Properties['State']
    if ($null -ne $stateProperty -and $null -ne $stateProperty.Value) { $info['State'] = [string]$stateProperty.Value }

    try {
        $xml = [string](Export-ScheduledTask -TaskName $info['TaskName'] -TaskPath $info['TaskPath'] -ErrorAction Stop)
        $definition = Get-FslDailyTaskDefinition -Xml $xml
        $info['Execute'] = $definition.Command
        $info['Arguments'] = $definition.Arguments
        $info['UserId'] = $definition.UserId
        if (-not [string]::IsNullOrWhiteSpace($definition.UserId)) {
            $info['RunAs'] = if ($definition.UserId -in @('S-1-5-18', 'NT AUTHORITY\SYSTEM', 'SYSTEM')) { 'System' } else { 'CurrentUser' }
        }
        if (-not [string]::IsNullOrWhiteSpace($definition.StartBoundary)) {
            $start = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse($definition.StartBoundary, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$start)) {
                $info['At'] = $start.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            }
            elseif ($definition.StartBoundary -match 'T(\d{2}:\d{2})') {
                $info['At'] = $Matches[1]
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($definition.Arguments)) {
            $parsed = ConvertFrom-FslDailyTaskArgument -ArgumentString $definition.Arguments
            $info['ContainerScope'] = $parsed.ContainerScope
            $info['ReportRoot'] = $parsed.ReportRoot
            $info['Offline'] = [bool]$parsed.Offline
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Export-ScheduledTask (daily task)'
        $info['Message'] = "Task definition could not be read: $($_.Exception.Message)"
    }

    try {
        if ($null -ne (Get-Command -Name 'Get-ScheduledTaskInfo' -ErrorAction SilentlyContinue)) {
            $runInfo = Get-ScheduledTaskInfo -TaskName $info['TaskName'] -TaskPath $info['TaskPath'] -ErrorAction Stop
            foreach ($name in @('LastRunTime', 'NextRunTime', 'LastTaskResult')) {
                $property = $runInfo.PSObject.Properties[$name]
                if ($null -ne $property) { $info[$name] = $property.Value }
            }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Get-ScheduledTaskInfo (daily task)'
        if ($null -eq $info['Message']) { $info['Message'] = "Run information could not be read: $($_.Exception.Message)" }
    }

    return (& $emit)
}
