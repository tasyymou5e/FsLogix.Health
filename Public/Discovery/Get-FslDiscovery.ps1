function Get-FslDiscovery {
    <#
    .SYNOPSIS
        Discovers FSLogix on the image the toolkit runs on: operating system, FSLogix installation, Microsoft 365 Apps,
        registry settings, Group Policy, storage locations and the container mode in use.
    .DESCRIPTION
        Returns one FSLogixToolkit.Discovery object:
          ComputerName, DiscoveredAt (ISO 8601), IsElevated,
          Image            - Win32_OperatingSystem (Caption, BuildNumber, InstallDate, LastBootUpTime, ProductType,
                             OperatingSystemSKU), CurrentVersion UBR, Windows version name (Config/KnownVersions.psd1),
                             Win32_ComputerSystem (Manufacturer, Model, PartOfDomain, Domain, Workgroup),
                             JoinState parsed from 'dsregcmd /status' (AzureAdJoined, EnterpriseJoined, DomainJoined,
                             DomainName, TenantName, TenantId, JoinType), IsMultiSession (OperatingSystemSKU 175),
                             IsAzureVm + Azure (location, vmSize, imageReference) from the Azure Instance Metadata Service,
                             AvdAgent (RDAgentBootLoader service, RDInfraAgent IsRegistered). Unknown values are $null.
          FSLogix          - Find-FslInstallation output.
          Office           - Microsoft 365 Apps Click-to-Run facts (CDNBaseUrl/UpdateChannel, shared computer activation,
                             licensing token location). Version and Platform are $null (no authoritative registry reference).
          Settings         - Get-FslEffectiveSetting (all scopes). Source is GroupPolicy, Registry (only when elevated and
                             computer RSoP confirmed no winning Group Policy entry) or Unknown; SourceDetail explains why.
          StorageLocations - Get-FslStorageLocation.
          GroupPolicy      - Get-FslGpoReport results (computer RSoP is Skipped when not elevated).
          DetectedMode     - ODFC|Profiles|Both|None from the effective 'Enabled' values under Profiles and ODFC
                             ($null when the registry could not be read, for example on non-Windows).
          ConfiguredMode   - Get-FslContainerMode.
          ModeMismatch     - $true when DetectedMode differs from ConfiguredMode ('None' is a mismatch), $null when unknown.
          NonPolicyOdfcValues - (PHASE 3, appended) value names/kinds found under HKLM\SOFTWARE\FSLogix\ODFC (the
                             non-Policies key; FSLogix documents ODFC settings under HKLM\SOFTWARE\Policies\FSLogix\ODFC).
                             Read-only; values are not returned. Empty array when none, $null when not read (non-Windows).
        The IMDS query is skipped with -Offline or when the toolkit Offline preference is set; otherwise it is a
        link-local GET (http://169.254.169.254, header Metadata: true, -NoProxy, 2 s timeouts). On a computer that is
        not an Azure VM, IsAzureVm is $null (unknown), never $false. Works as a standard user. Never throws.
    .PARAMETER Offline
        Do not query the Azure Instance Metadata Service.
    .EXAMPLE
        $discovery = Get-FslDiscovery
        $discovery.DetectedMode, $discovery.ConfiguredMode, $discovery.ModeMismatch

        Shows whether the toolkit container mode matches the FSLogix configuration of this image.
    .EXAMPLE
        (Get-FslDiscovery -Offline).Image | Format-List

        Shows image facts without contacting the Azure Instance Metadata Service.
    .OUTPUTS
        FSLogixToolkit.Discovery
    .NOTES
        RequiresElevation: No (Group Policy RSoP details require elevation and are Skipped otherwise).
        Sources:
        https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem
        https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem
        https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-device-dsregcmd
        https://learn.microsoft.com/en-us/azure/virtual-desktop/windows-multisession-faq
        https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getproductinfo
        https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service
        https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-desktop/troubleshoot-agent
        https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/update-office
        https://learn.microsoft.com/en-us/microsoft-365-apps/licensing-activation/overview-shared-computer-activation
        https://learn.microsoft.com/en-us/microsoft-365-apps/licensing-activation/troubleshoot-shared-computer-activation
        https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
        https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components
        https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers
    #>
    [CmdletBinding()]
    [OutputType('FSLogixToolkit.Discovery')]
    param(
        [Parameter()]
        [switch] $Offline
    )

    $component = 'Discovery'
    $offlineMode = [bool]$Offline
    if (-not $offlineMode) {
        try { $offlineMode = [bool](Get-FslPreference -Name 'Offline') }
        catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Read Offline preference' }
    }
    Write-FslLog -Message "Get-FslDiscovery started (Offline=$offlineMode)." -Level Verbose -Component $component

    $isElevated = $false
    try { $isElevated = [bool](Test-FslElevation) }
    catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Test-FslElevation' }

    $image = $null
    try { $image = Get-FslDiscImage -Offline $offlineMode }
    catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Discover image' }

    $fslogix = $null
    try { $fslogix = Find-FslInstallation }
    catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Find-FslInstallation' }

    $office = $null
    try { $office = Get-FslDiscOffice }
    catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Discover Microsoft 365 Apps' }

    $settings = @()
    $settingsRead = $false
    try {
        $settings = @(Get-FslEffectiveSetting)
        $settingsRead = [bool](Test-FslIsWindows)
    }
    catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Get-FslEffectiveSetting' }

    $storageLocations = @()
    try { $storageLocations = @(Get-FslStorageLocation) }
    catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Get-FslStorageLocation' }

    $groupPolicy = @()
    try { $groupPolicy = @(Get-FslGpoReport) }
    catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Get-FslGpoReport' }

    $nonPolicyOdfcValues = $null
    if ($settingsRead) {
        try { $nonPolicyOdfcValues = @(Get-FslDiscNonPolicyOdfcValue) }
        catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Read HKLM\SOFTWARE\FSLogix\ODFC (non-Policies key)' }
    }

    $detectedMode = $null
    if ($settingsRead) {
        try { $detectedMode = Get-FslDiscDetectedMode -Setting $settings }
        catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Determine detected container mode' }
    }

    $configuredMode = 'ODFC'
    try { $configuredMode = [string](Get-FslContainerMode) }
    catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Get-FslContainerMode' }

    $mismatch = $null
    try { $mismatch = Test-FslDiscModeMismatch -DetectedMode $detectedMode -ConfiguredMode $configuredMode }
    catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Compare container modes' }

    Write-FslLog -Message "Get-FslDiscovery finished: DetectedMode=$detectedMode ConfiguredMode=$configuredMode ModeMismatch=$mismatch Settings=$($settings.Count) Locations=$($storageLocations.Count)." -Level Verbose -Component $component

    [pscustomobject][ordered]@{
        PSTypeName       = 'FSLogixToolkit.Discovery'
        ComputerName     = [System.Environment]::MachineName
        DiscoveredAt     = (Get-Date).ToString('o')
        IsElevated       = $isElevated
        Image            = $image
        FSLogix          = $fslogix
        Office           = $office
        Settings         = $settings
        StorageLocations = $storageLocations
        GroupPolicy      = $groupPolicy
        DetectedMode     = $detectedMode
        ConfiguredMode   = $configuredMode
        ModeMismatch     = $mismatch
        NonPolicyOdfcValues = $nonPolicyOdfcValues
    }
}
