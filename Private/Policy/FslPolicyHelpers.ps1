# FSLogixToolkit - Policy area private helpers (prefix *-FslPol*).
#
# Verified sources (retrieved 2026-09-17):
# - FSLogix registry keys (Profiles = SOFTWARE\FSLogix\Profiles, ODFC = SOFTWARE\Policies\FSLogix\ODFC,
#   Logging = SOFTWARE\FSLogix\Logging, Apps = SOFTWARE\FSLogix\Apps), VHDLocations/CCDLocations types and format:
#   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
# - ObjectSpecific VHDLocations (HKLM:\SOFTWARE\FSLogix\Profiles\ObjectSpecific\<SID>):
#   https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples
# - CCDLocations examples (providers separated by ';'):
#   https://learn.microsoft.com/en-us/fslogix/tutorial-cloud-cache-containers
# - Secure key reference |fslogix/<key-name>| and frx add-secure-key:
#   https://learn.microsoft.com/en-us/fslogix/how-to-protect-connection-string
# - Azure Storage connection string keys (AccountName, AccountKey, EndpointSuffix, BlobEndpoint, SharedAccessSignature):
#   https://learn.microsoft.com/en-us/azure/storage/common/storage-configure-connection-string
# - RSOP_RegistryPolicySetting / RSOP_PolicySetting (precedence 1 = winning) / RSOP_GPO (namespace Root\RSOP\Computer):
#   https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-registrypolicysetting
#   https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-policysetting
#   https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-gpo
# - RSOP_SOM (type Local = 1) / RSOP_GPLink (links from a local scope):
#   https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-som
#   https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-gplink
# - Microsoft.Win32.RegistryKey OpenBaseKey/OpenSubKey/GetValue/GetValueKind/GetValueNames verified via .NET reflection (PowerShell 7.5.2).

function Get-FslPolScopeKey {
    <# Returns the verified FSLogix registry sub keys (under HKLM) per scope. #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    [ordered]@{
        Profiles = 'SOFTWARE\FSLogix\Profiles'
        ODFC     = 'SOFTWARE\Policies\FSLogix\ODFC'
        Logging  = 'SOFTWARE\FSLogix\Logging'
        Apps     = 'SOFTWARE\FSLogix\Apps'
    }
}

function Get-FslPolSourceUrl {
    <# Returns the verified documentation URLs used by the Policy area. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        ConfigurationSettings = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings'
        GroupPolicyTemplates  = 'https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates'
        ProtectConnection     = 'https://learn.microsoft.com/en-us/fslogix/how-to-protect-connection-string'
        ConfigurationExamples = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples'
        RsopRegistrySetting   = 'https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-registrypolicysetting'
        RsopPolicySetting     = 'https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-policysetting'
        RsopGpo               = 'https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-gpo'
        RsopSom               = 'https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-som'
        GpResult              = 'https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/gpresult'
    }
}

function ConvertTo-FslPolRedactedText {
    <#
        Redacts secrets from a string: Azure Storage AccountKey= and SharedAccessSignature= values and SAS sig= parameters.
        Secure key references (|fslogix/<key-name>|) are not secrets and are kept.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $result = [regex]::Replace($Text, '(AccountKey\s*=)[^;"]*', '$1<redacted>', $options)
    $result = [regex]::Replace($result, '(SharedAccessSignature\s*=)[^;"]*', '$1<redacted>', $options)
    $result = [regex]::Replace($result, '((?:^|[?&;,\s])sig=)[^&;"\s]*', '$1<redacted>', $options)
    $result
}

function ConvertTo-FslPolRedactedValue {
    <# Redacts secrets from a registry value (string or string[]); other types are returned unchanged. #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (ConvertTo-FslPolRedactedText -Text $Value) }
    if ($Value -is [string[]]) {
        [string[]] $redacted = foreach ($item in $Value) { ConvertTo-FslPolRedactedText -Text $item }
        return , $redacted
    }
    $Value
}

function ConvertTo-FslPolNormalizedKey {
    <# Normalizes a registry key path to 'SOFTWARE\...' form (no hive prefix, no trailing backslash). #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Key
    )

    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }
    $normalized = $Key.Trim()
    $normalized = [regex]::Replace($normalized, '^(HKEY_LOCAL_MACHINE|HKLM:|HKLM|MACHINE|Registry::HKEY_LOCAL_MACHINE)\\+', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $normalized.Trim('\')
}

function Get-FslPolRegistryValue {
    <#
        Reads all values of HKLM\<SubKey> (64-bit view) preserving the value kind. Values are NOT redacted here.
        Returns nothing when the key does not exist. Windows only; callers guard with Test-FslIsWindows.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SubKey
    )

    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $key = $baseKey.OpenSubKey($SubKey, $false)
        if ($null -eq $key) {
            Write-FslLog -Message "Registry key HKLM:\$SubKey not found." -Level Debug -Component 'Policy'
            return
        }
        foreach ($valueName in $key.GetValueNames()) {
            if ([string]::IsNullOrEmpty($valueName)) { continue }   # skip the (Default) value
            $kind = $key.GetValueKind($valueName)
            $kindName = switch ($kind) {
                ([Microsoft.Win32.RegistryValueKind]::DWord) { 'DWord' }
                ([Microsoft.Win32.RegistryValueKind]::QWord) { 'QWord' }
                ([Microsoft.Win32.RegistryValueKind]::String) { 'String' }
                ([Microsoft.Win32.RegistryValueKind]::ExpandString) { 'ExpandString' }
                ([Microsoft.Win32.RegistryValueKind]::MultiString) { 'MultiString' }
                ([Microsoft.Win32.RegistryValueKind]::Binary) { 'Binary' }
                default { $null }
            }
            if ($null -eq $kindName) {
                Write-FslLog -Message "Skipping HKLM:\$SubKey\$valueName with unsupported value kind '$kind'." -Level Debug -Component 'Policy'
                continue
            }
            $raw = $key.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $value = switch ($kindName) {
                'DWord' { [int]$raw }
                'QWord' { [long]$raw }
                'MultiString' { , ([string[]]$raw) }
                'Binary' { , ([byte[]]$raw) }
                default { [string]$raw }
            }
            [pscustomobject]@{
                SubKey    = $SubKey
                Name      = $valueName
                Value     = $value
                ValueKind = $kindName
            }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Policy' -Context "Reading registry key HKLM:\$SubKey"
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Get-FslPolRegistrySubKeyName {
    <# Returns the sub key names of HKLM\<SubKey> (64-bit view), or nothing when the key does not exist. Windows only. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SubKey
    )

    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $key = $baseKey.OpenSubKey($SubKey, $false)
        if ($null -eq $key) { return }
        $key.GetSubKeyNames()
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Policy' -Context "Enumerating sub keys of HKLM:\$SubKey"
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Get-FslPolRsopData {
    <#
        Queries computer RSoP (WMI namespace root\rsop\computer). Returns [pscustomobject]@{ GpoCount; Rows } where
        GpoCount is the number of RSOP_GPO instances and Rows are the RSOP_RegistryPolicySetting entries under
        SOFTWARE\FSLogix or SOFTWARE\Policies\FSLogix (with GPO display names resolved from RSOP_GPO).
        RSOP_SOM documents a 'Local' (1) scope of management and RSOP_GPLink links from a local scope, so the RSoP model
        covers the local scope; whether FSLogix values delivered by Local Group Policy appear as
        RSOP_RegistryPolicySetting rows (and the local GPO display name) is a Windows lab item - nothing here depends on
        a specific local GPO id or name.
        Windows + elevated only (callers check). Throws on query failure so callers can record the error.
        Sources: https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-gpo
                 https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-som
                 https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-gplink
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $namespace = 'root\rsop\computer'
    $gpoById = @{}
    $gpoByGuid = @{}
    $gpos = @(Get-CimInstance -Namespace $namespace -ClassName 'RSOP_GPO' -ErrorAction Stop)
    foreach ($gpo in $gpos) {
        if (-not [string]::IsNullOrEmpty($gpo.id)) { $gpoById[[string]$gpo.id] = [string]$gpo.name }
        if (-not [string]::IsNullOrEmpty($gpo.guidName)) { $gpoByGuid[([string]$gpo.guidName).Trim('{', '}').ToLowerInvariant()] = [string]$gpo.name }
    }

    $resultRows = [System.Collections.Generic.List[object]]::new()
    $rows = @(Get-CimInstance -Namespace $namespace -ClassName 'RSOP_RegistryPolicySetting' -ErrorAction Stop)
    foreach ($row in $rows) {
        $normalizedKey = ConvertTo-FslPolNormalizedKey -Key ([string]$row.registryKey)
        if (-not ($normalizedKey -match '^SOFTWARE\\(Policies\\)?FSLogix(\\|$)')) { continue }

        $gpoId = [string]$row.GPOID
        $gpoName = $null
        if ($gpoById.ContainsKey($gpoId)) { $gpoName = $gpoById[$gpoId] }
        else {
            $guidMatch = [regex]::Match($gpoId, '\{?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}?')
            if ($guidMatch.Success -and $gpoByGuid.ContainsKey($guidMatch.Groups[1].Value.ToLowerInvariant())) {
                $gpoName = $gpoByGuid[$guidMatch.Groups[1].Value.ToLowerInvariant()]
            }
        }

        $resultRows.Add([pscustomobject]@{
                RegistryKey = $normalizedKey
                ValueName   = [string]$row.valueName
                Precedence  = [int]$row.precedence
                Deleted     = [bool]$row.deleted
                GpoId       = $gpoId
                GpoName     = $gpoName
            })
    }

    [pscustomobject]@{
        GpoCount = $gpos.Count
        Rows     = $resultRows.ToArray()
    }
}

function Get-FslPolRsopRegistrySetting {
    <#
        Returns the FSLogix RSOP_RegistryPolicySetting rows of computer RSoP (see Get-FslPolRsopData).
        Windows + elevated only (callers check). Throws on query failure so callers can record the error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $data = Get-FslPolRsopData
    foreach ($row in @($data.Rows)) { $row }
}

function Get-FslPolRsopState {
    <#
        Determines whether Group Policy provenance can be established (contract PHASE 3 P3.1 item 1) and returns
        [pscustomobject]@{ Status; Rows; GpoCount; Detail } with Status:
          Ok          - Windows, elevated, computer RSoP query succeeded and returned at least one RSOP_GPO instance.
          NotWindows  - not running on Windows.
          NotElevated - computer RSoP (root\rsop\computer) was not queried because the session is not elevated.
          Failed      - the RSoP query threw (message redacted).
          Unavailable - the query succeeded but returned no RSOP_GPO instances, so RSoP data is treated as unavailable
                        (toolkit conservative choice: provenance stays Unknown rather than Registry).
        Never throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $state = [pscustomobject]@{ Status = 'Unavailable'; Rows = @(); GpoCount = 0; Detail = '' }

    if (-not (Test-FslIsWindows)) {
        $state.Status = 'NotWindows'
        $state.Detail = 'Not Windows: Group Policy provenance not checked'
        return $state
    }

    $isElevated = $false
    try { $isElevated = [bool](Test-FslElevation) }
    catch { Add-FslError -ErrorRecord $_ -Component 'Policy' -Context 'Checking elevation for RSoP provenance' }
    if (-not $isElevated) {
        $state.Status = 'NotElevated'
        $state.Detail = 'Not elevated: Group Policy provenance not checked'
        Write-FslLog -Message 'Not elevated: computer RSoP is not queried; FSLogix setting provenance is reported as Unknown.' -Level Verbose -Component 'Policy'
        return $state
    }

    try {
        $data = Get-FslPolRsopData
        $state.GpoCount = [int]$data.GpoCount
        $state.Rows = @($data.Rows | Where-Object -FilterScript { $null -ne $_ })
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Policy' -Context 'Querying computer RSoP (root\rsop\computer) for FSLogix policy settings'
        $state.Status = 'Failed'
        $state.Rows = @()
        $state.Detail = "RSoP query failed: $(ConvertTo-FslPolRedactedText -Text ([string]$_.Exception.Message))"
        return $state
    }

    if ($state.GpoCount -le 0) {
        $state.Status = 'Unavailable'
        $state.Rows = @()
        $state.Detail = 'RSoP unavailable: computer RSoP returned no Group Policy Objects (RSOP_GPO); Group Policy provenance not confirmed'
        return $state
    }

    $state.Status = 'Ok'
    $state.Detail = 'Computer RSoP query succeeded'
    $state
}

function Get-FslPolProvenance {
    <#
        Resolves Source/PolicyName/SourceDetail for one registry value (three-state provenance, contract PHASE 3 P3.1):
          GroupPolicy - RSoP status Ok and a winning (precedence 1), non-deleted RSoP row matches the key and value name.
          Registry    - RSoP status Ok (Windows, elevated, query succeeded) and no winning row matches.
          Unknown     - any other RSoP status (not elevated, query failed, RSoP unavailable, not Windows).
        MDM/Intune delivery is not detected (no verified method). 'Registry' means "no winning RSoP row", not a proven
        absence of Group Policy: whether values delivered by LOCAL Group Policy surface as RSOP_RegistryPolicySetting
        rows is still an open lab item (see Get-FslPolRsopData), so SourceDetail names Local Group Policy as a
        possibility instead of claiming the value is not delivered by Group Policy.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $RsopRow,

        [Parameter(Mandatory)]
        [string] $SubKey,

        [Parameter(Mandatory)]
        [string] $ValueName,

        [Parameter(Mandatory)]
        [ValidateSet('Ok', 'NotWindows', 'NotElevated', 'Failed', 'Unavailable')]
        [string] $RsopStatus,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $RsopDetail
    )

    if ($RsopStatus -ne 'Ok') {
        $detail = if ([string]::IsNullOrWhiteSpace($RsopDetail)) { "Group Policy provenance not confirmed (RSoP status $RsopStatus)" } else { $RsopDetail }
        return [pscustomobject]@{ Source = 'Unknown'; PolicyName = $null; SourceDetail = $detail }
    }

    $match = $null
    if ($null -ne $RsopRow) {
        $match = $RsopRow | Where-Object -FilterScript {
            $null -ne $_ -and $_.Precedence -eq 1 -and -not $_.Deleted -and
            $_.RegistryKey -eq $SubKey -and $_.ValueName -eq $ValueName
        } | Select-Object -First 1
    }
    if ($null -ne $match) {
        $label = if ($match.GpoName) { [string]$match.GpoName } else { [string]$match.GpoId }
        return [pscustomobject]@{
            Source       = 'GroupPolicy'
            PolicyName   = $match.GpoName
            SourceDetail = "Winning entry (precedence 1) in computer RSoP from GPO '$label'"
        }
    }
    [pscustomobject]@{
        Source       = 'Registry'
        PolicyName   = $null
        SourceDetail = 'Computer RSoP query succeeded (elevated); no winning Group Policy entry for this value (set locally, by Local Group Policy if its registry entries are not listed in RSoP, by other tooling, or left behind by a removed GPO; MDM delivery is not detected)'
    }
}

function Format-FslPolSourceText {
    <# Formats Setting provenance for display: GroupPolicy 'name' / Registry / Unknown - <detail>. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Source,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $PolicyName,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $SourceDetail
    )

    if ($Source -eq 'GroupPolicy' -and -not [string]::IsNullOrWhiteSpace($PolicyName)) { return "GroupPolicy '$PolicyName'" }
    if ($Source -eq 'Unknown' -and -not [string]::IsNullOrWhiteSpace($SourceDetail)) { return "Unknown - $SourceDetail" }
    if ([string]::IsNullOrWhiteSpace($Source)) { return 'Unknown' }
    $Source
}

function Get-FslPolUncHost {
    <# Returns the host part of a UNC path (\\host\share), or $null. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Path
    )

    $m = [regex]::Match($Path.Trim().Trim('"'), '^\\\\([^\\/?.][^\\/]*)\\')
    if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($Path.Trim().Trim('"'), '^\\\\([^\\/?.][^\\/]*)$')
    if ($m.Success) { return $m.Groups[1].Value }
    $null
}

function Get-FslPolAzureHost {
    <#
        Returns the blob endpoint host name from a plain-text Azure Storage connection string, or $null when the
        connection string is a secure key reference (|fslogix/<key-name>|) or has no usable endpoint information.
        Uses BlobEndpoint when present, otherwise AccountName + '.blob.' + EndpointSuffix (default core.windows.net,
        as in https://<account>.blob.core.windows.net shown in the Azure Storage connection string article).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ConnectionString
    )

    $text = $ConnectionString.Trim().Trim('"')
    if ($text -match '^\|fslogix/[^|]+\|$') { return $null }

    $pairs = @{}
    foreach ($part in $text.Split(';')) {
        $index = $part.IndexOf('=')
        if ($index -gt 0) { $pairs[$part.Substring(0, $index).Trim()] = $part.Substring($index + 1).Trim() }
    }
    if ($pairs.ContainsKey('BlobEndpoint')) {
        $uri = $null
        if ([System.Uri]::TryCreate($pairs['BlobEndpoint'], [System.UriKind]::Absolute, [ref]$uri)) { return $uri.Host }
    }
    if ($pairs.ContainsKey('AccountName') -and $pairs['AccountName'] -match '^[a-z0-9]+$') {
        $suffix = 'core.windows.net'
        if ($pairs.ContainsKey('EndpointSuffix') -and -not [string]::IsNullOrWhiteSpace($pairs['EndpointSuffix'])) { $suffix = $pairs['EndpointSuffix'] }
        return ('{0}.blob.{1}' -f $pairs['AccountName'], $suffix)
    }
    $null
}

function Split-FslPolCcdProvider {
    <#
        Splits a CCDLocations string into provider entries. Providers are separated by ';'. Because a plain-text
        Azure connection string also contains ';', a segment that does not start with 'type=' is appended to the
        previous provider.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $providers = [System.Collections.Generic.List[string]]::new()
    foreach ($segment in $Text.Split(';')) {
        if ($segment.TrimStart().StartsWith('type=', [System.StringComparison]::OrdinalIgnoreCase) -or $providers.Count -eq 0) {
            $providers.Add($segment)
        }
        else {
            $providers[$providers.Count - 1] = $providers[$providers.Count - 1] + ';' + $segment
        }
    }
    foreach ($provider in $providers) {
        if (-not [string]::IsNullOrWhiteSpace($provider)) { $provider.Trim() }
    }
}

function ConvertFrom-FslPolLocationValue {
    <#
        Converts a VHDLocations or CCDLocations registry value (string or string[]) into FSLogixToolkit.StorageLocation
        objects. Paths are redacted. VHDLocations REG_SZ entries are split on ';' (documented); MULTI_SZ entries are
        taken one per element.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Profiles', 'ODFC')]
        [string] $Scope,

        [Parameter(Mandatory)]
        [ValidateSet('VHDLocations', 'CCDLocations')]
        [string] $LocationType,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Source
    )

    if ($null -eq $Value) { return }
    $isMulti = $Value -is [System.Array]
    $elements = @($Value | ForEach-Object -Process { [string]$_ })

    if ($LocationType -eq 'VHDLocations') {
        $paths = foreach ($element in $elements) {
            if ($isMulti) { $element } else { $element.Split(';') }
        }
        foreach ($rawPath in $paths) {
            $path = $rawPath.Trim()
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            $providerType = 'Unknown'
            $hostName = $null
            if ($path -match '^\\\\') {
                $providerType = 'SMB'
                $hostName = Get-FslPolUncHost -Path $path
            }
            elseif ($path -match '^[A-Za-z]:\\') { $providerType = 'Local' }
            [pscustomobject]@{
                PSTypeName   = 'FSLogixToolkit.StorageLocation'
                Scope        = $Scope
                LocationType = $LocationType
                Path         = ConvertTo-FslPolRedactedText -Text $path
                ProviderType = $providerType
                HostName     = $hostName
                Source       = $Source
            }
        }
        return
    }

    foreach ($element in $elements) {
        foreach ($provider in (Split-FslPolCcdProvider -Text $element)) {
            $providerType = 'Unknown'
            $hostName = $null
            $path = $provider
            # Parameters and values are case sensitive per FSLogix documentation (type=smb / type=azure / connectionString=).
            $typeMatch = [regex]::Match($provider, '^type=([^,]*)')
            $connectionMatch = [regex]::Match($provider, 'connectionString=(.*)$')
            if ($connectionMatch.Success) {
                $path = $connectionMatch.Groups[1].Value.Trim()
                if ($path.Length -ge 2 -and $path.StartsWith('"') -and $path.EndsWith('"')) { $path = $path.Substring(1, $path.Length - 2) }
            }
            if ($typeMatch.Success) {
                switch -CaseSensitive ($typeMatch.Groups[1].Value) {
                    'smb' {
                        if ($path -match '^\\\\') { $providerType = 'SMB'; $hostName = Get-FslPolUncHost -Path $path }
                        elseif ($path -match '^[A-Za-z]:\\') { $providerType = 'Local' }
                    }
                    'azure' {
                        $providerType = 'AzurePageBlob'
                        $hostName = Get-FslPolAzureHost -ConnectionString $path
                    }
                }
            }
            [pscustomobject]@{
                PSTypeName   = 'FSLogixToolkit.StorageLocation'
                Scope        = $Scope
                LocationType = $LocationType
                Path         = ConvertTo-FslPolRedactedText -Text $path
                ProviderType = $providerType
                HostName     = $hostName
                Source       = $Source
            }
        }
    }
}

function Get-FslPolKeyScope {
    <#
        Maps a normalized FSLogix registry key ('SOFTWARE\...') to a Result scope (contract P2.2):
        SOFTWARE\FSLogix\Profiles[\...] -> Profiles, SOFTWARE\Policies\FSLogix\ODFC[\...] -> ODFC,
        everything else (Logging, Apps, other FSLogix keys) -> General. Key paths come from Get-FslPolScopeKey
        (verified at https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $RegistryKey
    )

    $normalized = ConvertTo-FslPolNormalizedKey -Key $RegistryKey
    $scopeKeys = Get-FslPolScopeKey
    foreach ($scopeName in @('Profiles', 'ODFC')) {
        $scopeKey = [string]$scopeKeys[$scopeName]
        if ($normalized.Equals($scopeKey, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith($scopeKey + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $scopeName
        }
    }
    'General'
}

function Get-FslPolCommonScope {
    <# Returns the single Result scope shared by all given scopes (General when mixed, General or empty). #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $Scope
    )

    $distinct = @($Scope | Where-Object -FilterScript { -not [string]::IsNullOrEmpty($_) } | Sort-Object -Unique)
    if ($distinct.Count -eq 1 -and $distinct[0] -in @('Profiles', 'ODFC')) { return [string]$distinct[0] }
    'General'
}
