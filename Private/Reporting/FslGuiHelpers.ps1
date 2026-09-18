# Private helpers for Show-FslDashboard: data model (no WPF types in this file).
# All results live in ONE System.Data.DataTable; every grid binds to its own System.Data.DataView over
# that table with a base RowFilter (for example Category + Scope). Rows of a run replace earlier rows
# with the same Category + Scope.
# Sources:
#   https://learn.microsoft.com/dotnet/api/system.data.dataview (live view; thread safe for reads only)
#   https://learn.microsoft.com/dotnet/api/system.data.dataview.rowfilter
#   https://learn.microsoft.com/dotnet/api/system.data.datacolumn.expression
#     - string literals in single quotes; a single quote inside a value is escaped by doubling it
#     - LIKE: '*' and '%' are wildcards; literal '*', '%', '[' and ']' must be enclosed in brackets
#     - wildcards are allowed only at the start and/or end of a pattern
#     - column names in square brackets: ']' and '\' are escaped with a backslash
#   https://learn.microsoft.com/dotnet/api/system.uri.trycreate

function Get-FslGuiStatusName {
    <#
    .SYNOPSIS
        Returns the Result status values (CONTRACT 5.1) in display order.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    @('Pass', 'Warn', 'Fail', 'Error', 'Info', 'Skipped')
}

function Get-FslGuiResultColumnName {
    <#
    .SYNOPSIS
        Returns the result grid column names in display order (all Result v2 properties).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    @('Status', 'Scope', 'Category', 'Check', 'Target', 'Value', 'Expected', 'Message', 'Recommendation',
        'Source', 'RequiresElevation', 'ComputerName', 'Timestamp')
}

function Get-FslGuiResultExportPropertyName {
    <#
    .SYNOPSIS
        Returns the Result v2 property order (CONTRACT 5.1 + P2.3 Scope appended) used for exports.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    @('Timestamp', 'ComputerName', 'Category', 'Check', 'Status', 'Target', 'Value', 'Expected', 'Message',
        'Recommendation', 'Source', 'RequiresElevation', 'Scope')
}

function Get-FslGuiPropertyText {
    <#
    .SYNOPSIS
        StrictMode-safe property (or dictionary key) read that always returns a string ('' when missing).
    .DESCRIPTION
        Collections are joined with '; '. DateTime values are formatted as 'yyyy-MM-dd HH:mm:ss'.
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
    $value = $null
    if ($InputObject -is [System.Collections.IDictionary]) {
        if (-not $InputObject.Contains($Name)) { return '' }
        $value = $InputObject[$Name]
    }
    else {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -eq $property) { return '' }
        try { $value = $property.Value } catch { return '' }
    }
    if ($null -eq $value) { return '' }
    if ($value -is [string]) { return $value }
    if ($value -is [datetime]) { return $value.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($value -is [System.Collections.IDictionary]) {
        $pairs = foreach ($key in $value.Keys) { '{0}={1}' -f $key, [string]$value[$key] }
        return (@($pairs) -join '; ')
    }
    if ($value -is [System.Collections.IEnumerable]) {
        return ((@($value) | ForEach-Object -Process { [string]$_ }) -join '; ')
    }
    return [string]$value
}

function Initialize-FslGuiResultTable {
    <#
    .SYNOPSIS
        Creates a DataTable with one string column per Result v2 property (display order).
    #>
    [CmdletBinding()]
    [OutputType([System.Data.DataTable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $TableName
    )

    $table = [System.Data.DataTable]::new($TableName)
    foreach ($column in (Get-FslGuiResultColumnName)) {
        [void]$table.Columns.Add($column, [string])
    }
    Write-Output -InputObject $table -NoEnumerate
}

function Initialize-FslGuiSummaryTable {
    <#
    .SYNOPSIS
        Creates the Overview summary DataTable (Scope x Category x Status counts).
    #>
    [CmdletBinding()]
    [OutputType([System.Data.DataTable])]
    param()

    $table = [System.Data.DataTable]::new('Summary')
    [void]$table.Columns.Add('Scope', [string])
    [void]$table.Columns.Add('Category', [string])
    foreach ($status in (Get-FslGuiStatusName)) {
        [void]$table.Columns.Add($status, [int])
    }
    [void]$table.Columns.Add('Other', [int])
    [void]$table.Columns.Add('Total', [int])
    Write-Output -InputObject $table -NoEnumerate
}

function Initialize-FslGuiErrorTable {
    <#
    .SYNOPSIS
        Creates the Errors DataTable (subset of the Add-FslError object plus Origin).
    #>
    [CmdletBinding()]
    [OutputType([System.Data.DataTable])]
    param()

    $table = [System.Data.DataTable]::new('Errors')
    foreach ($column in @('Timestamp', 'Origin', 'Component', 'Context', 'Message', 'ExceptionType', 'CategoryInfo', 'TargetObject')) {
        [void]$table.Columns.Add($column, [string])
    }
    Write-Output -InputObject $table -NoEnumerate
}

function Initialize-FslGuiDailyTable {
    <#
    .SYNOPSIS
        Creates the Daily history DataTable (Get-FslDailyHistory output shape, CONTRACT P2.4).
    #>
    [CmdletBinding()]
    [OutputType([System.Data.DataTable])]
    param()

    $table = [System.Data.DataTable]::new('DailyHistory')
    foreach ($column in @('Date', 'Time', 'ContainerScope')) { [void]$table.Columns.Add($column, [string]) }
    foreach ($column in @('Pass', 'Warn', 'Fail', 'Error', 'Info', 'Skipped', 'NewIssueCount')) { [void]$table.Columns.Add($column, [int]) }
    foreach ($column in @('HtmlReport', 'CsvReport', 'SummaryPath')) { [void]$table.Columns.Add($column, [string]) }
    Write-Output -InputObject $table -NoEnumerate
}

function Get-FslGuiReplacementKey {
    <#
    .SYNOPSIS
        Returns the Category|Scope key used to replace result rows.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Category,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Scope
    )

    $scopeText = if ([string]::IsNullOrWhiteSpace($Scope)) { 'General' } else { $Scope }
    return ('{0}|{1}' -f $Category, $scopeText)
}

function Sync-FslGuiResultRow {
    <#
    .SYNOPSIS
        Replaces result rows by Category + Scope and appends the new results.
    .DESCRIPTION
        Removes every row whose Category|Scope key is in the replacement set, then adds the results.
        The replacement set is the cross product of -Category and -Scope plus the Category|Scope pairs present
        in -Result, so rows of other scopes (for example Profiles rows during an ODFC run) are kept.
        A missing or empty Scope is stored as 'General' (CONTRACT P2.3 default). Returns a hashtable with
        Removed and Added counts. Must be called on the thread that owns the bound grids.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.Data.DataTable] $Table,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Category,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Scope
    )

    $keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($categoryName in $Category) {
        foreach ($scopeName in $Scope) {
            [void]$keys.Add((Get-FslGuiReplacementKey -Category $categoryName -Scope $scopeName))
        }
    }
    $valid = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Result) {
        if ($null -eq $item) { continue }
        $itemCategory = Get-FslGuiPropertyText -InputObject $item -Name 'Category'
        if ([string]::IsNullOrEmpty($itemCategory)) { continue }
        [void]$keys.Add((Get-FslGuiReplacementKey -Category $itemCategory -Scope (Get-FslGuiPropertyText -InputObject $item -Name 'Scope')))
        $valid.Add($item)
    }

    $removed = 0
    $added = 0
    $Table.BeginLoadData()
    try {
        for ($index = $Table.Rows.Count - 1; $index -ge 0; $index--) {
            $row = $Table.Rows[$index]
            $key = Get-FslGuiReplacementKey -Category ([string]$row['Category']) -Scope ([string]$row['Scope'])
            if ($keys.Contains($key)) {
                $Table.Rows.RemoveAt($index)
                $removed++
            }
        }
        foreach ($item in $valid) {
            $row = $Table.NewRow()
            foreach ($column in $Table.Columns) {
                $row[$column.ColumnName] = Get-FslGuiPropertyText -InputObject $item -Name $column.ColumnName
            }
            if ([string]::IsNullOrWhiteSpace([string]$row['Scope'])) { $row['Scope'] = 'General' }
            $Table.Rows.Add($row)
            $added++
        }
    }
    finally {
        $Table.EndLoadData()
    }
    $Table.AcceptChanges()
    return @{ Removed = $removed; Added = $added }
}

function Sync-FslGuiSummaryTable {
    <#
    .SYNOPSIS
        Rebuilds the summary DataTable (Scope x Category x Status counts) from the result DataTable.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [System.Data.DataTable] $Table,

        [Parameter(Mandatory)]
        [System.Data.DataTable] $ResultTable
    )

    $statuses = Get-FslGuiStatusName
    $groups = [ordered]@{}
    foreach ($row in $ResultTable.Rows) {
        $key = '{0}|{1}' -f [string]$row['Scope'], [string]$row['Category']
        if (-not $groups.Contains($key)) {
            $counts = @{ Scope = [string]$row['Scope']; Category = [string]$row['Category']; Other = 0; Total = 0 }
            foreach ($status in $statuses) { $counts[$status] = 0 }
            $groups[$key] = $counts
        }
        $entry = $groups[$key]
        $status = [string]$row['Status']
        if ($status -in $statuses) { $entry[$status] = [int]$entry[$status] + 1 } else { $entry['Other'] = [int]$entry['Other'] + 1 }
        $entry['Total'] = [int]$entry['Total'] + 1
    }

    $Table.BeginLoadData()
    try {
        $Table.Rows.Clear()
        foreach ($key in (@($groups.Keys) | Sort-Object)) {
            $entry = $groups[$key]
            $row = $Table.NewRow()
            foreach ($column in $Table.Columns) { $row[$column.ColumnName] = $entry[$column.ColumnName] }
            $Table.Rows.Add($row)
        }
    }
    finally {
        $Table.EndLoadData()
    }
    $Table.AcceptChanges()
}

function Sync-FslGuiErrorTable {
    <#
    .SYNOPSIS
        Rebuilds the Errors DataTable from error entries grouped by origin.
    .PARAMETER ErrorSet
        Ordered dictionary: origin label -> error objects (Add-FslError shape).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [System.Data.DataTable] $Table,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ErrorSet
    )

    $Table.BeginLoadData()
    try {
        $Table.Rows.Clear()
        foreach ($origin in $ErrorSet.Keys) {
            foreach ($item in @($ErrorSet[$origin])) {
                if ($null -eq $item) { continue }
                $row = $Table.NewRow()
                foreach ($column in $Table.Columns) {
                    if ($column.ColumnName -eq 'Origin') { $row['Origin'] = [string]$origin; continue }
                    $row[$column.ColumnName] = Get-FslGuiPropertyText -InputObject $item -Name $column.ColumnName
                }
                $Table.Rows.Add($row)
            }
        }
    }
    finally {
        $Table.EndLoadData()
    }
    $Table.AcceptChanges()
}

function Sync-FslGuiObjectTable {
    <#
    .SYNOPSIS
        Replaces all rows of a DataTable with the matching properties of the input objects.
    .DESCRIPTION
        Integer columns receive 0 when the property is missing or not numeric; string columns receive ''.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [System.Data.DataTable] $Table,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $InputObject
    )

    $Table.BeginLoadData()
    try {
        $Table.Rows.Clear()
        foreach ($item in $InputObject) {
            if ($null -eq $item) { continue }
            $row = $Table.NewRow()
            foreach ($column in $Table.Columns) {
                $text = Get-FslGuiPropertyText -InputObject $item -Name $column.ColumnName
                if ($column.DataType -eq [int]) {
                    $number = 0
                    if ([int]::TryParse($text, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
                        $row[$column.ColumnName] = $number
                    }
                    else { $row[$column.ColumnName] = 0 }
                }
                else {
                    $row[$column.ColumnName] = $text
                }
            }
            $Table.Rows.Add($row)
        }
    }
    finally {
        $Table.EndLoadData()
    }
    $Table.AcceptChanges()
}

function ConvertTo-FslGuiFilterLiteral {
    <#
    .SYNOPSIS
        Returns a DataColumn.Expression string literal: the value in single quotes with every single quote doubled.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    return ("'" + $Text.Replace("'", "''") + "'")
}

function ConvertTo-FslGuiLikePattern {
    <#
    .SYNOPSIS
        Escapes user text for use inside a DataColumn.Expression LIKE string literal (without the quotes).
    .DESCRIPTION
        '*', '%', '[' and ']' are each enclosed in brackets ([*], [%], [[], []]) so they match literally;
        single quotes are doubled. Characters are processed one at a time so brackets added by the escaping
        are never escaped again.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $builder = [System.Text.StringBuilder]::new($Text.Length + 8)
    foreach ($character in $Text.ToCharArray()) {
        switch ($character) {
            '*' { [void]$builder.Append('[*]') }
            '%' { [void]$builder.Append('[%]') }
            '[' { [void]$builder.Append('[[]') }
            ']' { [void]$builder.Append('[]]') }
            "'" { [void]$builder.Append("''") }
            default { [void]$builder.Append($character) }
        }
    }
    return $builder.ToString()
}

function ConvertTo-FslGuiFilterColumn {
    <#
    .SYNOPSIS
        Returns a column reference in square brackets with ']' and '\' escaped by a backslash.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    return ('[' + $Name.Replace('\', '\\').Replace(']', '\]') + ']')
}

function Get-FslGuiRowFilter {
    <#
    .SYNOPSIS
        Builds a DataView.RowFilter from a base filter, a status selection and free search text.
    .DESCRIPTION
        Status is applied only when the table has a Status column and the value is a contract status.
        Search text (trimmed; control characters removed) becomes "col LIKE '*text*'" OR-ed over the
        string columns of the table (or -SearchColumn when given). The parts are AND-ed together.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Data.DataTable] $Table,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $BaseFilter,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Status,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $SearchText,

        [Parameter()]
        [string[]] $SearchColumn
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($BaseFilter)) { $parts.Add("($BaseFilter)") }

    if (-not [string]::IsNullOrWhiteSpace($Status) -and $Status -in (Get-FslGuiStatusName) -and $Table.Columns.Contains('Status')) {
        $parts.Add(('{0} = {1}' -f (ConvertTo-FslGuiFilterColumn -Name 'Status'), (ConvertTo-FslGuiFilterLiteral -Text $Status)))
    }

    $text = if ($null -eq $SearchText) { '' } else { [regex]::Replace($SearchText, '[\p{Cc}]', ' ').Trim() }
    if ($text.Length -gt 0) {
        $columns = [System.Collections.Generic.List[string]]::new()
        $candidates = if ($PSBoundParameters.ContainsKey('SearchColumn') -and $null -ne $SearchColumn) { $SearchColumn } else { @($Table.Columns | ForEach-Object -Process { $_.ColumnName }) }
        foreach ($name in $candidates) {
            if ($Table.Columns.Contains($name) -and $Table.Columns[$name].DataType -eq [string]) { $columns.Add($name) }
        }
        if ($columns.Count -gt 0) {
            $pattern = "'*" + (ConvertTo-FslGuiLikePattern -Text $text) + "*'"
            $likes = foreach ($name in $columns) { '{0} LIKE {1}' -f (ConvertTo-FslGuiFilterColumn -Name $name), $pattern }
            $parts.Add('(' + (@($likes) -join ' OR ') + ')')
        }
    }
    return ($parts -join ' AND ')
}

function ConvertFrom-FslGuiDataRow {
    <#
    .SYNOPSIS
        Converts a DataRow or DataRowView into a pscustomobject (column order, or Result v2 order with -AsResult).
    .DESCRIPTION
        With -AsResult, RequiresElevation is converted back to [bool] when it holds True/False.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Row,

        [Parameter()]
        [switch] $AsResult
    )

    $dataRow = if ($Row -is [System.Data.DataRowView]) { $Row.Row } else { $Row }
    if ($dataRow -isnot [System.Data.DataRow]) {
        throw [System.ArgumentException]::new('Row must be a System.Data.DataRow or System.Data.DataRowView.')
    }
    $table = $dataRow.Table
    $names = if ($AsResult) { @(Get-FslGuiResultExportPropertyName | Where-Object -FilterScript { $table.Columns.Contains($_) }) } else { @($table.Columns | ForEach-Object -Process { $_.ColumnName }) }
    $properties = [ordered]@{}
    foreach ($name in $names) {
        $value = $dataRow[$name]
        if ($value -is [System.DBNull]) { $value = $null }
        if ($AsResult -and $name -eq 'RequiresElevation') {
            $flag = $false
            if ([bool]::TryParse([string]$value, [ref]$flag)) { $value = $flag }
        }
        $properties[$name] = $value
    }
    [pscustomobject]$properties
}

function Get-FslGuiViewObject {
    <#
    .SYNOPSIS
        Returns the rows currently visible in a DataView (RowFilter applied) as objects.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Data.DataView] $View,

        [Parameter()]
        [switch] $AsResult
    )

    for ($index = 0; $index -lt $View.Count; $index++) {
        ConvertFrom-FslGuiDataRow -Row $View[$index] -AsResult:$AsResult
    }
}

function Test-FslGuiHttpsUrl {
    <#
    .SYNOPSIS
        Returns $true only for an absolute https URI (the only kind the dashboard opens).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $trimmed = $Text.Trim()
    if ($trimmed -match '\s') { return $false }
    $uri = $null
    if (-not [System.Uri]::TryCreate($trimmed, [System.UriKind]::Absolute, [ref]$uri)) { return $false }
    return ($uri.Scheme -eq [System.Uri]::UriSchemeHttps -and -not [string]::IsNullOrEmpty($uri.Host))
}

function Test-FslGuiPathUnderRoot {
    <#
    .SYNOPSIS
        Returns $true when Path resolves (full path) to a location inside Root.
    .DESCRIPTION
        Uses System.IO.Path.GetFullPath on both values and compares with a trailing directory separator, so
        '..' segments and sibling folders with a common prefix are rejected. Comparison is case-insensitive
        on Windows and case-sensitive elsewhere.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullRoot = [System.IO.Path]::GetFullPath($Root)
    }
    catch {
        return $false
    }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $alternate = [System.IO.Path]::AltDirectorySeparatorChar
    $fullRoot = $fullRoot.TrimEnd($separator, $alternate) + $separator
    $comparison = if (Test-FslIsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    return ($fullPath.StartsWith($fullRoot, $comparison) -and $fullPath.Length -gt $fullRoot.Length)
}

function Test-FslGuiTimeText {
    <#
    .SYNOPSIS
        Returns $true for a 24-hour HH:mm time (00:00 - 23:59).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    if ($null -eq $Text) { return $false }
    return ($Text -cmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$')
}

function Get-FslGuiScopeList {
    <#
    .SYNOPSIS
        Maps a container mode to container scopes (CONTRACT P2.4: ODFC -> ODFC, Profiles -> Profiles, Both -> ODFC, Profiles).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $Mode
    )

    switch ($Mode) {
        'ODFC' { return , [string[]]@('ODFC') }
        'Profiles' { return , [string[]]@('Profiles') }
        default { return , [string[]]@('ODFC', 'Profiles') }
    }
}

function Get-FslGuiModeText {
    <#
    .SYNOPSIS
        Returns the display texts for a container mode (badge, window title, off messages).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ODFC', 'Profiles', 'Both')]
        [string] $Mode
    )

    $badge = switch ($Mode) {
        'ODFC' { 'Office Containers only' }
        'Profiles' { 'Profile Containers only' }
        default { 'Office + Profile Containers' }
    }
    return @{
        Badge            = $badge
        Title            = "FSLogixToolkit - $badge"
        OfficeOff        = 'Office container checks are off (Profile containers only). Use Options > Container Mode to include Office containers.'
        ProfilesOff      = 'Profile container checks are off (Office containers only).'
        OfficeEnabled    = ($Mode -in @('ODFC', 'Both'))
        ProfilesEnabled  = ($Mode -in @('Profiles', 'Both'))
    }
}
