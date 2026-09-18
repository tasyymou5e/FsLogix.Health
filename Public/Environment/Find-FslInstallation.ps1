function Find-FslInstallation {
    <#
    .SYNOPSIS
        Locates the FSLogix Apps installation and reports its version, services and minifilter drivers.
    .DESCRIPTION
        Detection order (first hit wins for InstallPath; all methods that matched are listed in DetectionMethod):
          1. Uninstall registry entries (HKLM ...\CurrentVersion\Uninstall and the WOW6432Node view) whose
             DisplayName contains 'FSLogix' (the exact product name 'Microsoft FSLogix Apps' is preferred).
          2. HKLM\SOFTWARE\FSLogix\Apps InstallPath / InstallVersion (created by the installer).
          3. The documented default folder %ProgramFiles%\FSLogix\Apps (frx.exe present).
          4. The frxsvc service executable path (Get-Service BinaryPathName).
        Version preference: InstallVersion registry value, then uninstall DisplayVersion, then the frx.exe file version.
        Services (frxsvc, frxccds) are read with Get-Service. Minifilter drivers are identified by their documented file
        names (frxdrv.sys, frxdrvvt.sys, frxccd.sys) at the end of Win32_SystemDriver.PathName, because the driver
        service names are not documented (frxccd is additionally matched by its documented service key name).
        Driver State is the Win32_SystemDriver State, 'NotDetected' when no system driver uses the file, or 'Unknown'
        when Win32_SystemDriver could not be queried. Works as a standard user. On non-Windows returns IsInstalled = $false.
    .EXAMPLE
        Find-FslInstallation

        Returns InstallPath, Version, FrxPath, IsInstalled, Services, Drivers and DetectionMethod.
    .EXAMPLE
        (Find-FslInstallation).Services | Format-Table

        Shows FSLogix service state.
    .NOTES
        RequiresElevation: No
        Sources:
        https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components
        https://learn.microsoft.com/en-us/fslogix/troubleshooting-fslogix-service
        https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
        https://learn.microsoft.com/en-us/fslogix/utilities/frx/frx
        https://learn.microsoft.com/en-us/fslogix/how-to-install-fslogix
        https://learn.microsoft.com/en-us/windows/win32/msi/uninstall-registry-key
        https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-systemdriver
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-service
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $definition = Get-FslEnvComponentDefinition
    $methods = [System.Collections.Generic.List[string]]::new()
    $installPath = $null
    $versionText = $null
    $uninstallVersion = $null
    $frxPath = $null
    $services = [System.Collections.Generic.List[object]]::new()
    $drivers = [System.Collections.Generic.List[object]]::new()

    if (-not (Test-FslIsWindows)) {
        Write-FslLog -Message 'Find-FslInstallation: not running on Windows; FSLogix detection skipped.' -Level Verbose -Component 'Environment'
        return [pscustomobject][ordered]@{
            InstallPath     = $null
            Version         = $null
            FrxPath         = $null
            IsInstalled     = $false
            Services        = @()
            Drivers         = @()
            DetectionMethod = 'NotWindows'
        }
    }

    # 1. Uninstall registry entries
    foreach ($uninstallRoot in $definition.UninstallPaths) {
        try {
            if (-not (Test-Path -LiteralPath $uninstallRoot)) { continue }
            $entries = foreach ($key in (Get-ChildItem -LiteralPath $uninstallRoot -ErrorAction SilentlyContinue)) {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $props) { continue }
                $nameProperty = $props.PSObject.Properties['DisplayName']
                if ($null -eq $nameProperty -or [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) { continue }
                if ([string]$nameProperty.Value -notlike '*FSLogix*') { continue }
                $locationProperty = $props.PSObject.Properties['InstallLocation']
                $versionProperty = $props.PSObject.Properties['DisplayVersion']
                [pscustomobject]@{
                    DisplayName     = [string]$nameProperty.Value
                    DisplayVersion  = if ($null -ne $versionProperty) { [string]$versionProperty.Value } else { $null }
                    InstallLocation = if ($null -ne $locationProperty) { [string]$locationProperty.Value } else { $null }
                    IsExactProduct  = ([string]$nameProperty.Value -eq $definition.ProductName)
                }
            }
            $best = @($entries | Sort-Object -Property @{ Expression = 'IsExactProduct'; Descending = $true }, 'DisplayName') | Select-Object -First 1
            if ($null -ne $best) {
                if (-not $methods.Contains('UninstallRegistry')) { $methods.Add('UninstallRegistry') }
                if ($null -eq $uninstallVersion -and -not [string]::IsNullOrWhiteSpace($best.DisplayVersion)) { $uninstallVersion = $best.DisplayVersion }
                if ($null -eq $installPath -and -not [string]::IsNullOrWhiteSpace($best.InstallLocation) -and (Test-Path -LiteralPath $best.InstallLocation)) {
                    $installPath = $best.InstallLocation
                }
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Environment' -Context "Enumerate uninstall entries under $uninstallRoot"
        }
    }

    # 2. HKLM\SOFTWARE\FSLogix\Apps InstallPath / InstallVersion
    $registryInstallPath = Get-FslEnvRegistryValue -Path $definition.AppsRegistryPath -Name 'InstallPath'
    $registryInstallVersion = Get-FslEnvRegistryValue -Path $definition.AppsRegistryPath -Name 'InstallVersion'
    if (-not [string]::IsNullOrWhiteSpace([string]$registryInstallPath) -or -not [string]::IsNullOrWhiteSpace([string]$registryInstallVersion)) {
        $methods.Add('FSLogixAppsRegistry')
        if ($null -eq $installPath -and -not [string]::IsNullOrWhiteSpace([string]$registryInstallPath)) {
            $candidate = [Environment]::ExpandEnvironmentVariables([string]$registryInstallPath)
            if (Test-Path -LiteralPath $candidate) { $installPath = $candidate }
        }
    }

    # 3. Documented default folder
    try {
        $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
        if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
            $defaultFolder = Join-Path -Path $programFiles -ChildPath $definition.DefaultFolderPart
            if (Test-Path -LiteralPath (Join-Path -Path $defaultFolder -ChildPath $definition.FrxFileName)) {
                $methods.Add('DefaultFolder')
                if ($null -eq $installPath) { $installPath = $defaultFolder }
            }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'Check default FSLogix install folder'
    }

    # Services (also used as detection method 4)
    foreach ($serviceDefinition in $definition.Services) {
        $service = $null
        try {
            $service = Get-Service -Name $serviceDefinition.Name -ErrorAction SilentlyContinue
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Environment' -Context "Get-Service $($serviceDefinition.Name)"
        }
        if ($null -ne $service) {
            $binaryPath = $null
            $binaryProperty = $service.PSObject.Properties['BinaryPathName']
            if ($null -ne $binaryProperty) { $binaryPath = [string]$binaryProperty.Value }
            $services.Add([pscustomobject][ordered]@{
                    Name           = $service.Name
                    DisplayName    = $service.DisplayName
                    Exists         = $true
                    Status         = [string]$service.Status
                    StartType      = [string]$service.StartType
                    BinaryPathName = $binaryPath
                    Critical       = [bool]$serviceDefinition.Critical
                })
            if ($serviceDefinition.Name -eq 'frxsvc') {
                $exePath = Get-FslEnvExecutablePath -CommandLine $binaryPath
                if (-not [string]::IsNullOrWhiteSpace($exePath)) {
                    $methods.Add('ServiceImagePath')
                    $serviceFolder = Split-Path -Path $exePath -Parent
                    if ($null -eq $installPath -and (Test-Path -LiteralPath $serviceFolder)) { $installPath = $serviceFolder }
                }
            }
        }
        else {
            $services.Add([pscustomobject][ordered]@{
                    Name           = $serviceDefinition.Name
                    DisplayName    = $serviceDefinition.Description
                    Exists         = $false
                    Status         = 'NotFound'
                    StartType      = $null
                    BinaryPathName = $null
                    Critical       = [bool]$serviceDefinition.Critical
                })
        }
    }

    # Drivers - matched by documented driver FILE name at the end of Win32_SystemDriver.PathName (service names for
    # frxdrv.sys / frxdrvvt.sys are not documented). Query failure -> State 'Unknown'; no match -> 'NotDetected'.
    $driverInstances = @()
    $driverQueryFailed = $false
    try {
        $driverInstances = @(Get-CimInstance -ClassName 'Win32_SystemDriver' -Property 'Name', 'PathName', 'State', 'Started', 'StartMode' -ErrorAction Stop)
    }
    catch {
        $driverQueryFailed = $true
        Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'Query Win32_SystemDriver for FSLogix drivers'
    }
    foreach ($driverState in @(Get-FslEnvDriverState -Definition @($definition.Drivers) -Instance $driverInstances -QueryFailed $driverQueryFailed)) {
        $drivers.Add($driverState)
    }

    # frx.exe and version
    if ($null -ne $installPath) {
        $candidateFrx = Join-Path -Path $installPath -ChildPath $definition.FrxFileName
        if (Test-Path -LiteralPath $candidateFrx -PathType Leaf) { $frxPath = $candidateFrx }
    }

    if ($null -ne (ConvertTo-FslEnvVersion -InputObject $registryInstallVersion)) {
        $versionText = ([string](ConvertTo-FslEnvVersion -InputObject $registryInstallVersion))
    }
    elseif ($null -ne (ConvertTo-FslEnvVersion -InputObject $uninstallVersion)) {
        $versionText = ([string](ConvertTo-FslEnvVersion -InputObject $uninstallVersion))
    }
    elseif ($null -ne $frxPath) {
        try {
            $fileInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($frxPath)
            $fileVersion = [version]::new($fileInfo.FileMajorPart, $fileInfo.FileMinorPart, $fileInfo.FileBuildPart, $fileInfo.FilePrivatePart)
            if ($fileVersion -gt [version]::new(0, 0, 0, 0)) { $versionText = [string]$fileVersion }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Environment' -Context "Read file version of $frxPath"
        }
    }

    $isInstalled = ($methods.Count -gt 0) -and (($null -ne $installPath) -or ($null -ne $versionText) -or $methods.Contains('ServiceImagePath'))
    $detection = if ($methods.Count -gt 0) { $methods -join ', ' } else { 'NotFound' }
    Write-FslLog -Message "Find-FslInstallation: IsInstalled=$isInstalled Version=$versionText Path=$installPath Methods=$detection" -Level Verbose -Component 'Environment'

    [pscustomobject][ordered]@{
        InstallPath     = $installPath
        Version         = $versionText
        FrxPath         = $frxPath
        IsInstalled     = [bool]$isInstalled
        Services        = $services.ToArray()
        Drivers         = $drivers.ToArray()
        DetectionMethod = $detection
    }
}
