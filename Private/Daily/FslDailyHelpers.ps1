# Private helpers for the Daily area (Invoke-/Get-FslDailyHealthCheck, Get-FslDailyHistory,
# Register-/Unregister-FslDailyHealthCheck).
# Sources:
#   https://learn.microsoft.com/cpp/c-language/parsing-c-command-line-arguments (Windows argv quoting rules)
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_pwsh (-File, -NoProfile, -NonInteractive)
#   https://learn.microsoft.com/dotnet/api/system.environment.processpath
#   https://learn.microsoft.com/powershell/module/scheduledtasks/export-scheduledtask
#   https://learn.microsoft.com/windows/win32/taskschd/daily-trigger-example--xml- (Task XML: Triggers/CalendarTrigger/StartBoundary, Principals/Principal/UserId, Actions/Exec/Command)
#   https://learn.microsoft.com/windows/win32/taskschd/taskschedulerschema-arguments-exectype-element
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.management/get-item (-Stream, Windows only)
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/unblock-file (Zone.Identifier)

function Get-FslDailyConfig {
    <#
    .SYNOPSIS
        Returns the Daily settings merged over toolkit defaults (TaskName, TaskPath, Time, RunAs, FolderName, RetainDays, Formats).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    # Toolkit defaults (same values as Config/Settings.psd1 Daily section).
    $config = @{
        TaskName   = 'FSLogixToolkit Daily Health Check'
        TaskPath   = '\FSLogixToolkit\'
        Time       = '06:00'
        RunAs      = 'System'
        FolderName = 'Daily'
        RetainDays = 30
        Formats    = 'Both'
    }
    try {
        $section = Get-FslConfig -Section 'Daily'
        foreach ($key in @($config.Keys)) {
            if ($section.ContainsKey($key) -and $null -ne $section[$key] -and -not [string]::IsNullOrWhiteSpace([string]$section[$key])) {
                $config[$key] = $section[$key]
            }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Reading Daily settings'
    }
    if ([string]$config['Formats'] -notin @('Csv', 'Html', 'Both')) { $config['Formats'] = 'Both' }
    if ([string]$config['RunAs'] -notin @('System', 'CurrentUser')) { $config['RunAs'] = 'System' }
    if ([string]$config['Time'] -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $config['Time'] = '06:00' }
    try { $config['RetainDays'] = [int]$config['RetainDays'] } catch { $config['RetainDays'] = 30 }
    $taskPath = [string]$config['TaskPath']
    if (-not $taskPath.StartsWith('\')) { $taskPath = '\' + $taskPath }
    if (-not $taskPath.EndsWith('\')) { $taskPath = $taskPath + '\' }
    $config['TaskPath'] = $taskPath
    return $config
}

function Resolve-FslDailyReportRoot {
    <#
    .SYNOPSIS
        Returns the report root: -ReportRoot (made absolute) or the session ReportRoot (session initialized implicitly).
    .DESCRIPTION
        When -Initialize is set and -ReportRoot differs from the session ReportRoot, Initialize-FslSession -ReportRoot
        is called so that reports, error log exports and the session agree.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ReportRoot,

        [Parameter()]
        [switch] $Initialize
    )

    if (-not [string]::IsNullOrWhiteSpace($ReportRoot)) {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportRoot)
        if ($Initialize) {
            $current = [string]$script:FslSession['ReportRoot']
            if (-not $script:FslSession['Initialized'] -or [string]::IsNullOrEmpty($current) -or
                -not [string]::Equals($current.TrimEnd('\', '/'), $full.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
                # Keep the current log folder and debug logging; only the report root changes.
                $sessionParams = @{ ReportRoot = $full }
                if ($script:FslSession['Initialized'] -and -not [string]::IsNullOrEmpty([string]$script:FslSession['LogRoot'])) {
                    $sessionParams['LogRoot'] = [string]$script:FslSession['LogRoot']
                }
                if ($script:FslSession['DebugLogging']) { $sessionParams['EnableDebugLogging'] = $true }
                $null = Initialize-FslSession @sessionParams
            }
        }
        return $full
    }
    if (-not $script:FslSession['Initialized']) { $null = Initialize-FslSession }
    $root = [string]$script:FslSession['ReportRoot']
    if ([string]::IsNullOrWhiteSpace($root)) { throw 'No report root available: pass -ReportRoot or run Initialize-FslSession.' }
    return $root
}

function Get-FslDailyJsonValue {
    <#
    .SYNOPSIS
        StrictMode-safe read of a (possibly nested) property from a ConvertFrom-Json object. Returns $null when missing.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name
    )

    $current = $InputObject
    foreach ($segment in $Name) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $null }
            $current = $current[$segment]
            continue
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $null }
        $current = $property.Value
    }
    return $current
}

function Get-FslDailyDayFolder {
    <#
    .SYNOPSIS
        Lists day folders (name yyyy-MM-dd, valid date) directly under the Daily folder, newest first.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DailyRoot
    )

    if (-not (Test-Path -LiteralPath $DailyRoot -PathType Container)) { return }
    $folders = Get-ChildItem -LiteralPath $DailyRoot -Directory -ErrorAction Stop |
        Where-Object -FilterScript { $_.Name -match '^\d{4}-\d{2}-\d{2}$' }
    $items = foreach ($folder in $folders) {
        $date = [datetime]::MinValue
        if ([datetime]::TryParseExact($folder.Name, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$date)) {
            [pscustomobject]@{ Date = $date; Folder = $folder }
        }
    }
    @($items) | Sort-Object -Property Date -Descending
}

function Get-FslDailySummaryFile {
    <#
    .SYNOPSIS
        Lists Summary_*.json files in the day folders under the Daily folder, newest first.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DailyRoot,

        [Parameter()]
        [Nullable[datetime]] $Since
    )

    foreach ($day in @(Get-FslDailyDayFolder -DailyRoot $DailyRoot)) {
        if ($null -ne $Since -and $day.Date -lt ([datetime]$Since).Date) { continue }
        Get-ChildItem -LiteralPath $day.Folder.FullName -File -Filter 'Summary_*.json' -ErrorAction SilentlyContinue |
            Where-Object -FilterScript { $_.Name -match '^Summary_\d{6}(_\d+)?\.json$' } |
            Sort-Object -Property Name -Descending
    }
}

function Read-FslDailySummary {
    <#
    .SYNOPSIS
        Reads a Summary_*.json file. Returns $null (error recorded) when it cannot be parsed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    try {
        $text = [System.IO.File]::ReadAllText($Path)
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context "Read daily summary '$Path'"
        return $null
    }
}

function Get-FslDailyIssueKey {
    <#
    .SYNOPSIS
        Builds the NewIssues comparison key Category|Check|Target|Scope (missing Scope = General).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject
    )

    $parts = foreach ($name in @('Category', 'Check', 'Target', 'Scope')) {
        $value = Get-FslDailyJsonValue -InputObject $InputObject -Name $name
        $text = if ($null -eq $value) { '' } else { [string]$value }
        if ($name -eq 'Scope' -and [string]::IsNullOrWhiteSpace($text)) { $text = 'General' }
        $text
    }
    return (@($parts) -join '|')
}

function Remove-FslDailyExpiredFolder {
    <#
    .SYNOPSIS
        Removes day folders (yyyy-MM-dd) under the Daily folder that are older than RetainDays. Returns removed paths.
    .DESCRIPTION
        Only direct child folders whose name is a valid yyyy-MM-dd date are considered; nothing else is touched.
        RetainDays <= 0 disables pruning. Today's folder is never removed.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DailyRoot,

        [Parameter(Mandatory)]
        [int] $RetainDays
    )

    if ($RetainDays -le 0) { return }
    $cutoff = (Get-Date).Date.AddDays(-$RetainDays)
    foreach ($day in @(Get-FslDailyDayFolder -DailyRoot $DailyRoot)) {
        if ($day.Date -ge $cutoff) { continue }
        $path = $day.Folder.FullName
        if ($PSCmdlet.ShouldProcess($path, 'Remove expired daily health check folder')) {
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                Write-FslLog -Message "Daily: removed expired folder $path (older than $RetainDays days)" -Level Info -Component 'Daily'
                $path
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Daily' -Context "Remove expired daily folder '$path'"
            }
        }
    }
}

function Get-FslDailyToolkitVersion {
    <#
    .SYNOPSIS
        Returns the ModuleVersion from the module manifest, or 'Unknown'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $manifest = Join-Path -Path $script:FslSession['ModuleRoot'] -ChildPath 'FSLogixToolkit.psd1'
        $data = Import-PowerShellDataFile -LiteralPath $manifest -ErrorAction Stop
        if ($data.ContainsKey('ModuleVersion')) { return [string]$data['ModuleVersion'] }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Daily' -Context 'Read module version from manifest'
    }
    return 'Unknown'
}

function ConvertTo-FslDailyQuotedArgument {
    <#
    .SYNOPSIS
        Quotes one argument for a Windows command line so the Microsoft C runtime argv rules return it unchanged.
    .DESCRIPTION
        Rules (learn.microsoft.com/cpp/c-language/parsing-c-command-line-arguments): backslashes are literal unless
        they precede a double quote; 2n backslashes + quote -> n backslashes and a delimiter; 2n+1 backslashes + quote
        -> n backslashes and a literal quote. The argument is wrapped in double quotes when it is empty or contains
        whitespace or quotes (always with -AlwaysQuote); backslashes before an embedded quote or the closing quote
        are doubled, so a trailing backslash (e.g. C:\Reports\) cannot escape the closing quote.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value,

        [Parameter()]
        [switch] $AlwaysQuote
    )

    if (-not $AlwaysQuote -and $Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$sb.Append('\', (2 * $backslashes) + 1)
            [void]$sb.Append('"')
        }
        else {
            if ($backslashes -gt 0) { [void]$sb.Append('\', $backslashes) }
            [void]$sb.Append($character)
        }
        $backslashes = 0
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\', 2 * $backslashes) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertFrom-FslDailyArgumentString {
    <#
    .SYNOPSIS
        Splits a Windows command-line argument string into arguments using the Microsoft C runtime argv rules
        (argv[1..n]; the program name is not part of the input).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ArgumentString
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $inQuotes = $false
    $hasToken = $false
    $chars = $ArgumentString.ToCharArray()
    $i = 0
    while ($i -lt $chars.Length) {
        $c = $chars[$i]
        if ($c -eq '\') {
            $count = 0
            while ($i -lt $chars.Length -and $chars[$i] -eq '\') { $count++; $i++ }
            if ($i -lt $chars.Length -and $chars[$i] -eq '"') {
                [void]$current.Append('\', [int][math]::Floor($count / 2))
                if ($count % 2 -eq 1) {
                    [void]$current.Append('"')
                    $i++
                }
                # even: the quote is processed by the next loop iteration as a delimiter
            }
            else {
                [void]$current.Append('\', $count)
            }
            $hasToken = $true
            continue
        }
        if ($c -eq '"') {
            if ($inQuotes -and ($i + 1) -lt $chars.Length -and $chars[$i + 1] -eq '"') {
                # Within a quoted string, a pair of double quote marks is a single escaped double quote mark.
                [void]$current.Append('"')
                $i += 2
                $hasToken = $true
                continue
            }
            $inQuotes = -not $inQuotes
            $hasToken = $true
            $i++
            continue
        }
        if (-not $inQuotes -and ($c -eq ' ' -or $c -eq "`t")) {
            if ($hasToken) {
                $arguments.Add($current.ToString())
                [void]$current.Clear()
                $hasToken = $false
            }
            $i++
            continue
        }
        [void]$current.Append($c)
        $hasToken = $true
        $i++
    }
    if ($hasToken) { $arguments.Add($current.ToString()) }
    # Unrolled to the pipeline; callers wrap the call in @().
    return $arguments.ToArray()
}

function Get-FslDailyPwshPath {
    <#
    .SYNOPSIS
        Returns the PowerShell 7 executable path: [Environment]::ProcessPath when it is pwsh, else $PSHOME/pwsh(.exe).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $exeName = if (Test-FslIsWindows) { 'pwsh.exe' } else { 'pwsh' }
    $processPath = [System.Environment]::ProcessPath
    if (-not [string]::IsNullOrWhiteSpace($processPath) -and
        [string]::Equals([System.IO.Path]::GetFileName($processPath), $exeName, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $processPath
    }
    return (Join-Path -Path $PSHOME -ChildPath $exeName)
}

function New-FslDailyTaskArgument {
    <#
    .SYNOPSIS
        Builds the scheduled task argument string for Start-FSLogixToolkit.ps1 -Daily.
    .DESCRIPTION
        -NoProfile -NonInteractive -File "<ScriptPath>" -Daily -ContainerScope <mode> -OutputPath "<ReportRoot>" [-Offline]
        Paths are quoted with ConvertTo-FslDailyQuotedArgument. -File must be the last pwsh parameter (about_Pwsh).
        No -ExecutionPolicy argument is added.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string only.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ScriptPath,

        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $ContainerScope,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ReportRoot,

        [Parameter()]
        [switch] $Offline
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($token in @('-NoProfile', '-NonInteractive', '-File')) { $parts.Add($token) }
    $parts.Add((ConvertTo-FslDailyQuotedArgument -Value $ScriptPath -AlwaysQuote))
    $parts.Add('-Daily')
    $parts.Add('-ContainerScope')
    $parts.Add($ContainerScope)
    $parts.Add('-OutputPath')
    $parts.Add((ConvertTo-FslDailyQuotedArgument -Value $ReportRoot -AlwaysQuote))
    if ($Offline) { $parts.Add('-Offline') }
    return ($parts -join ' ')
}

function ConvertFrom-FslDailyTaskArgument {
    <#
    .SYNOPSIS
        Parses a task argument string built by New-FslDailyTaskArgument into ScriptPath, ContainerScope, ReportRoot, Offline, Daily.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ArgumentString
    )

    $tokens = @(ConvertFrom-FslDailyArgumentString -ArgumentString $ArgumentString)
    $result = [ordered]@{ ScriptPath = $null; Daily = $false; ContainerScope = $null; ReportRoot = $null; Offline = $false }
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $token = $tokens[$index]
        $hasNext = ($index + 1) -lt $tokens.Count
        switch -Regex ($token) {
            '^-(File|f)$' { if ($hasNext -and $null -eq $result['ScriptPath']) { $result['ScriptPath'] = $tokens[$index + 1]; $index++ } }
            '^-Daily$' { $result['Daily'] = $true }
            '^-Offline$' { $result['Offline'] = $true }
            '^-ContainerScope$' { if ($hasNext) { $result['ContainerScope'] = $tokens[$index + 1]; $index++ } }
            '^-OutputPath$' { if ($hasNext) { $result['ReportRoot'] = $tokens[$index + 1]; $index++ } }
        }
    }
    return [pscustomobject]$result
}

function Test-FslDailyAccessDenied {
    <#
    .SYNOPSIS
        Returns $true when an ErrorRecord/exception chain indicates access denied (UnauthorizedAccessException or HRESULT 0x80070005).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $ErrorRecord
    )

    if ($null -eq $ErrorRecord) { return $false }
    $exception = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord -as [System.Exception] }
    while ($null -ne $exception) {
        if ($exception -is [System.UnauthorizedAccessException]) { return $true }
        if ($exception.HResult -eq -2147024891) { return $true }   # 0x80070005 E_ACCESSDENIED
        if ($exception.Message -match 'Access is denied') { return $true }
        $exception = $exception.InnerException
    }
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord] -and
        $ErrorRecord.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::PermissionDenied) {
        return $true
    }
    return $false
}

function Find-FslDailyBlockedFile {
    <#
    .SYNOPSIS
        Returns module script files (.ps1/.psm1/.psd1) that carry a Zone.Identifier alternate data stream (Windows only).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ModuleRoot
    )

    if (-not (Test-FslIsWindows)) { return }
    $files = Get-ChildItem -LiteralPath $ModuleRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object -FilterScript { $_.Extension -in @('.ps1', '.psm1', '.psd1') }
    foreach ($file in $files) {
        # Get-Item -Stream is a FileSystem provider dynamic parameter available only on Windows.
        $stream = Get-Item -LiteralPath $file.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
        if ($null -ne $stream) { $file.FullName }
    }
}

function Get-FslDailyTaskDefinition {
    <#
    .SYNOPSIS
        Reads Command, Arguments, UserId and StartBoundary from Export-ScheduledTask XML (namespace-agnostic XPath).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Xml
    )

    $definition = [ordered]@{ Command = $null; Arguments = $null; UserId = $null; LogonType = $null; StartBoundary = $null }
    if ([string]::IsNullOrWhiteSpace($Xml)) { return [pscustomobject]$definition }
    $document = [System.Xml.XmlDocument]::new()
    $document.LoadXml($Xml)
    $map = @{
        Command       = "/*[local-name()='Task']/*[local-name()='Actions']/*[local-name()='Exec']/*[local-name()='Command']"
        Arguments     = "/*[local-name()='Task']/*[local-name()='Actions']/*[local-name()='Exec']/*[local-name()='Arguments']"
        UserId        = "/*[local-name()='Task']/*[local-name()='Principals']/*[local-name()='Principal']/*[local-name()='UserId']"
        LogonType     = "/*[local-name()='Task']/*[local-name()='Principals']/*[local-name()='Principal']/*[local-name()='LogonType']"
        StartBoundary = "/*[local-name()='Task']/*[local-name()='Triggers']/*[local-name()='CalendarTrigger']/*[local-name()='StartBoundary']"
    }
    foreach ($key in $map.Keys) {
        $node = $document.SelectSingleNode($map[$key])
        if ($null -ne $node) { $definition[$key] = $node.InnerText }
    }
    return [pscustomobject]$definition
}
