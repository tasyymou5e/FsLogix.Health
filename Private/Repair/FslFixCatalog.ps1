# Private helpers for the repair catalog and the FSLogixToolkit.RepairAction shape (Agent P3-5, prefix *-FslFix*).
#
# Data: Config/Repairs.psd1 (see that file for the entry keys and the verified Microsoft sources).
# Nothing here changes state; the catalog is read-only and usable by a standard user.
#
# Sources:
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/import-powershelldatafile
#   https://learn.microsoft.com/dotnet/api/system.security.cryptography.sha256.hashdata
#   https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates
#     (Local Group Policy Editor: "Browse to Computer Configuration then Administrative Templates then FSLogix.")

$script:FslFixActionKinds = @('RegistryValue', 'ServiceStartType', 'ServiceStart', 'Container')
$script:FslFixActionScopes = @('General', 'ODFC', 'Profiles')
$script:FslFixActionStatuses = @('Ready', 'Blocked', 'NotNeeded', 'GuidanceOnly')
$script:FslFixRollbackMethods = @('RestoreValue', 'RestoreStartType', 'MoveBack', 'None')
$script:FslFixEffectiveWhenValues = @('Immediate', 'ServiceRestart', 'NextSignIn', 'Reboot', 'Unknown')
$script:FslFixCatalogCache = $null

# Verified Group Policy editor path for FSLogix administrative template settings (how-to-use-group-policy-templates).
$script:FslFixGroupPolicyPath = 'gpedit.msc > Computer Configuration > Administrative Templates > FSLogix'
$script:FslFixGroupPolicySource = 'https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates'

function Get-FslFixCatalog {
    <#
    .SYNOPSIS
        Returns the repair catalog from Config/Repairs.psd1 as @{ DataVerifiedOn; Actions }. Cached per session.
    .DESCRIPTION
        Entries with an unknown Kind, Scope, RollbackMethod or EffectiveWhen, a missing Id/Detect/Apply or a duplicate
        Id are dropped with a warning so a damaged data file can never produce an unexpected change. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [switch] $Refresh
    )

    if (-not $Refresh -and $null -ne $script:FslFixCatalogCache) { return $script:FslFixCatalogCache }

    $catalog = @{ DataVerifiedOn = $null; Actions = @() }
    try {
        $data = Get-FslDataFile -Name 'Repairs'
        if ($null -eq $data -or -not ($data -is [System.Collections.IDictionary]) -or -not $data.Contains('Actions')) {
            Write-FslLog -Message 'Config/Repairs.psd1 is missing or has no Actions list; the repair catalog is empty.' -Level Warning -Component 'Repair'
            $script:FslFixCatalogCache = $catalog
            return $catalog
        }
        if ($data.Contains('DataVerifiedOn')) { $catalog['DataVerifiedOn'] = [string]$data['DataVerifiedOn'] }

        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $actions = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($entry in @($data['Actions'])) {
            if ($null -eq $entry -or -not ($entry -is [System.Collections.IDictionary])) { continue }
            $id = [string](Get-FslFixValue -InputObject $entry -Name 'Id')
            $kind = [string](Get-FslFixValue -InputObject $entry -Name 'Kind')
            $scope = [string](Get-FslFixValue -InputObject $entry -Name 'Scope')
            $rollbackMethod = [string](Get-FslFixValue -InputObject $entry -Name 'RollbackMethod')
            $effectiveWhen = [string](Get-FslFixValue -InputObject $entry -Name 'EffectiveWhen')
            $detect = [string](Get-FslFixValue -InputObject $entry -Name 'Detect')
            $apply = [string](Get-FslFixValue -InputObject $entry -Name 'Apply')
            $reason = $null
            if ([string]::IsNullOrWhiteSpace($id)) { $reason = 'no Id' }
            elseif (-not $seen.Add($id)) { $reason = 'duplicate Id' }
            elseif ($script:FslFixActionKinds -notcontains $kind) { $reason = "unknown Kind '$kind'" }
            elseif ($script:FslFixActionScopes -notcontains $scope) { $reason = "unknown Scope '$scope'" }
            elseif ($script:FslFixRollbackMethods -notcontains $rollbackMethod) { $reason = "unknown RollbackMethod '$rollbackMethod'" }
            elseif ($script:FslFixEffectiveWhenValues -notcontains $effectiveWhen) { $reason = "unknown EffectiveWhen '$effectiveWhen'" }
            elseif ([string]::IsNullOrWhiteSpace($detect) -or [string]::IsNullOrWhiteSpace($apply)) { $reason = 'no Detect/Apply handler' }
            if ($null -ne $reason) {
                Write-FslLog -Message "Repair catalog entry '$id' ignored: $reason." -Level Warning -Component 'Repair'
                continue
            }
            $normalized = @{}
            foreach ($key in $entry.Keys) { $normalized[[string]$key] = $entry[$key] }
            $tier = 0
            if ([int]::TryParse([string](Get-FslFixValue -InputObject $entry -Name 'RiskTier'), [ref]$tier) -and $tier -ge 0 -and $tier -le 3) {
                $normalized['RiskTier'] = $tier
            }
            else {
                Write-FslLog -Message "Repair catalog entry '$id' has an invalid RiskTier; treated as tier 3 (most restrictive)." -Level Warning -Component 'Repair'
                $normalized['RiskTier'] = 3
            }
            $normalized['OperatorSelected'] = [bool](Get-FslFixValue -InputObject $entry -Name 'OperatorSelected')
            $normalized['RequiresNoSessions'] = [bool](Get-FslFixValue -InputObject $entry -Name 'RequiresNoSessions')
            $actions.Add($normalized)
        }
        $catalog['Actions'] = $actions.ToArray()
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Load the repair catalog (Config/Repairs.psd1)'
    }
    $script:FslFixCatalogCache = $catalog
    return $catalog
}

function Get-FslFixActionDefinition {
    <#
    .SYNOPSIS
        Returns catalog action definitions (hashtables), optionally filtered by Id, container scope and maximum risk tier.
    .DESCRIPTION
        OperatorSelected actions are returned only when their Id is named in -ActionId (contract P3.5). -Scope keeps
        General actions plus actions whose Scope is in the list (container-mode gate G7).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string[]] $ActionId,

        [ValidateSet('ODFC', 'Profiles')]
        [string[]] $Scope,

        [ValidateRange(0, 3)]
        [int] $MaxRiskTier = 3
    )

    $catalog = Get-FslFixCatalog
    foreach ($definition in @($catalog['Actions'])) {
        $id = [string]$definition['Id']
        $named = ($ActionId -and @($ActionId | Where-Object -FilterScript { [string]::Equals([string]$_, $id, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
        if ($ActionId -and -not $named) { continue }
        if (-not $named -and [bool]$definition['OperatorSelected']) { continue }
        if ([int]$definition['RiskTier'] -gt $MaxRiskTier) { continue }
        if ($Scope -and [string]$definition['Scope'] -ne 'General' -and $Scope -notcontains [string]$definition['Scope']) { continue }
        $definition
    }
}

function Get-FslFixDefinitionValue {
    <#
    .SYNOPSIS
        StrictMode-safe read of a definition key with a default value.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition,

        [Parameter(Mandatory)]
        [string] $Name,

        [AllowNull()]
        [object] $Default
    )

    if ($Definition.ContainsKey($Name) -and $null -ne $Definition[$Name]) { return , $Definition[$Name] }
    return , $Default
}

function Get-FslFixTargetText {
    <#
    .SYNOPSIS
        Returns the operator-facing target text of a definition (registry path, service names or container type).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition
    )

    $target = Get-FslFixDefinitionValue -Definition $Definition -Name 'Target' -Default @{}
    switch ([string]$Definition['Kind']) {
        'RegistryValue' {
            return ('{0}\{1}\{2}' -f [string](Get-FslFixValue -InputObject $target -Name 'Hive'),
                [string](Get-FslFixValue -InputObject $target -Name 'Key'), [string](Get-FslFixValue -InputObject $target -Name 'ValueName'))
        }
        'Container' {
            $type = [string](Get-FslFixValue -InputObject $target -Name 'ContainerType')
            if ([string]::IsNullOrEmpty($type)) { $type = 'Container' }
            return ('{0} container' -f $type)
        }
        default {
            # Assign first: @(Get-FslFixValue ...) around the call would keep the returned array as ONE element.
            $rawNames = Get-FslFixValue -InputObject $target -Name 'ServiceName'
            $names = @($rawNames | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object -Process { [string]$_ })
            if ($names.Count -eq 0) { return [string]$Definition['Id'] }
            return ($names -join '; ')
        }
    }
}

function Get-FslFixComparableState {
    <#
    .SYNOPSIS
        Returns the durable part of a before/after state as an ordered hashtable (used for fingerprints and drift checks).
    .DESCRIPTION
        Volatile fields (timestamps, messages, service run status for a start-type action) are removed so a preview and
        the apply that follows it compare equal while a real change of the repaired state is always detected.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $Kind,

        [AllowNull()]
        [System.Collections.IDictionary] $State
    )

    $result = [ordered]@{ Kind = $Kind }
    if ($null -eq $State) { return $result }

    switch ($Kind) {
        'RegistryValue' {
            $result['Path'] = [string](Get-FslFixValue -InputObject $State -Name 'Path')
            $result['Exists'] = [bool](Get-FslFixValue -InputObject $State -Name 'Exists')
            $result['ValueKind'] = [string](Get-FslFixValue -InputObject $State -Name 'ValueKind')
            $result['Value'] = ConvertTo-FslCoreResultString -InputObject (Get-FslFixValue -InputObject $State -Name 'Value')
            return $result
        }
        'ServiceStartType' {
            $services = Get-FslFixValue -InputObject $State -Name 'Services'
            $table = [ordered]@{}
            if ($services -is [System.Collections.IDictionary]) {
                foreach ($name in @($services.Keys | Sort-Object)) {
                    $entry = $services[$name]
                    $table[[string]$name] = [ordered]@{
                        Exists    = [bool](Get-FslFixValue -InputObject $entry -Name 'Exists')
                        StartType = [string](Get-FslFixValue -InputObject $entry -Name 'StartType')
                    }
                }
            }
            $result['Services'] = $table
            return $result
        }
        'ServiceStart' {
            $result['ServiceName'] = [string](Get-FslFixValue -InputObject $State -Name 'ServiceName')
            $result['Exists'] = [bool](Get-FslFixValue -InputObject $State -Name 'Exists')
            $result['StartType'] = [string](Get-FslFixValue -InputObject $State -Name 'StartType')
            $result['Status'] = [string](Get-FslFixValue -InputObject $State -Name 'Status')
            return $result
        }
        default {
            $skip = @('Timestamp', 'CheckedAt', 'Message', 'Temporary', 'ExpiresAt')
            foreach ($key in @($State.Keys | Sort-Object)) {
                if ($skip -contains [string]$key) { continue }
                $result[[string]$key] = ConvertTo-FslCoreResultString -InputObject $State[$key]
            }
            return $result
        }
    }
}

function Get-FslFixStateFingerprint {
    <#
    .SYNOPSIS
        Returns the SHA256 (upper-case hex) of the comparable before-state JSON of an action (contract P3.3 Fingerprint).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Kind,

        [AllowNull()]
        [System.Collections.IDictionary] $State
    )

    try {
        $comparable = Get-FslFixComparableState -Kind $Kind -State $State
        $json = ConvertTo-FslFixJson -InputObject $comparable -Compress
        return (Get-FslFixSha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($json)))
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Fingerprint state ($Kind)"
        return $null
    }
}

function Test-FslFixStateMatch {
    <#
    .SYNOPSIS
        Returns $true when two states have the same durable content (same comparable JSON).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Kind,

        [AllowNull()]
        [System.Collections.IDictionary] $Expected,

        [AllowNull()]
        [System.Collections.IDictionary] $Actual
    )

    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    $left = Get-FslFixStateFingerprint -Kind $Kind -State $Expected
    $right = Get-FslFixStateFingerprint -Kind $Kind -State $Actual
    if ([string]::IsNullOrEmpty($left) -or [string]::IsNullOrEmpty($right)) { return $false }
    return [string]::Equals($left, $right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-FslFixChangeReferenceRequired {
    <#
    .SYNOPSIS
        Returns $true when an action of this risk tier requires -ChangeReference (Settings Repair.RequireChangeReferenceTier).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 3)]
        [int] $RiskTier
    )

    $threshold = 3
    try {
        $config = Get-FslFixConfig
        if ($config.ContainsKey('RequireChangeReferenceTier')) {
            $parsed = 0
            if ([int]::TryParse([string]$config['RequireChangeReferenceTier'], [ref]$parsed)) { $threshold = $parsed }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Read Repair.RequireChangeReferenceTier'
    }
    return ($RiskTier -ge $threshold)
}

function New-FslFixRepairAction {
    <#
    .SYNOPSIS
        Builds an FSLogixToolkit.RepairAction (contract P3.3) from a catalog definition and a detection result.
    .DESCRIPTION
        Status: Blocked (detection returned a BlockReason), GuidanceOnly (the value is delivered by Group Policy - the
        operator changes it in Local Group Policy), NotNeeded (the documented state is already in place) or Ready.
        Fingerprint is the SHA256 of the comparable before-state JSON (Get-FslFixStateFingerprint).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only; no state is changed.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition,

        [Parameter(Mandatory)]
        [object] $Detection,

        [hashtable] $Parameters = @{}
    )

    $kind = [string]$Definition['Kind']
    $blockReason = [string](Get-FslFixValue -InputObject $Detection -Name 'BlockReason')
    $guidanceOnly = [bool](Get-FslFixValue -InputObject $Detection -Name 'GuidanceOnly')
    $needed = [bool](Get-FslFixValue -InputObject $Detection -Name 'Needed')
    $status = if (-not [string]::IsNullOrWhiteSpace($blockReason)) { 'Blocked' }
    elseif ($guidanceOnly) { 'GuidanceOnly' }
    elseif (-not $needed) { 'NotNeeded' }
    else { 'Ready' }

    $beforeState = Get-FslFixValue -InputObject $Detection -Name 'BeforeState'
    if ($null -ne $beforeState -and -not ($beforeState -is [System.Collections.IDictionary])) { $beforeState = $null }
    $target = [string](Get-FslFixValue -InputObject $Detection -Name 'Target')
    if ([string]::IsNullOrWhiteSpace($target)) { $target = Get-FslFixTargetText -Definition $Definition }
    $guidance = [string](Get-FslFixValue -InputObject $Detection -Name 'Guidance')
    $definitionGuidance = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'Guidance' -Default '')
    if ([string]::IsNullOrWhiteSpace($guidance)) { $guidance = $definitionGuidance }
    elseif (-not [string]::IsNullOrWhiteSpace($definitionGuidance)) { $guidance = '{0} {1}' -f $guidance, $definitionGuidance }
    $proposed = Get-FslFixValue -InputObject $Detection -Name 'ProposedValue'
    if ($null -eq $proposed) { $proposed = Get-FslFixDefinitionValue -Definition $Definition -Name 'ProposedValue' -Default $null }

    [pscustomobject]@{
        PSTypeName              = 'FSLogixToolkit.RepairAction'
        ActionId                = [string]$Definition['Id']
        Title                   = [string]$Definition['Title']
        Scope                   = [string]$Definition['Scope']
        RiskTier                = [int]$Definition['RiskTier']
        Status                  = $status
        Condition               = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'Condition' -Default '')
        Target                  = [string](ConvertTo-FslCoreRedactedText -Text $target)
        CurrentValue            = [string](ConvertTo-FslCoreRedactedText -Text (ConvertTo-FslCoreResultString -InputObject (Get-FslFixValue -InputObject $Detection -Name 'CurrentValue')))
        ProposedValue           = [string](ConvertTo-FslCoreRedactedText -Text (ConvertTo-FslCoreResultString -InputObject $proposed))
        BlockReason             = [string](ConvertTo-FslCoreRedactedText -Text $blockReason)
        Guidance                = [string](ConvertTo-FslCoreRedactedText -Text $guidance)
        RequiresElevation       = ([int]$Definition['RiskTier'] -ge 1)
        RequiresChangeReference = (Test-FslFixChangeReferenceRequired -RiskTier ([int]$Definition['RiskTier']))
        RollbackMethod          = [string]$Definition['RollbackMethod']
        EffectiveWhen           = [string]$Definition['EffectiveWhen']
        Fingerprint             = Get-FslFixStateFingerprint -Kind $kind -State $beforeState
        PlannedAt               = (Get-Date).ToString('o')
        Source                  = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'Source' -Default '')
        Parameters              = $Parameters
        Kind                    = $kind
        BeforeState             = $beforeState
        Message                 = [string](ConvertTo-FslCoreRedactedText -Text ([string](Get-FslFixValue -InputObject $Detection -Name 'Message')))
    }
}

function Get-FslFixGroupPolicyGuidance {
    <#
    .SYNOPSIS
        Returns the operator guidance for a registry value that Group Policy delivers (GuidanceOnly actions).
    .DESCRIPTION
        FSLogix administrative template SETTING names are not verified against Microsoft documentation, so the text
        names the registry value and the verified editor path only (how-to-use-group-policy-templates).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RegistryPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $PolicyName,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $ProposedValue
    )

    $gpo = if ([string]::IsNullOrWhiteSpace($PolicyName)) { '' } else { " The winning Group Policy Object is '$PolicyName'." }
    $value = if ([string]::IsNullOrWhiteSpace($ProposedValue)) { '' } else { " Target state: $ProposedValue." }
    return ("This value is delivered by Group Policy, so writing the registry would be undone at the next policy refresh. " +
        "Change the Local Group Policy setting that writes $RegistryPath ($script:FslFixGroupPolicyPath), then run " +
        "'GPUPDATE /Target:Computer /force' and run the repair plan again.$gpo$value")
}
