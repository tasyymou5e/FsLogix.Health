# Core relaunch helpers (Agent P3-2, contract PHASE 3 P3.2): relaunch elevated (UAC) or as a different user (runas /smartcard).
# The toolkit never prompts for, reads, passes, logs or stores passwords or PINs: runas.exe / Windows collect them.
# Sources:
#   https://learn.microsoft.com/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/cc771525(v=ws.11)   (runas syntax, /smartcard, /user formats, /profile default, Secondary Logon)
#   https://learn.microsoft.com/troubleshoot/windows-server/shell-experience/use-run-as-feature                    (Secondary Logon service must be running)
#   https://learn.microsoft.com/troubleshoot/windows-server/shell-experience/access-denied-runas-command-run-as-administrator (service name seclogon)
#   https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw           (32,767 character command line limit)
#   https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-createprocesswithlogonw                      (1,024 character command line limit of the Secondary Logon API)
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_pwsh                        (-EncodedCommand = Base64 of UTF-16LE)
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.management/start-process                    (-Verb RunAs, single-string ArgumentList)

# CreateProcess lpCommandLine maximum (including the terminating null character).
$script:FslCoreMaxCommandLineLength = 32766
# CreateProcessWithLogonW lpCommandLine maximum. runas.exe relies on the Secondary Logon service; how runas passes the
# program string internally is not documented, so the documented Secondary Logon API limit is applied as a conservative
# toolkit limit to the runas program string.
$script:FslCoreMaxRunAsProgramLength = 1024

# DOMAIN\user (or COMPUTER\user) or UPN user@dns.domain. Whitespace, double quotes and % are rejected: runas documents
# only the <Domain>\<User> and <User>@<Domain> formats and quoting of user names with spaces is not documented.
$script:FslCoreRunAsUserNamePattern = '^(?:[A-Za-z0-9][A-Za-z0-9.\-]{0,254}\\[^\\/"\[\]:;|=,+*?<>@%\s]{1,256}|[^\\/"\[\]:;|=,+*?<>@%\s]{1,256}@[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)+)\z'

function Test-FslCoreRunAsUserName {
    <#
    .SYNOPSIS
        Returns $true when the text is DOMAIN\user or a UPN (user@domain.tld) without whitespace, quotes or %.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $UserName
    )

    if ([string]::IsNullOrEmpty($UserName)) { return $false }
    return ($UserName -cmatch $script:FslCoreRunAsUserNamePattern)
}

function ConvertTo-FslCoreQuotedLiteral {
    <#
    .SYNOPSIS
        Returns a PowerShell single-quoted string literal ('' escaping; about_Quoting_Rules).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    # CodeGeneration.EscapeSingleQuotedStringContent doubles ' and the typographic single quotes PowerShell also accepts.
    return "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text) + "'"
}

function New-FslCoreLauncherCommand {
    <#
    .SYNOPSIS
        Builds the PowerShell command text that invokes the launcher with the given parameters.
    .DESCRIPTION
        Output: & '<LauncherPath>' -Name 'value' -Switch -Array 'a','b' ...  Parameter names must be simple identifiers
        (letters/digits). Values: SwitchParameter/bool $true -> -Name; $false -> -Name:$false; arrays -> comma separated
        single-quoted literals; everything else -> single-quoted literal. Throws on an invalid parameter name.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string in memory only.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LauncherPath,

        [AllowNull()]
        [System.Collections.IDictionary] $Arguments
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('& ' + (ConvertTo-FslCoreQuotedLiteral -Text $LauncherPath))
    if ($null -ne $Arguments) {
        foreach ($key in @($Arguments.Keys | Sort-Object)) {
            $name = [string]$key
            if ($name -notmatch '^[A-Za-z][A-Za-z0-9]*$') {
                throw [System.ArgumentException]::new("Invalid launcher parameter name '$name'.", 'Arguments')
            }
            $value = $Arguments[$key]
            if ($value -is [System.Management.Automation.SwitchParameter]) {
                if ($value.IsPresent) { $parts.Add("-$name") } else { $parts.Add("-${name}:`$false") }
            }
            elseif ($value -is [bool]) {
                if ($value) { $parts.Add("-$name") } else { $parts.Add("-${name}:`$false") }
            }
            elseif ($null -eq $value) {
                continue
            }
            elseif ($value -is [System.Array] -or ($value -is [System.Collections.IList] -and $value -isnot [string])) {
                $items = @(foreach ($element in $value) { ConvertTo-FslCoreQuotedLiteral -Text ([string]$element) })
                if ($items.Count -gt 0) { $parts.Add("-$name " + ($items -join ',')) }
            }
            else {
                $parts.Add("-$name " + (ConvertTo-FslCoreQuotedLiteral -Text ([string]$value)))
            }
        }
    }
    return ($parts -join ' ')
}

function ConvertTo-FslCoreEncodedCommand {
    <#
    .SYNOPSIS
        Encodes command text for pwsh -EncodedCommand (Base64 of UTF-16LE, about_Pwsh).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $CommandText
    )

    return [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($CommandText))
}

function Get-FslCorePwshPath {
    <#
    .SYNOPSIS
        Returns the current PowerShell 7 executable: [Environment]::ProcessPath when it is pwsh, else $PSHOME\pwsh(.exe).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $exeName = if (Test-FslIsWindows) { 'pwsh.exe' } else { 'pwsh' }
    $processPath = $null
    try { $processPath = [System.Environment]::ProcessPath } catch { $processPath = $null }
    if (-not [string]::IsNullOrWhiteSpace($processPath) -and [string]::Equals([System.IO.Path]::GetFileName($processPath), $exeName, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $processPath
    }
    return (Join-Path -Path $PSHOME -ChildPath $exeName)
}

function New-FslCorePwshArgumentList {
    <#
    .SYNOPSIS
        Returns the pwsh arguments: -NoProfile [-NoExit] -EncodedCommand <Base64>.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string in memory only.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $EncodedCommand,

        [switch] $NoExit
    )

    $list = [System.Collections.Generic.List[string]]::new()
    $list.Add('-NoProfile')
    if ($NoExit) { $list.Add('-NoExit') }
    $list.Add('-EncodedCommand')
    $list.Add($EncodedCommand)
    return [string[]]$list.ToArray()
}

function New-FslCoreRunAsArgumentString {
    <#
    .SYNOPSIS
        Builds the runas.exe argument string: [/smartcard] /user:<UserName> "<program string>".
    .DESCRIPTION
        runas syntax (learn.microsoft.com, Runas): runas [/profile] ... [/smartcard] /user:<UserAccountName> "<ProgramName> <PathToProgramFile>".
        The program string is one double-quoted argument; double quotes inside it are escaped as \" (runas /? example
        runas /env /user:user@domain.microsoft.com "notepad \"my file.txt\""). The executable path is quoted inside the
        program string so a path with spaces is not ambiguous (CreateProcess security remarks). /profile is the default
        and is not passed; /savecred and /netonly are never used.
        Throws when the user name is invalid, the program string contains a character that cannot be passed safely, or a
        length limit is exceeded.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string in memory only.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $UserName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ExecutablePath,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $ArgumentList,

        [bool] $SmartCard = $true
    )

    if (-not (Test-FslCoreRunAsUserName -UserName $UserName)) {
        throw [System.ArgumentException]::new("User name '$UserName' is not valid. Use DOMAIN\user or user@domain.tld (no spaces, quotes or %).", 'UserName')
    }
    if ($ExecutablePath.Contains('"')) {
        throw [System.ArgumentException]::new('The executable path must not contain double quotes.', 'ExecutablePath')
    }
    foreach ($argument in @($ArgumentList)) {
        if ($null -eq $argument) { continue }
        if ($argument -notmatch '^[A-Za-z0-9+/=\-]+$') {
            # Only switch names and Base64 are passed (no quoting needed); anything else is refused.
            throw [System.ArgumentException]::new("Unsupported program argument '$argument' for runas (only simple switches and Base64 values are passed).", 'ArgumentList')
        }
    }

    $program = '\"' + $ExecutablePath + '\"'
    $argumentText = (@($ArgumentList | Where-Object -FilterScript { $null -ne $_ }) -join ' ')
    if ($argumentText.Length -gt 0) { $program = $program + ' ' + $argumentText }

    # Length of the program string as runas receives it (escapes removed).
    $programLength = $program.Replace('\"', '"').Length
    if ($programLength -gt $script:FslCoreMaxRunAsProgramLength) {
        throw [System.InvalidOperationException]::new("The runas program string is $programLength characters; the toolkit limit is $($script:FslCoreMaxRunAsProgramLength) (Secondary Logon CreateProcessWithLogonW command line limit). Move the toolkit to a shorter path or pass fewer parameters.")
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($SmartCard) { $parts.Add('/smartcard') }
    $parts.Add('/user:' + $UserName)
    $parts.Add('"' + $program + '"')
    return ($parts -join ' ')
}

function Test-FslCoreCommandLineLength {
    <#
    .SYNOPSIS
        Returns @{ Ok; Length; Limit; Message } for "<executable>" + arguments against the CreateProcess 32,767 limit.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ExecutablePath,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $ArgumentList
    )

    $length = ('"{0}"' -f $ExecutablePath).Length
    foreach ($argument in @($ArgumentList)) { if ($null -ne $argument) { $length += 1 + $argument.Length } }
    $limit = $script:FslCoreMaxCommandLineLength
    $ok = $length -le $limit
    $message = if ($ok) { "Command line length $length (limit $limit)." } else { "The command line is $length characters; Windows allows at most $limit (CreateProcess lpCommandLine 32,767 including the terminating null)." }
    return @{ Ok = $ok; Length = $length; Limit = $limit; Message = $message }
}

function Test-FslCoreSecondaryLogonService {
    <#
    .SYNOPSIS
        Checks that the Secondary Logon service (seclogon), required by runas, exists and is not Disabled.
    .DESCRIPTION
        Returns @{ Ok (bool); Status; StartType; Message }. Never throws. Non-Windows -> Ok $false.
    .NOTES
        Sources:
          https://learn.microsoft.com/troubleshoot/windows-server/shell-experience/use-run-as-feature
          https://learn.microsoft.com/troubleshoot/windows-server/shell-experience/access-denied-runas-command-run-as-administrator
          https://learn.microsoft.com/powershell/module/microsoft.powershell.management/get-service
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if (-not (Test-FslIsWindows)) {
        return @{ Ok = $false; Status = $null; StartType = $null; Message = 'The Secondary Logon service exists only on Windows.' }
    }
    try {
        $service = Get-Service -Name 'seclogon' -ErrorAction Stop
        $startType = [string]$service.StartType
        $status = [string]$service.Status
        if ($startType -eq 'Disabled') {
            return @{ Ok = $false; Status = $status; StartType = $startType; Message = 'The Secondary Logon service (seclogon) is Disabled. runas needs it; ask an administrator to set it to Manual or Automatic, or use Relaunch Elevated (UAC) instead.' }
        }
        return @{ Ok = $true; Status = $status; StartType = $startType; Message = "Secondary Logon service (seclogon): $status, start type $startType." }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Checking the Secondary Logon service (seclogon)'
        return @{ Ok = $false; Status = $null; StartType = $null; Message = "The Secondary Logon service (seclogon) was not found or could not be queried: $($_.Exception.Message). runas needs this service." }
    }
}

function Start-FslCoreRelaunch {
    <#
    .SYNOPSIS
        Relaunches Start-FSLogixToolkit.ps1 elevated (UAC) or as a different user (runas /smartcard). Returns $true when started.
    .DESCRIPTION
        Elevate: Start-Process <pwsh> -Verb RunAs -ArgumentList -NoProfile [-NoExit] -EncodedCommand <launcher invocation>
          (Windows shows the UAC prompt / credential UI). -Arguments are passed unchanged.
        DifferentUser: checks the Secondary Logon service (seclogon), then Start-Process <System32>\runas.exe with
          [/smartcard] /user:<UserName> "\"<pwsh>\" -NoProfile [-NoExit] -EncodedCommand <launcher invocation>" in a new
          console window, where runas asks for the smart card PIN. The launcher invocation always carries
          -ContainerScope <resolved mode>, -OutputPath <current ReportRoot> when Settings RunAs.PassReportRoot is true
          (the other account has a different profile), and -RequestElevation when -ElevateAfterSignIn.
          /smartcard is used when Settings RunAs.SmartCardByDefault is true (default). The user name is required by the
          documented runas syntax; when -UserName is omitted the RunAsUserName preference is used. After a successful
          start the user name is saved as the RunAsUserName preference.
        -NoExit is added when -Arguments contains NoGui (console stays open), as before.
        The toolkit never prompts for, reads, passes, logs or stores a password or PIN. Never throws; failures are logged
        (Warning) and return $false.
    .PARAMETER Mode
        Elevate | DifferentUser.
    .PARAMETER UserName
        DOMAIN\user or user@domain.tld for DifferentUser.
    .PARAMETER ElevateAfterSignIn
        DifferentUser only: the relaunched launcher receives -RequestElevation.
    .PARAMETER Arguments
        Launcher parameters (name -> value) to pass to the relaunched Start-FSLogixToolkit.ps1.
    .NOTES
        RequiresElevation: No
        Sources: see the header of this file.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Elevate', 'DifferentUser')]
        [string] $Mode,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $UserName,

        [switch] $ElevateAfterSignIn,

        [AllowNull()]
        [hashtable] $Arguments
    )

    try {
        if (-not (Test-FslIsWindows)) {
            Write-FslLog -Message "Relaunch ($Mode) is only supported on Windows." -Level Warning -Component 'Core'
            return $false
        }

        $moduleRoot = [string]$script:FslSession['ModuleRoot']
        $launcherPath = Join-Path -Path $moduleRoot -ChildPath 'Start-FSLogixToolkit.ps1'
        if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
            Write-FslLog -Message "Relaunch ($Mode): launcher not found at '$launcherPath'." -Level Warning -Component 'Core'
            return $false
        }

        $launcherArguments = @{}
        if ($null -ne $Arguments) {
            foreach ($key in @($Arguments.Keys)) { $launcherArguments[[string]$key] = $Arguments[$key] }
        }
        foreach ($blocked in @('RunAsDifferentUser', 'RunAsUserName')) { $launcherArguments.Remove($blocked) }
        $noExit = $false
        if ($launcherArguments.ContainsKey('NoGui')) {
            $noGuiValue = $launcherArguments['NoGui']
            $noExit = ($noGuiValue -is [System.Management.Automation.SwitchParameter] -and $noGuiValue.IsPresent) -or ($noGuiValue -is [bool] -and $noGuiValue)
        }
        $pwshPath = Get-FslCorePwshPath

        if ($Mode -eq 'Elevate') {
            $launcherArguments.Remove('RequestElevation')
            $commandText = New-FslCoreLauncherCommand -LauncherPath $launcherPath -Arguments $launcherArguments
            $argumentList = New-FslCorePwshArgumentList -EncodedCommand (ConvertTo-FslCoreEncodedCommand -CommandText $commandText) -NoExit:$noExit
            $lengthCheck = Test-FslCoreCommandLineLength -ExecutablePath $pwshPath -ArgumentList $argumentList
            if (-not $lengthCheck['Ok']) {
                Write-FslLog -Message "Relaunch elevated refused: $($lengthCheck['Message'])" -Level Warning -Component 'Core'
                return $false
            }
            if (-not $PSCmdlet.ShouldProcess($pwshPath, 'Relaunch FSLogixToolkit elevated (UAC)')) { return $false }
            Write-FslLog -Message "Relaunching elevated: $launcherPath (encoded command length $($argumentList[-1].Length))." -Level Info -Component 'Core'
            Start-Process -FilePath $pwshPath -ArgumentList $argumentList -Verb RunAs -WorkingDirectory $moduleRoot -ErrorAction Stop -WhatIf:$false -Confirm:$false
            return $true
        }

        # DifferentUser
        if ([string]::IsNullOrWhiteSpace($UserName)) {
            $saved = [string](Get-FslPreference -Name 'RunAsUserName')
            if (-not [string]::IsNullOrWhiteSpace($saved)) { $UserName = $saved }
        }
        if ([string]::IsNullOrWhiteSpace($UserName)) {
            Write-FslLog -Message 'Relaunch as a different user refused: a user name (DOMAIN\user or user@domain.tld) is required by the runas syntax.' -Level Warning -Component 'Core'
            return $false
        }
        $UserName = $UserName.Trim()
        if (-not (Test-FslCoreRunAsUserName -UserName $UserName)) {
            Write-FslLog -Message "Relaunch as a different user refused: '$UserName' is not DOMAIN\user or user@domain.tld (no spaces, quotes or %)." -Level Warning -Component 'Core'
            return $false
        }

        $serviceCheck = Test-FslCoreSecondaryLogonService
        if (-not $serviceCheck['Ok']) {
            Write-FslLog -Message "Relaunch as a different user refused: $($serviceCheck['Message'])" -Level Warning -Component 'Core'
            return $false
        }

        $runAsConfig = Get-FslConfig -Section 'RunAs'
        $smartCard = $true
        $passReportRoot = $true
        if ($runAsConfig -is [hashtable]) {
            if ($runAsConfig.ContainsKey('SmartCardByDefault') -and $runAsConfig['SmartCardByDefault'] -is [bool]) { $smartCard = [bool]$runAsConfig['SmartCardByDefault'] }
            if ($runAsConfig.ContainsKey('PassReportRoot') -and $runAsConfig['PassReportRoot'] -is [bool]) { $passReportRoot = [bool]$runAsConfig['PassReportRoot'] }
        }

        $modeArgument = if ($launcherArguments.ContainsKey('ContainerScope') -and -not [string]::IsNullOrWhiteSpace([string]$launcherArguments['ContainerScope'])) {
            Get-FslContainerMode -Mode ([string]$launcherArguments['ContainerScope'])
        }
        else { Get-FslContainerMode }
        $launcherArguments['ContainerScope'] = $modeArgument

        if ($passReportRoot -and -not $launcherArguments.ContainsKey('OutputPath')) {
            $reportRoot = [string]$script:FslSession['ReportRoot']
            if ([string]::IsNullOrWhiteSpace($reportRoot)) {
                try { $reportRoot = [string](Initialize-FslSession).ReportRoot } catch { $reportRoot = $null }
            }
            if (-not [string]::IsNullOrWhiteSpace($reportRoot)) { $launcherArguments['OutputPath'] = $reportRoot }
        }

        $launcherArguments.Remove('RequestElevation')
        if ($ElevateAfterSignIn) { $launcherArguments['RequestElevation'] = $true }

        $commandText = New-FslCoreLauncherCommand -LauncherPath $launcherPath -Arguments $launcherArguments
        $pwshArguments = New-FslCorePwshArgumentList -EncodedCommand (ConvertTo-FslCoreEncodedCommand -CommandText $commandText) -NoExit:$noExit
        $runAsArguments = $null
        try {
            $runAsArguments = New-FslCoreRunAsArgumentString -UserName $UserName -ExecutablePath $pwshPath -ArgumentList $pwshArguments -SmartCard $smartCard
        }
        catch {
            Write-FslLog -Message "Relaunch as a different user refused: $($_.Exception.Message)" -Level Warning -Component 'Core'
            return $false
        }

        $runAsPath = Join-Path -Path ([System.Environment]::SystemDirectory) -ChildPath 'runas.exe'
        $lengthCheck = Test-FslCoreCommandLineLength -ExecutablePath $runAsPath -ArgumentList @($runAsArguments)
        if (-not $lengthCheck['Ok']) {
            Write-FslLog -Message "Relaunch as a different user refused: $($lengthCheck['Message'])" -Level Warning -Component 'Core'
            return $false
        }
        if (-not (Test-Path -LiteralPath $runAsPath -PathType Leaf)) {
            Write-FslLog -Message "Relaunch as a different user refused: runas.exe not found at '$runAsPath'." -Level Warning -Component 'Core'
            return $false
        }

        $action = if ($smartCard) { "Relaunch FSLogixToolkit as $UserName (runas /smartcard)" } else { "Relaunch FSLogixToolkit as $UserName (runas)" }
        if (-not $PSCmdlet.ShouldProcess($runAsPath, $action)) { return $false }

        Write-FslLog -Message ("Relaunching as {0} via runas{1}: container mode {2}; report folder {3}; elevate after sign-in {4}." -f $UserName, $(if ($smartCard) { ' /smartcard' } else { '' }), $modeArgument, $(if ($launcherArguments.ContainsKey('OutputPath')) { $launcherArguments['OutputPath'] } else { '<account default>' }), [bool]$ElevateAfterSignIn) -Level Info -Component 'Core'
        # New console window: runas prompts there for the smart card PIN (runas handles it; the toolkit never sees it).
        Start-Process -FilePath $runAsPath -ArgumentList $runAsArguments -WorkingDirectory ([System.Environment]::SystemDirectory) -ErrorAction Stop -WhatIf:$false -Confirm:$false

        try {
            $null = Set-FslPreference -Name 'RunAsUserName' -Value $UserName -WhatIf:$false -Confirm:$false -ErrorAction Stop
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Saving RunAsUserName preference'
        }
        return $true
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Start-FslCoreRelaunch -Mode $Mode"
        return $false
    }
}
