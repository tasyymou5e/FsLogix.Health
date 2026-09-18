# Private helpers for the Diagnostics area (prefix *-FslDiag*).
# Sources:
#   https://learn.microsoft.com/en-us/fslogix/troubleshooting-events-logs-diagnostics
#   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings (Logging: LogDir default %ProgramData%\FSLogix\Logs)

# Default FSLogix text log folder (reference-configuration-settings, Logging > LogDir default value).
$script:FslDiagDefaultLogDir = '%ProgramData%\FSLogix\Logs'

# Verified FSLogix event log channel (troubleshooting-known-issues shows 'Log Name: Microsoft-FSLogix-Apps/Operational').
# Other FSLogix channels (Apps Admin, CloudCache Admin/Operational) are documented only by their Event Viewer
# folder, so they are discovered at runtime with Get-WinEvent -ListLog 'Microsoft-FSLogix-*'.
$script:FslDiagVerifiedEventLog = 'Microsoft-FSLogix-Apps/Operational'
$script:FslDiagEventLogPattern = 'Microsoft-FSLogix-*'

function ConvertTo-FslDiagRedactedText {
    <#
    .SYNOPSIS
        Redacts Azure storage secrets (AccountKey=, SharedAccessSignature=, sig=) from text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $result = [regex]::Replace($Text, '(AccountKey\s*=\s*)[^;"''\s<>&]+', '${1}REDACTED', $options)
    $result = [regex]::Replace($result, '(SharedAccessSignature\s*=\s*)[^;"''\s<>]+', '${1}REDACTED', $options)
    $result = [regex]::Replace($result, '(\bsig=)[^&;"''\s<>]+', '${1}REDACTED', $options)
    return $result
}

function ConvertTo-FslDiagVersion {
    <#
    .SYNOPSIS
        Converts a string/version object to [version]; returns $null when it cannot be parsed.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [version]) { return $InputObject }
    $text = ([string]$InputObject).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = $null
    if ([version]::TryParse($text, [ref]$parsed)) { return $parsed }
    return $null
}

function Test-FslDiagIssueApplicable {
    <#
    .SYNOPSIS
        Returns $true when a KnownIssues.psd1 entry applies to the given FSLogix version.
    .DESCRIPTION
        AffectedFrom/AffectedTo are inclusive bounds ($null = unbounded). Versions >= FixedIn never match.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Issue,

        [Parameter(Mandatory)]
        [version] $Version
    )

    $from = ConvertTo-FslDiagVersion -InputObject $Issue['AffectedFrom']
    $to = ConvertTo-FslDiagVersion -InputObject $Issue['AffectedTo']
    $fixed = ConvertTo-FslDiagVersion -InputObject $Issue['FixedIn']

    if ($null -ne $from -and $Version -lt $from) { return $false }
    if ($null -ne $to -and $Version -gt $to) { return $false }
    if ($null -ne $fixed -and $Version -ge $fixed) { return $false }
    return $true
}

function Get-FslDiagLogDirectory {
    <#
    .SYNOPSIS
        Returns the FSLogix text log folder: Logging\LogDir when configured, else the documented default.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $logDir = $script:FslDiagDefaultLogDir
    try {
        if (Get-Command -Name 'Get-FslEffectiveSetting' -ErrorAction SilentlyContinue) {
            $setting = Get-FslEffectiveSetting -Scope 'Logging' |
                Where-Object -FilterScript { $_.Name -eq 'LogDir' } |
                Select-Object -First 1
            if ($null -ne $setting -and -not [string]::IsNullOrWhiteSpace([string]$setting.Value)) {
                $logDir = [string]$setting.Value
            }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Diagnostics' -Context 'Reading FSLogix Logging\LogDir setting'
    }
    return [System.Environment]::ExpandEnvironmentVariables($logDir)
}

function Get-FslDiagLogFileSummary {
    <#
    .SYNOPSIS
        Counts FSLogix text log lines with [ERROR:xxxxxx] / [WARN:xxxxxx] prefixes and groups their messages.
    .DESCRIPTION
        Line markers are documented at
        https://learn.microsoft.com/en-us/fslogix/troubleshooting-events-logs-diagnostics
        ("[INFO] ... [WARN:xxxxxx] ... [ERROR:xxxxxx]"). Other line fields are not parsed; the message is the
        raw text starting at the marker. Files are opened with FileShare.ReadWrite because the service may
        be writing to them.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo] $File,

        [Parameter()]
        [ValidateRange(1, 1000)]
        [int] $SampleSize = 20
    )

    $errorCount = 0
    $warningCount = 0
    $matched = [System.Collections.Generic.List[string]]::new()
    $markerRegex = [regex]::new('\[(ERROR|WARN):[^\]]*\]', [System.Text.RegularExpressions.RegexOptions]::None)

    $stream = [System.IO.FileStream]::new($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
        $reader = [System.IO.StreamReader]::new($stream, $true)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                $match = $markerRegex.Match($line)
                if (-not $match.Success) { continue }
                if ($match.Groups[1].Value -eq 'ERROR') { $errorCount++ } else { $warningCount++ }
                $message = $line.Substring($match.Index).Trim()
                if ($message.Length -gt 300) { $message = $message.Substring(0, 300) }
                $matched.Add((ConvertTo-FslDiagRedactedText -Text $message))
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    $top = @()
    if ($matched.Count -gt 0) {
        $top = @($matched | Group-Object -NoElement | Sort-Object -Property Count -Descending |
                Select-Object -First $SampleSize | ForEach-Object -Process { '{0}x {1}' -f $_.Count, $_.Name })
    }

    [pscustomobject]@{
        File         = $File.FullName
        ErrorCount   = $errorCount
        WarningCount = $warningCount
        TopMessages  = $top
    }
}

function Copy-FslDiagFile {
    <#
    .SYNOPSIS
        Copies a file into the staging folder, redacting secrets from text content.
    .DESCRIPTION
        Reads with FileShare.ReadWrite so files open by other processes (FSLogix service, toolkit logger) can be copied.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [string] $SourcePath,

        [Parameter(Mandatory)]
        [string] $DestinationPath
    )

    $textExtensions = @('.log', '.txt', '.csv', '.json', '.html', '.htm', '.xml', '.md')
    $parent = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -Path $parent -ItemType Directory -Force
    }

    $extension = [System.IO.Path]::GetExtension($SourcePath).ToLowerInvariant()
    $stream = [System.IO.FileStream]::new($SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
        if ($textExtensions -contains $extension) {
            $reader = [System.IO.StreamReader]::new($stream, $true)
            try {
                $content = $reader.ReadToEnd()
                $encoding = $reader.CurrentEncoding
            }
            finally {
                $reader.Dispose()
            }
            [System.IO.File]::WriteAllText($DestinationPath, (ConvertTo-FslDiagRedactedText -Text $content), $encoding)
        }
        else {
            $target = [System.IO.File]::Create($DestinationPath)
            try { $stream.CopyTo($target) } finally { $target.Dispose() }
        }
    }
    finally {
        $stream.Dispose()
    }
    return [System.IO.FileInfo]::new($DestinationPath)
}

function Get-FslDiagIssueRangeText {
    <#
    .SYNOPSIS
        Formats the affected range and fixed-in version of a known issue entry.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Issue
    )

    $from = if ($Issue['AffectedFrom']) { [string]$Issue['AffectedFrom'] } else { 'not stated' }
    $to = if ($Issue['AffectedTo']) { [string]$Issue['AffectedTo'] } else { 'not stated' }
    $fixed = if ($Issue['FixedIn']) { [string]$Issue['FixedIn'] } else { 'not stated' }
    $state = if ($Issue['State']) { [string]$Issue['State'] } else { 'not stated' }
    return ('AffectedFrom: {0}; AffectedTo: {1}; FixedIn: {2}; State: {3}' -f $from, $to, $fixed, $state)
}

function Get-FslDiagIssueScope {
    <#
    .SYNOPSIS
        Returns the Scope tag of a KnownIssues.psd1 entry (General|Profiles|ODFC|CloudCache); missing/unknown -> General.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Issue
    )

    if ($Issue.ContainsKey('Scope')) {
        $value = [string]$Issue['Scope']
        foreach ($known in @('General', 'Profiles', 'ODFC', 'CloudCache')) {
            if ([string]::Equals($value, $known, [System.StringComparison]::OrdinalIgnoreCase)) { return $known }
        }
    }
    return 'General'
}

function ConvertTo-FslDiagResultScope {
    <#
    .SYNOPSIS
        Maps a known-issue or log scope to a Result Scope: Profiles -> Profiles, ODFC -> ODFC, anything else (General, CloudCache) -> General.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Scope
    )

    if ($Scope -eq 'Profiles') { return 'Profiles' }
    if ($Scope -eq 'ODFC') { return 'ODFC' }
    return 'General'
}

# FSLogix text log subfolders mapped to a container scope. A subfolder may be mapped only when Microsoft Learn documents
# that its log is limited to one container type. The only documented subfolder is 'Profile'
# (C:\ProgramData\FSLogix\Logs\Profile\Profile_%date%.log, https://learn.microsoft.com/en-us/fslogix/troubleshooting-events-logs-diagnostics),
# which is described as the most common troubleshooting log, not as profile-container-only. Per
# https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings (Logging), LoggingEnabled defaults to 2, which
# ignores the component-specific settings and enables all log files; the component switches (including ODFC, default 0)
# apply only when LoggingEnabled = 1, so ODFC activity may be written to the Profile log or to a separate ODFC log. The Profile subfolder therefore stays General (always included, also in ODFC mode).
$script:FslDiagVerifiedLogSubfolderScope = @{
    'Profile' = 'General'
}

function Get-FslDiagLogFileScope {
    <#
    .SYNOPSIS
        Returns the scope of an FSLogix text log file from its first subfolder under the log folder:
        a subfolder documented as limited to one container type maps to that scope; everything else
        (including Profile, which is not documented as profile-only) -> General.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FilePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LogDirectory
    )

    try {
        $relative = [System.IO.Path]::GetRelativePath($LogDirectory, $FilePath)
    }
    catch {
        return 'General'
    }
    if ([string]::IsNullOrEmpty($relative) -or $relative.StartsWith('..') -or [System.IO.Path]::IsPathRooted($relative)) { return 'General' }
    $segments = $relative.Split([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar), [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($segments.Count -lt 2) { return 'General' }   # file directly in the log folder
    foreach ($key in $script:FslDiagVerifiedLogSubfolderScope.Keys) {
        if ([string]::Equals($segments[0], $key, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$script:FslDiagVerifiedLogSubfolderScope[$key]
        }
    }
    return 'General'
}
