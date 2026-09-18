function Test-FslStoragePerformance {
    <#
    .SYNOPSIS
        Measures storage IOPS and latency for FSLogix storage locations using performance counters, with an
        optional coarse sequential write/read test.
    .DESCRIPTION
        Samples Windows performance counters with Get-Counter (SampleInterval 1 second, MaxSamples = SampleSeconds)
        and reports average and maximum values per instance:
          - PhysicalDisk: Disk Reads/sec, Disk Writes/sec, Disk Transfers/sec (IOPS, Info),
            Avg. Disk sec/Read and Avg. Disk sec/Write (latency, converted to ms, Pass/Warn/Fail),
            Current Disk Queue Length (Info). The _Total instance is reported separately (Target '_Total').
          - SMB Client Shares: Read Requests/sec, Write Requests/sec, Data Requests/sec (IOPS, Info),
            Avg. sec/Read and Avg. sec/Write (latency in ms, Pass/Warn/Fail) for instances that match the SMB
            storage locations.
        Counter sets and counter paths are discovered at runtime with Get-Counter -ListSet. Counter names are
        localized; when the English counter sets cannot be found (non-English OS) or cannot be read (access
        denied), a Skipped result is returned with the reason instead of throwing.
        Latency thresholds come from Config/Settings.psd1 (Performance.LatencyMsWarn / LatencyMsFail) and are
        toolkit defaults, not Microsoft guidance.

        -IncludeWriteTest (opt-in) writes Performance.WriteTestSizeMB of random data in 4 MB blocks (1 MB when
        the size is below 4 MB) to a uniquely named temporary file (.FSLogixToolkit_perftest_<guid>.tmp) in the
        root of each SMB/Local storage location using FileOptions.WriteThrough, flushes to disk, then reads it
        back sequentially and reports MB/s and elapsed ms. The file is always deleted. This is a coarse,
        single-threaded sequential test and is not a substitute for DiskSpd. Read results can be served from the
        client cache. The test never writes inside user container folders.

        Result Scope: PhysicalDisk counters and host-wide items are General; share/location-specific results
        (SMB share latency/IOPS, write test, skipped targets) carry the scope of the storage location (General
        when a path is configured for both Profiles and ODFC, or when it was supplied with -Path). SMB Client
        Shares counter set status rows carry the common scope of the SMB targets (General when mixed).
        With -Scope ODFC only ODFC storage locations are resolved, sampled and written to.
    .PARAMETER Path
        Storage location paths (UNC paths such as \\server\share\folder, or local rooted paths). Defaults to the
        SMB and Local locations returned by Get-FslStorageLocation.
    .PARAMETER SampleSeconds
        Number of one-second counter samples to collect. Defaults to Performance.SampleSeconds (toolkit default 10).
    .PARAMETER IncludeWriteTest
        Opt-in: run the temporary-file sequential write/read test against each SMB/Local location root.
    .PARAMETER Scope
        Container scopes whose storage locations are the default targets: Profiles, ODFC or both (default, phase 1
        behavior). Passed to Get-FslStorageLocation -Scope. Ignored for target selection when -Path is supplied.
    .EXAMPLE
        Test-FslStoragePerformance
        Samples PhysicalDisk and SMB client share counters for the configured FSLogix storage locations.
    .EXAMPLE
        Test-FslStoragePerformance -Path '\\fs01\profiles' -SampleSeconds 30 -IncludeWriteTest
        Samples counters for 30 seconds and runs the write/read test against \\fs01\profiles.
    .EXAMPLE
        Test-FslStoragePerformance -Scope ODFC
        Samples PhysicalDisk counters and SMB client share counters for the Office container (ODFC) locations only.
    .OUTPUTS
        FSLogixToolkit.Result
    .NOTES
        RequiresElevation: No. Get-Counter documentation: many counter sets are protected by access control lists
        (ACL); to see all counter sets, open PowerShell with the Run as administrator option. When counters cannot
        be read, results are Skipped with RequiresElevation = $true when the session is not elevated.
        Windows only for counters (Get-Counter is only available on Windows); the write test also runs on other
        platforms for testing.
        Sources:
          https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-counter?view=powershell-7.5
          https://learn.microsoft.com/en-us/archive/blogs/askcore/windows-performance-monitor-disk-counters-explained
          https://learn.microsoft.com/en-us/archive/blogs/josebda/windows-server-2012-file-server-tip-new-per-share-smb-client-performance-counters-provide-great-insight
          https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/file-server/smb-file-server
          https://learn.microsoft.com/en-us/dotnet/api/system.io.fileoptions
          https://learn.microsoft.com/en-us/previous-versions/azure/azure-local/manage/diskspd-overview
    #>
    [CmdletBinding()]
    [OutputType('FSLogixToolkit.Result')]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int] $SampleSeconds,

        [Parameter()]
        [switch] $IncludeWriteTest,

        [Parameter()]
        [ValidateSet('Profiles', 'ODFC')]
        [string[]] $Scope = @('Profiles', 'ODFC')
    )

    $category = 'Performance'
    $getCounterUrl = 'https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-counter?view=powershell-7.5'
    $diskCounterUrl = 'https://learn.microsoft.com/en-us/archive/blogs/askcore/windows-performance-monitor-disk-counters-explained'
    $smbCounterUrl = 'https://learn.microsoft.com/en-us/archive/blogs/josebda/windows-server-2012-file-server-tip-new-per-share-smb-client-performance-counters-provide-great-insight'
    $diskSpdUrl = 'https://learn.microsoft.com/en-us/previous-versions/azure/azure-local/manage/diskspd-overview'

    # --- Configuration (toolkit defaults) -------------------------------------------------------------------
    $warnMs = 20
    $failMs = 50
    $writeTestSizeMB = 64
    $configSampleSeconds = 10
    try {
        $config = Get-FslConfig -Section 'Performance'
        if ($config -is [System.Collections.IDictionary]) {
            if ($config.Contains('LatencyMsWarn')) { $warnMs = [double]$config['LatencyMsWarn'] }
            if ($config.Contains('LatencyMsFail')) { $failMs = [double]$config['LatencyMsFail'] }
            if ($config.Contains('WriteTestSizeMB')) { $writeTestSizeMB = [int]$config['WriteTestSizeMB'] }
            if ($config.Contains('SampleSeconds')) { $configSampleSeconds = [int]$config['SampleSeconds'] }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component $category -Context 'Reading Performance settings; using built-in toolkit defaults'
    }
    if (-not $PSBoundParameters.ContainsKey('SampleSeconds')) {
        $SampleSeconds = [System.Math]::Max(1, $configSampleSeconds)
    }
    if ($writeTestSizeMB -lt 1) { $writeTestSizeMB = 1 }
    $expectedLatency = "Average < $warnMs ms (Warn at >= $warnMs ms, Fail at >= $failMs ms; toolkit default)"

    $onWindows = [bool](Test-FslIsWindows)
    $isElevated = $false
    try { $isElevated = [bool](Test-FslElevation) }
    catch { Add-FslError -ErrorRecord $_ -Component $category -Context 'Checking elevation' }

    # --- Resolve targets ------------------------------------------------------------------------------------
    $targets = @()
    $scopeMap = $null
    $selectedScopes = @($Scope | Select-Object -Unique)
    try {
        if ($PSBoundParameters.ContainsKey('Path')) {
            $targets = @(Resolve-FslPerfTarget -Path $Path)
        }
        else {
            $locations = @(Get-FslStorageLocation -Scope $selectedScopes | Where-Object { $_.ProviderType -in @('SMB', 'Local') -and $_.Scope -in $selectedScopes })
            $scopeMap = Get-FslPerfScopeMap -StorageLocation $locations
            $locationPaths = @($locations | ForEach-Object { [string]$_.Path } | Select-Object -Unique)
            $targets = @(Resolve-FslPerfTarget -Path $locationPaths)
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component $category -Context 'Resolving storage locations'
        New-FslResult -Category $category -Check 'Storage locations' -Status 'Error' `
            -Message "Could not resolve storage locations: $($_.Exception.Message)" -Source 'Toolkit default' -Scope 'General'
    }
    foreach ($unsupported in @($targets | Where-Object { $_.ProviderType -eq 'Unsupported' })) {
        New-FslResult -Category $category -Check 'Storage target' -Status 'Skipped' -Target $unsupported.Path `
            -Message 'Path is not a UNC (SMB) or local rooted path; storage performance counters and the write test are not applicable.' `
            -Source 'Toolkit default' -Scope (Get-FslPerfTargetScope -ScopeMap $scopeMap -Path $unsupported.Path)
    }
    $smbTargets = @($targets | Where-Object { $_.ProviderType -eq 'SMB' })
    $fileTargets = @($targets | Where-Object { $_.ProviderType -in @('SMB', 'Local') })
    # Counter set level SMB rows cover all SMB targets: their common scope, General when mixed.
    $smbSetScope = Get-FslPerfCommonScope -Scope @($smbTargets | ForEach-Object { Get-FslPerfTargetScope -ScopeMap $scopeMap -Path $_.Path })
    if ($targets.Count -eq 0) {
        New-FslResult -Category $category -Check 'Storage locations' -Status 'Info' `
            -Message 'No SMB or local storage locations were supplied or configured; only local PhysicalDisk counters are sampled.' `
            -Source 'Toolkit default' -Scope 'General'
    }

    # --- Performance counters -------------------------------------------------------------------------------
    if (-not $onWindows) {
        New-FslResult -Category $category -Check 'Performance counters' -Status 'Skipped' `
            -Message 'Get-Counter is only available on Windows; PhysicalDisk and SMB Client Shares counters were not sampled.' `
            -Source $getCounterUrl -Scope 'General'
    }
    else {
        $diskCounters = @('Disk Reads/sec', 'Disk Writes/sec', 'Disk Transfers/sec', 'Avg. Disk sec/Read', 'Avg. Disk sec/Write', 'Current Disk Queue Length')
        $smbCounters = @('Read Requests/sec', 'Write Requests/sec', 'Data Requests/sec', 'Avg. sec/Read', 'Avg. sec/Write')
        # Wording per the Get-Counter documentation (PowerShell 7.5).
        $accessMessage = 'Many counter sets are protected by access control lists (ACL); to see all counter sets, open PowerShell with the Run as administrator option. Performance counter names are also localized; on non-English systems the English counter set names are not found.'
        $counterPaths = [System.Collections.Generic.List[string]]::new()
        $diskAvailable = $false
        $smbAvailable = $false

        try {
            $diskInfo = Get-FslPerfCounterPath -SetName 'PhysicalDisk' -CounterName $diskCounters
            foreach ($name in $diskCounters) {
                if ($diskInfo.Paths.Contains($name)) { $counterPaths.Add($diskInfo.Paths[$name]) }
            }
            $missingDisk = @($diskCounters | Where-Object { -not $diskInfo.Paths.Contains($_) })
            if ($missingDisk.Count -gt 0) {
                New-FslResult -Category $category -Check 'PhysicalDisk counters' -Status 'Warn' `
                    -Value ($missingDisk -join '; ') -Message 'Some expected PhysicalDisk counters were not found (localized names or missing counters).' `
                    -Source $diskCounterUrl -Scope 'General'
            }
            $diskAvailable = ($diskInfo.Paths.Count -gt 0)
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $category -Context "Get-Counter -ListSet 'PhysicalDisk'"
            New-FslResult -Category $category -Check 'PhysicalDisk counters' -Status 'Skipped' `
                -Message "Unable to list the PhysicalDisk counter set: $($_.Exception.Message) $accessMessage" `
                -Source $getCounterUrl -RequiresElevation (-not $isElevated) -Scope 'General'
        }

        if ($smbTargets.Count -gt 0) {
            try {
                $smbInfo = Get-FslPerfCounterPath -SetName 'SMB Client Shares' -CounterName $smbCounters
                if (-not $smbInfo.HasInstances) {
                    New-FslResult -Category $category -Check 'SMB client share counters' -Status 'Info' `
                        -Message 'The SMB Client Shares counter set has no active share instances; no SMB traffic has been observed for any share yet.' `
                        -Source $smbCounterUrl -Scope $smbSetScope
                }
                else {
                    foreach ($name in $smbCounters) {
                        if ($smbInfo.Paths.Contains($name)) { $counterPaths.Add($smbInfo.Paths[$name]) }
                    }
                    $missingSmb = @($smbCounters | Where-Object { -not $smbInfo.Paths.Contains($_) })
                    if ($missingSmb.Count -gt 0) {
                        New-FslResult -Category $category -Check 'SMB client share counters' -Status 'Warn' `
                            -Value ($missingSmb -join '; ') -Message 'Some expected SMB Client Shares counters were not found (localized names or missing counters).' `
                            -Source $smbCounterUrl -Scope $smbSetScope
                    }
                    $smbAvailable = ($smbInfo.Paths.Count -gt 0)
                }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component $category -Context "Get-Counter -ListSet 'SMB Client Shares'"
                New-FslResult -Category $category -Check 'SMB client share counters' -Status 'Skipped' `
                    -Message "Unable to list the SMB Client Shares counter set: $($_.Exception.Message) $accessMessage" `
                    -Source $getCounterUrl -RequiresElevation (-not $isElevated) -Scope $smbSetScope
            }
        }

        $stats = @()
        if ($counterPaths.Count -gt 0) {
            try {
                Write-FslLog -Message "Sampling $($counterPaths.Count) counter path(s) for $SampleSeconds second(s)." -Level Verbose -Component $category
                $sampleSets = @(Get-Counter -Counter $counterPaths.ToArray() -SampleInterval 1 -MaxSamples $SampleSeconds -ErrorAction Stop)
                $stats = @(Measure-FslPerfCounterSample -SampleSet $sampleSets)
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component $category -Context 'Get-Counter sampling'
                $firstError = $_.Exception.Message
                $diskOnly = @($counterPaths | Where-Object { $_.StartsWith('\PhysicalDisk(', [System.StringComparison]::OrdinalIgnoreCase) })
                if ($smbAvailable -and $diskAvailable -and $diskOnly.Count -gt 0) {
                    New-FslResult -Category $category -Check 'SMB client share counters' -Status 'Skipped' `
                        -Message "Sampling PhysicalDisk and SMB Client Shares counters together failed ($firstError); retrying with PhysicalDisk counters only." `
                        -Source $getCounterUrl -RequiresElevation (-not $isElevated) -Scope $smbSetScope
                    $smbAvailable = $false
                    try {
                        $sampleSets = @(Get-Counter -Counter $diskOnly -SampleInterval 1 -MaxSamples $SampleSeconds -ErrorAction Stop)
                        $stats = @(Measure-FslPerfCounterSample -SampleSet $sampleSets)
                    }
                    catch {
                        Add-FslError -ErrorRecord $_ -Component $category -Context 'Get-Counter sampling (PhysicalDisk only)'
                        New-FslResult -Category $category -Check 'Performance counters' -Status 'Skipped' `
                            -Message "Sampling performance counters failed: $($_.Exception.Message) $accessMessage" `
                            -Source $getCounterUrl -RequiresElevation (-not $isElevated) -Scope 'General'
                    }
                }
                else {
                    New-FslResult -Category $category -Check 'Performance counters' -Status 'Skipped' `
                        -Message "Sampling performance counters failed: $firstError $accessMessage" `
                        -Source $getCounterUrl -RequiresElevation (-not $isElevated) -Scope 'General'
                }
            }
        }

        $sampleNote = "$SampleSeconds x 1 s samples"

        # PhysicalDisk results
        if ($diskAvailable -and $stats.Count -gt 0) {
            $diskStats = @($stats | Where-Object { $_.CounterName -in $diskCounters })
            $instances = @($diskStats | ForEach-Object { $_.InstanceName } | Sort-Object -Unique |
                    Sort-Object -Property @{ Expression = { $_ -eq '_total' } }, @{ Expression = { $_ } })
            foreach ($instance in $instances) {
                $target = if ($instance -eq '_total') { '_Total' } else { "PhysicalDisk($instance)" }
                $byName = @{}
                foreach ($stat in @($diskStats | Where-Object { $_.InstanceName -eq $instance })) {
                    $byName[$stat.CounterName] = $stat
                }
                foreach ($latency in @(@{ Counter = 'Avg. Disk sec/Read'; Check = 'PhysicalDisk read latency' },
                        @{ Counter = 'Avg. Disk sec/Write'; Check = 'PhysicalDisk write latency' })) {
                    if (-not $byName.ContainsKey($latency.Counter)) { continue }
                    $stat = $byName[$latency.Counter]
                    $avgMs = [System.Math]::Round($stat.Average * 1000, 2)
                    $maxMs = [System.Math]::Round($stat.Maximum * 1000, 2)
                    $status = Get-FslPerfLatencyStatus -ValueMs $avgMs -WarnMs $warnMs -FailMs $failMs
                    $recommendation = if ($status -ne 'Pass') { 'Investigate disk load and queueing on this host; confirm with a longer capture or DiskSpd.' } else { $null }
                    New-FslResult -Category $category -Check $latency.Check -Status $status -Target $target `
                        -Value "avg $avgMs ms; max $maxMs ms" -Expected $expectedLatency `
                        -Message "$($latency.Counter) over $sampleNote (counter reported in seconds, converted to ms)." `
                        -Recommendation $recommendation -Source 'Toolkit default' -Scope 'General'
                }
                $iopsParts = foreach ($name in @('Disk Reads/sec', 'Disk Writes/sec', 'Disk Transfers/sec')) {
                    if ($byName.ContainsKey($name)) {
                        '{0} avg {1}, max {2}' -f $name, [System.Math]::Round($byName[$name].Average, 1), [System.Math]::Round($byName[$name].Maximum, 1)
                    }
                }
                if (@($iopsParts).Count -gt 0) {
                    New-FslResult -Category $category -Check 'PhysicalDisk IOPS' -Status 'Info' -Target $target `
                        -Value @($iopsParts) -Message "IOPS over $sampleNote." -Source $diskCounterUrl -Scope 'General'
                }
                if ($byName.ContainsKey('Current Disk Queue Length')) {
                    $queue = $byName['Current Disk Queue Length']
                    New-FslResult -Category $category -Check 'PhysicalDisk queue length' -Status 'Info' -Target $target `
                        -Value ('avg {0}; max {1}' -f [System.Math]::Round($queue.Average, 2), [System.Math]::Round($queue.Maximum, 2)) `
                        -Message "Current Disk Queue Length over $sampleNote." -Source $diskCounterUrl -Scope 'General'
                }
            }
        }

        # SMB Client Shares results
        if ($smbAvailable -and $stats.Count -gt 0) {
            $smbStats = @($stats | Where-Object { $_.CounterName -in $smbCounters -and $_.InstanceName -ne '_total' })
            foreach ($smbTarget in $smbTargets) {
                $smbTargetScope = Get-FslPerfTargetScope -ScopeMap $scopeMap -Path $smbTarget.Path
                $matched = @($smbStats | Where-Object {
                        Test-FslPerfSmbInstanceMatch -InstanceName $_.InstanceName -HostName $smbTarget.HostName -ShareName $smbTarget.ShareName
                    })
                if ($matched.Count -eq 0) {
                    New-FslResult -Category $category -Check 'SMB share latency' -Status 'Info' -Target $smbTarget.Path `
                        -Message "No SMB Client Shares counter instance matched \\$($smbTarget.HostName)\$($smbTarget.ShareName); the share may not be in use by this client." `
                        -Source $smbCounterUrl -Scope $smbTargetScope
                    continue
                }
                foreach ($instance in @($matched | ForEach-Object { $_.InstanceName } | Sort-Object -Unique)) {
                    $byName = @{}
                    foreach ($stat in @($matched | Where-Object { $_.InstanceName -eq $instance })) {
                        $byName[$stat.CounterName] = $stat
                    }
                    $target = "$($smbTarget.Path) [$instance]"
                    foreach ($latency in @(@{ Counter = 'Avg. sec/Read'; Check = 'SMB share read latency' },
                            @{ Counter = 'Avg. sec/Write'; Check = 'SMB share write latency' })) {
                        if (-not $byName.ContainsKey($latency.Counter)) { continue }
                        $stat = $byName[$latency.Counter]
                        $avgMs = [System.Math]::Round($stat.Average * 1000, 2)
                        $maxMs = [System.Math]::Round($stat.Maximum * 1000, 2)
                        $status = Get-FslPerfLatencyStatus -ValueMs $avgMs -WarnMs $warnMs -FailMs $failMs
                        $recommendation = if ($status -ne 'Pass') { 'Investigate file server storage, network latency and SMB configuration (see Test-FslNetworkHealth); confirm with DiskSpd.' } else { $null }
                        New-FslResult -Category $category -Check $latency.Check -Status $status -Target $target `
                            -Value "avg $avgMs ms; max $maxMs ms" -Expected $expectedLatency `
                            -Message "SMB Client Shares $($latency.Counter) over $sampleNote (counter reported in seconds, converted to ms)." `
                            -Recommendation $recommendation -Source 'Toolkit default' -Scope $smbTargetScope
                    }
                    $iopsParts = foreach ($name in @('Read Requests/sec', 'Write Requests/sec', 'Data Requests/sec')) {
                        if ($byName.ContainsKey($name)) {
                            '{0} avg {1}, max {2}' -f $name, [System.Math]::Round($byName[$name].Average, 1), [System.Math]::Round($byName[$name].Maximum, 1)
                        }
                    }
                    if (@($iopsParts).Count -gt 0) {
                        New-FslResult -Category $category -Check 'SMB share IOPS' -Status 'Info' -Target $target `
                            -Value @($iopsParts) -Message "SMB client share IOPS over $sampleNote." -Source $smbCounterUrl -Scope $smbTargetScope
                    }
                }
            }
        }
    }

    # --- Optional write/read test ---------------------------------------------------------------------------
    if ($IncludeWriteTest) {
        if ($fileTargets.Count -eq 0) {
            New-FslResult -Category $category -Check 'Write test' -Status 'Skipped' `
                -Message 'No SMB or local storage location is available for the write test.' -Source 'Toolkit default' -Scope 'General'
        }
        foreach ($fileTarget in $fileTargets) {
            $folder = $fileTarget.Path
            $fileTargetScope = Get-FslPerfTargetScope -ScopeMap $scopeMap -Path $folder
            if ($folder.Contains('%')) {
                New-FslResult -Category $category -Check 'Write test' -Status 'Skipped' -Target $folder `
                    -Message 'The path contains an unexpanded variable (%...%); the write test only runs against a concrete location root.' `
                    -Source 'Toolkit default' -Scope $fileTargetScope
                continue
            }
            try {
                if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                    New-FslResult -Category $category -Check 'Write test' -Status 'Skipped' -Target $folder `
                        -Message 'The location root does not exist or is not reachable.' -Source 'Toolkit default' -Scope $fileTargetScope
                    continue
                }
                Write-FslLog -Message "Running $writeTestSizeMB MB write/read test against '$folder'." -Level Info -Component $category
                $test = Invoke-FslPerfWriteTest -Folder $folder -SizeMB $writeTestSizeMB
                if (-not $test.Writable) {
                    New-FslResult -Category $category -Check 'Write test' -Status 'Skipped' -Target $folder `
                        -Message "The location root is not writable by the current user: $($test.Message)" -Source 'Toolkit default' -Scope $fileTargetScope
                    continue
                }
                $disclaimer = 'Coarse single-threaded sequential test using a temporary file (deleted afterwards); not a substitute for DiskSpd.'
                New-FslResult -Category $category -Check 'Sequential write test' -Status 'Info' -Target $folder `
                    -Value ('{0} MB/s; {1} ms' -f $test.WriteMBps, $test.WriteMs) `
                    -Message "$($test.SizeMB) MB written in $($test.BlockSizeMB) MB blocks with FileOptions.WriteThrough and flushed to disk. $disclaimer" `
                    -Source $diskSpdUrl -Scope $fileTargetScope
                New-FslResult -Category $category -Check 'Sequential read test' -Status 'Info' -Target $folder `
                    -Value ('{0} MB/s; {1} ms' -f $test.ReadMBps, $test.ReadMs) `
                    -Message "$([System.Math]::Round($test.BytesRead / 1MB, 1)) MB read back sequentially; the result may be served from the OS/SMB client cache. $disclaimer" `
                    -Source $diskSpdUrl -Scope $fileTargetScope
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component $category -Context "Write test against '$folder'"
                New-FslResult -Category $category -Check 'Write test' -Status 'Error' -Target $folder `
                    -Message "Write/read test failed: $($_.Exception.Message)" -Source 'Toolkit default' -Scope $fileTargetScope
            }
        }
    }
}
