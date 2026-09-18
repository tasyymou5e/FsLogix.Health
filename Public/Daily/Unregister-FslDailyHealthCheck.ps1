function Unregister-FslDailyHealthCheck {
    <#
    .SYNOPSIS
        Removes the FSLogixToolkit daily health check scheduled task.

    .DESCRIPTION
        Removes the task Daily.TaskName in Daily.TaskPath (Config/Settings.psd1) with
        Unregister-ScheduledTask -Confirm:$false inside this function's own ShouldProcess confirmation.
        Daily report folders are not touched. Returns one Result (Category Daily):
        Pass when removed, Info when no task is registered, Skipped on non-Windows or when access is denied
        (RequiresElevation), Error otherwise.

    .EXAMPLE
        Unregister-FslDailyHealthCheck -WhatIf

    .EXAMPLE
        Unregister-FslDailyHealthCheck -Confirm:$false

    .OUTPUTS
        FSLogixToolkit.Result

    .NOTES
        RequiresElevation: Depends on the task principal (a task registered as SYSTEM needs an elevated session; access denied -> Skipped).
        Sources:
          https://learn.microsoft.com/powershell/module/scheduledtasks/unregister-scheduledtask
          https://learn.microsoft.com/powershell/module/scheduledtasks/get-scheduledtask
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param()

    $check = 'Unregister daily health check'
    $source = 'https://learn.microsoft.com/powershell/module/scheduledtasks/unregister-scheduledtask'
    $config = Get-FslDailyConfig
    $taskName = [string]$config['TaskName']
    $taskPath = [string]$config['TaskPath']
    $target = "$taskPath$taskName"

    if (-not (Test-FslIsWindows)) {
        New-FslResult -Category 'Daily' -Check $check -Status 'Skipped' -Target $target `
            -Message 'Scheduled tasks (ScheduledTasks module) are only available on Windows.' -Recommendation 'Run on the Windows session host.' -Source $source
        return
    }
    if ($null -eq (Get-Command -Name 'Unregister-ScheduledTask' -ErrorAction SilentlyContinue) -or
        $null -eq (Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue)) {
        New-FslResult -Category 'Daily' -Check $check -Status 'Error' -Target $target `
            -Message 'The ScheduledTasks module commands are not available in this session.' `
            -Recommendation 'Run on Windows 10 1809+ / Windows Server 1809+ where the ScheduledTasks module is present.' `
            -Source 'https://learn.microsoft.com/powershell/windows/module-compatibility'
        return
    }

    $existing = $null
    try {
        $existing = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context "Get scheduled task $target"
    }
    if ($null -eq $existing) {
        New-FslResult -Category 'Daily' -Check $check -Status 'Info' -Target $target -Value 'NotRegistered' `
            -Message 'No daily health check task is registered; nothing to remove.' -Source $source
        return
    }

    if (-not $PSCmdlet.ShouldProcess($target, 'Unregister scheduled task')) { return }

    try {
        Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
        Write-FslLog -Message "Daily: unregistered task $target" -Level Info -Component 'Daily'
        New-FslResult -Category 'Daily' -Check $check -Status 'Pass' -Target $target -Value 'Removed' `
            -Message 'The daily health check task was removed. Daily report folders were kept.' -Source $source
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context "Unregister scheduled task $target"
        if (Test-FslDailyAccessDenied -ErrorRecord $_) {
            New-FslResult -Category 'Daily' -Check $check -Status 'Skipped' -Target $target `
                -Message "Access denied while removing the scheduled task: $($_.Exception.Message)" `
                -Recommendation 'Run PowerShell as administrator and try again.' -Source $source -RequiresElevation $true
        }
        else {
            New-FslResult -Category 'Daily' -Check $check -Status 'Error' -Target $target `
                -Message "Removing the scheduled task failed: $($_.Exception.Message)" -Recommendation 'Review the error log (Get-FslErrorLog).' -Source $source
        }
    }
}
