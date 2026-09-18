function Get-FslContainerReport {
    <#
    .SYNOPSIS
        Produces health results for FSLogix containers: stale, oversized, orphaned and locked flags plus totals.

    .DESCRIPTION
        Evaluates container inventory objects (from Get-FslContainer) and returns FSLogixToolkit.Result objects
        in Category 'Containers'.

        Per container (one result per triggered condition, or a single Pass result when none apply):
          - Stale:     DaysSinceLastWrite >= StaleDays                  -> Warn
          - Size:      PercentOfMax >= PercentOfMaxFail                 -> Fail
                       PercentOfMax >= PercentOfMaxWarn                 -> Warn
          - Account:   AccountStatus 'Orphaned' (SID not mappable)      -> Warn
          - Locked:    IsLocked $true (file in use / attached)          -> Info
        Summary: container count, total size (GB), stale, oversized (>= warn threshold), orphaned and
        locked counts.

        StaleDays, PercentOfMaxWarn and PercentOfMaxFail are TOOLKIT DEFAULTS from Config/Settings.psd1
        (section Containers) unless supplied as parameters; they are not Microsoft recommendations.

    .PARAMETER Container
        Container objects (FSLogixToolkit.Container). When omitted, Get-FslContainer is called.

    .PARAMETER StaleDays
        Days since last write at or above which a container is reported stale. Default from settings.

    .PARAMETER PercentOfMaxWarn
        Percent of SizeInMBs at or above which a Warn is reported. Default from settings.

    .PARAMETER PercentOfMaxFail
        Percent of SizeInMBs at or above which a Fail is reported. Default from settings.

    .PARAMETER Scope
        Container scopes to report on: Profiles, ODFC (default both). When supplied, it is passed to
        Get-FslContainer during discovery and supplied -Container objects are filtered to these scopes;
        containers whose scope is Unknown (file name matches neither or both VHDNameMatch patterns) are then
        excluded. When omitted, all containers are reported (including Unknown), as before.
        Per-container results carry the container Scope (Unknown -> General). Summary results carry the scope
        when exactly one scope is requested, otherwise General.

    .EXAMPLE
        Get-FslContainerReport | Where-Object -Property Status -NE -Value 'Pass'

    .EXAMPLE
        Get-FslContainerReport -Scope ODFC

    .EXAMPLE
        Get-FslContainer -Path '\\fileserver\profiles' | Get-FslContainerReport -StaleDays 60

    .NOTES
        RequiresElevation: No (read access to the container locations is required).
        Sources:
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
          https://learn.microsoft.com/en-us/dotnet/api/system.security.principal.securityidentifier.translate
          https://learn.microsoft.com/en-us/dotnet/standard/io/handling-io-errors
          Thresholds: Toolkit default (Config/Settings.psd1)
    #>
    [CmdletBinding()]
    [OutputType('FSLogixToolkit.Result')]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowEmptyCollection()]
        [object[]] $Container,

        [Parameter()]
        [ValidateRange(1, 36500)]
        [int] $StaleDays,

        [Parameter()]
        [ValidateRange(1, 1000)]
        [int] $PercentOfMaxWarn,

        [Parameter()]
        [ValidateRange(1, 1000)]
        [int] $PercentOfMaxFail,

        [Parameter()]
        [ValidateSet('Profiles', 'ODFC')]
        [string[]] $Scope = @('Profiles', 'ODFC')
    )

    begin {
        $category = 'Containers'
        $toolkitSource = 'Toolkit default'
        $translateSource = 'https://learn.microsoft.com/en-us/dotnet/api/system.security.principal.securityidentifier.translate'
        $ioSource = 'https://learn.microsoft.com/en-us/dotnet/standard/io/handling-io-errors'

        $config = $null
        try {
            $config = Get-FslConfig -Section 'Containers'
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Containers' -Context 'Reading Containers settings'
        }

        # Fallbacks mirror Config/Settings.psd1 (toolkit defaults) when the config cannot be read.
        $thresholds = @{ StaleDays = 90; PercentOfMaxWarn = 80; PercentOfMaxFail = 95 }
        foreach ($key in @('StaleDays', 'PercentOfMaxWarn', 'PercentOfMaxFail')) {
            if ($PSBoundParameters.ContainsKey($key)) {
                $thresholds[$key] = [int]$PSBoundParameters[$key]
            }
            elseif ($config -is [System.Collections.IDictionary] -and $config.Contains($key) -and $null -ne $config[$key]) {
                $thresholds[$key] = [int]$config[$key]
            }
        }
        if ($thresholds['PercentOfMaxWarn'] -gt $thresholds['PercentOfMaxFail']) {
            Write-FslLog -Message "PercentOfMaxWarn ($($thresholds['PercentOfMaxWarn'])) is greater than PercentOfMaxFail ($($thresholds['PercentOfMaxFail'])); Fail is evaluated first." -Level Warning -Component 'Containers'
        }

        $scopeBound = $PSBoundParameters.ContainsKey('Scope')
        $requestedScopes = @($Scope | Select-Object -Unique)
        # Summary rows: the single requested scope, otherwise General (P2.4).
        $summaryScope = if ($scopeBound -and $requestedScopes.Count -eq 1) { [string]$requestedScopes[0] } else { 'General' }

        $items = [System.Collections.Generic.List[object]]::new()
        $containerSupplied = $PSBoundParameters.ContainsKey('Container') -or $MyInvocation.ExpectingInput
    }

    process {
        foreach ($item in @($Container)) {
            if ($null -eq $item) { continue }
            if ($scopeBound) {
                $itemScopeProperty = $item.PSObject.Properties['Scope']
                $itemScope = if ($null -ne $itemScopeProperty) { [string]$itemScopeProperty.Value } else { '' }
                if ($itemScope -notin $requestedScopes) { continue }
            }
            $items.Add($item)
        }
    }

    end {
        if (-not $containerSupplied -and $items.Count -eq 0) {
            if (-not (Test-FslIsWindows)) {
                # Default locations come from FSLogix registry settings (Get-FslStorageLocation), which exist only on Windows.
                New-FslResult -Category $category -Check 'Container inventory' -Status 'Skipped' -Target 'Container locations' `
                    -Message 'FSLogix storage locations can only be read on Windows. Supply -Container (Get-FslContainer -Path <folder>) to report on specific locations.' `
                    -Source $toolkitSource -RequiresElevation $false -Scope $summaryScope
                return
            }
            try {
                $discovered = if ($scopeBound) { @(Get-FslContainer -Scope $requestedScopes -ErrorAction Stop) } else { @(Get-FslContainer -ErrorAction Stop) }
                foreach ($item in $discovered) {
                    if ($null -ne $item) { $items.Add($item) }
                }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Containers' -Context 'Get-FslContainer'
                New-FslResult -Category $category -Check 'Container inventory' -Status 'Error' -Target 'Container locations' `
                    -Message "Container inventory failed: $($_.Exception.Message)" `
                    -Recommendation 'Check the storage locations and read permissions, then review the toolkit error log.' `
                    -Source $toolkitSource -RequiresElevation $false -Scope $summaryScope
                return
            }
        }

        $staleCount = 0
        $oversizedCount = 0
        $orphanedCount = 0
        $lockedCount = 0
        [long]$totalBytes = 0

        foreach ($item in $items) {
            $itemResultScope = 'General'
            try {
                $itemResultScope = ConvertTo-FslCtrResultScope -Scope ([string]$item.Scope)
                $target = [string]$item.FullName
                $flagged = $false
                $totalBytes += [long]$item.SizeBytes

                $days = $item.DaysSinceLastWrite
                if ($null -ne $days -and [int]$days -ge $thresholds['StaleDays']) {
                    $staleCount++
                    $flagged = $true
                    New-FslResult -Category $category -Check 'Container stale' -Status 'Warn' -Target $target `
                        -Value "$([int]$days) days since last write" -Expected "< $($thresholds['StaleDays']) days" `
                        -Message "Container for '$($item.UserName)' ($($item.Scope)) has not been written for $([int]$days) days (last write $($item.LastWriteTime))." `
                        -Recommendation 'Confirm whether the user still needs this container; archive or remove it (Remove-FslStaleContainer) if not.' `
                        -Source $toolkitSource -RequiresElevation $false -Scope $itemResultScope
                }

                $percent = $item.PercentOfMax
                if ($null -ne $percent) {
                    $percentValue = [double]$percent
                    $sizeStatus = $null
                    if ($percentValue -ge $thresholds['PercentOfMaxFail']) { $sizeStatus = 'Fail' }
                    elseif ($percentValue -ge $thresholds['PercentOfMaxWarn']) { $sizeStatus = 'Warn' }
                    if ($sizeStatus) {
                        $oversizedCount++
                        $flagged = $true
                        New-FslResult -Category $category -Check 'Container size' -Status $sizeStatus -Target $target `
                            -Value "$percentValue% of $($item.MaxSizeMB) MB ($($item.SizeGB) GB)" `
                            -Expected "< $($thresholds['PercentOfMaxWarn'])% (warn), < $($thresholds['PercentOfMaxFail'])% (fail)" `
                            -Message "Container for '$($item.UserName)' ($($item.Scope)) is at $percentValue% of the configured SizeInMBs ($($item.MaxSizeMB) MB). Users receive errors if the container grows beyond SizeInMBs." `
                            -Recommendation 'Review the container content, compact it (Invoke-FslContainerShrink), or increase SizeInMBs (it can be increased but not decreased).' `
                            -Source $toolkitSource -RequiresElevation $false -Scope $itemResultScope
                    }
                }

                if ([string]$item.AccountStatus -eq 'Orphaned') {
                    $orphanedCount++
                    $flagged = $true
                    New-FslResult -Category $category -Check 'Container account' -Status 'Warn' -Target $target `
                        -Value "SID $($item.SID) not mapped" -Expected 'Resolved' `
                        -Message "The SID $($item.SID) in the container folder name could not be translated to an account (IdentityNotMappedException); the account may have been deleted." `
                        -Recommendation 'Verify the account no longer exists in the directory before archiving or removing the container.' `
                        -Source $translateSource -RequiresElevation $false -Scope $itemResultScope
                }

                if ($item.IsLocked -eq $true) {
                    $lockedCount++
                    $flagged = $true
                    New-FslResult -Category $category -Check 'Container locked' -Status 'Info' -Target $target `
                        -Value 'In use' -Expected '' `
                        -Message "Container for '$($item.UserName)' ($($item.Scope)) is open by another process (sharing violation), typically because it is attached in a user session." `
                        -Recommendation 'No action required; maintenance operations skip containers that are in use.' `
                        -Source $ioSource -RequiresElevation $false -Scope $itemResultScope
                }

                if (-not $flagged) {
                    $lockText = if ($null -eq $item.IsLocked) { 'unknown' } elseif ($item.IsLocked) { 'yes' } else { 'no' }
                    New-FslResult -Category $category -Check 'Container health' -Status 'Pass' -Target $target `
                        -Value "$($item.SizeGB) GB; $($item.DaysSinceLastWrite) days since write; account $($item.AccountStatus); locked $lockText" `
                        -Expected "Written within $($thresholds['StaleDays']) days; < $($thresholds['PercentOfMaxWarn'])% of SizeInMBs; account not orphaned" `
                        -Message "Container for '$($item.UserName)' ($($item.Scope)) has no flagged conditions." `
                        -Recommendation '' -Source $toolkitSource -RequiresElevation $false -Scope $itemResultScope
                }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Containers' -Context 'Evaluating container'
                New-FslResult -Category $category -Check 'Container evaluation' -Status 'Error' -Target ([string]$item) `
                    -Message "Failed to evaluate container: $($_.Exception.Message)" -Recommendation 'Review the toolkit error log.' `
                    -Source $toolkitSource -RequiresElevation $false -Scope $itemResultScope
            }
        }

        $count = $items.Count
        $totalGB = [math]::Round($totalBytes / 1GB, 2)

        New-FslResult -Category $category -Check 'Container count' -Status 'Info' -Target 'All containers' `
            -Value ([string]$count) -Expected '' `
            -Message $(if ($count -eq 0) { 'No containers found in the enumerated locations.' } else { "$count container file(s) found." }) `
            -Recommendation '' -Source $toolkitSource -RequiresElevation $false -Scope $summaryScope

        New-FslResult -Category $category -Check 'Container total size' -Status 'Info' -Target 'All containers' `
            -Value "$totalGB GB" -Expected '' -Message "Total size of $count container file(s): $totalGB GB." `
            -Recommendation '' -Source $toolkitSource -RequiresElevation $false -Scope $summaryScope

        New-FslResult -Category $category -Check 'Stale container count' -Status $(if ($staleCount -gt 0) { 'Warn' } else { 'Pass' }) `
            -Target 'All containers' -Value ([string]$staleCount) -Expected '0' `
            -Message "$staleCount container(s) not written for $($thresholds['StaleDays']) days or more." `
            -Recommendation $(if ($staleCount -gt 0) { 'Review stale containers for archiving or removal.' } else { '' }) `
            -Source $toolkitSource -RequiresElevation $false -Scope $summaryScope

        New-FslResult -Category $category -Check 'Oversized container count' -Status $(if ($oversizedCount -gt 0) { 'Warn' } else { 'Pass' }) `
            -Target 'All containers' -Value ([string]$oversizedCount) -Expected '0' `
            -Message "$oversizedCount container(s) at or above $($thresholds['PercentOfMaxWarn'])% of SizeInMBs." `
            -Recommendation $(if ($oversizedCount -gt 0) { 'Review oversized containers (compact or increase SizeInMBs).' } else { '' }) `
            -Source $toolkitSource -RequiresElevation $false -Scope $summaryScope

        New-FslResult -Category $category -Check 'Orphaned container count' -Status $(if ($orphanedCount -gt 0) { 'Warn' } else { 'Pass' }) `
            -Target 'All containers' -Value ([string]$orphanedCount) -Expected '0' `
            -Message "$orphanedCount container(s) whose folder SID could not be mapped to an account." `
            -Recommendation $(if ($orphanedCount -gt 0) { 'Confirm the accounts were deleted before archiving or removing these containers.' } else { '' }) `
            -Source $translateSource -RequiresElevation $false -Scope $summaryScope

        New-FslResult -Category $category -Check 'Locked container count' -Status 'Info' `
            -Target 'All containers' -Value ([string]$lockedCount) -Expected '' `
            -Message "$lockedCount container(s) currently in use." `
            -Recommendation '' -Source $ioSource -RequiresElevation $false -Scope $summaryScope
    }
}
