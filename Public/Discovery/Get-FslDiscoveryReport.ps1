function Get-FslDiscoveryReport {
    <#
    .SYNOPSIS
        Converts FSLogix discovery (image, FSLogix, Microsoft 365 Apps, registry, Group Policy, storage locations,
        container mode) into Result objects.
    .DESCRIPTION
        Emits FSLogixToolkit.Result objects with Category 'Discovery'; Target is the section name:
          Image           - operating system, version name, install date, last boot, manufacturer/model, domain or
                            workgroup, join state (dsregcmd), multi-session, Azure VM / image reference, AVD agent.
          FSLogix         - installation, version, services and minifilter drivers (facts; health verdicts are in
                            Get-FslEnvironment).
          Office          - Microsoft 365 Apps Click-to-Run detection, update channel, shared computer activation
                            (Pass when SharedComputerLicensing = 1; any other value is reported as Info, not interpreted),
                            licensing token location.
          Registry        - one Result per FSLogix setting: Check '<Scope>\<Name>', Value (redacted), Message with the
                            Source (GroupPolicy / Registry / Unknown), SourceDetail, GPO name and registry path; Scope
                            Profiles/ODFC/General. Registry means elevated computer RSoP found no winning Group Policy
                            entry; Unknown means provenance was not confirmed (for example not elevated), so the value may
                            still be delivered by Group Policy. When any setting is Unknown one summary Info result
                            'FSLogix setting provenance' explains why.
                            'Non-policy ODFC registry values' (Info, Scope ODFC): value names found under
                            HKLM\SOFTWARE\FSLogix\ODFC, which is not the documented ODFC settings key
                            (HKLM\SOFTWARE\Policies\FSLogix\ODFC). Names only; values are not echoed.
          GroupPolicy     - Get-FslGpoReport results re-emitted as Discovery results (Status kept; Skipped when not elevated).
          StorageLocation - one Result per VHDLocations/CCDLocations entry (Scope of the location).
          Mode            - detected mode, configured toolkit mode, and 'Container mode match' (Pass, or Warn with a
                            recommendation when they differ, for example profile containers enabled while the toolkit is in
                            Office-containers-only mode).
        Never throws; failures are recorded with Add-FslError and reported as Error results.
    .PARAMETER Discovery
        A FSLogixToolkit.Discovery object from Get-FslDiscovery. When omitted Get-FslDiscovery is run.
    .PARAMETER Offline
        Passed to Get-FslDiscovery when -Discovery is not supplied (skips the Azure Instance Metadata Service).
    .EXAMPLE
        Get-FslDiscoveryReport | Format-Table -Property Target, Check, Status, Value

        Runs discovery and lists all discovered facts.
    .EXAMPLE
        $discovery = Get-FslDiscovery -Offline
        Get-FslDiscoveryReport -Discovery $discovery | Where-Object -Property Target -EQ 'Registry'

        Lists FSLogix registry settings with their provenance.
    .OUTPUTS
        FSLogixToolkit.Result
    .NOTES
        RequiresElevation: No (Group Policy RSoP results are Skipped when not elevated).
        Sources:
        https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem
        https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem
        https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-device-dsregcmd
        https://learn.microsoft.com/en-us/azure/virtual-desktop/windows-multisession-faq
        https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service
        https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-desktop/troubleshoot-agent
        https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/update-office
        https://learn.microsoft.com/en-us/microsoft-365-apps/licensing-activation/overview-shared-computer-activation
        https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
        https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components
        https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates
        https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers
        https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/rsop-registrypolicysetting
    #>
    [CmdletBinding()]
    [OutputType('FSLogixToolkit.Result')]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [AllowNull()]
        [object] $Discovery,

        [Parameter()]
        [switch] $Offline
    )

    process {
        $category = 'Discovery'
        $component = 'Discovery'
        $urls = Get-FslDiscSourceUrl

        if ($null -eq $Discovery) {
            try { $Discovery = Get-FslDiscovery -Offline:$Offline }
            catch {
                Add-FslError -ErrorRecord $_ -Component $component -Context 'Get-FslDiscovery'
                New-FslResult -Category $category -Check 'Discovery' -Status 'Error' -Target 'Image' -Message $_.Exception.Message -Source 'Toolkit default'
                return
            }
        }
        $requiredProperties = @('Image', 'FSLogix', 'Office', 'Settings', 'StorageLocations', 'GroupPolicy', 'DetectedMode', 'ConfiguredMode', 'ModeMismatch')
        $missing = @($requiredProperties | Where-Object -FilterScript { $null -eq $Discovery.PSObject.Properties[$_] })
        if ($missing.Count -gt 0) {
            New-FslResult -Category $category -Check 'Discovery input' -Status 'Error' -Target 'Image' -Value ($missing -join ', ') `
                -Message 'The -Discovery object is not a FSLogixToolkit.Discovery object (missing properties).' -Source 'Toolkit default'
            return
        }

        $formatValue = {
            param($InputValue)
            if ($null -eq $InputValue) { return 'Unknown' }
            if ($InputValue -is [bool]) { if ($InputValue) { return 'Yes' } else { return 'No' } }
            return [string]$InputValue
        }

        # ---------------- Image ----------------
        try {
            $image = $Discovery.Image
            if ($null -eq $image) {
                New-FslResult -Category $category -Check 'Image discovery' -Status 'Error' -Target 'Image' -Message 'Image information could not be collected.' -Source $urls.OperatingSystem
            }
            elseif (-not $image.IsWindows) {
                New-FslResult -Category $category -Check 'Operating system' -Status 'Skipped' -Target 'Image' -Value $image.OSCaption -Expected 'Windows' `
                    -Message 'Not running on Windows; image, FSLogix and Microsoft 365 Apps discovery is Windows-only.' -Source $urls.OperatingSystem
            }
            else {
                $osValue = (@($image.OSCaption, $(if ($image.FullBuild) { "build $($image.FullBuild)" })) | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ', '
                New-FslResult -Category $category -Check 'Operating system' -Status $(if ($osValue) { 'Info' } else { 'Error' }) -Target 'Image' -Value $osValue `
                    -Message $(if ($image.DisplayVersion) { "DisplayVersion $($image.DisplayVersion) (informational)." } else { 'Win32_OperatingSystem Caption and build (CurrentBuildNumber.UBR).' }) `
                    -Source $urls.OperatingSystem
                New-FslResult -Category $category -Check 'Windows version' -Status 'Info' -Target 'Image' -Value (& $formatValue $image.WindowsVersionName) `
                    -Message 'Version name for the build number from Config/KnownVersions.psd1 (Unknown when the build is not listed).' -Source $urls.WindowsRelease
                New-FslResult -Category $category -Check 'Windows Enterprise multi-session' -Status 'Info' -Target 'Image' -Value (& $formatValue $image.IsMultiSession) `
                    -Message "Win32_OperatingSystem OperatingSystemSKU = $(& $formatValue $image.OperatingSystemSKU) (175 = PRODUCT_ENTERPRISE_FOR_VIRTUAL_DESKTOPS; multi-session reports ProductType 3 like Windows Server)." `
                    -Source $urls.MultiSession
                New-FslResult -Category $category -Check 'OS install date' -Status 'Info' -Target 'Image' -Value (& $formatValue $image.InstallDate) -Source $urls.OperatingSystem
                New-FslResult -Category $category -Check 'Last boot' -Status 'Info' -Target 'Image' -Value (& $formatValue $image.LastBootUpTime) -Source $urls.OperatingSystem
                $hardware = (@($image.Manufacturer, $image.Model) | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' / '
                New-FslResult -Category $category -Check 'Manufacturer / model' -Status 'Info' -Target 'Image' -Value $(if ($hardware) { $hardware } else { 'Unknown' }) -Source $urls.ComputerSystem
                $membership = if ($image.PartOfDomain -eq $true) { "Domain: $($image.Domain)" } elseif ($image.PartOfDomain -eq $false) { "Workgroup: $($image.Workgroup)" } else { 'Unknown' }
                New-FslResult -Category $category -Check 'Domain / workgroup' -Status 'Info' -Target 'Image' -Value $membership -Message 'Win32_ComputerSystem PartOfDomain, Domain and Workgroup.' -Source $urls.ComputerSystem

                $join = $image.JoinState
                if ($null -eq $join) {
                    New-FslResult -Category $category -Check 'Join state' -Status 'Info' -Target 'Image' -Value 'Unknown' `
                        -Message "Microsoft Entra / Active Directory join state could not be read from 'dsregcmd /status'." -Source $urls.Dsregcmd
                }
                else {
                    $joinDetails = "AzureAdJoined=$(& $formatValue $join.AzureAdJoined), EnterpriseJoined=$(& $formatValue $join.EnterpriseJoined), DomainJoined=$(& $formatValue $join.DomainJoined)"
                    if ($join.DomainName) { $joinDetails += ", DomainName=$($join.DomainName)" }
                    if ($join.TenantName) { $joinDetails += ", TenantName=$($join.TenantName)" }
                    New-FslResult -Category $category -Check 'Join state' -Status 'Info' -Target 'Image' -Value (& $formatValue $join.JoinType) `
                        -Message "dsregcmd /status: $joinDetails." -Source $urls.Dsregcmd
                }

                $avd = $image.AvdAgent
                if ($null -ne $avd) {
                    $avdValue = if ($avd.BootLoaderInstalled) { "RDAgentBootLoader $($avd.BootLoaderStatus); IsRegistered=$(& $formatValue $avd.IsRegistered)" } else { 'Not detected' }
                    New-FslResult -Category $category -Check 'Azure Virtual Desktop agent' -Status 'Info' -Target 'Image' -Value $avdValue `
                        -Message 'Remote Desktop Agent Loader service (RDAgentBootLoader) and HKLM\SOFTWARE\Microsoft\RDInfraAgent IsRegistered (1 = registered).' -Source $urls.AvdAgent
                }
            }

            if ($null -ne $image) {
                if (-not $image.AzureQueried) {
                    New-FslResult -Category $category -Check 'Azure VM' -Status 'Skipped' -Target 'Image' -Value 'Unknown' `
                        -Message 'Offline mode: the Azure Instance Metadata Service was not queried.' -Source $urls.Imds
                }
                elseif ($image.IsAzureVm -eq $true) {
                    $azure = $image.Azure
                    New-FslResult -Category $category -Check 'Azure VM' -Status 'Info' -Target 'Image' -Value 'Yes' `
                        -Message "Azure Instance Metadata Service: location $(& $formatValue $azure.Location), size $(& $formatValue $azure.VmSize), environment $(& $formatValue $azure.AzEnvironment)." -Source $urls.Imds
                    $reference = $azure.ImageReference
                    $referenceValue = switch ($reference.ImageSource) {
                        'PlatformOrMarketplace' { "$($reference.Publisher):$($reference.Offer):$($reference.Sku):$($reference.Version)" }
                        'CommunityGallery' { "$($reference.CommunityGalleryImageId) $($reference.ExactVersion)".Trim() }
                        'SharedGallery' { "$($reference.SharedGalleryImageId) $($reference.ExactVersion)".Trim() }
                        'ResourceId' { [string]$reference.Id }
                        default { 'Unknown' }
                    }
                    New-FslResult -Category $category -Check 'Azure image reference' -Status 'Info' -Target 'Image' -Value $referenceValue `
                        -Message "compute.storageProfile.imageReference ($(& $formatValue $reference.ImageSource))." -Source $urls.Imds
                }
                else {
                    New-FslResult -Category $category -Check 'Azure VM' -Status 'Info' -Target 'Image' -Value 'Unknown' `
                        -Message 'The Azure Instance Metadata Service (169.254.169.254) could not be reached (2-second timeout, proxy bypassed); this is expected when the computer is not an Azure VM or IMDS is blocked.' -Source $urls.Imds
                }
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $component -Context 'Discovery report: Image'
            New-FslResult -Category $category -Check 'Image discovery' -Status 'Error' -Target 'Image' -Message $_.Exception.Message -Source $urls.OperatingSystem
        }

        # ---------------- FSLogix ----------------
        try {
            $installation = $Discovery.FSLogix
            if ($null -eq $installation) {
                New-FslResult -Category $category -Check 'FSLogix installation' -Status 'Error' -Target 'FSLogix' -Message 'FSLogix installation information could not be collected.' -Source $urls.FSLogixComponents
            }
            elseif ([string]$installation.DetectionMethod -eq 'NotWindows') {
                New-FslResult -Category $category -Check 'FSLogix installation' -Status 'Skipped' -Target 'FSLogix' -Message 'Not running on Windows.' -Source $urls.FSLogixComponents
            }
            else {
                New-FslResult -Category $category -Check 'FSLogix installed' -Status 'Info' -Target 'FSLogix' -Value (& $formatValue ([bool]$installation.IsInstalled)) `
                    -Message "Install path: $(& $formatValue $installation.InstallPath); detected via: $($installation.DetectionMethod)." -Source $urls.FSLogixComponents
                New-FslResult -Category $category -Check 'FSLogix version' -Status 'Info' -Target 'FSLogix' -Value (& $formatValue $installation.Version) `
                    -Message 'Version comparison with the latest release is reported by Get-FslEnvironment.' -Source $urls.FSLogixComponents
                foreach ($service in @($installation.Services)) {
                    if ($null -eq $service) { continue }
                    New-FslResult -Category $category -Check "FSLogix service $($service.Name)" -Status 'Info' -Target 'FSLogix' `
                        -Value $(if ($service.StartType) { "$($service.Status) (StartType $($service.StartType))" } else { [string]$service.Status }) `
                        -Message ([string]$service.DisplayName) -Source $urls.FSLogixComponents
                }
                foreach ($driver in @($installation.Drivers)) {
                    if ($null -eq $driver) { continue }
                    $driverFile = if ($driver.PSObject.Properties['FileName'] -and $driver.FileName) { [string]$driver.FileName } else { [string]$driver.Name }
                    $driverMessage = if ($driver.Exists -eq $true) { "$($driver.Description); driver service '$($driver.Name)'; $($driver.PathName)" } else { [string]$driver.Description }
                    New-FslResult -Category $category -Check "FSLogix driver $driverFile" -Status 'Info' -Target 'FSLogix' -Value ([string]$driver.State) `
                        -Message $driverMessage -Source 'https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-systemdriver'
                }
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $component -Context 'Discovery report: FSLogix'
            New-FslResult -Category $category -Check 'FSLogix installation' -Status 'Error' -Target 'FSLogix' -Message $_.Exception.Message -Source $urls.FSLogixComponents
        }

        # ---------------- Office (Microsoft 365 Apps) ----------------
        try {
            $office = $Discovery.Office
            $onWindows = ($null -ne $Discovery.Image) -and [bool]$Discovery.Image.IsWindows
            if ($null -eq $office) {
                New-FslResult -Category $category -Check 'Microsoft 365 Apps' -Status 'Error' -Target 'Office' -Message 'Microsoft 365 Apps information could not be collected.' -Source $urls.OfficeUpdateRegistry
            }
            elseif (-not $onWindows) {
                New-FslResult -Category $category -Check 'Microsoft 365 Apps' -Status 'Skipped' -Target 'Office' -Message 'Not running on Windows.' -Source $urls.OfficeUpdateRegistry
            }
            else {
                if ($office.Installed -eq $true) {
                    New-FslResult -Category $category -Check 'Microsoft 365 Apps (Click-to-Run)' -Status 'Info' -Target 'Office' -Value 'Detected' `
                        -Message "CDNBaseUrl is set in $($office.RegistryPath) (set when Microsoft 365 Apps installs). The installed version is not reported." -Source $urls.OfficeUpdateRegistry
                }
                else {
                    New-FslResult -Category $category -Check 'Microsoft 365 Apps (Click-to-Run)' -Status 'Info' -Target 'Office' -Value 'Not detected' `
                        -Message "CDNBaseUrl was not found in $($office.RegistryPath)." -Source $urls.OfficeUpdateRegistry
                }
                if ($office.UpdateChannel -or $office.CDNBaseUrl) {
                    New-FslResult -Category $category -Check 'Microsoft 365 Apps update channel' -Status 'Info' -Target 'Office' -Value (& $formatValue $office.UpdateChannelName) `
                        -Message "UpdateChannel: $(& $formatValue $office.UpdateChannel); CDNBaseUrl: $(& $formatValue $office.CDNBaseUrl)." -Source $urls.OfficeUpdateRegistry
                }

                if ($office.SharedComputerActivation -eq $true) {
                    New-FslResult -Category $category -Check 'Shared computer activation' -Status 'Pass' -Target 'Office' -Value 'Enabled' -Expected 'Enabled on shared / multi-user hosts' `
                        -Message "SharedComputerLicensing = 1 in $($office.RegistryPath)." -Source $urls.SharedComputerVerify
                }
                elseif ($office.Installed -eq $true -or $null -ne $office.SharedComputerLicensing) {
                    New-FslResult -Category $category -Check 'Shared computer activation' -Status 'Info' -Target 'Office' `
                        -Value $(if ($null -ne $office.SharedComputerLicensing) { "SharedComputerLicensing = $($office.SharedComputerLicensing) (not enabled or unknown)" } else { 'Not set' }) `
                        -Message "SharedComputerLicensing in $($office.RegistryPath): only value 1 (enabled) is documented; other values are not interpreted. When configured by the Office Group Policy 'Use shared computer activation', verify in an Office app under File > Account > About." `
                        -Source $urls.SharedComputerVerify
                }
                if ($null -ne $office.SCLCacheOverride -or $office.SCLCacheOverrideDirectory) {
                    New-FslResult -Category $category -Check 'Licensing token location' -Status 'Info' -Target 'Office' `
                        -Value "SCLCacheOverride = $(& $formatValue $office.SCLCacheOverride); SCLCacheOverrideDirectory = $(& $formatValue $office.SCLCacheOverrideDirectory)" `
                        -Message 'Licensing token roaming for shared computer activation (default location %localappdata%\Microsoft\Office\16.0\Licensing).' -Source $urls.SharedComputer
                }
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $component -Context 'Discovery report: Office'
            New-FslResult -Category $category -Check 'Microsoft 365 Apps' -Status 'Error' -Target 'Office' -Message $_.Exception.Message -Source $urls.OfficeUpdateRegistry
        }

        # ---------------- Registry (FSLogix settings) ----------------
        try {
            $settings = @($Discovery.Settings | Where-Object -FilterScript { $null -ne $_ })
            $onWindows = ($null -ne $Discovery.Image) -and [bool]$Discovery.Image.IsWindows
            if (-not $onWindows -and $settings.Count -eq 0) {
                New-FslResult -Category $category -Check 'FSLogix registry settings' -Status 'Skipped' -Target 'Registry' -Message 'Not running on Windows.' -Source $urls.FSLogixSettings
            }
            elseif ($settings.Count -eq 0) {
                New-FslResult -Category $category -Check 'FSLogix registry settings' -Status 'Info' -Target 'Registry' -Value '0' `
                    -Message 'No FSLogix configuration values were found under HKLM\SOFTWARE\FSLogix or HKLM\SOFTWARE\Policies\FSLogix\ODFC. FSLogix uses documented defaults for values that are not set (Enabled defaults to 0).' `
                    -Source $urls.FSLogixSettings
            }
            else {
                foreach ($setting in $settings) {
                    $sourceName = if ($setting.PSObject.Properties['Source'] -and -not [string]::IsNullOrWhiteSpace([string]$setting.Source)) { [string]$setting.Source } else { 'Unknown' }
                    $sourceText = $sourceName
                    if ($setting.PSObject.Properties['PolicyName'] -and $setting.PolicyName) { $sourceText += " (GPO '$($setting.PolicyName)')" }
                    $detailText = if ($setting.PSObject.Properties['SourceDetail'] -and -not [string]::IsNullOrWhiteSpace([string]$setting.SourceDetail)) { "; SourceDetail: $($setting.SourceDetail)" } else { '' }
                    New-FslResult -Category $category -Check "$($setting.Scope)\$($setting.Name)" -Status 'Info' -Target 'Registry' -Value $setting.Value `
                        -Message "Source: $sourceText$detailText; $($setting.RegistryPath)\$($setting.Name) ($($setting.ValueKind))." `
                        -Source $urls.FSLogixSettings -Scope (ConvertTo-FslDiscResultScope -Scope ([string]$setting.Scope))
                }

                $unknownSettings = @($settings | Where-Object -FilterScript { -not $_.PSObject.Properties['Source'] -or [string]::IsNullOrWhiteSpace([string]$_.Source) -or [string]$_.Source -eq 'Unknown' })
                if ($unknownSettings.Count -gt 0) {
                    $reasons = @($unknownSettings | ForEach-Object -Process {
                            if ($_.PSObject.Properties['SourceDetail'] -and -not [string]::IsNullOrWhiteSpace([string]$_.SourceDetail)) { [string]$_.SourceDetail } else { 'Group Policy provenance not confirmed' }
                        } | Sort-Object -Unique)
                    New-FslResult -Category $category -Check 'FSLogix setting provenance' -Status 'Info' -Target 'Registry' -Value "Unknown: $($unknownSettings.Count) of $($settings.Count)" `
                        -Message "Provenance of $($unknownSettings.Count) FSLogix value(s) is Unknown ($($reasons -join '; ')). Unknown is not the same as Registry: these values may be delivered by Group Policy (including Local Group Policy)." `
                        -Recommendation 'Run the toolkit elevated so computer RSoP can be queried and each value reported as GroupPolicy or Registry.' `
                        -Source $urls.RsopRegistrySetting -RequiresElevation $true -Scope 'General'
                }
            }

            # Values under the non-Policies ODFC key (HKLM\SOFTWARE\FSLogix\ODFC). Read-only; names only.
            $nonPolicyOdfc = $null
            if ($Discovery.PSObject.Properties['NonPolicyOdfcValues']) { $nonPolicyOdfc = $Discovery.NonPolicyOdfcValues }
            elseif ($onWindows) { $nonPolicyOdfc = @(Get-FslDiscNonPolicyOdfcValue) }
            $nonPolicyNames = @(@($nonPolicyOdfc) | Where-Object -FilterScript { $null -ne $_ } | ForEach-Object -Process {
                    if ($_ -is [string]) { $_ } elseif ($_.PSObject.Properties['Name']) { [string]$_.Name }
                } | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
            if ($nonPolicyNames.Count -gt 0) {
                New-FslResult -Category $category -Check 'Non-policy ODFC registry values' -Status 'Info' -Target 'Registry' -Value $nonPolicyNames `
                    -Expected 'ODFC settings under HKLM\SOFTWARE\Policies\FSLogix\ODFC' `
                    -Message "$($nonPolicyNames.Count) value(s) exist under HKLM\SOFTWARE\FSLogix\ODFC. Microsoft documents the ODFC container settings under HKLM\SOFTWARE\Policies\FSLogix\ODFC; the toolkit reads ODFC settings only from that key and does not report these values as effective settings (values are not shown)." `
                    -Recommendation 'Configure ODFC settings under HKLM\SOFTWARE\Policies\FSLogix\ODFC (for example with the FSLogix ODFC administrative template settings in Group Policy) and review whether the values under HKLM\SOFTWARE\FSLogix\ODFC are left over, for example from the registry sample in Configure ODFC containers, which writes to that key.' `
                    -Source $urls.FSLogixSettings -Scope 'ODFC'
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $component -Context 'Discovery report: Registry'
            New-FslResult -Category $category -Check 'FSLogix registry settings' -Status 'Error' -Target 'Registry' -Message $_.Exception.Message -Source $urls.FSLogixSettings
        }

        # ---------------- GroupPolicy ----------------
        try {
            $gpoResults = @($Discovery.GroupPolicy | Where-Object -FilterScript { $null -ne $_ })
            if ($gpoResults.Count -eq 0) {
                New-FslResult -Category $category -Check 'Group Policy' -Status 'Info' -Target 'GroupPolicy' -Value '0' `
                    -Message 'No Group Policy results were returned.' -Source $urls.FSLogixGroupPolicy
            }
            foreach ($gpo in $gpoResults) {
                $gpoStatus = if ([string]$gpo.Status -in @('Pass', 'Warn', 'Fail', 'Info', 'Skipped', 'Error')) { [string]$gpo.Status } else { 'Info' }
                $gpoScope = if ($gpo.PSObject.Properties['Scope']) { ConvertTo-FslDiscResultScope -Scope ([string]$gpo.Scope) } else { 'General' }
                $gpoCheck = if ([string]::IsNullOrWhiteSpace([string]$gpo.Check)) { 'Group Policy' } else { [string]$gpo.Check }
                $gpoMessage = if ([string]::IsNullOrWhiteSpace([string]$gpo.Target)) { [string]$gpo.Message } else { "[$($gpo.Target)] $($gpo.Message)" }
                New-FslResult -Category $category -Check $gpoCheck -Status $gpoStatus -Target 'GroupPolicy' -Value $gpo.Value -Expected $gpo.Expected `
                    -Message $gpoMessage -Recommendation ([string]$gpo.Recommendation) -Source ([string]$gpo.Source) `
                    -RequiresElevation ([bool]$gpo.RequiresElevation) -Scope $gpoScope
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $component -Context 'Discovery report: GroupPolicy'
            New-FslResult -Category $category -Check 'Group Policy' -Status 'Error' -Target 'GroupPolicy' -Message $_.Exception.Message -Source $urls.FSLogixGroupPolicy
        }

        # ---------------- StorageLocation ----------------
        try {
            $locations = @($Discovery.StorageLocations | Where-Object -FilterScript { $null -ne $_ })
            $onWindows = ($null -ne $Discovery.Image) -and [bool]$Discovery.Image.IsWindows
            if ($locations.Count -eq 0) {
                if ($onWindows) {
                    New-FslResult -Category $category -Check 'Storage locations' -Status 'Info' -Target 'StorageLocation' -Value '0' `
                        -Message 'No VHDLocations or CCDLocations are configured for profile or Office containers.' -Source $urls.FSLogixSettings
                }
                else {
                    New-FslResult -Category $category -Check 'Storage locations' -Status 'Skipped' -Target 'StorageLocation' -Message 'Not running on Windows.' -Source $urls.FSLogixSettings
                }
            }
            foreach ($location in $locations) {
                $hostText = if ($location.HostName) { "; host $($location.HostName)" } else { '' }
                New-FslResult -Category $category -Check "$($location.Scope)\$($location.LocationType)" -Status 'Info' -Target 'StorageLocation' -Value $location.Path `
                    -Message "Provider $($location.ProviderType)$hostText; source $($location.Source)." `
                    -Source $urls.FSLogixSettings -Scope (ConvertTo-FslDiscResultScope -Scope ([string]$location.Scope))
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $component -Context 'Discovery report: StorageLocation'
            New-FslResult -Category $category -Check 'Storage locations' -Status 'Error' -Target 'StorageLocation' -Message $_.Exception.Message -Source $urls.FSLogixSettings
        }

        # ---------------- Mode ----------------
        try {
            $detected = [string]$Discovery.DetectedMode
            $configured = [string]$Discovery.ConfiguredMode
            New-FslResult -Category $category -Check 'Detected container mode' -Status 'Info' -Target 'Mode' -Value $(if ($detected) { $detected } else { 'Unknown' }) `
                -Message "From FSLogix 'Enabled' values: Profiles (HKLM\SOFTWARE\FSLogix\Profiles) and ODFC (HKLM\SOFTWARE\Policies\FSLogix\ODFC); 1 = enabled." -Source $urls.FSLogixSettings
            New-FslResult -Category $category -Check 'Toolkit container mode' -Status 'Info' -Target 'Mode' -Value $configured `
                -Message 'Toolkit checks run for this mode (ODFC = Office containers only, the default). Change it in Options > Container Mode or with Set-FslPreference -Name ContainerMode.' -Source 'Toolkit default'
            if ([string]::IsNullOrWhiteSpace($detected) -or $null -eq $Discovery.ModeMismatch) {
                New-FslResult -Category $category -Check 'Container mode match' -Status 'Skipped' -Target 'Mode' -Value 'Unknown' -Expected $configured `
                    -Message 'The FSLogix container mode of this image could not be determined (registry not readable or not Windows).' -Source 'Toolkit default'
            }
            elseif ($Discovery.ModeMismatch -eq $true) {
                $text = Get-FslDiscModeRecommendation -DetectedMode $detected -ConfiguredMode $configured
                New-FslResult -Category $category -Check 'Container mode match' -Status 'Warn' -Target 'Mode' -Value $detected -Expected $configured `
                    -Message $text['Message'] -Recommendation $text['Recommendation'] -Source $urls.FSLogixSettings
            }
            else {
                New-FslResult -Category $category -Check 'Container mode match' -Status 'Pass' -Target 'Mode' -Value $detected -Expected $configured `
                    -Message 'The toolkit container mode matches the container types enabled on this image.' -Source $urls.FSLogixSettings
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $component -Context 'Discovery report: Mode'
            New-FslResult -Category $category -Check 'Container mode match' -Status 'Error' -Target 'Mode' -Message $_.Exception.Message -Source 'Toolkit default'
        }
    }
}
