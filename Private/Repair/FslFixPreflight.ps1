# Private pre-flight gates for repairs (Agent P3-5, prefix *-FslFix*).
#
# Gates implemented (plan section 3, contract P3.5): G1-G8, G10, G12-G18, G21.
# G9 (session enumeration) is NOT implemented: no locale-safe method is verified. Container actions use the
# exclusive-open check (G10) plus the operator attestation -UserSignedOutConfirmed instead.
# G11 (drain attestation), G19/G20 (installer gates) are out of scope for this phase.
#
# Result convention: Category Repair, Check 'Preflight:<Gate>'. Run-wide gates use Target 'Repair run';
# per-action gates use the action id as Target. Fail/Error = blocking; Warn/Info never block.
#
# Sources:
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/unblock-file
#     ("Internally, the Unblock-File cmdlet removes the Zone.Identifier alternate data stream" / Get-Item -Stream)
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_filesystem_provider (Stream)
#   https://learn.microsoft.com/dotnet/api/system.io.driveinfo.availablefreespace
#   https://learn.microsoft.com/dotnet/api/system.io.fileshare
#   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings

$script:FslFixPreflightTargetRun = 'Repair run'
$script:FslFixPreflightSource = 'Toolkit default'

function New-FslFixPreflightResult {
    <#
    .SYNOPSIS
        Creates one pre-flight Result (Category Repair, Check 'Preflight:<Gate>').
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory Result object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Gate,

        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Warn', 'Fail', 'Info', 'Skipped', 'Error')]
        [string] $Status,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Target,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Message,

        [AllowNull()]
        [object] $Value,

        [AllowNull()]
        [object] $Expected,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Recommendation,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Source,

        [bool] $RequiresElevation = $false,

        [ValidateSet('General', 'ODFC', 'Profiles')]
        [string] $Scope = 'General'
    )

    if ([string]::IsNullOrWhiteSpace($Source)) { $Source = $script:FslFixPreflightSource }
    New-FslResult -Category 'Repair' -Check ("Preflight:{0}" -f $Gate) -Status $Status -Target $Target -Value $Value `
        -Expected $Expected -Message $Message -Recommendation $Recommendation -Source $Source `
        -RequiresElevation $RequiresElevation -Scope $Scope
}

function Get-FslFixBlockedFile {
    <#
    .SYNOPSIS
        Windows: returns the toolkit files that still carry the Zone.Identifier stream (downloaded and not unblocked).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Root
    )

    if (-not (Test-FslIsWindows)) { return }
    try {
        $files = Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.xaml' -ErrorAction SilentlyContinue
        foreach ($file in @($files)) {
            $stream = Get-Item -LiteralPath $file.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
            if ($null -ne $stream) { $file.FullName }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Check Zone.Identifier streams under $Root"
    }
}

function Test-FslFixRunLockFree {
    <#
    .SYNOPSIS
        Returns @{ Free; Message } after probing the single-run lock (opened with FileShare.None and released again).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StateRoot
    )

    $lockPath = Join-Path -Path $StateRoot -ChildPath 'repair.lock'
    if (-not [System.IO.Directory]::Exists($StateRoot)) {
        return @{ Free = $true; Message = "The rollback store folder does not exist yet ($StateRoot), so no repair run holds the lock." }
    }
    $stream = $null
    try {
        $stream = [System.IO.FileStream]::new($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        return @{ Free = $true; Message = "No other repair run holds the lock ($lockPath)." }
    }
    catch [System.IO.DirectoryNotFoundException] {
        return @{ Free = $true; Message = "The rollback store folder does not exist yet ($StateRoot), so no repair run holds the lock." }
    }
    catch [System.IO.IOException] {
        return @{ Free = $false; Message = "Another repair run holds the repair lock ($lockPath). Only one repair run at a time is allowed." }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Probe the repair run lock in $StateRoot"
        return @{ Free = $false; Message = "The repair lock could not be checked: $($_.Exception.Message)" }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-FslFixFreeSpaceMB {
    <#
    .SYNOPSIS
        Returns the free space in MB of the volume that holds a path, or $null when it cannot be determined.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        if ([string]::IsNullOrWhiteSpace($root)) { return $null }
        $drive = [System.IO.DriveInfo]::new($root)
        if (-not $drive.IsReady) { return $null }
        return [math]::Round($drive.AvailableFreeSpace / 1MB, 0)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Read free space for $Path"
        return $null
    }
}

function Get-FslFixContainerPath {
    <#
    .SYNOPSIS
        Returns the container file path recorded in an action's before state (container actions), or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Action
    )

    $state = Get-FslFixValue -InputObject $Action -Name 'BeforeState'
    if ($null -eq $state) { return $null }
    foreach ($name in @('ContainerPath', 'FullName', 'Path', 'SourcePath')) {
        $value = [string](Get-FslFixValue -InputObject $state -Name $name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return $null
}

function Get-FslFixPreflightResult {
    <#
    .SYNOPSIS
        Runs the pre-flight gates for a set of RepairAction objects and returns Result[] (Category Repair).
    .DESCRIPTION
        -Mode Plan is the read-only check used by Test-FslRepairPrerequisite: gates that only matter for a real change
        (change reference, rollback store) report Warn instead of Fail. -Mode Preview (Invoke-FslRepair -WhatIf) uses
        the strict statuses but creates nothing. -Mode Apply and -Mode Undo are strict and may create the admin-only
        rollback store.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Action,

        [ValidateSet('Plan', 'Preview', 'Apply', 'Undo')]
        [string] $Mode = 'Plan',

        [AllowNull()]
        [AllowEmptyString()]
        [string] $ChangeReference,

        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $ContainerMode,

        [hashtable] $Parameters = @{}
    )

    $actions = @($Action | Where-Object -FilterScript { $null -ne $_ })
    $isStrict = ($Mode -ne 'Plan')
    $createStateRoot = (@('Apply', 'Undo') -contains $Mode)
    $blockingStatus = if ($isStrict) { 'Fail' } else { 'Warn' }
    $config = Get-FslFixConfig
    $moduleRoot = [string]$script:FslSession['ModuleRoot']

    # ---- G1 platform ------------------------------------------------------------------------------------------
    $psVersion = $PSVersionTable.PSVersion
    $minimumVersion = [version]'7.4'
    if (-not (Test-FslIsWindows)) {
        New-FslFixPreflightResult -Gate 'G1' -Status 'Fail' -Target $script:FslFixPreflightTargetRun -Value ([string]$PSVersionTable.Platform) `
            -Expected 'Windows with PowerShell 7.4 or later' -Message 'Repairs change Windows services and the Windows registry and only run on Windows.' `
            -Recommendation 'Run the repair on the affected Windows session host.'
    }
    elseif ($psVersion -lt $minimumVersion) {
        New-FslFixPreflightResult -Gate 'G1' -Status 'Fail' -Target $script:FslFixPreflightTargetRun -Value ([string]$psVersion) `
            -Expected "PowerShell $minimumVersion or later" -Message "This PowerShell version ($psVersion) is older than the supported minimum." `
            -Recommendation 'Run the toolkit with PowerShell 7.4 or later.'
    }
    else {
        New-FslFixPreflightResult -Gate 'G1' -Status 'Pass' -Target $script:FslFixPreflightTargetRun -Value ("Windows, PowerShell $psVersion") `
            -Expected 'Windows with PowerShell 7.4 or later' -Message 'The platform supports repairs.'
    }

    # ---- G2 elevation -----------------------------------------------------------------------------------------
    $isElevated = $false
    try { $isElevated = [bool](Test-FslElevation) } catch { Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Pre-flight elevation check' }
    if ($isElevated) {
        New-FslFixPreflightResult -Gate 'G2' -Status 'Pass' -Target $script:FslFixPreflightTargetRun -Value 'Elevated' -Expected 'Elevated' `
            -Message 'The session is elevated.' -RequiresElevation $true
    }
    else {
        New-FslFixPreflightResult -Gate 'G2' -Status 'Fail' -Target $script:FslFixPreflightTargetRun -Value 'Not elevated' -Expected 'Elevated' `
            -Message 'Repairs change services and machine-wide registry values and need an elevated session.' `
            -Recommendation 'Start the toolkit elevated (Start-FSLogixToolkit.ps1 -RequestElevation) or as your admin account (-RunAsDifferentUser).' -RequiresElevation $true
    }

    # ---- G3 toolkit folder security ---------------------------------------------------------------------------
    $pathSecure = $false
    try { $pathSecure = [bool](Test-FslCoreToolkitPathSecure -Path $moduleRoot) } catch { Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Pre-flight toolkit path security' }
    if ($pathSecure) {
        New-FslFixPreflightResult -Gate 'G3' -Status 'Pass' -Target $script:FslFixPreflightTargetRun -Value $moduleRoot `
            -Expected 'Only administrators can change the toolkit files' -Message 'The toolkit folder can only be changed by administrators.'
    }
    else {
        New-FslFixPreflightResult -Gate 'G3' -Status 'Fail' -Target $script:FslFixPreflightTargetRun -Value $moduleRoot `
            -Expected 'Only administrators can change the toolkit files' `
            -Message 'The toolkit folder is not verified as administrator-only (or the check is not available on this platform). Code in a folder that non-administrators can change would run as administrator during a repair.' `
            -Recommendation 'Install the toolkit in an admin-only folder such as C:\Program Files\FSLogixToolkit and run Test-FslToolkitPathSecurity.' -RequiresElevation $true
    }

    # ---- G4 files unblocked -----------------------------------------------------------------------------------
    if (-not (Test-FslIsWindows)) {
        New-FslFixPreflightResult -Gate 'G4' -Status 'Skipped' -Target $script:FslFixPreflightTargetRun `
            -Message 'Alternate data streams (Zone.Identifier) can only be checked on Windows.' `
            -Source 'https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/unblock-file'
    }
    else {
        $blocked = @(Get-FslFixBlockedFile -Root $moduleRoot)
        if ($blocked.Count -eq 0) {
            New-FslFixPreflightResult -Gate 'G4' -Status 'Pass' -Target $script:FslFixPreflightTargetRun -Value '0 blocked files' `
                -Expected 'No Zone.Identifier streams' -Message 'No toolkit file carries the Zone.Identifier stream.' `
                -Source 'https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/unblock-file'
        }
        else {
            New-FslFixPreflightResult -Gate 'G4' -Status 'Fail' -Target $script:FslFixPreflightTargetRun -Value ("{0} blocked files" -f $blocked.Count) `
                -Expected 'No Zone.Identifier streams' `
                -Message ("Toolkit files are still marked as downloaded from the internet: {0}" -f (($blocked | Select-Object -First 5) -join '; ')) `
                -Recommendation 'Review the files and remove the mark with Unblock-File, then run the repair again.' `
                -Source 'https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/unblock-file'
        }
    }

    # ---- G5 FSLogix installed ---------------------------------------------------------------------------------
    $installation = $null
    try { $installation = Find-FslInstallation } catch { Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Pre-flight FSLogix installation check' }
    $installedVersion = $null
    if ($null -ne $installation) {
        $versionText = [string](Get-FslFixValue -InputObject $installation -Name 'Version')
        $parsed = [version]'0.0'
        if (-not [string]::IsNullOrWhiteSpace($versionText) -and [version]::TryParse($versionText, [ref]$parsed)) { $installedVersion = $parsed }
    }
    if ($null -ne $installation -and [bool](Get-FslFixValue -InputObject $installation -Name 'IsInstalled') -and $null -ne $installedVersion) {
        New-FslFixPreflightResult -Gate 'G5' -Status 'Pass' -Target $script:FslFixPreflightTargetRun -Value ([string]$installedVersion) `
            -Expected 'FSLogix installed with a readable version' -Message "FSLogix $installedVersion is installed." `
            -Source 'https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components'
    }
    else {
        New-FslFixPreflightResult -Gate 'G5' -Status 'Fail' -Target $script:FslFixPreflightTargetRun -Value 'Not detected' `
            -Expected 'FSLogix installed with a readable version' `
            -Message 'FSLogix was not detected on this computer, or its version could not be read.' `
            -Recommendation 'Run the repair on a session host with FSLogix installed (Get-FslEnvironment shows the installation state).' `
            -Source 'https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components'
    }

    # ---- G12 maintenance window -------------------------------------------------------------------------------
    New-FslFixPreflightResult -Gate 'G12' -Status 'Info' -Target $script:FslFixPreflightTargetRun -Value 'Not configured' `
        -Expected 'Optional' -Message 'No maintenance window is configured for repairs (Config/Settings.psd1, section Repair), so repairs are not time-restricted. Run changes in your own change window.'

    # ---- G14 rollback store / G15 free space / G18 run lock ---------------------------------------------------
    $stateRootCheck = $null
    try {
        $stateRootCheck = if ($createStateRoot -and $isElevated) { Test-FslFixStateRoot -Create } else { Test-FslFixStateRoot }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Pre-flight rollback store check'
    }
    $stateRootPath = if ($null -ne $stateRootCheck) { [string]$stateRootCheck['Path'] } else { $null }
    $stateRootOk = ($null -ne $stateRootCheck -and [bool]$stateRootCheck['Ok'])
    if ($stateRootOk) {
        New-FslFixPreflightResult -Gate 'G14' -Status 'Pass' -Target $script:FslFixPreflightTargetRun -Value $stateRootPath `
            -Expected 'Admin-only rollback store available' `
            -Message "The rollback store is available: $([string]$stateRootCheck['Message']) Every change is written to it (with a SHA256 manifest) and verified before the change is applied." -RequiresElevation $true
    }
    else {
        # A preview (-WhatIf) writes nothing to the store, so a store that does not exist yet only warns there.
        $storeStatus = if ($createStateRoot) { 'Fail' } else { 'Warn' }
        $message = if ($null -ne $stateRootCheck) { [string]$stateRootCheck['Message'] } else { 'The rollback store could not be checked.' }
        New-FslFixPreflightResult -Gate 'G14' -Status $storeStatus -Target $script:FslFixPreflightTargetRun -Value $stateRootPath `
            -Expected 'Admin-only rollback store available' -Message "No verified rollback store: $message" `
            -Recommendation 'Run elevated so the admin-only rollback store (Settings Repair.StateRoot) can be created and verified.' -RequiresElevation $true
    }

    $minimumFreeMB = 1024
    if ($config.ContainsKey('MinFreeSpaceMB')) {
        $parsedFree = 0
        if ([int]::TryParse([string]$config['MinFreeSpaceMB'], [ref]$parsedFree) -and $parsedFree -ge 0) { $minimumFreeMB = $parsedFree }
    }
    $freeMB = $null
    if (-not [string]::IsNullOrWhiteSpace($stateRootPath)) { $freeMB = Get-FslFixFreeSpaceMB -Path $stateRootPath }
    if ($null -eq $freeMB) {
        New-FslFixPreflightResult -Gate 'G15' -Status 'Warn' -Target $script:FslFixPreflightTargetRun -Value 'Unknown' `
            -Expected "$minimumFreeMB MB free" -Message 'The free space on the volume that holds the rollback store could not be determined.'
    }
    elseif ($freeMB -lt $minimumFreeMB) {
        New-FslFixPreflightResult -Gate 'G15' -Status $(if ($createStateRoot) { 'Fail' } else { 'Warn' }) -Target $script:FslFixPreflightTargetRun -Value ("$freeMB MB") `
            -Expected "$minimumFreeMB MB free" -Message "The volume that holds the rollback store has $freeMB MB free; the toolkit default minimum is $minimumFreeMB MB." `
            -Recommendation 'Free disk space before running repairs.'
    }
    else {
        New-FslFixPreflightResult -Gate 'G15' -Status 'Pass' -Target $script:FslFixPreflightTargetRun -Value ("$freeMB MB") `
            -Expected "$minimumFreeMB MB free" -Message "The volume that holds the rollback store has $freeMB MB free."
    }

    if ($stateRootOk) {
        $lock = Test-FslFixRunLockFree -StateRoot $stateRootPath
        if ([bool]$lock['Free']) {
            New-FslFixPreflightResult -Gate 'G18' -Status 'Pass' -Target $script:FslFixPreflightTargetRun -Value 'Free' -Expected 'One repair run at a time' `
                -Message ([string]$lock['Message'])
        }
        else {
            New-FslFixPreflightResult -Gate 'G18' -Status 'Fail' -Target $script:FslFixPreflightTargetRun -Value 'Held' -Expected 'One repair run at a time' `
                -Message ([string]$lock['Message']) -Recommendation 'Wait until the other repair run has finished.'
        }
    }
    else {
        New-FslFixPreflightResult -Gate 'G18' -Status 'Skipped' -Target $script:FslFixPreflightTargetRun -Value 'Not checked' `
            -Expected 'One repair run at a time' -Message 'The single-run lock lives in the rollback store, which is not available (see G14).'
    }

    # ---- G16 pre-repair snapshot / G21 post-repair verification ------------------------------------------------
    New-FslFixPreflightResult -Gate 'G16' -Status 'Info' -Target $script:FslFixPreflightTargetRun -Value 'Per action' `
        -Expected 'Before-state recorded before every change' `
        -Message 'The exact before state of every action is written to the rollback store (rollback.json + manifest.sha256, re-read and verified) and to the run JSON before the change is applied. The toolkit takes no VM snapshot - take one yourself if your change process requires it.'
    New-FslFixPreflightResult -Gate 'G21' -Status 'Info' -Target $script:FslFixPreflightTargetRun -Value 'Per action' `
        -Expected 'Re-detection after every change' `
        -Message 'After every change the action is detected again; the record carries VerificationStatus Verified or Failed. A failed verification is never rolled back automatically - run Undo-FslRepair -RunId <run> to restore the recorded state.'

    # ---- per-action gates --------------------------------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($ContainerMode)) {
        try { $ContainerMode = [string](Get-FslContainerMode) } catch { $ContainerMode = 'ODFC' }
    }
    $allowedScopes = @('General') + @(Resolve-FslPrefContainerScope -Mode $ContainerMode)
    $planMaxAgeMinutes = 60
    if ($config.ContainsKey('PlanMaxAgeMinutes')) {
        $parsedAge = 0
        if ([int]::TryParse([string]$config['PlanMaxAgeMinutes'], [ref]$parsedAge) -and $parsedAge -gt 0) { $planMaxAgeMinutes = $parsedAge }
    }
    $containerActionCount = 0

    foreach ($item in $actions) {
        $actionId = [string](Get-FslFixValue -InputObject $item -Name 'ActionId')
        if ([string]::IsNullOrWhiteSpace($actionId)) { continue }
        $definition = Get-FslFixDefinitionForAction -Action $item
        # The catalog is the authority for Scope, RiskTier and Kind: a -Action object supplied by the caller (a stale
        # plan, a hand-built object, the GUI) must not be able to steer which gates run. Only an action that is no
        # longer in the catalog falls back to the object's own values - and G17 blocks that action anyway.
        $scope = if ($null -ne $definition) { [string]$definition['Scope'] } else { [string](Get-FslFixValue -InputObject $item -Name 'Scope') }
        $tier = if ($null -ne $definition) { [int]$definition['RiskTier'] } else { [int](Get-FslFixValue -InputObject $item -Name 'RiskTier') }
        $kind = if ($null -ne $definition) { [string]$definition['Kind'] } else { [string](Get-FslFixValue -InputObject $item -Name 'Kind') }

        # G6 version gate
        $minimumFslVersion = $null
        if ($null -ne $definition) {
            $versionText = [string](Get-FslFixDefinitionValue -Definition $definition -Name 'MinimumFSLogixVersion' -Default '')
            $parsedMinimum = [version]'0.0'
            if (-not [string]::IsNullOrWhiteSpace($versionText) -and [version]::TryParse($versionText, [ref]$parsedMinimum)) { $minimumFslVersion = $parsedMinimum }
        }
        if ($null -eq $minimumFslVersion) {
            New-FslFixPreflightResult -Gate 'G6' -Status 'Info' -Target $actionId -Value 'No version gate' -Expected 'No version gate' `
                -Message 'This action has no FSLogix version requirement.' -Scope (Get-FslFixResultScope -Scope $scope)
        }
        elseif ($null -ne $installedVersion -and $installedVersion -ge $minimumFslVersion) {
            New-FslFixPreflightResult -Gate 'G6' -Status 'Pass' -Target $actionId -Value ([string]$installedVersion) -Expected (">= $minimumFslVersion") `
                -Message "The installed FSLogix version meets the requirement of this action." -Scope (Get-FslFixResultScope -Scope $scope)
        }
        else {
            New-FslFixPreflightResult -Gate 'G6' -Status 'Fail' -Target $actionId -Value ([string]$installedVersion) -Expected (">= $minimumFslVersion") `
                -Message "This action requires FSLogix $minimumFslVersion or later." -Scope (Get-FslFixResultScope -Scope $scope)
        }

        # G7 container mode scope
        if ($allowedScopes -contains $scope) {
            New-FslFixPreflightResult -Gate 'G7' -Status 'Pass' -Target $actionId -Value $scope -Expected ($allowedScopes -join ', ') `
                -Message "The action scope $scope is in the current container mode ($ContainerMode)." -Scope (Get-FslFixResultScope -Scope $scope)
        }
        else {
            New-FslFixPreflightResult -Gate 'G7' -Status 'Fail' -Target $actionId -Value $scope -Expected ($allowedScopes -join ', ') `
                -Message "The container mode is $ContainerMode, so $scope actions are not run." `
                -Recommendation 'Switch the container mode (Set-FslPreference -Name ContainerMode) only when this host really uses that container type.' -Scope (Get-FslFixResultScope -Scope $scope)
        }

        # G8 provenance (registry actions only)
        if ($kind -eq 'RegistryValue' -and $null -ne $definition) {
            $target = Get-FslFixDefinitionValue -Definition $definition -Name 'Target' -Default @{}
            $valueName = [string](Get-FslFixValue -InputObject $target -Name 'ValueName')
            $settingScope = [string](Get-FslFixDefinitionValue -Definition $definition -Name 'SettingScope' -Default 'Logging')
            $provenance = Get-FslFixProvenance -SettingScope $settingScope -ValueName $valueName
            $source = [string]$provenance['Source']
            $detail = [string]$provenance['SourceDetail']
            switch ($source) {
                'Registry' {
                    # 'Registry' means no WINNING RSoP row matched - not a proven absence of Group Policy. Whether values
                    # delivered by LOCAL Group Policy appear as RSOP_RegistryPolicySetting rows is an open lab item
                    # (Get-FslPolRsopData), so the message stays descriptive and the recommendation names the local editor.
                    New-FslFixPreflightResult -Gate 'G8' -Status 'Pass' -Target $actionId -Value $source -Expected 'Registry' `
                        -Message "No winning Group Policy entry was found for this value in computer RSoP, so the registry value is written: $detail" `
                        -Recommendation ("Group Policy delivery could not be ruled out completely: if FSLogix settings on this host come from Local Group Policy ({0}), check there that this setting is Not Configured, otherwise the next policy refresh re-applies the policy value over this repair." -f $script:FslFixGroupPolicyPath) `
                        -Scope (Get-FslFixResultScope -Scope $scope) `
                        -Source 'https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates'
                }
                'GroupPolicy' {
                    New-FslFixPreflightResult -Gate 'G8' -Status 'Warn' -Target $actionId -Value $source -Expected 'Registry' `
                        -Message "The value is delivered by Group Policy ($detail); the registry is not written. The plan shows the Local Group Policy setting to change instead." `
                        -Recommendation ("Change the setting in Local Group Policy ({0}), run 'GPUPDATE /Target:Computer /force' and plan again." -f $script:FslFixGroupPolicyPath) `
                        -Scope (Get-FslFixResultScope -Scope $scope) -Source 'https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates'
                }
                default {
                    New-FslFixPreflightResult -Gate 'G8' -Status 'Fail' -Target $actionId -Value $source -Expected 'Registry' `
                        -Message "Group Policy provenance is $source ($detail). A value that Group Policy delivers must not be written in the registry, so the action is blocked." `
                        -Recommendation 'Run elevated so Group Policy provenance can be checked (computer RSoP).' `
                        -Scope (Get-FslFixResultScope -Scope $scope) -RequiresElevation $true `
                        -Source 'https://learn.microsoft.com/en-us/fslogix/how-to-use-group-policy-templates'
                }
            }
        }

        # G10 container lock (container actions only)
        if ($kind -eq 'Container') {
            $containerActionCount++
            $containerPath = Get-FslFixContainerPath -Action $item
            if ([string]::IsNullOrWhiteSpace($containerPath)) {
                New-FslFixPreflightResult -Gate 'G10' -Status 'Warn' -Target $actionId -Value 'Unknown' -Expected 'Container file not in use' `
                    -Message 'The container file of this action is not known yet (select a user first); the handler tests exclusive access again immediately before it acts.' `
                    -Scope (Get-FslFixResultScope -Scope $scope)
            }
            else {
                $locked = Test-FslCtrFileLock -LiteralPath $containerPath
                if ($locked -eq $true) {
                    New-FslFixPreflightResult -Gate 'G10' -Status 'Fail' -Target $actionId -Value 'In use' -Expected 'Container file not in use' `
                        -Message 'The container file is open (attached or in use by a session host); it is never moved while it is in use.' `
                        -Recommendation 'Make sure the user is signed out of every session host and try again.' -Scope (Get-FslFixResultScope -Scope $scope)
                }
                elseif ($locked -eq $false) {
                    New-FslFixPreflightResult -Gate 'G10' -Status 'Pass' -Target $actionId -Value 'Not in use' -Expected 'Container file not in use' `
                        -Message 'The container file could be opened exclusively; the handler repeats this check immediately before it acts.' -Scope (Get-FslFixResultScope -Scope $scope)
                }
                else {
                    New-FslFixPreflightResult -Gate 'G10' -Status 'Warn' -Target $actionId -Value 'Unknown' -Expected 'Container file not in use' `
                        -Message 'Whether the container file is in use could not be determined (access denied or an I/O error).' -Scope (Get-FslFixResultScope -Scope $scope)
                }
            }
        }

        # G13 change reference (derived from the catalog risk tier, not from the supplied action object)
        $needsReference = if ($null -ne $definition) { [bool](Test-FslFixChangeReferenceRequired -RiskTier $tier) }
        else { [bool](Get-FslFixValue -InputObject $item -Name 'RequiresChangeReference') }
        if (-not $needsReference) {
            New-FslFixPreflightResult -Gate 'G13' -Status 'Pass' -Target $actionId -Value 'Not required' -Expected 'Not required' `
                -Message "Risk tier $tier does not require a change reference (Settings Repair.RequireChangeReferenceTier)." -Scope (Get-FslFixResultScope -Scope $scope)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($ChangeReference)) {
            New-FslFixPreflightResult -Gate 'G13' -Status 'Pass' -Target $actionId -Value 'Supplied' -Expected 'Required' `
                -Message "A change reference was supplied for this risk tier ($tier)." -Scope (Get-FslFixResultScope -Scope $scope)
        }
        else {
            New-FslFixPreflightResult -Gate 'G13' -Status $blockingStatus -Target $actionId -Value 'Missing' -Expected 'Required' `
                -Message "Risk tier $tier requires a change reference (Settings Repair.RequireChangeReferenceTier)." `
                -Recommendation 'Pass -ChangeReference "<your change record>" to Invoke-FslRepair.' -Scope (Get-FslFixResultScope -Scope $scope)
        }

        # G17 plan freshness and drift
        $plannedAt = [datetime]::MinValue
        $plannedText = [string](Get-FslFixValue -InputObject $item -Name 'PlannedAt')
        $hasPlannedAt = [datetime]::TryParse($plannedText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$plannedAt)
        $ageMinutes = if ($hasPlannedAt) { [math]::Round(((Get-Date) - $plannedAt).TotalMinutes, 1) } else { $null }
        if ($null -eq $definition) {
            New-FslFixPreflightResult -Gate 'G17' -Status 'Fail' -Target $actionId -Value 'Unknown action' -Expected 'Known catalog action' `
                -Message "The action $actionId is not in the repair catalog (Config/Repairs.psd1)." -Scope (Get-FslFixResultScope -Scope $scope)
        }
        elseif ($hasPlannedAt -and $ageMinutes -gt $planMaxAgeMinutes) {
            New-FslFixPreflightResult -Gate 'G17' -Status $blockingStatus -Target $actionId -Value ("$ageMinutes minutes old") `
                -Expected "Younger than $planMaxAgeMinutes minutes" -Message 'The plan for this action is older than the configured maximum plan age.' `
                -Recommendation 'Run Get-FslRepairPlan again and repair from the fresh plan.' -Scope (Get-FslFixResultScope -Scope $scope)
        }
        else {
            $fresh = Invoke-FslFixDetect -Definition $definition -Parameters $Parameters
            $currentFingerprint = Get-FslFixStateFingerprint -Kind $kind -State ($fresh.BeforeState)
            $plannedFingerprint = [string](Get-FslFixValue -InputObject $item -Name 'Fingerprint')
            if ([string]::IsNullOrWhiteSpace($plannedFingerprint) -or [string]::IsNullOrWhiteSpace($currentFingerprint)) {
                New-FslFixPreflightResult -Gate 'G17' -Status 'Warn' -Target $actionId -Value 'Unknown' -Expected 'Unchanged since the plan' `
                    -Message 'The before state of this action could not be fingerprinted, so drift since the plan cannot be ruled out.' -Scope (Get-FslFixResultScope -Scope $scope)
            }
            elseif ([string]::Equals($plannedFingerprint, $currentFingerprint, [System.StringComparison]::OrdinalIgnoreCase)) {
                New-FslFixPreflightResult -Gate 'G17' -Status 'Pass' -Target $actionId -Value 'Unchanged' -Expected 'Unchanged since the plan' `
                    -Message "The state of this action is unchanged since the plan was made$(if ($null -ne $ageMinutes) { " ($ageMinutes minutes ago)" } else { '' })." -Scope (Get-FslFixResultScope -Scope $scope)
            }
            else {
                New-FslFixPreflightResult -Gate 'G17' -Status 'Fail' -Target $actionId -Value 'Changed' -Expected 'Unchanged since the plan' `
                    -Message "The state changed after the plan was made (current: $([string]$fresh.CurrentValue)); the action is blocked to avoid acting on stale information." `
                    -Recommendation 'Run Get-FslRepairPlan again and review the new plan.' -Scope (Get-FslFixResultScope -Scope $scope)
            }
        }
    }

    if ($containerActionCount -eq 0) {
        New-FslFixPreflightResult -Gate 'G10' -Status 'Info' -Target $script:FslFixPreflightTargetRun -Value 'No container action' `
            -Expected 'Container file not in use' -Message 'No container action is part of this run, so no container file is checked for exclusive access.'
    }
}

function Get-FslFixResultScope {
    <#
    .SYNOPSIS
        Maps an action scope to a Result scope (General|ODFC|Profiles).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Scope
    )

    switch ($Scope) {
        'ODFC' { return 'ODFC' }
        'Profiles' { return 'Profiles' }
        default { return 'General' }
    }
}
