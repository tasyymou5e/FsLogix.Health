function Get-FslRepairPlan {
    <#
    .SYNOPSIS
        Returns the repair plan for this computer: one FSLogixToolkit.RepairAction per catalog action, with its status.

    .DESCRIPTION
        Read-only preview. Every action in Config/Repairs.psd1 that is in scope is detected (registry values are read,
        services are queried) and returned as an FSLogixToolkit.RepairAction with:
          Ready         the documented condition is met and the change may be applied;
          NotNeeded     the documented state is already in place;
          GuidanceOnly  the registry value is delivered by Group Policy - the operator changes it in Local Group Policy
                        (gpedit.msc > Computer Configuration > Administrative Templates > FSLogix), the toolkit never
                        writes a value that Group Policy would re-apply;
          Blocked       the action must not run (Group Policy provenance Unknown - for example because the session is
                        not elevated - or the target is not on the repair allow-list).
        Nothing is changed and no elevation is required, but without elevation Group Policy provenance cannot be
        checked, so registry actions are reported as Blocked (contract P3.1: Unknown provenance blocks writes).
        Actions marked OperatorSelected in the catalog (Cloud Caching service start type, verbose logging, Office container
        reset) appear only when their
        id is named in -ActionId. Each action carries a Fingerprint (SHA256 of its before state) that Invoke-FslRepair
        compares again to detect drift between the preview and the change.

    .PARAMETER ContainerScope
        Container mode for the plan: ODFC (Office containers only, default), Profiles or Both. Actions of a scope that
        is not in the mode are not planned. Default: the saved container mode (Get-FslContainerMode).

    .PARAMETER ActionId
        Only these action ids (for example FIX-SVC-01). Required to see OperatorSelected actions.

    .PARAMETER MaxRiskTier
        Highest risk tier to include: 0 read-only, 1 reversible low risk, 2 persistent config change with backup,
        3 disruptive. Default: Config/Settings.psd1 Repair.MaxRiskTierDefault (toolkit default 2).

    .PARAMETER Parameters
        Extra parameters for handlers that need them (for example @{ UserName = 'CONTOSO\jdoe'; ArchivePath = '\\server\archive' }
        for the Office container reset).

    .EXAMPLE
        Get-FslRepairPlan | Format-Table ActionId, Status, Target, CurrentValue, ProposedValue, RiskTier

    .EXAMPLE
        Get-FslRepairPlan -ActionId 'FIX-LOG-02' | Select-Object ActionId, Status, Guidance

        Shows the operator-selected temporary verbose logging action.

    .OUTPUTS
        FSLogixToolkit.RepairAction

    .NOTES
        RequiresElevation: No (read-only), but registry actions need an elevated session to confirm Group Policy
        provenance; without elevation they are Blocked.
        Sources:
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
          https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components
          https://learn.microsoft.com/en-us/fslogix/troubleshooting-vhd-disk-compaction
          https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates
          https://learn.microsoft.com/en-us/fslogix/concepts-container-types
    #>
    [CmdletBinding()]
    [OutputType('FSLogixToolkit.RepairAction')]
    param(
        [Parameter()]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $ContainerScope,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $ActionId,

        [Parameter()]
        [ValidateRange(0, 3)]
        [int] $MaxRiskTier,

        [Parameter()]
        [hashtable] $Parameters = @{}
    )

    try {
        $mode = if ($PSBoundParameters.ContainsKey('ContainerScope')) { Get-FslContainerMode -Mode $ContainerScope } else { Get-FslContainerMode }
        $scopes = @(Resolve-FslPrefContainerScope -Mode $mode)
        if (-not $PSBoundParameters.ContainsKey('MaxRiskTier')) {
            $MaxRiskTier = 2
            $config = Get-FslFixConfig
            if ($config.ContainsKey('MaxRiskTierDefault')) {
                $parsed = 0
                if ([int]::TryParse([string]$config['MaxRiskTierDefault'], [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 3) { $MaxRiskTier = $parsed }
            }
        }

        $planParams = @{ Scope = $scopes; MaxRiskTier = $MaxRiskTier; Parameters = $Parameters }
        if ($ActionId) { $planParams['ActionId'] = $ActionId }
        Write-FslLog -Message "Building the repair plan (container mode $mode, max risk tier $MaxRiskTier)." -Level Verbose -Component 'Repair'
        Get-FslFixPlanAction @planParams
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Build the repair plan'
    }
}
