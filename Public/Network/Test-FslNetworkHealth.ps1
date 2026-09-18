function Test-FslNetworkHealth {
    <#
    .SYNOPSIS
        Tests network health from this host to the FSLogix storage locations.

    .DESCRIPTION
        For every unique storage host (from Get-FslStorageLocation, or from -Path) the function reports:
        - DNS resolution (System.Net.Dns.GetHostAddressesAsync with a timeout): Pass with addresses, or Fail.
        - TCP reachability and connect latency (System.Net.Sockets.TcpClient.ConnectAsync, 4 attempts):
          port 445 for SMB hosts, port 443 (HTTPS) for Azure page blob (Cloud Cache) hosts.
          Min/avg/max ms are compared with Settings.psd1 Network.TcpLatencyMsWarn / TcpLatencyMsFail
          (toolkit defaults, not Microsoft guidance). TCP connect time is a round-trip indicator only.
        - ICMP echo (informational only; ICMP is often blocked, so it never produces Warn/Fail).
        - On Windows, for SMB hosts: the SMB connection Dialect, Signed and Encrypted properties from
          Get-SmbConnection for connections already established to that host (reported as Info).
        - On Windows, when SMB hosts are tested: SMB client network interfaces (RSS/RDMA capability,
          link speed) from Get-SmbClientNetworkInterface (Info).
        Check functions never throw: failures are returned as Result objects with Status 'Error'.

        Result Scope: TCP connect and skipped-target results carry the scope of the storage locations for that
        host and port; DNS and SMB connection results carry the scope of all locations for that host. When the
        locations belong to both Profiles and ODFC (or targets come from -Path) the scope is General. ICMP echo
        and SMB client interface results are always General. With -Scope ODFC only ODFC storage hosts are
        resolved and connected to.

    .PARAMETER Path
        One or more storage paths to test instead of the configured storage locations. UNC paths
        (\\server\share) are tested as SMB on port 445; http/https URIs are tested on port 443.
        Local paths are reported as Skipped. Hosts are de-duplicated.

    .PARAMETER TimeoutMs
        Timeout in milliseconds for each DNS lookup, TCP connect attempt and ICMP echo.
        Defaults to Settings.psd1 Network.TimeoutMs (toolkit default 3000).

    .PARAMETER Scope
        Container scopes whose storage locations are tested: Profiles, ODFC or both (default, phase 1 behavior).
        Passed to Get-FslStorageLocation -Scope. Not used for target selection when -Path is supplied.

    .EXAMPLE
        Test-FslNetworkHealth

        Tests all VHDLocations/CCDLocations hosts configured for Profile and ODFC containers.

    .EXAMPLE
        Test-FslNetworkHealth -Path '\\fs01.contoso.com\profiles' -TimeoutMs 2000

        Tests DNS, TCP 445 latency, ICMP and SMB connection details for fs01.contoso.com.

    .EXAMPLE
        Test-FslNetworkHealth -Scope ODFC

        Tests only the storage hosts of the Office container (ODFC) VHDLocations/CCDLocations.

    .OUTPUTS
        FSLogixToolkit.Result

    .NOTES
        RequiresElevation: No. SMB connection details only list connections visible to Get-SmbConnection
        in the current session; if none are found, an Info result is returned.
        Thresholds TcpLatencyMsWarn/TcpLatencyMsFail are toolkit defaults (Config/Settings.psd1).
        FSLogix uses the built-in Windows SMB client and is not bound to an SMB protocol version, so the
        dialect is reported as Info.
        Sources:
        https://learn.microsoft.com/dotnet/api/system.net.dns.gethostaddressesasync
        https://learn.microsoft.com/dotnet/api/system.net.sockets.tcpclient.connectasync
        https://learn.microsoft.com/dotnet/api/system.net.networkinformation.ping.sendpingasync
        https://learn.microsoft.com/powershell/module/smbshare/get-smbconnection
        https://learn.microsoft.com/previous-versions/windows/desktop/smb/msft-smbconnection
        https://learn.microsoft.com/powershell/module/smbshare/get-smbclientnetworkinterface
        https://learn.microsoft.com/previous-versions/windows/desktop/smb/msft-smbclientnetworkinterface
        https://learn.microsoft.com/fslogix/concepts-container-storage-options
        https://learn.microsoft.com/azure/storage/files/files-smb-protocol
        https://learn.microsoft.com/en-us/azure/storage/files/storage-how-to-use-files-windows
          ("The SMB protocol requires TCP port 445 to be open. Connections fail if port 445 is blocked.")
    #>
    [CmdletBinding()]
    [OutputType('FSLogixToolkit.Result')]
    param(
        [Parameter(ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path,

        [Parameter()]
        [ValidateRange(100, 60000)]
        [int] $TimeoutMs,

        [Parameter()]
        [ValidateSet('Profiles', 'ODFC')]
        [string[]] $Scope = @('Profiles', 'ODFC')
    )

    begin {
        $component = 'Network'
        $category = 'Network'
        $collectedPaths = [System.Collections.Generic.List[string]]::new()
        $srcDns = 'https://learn.microsoft.com/dotnet/api/system.net.dns.gethostaddressesasync'
        $srcTcp = 'https://learn.microsoft.com/dotnet/api/system.net.sockets.tcpclient.connectasync'
        $srcPing = 'https://learn.microsoft.com/dotnet/api/system.net.networkinformation.ping.sendpingasync'
        $srcSmbConnection = 'https://learn.microsoft.com/previous-versions/windows/desktop/smb/msft-smbconnection'
        $srcSmbInterface = 'https://learn.microsoft.com/powershell/module/smbshare/get-smbclientnetworkinterface'
        $srcFslSmb = 'https://learn.microsoft.com/fslogix/concepts-container-storage-options'
        # Verified: "The SMB protocol requires TCP port 445 to be open. Connections fail if port 445 is blocked."
        $srcSmbPort445 = 'https://learn.microsoft.com/en-us/azure/storage/files/storage-how-to-use-files-windows'
        $selectedScopes = @($Scope | Select-Object -Unique)
    }

    process {
        if ($Path) {
            foreach ($p in $Path) { $collectedPaths.Add($p) }
        }
    }

    end {
        # Settings (toolkit defaults)
        $smbPort = 445
        $httpsPort = 443
        $latencyWarn = 30
        $latencyFail = 100
        $configTimeout = 3000
        try {
            $networkConfig = Get-FslConfig -Section 'Network'
            if ($networkConfig) {
                if ($networkConfig.ContainsKey('SmbPort')) { $smbPort = [int]$networkConfig.SmbPort }
                if ($networkConfig.ContainsKey('HttpsPort')) { $httpsPort = [int]$networkConfig.HttpsPort }
                if ($networkConfig.ContainsKey('TcpLatencyMsWarn')) { $latencyWarn = [int]$networkConfig.TcpLatencyMsWarn }
                if ($networkConfig.ContainsKey('TcpLatencyMsFail')) { $latencyFail = [int]$networkConfig.TcpLatencyMsFail }
                if ($networkConfig.ContainsKey('TimeoutMs')) { $configTimeout = [int]$networkConfig.TimeoutMs }
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $component -Context 'Reading Network settings; using built-in toolkit defaults'
        }
        if (-not $PSBoundParameters.ContainsKey('TimeoutMs')) { $TimeoutMs = $configTimeout }
        $probeCount = 4   # toolkit default number of TCP connect attempts

        # Targets
        $locations = $null
        if ($collectedPaths.Count -eq 0) {
            try {
                $locations = @(Get-FslStorageLocation -Scope $selectedScopes | Where-Object -FilterScript { $_.Scope -in $selectedScopes })
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component $component -Context 'Get-FslStorageLocation'
                New-FslResult -Category $category -Check 'Storage locations' -Status 'Error' -Target 'Get-FslStorageLocation' `
                    -Message "Could not read storage locations: $($_.Exception.Message)" -Source 'Toolkit default' -Scope 'General'
                return
            }
            if ($locations.Count -eq 0) {
                $noLocationMessage = if ($PSBoundParameters.ContainsKey('Scope')) {
                    "No FSLogix storage locations are configured on this computer for scope(s) $($selectedScopes -join ', '); nothing to test. Use -Path to test specific shares."
                }
                else {
                    'No FSLogix storage locations are configured on this computer; nothing to test. Use -Path to test specific shares.'
                }
                New-FslResult -Category $category -Check 'Storage locations' -Status 'Info' -Target 'VHDLocations/CCDLocations' `
                    -Message $noLocationMessage -Source 'Toolkit default' -Scope (Get-FslNetResultScope -Scope $selectedScopes)
                return
            }
        }

        try {
            $allTargets = @(Get-FslNetTarget -Path $collectedPaths.ToArray() -StorageLocation $locations -SmbPort $smbPort -HttpsPort $httpsPort)
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $component -Context 'Building network target list'
            New-FslResult -Category $category -Check 'Network targets' -Status 'Error' -Message "Could not build target list: $($_.Exception.Message)" -Source 'Toolkit default' -Scope 'General'
            return
        }

        foreach ($skip in @($allTargets | Where-Object -FilterScript { -not $_.IsTarget })) {
            New-FslResult -Category $category -Check 'Network target' -Status 'Skipped' -Target $skip.Origin `
                -Value $skip.ProviderType -Message 'Location has no remote host name to test (local path, unparsable path or unknown provider).' `
                -Source 'Toolkit default' -Scope (Get-FslNetResultScope -Scope $skip.Scopes)
        }

        $targets = @($allTargets | Where-Object -FilterScript { $_.IsTarget })
        if ($targets.Count -eq 0) {
            New-FslResult -Category $category -Check 'Network targets' -Status 'Info' -Message 'No remote storage hosts found to test.' -Source 'Toolkit default' -Scope 'General'
            return
        }

        $onWindows = $false
        try { $onWindows = [bool](Test-FslIsWindows) } catch { Add-FslError -ErrorRecord $_ -Component $component -Context 'Test-FslIsWindows' }

        $smbConnections = $null
        $smbConnectionError = $null
        $smbCmdletAvailable = $false
        if ($onWindows -and @($targets | Where-Object -FilterScript { $_.ProviderType -eq 'SMB' }).Count -gt 0) {
            $smbCmdletAvailable = $null -ne (Get-Command -Name 'Get-SmbConnection' -ErrorAction SilentlyContinue)
            if ($smbCmdletAvailable) {
                try {
                    $smbConnections = @(Get-SmbConnection -ErrorAction Stop)
                }
                catch {
                    $smbConnectionError = $_.Exception.Message
                    Add-FslError -ErrorRecord $_ -Component $component -Context 'Get-SmbConnection'
                }
            }
        }

        # Host-level scope = scopes of all locations for that host (any port).
        $hostScopes = @{}
        foreach ($t in $targets) {
            $hostKey = ([string]$t.HostName).ToLowerInvariant()
            if (-not $hostScopes.ContainsKey($hostKey)) { $hostScopes[$hostKey] = [System.Collections.Generic.List[string]]::new() }
            foreach ($s in @($t.Scopes)) { if (-not [string]::IsNullOrEmpty($s)) { $hostScopes[$hostKey].Add($s) } }
        }

        $dnsCache = @{}
        foreach ($target in $targets) {
            $hostName = $target.HostName
            $targetScope = Get-FslNetResultScope -Scope $target.Scopes
            $hostScope = Get-FslNetResultScope -Scope @($hostScopes[$hostName.ToLowerInvariant()])
            $protocolLabel = if ($target.ProviderType -eq 'AzurePageBlob') { 'HTTPS' } else { 'SMB' }
            Write-FslLog -Message "Testing $hostName ($protocolLabel port $($target.Port))" -Level Verbose -Component $component

            # DNS (resolved and reported once per host; a host may be tested on 445 and 443)
            $firstForHost = -not $dnsCache.ContainsKey($hostName)
            if ($firstForHost) {
                try {
                    $dnsCache[$hostName] = Resolve-FslNetHost -HostName $hostName -TimeoutMs $TimeoutMs
                }
                catch {
                    $dnsCache[$hostName] = $null
                    Add-FslError -ErrorRecord $_ -Component $component -Context "DNS resolution for $hostName"
                    New-FslResult -Category $category -Check 'DNS resolution' -Status 'Error' -Target $hostName -Message $_.Exception.Message -Source $srcDns -Scope $hostScope
                }
            }
            $dns = $dnsCache[$hostName]
            if ($null -eq $dns) { continue }

            if (-not $firstForHost) {
                if (-not $dns.Success) {
                    New-FslResult -Category $category -Check "TCP $($target.Port) connect" -Status 'Skipped' -Target $hostName `
                        -Message 'Skipped because DNS resolution failed.' -Source $srcTcp -Scope $targetScope
                    continue
                }
            }
            elseif ($dns.IsIpLiteral) {
                New-FslResult -Category $category -Check 'DNS resolution' -Status 'Info' -Target $hostName -Value $hostName `
                    -Message 'Target is an IP address literal; DNS resolution not required.' `
                    -Source $srcDns -Scope $hostScope
            }
            elseif ($dns.Success) {
                New-FslResult -Category $category -Check 'DNS resolution' -Status 'Pass' -Target $hostName `
                    -Value (@($dns.Addresses | ForEach-Object -Process { $_.ToString() })) `
                    -Expected 'At least one address' -Message "Resolved in $($dns.ElapsedMs) ms." -Source $srcDns -Scope $hostScope
            }
            else {
                New-FslResult -Category $category -Check 'DNS resolution' -Status 'Fail' -Target $hostName -Value '' -Expected 'At least one address' `
                    -Message "DNS resolution failed: $($dns.ErrorMessage)" `
                    -Recommendation 'Verify DNS configuration and that the host name is correct.' `
                    -Source $srcDns -Scope $hostScope
                New-FslResult -Category $category -Check "TCP $($target.Port) connect" -Status 'Skipped' -Target $hostName `
                    -Message 'Skipped because DNS resolution failed.' -Source $srcTcp -Scope $targetScope
                continue
            }

            # Prefer IPv4 when available, otherwise first address.
            $address = @($dns.Addresses | Where-Object -FilterScript { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }) | Select-Object -First 1
            if ($null -eq $address) { $address = @($dns.Addresses)[0] }
            $targetLabel = '{0} ({1}):{2}' -f $hostName, $address, $target.Port

            # TCP connect latency
            $isSmb445 = ($target.ProviderType -eq 'SMB' -and $target.Port -eq 445)
            try {
                $tcp = Measure-FslNetTcpConnect -Address $address -Port $target.Port -TimeoutMs $TimeoutMs -Count $probeCount
                $valueText = if ($tcp.Successes -gt 0) { 'min {0} ms; avg {1} ms; max {2} ms; {3}/{4} succeeded' -f $tcp.MinMs, $tcp.AvgMs, $tcp.MaxMs, $tcp.Successes, $tcp.Attempts } else { "0/$($tcp.Attempts) succeeded" }
                $expectedText = "All attempts succeed; avg < $latencyWarn ms (warn), < $latencyFail ms (fail)"
                if ($tcp.Successes -eq 0) {
                    New-FslResult -Category $category -Check "TCP $($target.Port) connect" -Status 'Fail' -Target $targetLabel -Value $valueText -Expected $expectedText `
                        -Message "Port $($target.Port) is not reachable: $($tcp.LastError)$(if ($isSmb445) { ' The SMB protocol requires TCP port 445 to be open; connections fail if port 445 is blocked (Microsoft Learn, Azure Files).' })" `
                        -Recommendation "Check firewalls, NSGs, private endpoints and routing for outbound TCP $($target.Port) to $hostName." `
                        -Source $(if ($isSmb445) { "Toolkit default; $srcSmbPort445" } else { 'Toolkit default' }) -Scope $targetScope
                }
                else {
                    $status = 'Pass'
                    $message = "TCP connect latency average $($tcp.AvgMs) ms (thresholds are toolkit defaults)."
                    $recommendation = ''
                    if ($tcp.AvgMs -ge $latencyFail) {
                        $status = 'Fail'
                        $recommendation = 'High latency to container storage. FSLogix guidance: proximity (latency) to the virtual desktops is the most important storage selection factor. Place storage close to session hosts.'
                    }
                    elseif ($tcp.AvgMs -ge $latencyWarn) {
                        $status = 'Warn'
                        $recommendation = 'Elevated latency to container storage. FSLogix guidance: proximity (latency) to the virtual desktops is the most important storage selection factor.'
                    }
                    if ($tcp.Successes -lt $tcp.Attempts) {
                        if ($status -eq 'Pass') { $status = 'Warn' }
                        $message = "$message $($tcp.Attempts - $tcp.Successes) of $($tcp.Attempts) attempts failed: $($tcp.LastError)"
                        if (-not $recommendation) { $recommendation = 'Intermittent connection failures: investigate packet loss, firewall or load on the storage endpoint.' }
                    }
                    New-FslResult -Category $category -Check "TCP $($target.Port) connect" -Status $status -Target $targetLabel -Value $valueText -Expected $expectedText `
                        -Message $message -Recommendation $recommendation -Source $(if ($isSmb445) { "Toolkit default; $srcFslSmb; $srcSmbPort445" } else { "Toolkit default; $srcFslSmb" }) -Scope $targetScope
                }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component $component -Context "TCP connect test for $targetLabel"
                New-FslResult -Category $category -Check "TCP $($target.Port) connect" -Status 'Error' -Target $targetLabel -Message $_.Exception.Message -Source $srcTcp -Scope $targetScope
            }

            # ICMP (informational only, once per host)
            if ($firstForHost) {
                try {
                    $icmp = Test-FslNetIcmp -Address $address -TimeoutMs $TimeoutMs
                    $icmpMessage = if ($icmp.Success) { "ICMP echo reply in $($icmp.RoundtripMs) ms." } else { "No ICMP echo reply ($($icmp.Status)$(if ($icmp.ErrorMessage) { ": $($icmp.ErrorMessage)" })). ICMP may be blocked by firewalls or the storage endpoint; this alone does not indicate a problem." }
                    New-FslResult -Category $category -Check 'ICMP echo' -Status 'Info' -Target ('{0} ({1})' -f $hostName, $address) `
                        -Value $(if ($icmp.Success) { "$($icmp.RoundtripMs) ms" } else { [string]$icmp.Status }) -Message $icmpMessage -Source $srcPing -Scope 'General'
                }
                catch {
                    Add-FslError -ErrorRecord $_ -Component $component -Context "ICMP test for $hostName"
                    New-FslResult -Category $category -Check 'ICMP echo' -Status 'Error' -Target $hostName -Message $_.Exception.Message -Source $srcPing -Scope 'General'
                }
            }

            # SMB connection details (Windows only)
            if ($target.ProviderType -ne 'SMB') { continue }
            if (-not $onWindows) {
                New-FslResult -Category $category -Check 'SMB connection' -Status 'Skipped' -Target $hostName `
                    -Message 'SMB connection details (Get-SmbConnection) are only available on Windows.' -Source $srcSmbConnection -Scope $hostScope
                continue
            }
            if (-not $smbCmdletAvailable) {
                New-FslResult -Category $category -Check 'SMB connection' -Status 'Skipped' -Target $hostName `
                    -Message 'Get-SmbConnection (SmbShare module) is not available on this computer.' -Source $srcSmbConnection -Scope $hostScope
                continue
            }
            if ($smbConnectionError) {
                New-FslResult -Category $category -Check 'SMB connection' -Status 'Error' -Target $hostName `
                    -Message "Get-SmbConnection failed: $smbConnectionError" -Source $srcSmbConnection -Scope $hostScope
                continue
            }

            $shortName = if (-not $dns.IsIpLiteral -and $hostName.Contains('.')) { $hostName.Split('.')[0] } else { $null }
            $matching = @($smbConnections | Where-Object -FilterScript {
                    $serverName = [string]$_.ServerName
                    ($serverName -eq $hostName) -or ($shortName -and $serverName -eq $shortName)
                })
            if ($matching.Count -eq 0) {
                New-FslResult -Category $category -Check 'SMB connection' -Status 'Info' -Target $hostName `
                    -Message 'No established SMB connection to this host is visible to Get-SmbConnection in this session. Dialect, signing and encryption can only be read for an existing connection (for example while a user is signed in with a mounted container).' `
                    -Source $srcSmbConnection -Scope $hostScope
                continue
            }

            foreach ($connection in $matching) {
                try {
                    $shareTarget = '\\{0}\{1}' -f $connection.ServerName, $connection.ShareName
                    $dialect = [string]$connection.Dialect
                    New-FslResult -Category $category -Check 'SMB dialect' -Status 'Info' -Target $shareTarget -Value $dialect `
                        -Message "Negotiated SMB dialect $dialect. FSLogix uses the built-in Windows SMB client and is not bound to an SMB protocol version. Azure Files: SMB 2.1 does not support encryption in transit and is only allowed within the same Azure region." `
                        -Source "$srcSmbConnection; $srcFslSmb; https://learn.microsoft.com/azure/storage/files/files-smb-protocol" -Scope $hostScope

                    $properties = $connection.PSObject.Properties
                    $signed = if ($properties['Signed']) { $connection.Signed } else { $null }
                    $encrypted = if ($properties['Encrypted']) { $connection.Encrypted } else { $null }
                    $securityValue = 'Signed={0}; Encrypted={1}' -f $(if ($null -eq $signed) { 'Unknown' } else { $signed }), $(if ($null -eq $encrypted) { 'Unknown' } else { $encrypted })
                    $securityMessage = if ($encrypted -eq $true) {
                        'Connection is encrypted. Per MSFT_SmbConnection documentation, Signed is reported False when Encrypted is True even though an encrypted connection is also signed.'
                    }
                    else {
                        'SMB signing and encryption state as reported by Get-SmbConnection.'
                    }
                    New-FslResult -Category $category -Check 'SMB signing/encryption' -Status 'Info' -Target $shareTarget -Value $securityValue `
                        -Message $securityMessage -Source $srcSmbConnection -Scope $hostScope
                }
                catch {
                    Add-FslError -ErrorRecord $_ -Component $component -Context "Reading SMB connection properties for $hostName"
                    New-FslResult -Category $category -Check 'SMB connection' -Status 'Error' -Target $hostName -Message $_.Exception.Message -Source $srcSmbConnection -Scope $hostScope
                }
            }
        }

        # SMB client network interfaces (Windows only, once)
        if ($onWindows -and @($targets | Where-Object -FilterScript { $_.ProviderType -eq 'SMB' }).Count -gt 0) {
            if ($null -ne (Get-Command -Name 'Get-SmbClientNetworkInterface' -ErrorAction SilentlyContinue)) {
                try {
                    $interfaces = @(Get-SmbClientNetworkInterface -ErrorAction Stop)
                    foreach ($interface in $interfaces) {
                        $linkGbps = if ($null -ne $interface.LinkSpeed) { [math]::Round(([double]$interface.LinkSpeed) / 1e9, 2) } else { $null }
                        New-FslResult -Category $category -Check 'SMB client interface' -Status 'Info' `
                            -Target ('{0} (ifIndex {1})' -f $interface.FriendlyName, $interface.InterfaceIndex) `
                            -Value ('RssCapable={0}; RdmaCapable={1}; LinkSpeedGbps={2}; IpAddresses={3}' -f $interface.RssCapable, $interface.RdmaCapable, $linkGbps, (@($interface.IpAddresses) -join ', ')) `
                            -Message 'Network interface used by the SMB client.' -Source $srcSmbInterface -Scope 'General'
                    }
                }
                catch {
                    Add-FslError -ErrorRecord $_ -Component $component -Context 'Get-SmbClientNetworkInterface'
                    New-FslResult -Category $category -Check 'SMB client interface' -Status 'Error' -Message $_.Exception.Message -Source $srcSmbInterface -Scope 'General'
                }
            }
        }
    }
}
