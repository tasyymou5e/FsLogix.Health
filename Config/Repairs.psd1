# FSLogixToolkit repair catalog (contract PHASE 3 P3.5, plan Docs/REPAIR-PLAN.md section 2, release R2/R3).
#
# Every entry is documented by Microsoft; the Source URL is carried into the plan, the repair record and the log.
# Nothing in this file is a toolkit recommendation: the Condition/ProposedValue pairs only restore or apply a
# DOCUMENTED value (documented startup type, documented default, documented maximum, documented "troubleshooting
# only" setting). Toolkit-tunable numbers (risk tier default, change-reference tier, plan age, free space,
# temporary logging hours) live in Config/Settings.psd1 (section Repair) and are toolkit defaults.
#
# Entry keys (contract P3.5):
#   Id             Action id (FIX-<area>-<nn>), unique.
#   Title          Short operator-facing title.
#   Scope          General | ODFC | Profiles (Result/record scope, contract P2.2).
#   RiskTier       0 read-only | 1 reversible low risk | 2 persistent config change with backup | 3 disruptive.
#   Kind           RegistryValue | ServiceStartType | ServiceStart | Container.
#   Target         Kind-specific target:
#                    RegistryValue    @{ Hive; Key; ValueName; ValueKind }   (Hive is always HKLM, 64-bit view)
#                    ServiceStartType @{ ServiceName = @(...); DisplayName }
#                    ServiceStart     @{ ServiceName = @(...); DisplayName }
#                    Container        @{ ContainerType }
#   ProposedValue  The value/start type the action would set ('(remove value)' for a value removal).
#   Condition      Human-readable condition text (shown in the plan and the log).
#   Detect/Apply/Rollback  Private handler function names (prefix *-FslFix*); Rollback $null = no rollback.
#   RollbackMethod RestoreValue | RestoreStartType | MoveBack | None.
#   EffectiveWhen  Immediate | ServiceRestart | NextSignIn | Reboot | Unknown (Unknown when Microsoft does not state it).
#   OperatorSelected  $true = never planned automatically; only when named in -ActionId.
#   RequiresNoSessions $true = needs the operator to confirm the user is signed out (-UserSignedOutConfirmed).
#   Source         Microsoft documentation URL that documents the target state.
#   Guidance       Extra operator guidance (also shown when an action is GuidanceOnly or Blocked).
# RegistryValue entries additionally carry:
#   SettingScope   Get-FslEffectiveSetting scope used for Group Policy provenance (Logging | ODFC | Profiles | Apps).
#   Operation      Set | Remove.
#   Trigger        @{ Type = ValuePresent | ValueEquals | ValueNotEquals | ValueGreaterThan | ValueMissingOrNotEquals; Value = <n> }
#   DocumentedDefault  Documented default of the value (text, for the message; $null when none).
#   Temporary      $true = the change is temporary and must be undone (retention keeps the run until it is reverted).
#   TemporaryHoursSetting  Settings key (section Repair) with the maximum number of hours for a temporary change.
# ServiceStartType entries additionally carry:
#   FromStartType  Only change a service whose current start type is in this list ($null = any start type that differs).
#   StartIfStopped $true = also start the service after the start type was corrected (never stop, never restart).
#   DependsOn      Service that must be Running before this service can be started (documented dependency).
#
# Verified sources (retrieved 2026-09-17):
#   https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components
#     frxsvc.exe "FSLogix Apps Services" Startup type: Automatic; frxccds.exe "FSLogix Cloud Caching Service"
#     Startup type: Automatic, "Dependent on FSLogix Apps Services".
#   https://learn.microsoft.com/en-us/fslogix/troubleshooting-fslogix-service
#     Service crash recommendations: "Always upgrade to the latest version of FSLogix and review the release notes."
#     and "Open a support request to report the issue and have the crash analyzed." (no restart procedure is documented).
#   https://learn.microsoft.com/en-us/fslogix/troubleshooting-vhd-disk-compaction
#     "The VHD Disk Compaction feature relies on the Optimize Drives (defragsvc) and Microsoft Storage Spaces SMP
#     (smphost) services. If the service StartupType is set to Disabled, VHD Disk Compaction can't run. The service
#     StartupType must be set to Manual or Automatic, regardless if the service state is Running or Stopped."
#   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
#     Log Settings: Registry Hive HKEY_LOCAL_MACHINE, Registry Path SOFTWARE\FSLogix\Logging.
#       LoggingEnabled REG_DWORD, default 2 ("all log files are enabled"); 0 = "all log files are disabled".
#       LoggingLevel REG_DWORD, default 1; 0 = "Verbose log file output that includes DBG, INFO, WARN, and ERROR messages."
#       LogFileKeepingPeriod REG_DWORD, default 2, Max Value 180.
#       RobocopyLogPath REG_SZ, Default Value None, "This setting is recommended for troubleshooting only."
#     ODFC container settings: Registry Hive HKEY_LOCAL_MACHINE, Registry Path SOFTWARE\Policies\FSLogix\ODFC.
#       RefreshUserPolicy REG_DWORD, default 0; "RefreshUserPolicy shouldn't be set, or should be set to 0, unless
#       there's a specific GPO event. After the GPO event, the setting should be reverted to default."
#   https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates
#     Local Group Policy Editor (GPEDIT.MSC): "Browse to Computer Configuration then Administrative Templates then FSLogix."
#     "Group Policy settings stored under HKEY_LOCAL_MACHINE\SOFTWARE\FSLogix are considered preferences and NOT
#     policies. ... ODFC settings are located under HKEY_LOCAL_MACHINE\SOFTWARE\Policies\FSLogix\ODFC and will
#     correctly reset themselves under the above circumstances."
#   https://learn.microsoft.com/en-us/fslogix/concepts-container-types
#     "Most data contained in the ODFC container is sourced from other remote systems and is easily replaced should
#     the ODFC container become corrupted or deleted."
#   https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/set-service
#     -StartupType values Automatic, AutomaticDelayedStart, Disabled, InvalidValue, Manual; Windows only; needs elevation.
#   https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-service
#     "You can start only the services that have a start type of Manual, Automatic, or Automatic (Delayed Start)."
@{
    DataVerifiedOn = '2026-09-17'
    Actions        = @(
        @{
            Id                = 'FIX-SVC-01'
            Title             = 'Set the FSLogix Apps service (frxsvc) start type to Automatic'
            Scope             = 'General'
            RiskTier          = 2
            Kind              = 'ServiceStartType'
            Target            = @{ ServiceName = @('frxsvc'); DisplayName = 'FSLogix Apps Services' }
            ProposedValue     = 'Automatic'
            Condition         = 'The frxsvc service start type is not Automatic (documented startup type: Automatic).'
            Detect            = 'Get-FslFixServiceStartTypeState'
            Apply             = 'Set-FslFixServiceStartTypeState'
            Rollback          = 'Restore-FslFixServiceStartType'
            RollbackMethod    = 'RestoreStartType'
            EffectiveWhen     = 'Reboot'
            OperatorSelected  = $false
            RequiresNoSessions = $false
            FromStartType     = $null
            StartIfStopped    = $false
            DependsOn         = $null
            Source            = 'https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components'
            Guidance          = 'FSLogix documents the FSLogix Apps Services (frxsvc.exe) startup type as Automatic. The new start type applies at the next system start; the service is not started or restarted by this action.'
        }
        @{
            Id                = 'FIX-SVC-02'
            Title             = 'Start the stopped FSLogix Apps service (frxsvc)'
            Scope             = 'General'
            RiskTier          = 1
            Kind              = 'ServiceStart'
            Target            = @{ ServiceName = @('frxsvc'); DisplayName = 'FSLogix Apps Services' }
            ProposedValue     = 'Running'
            Condition         = 'The frxsvc service is Stopped while its start type is Automatic.'
            Detect            = 'Get-FslFixServiceStartState'
            Apply             = 'Start-FslFixServiceState'
            Rollback          = $null
            RollbackMethod    = 'None'
            EffectiveWhen     = 'Immediate'
            OperatorSelected  = $false
            RequiresNoSessions = $false
            DependsOn         = $null
            Source            = 'https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components'
            Guidance          = 'The service is started once (Start-Service); it is never stopped or restarted, and the start is not repeated. Microsoft does not document a restart procedure: for repeated stops or crashes of frxsvc/frxccds the documented recommendations are to upgrade to the latest FSLogix version, review the release notes and open a support request (https://learn.microsoft.com/en-us/fslogix/troubleshooting-fslogix-service). Starting a service cannot be undone by the toolkit (it never stops FSLogix services).'
        }
        @{
            Id                = 'FIX-SVC-03'
            Title             = 'Set the FSLogix Cloud Caching service (frxccds) start type to Automatic'
            Scope             = 'General'
            RiskTier          = 2
            Kind              = 'ServiceStartType'
            Target            = @{ ServiceName = @('frxccds'); DisplayName = 'FSLogix Cloud Caching Service' }
            ProposedValue     = 'Automatic'
            Condition         = 'The frxccds service start type is not Automatic (documented startup type: Automatic), or it is Stopped while its start type allows starting.'
            Detect            = 'Get-FslFixServiceStartTypeState'
            Apply             = 'Set-FslFixServiceStartTypeState'
            Rollback          = 'Restore-FslFixServiceStartType'
            RollbackMethod    = 'RestoreStartType'
            EffectiveWhen     = 'Reboot'
            OperatorSelected  = $true
            RequiresNoSessions = $false
            FromStartType     = $null
            StartIfStopped    = $true
            DependsOn         = 'frxsvc'
            Source            = 'https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components'
            Guidance          = 'FSLogix documents the FSLogix Cloud Caching Service (frxccds.exe) startup type as Automatic and that it is "Dependent on FSLogix Apps Services": the toolkit only starts frxccds after frxsvc is Running. Undo restores the previous start type; a service that was started is never stopped again by the toolkit. This host does not use Cloud Cache, so frxccds has no containers to serve - the action only restores the documented service configuration. It is therefore operator-selected: it is never planned automatically and only runs when FIX-SVC-03 is named in -ActionId, so a deliberately disabled frxccds on the image is not re-enabled by a plan-wide apply.'
        }
        @{
            Id                = 'FIX-SVC-04'
            Title             = 'Set the Optimize Drives (defragsvc) / Microsoft Storage Spaces SMP (smphost) start type from Disabled to Manual'
            Scope             = 'General'
            RiskTier          = 2
            Kind              = 'ServiceStartType'
            Target            = @{ ServiceName = @('defragsvc', 'smphost'); DisplayName = 'Optimize Drives; Microsoft Storage Spaces SMP' }
            ProposedValue     = 'Manual'
            Condition         = 'The defragsvc or smphost service start type is Disabled while FSLogix VHD Disk Compaction relies on both services.'
            Detect            = 'Get-FslFixServiceStartTypeState'
            Apply             = 'Set-FslFixServiceStartTypeState'
            Rollback          = 'Restore-FslFixServiceStartType'
            RollbackMethod    = 'RestoreStartType'
            EffectiveWhen     = 'Unknown'
            OperatorSelected  = $false
            RequiresNoSessions = $false
            FromStartType     = @('Disabled')
            StartIfStopped    = $false
            DependsOn         = $null
            Source            = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-vhd-disk-compaction'
            Guidance          = 'Only a Disabled start type is changed, and only to Manual (the documented resolution is "Set-Service defragsvc -StartupType Manual" / "Set-Service smphost -StartupType Manual"); a service already set to Manual or Automatic is left unchanged. Microsoft does not state when a running compaction picks up the change. If a baseline or Group Policy sets these services to Disabled, it will set them back - check your security baseline.'
        }
        @{
            Id                = 'FIX-LOG-01'
            Title             = 'Remove LoggingEnabled = 0 so FSLogix logging returns to the documented default'
            Scope             = 'General'
            RiskTier          = 2
            Kind              = 'RegistryValue'
            Target            = @{ Hive = 'HKLM'; Key = 'SOFTWARE\FSLogix\Logging'; ValueName = 'LoggingEnabled'; ValueKind = 'DWord' }
            ProposedValue     = '(remove value)'
            Condition         = 'LoggingEnabled is 0, which disables all FSLogix log files.'
            Detect            = 'Get-FslFixRegistryState'
            Apply             = 'Set-FslFixRegistryState'
            Rollback          = 'Restore-FslFixRegistryState'
            RollbackMethod    = 'RestoreValue'
            EffectiveWhen     = 'Unknown'
            OperatorSelected  = $false
            RequiresNoSessions = $false
            SettingScope      = 'Logging'
            Operation         = 'Remove'
            Trigger           = @{ Type = 'ValueEquals'; Value = 0 }
            DocumentedDefault = '2 (all log files are enabled)'
            Temporary         = $false
            Source            = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings'
            Guidance          = 'With LoggingEnabled = 0 "the specific settings for each log file are ignored and all log files are disabled", so no FSLogix logs are available for troubleshooting. Removing the value restores the documented default 2 (all log files enabled). Values under HKLM\SOFTWARE\FSLogix are preferences: they stay after a GPO is removed or set to Not Configured (how-to-use-group-policy-templates).'
        }
        @{
            Id                    = 'FIX-LOG-02'
            Title                 = 'Turn on verbose FSLogix logging temporarily (LoggingLevel = 0)'
            Scope                 = 'General'
            RiskTier              = 1
            Kind                  = 'RegistryValue'
            Target                = @{ Hive = 'HKLM'; Key = 'SOFTWARE\FSLogix\Logging'; ValueName = 'LoggingLevel'; ValueKind = 'DWord' }
            ProposedValue         = 0
            Condition             = 'The operator needs verbose troubleshooting data and LoggingLevel is not already 0.'
            Detect                = 'Get-FslFixRegistryState'
            Apply                 = 'Set-FslFixRegistryState'
            Rollback              = 'Restore-FslFixRegistryState'
            RollbackMethod        = 'RestoreValue'
            EffectiveWhen         = 'Unknown'
            OperatorSelected      = $true
            RequiresNoSessions    = $false
            SettingScope          = 'Logging'
            Operation             = 'Set'
            Trigger               = @{ Type = 'ValueMissingOrNotEquals'; Value = 0 }
            DocumentedDefault     = '1 (INFO, WARN and ERROR messages)'
            Temporary             = $true
            TemporaryHoursSetting = 'TemporaryLoggingMaxHours'
            Source                = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings'
            Guidance              = 'LoggingLevel 0 is "Verbose log file output that includes DBG, INFO, WARN, and ERROR messages" and produces much larger log files. This is a TEMPORARY change: Undo-FslRepair restores the previous value (or removes the value when it did not exist) and the daily health check warns once the expiry has passed. LoggingEnabled is never changed to 1 to switch a component log on, because that would switch the other logs off. Microsoft documents a reboot or FSLogix service restart only for LogDir, so when the new logging level takes effect is not documented.'
        }
        @{
            Id                = 'FIX-LOG-03'
            Title             = 'Reduce LogFileKeepingPeriod to the documented maximum of 180'
            Scope             = 'General'
            RiskTier          = 2
            Kind              = 'RegistryValue'
            Target            = @{ Hive = 'HKLM'; Key = 'SOFTWARE\FSLogix\Logging'; ValueName = 'LogFileKeepingPeriod'; ValueKind = 'DWord' }
            ProposedValue     = 180
            Condition         = 'LogFileKeepingPeriod is greater than the documented maximum value 180.'
            Detect            = 'Get-FslFixRegistryState'
            Apply             = 'Set-FslFixRegistryState'
            Rollback          = 'Restore-FslFixRegistryState'
            RollbackMethod    = 'RestoreValue'
            EffectiveWhen     = 'Unknown'
            OperatorSelected  = $false
            RequiresNoSessions = $false
            SettingScope      = 'Logging'
            Operation         = 'Set'
            Trigger           = @{ Type = 'ValueGreaterThan'; Value = 180 }
            DocumentedDefault = '2 (a new log file is created each day; this value specifies how many to keep)'
            Temporary         = $false
            Source            = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings'
            Guidance          = 'LogFileKeepingPeriod has a documented Max Value of 180. The action sets the documented maximum, not the documented default (2), so no log files are deleted beyond the documented limit.'
        }
        @{
            Id                = 'FIX-LOG-04'
            Title             = 'Remove RobocopyLogPath (troubleshooting-only setting)'
            Scope             = 'General'
            RiskTier          = 2
            Kind              = 'RegistryValue'
            Target            = @{ Hive = 'HKLM'; Key = 'SOFTWARE\FSLogix\Logging'; ValueName = 'RobocopyLogPath'; ValueKind = 'String' }
            ProposedValue     = '(remove value)'
            Condition         = 'RobocopyLogPath is configured (documented default: None; recommended for troubleshooting only).'
            Detect            = 'Get-FslFixRegistryState'
            Apply             = 'Set-FslFixRegistryState'
            Rollback          = 'Restore-FslFixRegistryState'
            RollbackMethod    = 'RestoreValue'
            EffectiveWhen     = 'Unknown'
            OperatorSelected  = $false
            RequiresNoSessions = $false
            SettingScope      = 'Logging'
            Operation         = 'Remove'
            Trigger           = @{ Type = 'ValuePresent'; Value = $null }
            DocumentedDefault = 'None (robocopy results are not logged)'
            Temporary         = $false
            Source            = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings'
            Guidance          = 'RobocopyLogPath stores the output of the robocopy commands FSLogix runs; the documented default is None and the setting "is recommended for troubleshooting only". Removing the value stops that extra logging. Undo restores the previous path.'
        }
        @{
            Id                = 'FIX-ODFC-01'
            Title             = 'Reset the ODFC RefreshUserPolicy value to the documented default 0'
            Scope             = 'ODFC'
            RiskTier          = 2
            Kind              = 'RegistryValue'
            Target            = @{ Hive = 'HKLM'; Key = 'SOFTWARE\Policies\FSLogix\ODFC'; ValueName = 'RefreshUserPolicy'; ValueKind = 'DWord' }
            ProposedValue     = 0
            Condition         = 'The ODFC RefreshUserPolicy value is not 0 (documented default) after a Group Policy event.'
            Detect            = 'Get-FslFixRegistryState'
            Apply             = 'Set-FslFixRegistryState'
            Rollback          = 'Restore-FslFixRegistryState'
            RollbackMethod    = 'RestoreValue'
            EffectiveWhen     = 'Unknown'
            OperatorSelected  = $false
            RequiresNoSessions = $false
            SettingScope      = 'ODFC'
            Operation         = 'Set'
            Trigger           = @{ Type = 'ValueNotEquals'; Value = 0 }
            DocumentedDefault = '0 (disabled)'
            Temporary         = $false
            Source            = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings'
            Guidance          = 'Microsoft documents a performance implication for RefreshUserPolicy = 1 and states it "shouldn''t be set, or should be set to 0, unless there''s a specific GPO event. After the GPO event, the setting should be reverted to default." Only the documented ODFC key HKLM\SOFTWARE\Policies\FSLogix\ODFC is written; values under HKLM\SOFTWARE\FSLogix\ODFC are never changed by a repair.'
        }
        @{
            Id                = 'FIX-ODFC-02'
            Title             = 'Reset a user''s Office (ODFC) container by archiving the container file'
            Scope             = 'ODFC'
            RiskTier          = 3
            Kind              = 'Container'
            Target            = @{ ContainerType = 'ODFC' }
            ProposedValue     = '(move the container file to the archive path)'
            Condition         = 'The operator selects a user whose Office container is corrupt or unusable.'
            Detect            = 'Get-FslFixContainerResetState'
            Apply             = 'Invoke-FslFixContainerReset'
            Rollback          = 'Undo-FslFixContainerReset'
            RollbackMethod    = 'MoveBack'
            EffectiveWhen     = 'NextSignIn'
            OperatorSelected  = $true
            RequiresNoSessions = $true
            Source            = 'https://learn.microsoft.com/en-us/fslogix/concepts-container-types'
            Guidance          = 'The container file is copied to the archive path, verified (length and SHA256) and only then removed from the container share; the folder and other files are never deleted. FSLogix creates a new, empty Office container at the user''s next sign-in. Microsoft states "Most data contained in the ODFC container is sourced from other remote systems and is easily replaced should the ODFC container become corrupted or deleted" - MOST data (Outlook cache, OneDrive, Teams, SharePoint) is re-synced from Microsoft 365, but local-only or unsynced items (for example local OneNote notebooks) are only in the archived copy. Requires: elevation, ODFC enabled with profile containers disabled, no Cloud Cache, the user signed out of every session host (-UserSignedOutConfirmed), a reachable archive path, -AllowDisruptive and a change reference.'
        }
    )
}
