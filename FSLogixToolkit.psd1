@{
    RootModule           = 'FSLogixToolkit.psm1'
    ModuleVersion        = '0.3.0'
    GUID                 = '6f1d7c5e-2b8a-4d0e-9a51-3c7e2f9b8d41'
    Author               = 'FSLogixToolkit contributors'
    Description          = 'FSLogix Office (ODFC) and profile container health, discovery (image, registry, GPO), best-practice analysis, storage/network diagnostics, daily health checks, maintenance and reporting with a menu-driven WPF dashboard.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        # Core
        'Initialize-FslSession', 'Initialize-FslPrerequisites', 'Get-FslErrorLog', 'Export-FslErrorLog', 'Test-FslElevation'
        'Get-FslPreference', 'Set-FslPreference', 'Get-FslContainerMode', 'Test-FslToolkitPathSecurity'
        # Repair
        'Get-FslRepairPlan', 'Test-FslRepairPrerequisite', 'Invoke-FslRepair', 'Undo-FslRepair', 'Get-FslRepairLog'
        # Discovery
        'Get-FslDiscovery', 'Get-FslDiscoveryReport'
        # Daily
        'Invoke-FslDailyHealthCheck', 'Get-FslDailyHistory', 'Register-FslDailyHealthCheck', 'Unregister-FslDailyHealthCheck', 'Get-FslDailyHealthCheck'
        # Environment
        'Find-FslInstallation', 'Get-FslLatestVersionInfo', 'Get-FslEnvironment'
        # Policy
        'Get-FslEffectiveSetting', 'Get-FslGpoReport', 'Get-FslStorageLocation'
        # BestPractice
        'Invoke-FslBestPracticeAnalyzer'
        # Containers
        'Get-FslContainer', 'Get-FslContainerReport'
        # Performance
        'Test-FslStoragePerformance'
        # Network
        'Test-FslNetworkHealth'
        # Maintenance
        'Invoke-FslContainerShrink', 'Remove-FslStaleContainer'
        # Diagnostics
        'Get-FslLogSummary', 'Get-FslKnownIssue', 'Export-FslDiagnosticBundle'
        # Reporting / GUI
        'Invoke-FslHealthCheck', 'Export-FslReport', 'Show-FslDashboard'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags = @('FSLogix', 'AVD', 'VDI', 'ProfileContainer', 'Windows')
        }
    }
}
