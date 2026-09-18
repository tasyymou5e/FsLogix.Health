function Get-FslRepairLog {
    <#
    .SYNOPSIS
        Returns repair run history from the readable repair log copies, newest first.

    .DESCRIPTION
        Reads the JSON run envelopes <ReportRoot>/<Repair.FolderName>/<yyyy-MM-dd>/Repair_<HHmmss>_<RunId8>.json written by
        the repair engine and returns one FSLogixToolkit.RepairLog object per run: RunId, Mode, RollbackOfRunId, StartedAt,
        EndedAt, ComputerName, Operator, OperatorSid, IsElevated, InvocationSource, ToolkitVersion, FSLogixVersion,
        ContainerMode, ChangeReference, ActionCount, Pass, Fail, Error, Skipped, Info, PreflightFailed, LogPath, JsonPath,
        CsvPath, RollbackStorePath and, with -IncludeRecords, Records (FSLogixToolkit.RepairRecord[] in contract order).
        Only day folders named yyyy-MM-dd are read; unreadable files are skipped and recorded in the error log.
        The authoritative rollback store (Repair.StateRoot) is not read. Text is redacted again on output.

    .PARAMETER Days
        Number of days to include, counting back from today (today included). Default: Repair.RetainDays (toolkit default 180).

    .PARAMETER RunId
        Return only the run with this RunId.

    .PARAMETER ReportRoot
        Report root folder. Default: the session ReportRoot (Initialize-FslSession).

    .PARAMETER IncludeRecords
        Adds the per-action RepairRecord objects of each run in the Records property.

    .EXAMPLE
        Get-FslRepairLog -Days 7 | Format-Table StartedAt, Mode, RunId, ActionCount, Fail, Error

    .EXAMPLE
        Get-FslRepairLog -RunId 'd2f1a0c4-6b0e-4a51-9d7e-2b1f0e7c9a11' -IncludeRecords | Select-Object -ExpandProperty Records

    .OUTPUTS
        FSLogixToolkit.RepairLog

    .NOTES
        RequiresElevation: No (reads the readable log copies under ReportRoot only).
        Sources:
          https://learn.microsoft.com/dotnet/api/system.text.json.jsondocument
          https://learn.microsoft.com/powershell/module/microsoft.powershell.management/get-childitem
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateRange(1, 3650)]
        [int] $Days,

        [Parameter()]
        [guid] $RunId,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ReportRoot,

        [Parameter()]
        [switch] $IncludeRecords
    )

    $component = 'Repair'
    try {
        $repairRoot = Resolve-FslFixReportRoot -ReportRoot $ReportRoot
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component $component -Context 'Resolve repair log folder'
        return
    }

    if (-not $PSBoundParameters.ContainsKey('Days')) {
        $Days = [int](Get-FslFixConfig)['RetainDays']
        if ($Days -le 0) { $Days = 180 }
    }
    $since = (Get-Date).Date.AddDays( - ($Days - 1))
    if (-not [System.IO.Directory]::Exists($repairRoot)) {
        Write-FslLog -Message "No repair logs found (folder missing): $repairRoot" -Level Verbose -Component $component
        return
    }

    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    try {
        foreach ($folder in [System.IO.Directory]::GetDirectories($repairRoot)) {
            $date = [datetime]::MinValue
            if (-not [datetime]::TryParseExact([System.IO.Path]::GetFileName($folder), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None, [ref]$date)) { continue }
            if ($date -lt $since) { continue }
            foreach ($path in [System.IO.Directory]::GetFiles($folder, 'Repair_*.json')) {
                if ($PSBoundParameters.ContainsKey('RunId')) {
                    $short = $RunId.ToString('N').Substring(0, 8)
                    if (-not [System.IO.Path]::GetFileName($path).EndsWith("_$short.json", [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                }
                $files.Add([System.IO.FileInfo]::new($path))
            }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component $component -Context "List repair logs under '$repairRoot'"
        return
    }

    $runs = foreach ($file in $files) {
        try {
            $envelope = ConvertFrom-FslFixJson -Json ([System.IO.File]::ReadAllText($file.FullName))
            if (-not ($envelope -is [System.Collections.IDictionary]) -or -not $envelope.Contains('RunId')) { continue }
            if ($PSBoundParameters.ContainsKey('RunId') -and
                -not [string]::Equals([string]$envelope['RunId'], $RunId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            $summary = Get-FslFixValue -InputObject $envelope -Name 'Summary'
            $operator = Get-FslFixValue -InputObject $envelope -Name 'Operator'
            $actionsValue = Get-FslFixValue -InputObject $envelope -Name 'Actions'
            $actions = @($actionsValue | Where-Object -FilterScript { $null -ne $_ })
            $basePath = $file.FullName.Substring(0, $file.FullName.Length - $file.Extension.Length)

            $row = [ordered]@{
                PSTypeName        = 'FSLogixToolkit.RepairLog'
                RunId             = [string]$envelope['RunId']
                Mode              = [string](Get-FslFixValue -InputObject $envelope -Name 'Mode')
                RollbackOfRunId   = Get-FslFixValue -InputObject $envelope -Name 'RollbackOfRunId'
                StartedAt         = [string](Get-FslFixValue -InputObject $envelope -Name 'StartedAt')
                EndedAt           = [string](Get-FslFixValue -InputObject $envelope -Name 'EndedAt')
                ComputerName      = [string](Get-FslFixValue -InputObject $envelope -Name 'ComputerName')
                Operator          = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $operator -Name 'Name')
                OperatorSid       = Get-FslFixValue -InputObject $operator -Name 'Sid'
                IsElevated        = [bool](Get-FslFixValue -InputObject $envelope -Name 'IsElevated')
                InvocationSource  = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $envelope -Name 'InvocationSource')
                ToolkitVersion    = [string](Get-FslFixValue -InputObject $envelope -Name 'ToolkitVersion')
                FSLogixVersion    = Get-FslFixValue -InputObject $envelope -Name 'FSLogixVersion'
                ContainerMode     = Get-FslFixValue -InputObject $envelope -Name 'ContainerMode'
                ChangeReference   = ConvertTo-FslFixText -InputObject (Get-FslFixValue -InputObject $envelope -Name 'ChangeReference')
                ActionCount       = $actions.Count
                Pass              = [int](Get-FslFixValue -InputObject $summary -Name 'Pass')
                Fail              = [int](Get-FslFixValue -InputObject $summary -Name 'Fail')
                Error             = [int](Get-FslFixValue -InputObject $summary -Name 'Error')
                Skipped           = [int](Get-FslFixValue -InputObject $summary -Name 'Skipped')
                Info              = [int](Get-FslFixValue -InputObject $summary -Name 'Info')
                PreflightFailed   = [int](Get-FslFixValue -InputObject $summary -Name 'PreflightFailed')
                LogPath           = "$basePath.log"
                JsonPath          = $file.FullName
                CsvPath           = "$basePath.csv"
                RollbackStorePath = Get-FslFixValue -InputObject $envelope -Name 'RollbackStorePath'
            }
            if ($IncludeRecords) {
                $row['Records'] = @(foreach ($action in $actions) {
                        $record = [ordered]@{ PSTypeName = 'FSLogixToolkit.RepairRecord' }
                        foreach ($name in $script:FslFixRecordProperties) {
                            $value = Get-FslFixValue -InputObject $action -Name $name
                            $record[$name] = switch ($name) {
                                'Sequence' { if ($null -ne $value) { [int]$value } else { $null } }
                                'RiskTier' { if ($null -ne $value) { [int]$value } else { $null } }
                                'IsElevated' { [bool]$value }
                                'RollbackAvailable' { [bool]$value }
                                default { ConvertTo-FslFixText -InputObject $value }
                            }
                        }
                        [pscustomobject]$record
                    })
            }
            [pscustomobject]$row
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $component -Context "Read repair log '$($file.FullName)'"
        }
    }

    @($runs) | Sort-Object -Property StartedAt -Descending
}
