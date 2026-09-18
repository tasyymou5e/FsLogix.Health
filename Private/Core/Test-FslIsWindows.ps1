function Test-FslIsWindows {
    <#
    .SYNOPSIS
        Returns $true when running on Windows.
    .NOTES
        Source: https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_automatic_variables
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # $IsWindows is an automatic variable in PowerShell 6.0 and later.
    return [bool]$IsWindows
}
