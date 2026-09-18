function Test-FslRepairPrerequisite {
    <#
    .SYNOPSIS
        Runs the repair pre-flight gates for one or more repair actions and returns the gate Results.

    .DESCRIPTION
        Read-only check of the gates that Invoke-FslRepair applies (plan section 3, contract P3.5). One Result per gate
        (Category Repair, Check 'Preflight:<Gate>'); run-wide gates use Target 'Repair run', per-action gates the
        action id:
          G1  Windows and PowerShell 7.4 or later
          G2  elevated session
          G3  the toolkit folder can only be changed by administrators (Test-FslToolkitPathSecurity)
          G4  no toolkit file still carries the Zone.Identifier stream (downloaded and not unblocked)
          G5  FSLogix is installed and its version could be read
          G6  per-action FSLogix version requirement
          G7  the action scope fits the container mode (Profiles actions are not run in ODFC mode)
          G8  Group Policy provenance of registry values (GroupPolicy -> guidance, Unknown -> blocked)
          G10 the container file of a container action is not in use (re-checked immediately before the change)
          G12 maintenance window (informational; none is configured)
          G13 change reference for the risk tiers that require one (Settings Repair.RequireChangeReferenceTier)
          G14 an admin-only rollback store is available (Settings Repair.StateRoot)
          G15 free disk space for the rollback store (Settings Repair.MinFreeSpaceMB)
          G16 the before state of every action is recorded before the change (informational)
          G17 the plan is fresh (Settings Repair.PlanMaxAgeMinutes) and the state has not drifted since the plan
          G18 no other repair run holds the single-run lock
          G21 every change is verified by re-detection afterwards (informational)
        G9 (session enumeration) is not implemented - no locale-safe method is verified; container actions use the
        exclusive-open check (G10) and the operator attestation (-UserSignedOutConfirmed) instead. G11, G19 and G20
        (drain attestation and installer gates) are out of scope in this release.
        Because this function is read-only it does not know the -ChangeReference of a later repair, so G13 reports Warn
        instead of Fail; Invoke-FslRepair runs the same gates strictly and blocks the action.

    .PARAMETER Action
        FSLogixToolkit.RepairAction objects from Get-FslRepairPlan (pipeline supported).

    .EXAMPLE
        Get-FslRepairPlan | Test-FslRepairPrerequisite | Format-Table Check, Status, Target, Message

    .OUTPUTS
        FSLogixToolkit.Result

    .NOTES
        RequiresElevation: No, but most gates only pass in an elevated session (G2, G8, G14).
        Sources:
          https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/unblock-file
          https://learn.microsoft.com/dotnet/api/system.io.driveinfo.availablefreespace
          https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates
    #>
    [CmdletBinding()]
    [OutputType('FSLogixToolkit.Result')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyCollection()]
        [object[]] $Action
    )

    begin {
        $collected = [System.Collections.Generic.List[object]]::new()
    }
    process {
        foreach ($item in @($Action)) {
            if ($null -ne $item) { $collected.Add($item) }
        }
    }
    end {
        try {
            Get-FslFixPreflightResult -Action $collected.ToArray() -Mode 'Plan'
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Run the repair pre-flight gates'
            New-FslResult -Category 'Repair' -Check 'Preflight:G1' -Status 'Error' -Target 'Repair run' `
                -Message "The pre-flight gates could not be evaluated: $($_.Exception.Message)" -Source 'Toolkit default' -RequiresElevation $true
        }
    }
}
