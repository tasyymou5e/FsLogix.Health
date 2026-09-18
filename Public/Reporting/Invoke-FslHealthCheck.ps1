function Invoke-FslHealthCheck {
    <#
    .SYNOPSIS
        Runs the read-only FSLogixToolkit checks for the selected container mode and returns all Result objects.

    .DESCRIPTION
        Resolves the container mode (-ContainerScope, default Get-FslContainerMode: ODFC unless the user
        preference or settings select Profiles or Both) into container scopes with
        Resolve-FslPrefContainerScope (ODFC -> ODFC; Profiles -> Profiles; Both -> ODFC, Profiles) and runs
        each selected category, isolated in its own try/catch (contract P2.4):
          Discovery    -> Get-FslDiscoveryReport [-Offline]
          Environment  -> Get-FslEnvironment [-Offline]
          Policy       -> Get-FslGpoReport -Scope <scopes>
          BestPractice -> Invoke-FslBestPracticeAnalyzer -Scope <scopes + Logging, Apps>
          Containers   -> Get-FslContainerReport -Scope <scopes>
          Performance  -> Test-FslStoragePerformance -Scope <scopes> [-IncludeWriteTest]
          Network      -> Test-FslNetworkHealth -Scope <scopes>
          Diagnostics  -> Get-FslLogSummary -Scope <scopes> and Get-FslKnownIssue -Scope <scopes>
        Only parameters that the called function declares are passed (Get-Command .Parameters). When a
        scope-specific function does not declare -Scope, it is called without -Scope only when the mode is
        Both (it would cover both scopes anyway); otherwise it is not called and a Skipped Result is returned,
        so no Profiles-scope work runs in ODFC mode (and no ODFC work in Profiles mode).
        As a safety net, Results whose Scope is outside the selected mode (for example Scope Profiles in
        ODFC mode) are dropped (logged Verbose), except Discovery results with Target 'Mode', which report
        a mismatch between the image configuration and the toolkit mode and must stay visible.
        When a check function is missing or throws, a Result with Status 'Error' (carrying -Scope when the
        step is scope-specific and a single scope is selected) is emitted and the error is recorded with
        Add-FslError; remaining categories still run.
        Maintenance functions (Invoke-FslContainerShrink, Remove-FslStaleContainer) are never run.

    .PARAMETER Category
        Categories to run. Default: Discovery, Environment, Policy, BestPractice, Containers, Performance,
        Network, Diagnostics.

    .PARAMETER ContainerScope
        Container mode: ODFC (Office containers only), Profiles or Both. Default: Get-FslContainerMode.

    .PARAMETER IncludeWriteTest
        Passes -IncludeWriteTest to Test-FslStoragePerformance (opt-in temporary file write/read test;
        the file is removed by that function).

    .PARAMETER Offline
        Passes -Offline to Get-FslDiscoveryReport and Get-FslEnvironment so no online lookups are made.

    .EXAMPLE
        Invoke-FslHealthCheck | Export-FslReport

        Runs all categories for the configured container mode (ODFC by default) and exports reports.

    .EXAMPLE
        Invoke-FslHealthCheck -Category Environment, Diagnostics -ContainerScope Both -Offline

    .OUTPUTS
        FSLogixToolkit.Result

    .NOTES
        RequiresElevation: No (individual checks return Skipped results when elevation is required)
        Sources:
          https://learn.microsoft.com/powershell/module/microsoft.powershell.core/get-command
          https://learn.microsoft.com/dotnet/api/system.management.automation.commandinfo.parameters
          https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_try_catch_finally
          Container mode / scope plumbing: Toolkit contract P2.2 and P2.4.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateSet('Discovery', 'Environment', 'Policy', 'BestPractice', 'Containers', 'Performance', 'Network', 'Diagnostics')]
        [string[]] $Category = @('Discovery', 'Environment', 'Policy', 'BestPractice', 'Containers', 'Performance', 'Network', 'Diagnostics'),

        [Parameter()]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $ContainerScope,

        [Parameter()]
        [switch] $IncludeWriteTest,

        [Parameter()]
        [switch] $Offline
    )

    if (-not $script:FslSession['Initialized']) {
        try {
            $null = Initialize-FslSession
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Reporting' -Context 'Initialize-FslSession before health check'
        }
    }

    # Resolve mode and scopes.
    $mode = 'ODFC'
    try {
        if ($PSBoundParameters.ContainsKey('ContainerScope')) { $mode = $ContainerScope }
        else { $mode = [string](Get-FslContainerMode) }
        if ($mode -notin @('ODFC', 'Profiles', 'Both')) {
            Write-FslLog -Message "Health check: unexpected container mode '$mode'; using ODFC." -Level Warning -Component 'Reporting'
            $mode = 'ODFC'
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Reporting' -Context 'Resolve container mode for health check'
        $mode = if ($PSBoundParameters.ContainsKey('ContainerScope')) { $ContainerScope } else { 'ODFC' }
    }
    $scopes = @(Resolve-FslRptHealthScope -Mode $mode)
    $allowedResultScopes = @('General') + $scopes
    $singleScope = if ($scopes.Count -eq 1) { $scopes[0] } else { $null }
    Write-FslLog -Message "Health check: container mode $mode (scopes: $($scopes -join ', ')); categories: $(@($Category) -join ', ')" -Level Info -Component 'Reporting'

    $bestPracticeScopes = @($scopes) + @('Logging', 'Apps')

    # Ordered plan: category -> steps. ScopeValue $null = not scope-specific. Maintenance is intentionally absent.
    $plan = [ordered]@{
        Discovery    = @(@{ Name = 'Get-FslDiscoveryReport'; Switches = @{ Offline = [bool]$Offline }; ScopeValue = $null })
        Environment  = @(@{ Name = 'Get-FslEnvironment'; Switches = @{ Offline = [bool]$Offline }; ScopeValue = $null })
        Policy       = @(@{ Name = 'Get-FslGpoReport'; Switches = @{}; ScopeValue = $scopes })
        BestPractice = @(@{ Name = 'Invoke-FslBestPracticeAnalyzer'; Switches = @{}; ScopeValue = $bestPracticeScopes })
        Containers   = @(@{ Name = 'Get-FslContainerReport'; Switches = @{}; ScopeValue = $scopes })
        Performance  = @(@{ Name = 'Test-FslStoragePerformance'; Switches = @{ IncludeWriteTest = [bool]$IncludeWriteTest }; ScopeValue = $scopes })
        Network      = @(@{ Name = 'Test-FslNetworkHealth'; Switches = @{}; ScopeValue = $scopes })
        Diagnostics  = @(
            @{ Name = 'Get-FslLogSummary'; Switches = @{}; ScopeValue = $scopes }
            @{ Name = 'Get-FslKnownIssue'; Switches = @{}; ScopeValue = $scopes }
        )
    }

    $selected = @($Category | Select-Object -Unique)
    foreach ($categoryName in $plan.Keys) {
        if ($categoryName -notin $selected) { continue }
        foreach ($step in $plan[$categoryName]) {
            $commandName = [string]$step['Name']
            $isScoped = $null -ne $step['ScopeValue']
            $errorScopeParams = @{}
            if ($isScoped -and $null -ne $singleScope) { $errorScopeParams['Scope'] = $singleScope }

            Write-FslLog -Message "Health check: running $commandName ($categoryName)" -Level Verbose -Component 'Reporting'
            $command = Get-Command -Name $commandName -CommandType Function -ErrorAction SilentlyContinue
            if ($null -eq $command) {
                $message = "Check function '$commandName' is not available in this module build."
                $exception = [System.Management.Automation.CommandNotFoundException]::new($message)
                $record = [System.Management.Automation.ErrorRecord]::new($exception, 'FslHealthCheckCommandMissing', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $commandName)
                Add-FslError -ErrorRecord $record -Component 'Reporting' -Context "Health check category $categoryName"
                New-FslResult -Category $categoryName -Check "HealthCheck: $commandName" -Status 'Error' -Target $commandName `
                    -Message $message -Recommendation 'Verify the module files are complete and re-import the module.' -Source 'Toolkit default' @errorScopeParams
                continue
            }

            # Only pass switches that are set and that the command actually declares.
            $splat = @{}
            foreach ($key in $step['Switches'].Keys) {
                if ($step['Switches'][$key]) {
                    if ($command.Parameters.ContainsKey($key)) { $splat[$key] = $true }
                    else { Write-FslLog -Message "Health check: $commandName does not declare -$key; not passed." -Level Verbose -Component 'Reporting' }
                }
            }

            if ($isScoped) {
                if ($command.Parameters.ContainsKey('Scope')) {
                    $splat['Scope'] = [string[]]@($step['ScopeValue'])
                }
                elseif ($mode -eq 'Both') {
                    Write-FslLog -Message "Health check: $commandName does not declare -Scope; running without -Scope (mode Both covers all scopes)." -Level Verbose -Component 'Reporting'
                }
                else {
                    $message = "Check function '$commandName' does not support -Scope in this module build; it was not run so that no work outside container mode $mode is performed."
                    Write-FslLog -Message "Health check: $message" -Level Verbose -Component 'Reporting'
                    New-FslResult -Category $categoryName -Check "HealthCheck: $commandName" -Status 'Skipped' -Target $commandName `
                        -Value $mode -Message $message -Recommendation 'Update the module files, or run with -ContainerScope Both.' -Source 'Toolkit default' @errorScopeParams
                    continue
                }
            }

            try {
                $stepErrors = $null
                $stepOutput = @(& $command @splat -ErrorVariable stepErrors -ErrorAction Continue)
                foreach ($stepError in @($stepErrors)) {
                    if ($null -ne $stepError) {
                        Write-FslLog -Message "Health check: $commandName wrote a non-terminating error: $($stepError.ToString())" -Level Warning -Component 'Reporting'
                    }
                }
                $dropped = 0
                foreach ($item in $stepOutput) {
                    if ($null -eq $item) { continue }
                    $itemScope = Get-FslRptResultScope -InputObject $item
                    $keep = $itemScope -in $allowedResultScopes
                    if (-not $keep -and $categoryName -eq 'Discovery' -and (Get-FslRptPropertyValue -InputObject $item -Name 'Target') -eq 'Mode') { $keep = $true }
                    if ($keep) { $item }
                    else { $dropped++ }
                }
                if ($dropped -gt 0) {
                    Write-FslLog -Message "Health check: dropped $dropped result(s) from $commandName with a Scope outside container mode $mode." -Level Verbose -Component 'Reporting'
                }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Reporting' -Context "Health check $commandName ($categoryName)"
                New-FslResult -Category $categoryName -Check "HealthCheck: $commandName" -Status 'Error' -Target $commandName `
                    -Message "Check failed: $($_.Exception.Message)" -Recommendation 'Review the error log (Get-FslErrorLog) and the toolkit log file.' -Source 'Toolkit default' @errorScopeParams
            }
        }
    }
}
