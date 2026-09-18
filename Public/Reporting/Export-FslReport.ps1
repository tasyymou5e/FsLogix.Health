function Export-FslReport {
    <#
    .SYNOPSIS
        Exports FSLogixToolkit results to CSV and/or a self-contained HTML report.

    .DESCRIPTION
        Collects Result objects (CONTRACT 5.1) from the pipeline or -InputObject and writes
        FSLogixToolkit_Report_<yyyyMMdd_HHmmss>.csv and/or .html into -Path (or the session ReportRoot).
        CSV is written with Export-Csv -NoTypeInformation -Encoding utf8.
        HTML is self-contained (inline CSS, no scripts, no external resources); every value is encoded
        with [System.Net.WebUtility]::HtmlEncode. The HTML header shows computer name, timestamp,
        elevation state and PowerShell version, followed by a Category x Status summary table, a
        Scope x Status summary table (container scope General|ODFC|Profiles) and one detail table per
        Category with status CSS classes and a Scope column.
        When every input object is a Result, the CSV columns are the Result properties in contract order
        including the trailing Scope column. Results without a Scope property (phase 1 producers) are
        exported and summarized as Scope 'General'.

    .PARAMETER InputObject
        Result objects to export. Accepts pipeline input.

    .PARAMETER Format
        Csv, Html or Both (default).

    .PARAMETER Path
        Output folder. Created when missing. Defaults to the session ReportRoot (Initialize-FslSession).

    .PARAMETER Title
        Report title used in the HTML report.

    .EXAMPLE
        Invoke-FslHealthCheck | Export-FslReport -Format Both

    .EXAMPLE
        Export-FslReport -InputObject (Get-FslEnvironment) -Format Html -Path 'C:\Temp\Reports'

    .OUTPUTS
        System.IO.FileInfo

    .NOTES
        RequiresElevation: No
        Sources:
          https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/export-csv
          https://learn.microsoft.com/dotnet/api/system.net.webutility.htmlencode
          https://learn.microsoft.com/powershell/module/microsoft.powershell.management/set-content
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $InputObject,

        [Parameter()]
        [ValidateSet('Csv', 'Html', 'Both')]
        [string] $Format = 'Both',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Title = 'FSLogixToolkit Health Report'
    )

    begin {
        $collected = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $InputObject) {
            if ($null -ne $item) { $collected.Add($item) }
        }
    }

    end {
        if ($collected.Count -eq 0) {
            Write-FslLog -Message 'Export-FslReport: no input objects; nothing exported.' -Level Warning -Component 'Reporting'
            return
        }

        try {
            $folder = Resolve-FslRptOutputFolder -Path $Path
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Reporting' -Context 'Resolve report output folder'
            return
        }

        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $baseName = "FSLogixToolkit_Report_$stamp"
        $items = $collected.ToArray()
        $allResults = @($items | Where-Object -FilterScript { Test-FslRptIsResult -InputObject $_ }).Count -eq $items.Count

        if ($Format -in @('Csv', 'Both')) {
            $csvPath = Join-Path -Path $folder -ChildPath "$baseName.csv"
            try {
                if ($allResults) {
                    $items | Select-Object -Property (Get-FslRptCsvPropertySelector) |
                        Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
                }
                else {
                    $items | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
                }
                Write-FslLog -Message "CSV report written: $csvPath" -Level Info -Component 'Reporting'
                Get-Item -LiteralPath $csvPath -ErrorAction Stop
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Reporting' -Context "Write CSV report '$csvPath'"
            }
        }

        if ($Format -in @('Html', 'Both')) {
            $htmlPath = Join-Path -Path $folder -ChildPath "$baseName.html"
            try {
                $elevated = 'Unknown'
                try {
                    $elevated = if (Test-FslElevation) { 'Yes' } else { 'No' }
                }
                catch {
                    Add-FslError -ErrorRecord $_ -Component 'Reporting' -Context 'Determine elevation for report header'
                }
                $htmlParams = @{
                    Result            = $items
                    Title             = $Title
                    ComputerName      = [System.Environment]::MachineName
                    Generated         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz', [System.Globalization.CultureInfo]::InvariantCulture)
                    Elevated          = $elevated
                    PowerShellVersion = "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
                }
                $html = ConvertTo-FslRptHtml @htmlParams
                Set-Content -LiteralPath $htmlPath -Value $html -Encoding utf8 -NoNewline -ErrorAction Stop
                Write-FslLog -Message "HTML report written: $htmlPath" -Level Info -Component 'Reporting'
                Get-Item -LiteralPath $htmlPath -ErrorAction Stop
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Reporting' -Context "Write HTML report '$htmlPath'"
            }
        }
    }
}
