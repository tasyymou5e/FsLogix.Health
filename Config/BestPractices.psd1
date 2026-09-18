# FSLogixToolkit best-practice rules (data file used by Invoke-FslBestPracticeAnalyzer).
#
# Every Expected value / DefaultValue below was read on 2026-09-17 from:
#   https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples   (ms.date 2026-03-09)
#   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings  (ms.date 2025-08-26)
#   https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers   (ms.date 2025-03-04; ODFC rules, phase 2)
#   https://learn.microsoft.com/en-us/microsoftteams/teams-client-vdi-requirements-deploy (ms.date 2026-07-17; IncludeTeams note)
# Result Scope (phase 2): rule Scope Profiles -> Profiles, ODFC -> ODFC, Logging/Apps -> General.
# Severity (Fail/Warn/Info) is a TOOLKIT classification of how important the deviation is; the
# recommendation itself is Microsoft's (see Source).
#
# Rule keys:
#   Id, Scope (Profiles|ODFC|Logging|Apps), Setting (registry value name),
#   Operator (Equals|NotEquals|Exists|NotExists|GreaterOrEqual|LessOrEqual|In), Expected,
#   DefaultValue (documented default or $null), DefaultSource (URL documenting the default),
#   Severity (Fail|Warn|Info),
#   AppliesWhen ($null, one condition hashtable, or an array of condition hashtables that must ALL be true;
#                condition keys: Setting, Operator, Expected, optional DefaultValue; evaluated in the rule's Scope),
#   Title, Recommendation, Source.
# CrossCheck keys: Id, Scopes, Handler (private Test-FslBpa* function), Title, Severity, Recommendation, Source.
@{
    DataVerifiedOn = '2026-09-17'

    Rules          = @(
        # ---------------- Profiles (HKLM\SOFTWARE\FSLogix\Profiles) ----------------
        @{
            Id             = 'FSL-PRO-001'
            Scope          = 'Profiles'
            Setting        = 'Enabled'
            Operator       = 'Equals'
            Expected       = 1
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#enabled'
            Severity       = 'Warn'
            AppliesWhen    = $null
            Title          = 'Profile containers enabled'
            Recommendation = 'Set Profiles\Enabled (DWORD) to 1. Microsoft lists it as REQUIRED for profile containers (default 0 = disabled).'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#registry-settings-standard'
        }
        @{
            Id             = 'FSL-PRO-002'
            Scope          = 'Profiles'
            Setting        = 'DeleteLocalProfileWhenVHDShouldApply'
            Operator       = 'Equals'
            Expected       = 1
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#deletelocalprofilewhenvhdshouldapply'
            Severity       = 'Warn'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'Delete local profile when a profile container should apply'
            Recommendation = 'Set DeleteLocalProfileWhenVHDShouldApply (DWORD) to 1 (Recommended) so users do not use local profiles and lose data unexpectedly. Note: an existing local profile is permanently deleted when a container should apply.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#registry-settings-standard'
        }
        @{
            Id             = 'FSL-PRO-003'
            Scope          = 'Profiles'
            Setting        = 'FlipFlopProfileDirectoryName'
            Operator       = 'Equals'
            Expected       = 1
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#flipflopprofiledirectoryname'
            Severity       = 'Info'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'Profile folder name format (FlipFlopProfileDirectoryName)'
            Recommendation = 'FlipFlopProfileDirectoryName = 1 is Recommended for NEW deployments (easier browsing of %username%_%sid% folders). Do NOT change it on an existing deployment: FSLogix will not find existing containers and creates new empty profiles.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#registry-settings-standard'
        }
        @{
            Id             = 'FSL-PRO-004'
            Scope          = 'Profiles'
            Setting        = 'LockedRetryCount'
            Operator       = 'Equals'
            Expected       = 3
            DefaultValue   = 12
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#lockedretrycount'
            Severity       = 'Info'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'Locked container retry count'
            Recommendation = 'Set LockedRetryCount (DWORD) to 3 (Recommended) to decrease retry timing and enable a faster fail scenario.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#registry-settings-standard'
        }
        @{
            Id             = 'FSL-PRO-005'
            Scope          = 'Profiles'
            Setting        = 'LockedRetryInterval'
            Operator       = 'Equals'
            Expected       = 15
            DefaultValue   = 5
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#lockedretryinterval'
            Severity       = 'Info'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'Locked container retry interval'
            Recommendation = 'Set LockedRetryInterval (DWORD, seconds) to 15 (Recommended) to decrease retry timing and enable a faster fail scenario.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#registry-settings-standard'
        }
        @{
            Id             = 'FSL-PRO-006'
            Scope          = 'Profiles'
            Setting        = 'ReAttachRetryCount'
            Operator       = 'Equals'
            Expected       = 3
            DefaultValue   = 60
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#reattachretrycount'
            Severity       = 'Info'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'Container reattach retry count'
            Recommendation = 'Set ReAttachRetryCount (DWORD) to 3 (Recommended) to decrease retry timing and enable a faster fail scenario.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#registry-settings-standard'
        }
        @{
            Id             = 'FSL-PRO-007'
            Scope          = 'Profiles'
            Setting        = 'ReAttachIntervalSeconds'
            Operator       = 'Equals'
            Expected       = 15
            DefaultValue   = 10
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#reattachintervalseconds'
            Severity       = 'Info'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'Container reattach interval'
            Recommendation = 'Set ReAttachIntervalSeconds (DWORD) to 15 (Recommended) to decrease retry timing and enable a faster fail scenario.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#registry-settings-standard'
        }
        @{
            Id             = 'FSL-PRO-008'
            Scope          = 'Profiles'
            Setting        = 'ProfileType'
            Operator       = 'Equals'
            Expected       = 0
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#profiletype'
            Severity       = 'Info'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'Profile type (concurrent connections)'
            Recommendation = 'ProfileType 0 (single connection) reduces complexity and increases performance and is used in the Standard examples. Concurrent connections (ProfileType 3) are the Complex example; all sessions using the VHD concurrently must use a matching ProfileType and 0 must not be mixed with other values.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#registry-settings-standard'
        }
        @{
            Id             = 'FSL-PRO-009'
            Scope          = 'Profiles'
            Setting        = 'VolumeType'
            Operator       = 'Equals'
            Expected       = 'VHDX'
            DefaultValue   = 'vhd'
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#volumetype'
            Severity       = 'Warn'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'Container volume type'
            Recommendation = 'Set VolumeType (REG_SZ) to VHDX (Recommended). VHDX is preferred over VHD because of its supported size and reduced corruption scenarios. Applies to newly created containers.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#registry-settings-standard'
        }
        @{
            Id             = 'FSL-PRO-010'
            Scope          = 'Profiles'
            Setting        = 'AccessNetworkAsComputerObject'
            Operator       = 'Equals'
            Expected       = 0
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#accessnetworkascomputerobject'
            Severity       = 'Warn'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'Access network as computer object'
            Recommendation = 'Leave AccessNetworkAsComputerObject at 0 (attach as user) unless the storage provider or architecture will not work with user-level permissions: 1 lets the virtual machine access all VHD(x) files on the storage provider (security risk).'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#accessnetworkascomputerobject'
        }
        @{
            Id             = 'FSL-PRO-011'
            Scope          = 'Profiles'
            Setting        = 'VHDXSectorSize'
            Operator       = 'Equals'
            Expected       = 0
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#vhdxsectorsize'
            Severity       = 'Warn'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'VHDX sector size'
            Recommendation = 'Do not set VHDXSectorSize (default 0 = system default) unless directed by Microsoft Support. A mismatch in disk sector sizes can lead to a system BSOD.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#vhdxsectorsize'
        }
        @{
            Id             = 'FSL-PRO-012'
            Scope          = 'Profiles'
            Setting        = 'ClearCacheOnLogoff'
            Operator       = 'Equals'
            Expected       = 1
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#clearcacheonlogoff'
            Severity       = 'Info'
            AppliesWhen    = @(
                @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
                @{ Setting = 'CCDLocations'; Operator = 'Exists'; Expected = $null }
            )
            Title          = 'Cloud Cache: clear local cache on sign-out'
            Recommendation = 'With Cloud Cache (CCDLocations), set ClearCacheOnLogoff (DWORD) to 1 (Recommended) to save local disk space and reduce the risk of data loss when using pooled desktops.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#registry-settings-standard--high-availability'
        }
        @{
            Id             = 'FSL-PRO-013'
            Scope          = 'Profiles'
            Setting        = 'HealthyProvidersRequiredForRegister'
            Operator       = 'GreaterOrEqual'
            Expected       = 1
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#healthyprovidersrequiredforregister'
            Severity       = 'Warn'
            AppliesWhen    = @(
                @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
                @{ Setting = 'CCDLocations'; Operator = 'Exists'; Expected = $null }
            )
            Title          = 'Cloud Cache: healthy providers required for sign-in'
            Recommendation = 'With Cloud Cache (CCDLocations), set HealthyProvidersRequiredForRegister (DWORD) to 1 (Recommended) so users cannot create a local cache when no provider is healthy. When non-zero, also use PreventLoginWithFailure and/or PreventLoginWithTempProfile.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#registry-settings-standard--high-availability'
        }
        @{
            Id             = 'FSL-PRO-014'
            Scope          = 'Profiles'
            Setting        = 'HealthyProvidersRequiredForUnregister'
            Operator       = 'NotEquals'
            Expected       = 0
            DefaultValue   = 1
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#healthyprovidersrequiredforunregister'
            Severity       = 'Warn'
            AppliesWhen    = @(
                @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
                @{ Setting = 'CCDLocations'; Operator = 'Exists'; Expected = $null }
            )
            Title          = 'Cloud Cache: healthy providers required for sign-out'
            Recommendation = 'Do not set HealthyProvidersRequiredForUnregister to 0 (NOT recommended; default 1). With 0, CcdUnregisterTimeout and ClearCacheOnForcedUnregister have no effect and user session data in the local cache may be permanently deleted.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#healthyprovidersrequiredforunregister'
        }

        # ---------------- ODFC (HKLM\SOFTWARE\Policies\FSLogix\ODFC) ----------------
        @{
            Id             = 'FSL-ODFC-001'
            Scope          = 'ODFC'
            Setting        = 'AccessNetworkAsComputerObject'
            Operator       = 'Equals'
            Expected       = 0
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#accessnetworkascomputerobject-1'
            Severity       = 'Warn'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'ODFC: access network as computer object'
            Recommendation = 'Leave ODFC AccessNetworkAsComputerObject at 0 (attach as user) unless the storage provider or architecture will not work with user-level permissions: 1 lets the virtual machine access all VHD(x) files on the storage provider (security risk).'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#accessnetworkascomputerobject-1'
        }
        @{
            Id             = 'FSL-ODFC-002'
            Scope          = 'ODFC'
            Setting        = 'HealthyProvidersRequiredForUnregister'
            Operator       = 'NotEquals'
            Expected       = 0
            DefaultValue   = 1
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#healthyprovidersrequiredforunregister'
            Severity       = 'Warn'
            AppliesWhen    = @(
                @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
                @{ Setting = 'CCDLocations'; Operator = 'Exists'; Expected = $null }
            )
            Title          = 'ODFC Cloud Cache: healthy providers required for sign-out'
            Recommendation = 'Do not set HealthyProvidersRequiredForUnregister to 0 (NOT recommended; default 1). With 0, CcdUnregisterTimeout and ClearCacheOnForcedUnregister have no effect and user session data in the local cache may be permanently deleted.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#healthyprovidersrequiredforunregister'
        }

        # ---- ODFC phase 2 rules (verified 2026-09-17) ----
        # Recommended values: https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers#odfc-container-configuration (ms.date 2025-03-04, last updated 2026-09-01)
        # Defaults / notes:   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings (ODFC container Settings, '-1' anchors)
        # Teams:              https://learn.microsoft.com/en-us/microsoftteams/teams-client-vdi-requirements-deploy#profile-and-cache-location-for-the-teams-client (ms.date 2026-07-17)
        @{
            Id             = 'FSL-ODFC-003'
            Scope          = 'ODFC'
            Setting        = 'Enabled'
            Operator       = 'Equals'
            Expected       = 1
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#enabled-1'
            Severity       = 'Warn'
            AppliesWhen    = $null
            Title          = 'ODFC: Office containers enabled'
            Recommendation = 'Set ODFC\Enabled (DWORD) to 1. Microsoft lists it as Required for ODFC containers (documented default 0 = ODFC containers disabled).'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers#odfc-container-configuration'
        }
        @{
            Id             = 'FSL-ODFC-004'
            Scope          = 'ODFC'
            Setting        = 'FlipFlopProfileDirectoryName'
            Operator       = 'Equals'
            Expected       = 1
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#flipflopprofiledirectoryname-1'
            Severity       = 'Info'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'ODFC: container folder name format (FlipFlopProfileDirectoryName)'
            Recommendation = 'ODFC FlipFlopProfileDirectoryName = 1 is Recommended (easier browsing of %username%_%sid% folders). Be careful when changing it in an existing FSLogix environment: FSLogix looks for folders using the new naming convention and creates new containers when they are not found.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers#odfc-container-configuration'
        }
        @{
            Id             = 'FSL-ODFC-005'
            Scope          = 'ODFC'
            Setting        = 'IncludeTeams'
            Operator       = 'Equals'
            Expected       = 1
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#includeteams'
            Severity       = 'Warn'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'ODFC: include Microsoft Teams data'
            Recommendation = 'Set ODFC\IncludeTeams (DWORD) to 1 (Recommended; documented default 0). It keeps classic and new Teams data in the ODFC container and registers the new Teams AppX package during sign-in. The Teams VDI documentation states that customers using just ODFC containers still need to add IncludeTeams for the Teams user data/cache to be preserved.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers#odfc-container-configuration'
        }
        @{
            Id             = 'FSL-ODFC-006'
            Scope          = 'ODFC'
            Setting        = 'LockedRetryCount'
            Operator       = 'Equals'
            Expected       = 3
            DefaultValue   = 12
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#lockedretrycount-1'
            Severity       = 'Info'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'ODFC: locked container retry count'
            Recommendation = 'Set ODFC\LockedRetryCount (DWORD) to 3 (Recommended; documented default 12) to decrease the retry timing and enable a faster fail scenario.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers#odfc-container-configuration'
        }
        @{
            Id             = 'FSL-ODFC-007'
            Scope          = 'ODFC'
            Setting        = 'LockedRetryInterval'
            Operator       = 'Equals'
            Expected       = 15
            DefaultValue   = 5
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#lockedretryinterval-1'
            Severity       = 'Info'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'ODFC: locked container retry interval'
            Recommendation = 'Set ODFC\LockedRetryInterval (DWORD, seconds) to 15 (Recommended; documented default 5) to decrease the retry timing and enable a faster fail scenario.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers#odfc-container-configuration'
        }
        @{
            Id             = 'FSL-ODFC-008'
            Scope          = 'ODFC'
            Setting        = 'ReAttachIntervalSeconds'
            Operator       = 'Equals'
            Expected       = 15
            DefaultValue   = 10
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#reattachintervalseconds-1'
            Severity       = 'Info'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'ODFC: container reattach interval'
            Recommendation = 'Set ODFC\ReAttachIntervalSeconds (DWORD) to 15 (Recommended; documented default 10) to decrease the retry timing and enable a faster fail scenario.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers#odfc-container-configuration'
        }
        @{
            Id             = 'FSL-ODFC-009'
            Scope          = 'ODFC'
            Setting        = 'ReAttachRetryCount'
            Operator       = 'Equals'
            Expected       = 3
            DefaultValue   = 60
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#reattachretrycount-1'
            Severity       = 'Info'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'ODFC: container reattach retry count'
            Recommendation = 'Set ODFC\ReAttachRetryCount (DWORD) to 3 (Recommended; documented default 60) to decrease the retry timing and enable a faster fail scenario.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers#odfc-container-configuration'
        }
        @{
            Id             = 'FSL-ODFC-010'
            Scope          = 'ODFC'
            Setting        = 'VolumeType'
            Operator       = 'Equals'
            Expected       = 'VHDX'
            DefaultValue   = 'vhd'
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#volumetype-1'
            Severity       = 'Warn'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'ODFC: container volume type'
            Recommendation = 'Set ODFC\VolumeType (REG_SZ) to VHDX (Recommended; documented default vhd). VHDX is preferred over VHD due to its supported size and reduced corruption scenarios. Applies to newly created containers.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/how-to-configure-odfc-containers#odfc-container-configuration'
        }
        @{
            Id             = 'FSL-ODFC-011'
            Scope          = 'ODFC'
            Setting        = 'RefreshUserPolicy'
            Operator       = 'Equals'
            Expected       = 0
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#refreshuserpolicy'
            Severity       = 'Warn'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'ODFC: refresh user policy'
            Recommendation = 'RefreshUserPolicy has a performance implication. It should not be set, or should be set to 0 (documented default), unless there is a specific GPO event; after the GPO event revert it to the default.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#refreshuserpolicy'
        }
        @{
            Id             = 'FSL-ODFC-012'
            Scope          = 'ODFC'
            Setting        = 'RedirectType'
            Operator       = 'Equals'
            Expected       = 2
            DefaultValue   = 2
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#redirecttype-1'
            Severity       = 'Warn'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'ODFC: redirection type'
            Recommendation = 'Do not use ODFC\RedirectType unless directed by Microsoft Support. Documented default 2 = FSLogix advanced redirection; 1 = legacy redirection.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#redirecttype-1'
        }
        @{
            Id             = 'FSL-ODFC-013'
            Scope          = 'ODFC'
            Setting        = 'VHDAccessMode'
            Operator       = 'In'
            Expected       = @(0, 3)
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#vhdaccessmode'
            Severity       = 'Warn'
            AppliesWhen    = @(
                @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
                @{ Setting = 'IncludeOutlook'; Operator = 'Equals'; Expected = 1; DefaultValue = 1 }
                @{ Setting = 'OutlookCachedMode'; Operator = 'Equals'; Expected = 1; DefaultValue = 1 }
            )
            Title          = 'ODFC: VHD access mode compatible with Outlook cached mode'
            Recommendation = 'If the ODFC container is being used with Outlook cache mode, VHDAccessMode 0 or 3 must be used (modes 1 and 2 use difference disks and should not be used with Outlook Cached Exchange mode). Evaluated because IncludeOutlook and OutlookCachedMode are 1 (configured or documented default).'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#vhdaccessmode'
        }
        @{
            Id             = 'FSL-ODFC-014'
            Scope          = 'ODFC'
            Setting        = 'VHDAccessMode'
            Operator       = 'Equals'
            Expected       = 0
            DefaultValue   = 0
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#vhdaccessmode'
            Severity       = 'Info'
            AppliesWhen    = @(
                @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
                @{ Setting = 'IncludeOneDrive'; Operator = 'Equals'; Expected = 1; DefaultValue = 1 }
            )
            Title          = 'ODFC: concurrent VHD access with OneDrive included'
            Recommendation = 'If the VHD is not accessed concurrently, VHDAccessMode should be 0 (documented default). All sessions using the VHD concurrently must have a matching VHDAccessMode. OneDrive (IncludeOneDrive = 1, documented default) does not support multiple concurrent connections using the same profile under any circumstances.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#vhdaccessmode'
        }
        @{
            Id             = 'FSL-ODFC-015'
            Scope          = 'ODFC'
            Setting        = 'IncludeOutlook'
            Operator       = 'Equals'
            Expected       = 1
            DefaultValue   = 1
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#includeoutlook'
            Severity       = 'Info'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'ODFC: Outlook data included (documented default)'
            Recommendation = 'Informational - documented default 1 (Outlook data, classic and new Outlook for Windows, is redirected to the ODFC container); this is not a Microsoft recommendation to change or keep the value. A non-default value means Outlook data is not stored in the ODFC container.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#includeoutlook'
        }
        @{
            Id             = 'FSL-ODFC-016'
            Scope          = 'ODFC'
            Setting        = 'IncludeOfficeActivation'
            Operator       = 'Equals'
            Expected       = 1
            DefaultValue   = 1
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#includeofficeactivation'
            Severity       = 'Info'
            AppliesWhen    = @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
            Title          = 'ODFC: Office activation data included (documented default)'
            Recommendation = 'Informational - documented default 1 (Office 2016 and later activation data is redirected to the ODFC container); this is not a Microsoft recommendation to change or keep the value. A non-default value means Office activation data is not stored in the ODFC container.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#includeofficeactivation'
        }
        @{
            Id             = 'FSL-ODFC-017'
            Scope          = 'ODFC'
            Setting        = 'OutlookCachedMode'
            Operator       = 'Equals'
            Expected       = 1
            DefaultValue   = 1
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#outlookcachedmode-1'
            Severity       = 'Info'
            AppliesWhen    = @(
                @{ Setting = 'Enabled'; Operator = 'Equals'; Expected = 1; DefaultValue = 0 }
                @{ Setting = 'IncludeOutlook'; Operator = 'Equals'; Expected = 1; DefaultValue = 1 }
            )
            Title          = 'ODFC: Outlook cached mode handling (documented default)'
            Recommendation = 'Informational - documented default 1 (cached mode is set only while the ODFC container is attached; does not apply to new Outlook for Windows). For this feature to work Outlook must be configured for online mode (HKLM\Software\Policies\Microsoft\office\16.0\Outlook\OST\NoOST = 2, DWORD); that Office policy is not evaluated by this rule.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#outlookcachedmode-1'
        }

        # ---------------- Logging (HKLM\SOFTWARE\FSLogix\Logging) ----------------
        @{
            Id             = 'FSL-LOG-001'
            Scope          = 'Logging'
            Setting        = 'LogFileKeepingPeriod'
            Operator       = 'LessOrEqual'
            Expected       = 180
            DefaultValue   = 2
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#logfilekeepingperiod'
            Severity       = 'Warn'
            AppliesWhen    = $null
            Title          = 'Log file keeping period within documented maximum'
            Recommendation = 'LogFileKeepingPeriod (REG_DWORD, number of daily log files to keep) has a documented maximum value of 180 (default 2).'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#logfilekeepingperiod'
        }
        @{
            Id             = 'FSL-LOG-002'
            Scope          = 'Logging'
            Setting        = 'RobocopyLogPath'
            Operator       = 'NotExists'
            Expected       = $null
            DefaultValue   = $null
            DefaultSource  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#robocopylogpath'
            Severity       = 'Info'
            AppliesWhen    = $null
            Title          = 'Robocopy logging (troubleshooting only)'
            Recommendation = 'RobocopyLogPath is recommended for troubleshooting only. Remove it when troubleshooting is complete.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#robocopylogpath'
        }
    )

    CrossChecks    = @(
        @{
            Id             = 'FSL-XC-001'
            Scopes         = @('Profiles', 'ODFC')
            Handler        = 'Test-FslBpaLocationConflict'
            Title          = 'VHDLocations and CCDLocations not both configured'
            Severity       = 'Fail'
            Recommendation = 'CCDLocations and VHDLocations must not both be present at the same time. Keep CCDLocations for Cloud Cache or VHDLocations for standard containers and remove the other.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#container-specific-settings'
        }
        @{
            Id             = 'FSL-XC-002'
            Scopes         = @('Profiles', 'ODFC')
            Handler        = 'Test-FslBpaMissingLocation'
            Title          = 'Container storage location configured when enabled'
            Severity       = 'Fail'
            Recommendation = 'When Enabled = 1, configure VHDLocations (required setting for standard containers) or CCDLocations (required setting for Cloud Cache).'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#vhdlocations'
        }
        @{
            Id             = 'FSL-XC-003'
            Scopes         = @('Profiles')
            Handler        = 'Test-FslBpaMultipleVhdLocation'
            Title          = 'Multiple VHDLocations entries'
            Severity       = 'Info'
            Recommendation = 'Multiple VHDLocations entries do not provide container resiliency; the first available location the user can access is used. Users should have access to only a single location - consider object-specific settings instead of multiple VHDLocations, or Cloud Cache for high availability.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples#object-specific-vhdlocations'
        }
        @{
            Id             = 'FSL-XC-004'
            Scopes         = @('Profiles', 'ODFC')
            Handler        = 'Test-FslBpaCcdProviderCount'
            Title          = 'Cloud Cache provider count within supported maximum'
            Severity       = 'Fail'
            Recommendation = 'CCDLocations supports up to four remote container locations. Reduce the number of providers.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#ccdlocations'
        }
        @{
            Id             = 'FSL-XC-005'
            Scopes         = @('Profiles', 'ODFC')
            Handler        = 'Test-FslBpaCcdAzureProtectedKey'
            Title          = 'Cloud Cache Azure provider uses a protected connection string'
            Severity       = 'Warn'
            Recommendation = 'Do not use a plain-text connectionString for Azure page blob providers; reference a protected key, for example connectionString="|fslogix/azureblob1|".'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#ccdlocations'
        }
        @{
            Id             = 'FSL-XC-006'
            Scopes         = @('Profiles', 'ODFC')
            Handler        = 'Test-FslBpaRegisterLoginExperience'
            Title          = 'Sign-in failure experience when healthy providers are required'
            Severity       = 'Warn'
            Recommendation = 'When HealthyProvidersRequiredForRegister is not 0, use PreventLoginWithFailure and/or PreventLoginWithTempProfile to create the desired user experience.'
            Source         = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#healthyprovidersrequiredforregister'
        }
    )
}
