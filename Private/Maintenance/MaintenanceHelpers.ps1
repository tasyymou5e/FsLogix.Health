# FSLogixToolkit - Maintenance private helpers (Agent 8).
# Sources verified 2026-09-17:
#   https://learn.microsoft.com/en-us/fslogix/concepts-vhd-disk-compaction
#   https://learn.microsoft.com/en-us/fslogix/troubleshooting-vhd-disk-compaction ("The VHD Disk Compaction feature is available in
#     FSLogix 2210 (2.9.8361.52326) or later"; compaction relies on defragsvc and smphost; StartupType Disabled on either
#     -> compaction can't run; Manual or Automatic required; ERROR:00000422 / ERROR:00000102 are not mapped to a service;
#     Event 60 (Admin log) names defragsvc)
#   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings (VHDCompactDisk, HKLM\SOFTWARE\FSLogix\Apps, default 1)
#   https://learn.microsoft.com/en-us/powershell/module/hyper-v/optimize-vhd
#   https://learn.microsoft.com/en-us/powershell/module/storage/mount-diskimage
#   https://learn.microsoft.com/en-us/powershell/module/storage/dismount-diskimage
#   https://learn.microsoft.com/en-us/powershell/module/storage/get-diskimage
#   https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-diskimage
#   https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/diskpart
#   https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/select-vdisk
#   https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/attach-vdisk
#   https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/compact-vdisk
#   https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/detach-vdisk
#   https://github.com/FSLogix/Invoke-FslShrinkDisk (read only, not executed)

function Get-FslMntSource {
    <# Returns the verified source URLs used by the Maintenance area. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        FslCompaction     = 'https://learn.microsoft.com/en-us/fslogix/concepts-vhd-disk-compaction'
        FslCompactionTroubleshooting = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-vhd-disk-compaction'
        FslConfigSettings = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings'
        OptimizeVhd       = 'https://learn.microsoft.com/en-us/powershell/module/hyper-v/optimize-vhd'
        MountDiskImage    = 'https://learn.microsoft.com/en-us/powershell/module/storage/mount-diskimage'
        DismountDiskImage = 'https://learn.microsoft.com/en-us/powershell/module/storage/dismount-diskimage'
        GetDiskImage      = 'https://learn.microsoft.com/en-us/powershell/module/storage/get-diskimage'
        CompactVdisk      = 'https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/compact-vdisk'
        DiskPart          = 'https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/diskpart'
        FslShrinkDisk     = 'https://github.com/FSLogix/Invoke-FslShrinkDisk'
        InstallHyperV     = 'https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/install-hyper-v'
        MoveItem          = 'https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/move-item'
        RemoveItem        = 'https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/remove-item'
    }
}

function ConvertTo-FslMntResultScope {
    <# Maps a container Scope (Profiles|ODFC|Unknown|other/empty) to a Result Scope (Profiles|ODFC|General). #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Scope
    )

    if ($Scope -eq 'Profiles') { return 'Profiles' }
    if ($Scope -eq 'ODFC') { return 'ODFC' }
    return 'General'
}

function Get-FslMntPropertyValue {
    <# StrictMode-safe property read from a PSObject/hashtable; returns $null when absent. #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-FslMntConfigValue {
    <# Reads a toolkit default from Config/Settings.psd1 via Get-FslConfig, with a fallback value. #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Section,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Default
    )

    try {
        $config = Get-FslConfig -Section $Section
        if ($config -is [System.Collections.IDictionary] -and $config.Contains($Name) -and $null -ne $config[$Name]) {
            return $config[$Name]
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "Reading toolkit setting $Section.$Name"
    }
    return $Default
}

function ConvertTo-FslMntGigabyte {
    <# Converts bytes to GB (1024^3) rounded to 2 decimals. #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [long] $Bytes
    )

    return [math]::Round(($Bytes / 1GB), 2)
}

function Get-FslMntNormalizedPath {
    <# Full path without trailing directory separators (for comparisons). Returns $null on invalid input. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($full)
        if ($full.Length -gt $root.Length) {
            $full = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        }
        return $full
    }
    catch {
        return $null
    }
}

function Test-FslMntPathEqual {
    <# Compares two paths after normalization (case-insensitive on Windows). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $OtherPath
    )

    $a = Get-FslMntNormalizedPath -Path $Path
    $b = Get-FslMntNormalizedPath -Path $OtherPath
    if ($null -eq $a -or $null -eq $b) { return $false }
    $comparison = if (Test-FslIsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    return [string]::Equals($a, $b, $comparison)
}

function Test-FslMntPathUnder {
    <# True when Path equals or is located under ParentPath. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $ParentPath
    )

    $child = Get-FslMntNormalizedPath -Path $Path
    $parent = Get-FslMntNormalizedPath -Path $ParentPath
    if ($null -eq $child -or $null -eq $parent) { return $false }
    $comparison = if (Test-FslIsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if ([string]::Equals($child, $parent, $comparison)) { return $true }
    $prefix = $parent.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    return $child.StartsWith($prefix, $comparison)
}

function Test-FslMntUnauthorizedError {
    <# True when an ErrorRecord/exception chain represents an access-denied condition. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    if ($ErrorRecord.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::PermissionDenied) { return $true }
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [System.UnauthorizedAccessException] -or $exception -is [System.Security.SecurityException]) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Test-FslMntFileInUse {
    <#
    Attempts an exclusive (FileShare.None) read open of a file and closes it immediately.
    Returns InUse = $true (sharing violation), $false (exclusive open succeeded) or $null (could not
    determine), plus AccessDenied when the open failed with UnauthorizedAccessException.
    Nothing is written to the file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LiteralPath
    )

    $inUse = $null
    $accessDenied = $false
    $reason = ''
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($LiteralPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $inUse = $false
        $reason = 'Exclusive open succeeded'
    }
    catch [System.UnauthorizedAccessException] {
        $accessDenied = $true
        $reason = "Access denied: $($_.Exception.Message)"
    }
    catch [System.IO.FileNotFoundException] {
        $reason = 'File not found'
    }
    catch [System.IO.IOException] {
        $inUse = $true
        $reason = "File is in use: $($_.Exception.Message)"
    }
    catch {
        $reason = "Could not test file lock: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    return [pscustomobject]@{
        InUse        = $inUse
        AccessDenied = $accessDenied
        Reason       = $reason
    }
}

function Test-FslMntContainerObject {
    <#
    Validates a Container object (CONTRACT 5.4) against the file system. Returns IsValid, Reason and
    the refreshed FileInfo. Never touches files other than reading metadata.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Container,

        [Parameter(Mandatory)]
        [string[]] $AllowedExtension
    )

    $result = [pscustomobject]@{ IsValid = $false; Reason = ''; File = $null; FullName = $null }
    if ($null -eq $Container) { $result.Reason = 'Container object is null'; return $result }

    foreach ($required in @('FullName', 'FolderPath', 'IsLocked')) {
        if ($null -eq $Container.PSObject.Properties[$required]) {
            $result.Reason = "Input object is missing required Container property '$required'"
            return $result
        }
    }

    $fullName = [string](Get-FslMntPropertyValue -InputObject $Container -Name 'FullName')
    $result.FullName = $fullName
    if ([string]::IsNullOrWhiteSpace($fullName)) { $result.Reason = 'FullName is empty'; return $result }

    try {
        if (-not (Test-Path -LiteralPath $fullName -PathType Leaf)) {
            $result.Reason = 'Container file does not exist (or is not a file)'
            return $result
        }
        $file = Get-Item -LiteralPath $fullName -Force -ErrorAction Stop
    }
    catch {
        $result.Reason = "Container file could not be read: $($_.Exception.Message)"
        return $result
    }

    if ($file -isnot [System.IO.FileInfo]) { $result.Reason = 'Container path is not a file'; return $result }

    $extensionAllowed = $false
    foreach ($extension in $AllowedExtension) {
        if ([string]::Equals($file.Extension, $extension, [System.StringComparison]::OrdinalIgnoreCase)) { $extensionAllowed = $true }
    }
    if (-not $extensionAllowed) {
        $result.Reason = "Extension '$($file.Extension)' is not a container extension ($($AllowedExtension -join ', '))"
        return $result
    }

    $folderPath = [string](Get-FslMntPropertyValue -InputObject $Container -Name 'FolderPath')
    if (-not (Test-FslMntPathEqual -Path $file.DirectoryName -OtherPath $folderPath)) {
        $result.Reason = 'FolderPath does not match the parent folder of FullName'
        return $result
    }

    $result.IsValid = $true
    $result.File = $file
    return $result
}

function Get-FslMntCompactionSettingResult {
    <#
    Reports the FSLogix built-in VHD Disk Compaction setting (VHDCompactDisk, HKLM\SOFTWARE\FSLogix\Apps,
    DWORD, 1 = enabled (default), 0 = disabled) and the start types of the Optimize Drives (defragsvc) and
    Microsoft Storage Spaces SMP (smphost) services that compaction relies on. Info/Warn results only; read-only.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $sources = Get-FslMntSource

    try {
        $settings = @(Get-FslEffectiveSetting -Scope 'Apps')
        $setting = $settings | Where-Object -FilterScript { [string](Get-FslMntPropertyValue -InputObject $_ -Name 'Name') -eq 'VHDCompactDisk' } | Select-Object -First 1
        if ($null -eq $setting) {
            New-FslResult -Category 'Maintenance' -Check 'BuiltInCompaction' -Status 'Info' `
                -Target 'HKLM\SOFTWARE\FSLogix\Apps\VHDCompactDisk' -Value 'Not configured' -Expected '1 (default)' `
                -Message 'VHDCompactDisk is not configured, so the FSLogix default (1, reference-configuration-settings) applies: VHD Disk Compaction is enabled and runs at sign-out for dynamically expanding containers. The VHD Disk Compaction feature is available in FSLogix 2210 (2.9.8361.52326) or later.' `
                -Recommendation 'Built-in compaction normally keeps containers compact at sign-out; offline compaction is mainly useful for containers that are not signed out through FSLogix or where compaction is disabled.' `
                -Source $sources.FslCompactionTroubleshooting -RequiresElevation $false
        }
        else {
            $value = Get-FslMntPropertyValue -InputObject $setting -Name 'Value'
            $origin = [string](Get-FslMntPropertyValue -InputObject $setting -Name 'Source')
            $path = [string](Get-FslMntPropertyValue -InputObject $setting -Name 'RegistryPath')
            $numeric = $null
            $isNumber = [long]::TryParse([string]$value, [ref]$numeric)
            if ($isNumber -and $numeric -eq 1) {
                $message = "VHD Disk Compaction is enabled (VHDCompactDisk = 1, source: $origin)."
                $recommendation = ''
            }
            elseif ($isNumber -and $numeric -eq 0) {
                $message = "VHD Disk Compaction is disabled (VHDCompactDisk = 0, source: $origin). Containers are not compacted at sign-out."
                $recommendation = 'Consider enabling VHDCompactDisk (1) or schedule offline compaction with Invoke-FslContainerShrink.'
            }
            else {
                $message = "VHDCompactDisk has an undocumented value '$value' (source: $origin). Documented values are 1 (enabled, default) and 0 (disabled)."
                $recommendation = 'Set VHDCompactDisk to a documented value.'
            }
            New-FslResult -Category 'Maintenance' -Check 'BuiltInCompaction' -Status 'Info' `
                -Target $(if ($path) { "$path\VHDCompactDisk" } else { 'VHDCompactDisk' }) -Value ([string]$value) -Expected '1 (default)' `
                -Message $message -Recommendation $recommendation -Source $sources.FslConfigSettings -RequiresElevation $false
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context 'Reading VHDCompactDisk via Get-FslEffectiveSetting'
        New-FslResult -Category 'Maintenance' -Check 'BuiltInCompaction' -Status 'Error' -Target 'VHDCompactDisk' `
            -Message "Could not read the VHDCompactDisk setting: $($_.Exception.Message)" -Source $sources.FslConfigSettings -RequiresElevation $false
    }

    # VHD Disk Compaction relies on the Optimize Drives (defragsvc) and Microsoft Storage Spaces SMP (smphost) services.
    # If a service StartupType is Disabled, compaction can't run; Manual or Automatic is required, regardless of whether
    # the service is Running or Stopped (troubleshooting-vhd-disk-compaction). The documented log errors
    # ERROR:00000422 and ERROR:00000102 are not mapped to a specific service there; Event 60 (Admin log) names defragsvc.
    $compactionServices = @(
        [pscustomobject]@{ Name = 'defragsvc'; DisplayName = 'Optimize Drives'; Check = 'OptimizeDrivesService' }
        [pscustomobject]@{ Name = 'smphost'; DisplayName = 'Microsoft Storage Spaces SMP'; Check = 'StorageSpacesSmpService' }
    )
    foreach ($compactionService in $compactionServices) {
        $serviceLabel = "$($compactionService.DisplayName) service ($($compactionService.Name))"
        try {
            $service = Get-Service -Name $compactionService.Name -ErrorAction Stop
            $startType = [string]$service.StartType
            if ($startType -eq 'Disabled') {
                $eventHint = if ($compactionService.Name -eq 'defragsvc') { ' FSLogix logs Event 60 in the Microsoft-FSLogix-Apps/Admin log for a disabled defragsvc.' } else { '' }
                New-FslResult -Category 'Maintenance' -Check $compactionService.Check -Status 'Warn' -Target $compactionService.Name `
                    -Value $startType -Expected 'Manual or Automatic' `
                    -Message "The $serviceLabel is Disabled. FSLogix VHD Disk Compaction relies on the defragsvc and smphost services and can't run while either StartupType is Disabled. The FSLogix log may show ERROR:00000422 or ERROR:00000102.$eventHint" `
                    -Recommendation "Set the $($compactionService.Name) StartupType to Manual or Automatic." -Source $sources.FslCompactionTroubleshooting -RequiresElevation $false
            }
            else {
                New-FslResult -Category 'Maintenance' -Check $compactionService.Check -Status 'Info' -Target $compactionService.Name `
                    -Value $startType -Expected 'Manual or Automatic' `
                    -Message "The $serviceLabel StartupType is $startType." -Source $sources.FslCompactionTroubleshooting -RequiresElevation $false
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "Reading $($compactionService.Name) service start type"
            New-FslResult -Category 'Maintenance' -Check $compactionService.Check -Status 'Error' -Target $compactionService.Name `
                -Message "Could not read the $($serviceLabel): $($_.Exception.Message)" -Source $sources.FslCompactionTroubleshooting -RequiresElevation $false
        }
    }
}

function Test-FslMntDiskImageAttached {
    <# Uses Get-DiskImage (Storage module, MSFT_DiskImage.Attached) to test whether an image is attached. Returns $true/$false/$null. #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ImagePath
    )

    try {
        $image = Get-DiskImage -ImagePath $ImagePath -ErrorAction Stop
        return [bool]$image.Attached
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "Get-DiskImage '$ImagePath'"
        return $null
    }
}

function Invoke-FslMntOptimizeVhd {
    <#
    Compacts a dynamic VHD(X) with the Hyper-V module: Mount-DiskImage -Access ReadOnly -NoDriveLetter,
    Optimize-VHD -Mode Full ("Full" is allowable only if the virtual hard disk is mounted read-only),
    then Dismount-DiskImage in finally. Caller performs ShouldProcess, elevation and lock checks.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ImagePath
    )

    $outcome = [pscustomobject]@{ Success = $false; Method = 'Optimize-VHD -Mode Full (read-only mount)'; Message = '' }
    $mounted = $false
    try {
        $null = Mount-DiskImage -ImagePath $ImagePath -Access ReadOnly -NoDriveLetter -ErrorAction Stop -Confirm:$false -WhatIf:$false
        $mounted = $true
        Optimize-VHD -Path $ImagePath -Mode Full -ErrorAction Stop -Confirm:$false -WhatIf:$false
        $outcome.Success = $true
        $outcome.Message = 'Optimize-VHD completed.'
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "Optimize-VHD '$ImagePath'"
        $outcome.Message = "Optimize-VHD failed: $($_.Exception.Message)"
    }
    finally {
        if ($mounted) {
            try {
                Dismount-DiskImage -ImagePath $ImagePath -ErrorAction Stop -Confirm:$false -WhatIf:$false | Out-Null
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "Dismount-DiskImage '$ImagePath'"
                $outcome.Success = $false
                $outcome.Message = ($outcome.Message + " Dismount failed: $($_.Exception.Message)").Trim()
            }
        }
    }
    return $outcome
}

function Invoke-FslMntDiskPartCompact {
    <#
    Compacts a dynamic VHD(X) with diskpart, using the same script lines as FSLogix Invoke-FslShrinkDisk:
      SELECT VDISK FILE='<path>' / attach vdisk readonly / COMPACT VDISK / detach vdisk
    The script is written to a unique temp folder, run with diskpart /s, output captured, temp removed.
    diskpart exits with an error code on the first failing command (no 'noerr'), so a non-zero exit code
    is treated as failure. Any image still attached afterwards is dismounted in finally.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ImagePath
    )

    $outcome = [pscustomobject]@{ Success = $false; Method = 'diskpart compact vdisk (attached read-only)'; Message = ''; ExitCode = $null }
    $tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('FslMntDiskPart_' + [guid]::NewGuid().ToString('N'))
    try {
        if ($ImagePath.Contains("'") -or $ImagePath.IndexOfAny([char[]]@("`r", "`n")) -ge 0) {
            $outcome.Message = 'Path contains a quote or line-break character that cannot be passed safely to diskpart.'
            return $outcome
        }
        $diskPartExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\diskpart.exe'
        if (-not (Test-Path -LiteralPath $diskPartExe -PathType Leaf)) {
            $outcome.Message = "diskpart.exe was not found at '$diskPartExe'."
            return $outcome
        }

        $null = New-Item -ItemType Directory -Path $tempFolder -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
        $scriptFile = Join-Path -Path $tempFolder -ChildPath 'compact.txt'
        $lines = @(
            "SELECT VDISK FILE='$ImagePath'"
            'attach vdisk readonly'
            'COMPACT VDISK'
            'detach vdisk'
        )
        Set-Content -LiteralPath $scriptFile -Value $lines -Encoding ansi -ErrorAction Stop -WhatIf:$false -Confirm:$false

        $output = & $diskPartExe /s $scriptFile 2>&1
        $outcome.ExitCode = $LASTEXITCODE
        $outputText = (@($output) | ForEach-Object -Process { [string]$_ } | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | '
        Write-FslLog -Message "diskpart exit code $($outcome.ExitCode) for '$ImagePath': $outputText" -Level Debug -Component 'Maintenance'

        if ($outcome.ExitCode -eq 0) {
            $outcome.Success = $true
            $outcome.Message = 'diskpart compact vdisk completed.'
        }
        else {
            $lastLines = (@($output) | ForEach-Object -Process { [string]$_ } | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 3) -join ' '
            $outcome.Message = "diskpart failed with exit code $($outcome.ExitCode): $lastLines"
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "diskpart compact '$ImagePath'"
        $outcome.Message = "diskpart could not be run: $($_.Exception.Message)"
    }
    finally {
        $attached = Test-FslMntDiskImageAttached -ImagePath $ImagePath
        if ($attached -eq $true) {
            try {
                Dismount-DiskImage -ImagePath $ImagePath -ErrorAction Stop -Confirm:$false -WhatIf:$false | Out-Null
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "Dismount-DiskImage '$ImagePath' after diskpart"
                $outcome.Success = $false
                $outcome.Message = ($outcome.Message + " Disk image is still attached and could not be dismounted: $($_.Exception.Message)").Trim()
            }
        }
        if (Test-Path -LiteralPath $tempFolder) {
            try { Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false }
            catch { Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "Removing temp folder '$tempFolder'" }
        }
    }
    return $outcome
}
