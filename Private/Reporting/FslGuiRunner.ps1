# Private helpers for Show-FslDashboard: ONE persistent background runspace and a one-at-a-time operation queue.
# No WPF types in this file. The dashboard polls Step-FslGuiRunner from a DispatcherTimer on the UI thread;
# results are applied to the DataTables on the UI thread only.
# Sources:
#   https://learn.microsoft.com/dotnet/api/system.management.automation.runspaces.initialsessionstate.createdefault
#   https://learn.microsoft.com/dotnet/api/system.management.automation.runspaces.runspaceavailability
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.core/import-module
#   https://learn.microsoft.com/dotnet/api/system.management.automation.runspaces.runspacefactory.createrunspace
#   https://learn.microsoft.com/dotnet/api/system.management.automation.runspaces.runspace.openasync
#   https://learn.microsoft.com/dotnet/api/system.management.automation.powershell.begininvoke
#   https://learn.microsoft.com/dotnet/api/system.management.automation.powershell.endinvoke
#   https://learn.microsoft.com/dotnet/api/system.management.automation.powershell.beginstop
#   https://learn.microsoft.com/dotnet/api/system.management.automation.powershell.stop

function Get-FslGuiBackgroundScript {
    <#
    .SYNOPSIS
        Returns the script text executed in the background runspace for one queued operation.
    .DESCRIPTION
        The script imports the module manifest into the runspace (first run), so only exported (public) functions are
        called. Parameters are passed to a command only when that command declares them (Get-Command). The script returns one envelope
        object: Operation, Results (objects with Category and Status), Data (hashtable), Errors (new entries of
        Get-FslErrorLog in the background session) and Failures (terminating errors caught by the script).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $script = {
        param(
            [string] $Operation,
            [hashtable] $Parameters,
            [string] $ManifestPath
        )

        Set-StrictMode -Version Latest
        # The runspace is opened without InitialSessionState.ImportPSModule (see Open-FslGuiRunspace): import the manifest
        # once into the global session state of this persistent runspace. A failure is terminating (EndInvoke -> Failed).
        if ($null -eq (Get-Module -Name 'FSLogixToolkit')) {
            Import-Module -Name $ManifestPath -ErrorAction Stop
        }
        $started = [datetime]::UtcNow
        $results = [System.Collections.Generic.List[object]]::new()
        $data = @{}
        $failures = [System.Collections.Generic.List[object]]::new()
        $errorsBefore = 0
        try { $errorsBefore = @(Get-FslErrorLog).Count } catch { $errorsBefore = 0 }

        $newFailure = {
            param([object] $Record, [string] $Context)
            $exception = $null
            if ($Record -is [System.Management.Automation.ErrorRecord]) { $exception = $Record.Exception }
            elseif ($Record -is [System.Exception]) { $exception = $Record }
            [pscustomobject]@{
                Timestamp     = (Get-Date).ToString('o')
                Component     = 'GUI'
                Context       = $Context
                Message       = if ($null -ne $exception) { $exception.Message } else { [string]$Record }
                ExceptionType = if ($null -ne $exception) { $exception.GetType().FullName } else { $null }
                CategoryInfo  = if ($Record -is [System.Management.Automation.ErrorRecord]) { [string]$Record.CategoryInfo } else { $null }
                TargetObject  = if ($Record -is [System.Management.Automation.ErrorRecord]) { [string]$Record.TargetObject } else { $null }
            }
        }

        # Invokes a module command with only the parameters it declares. Required names must be declared.
        $invokeDeclared = {
            param([string] $CommandName, [hashtable] $Arguments, [string[]] $Required)
            $command = Get-Command -Name $CommandName -CommandType Function -ErrorAction SilentlyContinue
            if ($null -eq $command) {
                throw [System.Management.Automation.CommandNotFoundException]::new("'$CommandName' is not available in this FSLogixToolkit build.")
            }
            foreach ($name in @($Required)) {
                if (-not [string]::IsNullOrEmpty($name) -and -not $command.Parameters.ContainsKey($name)) {
                    throw [System.InvalidOperationException]::new("'$CommandName' does not declare -$name in this FSLogixToolkit build; the operation was not started.")
                }
            }
            $splat = @{}
            foreach ($key in @($Arguments.Keys)) {
                $value = $Arguments[$key]
                if ($null -eq $value) { continue }
                if (-not $command.Parameters.ContainsKey($key)) { continue }
                if ($key -eq 'Confirm') { $splat[$key] = [bool]$value; continue }
                if ($value -is [bool] -and -not $value) { continue }
                if ($value -is [string] -and [string]::IsNullOrEmpty($value)) { continue }
                $splat[$key] = $value
            }
            & $command @splat
        }

        $addResults = {
            param([object[]] $Items)
            foreach ($item in @($Items)) {
                if ($null -eq $item) { continue }
                if ($null -ne $item.PSObject.Properties['Category'] -and $null -ne $item.PSObject.Properties['Status']) { $results.Add($item) }
            }
        }

        $offline = $false
        if ($Parameters.ContainsKey('Offline')) { $offline = [bool]$Parameters['Offline'] }

        try {
            switch ($Operation) {
                'Initialize' {
                    $init = @{}
                    if (-not [string]::IsNullOrEmpty([string]$Parameters['LogRoot'])) { $init['LogRoot'] = [string]$Parameters['LogRoot'] }
                    if (-not [string]::IsNullOrEmpty([string]$Parameters['ReportRoot'])) { $init['ReportRoot'] = [string]$Parameters['ReportRoot'] }
                    if ([bool]$Parameters['DebugLogging']) { $init['EnableDebugLogging'] = $true }
                    if ($init.Count -eq 0) { $init['Force'] = $true }
                    $data['Session'] = Initialize-FslSession @init
                }
                'Debug' {
                    $init = @{ Force = $true }
                    if (-not [string]::IsNullOrEmpty([string]$Parameters['LogRoot'])) { $init['LogRoot'] = [string]$Parameters['LogRoot'] }
                    if (-not [string]::IsNullOrEmpty([string]$Parameters['ReportRoot'])) { $init['ReportRoot'] = [string]$Parameters['ReportRoot'] }
                    if ([bool]$Parameters['DebugLogging']) { $init['EnableDebugLogging'] = $true }
                    $data['Session'] = Initialize-FslSession @init
                }
                'HealthCheck' {
                    $arguments = @{ Category = [string[]]$Parameters['Category']; ContainerScope = [string]$Parameters['ContainerScope']; Offline = $offline }
                    & $addResults @(& $invokeDeclared 'Invoke-FslHealthCheck' $arguments @('Category', 'ContainerScope'))
                }
                'Discovery' {
                    $discovery = @(& $invokeDeclared 'Get-FslDiscovery' @{ Offline = $offline } @())
                    $reportArguments = @{ Offline = $offline }
                    if ($discovery.Count -gt 0) {
                        $data['Discovery'] = $discovery[$discovery.Count - 1]
                        $reportArguments['Discovery'] = $data['Discovery']
                    }
                    # Same rule as Invoke-FslHealthCheck: keep General and the container mode's scopes (Target 'Mode' always
                    # kept, it reports the mode mismatch), so Profiles-scope rows are not shown in ODFC mode. The operation
                    # replaces all Discovery scopes, so rows from a previous mode are removed.
                    $discoveryMode = [string]$Parameters['ContainerScope']
                    $allowedScopes = switch ($discoveryMode) {
                        'ODFC' { @('General', 'ODFC') }
                        'Profiles' { @('General', 'Profiles') }
                        default { @('General', 'ODFC', 'Profiles') }
                    }
                    foreach ($reportItem in @(& $invokeDeclared 'Get-FslDiscoveryReport' $reportArguments @())) {
                        if ($null -eq $reportItem) { continue }
                        $scopeProperty = $reportItem.PSObject.Properties['Scope']
                        $itemScope = if ($null -ne $scopeProperty -and -not [string]::IsNullOrWhiteSpace([string]$scopeProperty.Value)) { [string]$scopeProperty.Value } else { 'General' }
                        $targetProperty = $reportItem.PSObject.Properties['Target']
                        $isModeRow = $null -ne $targetProperty -and [string]$targetProperty.Value -eq 'Mode'
                        if ($itemScope -in $allowedScopes -or $isModeRow) { & $addResults @($reportItem) }
                    }
                }
                'Environment' {
                    & $addResults @(& $invokeDeclared 'Get-FslEnvironment' @{ Offline = $offline } @())
                }
                'Prerequisites' {
                    # No -AllowInstall: the dashboard never installs modules.
                    & $addResults @(& $invokeDeclared 'Initialize-FslPrerequisites' @{} @())
                }
                'ErrorLog' {
                    $data['ErrorLog'] = @(Get-FslErrorLog)
                }
                'DailyRun' {
                    $arguments = @{ ContainerScope = [string]$Parameters['ContainerScope']; Offline = $offline; ReportRoot = [string]$Parameters['ReportRoot'] }
                    $summary = @(& $invokeDeclared 'Invoke-FslDailyHealthCheck' $arguments @('ContainerScope'))
                    if ($summary.Count -gt 0) { $data['Summary'] = $summary[$summary.Count - 1] }
                }
                'DailyState' {
                    try {
                        $task = @(& $invokeDeclared 'Get-FslDailyHealthCheck' @{} @())
                        if ($task.Count -gt 0) { $data['Task'] = $task[$task.Count - 1] }
                    }
                    catch { $failures.Add((& $newFailure $_ 'Get-FslDailyHealthCheck')) }
                    # History is read from the folder the registered task writes to (its -OutputPath, when reported),
                    # otherwise from the dashboard ReportRoot.
                    $historyRoot = [string]$Parameters['ReportRoot']
                    if ($data.ContainsKey('Task') -and $null -ne $data['Task']) {
                        $taskObject = $data['Task']
                        $registeredProperty = $taskObject.PSObject.Properties['Registered']
                        $rootProperty = $taskObject.PSObject.Properties['ReportRoot']
                        if ($null -ne $registeredProperty -and $registeredProperty.Value -eq $true -and $null -ne $rootProperty -and -not [string]::IsNullOrWhiteSpace([string]$rootProperty.Value)) {
                            $historyRoot = [string]$rootProperty.Value
                        }
                    }
                    $data['HistoryRoot'] = $historyRoot
                    try {
                        $data['History'] = @(& $invokeDeclared 'Get-FslDailyHistory' @{ ReportRoot = $historyRoot } @())
                    }
                    catch { $failures.Add((& $newFailure $_ 'Get-FslDailyHistory')) }
                }
                'DailyRegister' {
                    $arguments = @{
                        At             = [string]$Parameters['At']
                        ContainerScope = [string]$Parameters['ContainerScope']
                        RunAs          = [string]$Parameters['RunAs']
                        Offline        = $offline
                        Force          = [bool]$Parameters['Force']
                        Confirm        = $false
                    }
                    $data['Output'] = @(& $invokeDeclared 'Register-FslDailyHealthCheck' $arguments @('At', 'ContainerScope', 'RunAs'))
                }
                'DailyUnregister' {
                    $data['Output'] = @(& $invokeDeclared 'Unregister-FslDailyHealthCheck' @{ Confirm = $false } @())
                }
                'DiagnosticBundle' {
                    $files = @(& $invokeDeclared 'Export-FslDiagnosticBundle' @{} @())
                    if ($files.Count -gt 0) { $data['File'] = $files[$files.Count - 1] }
                }
                # ---- Repair (CONTRACT P3.5 / P3.6) -------------------------------------------------------------
                # Read-only: the plan and its pre-flight gates. The gate Results are kept in Data, not in Results,
                # so they never replace the Repair rows of an earlier preview or apply in the dashboard table.
                'RepairPlan' {
                    $arguments = @{ ContainerScope = [string]$Parameters['ContainerScope'] }
                    if ($Parameters.ContainsKey('ActionId')) { $arguments['ActionId'] = [string[]]$Parameters['ActionId'] }
                    if ($Parameters.ContainsKey('MaxRiskTier')) { $arguments['MaxRiskTier'] = [int]$Parameters['MaxRiskTier'] }
                    if ($Parameters.ContainsKey('Parameters')) { $arguments['Parameters'] = [hashtable]$Parameters['Parameters'] }
                    $plan = @(& $invokeDeclared 'Get-FslRepairPlan' $arguments @('ContainerScope'))
                    $data['Plan'] = $plan
                    $data['Preflight'] = @(& $invokeDeclared 'Test-FslRepairPrerequisite' @{ Action = [object[]]$plan } @('Action'))
                }
                # Preview is Invoke-FslRepair -WhatIf (nothing is changed); apply and the Office container reset run
                # with -Confirm:$false because the operator already confirmed in the dashboard and a background
                # runspace cannot answer a ShouldProcess prompt.
                { $_ -in @('RepairPreview', 'RepairApply', 'ContainerReset') } {
                    $arguments = @{
                        ActionId       = [string[]]$Parameters['ActionId']
                        ContainerScope = [string]$Parameters['ContainerScope']
                    }
                    if ($Parameters.ContainsKey('MaxRiskTier')) { $arguments['MaxRiskTier'] = [int]$Parameters['MaxRiskTier'] }
                    if ($Parameters.ContainsKey('AllowDisruptive')) { $arguments['AllowDisruptive'] = [bool]$Parameters['AllowDisruptive'] }
                    if ($Parameters.ContainsKey('UserSignedOutConfirmed')) { $arguments['UserSignedOutConfirmed'] = [bool]$Parameters['UserSignedOutConfirmed'] }
                    if ($Parameters.ContainsKey('ChangeReference')) { $arguments['ChangeReference'] = [string]$Parameters['ChangeReference'] }
                    if ($Parameters.ContainsKey('Parameters')) { $arguments['Parameters'] = [hashtable]$Parameters['Parameters'] }
                    if ($Operation -eq 'RepairPreview') { $arguments['WhatIf'] = $true } else { $arguments['Confirm'] = $false }
                    & $addResults @(& $invokeDeclared 'Invoke-FslRepair' $arguments @('ActionId', 'ContainerScope'))
                }
                'RepairUndo' {
                    $arguments = @{ RunId = [guid]([string]$Parameters['RunId']); Confirm = $false }
                    if ($Parameters.ContainsKey('ActionId')) { $arguments['ActionId'] = [string[]]$Parameters['ActionId'] }
                    & $addResults @(& $invokeDeclared 'Undo-FslRepair' $arguments @('RunId'))
                }
                'RepairLog' {
                    $arguments = @{ IncludeRecords = $false }
                    if ($Parameters.ContainsKey('Days')) { $arguments['Days'] = [int]$Parameters['Days'] }
                    $data['RepairLog'] = @(& $invokeDeclared 'Get-FslRepairLog' $arguments @())
                }
                'ContainerList' {
                    $data['Container'] = @(& $invokeDeclared 'Get-FslContainer' @{ Scope = [string[]]@('ODFC') } @('Scope'))
                }
                default {
                    throw [System.ArgumentException]::new("Unknown dashboard operation '$Operation'.")
                }
            }
        }
        catch {
            $failures.Add((& $newFailure $_ "Background operation $Operation"))
        }

        $newErrors = @()
        try {
            $allErrors = @(Get-FslErrorLog)
            if ($allErrors.Count -gt $errorsBefore) { $newErrors = @($allErrors[$errorsBefore..($allErrors.Count - 1)]) }
        }
        catch {
            $failures.Add((& $newFailure $_ 'Read background error log'))
        }

        [pscustomobject]@{
            Operation       = $Operation
            Results         = $results.ToArray()
            Data            = $data
            Errors          = $newErrors
            Failures        = $failures.ToArray()
            DurationSeconds = [math]::Round(([datetime]::UtcNow - $started).TotalSeconds, 1)
        }
    }
    return $script.ToString()
}

function Add-FslGuiOperation {
    <#
    .SYNOPSIS
        Appends (or with -First, prepends) operations to the dashboard queue and assigns ids.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]] $Operation,

        [Parameter()]
        [switch] $First
    )

    $runner = $State['Runner']
    $index = 0
    foreach ($item in $Operation) {
        $item['Id'] = [int]$runner['NextId']
        $runner['NextId'] = [int]$runner['NextId'] + 1
        $item['QueuedAt'] = [datetime]::Now
        if ($First) {
            $runner['Queue'].Insert($index, $item)
            $index++
        }
        else {
            $runner['Queue'].Add($item)
        }
    }
}

function Clear-FslGuiOperationQueue {
    <#
    .SYNOPSIS
        Removes all queued (not yet started) operations. Returns the number removed.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $queue = $State['Runner']['Queue']
    $count = $queue.Count
    # A repair that changes the machine may still be waiting in the queue (Cancel, or a failed background
    # Initialize, clears it before it ever starts). Complete-FslGuiOperation would then never run for it and the
    # Repair 'Applying' flag would stay raised, so the window would refuse to close for the rest of the session
    # (CONTRACT P3.7). Release the flag unless the operation that is running right now is such a repair.
    if ($null -ne $State['Repair'] -and [bool]$State['Repair']['Applying']) {
        $names = Get-FslGuiRepairChangeOperationName
        $current = $State['Runner']['Current']
        if ($null -eq $current -or ([string]$current['Name']) -notin $names) {
            $State['Repair']['Applying'] = $false
            Write-FslLog -Message 'A queued repair run was removed from the dashboard queue; the close block was released.' -Level Info -Component 'GUI'
        }
    }
    $queue.Clear()
    return $count
}

function Test-FslGuiBusy {
    <#
    .SYNOPSIS
        Returns $true while an operation is running or queued.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $runner = $State['Runner']
    return ($null -ne $runner['Current'] -or $runner['Queue'].Count -gt 0)
}

function Open-FslGuiRunspace {
    <#
    .SYNOPSIS
        Creates the persistent background runspace and starts opening it asynchronously.
    .DESCRIPTION
        The manifest is NOT added with InitialSessionState.ImportPSModule: with OpenAsync the runspace reports Opened
        (and briefly Available) before that import runs, and a pipeline started during the import fails with "a pipeline
        is already running". The background script imports the manifest itself (Get-FslGuiBackgroundScript). An
        Initialize operation (Initialize-FslSession with the dashboard LogRoot/ReportRoot) is queued first.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $runner = $State['Runner']
    $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialState)
    $runspace.Name = 'FSLogixToolkitDashboard'
    $runner['Runspace'] = $runspace
    $runner['Initialized'] = $false
    $runspace.OpenAsync()
    Write-FslLog -Message 'Dashboard background runspace opening.' -Level Verbose -Component 'GUI'
}

function Get-FslGuiInitializeOperation {
    <#
    .SYNOPSIS
        Creates the Initialize operation (same LogRoot/ReportRoot/debug logging as the dashboard session).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    Get-FslGuiOperation -Name 'Initialize' -Display 'Background session' -Parameter @{
        LogRoot      = [string]$State['LogRoot']
        ReportRoot   = [string]$State['ReportRoot']
        DebugLogging = [bool]$State['DebugLogging']
    }
}

function Receive-FslGuiOperation {
    <#
    .SYNOPSIS
        Collects the completed (or stopped/failed) current operation and disposes its PowerShell instance.
    .DESCRIPTION
        Returns a normalized envelope hashtable: Operation, Status (Completed|Cancelled|Failed), Results, Data,
        ModuleErrors (background Get-FslErrorLog entries), RunnerErrors (script failures and error stream records),
        DurationSeconds.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $runner = $State['Runner']
    $shell = $runner['PowerShell']
    $operation = $runner['Current']
    $envelope = @{
        Operation       = $operation
        Status          = 'Completed'
        Results         = @()
        Data            = @{}
        ModuleErrors    = @()
        RunnerErrors    = @()
        DurationSeconds = 0
    }
    $runnerErrors = [System.Collections.Generic.List[object]]::new()
    $toEntry = {
        param([object] $Record, [string] $Context)
        $exception = if ($Record -is [System.Management.Automation.ErrorRecord]) { $Record.Exception } elseif ($Record -is [System.Exception]) { $Record } else { $null }
        [pscustomobject]@{
            Timestamp     = (Get-Date).ToString('o')
            Component     = 'GUI'
            Context       = $Context
            Message       = if ($null -ne $exception) { $exception.Message } else { [string]$Record }
            ExceptionType = if ($null -ne $exception) { $exception.GetType().FullName } else { $null }
            CategoryInfo  = if ($Record -is [System.Management.Automation.ErrorRecord]) { [string]$Record.CategoryInfo } else { $null }
            TargetObject  = if ($Record -is [System.Management.Automation.ErrorRecord]) { [string]$Record.TargetObject } else { $null }
        }
    }

    try {
        if ($null -ne $shell) {
            $output = $null
            try {
                $output = $shell.EndInvoke($runner['Handle'])
            }
            catch {
                $stateInfo = $shell.InvocationStateInfo
                if ($runner['Cancelling'] -or $stateInfo.State -eq [System.Management.Automation.PSInvocationState]::Stopped) {
                    $envelope['Status'] = 'Cancelled'
                }
                else {
                    $envelope['Status'] = 'Failed'
                    $runnerErrors.Add((& $toEntry $_ "Background operation $($operation['Name'])"))
                }
            }
            if ($runner['Cancelling'] -and $envelope['Status'] -eq 'Completed') {
                $envelope['Status'] = 'Cancelled'
            }
            foreach ($record in @($shell.Streams.Error)) {
                $runnerErrors.Add((& $toEntry $record "Background error stream ($($operation['Name']))"))
            }
            if ($null -ne $output -and $output.Count -gt 0) {
                $last = $output[$output.Count - 1]
                if ($null -ne $last) {
                    if ($null -ne $last.PSObject.Properties['Results']) { $envelope['Results'] = @($last.Results) }
                    if ($null -ne $last.PSObject.Properties['Data'] -and $last.Data -is [hashtable]) { $envelope['Data'] = $last.Data }
                    if ($null -ne $last.PSObject.Properties['Errors']) { $envelope['ModuleErrors'] = @($last.Errors) }
                    if ($null -ne $last.PSObject.Properties['Failures']) {
                        foreach ($failure in @($last.Failures)) { if ($null -ne $failure) { $runnerErrors.Add($failure) } }
                    }
                    if ($null -ne $last.PSObject.Properties['DurationSeconds']) { $envelope['DurationSeconds'] = $last.DurationSeconds }
                }
            }
            elseif ($envelope['Status'] -eq 'Completed') {
                $envelope['Status'] = 'Failed'
                $runnerErrors.Add((& $toEntry 'The background operation returned no output.' "Background operation $($operation['Name'])"))
            }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Collect background operation output'
        $envelope['Status'] = 'Failed'
    }
    finally {
        if ($null -ne $shell) {
            try { $shell.Dispose() } catch { Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Dispose background PowerShell' }
        }
        if ($null -ne $operation -and $null -ne $operation['StartedAt'] -and $envelope['DurationSeconds'] -eq 0) {
            $envelope['DurationSeconds'] = [math]::Round(([datetime]::Now - [datetime]$operation['StartedAt']).TotalSeconds, 1)
        }
        $runner['PowerShell'] = $null
        $runner['Handle'] = $null
        $runner['Current'] = $null
        $runner['Cancelling'] = $false
    }
    $envelope['RunnerErrors'] = $runnerErrors.ToArray()
    return $envelope
}

function Step-FslGuiRunner {
    <#
    .SYNOPSIS
        Advances the background runner by one step. Returns an envelope when an operation finished (or could not
        start), otherwise $null.
    .DESCRIPTION
        - Current operation still running: returns $null.
        - Current operation completed/stopped: collects it (Receive-FslGuiOperation) and returns the envelope.
        - Idle with a queued operation: creates the runspace on first use (Open-FslGuiRunspace, Initialize queued
          first), waits while it is opening, fails queued operations when it is Broken, otherwise starts the next
          operation with BeginInvoke and returns $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $runner = $State['Runner']
    if ($null -ne $runner['Current']) {
        if ($null -ne $runner['Handle'] -and -not $runner['Handle'].IsCompleted) { return $null }
        return (Receive-FslGuiOperation -State $State)
    }
    if ($runner['Queue'].Count -eq 0) { return $null }

    $runspace = $runner['Runspace']
    if ($null -ne $runspace) {
        $runspaceState = $runspace.RunspaceStateInfo.State
        if ($runspaceState -in @([System.Management.Automation.Runspaces.RunspaceState]::Closed, [System.Management.Automation.Runspaces.RunspaceState]::Closing)) {
            try { $runspace.Dispose() } catch { Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Dispose closed background runspace' }
            $runner['Runspace'] = $null
            $runspace = $null
        }
    }
    if ($null -eq $runspace) {
        Open-FslGuiRunspace -State $State
        return $null
    }

    $runspaceState = $runspace.RunspaceStateInfo.State
    if ($runspaceState -in @([System.Management.Automation.Runspaces.RunspaceState]::BeforeOpen, [System.Management.Automation.Runspaces.RunspaceState]::Opening)) {
        return $null
    }
    # Never start a pipeline while the runspace reports Busy ("a pipeline is already running").
    # https://learn.microsoft.com/dotnet/api/system.management.automation.runspaces.runspaceavailability
    if ($runspaceState -eq [System.Management.Automation.Runspaces.RunspaceState]::Opened -and
        $runspace.RunspaceAvailability -eq [System.Management.Automation.Runspaces.RunspaceAvailability]::Busy) {
        return $null
    }
    if ($runspaceState -ne [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
        # Broken (for example the module failed to import): fail the next operation and drop the runspace so the
        # following operation retries with a new one.
        $operation = $runner['Queue'][0]
        $runner['Queue'].RemoveAt(0)
        $reason = $runspace.RunspaceStateInfo.Reason
        $message = if ($null -ne $reason) { $reason.Message } else { "Background runspace state is $runspaceState." }
        try { $runspace.Dispose() } catch { Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Dispose broken background runspace' }
        $runner['Runspace'] = $null
        $runner['Initialized'] = $false
        Write-FslLog -Message "Dashboard background runspace unavailable: $message" -Level Error -Component 'GUI'
        return @{
            Operation       = $operation
            Status          = 'Failed'
            Results         = @()
            Data            = @{}
            ModuleErrors    = @()
            RunnerErrors    = @([pscustomobject]@{
                    Timestamp = (Get-Date).ToString('o'); Component = 'GUI'; Context = 'Background runspace'; Message = $message
                    ExceptionType = if ($null -ne $reason) { $reason.GetType().FullName } else { $null }; CategoryInfo = $null; TargetObject = [string]$State['ManifestPath']
                })
            DurationSeconds = 0
        }
    }

    if (-not $runner['Initialized'] -and $runner['Queue'][0]['Name'] -ne 'Initialize') {
        Add-FslGuiOperation -State $State -Operation @(Get-FslGuiInitializeOperation -State $State) -First
    }

    $operation = $runner['Queue'][0]
    $runner['Queue'].RemoveAt(0)
    if ($null -eq $operation['Parameters']) { $operation['Parameters'] = @{} }
    if ($operation['Name'] -in @('DailyRun', 'DailyState') -and -not $operation['Parameters'].ContainsKey('ReportRoot')) {
        # Daily reports are read and written under the daily report root (registered task output folder, else the
        # dashboard ReportRoot).
        $operation['Parameters']['ReportRoot'] = [string](Get-FslGuiDailyReportRoot -State $State)
    }
    $shell = [System.Management.Automation.PowerShell]::Create()
    try {
        $shell.Runspace = $runspace
        [void]$shell.AddScript((Get-FslGuiBackgroundScript))
        [void]$shell.AddParameter('Operation', [string]$operation['Name'])
        [void]$shell.AddParameter('Parameters', [hashtable]$operation['Parameters'])
        [void]$shell.AddParameter('ManifestPath', [string]$State['ManifestPath'])
        $operation['StartedAt'] = [datetime]::Now
        $runner['Current'] = $operation
        $runner['PowerShell'] = $shell
        $runner['Cancelling'] = $false
        $runner['Handle'] = $shell.BeginInvoke()
        Write-FslLog -Message "Dashboard operation started: $($operation['Display']) (#$($operation['Id']))" -Level Verbose -Component 'GUI'
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context "Start background operation $($operation['Name'])"
        try { $shell.Dispose() } catch { Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Dispose background PowerShell' }
        $runner['Current'] = $null
        $runner['PowerShell'] = $null
        $runner['Handle'] = $null
        return @{
            Operation       = $operation
            Status          = 'Failed'
            Results         = @()
            Data            = @{}
            ModuleErrors    = @()
            RunnerErrors    = @([pscustomobject]@{
                    Timestamp = (Get-Date).ToString('o'); Component = 'GUI'; Context = "Start background operation $($operation['Name'])"; Message = $_.Exception.Message
                    ExceptionType = $_.Exception.GetType().FullName; CategoryInfo = [string]$_.CategoryInfo; TargetObject = $null
                })
            DurationSeconds = 0
        }
    }
    return $null
}

function Request-FslGuiCancel {
    <#
    .SYNOPSIS
        Clears the queue and asynchronously stops the running operation (PowerShell.BeginStop). Returns a status text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $runner = $State['Runner']
    $cleared = Clear-FslGuiOperationQueue -State $State
    if ($null -eq $runner['Current'] -or $null -eq $runner['PowerShell']) {
        return "Nothing is running. $cleared queued operation(s) removed."
    }
    # A repair run is never stopped in the middle: PowerShell.BeginStop would abort the pipeline between the rollback
    # entry and the change (or between the change and its verification), which is exactly the state the undo store is
    # there to prevent. The queue is cleared and the running repair finishes its current action (CONTRACT P3.7).
    if (([string]$runner['Current']['Name']) -in (Get-FslGuiRepairChangeOperationName)) {
        Write-FslLog -Message "Cancel requested during $($runner['Current']['Name']): the repair run is allowed to finish; $cleared queued operation(s) removed." -Level Info -Component 'GUI'
        return "$($runner['Current']['Display']) cannot be interrupted: it stops after the current action. $cleared queued operation(s) removed."
    }
    if (-not $runner['Cancelling']) {
        $runner['Cancelling'] = $true
        [void]$runner['PowerShell'].BeginStop($null, $null)
        Write-FslLog -Message "Dashboard operation cancel requested: $($runner['Current']['Display'])" -Level Info -Component 'GUI'
    }
    return "Cancelling $($runner['Current']['Display'])... ($cleared queued operation(s) removed)"
}

function Close-FslGuiRunner {
    <#
    .SYNOPSIS
        Stops the running operation (synchronously), clears the queue and disposes the PowerShell instance and runspace.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $runner = $State['Runner']
    [void](Clear-FslGuiOperationQueue -State $State)
    if ($null -ne $runner['PowerShell']) {
        try {
            if ($null -ne $runner['Handle'] -and -not $runner['Handle'].IsCompleted) { $runner['PowerShell'].Stop() }
        }
        catch { Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Stop background operation' }
        try { $runner['PowerShell'].Dispose() } catch { Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Dispose background PowerShell' }
    }
    if ($null -ne $runner['Runspace']) {
        try { $runner['Runspace'].Dispose() } catch { Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Dispose background runspace' }
    }
    $runner['PowerShell'] = $null
    $runner['Handle'] = $null
    $runner['Current'] = $null
    $runner['Runspace'] = $null
    $runner['Initialized'] = $false
    $runner['Cancelling'] = $false
}

function Complete-FslGuiOperation {
    <#
    .SYNOPSIS
        Applies a finished operation envelope to the dashboard state (tables, discovery, daily, errors).
    .DESCRIPTION
        Data-only (no WPF). Returns @{ StatusText; Refresh (string[]: Banner, Discovery, Daily, Repair, Errors,
        Summary, Debug); Output (objects to show to the user); FollowUp (operations queued); Dialog (the dialog the
        dashboard opens next: '', 'Repair' or 'ContainerReset') }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [hashtable] $Envelope
    )

    $operation = $Envelope['Operation']
    $name = if ($null -ne $operation) { [string]$operation['Name'] } else { '' }
    $display = if ($null -ne $operation) { [string]$operation['Display'] } else { 'Operation' }
    $refresh = [System.Collections.Generic.List[string]]::new()
    $output = @()
    $dialog = ''
    $data = $Envelope['Data']
    if ($null -eq $data) { $data = @{} }

    # A repair run is over (completed, failed or cancelled): release the close/auto-refresh block in every case.
    if ($name -in @('RepairApply', 'RepairUndo', 'ContainerReset')) {
        $State['Repair']['Applying'] = $false
        $refresh.Add('Repair')
    }

    foreach ($entry in @($Envelope['ModuleErrors'])) { if ($null -ne $entry) { $State['BackgroundErrors'].Add($entry) } }
    foreach ($entry in @($Envelope['RunnerErrors'])) { if ($null -ne $entry) { $State['RunnerErrors'].Add($entry) } }
    $errorCount = @($Envelope['ModuleErrors']).Count + @($Envelope['RunnerErrors']).Count
    if ($errorCount -gt 0) { $refresh.Add('Errors') }

    $status = [string]$Envelope['Status']
    $duration = $Envelope['DurationSeconds']
    if ($status -eq 'Cancelled') {
        # No dialog is reopened for a cancelled run, so the reopen flags must be released here or the next
        # unrelated repair operation would open a dialog the operator did not ask for. A cancelled run that changes
        # the machine also invalidates the preview: it may have applied part of the selection before it stopped.
        if ($name -in @('RepairPlan', 'RepairPreview', 'RepairApply', 'RepairUndo', 'RepairLog', 'ContainerList', 'ContainerReset')) {
            $State['Repair']['Reopen'] = $false
            $State['Repair']['ReopenContainer'] = $false
            if ($name -in (Get-FslGuiRepairChangeOperationName)) {
                $State['Repair']['PreviewHash'] = ''
                $State['Repair']['PreviewActionId'] = [string[]]@()
                $State['Repair']['PreviewAt'] = $null
            }
        }
        return @{ StatusText = "$display was cancelled after $duration s."; Refresh = [string[]]$refresh.ToArray(); Output = @(); FollowUp = @(); Dialog = '' }
    }

    $resultCount = @($Envelope['Results']).Count
    switch ($name) {
        'Initialize' {
            if ($data.ContainsKey('Session') -and $null -ne $data['Session']) {
                $State['Runner']['Initialized'] = $true
                $State['BackgroundLogPath'] = Get-FslGuiPropertyText -InputObject $data['Session'] -Name 'LogPath'
            }
            else {
                # Without this, Step-FslGuiRunner would queue Initialize again before the next operation, forever.
                $dropped = Clear-FslGuiOperationQueue -State $State
                if ($dropped -gt 0) { $refresh.Add('Errors') }
                Write-FslLog -Message "Dashboard background session could not be initialized; $dropped queued operation(s) removed." -Level Error -Component 'GUI'
            }
        }
        'Debug' {
            if ($data.ContainsKey('Session') -and $null -ne $data['Session']) {
                $State['Runner']['Initialized'] = $true
                $State['BackgroundLogPath'] = Get-FslGuiPropertyText -InputObject $data['Session'] -Name 'LogPath'
            }
            $refresh.Add('Debug')
        }
        { $_ -in @('HealthCheck', 'Discovery', 'Environment', 'Prerequisites') } {
            if ($status -eq 'Completed' -and $null -ne $operation) {
                $change = Sync-FslGuiResultRow -Table $State['Tables']['Results'] -Result @($Envelope['Results']) -Category @($operation['Categories']) -Scope @($operation['Scopes'])
                Write-FslLog -Message "Dashboard results for '$display': removed $($change['Removed']), added $($change['Added'])." -Level Verbose -Component 'GUI'
                Sync-FslGuiSummaryTable -Table $State['Tables']['Summary'] -ResultTable $State['Tables']['Results']
                if ($name -in @('HealthCheck', 'Discovery')) { $State['LastCheck'] = [datetime]::Now }
                $refresh.Add('Summary'); $refresh.Add('Banner')
            }
            if ($name -eq 'Discovery' -and $data.ContainsKey('Discovery')) {
                $State['Discovery'] = $data['Discovery']
                $refresh.Add('Discovery')
            }
        }
        'ErrorLog' {
            if ($data.ContainsKey('ErrorLog')) {
                $State['BackgroundErrors'].Clear()
                foreach ($entry in @($data['ErrorLog'])) { if ($null -ne $entry) { $State['BackgroundErrors'].Add($entry) } }
            }
            $refresh.Add('Errors')
        }
        'DailyState' {
            if ($data.ContainsKey('Task')) { $State['DailyTask'] = $data['Task'] }
            if ($data.ContainsKey('HistoryRoot') -and -not [string]::IsNullOrWhiteSpace([string]$data['HistoryRoot'])) { $State['DailyReportRoot'] = [string]$data['HistoryRoot'] }
            if ($data.ContainsKey('History')) {
                Sync-FslGuiObjectTable -Table $State['Tables']['Daily'] -InputObject @($data['History'])
            }
            $refresh.Add('Daily'); $refresh.Add('Banner')
        }
        'DailyRun' {
            if ($data.ContainsKey('Summary')) { $output = @($data['Summary']) }
            $refresh.Add('Daily')
        }
        { $_ -in @('DailyRegister', 'DailyUnregister') } {
            if ($data.ContainsKey('Output')) { $output = @($data['Output']) }
            $refresh.Add('Daily')
        }
        'DiagnosticBundle' {
            if ($data.ContainsKey('File')) { $output = @($data['File']) }
        }
        'RepairPlan' {
            $State['Repair']['Plan'] = if ($data.ContainsKey('Plan')) { @($data['Plan']) } else { @() }
            $State['Repair']['Preflight'] = if ($data.ContainsKey('Preflight')) { @($data['Preflight']) } else { @() }
            $State['Repair']['PlanAt'] = [datetime]::Now
            # The reopen flag is consumed even when the plan failed: Invoke-FslGuiRepairDialog then reports the empty
            # plan and clears it. Leaving it raised would reopen the dialog after an unrelated later repair run.
            if ([bool]$State['Repair']['Reopen']) { $dialog = 'Repair' }
            $refresh.Add('Repair')
        }
        { $_ -in @('RepairPreview', 'RepairApply', 'RepairUndo', 'ContainerReset') } {
            if ($status -eq 'Completed' -and $null -ne $operation) {
                $change = Sync-FslGuiResultRow -Table $State['Tables']['Results'] -Result @($Envelope['Results']) -Category @($operation['Categories']) -Scope @($operation['Scopes'])
                Write-FslLog -Message "Dashboard results for '$display': removed $($change['Removed']), added $($change['Added'])." -Level Verbose -Component 'GUI'
                Sync-FslGuiSummaryTable -Table $State['Tables']['Summary'] -ResultTable $State['Tables']['Results']
                $refresh.Add('Summary'); $refresh.Add('Banner')
            }
            $repairMode = switch ($name) {
                'RepairPreview' { 'Preview' }
                'RepairUndo' { 'Undo' }
                'ContainerReset' { 'ContainerReset' }
                default { 'Apply' }
            }
            $State['Repair']['LastResult'] = @($Envelope['Results'])
            $State['Repair']['LastMode'] = $repairMode
            $repairSummary = Get-FslGuiRepairResultSummary -Result @($Envelope['Results']) -Mode $repairMode
            $State['Repair']['LastRunId'] = [string]$repairSummary['RunId']
            $output = @($repairSummary)

            $requested = [string[]]@()
            if ($null -ne $operation -and $operation['Parameters'].ContainsKey('ActionId')) { $requested = [string[]]@($operation['Parameters']['ActionId']) }
            if ($name -eq 'RepairPreview') {
                $outcome = @(Get-FslGuiRepairPreviewOutcome -Result @($Envelope['Results']) -ActionId $requested)
                $State['Repair']['PreviewActionId'] = [string[]]@(@($outcome | Where-Object -FilterScript { $_.CanApply }) | ForEach-Object -Process { [string]$_.ActionId })
                $State['Repair']['PreviewHash'] = Get-FslGuiRepairSelectionHash -ActionId $requested
                $State['Repair']['PreviewAt'] = [datetime]::Now
                # Also on a failed preview: the dialog shows the outcome and the flag is released either way.
                if ([bool]$State['Repair']['Reopen']) { $dialog = 'Repair' }
            }
            else {
                # The machine state changed: a preview taken before the run no longer describes it.
                $State['Repair']['PreviewHash'] = ''
                $State['Repair']['PreviewActionId'] = [string[]]@()
                $State['Repair']['PreviewAt'] = $null
                if ($name -eq 'RepairApply' -and [bool]$State['Repair']['Reopen']) { $dialog = 'Repair' }
            }
            $refresh.Add('Repair')
        }
        'RepairLog' {
            if ($data.ContainsKey('RepairLog')) {
                Sync-FslGuiObjectTable -Table $State['Tables']['Repair'] -InputObject @($data['RepairLog'])
                $State['Repair']['HistoryLoaded'] = $true
            }
            $refresh.Add('Repair')
        }
        'ContainerList' {
            $State['Repair']['Container'] = if ($data.ContainsKey('Container')) { @($data['Container']) } else { @() }
            $State['Repair']['ContainerAt'] = [datetime]::Now
            # Consumed even when the listing failed: the dialog then reports that no container was found.
            if ([bool]$State['Repair']['ReopenContainer']) { $dialog = 'ContainerReset' }
        }
    }

    $followUp = @()
    if ($name -in @('DailyRun', 'DailyRegister', 'DailyUnregister')) {
        $followUp = @(Get-FslGuiOperation -Name 'DailyState' -Display 'Daily schedule and history')
        Add-FslGuiOperation -State $State -Operation $followUp
    }
    if ($name -in @('RepairApply', 'RepairUndo', 'ContainerReset')) {
        # A run that changed something wrote a repair log: refresh the history so Undo can use it.
        $followUp = @(Get-FslGuiRepairOperation -Kind 'Log' -ContainerScope ([string]$State['Mode']))
        Add-FslGuiOperation -State $State -Operation $followUp
    }

    $text = if ($status -eq 'Failed') { "$display failed after $duration s" } else { "$display completed in $duration s" }
    if ($name -in @('HealthCheck', 'Discovery', 'Environment', 'Prerequisites')) {
        $counts = @{}
        foreach ($item in @($Envelope['Results'])) {
            $itemStatus = Get-FslGuiPropertyText -InputObject $item -Name 'Status'
            if (-not $counts.ContainsKey($itemStatus)) { $counts[$itemStatus] = 0 }
            $counts[$itemStatus] = [int]$counts[$itemStatus] + 1
        }
        $parts = foreach ($statusName in @('Fail', 'Error', 'Warn')) { if ($counts.ContainsKey($statusName)) { "$statusName $($counts[$statusName])" } }
        $text += ": $resultCount result(s)"
        if (@($parts).Count -gt 0) { $text += ' (' + (@($parts) -join ', ') + ')' }
    }
    if ($name -eq 'DiagnosticBundle' -and @($output).Count -gt 0) {
        $text += ': ' + (Get-FslGuiPropertyText -InputObject $output[0] -Name 'FullName')
    }
    if ($name -in @('RepairPreview', 'RepairApply', 'RepairUndo', 'ContainerReset')) {
        $text += ": $resultCount result(s)"
        $runId = [string]$State['Repair']['LastRunId']
        if (-not [string]::IsNullOrWhiteSpace($runId)) { $text += " (RunId $runId)" }
    }
    if ($name -eq 'RepairPlan') { $text += ": $(@($State['Repair']['Plan']).Count) action(s)" }
    if ($errorCount -gt 0) { $text += "; $errorCount error(s) - see Errors & Log" }
    $text += '.'
    return @{ StatusText = $text; Refresh = [string[]]@($refresh | Select-Object -Unique); Output = $output; FollowUp = $followUp; Dialog = $dialog }
}
