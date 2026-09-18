function Get-FslEnvironment {
    <#
    .SYNOPSIS
        Checks the operating system, PowerShell and FSLogix installation against the toolkit's supported baseline.
    .DESCRIPTION
        Emits FSLogixToolkit.Result objects (Category Environment):
          - Operating system (Info): caption, build.UBR, DisplayVersion (informational only).
          - Windows build: Pass when build >= Environment.MinimumWindowsBuild (26100 = Windows 11 24H2 / Windows Server 2025), else Fail.
          - PowerShell edition: Pass for Core, Fail otherwise.
          - PowerShell minimum version: Pass when >= Environment.MinimumPowerShellVersion, else Fail.
          - PowerShell latest version: Pass when equal to latest stable, Warn when older, Info when newer or a preview.
          - PowerShell support lifecycle: Pass while the release line is supported, Fail after end-of-support, Info when unknown.
          - FSLogix installed: Pass / Fail.
          - FSLogix version: Pass when >= latest known release, Warn when older.
          - FSLogix services (frxsvc, frxccds) and minifilter drivers (frxdrv.sys, frxdrvvt.sys, frxccd.sys, matched by
            driver file name in Win32_SystemDriver.PathName; Warn when not detected, Error when the state is unknown).
          - Elevation (Info).
        Windows-only checks return Skipped on other platforms; PowerShell checks always run. Never throws.
    .PARAMETER Offline
        Use Config/KnownVersions.psd1 instead of querying GitHub / learn.microsoft.com for latest versions.
    .EXAMPLE
        Get-FslEnvironment | Format-Table -Property Check, Status, Value, Expected

        Runs all environment checks.
    .EXAMPLE
        Get-FslEnvironment -Offline

        Runs the checks without network access.
    .NOTES
        RequiresElevation: No
        Sources:
        https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information
        https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info
        https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem
        https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-win32-deploy-update-package
        https://learn.microsoft.com/en-us/powershell/scripting/install/powershell-support-lifecycle
        https://github.com/PowerShell/PowerShell/releases
        https://learn.microsoft.com/en-us/fslogix/overview-release-notes
        https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components
        https://learn.microsoft.com/en-us/fslogix/troubleshooting-fslogix-service
        https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-systemdriver
        https://learn.microsoft.com/en-us/azure/virtual-desktop/windows-multisession-faq
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [switch] $Offline
    )

    $category = 'Environment'
    $computerTarget = [Environment]::MachineName
    $onWindows = $false
    try { $onWindows = [bool](Test-FslIsWindows) }
    catch { Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'Test-FslIsWindows' }

    $environmentConfig = $null
    try { $environmentConfig = Get-FslConfig -Section 'Environment' }
    catch { Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'Read Environment settings' }

    $minimumBuild = 26100
    $minimumPowerShell = [version]'7.4'
    if ($null -ne $environmentConfig) {
        if ($environmentConfig.ContainsKey('MinimumWindowsBuild')) { $minimumBuild = [int]$environmentConfig.MinimumWindowsBuild }
        if ($environmentConfig.ContainsKey('MinimumPowerShellVersion')) {
            $configuredMinimum = ConvertTo-FslEnvVersion -InputObject ([string]$environmentConfig.MinimumPowerShellVersion)
            if ($null -ne $configuredMinimum) { $minimumPowerShell = $configuredMinimum }
        }
    }

    $known = Get-FslEnvKnownVersion
    $windowsSource = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information'
    $lifecycleSource = 'https://learn.microsoft.com/en-us/powershell/scripting/install/powershell-support-lifecycle'
    $definition = Get-FslEnvComponentDefinition

    # ---------------- Operating system ----------------
    if (-not $onWindows) {
        New-FslResult -Category $category -Check 'Operating system' -Status 'Skipped' -Target $computerTarget `
            -Value ([System.Runtime.InteropServices.RuntimeInformation]::OSDescription) -Expected 'Windows' `
            -Message 'Not running on Windows; Windows checks skipped.' -Source $windowsSource -RequiresElevation $false
        New-FslResult -Category $category -Check 'Windows build' -Status 'Skipped' -Target $computerTarget `
            -Expected ">= $minimumBuild" -Message 'Not running on Windows.' -Source $windowsSource -RequiresElevation $false
    }
    else {
        try {
            $windowsInfo = Get-FslEnvWindowsInfo
            if (-not $windowsInfo.Collected -or $null -eq $windowsInfo.BuildNumber) {
                New-FslResult -Category $category -Check 'Windows build' -Status 'Error' -Target $computerTarget `
                    -Expected ">= $minimumBuild" -Message 'Unable to read the Windows build number.' -Source $windowsSource -RequiresElevation $false
            }
            else {
                $versionName = Get-FslEnvWindowsVersionName -KnownVersions $known -BuildNumber $windowsInfo.BuildNumber -ProductType $windowsInfo.ProductType -OperatingSystemSKU $windowsInfo.OperatingSystemSKU
                $fullBuild = if ($null -ne $windowsInfo.UBR) { '{0}.{1}' -f $windowsInfo.BuildNumber, $windowsInfo.UBR } else { [string]$windowsInfo.BuildNumber }
                $osParts = @($windowsInfo.Caption, "build $fullBuild")
                # DisplayVersion is informational only (Q&A-sourced registry value); the build number drives all checks.
                if ($windowsInfo.DisplayVersion) { $osParts += "DisplayVersion $($windowsInfo.DisplayVersion) (informational)" }
                New-FslResult -Category $category -Check 'Operating system' -Status 'Info' -Target $computerTarget `
                    -Value (($osParts | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ', ') `
                    -Message $(if ($versionName) { "Detected $versionName." } else { 'Operating system edition and build.' }) `
                    -Source 'https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem' -RequiresElevation $false

                if ($windowsInfo.BuildNumber -ge $minimumBuild) {
                    New-FslResult -Category $category -Check 'Windows build' -Status 'Pass' -Target $computerTarget `
                        -Value $fullBuild -Expected ">= $minimumBuild (Windows 11 24H2 / Windows Server 2025 or later)" `
                        -Message "Build $fullBuild meets the supported baseline." -Source $windowsSource -RequiresElevation $false
                }
                else {
                    New-FslResult -Category $category -Check 'Windows build' -Status 'Fail' -Target $computerTarget `
                        -Value $fullBuild -Expected ">= $minimumBuild (Windows 11 24H2 / Windows Server 2025 or later)" `
                        -Message "Build $fullBuild is below the toolkit's supported baseline." `
                        -Recommendation 'Upgrade to Windows 11 24H2 / Windows Server 2025 or later.' -Source $windowsSource -RequiresElevation $false
                }
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'Operating system checks'
            New-FslResult -Category $category -Check 'Windows build' -Status 'Error' -Target $computerTarget `
                -Message $_.Exception.Message -Source $windowsSource -RequiresElevation $false
        }
    }

    # ---------------- PowerShell ----------------
    $currentSemantic = $PSVersionTable.PSVersion
    $currentVersion = ConvertTo-FslEnvVersion -InputObject $currentSemantic
    $isPreview = ($currentSemantic -is [System.Management.Automation.SemanticVersion]) -and -not [string]::IsNullOrEmpty($currentSemantic.PreReleaseLabel)
    $edition = [string]$PSVersionTable.PSEdition

    try {
        if ($edition -eq 'Core') {
            New-FslResult -Category $category -Check 'PowerShell edition' -Status 'Pass' -Target 'PowerShell' -Value $edition -Expected 'Core' `
                -Message 'Running on PowerShell (Core edition).' -Source 'Toolkit default' -RequiresElevation $false
        }
        else {
            New-FslResult -Category $category -Check 'PowerShell edition' -Status 'Fail' -Target 'PowerShell' -Value $edition -Expected 'Core' `
                -Message 'The toolkit requires PowerShell 7 (Core edition).' -Recommendation 'Run the toolkit in PowerShell 7.4 or later (pwsh.exe).' `
                -Source 'Toolkit default' -RequiresElevation $false
        }

        if ($null -ne $currentVersion -and $currentVersion -ge $minimumPowerShell) {
            New-FslResult -Category $category -Check 'PowerShell minimum version' -Status 'Pass' -Target 'PowerShell' -Value ([string]$currentSemantic) `
                -Expected ">= $minimumPowerShell" -Message 'PowerShell version meets the toolkit minimum.' -Source 'Toolkit default' -RequiresElevation $false
        }
        else {
            New-FslResult -Category $category -Check 'PowerShell minimum version' -Status 'Fail' -Target 'PowerShell' -Value ([string]$currentSemantic) `
                -Expected ">= $minimumPowerShell" -Message 'PowerShell version is below the toolkit minimum.' `
                -Recommendation "Install PowerShell $minimumPowerShell or later." -Source 'Toolkit default' -RequiresElevation $false
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'PowerShell edition/minimum checks'
        New-FslResult -Category $category -Check 'PowerShell minimum version' -Status 'Error' -Target 'PowerShell' -Message $_.Exception.Message -Source 'Toolkit default' -RequiresElevation $false
    }

    $latestInfo = $null
    try {
        $latestInfo = Get-FslLatestVersionInfo -Offline:$Offline
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'Get-FslLatestVersionInfo'
    }

    try {
        $latestPowerShell = if ($null -ne $latestInfo) { ConvertTo-FslEnvVersion -InputObject $latestInfo.PowerShellLatest } else { $null }
        $psSource = if ($null -ne $latestInfo -and $latestInfo.PowerShellSource) { [string]$latestInfo.PowerShellSource } else { 'https://github.com/PowerShell/PowerShell/releases' }
        $retrievedNote = if ($null -ne $latestInfo) { " (latest version data: $($latestInfo.Retrieved))" } else { '' }
        if ($null -eq $latestPowerShell -or $null -eq $currentVersion) {
            New-FslResult -Category $category -Check 'PowerShell latest version' -Status 'Error' -Target 'PowerShell' -Value ([string]$currentSemantic) `
                -Message 'Unable to determine the latest stable PowerShell version.' -Source $psSource -RequiresElevation $false
        }
        elseif ($isPreview -or $currentVersion -gt $latestPowerShell) {
            New-FslResult -Category $category -Check 'PowerShell latest version' -Status 'Info' -Target 'PowerShell' -Value ([string]$currentSemantic) `
                -Expected ([string]$latestPowerShell) -Message "Running a preview or newer build than the latest stable release$retrievedNote." -Source $psSource -RequiresElevation $false
        }
        elseif ($currentVersion -eq $latestPowerShell) {
            New-FslResult -Category $category -Check 'PowerShell latest version' -Status 'Pass' -Target 'PowerShell' -Value ([string]$currentSemantic) `
                -Expected ([string]$latestPowerShell) -Message "Running the latest stable PowerShell release$retrievedNote." -Source $psSource -RequiresElevation $false
        }
        else {
            New-FslResult -Category $category -Check 'PowerShell latest version' -Status 'Warn' -Target 'PowerShell' -Value ([string]$currentSemantic) `
                -Expected ([string]$latestPowerShell) -Message "A newer stable PowerShell release is available$retrievedNote." `
                -Recommendation "Update PowerShell to $latestPowerShell." -Source $psSource -RequiresElevation $false
        }

        # Support lifecycle of the running release line
        $line = if ($null -ne $currentVersion) { '{0}.{1}' -f $currentVersion.Major, $currentVersion.Minor } else { $null }
        $lineEntry = $null
        $retired = $null
        if ($null -ne $known -and $known.ContainsKey('PowerShell') -and $null -ne $line) {
            $lineEntry = @($known.PowerShell.SupportedLines) | Where-Object -FilterScript { $_.Line -eq $line } | Select-Object -First 1
            if ($known.PowerShell.ContainsKey('RetiredLines')) {
                $retired = @($known.PowerShell.RetiredLines) | Where-Object -FilterScript { $_.Line -eq $line } | Select-Object -First 1
            }
        }
        $endOfSupportText = if ($null -ne $lineEntry) { [string]$lineEntry.EndOfSupport } elseif ($null -ne $retired) { [string]$retired.EndOfSupport } else { $null }
        $endOfSupport = [datetime]::MinValue
        if ($null -ne $endOfSupportText -and [datetime]::TryParseExact($endOfSupportText, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$endOfSupport)) {
            if ([datetime]::Today -gt $endOfSupport) {
                New-FslResult -Category $category -Check 'PowerShell support lifecycle' -Status 'Fail' -Target 'PowerShell' -Value "PowerShell $line" `
                    -Expected "Supported release line (end-of-support $endOfSupportText)" -Message "PowerShell $line reached end-of-support on $endOfSupportText." `
                    -Recommendation 'Upgrade to a supported PowerShell release.' -Source $lifecycleSource -RequiresElevation $false
            }
            else {
                New-FslResult -Category $category -Check 'PowerShell support lifecycle' -Status 'Pass' -Target 'PowerShell' -Value "PowerShell $line" `
                    -Expected "Supported release line (end-of-support $endOfSupportText)" -Message "PowerShell $line is supported until $endOfSupportText." `
                    -Source $lifecycleSource -RequiresElevation $false
            }
        }
        else {
            New-FslResult -Category $category -Check 'PowerShell support lifecycle' -Status 'Info' -Target 'PowerShell' -Value $(if ($line) { "PowerShell $line" } else { [string]$currentSemantic }) `
                -Message 'Release line not listed in Config/KnownVersions.psd1 (preview or newer than the data file).' -Source $lifecycleSource -RequiresElevation $false
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'PowerShell latest/lifecycle checks'
        New-FslResult -Category $category -Check 'PowerShell latest version' -Status 'Error' -Target 'PowerShell' -Message $_.Exception.Message -Source 'https://github.com/PowerShell/PowerShell/releases' -RequiresElevation $false
    }

    # ---------------- FSLogix ----------------
    $fslSource = $definition.Sources.Components
    if (-not $onWindows) {
        foreach ($checkName in @('FSLogix installed', 'FSLogix version', 'FSLogix services', 'FSLogix drivers')) {
            New-FslResult -Category $category -Check $checkName -Status 'Skipped' -Target $computerTarget `
                -Message 'Not running on Windows.' -Source $fslSource -RequiresElevation $false
        }
    }
    else {
        $installation = $null
        try {
            $installation = Find-FslInstallation
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'Find-FslInstallation'
            New-FslResult -Category $category -Check 'FSLogix installed' -Status 'Error' -Target $computerTarget `
                -Message $_.Exception.Message -Source $fslSource -RequiresElevation $false
        }

        if ($null -ne $installation) {
            try {
                if ($installation.IsInstalled) {
                    New-FslResult -Category $category -Check 'FSLogix installed' -Status 'Pass' -Target $computerTarget `
                        -Value $(if ($installation.InstallPath) { $installation.InstallPath } else { 'Installed' }) `
                        -Message "Detected via: $($installation.DetectionMethod)." -Source $definition.Sources.Install -RequiresElevation $false
                }
                else {
                    New-FslResult -Category $category -Check 'FSLogix installed' -Status 'Fail' -Target $computerTarget -Value 'Not found' -Expected 'Installed' `
                        -Message 'FSLogix Apps was not found (uninstall registry, FSLogix Apps registry key, default folder, frxsvc service).' `
                        -Recommendation 'Install the latest FSLogix release.' -Source $definition.Sources.Install -RequiresElevation $false
                }

                # Version vs latest
                $latestFslText = if ($null -ne $latestInfo) { [string]$latestInfo.FSLogixLatest } else { $null }
                $latestFsl = ConvertTo-FslEnvVersion -InputObject $latestFslText
                $installedFsl = ConvertTo-FslEnvVersion -InputObject $installation.Version
                $releaseLabel = if ($null -ne $latestInfo -and $latestInfo.PSObject.Properties['FSLogixLatestReleaseName'] -and $latestInfo.FSLogixLatestReleaseName) { " ($($latestInfo.FSLogixLatestReleaseName))" } else { '' }
                $releaseSource = if ($null -ne $latestInfo -and $latestInfo.FSLogixSource) { [string]$latestInfo.FSLogixSource } else { $definition.Sources.ReleaseNotes }
                if (-not $installation.IsInstalled) {
                    New-FslResult -Category $category -Check 'FSLogix version' -Status 'Skipped' -Target $computerTarget -Expected "$latestFslText$releaseLabel" `
                        -Message 'FSLogix is not installed.' -Source $releaseSource -RequiresElevation $false
                }
                elseif ($null -eq $installedFsl -or $null -eq $latestFsl) {
                    New-FslResult -Category $category -Check 'FSLogix version' -Status 'Error' -Target $computerTarget -Value $installation.Version -Expected "$latestFslText$releaseLabel" `
                        -Message 'Unable to determine the installed or latest FSLogix version.' -Source $releaseSource -RequiresElevation $false
                }
                elseif ($installedFsl -ge $latestFsl) {
                    New-FslResult -Category $category -Check 'FSLogix version' -Status 'Pass' -Target $computerTarget -Value ([string]$installedFsl) -Expected ">= $latestFslText$releaseLabel" `
                        -Message 'FSLogix is at the latest known release.' -Source $releaseSource -RequiresElevation $false
                }
                else {
                    $installedName = $null
                    if ($null -ne $known -and $known.ContainsKey('FSLogix')) {
                        $matchKnown = @($known.FSLogix) | Where-Object -FilterScript { (ConvertTo-FslEnvVersion -InputObject $_.Build) -eq $installedFsl } | Select-Object -First 1
                        if ($null -ne $matchKnown) { $installedName = " ($($matchKnown.ReleaseName))" }
                    }
                    New-FslResult -Category $category -Check 'FSLogix version' -Status 'Warn' -Target $computerTarget -Value "$installedFsl$installedName" -Expected ">= $latestFslText$releaseLabel" `
                        -Message 'A newer FSLogix release is available. Microsoft requires customers to install and use the latest version.' `
                        -Recommendation 'Upgrade FSLogix to the latest release.' -Source $releaseSource -RequiresElevation $false
                }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'FSLogix install/version checks'
                New-FslResult -Category $category -Check 'FSLogix version' -Status 'Error' -Target $computerTarget -Message $_.Exception.Message -Source $definition.Sources.ReleaseNotes -RequiresElevation $false
            }

            # Services
            foreach ($service in @($installation.Services)) {
                try {
                    $check = "FSLogix service $($service.Name)"
                    if (-not $installation.IsInstalled) {
                        New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $service.Name -Message 'FSLogix is not installed.' -Source $definition.Sources.Components -RequiresElevation $false
                    }
                    elseif ($service.Status -eq 'Running') {
                        New-FslResult -Category $category -Check $check -Status 'Pass' -Target $service.Name -Value "Running (StartType $($service.StartType))" -Expected 'Running (Startup type: Automatic)' `
                            -Message "$($service.DisplayName) is running." -Source $definition.Sources.Components -RequiresElevation $false
                    }
                    else {
                        $serviceStatus = if ($service.Critical) { 'Fail' } else { 'Warn' }
                        New-FslResult -Category $category -Check $check -Status $serviceStatus -Target $service.Name -Value $(if ($service.StartType) { "$($service.Status) (StartType $($service.StartType))" } else { [string]$service.Status }) `
                            -Expected 'Running (Startup type: Automatic)' -Message "$($service.DisplayName) is not running." `
                            -Recommendation 'Start the service and review FSLogix event logs; reinstall or upgrade FSLogix if the service is missing or crashing.' `
                            -Source $definition.Sources.Services -RequiresElevation $false
                    }
                }
                catch {
                    Add-FslError -ErrorRecord $_ -Component 'Environment' -Context "Service check $($service.Name)"
                }
            }

            # Drivers (identified by documented driver file name; see Find-FslInstallation)
            foreach ($driver in @($installation.Drivers)) {
                try {
                    $driverFile = if ($driver.PSObject.Properties['FileName'] -and $driver.FileName) { [string]$driver.FileName } else { [string]$driver.Name }
                    $check = "FSLogix driver $driverFile"
                    if (-not $installation.IsInstalled) {
                        New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $driverFile -Message 'FSLogix is not installed.' -Source $definition.Sources.Components -RequiresElevation $false
                    }
                    elseif ($null -eq $driver.Exists) {
                        New-FslResult -Category $category -Check $check -Status 'Error' -Target $driverFile -Value 'Unknown' -Expected 'Running' `
                            -Message 'Unable to query Win32_SystemDriver; the driver state is unknown.' -Source $definition.Sources.SystemDriver -RequiresElevation $false
                    }
                    elseif ($driver.State -eq 'Running') {
                        New-FslResult -Category $category -Check $check -Status 'Pass' -Target $driverFile -Value "Running (driver service '$($driver.Name)', StartMode $($driver.StartMode))" -Expected 'Running' `
                            -Message "$($driver.Description) is loaded ($($driver.PathName))." -Source $definition.Sources.Components -RequiresElevation $false
                    }
                    elseif (-not $driver.Exists) {
                        New-FslResult -Category $category -Check $check -Status 'Warn' -Target $driverFile -Value 'Not detected' -Expected 'Running' `
                            -Message "No system driver whose Win32_SystemDriver PathName ends with $driverFile was found ($($driver.Description))." `
                            -Recommendation 'Verify the FSLogix installation and antivirus exclusions for FSLogix driver files; reinstall FSLogix if the driver is missing.' `
                            -Source $definition.Sources.SystemDriver -RequiresElevation $false
                    }
                    else {
                        New-FslResult -Category $category -Check $check -Status 'Warn' -Target $driverFile -Value "$($driver.State) (driver service '$($driver.Name)')" -Expected 'Running' `
                            -Message "$($driver.Description) is not running." `
                            -Recommendation 'Verify the FSLogix installation and antivirus exclusions for FSLogix driver files; reinstall FSLogix if the driver is missing.' `
                            -Source $definition.Sources.Components -RequiresElevation $false
                    }
                }
                catch {
                    Add-FslError -ErrorRecord $_ -Component 'Environment' -Context "Driver check $($driver.Name)"
                }
            }
        }
    }

    # ---------------- Elevation ----------------
    try {
        $elevated = [bool](Test-FslElevation)
        New-FslResult -Category $category -Check 'Elevation' -Status 'Info' -Target $computerTarget -Value $(if ($elevated) { 'Elevated' } else { 'Standard user' }) `
            -Message $(if ($elevated) { 'Running elevated; all checks can run.' } else { 'Running as a standard user; checks that need administrator rights return Skipped.' }) `
            -Source 'Toolkit default' -RequiresElevation $false
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'Test-FslElevation'
        New-FslResult -Category $category -Check 'Elevation' -Status 'Error' -Target $computerTarget -Message $_.Exception.Message -Source 'Toolkit default' -RequiresElevation $false
    }
}
