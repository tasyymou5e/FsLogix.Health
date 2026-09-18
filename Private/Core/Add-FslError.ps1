function Add-FslError {
    <#
    .SYNOPSIS
        Records an ErrorRecord in the session error collection and logs it at Error level.
    .DESCRIPTION
        Appends an object (Timestamp, Component, Context, Message, ExceptionType, CategoryInfo,
        TargetObject, ScriptStackTrace, InvocationLine) to $script:FslSession.Errors. Secrets are redacted.
        Never throws.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord,

        [ValidateNotNullOrEmpty()]
        [string] $Component = 'Core',

        [AllowEmptyString()]
        [AllowNull()]
        [string] $Context
    )

    try {
        $exception = $ErrorRecord.Exception
        $message = if ($null -ne $exception) { $exception.Message } else { [string]$ErrorRecord }
        $exceptionType = if ($null -ne $exception) { $exception.GetType().FullName } else { $null }

        $categoryInfo = $null
        try { if ($null -ne $ErrorRecord.CategoryInfo) { $categoryInfo = $ErrorRecord.CategoryInfo.ToString() } } catch { $null = $_ }

        $target = $null
        try { if ($null -ne $ErrorRecord.TargetObject) { $target = [string]$ErrorRecord.TargetObject } } catch { $null = $_ }

        $invocationLine = $null
        try { if ($null -ne $ErrorRecord.InvocationInfo) { $invocationLine = $ErrorRecord.InvocationInfo.Line } } catch { $null = $_ }
        if ($null -ne $invocationLine) { $invocationLine = $invocationLine.Trim() }

        $entry = [pscustomobject]@{
            Timestamp        = (Get-Date).ToString('o')
            Component        = $Component
            Context          = ConvertTo-FslCoreRedactedText -Text $Context
            Message          = ConvertTo-FslCoreRedactedText -Text $message
            ExceptionType    = $exceptionType
            CategoryInfo     = $categoryInfo
            TargetObject     = ConvertTo-FslCoreRedactedText -Text $target
            ScriptStackTrace = $ErrorRecord.ScriptStackTrace
            InvocationLine   = ConvertTo-FslCoreRedactedText -Text $invocationLine
        }

        if ($null -ne $script:FslSession -and $null -ne $script:FslSession['Errors']) {
            $script:FslSession['Errors'].Add($entry)
        }

        $logMessage = if ([string]::IsNullOrEmpty($Context)) { $message } else { "$Context - $message" }
        Write-FslLog -Message $logMessage -Level Error -Component $Component
    }
    catch {
        try { Write-Verbose -Message "Add-FslError failed: $($_.Exception.Message)" } catch { $null = $_ }
    }
}
