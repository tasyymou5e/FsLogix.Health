# Core preference helpers (Agent P2-1, contract P2.2 / P2.4; RunAsUserName added by Agent P3-2, contract P3.2).
# Preference file: <LocalApplicationData>/FSLogixToolkit/<Toolkit.PreferenceFileName> (JSON).
# Environment variable FSLOGIXTOOLKIT_PREFERENCE_PATH overrides the full file path.
# Sources:
#   https://learn.microsoft.com/dotnet/api/system.environment.getfolderpath
#   https://learn.microsoft.com/dotnet/api/system.io.file.move
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertfrom-json
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertto-json

# Names that can be stored in the preference file (contract P2.4 Set-FslPreference -Name).
$script:FslPrefSettableNames = @('ContainerMode', 'AutoDiscoverOnStartup', 'AutoRunHealthCheckOnStartup', 'AutoRefreshMinutes', 'Offline', 'RunAsUserName')

function Get-FslPrefDefault {
    <#
    .SYNOPSIS
        Returns the Toolkit section defaults (Config/Settings.psd1 Toolkit, with built-in toolkit fallbacks).
    .DESCRIPTION
        Returns a new hashtable (copy) so callers can modify it. Built-in fallbacks are toolkit defaults
        used only when Settings.psd1 lacks a key: ContainerMode ODFC, AutoDiscoverOnStartup $true,
        AutoRunHealthCheckOnStartup $true, AutoRefreshMinutes 0, Offline $false, RunAsUserName '' (none),
        PreferenceFileName preferences.json.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $defaults = @{
        ContainerMode               = 'ODFC'
        AutoDiscoverOnStartup       = $true
        AutoRunHealthCheckOnStartup = $true
        AutoRefreshMinutes          = 0
        Offline                     = $false
        RunAsUserName               = ''
        PreferenceFileName          = 'preferences.json'
    }

    $toolkit = $null
    try { $toolkit = Get-FslConfig -Section 'Toolkit' } catch { Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Reading Toolkit settings' }

    if ($toolkit -is [hashtable]) {
        foreach ($key in @($toolkit.Keys)) {
            $keyName = [string]$key
            if ($script:FslPrefSettableNames -contains $keyName) {
                $check = ConvertTo-FslPrefValue -Name $keyName -Value $toolkit[$key]
                if ($check['IsValid']) {
                    $defaults[$keyName] = $check['Value']
                }
                else {
                    Write-FslLog -Message "Config/Settings.psd1 Toolkit.$keyName is invalid ($($check['Message'])); using toolkit default '$($defaults[$keyName])'." -Level Warning -Component 'Core'
                }
            }
            else {
                $defaults[$keyName] = $toolkit[$key]
            }
        }
    }
    return $defaults
}

function ConvertTo-FslPrefValue {
    <#
    .SYNOPSIS
        Validates and normalizes a preference value.
    .DESCRIPTION
        Returns a hashtable: IsValid (bool), Value (normalized), Message (reason when invalid).
        ContainerMode: ODFC|Profiles|Both, case-insensitive, normalized to canonical casing.
        AutoRefreshMinutes: whole number 0..1440 (int or integer-valued string).
        AutoDiscoverOnStartup / AutoRunHealthCheckOnStartup / Offline: [bool] or 'true'/'false' string.
        RunAsUserName: last user name used for 'relaunch as different user' (not a secret): empty string (clears it),
        DOMAIN\user or user@domain.tld without spaces, double quotes or % (Test-FslCoreRunAsUserName); trimmed.
        Never throws.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [AllowNull()]
        [object] $Value
    )

    $result = @{ IsValid = $false; Value = $null; Message = $null }
    try {
        switch ($Name) {
            'ContainerMode' {
                $text = if ($Value -is [string]) { $Value.Trim() } else { $null }
                $canonical = switch ($text) {
                    'ODFC' { 'ODFC' }
                    'Profiles' { 'Profiles' }
                    'Both' { 'Both' }
                    default { $null }
                }
                if ($null -ne $canonical) { $result['IsValid'] = $true; $result['Value'] = $canonical }
                else { $result['Message'] = "ContainerMode must be one of ODFC, Profiles, Both (got '$Value')." }
            }
            'AutoRefreshMinutes' {
                $number = $null
                if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long]) {
                    $number = [long]$Value
                }
                elseif ($Value -is [string]) {
                    $parsed = [long]0
                    if ([long]::TryParse($Value.Trim(), [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                        $number = $parsed
                    }
                }
                if ($null -ne $number -and $number -ge 0 -and $number -le 1440) {
                    $result['IsValid'] = $true
                    $result['Value'] = [int]$number
                }
                else {
                    $result['Message'] = "AutoRefreshMinutes must be a whole number from 0 to 1440 (got '$Value')."
                }
            }
            { $_ -in @('AutoDiscoverOnStartup', 'AutoRunHealthCheckOnStartup', 'Offline') } {
                if ($Value -is [bool]) {
                    $result['IsValid'] = $true; $result['Value'] = $Value
                }
                elseif ($Value -is [System.Management.Automation.SwitchParameter]) {
                    $result['IsValid'] = $true; $result['Value'] = $Value.IsPresent
                }
                elseif ($Value -is [string] -and $Value.Trim() -in @('true', 'false')) {
                    $result['IsValid'] = $true; $result['Value'] = ($Value.Trim() -eq 'true')
                }
                else {
                    $result['Message'] = "$Name must be a boolean (got '$Value')."
                }
            }
            'RunAsUserName' {
                if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) {
                    $result['IsValid'] = $true; $result['Value'] = ''
                }
                elseif ($Value -is [string] -and (Test-FslCoreRunAsUserName -UserName $Value.Trim())) {
                    $result['IsValid'] = $true; $result['Value'] = $Value.Trim()
                }
                else {
                    $result['Message'] = "RunAsUserName must be empty, DOMAIN\user or user@domain.tld without spaces, quotes or % (got '$Value')."
                }
            }
            default {
                $result['Message'] = "Unknown preference name '$Name'. Valid names: $($script:FslPrefSettableNames -join ', ')."
            }
        }
    }
    catch {
        $result['IsValid'] = $false
        $result['Message'] = "Validation of '$Name' failed: $($_.Exception.Message)"
    }
    return $result
}

function Get-FslPrefFilePath {
    <#
    .SYNOPSIS
        Returns the full path of the user preference file.
    .DESCRIPTION
        FSLOGIXTOOLKIT_PREFERENCE_PATH (full path) when set; otherwise
        [Environment]::GetFolderPath('LocalApplicationData')/FSLogixToolkit/<Toolkit.PreferenceFileName>.
        Returns $null when no path can be determined. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $override = [Environment]::GetEnvironmentVariable('FSLOGIXTOOLKIT_PREFERENCE_PATH')
        if (-not [string]::IsNullOrWhiteSpace($override)) {
            return [System.IO.Path]::GetFullPath($override.Trim())
        }

        $fileName = 'preferences.json'
        $toolkit = Get-FslConfig -Section 'Toolkit'
        if ($toolkit -is [hashtable] -and $toolkit.ContainsKey('PreferenceFileName') -and -not [string]::IsNullOrWhiteSpace([string]$toolkit['PreferenceFileName'])) {
            $fileName = [System.IO.Path]::GetFileName([string]$toolkit['PreferenceFileName'])
        }

        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            Write-FslLog -Message 'LocalApplicationData folder could not be determined; preference file unavailable.' -Level Warning -Component 'Core'
            return $null
        }
        return (Join-Path -Path (Join-Path -Path $localAppData -ChildPath 'FSLogixToolkit') -ChildPath $fileName)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Resolving preference file path'
        return $null
    }
}

function Read-FslPrefFile {
    <#
    .SYNOPSIS
        Reads valid preference entries from the preference file.
    .DESCRIPTION
        Returns a hashtable containing only known, valid, normalized entries. Missing file -> empty hashtable.
        Corrupt JSON or non-object content -> logged Warning, empty hashtable (callers fall back to Settings).
        Unknown keys are ignored (Verbose log); invalid values are ignored (Warning log). Never throws.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Path
    )

    $values = @{}
    if (-not $PSBoundParameters.ContainsKey('Path')) { $Path = Get-FslPrefFilePath }
    if ([string]::IsNullOrEmpty($Path)) { return $values }

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Write-FslLog -Message "Preference file not found at '$Path'; using Config/Settings.psd1 values." -Level Verbose -Component 'Core'
            return $values
        }

        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($json)) {
            Write-FslLog -Message "Preference file '$Path' is empty; using Config/Settings.psd1 values." -Level Warning -Component 'Core'
            return $values
        }

        $data = $null
        try {
            $data = ConvertFrom-Json -InputObject $json -AsHashtable -ErrorAction Stop
        }
        catch {
            Write-FslLog -Message "Preference file '$Path' is not valid JSON ($($_.Exception.Message)); using Config/Settings.psd1 values." -Level Warning -Component 'Core'
            return $values
        }

        if ($data -isnot [System.Collections.IDictionary]) {
            Write-FslLog -Message "Preference file '$Path' does not contain a JSON object; using Config/Settings.psd1 values." -Level Warning -Component 'Core'
            return $values
        }

        foreach ($key in @($data.Keys)) {
            $keyName = [string]$key
            $canonicalName = $script:FslPrefSettableNames | Where-Object -FilterScript { $_ -eq $keyName } | Select-Object -First 1
            if ($null -eq $canonicalName) {
                Write-FslLog -Message "Ignoring unknown key '$keyName' in preference file '$Path'." -Level Verbose -Component 'Core'
                continue
            }
            $check = ConvertTo-FslPrefValue -Name $canonicalName -Value $data[$key]
            if ($check['IsValid']) {
                $values[$canonicalName] = $check['Value']
            }
            else {
                Write-FslLog -Message "Ignoring invalid value in preference file '$Path': $($check['Message'])" -Level Warning -Component 'Core'
            }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Reading preference file '$Path'"
        return @{}
    }
    return $values
}

function Write-FslPrefFile {
    <#
    .SYNOPSIS
        Writes preference entries to the preference file atomically (temp file in the same folder + move).
    .DESCRIPTION
        Creates the folder when needed. Refuses to write inside the module folder (contract P2.2).
        Throws on failure; the public caller handles errors. State change is gated by the public caller's ShouldProcess.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helper; ShouldProcess is handled by Set-FslPreference.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory)]
        [hashtable] $Values
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $moduleRoot = [string]$script:FslSession['ModuleRoot']
    if (-not [string]::IsNullOrEmpty($moduleRoot)) {
        $rootFull = [System.IO.Path]::GetFullPath($moduleRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if ($fullPath.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw [System.InvalidOperationException]::new("Refusing to write preferences inside the module folder ('$fullPath').")
        }
    }

    $folder = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [string]::IsNullOrEmpty($folder) -and -not (Test-Path -LiteralPath $folder -PathType Container)) {
        $null = New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop
    }

    $ordered = [ordered]@{}
    foreach ($name in $script:FslPrefSettableNames) {
        if ($Values.ContainsKey($name)) { $ordered[$name] = $Values[$name] }
    }
    $json = ConvertTo-Json -InputObject $ordered -Depth 3

    $tempPath = Join-Path -Path $folder -ChildPath ('.{0}.{1}.tmp' -f [System.IO.Path]::GetFileName($fullPath), [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
        # File.Move(source, dest, overwrite) - same folder, so this is a rename that replaces the target.
        [System.IO.File]::Move($tempPath, $fullPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            try { Remove-Item -LiteralPath $tempPath -Force -ErrorAction Stop } catch { $null = $_ }
        }
    }
}

function Resolve-FslPrefContainerScope {
    <#
    .SYNOPSIS
        Maps a container mode to container scopes (contract P2.4).
    .DESCRIPTION
        ODFC -> 'ODFC'; Profiles -> 'Profiles'; Both -> 'ODFC','Profiles'. Values are written to the
        pipeline individually; wrap the call in @() when an array is required.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $Mode
    )

    switch ($Mode) {
        'ODFC' { return [string[]]@('ODFC') }
        'Profiles' { return [string[]]@('Profiles') }
        default { return [string[]]@('ODFC', 'Profiles') }
    }
}
