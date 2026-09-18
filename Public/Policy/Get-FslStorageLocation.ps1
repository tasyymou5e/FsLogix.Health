function Get-FslStorageLocation {
    <#
    .SYNOPSIS
        Gets the FSLogix container storage locations (VHDLocations / CCDLocations) configured on this computer.
    .DESCRIPTION
        Parses VHDLocations and CCDLocations for Profiles (HKLM:\SOFTWARE\FSLogix\Profiles) and ODFC
        (HKLM:\SOFTWARE\Policies\FSLogix\ODFC), plus object-specific Profiles VHDLocations
        (HKLM:\SOFTWARE\FSLogix\Profiles\ObjectSpecific\<SID>).
        - VHDLocations: MULTI_SZ entries are one location each; REG_SZ values are split on ';' (documented separator).
          UNC paths are ProviderType SMB (HostName = UNC host), drive-letter paths are Local, anything else Unknown.
        - CCDLocations: providers separated by ';' in the documented format
          type=smb|azure,name="...",connectionString=... (case sensitive). type=smb -> SMB with UNC host;
          type=azure -> AzurePageBlob with HostName taken from a plain-text connection string (BlobEndpoint or
          AccountName/EndpointSuffix) and $null for a secure key reference (|fslogix/<key-name>|).
        Secrets (AccountKey, SharedAccessSignature, SAS sig=) are always redacted from Path. Microsoft recommends
        storing Azure page blob connection strings with 'frx add-secure-key' instead of plain text.
        Source contains the provenance and registry path of the value: "GroupPolicy '<GPO>' (<path>)",
        "Registry (<path>)" (only when elevated and computer RSoP confirmed no winning Group Policy entry) or
        "Unknown - <reason> (<path>)" (for example 'Not elevated: Group Policy provenance not checked').
        -Scope limits which container type is read: with -Scope ODFC the Profiles registry key (including
        ObjectSpecific sub keys) is not read at all.
    .PARAMETER Scope
        One or more of Profiles, ODFC. Defaults to both (phase 1 behavior).
    .EXAMPLE
        Get-FslStorageLocation | Where-Object -Property ProviderType -EQ 'SMB'
    .EXAMPLE
        Get-FslStorageLocation -Scope ODFC
        Returns only the Office container (ODFC) VHDLocations/CCDLocations.
    .OUTPUTS
        FSLogixToolkit.StorageLocation
    .NOTES
        RequiresElevation: No (Group Policy provenance in Source requires elevation; otherwise 'Unknown').
        Sources:
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
          https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples
          https://learn.microsoft.com/en-us/fslogix/tutorial-cloud-cache-containers
          https://learn.microsoft.com/en-us/fslogix/how-to-protect-connection-string
          https://learn.microsoft.com/en-us/azure/storage/common/storage-configure-connection-string
    #>
    [CmdletBinding()]
    [OutputType('FSLogixToolkit.StorageLocation')]
    param(
        [Parameter()]
        [ValidateSet('Profiles', 'ODFC')]
        [string[]] $Scope = @('Profiles', 'ODFC')
    )

    $selectedScopes = @($Scope | Select-Object -Unique)

    if (-not (Test-FslIsWindows)) {
        Write-FslLog -Message 'Get-FslStorageLocation: FSLogix registry settings are only available on Windows; nothing to read.' -Level Verbose -Component 'Policy'
        return
    }

    try {
        $settings = @(Get-FslEffectiveSetting -Scope $selectedScopes | Where-Object -FilterScript { $_.Name -in @('VHDLocations', 'CCDLocations') -and $_.Scope -in $selectedScopes })
        foreach ($setting in $settings) {
            $sourceDetail = if ($setting.PSObject.Properties['SourceDetail']) { [string]$setting.SourceDetail } else { $null }
            $sourceLabel = Format-FslPolSourceText -Source ([string]$setting.Source) -PolicyName ([string]$setting.PolicyName) -SourceDetail $sourceDetail
            $source = "$sourceLabel ($($setting.RegistryPath)\$($setting.Name))"
            # Match the documented (case-sensitive) value name casing to the location type.
            $locationType = if ($setting.Name -eq 'CCDLocations') { 'CCDLocations' } else { 'VHDLocations' }
            ConvertFrom-FslPolLocationValue -Scope $setting.Scope -LocationType $locationType -Value $setting.Value -Source $source
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Policy' -Context "Parsing $($selectedScopes -join '/') VHDLocations and CCDLocations"
    }

    # Object-specific VHDLocations exist for Profiles only; never read the Profiles key when Profiles is not selected.
    if ($selectedScopes -notcontains 'Profiles') { return }

    # Object-specific VHDLocations (Profiles only, as documented).
    $scopeKeys = Get-FslPolScopeKey
    $objectSpecificKey = "$($scopeKeys['Profiles'])\ObjectSpecific"
    try {
        $sids = @(Get-FslPolRegistrySubKeyName -SubKey $objectSpecificKey)
        $rsop = $null
        if ($sids.Count -gt 0) { $rsop = Get-FslPolRsopState }
        foreach ($sid in $sids) {
            $subKey = "$objectSpecificKey\$sid"
            $values = @(Get-FslPolRegistryValue -SubKey $subKey | Where-Object -FilterScript { $_.Name -eq 'VHDLocations' })
            foreach ($item in $values) {
                $provenance = Get-FslPolProvenance -RsopRow $rsop.Rows -SubKey $subKey -ValueName $item.Name -RsopStatus $rsop.Status -RsopDetail $rsop.Detail
                $sourceLabel = Format-FslPolSourceText -Source ([string]$provenance.Source) -PolicyName ([string]$provenance.PolicyName) -SourceDetail ([string]$provenance.SourceDetail)
                $source = "$sourceLabel (HKLM:\$subKey\VHDLocations)"
                ConvertFrom-FslPolLocationValue -Scope 'Profiles' -LocationType 'VHDLocations' -Value (ConvertTo-FslPolRedactedValue -Value $item.Value) -Source $source
            }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Policy' -Context "Reading ObjectSpecific VHDLocations (HKLM:\$objectSpecificKey)"
    }
}
