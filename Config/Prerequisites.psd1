# FSLogixToolkit prerequisite modules (consumed by Initialize-FslPrerequisites).
# Only modules whose commands the toolkit code actually calls are listed (DnsClient, NetTCPIP and GroupPolicy were
# removed: Network uses System.Net.Dns / System.Net.Sockets.TcpClient and Policy uses gpresult.exe).
# Keys per entry:
#   Name               Module name as reported by Get-Module.
#   MinimumVersion     Minimum module version or $null (no toolkit minimum - none invented).
#   Required           $true = the areas in UsedBy cannot run without it (missing -> Fail).
#   Source             BuiltIn | PSGallery | WindowsCapability | WindowsFeature. Only PSGallery modules are ever
#                      downloaded (Initialize-FslPrerequisites -AllowInstall, Start-FSLogixToolkit.ps1 -DownloadModules).
#   InboxWindowsModule $true = ships in the Windows PowerShell module folder (%windir%\system32\WindowsPowerShell\v1.0\Modules);
#                      imported from there by manifest path when it is not on PSModulePath.
#   UsedBy             Toolkit areas that call commands from the module.
#   Fallback           What the toolkit does without the module (string), or $null when there is no fallback.
#                      Optional + Fallback -> Info; optional without Fallback -> Warn.
#   InstallHint        Human guidance. Windows features/capabilities are NEVER auto-installed.
#   Windows            $true = Windows-only module (reported as Skipped on other platforms).
#   Reference          Verification source (learn.microsoft.com / github.com/PowerShell).
#   Notes              Optional extra facts surfaced in the result message.
@{
    Modules = @(
        @{
            # Install-PSResource / Save-PSResource. Ships with PowerShell 7.4 and later.
            Name               = 'Microsoft.PowerShell.PSResourceGet'
            MinimumVersion     = $null
            Required           = $false
            Source             = 'BuiltIn'
            InboxWindowsModule = $false
            UsedBy             = @('Core (module downloads)')
            Fallback           = 'Health checks do not need it; only downloading PowerShell Gallery modules (-AllowInstall / -DownloadModules) needs it (Install-Module is used for CurrentUser installs when available).'
            InstallHint        = 'Included with PowerShell 7.4 and later. Repair or update PowerShell 7 if missing.'
            Windows            = $false
            Reference          = 'https://learn.microsoft.com/powershell/gallery/powershellget/install-powershellget'
            Notes              = $null
        }
        @{
            # Get-CimInstance (Environment, Discovery, Policy). "Built into PowerShell 7".
            Name               = 'CimCmdlets'
            MinimumVersion     = $null
            Required           = $true
            Source             = 'BuiltIn'
            InboxWindowsModule = $false
            UsedBy             = @('Environment', 'Discovery', 'Policy')
            Fallback           = $null
            InstallHint        = 'Included with PowerShell 7 on Windows ($PSHOME\Modules). Repair or reinstall PowerShell 7 if missing.'
            Windows            = $true
            Reference          = 'https://learn.microsoft.com/powershell/windows/module-compatibility'
            Notes              = $null
        }
        @{
            # Get-Counter (Performance) / Get-WinEvent (Diagnostics). Ships with PowerShell 7 on Windows.
            Name               = 'Microsoft.PowerShell.Diagnostics'
            MinimumVersion     = $null
            Required           = $true
            Source             = 'BuiltIn'
            InboxWindowsModule = $false
            UsedBy             = @('Performance', 'Diagnostics')
            Fallback           = $null
            InstallHint        = 'Included with PowerShell 7 on Windows ($PSHOME\Modules). Repair or reinstall PowerShell 7 if missing.'
            Windows            = $true
            Reference          = 'https://learn.microsoft.com/powershell/module/microsoft.powershell.diagnostics/get-counter'
            Notes              = $null
        }
        @{
            # Mount-DiskImage / Dismount-DiskImage / Get-DiskImage (Invoke-FslContainerShrink). Natively compatible.
            Name               = 'Storage'
            MinimumVersion     = $null
            Required           = $false
            Source             = 'BuiltIn'
            InboxWindowsModule = $true
            UsedBy             = @('Maintenance (container shrink)')
            Fallback           = $null
            InstallHint        = 'Inbox Windows module (Windows 10/Server 1809 and later); not available from the PowerShell Gallery. If it is not found, check that %SystemRoot%\system32\WindowsPowerShell\v1.0\Modules is on PSModulePath.'
            Windows            = $true
            Reference          = 'https://learn.microsoft.com/powershell/windows/module-compatibility'
            Notes              = $null
        }
        @{
            # Get-SmbConnection / Get-SmbClientNetworkInterface (Test-FslNetworkHealth, guarded by Get-Command). Natively compatible.
            Name               = 'SmbShare'
            MinimumVersion     = $null
            Required           = $false
            Source             = 'BuiltIn'
            InboxWindowsModule = $true
            UsedBy             = @('Network (SMB connection details)')
            Fallback           = 'Network health still checks DNS resolution and TCP 445 reachability/latency; only SMB connection details (dialect, signing, encryption, client interfaces) are skipped.'
            InstallHint        = 'Inbox Windows module (Windows 10/Server 1809 and later); not available from the PowerShell Gallery. If it is not found, check that %SystemRoot%\system32\WindowsPowerShell\v1.0\Modules is on PSModulePath.'
            Windows            = $true
            Reference          = 'https://learn.microsoft.com/powershell/windows/module-compatibility'
            Notes              = $null
        }
        @{
            # Register-/Unregister-/Get-/Export-ScheduledTask, New-ScheduledTask* (daily schedule). Natively compatible.
            Name               = 'ScheduledTasks'
            MinimumVersion     = $null
            Required           = $false
            Source             = 'BuiltIn'
            InboxWindowsModule = $true
            UsedBy             = @('Daily (schedule register/view/remove)')
            Fallback           = $null
            InstallHint        = 'Inbox Windows module (Windows 10/Server 1809 and later); not available from the PowerShell Gallery. If it is not found, check that %SystemRoot%\system32\WindowsPowerShell\v1.0\Modules is on PSModulePath.'
            Windows            = $true
            Reference          = 'https://learn.microsoft.com/powershell/windows/module-compatibility'
            Notes              = $null
        }
        @{
            # Optimize-VHD (Invoke-FslContainerShrink, optional). Natively compatible when the feature is installed.
            Name               = 'Hyper-V'
            MinimumVersion     = $null
            Required           = $false
            Source             = 'WindowsFeature'
            InboxWindowsModule = $true
            UsedBy             = @('Maintenance (container shrink)')
            Fallback           = 'Invoke-FslContainerShrink compacts containers with diskpart (compact vdisk) instead of Optimize-VHD.'
            InstallHint        = 'Optional. Windows client (elevated): Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell. Windows Server: Install-WindowsFeature -Name Hyper-V-PowerShell. Not available from the PowerShell Gallery and not auto-installed by the toolkit.'
            Windows            = $true
            Reference          = 'https://learn.microsoft.com/powershell/windows/module-compatibility'
            Notes              = $null
        }
        @{
            # Development only - used by Tests/Invoke-FslValidation.ps1.
            Name               = 'PSScriptAnalyzer'
            MinimumVersion     = $null
            Required           = $false
            Source             = 'PSGallery'
            InboxWindowsModule = $false
            UsedBy             = @('Development (Tests/Invoke-FslValidation.ps1)')
            Fallback           = 'Health checks do not use it; only the development validator (Tests/Invoke-FslValidation.ps1) needs it.'
            InstallHint        = 'Start-FSLogixToolkit.ps1 -DownloadModules (saves it to the project Modules folder) or Initialize-FslPrerequisites -Name PSScriptAnalyzer -AllowInstall.'
            Windows            = $false
            Reference          = 'https://github.com/PowerShell/PSScriptAnalyzer'
            Notes              = $null
        }
    )
}
