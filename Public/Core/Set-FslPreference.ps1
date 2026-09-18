function Set-FslPreference {
    <#
    .SYNOPSIS
        Saves one toolkit preference to the user preference file and returns the merged preferences.
    .DESCRIPTION
        Validates the value, then writes the preference file atomically (temporary file in the same folder,
        then File.Move with overwrite). The folder is created when needed. The file lives at
        <LocalApplicationData>/FSLogixToolkit/<Toolkit.PreferenceFileName>, or at the full path in the
        FSLOGIXTOOLKIT_PREFERENCE_PATH environment variable; it is never written inside the module folder.
        Valid values:
          ContainerMode               ODFC | Profiles | Both (case-insensitive; stored in canonical casing)
          AutoRefreshMinutes          whole number 0..1440 (0 = off)
          AutoDiscoverOnStartup, AutoRunHealthCheckOnStartup, Offline   boolean ($true/$false or 'true'/'false')
          RunAsUserName               last user name for 'relaunch as different user' (not a secret): DOMAIN\user or
                                      user@domain.tld without spaces, double quotes or %; empty string or $null clears it
        An invalid value or a write failure produces a non-terminating error (also recorded with Add-FslError)
        and no output. With -WhatIf the file is not changed and the current merged preferences are returned.
    .PARAMETER Name
        Preference to set: ContainerMode, AutoDiscoverOnStartup, AutoRunHealthCheckOnStartup, AutoRefreshMinutes, Offline,
        RunAsUserName.
    .PARAMETER Value
        New value for the preference (see DESCRIPTION).
    .EXAMPLE
        Set-FslPreference -Name ContainerMode -Value Both

        Enables Office and Profile container checks for this user.
    .EXAMPLE
        Set-FslPreference -Name AutoRefreshMinutes -Value 30 -WhatIf
    .EXAMPLE
        Set-FslPreference -Name RunAsUserName -Value 'CONTOSO\adm-jdoe'

        Remembers the admin account offered by 'Relaunch as Different User (Smart Card)'. Only the name is stored.
    .NOTES
        RequiresElevation: No
        Sources:
          https://learn.microsoft.com/dotnet/api/system.io.file.move
          https://learn.microsoft.com/dotnet/api/system.environment.getfolderpath
          https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertto-json
          RunAsUserName formats: https://learn.microsoft.com/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/cc771525(v=ws.11)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('ContainerMode', 'AutoDiscoverOnStartup', 'AutoRunHealthCheckOnStartup', 'AutoRefreshMinutes', 'Offline', 'RunAsUserName')]
        [string] $Name,

        [Parameter(Mandatory, Position = 1)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Value
    )

    # Canonical name casing (ValidateSet matching is case-insensitive).
    $canonicalName = $script:FslPrefSettableNames | Where-Object -FilterScript { $_ -eq $Name } | Select-Object -First 1

    $check = ConvertTo-FslPrefValue -Name $canonicalName -Value $Value
    if (-not $check['IsValid']) {
        $exception = [System.ArgumentException]::new($check['Message'], 'Value')
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'FslInvalidPreferenceValue', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Value)
        Add-FslError -ErrorRecord $record -Component 'Core' -Context "Set-FslPreference -Name $canonicalName"
        $PSCmdlet.WriteError($record)
        return
    }

    $path = Get-FslPrefFilePath
    if ([string]::IsNullOrEmpty($path)) {
        $exception = [System.InvalidOperationException]::new('The preference file path could not be determined.')
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'FslPreferencePathUnavailable', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null)
        Add-FslError -ErrorRecord $record -Component 'Core' -Context "Set-FslPreference -Name $canonicalName"
        $PSCmdlet.WriteError($record)
        return
    }

    if ($PSCmdlet.ShouldProcess($path, "Set preference $canonicalName = $($check['Value'])")) {
        try {
            $stored = Read-FslPrefFile -Path $path
            $stored[$canonicalName] = $check['Value']
            Write-FslPrefFile -Path $path -Values $stored
            Write-FslLog -Message "Preference $canonicalName set to '$($check['Value'])' in '$path'." -Level Info -Component 'Core'
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Writing preference $canonicalName to '$path'"
            $PSCmdlet.WriteError($_)
            return
        }
    }

    return (Get-FslPreference)
}
