function Test-FslElevation {
    <#
    .SYNOPSIS
        Tests whether the current PowerShell session is running elevated (local Administrators role).
    .DESCRIPTION
        On Windows, returns WindowsPrincipal.IsInRole(WindowsBuiltInRole.Administrator) for the current
        Windows identity. Under UAC, a member of Administrators running a non-elevated session gets $false.
        On non-Windows platforms always returns $false. Never throws.
    .EXAMPLE
        Test-FslElevation

        Returns $true when PowerShell was started with "Run as administrator".
    .NOTES
        RequiresElevation: No
        Sources:
          https://learn.microsoft.com/dotnet/api/system.security.principal.windowsprincipal.isinrole
          https://learn.microsoft.com/dotnet/api/system.security.principal.windowsbuiltinrole
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-FslIsWindows)) { return $false }

    $identity = $null
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Checking elevation (WindowsPrincipal.IsInRole)'
        return $false
    }
    finally {
        if ($null -ne $identity) { $identity.Dispose() }
    }
}
