# Core logging helpers (Agent 1).
# Module-scope state used only by Core helpers. Created when the file is dot-sourced by the loader.
$script:FslCoreLogBuffer = [System.Collections.Generic.List[string]]::new()
$script:FslCoreInitializing = $false
$script:FslCoreInitAttempted = $false
$script:FslCoreLogBufferMax = 1000

function ConvertTo-FslCoreRedactedText {
    <#
    .SYNOPSIS
        Redacts Azure Storage secrets from free text before it is logged or stored.
    .DESCRIPTION
        Masks the values of connection-string keys AccountKey= and SharedAccessSignature= and the SAS
        query parameter sig=. Sources:
        https://learn.microsoft.com/azure/storage/common/storage-configure-connection-string
        https://learn.microsoft.com/azure/storage/common/storage-sas-overview
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    try {
        $redacted = [regex]::Replace($Text, '(?i)(AccountKey\s*=\s*)[^;\s"'']+', '${1}***REDACTED***')
        $redacted = [regex]::Replace($redacted, '(?i)(SharedAccessSignature\s*=\s*)[^;\s"'']+', '${1}***REDACTED***')
        $redacted = [regex]::Replace($redacted, '(?i)((?:^|[?&;\s])sig=)[^&;\s"'']+', '${1}***REDACTED***')
        return $redacted
    }
    catch {
        return '***REDACTION FAILED - TEXT SUPPRESSED***'
    }
}

function Write-FslLog {
    <#
    .SYNOPSIS
        Writes a line to the toolkit log file and forwards it to the matching PowerShell stream.
    .DESCRIPTION
        Line format: yyyy-MM-dd HH:mm:ss.fff [LEVEL] [Component] Message (UTF-8, no BOM).
        Debug lines are written to the file only when the session DebugLogging flag is true.
        Info/Verbose -> Write-Verbose, Debug -> Write-Debug, Warning/Error -> Write-Warning
        (Write-Error is deliberately not used so callers running with ErrorActionPreference Stop
        are not terminated). If the session is not initialized, Initialize-FslSession is attempted once;
        lines produced before a log path exists are buffered and flushed later. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet('Info', 'Warning', 'Error', 'Debug', 'Verbose')]
        [string] $Level = 'Info',

        [ValidateNotNullOrEmpty()]
        [string] $Component = 'Core'
    )

    try {
        $safeMessage = ConvertTo-FslCoreRedactedText -Text $Message
        $session = $script:FslSession

        # Lazy initialization (once) - guarded against recursion from Initialize-FslSession itself.
        if ($null -ne $session -and -not $session['Initialized'] -and -not $script:FslCoreInitializing -and -not $script:FslCoreInitAttempted) {
            $script:FslCoreInitAttempted = $true
            try { $null = Initialize-FslSession } catch { $null = $_ }
        }

        $line = '{0} [{1}] [{2}] {3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level.ToUpperInvariant(), $Component, $safeMessage

        # Forward to streams. Wrapped so -WarningAction/-Debug Stop preferences cannot escape.
        try {
            switch ($Level) {
                'Warning' { Write-Warning -Message "[$Component] $safeMessage" }
                'Error' { Write-Warning -Message "[$Component] ERROR: $safeMessage" }
                'Debug' { Write-Debug -Message "[$Component] $safeMessage" }
                default { Write-Verbose -Message "[$Component] $safeMessage" }
            }
        }
        catch { $null = $_ }

        $debugEnabled = $false
        if ($null -ne $session) { $debugEnabled = [bool]$session['DebugLogging'] }
        if ($Level -eq 'Debug' -and -not $debugEnabled) { return }

        $logPath = $null
        if ($null -ne $session) { $logPath = $session['LogPath'] }

        if ([string]::IsNullOrEmpty($logPath)) {
            if ($script:FslCoreLogBuffer.Count -lt $script:FslCoreLogBufferMax) { $script:FslCoreLogBuffer.Add($line) }
            return
        }

        $text = [System.Text.StringBuilder]::new()
        if ($script:FslCoreLogBuffer.Count -gt 0) {
            foreach ($buffered in $script:FslCoreLogBuffer) { [void]$text.AppendLine($buffered) }
            $script:FslCoreLogBuffer.Clear()
        }
        [void]$text.AppendLine($line)

        Write-FslCoreLogFile -Path $logPath -Text $text.ToString()
    }
    catch {
        try { Write-Verbose -Message "Write-FslLog failed: $($_.Exception.Message)" } catch { $null = $_ }
    }
}

function Write-FslCoreLogFile {
    <#
    .SYNOPSIS
        Appends text to a log file (UTF-8 without BOM) with a short retry on IOException (file in use).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($Path, $Text, $encoding)
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -eq $maxAttempts) {
                Write-Verbose -Message "Log append failed after $maxAttempts attempts: $($_.Exception.Message)"
                return
            }
            Start-Sleep -Milliseconds (25 * $attempt)
        }
        catch {
            Write-Verbose -Message "Log append failed: $($_.Exception.Message)"
            return
        }
    }
}
