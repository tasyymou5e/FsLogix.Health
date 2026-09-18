# Private registry wrappers and registry repair handlers (Agent P3-5, prefix *-FslFix*).
#
# All reads and writes use the 64-bit view (Microsoft.Win32.RegistryKey.OpenBaseKey(LocalMachine, Registry64)) and
# preserve the documented value kind. Only value names on the allow-list below may be written or removed; the storage
# location values (VHDLocations, CCDLocations) are explicitly denied and are never touched by a repair.
#
# Sources:
#   https://learn.microsoft.com/dotnet/api/microsoft.win32.registrykey.openbasekey
#   https://learn.microsoft.com/dotnet/api/microsoft.win32.registrykey.setvalue
#   https://learn.microsoft.com/dotnet/api/microsoft.win32.registrykey.deletevalue
#   https://learn.microsoft.com/dotnet/api/microsoft.win32.registryvaluekind
#   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
#     (Log settings: HKEY_LOCAL_MACHINE\SOFTWARE\FSLogix\Logging; ODFC settings: SOFTWARE\Policies\FSLogix\ODFC)
#   https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates

# Allow-list: repairs may only touch these value names under these keys (contract P3.4: repairable registry value
# names are an allow-list). Keys are compared without the HKLM prefix, case-insensitively.
$script:FslFixRegistryAllowList = @{
    'SOFTWARE\FSLogix\Logging'        = @('LoggingEnabled', 'LoggingLevel', 'LogFileKeepingPeriod', 'RobocopyLogPath')
    'SOFTWARE\Policies\FSLogix\ODFC'  = @('RefreshUserPolicy')
}
# Never writable by any repair, whatever the catalog says (container storage locations).
$script:FslFixRegistryDenyList = @('VHDLocations', 'CCDLocations')
# Value kinds a repair may write.
$script:FslFixRegistryWritableKinds = @('DWord', 'QWord', 'String', 'ExpandString', 'MultiString')

function Test-FslFixRegistryTarget {
    <#
    .SYNOPSIS
        Verifies a registry target against the repair allow-list. Returns @{ Ok; Message }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Key,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ValueName,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $ValueKind
    )

    $normalizedKey = ([string]$Key).Trim().TrimStart('\').TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($normalizedKey) -or [string]::IsNullOrWhiteSpace($ValueName)) {
        return @{ Ok = $false; Message = 'The repair target has no registry key or value name.' }
    }
    foreach ($denied in $script:FslFixRegistryDenyList) {
        if ([string]::Equals($denied, $ValueName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return @{ Ok = $false; Message = "The value '$ValueName' holds container storage locations and is never changed by a repair." }
        }
    }
    $match = @($script:FslFixRegistryAllowList.Keys | Where-Object -FilterScript { [string]::Equals([string]$_, $normalizedKey, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($match.Count -eq 0) {
        return @{ Ok = $false; Message = "The registry key HKLM\$normalizedKey is not on the repair allow-list." }
    }
    $allowedNames = @($script:FslFixRegistryAllowList[$match[0]])
    if (@($allowedNames | Where-Object -FilterScript { [string]::Equals([string]$_, $ValueName, [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
        return @{ Ok = $false; Message = "The value '$ValueName' under HKLM\$normalizedKey is not on the repair allow-list." }
    }
    if (-not [string]::IsNullOrWhiteSpace($ValueKind) -and $script:FslFixRegistryWritableKinds -notcontains $ValueKind) {
        return @{ Ok = $false; Message = "The value kind '$ValueKind' is not written by repairs." }
    }
    return @{ Ok = $true; Message = "HKLM\$normalizedKey\$ValueName is on the repair allow-list." }
}

function Get-FslFixRegistryEntry {
    <#
    .SYNOPSIS
        Reads one HKLM value (64-bit view). Returns @{ Key; ValueName; Path; Exists; Value; ValueKind; Message }.
    .DESCRIPTION
        Windows only; on other platforms Exists is $false and Message explains why (tests replace this wrapper).
        Never throws: read problems are recorded and reported in Message with Exists = $false.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Key,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ValueName
    )

    $normalizedKey = $Key.Trim().TrimStart('\').TrimEnd('\')
    $result = @{
        Key       = $normalizedKey
        ValueName = $ValueName
        Path      = "HKLM\$normalizedKey\$ValueName"
        Exists    = $false
        Value     = $null
        ValueKind = $null
        Message   = $null
    }
    if (-not (Test-FslIsWindows)) {
        $result['Message'] = 'The registry is only available on Windows.'
        return $result
    }

    $baseKey = $null
    $subKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $subKey = $baseKey.OpenSubKey($normalizedKey, $false)
        if ($null -eq $subKey) {
            $result['Message'] = "The registry key HKLM\$normalizedKey does not exist."
            return $result
        }
        $names = @($subKey.GetValueNames() | Where-Object -FilterScript { [string]::Equals([string]$_, $ValueName, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($names.Count -eq 0) {
            $result['Message'] = "The value $ValueName does not exist under HKLM\$normalizedKey."
            return $result
        }
        $actualName = [string]$names[0]
        $kind = $subKey.GetValueKind($actualName)
        $raw = $subKey.GetValue($actualName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $result['Exists'] = $true
        $result['ValueName'] = $actualName
        $result['ValueKind'] = [string]$kind
        $result['Value'] = switch ([string]$kind) {
            'DWord' { [int]$raw }
            'QWord' { [long]$raw }
            'MultiString' { , ([string[]]$raw) }
            'Binary' { , ([byte[]]$raw) }
            default { [string]$raw }
        }
        $result['Message'] = "Read HKLM\$normalizedKey\$actualName."
        return $result
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Read registry value HKLM\$normalizedKey\$ValueName"
        $result['Message'] = "The value could not be read: $($_.Exception.Message)"
        return $result
    }
    finally {
        if ($null -ne $subKey) { $subKey.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function ConvertTo-FslFixRegistryValue {
    <#
    .SYNOPSIS
        Converts a catalog/rollback value to the .NET type that matches the registry value kind. Throws on a bad value.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'MultiString')]
        [string] $ValueKind
    )

    switch ($ValueKind) {
        'DWord' { return [int]$Value }
        'QWord' { return [long]$Value }
        'MultiString' { return , ([string[]]@($Value | ForEach-Object -Process { [string]$_ })) }
        default { return [string]$Value }
    }
}

function Set-FslFixRegistryEntry {
    <#
    .SYNOPSIS
        Writes one HKLM value (64-bit view) with the given value kind. Returns @{ Success; Message }.
    .DESCRIPTION
        The registry key must already exist (the FSLogix installer creates the base keys); a repair never creates keys.
        Internal repair write inside an already confirmed run - the caller owns ShouldProcess.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Low-level wrapper; ShouldProcess is handled by Invoke-FslRepair/Undo-FslRepair before the call.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Key,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ValueName,

        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'MultiString')]
        [string] $ValueKind
    )

    $normalizedKey = $Key.Trim().TrimStart('\').TrimEnd('\')
    $allowed = Test-FslFixRegistryTarget -Key $normalizedKey -ValueName $ValueName -ValueKind $ValueKind
    if (-not $allowed['Ok']) { return @{ Success = $false; Message = $allowed['Message'] } }
    if (-not (Test-FslIsWindows)) { return @{ Success = $false; Message = 'The registry is only available on Windows.' } }

    $baseKey = $null
    $subKey = $null
    try {
        $typed = ConvertTo-FslFixRegistryValue -Value $Value -ValueKind $ValueKind
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $subKey = $baseKey.OpenSubKey($normalizedKey, $true)
        if ($null -eq $subKey) {
            return @{ Success = $false; Message = "The registry key HKLM\$normalizedKey does not exist; a repair never creates registry keys." }
        }
        $subKey.SetValue($ValueName, $typed, [Microsoft.Win32.RegistryValueKind]::$ValueKind)
        return @{ Success = $true; Message = "Wrote HKLM\$normalizedKey\$ValueName ($ValueKind)." }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Write registry value HKLM\$normalizedKey\$ValueName"
        return @{ Success = $false; Message = "The value could not be written: $($_.Exception.Message)" }
    }
    finally {
        if ($null -ne $subKey) { $subKey.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Remove-FslFixRegistryEntry {
    <#
    .SYNOPSIS
        Deletes one HKLM value (64-bit view). Returns @{ Success; Message }. A missing value is a success (nothing to do).
    .DESCRIPTION
        Only values, never keys. Internal repair write inside an already confirmed run - the caller owns ShouldProcess.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Low-level wrapper; ShouldProcess is handled by Invoke-FslRepair/Undo-FslRepair before the call.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Key,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ValueName
    )

    $normalizedKey = $Key.Trim().TrimStart('\').TrimEnd('\')
    $allowed = Test-FslFixRegistryTarget -Key $normalizedKey -ValueName $ValueName
    if (-not $allowed['Ok']) { return @{ Success = $false; Message = $allowed['Message'] } }
    if (-not (Test-FslIsWindows)) { return @{ Success = $false; Message = 'The registry is only available on Windows.' } }

    $baseKey = $null
    $subKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $subKey = $baseKey.OpenSubKey($normalizedKey, $true)
        if ($null -eq $subKey) { return @{ Success = $true; Message = "The registry key HKLM\$normalizedKey does not exist; nothing to remove." } }
        $subKey.DeleteValue($ValueName, $false)
        return @{ Success = $true; Message = "Removed HKLM\$normalizedKey\$ValueName." }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Remove registry value HKLM\$normalizedKey\$ValueName"
        return @{ Success = $false; Message = "The value could not be removed: $($_.Exception.Message)" }
    }
    finally {
        if ($null -ne $subKey) { $subKey.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Get-FslFixProvenance {
    <#
    .SYNOPSIS
        Returns where an FSLogix registry value comes from: @{ Source; PolicyName; SourceDetail; Present }.
    .DESCRIPTION
        Uses the three-state provenance of Get-FslEffectiveSetting (contract P3.1): GroupPolicy, Registry or Unknown
        (MDM is reserved and not detected). When the value is not present at all, the computer RSoP state
        (Get-FslPolRsopState) decides: Ok -> Registry (no policy entry, safe to write), anything else -> Unknown.
        Unknown always blocks a registry repair.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Profiles', 'ODFC', 'Logging', 'Apps')]
        [string] $SettingScope,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ValueName
    )

    $result = @{ Source = 'Unknown'; PolicyName = $null; SourceDetail = 'Group Policy provenance not checked'; Present = $false }
    try {
        foreach ($setting in @(Get-FslEffectiveSetting -Scope $SettingScope)) {
            if (-not [string]::Equals([string](Get-FslFixValue -InputObject $setting -Name 'Name'), $ValueName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $result['Present'] = $true
            $result['Source'] = [string](Get-FslFixValue -InputObject $setting -Name 'Source')
            $result['PolicyName'] = Get-FslFixValue -InputObject $setting -Name 'PolicyName'
            $result['SourceDetail'] = [string](Get-FslFixValue -InputObject $setting -Name 'SourceDetail')
            return $result
        }
        # The value is not configured, so Get-FslEffectiveSetting emitted no row for it. Only the RSoP state can say
        # whether Group Policy provenance was checkable - and the RSoP rows must still be searched: a policy that
        # DELETES a value (RSOP_RegistryPolicySetting.deleted, "Indicates whether the registry key or registry value
        # has been deleted") is also a value Group Policy owns, and writing it would be undone at the next refresh.
        $rsop = Get-FslPolRsopState
        if ([string](Get-FslFixValue -InputObject $rsop -Name 'Status') -ne 'Ok') {
            $result['SourceDetail'] = [string](Get-FslFixValue -InputObject $rsop -Name 'Detail')
            return $result
        }
        $subKey = [string]((Get-FslPolScopeKey)[$SettingScope])
        $policyRow = @($rsop.Rows | Where-Object -FilterScript {
                $null -ne $_ -and $_.Precedence -eq 1 -and
                [string]::Equals([string]$_.RegistryKey, $subKey, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$_.ValueName, $ValueName, [System.StringComparison]::OrdinalIgnoreCase)
            }) | Select-Object -First 1
        if ($null -ne $policyRow) {
            $label = if ($policyRow.GpoName) { [string]$policyRow.GpoName } else { [string]$policyRow.GpoId }
            $result['Source'] = 'GroupPolicy'
            $result['PolicyName'] = $policyRow.GpoName
            $result['SourceDetail'] = if ([bool]$policyRow.Deleted) {
                "The value is not configured because a winning computer Group Policy entry from GPO '$label' removes it"
            }
            else {
                "The value is not configured but a winning computer Group Policy entry from GPO '$label' controls it"
            }
            return $result
        }
        $result['Source'] = 'Registry'
        $result['SourceDetail'] = 'The value is not configured and the computer RSoP query succeeded (no Group Policy entry for it).'
        return $result
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Determine provenance of $SettingScope\$ValueName"
        $result['Source'] = 'Unknown'
        $result['SourceDetail'] = "Provenance could not be determined: $($_.Exception.Message)"
        return $result
    }
}

function Test-FslFixRegistryTrigger {
    <#
    .SYNOPSIS
        Returns $true when the catalog Trigger of a registry action matches the current value.
    .DESCRIPTION
        Trigger types: ValuePresent (the value exists), ValueEquals, ValueNotEquals, ValueGreaterThan (numeric,
        value present), ValueMissingOrNotEquals (the value is missing or differs). Non-numeric values never match a
        numeric trigger.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Trigger,

        [Parameter(Mandatory)]
        [hashtable] $Entry
    )

    $type = [string](Get-FslFixValue -InputObject $Trigger -Name 'Type')
    $exists = [bool]$Entry['Exists']
    $expected = Get-FslFixValue -InputObject $Trigger -Name 'Value'
    $styles = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $currentNumber = [double]0
    $currentIsNumber = $false
    if ($exists) { $currentIsNumber = [double]::TryParse([string]$Entry['Value'], $styles, $culture, [ref]$currentNumber) }
    $expectedNumber = [double]0
    $expectedIsNumber = [double]::TryParse([string]$expected, $styles, $culture, [ref]$expectedNumber)
    $numbersEqual = ($currentIsNumber -and $expectedIsNumber -and $currentNumber -eq $expectedNumber)

    switch ($type) {
        'ValuePresent' { return $exists }
        'ValueEquals' { return ($exists -and $numbersEqual) }
        'ValueNotEquals' { return ($exists -and -not $numbersEqual) }
        'ValueGreaterThan' { return ($exists -and $currentIsNumber -and $expectedIsNumber -and $currentNumber -gt $expectedNumber) }
        'ValueMissingOrNotEquals' { return (-not $exists -or -not $numbersEqual) }
        default {
            Write-FslLog -Message "Unknown repair trigger type '$type'; the action is treated as not needed." -Level Warning -Component 'Repair'
            return $false
        }
    }
}

function Get-FslFixRegistryState {
    <#
    .SYNOPSIS
        Detect handler for registry repairs (contract P3.5 handler interface).
    .DESCRIPTION
        Returns [pscustomobject] Needed, CurrentValue, ProposedValue, Target, BeforeState, BlockReason, GuidanceOnly,
        Guidance, Message. Group Policy provenance -> GuidanceOnly (change it in Local Group Policy instead);
        Unknown provenance (not elevated, RSoP failed or unavailable) -> BlockReason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition,

        [hashtable] $Parameters = @{}
    )

    $null = $Parameters
    $target = Get-FslFixDefinitionValue -Definition $Definition -Name 'Target' -Default @{}
    $key = [string](Get-FslFixValue -InputObject $target -Name 'Key')
    $valueName = [string](Get-FslFixValue -InputObject $target -Name 'ValueName')
    $valueKind = [string](Get-FslFixValue -InputObject $target -Name 'ValueKind')
    $path = 'HKLM\{0}\{1}' -f $key.Trim('\'), $valueName
    $operation = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'Operation' -Default 'Set')
    $proposedText = [string](ConvertTo-FslCoreResultString -InputObject (Get-FslFixDefinitionValue -Definition $Definition -Name 'ProposedValue' -Default ''))
    $documentedDefault = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'DocumentedDefault' -Default '')

    $detection = [pscustomobject]@{
        Needed        = $false
        CurrentValue  = $null
        ProposedValue = $proposedText
        Target        = $path
        BeforeState   = $null
        BlockReason   = $null
        GuidanceOnly  = $false
        Guidance      = $null
        Message       = $null
    }

    $allowed = Test-FslFixRegistryTarget -Key $key -ValueName $valueName -ValueKind $valueKind
    if (-not $allowed['Ok']) {
        $detection.BlockReason = $allowed['Message']
        $detection.Message = $allowed['Message']
        return $detection
    }

    $entry = Get-FslFixRegistryEntry -Key $key -ValueName $valueName
    $beforeState = @{
        Kind      = 'RegistryValue'
        Hive      = 'HKLM'
        Key       = $key.Trim('\')
        ValueName = $valueName
        Path      = $path
        Exists    = [bool]$entry['Exists']
        Value     = $entry['Value']
        ValueKind = if ($entry['Exists']) { [string]$entry['ValueKind'] } else { $valueKind }
    }
    $detection.BeforeState = $beforeState
    $detection.CurrentValue = if ($entry['Exists']) { ConvertTo-FslCoreResultString -InputObject $entry['Value'] } else { '(not configured)' }

    $trigger = Get-FslFixDefinitionValue -Definition $Definition -Name 'Trigger' -Default @{ Type = 'ValuePresent' }
    $needed = Test-FslFixRegistryTrigger -Trigger ([hashtable]$trigger) -Entry $entry
    $detection.Needed = $needed

    $defaultText = if ([string]::IsNullOrWhiteSpace($documentedDefault)) { '' } else { " Documented default: $documentedDefault." }
    if (-not $needed) {
        $detection.Message = if ($operation -eq 'Remove') {
            "$path is not configured or does not match the condition; nothing to remove.$defaultText"
        }
        else {
            "$path already matches the documented state ($($detection.CurrentValue)).$defaultText"
        }
        return $detection
    }

    $provenance = Get-FslFixProvenance -SettingScope ([string](Get-FslFixDefinitionValue -Definition $Definition -Name 'SettingScope' -Default 'Logging')) -ValueName $valueName
    switch ([string]$provenance['Source']) {
        'GroupPolicy' {
            $detection.GuidanceOnly = $true
            $detection.Guidance = Get-FslFixGroupPolicyGuidance -RegistryPath $path -PolicyName ([string]$provenance['PolicyName']) -ProposedValue $proposedText
            $detection.Message = "$path is currently $($detection.CurrentValue) and is delivered by Group Policy ($([string]$provenance['SourceDetail'])); the registry is not written."
        }
        'Registry' {
            $detection.Message = "$path is $($detection.CurrentValue); the repair would set it to $proposedText.$defaultText"
        }
        default {
            $detection.BlockReason = "Group Policy provenance of $path is Unknown ($([string]$provenance['SourceDetail'])). Run elevated so Group Policy provenance can be checked; a value delivered by Group Policy must be changed in Local Group Policy."
            $detection.Message = $detection.BlockReason
        }
    }
    return $detection
}

function Set-FslFixRegistryState {
    <#
    .SYNOPSIS
        Apply handler for registry repairs (contract P3.5 handler interface).
    .DESCRIPTION
        Returns @{ Success; AfterState; Created; Message }. Operation 'Remove' deletes the value; 'Set' writes the
        catalog ProposedValue with the documented value kind. Created lists the registry path when the value did not
        exist before, so Undo removes it again. Temporary actions (Config/Repairs.psd1 Temporary = $true) carry
        Temporary/ExpiresAt in the after state so the rollback store keeps the run until the change is reverted.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Handler called by Invoke-FslRepair after ShouldProcess, preflight and a verified rollback entry.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition,

        [Parameter(Mandatory)]
        [pscustomobject] $Action,

        [Parameter(Mandatory)]
        [hashtable] $BeforeState
    )

    $null = $Action
    $key = [string]$BeforeState['Key']
    $valueName = [string]$BeforeState['ValueName']
    $path = [string]$BeforeState['Path']
    $operation = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'Operation' -Default 'Set')
    $target = Get-FslFixDefinitionValue -Definition $Definition -Name 'Target' -Default @{}
    $valueKind = [string](Get-FslFixValue -InputObject $target -Name 'ValueKind')
    $created = @()

    if ($operation -eq 'Remove') {
        $outcome = Remove-FslFixRegistryEntry -Key $key -ValueName $valueName
    }
    else {
        if (-not [bool]$BeforeState['Exists']) { $created = @($path) }
        $outcome = Set-FslFixRegistryEntry -Key $key -ValueName $valueName -Value (Get-FslFixDefinitionValue -Definition $Definition -Name 'ProposedValue' -Default $null) -ValueKind $valueKind
    }

    $entry = Get-FslFixRegistryEntry -Key $key -ValueName $valueName
    $afterState = @{
        Kind      = 'RegistryValue'
        Hive      = 'HKLM'
        Key       = $key
        ValueName = $valueName
        Path      = $path
        Exists    = [bool]$entry['Exists']
        Value     = $entry['Value']
        ValueKind = if ($entry['Exists']) { [string]$entry['ValueKind'] } else { $valueKind }
    }
    if ([bool](Get-FslFixDefinitionValue -Definition $Definition -Name 'Temporary' -Default $false)) {
        $afterState['Temporary'] = $true
        $afterState['ExpiresAt'] = (Get-FslFixTemporaryExpiry -Definition $Definition).ToString('o')
    }

    return @{
        Success    = [bool]$outcome['Success']
        AfterState = $afterState
        Created    = $created
        Message    = [string]$outcome['Message']
    }
}

function Restore-FslFixRegistryState {
    <#
    .SYNOPSIS
        Rollback handler for registry repairs (contract P3.5 handler interface). Returns @{ Success; Message }.
    .DESCRIPTION
        Restores the exact previous value and value kind. When the value did not exist before the repair (the repair
        created it) the value is removed again.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Handler called by Undo-FslRepair after ShouldProcess and the rollback-store integrity check.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition,

        [Parameter(Mandatory)]
        [hashtable] $BeforeState,

        [AllowNull()]
        [hashtable] $AfterState
    )

    $null = $Definition
    $null = $AfterState
    $key = [string]$BeforeState['Key']
    $valueName = [string]$BeforeState['ValueName']
    $path = [string]$BeforeState['Path']

    if (-not [bool]$BeforeState['Exists']) {
        $outcome = Remove-FslFixRegistryEntry -Key $key -ValueName $valueName
        return @{ Success = [bool]$outcome['Success']; Message = "The repair created $path; it was removed again. $([string]$outcome['Message'])" }
    }
    $valueKind = [string]$BeforeState['ValueKind']
    if ($script:FslFixRegistryWritableKinds -notcontains $valueKind) {
        return @{ Success = $false; Message = "The recorded value kind '$valueKind' of $path cannot be restored by the toolkit." }
    }
    $outcome = Set-FslFixRegistryEntry -Key $key -ValueName $valueName -Value $BeforeState['Value'] -ValueKind $valueKind
    return @{ Success = [bool]$outcome['Success']; Message = "Restored $path to the recorded value. $([string]$outcome['Message'])" }
}

function Get-FslFixTemporaryExpiry {
    <#
    .SYNOPSIS
        Returns the expiry [datetime] of a temporary change (now + Settings Repair.<TemporaryHoursSetting>, default 24 h).
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition
    )

    $hours = 24
    $settingName = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'TemporaryHoursSetting' -Default 'TemporaryLoggingMaxHours')
    try {
        $config = Get-FslFixConfig
        if ($config.ContainsKey($settingName)) {
            $parsed = 0
            if ([int]::TryParse([string]$config[$settingName], [ref]$parsed) -and $parsed -gt 0) { $hours = $parsed }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Read Repair.$settingName"
    }
    return (Get-Date).AddHours($hours)
}
