function Invoke-FslBestPracticeAnalyzer {
    <#
    .SYNOPSIS
        Analyzes FSLogix settings against Microsoft-documented recommendations and defaults.

    .DESCRIPTION
        Evaluates FSLogix registry settings (Setting objects, contract 5.2) against the data-driven rules in
        Config/BestPractices.psd1. Each rule compares one registry value with the value Microsoft recommends in
        the FSLogix configuration examples or the configuration settings reference. When a setting is not
        configured, the documented default value is used and the Message says so.

        Cross-checks evaluate combinations of settings documented by Microsoft (for example VHDLocations and
        CCDLocations must not both be present, containers enabled without a storage location, more than four
        Cloud Cache providers, plain-text Azure connection strings).

        When -Setting is not supplied, settings are read with Get-FslEffectiveSetting (Windows only). On
        non-Windows systems a Skipped result is returned unless -Setting is supplied, so the analyzer can be
        run offline against exported or fabricated settings.

        Every result carries Scope (contract P2.2): rules and cross-checks of setting scope Profiles -> Profiles,
        ODFC -> ODFC, Logging/Apps -> General; analyzer-level Skipped/Error results are General. Rules and
        cross-checks of scopes not listed in -Scope are not evaluated, so -Scope ODFC,Logging,Apps (Office
        containers only) never produces Profiles results.

        ODFC rules follow the recommended values in "Configure ODFC containers" (Enabled, FlipFlopProfileDirectoryName,
        IncludeTeams, LockedRetryCount, LockedRetryInterval, ReAttachIntervalSeconds, ReAttachRetryCount, VolumeType)
        plus documented cautions/defaults from the ODFC section of the configuration settings reference.

        Rule severity (Fail/Warn/Info) is a toolkit classification; the recommended values come from the
        Source URL recorded on each result. Storage location paths and connection strings are never echoed.

    .PARAMETER Setting
        Setting objects (FSLogixToolkit.Setting: Scope, Name, Value, ValueKind, RegistryPath, Source, PolicyName,
        ComputerName). Only Scope, Name, Value and Source are used. When omitted, Get-FslEffectiveSetting is called.

    .PARAMETER Scope
        Setting scopes to analyze: Profiles, ODFC, Logging, Apps. Defaults to all. Only rules and cross-checks of
        these scopes are evaluated and, when -Setting is omitted, only these scopes are read.

    .EXAMPLE
        Invoke-FslBestPracticeAnalyzer

        Reads the effective FSLogix settings of the local computer and evaluates all rules.

    .EXAMPLE
        $settings = Get-FslEffectiveSetting -Scope Profiles
        Invoke-FslBestPracticeAnalyzer -Setting $settings -Scope Profiles | Where-Object -Property Status -NE 'Pass'

        Analyzes only profile container settings and shows deviations.

    .EXAMPLE
        Invoke-FslBestPracticeAnalyzer -Scope ODFC, Logging, Apps

        Office containers only (default toolkit container mode): evaluates ODFC, Logging and Apps rules; no Profiles results.

    .EXAMPLE
        $settings = @([pscustomobject]@{ Scope = 'Profiles'; Name = 'Enabled'; Value = 1; ValueKind = 'DWord'; Source = 'Registry' })
        Invoke-FslBestPracticeAnalyzer -Setting $settings

        Offline analysis of a fabricated setting set (works on any platform).

    .OUTPUTS
        FSLogixToolkit.Result (Category BestPractice).

    .NOTES
        RequiresElevation: No (reading HKLM FSLogix keys is done by Get-FslEffectiveSetting).
        Rules data: Config/BestPractices.psd1 (DataVerifiedOn recorded in the file).
        Sources:
          https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#registry-settings-standard
          https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#registry-settings-standard--high-availability
          https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#object-specific-vhdlocations
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#container-specific-settings
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#ccdlocations
          https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers#odfc-container-configuration
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#odfc-container-settings
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#vhdaccessmode
          https://learn.microsoft.com/en-us/microsoftteams/teams-client-vdi-requirements-deploy#profile-and-cache-location-for-the-teams-client
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Setting,

        [Parameter()]
        [ValidateSet('Profiles', 'ODFC', 'Logging', 'Apps')]
        [string[]] $Scope = @('Profiles', 'ODFC', 'Logging', 'Apps')
    )

    begin {
        $component = 'BestPractice'
        $collected = [System.Collections.Generic.List[object]]::new()
        $settingSupplied = $PSBoundParameters.ContainsKey('Setting')
    }

    process {
        if ($null -ne $Setting) {
            foreach ($item in $Setting) {
                if ($null -ne $item) { $collected.Add($item) }
            }
        }
    }

    end {
        # Pipeline input binds per item; treat any pipeline/bound input as supplied.
        if ($collected.Count -gt 0) { $settingSupplied = $true }

        if (-not $settingSupplied) {
            if (-not (Test-FslIsWindows)) {
                New-FslResult -Category 'BestPractice' -Check 'Best practice analysis' -Status 'Skipped' -Target 'FSLogix settings' `
                    -Message 'FSLogix registry settings can only be read on Windows. Supply -Setting to analyze offline.' `
                    -Source 'Toolkit default' -RequiresElevation $false -Scope 'General'
                return
            }
            try {
                foreach ($item in @(Get-FslEffectiveSetting -Scope $Scope -ErrorAction Stop)) {
                    if ($null -ne $item) { $collected.Add($item) }
                }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component $component -Context 'Reading effective FSLogix settings (Get-FslEffectiveSetting)'
                New-FslResult -Category 'BestPractice' -Check 'Best practice analysis' -Status 'Error' -Target 'FSLogix settings' `
                    -Message "Could not read FSLogix settings: $($_.Exception.Message)" -Source 'Toolkit default' -RequiresElevation $false -Scope 'General'
                return
            }
        }

        $settings = $collected.ToArray()
        Write-FslLog -Message "Best practice analysis started: $($settings.Count) setting(s), scope(s) $($Scope -join ', ')." -Level Info -Component $component

        try {
            $data = Get-FslDataFile -Name 'BestPractices'
            if ($null -eq $data -or -not ($data -is [System.Collections.IDictionary]) -or -not $data.Contains('Rules')) {
                throw [System.IO.InvalidDataException]::new('Config/BestPractices.psd1 did not return a hashtable with a Rules key.')
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $component -Context 'Loading Config/BestPractices.psd1'
            New-FslResult -Category 'BestPractice' -Check 'Best practice rules' -Status 'Error' -Target 'Config/BestPractices.psd1' `
                -Message "Could not load best practice rules: $($_.Exception.Message)" -Source 'Toolkit default' -RequiresElevation $false -Scope 'General'
            return
        }

        foreach ($rule in @($data['Rules'])) {
            $ruleId = [string](Get-FslBpaPropertyValue -InputObject $rule -Name 'Id')
            # Skip rules of scopes that were not requested before any evaluation (no Profiles work in ODFC mode).
            $ruleScope = [string](Get-FslBpaPropertyValue -InputObject $rule -Name 'Scope')
            if ($ruleScope -in @('Profiles', 'ODFC', 'Logging', 'Apps') -and $ruleScope -notin $Scope) { continue }
            try {
                $problems = @(Test-FslBpaRuleDefinition -Rule $rule)
                if ($problems.Count -gt 0) {
                    Write-FslLog -Message "Invalid rule '$ruleId': $($problems -join ' ')" -Level Warning -Component $component
                    New-FslResult -Category 'BestPractice' -Check "Rule definition $ruleId" -Status 'Error' -Target 'Config/BestPractices.psd1' `
                        -Message "Invalid rule definition: $($problems -join ' ')" -Source 'Toolkit default' -RequiresElevation $false -Scope 'General'
                    continue
                }
                Invoke-FslBpaRule -Rule $rule -Setting $settings
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component $component -Context "Evaluating rule $ruleId"
                New-FslResult -Category 'BestPractice' -Check "Rule $ruleId" -Status 'Error' -Target 'Config/BestPractices.psd1' `
                    -Message "Rule evaluation failed: $($_.Exception.Message)" -Source 'Toolkit default' -RequiresElevation $false -Scope 'General'
            }
        }

        $crossChecks = if ($data.Contains('CrossChecks')) { @($data['CrossChecks']) } else { @() }
        foreach ($crossCheck in $crossChecks) {
            $checkId = [string](Get-FslBpaPropertyValue -InputObject $crossCheck -Name 'Id')
            try {
                $handler = [string](Get-FslBpaPropertyValue -InputObject $crossCheck -Name 'Handler')
                $source = [string](Get-FslBpaPropertyValue -InputObject $crossCheck -Name 'Source')
                # Only private Test-FslBpa* functions may be invoked from data (no arbitrary commands).
                $command = if ($handler -match '^Test-FslBpa[A-Za-z]+$') { Get-Command -Name $handler -CommandType Function -ErrorAction SilentlyContinue } else { $null }
                if ($crossCheck -isnot [System.Collections.IDictionary] -or $null -eq $command -or
                    -not $source.StartsWith('https://learn.microsoft.com/', [System.StringComparison]::OrdinalIgnoreCase)) {
                    New-FslResult -Category 'BestPractice' -Check "Cross-check definition $checkId" -Status 'Error' -Target 'Config/BestPractices.psd1' `
                        -Message "Invalid cross-check definition (handler '$handler' not allowed/found, or Source is not a learn.microsoft.com URL)." `
                        -Source 'Toolkit default' -RequiresElevation $false -Scope 'General'
                    continue
                }
                # Get-FslBpaPropertyValue preserves arrays; do not wrap in @() (would nest the array).
                $checkScopes = Get-FslBpaPropertyValue -InputObject $crossCheck -Name 'Scopes'
                foreach ($checkScope in $checkScopes) {
                    if ([string]$checkScope -notin $Scope) { continue }
                    & $command -CrossCheck $crossCheck -Setting $settings -Scope ([string]$checkScope)
                }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component $component -Context "Evaluating cross-check $checkId"
                New-FslResult -Category 'BestPractice' -Check "Cross-check $checkId" -Status 'Error' -Target 'Config/BestPractices.psd1' `
                    -Message "Cross-check evaluation failed: $($_.Exception.Message)" -Source 'Toolkit default' -RequiresElevation $false -Scope 'General'
            }
        }

        Write-FslLog -Message 'Best practice analysis completed.' -Level Info -Component $component
    }
}
