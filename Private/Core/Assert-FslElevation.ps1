function Assert-FslElevation {
    <#
    .SYNOPSIS
        Returns $true when the session is elevated; otherwise logs a Warning and returns $false.
    .DESCRIPTION
        Callers use the return value to emit Skipped results. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Operation
    )

    try {
        if (Test-FslElevation) { return $true }

        $user = [Environment]::UserName
        if (Test-FslIsWindows) { $user = '{0}\{1}' -f [Environment]::UserDomainName, [Environment]::UserName }
        Write-FslLog -Message "Operation $Operation requires elevation - skipped (running as $user)" -Level Warning -Component 'Core'
        return $false
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Assert-FslElevation ($Operation)"
        return $false
    }
}
