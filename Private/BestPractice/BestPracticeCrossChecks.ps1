# Private cross-check handlers for Invoke-FslBestPracticeAnalyzer.
# Each handler: -CrossCheck <IDictionary> -Setting <object[]> -Scope <string> -> Result[] (Category BestPractice).
# Handlers emit nothing when the check does not apply to the scope's configuration.
# Sources (verified 2026-09-17):
#   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#container-specific-settings
#   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#vhdlocations
#   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#ccdlocations
#   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#healthyprovidersrequiredforregister
#   https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#object-specific-vhdlocations

function ConvertTo-FslBpaCrossCheckResult {
    <# Creates a Result for a cross-check definition. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $CrossCheck,
        [Parameter(Mandatory)] [string] $Scope,
        [Parameter(Mandatory)] [ValidateSet('Pass', 'Warn', 'Fail', 'Info')] [string] $Status,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Expected,
        [Parameter(Mandatory)] [string] $Message
    )
    New-FslResult -Category 'BestPractice' -Check ('{0} ({1})' -f [string]$CrossCheck['Title'], $Scope) -Status $Status `
        -Target ('{0}\{1}' -f $Scope, $Target) -Value $Value -Expected $Expected `
        -Message ('[{0}] {1}' -f [string]$CrossCheck['Id'], $Message) -Recommendation ([string]$CrossCheck['Recommendation']) `
        -Source ([string]$CrossCheck['Source']) -RequiresElevation $false -Scope (ConvertTo-FslBpaResultScope -SettingScope $Scope)
}

function Get-FslBpaSettingNumber {
    <# Returns a setting's integer value, or DefaultValue when not configured or not numeric. #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Setting,
        [Parameter(Mandatory)] [string] $Scope,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [long] $DefaultValue
    )
    $found = Get-FslBpaSetting -Setting $Setting -Scope $Scope -Name $Name
    if ($null -eq $found) { return $DefaultValue }
    $number = ConvertTo-FslBpaNumber -Value (Get-FslBpaPropertyValue -InputObject $found -Name 'Value')
    if ($null -eq $number) { return $DefaultValue }
    return [long]$number
}

function Get-FslBpaLocationText {
    <# Joins a VHDLocations/CCDLocations value (REG_SZ or MULTI_SZ) into one ';'-delimited string. Returns '' when not configured. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Setting,
        [Parameter(Mandatory)] [string] $Scope,
        [Parameter(Mandatory)] [ValidateSet('VHDLocations', 'CCDLocations')] [string] $Name
    )
    $found = Get-FslBpaSetting -Setting $Setting -Scope $Scope -Name $Name
    if ($null -eq $found) { return '' }
    $value = Get-FslBpaPropertyValue -InputObject $found -Name 'Value'
    if ($null -eq $value) { return '' }
    $parts = @($value) | ForEach-Object -Process { [string]$_ } | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) }
    return (@($parts) -join ';')
}

function Test-FslBpaLocationConfigured {
    <# $true when the location value exists and contains at least one non-empty entry. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Setting,
        [Parameter(Mandatory)] [string] $Scope,
        [Parameter(Mandatory)] [ValidateSet('VHDLocations', 'CCDLocations')] [string] $Name
    )
    $text = Get-FslBpaLocationText -Setting $Setting -Scope $Scope -Name $Name
    return (@($text.Split(';') | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)
}

function Get-FslBpaCcdProvider {
    <#
        Splits a CCDLocations string into provider definitions. Providers are 'type=<smb|azure>,...' entries
        separated by ';' (parameters are case sensitive per Microsoft docs). A ';' that is not followed by
        'type=' is treated as part of the previous provider (for example inside a plain-text connection string).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $providers = [regex]::Split($Text, ';(?=\s*type=)') |
        ForEach-Object -Process { $_.Trim().TrimEnd(';') } |
        Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) }
    return [string[]]@($providers)
}

function Test-FslBpaLocationConflict {
    <# VHDLocations and CCDLocations must not both be present at the same time. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $CrossCheck,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Setting,
        [Parameter(Mandatory)] [string] $Scope
    )
    $hasVhd = $null -ne (Get-FslBpaSetting -Setting $Setting -Scope $Scope -Name 'VHDLocations')
    $hasCcd = $null -ne (Get-FslBpaSetting -Setting $Setting -Scope $Scope -Name 'CCDLocations')
    if (-not ($hasVhd -or $hasCcd)) { return }
    $value = 'VHDLocations={0}; CCDLocations={1}' -f $(if ($hasVhd) { 'present' } else { 'absent' }), $(if ($hasCcd) { 'present' } else { 'absent' })
    if ($hasVhd -and $hasCcd) {
        ConvertTo-FslBpaCrossCheckResult -CrossCheck $CrossCheck -Scope $Scope -Status ([string]$CrossCheck['Severity']) -Target 'VHDLocations+CCDLocations' `
            -Value $value -Expected 'Only one of VHDLocations or CCDLocations' -Message 'Both VHDLocations and CCDLocations are present.'
    }
    else {
        ConvertTo-FslBpaCrossCheckResult -CrossCheck $CrossCheck -Scope $Scope -Status 'Pass' -Target 'VHDLocations+CCDLocations' `
            -Value $value -Expected 'Only one of VHDLocations or CCDLocations' -Message 'Only one location type is configured.'
    }
}

function Test-FslBpaMissingLocation {
    <# When containers are enabled (Enabled = 1; documented default 0), VHDLocations or CCDLocations must be configured. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $CrossCheck,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Setting,
        [Parameter(Mandatory)] [string] $Scope
    )
    if ((Get-FslBpaSettingNumber -Setting $Setting -Scope $Scope -Name 'Enabled' -DefaultValue 0) -ne 1) { return }
    $hasVhd = Test-FslBpaLocationConfigured -Setting $Setting -Scope $Scope -Name 'VHDLocations'
    $hasCcd = Test-FslBpaLocationConfigured -Setting $Setting -Scope $Scope -Name 'CCDLocations'
    if ($hasVhd -or $hasCcd) {
        $which = @(if ($hasVhd) { 'VHDLocations' }; if ($hasCcd) { 'CCDLocations' }) -join ', '
        ConvertTo-FslBpaCrossCheckResult -CrossCheck $CrossCheck -Scope $Scope -Status 'Pass' -Target 'Enabled' `
            -Value "Enabled=1; $which configured" -Expected 'VHDLocations or CCDLocations configured' -Message "$which configured."
    }
    else {
        ConvertTo-FslBpaCrossCheckResult -CrossCheck $CrossCheck -Scope $Scope -Status ([string]$CrossCheck['Severity']) -Target 'Enabled' `
            -Value 'Enabled=1; no VHDLocations or CCDLocations' -Expected 'VHDLocations or CCDLocations configured' `
            -Message 'Containers are enabled but no VHDLocations or CCDLocations value is configured.'
    }
}

function Test-FslBpaMultipleVhdLocation {
    <# Multiple VHDLocations entries do not provide resiliency (Info). Location paths are not echoed; only the count. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $CrossCheck,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Setting,
        [Parameter(Mandatory)] [string] $Scope
    )
    $text = Get-FslBpaLocationText -Setting $Setting -Scope $Scope -Name 'VHDLocations'
    $entries = @($text.Split(';') | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) })
    if ($entries.Count -eq 0) { return }
    if ($entries.Count -gt 1) {
        ConvertTo-FslBpaCrossCheckResult -CrossCheck $CrossCheck -Scope $Scope -Status ([string]$CrossCheck['Severity']) -Target 'VHDLocations' `
            -Value "$($entries.Count) entries" -Expected '1 entry (or object-specific settings)' `
            -Message "VHDLocations contains $($entries.Count) entries. Users with access to more than one location may create a new profile in another location if their profile location is unavailable."
    }
    else {
        ConvertTo-FslBpaCrossCheckResult -CrossCheck $CrossCheck -Scope $Scope -Status 'Pass' -Target 'VHDLocations' `
            -Value '1 entry' -Expected '1 entry (or object-specific settings)' -Message 'VHDLocations contains a single entry.'
    }
}

function Test-FslBpaCcdProviderCount {
    <# CCDLocations supports up to four remote container locations. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $CrossCheck,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Setting,
        [Parameter(Mandatory)] [string] $Scope
    )
    $text = Get-FslBpaLocationText -Setting $Setting -Scope $Scope -Name 'CCDLocations'
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $count = @(Get-FslBpaCcdProvider -Text $text).Count
    $status = if ($count -le 4) { 'Pass' } else { [string]$CrossCheck['Severity'] }
    ConvertTo-FslBpaCrossCheckResult -CrossCheck $CrossCheck -Scope $Scope -Status $status -Target 'CCDLocations' `
        -Value "$count provider(s)" -Expected '<= 4 providers' -Message "CCDLocations defines $count provider(s)."
}

function Test-FslBpaCcdAzureProtectedKey {
    <#
        Azure page blob providers should reference a protected key (connectionString="|keyname|") rather than a
        plain-text connection string. The connection string itself is never written to output or logs.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $CrossCheck,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Setting,
        [Parameter(Mandatory)] [string] $Scope
    )
    $text = Get-FslBpaLocationText -Setting $Setting -Scope $Scope -Name 'CCDLocations'
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $azureProviders = @(Get-FslBpaCcdProvider -Text $text | Where-Object -FilterScript { $_ -match '^\s*type=azure\s*(,|$)' })
    if ($azureProviders.Count -eq 0) { return }
    $unprotected = 0
    foreach ($provider in $azureProviders) {
        $match = [regex]::Match($provider, 'connectionString=(?<cs>.*)$')
        $connection = if ($match.Success) { $match.Groups['cs'].Value.Trim() } else { '' }
        if ($connection -notmatch '^"?\|[^|]+\|"?$') { $unprotected++ }
    }
    if ($unprotected -eq 0) {
        ConvertTo-FslBpaCrossCheckResult -CrossCheck $CrossCheck -Scope $Scope -Status 'Pass' -Target 'CCDLocations' `
            -Value "$($azureProviders.Count) azure provider(s), all protected-key references" -Expected 'connectionString="|<key name>|"' `
            -Message 'All Azure providers reference a protected key.'
    }
    else {
        ConvertTo-FslBpaCrossCheckResult -CrossCheck $CrossCheck -Scope $Scope -Status ([string]$CrossCheck['Severity']) -Target 'CCDLocations' `
            -Value "$unprotected of $($azureProviders.Count) azure provider(s) not a protected-key reference" -Expected 'connectionString="|<key name>|"' `
            -Message "$unprotected Azure provider(s) do not use a protected-key reference (or the value was redacted and could not be verified). The connection string is not shown."
    }
}

function Test-FslBpaRegisterLoginExperience {
    <# HealthyProvidersRequiredForRegister (default 0) non-zero -> PreventLoginWithFailure and/or PreventLoginWithTempProfile (defaults 0) should be used. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $CrossCheck,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Setting,
        [Parameter(Mandatory)] [string] $Scope
    )
    if (-not (Test-FslBpaLocationConfigured -Setting $Setting -Scope $Scope -Name 'CCDLocations')) { return }
    $register = Get-FslBpaSettingNumber -Setting $Setting -Scope $Scope -Name 'HealthyProvidersRequiredForRegister' -DefaultValue 0
    if ($register -eq 0) { return }
    $failure = Get-FslBpaSettingNumber -Setting $Setting -Scope $Scope -Name 'PreventLoginWithFailure' -DefaultValue 0
    $temp = Get-FslBpaSettingNumber -Setting $Setting -Scope $Scope -Name 'PreventLoginWithTempProfile' -DefaultValue 0
    $value = 'HealthyProvidersRequiredForRegister={0}; PreventLoginWithFailure={1}; PreventLoginWithTempProfile={2}' -f $register, $failure, $temp
    $expected = 'PreventLoginWithFailure=1 and/or PreventLoginWithTempProfile=1'
    if ($failure -eq 1 -or $temp -eq 1) {
        ConvertTo-FslBpaCrossCheckResult -CrossCheck $CrossCheck -Scope $Scope -Status 'Pass' -Target 'HealthyProvidersRequiredForRegister' `
            -Value $value -Expected $expected -Message 'A prevent-login setting is enabled together with HealthyProvidersRequiredForRegister.'
    }
    else {
        ConvertTo-FslBpaCrossCheckResult -CrossCheck $CrossCheck -Scope $Scope -Status ([string]$CrossCheck['Severity']) -Target 'HealthyProvidersRequiredForRegister' `
            -Value $value -Expected $expected -Message 'HealthyProvidersRequiredForRegister is non-zero but neither PreventLoginWithFailure nor PreventLoginWithTempProfile is enabled (unconfigured values use documented default 0).'
    }
}
