# FSLogixToolkit - Network private helpers (Agent 7).
# .NET APIs verified via local PowerShell 7.5.2 reflection (.NET 9) and:
#   https://learn.microsoft.com/dotnet/api/system.net.dns.gethostaddressesasync
#   https://learn.microsoft.com/dotnet/api/system.net.sockets.tcpclient.connectasync
#   https://learn.microsoft.com/dotnet/api/system.net.networkinformation.ping.sendpingasync
#   https://learn.microsoft.com/dotnet/api/system.uri.checkhostname

function ConvertTo-FslNetSafeText {
    <# Returns '[redacted]' for text that may contain secrets (connection strings, keys, SAS tokens). #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text -match '(?i)(accountkey|sharedaccesssignature|connectionstring|sig=|sv=|se=|key=|password|secret|token)') {
        return '[redacted]'
    }
    return $Text
}

function Get-FslNetTarget {
    <#
    Builds a de-duplicated list of network targets (HostName, Port, ProviderType, Origin, IsTarget, Scopes).
    From StorageLocation objects (contract 5.3) or from raw -Path strings.
    Scopes (string[]) collects the StorageLocation.Scope values (Profiles/ODFC) of every location that maps to the
    same host|port target; it is empty for -Path input.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Path,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $StorageLocation,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int] $SmbPort,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int] $HttpsPort
    )

    $targets = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()

    if ($Path) {
        foreach ($p in $Path) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $trimmed = $p.Trim().Trim('"')
            $hostName = $null
            $provider = 'Unknown'
            if ($trimmed -match '^(\\\\|//)(?<host>[^\\/]+)') {
                $hostName = $Matches['host']
                $provider = 'SMB'
            }
            elseif ($trimmed -match '^(?i)https?://') {
                try {
                    $uri = [System.Uri]::new($trimmed)
                    $hostName = $uri.Host
                    $provider = 'AzurePageBlob'
                }
                catch {
                    $hostName = $null
                }
            }
            elseif ($trimmed -match '^[A-Za-z]:[\\/]' -or $trimmed.StartsWith('/')) {
                $provider = 'Local'
            }

            if ($hostName) {
                $targets.Add([pscustomobject]@{ HostName = $hostName; ProviderType = $provider; Origin = (ConvertTo-FslNetSafeText -Text $trimmed); Scope = $null })
            }
            else {
                $skipped.Add([pscustomobject]@{ ProviderType = $provider; Origin = (ConvertTo-FslNetSafeText -Text $trimmed); Scope = $null })
            }
        }
    }

    if ($StorageLocation) {
        foreach ($location in $StorageLocation) {
            if ($null -eq $location) { continue }
            $provider = [string]$location.ProviderType
            $hostName = [string]$location.HostName
            $origin = ConvertTo-FslNetSafeText -Text ([string]$location.Path)
            $locationScope = if ($location.PSObject.Properties['Scope']) { [string]$location.Scope } else { $null }
            if ([string]::IsNullOrWhiteSpace($hostName) -and $provider -eq 'SMB' -and ([string]$location.Path) -match '^(\\\\|//)(?<host>[^\\/]+)') {
                $hostName = $Matches['host']
            }
            if (($provider -in @('SMB', 'AzurePageBlob')) -and -not [string]::IsNullOrWhiteSpace($hostName)) {
                $targets.Add([pscustomobject]@{ HostName = $hostName.Trim(); ProviderType = $provider; Origin = $origin; Scope = $locationScope })
            }
            else {
                $skipped.Add([pscustomobject]@{ ProviderType = $provider; Origin = $origin; Scope = $locationScope })
            }
        }
    }

    $scopesByKey = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $uniqueList = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $targets) {
        $port = if ($t.ProviderType -eq 'AzurePageBlob') { $HttpsPort } else { $SmbPort }
        $key = '{0}|{1}' -f $t.HostName, $port
        if (-not $scopesByKey.ContainsKey($key)) {
            $scopesByKey[$key] = [System.Collections.Generic.List[string]]::new()
            $uniqueList.Add([pscustomobject]@{
                    HostName     = $t.HostName
                    Port         = $port
                    ProviderType = $t.ProviderType
                    Origin       = $t.Origin
                    IsTarget     = $true
                    Key          = $key
                })
        }
        if (-not [string]::IsNullOrEmpty($t.Scope) -and -not $scopesByKey[$key].Contains($t.Scope)) { $scopesByKey[$key].Add($t.Scope) }
    }
    $unique = foreach ($u in $uniqueList) {
        [pscustomobject]@{
            HostName     = $u.HostName
            Port         = $u.Port
            ProviderType = $u.ProviderType
            Origin       = $u.Origin
            IsTarget     = $true
            Scopes       = [string[]]@($scopesByKey[$u.Key])
        }
    }
    $skippedOut = foreach ($s in $skipped) {
        [pscustomobject]@{
            HostName     = $null
            Port         = $null
            ProviderType = $s.ProviderType
            Origin       = $s.Origin
            IsTarget     = $false
            Scopes       = [string[]]@($s.Scope | Where-Object -FilterScript { -not [string]::IsNullOrEmpty($_) })
        }
    }
    @($unique) + @($skippedOut)
}

function Resolve-FslNetHost {
    <# DNS resolution with timeout. Returns HostName, Success, IsIpLiteral, Addresses (IPAddress[]), ElapsedMs, ErrorMessage. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $HostName,

        [Parameter(Mandatory)]
        [ValidateRange(100, 600000)]
        [int] $TimeoutMs
    )

    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($HostName, [ref]$parsed)) {
        return [pscustomobject]@{ HostName = $HostName; Success = $true; IsIpLiteral = $true; Addresses = @($parsed); ElapsedMs = 0; ErrorMessage = $null }
    }

    $cts = [System.Threading.CancellationTokenSource]::new($TimeoutMs)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $task = [System.Net.Dns]::GetHostAddressesAsync($HostName, $cts.Token)
        $completed = $task.Wait($TimeoutMs)
        $stopwatch.Stop()
        if (-not $completed) {
            return [pscustomobject]@{ HostName = $HostName; Success = $false; IsIpLiteral = $false; Addresses = @(); ElapsedMs = $stopwatch.ElapsedMilliseconds; ErrorMessage = "DNS resolution timed out after $TimeoutMs ms." }
        }
        $addresses = @($task.Result)
        return [pscustomobject]@{ HostName = $HostName; Success = ($addresses.Count -gt 0); IsIpLiteral = $false; Addresses = $addresses; ElapsedMs = $stopwatch.ElapsedMilliseconds; ErrorMessage = $(if ($addresses.Count -eq 0) { 'No addresses returned.' } else { $null }) }
    }
    catch {
        $stopwatch.Stop()
        $inner = $_.Exception
        while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
        return [pscustomobject]@{ HostName = $HostName; Success = $false; IsIpLiteral = $false; Addresses = @(); ElapsedMs = $stopwatch.ElapsedMilliseconds; ErrorMessage = $inner.Message }
    }
    finally {
        $cts.Dispose()
    }
}

function Measure-FslNetTcpConnect {
    <# Repeated TCP connect to an IP address/port. Returns Attempts, Successes, MinMs, AvgMs, MaxMs, LastError. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Net.IPAddress] $Address,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int] $Port,

        [Parameter(Mandatory)]
        [ValidateRange(100, 600000)]
        [int] $TimeoutMs,

        [Parameter()]
        [ValidateRange(1, 20)]
        [int] $Count = 4
    )

    $times = [System.Collections.Generic.List[double]]::new()
    $lastError = $null
    for ($i = 0; $i -lt $Count; $i++) {
        $client = [System.Net.Sockets.TcpClient]::new($Address.AddressFamily)
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $task = $client.ConnectAsync($Address, $Port)
            $completed = $task.Wait($TimeoutMs)
            $stopwatch.Stop()
            if ($completed -and $client.Connected) {
                $times.Add($stopwatch.Elapsed.TotalMilliseconds)
            }
            elseif (-not $completed) {
                $lastError = "TCP connect timed out after $TimeoutMs ms."
            }
            else {
                $lastError = 'TCP connect did not complete.'
            }
        }
        catch {
            $stopwatch.Stop()
            $inner = $_.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $lastError = $inner.Message
        }
        finally {
            $client.Dispose()
        }
    }

    $stats = if ($times.Count -gt 0) { $times | Measure-Object -Minimum -Maximum -Average } else { $null }
    [pscustomobject]@{
        Attempts  = $Count
        Successes = $times.Count
        MinMs     = $(if ($stats) { [math]::Round($stats.Minimum, 1) } else { $null })
        AvgMs     = $(if ($stats) { [math]::Round($stats.Average, 1) } else { $null })
        MaxMs     = $(if ($stats) { [math]::Round($stats.Maximum, 1) } else { $null })
        LastError = $lastError
    }
}

function Test-FslNetIcmp {
    <# Single ICMP echo with timeout. Returns Success, Status, RoundtripMs, ErrorMessage. Never throws. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Net.IPAddress] $Address,

        [Parameter(Mandatory)]
        [ValidateRange(100, 600000)]
        [int] $TimeoutMs
    )

    $ping = [System.Net.NetworkInformation.Ping]::new()
    try {
        $task = $ping.SendPingAsync($Address, $TimeoutMs)
        if (-not $task.Wait($TimeoutMs + 1000)) {
            return [pscustomobject]@{ Success = $false; Status = 'TimedOut'; RoundtripMs = $null; ErrorMessage = "No reply within $TimeoutMs ms." }
        }
        $reply = $task.Result
        $ok = $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success
        return [pscustomobject]@{ Success = $ok; Status = [string]$reply.Status; RoundtripMs = $(if ($ok) { $reply.RoundtripTime } else { $null }); ErrorMessage = $null }
    }
    catch {
        $inner = $_.Exception
        while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
        return [pscustomobject]@{ Success = $false; Status = 'Error'; RoundtripMs = $null; ErrorMessage = $inner.Message }
    }
    finally {
        $ping.Dispose()
    }
}

function Get-FslNetResultScope {
    <#
    Returns the Result scope (contract P2.2/P2.4) for a set of storage location scopes: the single container scope
    (Profiles or ODFC) when all locations share it, otherwise General (mixed, empty or -Path input).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Scope
    )

    $distinct = @($Scope | Where-Object -FilterScript { -not [string]::IsNullOrEmpty($_) } | Sort-Object -Unique)
    if ($distinct.Count -eq 1 -and $distinct[0] -in @('Profiles', 'ODFC')) { return [string]$distinct[0] }
    return 'General'
}
