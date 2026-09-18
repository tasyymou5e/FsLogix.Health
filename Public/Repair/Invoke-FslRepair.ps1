function Invoke-FslRepair {
    <#
    .SYNOPSIS
        Applies selected FSLogix repair actions with pre-flight gates, a verified rollback entry per change and
        post-change verification.

    .DESCRIPTION
        The safe order for every action is: pre-flight gates -> confirmation (ConfirmImpact High) -> re-detect (drift
        check against the plan Fingerprint) -> write the before state to the admin-only rollback store and verify it
        (SHA256 manifest) -> apply the change -> detect again and record the verification -> write the run log.
        Nothing is changed when the pre-flight gates block a run or an action; with -WhatIf the run only records what
        it would do (Mode WhatIf) and no registry value, service or file is touched.

        Safety rules that cannot be switched off:
          - registry values delivered by Group Policy are never written: the action becomes GuidanceOnly and names the
            Local Group Policy setting to change (gpedit.msc > Computer Configuration > Administrative Templates > FSLogix);
          - Unknown Group Policy provenance (for example a session that is not elevated, or an RSoP query that failed)
            blocks a registry action;
          - ODFC values are only written under HKLM\SOFTWARE\Policies\FSLogix\ODFC, and only value names on the repair
            allow-list are changed (never VHDLocations/CCDLocations);
          - defragsvc and smphost are only changed from Disabled to Manual;
          - frxsvc is only started when it is stopped - services are never stopped or restarted;
          - risk tier 3 actions need -AllowDisruptive and a change reference, and actions that require it need
            -UserSignedOutConfirmed;
          - a failed verification is NEVER rolled back automatically; the record says to run Undo-FslRepair.
        Output: the pre-flight Results, one Result per action (Check 'Repair:<ActionId>') and a summary Result
        (Check 'RepairRun', Target = RunId). Blocked actions carry a message that starts with 'Blocked: '.
        Readable logs are written to <ReportRoot>/Repair/<yyyy-MM-dd>/Repair_<HHmmss>_<RunId8>.log|.json|.csv; the
        authoritative rollback store stays in the admin-only Repair.StateRoot.

    .PARAMETER Action
        FSLogixToolkit.RepairAction objects from Get-FslRepairPlan (pipeline supported).

    .PARAMETER ActionId
        Action ids to plan and apply (for example FIX-SVC-01). The plan is built from the current state.

    .PARAMETER ContainerScope
        Container mode for this run: ODFC (default), Profiles or Both. Actions outside the mode are blocked (gate G7).

    .PARAMETER MaxRiskTier
        Highest risk tier to apply. Default: Config/Settings.psd1 Repair.MaxRiskTierDefault (toolkit default 2);
        with -AllowDisruptive and no explicit value the maximum is 3.

    .PARAMETER AllowDisruptive
        Required for risk tier 3 actions (disruptive or not fully reversible, such as the Office container reset).

    .PARAMETER ChangeReference
        Your change record reference. Required for the risk tiers listed in Repair.RequireChangeReferenceTier
        (toolkit default: tier 3). It is written to the repair log and the rollback store.

    .PARAMETER Parameters
        Extra parameters for handlers that need them, for example @{ UserName = 'CONTOSO\jdoe'; ArchivePath = '\\server\share\archive' }.

    .PARAMETER UserSignedOutConfirmed
        Operator attestation that the affected user is signed out of every session host. Required for actions marked
        RequiresNoSessions in the catalog (the Office container reset).

    .EXAMPLE
        Invoke-FslRepair -ActionId 'FIX-SVC-01' -WhatIf

        Previews the change: the run is recorded with Mode WhatIf and nothing is changed.

    .EXAMPLE
        Get-FslRepairPlan | Where-Object Status -eq 'Ready' | Invoke-FslRepair -ChangeReference 'CHG0012345'

    .EXAMPLE
        Invoke-FslRepair -ActionId 'FIX-ODFC-02' -AllowDisruptive -UserSignedOutConfirmed -ChangeReference 'CHG0012345' -Parameters @{ UserName = 'CONTOSO\jdoe'; ArchivePath = '\\server\share\odfc-archive' }

    .OUTPUTS
        FSLogixToolkit.Result

    .NOTES
        RequiresElevation: Yes (gate G2). The daily scheduled health check never runs repairs.
        Sources:
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
          https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components
          https://learn.microsoft.com/en-us/fslogix/troubleshooting-vhd-disk-compaction
          https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates
          https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ActionId')]
    [OutputType('FSLogixToolkit.Result')]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'Action')]
        [AllowEmptyCollection()]
        [object[]] $Action,

        [Parameter(Mandatory, ParameterSetName = 'ActionId')]
        [ValidateNotNullOrEmpty()]
        [string[]] $ActionId,

        [Parameter()]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $ContainerScope,

        [Parameter()]
        [ValidateRange(0, 3)]
        [int] $MaxRiskTier,

        [Parameter()]
        [switch] $AllowDisruptive,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ChangeReference,

        [Parameter()]
        [hashtable] $Parameters = @{},

        [Parameter()]
        [switch] $UserSignedOutConfirmed
    )

    begin {
        $collected = [System.Collections.Generic.List[object]]::new()
    }
    process {
        if ($PSCmdlet.ParameterSetName -eq 'Action') {
            foreach ($item in @($Action)) { if ($null -ne $item) { $collected.Add($item) } }
        }
    }
    end {
        $component = 'Repair'
        $results = [System.Collections.Generic.List[object]]::new()
        $isWhatIf = [bool]$WhatIfPreference
        $runMode = if ($isWhatIf) { 'WhatIf' } else { 'Apply' }

        $containerMode = 'ODFC'
        try { $containerMode = if ($PSBoundParameters.ContainsKey('ContainerScope')) { Get-FslContainerMode -Mode $ContainerScope } else { Get-FslContainerMode } }
        catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Resolve the container mode for the repair run' }

        # The handler interface has no channel for the run-level attestations, so they travel in -Parameters
        # (a copy: the caller's hashtable is never modified). Without them the Office container reset (FIX-ODFC-02)
        # would always report Blocked because its own gate re-check reads these two keys.
        $handlerParameters = @{}
        foreach ($key in @($Parameters.Keys)) { $handlerParameters[[string]$key] = $Parameters[$key] }
        $handlerParameters['UserSignedOutConfirmed'] = [bool]$UserSignedOutConfirmed
        if ($PSBoundParameters.ContainsKey('ChangeReference')) { $handlerParameters['ChangeReference'] = $ChangeReference }

        $effectiveMaxTier = 2
        if ($PSBoundParameters.ContainsKey('MaxRiskTier')) { $effectiveMaxTier = $MaxRiskTier }
        elseif ($AllowDisruptive) { $effectiveMaxTier = 3 }
        else {
            $config = Get-FslFixConfig
            if ($config.ContainsKey('MaxRiskTierDefault')) {
                $parsedTier = 0
                if ([int]::TryParse([string]$config['MaxRiskTierDefault'], [ref]$parsedTier) -and $parsedTier -ge 0 -and $parsedTier -le 3) { $effectiveMaxTier = $parsedTier }
            }
        }

        # ---- the actions of this run --------------------------------------------------------------------------
        $actions = @()
        if ($PSCmdlet.ParameterSetName -eq 'ActionId') {
            $actions = @(Get-FslRepairPlan -ContainerScope $containerMode -ActionId $ActionId -MaxRiskTier $effectiveMaxTier -Parameters $handlerParameters)
            foreach ($requested in @($ActionId | Select-Object -Unique)) {
                if (@($actions | Where-Object -FilterScript { [string]::Equals([string]$_.ActionId, [string]$requested, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
                $results.Add((New-FslResult -Category 'Repair' -Check ("Repair:{0}" -f $requested) -Status 'Warn' -Target ([string]$requested) `
                            -Message "Blocked: the action $requested is not available (unknown id, a risk tier above $effectiveMaxTier, or a scope outside the container mode $containerMode)." `
                            -Recommendation 'Run Get-FslRepairPlan to see the available actions and their risk tiers.' -Source 'Toolkit default' -RequiresElevation $true))
            }
        }
        else {
            $actions = @($collected.ToArray())
        }

        if ($actions.Count -eq 0) {
            $results.Add((New-FslResult -Category 'Repair' -Check 'RepairRun' -Status 'Info' -Target 'Repair run' `
                        -Message 'No repair action was selected; nothing was changed.' -Source 'Toolkit default' -RequiresElevation $true))
            return $results.ToArray()
        }

        # ---- pre-flight (before the run takes the single-run lock) --------------------------------------------
        $preflightMode = if ($isWhatIf) { 'Preview' } else { 'Apply' }
        $preflight = @()
        try {
            $preflight = @(Get-FslFixPreflightResult -Action $actions -Mode $preflightMode -ChangeReference $ChangeReference -ContainerMode $containerMode -Parameters $handlerParameters)
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $component -Context 'Run the repair pre-flight gates'
            $results.Add((New-FslResult -Category 'Repair' -Check 'RepairRun' -Status 'Error' -Target 'Repair run' `
                        -Message "The pre-flight gates could not be evaluated: $($_.Exception.Message). Nothing was changed." -Source 'Toolkit default' -RequiresElevation $true))
            return $results.ToArray()
        }
        foreach ($item in $preflight) { $results.Add($item) }

        $runBlocking = @(Test-FslFixPreflightBlocking -Result $preflight -ActionId '')
        if ($runBlocking.Count -gt 0) {
            $reasons = (@($runBlocking | ForEach-Object -Process { '{0}: {1}' -f $_.Check, $_.Message }) -join ' | ')
            Write-FslLog -Message "Repair refused by the pre-flight gates: $reasons" -Level Warning -Component $component
            $results.Add((New-FslResult -Category 'Repair' -Check 'RepairRun' -Status 'Fail' -Target 'Repair run' `
                        -Value ("{0} blocking gate(s)" -f $runBlocking.Count) -Expected 'All gates pass' `
                        -Message "Blocked: the repair run was refused by the pre-flight gates. $reasons Nothing was changed." `
                        -Recommendation 'Fix the reported gates and run the repair again.' -Source 'Toolkit default' -RequiresElevation $true))
            return $results.ToArray()
        }

        # ---- run context ---------------------------------------------------------------------------------------
        $run = $null
        try {
            $runParams = @{ Mode = $runMode; InvocationSource = 'Invoke-FslRepair'; ContainerMode = $containerMode }
            if ($PSBoundParameters.ContainsKey('ChangeReference')) { $runParams['ChangeReference'] = $ChangeReference }
            $run = New-FslFixRun @runParams
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $component -Context 'Start the repair run'
            $results.Add((New-FslResult -Category 'Repair' -Check 'RepairRun' -Status 'Error' -Target 'Repair run' `
                        -Message "Blocked: the repair run could not be started: $($_.Exception.Message). Nothing was changed." -Source 'Toolkit default' -RequiresElevation $true))
            return $results.ToArray()
        }

        $runFaulted = $false
        try {
            Add-FslFixPreflight -Run $run -Result $preflight

            foreach ($item in $actions) {
                $currentActionId = [string](Get-FslFixValue -InputObject $item -Name 'ActionId')
                $definition = Get-FslFixDefinitionForAction -Action $item
                $blockReasons = [System.Collections.Generic.List[string]]::new()

                # The catalog is the authority for the risk tier and the change-reference requirement: a -Action object
                # supplied by the caller (pipeline, GUI, a stale plan) must not be able to lower them.
                $tier = if ($null -ne $definition) { [int]$definition['RiskTier'] } else { [int](Get-FslFixValue -InputObject $item -Name 'RiskTier') }
                $needsChangeReference = if ($null -ne $definition) { [bool](Test-FslFixChangeReferenceRequired -RiskTier $tier) }
                else { [bool](Get-FslFixValue -InputObject $item -Name 'RequiresChangeReference') }

                if ($null -eq $definition) { $blockReasons.Add("The action $currentActionId is not in the repair catalog.") }
                if ($tier -gt $effectiveMaxTier) { $blockReasons.Add("Risk tier $tier is above the maximum for this run ($effectiveMaxTier).") }
                if ($tier -ge 3 -and -not $AllowDisruptive) { $blockReasons.Add('Risk tier 3 actions are disruptive and need -AllowDisruptive.') }
                if ($needsChangeReference -and [string]::IsNullOrWhiteSpace($ChangeReference)) {
                    $blockReasons.Add('This risk tier requires -ChangeReference.')
                }
                if ($null -ne $definition -and [bool]$definition['RequiresNoSessions'] -and -not $UserSignedOutConfirmed) {
                    $blockReasons.Add('This action needs the operator to confirm that the user is signed out of every session host (-UserSignedOutConfirmed).')
                }
                $status = [string](Get-FslFixValue -InputObject $item -Name 'Status')
                if ($status -eq 'Blocked') { $blockReasons.Add([string](Get-FslFixValue -InputObject $item -Name 'BlockReason')) }
                foreach ($gate in @(Test-FslFixPreflightBlocking -Result $preflight -ActionId $currentActionId)) {
                    $blockReasons.Add(('{0}: {1}' -f $gate.Check, $gate.Message))
                }

                if ($blockReasons.Count -gt 0) {
                    $message = 'Blocked: ' + (($blockReasons | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) }) -join ' ')
                    $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $item -Mode 'Blocked' -Status 'Skipped' -Message $message)
                    $results.Add((New-FslFixActionResult -Action $item -Status 'Fail' -Message $message `
                                -Recommendation 'Resolve the reported gate and plan the repair again.'))
                    continue
                }

                if ($status -eq 'GuidanceOnly') {
                    $guidance = [string](Get-FslFixValue -InputObject $item -Name 'Guidance')
                    $message = 'Guidance only: {0} {1}' -f [string](Get-FslFixValue -InputObject $item -Name 'Message'), $guidance
                    $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $item -Mode 'Blocked' -Status 'Info' -Message $message)
                    $results.Add((New-FslFixActionResult -Action $item -Status 'Warn' -Message $message -Recommendation $guidance))
                    continue
                }

                if ($status -eq 'NotNeeded') {
                    $message = [string](Get-FslFixValue -InputObject $item -Name 'Message')
                    if ([string]::IsNullOrWhiteSpace($message)) { $message = 'No change needed; the documented state is already in place.' }
                    $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $item -Mode 'Blocked' -Status 'Info' -Message $message)
                    $results.Add((New-FslFixActionResult -Action $item -Status 'Pass' -Message $message))
                    continue
                }

                # ---- Ready -------------------------------------------------------------------------------------
                $target = Get-FslFixShouldProcessTarget -Action $item
                $operation = [string](Get-FslFixValue -InputObject $item -Name 'Title')
                # A host that cannot show the confirmation prompt (redirected input, a scheduled task, a background
                # runspace) makes ShouldProcess throw. That must stop this action only - not the whole run, which
                # would silently skip every action after it.
                $proceed = $false
                try {
                    $proceed = $PSCmdlet.ShouldProcess($target, $operation)
                }
                catch {
                    Add-FslError -ErrorRecord $_ -Component $component -Context "Confirmation prompt for $currentActionId"
                    $message = 'The confirmation prompt could not be shown in this session, so nothing was changed. Run the repair with -Confirm:$false when the session cannot answer prompts.'
                    $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $item -Mode 'Blocked' -Status 'Fail' -Message $message)
                    $results.Add((New-FslFixActionResult -Action $item -Status 'Fail' -Message $message `
                                -Recommendation 'Re-run the repair with -Confirm:$false, or run it in a session that can answer a confirmation prompt.'))
                    continue
                }

                if ($isWhatIf) {
                    $message = 'WhatIf: would apply {0} - {1}' -f $currentActionId, [string](Get-FslFixValue -InputObject $item -Name 'Message')
                    $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $item -Mode 'WhatIf' -Status 'Info' -Message $message -VerificationStatus 'NotRun')
                    $results.Add((New-FslFixActionResult -Action $item -Status 'Info' -Message $message))
                    continue
                }
                if (-not $proceed) {
                    $message = 'The operator declined the change at the confirmation prompt; nothing was changed.'
                    $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $item -Mode 'Declined' -Status 'Skipped' -Message $message)
                    $results.Add((New-FslFixActionResult -Action $item -Status 'Info' -Message $message))
                    continue
                }

                # Re-detect immediately before the change (drift, provenance and need are checked again).
                $fresh = Invoke-FslFixDetect -Definition $definition -Parameters $handlerParameters
                $freshState = ConvertTo-FslFixHashtable -InputObject $fresh.BeforeState
                $freshFingerprint = Get-FslFixStateFingerprint -Kind ([string]$definition['Kind']) -State $freshState
                $plannedFingerprint = [string](Get-FslFixValue -InputObject $item -Name 'Fingerprint')
                $lateBlock = $null
                if (-not [string]::IsNullOrWhiteSpace([string]$fresh.BlockReason)) { $lateBlock = [string]$fresh.BlockReason }
                elseif ([bool]$fresh.GuidanceOnly) { $lateBlock = 'The value is delivered by Group Policy; the registry is not written.' }
                elseif (-not [bool]$fresh.Needed) { $lateBlock = 'The change is no longer needed (the state changed since the plan).' }
                elseif ([string]::IsNullOrWhiteSpace($freshFingerprint) -or -not [string]::Equals($freshFingerprint, $plannedFingerprint, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $lateBlock = 'The state changed after the plan was made (fingerprint drift).'
                }
                if ($null -ne $lateBlock) {
                    $message = "Blocked: $lateBlock Nothing was changed."
                    $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $item -Mode 'Blocked' -Status 'Skipped' -Message $message -BeforeState $freshState)
                    $results.Add((New-FslFixActionResult -Action $item -Status 'Fail' -Message $message -Recommendation 'Run Get-FslRepairPlan again and review the new plan.'))
                    continue
                }

                # Backup first (gate G14): the change only runs when the rollback entry was written and verified.
                $rollbackRef = $null
                $rollbackAvailable = $false
                $hasRollbackHandler = -not [string]::IsNullOrWhiteSpace([string](Get-FslFixDefinitionValue -Definition $definition -Name 'Rollback' -Default ''))
                try {
                    $saveParams = @{ Run = $run; ActionId = $currentActionId; BeforeState = $freshState }
                    if ([bool](Get-FslFixDefinitionValue -Definition $definition -Name 'Temporary' -Default $false)) {
                        $saveParams['Temporary'] = $true
                        $saveParams['ExpiresAt'] = Get-FslFixTemporaryExpiry -Definition $definition
                    }
                    $entry = Save-FslFixRollbackEntry @saveParams
                    $rollbackRef = [string]$entry.RollbackRef
                    if (-not (Test-FslFixRollbackIntegrity -RunId ([guid]$run.RunId))) {
                        throw 'The rollback store failed its integrity check right after the entry was written.'
                    }
                    $rollbackAvailable = $hasRollbackHandler
                }
                catch {
                    Add-FslError -ErrorRecord $_ -Component $component -Context "Save the rollback entry for $currentActionId"
                    $message = "Blocked: the before state could not be stored safely ($($_.Exception.Message)); the change was not applied."
                    $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $item -Mode 'Blocked' -Status 'Error' -Message $message -BeforeState $freshState)
                    $results.Add((New-FslFixActionResult -Action $item -Status 'Error' -Message $message))
                    continue
                }

                # Apply.
                $outcome = Invoke-FslFixApply -Definition $definition -Action $item -BeforeState $freshState
                $afterState = ConvertTo-FslFixHashtable -InputObject $outcome['AfterState']
                $created = @($outcome['Created'])
                try {
                    $saveParams = @{ Run = $run; ActionId = $currentActionId; BeforeState = $freshState; AfterState = $afterState; Created = $created }
                    if ([bool](Get-FslFixDefinitionValue -Definition $definition -Name 'Temporary' -Default $false)) {
                        $saveParams['Temporary'] = $true
                        $saveParams['ExpiresAt'] = Get-FslFixTemporaryExpiry -Definition $definition
                    }
                    $entry = Save-FslFixRollbackEntry @saveParams
                    $rollbackRef = [string]$entry.RollbackRef
                }
                catch {
                    Add-FslError -ErrorRecord $_ -Component $component -Context "Update the rollback entry for $currentActionId"
                }

                # Verify by detecting again (G21). A failed verification is never rolled back automatically.
                $verification = Invoke-FslFixDetect -Definition $definition -Parameters $handlerParameters
                $verified = ([bool]$outcome['Success'] -and -not [bool]$verification.Needed -and [string]::IsNullOrWhiteSpace([string]$verification.BlockReason))
                $verificationStatus = if ($verified) { 'Verified' } else { 'Failed' }
                $undoHint = if ($rollbackAvailable) { " Run 'Undo-FslRepair -RunId $($run.RunId) -ActionId $currentActionId' to restore the recorded state." }
                else { ' This action has no rollback (RollbackMethod None); check the state manually.' }
                $message = if ($verified) {
                    'Applied and verified. {0} Now: {1}.' -f [string]$outcome['Message'], [string]$verification.CurrentValue
                }
                else {
                    'The change did not verify. {0} Now: {1}.{2}' -f [string]$outcome['Message'], [string]$verification.CurrentValue, $undoHint
                }

                $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $item -Mode 'Executed' `
                        -Status $(if ($verified) { 'Pass' } else { 'Fail' }) -Message $message -BeforeState $freshState -AfterState $afterState `
                        -VerificationStatus $verificationStatus -RollbackAvailable $rollbackAvailable -RollbackRef $rollbackRef)
                $results.Add((New-FslFixActionResult -Action $item -Status $(if ($verified) { 'Pass' } else { 'Fail' }) -Message $message `
                            -Value ([string]$verification.CurrentValue) -Recommendation $(if ($verified) { '' } else { "Run Undo-FslRepair -RunId $($run.RunId) if the change must be reverted." })))
            }
        }
        catch {
            $runFaulted = $true
            Add-FslError -ErrorRecord $_ -Component $component -Context "Repair run $($run.RunId)"
            $results.Add((New-FslResult -Category 'Repair' -Check 'RepairRun' -Status 'Error' -Target ([string]$run.RunId) `
                        -Message "The repair run stopped with an error: $($_.Exception.Message)" -Source 'Toolkit default' -RequiresElevation $true))
        }
        finally {
            $summary = $null
            try { $summary = Complete-FslFixRun -Run $run }
            catch { Add-FslError -ErrorRecord $_ -Component $component -Context "Complete the repair run $($run.RunId)" }
            if ($null -ne $summary) {
                # A run that stopped with an error must never summarise as Pass, even when no record was written.
                $status = if ($runFaulted) { 'Error' }
                elseif ([int]$summary.Fail -gt 0 -or [int]$summary.Error -gt 0) { 'Fail' }
                elseif ([int]$summary.ModeBlocked -gt 0 -and $runMode -ne 'WhatIf') { 'Warn' }
                elseif ($runMode -eq 'WhatIf') { 'Info' }
                else { 'Pass' }
                $message = 'Repair run {0} ({1}) finished: {2} action(s), Pass {3}, Fail {4}, Error {5}, Skipped {6}, Info {7}. Log: {8}' -f
                $summary.RunId, $run.Mode, $summary.Total, $summary.Pass, $summary.Fail, $summary.Error, $summary.Skipped, $summary.Info, $summary.LogPath
                $results.Add((New-FslFixRunResult -Run $run -Summary $summary -Status $status -Message $message `
                            -Recommendation $(if ($status -in 'Fail', 'Error') { "Review the run log and run Undo-FslRepair -RunId $($summary.RunId) when a change must be reverted." } else { '' })))
            }
        }

        return $results.ToArray()
    }
}
