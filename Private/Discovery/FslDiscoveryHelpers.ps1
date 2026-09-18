# Private helpers for the Discovery area (prefix *-FslDisc*).

function Get-FslDiscSourceUrl {
    <#
    .SYNOPSIS
        Returns the verified source URLs used by Discovery.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        OperatingSystem       = 'https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem'
        ComputerSystem        = 'https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem'
        WindowsRelease        = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information'
        MultiSession          = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/windows-multisession-faq'
        ProductInfo           = 'https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getproductinfo'
        Dsregcmd              = 'https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-device-dsregcmd'
        Imds                  = 'https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service'
        AvdAgent              = 'https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-desktop/troubleshoot-agent'
        SharedComputer        = 'https://learn.microsoft.com/en-us/microsoft-365-apps/licensing-activation/overview-shared-computer-activation'
        SharedComputerVerify  = 'https://learn.microsoft.com/en-us/microsoft-365-apps/licensing-activation/troubleshoot-shared-computer-activation'
        OfficeUpdateRegistry  = 'https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/update-office'
        FSLogixComponents     = 'https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components'
        FSLogixSettings       = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings'
        FSLogixGroupPolicy    = 'https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates'
        FSLogixConfigExamples = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples'
        FSLogixOdfcHowTo      = 'https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers'
        RsopRegistrySetting   = 'https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-registrypolicysetting'
        InvokeRestMethod      = 'https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/invoke-restmethod'
    }
}

function ConvertTo-FslDiscIsoDate {
    <#
    .SYNOPSIS
        Converts a [datetime] to an ISO 8601 round-trip string; anything else returns $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object] $InputObject
    )

    if ($InputObject -is [datetime]) { return $InputObject.ToString('o') }
    return $null
}

function ConvertTo-FslDiscResultScope {
    <#
    .SYNOPSIS
        Maps a setting/location scope to a Result scope (contract P2.2): Profiles->Profiles, ODFC->ODFC, else General.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Scope
    )

    if ([string]::Equals($Scope, 'Profiles', [System.StringComparison]::OrdinalIgnoreCase)) { return 'Profiles' }
    if ([string]::Equals($Scope, 'ODFC', [System.StringComparison]::OrdinalIgnoreCase)) { return 'ODFC' }
    return 'General'
}

function ConvertFrom-FslDiscDsregcmdOutput {
    <#
    .SYNOPSIS
        Parses the documented Device State / Tenant Details fields from 'dsregcmd /status' text.
    .DESCRIPTION
        Only fields documented on the Microsoft Entra dsregcmd troubleshooting page are parsed:
        AzureAdJoined, EnterpriseJoined, DomainJoined, DomainName, TenantName, TenantId ('Name : Value' lines).
        JoinType follows the documented device state table:
          AzureAdJoined YES, EnterpriseJoined NO, DomainJoined NO  -> MicrosoftEntraJoined
          AzureAdJoined NO,  EnterpriseJoined NO, DomainJoined YES -> DomainJoined
          AzureAdJoined YES, EnterpriseJoined NO, DomainJoined YES -> MicrosoftEntraHybridJoined
          AzureAdJoined NO,  EnterpriseJoined YES, DomainJoined YES -> OnPremisesDrsJoined
          any other combination (including all NO, which is not in the documented table) -> $null (unknown).
        The Workplace Joined (Microsoft Entra registered) state is reported in the separate User State section and is not read.
        Returns $null when none of the three join fields is present.
    .NOTES
        Source: https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-device-dsregcmd
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $fieldNames = @('AzureAdJoined', 'EnterpriseJoined', 'DomainJoined', 'DomainName', 'TenantName', 'TenantId')
    $values = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        $match = [regex]::Match($line, '^\s*([A-Za-z]+)\s*:\s*(.*?)\s*$')
        if (-not $match.Success) { continue }
        $key = $match.Groups[1].Value
        $fieldName = $fieldNames | Where-Object -FilterScript { [string]::Equals($_, $key, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($null -eq $fieldName -or $values.ContainsKey($fieldName)) { continue }
        $values[$fieldName] = $match.Groups[2].Value
    }

    $toBool = {
        param($FieldName)
        if (-not $values.ContainsKey($FieldName)) { return $null }
        switch -Regex ($values[$FieldName]) {
            '^(?i)YES$' { return $true }
            '^(?i)NO$' { return $false }
            default { return $null }
        }
    }
    $azureAd = & $toBool 'AzureAdJoined'
    $enterprise = & $toBool 'EnterpriseJoined'
    $domain = & $toBool 'DomainJoined'
    if ($null -eq $azureAd -and $null -eq $enterprise -and $null -eq $domain) { return $null }

    $joinType = $null
    if ($azureAd -eq $true -and $enterprise -eq $false -and $domain -eq $false) { $joinType = 'MicrosoftEntraJoined' }
    elseif ($azureAd -eq $false -and $enterprise -eq $false -and $domain -eq $true) { $joinType = 'DomainJoined' }
    elseif ($azureAd -eq $true -and $enterprise -eq $false -and $domain -eq $true) { $joinType = 'MicrosoftEntraHybridJoined' }
    elseif ($azureAd -eq $false -and $enterprise -eq $true -and $domain -eq $true) { $joinType = 'OnPremisesDrsJoined' }

    $getText = {
        param($FieldName)
        if ($values.ContainsKey($FieldName) -and -not [string]::IsNullOrWhiteSpace($values[$FieldName])) { return [string]$values[$FieldName] }
        return $null
    }

    [pscustomobject][ordered]@{
        AzureAdJoined    = $azureAd
        EnterpriseJoined = $enterprise
        DomainJoined     = $domain
        DomainName       = & $getText 'DomainName'
        TenantName       = & $getText 'TenantName'
        TenantId         = & $getText 'TenantId'
        JoinType         = $joinType
        Method           = 'dsregcmd /status'
    }
}

function Invoke-FslDiscDsregcmd {
    <#
    .SYNOPSIS
        Runs 'dsregcmd /status' with a timeout and returns its standard output, or $null.
    .DESCRIPTION
        dsregcmd is resolved with Get-Command (no path assumption). The process is killed when it does not exit within
        TimeoutSeconds (toolkit default 15). Windows only. Never throws.
    .NOTES
        Source: https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-device-dsregcmd
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [ValidateRange(1, 120)]
        [int] $TimeoutSeconds = 15
    )

    if (-not (Test-FslIsWindows)) { return $null }
    $process = $null
    try {
        $command = Get-Command -Name 'dsregcmd.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            Write-FslLog -Message 'dsregcmd.exe was not found; join state not determined.' -Level Verbose -Component 'Discovery'
            return $null
        }
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $command.Source
        $startInfo.ArgumentList.Add('/status')
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $null = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { Add-FslError -ErrorRecord $_ -Component 'Discovery' -Context 'Stop dsregcmd after timeout' }
            Write-FslLog -Message "dsregcmd /status did not finish within $TimeoutSeconds s; join state not determined." -Level Warning -Component 'Discovery'
            return $null
        }
        return [string]$outputTask.GetAwaiter().GetResult()
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Discovery' -Context 'Run dsregcmd /status'
        return $null
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Get-FslDiscImdsCompute {
    <#
    .SYNOPSIS
        Reads the compute metadata from the Azure Instance Metadata Service; returns $null when unavailable.
    .DESCRIPTION
        GET http://169.254.169.254/metadata/instance/compute?api-version=2023-07-01&format=json with header
        'Metadata: true', proxies bypassed (-NoProxy) and short connection/read timeouts (toolkit default 2 s).
        A failure is expected on computers that are not Azure VMs and is logged at Verbose level only.
    .NOTES
        Sources:
        https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service (endpoint, Metadata header, proxy bypass, api-version list)
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/invoke-restmethod (NoProxy, ConnectionTimeoutSeconds, OperationTimeoutSeconds)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateRange(1, 2)]
        [int] $TimeoutSeconds = 2
    )

    try {
        $parameters = @{
            Uri                      = 'http://169.254.169.254/metadata/instance/compute?api-version=2023-07-01&format=json'
            Method                   = 'Get'
            Headers                  = @{ Metadata = 'true' }
            NoProxy                  = $true
            ConnectionTimeoutSeconds = $TimeoutSeconds
            OperationTimeoutSeconds  = $TimeoutSeconds
            ErrorAction              = 'Stop'
        }
        $response = Invoke-RestMethod @parameters
        if ($null -eq $response -or $response -is [string]) { return $null }
        return $response
    }
    catch {
        Write-FslLog -Message "Azure Instance Metadata Service not reachable (not an Azure VM or IMDS blocked): $($_.Exception.Message)" -Level Verbose -Component 'Discovery'
        return $null
    }
}

function ConvertFrom-FslDiscImdsCompute {
    <#
    .SYNOPSIS
        Extracts the documented, non-sensitive compute fields from an IMDS compute response.
    .DESCRIPTION
        Fields: azEnvironment, location, vmSize, osType, storageProfile.imageReference (publisher, offer, sku, version,
        id, communityGalleryImageId, sharedGalleryImageId, exactVersion). IMDS returns missing values as empty strings;
        they are converted to $null. Tags and userData are never read. ImageSource: PlatformOrMarketplace when publisher/offer/sku
        are set (IMDS documents these as 'of the platform or marketplace image', so the two cannot be told apart),
        CommunityGallery / SharedGallery when those ids are set, ResourceId when only id is set (type not implied), else $null.
    .NOTES
        Source: https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service (compute and storage profile schema)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) { return $null }
    $read = {
        param($Object, [string[]] $PropertyPath)
        $current = $Object
        foreach ($segment in $PropertyPath) {
            if ($null -eq $current) { return $null }
            $property = $current.PSObject.Properties[$segment]
            if ($null -eq $property) { return $null }
            $current = $property.Value
        }
        if ($null -eq $current) { return $null }
        $text = [string]$current
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text
    }

    $image = [pscustomobject][ordered]@{
        Publisher               = & $read $InputObject @('storageProfile', 'imageReference', 'publisher')
        Offer                   = & $read $InputObject @('storageProfile', 'imageReference', 'offer')
        Sku                     = & $read $InputObject @('storageProfile', 'imageReference', 'sku')
        Version                 = & $read $InputObject @('storageProfile', 'imageReference', 'version')
        ExactVersion            = & $read $InputObject @('storageProfile', 'imageReference', 'exactVersion')
        Id                      = & $read $InputObject @('storageProfile', 'imageReference', 'id')
        CommunityGalleryImageId = & $read $InputObject @('storageProfile', 'imageReference', 'communityGalleryImageId')
        SharedGalleryImageId    = & $read $InputObject @('storageProfile', 'imageReference', 'sharedGalleryImageId')
        ImageSource             = $null
    }
    if ($image.Publisher -and $image.Offer -and $image.Sku) { $image.ImageSource = 'PlatformOrMarketplace' }
    elseif ($image.CommunityGalleryImageId) { $image.ImageSource = 'CommunityGallery' }
    elseif ($image.SharedGalleryImageId) { $image.ImageSource = 'SharedGallery' }
    elseif ($image.Id) { $image.ImageSource = 'ResourceId' }

    [pscustomobject][ordered]@{
        AzEnvironment  = & $read $InputObject @('azEnvironment')
        Location       = & $read $InputObject @('location')
        VmSize         = & $read $InputObject @('vmSize')
        OsType         = & $read $InputObject @('osType')
        ImageReference = $image
    }
}

function Get-FslDiscAzureInfo {
    <#
    .SYNOPSIS
        Returns IsAzureVm / Azure metadata. Skipped (IsAzureVm $null, Queried $false) when offline.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [bool] $Offline = $false
    )

    if ($Offline) {
        return [pscustomobject][ordered]@{ Queried = $false; IsAzureVm = $null; Metadata = $null }
    }
    $compute = Get-FslDiscImdsCompute
    if ($null -eq $compute) {
        return [pscustomobject][ordered]@{ Queried = $true; IsAzureVm = $null; Metadata = $null }
    }
    [pscustomobject][ordered]@{ Queried = $true; IsAzureVm = $true; Metadata = (ConvertFrom-FslDiscImdsCompute -InputObject $compute) }
}

function Get-FslDiscAvdAgent {
    <#
    .SYNOPSIS
        Detects the Azure Virtual Desktop agent boot loader service and the RDInfraAgent registration flag.
    .DESCRIPTION
        RDAgentBootLoader service (Get-Service) and HKLM:\SOFTWARE\Microsoft\RDInfraAgent IsRegistered (1 = registered).
        The RegistrationToken value is never read. Returns $null on non-Windows.
    .NOTES
        Source: https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-desktop/troubleshoot-agent
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if (-not (Test-FslIsWindows)) { return $null }
    $service = $null
    try {
        $service = Get-Service -Name 'RDAgentBootLoader' -ErrorAction SilentlyContinue
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Discovery' -Context 'Get-Service RDAgentBootLoader'
    }
    $isRegisteredRaw = Get-FslEnvRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -Name 'IsRegistered'
    $isRegistered = $null
    if ($null -ne $isRegisteredRaw) {
        if ([string]$isRegisteredRaw -eq '1') { $isRegistered = $true }
        elseif ([string]$isRegisteredRaw -eq '0') { $isRegistered = $false }
    }
    [pscustomobject][ordered]@{
        BootLoaderInstalled = ($null -ne $service)
        BootLoaderStatus    = if ($null -ne $service) { [string]$service.Status } else { $null }
        IsRegistered        = $isRegistered
    }
}

function Get-FslDiscComputerSystem {
    <#
    .SYNOPSIS
        Reads Manufacturer, Model, PartOfDomain, Domain and Workgroup from Win32_ComputerSystem; $null on failure.
    .NOTES
        Source: https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if (-not (Test-FslIsWindows)) { return $null }
    try {
        $system = Get-CimInstance -ClassName 'Win32_ComputerSystem' -Property 'Manufacturer', 'Model', 'PartOfDomain', 'Domain', 'Workgroup' -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $system) { return $null }
        $partOfDomain = if ($null -ne $system.PartOfDomain) { [bool]$system.PartOfDomain } else { $null }
        [pscustomobject][ordered]@{
            Manufacturer = [string]$system.Manufacturer
            Model        = [string]$system.Model
            PartOfDomain = $partOfDomain
            Domain       = if ($partOfDomain -eq $true) { [string]$system.Domain } else { $null }
            Workgroup    = if ($partOfDomain -eq $false -and -not [string]::IsNullOrWhiteSpace([string]$system.Workgroup)) { [string]$system.Workgroup } else { $null }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Discovery' -Context 'Query Win32_ComputerSystem'
        return $null
    }
}

function Get-FslDiscImage {
    <#
    .SYNOPSIS
        Builds the Discovery Image section (operating system, hardware, join state, multi-session, Azure, AVD agent).
    .DESCRIPTION
        Unknown values are $null. IsMultiSession is $true when Win32_OperatingSystem.OperatingSystemSKU is 175
        (PRODUCT_ENTERPRISE_FOR_VIRTUAL_DESKTOPS), $false for any other SKU, $null when the SKU was not read.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [bool] $Offline = $false
    )

    $onWindows = [bool](Test-FslIsWindows)
    $windows = $null
    $versionName = $null
    $isMultiSession = $null
    $system = $null
    $joinState = $null
    $avd = $null
    if ($onWindows) {
        try {
            $windows = Get-FslEnvWindowsInfo
            if ($null -ne $windows.BuildNumber) {
                $versionName = Get-FslEnvWindowsVersionName -KnownVersions (Get-FslEnvKnownVersion) -BuildNumber $windows.BuildNumber -ProductType $windows.ProductType -OperatingSystemSKU $windows.OperatingSystemSKU
            }
            if ($null -ne $windows.OperatingSystemSKU) { $isMultiSession = ([int]$windows.OperatingSystemSKU -eq 175) }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Discovery' -Context 'Collect Windows version information'
        }
        $system = Get-FslDiscComputerSystem
        $joinState = ConvertFrom-FslDiscDsregcmdOutput -Text (Invoke-FslDiscDsregcmd)
        $avd = Get-FslDiscAvdAgent
    }
    $azure = Get-FslDiscAzureInfo -Offline $Offline

    $fullBuild = $null
    if ($null -ne $windows -and $null -ne $windows.BuildNumber) {
        $fullBuild = if ($null -ne $windows.UBR) { '{0}.{1}' -f $windows.BuildNumber, $windows.UBR } else { [string]$windows.BuildNumber }
    }

    [pscustomobject][ordered]@{
        IsWindows          = $onWindows
        OSCaption          = if ($null -ne $windows -and $windows.Caption) { [string]$windows.Caption } elseif (-not $onWindows) { [System.Runtime.InteropServices.RuntimeInformation]::OSDescription } else { $null }
        BuildNumber        = if ($null -ne $windows) { $windows.BuildNumber } else { $null }
        UBR                = if ($null -ne $windows) { $windows.UBR } else { $null }
        FullBuild          = $fullBuild
        WindowsVersionName = $versionName
        DisplayVersion     = if ($null -ne $windows) { $windows.DisplayVersion } else { $null }
        ProductType        = if ($null -ne $windows) { $windows.ProductType } else { $null }
        OperatingSystemSKU = if ($null -ne $windows) { $windows.OperatingSystemSKU } else { $null }
        IsMultiSession     = $isMultiSession
        InstallDate        = if ($null -ne $windows) { ConvertTo-FslDiscIsoDate -InputObject $windows.InstallDate } else { $null }
        LastBootUpTime     = if ($null -ne $windows) { ConvertTo-FslDiscIsoDate -InputObject $windows.LastBootUpTime } else { $null }
        Manufacturer       = if ($null -ne $system) { $system.Manufacturer } else { $null }
        Model              = if ($null -ne $system) { $system.Model } else { $null }
        PartOfDomain       = if ($null -ne $system) { $system.PartOfDomain } else { $null }
        Domain             = if ($null -ne $system) { $system.Domain } else { $null }
        Workgroup          = if ($null -ne $system) { $system.Workgroup } else { $null }
        JoinState          = $joinState
        AzureQueried       = $azure.Queried
        IsAzureVm          = $azure.IsAzureVm
        Azure              = $azure.Metadata
        AvdAgent           = $avd
    }
}

function Get-FslDiscOfficeChannelName {
    <#
    .SYNOPSIS
        Maps a Microsoft 365 Apps UpdateChannel / CDNBaseUrl value to the documented channel name, or $null.
    .NOTES
        Source: https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/update-office
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    $channels = [ordered]@{
        '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'
        '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Channel (preview)'
        '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise Channel'
        '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise Channel'
        'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semi-Annual Enterprise Channel (Preview)'
        '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta'
    }
    foreach ($guid in $channels.Keys) {
        if ($Url.IndexOf($guid, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return [string]$channels[$guid] }
    }
    return $null
}

function Get-FslDiscOffice {
    <#
    .SYNOPSIS
        Reads Microsoft 365 Apps (Click-to-Run) facts relevant to Office containers from documented registry values.
    .DESCRIPTION
        HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration:
          CDNBaseUrl (set when Microsoft 365 Apps installs), UpdateChannel,
          SharedComputerLicensing ('1' = shared computer activation enabled, '0' = turned off),
          SCLCacheOverride ('1') and SCLCacheOverrideDirectory (licensing token location).
        Installed is $true when CDNBaseUrl is present, otherwise $null (not detected; no documented negative test).
        The installed Microsoft 365 Apps version and platform are not reported (no authoritative registry reference found).
    .NOTES
        Sources:
        https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/update-office
        https://learn.microsoft.com/en-us/microsoft-365-apps/licensing-activation/overview-shared-computer-activation
        https://learn.microsoft.com/en-us/microsoft-365-apps/licensing-activation/troubleshoot-shared-computer-activation
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $path = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $result = [ordered]@{
        RegistryPath                 = $path
        Installed                    = $null
        CDNBaseUrl                   = $null
        UpdateChannel                = $null
        UpdateChannelName            = $null
        SharedComputerLicensing      = $null
        SharedComputerActivation     = $null
        SCLCacheOverride             = $null
        SCLCacheOverrideDirectory    = $null
        Version                      = $null
        Platform                     = $null
    }
    if (-not (Test-FslIsWindows)) { return [pscustomobject]$result }

    $cdn = Get-FslEnvRegistryValue -Path $path -Name 'CDNBaseUrl'
    if (-not [string]::IsNullOrWhiteSpace([string]$cdn)) {
        $result.Installed = $true
        $result.CDNBaseUrl = [string]$cdn
    }
    $channel = Get-FslEnvRegistryValue -Path $path -Name 'UpdateChannel'
    if (-not [string]::IsNullOrWhiteSpace([string]$channel)) { $result.UpdateChannel = [string]$channel }
    $channelSource = if ($result.UpdateChannel) { $result.UpdateChannel } else { $result.CDNBaseUrl }
    $result.UpdateChannelName = Get-FslDiscOfficeChannelName -Url $channelSource

    $scl = Get-FslEnvRegistryValue -Path $path -Name 'SharedComputerLicensing'
    if ($null -ne $scl) {
        $result.SharedComputerLicensing = [string]$scl
        # Only value 1 is documented (enabled). Any other value is not documented, so activation stays $null (unknown).
        if ([string]$scl -eq '1') { $result.SharedComputerActivation = $true }
    }
    $cacheOverride = Get-FslEnvRegistryValue -Path $path -Name 'SCLCacheOverride'
    if ($null -ne $cacheOverride) { $result.SCLCacheOverride = [string]$cacheOverride }
    $cacheDirectory = Get-FslEnvRegistryValue -Path $path -Name 'SCLCacheOverrideDirectory'
    if (-not [string]::IsNullOrWhiteSpace([string]$cacheDirectory)) { $result.SCLCacheOverrideDirectory = [string]$cacheDirectory }

    [pscustomobject]$result
}

function Get-FslDiscDetectedMode {
    <#
    .SYNOPSIS
        Derives ODFC|Profiles|Both|None from effective 'Enabled' values (DWORD 1 = enabled) under Profiles and ODFC.
    .NOTES
        Source: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings (Enabled: 0 disabled (default), 1 enabled)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $Setting
    )

    $profiles = $false
    $odfc = $false
    foreach ($item in @($Setting)) {
        if ($null -eq $item) { continue }
        if (-not [string]::Equals([string]$item.Name, 'Enabled', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ([string]$item.Value -ne '1') { continue }
        if ([string]$item.Scope -eq 'Profiles') { $profiles = $true }
        elseif ([string]$item.Scope -eq 'ODFC') { $odfc = $true }
    }
    if ($profiles -and $odfc) { return 'Both' }
    if ($odfc) { return 'ODFC' }
    if ($profiles) { return 'Profiles' }
    return 'None'
}

function Test-FslDiscModeMismatch {
    <#
    .SYNOPSIS
        Returns $true when the detected mode differs from the configured toolkit mode, $null when detection is unknown.
    .DESCRIPTION
        Contract P2.4: mismatch = detected <> configured; 'None' counts as a mismatch only when the configured mode
        includes a container scope (ODFC, Profiles and Both all do).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $DetectedMode,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ConfiguredMode
    )

    if ([string]::IsNullOrWhiteSpace($DetectedMode) -or [string]::IsNullOrWhiteSpace($ConfiguredMode)) { return $null }
    if ($DetectedMode -eq 'None') { return ($ConfiguredMode -in @('ODFC', 'Profiles', 'Both')) }
    return ($DetectedMode -ne $ConfiguredMode)
}

function Get-FslDiscModeRecommendation {
    <#
    .SYNOPSIS
        Returns message and recommendation text for a detected/configured container mode combination.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DetectedMode,

        [Parameter(Mandatory = $true)]
        [string] $ConfiguredMode
    )

    $modeText = @{
        ODFC     = 'Office containers only'
        Profiles = 'Profile containers only'
        Both     = 'Office and profile containers'
        None     = 'no container type'
    }
    $message = "FSLogix registry has $($modeText[$DetectedMode]) enabled (Enabled = 1); the toolkit container mode is $ConfiguredMode ($($modeText[$ConfiguredMode]))."
    $recommendation = $null
    $detectedProfiles = $DetectedMode -in @('Profiles', 'Both')
    $detectedOdfc = $DetectedMode -in @('ODFC', 'Both')
    $configuredProfiles = $ConfiguredMode -in @('Profiles', 'Both')
    $configuredOdfc = $ConfiguredMode -in @('ODFC', 'Both')

    if ($DetectedMode -eq 'None') {
        $message = "Neither profile containers nor Office containers are enabled in the FSLogix registry (Profiles and ODFC 'Enabled' are not 1); the toolkit container mode is $ConfiguredMode."
        $recommendation = 'If this image should use FSLogix Office containers, set Enabled = 1 under HKLM\SOFTWARE\Policies\FSLogix\ODFC (for example with the FSLogix Group Policy template); otherwise container checks will report no data.'
    }
    elseif ($detectedProfiles -and -not $configuredProfiles) {
        $message = "Profile containers are enabled on this image but the toolkit is in Office-containers-only mode ($ConfiguredMode)."
        $recommendation = 'To check profile containers as well, use Options > Container Mode > Both (or Set-FslPreference -Name ContainerMode -Value Both). If profile containers should not be used on this image, set Profiles Enabled = 0.'
    }
    elseif ($detectedOdfc -and -not $configuredOdfc) {
        $message = "Office containers (ODFC) are enabled on this image but the toolkit is in profile-containers-only mode ($ConfiguredMode)."
        $recommendation = 'To check Office containers, use Options > Container Mode > Office Containers only or Both (or Set-FslPreference -Name ContainerMode -Value ODFC).'
    }
    elseif ($configuredProfiles -and -not $detectedProfiles) {
        $recommendation = 'Profile containers are not enabled on this image; use Options > Container Mode > Office Containers only (Set-FslPreference -Name ContainerMode -Value ODFC) to skip profile container checks.'
    }
    elseif ($configuredOdfc -and -not $detectedOdfc) {
        $recommendation = 'Office containers are not enabled on this image; use Options > Container Mode > Profile Containers only (Set-FslPreference -Name ContainerMode -Value Profiles) to skip Office container checks.'
    }
    @{ Message = $message; Recommendation = $recommendation }
}

function Get-FslDiscNonPolicyOdfcValue {
    <#
    .SYNOPSIS
        Lists the value names (and kinds) present under HKLM\SOFTWARE\FSLogix\ODFC (the non-Policies key). Read-only.
    .DESCRIPTION
        FSLogix documents the ODFC container settings under HKLM\SOFTWARE\Policies\FSLogix\ODFC
        (reference-configuration-settings); the PowerShell sample in 'Configure ODFC containers' writes to
        HKLM:\SOFTWARE\FSLogix\ODFC instead, so values can exist under the non-Policies key. The key is opened
        read-only (Get-FslPolRegistryValue: RegistryKey.OpenSubKey(name, $false), 64-bit view). Only names and value
        kinds are returned - values are never returned, so nothing secret can be echoed. Returns nothing on non-Windows
        or when the key does not exist or has no values.
    .NOTES
        Sources:
        https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
        https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if (-not (Test-FslIsWindows)) { return }
    $subKey = 'SOFTWARE\FSLogix\ODFC'
    foreach ($item in @(Get-FslPolRegistryValue -SubKey $subKey)) {
        if ($null -eq $item) { continue }
        [pscustomobject]@{
            RegistryPath = "HKLM:\$subKey"
            Name         = [string]$item.Name
            ValueKind    = [string]$item.ValueKind
        }
    }
}
