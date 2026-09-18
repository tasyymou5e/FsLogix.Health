# FSLogixToolkit known version data (offline fallback for Get-FslLatestVersionInfo / Get-FslEnvironment).
# Every value below was read from the Source URL on DataVerifiedOn. Update this file when new releases ship.
@{
    DataVerifiedOn = '2026-09-17'

    # Source: https://learn.microsoft.com/en-us/fslogix/overview-release-notes (latest release first)
    FSLogix        = @(
        @{
            Version     = '26.08'
            Build       = '3.26.826.17182'
            ReleaseName = 'FSLogix 26.08'
            ReleaseDate = '2026-08-31'
            Source      = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
        }
        @{
            Version     = '26.01 CU1'
            Build       = '3.26.126.19110'
            ReleaseName = 'FSLogix 26.01 CU1 (critical update)'
            ReleaseDate = '2026-02-10'
            Source      = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
        }
        @{
            Version     = '26.01'
            Build       = '3.26.102.18413'
            ReleaseName = 'FSLogix 26.01'
            ReleaseDate = '2026-01-13'
            Source      = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
        }
        @{
            Version     = '25.09'
            Build       = '3.25.822.19044'
            ReleaseName = 'FSLogix 25.09'
            ReleaseDate = '2025-09-09'
            Source      = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
        }
        @{
            Version     = '25.06'
            Build       = '3.25.626.21064'
            ReleaseName = 'FSLogix 25.06'
            ReleaseDate = '2025-07-08'
            Source      = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
        }
        @{
            Version     = '25.04'
            Build       = '3.25.401.15305'
            ReleaseName = 'FSLogix 25.04'
            ReleaseDate = '2025-04-08'
            Source      = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
        }
        @{
            Version     = '25.02'
            Build       = '3.25.202.4223'
            ReleaseName = 'FSLogix 25.02'
            ReleaseDate = '2025-02-11'
            Source      = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
        }
        @{
            Version     = '2210 hotfix 4'
            Build       = '2.9.8884.27471'
            ReleaseName = 'FSLogix 2210 hotfix 4'
            ReleaseDate = '2024-05-14'
            Source      = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
        }
    )

    PowerShell     = @{
        # Source: GitHub releases API /releases/latest (non-prerelease, non-draft) returned tag v7.6.6, published_at 2026-09-08T20:28:01Z
        LatestStable   = '7.6.6'
        Published      = '2026-09-08'
        Source         = 'https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6'
        # Source: https://learn.microsoft.com/en-us/powershell/scripting/install/powershell-support-lifecycle
        SupportedLines = @(
            @{
                Line         = '7.6'
                ReleaseType  = 'LTS'
                ReleaseDate  = '2026-03-18'
                EndOfSupport = '2028-11-14'
                DotNet       = '.NET 10.0'
                Source       = 'https://learn.microsoft.com/en-us/powershell/scripting/install/powershell-support-lifecycle'
            }
            @{
                Line         = '7.5'
                ReleaseType  = 'Stable'
                ReleaseDate  = '2025-01-23'
                EndOfSupport = '2026-11-10'
                DotNet       = '.NET 9.0'
                Source       = 'https://learn.microsoft.com/en-us/powershell/scripting/install/powershell-support-lifecycle'
            }
            @{
                Line         = '7.4'
                ReleaseType  = 'LTS'
                ReleaseDate  = '2023-11-16'
                EndOfSupport = '2026-11-10'
                DotNet       = '.NET 8.0'
                Source       = 'https://learn.microsoft.com/en-us/powershell/scripting/install/powershell-support-lifecycle'
            }
        )
        # Retired lines (same source): 7.3 EOS 2024-05-08, 7.2 LTS EOS 2024-11-08, 7.1 EOS 2022-05-08, 7.0 LTS EOS 2022-12-03
        RetiredLines   = @(
            @{ Line = '7.3'; EndOfSupport = '2024-05-08' }
            @{ Line = '7.2'; EndOfSupport = '2024-11-08' }
            @{ Line = '7.1'; EndOfSupport = '2022-05-08' }
            @{ Line = '7.0'; EndOfSupport = '2022-12-03' }
        )
    }

    Windows        = @{
        # Build -> version name. Build 26100 is shared by Windows 11 24H2 (client) and Windows Server 2025 (server).
        Builds       = @{
            '26100' = @{
                Client = 'Windows 11, version 24H2'
                Server = 'Windows Server 2025'
                Source = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information; https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info'
            }
            '26200' = @{
                Client = 'Windows 11, version 25H2'
                Source = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information'
            }
            '28000' = @{
                Client = 'Windows 11, version 26H1'
                Source = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information'
            }
            '22631' = @{
                Client = 'Windows 11, version 23H2'
                Source = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information'
            }
            '22621' = @{
                Client = 'Windows 11, version 22H2'
                Source = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information'
            }
            '22000' = @{
                Client = 'Windows 11, version 21H2'
                Source = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information'
            }
        }
    }
}
