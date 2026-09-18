# Private helpers for Test-FslStoragePerformance (Agent 6 - Performance).
# Sources:
#   Get-Counter (PowerShell 7.5, Windows only, localized counter names, -ListSet Paths/PathsWithInstances,
#   PerformanceCounterSample Path/InstanceName/CookedValue/Status):
#     https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-counter?view=powershell-7.5
#   PhysicalDisk counter names (Disk Reads/sec, Disk Writes/sec, Disk Transfers/sec, Avg. Disk sec/Read,
#   Avg. Disk sec/Write, Current Disk Queue Length; latency counters are in seconds):
#     https://learn.microsoft.com/en-us/archive/blogs/askcore/windows-performance-monitor-disk-counters-explained
#   SMB Client Shares counter names (Read Requests/sec, Write Requests/sec, Data Requests/sec, Avg. sec/Read,
#   Avg. sec/Write):
#     https://learn.microsoft.com/en-us/archive/blogs/josebda/windows-server-2012-file-server-tip-new-per-share-smb-client-performance-counters-provide-great-insight
#     https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/file-server/smb-file-server
#   FileOptions.WriteThrough / SequentialScan:
#     https://learn.microsoft.com/en-us/dotnet/api/system.io.fileoptions

function Get-FslPerfCounterPath {
    <#
    .SYNOPSIS
        Discovers the wildcard counter paths of a counter set at runtime (Get-Counter -ListSet).
    .DESCRIPTION
        Returns a hashtable: CounterName (as requested) -> wildcard path taken from the set's Paths property,
        plus a HasInstances flag derived from PathsWithInstances. Counters not present in the set are omitted.
        Throws when the counter set cannot be listed (not present, localized name, or access denied).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SetName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string[]] $CounterName
    )

    $set = Get-Counter -ListSet $SetName -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $set) {
        throw "Counter set '$SetName' was not found."
    }
    $paths = @($set.Paths)
    $found = [ordered]@{}
    foreach ($name in $CounterName) {
        $suffix = '\' + $name
        $match = $paths | Where-Object { $_.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($match) { $found[$name] = [string]$match }
    }
    $instancePaths = @($set.PathsWithInstances | Where-Object { $_ -notmatch '\(_Total\)' })
    return @{
        Paths        = $found
        HasInstances = ($instancePaths.Count -gt 0)
    }
}

function Measure-FslPerfCounterSample {
    <#
    .SYNOPSIS
        Aggregates Get-Counter sample sets into average/maximum per counter and instance.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $SampleSet
    )

    $bucket = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[double]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $meta = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($set in $SampleSet) {
        foreach ($sample in @($set.CounterSamples)) {
            # Status 0 = valid sample (see Get-Counter example 11).
            if ([uint32]$sample.Status -ne 0) { continue }
            $samplePath = [string]$sample.Path
            $counter = $samplePath.Substring($samplePath.LastIndexOf('\') + 1)
            $setMatch = [regex]::Match($samplePath, '^\\\\[^\\]+\\(?<set>[^(\\]+)\(')
            $setName = if ($setMatch.Success) { $setMatch.Groups['set'].Value } else { '' }
            $instance = [string]$sample.InstanceName
            $key = "$setName|$instance|$counter"
            if (-not $bucket.ContainsKey($key)) {
                $bucket[$key] = [System.Collections.Generic.List[double]]::new()
                $meta[$key] = [pscustomobject]@{ SetName = $setName; InstanceName = $instance; CounterName = $counter }
            }
            $bucket[$key].Add([double]$sample.CookedValue)
        }
    }
    foreach ($key in $bucket.Keys) {
        $values = $bucket[$key]
        $stats = $values | Measure-Object -Average -Maximum
        [pscustomobject]@{
            SetName      = $meta[$key].SetName
            InstanceName = $meta[$key].InstanceName
            CounterName  = $meta[$key].CounterName
            Average      = [double]$stats.Average
            Maximum      = [double]$stats.Maximum
            SampleCount  = $values.Count
        }
    }
}

function Get-FslPerfLatencyStatus {
    <#
    .SYNOPSIS
        Maps an average latency in milliseconds to Pass/Warn/Fail using toolkit default thresholds.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [double] $ValueMs,
        [Parameter(Mandatory)] [double] $WarnMs,
        [Parameter(Mandatory)] [double] $FailMs
    )
    if ($ValueMs -ge $FailMs) { return 'Fail' }
    if ($ValueMs -ge $WarnMs) { return 'Warn' }
    return 'Pass'
}

function Resolve-FslPerfTarget {
    <#
    .SYNOPSIS
        Classifies storage paths as SMB (UNC), Local (rooted path) or Unsupported and extracts host/share.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Path
    )
    foreach ($item in $Path) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $trimmed = $item.Trim()
        $providerType = 'Unsupported'
        $hostName = $null
        $shareName = $null
        if ($trimmed.StartsWith('\\')) {
            $parts = @($trimmed.TrimStart('\').Split('\', [System.StringSplitOptions]::RemoveEmptyEntries))
            if ($parts.Count -ge 2) {
                $providerType = 'SMB'
                $hostName = $parts[0]
                $shareName = $parts[1]
            }
        }
        elseif ($trimmed -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
            $providerType = 'Unsupported'
        }
        elseif ([System.IO.Path]::IsPathRooted($trimmed)) {
            $providerType = 'Local'
        }
        [pscustomobject]@{
            Path         = $trimmed
            ProviderType = $providerType
            HostName     = $hostName
            ShareName    = $shareName
        }
    }
}

function Test-FslPerfSmbInstanceMatch {
    <#
    .SYNOPSIS
        Tests whether an 'SMB Client Shares' counter instance name refers to the given host and share.
    .DESCRIPTION
        The exact instance name format is not documented in the verified sources, so the comparison is tolerant:
        leading backslashes are ignored and the host may match by full name or by its first DNS label.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $InstanceName,
        [Parameter(Mandatory)] [string] $HostName,
        [Parameter(Mandatory)] [string] $ShareName
    )
    $parts = @($InstanceName.TrimStart('\').Split('\', [System.StringSplitOptions]::RemoveEmptyEntries))
    if ($parts.Count -lt 2) { return $false }
    $instanceHost = $parts[0]
    $instanceShare = $parts[1]
    if (-not [string]::Equals($instanceShare, $ShareName, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ([string]::Equals($instanceHost, $HostName, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $shortHost = $HostName.Split('.')[0]
    $shortInstanceHost = $instanceHost.Split('.')[0]
    return [string]::Equals($shortHost, $shortInstanceHost, [System.StringComparison]::OrdinalIgnoreCase)
}

function Invoke-FslPerfWriteTest {
    <#
    .SYNOPSIS
        Coarse sequential write/read test using a uniquely named temporary file in the given folder.
    .DESCRIPTION
        Writes SizeMB of random bytes with FileOptions.WriteThrough, flushes to disk, then reads the file back
        sequentially. The temporary file is always removed in finally. Returns a result object; throws only for
        unexpected failures after the file was created. A path that cannot be written returns Writable = $false.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Folder,
        [Parameter(Mandatory)] [ValidateRange(1, 102400)] [int] $SizeMB
    )

    $blockMB = if ($SizeMB -ge 4) { 4 } else { 1 }
    $blockBytes = $blockMB * 1MB
    $totalBytes = [long]$SizeMB * 1MB
    $fileName = '.FSLogixToolkit_perftest_{0}.tmp' -f [guid]::NewGuid().ToString('N')
    $filePath = Join-Path -Path $Folder -ChildPath $fileName
    $created = $false
    $writeStream = $null
    $readStream = $null
    try {
        $buffer = [byte[]]::new($blockBytes)
        [System.Random]::new().NextBytes($buffer)

        try {
            $writeStream = [System.IO.FileStream]::new($filePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::WriteThrough)
            $created = $true
        }
        catch [System.UnauthorizedAccessException], [System.IO.IOException], [System.Security.SecurityException] {
            return [pscustomobject]@{ Writable = $false; Message = $_.Exception.Message }
        }

        $writeWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $written = [long]0
        while ($written -lt $totalBytes) {
            $count = [int][System.Math]::Min([long]$blockBytes, $totalBytes - $written)
            $writeStream.Write($buffer, 0, $count)
            $written += $count
        }
        $writeStream.Flush($true)
        $writeWatch.Stop()
        $writeStream.Dispose()
        $writeStream = $null

        $readBuffer = [byte[]]::new($blockBytes)
        $readWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $readStream = [System.IO.FileStream]::new($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read, 4096, [System.IO.FileOptions]::SequentialScan)
        $readTotal = [long]0
        while (($readCount = $readStream.Read($readBuffer, 0, $readBuffer.Length)) -gt 0) {
            $readTotal += $readCount
        }
        $readWatch.Stop()

        $writeSeconds = [System.Math]::Max($writeWatch.Elapsed.TotalSeconds, 0.000001)
        $readSeconds = [System.Math]::Max($readWatch.Elapsed.TotalSeconds, 0.000001)
        return [pscustomobject]@{
            Writable      = $true
            Message       = $null
            SizeMB        = $SizeMB
            BlockSizeMB   = $blockMB
            WriteMs       = [System.Math]::Round($writeWatch.Elapsed.TotalMilliseconds, 1)
            WriteMBps     = [System.Math]::Round(($written / 1MB) / $writeSeconds, 1)
            ReadMs        = [System.Math]::Round($readWatch.Elapsed.TotalMilliseconds, 1)
            ReadMBps      = [System.Math]::Round(($readTotal / 1MB) / $readSeconds, 1)
            BytesWritten  = $written
            BytesRead     = $readTotal
        }
    }
    finally {
        if ($null -ne $writeStream) { $writeStream.Dispose() }
        if ($null -ne $readStream) { $readStream.Dispose() }
        if ($created -and (Test-Path -LiteralPath $filePath)) {
            try {
                Remove-Item -LiteralPath $filePath -Force -ErrorAction Stop
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Performance' -Context "Removing write test file '$filePath'"
            }
        }
    }
}

function Get-FslPerfScopeMap {
    <#
    .SYNOPSIS
        Builds a case-insensitive map of trimmed storage location path -> Result scope (contract P2.2/P2.4).
    .DESCRIPTION
        A path configured for exactly one container scope (Profiles or ODFC) maps to that scope; a path configured
        for both maps to General. Paths not in the map (for example explicit -Path values) are General.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, string]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $StorageLocation
    )

    $scopesByPath = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($location in $StorageLocation) {
        if ($null -eq $location) { continue }
        $locationPath = ([string]$location.Path).Trim()
        if ([string]::IsNullOrWhiteSpace($locationPath)) { continue }
        if (-not $scopesByPath.ContainsKey($locationPath)) {
            $scopesByPath[$locationPath] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        [void]$scopesByPath[$locationPath].Add([string]$location.Scope)
    }
    $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $scopesByPath.Keys) {
        $map[$key] = Get-FslPerfCommonScope -Scope @($scopesByPath[$key])
    }
    , $map
}

function Get-FslPerfCommonScope {
    <#
    .SYNOPSIS
        Returns the single container scope (Profiles or ODFC) shared by all given scopes; General when mixed or empty.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [string[]] $Scope
    )

    $distinct = @($Scope | Where-Object { -not [string]::IsNullOrEmpty($_) } | Sort-Object -Unique)
    if ($distinct.Count -eq 1 -and $distinct[0] -in @('Profiles', 'ODFC')) { return [string]$distinct[0] }
    return 'General'
}

function Get-FslPerfTargetScope {
    <#
    .SYNOPSIS
        Returns the Result scope for one resolved performance target path using a map from Get-FslPerfScopeMap.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [System.Collections.Generic.Dictionary[string, string]] $ScopeMap,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path
    )

    if ($null -ne $ScopeMap -and $ScopeMap.ContainsKey($Path.Trim())) { return $ScopeMap[$Path.Trim()] }
    return 'General'
}
