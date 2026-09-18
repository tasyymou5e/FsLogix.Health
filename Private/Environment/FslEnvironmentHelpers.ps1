# Private helpers for the Environment area (prefix *-FslEnv*).

function Get-FslEnvComponentDefinition {
    <#
    .SYNOPSIS
        Returns verified FSLogix component names and locations.
    .NOTES
        Sources:
        https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components (services frxsvc.exe/frxccds.exe, drivers frxdrv.sys/frxdrvvt.sys/frxccd.sys)
        https://learn.microsoft.com/en-us/fslogix/troubleshooting-fslogix-service (service names frxsvc, frxccds)
        https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings (HKLM\SOFTWARE\FSLogix\Apps InstallPath/InstallVersion; Services\frxccd, Services\frxccds)
        https://learn.microsoft.com/en-us/fslogix/utilities/frx/frx (frx.exe in C:\Program Files\FSLogix\Apps)
        https://learn.microsoft.com/en-us/fslogix/how-to-install-fslogix (Installed apps entry 'Microsoft FSLogix Apps')
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        AppsRegistryPath  = 'HKLM:\SOFTWARE\FSLogix\Apps'
        DefaultFolderPart = 'FSLogix\Apps'
        FrxFileName       = 'frx.exe'
        ProductName       = 'Microsoft FSLogix Apps'
        UninstallPaths    = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        )
        Services          = @(
            @{ Name = 'frxsvc'; Description = 'FSLogix Apps Services'; Critical = $true }
            @{ Name = 'frxccds'; Description = 'FSLogix Cloud Caching Service'; Critical = $false }
        )
        # Driver FILE names are documented (reference-service-drivers-components). The driver SERVICE names for
        # frxdrv.sys / frxdrvvt.sys are not documented, so drivers are matched by the file name at the end of
        # Win32_SystemDriver.PathName ("Fully qualified path to the service binary file"). Only 'frxccd' is a
        # documented service key name (SYSTEM\CurrentControlSet\Services\frxccd\Parameters, reference-configuration-settings).
        Drivers           = @(
            @{ FileName = 'frxdrv.sys'; KnownServiceName = $null; Description = 'Virtualization Filter Driver' }
            @{ FileName = 'frxdrvvt.sys'; KnownServiceName = $null; Description = 'Redirection Filter Driver' }
            @{ FileName = 'frxccd.sys'; KnownServiceName = 'frxccd'; Description = 'Virtual Hard Drive Filter Driver (Cloud Cache)' }
        )
        Sources           = @{
            Components    = 'https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components'
            Services      = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-fslogix-service'
            Registry      = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings'
            Frx           = 'https://learn.microsoft.com/en-us/fslogix/utilities/frx/frx'
            Install       = 'https://learn.microsoft.com/en-us/fslogix/how-to-install-fslogix'
            ReleaseNotes  = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Uninstall     = 'https://learn.microsoft.com/en-us/windows/win32/msi/uninstall-registry-key'
            SystemDriver  = 'https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-systemdriver'
            GetService    = 'https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-service'
        }
    }
}

function ConvertTo-FslEnvVersion {
    <#
    .SYNOPSIS
        Parses a version string into [version]; returns $null when it cannot be parsed.
    .DESCRIPTION
        Strips a leading 'v' and any suffix after the numeric dotted part (for example '-preview.1' or ' (build)'),
        then uses [version]::TryParse. Single-number strings are not treated as versions.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [version]) { return $InputObject }
    if ($InputObject -is [System.Management.Automation.SemanticVersion]) {
        return [version]::new($InputObject.Major, $InputObject.Minor, $InputObject.Patch)
    }
    $text = ([string]$InputObject).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $match = [regex]::Match($text, '^[vV]?(\d+(?:\.\d+){1,3})')
    if (-not $match.Success) { return $null }
    $parsed = $null
    if ([version]::TryParse($match.Groups[1].Value, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-FslEnvRegistryValue {
    <#
    .SYNOPSIS
        Reads one registry value; returns $null when the key or value does not exist or cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    if (-not (Test-FslIsWindows)) { return $null }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $item) { return $null }
        $property = $item.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return $property.Value
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Environment' -Context "Read registry value $Path\$Name"
        return $null
    }
}

function Get-FslEnvKnownVersion {
    <#
    .SYNOPSIS
        Loads Config/KnownVersions.psd1; returns $null when it cannot be loaded.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    try {
        return (Get-FslDataFile -Name 'KnownVersions')
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'Load Config/KnownVersions.psd1'
        return $null
    }
}

function Get-FslEnvExecutablePath {
    <#
    .SYNOPSIS
        Extracts the executable path from a service ImagePath / BinaryPathName string.
    .DESCRIPTION
        Handles quoted paths ("C:\Program Files\...\frxsvc.exe" -args) and unquoted paths ending in .exe.
        Expands environment variables. Returns $null when no .exe path is found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $CommandLine
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $text = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    $quoted = [regex]::Match($text, '^"([^"]+)"')
    if ($quoted.Success) { return $quoted.Groups[1].Value }
    $unquoted = [regex]::Match($text, '^(.+?\.exe)(\s|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($unquoted.Success) { return $unquoted.Groups[1].Value }
    return $null
}

function Get-FslEnvWindowsInfo {
    <#
    .SYNOPSIS
        Collects Windows caption, product type, build number, UBR and DisplayVersion.
    .NOTES
        Sources:
        https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem (Caption, BuildNumber, ProductType 1=Work Station, 2=Domain Controller, 3=Server)
        https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-win32-deploy-update-package (HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion CurrentBuildNumber, UBR)
        https://learn.microsoft.com/en-us/answers/questions/721139/programmatically-(powershell)-getting-windows-vers (DisplayVersion value - Q&A source, informational only)
        https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem (OperatingSystemSKU, InstallDate, LastBootUpTime)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $info = [ordered]@{
        Caption            = $null
        ProductType        = $null
        BuildNumber        = $null
        UBR                = $null
        DisplayVersion     = $null   # informational only; never used for version decisions (build number is authoritative)
        Collected          = $false
        OperatingSystemSKU = $null   # Win32_OperatingSystem.OperatingSystemSKU (PRODUCT_* constant)
        InstallDate        = $null   # Win32_OperatingSystem.InstallDate
        LastBootUpTime     = $null   # Win32_OperatingSystem.LastBootUpTime
    }
    if (-not (Test-FslIsWindows)) { return [pscustomobject]$info }

    try {
        $os = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction Stop
        $info.Caption = ([string]$os.Caption).Trim()
        $info.ProductType = $os.ProductType
        if ($null -ne $os.PSObject.Properties['OperatingSystemSKU'] -and $null -ne $os.OperatingSystemSKU) { $info.OperatingSystemSKU = [int]$os.OperatingSystemSKU }
        if ($null -ne $os.PSObject.Properties['InstallDate'] -and $os.InstallDate -is [datetime]) { $info.InstallDate = $os.InstallDate }
        if ($null -ne $os.PSObject.Properties['LastBootUpTime'] -and $os.LastBootUpTime -is [datetime]) { $info.LastBootUpTime = $os.LastBootUpTime }
        $buildNumber = 0
        if ([int]::TryParse([string]$os.BuildNumber, [ref]$buildNumber)) { $info.BuildNumber = $buildNumber }
        $info.Collected = $true
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'Query Win32_OperatingSystem'
    }

    $currentVersionPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    if ($null -eq $info.BuildNumber) {
        $registryBuild = 0
        if ([int]::TryParse([string](Get-FslEnvRegistryValue -Path $currentVersionPath -Name 'CurrentBuildNumber'), [ref]$registryBuild)) {
            $info.BuildNumber = $registryBuild
            $info.Collected = $true
        }
    }
    $ubr = Get-FslEnvRegistryValue -Path $currentVersionPath -Name 'UBR'
    if ($null -ne $ubr) { $info.UBR = [int]$ubr }
    $displayVersion = Get-FslEnvRegistryValue -Path $currentVersionPath -Name 'DisplayVersion'
    if (-not [string]::IsNullOrWhiteSpace([string]$displayVersion)) { $info.DisplayVersion = [string]$displayVersion }

    [pscustomobject]$info
}

function Get-FslEnvWindowsVersionName {
    <#
    .SYNOPSIS
        Maps a Windows build number to a version name using Config/KnownVersions.psd1.
    .DESCRIPTION
        ProductType 2/3 selects the Server name, except when OperatingSystemSKU is 175
        (PRODUCT_ENTERPRISE_FOR_VIRTUAL_DESKTOPS / PRODUCT_SERVERRDSH, Windows Enterprise multi-session), which reports
        ProductType 3 but is a client edition.
    .NOTES
        Sources:
        https://learn.microsoft.com/en-us/azure/virtual-desktop/windows-multisession-faq (multi-session reports ProductType 3)
        https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem (OperatingSystemSKU 175 PRODUCT_ENTERPRISE_FOR_VIRTUAL_DESKTOPS)
        https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getproductinfo (0xAF PRODUCT_SERVERRDSH 'Windows 10 Enterprise for Virtual Desktops')
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [hashtable] $KnownVersions,

        [Parameter(Mandatory = $true)]
        [int] $BuildNumber,

        [Parameter()]
        [AllowNull()]
        [object] $ProductType,

        [Parameter()]
        [AllowNull()]
        [object] $OperatingSystemSKU
    )

    if ($null -eq $KnownVersions -or -not $KnownVersions.ContainsKey('Windows')) { return $null }
    $builds = $KnownVersions.Windows.Builds
    $key = [string]$BuildNumber
    if ($null -eq $builds -or -not $builds.ContainsKey($key)) { return $null }
    $entry = $builds[$key]
    $isMultiSession = ($null -ne $OperatingSystemSKU) -and ([int]$OperatingSystemSKU -eq 175)
    $isServer = ($null -ne $ProductType) -and ([int]$ProductType -in 2, 3) -and (-not $isMultiSession)
    if ($isServer -and $entry.ContainsKey('Server')) { return [string]$entry.Server }
    if ((-not $isServer) -and $entry.ContainsKey('Client')) { return [string]$entry.Client }
    return $null
}

function Get-FslEnvDriverFileName {
    <#
    .SYNOPSIS
        Returns the file name (leaf) of a Win32_SystemDriver.PathName value, or $null.
    .DESCRIPTION
        PathName is the fully qualified path to the driver binary (for example \SystemRoot\System32\drivers\afd.sys).
        Surrounding quotes are removed; both '\' and '/' separators are handled.
    .NOTES
        Source: https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-systemdriver (PathName)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $PathName
    )

    if ([string]::IsNullOrWhiteSpace($PathName)) { return $null }
    $text = $PathName.Trim().Trim('"')
    $parts = $text -split '[\\/]'
    $leaf = $parts[$parts.Count - 1].Trim()
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $null }
    return $leaf
}

function Get-FslEnvDriverState {
    <#
    .SYNOPSIS
        Matches documented FSLogix driver files against Win32_SystemDriver instances without assuming service names.
    .DESCRIPTION
        For each driver definition (FileName, KnownServiceName, Description) the instance whose PathName leaf equals the
        file name (case-insensitive) is used; a documented KnownServiceName is used as a fallback match.
        When the query failed ($QueryFailed) the state is 'Unknown' (Exists $null). When the query succeeded and no
        instance matched, State is 'NotDetected' (Exists $false). 'NotFound' is never reported.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Definition,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $Instance,

        [Parameter()]
        [bool] $QueryFailed = $false
    )

    foreach ($driverDefinition in $Definition) {
        $fileName = [string]$driverDefinition['FileName']
        $knownService = if ($driverDefinition.ContainsKey('KnownServiceName')) { [string]$driverDefinition['KnownServiceName'] } else { $null }
        $match = $null
        $method = $null
        if (-not $QueryFailed) {
            $match = @($Instance) | Where-Object -FilterScript {
                $null -ne $_ -and $null -ne $_.PSObject.Properties['PathName'] -and
                [string]::Equals((Get-FslEnvDriverFileName -PathName ([string]$_.PathName)), $fileName, [System.StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1
            if ($null -ne $match) { $method = 'PathName' }
            elseif (-not [string]::IsNullOrWhiteSpace($knownService)) {
                $match = @($Instance) | Where-Object -FilterScript {
                    $null -ne $_ -and [string]::Equals([string]$_.Name, $knownService, [System.StringComparison]::OrdinalIgnoreCase)
                } | Select-Object -First 1
                if ($null -ne $match) { $method = 'DocumentedServiceName' }
            }
        }

        if ($null -ne $match) {
            [pscustomobject][ordered]@{
                Name            = [string]$match.Name
                FileName        = $fileName
                Description     = [string]$driverDefinition['Description']
                Exists          = $true
                State           = [string]$match.State
                Started         = if ($null -ne $match.PSObject.Properties['Started'] -and $null -ne $match.Started) { [bool]$match.Started } else { $null }
                StartMode       = [string]$match.StartMode
                PathName        = [string]$match.PathName
                DetectionMethod = $method
            }
        }
        else {
            [pscustomobject][ordered]@{
                Name            = $fileName
                FileName        = $fileName
                Description     = [string]$driverDefinition['Description']
                Exists          = if ($QueryFailed) { $null } else { $false }
                State           = if ($QueryFailed) { 'Unknown' } else { 'NotDetected' }
                Started         = $null
                StartMode       = $null
                PathName        = $null
                DetectionMethod = $null
            }
        }
    }
}
