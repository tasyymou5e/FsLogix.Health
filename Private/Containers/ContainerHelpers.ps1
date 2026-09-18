# Private helpers for the Containers area (prefix *-FslCtr*).
# Sources (verified 2026-09-17):
#   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
#   https://learn.microsoft.com/en-us/dotnet/api/system.security.principal.securityidentifier.translate
#   https://learn.microsoft.com/en-us/dotnet/standard/io/handling-io-errors
#   https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-localusersandgroups
#     (Microsoft Entra ID SIDs use the S-1-12-1- prefix, e.g. S-1-12-1-111111111-22222222222-3333333333-4444444444)

# SID patterns recognised in container folder names:
#   S-1-5-21-<domain>-<rid>  Active Directory / local accounts (understand-security-identifiers)
#   S-1-12-1-<4 values>      Microsoft Entra ID users/groups (policy-csp-localusersandgroups example format)
$script:FslCtrSidRegex = '(?:S-1-5-21|S-1-12-1)-\d+-\d+-\d+-\d+'
$script:FslCtrEntraSidPrefix = 'S-1-12-1-'

function Get-FslCtrDefaultNaming {
    <#
        Documented FSLogix defaults (reference-configuration-settings):
          Profiles: VHDNameMatch 'Profile*', VHDNamePattern 'Profile_%username%'
          ODFC:     VHDNameMatch 'ODFC*',    VHDNamePattern 'ODFC_%username%'
          Both:     SIDDirNameMatch/SIDDirNamePattern '%sid%_%username%', FlipFlopProfileDirectoryName 0
                    (1 = '%username%_%sid%'), NoProfileContainingFolder 0, SizeInMBs 30000, IsDynamic 1.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Profiles', 'ODFC')]
        [string] $Scope
    )

    $prefix = if ($Scope -eq 'Profiles') { 'Profile' } else { 'ODFC' }
    return @{
        Scope                        = $Scope
        VHDNameMatch                 = "$prefix*"
        VHDNamePattern               = "${prefix}_%username%"
        SIDDirNameMatch              = '%sid%_%username%'
        FlipFlopProfileDirectoryName = 0
        NoProfileContainingFolder    = 0
        SizeInMBs                    = 30000
        IsDynamic                    = 1
    }
}

function Get-FslCtrNamingSetting {
    <# Returns a hashtable keyed by scope (Profiles, ODFC) with effective naming/size settings.
       Configured values from Get-FslEffectiveSetting override documented defaults.
       -NamingScope limits which FSLogix registry scopes are read (default both); scopes that are not read keep
       their documented defaults, so no Profiles key is read when only ODFC is requested. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [ValidateSet('Profiles', 'ODFC')]
        [string[]] $NamingScope = @('Profiles', 'ODFC')
    )

    $naming = @{
        Profiles = Get-FslCtrDefaultNaming -Scope 'Profiles'
        ODFC     = Get-FslCtrDefaultNaming -Scope 'ODFC'
    }

    $names = @('VHDNameMatch', 'VHDNamePattern', 'SIDDirNameMatch', 'FlipFlopProfileDirectoryName',
        'NoProfileContainingFolder', 'SizeInMBs', 'IsDynamic')

    $settings = @()
    try {
        $settings = @(Get-FslEffectiveSetting -Scope @($NamingScope | Select-Object -Unique) -ErrorAction Stop)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Containers' -Context 'Reading effective FSLogix settings; using documented defaults'
    }

    foreach ($setting in $settings) {
        if ($null -eq $setting) { continue }
        $scope = [string]$setting.Scope
        $name = [string]$setting.Name
        if (-not $naming.ContainsKey($scope)) { continue }
        $matchedName = $names | Where-Object -FilterScript { $_ -eq $name } | Select-Object -First 1
        if (-not $matchedName) { continue }
        $value = $setting.Value
        if ($null -eq $value) { continue }
        if ($value -is [array]) { $value = $value | Select-Object -First 1 }

        if ($matchedName -in @('FlipFlopProfileDirectoryName', 'NoProfileContainingFolder', 'SizeInMBs', 'IsDynamic')) {
            $number = 0L
            if ([long]::TryParse([string]$value, [ref]$number)) { $naming[$scope][$matchedName] = $number }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $naming[$scope][$matchedName] = [string]$value
        }
    }

    foreach ($scope in @('Profiles', 'ODFC')) {
        # FlipFlopProfileDirectoryName overrides SIDDirNameMatch (documented precedence).
        $naming[$scope]['FolderPattern'] = if ($naming[$scope]['FlipFlopProfileDirectoryName'] -eq 1) {
            '%username%_%sid%'
        }
        else {
            $naming[$scope]['SIDDirNameMatch']
        }
    }
    return $naming
}

function ConvertTo-FslCtrPatternRegex {
    <# Converts an FSLogix name pattern (e.g. '%sid%_%username%') to an anchored regex with
       named groups 'sid' and 'user'. Other %variables% match any text. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Pattern
    )

    $parts = [regex]::Split($Pattern, '(%[^%]+%)')
    $builder = [System.Text.StringBuilder]::new('^')
    foreach ($part in $parts) {
        if ([string]::IsNullOrEmpty($part)) { continue }
        switch -Regex ($part) {
            '^%sid%$' { [void]$builder.Append('(?<sid>' + $script:FslCtrSidRegex + ')'); break }
            '^%username%$' { [void]$builder.Append('(?<user>.+?)'); break }
            '^%[^%]+%$' { [void]$builder.Append('.+?'); break }
            default { [void]$builder.Append([regex]::Escape($part)) }
        }
    }
    [void]$builder.Append('$')
    return $builder.ToString()
}

function ConvertTo-FslCtrWildcard {
    <# Converts an FSLogix match pattern (e.g. 'Profile*' or 'Profile_%username%') to a -like wildcard. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Pattern
    )

    $parts = [regex]::Split($Pattern, '(%[^%]+%|\*)')
    $builder = [System.Text.StringBuilder]::new()
    foreach ($part in $parts) {
        if ([string]::IsNullOrEmpty($part)) { continue }
        if ($part -eq '*' -or $part -match '^%[^%]+%$') { [void]$builder.Append('*') }
        else { [void]$builder.Append([System.Management.Automation.WildcardPattern]::Escape($part)) }
    }
    return $builder.ToString()
}

function Get-FslCtrScope {
    <# Determines container scope from the file name using the effective VHDNameMatch patterns.
       Returns 'Unknown' when neither or both patterns match. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FileName,

        [Parameter(Mandatory)]
        [hashtable] $Naming
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $matched = foreach ($scope in @('Profiles', 'ODFC')) {
        $wildcard = ConvertTo-FslCtrWildcard -Pattern ([string]$Naming[$scope]['VHDNameMatch'])
        if ($baseName -like $wildcard -or $FileName -like $wildcard) { $scope }
    }
    $matched = @($matched)
    if ($matched.Count -eq 1) { return $matched[0] }
    return 'Unknown'
}

function Get-FslCtrIdentityFromName {
    <# Extracts SID and user name from the containing folder name and/or file name. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FileName,

        [Parameter()]
        [AllowEmptyString()]
        [string] $FolderName,

        [Parameter(Mandatory)]
        [ValidateSet('Profiles', 'ODFC', 'Unknown')]
        [string] $Scope,

        [Parameter(Mandatory)]
        [hashtable] $Naming
    )

    $sid = $null
    $user = $null

    if (-not [string]::IsNullOrEmpty($FolderName)) {
        $folderPatterns = if ($Scope -eq 'Unknown') {
            @($Naming['Profiles']['FolderPattern'], $Naming['ODFC']['FolderPattern'], '%sid%_%username%', '%username%_%sid%') |
                Select-Object -Unique
        }
        else { @($Naming[$Scope]['FolderPattern']) }

        foreach ($pattern in $folderPatterns) {
            $regex = ConvertTo-FslCtrPatternRegex -Pattern ([string]$pattern)
            $match = [regex]::Match($FolderName, $regex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) {
                if ($match.Groups['sid'].Success) { $sid = $match.Groups['sid'].Value }
                if ($match.Groups['user'].Success) { $user = $match.Groups['user'].Value }
                if ($sid) { break }
            }
        }
        if (-not $sid) {
            $sidMatch = [regex]::Match($FolderName, $script:FslCtrSidRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($sidMatch.Success) { $sid = $sidMatch.Value }
        }
    }

    if (-not $user -and $Scope -ne 'Unknown') {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
        $regex = ConvertTo-FslCtrPatternRegex -Pattern ([string]$Naming[$Scope]['VHDNamePattern'])
        $match = [regex]::Match($baseName, $regex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success -and $match.Groups['user'].Success) { $user = $match.Groups['user'].Value }
    }

    if ($sid) { $sid = $sid.ToUpperInvariant() }
    return @{ SID = $sid; UserName = $user }
}

function Resolve-FslCtrAccount {
    <# Translates a SID to an NTAccount. Resolved / Orphaned (IdentityNotMappedException) / Unknown.
       Microsoft Entra ID SIDs (S-1-12-1-...): whether this host can translate them depends on its join state
       and cannot be verified here, so a failed translation (including IdentityNotMappedException) is reported
       as Unknown and such containers are NEVER marked Orphaned. A successful translation is Resolved. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Sid,

        [Parameter(Mandatory)]
        [hashtable] $Cache
    )

    if ([string]::IsNullOrEmpty($Sid)) { return @{ AccountStatus = 'Unknown'; AccountName = $null } }
    if ($Cache.ContainsKey($Sid)) { return $Cache[$Sid] }

    $result = @{ AccountStatus = 'Unknown'; AccountName = $null }
    $isEntraSid = $Sid.StartsWith($script:FslCtrEntraSidPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    if (Test-FslIsWindows) {
        try {
            $identifier = [System.Security.Principal.SecurityIdentifier]::new($Sid)
            $account = $identifier.Translate([System.Security.Principal.NTAccount])
            $result = @{ AccountStatus = 'Resolved'; AccountName = $account.Value }
        }
        catch [System.Security.Principal.IdentityNotMappedException] {
            if ($isEntraSid) {
                Write-FslLog -Message "Microsoft Entra ID SID $Sid could not be translated on this host; account status Unknown (not treated as orphaned)." -Level Debug -Component 'Containers'
                $result = @{ AccountStatus = 'Unknown'; AccountName = $null }
            }
            else {
                $result = @{ AccountStatus = 'Orphaned'; AccountName = $null }
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Containers' -Context "Translating SID $Sid"
        }
    }
    $Cache[$Sid] = $result
    return $result
}

function Test-FslCtrFileLock {
    <# Opens the file read-only with FileShare.None and immediately disposes it; never writes.
       $true  = sharing violation (Win32 error 32, HResult low word) -> in use / attached
       $false = opened exclusively
       $null  = unknown (access denied, other I/O error, or non-Windows where sharing semantics differ) #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LiteralPath
    )

    if (-not (Test-FslIsWindows)) { return $null }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($LiteralPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        return $false
    }
    catch [System.UnauthorizedAccessException] {
        return $null
    }
    catch [System.IO.IOException] {
        $exception = $_.Exception
        while ($exception -isnot [System.IO.IOException] -and $null -ne $exception.InnerException) {
            $exception = $exception.InnerException
        }
        if (($exception.HResult -band 0xFFFF) -eq 32) { return $true }
        Add-FslError -ErrorRecord $_ -Component 'Containers' -Context "Lock test on $LiteralPath"
        return $null
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Containers' -Context "Lock test on $LiteralPath"
        return $null
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-FslCtrSearchLocation {
    <# Returns unique local/SMB folder paths from Get-FslStorageLocation for the requested scopes. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Scope
    )

    $paths = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $locations = @()
    try {
        $locationScopes = @($Scope | Where-Object -FilterScript { $_ -in @('Profiles', 'ODFC') } | Select-Object -Unique)
        if ($locationScopes.Count -gt 0) {
            $locations = @(Get-FslStorageLocation -Scope $locationScopes -ErrorAction Stop)
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Containers' -Context 'Reading storage locations'
    }

    foreach ($location in $locations) {
        if ($null -eq $location) { continue }
        if ([string]$location.Scope -notin $Scope) { continue }
        if ([string]$location.ProviderType -notin @('SMB', 'Local')) { continue }
        $path = [string]$location.Path
        # CCDLocations entries use 'type=smb,name="...",connectionString=\\server\share' (documented format).
        $connection = [regex]::Match($path, 'connectionString=("?)(?<cs>[^",;]+)\1')
        if ($connection.Success) { $path = $connection.Groups['cs'].Value }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($path.Contains('%')) {
            Write-FslLog -Message "Skipping storage location containing per-user variables (cannot enumerate): $path" -Level Warning -Component 'Containers'
            continue
        }
        if ($seen.Add($path)) { $paths.Add($path) }
    }
    return , $paths.ToArray()
}

function ConvertTo-FslCtrResultScope {
    <# Maps a container Scope (Profiles|ODFC|Unknown|other) to a Result Scope (Profiles|ODFC|General). #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Scope
    )

    if ($Scope -eq 'Profiles') { return 'Profiles' }
    if ($Scope -eq 'ODFC') { return 'ODFC' }
    return 'General'
}
