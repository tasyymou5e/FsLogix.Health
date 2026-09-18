function Get-FslPreference {
    <#
    .SYNOPSIS
        Returns the toolkit preferences (Config/Settings.psd1 Toolkit section merged with the user preference file).
    .DESCRIPTION
        Starts from all keys of the Toolkit section in Config/Settings.psd1 and overlays valid values from the
        user preference file (JSON) at <LocalApplicationData>/FSLogixToolkit/<Toolkit.PreferenceFileName>, or at
        the full path in the FSLOGIXTOOLKIT_PREFERENCE_PATH environment variable when set.
        A missing or corrupt preference file is tolerated (logged) and Settings values are used. Unknown keys in
        the file are ignored (Verbose log). With -Name, returns only that value ($null and a Warning log when
        the name is not a Toolkit key). Never throws.
    .PARAMETER Name
        Optional Toolkit key to return (for example ContainerMode). Case-insensitive.
    .EXAMPLE
        Get-FslPreference

        Returns a hashtable with ContainerMode, AutoDiscoverOnStartup, AutoRunHealthCheckOnStartup,
        AutoRefreshMinutes, Offline, RunAsUserName (last user name used for 'relaunch as different user'; '' when none)
        and PreferenceFileName.
    .EXAMPLE
        Get-FslPreference -Name ContainerMode

        Returns 'ODFC' unless changed with Set-FslPreference.
    .EXAMPLE
        Get-FslPreference -Name RunAsUserName
    .NOTES
        RequiresElevation: No
        Sources:
          https://learn.microsoft.com/dotnet/api/system.environment.getfolderpath
          https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertfrom-json
    #>
    [CmdletBinding()]
    [OutputType([hashtable], [object])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    try {
        $merged = Get-FslPrefDefault
        $fileValues = Read-FslPrefFile
        foreach ($key in @($fileValues.Keys)) { $merged[$key] = $fileValues[$key] }

        if (-not $PSBoundParameters.ContainsKey('Name')) { return $merged }

        # Hashtable literals created with @{} use a case-insensitive key comparer.
        if ($merged.ContainsKey($Name)) { return $merged[$Name] }

        Write-FslLog -Message "Unknown preference '$Name'. Valid names: $((@($merged.Keys) | Sort-Object) -join ', ')." -Level Warning -Component 'Core'
        return $null
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Get-FslPreference'
        if ($PSBoundParameters.ContainsKey('Name')) { return $null }
        return @{}
    }
}
