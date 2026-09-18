# FSLogixToolkit known issues data (owned by Diagnostics).
# Every entry is traceable to text read on the Source URL on DataVerifiedOn.
# Matching rules used by Get-FslKnownIssue:
#   - AffectedFrom / AffectedTo are inclusive FSLogix build versions; $null means unbounded on that side.
#   - FixedIn is the first build whose release notes (FixedInSource) state the fix; versions >= FixedIn never match.
#   - AffectedFrom and AffectedTo both $null means the source does not bound the range (for example
#     "All versions", or a fix listed in release notes without stating affected versions).
#   - Severity is a toolkit classification (Fail = sign-in/profile failure, data loss, crash or security;
#     Warn = functional issue; Info = informational/expected behaviour). It is not a Microsoft rating.
#   - Scope (General|Profiles|ODFC|CloudCache) is tagged ONLY from the Source text (verified 2026-09-17): an entry is
#     Profiles/ODFC/CloudCache only when the source text clearly limits the issue to profile containers, ODFC
#     containers or Cloud Cache; otherwise General. Get-FslKnownIssue always includes General and CloudCache entries.
#     ODFC:     FSL-KI-001 ("ODFC VHD(x) containers won't be created or mounted"), FSL-KI-007 ("ODFC settings ...
#               aren't applied"), FSL-KI-020 ("ODFC disk compaction fails"), FSL-KI-027 ("...enabled with ODFC containers").
#     Profiles: FSL-KI-013 ("UWP folders inside the user's profile container"), FSL-KI-019 ("the user's profile
#               container failing to attach").
@{
    DataVerifiedOn = '2026-09-17'
    Issues         = @(
        @{
            Id            = 'FSL-KI-001'
            Title         = 'ODFC VHD(x) containers are not created or mounted when CleanupInvalidSessions is enabled'
            Description   = 'When Profiles and ODFC are enabled with CleanupInvalidSessions, FSLogix fails to create or mount the ODFC VHD(x) container. Microsoft state: Fixed. Affected version: 26.01 (3.26.102.18413). Fixed in 26.01 CU1 (3.26.126.19110).'
            AffectedFrom  = '3.26.102.18413'
            AffectedTo    = '3.26.102.18413'
            FixedIn       = '3.26.126.19110'
            Workaround    = 'Mitigation: disable CleanupInvalidSessions. Resolution: install the latest FSLogix version.'
            Severity      = 'Fail'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'ODFC'
        }
        @{
            Id            = 'FSL-KI-002'
            Title         = 'Devices that are only Entra joined see an increase in Event Log errors (Event ID 26)'
            Description   = 'Affected version(s): All versions. State: In progress. Application rule sets query a Domain Controller using LDAP; on devices that are only Microsoft Entra joined this check fails, resulting in two Event ID 26 errors in Microsoft-FSLogix-Apps/Operational. These errors are expected even without rule sets and can be safely ignored.'
            AffectedFrom  = $null
            AffectedTo    = $null
            FixedIn       = $null
            Workaround    = 'The errors can be safely ignored. Microsoft plan to address this in a future release.'
            Severity      = 'Info'
            State         = 'In progress'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = $null
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-003'
            Title         = 'RSOP or GPResult /R fails to find data when signing into the same virtual machine between sessions'
            Description   = 'Affected version(s): 2210 hotfix 4 (2.9.8884.27471) or later. State: In progress. User-based policies are still processed and applied but cannot be rendered by RSOP/GPResult when the user signs into the same virtual machine between sessions.'
            AffectedFrom  = '2.9.8884.27471'
            AffectedTo    = $null
            FixedIn       = $null
            Workaround    = 'Microsoft plan to address this in a future release.'
            Severity      = 'Info'
            State         = 'In progress'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = $null
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-004'
            Title         = 'OneDrive is intermittently stuck at signing in on Windows Server 2019'
            Description   = 'Affected version(s): 2210 hotfix 4 (2.9.8884.27471) or later. State: In progress. Applies to Windows Server 2019: the OneDrive sync client intermittently gets stuck at signing in and fails to complete sign in.'
            AffectedFrom  = '2.9.8884.27471'
            AffectedTo    = $null
            FixedIn       = $null
            Workaround    = 'Microsoft plan to address this in a future release.'
            Severity      = 'Info'
            State         = 'In progress'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = $null
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-005'
            Title         = 'Nonroamable identity registry locations are not removed during sign out'
            Description   = 'Affected version(s): 25.09 (3.25.822.19044) and previous versions. State: Fixed. The recommended exclusions for identity data, which include several registry locations, were not properly removed during user sign out.'
            AffectedFrom  = $null
            AffectedTo    = '3.25.822.19044'
            FixedIn       = $null
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = $null
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-006'
            Title         = 'Incorrect file name displayed when emptying the Recycle Bin with only a single item in it'
            Description   = 'Affected version(s): 25.02 (3.25.202.4223), 25.04 (3.25.401.15305). State: Fixed. When the Recycle Bin is redirected to the container and holds a single item, the item name is not displayed correctly and the Recycle Bin cannot be emptied. The 25.09 (3.25.822.19044) release notes list the fix.'
            AffectedFrom  = '3.25.202.4223'
            AffectedTo    = '3.25.401.15305'
            FixedIn       = '3.25.822.19044'
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-007'
            Title         = 'ODFC settings applied after ProfileLoad during sign in are not applied to the user'
            Description   = 'Affected version(s): 25.02 (3.25.202.4223), 25.04 (3.25.401.15305). State: Fixed. With a third-party profile solution where ODFC settings are applied as part of the sign in flow, the ODFC settings are read before StartShell and are not applied to the signed in user.'
            AffectedFrom  = '3.25.202.4223'
            AffectedTo    = '3.25.401.15305'
            FixedIn       = $null
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = $null
            Scope         = 'ODFC'
        }
        @{
            Id            = 'FSL-KI-008'
            Title         = 'FSLogix containers do not detach and prevent users from signing into a new session'
            Description   = 'Affected version(s): 25.02 (3.25.202.4223). State: Fixed. Unhandled exceptions broke the code flow that detaches a container. Listed as fixed in 25.04 (3.25.401.15305).'
            AffectedFrom  = '3.25.202.4223'
            AffectedTo    = '3.25.202.4223'
            FixedIn       = '3.25.401.15305'
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Fail'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-009'
            Title         = 'FSLogix Rules do not apply to users as expected'
            Description   = 'Affected version(s): 25.02 (3.25.202.4223). State: Fixed. Users were not correctly assigned to rules, so rules did not work as expected. Listed as fixed in 25.04 (3.25.401.15305).'
            AffectedFrom  = '3.25.202.4223'
            AffectedTo    = '3.25.202.4223'
            FixedIn       = '3.25.401.15305'
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-010'
            Title         = 'FRXShell rule fails clean up and prevents all user sign ins'
            Description   = 'Affected version(s): 25.02 (3.25.202.4223). State: Fixed. Under some situations the FRXShell rule applied to all users, preventing sign in. Listed as fixed in 25.04 (3.25.401.15305).'
            AffectedFrom  = '3.25.202.4223'
            AffectedTo    = '3.25.202.4223'
            FixedIn       = '3.25.401.15305'
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Fail'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-011'
            Title         = 'After signing in, user receives an error message that the Recycle Bin is corrupted'
            Description   = 'Affected version(s): 25.02 (3.25.202.4223). State: Fixed. Users intermittently received a "Recycle Bin is corrupted" notification because the Recycle Bin within the profile VHD could not be accessed. Listed as fixed in 25.04 (3.25.401.15305).'
            AffectedFrom  = '3.25.202.4223'
            AffectedTo    = '3.25.202.4223'
            FixedIn       = '3.25.401.15305'
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-012'
            Title         = 'Searchindexer.exe (frx_usermode_x64.dll) crashing in Windows Server 2016'
            Description   = 'Affected version(s): 25.02 (3.25.202.4223). State: Fixed. Applies to Windows Server 2016: an updated call to Windows Search / Outlook Cached Mode components caused Searchindexer.exe to crash. Listed as fixed in 25.04 (3.25.401.15305).'
            AffectedFrom  = '3.25.202.4223'
            AffectedTo    = '3.25.202.4223'
            FixedIn       = '3.25.401.15305'
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-013'
            Title         = 'LocalCache and TempState folders are not properly cleaned up during sign out'
            Description   = 'Affected version(s): 2210 hotfix 4 (2.9.8884.27471). State: Fixed. LocalCache and TempState folders of UWP/MSIX packages were not deleted at sign out and may have an adverse effect when roamed between virtual machines (does not affect LocalCache for Microsoft Teams). The 25.02 (3.25.202.4223) release notes list the fix.'
            AffectedFrom  = '2.9.8884.27471'
            AffectedTo    = '2.9.8884.27471'
            FixedIn       = '3.25.202.4223'
            Workaround    = 'Create or update redirections.xml to exclude the package TempState folder. Resolution: install the latest FSLogix version.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'Profiles'
        }
        @{
            Id            = 'FSL-KI-014'
            Title         = 'New Microsoft Teams cannot launch on virtual desktops running Windows Server 2019'
            Description   = 'Affected version(s): 2210 hotfix 3 (2.9.8784.63912) and older. State: Fixed. Applies to Windows Server 2019: users are unable to launch or use new Microsoft Teams. The 2210 hotfix 4 (2.9.8884.27471) release notes list the fix.'
            AffectedFrom  = $null
            AffectedTo    = '2.9.8784.63912'
            FixedIn       = '2.9.8884.27471'
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-015'
            Title         = 'Enabled-by-default policies in the ADMX template cannot be disabled using Group Policy'
            Description   = 'Affected version(s): 2210 hotfix 2 (2.9.8612.60056) through 2210 hotfix 4 (2.9.8884.27471). State: Fixed. Selecting Disabled in the Group Policy template removes the setting instead of setting the registry value to 0. The 25.02 (3.25.202.4223) release notes list updated ADMX templates. This issue concerns the ADMX/ADML files in use, which may differ from the installed agent version.'
            AffectedFrom  = '2.9.8612.60056'
            AffectedTo    = '2.9.8884.27471'
            FixedIn       = '3.25.202.4223'
            Workaround    = 'Use a manual configuration option. Resolution: use the latest FSLogix ADMX / ADML files.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-016'
            Title         = 'Unexpected VHD disk compaction results with differencing disks'
            Description   = 'Affected version(s): 2210 (2.9.8361.52326) through 2210 hotfix 4 (2.9.8884.27471). State: Fixed. With ProfileType = 3 or VHDAccessMode = 1, 2 or 3, the size of the differencing disk is used to evaluate compaction thresholds, so compaction rarely runs. The 25.02 (3.25.202.4223) release notes list the fix.'
            AffectedFrom  = '2.9.8361.52326'
            AffectedTo    = '2.9.8884.27471'
            FixedIn       = '3.25.202.4223'
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-017'
            Title         = 'Microsoft Entra ID authentication prompts for applications at every sign-in'
            Description   = 'Affected version(s): 2210 (2.9.8361.52326). State: Fixed. Users might be required to authenticate to applications (Microsoft 365 apps, Teams, OneDrive) at every sign-in depending on the virtual machine Microsoft Entra join state.'
            AffectedFrom  = '2.9.8361.52326'
            AffectedTo    = '2.9.8361.52326'
            FixedIn       = $null
            Workaround    = 'Install the latest FSLogix version and configure RoamIdentity = 1 (registry or Group Policy).'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = $null
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-018'
            Title         = 'Black screen at sign-in or sihost.exe application hanging'
            Description   = 'Affected version(s): 2210 (2.9.8361.52326). State: Fixed. With RoamRecycleBin enabled (enabled by default), some users might see a black screen at sign-in while the recycle bin virtualization is configured.'
            AffectedFrom  = '2.9.8361.52326'
            AffectedTo    = '2.9.8361.52326'
            FixedIn       = $null
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Fail'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = $null
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-019'
            Title         = 'Service crash: user receives default or temporary profile'
            Description   = 'Affected version(s): 2210 (2.9.8361.52326). State: Fixed. With InstallAppxPackages enabled (enabled by default), frxsvc.exe can crash during sign-in so the profile container fails to attach.'
            AffectedFrom  = '2.9.8361.52326'
            AffectedTo    = '2.9.8361.52326'
            FixedIn       = $null
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Fail'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = $null
            Scope         = 'Profiles'
        }
        @{
            Id            = 'FSL-KI-020'
            Title         = 'ODFC disk compaction fails with RoamSearch enabled'
            Description   = 'Affected version(s): 2210 (2.9.8361.52326). State: Fixed. In some cases with RoamSearch and VHDCompactDisk enabled, compaction fails ("CoInitialize has not been called"), frxsvc.exe crashes and the operation fails.'
            AffectedFrom  = '2.9.8361.52326'
            AffectedTo    = '2.9.8361.52326'
            FixedIn       = $null
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = $null
            Scope         = 'ODFC'
        }
        @{
            Id            = 'FSL-KI-021'
            Title         = 'Windows Kerberos hardening (RC4 to AES-SHA1) may affect access to container file shares'
            Description   = 'Advisory (not version specific). Microsoft state that the April 2026 Windows Server update changes the default Kerberos encryption type from RC4 to AES-SHA1; file shares hosting FSLogix containers that are not upgraded to AES-SHA1 might have access issues. Customers already upgraded to AES-SHA1 are not affected.'
            AffectedFrom  = $null
            AffectedTo    = $null
            FixedIn       = $null
            Workaround    = 'Complete the upgrade of the storage account/file share to AES-SHA1 before installing the update.'
            Severity      = 'Warn'
            State         = 'Advisory'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'
            FixedInSource = $null
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-022'
            Title         = 'Security vulnerabilities in the FSLogix driver and service (fixed in 26.08)'
            Description   = 'FSLogix 26.08 release notes: addressed several security vulnerabilities in the FSLogix driver and service, including an elevation of privilege and kernel memory-safety issues. Affected versions are not stated; flagged for versions older than 26.08.'
            AffectedFrom  = $null
            AffectedTo    = $null
            FixedIn       = '3.26.826.17182'
            Workaround    = 'Install FSLogix 26.08 (3.26.826.17182) or later.'
            Severity      = 'Fail'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-023'
            Title         = 'Unlinking OneDrive during a session could lead to data loss (fixed in 26.08)'
            Description   = 'FSLogix 26.08 release notes: fixed an issue where unlinking OneDrive during a session could lead to data loss. Affected versions are not stated; flagged for versions older than 26.08.'
            AffectedFrom  = $null
            AffectedTo    = $null
            FixedIn       = '3.26.826.17182'
            Workaround    = 'Install FSLogix 26.08 (3.26.826.17182) or later.'
            Severity      = 'Fail'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-024'
            Title         = 'OneDrive cloud-only placeholder files could be corrupted during container mirror-back (fixed in 26.08)'
            Description   = 'FSLogix 26.08 release notes: fixed an issue where OneDrive cloud-only placeholder files could be corrupted during container mirror-back, causing sync errors or a sync client crash loop. Affected versions are not stated; flagged for versions older than 26.08.'
            AffectedFrom  = $null
            AffectedTo    = $null
            FixedIn       = '3.26.826.17182'
            Workaround    = 'Install FSLogix 26.08 (3.26.826.17182) or later.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-025'
            Title         = 'Bugchecks (Stop codes 0x139, 0x50, APC_INDEX_MISMATCH) (fixed in 26.08)'
            Description   = 'FSLogix 26.08 release notes: fixed multiple issues that could cause a bugcheck (Stop Codes: 0x139, 0x50, and APC_INDEX_MISMATCH), and a driver crash during redirection setup when a container filename allocation failed. Affected versions are not stated; flagged for versions older than 26.08.'
            AffectedFrom  = $null
            AffectedTo    = $null
            FixedIn       = '3.26.826.17182'
            Workaround    = 'Install FSLogix 26.08 (3.26.826.17182) or later.'
            Severity      = 'Fail'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-026'
            Title         = 'A locked or unresponsive container could block all sign-ins and sign-outs on a host until reboot (fixed in 26.08)'
            Description   = 'FSLogix 26.08 release notes: fixed an issue where a locked or unresponsive container could block all sign-ins and sign-outs on a host until reboot (with improved retry handling for locked container files), and an issue where a stuck storage provider could hang sign-out and leave containers attached. Affected versions are not stated; flagged for versions older than 26.08.'
            AffectedFrom  = $null
            AffectedTo    = $null
            FixedIn       = '3.26.826.17182'
            Workaround    = 'Install FSLogix 26.08 (3.26.826.17182) or later.'
            Severity      = 'Fail'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-027'
            Title         = 'Long sign-out delays with CleanupInvalidSessions and ODFC containers (fixed in 26.08)'
            Description   = 'FSLogix 26.08 release notes: fixed a deadlock that could cause long sign-out delays when CleanupInvalidSessions was enabled with ODFC containers. Affected versions are not stated; flagged for versions older than 26.08.'
            AffectedFrom  = $null
            AffectedTo    = $null
            FixedIn       = '3.26.826.17182'
            Workaround    = 'Install FSLogix 26.08 (3.26.826.17182) or later.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'ODFC'
        }
        @{
            Id            = 'FSL-KI-028'
            Title         = 'Identity data exclusions could remove certificates or prevent OneDrive/Entra sign-in (fixed in 26.08)'
            Description   = 'FSLogix 26.08 release notes: fixed two identity data exclusion issues that could remove certificates from the user''s Personal store or prevent OneDrive/Entra sign-in, and an issue where OneDrive files could remain pending-delete when IncludeOneDrive was disabled. Affected versions are not stated; flagged for versions older than 26.08.'
            AffectedFrom  = $null
            AffectedTo    = $null
            FixedIn       = '3.26.826.17182'
            Workaround    = 'Install FSLogix 26.08 (3.26.826.17182) or later.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-029'
            Title         = 'Potential logon hang when a profile does not unload during a timeout operation (fixed in 26.01)'
            Description   = 'FSLogix 26.01 release notes: fixed a potential logon hang when a profile does not unload successfully during a timeout operation (< 30 sec), and an issue where a disk may not detach correctly after a compact operation. Affected versions are not stated; flagged for versions older than 26.01.'
            AffectedFrom  = $null
            AffectedTo    = $null
            FixedIn       = '3.26.102.18413'
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-030'
            Title         = 'Bugcheck 0xE3 or 0x24 when a redirection is removed prior to sign out (fixed in 25.09)'
            Description   = 'FSLogix 25.09 release notes: fixed an issue where a redirection removed prior to sign out resulted in a bugcheck E3 or 24 (Stop Code: 0xE3, 0x24). Affected versions are not stated; flagged for versions older than 25.09.'
            AffectedFrom  = $null
            AffectedTo    = $null
            FixedIn       = '3.25.822.19044'
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Fail'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
        @{
            Id            = 'FSL-KI-031'
            Title         = 'User-based Group Policy settings persist in the profile after the policy is removed or disabled (fixed in 2210 hotfix 4)'
            Description   = 'FSLogix 2210 hotfix 4 release notes: fixed an issue where user-based Group Policy settings would persist in the user''s profile after the policy setting was removed or set to disabled. Affected versions are not stated; flagged for versions older than 2210 hotfix 4.'
            AffectedFrom  = $null
            AffectedTo    = $null
            FixedIn       = '2.9.8884.27471'
            Workaround    = 'Install the latest FSLogix version.'
            Severity      = 'Warn'
            State         = 'Fixed'
            Source        = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            FixedInSource = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
            Scope         = 'General'
        }
    )
}
