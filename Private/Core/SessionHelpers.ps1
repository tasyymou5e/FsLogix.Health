# Private helpers for Initialize-FslSession (Agent 1).

function Get-FslCoreSessionInfo {
    <#
    .SYNOPSIS
        Returns the public session information object.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    [pscustomobject]@{
        ModuleRoot   = $script:FslSession['ModuleRoot']
        LogRoot      = $script:FslSession['LogRoot']
        ReportRoot   = $script:FslSession['ReportRoot']
        LogPath      = $script:FslSession['LogPath']
        DebugLogging = [bool]$script:FslSession['DebugLogging']
        IsElevated   = [bool](Test-FslElevation)
        IsWindows    = [bool](Test-FslIsWindows)
        PSVersion    = $PSVersionTable.PSVersion.ToString()
    }
}

function Test-FslCoreWritableFolder {
    <#
    .SYNOPSIS
        Creates the folder if needed and tests writability by creating and removing a temporary file.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $probe = $null
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            $null = New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop
        }
        $probe = Join-Path -Path $Path -ChildPath ('.fsltk_write_test_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'write test')
        return $true
    }
    catch {
        Write-Verbose -Message "Folder not writable: $Path ($($_.Exception.Message))"
        return $false
    }
    finally {
        if ($null -ne $probe) {
            try { if ([System.IO.File]::Exists($probe)) { [System.IO.File]::Delete($probe) } } catch { $null = $_ }
        }
    }
}

function Resolve-FslCoreWritableFolder {
    <#
    .SYNOPSIS
        Picks the first writable folder: preferred path, <ModuleRoot>/<FolderName>,
        <LocalAppData>/<FallbackFolder>/<FolderName>, then <Temp>/<FallbackFolder>/<FolderName>.
        Returns $null if none is writable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Preferred,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ModuleRoot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FolderName,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $LocalAppData,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FallbackFolder
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrEmpty($Preferred)) { $candidates.Add($Preferred) }
    $candidates.Add((Join-Path -Path $ModuleRoot -ChildPath $FolderName))
    if (-not [string]::IsNullOrEmpty($LocalAppData)) {
        $candidates.Add((Join-Path -Path (Join-Path -Path $LocalAppData -ChildPath $FallbackFolder) -ChildPath $FolderName))
    }
    $candidates.Add((Join-Path -Path (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath $FallbackFolder) -ChildPath $FolderName))

    $first = $true
    foreach ($candidate in $candidates) {
        if (Test-FslCoreWritableFolder -Path $candidate) {
            try { return [System.IO.Path]::GetFullPath($candidate) } catch { return $candidate }
        }
        if ($first -and -not [string]::IsNullOrEmpty($Preferred)) {
            Write-FslLog -Message "Requested folder '$Preferred' is not writable - using fallback location." -Level Warning -Component 'Core'
        }
        $first = $false
    }
    return $null
}

function Remove-FslCoreOldLog {
    <#
    .SYNOPSIS
        Deletes toolkit log files (FSLogixToolkit_*.log) older than RetainDays. Never removes the current log.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $LogRoot,

        [int] $RetainDays = 30,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $CurrentLogPath
    )

    if ([string]::IsNullOrEmpty($LogRoot) -or $RetainDays -le 0) { return }
    try {
        $cutoff = (Get-Date).AddDays(-$RetainDays)
        $oldLogs = Get-ChildItem -LiteralPath $LogRoot -Filter 'FSLogixToolkit_*.log' -File -ErrorAction Stop |
            Where-Object -FilterScript { $_.LastWriteTime -lt $cutoff -and $_.FullName -ne $CurrentLogPath }
        foreach ($log in $oldLogs) {
            if ($PSCmdlet.ShouldProcess($log.FullName, 'Remove toolkit log older than retention period')) {
                try {
                    Remove-Item -LiteralPath $log.FullName -Force -ErrorAction Stop
                    Write-FslLog -Message "Pruned old log $($log.Name)" -Level Verbose -Component 'Core'
                }
                catch { Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Pruning log $($log.FullName)" }
            }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Pruning logs in $LogRoot"
    }
}
