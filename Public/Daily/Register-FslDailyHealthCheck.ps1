function Register-FslDailyHealthCheck {
    <#
    .SYNOPSIS
        Registers a Windows scheduled task that runs the FSLogixToolkit daily health check.

    .DESCRIPTION
        Creates (or with -Force replaces) the scheduled task Daily.TaskName in Daily.TaskPath (Config/Settings.psd1)
        using the ScheduledTasks module (natively compatible with PowerShell 7 on Windows 10 1809+ / Server 1809+):
          Action    New-ScheduledTaskAction -Execute <current pwsh executable> -Argument
                    '-NoProfile -NonInteractive -File "<ModuleRoot>\Start-FSLogixToolkit.ps1" -Daily -ContainerScope <mode>
                     -OutputPath "<ReportRoot>" [-Offline]' -WorkingDirectory <ModuleRoot>
          Trigger   New-ScheduledTaskTrigger -Daily -At <HH:mm>
          Principal System:      New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                    CurrentUser: New-ScheduledTaskPrincipal -UserId <DOMAIN\user> -LogonType Interactive -RunLevel Limited
                    (Interactive = the task runs only while that user is logged on; no password is stored.)
          Settings  New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
                    -ExecutionTimeLimit 02:00:00 (toolkit default)
        The pwsh path is [Environment]::ProcessPath when the current process is pwsh.exe, otherwise $PSHOME\pwsh.exe.
        ReportRoot is the session ReportRoot (Initialize-FslSession -ReportRoot to choose it) and is passed explicitly
        so the SYSTEM task and the interactive user use the same daily history. No -ExecutionPolicy argument is added.
        If module script files carry a Zone.Identifier stream (downloaded files), a Warn Result recommends Unblock-File.
        Returns Result objects (Category Daily). On non-Windows a Skipped Result is returned. RunAs System requires
        elevation (Skipped with RequiresElevation when not elevated). For CurrentUser an access-denied failure is
        returned as Skipped with RequiresElevation.

    .PARAMETER At
        Daily start time HH:mm (24h). Default: Daily.Time (toolkit default 06:00).

    .PARAMETER ContainerScope
        Container mode for the daily run: ODFC, Profiles or Both. Default: Get-FslContainerMode.

    .PARAMETER RunAs
        System (default from Daily.RunAs; requires elevation) or CurrentUser.

    .PARAMETER Offline
        Adds -Offline to the scheduled command (no online lookups).

    .PARAMETER Force
        Replaces an existing task with the same name and path (Register-ScheduledTask -Force).

    .EXAMPLE
        Register-FslDailyHealthCheck -At 06:30 -RunAs System

        Registers the daily check (container mode from preferences, ODFC by default) to run as SYSTEM at 06:30.

    .EXAMPLE
        Register-FslDailyHealthCheck -RunAs CurrentUser -ContainerScope ODFC -Offline -Force -WhatIf

    .OUTPUTS
        FSLogixToolkit.Result

    .NOTES
        RequiresElevation: Yes for RunAs System; CurrentUser is attempted without elevation (access denied -> Skipped).
        Sources:
          https://learn.microsoft.com/powershell/module/scheduledtasks/register-scheduledtask
          https://learn.microsoft.com/powershell/module/scheduledtasks/new-scheduledtaskaction
          https://learn.microsoft.com/powershell/module/scheduledtasks/new-scheduledtasktrigger
          https://learn.microsoft.com/powershell/module/scheduledtasks/new-scheduledtaskprincipal
          https://learn.microsoft.com/powershell/module/scheduledtasks/new-scheduledtasksettingsset
          https://learn.microsoft.com/powershell/module/scheduledtasks/get-scheduledtask
          https://learn.microsoft.com/windows/win32/taskschd/principal-logontype
          https://learn.microsoft.com/powershell/windows/module-compatibility
          https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_pwsh
          https://learn.microsoft.com/cpp/c-language/parsing-c-command-line-arguments
          https://learn.microsoft.com/powershell/module/microsoft.powershell.management/get-item
          https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/unblock-file
          https://learn.microsoft.com/dotnet/api/system.environment.processpath
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
        [string] $At,

        [Parameter()]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $ContainerScope,

        [Parameter()]
        [ValidateSet('System', 'CurrentUser')]
        [string] $RunAs,

        [Parameter()]
        [switch] $Offline,

        [Parameter()]
        [switch] $Force
    )

    $check = 'Register daily health check'
    $source = 'https://learn.microsoft.com/powershell/module/scheduledtasks/register-scheduledtask'
    $config = Get-FslDailyConfig
    if (-not $PSBoundParameters.ContainsKey('At')) { $At = [string]$config['Time'] }
    if (-not $PSBoundParameters.ContainsKey('RunAs')) { $RunAs = [string]$config['RunAs'] }
    $taskName = [string]$config['TaskName']
    $taskPath = [string]$config['TaskPath']
    $target = "$taskPath$taskName"

    if (-not (Test-FslIsWindows)) {
        $message = 'Scheduled tasks (ScheduledTasks module) are only available on Windows.'
        Write-FslLog -Message "Daily: $message" -Level Warning -Component 'Daily'
        New-FslResult -Category 'Daily' -Check $check -Status 'Skipped' -Target $target -Message $message `
            -Recommendation 'Run Register-FslDailyHealthCheck on the Windows session host.' -Source $source -RequiresElevation ($RunAs -eq 'System')
        return
    }

    $mode = 'ODFC'
    try {
        $mode = if ($PSBoundParameters.ContainsKey('ContainerScope')) { $ContainerScope } else { [string](Get-FslContainerMode) }
        if ($mode -notin @('ODFC', 'Profiles', 'Both')) { $mode = 'ODFC' }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Resolve container mode for daily task'
    }

    $required = @('Register-ScheduledTask', 'New-ScheduledTaskAction', 'New-ScheduledTaskTrigger', 'New-ScheduledTaskPrincipal', 'New-ScheduledTaskSettingsSet', 'Get-ScheduledTask')
    $missing = @($required | Where-Object -FilterScript { $null -eq (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        New-FslResult -Category 'Daily' -Check $check -Status 'Error' -Target $target -Value ($missing -join ', ') `
            -Message 'The ScheduledTasks module commands are not available in this session.' `
            -Recommendation 'Run on Windows 10 1809+ / Windows Server 1809+ where the ScheduledTasks module is present.' `
            -Source 'https://learn.microsoft.com/powershell/windows/module-compatibility'
        return
    }

    if ($RunAs -eq 'System' -and -not (Assert-FslElevation -Operation 'Register daily health check task as SYSTEM')) {
        New-FslResult -Category 'Daily' -Check $check -Status 'Skipped' -Target $target -Value 'System' `
            -Message 'Registering a scheduled task that runs as SYSTEM requires an elevated PowerShell session.' `
            -Recommendation 'Run PowerShell as administrator, or use -RunAs CurrentUser.' -Source $source -RequiresElevation $true
        return
    }

    # Paths
    try {
        $reportRoot = Resolve-FslDailyReportRoot
        $moduleRoot = [string]$script:FslSession['ModuleRoot']
        $scriptPath = Join-Path -Path $moduleRoot -ChildPath 'Start-FSLogixToolkit.ps1'
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Launcher script not found: $scriptPath" }
        $pwshPath = Get-FslDailyPwshPath
        $argumentText = New-FslDailyTaskArgument -ScriptPath $scriptPath -ContainerScope $mode -ReportRoot $reportRoot -Offline:$Offline
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Build daily task command line'
        New-FslResult -Category 'Daily' -Check $check -Status 'Error' -Target $target -Message "Unable to build the task command line: $($_.Exception.Message)" `
            -Recommendation 'Verify the module files and the session ReportRoot (Initialize-FslSession).' -Source 'Toolkit default'
        return
    }

    # Downloaded module files (Zone.Identifier) may be blocked by the execution policy for the task.
    try {
        $blocked = @(Find-FslDailyBlockedFile -ModuleRoot $moduleRoot)
        if ($blocked.Count -gt 0) {
            New-FslResult -Category 'Daily' -Check 'Daily task: module files blocked' -Status 'Warn' -Target $moduleRoot -Value "$($blocked.Count) file(s)" `
                -Message "Module files carry a Zone.Identifier stream (downloaded from the internet), e.g. $($blocked[0]). Under the RemoteSigned execution policy the scheduled run can fail to load them." `
                -Recommendation "Review the files, then run: Get-ChildItem -LiteralPath '$moduleRoot' -Recurse -File | Unblock-File" `
                -Source 'https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/unblock-file'
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Check module files for Zone.Identifier'
    }

    try {
        $existing = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    }
    catch {
        $existing = $null
    }
    if ($null -ne $existing -and -not $Force) {
        New-FslResult -Category 'Daily' -Check $check -Status 'Info' -Target $target -Value 'AlreadyRegistered' `
            -Message 'The daily health check task is already registered; nothing was changed.' `
            -Recommendation 'Use -Force to replace it, or Unregister-FslDailyHealthCheck to remove it.' -Source $source
        return
    }

    $description = "FSLogixToolkit daily read-only health check (container mode $mode). Reports: $reportRoot"
    if (-not $PSCmdlet.ShouldProcess($target, "Register scheduled task ($RunAs, daily at $At): $pwshPath $argumentText")) {
        return
    }

    try {
        $atTime = [datetime]::ParseExact($At, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        $action = New-ScheduledTaskAction -Execute $pwshPath -Argument $argumentText -WorkingDirectory $moduleRoot -ErrorAction Stop
        $trigger = New-ScheduledTaskTrigger -Daily -At $atTime -ErrorAction Stop
        if ($RunAs -eq 'System') {
            $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest -ErrorAction Stop
        }
        else {
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            try { $userId = $identity.Name } finally { $identity.Dispose() }
            $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited -ErrorAction Stop
        }
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::FromHours(2)) -ErrorAction Stop

        $registerParams = @{
            TaskName    = $taskName
            TaskPath    = $taskPath
            Action      = $action
            Trigger     = $trigger
            Principal   = $principal
            Settings    = $settings
            Description = $description
            ErrorAction = 'Stop'
        }
        if ($Force) { $registerParams['Force'] = $true }
        $null = Register-ScheduledTask @registerParams
        Write-FslLog -Message "Daily: registered task $target ($RunAs, $At): $pwshPath $argumentText" -Level Info -Component 'Daily'
        New-FslResult -Category 'Daily' -Check $check -Status 'Pass' -Target $target -Value "$pwshPath $argumentText" `
            -Expected "Daily at $At as $RunAs" -Message "Scheduled task registered: runs daily at $At as $RunAs for container mode $mode. Reports: $reportRoot" `
            -Recommendation 'View results with Get-FslDailyHistory.' -Source $source -RequiresElevation ($RunAs -eq 'System')
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context "Register scheduled task $target"
        if (Test-FslDailyAccessDenied -ErrorRecord $_) {
            New-FslResult -Category 'Daily' -Check $check -Status 'Skipped' -Target $target -Value $RunAs `
                -Message "Access denied while registering the scheduled task: $($_.Exception.Message)" `
                -Recommendation 'Run PowerShell as administrator and try again.' -Source $source -RequiresElevation $true
        }
        else {
            New-FslResult -Category 'Daily' -Check $check -Status 'Error' -Target $target -Value $RunAs `
                -Message "Registering the scheduled task failed: $($_.Exception.Message)" `
                -Recommendation 'Review the error log (Get-FslErrorLog).' -Source $source -RequiresElevation ($RunAs -eq 'System')
        }
    }
}
