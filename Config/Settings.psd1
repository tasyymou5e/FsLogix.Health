# FSLogixToolkit settings. All thresholds below are TOOLKIT DEFAULTS (not Microsoft guidance) - tune per environment.
@{
    Toolkit     = @{
        ContainerMode               = 'ODFC'               # ODFC (Office containers only - default) | Profiles | Both
        AutoDiscoverOnStartup       = $true
        AutoRunHealthCheckOnStartup = $true
        AutoRefreshMinutes          = 0                    # 0 = off; GUI periodic re-check interval
        Offline                     = $false
        PreferenceFileName          = 'preferences.json'   # under LocalApplicationData\FSLogixToolkit
    }
    Daily       = @{
        TaskName   = 'FSLogixToolkit Daily Health Check'
        TaskPath   = '\FSLogixToolkit\'
        Time       = '06:00'
        RunAs      = 'System'      # System (requires elevation to register) | CurrentUser
        FolderName = 'Daily'       # under ReportRoot
        RetainDays = 30
        Formats    = 'Both'        # Csv | Html | Both
    }
    Repair      = @{
        FolderName                = 'Repair'                                    # readable log copies under ReportRoot
        StateRoot                 = '%ProgramData%\FSLogixToolkit\RepairState'  # authoritative rollback store (admin-only ACL)
        RetainDays                = 180
        MaxRiskTierDefault        = 2
        RequireChangeReferenceTier = 3                                          # tiers >= this require -ChangeReference
        PlanMaxAgeMinutes         = 60
        MinFreeSpaceMB            = 1024
        TemporaryLoggingMaxHours  = 24
        ContainerArchivePath      = ''                                          # default archive for Office container reset (UNC or local); empty = must be supplied
    }
    RunAs       = @{
        SmartCardByDefault = $true    # 'Relaunch as different user' uses runas.exe /smartcard
        PassReportRoot     = $true    # pass the current ReportRoot to the relaunched session (different user profile)
    }
    Paths       = @{
        LogFolderName    = 'Logs'
        ReportFolderName = 'Reports'
        FallbackFolder   = 'FSLogixToolkit'   # under LocalApplicationData when module folder is not writable
    }
    Logging     = @{
        RetainDays   = 30
        DebugLogging = $false
    }
    Environment = @{
        MinimumWindowsBuild      = 26100      # Windows 11 24H2 / Windows Server 2025
        MinimumPowerShellVersion = '7.4'
        PowerShellReleaseApi     = 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
        OnlineTimeoutSec         = 10
    }
    Containers  = @{
        Extensions       = @('.vhd', '.vhdx')
        StaleDays        = 90
        PercentOfMaxWarn = 80
        PercentOfMaxFail = 95
    }
    Performance = @{
        SampleSeconds   = 10
        LatencyMsWarn   = 20
        LatencyMsFail   = 50
        WriteTestSizeMB = 64
    }
    Network     = @{
        SmbPort          = 445
        HttpsPort        = 443
        TimeoutMs        = 3000
        TcpLatencyMsWarn = 30
        TcpLatencyMsFail = 100
    }
    Maintenance = @{
        ShrinkMinimumSizeGB  = 5
        ShrinkDaysSinceWrite = 0
    }
    Diagnostics = @{
        LogDays   = 7
        MaxEvents = 500
    }
}
