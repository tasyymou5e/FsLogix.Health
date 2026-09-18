function Get-FslContainerMode {
    <#
    .SYNOPSIS
        Returns the resolved FSLogix container mode for toolkit checks: ODFC, Profiles or Both.
    .DESCRIPTION
        Resolution order (contract P2.2): -Mode parameter > user preference file > Config/Settings.psd1
        Toolkit.ContainerMode > 'ODFC'. ODFC (Office containers only) is the default. Invalid stored values are
        ignored (logged). Never throws.
    .PARAMETER Mode
        Explicit mode that overrides the preference file and settings.
    .EXAMPLE
        Get-FslContainerMode

        Returns 'ODFC' unless the preference or settings select Profiles or Both.
    .EXAMPLE
        Get-FslContainerMode -Mode Both
    .NOTES
        RequiresElevation: No
        Sources:
          Toolkit default (contract P2.2); preference storage: https://learn.microsoft.com/dotnet/api/system.environment.getfolderpath
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $Mode
    )

    try {
        if ($PSBoundParameters.ContainsKey('Mode')) {
            $check = ConvertTo-FslPrefValue -Name 'ContainerMode' -Value $Mode
            if ($check['IsValid']) { return [string]$check['Value'] }
        }

        # Get-FslPreference merges preference file over Settings (validated; invalid Settings value -> 'ODFC').
        $resolved = Get-FslPreference -Name 'ContainerMode'
        $check = ConvertTo-FslPrefValue -Name 'ContainerMode' -Value $resolved
        if ($check['IsValid']) { return [string]$check['Value'] }

        Write-FslLog -Message "Container mode '$resolved' is invalid; using ODFC." -Level Warning -Component 'Core'
        return 'ODFC'
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Get-FslContainerMode'
        return 'ODFC'
    }
}
