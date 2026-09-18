function Get-FslGpoReport {
    <#
    .SYNOPSIS
        Reports Group Policy Objects that configure FSLogix and the setting-level provenance of FSLogix values.
    .DESCRIPTION
        Computer scope (requires elevation): queries computer RSoP (WMI namespace root\rsop\computer, classes
        RSOP_RegistryPolicySetting and RSOP_GPO) for registry policy entries under SOFTWARE\FSLogix and
        SOFTWARE\Policies\FSLogix and emits Policy results for:
          - each GPO that configures FSLogix values (display name and value names),
          - each FSLogix registry policy entry (winning precedence 1, or overridden precedence > 1),
          - FSLogix values present in the registry that are not delivered by Group Policy according to RSoP,
          - the Microsoft note that FSLogix Group Policy settings under HKLM\SOFTWARE\FSLogix are preferences that
            remain in the registry when the GPO is removed or set to Not Configured (ODFC under
            HKLM\SOFTWARE\Policies\FSLogix\ODFC resets correctly).
        When not elevated the computer RSoP check returns a Skipped result with RequiresElevation = $true; a failed RSoP
        query returns an Error result and an RSoP query without any RSOP_GPO instance a Warn result. In all three cases
        Get-FslEffectiveSetting reports Source 'Unknown' (never 'Registry') and the 'not delivered by Group Policy'
        comparison is not emitted. Local Group Policy: RSoP documents a Local scope of management (RSOP_SOM type 1);
        a local GPO is reported like any other GPO when RSoP lists it (no local GPO name or id is assumed).
        User scope (-IncludeUserScope): runs 'gpresult /scope user /x <temp file> /f' for the signed-in user, reports
        whether the user RSoP XML mentions FSLogix, and removes the temporary file. FSLogix administrative template
        settings are Computer Configuration settings.
        The GroupPolicy RSAT module is not required.
        Result Scope: rows for registry keys under SOFTWARE\FSLogix\Profiles are Profiles, under
        SOFTWARE\Policies\FSLogix\ODFC are ODFC, and Logging/Apps/other rows (and host-level rows) are General.
        With -Scope, rows for the unselected container scope are filtered out (and its registry key is not read);
        Logging/Apps rows are always kept as General. A GPO row lists only the values of the selected scopes and
        carries their scope when they all belong to one scope, otherwise General.
    .PARAMETER IncludeUserScope
        Also generate and inspect the user-scope RSoP report with gpresult.
    .PARAMETER Scope
        One or more of Profiles, ODFC. Defaults to both (phase 1 behavior).
    .EXAMPLE
        Get-FslGpoReport -Scope ODFC
        Reports Group Policy provenance for Office container (ODFC), Logging and Apps settings only.
    .EXAMPLE
        Get-FslGpoReport -IncludeUserScope | Format-Table -Property Status, Check, Target, Message
    .OUTPUTS
        FSLogixToolkit.Result
    .NOTES
        RequiresElevation: Yes for computer-scope RSoP (Skipped otherwise); No for -IncludeUserScope.
        Sources:
          https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
          https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-registrypolicysetting
          https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-policysetting
          https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-gpo
          https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-som
          https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/gpresult
          https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/get-ciminstance
    #>
    [CmdletBinding()]
    [OutputType('FSLogixToolkit.Result')]
    param(
        [Parameter()]
        [switch] $IncludeUserScope,

        [Parameter()]
        [ValidateSet('Profiles', 'ODFC')]
        [string[]] $Scope = @('Profiles', 'ODFC')
    )

    $selectedScopes = @($Scope | Select-Object -Unique)

    $urls = Get-FslPolSourceUrl
    $category = 'Policy'

    if (-not (Test-FslIsWindows)) {
        New-FslResult -Category $category -Check 'Group Policy RSoP (computer)' -Status 'Skipped' -Target ([System.Environment]::MachineName) `
            -Message 'Group Policy and FSLogix are Windows-only; RSoP was not queried on this platform.' `
            -Source $urls.GroupPolicyTemplates -RequiresElevation $true -Scope 'General'
        return
    }

    $computerName = [System.Environment]::MachineName
    $scopeKeys = Get-FslPolScopeKey

    # ---------------- Computer scope (RSoP WMI) ----------------
    $rsop = Get-FslPolRsopState
    $rsopRows = $null
    switch ($rsop.Status) {
        'Ok' { $rsopRows = @($rsop.Rows) }
        'Failed' {
            New-FslResult -Category $category -Check 'Group Policy RSoP (computer)' -Status 'Error' -Target $computerName `
                -Message "Computer $($rsop.Detail). FSLogix setting provenance is Unknown (not Registry)." `
                -Recommendation 'Verify the Group Policy client and WMI are healthy (for example, run gpresult /scope computer /r elevated).' `
                -Source $urls.RsopRegistrySetting -RequiresElevation $true -Scope 'General'
        }
        'Unavailable' {
            New-FslResult -Category $category -Check 'Group Policy RSoP (computer)' -Status 'Warn' -Target $computerName -Value 0 `
                -Message "$($rsop.Detail). FSLogix setting provenance is reported as Unknown because Group Policy delivery could not be confirmed or ruled out." `
                -Recommendation 'Run gpupdate /force and gpresult /scope computer /r in an elevated session, then run the report again.' `
                -Source $urls.RsopGpo -RequiresElevation $true -Scope 'General'
        }
        default {
            New-FslResult -Category $category -Check 'Group Policy RSoP (computer)' -Status 'Skipped' -Target $computerName `
                -Message 'Computer-scope RSoP requires an elevated session; Group Policy provenance of FSLogix settings was not determined (Source is reported as Unknown).' `
                -Recommendation 'Run PowerShell as Administrator to report which GPOs (including Local Group Policy, when listed in RSoP) configure FSLogix.' `
                -Source $urls.RsopRegistrySetting -RequiresElevation $true -Scope 'General'
        }
    }

    if ($null -ne $rsopRows) {
        # Rows of the selected container scopes plus General (Logging/Apps/other) rows. $rsopRows stays complete for provenance.
        $reportRows = @($rsopRows | Where-Object -FilterScript {
                $rowScope = Get-FslPolKeyScope -RegistryKey $_.RegistryKey
                $rowScope -eq 'General' -or $rowScope -in $selectedScopes
            })
        if ($rsopRows.Count -eq 0) {
            New-FslResult -Category $category -Check 'Group Policy RSoP (computer)' -Status 'Info' -Target $computerName `
                -Value 0 -Message 'No Group Policy registry settings for SOFTWARE\FSLogix or SOFTWARE\Policies\FSLogix were found in computer RSoP.' `
                -Source $urls.RsopRegistrySetting -RequiresElevation $true -Scope 'General'
        }
        elseif ($reportRows.Count -eq 0) {
            New-FslResult -Category $category -Check 'Group Policy RSoP (computer)' -Status 'Info' -Target $computerName `
                -Value 0 -Message "Computer RSoP contains FSLogix registry policy settings, but none for the selected scope(s) ($($selectedScopes -join ', ')) or for Logging/Apps." `
                -Source $urls.RsopRegistrySetting -RequiresElevation $true -Scope (Get-FslPolCommonScope -Scope $selectedScopes)
        }
        else {
            # One result per GPO (values of the selected scopes only).
            foreach ($group in ($reportRows | Group-Object -Property GpoId)) {
                $first = $group.Group[0]
                $gpoLabel = if ($first.GpoName) { $first.GpoName } else { $first.GpoId }
                $valueNames = @($group.Group | ForEach-Object -Process { if ($_.ValueName) { "$($_.RegistryKey)\$($_.ValueName)" } else { $_.RegistryKey } } | Sort-Object -Unique)
                $gpoScope = Get-FslPolCommonScope -Scope @($group.Group | ForEach-Object -Process { Get-FslPolKeyScope -RegistryKey $_.RegistryKey })
                New-FslResult -Category $category -Check 'GPO configuring FSLogix' -Status 'Info' -Target $gpoLabel `
                    -Value $valueNames -Message "GPO '$gpoLabel' configures $($valueNames.Count) FSLogix registry value(s)." `
                    -Source $urls.RsopGpo -RequiresElevation $true -Scope $gpoScope
            }

            # One result per registry policy entry.
            foreach ($row in ($reportRows | Sort-Object -Property RegistryKey, ValueName, Precedence)) {
                $rowScope = Get-FslPolKeyScope -RegistryKey $row.RegistryKey
                $gpoLabel = if ($row.GpoName) { $row.GpoName } else { $row.GpoId }
                $target = if ($row.ValueName) { "HKLM:\$($row.RegistryKey)\$($row.ValueName)" } else { "HKLM:\$($row.RegistryKey)" }
                if ($row.Deleted) {
                    New-FslResult -Category $category -Check 'GPO setting provenance' -Status 'Info' -Target $target -Value $gpoLabel `
                        -Message "GPO '$gpoLabel' deletes this registry value/key (precedence $($row.Precedence))." `
                        -Source $urls.RsopRegistrySetting -RequiresElevation $true -Scope $rowScope
                }
                elseif ($row.Precedence -eq 1) {
                    New-FslResult -Category $category -Check 'GPO setting provenance' -Status 'Info' -Target $target -Value $gpoLabel `
                        -Expected 'Precedence 1' -Message "Winning setting delivered by GPO '$gpoLabel'." `
                        -Source $urls.RsopPolicySetting -RequiresElevation $true -Scope $rowScope
                }
                else {
                    New-FslResult -Category $category -Check 'GPO setting provenance' -Status 'Warn' -Target $target -Value $gpoLabel `
                        -Expected 'Precedence 1' -Message "GPO '$gpoLabel' also sets this value (precedence $($row.Precedence)) but is overridden by a higher-precedence GPO." `
                        -Recommendation 'Toolkit recommendation: configure each FSLogix value in a single GPO to avoid conflicting settings.' `
                        -Source $urls.RsopPolicySetting -RequiresElevation $true -Scope $rowScope
                }
            }

            $preferenceRows = @($reportRows | Where-Object -FilterScript { $_.RegistryKey -match '^SOFTWARE\\FSLogix(\\|$)' })
            if ($preferenceRows.Count -gt 0) {
                New-FslResult -Category $category -Check 'FSLogix GPO settings are preferences' -Status 'Info' -Target 'HKLM:\SOFTWARE\FSLogix' `
                    -Value $preferenceRows.Count `
                    -Message 'Microsoft: Group Policy settings stored under HKLM\SOFTWARE\FSLogix are preferences, not policies; if the GPO is removed or set to Not Configured the registry value remains. ODFC settings under HKLM\SOFTWARE\Policies\FSLogix\ODFC reset correctly.' `
                    -Recommendation 'When removing or un-configuring FSLogix GPO settings for Apps, Logging or Profiles, also remove the registry values from session hosts.' `
                    -Source $urls.GroupPolicyTemplates -RequiresElevation $true -Scope 'General'
            }
        }

        # Values present in the registry but not delivered by Group Policy (per RSoP).
        foreach ($scopeName in @($scopeKeys.Keys)) {
            # Never read the registry key of an unselected container scope.
            if ($scopeName -in @('Profiles', 'ODFC') -and $scopeName -notin $selectedScopes) { continue }
            $resultScope = if ($scopeName -in @('Profiles', 'ODFC')) { $scopeName } else { 'General' }
            $subKey = $scopeKeys[$scopeName]
            try {
                # InstallPath / InstallVersion under Apps are created by the installer (documented base values), not configuration.
                $values = @(Get-FslPolRegistryValue -SubKey $subKey | Where-Object -FilterScript {
                        -not ($scopeName -eq 'Apps' -and $_.Name -in @('InstallPath', 'InstallVersion'))
                    })
                if ($values.Count -eq 0) { continue }
                $notFromGpo = @(foreach ($item in $values) {
                        $provenance = Get-FslPolProvenance -RsopRow $rsopRows -SubKey $subKey -ValueName $item.Name -RsopStatus 'Ok'
                        if ($provenance.Source -ne 'GroupPolicy') { $item.Name }
                    })
                if ($notFromGpo.Count -gt 0) {
                    New-FslResult -Category $category -Check 'FSLogix values not delivered by Group Policy' -Status 'Info' -Target "HKLM:\$subKey" `
                        -Value $notFromGpo `
                        -Message "$($notFromGpo.Count) of $($values.Count) $scopeName value(s) have no winning Group Policy entry in RSoP (set locally, by Local Group Policy if its registry entries are not listed in RSoP, by other tooling such as MDM or scripts, or left behind by a removed GPO)." `
                        -Source $urls.GroupPolicyTemplates -RequiresElevation $true -Scope $resultScope
                }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Policy' -Context "Comparing HKLM:\$subKey with RSoP"
                New-FslResult -Category $category -Check 'FSLogix values not delivered by Group Policy' -Status 'Error' -Target "HKLM:\$subKey" `
                    -Message "Comparison failed: $($_.Exception.Message)" -Source $urls.ConfigurationSettings -RequiresElevation $true -Scope $resultScope
            }
        }
    }

    # ---------------- User scope (gpresult) ----------------
    if ($IncludeUserScope) {
        $reportPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('FslGpresult_{0}.xml' -f [guid]::NewGuid().ToString('N'))
        try {
            $gpresult = Get-Command -Name 'gpresult.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $output = & $gpresult.Source '/scope' 'user' '/x' $reportPath '/f' 2>&1
            $exitCode = $LASTEXITCODE
            Write-FslLog -Message ("gpresult /scope user exit code {0}: {1}" -f $exitCode, (($output | ForEach-Object -Process { [string]$_ }) -join ' ')) -Level Debug -Component 'Policy'

            if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $reportPath)) {
                New-FslResult -Category $category -Check 'Group Policy RSoP (user)' -Status 'Error' -Target $env:USERNAME `
                    -Value $exitCode -Message 'gpresult did not produce a user-scope RSoP report.' `
                    -Recommendation 'Run gpresult /scope user /r manually to review the error.' `
                    -Source $urls.GpResult -RequiresElevation $false -Scope 'General'
            }
            else {
                $xmlText = Get-Content -LiteralPath $reportPath -Raw
                [void][xml]$xmlText   # confirms the report is well-formed XML
                $mentions = [regex]::Matches($xmlText, 'FSLogix', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
                $message = if ($mentions -gt 0) {
                    "User-scope RSoP report mentions FSLogix $mentions time(s). FSLogix administrative template settings are Computer Configuration settings; review user-scope GPOs referencing FSLogix."
                }
                else {
                    'User-scope RSoP report does not mention FSLogix. FSLogix administrative template settings are Computer Configuration settings.'
                }
                New-FslResult -Category $category -Check 'Group Policy RSoP (user)' -Status 'Info' -Target $env:USERNAME `
                    -Value $mentions -Message $message -Source $urls.GpResult -RequiresElevation $false -Scope 'General'
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Policy' -Context 'Generating user-scope RSoP report with gpresult'
            New-FslResult -Category $category -Check 'Group Policy RSoP (user)' -Status 'Error' -Target $env:USERNAME `
                -Message "User-scope RSoP report failed: $($_.Exception.Message)" -Source $urls.GpResult -RequiresElevation $false -Scope 'General'
        }
        finally {
            if (Test-Path -LiteralPath $reportPath) {
                Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
