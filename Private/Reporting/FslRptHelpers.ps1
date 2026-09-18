# Private helpers for Reporting (Export-FslReport / Invoke-FslHealthCheck).
# Phase 2: Result Scope column (General|ODFC|Profiles; missing Scope is treated as General) and Scope x Status summary.
# Sources:
#   https://learn.microsoft.com/dotnet/api/system.net.webutility.htmlencode
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/export-csv

function Get-FslRptResultPropertyName {
    <#
    .SYNOPSIS
        Returns the ordered property names of an FSLogixToolkit.Result (CONTRACT 5.1).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    # CONTRACT 5.1 v2 (P2.3): Scope is appended as the last property.
    @('Timestamp', 'ComputerName', 'Category', 'Check', 'Status', 'Target', 'Value', 'Expected',
        'Message', 'Recommendation', 'Source', 'RequiresElevation', 'Scope')
}

function Get-FslRptScopeName {
    <#
    .SYNOPSIS
        Returns the contract Result scope values (P2.3) in display order.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    @('General', 'ODFC', 'Profiles')
}

function Get-FslRptResultScope {
    <#
    .SYNOPSIS
        Returns the Scope of a Result; 'General' when the property is missing or empty (phase-1 results).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject
    )

    $scope = Get-FslRptPropertyValue -InputObject $InputObject -Name 'Scope'
    if ([string]::IsNullOrWhiteSpace($scope)) { return 'General' }
    return $scope
}

function Get-FslRptCsvPropertySelector {
    <#
    .SYNOPSIS
        Returns the Select-Object property list for CSV export of Results (Scope defaults to General).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $selector = foreach ($name in (Get-FslRptResultPropertyName)) {
        if ($name -eq 'Scope') {
            @{ Name = 'Scope'; Expression = { Get-FslRptResultScope -InputObject $_ } }
        }
        else { $name }
    }
    return , @($selector)
}

function Get-FslRptScopeStatusSummary {
    <#
    .SYNOPSIS
        Counts results by Scope x Status (missing Scope counts as General). One object per Scope.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result
    )

    $statuses = Get-FslRptStatusName
    $knownScopes = Get-FslRptScopeName
    $groups = @($Result | Group-Object -Property { Get-FslRptResultScope -InputObject $_ })
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($scopeName in $knownScopes) {
        if (@($groups | Where-Object -FilterScript { $_.Name -eq $scopeName }).Count -gt 0) { $names.Add($scopeName) }
    }
    foreach ($group in ($groups | Sort-Object -Property Name)) {
        if ($group.Name -notin $knownScopes) { $names.Add($group.Name) }
    }
    foreach ($scopeName in $names) {
        $group = @($groups | Where-Object -FilterScript { $_.Name -eq $scopeName })[0]
        $row = [ordered]@{ Scope = $scopeName }
        foreach ($status in $statuses) {
            $row[$status] = @($group.Group | Where-Object -FilterScript { (Get-FslRptPropertyValue -InputObject $_ -Name 'Status') -eq $status }).Count
        }
        $row['Other'] = @($group.Group | Where-Object -FilterScript { (Get-FslRptPropertyValue -InputObject $_ -Name 'Status') -notin $statuses }).Count
        $row['Total'] = $group.Count
        [pscustomobject]$row
    }
}

function Get-FslRptStatusName {
    <#
    .SYNOPSIS
        Returns the contract Result status values in display order.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    @('Pass', 'Warn', 'Fail', 'Error', 'Info', 'Skipped')
}

function Get-FslRptPropertyValue {
    <#
    .SYNOPSIS
        StrictMode-safe property read that always returns a string ('' when missing or null).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    if ($null -eq $InputObject) { return '' }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    $value = $property.Value
    if ($value -is [string]) { return $value }
    if ($value -is [System.Collections.IEnumerable]) {
        return ((@($value) | ForEach-Object -Process { [string]$_ }) -join '; ')
    }
    return [string]$value
}

function Test-FslRptIsResult {
    <#
    .SYNOPSIS
        Returns $true when the object carries the Category and Status properties of a Result.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) { return $false }
    return ($null -ne $InputObject.PSObject.Properties['Category'] -and $null -ne $InputObject.PSObject.Properties['Status'])
}

function Get-FslRptStatusSummary {
    <#
    .SYNOPSIS
        Counts results by Category x Status. Returns one object per Category plus totals.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result
    )

    $statuses = Get-FslRptStatusName
    $groups = $Result | Group-Object -Property { $c = Get-FslRptPropertyValue -InputObject $_ -Name 'Category'; if ($c) { $c } else { '(none)' } }
    foreach ($group in ($groups | Sort-Object -Property Name)) {
        $row = [ordered]@{ Category = $group.Name }
        foreach ($status in $statuses) {
            $row[$status] = @($group.Group | Where-Object -FilterScript { (Get-FslRptPropertyValue -InputObject $_ -Name 'Status') -eq $status }).Count
        }
        $other = @($group.Group | Where-Object -FilterScript { (Get-FslRptPropertyValue -InputObject $_ -Name 'Status') -notin $statuses }).Count
        $row['Other'] = $other
        $row['Total'] = $group.Count
        [pscustomobject]$row
    }
}

function Resolve-FslRptOutputFolder {
    <#
    .SYNOPSIS
        Resolves (and creates) the report output folder: -Path or the session ReportRoot.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Path
    )

    $folder = $Path
    if ([string]::IsNullOrWhiteSpace($folder)) {
        if (-not $script:FslSession.Initialized) {
            $null = Initialize-FslSession
        }
        $folder = $script:FslSession.ReportRoot
    }
    if ([string]::IsNullOrWhiteSpace($folder)) {
        throw 'No report folder available: pass -Path or run Initialize-FslSession.'
    }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        $null = New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop
    }
    return (Resolve-Path -LiteralPath $folder -ErrorAction Stop).ProviderPath
}

function ConvertTo-FslRptHtmlEncoded {
    <#
    .SYNOPSIS
        HTML-encodes a value with System.Net.WebUtility.HtmlEncode.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function ConvertTo-FslRptHtml {
    <#
    .SYNOPSIS
        Builds a self-contained HTML report (inline CSS, no external resources, every value encoded).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Title,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ComputerName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Generated,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Elevated,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PowerShellVersion
    )

    $statuses = Get-FslRptStatusName
    $sb = [System.Text.StringBuilder]::new()
    $enc = { param($t) ConvertTo-FslRptHtmlEncoded -Text ([string]$t) }

    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('<meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine("<title>$(& $enc $Title)</title>")
    [void]$sb.AppendLine(@'
<style>
body { font-family: "Segoe UI", Arial, Helvetica, sans-serif; margin: 0 16px 24px 16px; color: #1f2328; background: #ffffff; font-size: 14px; }
h1 { font-size: 22px; margin: 16px 0 8px 0; }
h2 { font-size: 18px; margin: 24px 0 8px 0; border-bottom: 1px solid #d0d7de; padding-bottom: 4px; }
table { border-collapse: collapse; width: 100%; margin-bottom: 8px; }
th, td { border: 1px solid #d0d7de; padding: 4px 6px; text-align: left; vertical-align: top; word-break: break-word; }
th { background: #f0f3f6; }
.meta td { border: none; padding: 2px 12px 2px 0; }
.meta { width: auto; }
.num { text-align: right; }
.status-pass { background: #dafbe1; color: #116329; font-weight: 600; }
.status-warn { background: #fff8c5; color: #7d4e00; font-weight: 600; }
.status-fail { background: #ffebe9; color: #a40e26; font-weight: 600; }
.status-error { background: #a40e26; color: #ffffff; font-weight: 600; }
.status-info { background: #ddf4ff; color: #0550ae; font-weight: 600; }
.status-skipped { background: #eaeef2; color: #57606a; font-weight: 600; }
.status-other { background: #ffffff; color: #1f2328; }
.wrap { overflow-x: auto; }
footer { margin-top: 24px; color: #57606a; font-size: 12px; }
</style>
'@)
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')
    [void]$sb.AppendLine("<h1>$(& $enc $Title)</h1>")
    [void]$sb.AppendLine('<table class="meta">')
    [void]$sb.AppendLine("<tr><td>Computer</td><td>$(& $enc $ComputerName)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Generated</td><td>$(& $enc $Generated)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Elevated</td><td>$(& $enc $Elevated)</td></tr>")
    [void]$sb.AppendLine("<tr><td>PowerShell</td><td>$(& $enc $PowerShellVersion)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Results</td><td>$(& $enc $Result.Count)</td></tr>")
    [void]$sb.AppendLine('</table>')

    # Summary: Category x Status
    [void]$sb.AppendLine('<h2>Summary</h2>')
    [void]$sb.AppendLine('<div class="wrap"><table>')
    $header = '<tr><th>Category</th>'
    foreach ($status in $statuses) { $header += "<th class=`"status-$($status.ToLowerInvariant())`">$(& $enc $status)</th>" }
    $header += '<th>Other</th><th>Total</th></tr>'
    [void]$sb.AppendLine($header)
    $summary = @(Get-FslRptStatusSummary -Result $Result)
    foreach ($row in $summary) {
        $line = "<tr><td>$(& $enc $row.Category)</td>"
        foreach ($status in $statuses) { $line += "<td class=`"num`">$(& $enc $row.$status)</td>" }
        $line += "<td class=`"num`">$(& $enc $row.Other)</td><td class=`"num`">$(& $enc $row.Total)</td></tr>"
        [void]$sb.AppendLine($line)
    }
    $totalLine = '<tr><th>Total</th>'
    foreach ($status in $statuses) {
        $sum = ($summary | Measure-Object -Property $status -Sum).Sum
        $totalLine += "<th class=`"num`">$(& $enc ([int]$sum))</th>"
    }
    $otherSum = ($summary | Measure-Object -Property Other -Sum).Sum
    $totalLine += "<th class=`"num`">$(& $enc ([int]$otherSum))</th><th class=`"num`">$(& $enc $Result.Count)</th></tr>"
    [void]$sb.AppendLine($totalLine)
    [void]$sb.AppendLine('</table></div>')

    # Summary: Scope x Status (Results without Scope count as General)
    [void]$sb.AppendLine('<h2>Summary by container scope</h2>')
    [void]$sb.AppendLine('<div class="wrap"><table>')
    $scopeHeader = '<tr><th>Scope</th>'
    foreach ($status in $statuses) { $scopeHeader += "<th class=`"status-$($status.ToLowerInvariant())`">$(& $enc $status)</th>" }
    $scopeHeader += '<th>Other</th><th>Total</th></tr>'
    [void]$sb.AppendLine($scopeHeader)
    foreach ($row in @(Get-FslRptScopeStatusSummary -Result $Result)) {
        $line = "<tr><td>$(& $enc $row.Scope)</td>"
        foreach ($status in $statuses) { $line += "<td class=`"num`">$(& $enc $row.$status)</td>" }
        $line += "<td class=`"num`">$(& $enc $row.Other)</td><td class=`"num`">$(& $enc $row.Total)</td></tr>"
        [void]$sb.AppendLine($line)
    }
    [void]$sb.AppendLine('</table></div>')

    # Detail per category
    $detailColumns = @('Check', 'Status', 'Scope', 'Target', 'Value', 'Expected', 'Message', 'Recommendation', 'Source', 'RequiresElevation', 'Timestamp')
    $groups = $Result | Group-Object -Property { $c = Get-FslRptPropertyValue -InputObject $_ -Name 'Category'; if ($c) { $c } else { '(none)' } }
    foreach ($group in ($groups | Sort-Object -Property Name)) {
        [void]$sb.AppendLine("<h2>$(& $enc $group.Name) ($(& $enc $group.Count))</h2>")
        [void]$sb.AppendLine('<div class="wrap"><table>')
        [void]$sb.AppendLine('<tr>' + (($detailColumns | ForEach-Object -Process { "<th>$(& $enc $_)</th>" }) -join '') + '</tr>')
        foreach ($item in $group.Group) {
            $cells = foreach ($column in $detailColumns) {
                $value = if ($column -eq 'Scope') { Get-FslRptResultScope -InputObject $item } else { Get-FslRptPropertyValue -InputObject $item -Name $column }
                switch ($column) {
                    'Status' {
                        $cssClass = if ($value -in $statuses) { "status-$($value.ToLowerInvariant())" } else { 'status-other' }
                        "<td class=`"$cssClass`">$(& $enc $value)</td>"
                    }
                    'Source' {
                        if ($value -match '^https?://\S+$') {
                            $encoded = & $enc $value
                            "<td><a href=`"$encoded`" rel=`"noopener noreferrer`">$encoded</a></td>"
                        }
                        else { "<td>$(& $enc $value)</td>" }
                    }
                    default { "<td>$(& $enc $value)</td>" }
                }
            }
            [void]$sb.AppendLine('<tr>' + ($cells -join '') + '</tr>')
        }
        [void]$sb.AppendLine('</table></div>')
    }

    [void]$sb.AppendLine('<footer>Generated by FSLogixToolkit. Thresholds marked "Toolkit default" are toolkit defaults, not Microsoft guidance.</footer>')
    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')
    return $sb.ToString()
}

function Resolve-FslRptHealthScope {
    <#
    .SYNOPSIS
        Resolves a container mode (ODFC|Profiles|Both) to container scopes via Resolve-FslPrefContainerScope.
    .DESCRIPTION
        Uses the Core helper Resolve-FslPrefContainerScope (contract P2.4). If that helper is unavailable or
        fails, the contract mapping is applied locally (ODFC -> ODFC; Profiles -> Profiles; Both -> ODFC, Profiles).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $Mode
    )

    $fallback = switch ($Mode) {
        'Profiles' { @('Profiles') }
        'Both' { @('ODFC', 'Profiles') }
        default { @('ODFC') }
    }
    try {
        if ($null -ne (Get-Command -Name 'Resolve-FslPrefContainerScope' -CommandType Function -ErrorAction SilentlyContinue)) {
            $resolved = @(Resolve-FslPrefContainerScope -Mode $Mode | Where-Object -FilterScript { $_ -in @('ODFC', 'Profiles') })
            if ($resolved.Count -gt 0) { return [string[]]$resolved }
        }
        Write-FslLog -Message "Resolve-FslPrefContainerScope unavailable or empty; using contract mapping for mode $Mode." -Level Verbose -Component 'Reporting'
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Reporting' -Context "Resolve container scopes for mode $Mode"
    }
    return [string[]]$fallback
}
