function Initialize-FslSession {
    <#
    .SYNOPSIS
        Initializes the toolkit session: log and report folders, log file, debug logging and log retention.
    .DESCRIPTION
        Resolves LogRoot and ReportRoot. Defaults are <ModuleRoot>/Logs and <ModuleRoot>/Reports when those
        folders are writable (tested by creating and removing a temporary file); otherwise
        <LocalApplicationData>/FSLogixToolkit/Logs|Reports ($env:LOCALAPPDATA on Windows,
        [Environment]::GetFolderPath('LocalApplicationData') elsewhere). If that is not writable either, the
        user temp folder is used as a last resort. Folder names come from Settings.psd1 (Paths section).
        Creates the log file FSLogixToolkit_yyyyMMdd_HHmmss.log, deletes toolkit log files older than
        Logging.RetainDays (toolkit default 30; 0 or less disables pruning) and sets DebugLogging from
        -EnableDebugLogging or Logging.DebugLogging.
        Prepends <ModuleRoot>/Modules (the project Modules folder, when it exists) to the process $env:PSModulePath once
        and stores it in the session as ModulesRoot.
        If the session is already initialized it is returned unchanged unless -Force or any of -LogRoot,
        -ReportRoot or -EnableDebugLogging is specified. Errors are recorded, not thrown.
    .PARAMETER LogRoot
        Folder for toolkit log files. Created if missing.
    .PARAMETER ReportRoot
        Folder for reports and exports. Created if missing.
    .PARAMETER EnableDebugLogging
        Writes Debug level lines to the log file.
    .PARAMETER Force
        Re-initializes an already initialized session (starts a new log file).
    .EXAMPLE
        Initialize-FslSession

        Initializes the session with default folders and returns the session information.
    .EXAMPLE
        Initialize-FslSession -LogRoot D:\FslToolkit\Logs -ReportRoot D:\FslToolkit\Reports -EnableDebugLogging

        Uses custom folders and enables debug logging.
    .NOTES
        RequiresElevation: No
        Sources:
          https://learn.microsoft.com/dotnet/api/system.environment.getfolderpath
          https://learn.microsoft.com/dotnet/api/system.environment.specialfolder
          https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_psmodulepath
          Retention days and folder names: Toolkit default (Config/Settings.psd1).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string] $LogRoot,

        [ValidateNotNullOrEmpty()]
        [string] $ReportRoot,

        [switch] $EnableDebugLogging,

        [switch] $Force
    )

    $reinitRequested = $Force.IsPresent -or $PSBoundParameters.ContainsKey('LogRoot') -or
        $PSBoundParameters.ContainsKey('ReportRoot') -or $EnableDebugLogging.IsPresent

    if ($script:FslSession['Initialized'] -and -not $reinitRequested) {
        return (Get-FslCoreSessionInfo)
    }

    $script:FslCoreInitializing = $true
    $script:FslCoreInitAttempted = $true
    try {
        $paths = Get-FslConfig -Section 'Paths'
        $logging = Get-FslConfig -Section 'Logging'

        $logFolderName = if ($paths['LogFolderName']) { [string]$paths['LogFolderName'] } else { 'Logs' }
        $reportFolderName = if ($paths['ReportFolderName']) { [string]$paths['ReportFolderName'] } else { 'Reports' }
        $fallbackFolder = if ($paths['FallbackFolder']) { [string]$paths['FallbackFolder'] } else { 'FSLogixToolkit' }

        $moduleRoot = [string]$script:FslSession['ModuleRoot']
        $localAppData = $null
        if (Test-FslIsWindows) { $localAppData = $env:LOCALAPPDATA }
        if ([string]::IsNullOrEmpty($localAppData)) {
            $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        }

        $resolvedLogRoot = Resolve-FslCoreWritableFolder -Preferred $LogRoot -ModuleRoot $moduleRoot -FolderName $logFolderName -LocalAppData $localAppData -FallbackFolder $fallbackFolder
        $resolvedReportRoot = Resolve-FslCoreWritableFolder -Preferred $ReportRoot -ModuleRoot $moduleRoot -FolderName $reportFolderName -LocalAppData $localAppData -FallbackFolder $fallbackFolder

        $debugLogging = $false
        if ($EnableDebugLogging.IsPresent) { $debugLogging = $true }
        elseif ($logging.ContainsKey('DebugLogging')) { $debugLogging = [bool]$logging['DebugLogging'] }

        $script:FslSession['LogRoot'] = $resolvedLogRoot
        $script:FslSession['ReportRoot'] = $resolvedReportRoot
        $script:FslSession['DebugLogging'] = $debugLogging
        $script:FslSession['LogPath'] = $null
        if (-not [string]::IsNullOrEmpty($resolvedLogRoot)) {
            $logName = 'FSLogixToolkit_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
            $script:FslSession['LogPath'] = Join-Path -Path $resolvedLogRoot -ChildPath $logName
        }
        $script:FslSession['Initialized'] = $true

        # Project Modules folder first on the process PSModulePath (no-op when the folder is missing).
        $null = Add-FslCoreLocalModulePath -Path (Join-Path -Path $moduleRoot -ChildPath 'Modules')
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Initialize-FslSession'
    }
    finally {
        $script:FslCoreInitializing = $false
    }

    if ($script:FslSession['Initialized']) {
        $retainDays = 30
        try {
            $loggingSection = Get-FslConfig -Section 'Logging'
            if ($loggingSection.ContainsKey('RetainDays')) { $retainDays = [int]$loggingSection['RetainDays'] }
        }
        catch { Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Reading Logging.RetainDays' }

        Remove-FslCoreOldLog -LogRoot $script:FslSession['LogRoot'] -RetainDays $retainDays -CurrentLogPath $script:FslSession['LogPath']

        Write-FslLog -Message ('Session initialized. LogRoot={0}; ReportRoot={1}; DebugLogging={2}; PowerShell={3}; IsWindows={4}' -f $script:FslSession['LogRoot'], $script:FslSession['ReportRoot'], $script:FslSession['DebugLogging'], $PSVersionTable.PSVersion, (Test-FslIsWindows)) -Level Info -Component 'Core'
        if ([string]::IsNullOrEmpty($script:FslSession['LogPath'])) {
            Write-FslLog -Message 'No writable log folder found - file logging disabled for this session.' -Level Warning -Component 'Core'
        }
    }

    return (Get-FslCoreSessionInfo)
}
