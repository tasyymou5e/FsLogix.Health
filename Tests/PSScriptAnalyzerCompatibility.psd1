# Advisory: checks commands/types against the Windows PowerShell 7 compatibility profile shipped with PSScriptAnalyzer.
@{
    IncludeRules = @('PSUseCompatibleCommands', 'PSUseCompatibleTypes')
    Rules        = @{
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-8_x64_10.0.17763.0_7.0.0_x64_3.1.2_core')
        }
        PSUseCompatibleTypes    = @{
            Enable         = $true
            TargetProfiles = @('win-8_x64_10.0.17763.0_7.0.0_x64_3.1.2_core')
        }
    }
}
