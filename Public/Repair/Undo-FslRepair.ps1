function Undo-FslRepair {
    <#
    .SYNOPSIS
        Restores the state a repair run recorded before it changed anything (per action, from the verified rollback store).

    .DESCRIPTION
        Reads the rollback store of the run (Repair.StateRoot\<RunId>\rollback.json with its SHA256 manifest) and, for
        every action of that run:
          - refuses when the store fails its integrity check (the whole undo is refused, nothing is changed);
          - refuses the action when the current state is not the state the repair left behind (drift) - somebody or
            something changed it after the repair, so the recorded rollback is no longer the right answer;
          - restores the recorded value, value kind or service start type; a value the repair created is removed again;
          - detects again afterwards and records whether the recorded state is back.
        Actions whose catalog entry has RollbackMethod None (for example "start the stopped frxsvc service": the
        toolkit never stops FSLogix services) are reported as Skipped. Undoing writes its own run (Mode Undo) with its
        own log, and marks the reverted actions in the original run's rollback store.

    .PARAMETER RunId
        RunId of the repair run to undo (Get-FslRepairLog shows the runs, the repair log line "RunId" names it).

    .PARAMETER ActionId
        Only undo these actions of the run. Default: every action of the run.

    .EXAMPLE
        Undo-FslRepair -RunId 'd2f1a0c4-6b0e-4a51-9d7e-2b1f0e7c9a11' -WhatIf

    .EXAMPLE
        Undo-FslRepair -RunId 'd2f1a0c4-6b0e-4a51-9d7e-2b1f0e7c9a11' -ActionId 'FIX-LOG-02'

        Ends the temporary verbose logging that FIX-LOG-02 turned on.

    .OUTPUTS
        FSLogixToolkit.Result

    .NOTES
        RequiresElevation: Yes (the rollback store is admin-only and the changes are machine-wide).
        Sources:
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
          https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components
          https://learn.microsoft.com/dotnet/api/system.security.cryptography.sha256.hashdata
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('FSLogixToolkit.Result')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [guid] $RunId,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $ActionId
    )

    $component = 'Repair'
    $results = [System.Collections.Generic.List[object]]::new()
    $isWhatIf = [bool]$WhatIfPreference
    $runIdText = $RunId.ToString('D')

    # ---- pre-flight (run-wide gates only; taken before the undo run takes the single-run lock) -----------------
    $preflightMode = if ($isWhatIf) { 'Preview' } else { 'Undo' }
    $preflight = @()
    try {
        $preflight = @(Get-FslFixPreflightResult -Action @() -Mode $preflightMode)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component $component -Context 'Run the pre-flight gates for an undo'
    }
    foreach ($item in $preflight) { $results.Add($item) }
    $runBlocking = @(Test-FslFixPreflightBlocking -Result $preflight -ActionId '')
    if ($runBlocking.Count -gt 0) {
        $reasons = (@($runBlocking | ForEach-Object -Process { '{0}: {1}' -f $_.Check, $_.Message }) -join ' | ')
        $results.Add((New-FslResult -Category 'Repair' -Check 'RepairRun' -Status 'Fail' -Target $runIdText `
                    -Message "Blocked: the undo was refused by the pre-flight gates. $reasons Nothing was changed." `
                    -Recommendation 'Fix the reported gates and run the undo again.' -Source 'Toolkit default' -RequiresElevation $true))
        return $results.ToArray()
    }

    # ---- rollback store ---------------------------------------------------------------------------------------
    if (-not (Test-FslFixRollbackIntegrity -RunId $RunId)) {
        $results.Add((New-FslResult -Category 'Repair' -Check 'RepairRun' -Status 'Error' -Target $runIdText `
                    -Message "Blocked: the rollback store of run $runIdText is missing or failed its SHA256 integrity check; nothing was changed." `
                    -Recommendation 'Restore the state manually using the repair log of that run (Get-FslRepairLog -RunId <run> -IncludeRecords).' `
                    -Source 'Toolkit default' -RequiresElevation $true))
        return $results.ToArray()
    }
    $entryParams = @{ RunId = $RunId }
    if ($ActionId) { $entryParams['ActionId'] = $ActionId }
    $entries = @(Get-FslFixRollbackEntry @entryParams)
    if ($entries.Count -eq 0) {
        $results.Add((New-FslResult -Category 'Repair' -Check 'RepairRun' -Status 'Info' -Target $runIdText `
                    -Message "The rollback store of run $runIdText holds no matching action; nothing was changed." -Source 'Toolkit default' -RequiresElevation $true))
        return $results.ToArray()
    }

    $run = $null
    try {
        # A preview must not touch the rollback store: Mode WhatIf takes no single-run lock, creates no StateRoot and
        # no <StateRoot>\<RunId> folder (contract P3.4), while still writing the readable run log.
        $run = New-FslFixRun -Mode $(if ($isWhatIf) { 'WhatIf' } else { 'Undo' }) -RollbackOfRunId $RunId -InvocationSource 'Undo-FslRepair'
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component $component -Context 'Start the undo run'
        $results.Add((New-FslResult -Category 'Repair' -Check 'RepairRun' -Status 'Error' -Target $runIdText `
                    -Message "Blocked: the undo run could not be started: $($_.Exception.Message). Nothing was changed." -Source 'Toolkit default' -RequiresElevation $true))
        return $results.ToArray()
    }

    $runFaulted = $false
    try {
        Add-FslFixPreflight -Run $run -Result $preflight

        foreach ($entry in $entries) {
            $entryActionId = [string]$entry.ActionId
            $definition = @(Get-FslFixActionDefinition -ActionId @($entryActionId)) | Select-Object -First 1
            $action = [pscustomobject]@{
                ActionId          = $entryActionId
                Title             = if ($null -ne $definition) { [string]$definition['Title'] } else { $entryActionId }
                Scope             = if ($null -ne $definition) { [string]$definition['Scope'] } else { 'General' }
                RiskTier          = if ($null -ne $definition) { [int]$definition['RiskTier'] } else { $null }
                Target            = if ($null -ne $definition) { Get-FslFixTargetText -Definition $definition } else { $entryActionId }
                CurrentValue      = ''
                ProposedValue     = 'the state recorded before the repair'
                Source            = if ($null -ne $definition) { [string](Get-FslFixDefinitionValue -Definition $definition -Name 'Source' -Default '') } else { '' }
                RequiresElevation = $true
                Condition         = "Undo of run $runIdText"
                BeforeState       = $entry.AfterState
            }

            if ($null -eq $definition) {
                $message = "Blocked: the action $entryActionId is not in the repair catalog any more, so its rollback handler is unknown."
                $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $action -Mode 'Blocked' -Status 'Skipped' -Message $message)
                $results.Add((New-FslFixActionResult -Action $action -Status 'Fail' -Message $message))
                continue
            }
            if ([bool]$entry.Reverted) {
                $message = "This action was already reverted (by run $([string]$entry.RevertedByRunId)); nothing was changed."
                $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $action -Mode 'Blocked' -Status 'Info' -Message $message)
                $results.Add((New-FslFixActionResult -Action $action -Status 'Info' -Message $message))
                continue
            }
            $rollbackHandler = [string](Get-FslFixDefinitionValue -Definition $definition -Name 'Rollback' -Default '')
            if ([string]::IsNullOrWhiteSpace($rollbackHandler) -or [string]$definition['RollbackMethod'] -eq 'None') {
                $message = "This action has no rollback (RollbackMethod $([string]$definition['RollbackMethod'])): $([string](Get-FslFixDefinitionValue -Definition $definition -Name 'Guidance' -Default ''))"
                $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $action -Mode 'Blocked' -Status 'Skipped' -Message $message)
                $results.Add((New-FslFixActionResult -Action $action -Status 'Warn' -Message $message))
                continue
            }

            $kind = [string]$definition['Kind']
            $recordedAfter = ConvertTo-FslFixHashtable -InputObject $entry.AfterState
            $recordedBefore = ConvertTo-FslFixHashtable -InputObject $entry.BeforeState

            # Container actions: re-detection needs the user the repair acted on, and after a successful reset the
            # container file is gone, so the generic state comparison below cannot be used (it would block every undo).
            # The rollback handler makes the equivalent checks itself, immediately before it acts: it refuses when a
            # container exists again at the original path, when the per-user folder is gone, and when the archived file
            # is missing or no longer matches the SHA256 recorded at apply time.
            $isContainerKind = ($kind -eq 'Container')
            $detectParameters = @{}
            if ($isContainerKind) {
                foreach ($state in @($recordedAfter, $recordedBefore)) {
                    if ($null -eq $state) { continue }
                    foreach ($pair in @(@{ From = 'Sid'; To = 'UserSid' }, @{ From = 'UserName'; To = 'UserName' }, @{ From = 'ArchiveRootPath'; To = 'ArchivePath' })) {
                        $value = [string](Get-FslFixValue -InputObject $state -Name $pair['From'])
                        if (-not [string]::IsNullOrWhiteSpace($value) -and -not $detectParameters.ContainsKey($pair['To'])) { $detectParameters[$pair['To']] = $value }
                    }
                }
            }
            $current = Invoke-FslFixDetect -Definition $definition -Parameters $detectParameters
            $currentState = ConvertTo-FslFixHashtable -InputObject $current.BeforeState
            $action.CurrentValue = [string]$current.CurrentValue

            if ($null -eq $recordedBefore) {
                $message = "Blocked: the rollback store has no before state for $entryActionId; nothing was changed."
                $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $action -Mode 'Blocked' -Status 'Error' -Message $message)
                $results.Add((New-FslFixActionResult -Action $action -Status 'Error' -Message $message))
                continue
            }
            if (-not $isContainerKind) {
                if (Test-FslFixStateMatch -Kind $kind -Expected $recordedBefore -Actual $currentState) {
                    $message = 'The recorded state is already in place; nothing was changed.'
                    $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $action -Mode 'Blocked' -Status 'Info' -Message $message -BeforeState $currentState)
                    $results.Add((New-FslFixActionResult -Action $action -Status 'Pass' -Message $message))
                    continue
                }
                if ($null -eq $recordedAfter -or -not (Test-FslFixStateMatch -Kind $kind -Expected $recordedAfter -Actual $currentState)) {
                    $message = "Blocked: the current state is not the state the repair left behind (current: $([string]$current.CurrentValue)). Something changed it after the repair, so the recorded rollback is not applied."
                    $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $action -Mode 'Blocked' -Status 'Skipped' -Message $message -BeforeState $currentState -AfterState $recordedAfter)
                    $results.Add((New-FslFixActionResult -Action $action -Status 'Fail' -Message $message `
                                -Recommendation 'Compare the current state with the repair log of that run and correct it deliberately.'))
                    continue
                }
            }
            elseif ($null -eq $recordedAfter) {
                $message = "Blocked: the rollback store has no after state for $entryActionId, so the archived container cannot be located; nothing was changed."
                $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $action -Mode 'Blocked' -Status 'Error' -Message $message -BeforeState $currentState)
                $results.Add((New-FslFixActionResult -Action $action -Status 'Error' -Message $message))
                continue
            }

            $target = 'undo {0} on {1} (restore: {2})' -f $entryActionId, $action.Target, (ConvertTo-FslFixText -InputObject $recordedBefore)
            # A host that cannot show the confirmation prompt (redirected input, a scheduled task, a background
            # runspace) makes ShouldProcess throw. That must stop this entry only, not the whole undo run.
            $proceed = $false
            try {
                $proceed = $PSCmdlet.ShouldProcess($target, "Undo $entryActionId")
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component $component -Context "Confirmation prompt for the undo of $entryActionId"
                $message = 'The confirmation prompt could not be shown in this session, so nothing was changed. Run the undo with -Confirm:$false when the session cannot answer prompts.'
                $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $action -Mode 'Blocked' -Status 'Fail' -Message $message -BeforeState $currentState)
                $results.Add((New-FslFixActionResult -Action $action -Status 'Fail' -Message $message `
                            -Recommendation 'Re-run the undo with -Confirm:$false, or run it in a session that can answer a confirmation prompt.'))
                continue
            }
            if ($isWhatIf) {
                $message = "WhatIf: would restore the state recorded before $entryActionId."
                $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $action -Mode 'WhatIf' -Status 'Info' -Message $message -BeforeState $currentState -VerificationStatus 'NotRun')
                $results.Add((New-FslFixActionResult -Action $action -Status 'Info' -Message $message))
                continue
            }
            if (-not $proceed) {
                $message = 'The operator declined the undo at the confirmation prompt; nothing was changed.'
                $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $action -Mode 'Declined' -Status 'Skipped' -Message $message -BeforeState $currentState)
                $results.Add((New-FslFixActionResult -Action $action -Status 'Info' -Message $message))
                continue
            }

            $outcome = Invoke-FslFixRollback -Definition $definition -BeforeState $recordedBefore -AfterState $recordedAfter
            $verification = Invoke-FslFixDetect -Definition $definition -Parameters $detectParameters
            $restoredState = ConvertTo-FslFixHashtable -InputObject $verification.BeforeState
            # Container: the handler verifies the restored file itself (length + SHA256 against the archived copy)
            # before it reports Success, so its result is the authority; every other kind is compared against the store.
            $restored = if ($isContainerKind) { [bool]$outcome['Success'] }
            else { ([bool]$outcome['Success'] -and (Test-FslFixStateMatch -Kind $kind -Expected $recordedBefore -Actual $restoredState)) }
            $message = if ($restored) {
                'Restored the state recorded before the repair. {0} Now: {1}.' -f [string]$outcome['Message'], [string]$verification.CurrentValue
            }
            else {
                'The undo did not restore the recorded state. {0} Now: {1}.' -f [string]$outcome['Message'], [string]$verification.CurrentValue
            }
            $null = Add-FslFixRecord -Run $run -Record (New-FslFixActionRecord -Action $action -Mode 'Undo' `
                    -Status $(if ($restored) { 'Pass' } else { 'Fail' }) -Message $message -BeforeState $currentState -AfterState $restoredState `
                    -VerificationStatus $(if ($restored) { 'Verified' } else { 'Failed' }) -RollbackAvailable $false -RollbackRef ('{0}/{1}' -f $runIdText, $entryActionId))
            $results.Add((New-FslFixActionResult -Action $action -Status $(if ($restored) { 'Pass' } else { 'Fail' }) -Message $message -Value ([string]$verification.CurrentValue)))
        }
    }
    catch {
        $runFaulted = $true
        Add-FslError -ErrorRecord $_ -Component $component -Context "Undo run for $runIdText"
        $results.Add((New-FslResult -Category 'Repair' -Check 'RepairRun' -Status 'Error' -Target ([string]$run.RunId) `
                    -Message "The undo run stopped with an error: $($_.Exception.Message)" -Source 'Toolkit default' -RequiresElevation $true))
    }
    finally {
        $summary = $null
        try { $summary = Complete-FslFixRun -Run $run }
        catch { Add-FslError -ErrorRecord $_ -Component $component -Context "Complete the undo run $($run.RunId)" }
        if ($null -ne $summary) {
            # A run that stopped with an error must never summarise as Pass, even when no record was written.
            $status = if ($runFaulted) { 'Error' }
            elseif ([int]$summary.Fail -gt 0 -or [int]$summary.Error -gt 0) { 'Fail' } elseif ($isWhatIf) { 'Info' } else { 'Pass' }
            $message = 'Undo run {0} of repair run {1} finished: {2} action(s), Pass {3}, Fail {4}, Error {5}, Skipped {6}, Info {7}. Log: {8}' -f
            $summary.RunId, $runIdText, $summary.Total, $summary.Pass, $summary.Fail, $summary.Error, $summary.Skipped, $summary.Info, $summary.LogPath
            $results.Add((New-FslFixRunResult -Run $run -Summary $summary -Status $status -Message $message))
        }
    }

    return $results.ToArray()
}
