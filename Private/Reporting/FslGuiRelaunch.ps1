# Private helpers for Show-FslDashboard: the File > Relaunch items and the run-as dialog (GUI/RunAsDialog.xaml).
#
# Relaunching is done only through the CONTRACT P3.2 private helper
#   Start-FslCoreRelaunch -Mode <Elevate|DifferentUser> [-UserName] [-ElevateAfterSignIn] [-Arguments <hashtable>]
# which builds the command line, checks the Secondary Logon service for the DifferentUser mode and starts either
# Start-Process -Verb RunAs (UAC) or runas.exe with its smart card switch. WINDOWS asks for the smart card and PIN in
# its own window: the toolkit never prompts for, reads, passes, logs or stores a password or PIN, never creates or
# requests a credential object, and never asks Windows to remember one for reuse. The only value the dashboard keeps is
# the user NAME (preference RunAsUserName), which is not a secret.
#
# Because the relaunched session runs under a DIFFERENT user profile (the admin accounts on this image are separate
# accounts), the dashboard passes the resolved container mode explicitly and, when Settings RunAs.PassReportRoot is
# true, the current report folder - otherwise the new session would use the other profile's preferences and write its
# reports somewhere else.
#
# Sources:
#   https://learn.microsoft.com/dotnet/api/system.windows.window.showdialog
#   https://learn.microsoft.com/dotnet/api/system.windows.window.dialogresult
#   https://learn.microsoft.com/dotnet/api/system.windows.messagebox.show
#   https://learn.microsoft.com/dotnet/api/system.security.principal.windowsidentity.getcurrent

function Get-FslGuiCurrentAccountText {
    <#
    .SYNOPSIS
        Returns the account running the dashboard as DOMAIN\User. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $command = Get-Command -Name 'Get-FslCoreCurrentAccount' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        try {
            $text = [string](& $command)
            if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Read the current account name'
        }
    }
    try {
        $domain = [System.Environment]::UserDomainName
        if ([string]::IsNullOrEmpty($domain)) { return [System.Environment]::UserName }
        return ('{0}\{1}' -f $domain, [System.Environment]::UserName)
    }
    catch {
        return '<unknown>'
    }
}

function Get-FslGuiRunAsControlName {
    <#
    .SYNOPSIS
        Returns every x:Name referenced in GUI/RunAsDialog.xaml.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return , [string[]]@('WndRunAs', 'TxtRunAsCurrent', 'TxtRunAsUser', 'ChkRunAsElevate', 'TxtRunAsInfo',
        'TxtRunAsError', 'BtnRunAsOk', 'BtnRunAsCancel')
}

function Test-FslGuiRunAsUserName {
    <#
    .SYNOPSIS
        Returns $true when the text is a user name Start-FslCoreRelaunch accepts (DOMAIN\user or user@domain.tld).
    .DESCRIPTION
        Delegates to the Core helper Test-FslCoreRunAsUserName so the dialog refuses exactly what the relaunch helper
        would refuse. When that helper is not available the dialog does not refuse the input (the relaunch helper
        validates it again and reports the refusal in the log).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $UserName
    )

    if ([string]::IsNullOrWhiteSpace($UserName)) { return $false }
    $command = Get-Command -Name 'Test-FslCoreRunAsUserName' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $command) { return $true }
    try { return [bool](& $command -UserName $UserName.Trim()) }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Validate the run-as user name'
        return $false
    }
}

function Get-FslGuiRelaunchArgument {
    <#
    .SYNOPSIS
        Builds the launcher parameters passed to Start-FslCoreRelaunch -Arguments. Pure function.
    .DESCRIPTION
        Always -ContainerScope <resolved mode> (the other account has a different preference file) and, when
        PassReportRoot is true and a report folder is known, -OutputPath <report folder>. -Offline is added only when
        offline mode is on in this session.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $ContainerScope,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ReportRoot,

        [Parameter()]
        [bool] $PassReportRoot = $true,

        [Parameter()]
        [bool] $Offline = $false
    )

    $arguments = @{ ContainerScope = $ContainerScope }
    if ($PassReportRoot -and -not [string]::IsNullOrWhiteSpace($ReportRoot)) { $arguments['OutputPath'] = $ReportRoot.Trim() }
    if ($Offline) { $arguments['Offline'] = $true }
    return $arguments
}

function Get-FslGuiRelaunchArgumentForState {
    <#
    .SYNOPSIS
        Builds the relaunch launcher parameters from the dashboard state and Settings RunAs.PassReportRoot.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $passReportRoot = $true
    try {
        $runAs = Get-FslConfig -Section 'RunAs'
        if ($runAs -is [hashtable] -and $runAs.ContainsKey('PassReportRoot') -and $runAs['PassReportRoot'] -is [bool]) {
            $passReportRoot = [bool]$runAs['PassReportRoot']
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Read the RunAs settings section'
    }
    return (Get-FslGuiRelaunchArgument -ContainerScope ([string]$State['Mode']) -ReportRoot ([string]$State['ReportRoot']) `
            -PassReportRoot $passReportRoot -Offline ([bool]$State['Offline']))
}

function Get-FslGuiRelaunchText {
    <#
    .SYNOPSIS
        Returns the confirmation / explanation texts of the relaunch actions. Pure function.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Elevate', 'DifferentUser')]
        [string] $Mode,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Account,

        [Parameter()]
        [bool] $IsElevated = $false,

        [Parameter()]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $ContainerScope = 'ODFC',

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ReportRoot
    )

    $who = if ([string]::IsNullOrWhiteSpace($Account)) { 'this account' } else { $Account }
    $elevation = if ($IsElevated) { 'elevated' } else { 'not elevated' }
    $current = "Running as: $who  (Elevated: $(if ($IsElevated) { 'Yes' } else { 'No' }))"
    $reportLine = if ([string]::IsNullOrWhiteSpace($ReportRoot)) { '' } else { " Reports are written to $ReportRoot." }
    if ($Mode -eq 'Elevate') {
        return @{
            Current = $current
            Caption = 'Relaunch Elevated (UAC)'
            Text    = "Start a second FSLogixToolkit window elevated?`r`n`r`nCurrent session: $who ($elevation).`r`n`r`nWindows shows the UAC prompt. When the signed-in user is not an administrator, Windows offers the administrator accounts (including smart card sign-in) in its own credential window - the toolkit never sees a password or PIN.`r`n`r`nThe new window starts in container mode $ContainerScope.$reportLine This window stays open until you close it."
        }
    }
    return @{
        Current = $current
        Caption = 'Relaunch as a Different User (Smart Card)'
        Text    = "The toolkit starts a new session with runas.exe. Windows asks for the smart card and PIN in its own window; the toolkit never sees, stores or logs a PIN or password.`r`n`r`nThe new window starts in container mode $ContainerScope.$reportLine"
    }
}

function Confirm-FslGuiRunAsDialog {
    <#
    .SYNOPSIS
        Click handler body of the run-as dialog OK button: validates the user name and closes the dialog.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $state = $script:FslGuiState
    if ($null -eq $state -or $null -eq $state['Repair']['RunAsDialog']) { return }
    $dialog = $state['Repair']['RunAsDialog']
    $userName = ([string]$dialog['Controls']['TxtRunAsUser'].Text).Trim()
    if (-not (Test-FslGuiRunAsUserName -UserName $userName)) {
        $dialog['Controls']['TxtRunAsError'].Text = 'Enter the account as DOMAIN\user or user@domain.tld (no spaces, quotation marks or % characters).'
        return
    }
    $dialog['Window'].DialogResult = $true
}

function Show-FslGuiRunAsDialog {
    <#
    .SYNOPSIS
        Shows GUI/RunAsDialog.xaml. Returns @{ UserName; ElevateAfterSignIn } or $null when cancelled.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $path = Join-Path -Path ([string]$State['ModuleRoot']) -ChildPath 'GUI/RunAsDialog.xaml'
    $window = Import-FslGuiXaml -Path $path
    $connected = Connect-FslGuiControl -Root $window -Name (Get-FslGuiRunAsControlName)
    if ($connected['Missing'].Count -gt 0) {
        throw [System.InvalidOperationException]::new("GUI/RunAsDialog.xaml is missing control(s): $($connected['Missing'] -join ', ')")
    }
    $controls = $connected['Controls']

    $saved = ''
    try {
        $value = Get-FslPreference -Name 'RunAsUserName'
        if ($null -ne $value) { $saved = [string]$value }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context 'Read the RunAsUserName preference'
    }
    $text = Get-FslGuiRelaunchText -Mode 'DifferentUser' -Account (Get-FslGuiCurrentAccountText) -IsElevated ([bool]$State['IsElevated']) `
        -ContainerScope ([string]$State['Mode']) -ReportRoot ([string]$State['ReportRoot'])
    $controls['TxtRunAsCurrent'].Text = [string]$text['Current']
    $controls['TxtRunAsInfo'].Text = [string]$text['Text']
    $controls['TxtRunAsUser'].Text = $saved
    $controls['ChkRunAsElevate'].IsChecked = $true
    $controls['TxtRunAsError'].Text = ''

    $State['Repair']['RunAsDialog'] = @{ Window = $window; Controls = $controls }
    try {
        $controls['BtnRunAsOk'].Add_Click({
                try { Confirm-FslGuiRunAsDialog }
                catch { Write-FslGuiHandlerError -ErrorRecord $_ -Context 'Run-as dialog OK' }
            })
        $window.Owner = $State['Window']
        $accepted = $window.ShowDialog()
        $request = @{
            UserName           = ([string]$controls['TxtRunAsUser'].Text).Trim()
            ElevateAfterSignIn = ($controls['ChkRunAsElevate'].IsChecked -eq $true)
        }
    }
    finally {
        $State['Repair']['RunAsDialog'] = $null
    }
    if ($accepted -ne $true) { return $null }
    return $request
}

function Start-FslGuiRelaunch {
    <#
    .SYNOPSIS
        Calls the Core relaunch helper with the dashboard's launcher parameters. Returns $true when a session started.
    .DESCRIPTION
        -Confirm:$false is passed because the operator already confirmed in the dashboard and a ShouldProcess prompt
        cannot be answered from a WPF window. Never throws.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [ValidateSet('Elevate', 'DifferentUser')]
        [string] $Mode,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $UserName,

        [Parameter()]
        [bool] $ElevateAfterSignIn = $false
    )

    $command = Get-Command -Name 'Start-FslCoreRelaunch' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        Write-FslLog -Message 'Start-FslCoreRelaunch is not available in this FSLogixToolkit build; the relaunch was not started.' -Level Warning -Component 'GUI'
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess([System.Environment]::MachineName, "Relaunch FSLogixToolkit ($Mode)")) { return $false }

    $splat = @{ Mode = $Mode; Arguments = (Get-FslGuiRelaunchArgumentForState -State $State); Confirm = $false }
    if ($Mode -eq 'DifferentUser') {
        if (-not [string]::IsNullOrWhiteSpace($UserName)) { $splat['UserName'] = $UserName.Trim() }
        if ($ElevateAfterSignIn) { $splat['ElevateAfterSignIn'] = $true }
    }
    try {
        return [bool](& $command @splat)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'GUI' -Context "Relaunch FSLogixToolkit ($Mode)"
        return $false
    }
}

function Invoke-FslGuiRelaunchAction {
    <#
    .SYNOPSIS
        File > Relaunch Elevated (UAC)... / Relaunch as Different User (Smart Card)...: confirms, relaunches and
        closes this window when a new session started. Returns a status text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [ValidateSet('Elevate', 'DifferentUser')]
        [string] $Mode
    )

    if (-not (Test-FslIsWindows)) { return 'Relaunching is only supported on Windows.' }
    if (Test-FslGuiRepairInProgress -State $State) {
        return 'A repair is running: wait until it finishes before relaunching the toolkit.'
    }

    $account = Get-FslGuiCurrentAccountText
    $text = Get-FslGuiRelaunchText -Mode $Mode -Account $account -IsElevated ([bool]$State['IsElevated']) `
        -ContainerScope ([string]$State['Mode']) -ReportRoot ([string]$State['ReportRoot'])

    if ($Mode -eq 'Elevate') {
        if ([bool]$State['IsElevated']) { return "This session is already elevated (running as $account)." }
        # These menu items stay available while background checks run, and a modal window runs a nested dispatcher
        # loop: block the poll tick so a check that finishes here cannot open a dialog on top of this one.
        $pump = Suspend-FslGuiOperationPump -State $State
        try { $answer = Show-FslGuiMessage -State $State -Text ([string]$text['Text']) -Caption ([string]$text['Caption']) -Button 'OKCancel' -Icon 'Warning' }
        finally { Resume-FslGuiOperationPump -State $State -Previous $pump }
        if ($answer -ne 'OK') { return 'Relaunch cancelled.' }
        if (-not (Start-FslGuiRelaunch -State $State -Mode 'Elevate' -Confirm:$false)) {
            return 'The elevated session could not be started (cancelled at the UAC prompt, or refused - see Errors & Log).'
        }
        Write-FslGuiStatus -State $State -Text 'Elevated session started; closing this window.'
        $State['Window'].Close()
        return 'Elevated session started.'
    }

    $pump = Suspend-FslGuiOperationPump -State $State
    try { $request = Show-FslGuiRunAsDialog -State $State }
    finally { Resume-FslGuiOperationPump -State $State -Previous $pump }
    if ($null -eq $request) { return 'Relaunch cancelled.' }
    $userName = [string]$request['UserName']
    # Remember the user NAME (not a secret) so the dialog and the launcher prefill it next time, even when the
    # relaunch itself is refused (for example because the Secondary Logon service is stopped).
    [void](Save-FslGuiPreference -Name 'RunAsUserName' -Value $userName)
    if (-not (Start-FslGuiRelaunch -State $State -Mode 'DifferentUser' -UserName $userName -ElevateAfterSignIn ([bool]$request['ElevateAfterSignIn']) -Confirm:$false)) {
        return "The session for $userName could not be started (see Errors & Log; the Secondary Logon service must be running)."
    }
    Write-FslGuiStatus -State $State -Text "Session for $userName started; closing this window."
    $State['Window'].Close()
    return "Session for $userName started."
}
