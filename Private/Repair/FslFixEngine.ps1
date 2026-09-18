# Private repair engine helpers: handler invocation, plan building, records and Results (Agent P3-5, prefix *-FslFix*).
#
# Handler interface (contract P3.5):
#   Detect   param([hashtable]$Definition, [hashtable]$Parameters)
#            -> [pscustomobject] Needed, CurrentValue, ProposedValue, Target, BeforeState, BlockReason, GuidanceOnly,
#               Guidance, Message
#   Apply    param([hashtable]$Definition, [pscustomobject]$Action, [hashtable]$BeforeState)
#            -> @{ Success; AfterState; Created; Message }
#   Rollback param([hashtable]$Definition, [hashtable]$BeforeState, [hashtable]$AfterState) -> @{ Success; Message }
#
# Handler names come from Config/Repairs.psd1, so they are validated against a strict pattern and must resolve to a
# function of this module before they are invoked (a tampered data file can never run an arbitrary command).
#
# Sources:
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.core/get-command
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_functions_advanced_parameters

$script:FslFixHandlerNamePattern = '^(Get|Set|Start|Restore|Undo|Invoke|New|Remove|Test)-FslFix[A-Za-z0-9]+$'

function Test-FslFixHandlerName {
    <#
    .SYNOPSIS
        Returns $true when a catalog handler name is a private repair function of this module (approved verb + FslFix prefix).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -notmatch $script:FslFixHandlerNamePattern) {
        Write-FslLog -Message "Repair handler '$Name' does not match the allowed handler name pattern and is not invoked." -Level Warning -Component 'Repair'
        return $false
    }
    $command = Get-Command -Name $Name -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        Write-FslLog -Message "Repair handler '$Name' was not found." -Level Warning -Component 'Repair'
        return $false
    }
    return $true
}

function Invoke-FslFixDetect {
    <#
    .SYNOPSIS
        Runs the Detect handler of a definition and returns a normalized detection object. Never throws.
    .DESCRIPTION
        A missing handler or a handler error produces a detection with BlockReason set, so the action can only be
        reported as Blocked - never silently applied.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition,

        [hashtable] $Parameters = @{}
    )

    $handler = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'Detect' -Default '')
    $fallback = [pscustomobject]@{
        Needed        = $false
        CurrentValue  = $null
        ProposedValue = Get-FslFixDefinitionValue -Definition $Definition -Name 'ProposedValue' -Default $null
        Target        = Get-FslFixTargetText -Definition $Definition
        BeforeState   = $null
        BlockReason   = "The detection handler '$handler' is not available."
        GuidanceOnly  = $false
        Guidance      = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'Guidance' -Default '')
        Message       = "The detection handler '$handler' is not available; the action is blocked."
    }
    if (-not (Test-FslFixHandlerName -Name $handler)) { return $fallback }

    try {
        $detection = & $handler -Definition $Definition -Parameters $Parameters
        $detection = @($detection) | Where-Object -FilterScript { $null -ne $_ } | Select-Object -First 1
        if ($null -eq $detection) {
            $fallback.BlockReason = "The detection handler '$handler' returned nothing."
            $fallback.Message = $fallback.BlockReason
            return $fallback
        }
        return [pscustomobject]@{
            Needed        = [bool](Get-FslFixValue -InputObject $detection -Name 'Needed')
            CurrentValue  = Get-FslFixValue -InputObject $detection -Name 'CurrentValue'
            ProposedValue = Get-FslFixValue -InputObject $detection -Name 'ProposedValue'
            Target        = Get-FslFixValue -InputObject $detection -Name 'Target'
            BeforeState   = Get-FslFixValue -InputObject $detection -Name 'BeforeState'
            BlockReason   = Get-FslFixValue -InputObject $detection -Name 'BlockReason'
            GuidanceOnly  = [bool](Get-FslFixValue -InputObject $detection -Name 'GuidanceOnly')
            Guidance      = Get-FslFixValue -InputObject $detection -Name 'Guidance'
            Message       = Get-FslFixValue -InputObject $detection -Name 'Message'
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Detect $([string]$Definition['Id'])"
        $fallback.BlockReason = "Detection failed: $($_.Exception.Message)"
        $fallback.Message = $fallback.BlockReason
        return $fallback
    }
}

function Invoke-FslFixApply {
    <#
    .SYNOPSIS
        Runs the Apply handler of a definition. Returns @{ Success; AfterState; Created; Message }. Never throws.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called by Invoke-FslRepair after ShouldProcess, preflight and a verified rollback entry; an inherited WhatIf must not skip half of an action.')]
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

    $handler = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'Apply' -Default '')
    if (-not (Test-FslFixHandlerName -Name $handler)) {
        return @{ Success = $false; AfterState = $BeforeState; Created = @(); Message = "The apply handler '$handler' is not available; nothing was changed." }
    }
    try {
        $outcome = & $handler -Definition $Definition -Action $Action -BeforeState $BeforeState
        $outcome = @($outcome) | Where-Object -FilterScript { $null -ne $_ } | Select-Object -First 1
        if ($null -eq $outcome) {
            return @{ Success = $false; AfterState = $BeforeState; Created = @(); Message = "The apply handler '$handler' returned nothing." }
        }
        $afterState = Get-FslFixValue -InputObject $outcome -Name 'AfterState'
        if ($null -ne $afterState -and -not ($afterState -is [System.Collections.IDictionary])) { $afterState = $null }
        # Assign first: @(Get-FslFixValue ...) around the call would keep the returned array as ONE element.
        $rawCreated = Get-FslFixValue -InputObject $outcome -Name 'Created'
        return @{
            Success    = [bool](Get-FslFixValue -InputObject $outcome -Name 'Success')
            AfterState = $afterState
            Created    = @($rawCreated | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object -Process { [string]$_ })
            Message    = [string](Get-FslFixValue -InputObject $outcome -Name 'Message')
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Apply $([string]$Definition['Id'])"
        return @{ Success = $false; AfterState = $null; Created = @(); Message = "The change failed: $($_.Exception.Message)" }
    }
}

function Invoke-FslFixRollback {
    <#
    .SYNOPSIS
        Runs the Rollback handler of a definition. Returns @{ Success; Message }. Never throws.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called by Undo-FslRepair after ShouldProcess and the rollback-store integrity check.')]
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

    $handler = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'Rollback' -Default '')
    if ([string]::IsNullOrWhiteSpace($handler)) {
        return @{ Success = $false; Message = "Action $([string]$Definition['Id']) has no rollback (RollbackMethod $([string]$Definition['RollbackMethod']))." }
    }
    if (-not (Test-FslFixHandlerName -Name $handler)) {
        return @{ Success = $false; Message = "The rollback handler '$handler' is not available; nothing was changed." }
    }
    try {
        $outcome = & $handler -Definition $Definition -BeforeState $BeforeState -AfterState $AfterState
        $outcome = @($outcome) | Where-Object -FilterScript { $null -ne $_ } | Select-Object -First 1
        if ($null -eq $outcome) { return @{ Success = $false; Message = "The rollback handler '$handler' returned nothing." } }
        return @{
            Success = [bool](Get-FslFixValue -InputObject $outcome -Name 'Success')
            Message = [string](Get-FslFixValue -InputObject $outcome -Name 'Message')
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Rollback $([string]$Definition['Id'])"
        return @{ Success = $false; Message = "The rollback failed: $($_.Exception.Message)" }
    }
}

function Get-FslFixPlanAction {
    <#
    .SYNOPSIS
        Builds RepairAction objects for the matching catalog definitions (detection only; nothing is changed).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $ActionId,

        [ValidateSet('ODFC', 'Profiles')]
        [string[]] $Scope,

        [ValidateRange(0, 3)]
        [int] $MaxRiskTier = 3,

        [hashtable] $Parameters = @{}
    )

    $definitionParams = @{ MaxRiskTier = $MaxRiskTier }
    if ($ActionId) { $definitionParams['ActionId'] = $ActionId }
    if ($Scope) { $definitionParams['Scope'] = $Scope }
    foreach ($definition in @(Get-FslFixActionDefinition @definitionParams)) {
        $detection = Invoke-FslFixDetect -Definition $definition -Parameters $Parameters
        New-FslFixRepairAction -Definition $definition -Detection $detection -Parameters $Parameters
    }
}

function Get-FslFixDefinitionForAction {
    <#
    .SYNOPSIS
        Returns the catalog definition of a RepairAction (by ActionId), or $null when the catalog has no such entry.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object] $Action
    )

    $id = [string](Get-FslFixValue -InputObject $Action -Name 'ActionId')
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    $definition = @(Get-FslFixActionDefinition -ActionId @($id)) | Select-Object -First 1
    if ($null -eq $definition) {
        Write-FslLog -Message "Repair action '$id' is not in the catalog (Config/Repairs.psd1)." -Level Warning -Component 'Repair'
        return $null
    }
    return $definition
}

function New-FslFixActionResult {
    <#
    .SYNOPSIS
        Creates the FSLogixToolkit.Result for one repair action (Category Repair, Check 'Repair:<ActionId>').
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory Result object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Action,

        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Warn', 'Fail', 'Info', 'Skipped', 'Error')]
        [string] $Status,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Message,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Recommendation,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Value
    )

    $scope = [string](Get-FslFixValue -InputObject $Action -Name 'Scope')
    if (@('General', 'ODFC', 'Profiles') -notcontains $scope) { $scope = 'General' }
    $actionId = [string](Get-FslFixValue -InputObject $Action -Name 'ActionId')
    if ([string]::IsNullOrEmpty($Value)) { $Value = [string](Get-FslFixValue -InputObject $Action -Name 'CurrentValue') }
    New-FslResult -Category 'Repair' -Check ("Repair:{0}" -f $actionId) -Status $Status `
        -Target ([string](Get-FslFixValue -InputObject $Action -Name 'Target')) -Value $Value `
        -Expected ([string](Get-FslFixValue -InputObject $Action -Name 'ProposedValue')) -Message $Message `
        -Recommendation $Recommendation -Source ([string](Get-FslFixValue -InputObject $Action -Name 'Source')) `
        -RequiresElevation ([bool](Get-FslFixValue -InputObject $Action -Name 'RequiresElevation')) -Scope $scope
}

function New-FslFixRunResult {
    <#
    .SYNOPSIS
        Creates the summary Result of a repair run (Check 'RepairRun', Target = RunId).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory Result object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Run,

        [Parameter(Mandatory)]
        [object] $Summary,

        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Warn', 'Fail', 'Info', 'Skipped', 'Error')]
        [string] $Status,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Message,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Recommendation
    )

    $value = 'Mode {0}; actions {1}; Pass {2}; Fail {3}; Error {4}; Skipped {5}; Info {6}' -f $Run.Mode, $Summary.Total,
    $Summary.Pass, $Summary.Fail, $Summary.Error, $Summary.Skipped, $Summary.Info
    New-FslResult -Category 'Repair' -Check 'RepairRun' -Status $Status -Target ([string]$Run.RunId) -Value $value `
        -Expected 'All selected actions applied and verified' -Message $Message -Recommendation $Recommendation `
        -Source ([string]$Run.LogPath) -RequiresElevation $true -Scope 'General'
}

function Get-FslFixShouldProcessTarget {
    <#
    .SYNOPSIS
        Returns the ShouldProcess target text of an action: "<ActionId> on <target> (<current> -> <proposed>)".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Action
    )

    '{0} on {1} (current: {2}; proposed: {3}; risk tier {4})' -f (Get-FslFixValue -InputObject $Action -Name 'ActionId'),
    (Get-FslFixValue -InputObject $Action -Name 'Target'), (Get-FslFixValue -InputObject $Action -Name 'CurrentValue'),
    (Get-FslFixValue -InputObject $Action -Name 'ProposedValue'), (Get-FslFixValue -InputObject $Action -Name 'RiskTier')
}

function New-FslFixActionRecord {
    <#
    .SYNOPSIS
        Builds the hashtable passed to Add-FslFixRecord for one action (FSLogixToolkit.RepairRecord fields).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory hashtable only.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object] $Action,

        [Parameter(Mandatory)]
        [ValidateSet('WhatIf', 'Executed', 'Declined', 'Blocked', 'Undo')]
        [string] $Mode,

        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Fail', 'Skipped', 'Error', 'Info')]
        [string] $Status,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Message,

        [AllowNull()]
        [System.Collections.IDictionary] $BeforeState,

        [AllowNull()]
        [System.Collections.IDictionary] $AfterState,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $VerificationStatus,

        [bool] $RollbackAvailable = $false,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $RollbackRef
    )

    if ($null -eq $BeforeState) { $BeforeState = Get-FslFixValue -InputObject $Action -Name 'BeforeState' }
    @{
        ActionId           = [string](Get-FslFixValue -InputObject $Action -Name 'ActionId')
        Title              = [string](Get-FslFixValue -InputObject $Action -Name 'Title')
        Scope              = [string](Get-FslFixValue -InputObject $Action -Name 'Scope')
        RiskTier           = Get-FslFixValue -InputObject $Action -Name 'RiskTier'
        Mode               = $Mode
        Target             = [string](Get-FslFixValue -InputObject $Action -Name 'Target')
        BeforeState        = $BeforeState
        AfterState         = $AfterState
        ExpectedState      = [string](Get-FslFixValue -InputObject $Action -Name 'ProposedValue')
        Status             = $Status
        VerificationStatus = $VerificationStatus
        Message            = $Message
        RollbackAvailable  = $RollbackAvailable
        RollbackRef        = $RollbackRef
        Source             = [string](Get-FslFixValue -InputObject $Action -Name 'Source')
        Condition          = [string](Get-FslFixValue -InputObject $Action -Name 'Condition')
    }
}

function Test-FslFixPreflightBlocking {
    <#
    .SYNOPSIS
        Returns the blocking (Fail/Error) pre-flight Results for an action id ('' = the run-wide gates).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $ActionId
    )

    foreach ($item in $Result) {
        if ($null -eq $item) { continue }
        if (@('Fail', 'Error') -notcontains [string](Get-FslFixValue -InputObject $item -Name 'Status')) { continue }
        $target = [string](Get-FslFixValue -InputObject $item -Name 'Target')
        if ([string]::IsNullOrEmpty($ActionId)) {
            if ($target -eq 'Repair run') { $item }
        }
        elseif ([string]::Equals($target, $ActionId, [System.StringComparison]::OrdinalIgnoreCase)) { $item }
    }
}
