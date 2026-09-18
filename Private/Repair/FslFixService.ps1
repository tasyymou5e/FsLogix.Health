# Private service wrappers and service repair handlers (Agent P3-5, prefix *-FslFix*).
#
# Reads use Get-Service (ServiceController.StartType / .Status), writes use Set-Service -StartupType and Start-Service.
# The toolkit NEVER stops or restarts a service: Microsoft documents no safe stop/restart procedure for the FSLogix
# services, and stopping them would disrupt every signed-in user.
#
# Sources:
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.management/get-service
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.management/set-service
#     (-StartupType: Automatic, AutomaticDelayedStart, Disabled, InvalidValue, Manual; Windows only; needs elevation)
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.management/start-service
#     ("You can start only the services that have a start type of Manual, Automatic, or Automatic (Delayed Start).")
#   https://learn.microsoft.com/dotnet/api/system.serviceprocess.servicecontroller.starttype
#     (System.ServiceProcess.ServiceStartMode: Boot, System, Automatic, Manual, Disabled - a delayed automatic start
#      is reported as Automatic, so a delayed-start service is never "corrected" by these repairs.)
#   https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components
#   https://learn.microsoft.com/en-us/fslogix/troubleshooting-vhd-disk-compaction

# Start types a repair may write (Set-Service -StartupType values the toolkit uses).
$script:FslFixServiceStartTypes = @('Automatic', 'Manual')

# Allow-list of services a repair (or a rollback) may touch, mirroring the registry value allow-list in
# FslFixRegistry.ps1: the service names come from Config/Repairs.psd1 and from the rollback store, so a damaged or
# tampered data file must never be able to change the start type of an unrelated Windows service.
#   frxsvc / frxccds  https://learn.microsoft.com/en-us/fslogix/reference-service-drivers-components
#   defragsvc / smphost  https://learn.microsoft.com/en-us/fslogix/troubleshooting-vhd-disk-compaction
$script:FslFixServiceAllowList = @('frxsvc', 'frxccds', 'defragsvc', 'smphost')

function Test-FslFixServiceTarget {
    <#
    .SYNOPSIS
        Returns @{ Ok; Message } for a service name against the repair allow-list.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return @{ Ok = $false; Message = 'The repair target has no service name.' }
    }
    if (@($script:FslFixServiceAllowList | Where-Object -FilterScript { [string]::Equals([string]$_, $Name.Trim(), [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
        return @{ Ok = $false; Message = "The service '$Name' is not on the repair allow-list ($($script:FslFixServiceAllowList -join ', ')); no repair changes it." }
    }
    return @{ Ok = $true; Message = "The service $Name is on the repair allow-list." }
}

function Get-FslFixServiceEntry {
    <#
    .SYNOPSIS
        Reads one service. Returns @{ Name; Exists; DisplayName; StartType; Status; Message }. Never throws.
    .DESCRIPTION
        Windows only (Get-Service is a Windows-only cmdlet in PowerShell 7); on other platforms Exists is $false
        (tests replace this wrapper).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    $result = @{ Name = $Name; Exists = $false; DisplayName = $null; StartType = $null; Status = $null; Message = $null }
    if (-not (Test-FslIsWindows)) {
        $result['Message'] = 'Services can only be read on Windows.'
        return $result
    }
    try {
        # -ErrorAction SilentlyContinue: a service that is not installed is a normal outcome, not an error
        # (the exception type is not available on every platform, so no typed catch is used).
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue -ErrorVariable 'serviceError'
        if ($null -eq $service) {
            $detail = if (@($serviceError).Count -gt 0) { [string]$serviceError[0].Exception.Message } else { '' }
            $result['Message'] = "The service $Name was not found on this computer. $detail".Trim()
            return $result
        }
        $result['Exists'] = $true
        $result['DisplayName'] = [string]$service.DisplayName
        $result['StartType'] = [string]$service.StartType
        $result['Status'] = [string]$service.Status
        $result['Message'] = "$Name is $([string]$service.Status) with start type $([string]$service.StartType)."
        return $result
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Read service $Name"
        $result['Message'] = "The service $Name could not be read: $($_.Exception.Message)"
        return $result
    }
}

function Set-FslFixServiceStartTypeEntry {
    <#
    .SYNOPSIS
        Sets a service start type with Set-Service. Returns @{ Success; Message }.
    .DESCRIPTION
        Only Automatic and Manual are written by repairs. Internal repair write inside an already confirmed run -
        the caller owns ShouldProcess, so -WhatIf/-Confirm are switched off here.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Low-level wrapper; ShouldProcess is handled by Invoke-FslRepair/Undo-FslRepair before the call.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('Automatic', 'Manual')]
        [string] $StartupType
    )

    $allowed = Test-FslFixServiceTarget -Name $Name
    if (-not $allowed['Ok']) { return @{ Success = $false; Message = $allowed['Message'] } }
    if (-not (Test-FslIsWindows)) { return @{ Success = $false; Message = 'Set-Service is only available on Windows.' } }
    try {
        Set-Service -Name $Name -StartupType $StartupType -WhatIf:$false -Confirm:$false -ErrorAction Stop
        return @{ Success = $true; Message = "Set the $Name start type to $StartupType." }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Set start type of $Name to $StartupType"
        return @{ Success = $false; Message = "The $Name start type could not be set to ${StartupType}: $($_.Exception.Message)" }
    }
}

function Start-FslFixServiceEntry {
    <#
    .SYNOPSIS
        Starts a stopped service once with Start-Service. Returns @{ Success; Message }. Never stops or restarts.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Low-level wrapper; ShouldProcess is handled by Invoke-FslRepair before the call.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    $allowed = Test-FslFixServiceTarget -Name $Name
    if (-not $allowed['Ok']) { return @{ Success = $false; Message = $allowed['Message'] } }
    if (-not (Test-FslIsWindows)) { return @{ Success = $false; Message = 'Start-Service is only available on Windows.' } }
    try {
        Start-Service -Name $Name -WhatIf:$false -Confirm:$false -ErrorAction Stop
        return @{ Success = $true; Message = "Sent a start request to $Name." }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Start service $Name"
        return @{ Success = $false; Message = "The service $Name could not be started: $($_.Exception.Message)" }
    }
}

function Get-FslFixServiceStateTable {
    <#
    .SYNOPSIS
        Reads every service of a definition and returns the nested Services hashtable used in before/after states.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Name
    )

    $services = @{}
    foreach ($serviceName in $Name) {
        $entry = Get-FslFixServiceEntry -Name $serviceName
        $services[$serviceName] = @{
            Exists      = [bool]$entry['Exists']
            StartType   = [string]$entry['StartType']
            Status      = [string]$entry['Status']
            DisplayName = [string]$entry['DisplayName']
        }
    }
    return $services
}

function Get-FslFixServiceNameList {
    <#
    .SYNOPSIS
        Returns the service names of a catalog definition Target as a string array.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition
    )

    $target = Get-FslFixDefinitionValue -Definition $Definition -Name 'Target' -Default @{}
    # Assign first: @(Get-FslFixValue ...) around the call would keep the returned array as ONE element.
    $rawNames = Get-FslFixValue -InputObject $target -Name 'ServiceName'
    $names = @($rawNames | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object -Process { [string]$_ })
    return [string[]]$names
}

function Get-FslFixServiceStartTypeState {
    <#
    .SYNOPSIS
        Detect handler for service start-type repairs (contract P3.5 handler interface).
    .DESCRIPTION
        Needed when a service exists and its start type differs from the catalog ProposedValue (optionally only when
        the current start type is in FromStartType, e.g. only Disabled -> Manual), or - with StartIfStopped - when the
        service is Stopped and its start type allows starting. Services that are not installed are ignored.
        A start is only planned when the documented dependency (DependsOn) is Running, because the apply handler
        refuses to start the service otherwise; planning it anyway would make the post-change verification fail for a
        repair that behaved exactly as designed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition,

        [hashtable] $Parameters = @{}
    )

    $null = $Parameters
    $names = @(Get-FslFixServiceNameList -Definition $Definition)
    $proposed = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'ProposedValue' -Default 'Automatic')
    $rawFromStartType = Get-FslFixDefinitionValue -Definition $Definition -Name 'FromStartType' -Default @()
    $fromStartType = @($rawFromStartType | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object -Process { [string]$_ })
    $startIfStopped = [bool](Get-FslFixDefinitionValue -Definition $Definition -Name 'StartIfStopped' -Default $false)
    $dependsOn = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'DependsOn' -Default '')
    $services = Get-FslFixServiceStateTable -Name $names

    # The apply handler only starts a stopped service after the documented dependency is Running, so detection (and
    # therefore the post-change verification) must use the same condition.
    $dependencyOk = $true
    $dependencyNote = ''
    if ($startIfStopped -and -not [string]::IsNullOrWhiteSpace($dependsOn)) {
        $dependency = Get-FslFixServiceEntry -Name $dependsOn
        $dependencyOk = ([bool]$dependency['Exists'] -and [string]$dependency['Status'] -eq 'Running')
        if (-not $dependencyOk) {
            $dependencyNote = " A stopped service is not started while the service it depends on ($dependsOn) is not Running."
        }
    }

    $detection = [pscustomobject]@{
        Needed        = $false
        CurrentValue  = $null
        ProposedValue = $proposed
        Target        = ($names -join '; ')
        BeforeState   = @{ Kind = 'ServiceStartType'; ServiceNames = ($names -join '; '); Services = $services }
        BlockReason   = $null
        GuidanceOnly  = $false
        Guidance      = $null
        Message       = $null
    }

    $current = [System.Collections.Generic.List[string]]::new()
    $todo = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($serviceName in $names) {
        $entry = $services[$serviceName]
        if (-not [bool]$entry['Exists']) {
            $missing.Add($serviceName)
            $current.Add(('{0}=not installed' -f $serviceName))
            continue
        }
        $startType = [string]$entry['StartType']
        $status = [string]$entry['Status']
        $current.Add(('{0}={1} ({2})' -f $serviceName, $startType, $status))
        $startTypeWrong = $false
        if (-not [string]::Equals($startType, $proposed, [System.StringComparison]::OrdinalIgnoreCase)) {
            $startTypeWrong = ($fromStartType.Count -eq 0 -or @($fromStartType | Where-Object -FilterScript { [string]::Equals([string]$_, $startType, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
        }
        $needsStart = ($startIfStopped -and $dependencyOk -and $status -eq 'Stopped' -and -not [string]::Equals($startType, 'Disabled', [System.StringComparison]::OrdinalIgnoreCase))
        if ($startTypeWrong) { $todo.Add(('{0}: start type {1} -> {2}' -f $serviceName, $startType, $proposed)) }
        if ($needsStart) { $todo.Add(('{0}: start the stopped service' -f $serviceName)) }
    }

    $detection.CurrentValue = ($current -join '; ')
    $detection.Needed = ($todo.Count -gt 0)
    if ($missing.Count -eq $names.Count -and $names.Count -gt 0) {
        $detection.Message = ('None of the services ({0}) are installed on this computer; nothing to change.' -f ($names -join ', '))
        return $detection
    }
    if ($todo.Count -eq 0) {
        $detection.Message = ('The service configuration already matches the documented state: {0}.{1}' -f $detection.CurrentValue, $dependencyNote)
        return $detection
    }
    $detection.Message = ('Planned changes: {0}. Current: {1}.{2}' -f ($todo -join '; '), $detection.CurrentValue, $dependencyNote)
    return $detection
}

function Set-FslFixServiceStartTypeState {
    <#
    .SYNOPSIS
        Apply handler for service start-type repairs (contract P3.5 handler interface).
    .DESCRIPTION
        Sets the start type of every service that needs it (only from FromStartType when the catalog restricts it) and,
        with StartIfStopped, starts a stopped service - but only after the documented dependency (DependsOn) is Running.
        Returns @{ Success; AfterState; Created; Message }. Nothing is ever stopped or restarted.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Handler called by Invoke-FslRepair after ShouldProcess, preflight and a verified rollback entry.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition,

        [Parameter(Mandatory)]
        [pscustomobject] $Action,

        [Parameter(Mandatory)]
        [hashtable] $BeforeState
    )

    $null = $Action
    $names = @(Get-FslFixServiceNameList -Definition $Definition)
    $proposed = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'ProposedValue' -Default 'Automatic')
    $rawFromStartType = Get-FslFixDefinitionValue -Definition $Definition -Name 'FromStartType' -Default @()
    $fromStartType = @($rawFromStartType | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object -Process { [string]$_ })
    $startIfStopped = [bool](Get-FslFixDefinitionValue -Definition $Definition -Name 'StartIfStopped' -Default $false)
    $dependsOn = [string](Get-FslFixDefinitionValue -Definition $Definition -Name 'DependsOn' -Default '')
    $before = Get-FslFixValue -InputObject $BeforeState -Name 'Services'
    $messages = [System.Collections.Generic.List[string]]::new()
    $success = $true

    if ($script:FslFixServiceStartTypes -notcontains $proposed) {
        return @{ Success = $false; AfterState = $BeforeState; Created = @(); Message = "Repairs only set the start types $($script:FslFixServiceStartTypes -join ' or '); '$proposed' was refused." }
    }

    foreach ($serviceName in $names) {
        $entry = if ($before -is [System.Collections.IDictionary] -and $before.Contains($serviceName)) { $before[$serviceName] } else { $null }
        if ($null -eq $entry -or -not [bool](Get-FslFixValue -InputObject $entry -Name 'Exists')) {
            $messages.Add("$serviceName is not installed; skipped.")
            continue
        }
        $startType = [string](Get-FslFixValue -InputObject $entry -Name 'StartType')
        if (-not [string]::Equals($startType, $proposed, [System.StringComparison]::OrdinalIgnoreCase)) {
            $allowed = ($fromStartType.Count -eq 0 -or @($fromStartType | Where-Object -FilterScript { [string]::Equals([string]$_, $startType, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
            if ($allowed) {
                $outcome = Set-FslFixServiceStartTypeEntry -Name $serviceName -StartupType $proposed
                $messages.Add([string]$outcome['Message'])
                if (-not [bool]$outcome['Success']) { $success = $false }
            }
            else {
                $messages.Add("$serviceName has start type $startType, which this action does not change.")
            }
        }
        if ($startIfStopped -and [string](Get-FslFixValue -InputObject $entry -Name 'Status') -eq 'Stopped') {
            $dependencyOk = $true
            if (-not [string]::IsNullOrWhiteSpace($dependsOn)) {
                $dependency = Get-FslFixServiceEntry -Name $dependsOn
                $dependencyOk = ([bool]$dependency['Exists'] -and [string]$dependency['Status'] -eq 'Running')
                if (-not $dependencyOk) {
                    $messages.Add("$serviceName was not started: the service it depends on ($dependsOn) is not Running.")
                }
            }
            if ($dependencyOk) {
                $outcome = Start-FslFixServiceEntry -Name $serviceName
                $messages.Add([string]$outcome['Message'])
                if (-not [bool]$outcome['Success']) { $success = $false }
            }
        }
    }

    return @{
        Success    = $success
        AfterState = @{ Kind = 'ServiceStartType'; ServiceNames = ($names -join '; '); Services = (Get-FslFixServiceStateTable -Name $names) }
        Created    = @()
        Message    = ($messages -join ' ')
    }
}

function Restore-FslFixServiceStartType {
    <#
    .SYNOPSIS
        Rollback handler for service start-type repairs (contract P3.5 handler interface). Returns @{ Success; Message }.
    .DESCRIPTION
        Restores the recorded start type of every service that was changed. A service that the repair started is left
        running: the toolkit never stops FSLogix (or Windows) services.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Handler called by Undo-FslRepair after ShouldProcess and the rollback-store integrity check.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition,

        [Parameter(Mandatory)]
        [hashtable] $BeforeState,

        [AllowNull()]
        [hashtable] $AfterState
    )

    $null = $Definition
    $null = $AfterState
    $before = Get-FslFixValue -InputObject $BeforeState -Name 'Services'
    if (-not ($before -is [System.Collections.IDictionary])) {
        return @{ Success = $false; Message = 'The recorded state has no service information; nothing was restored.' }
    }
    $messages = [System.Collections.Generic.List[string]]::new()
    $success = $true
    foreach ($serviceName in @($before.Keys)) {
        $entry = $before[$serviceName]
        if (-not [bool](Get-FslFixValue -InputObject $entry -Name 'Exists')) { continue }
        $recorded = [string](Get-FslFixValue -InputObject $entry -Name 'StartType')
        $currentEntry = Get-FslFixServiceEntry -Name ([string]$serviceName)
        if (-not [bool]$currentEntry['Exists']) {
            $messages.Add("$serviceName is no longer installed; skipped.")
            continue
        }
        if ([string]::Equals([string]$currentEntry['StartType'], $recorded, [System.StringComparison]::OrdinalIgnoreCase)) {
            $messages.Add("$serviceName already has the recorded start type $recorded.")
            continue
        }
        if ($script:FslFixServiceStartTypes -notcontains $recorded) {
            # Disabled is restored too: it is the state the computer had before the repair.
            if ([string]::Equals($recorded, 'Disabled', [System.StringComparison]::OrdinalIgnoreCase)) {
                $outcome = Set-FslFixServiceStartTypeDisabled -Name ([string]$serviceName)
                $messages.Add([string]$outcome['Message'])
                if (-not [bool]$outcome['Success']) { $success = $false }
                continue
            }
            $messages.Add("The recorded start type '$recorded' of $serviceName is not restored by the toolkit.")
            $success = $false
            continue
        }
        $outcome = Set-FslFixServiceStartTypeEntry -Name ([string]$serviceName) -StartupType $recorded
        $messages.Add([string]$outcome['Message'])
        if (-not [bool]$outcome['Success']) { $success = $false }
    }
    $messages.Add('If the repair started a service, it is left running: the toolkit never stops services.')
    return @{ Success = $success; Message = ($messages -join ' ') }
}

function Set-FslFixServiceStartTypeDisabled {
    <#
    .SYNOPSIS
        Sets a service start type back to Disabled (rollback only). Returns @{ Success; Message }.
    .DESCRIPTION
        Separate from Set-FslFixServiceStartTypeEntry so that a repair can never disable a service: only a rollback
        restores the Disabled state a computer had before the repair.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Low-level wrapper; ShouldProcess is handled by Undo-FslRepair before the call.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    $allowed = Test-FslFixServiceTarget -Name $Name
    if (-not $allowed['Ok']) { return @{ Success = $false; Message = $allowed['Message'] } }
    if (-not (Test-FslIsWindows)) { return @{ Success = $false; Message = 'Set-Service is only available on Windows.' } }
    try {
        Set-Service -Name $Name -StartupType 'Disabled' -WhatIf:$false -Confirm:$false -ErrorAction Stop
        return @{ Success = $true; Message = "Restored the $Name start type to Disabled." }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Restore start type of $Name to Disabled"
        return @{ Success = $false; Message = "The $Name start type could not be restored to Disabled: $($_.Exception.Message)" }
    }
}

function Get-FslFixServiceStartState {
    <#
    .SYNOPSIS
        Detect handler for the "start the stopped service" repair (contract P3.5 handler interface).
    .DESCRIPTION
        Needed only when the service exists, is Stopped and its start type is Automatic (the documented start type).
        A Disabled or Manual start type is reported as not needed with a pointer to the start-type action, because
        Start-Service can only start Manual, Automatic or delayed-automatic services.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition,

        [hashtable] $Parameters = @{}
    )

    $null = $Parameters
    $names = @(Get-FslFixServiceNameList -Definition $Definition)
    $serviceName = if ($names.Count -gt 0) { $names[0] } else { '' }
    $entry = Get-FslFixServiceEntry -Name $serviceName
    $beforeState = @{
        Kind        = 'ServiceStart'
        ServiceName = $serviceName
        Exists      = [bool]$entry['Exists']
        StartType   = [string]$entry['StartType']
        Status      = [string]$entry['Status']
        DisplayName = [string]$entry['DisplayName']
    }
    $detection = [pscustomobject]@{
        Needed        = $false
        CurrentValue  = if ([bool]$entry['Exists']) { ('{0} ({1})' -f [string]$entry['Status'], [string]$entry['StartType']) } else { 'not installed' }
        ProposedValue = 'Running'
        Target        = $serviceName
        BeforeState   = $beforeState
        BlockReason   = $null
        GuidanceOnly  = $false
        Guidance      = $null
        Message       = $null
    }

    if (-not [bool]$entry['Exists']) {
        $detection.Message = "The service $serviceName is not installed on this computer."
        return $detection
    }
    $status = [string]$entry['Status']
    $startType = [string]$entry['StartType']
    if ($status -ne 'Stopped') {
        $detection.Message = "$serviceName is $status; nothing to start."
        return $detection
    }
    if (-not [string]::Equals($startType, 'Automatic', [System.StringComparison]::OrdinalIgnoreCase)) {
        $detection.Message = "$serviceName is Stopped but its start type is $startType. Correct the start type first (FIX-SVC-01 for frxsvc, FIX-SVC-03 for frxccds); Start-Service cannot start a Disabled service."
        return $detection
    }
    $detection.Needed = $true
    $detection.Message = "$serviceName is Stopped while its start type is Automatic; the repair sends one start request (no stop, no restart, no retry loop)."
    return $detection
}

function Start-FslFixServiceState {
    <#
    .SYNOPSIS
        Apply handler for the "start the stopped service" repair (contract P3.5 handler interface).
    .DESCRIPTION
        Sends a single Start-Service request and re-reads the service. Returns @{ Success; AfterState; Created; Message }.
        There is no rollback: the toolkit never stops FSLogix services (RollbackMethod None in the catalog).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Handler called by Invoke-FslRepair after ShouldProcess, preflight and a verified rollback entry.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition,

        [Parameter(Mandatory)]
        [pscustomobject] $Action,

        [Parameter(Mandatory)]
        [hashtable] $BeforeState
    )

    $null = $Definition
    $null = $Action
    $serviceName = [string]$BeforeState['ServiceName']
    $outcome = Start-FslFixServiceEntry -Name $serviceName
    $entry = Get-FslFixServiceEntry -Name $serviceName
    $afterState = @{
        Kind        = 'ServiceStart'
        ServiceName = $serviceName
        Exists      = [bool]$entry['Exists']
        StartType   = [string]$entry['StartType']
        Status      = [string]$entry['Status']
        DisplayName = [string]$entry['DisplayName']
    }
    $success = ([bool]$outcome['Success'] -and @('Running', 'StartPending') -contains [string]$entry['Status'])
    return @{
        Success    = $success
        AfterState = $afterState
        Created    = @()
        Message    = ('{0} The service is now {1}.' -f [string]$outcome['Message'], [string]$entry['Status'])
    }
}
