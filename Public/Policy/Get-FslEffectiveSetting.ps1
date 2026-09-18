function Get-FslEffectiveSetting {
    <#
    .SYNOPSIS
        Gets the FSLogix configuration values present on this computer and where they came from.
    .DESCRIPTION
        Reads the FSLogix registry keys documented by Microsoft (HKLM 64-bit view):
          Profiles  HKLM:\SOFTWARE\FSLogix\Profiles
          ODFC      HKLM:\SOFTWARE\Policies\FSLogix\ODFC
          Logging   HKLM:\SOFTWARE\FSLogix\Logging
          Apps      HKLM:\SOFTWARE\FSLogix\Apps
        Value kinds are preserved (DWord -> int, QWord -> long, MultiString -> string[], String/ExpandString -> string
        (not expanded), Binary -> byte[]). Secrets (Azure AccountKey, SharedAccessSignature, SAS sig=) are redacted.

        Provenance (three-state, contract PHASE 3 P3.1):
          GroupPolicy - running elevated on Windows, computer RSoP (WMI root\rsop\computer, RSOP_RegistryPolicySetting)
                        was queried successfully and a winning (precedence 1), non-deleted entry matches the value;
                        PolicyName is the GPO display name from RSOP_GPO (or $null when it could not be resolved).
          Registry    - ONLY when running elevated on Windows, the RSoP query succeeded (with at least one RSOP_GPO
                        instance) and no winning entry matches the value.
          Unknown     - not elevated ('Not elevated: Group Policy provenance not checked'), the RSoP query threw
                        ('RSoP query failed: <message>') or RSoP returned no GPO instances ('RSoP unavailable: ...').
                        Unknown must be treated as "may be delivered by Group Policy".
          MDM         - reserved; MDM/Intune provenance is not detected (no verified detection method).
        SourceDetail explains the Source in words. Local Group Policy: the RSoP model documents a Local scope of
        management (RSOP_SOM type 1); a value delivered by Local Group Policy is reported as GroupPolicy when RSoP lists
        a winning entry for it (confirming that Local Group Policy registry values are logged in RSoP is a lab item).
        ObjectSpecific sub keys are not returned here (see Get-FslStorageLocation).
        FSLogix only uses documented defaults for values that are not present; absent values are not emitted.
    .PARAMETER Scope
        One or more of Profiles, ODFC, Logging, Apps. Defaults to all.
    .EXAMPLE
        Get-FslEffectiveSetting -Scope Profiles | Format-Table -Property Name, Value, ValueKind, Source, PolicyName, SourceDetail
    .OUTPUTS
        FSLogixToolkit.Setting
    .NOTES
        RequiresElevation: No for registry values. Yes for Group Policy provenance (RSoP); without elevation all values report Source 'Unknown'.
        Sources:
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
          https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates
          https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-registrypolicysetting
          https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-policysetting
          https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-gpo
          https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-som
          https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/get-ciminstance
    #>
    [CmdletBinding()]
    [OutputType('FSLogixToolkit.Setting')]
    param(
        [Parameter()]
        [ValidateSet('Profiles', 'ODFC', 'Logging', 'Apps')]
        [string[]] $Scope = @('Profiles', 'ODFC', 'Logging', 'Apps')
    )

    $computerName = [System.Environment]::MachineName
    if (-not (Test-FslIsWindows)) {
        Write-FslLog -Message 'Get-FslEffectiveSetting: FSLogix registry settings are only available on Windows; nothing to read.' -Level Verbose -Component 'Policy'
        return
    }

    # Three-state provenance: GroupPolicy / Registry (only when RSoP was confirmed) / Unknown.
    $rsop = Get-FslPolRsopState

    $scopeKeys = Get-FslPolScopeKey
    foreach ($scopeName in ($Scope | Select-Object -Unique)) {
        $subKey = $scopeKeys[$scopeName]
        try {
            foreach ($item in @(Get-FslPolRegistryValue -SubKey $subKey)) {
                $provenance = Get-FslPolProvenance -RsopRow $rsop.Rows -SubKey $subKey -ValueName $item.Name -RsopStatus $rsop.Status -RsopDetail $rsop.Detail
                [pscustomobject]@{
                    PSTypeName   = 'FSLogixToolkit.Setting'
                    Scope        = $scopeName
                    Name         = $item.Name
                    Value        = ConvertTo-FslPolRedactedValue -Value $item.Value
                    ValueKind    = $item.ValueKind
                    RegistryPath = "HKLM:\$subKey"
                    Source       = $provenance.Source
                    PolicyName   = $provenance.PolicyName
                    ComputerName = $computerName
                    SourceDetail = $provenance.SourceDetail
                }
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Policy' -Context "Reading FSLogix $scopeName settings (HKLM:\$subKey)"
        }
    }
}
