function Export-FslDiagnosticBundle {
    <#
    .SYNOPSIS
        Creates a zip with toolkit logs, the toolkit error log, recent FSLogix logs, latest reports and system info.
    .DESCRIPTION
        Stages files in a temporary folder and compresses them to
        <Path or ReportRoot>/FSLogixToolkit_Diagnostics_<yyyyMMdd_HHmmss>.zip:
          Toolkit/      toolkit log files from the session LogRoot modified within -Days (always includes the current log)
          ErrorLog/     output of Export-FslErrorLog (.json and .csv)
          FSLogix/      FSLogix *.log files modified within -Days (Windows only; folder structure kept)
          Reports/      the 10 most recent report files from ReportRoot (existing zip files excluded)
          Reports/Repair/<yyyy-MM-dd>/  repair run logs (Repair_*.log/.json/.csv) from <ReportRoot>/<Repair.FolderName>
                        modified within -Days. The authoritative rollback store (Repair.StateRoot) is never collected.
          SystemInfo.txt  PowerShell version table, OS description/version, FSLogix installation summary
          BundleManifest.txt  what was collected and what could not be collected
        Text files are redacted: values after AccountKey=, SharedAccessSignature= and sig= are replaced with
        REDACTED. The staging folder is always removed.
    .PARAMETER Path
        Output folder for the zip. Defaults to the session ReportRoot.
    .PARAMETER Days
        Include FSLogix and toolkit log files modified within this many days. Toolkit default: Settings.psd1 Diagnostics.LogDays.
    .EXAMPLE
        Export-FslDiagnosticBundle -Days 3
    .EXAMPLE
        Export-FslDiagnosticBundle -Path 'D:\Support' -WhatIf
    .NOTES
        RequiresElevation: No. FSLogix log files that deny access to a standard user are listed in BundleManifest.txt.
        Sources:
          https://learn.microsoft.com/en-us/fslogix/troubleshooting-events-logs-diagnostics (FSLogix log folder C:\ProgramData\FSLogix\Logs)
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings (Logging: LogDir default %ProgramData%\FSLogix\Logs)
          https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.archive/compress-archive (LiteralPath, DestinationPath, Force)
          Docs/CONTRACT.md P3.4 (repair log copies included, rollback store excluded)
        ETL trace files (trace.etl.00x) are not collected: Microsoft document them as intended for Microsoft internal use.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateRange(1, 365)]
        [int] $Days
    )

    $category = 'Diagnostics'

    try {
        if (-not $script:FslSession.Initialized) { $null = Initialize-FslSession }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component $category -Context 'Initializing session for diagnostic bundle'
    }

    if (-not $PSBoundParameters.ContainsKey('Days')) {
        $Days = 7
        try {
            $config = Get-FslConfig -Section 'Diagnostics'
            if ($config -and $config['LogDays']) { $Days = [int]$config['LogDays'] }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $category -Context 'Loading Diagnostics settings'
        }
    }

    if (-not $PSBoundParameters.ContainsKey('Path')) { $Path = $script:FslSession.ReportRoot }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'FSLogixToolkit'
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $zipPath = Join-Path -Path $Path -ChildPath "FSLogixToolkit_Diagnostics_$timestamp.zip"
    if (-not $PSCmdlet.ShouldProcess($zipPath, 'Create FSLogixToolkit diagnostic bundle')) { return }

    $startTime = (Get-Date).AddDays(-$Days)
    $staging = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("FSLogixToolkit_Diag_{0}" -f [guid]::NewGuid().ToString('N'))
    $manifest = [System.Collections.Generic.List[string]]::new()
    $manifest.Add("FSLogixToolkit diagnostic bundle created $((Get-Date).ToString('o'))")
    $manifest.Add("Days: $Days (files modified since $($startTime.ToString('s')))")

    try {
        $null = New-Item -Path $staging -ItemType Directory -Force

        # ---- Toolkit logs ----
        try {
            $toolkitDir = Join-Path -Path $staging -ChildPath 'Toolkit'
            $logRoot = $script:FslSession.LogRoot
            $toolkitLogs = [System.Collections.Generic.List[string]]::new()
            if ($script:FslSession.LogPath -and (Test-Path -LiteralPath $script:FslSession.LogPath -PathType Leaf)) {
                $toolkitLogs.Add([string](Resolve-Path -LiteralPath $script:FslSession.LogPath).ProviderPath)
            }
            if ($logRoot -and (Test-Path -LiteralPath $logRoot -PathType Container)) {
                foreach ($file in @(Get-ChildItem -LiteralPath $logRoot -File -ErrorAction SilentlyContinue |
                            Where-Object -FilterScript { $_.LastWriteTime -ge $startTime -and $_.Extension -ne '.zip' })) {
                    if (-not $toolkitLogs.Contains($file.FullName)) { $toolkitLogs.Add($file.FullName) }
                }
            }
            foreach ($logFile in $toolkitLogs) {
                try {
                    $null = Copy-FslDiagFile -SourcePath $logFile -DestinationPath (Join-Path -Path $toolkitDir -ChildPath (Split-Path -Path $logFile -Leaf))
                    $manifest.Add("Collected toolkit log: $logFile")
                }
                catch {
                    Add-FslError -ErrorRecord $_ -Component $category -Context "Copying toolkit log $logFile"
                    $manifest.Add("NOT collected toolkit log: $logFile ($($_.Exception.Message))")
                }
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $category -Context 'Collecting toolkit logs'
            $manifest.Add("Toolkit logs not collected: $($_.Exception.Message)")
        }

        # ---- Error log ----
        try {
            $errorDir = Join-Path -Path $staging -ChildPath 'ErrorLog'
            $null = New-Item -Path $errorDir -ItemType Directory -Force
            $exported = @(Export-FslErrorLog -Path $errorDir)
            foreach ($item in $exported) {
                if ($null -eq $item) { continue }
                $itemPath = [string]$item.FullName
                if (-not $itemPath.StartsWith($errorDir, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $itemPath -PathType Leaf)) {
                    $null = Copy-FslDiagFile -SourcePath $itemPath -DestinationPath (Join-Path -Path $errorDir -ChildPath $item.Name)
                }
                elseif (Test-Path -LiteralPath $itemPath -PathType Leaf) {
                    $redacted = ConvertTo-FslDiagRedactedText -Text ([System.IO.File]::ReadAllText($itemPath))
                    [System.IO.File]::WriteAllText($itemPath, $redacted)
                }
                $manifest.Add("Collected error log: $($item.Name)")
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $category -Context 'Exporting toolkit error log'
            $manifest.Add("Error log not collected: $($_.Exception.Message)")
        }

        # ---- FSLogix logs (Windows) ----
        if (Test-FslIsWindows) {
            try {
                $fslLogDir = Get-FslDiagLogDirectory
                if (Test-Path -LiteralPath $fslLogDir -PathType Container) {
                    $root = (Resolve-Path -LiteralPath $fslLogDir).ProviderPath.TrimEnd('\', '/')
                    $fslFiles = @(Get-ChildItem -LiteralPath $root -Filter '*.log' -File -Recurse -ErrorAction SilentlyContinue |
                            Where-Object -FilterScript { $_.LastWriteTime -ge $startTime })
                    foreach ($file in $fslFiles) {
                        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/')
                        try {
                            $null = Copy-FslDiagFile -SourcePath $file.FullName -DestinationPath (Join-Path -Path (Join-Path -Path $staging -ChildPath 'FSLogix') -ChildPath $relative)
                            $manifest.Add("Collected FSLogix log: $($file.FullName)")
                        }
                        catch {
                            Add-FslError -ErrorRecord $_ -Component $category -Context "Copying FSLogix log $($file.FullName)"
                            $manifest.Add("NOT collected FSLogix log: $($file.FullName) ($($_.Exception.Message))")
                        }
                    }
                    if ($fslFiles.Count -eq 0) { $manifest.Add("No FSLogix *.log files modified within $Days day(s) in $root") }
                }
                else {
                    $manifest.Add("FSLogix log folder not found: $fslLogDir")
                }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component $category -Context 'Collecting FSLogix logs'
                $manifest.Add("FSLogix logs not collected: $($_.Exception.Message)")
            }
        }
        else {
            $manifest.Add('FSLogix logs skipped: not running on Windows.')
        }

        # ---- Latest reports ----
        try {
            $reportRoot = $script:FslSession.ReportRoot
            if ($reportRoot -and (Test-Path -LiteralPath $reportRoot -PathType Container)) {
                $reports = @(Get-ChildItem -LiteralPath $reportRoot -File -ErrorAction SilentlyContinue |
                        Where-Object -FilterScript { $_.Extension -ne '.zip' -and $_.Name -ne '.gitkeep' } |
                        Sort-Object -Property LastWriteTime -Descending | Select-Object -First 10)
                foreach ($report in $reports) {
                    try {
                        $null = Copy-FslDiagFile -SourcePath $report.FullName -DestinationPath (Join-Path -Path (Join-Path -Path $staging -ChildPath 'Reports') -ChildPath $report.Name)
                        $manifest.Add("Collected report: $($report.Name)")
                    }
                    catch {
                        Add-FslError -ErrorRecord $_ -Component $category -Context "Copying report $($report.FullName)"
                        $manifest.Add("NOT collected report: $($report.Name) ($($_.Exception.Message))")
                    }
                }
            }
            else {
                $manifest.Add('No report folder available.')
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $category -Context 'Collecting reports'
            $manifest.Add("Reports not collected: $($_.Exception.Message)")
        }

        # ---- Repair logs (readable copies only; never the rollback StateRoot) ----
        try {
            $repairRoot = $null
            if ($script:FslSession.ReportRoot) {
                $repairFolderName = 'Repair'
                $repairConfig = Get-FslConfig -Section 'Repair'
                if ($repairConfig -and -not [string]::IsNullOrWhiteSpace([string]$repairConfig['FolderName'])) { $repairFolderName = [string]$repairConfig['FolderName'] }
                $repairRoot = Join-Path -Path $script:FslSession.ReportRoot -ChildPath $repairFolderName
            }
            $stateRoot = $null
            try { $stateRoot = Resolve-FslFixStateRoot } catch { $stateRoot = $null }
            if ($repairRoot -and $stateRoot -and
                ([System.IO.Path]::GetFullPath($repairRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar).StartsWith(
                    [System.IO.Path]::GetFullPath($stateRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                $manifest.Add("Repair logs skipped: repair log folder is inside the rollback StateRoot ($repairRoot).")
            }
            elseif ($repairRoot -and (Test-Path -LiteralPath $repairRoot -PathType Container)) {
                $repairCount = 0
                foreach ($dayFolder in @(Get-ChildItem -LiteralPath $repairRoot -Directory -ErrorAction SilentlyContinue)) {
                    $dayDate = [datetime]::MinValue
                    if (-not [datetime]::TryParseExact($dayFolder.Name, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::None, [ref]$dayDate)) { continue }
                    $repairFiles = @(Get-ChildItem -LiteralPath $dayFolder.FullName -File -Filter 'Repair_*' -ErrorAction SilentlyContinue |
                            Where-Object -FilterScript { $_.LastWriteTime -ge $startTime -and @('.log', '.json', '.csv') -contains $_.Extension.ToLowerInvariant() })
                    foreach ($repairFile in $repairFiles) {
                        try {
                            $destination = Join-Path -Path (Join-Path -Path (Join-Path -Path (Join-Path -Path $staging -ChildPath 'Reports') -ChildPath 'Repair') -ChildPath $dayFolder.Name) -ChildPath $repairFile.Name
                            $null = Copy-FslDiagFile -SourcePath $repairFile.FullName -DestinationPath $destination
                            $repairCount++
                        }
                        catch {
                            Add-FslError -ErrorRecord $_ -Component $category -Context "Copying repair log $($repairFile.FullName)"
                            $manifest.Add("NOT collected repair log: $($repairFile.FullName) ($($_.Exception.Message))")
                        }
                    }
                }
                $manifest.Add("Collected $repairCount repair log file(s) modified within $Days day(s) from $repairRoot")
            }
            else {
                $manifest.Add('No repair log folder available.')
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $category -Context 'Collecting repair logs'
            $manifest.Add("Repair logs not collected: $($_.Exception.Message)")
        }

        # ---- System info ----
        try {
            $info = [System.Text.StringBuilder]::new()
            $null = $info.AppendLine("ComputerName: $([System.Environment]::MachineName)")
            $null = $info.AppendLine("Collected: $((Get-Date).ToString('o'))")
            $null = $info.AppendLine("OSDescription: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)")
            $null = $info.AppendLine("OSVersion: $([System.Environment]::OSVersion.VersionString)")
            $null = $info.AppendLine("OSArchitecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)")
            $null = $info.AppendLine("IsElevated: $(Test-FslElevation)")
            $null = $info.AppendLine('')
            $null = $info.AppendLine('PSVersionTable:')
            foreach ($key in $PSVersionTable.Keys) {
                $null = $info.AppendLine(('  {0}: {1}' -f $key, ($PSVersionTable[$key] -join ', ')))
            }
            if (Test-FslIsWindows) {
                $null = $info.AppendLine('')
                $null = $info.AppendLine('FSLogix installation:')
                try {
                    $installation = Find-FslInstallation
                    if ($null -ne $installation) {
                        $null = $info.AppendLine(($installation | Format-List -Property * | Out-String -Width 200).TrimEnd())
                    }
                }
                catch {
                    Add-FslError -ErrorRecord $_ -Component $category -Context 'Detecting FSLogix installation for bundle'
                    $null = $info.AppendLine("  Not available: $($_.Exception.Message)")
                }
            }
            $infoPath = Join-Path -Path $staging -ChildPath 'SystemInfo.txt'
            [System.IO.File]::WriteAllText($infoPath, (ConvertTo-FslDiagRedactedText -Text $info.ToString()))
            $manifest.Add('Collected SystemInfo.txt')
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $category -Context 'Writing system information'
            $manifest.Add("SystemInfo.txt not written: $($_.Exception.Message)")
        }

        [System.IO.File]::WriteAllText((Join-Path -Path $staging -ChildPath 'BundleManifest.txt'),
            (ConvertTo-FslDiagRedactedText -Text ($manifest -join [System.Environment]::NewLine)))

        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            $null = New-Item -Path $Path -ItemType Directory -Force
        }
        $items = @(Get-ChildItem -LiteralPath $staging | ForEach-Object -Process { $_.FullName })
        Compress-Archive -LiteralPath $items -DestinationPath $zipPath -Force -ErrorAction Stop
        Write-FslLog -Message "Diagnostic bundle created: $zipPath" -Level Info -Component $category
        return (Get-Item -LiteralPath $zipPath)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component $category -Context 'Creating diagnostic bundle'
        Write-Error -Message "Failed to create diagnostic bundle: $($_.Exception.Message)" -ErrorAction Continue
    }
    finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
