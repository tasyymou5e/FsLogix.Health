function Get-FslErrorLog {
    <#
    .SYNOPSIS
        Returns the errors collected in the current toolkit session.
    .DESCRIPTION
        Outputs the error objects recorded by the toolkit (Timestamp, Component, Context, Message,
        ExceptionType, CategoryInfo, TargetObject, ScriptStackTrace, InvocationLine), oldest first.
        Secrets are redacted when errors are recorded.
    .EXAMPLE
        Get-FslErrorLog | Format-Table -Property Timestamp, Component, Context, Message

        Lists the errors captured during this session.
    .NOTES
        RequiresElevation: No
        Sources: Toolkit default (no external facts).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if ($null -eq $script:FslSession -or $null -eq $script:FslSession['Errors']) { return }
    foreach ($entry in @($script:FslSession['Errors'])) {
        $entry
    }
}
