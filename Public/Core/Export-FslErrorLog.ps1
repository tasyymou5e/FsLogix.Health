function Export-FslErrorLog {
    <#
    .SYNOPSIS
        Exports the session error log to JSON and CSV files.
    .DESCRIPTION
        Writes FSLogixToolkit_Errors_<yyyyMMdd_HHmmss>.json (ConvertTo-Json -Depth 4) and .csv (UTF-8) to the
        folder given by -Path, or to the session ReportRoot when -Path is omitted (the session is initialized
        implicitly). When there are no errors the JSON file contains an empty array and the CSV file contains
        only the header row. Returns the two FileInfo objects. Errors are recorded, not thrown.
    .PARAMETER Path
        Destination folder. Created if it does not exist. Defaults to the session ReportRoot.
    .EXAMPLE
        Export-FslErrorLog

        Exports the error log to the toolkit Reports folder.
    .EXAMPLE
        Export-FslErrorLog -Path C:\Temp\FslErrors

        Exports the error log to C:\Temp\FslErrors.
    .NOTES
        RequiresElevation: No
        Sources:
          https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertto-json
          https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/export-csv
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    try {
        if (-not $PSBoundParameters.ContainsKey('Path')) {
            if (-not $script:FslSession['Initialized']) { $null = Initialize-FslSession }
            $Path = $script:FslSession['ReportRoot']
        }
        if ([string]::IsNullOrEmpty($Path)) { throw 'No export folder available (ReportRoot is not set).' }

        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            $null = New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop
        }

        $baseName = 'FSLogixToolkit_Errors_{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
        $jsonPath = Join-Path -Path $Path -ChildPath "$baseName.json"
        $csvPath = Join-Path -Path $Path -ChildPath "$baseName.csv"

        $errors = @(Get-FslErrorLog)
        $encoding = [System.Text.UTF8Encoding]::new($false)

        $json = ConvertTo-Json -InputObject $errors -Depth 4
        [System.IO.File]::WriteAllText($jsonPath, $json, $encoding)

        if ($errors.Count -gt 0) {
            $errors | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8NoBOM -ErrorAction Stop
        }
        else {
            $header = '"Timestamp","Component","Context","Message","ExceptionType","CategoryInfo","TargetObject","ScriptStackTrace","InvocationLine"'
            [System.IO.File]::WriteAllText($csvPath, $header + [Environment]::NewLine, $encoding)
        }

        Write-FslLog -Message "Exported $($errors.Count) error(s) to $jsonPath and $csvPath" -Level Info -Component 'Core'
        Get-Item -LiteralPath $jsonPath, $csvPath -ErrorAction Stop
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Export-FslErrorLog'
    }
}
