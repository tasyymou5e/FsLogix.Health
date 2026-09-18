function Invoke-FslContainerShrink {
    <#
    .SYNOPSIS
        Compacts (shrinks the file size of) offline FSLogix VHD/VHDX containers.

    .DESCRIPTION
        Discovers containers with Get-FslContainer and compacts each eligible dynamically expanding
        VHD(X) file so that unused blocks are released from the file on the storage.

        Method (verified end-to-end on learn.microsoft.com):
          * When the Hyper-V module's Optimize-VHD cmdlet is available: Mount-DiskImage -Access ReadOnly
            -NoDriveLetter, Optimize-VHD -Mode Full (Full mode is only allowed while the disk is mounted
            read-only), Dismount-DiskImage in a finally block.
          * Otherwise: diskpart /s with the same script used by FSLogix Invoke-FslShrinkDisk
            (select vdisk / attach vdisk readonly / compact vdisk / detach vdisk). diskpart ships with
            Windows. The temporary script folder is always deleted and any image left attached is dismounted.
        The partition is NOT resized and the volume inside the disk is NOT defragmented; the disk contents
        are only ever attached read-only.

        Safety:
          * Requires Windows and an elevated session (mounting VHDs and diskpart need administrators);
            otherwise a Skipped result is returned.
          * Skips containers whose IsLocked is not $false (locked or unknown), files that are already
            attached (Get-DiskImage Attached), files that cannot be opened exclusively, and any object that
            fails validation (missing file, wrong extension, FolderPath mismatch).
          * SupportsShouldProcess with ConfirmImpact High; -WhatIf lists what would be compacted.
          * Records SizeBytes before and after and the reclaimed GB.

        The function also reports whether FSLogix built-in VHD Disk Compaction (VHDCompactDisk) is enabled
        and the start types of the Optimize Drives (defragsvc) and Microsoft Storage Spaces SMP (smphost)
        services it relies on, as Info/Warn results.

    .PARAMETER Path
        One or more storage paths passed to Get-FslContainer. When omitted, Get-FslContainer uses the
        configured FSLogix storage locations.

    .PARAMETER MinimumSizeGB
        Only containers whose current file size is at least this many GB are processed.
        Toolkit default: Maintenance.ShrinkMinimumSizeGB in Config/Settings.psd1.

    .PARAMETER DaysSinceLastWrite
        Only containers not written for at least this many days are processed.
        Toolkit default: Maintenance.ShrinkDaysSinceWrite in Config/Settings.psd1.

    .PARAMETER Scope
        Container scopes to process: Profiles, ODFC. When supplied it is passed to Get-FslContainer -Scope, so only
        containers of those scopes are discovered (containers whose scope is Unknown are then not processed).
        When omitted, all discovered containers are considered, as before.
        Per-container results carry the container Scope (Unknown -> General); other results carry the scope when
        exactly one scope is supplied, otherwise General.

    .EXAMPLE
        Invoke-FslContainerShrink -Path '\\fileserver\profiles' -WhatIf

        Lists the containers that would be compacted without changing anything.

    .EXAMPLE
        Invoke-FslContainerShrink -Path '\\fileserver\profiles' -MinimumSizeGB 10 -DaysSinceLastWrite 1 -Confirm:$false |
            Export-FslReport -Format Html

        Compacts containers of at least 10 GB that were not written in the last day and exports a report.

    .NOTES
        RequiresElevation: Yes (Mount-DiskImage/Dismount-DiskImage of VHDs and diskpart require administrator rights).
        FSLogix built-in compaction (VHDCompactDisk, HKLM\SOFTWARE\FSLogix\Apps, default 1) runs at sign-out; the VHD Disk
        Compaction feature is available in FSLogix 2210 (2.9.8361.52326) or later
        (https://learn.microsoft.com/en-us/fslogix/troubleshooting-vhd-disk-compaction). Only dynamically expanding
        disks are compacted; fixed-size disks cannot be compacted.
        Sources:
          https://learn.microsoft.com/en-us/fslogix/troubleshooting-vhd-disk-compaction
          https://learn.microsoft.com/en-us/fslogix/concepts-vhd-disk-compaction
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
          https://learn.microsoft.com/en-us/powershell/module/hyper-v/optimize-vhd
          https://learn.microsoft.com/en-us/powershell/module/storage/mount-diskimage
          https://learn.microsoft.com/en-us/powershell/module/storage/dismount-diskimage
          https://learn.microsoft.com/en-us/powershell/module/storage/get-diskimage
          https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-diskimage
          https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/diskpart
          https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/select-vdisk
          https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/attach-vdisk
          https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/compact-vdisk
          https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/detach-vdisk
          https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/install-hyper-v
          https://github.com/FSLogix/Invoke-FslShrinkDisk
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path,

        [Parameter()]
        [ValidateRange(0, 1048576)]
        [double] $MinimumSizeGB,

        [Parameter()]
        [ValidateRange(0, 36500)]
        [int] $DaysSinceLastWrite,

        [Parameter()]
        [ValidateSet('Profiles', 'ODFC')]
        [string[]] $Scope
    )

    $sources = Get-FslMntSource
    $category = 'Maintenance'
    $check = 'ContainerShrink'
    $scopeBound = $PSBoundParameters.ContainsKey('Scope')
    $requestedScopes = @($Scope | Where-Object -FilterScript { $null -ne $_ } | Select-Object -Unique)
    $runScope = if ($scopeBound -and $requestedScopes.Count -eq 1) { [string]$requestedScopes[0] } else { 'General' }

    if (-not $PSBoundParameters.ContainsKey('MinimumSizeGB')) {
        $MinimumSizeGB = [double](Get-FslMntConfigValue -Section 'Maintenance' -Name 'ShrinkMinimumSizeGB' -Default 5)
    }
    if (-not $PSBoundParameters.ContainsKey('DaysSinceLastWrite')) {
        $DaysSinceLastWrite = [int](Get-FslMntConfigValue -Section 'Maintenance' -Name 'ShrinkDaysSinceWrite' -Default 0)
    }

    if (-not (Test-FslIsWindows)) {
        New-FslResult -Category $category -Check $check -Status 'Skipped' -Target 'Local computer' `
            -Message 'Container compaction requires Windows (Storage module disk image cmdlets, diskpart or Hyper-V Optimize-VHD).' `
            -Source $sources.FslCompaction -RequiresElevation $true -Scope $runScope
        return
    }

    # Built-in FSLogix compaction status (read-only, no elevation needed).
    Get-FslMntCompactionSettingResult

    if (-not (Assert-FslElevation -Operation 'Invoke-FslContainerShrink (mount and compact VHD files)')) {
        New-FslResult -Category $category -Check $check -Status 'Skipped' -Target 'Local computer' `
            -Message 'Compacting containers requires an elevated (Run as administrator) session: mounting VHD files and running diskpart require administrator rights.' `
            -Recommendation 'Run PowerShell as administrator and try again.' -Source $sources.MountDiskImage -RequiresElevation $true -Scope $runScope
        return
    }

    # Choose method.
    $useOptimizeVhd = $null -ne (Get-Command -Name 'Optimize-VHD' -CommandType Cmdlet, Function -ErrorAction SilentlyContinue)
    $hasDiskImageCmdlets = ($null -ne (Get-Command -Name 'Get-DiskImage' -ErrorAction SilentlyContinue)) -and
        ($null -ne (Get-Command -Name 'Dismount-DiskImage' -ErrorAction SilentlyContinue)) -and
        ($null -ne (Get-Command -Name 'Mount-DiskImage' -ErrorAction SilentlyContinue))
    if (-not $hasDiskImageCmdlets) {
        New-FslResult -Category $category -Check $check -Status 'Skipped' -Target 'Local computer' `
            -Message 'The Storage module disk image cmdlets (Get-DiskImage, Mount-DiskImage, Dismount-DiskImage) are not available.' `
            -Recommendation 'Run on a Windows edition that includes the Storage module.' -Source $sources.GetDiskImage -RequiresElevation $true -Scope $runScope
        return
    }
    $methodName = if ($useOptimizeVhd) { 'Optimize-VHD -Mode Full (Hyper-V module, read-only mount)' } else { 'diskpart compact vdisk (attached read-only)' }
    $methodSource = if ($useOptimizeVhd) { $sources.OptimizeVhd } else { $sources.CompactVdisk }
    $methodMessage = "Compaction method: $methodName."
    if (-not $useOptimizeVhd) {
        $methodMessage += ' InstallHint: the Hyper-V PowerShell module (Optimize-VHD) is installed with the Hyper-V feature/management tools; it is optional because diskpart is used instead.'
    }
    New-FslResult -Category $category -Check 'ShrinkMethod' -Status 'Info' -Target 'Local computer' -Value $methodName `
        -Message $methodMessage -Source $methodSource -RequiresElevation $true -Scope $runScope

    # Discover containers.
    $containers = @()
    try {
        $containerParameters = @{}
        if ($PSBoundParameters.ContainsKey('Path')) { $containerParameters['Path'] = $Path }
        if ($scopeBound) { $containerParameters['Scope'] = $requestedScopes }
        $containers = @(Get-FslContainer @containerParameters)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context 'Get-FslContainer for shrink'
        New-FslResult -Category $category -Check $check -Status 'Error' -Target $(if ($Path) { $Path -join '; ' } else { 'Configured storage locations' }) `
            -Message "Container discovery failed: $($_.Exception.Message)" -Source 'Toolkit default' -RequiresElevation $true -Scope $runScope
        return
    }

    $extensions = @(Get-FslMntConfigValue -Section 'Containers' -Name 'Extensions' -Default @('.vhd', '.vhdx'))
    $minimumBytes = [long]($MinimumSizeGB * 1GB)
    $processed = 0
    $succeeded = 0
    $skipped = 0
    $failed = 0
    [long] $totalReclaimed = 0

    if ($containers.Count -eq 0) {
        New-FslResult -Category $category -Check $check -Status 'Info' -Target $(if ($Path) { $Path -join '; ' } else { 'Configured storage locations' }) `
            -Message 'No containers were found.' -Source 'Toolkit default' -RequiresElevation $true -Scope $runScope
        return
    }

    foreach ($container in $containers) {
        $containerScope = ConvertTo-FslMntResultScope -Scope ([string](Get-FslMntPropertyValue -InputObject $container -Name 'Scope'))
        $validation = Test-FslMntContainerObject -Container $container -AllowedExtension $extensions
        $target = if ($validation.FullName) { $validation.FullName } else { '<invalid object>' }
        if (-not $validation.IsValid) {
            $skipped++
            New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $target `
                -Message "Not processed - validation failed: $($validation.Reason)" -Source 'Toolkit default' -RequiresElevation $true -Scope $containerScope
            continue
        }

        $file = $validation.File
        [long] $beforeBytes = $file.Length
        $daysSinceWrite = [int][math]::Floor(((Get-Date) - $file.LastWriteTime).TotalDays)
        $isLocked = Get-FslMntPropertyValue -InputObject $container -Name 'IsLocked'

        if ($beforeBytes -lt $minimumBytes) {
            $skipped++
            New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $target -Value "$(ConvertTo-FslMntGigabyte -Bytes $beforeBytes) GB" `
                -Expected ">= $MinimumSizeGB GB" -Message 'Container is smaller than MinimumSizeGB.' -Source 'Toolkit default' -RequiresElevation $true -Scope $containerScope
            continue
        }
        if ($daysSinceWrite -lt $DaysSinceLastWrite) {
            $skipped++
            New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $target -Value "$daysSinceWrite days" `
                -Expected ">= $DaysSinceLastWrite days" -Message 'Container was written more recently than DaysSinceLastWrite.' -Source 'Toolkit default' -RequiresElevation $true -Scope $containerScope
            continue
        }
        if ($isLocked -ne $false) {
            $skipped++
            $lockText = if ($null -eq $isLocked) { 'unknown' } else { [string]$isLocked }
            New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $target -Value "IsLocked=$lockText" -Expected 'IsLocked=False' `
                -Message 'Container is locked or its lock state is unknown; it was not touched.' -Source 'Toolkit default' -RequiresElevation $true -Scope $containerScope
            continue
        }
        if (-not $useOptimizeVhd -and ($target.Contains("'") -or $target.IndexOfAny([char[]]@("`r", "`n")) -ge 0)) {
            $skipped++
            New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $target `
                -Message 'Path contains a quote or line-break character that cannot be passed safely to diskpart.' -Source $sources.CompactVdisk -RequiresElevation $true -Scope $containerScope
            continue
        }

        $action = "Compact virtual disk using $methodName (size $(ConvertTo-FslMntGigabyte -Bytes $beforeBytes) GB)"
        if (-not $PSCmdlet.ShouldProcess($target, $action)) {
            $skipped++
            $whatIfMessage = if ($WhatIfPreference) { "WhatIf: would compact this container using $methodName." } else { 'Compaction was not confirmed.' }
            New-FslResult -Category $category -Check $check -Status $(if ($WhatIfPreference) { 'Info' } else { 'Skipped' }) -Target $target `
                -Value "$beforeBytes bytes" -Message $whatIfMessage -Source $methodSource -RequiresElevation $true -Scope $containerScope
            continue
        }

        # Re-check right before acting: exclusive open and attach state.
        $lockTest = Test-FslMntFileInUse -LiteralPath $target
        if ($lockTest.InUse -ne $false) {
            $skipped++
            New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $target `
                -Message "Container could not be opened exclusively; it was not touched. $($lockTest.Reason)" -Source 'Toolkit default' -RequiresElevation $true -Scope $containerScope
            continue
        }
        $attached = Test-FslMntDiskImageAttached -ImagePath $target
        if ($attached -ne $false) {
            $skipped++
            $attachText = if ($null -eq $attached) { 'unknown' } else { 'attached' }
            New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $target -Value "Attach state: $attachText" `
                -Message 'Disk image is attached or its attach state could not be read; it was not touched.' -Source $sources.GetDiskImage -RequiresElevation $true -Scope $containerScope
            continue
        }

        $processed++
        Write-FslLog -Message "Compacting '$target' ($beforeBytes bytes) using $methodName" -Level Info -Component 'Maintenance'
        try {
            $outcome = if ($useOptimizeVhd) { Invoke-FslMntOptimizeVhd -ImagePath $target } else { Invoke-FslMntDiskPartCompact -ImagePath $target }
            $file.Refresh()
            [long] $afterBytes = $file.Length
            [long] $reclaimed = $beforeBytes - $afterBytes
            $value = "Before: $beforeBytes bytes ($(ConvertTo-FslMntGigabyte -Bytes $beforeBytes) GB); After: $afterBytes bytes ($(ConvertTo-FslMntGigabyte -Bytes $afterBytes) GB); Reclaimed: $(ConvertTo-FslMntGigabyte -Bytes $reclaimed) GB"
            if ($outcome.Success) {
                $succeeded++
                if ($reclaimed -gt 0) { $totalReclaimed += $reclaimed }
                $message = if ($reclaimed -gt 0) { "$($outcome.Message) Reclaimed $(ConvertTo-FslMntGigabyte -Bytes $reclaimed) GB." } else { "$($outcome.Message) No space was reclaimed (a compact can succeed without reducing the file size)." }
                New-FslResult -Category $category -Check $check -Status 'Pass' -Target $target -Value $value `
                    -Message $message -Source $methodSource -RequiresElevation $true -Scope $containerScope
            }
            else {
                $failed++
                New-FslResult -Category $category -Check $check -Status 'Error' -Target $target -Value $value `
                    -Message $outcome.Message -Recommendation 'Only dynamically expanding VHD(X) files that are not in use can be compacted. Review the toolkit error log.' `
                    -Source $methodSource -RequiresElevation $true -Scope $containerScope
            }
        }
        catch {
            $failed++
            Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "Compacting '$target'"
            New-FslResult -Category $category -Check $check -Status 'Error' -Target $target -Value "Before: $beforeBytes bytes" `
                -Message "Compaction failed: $($_.Exception.Message)" -Source $methodSource -RequiresElevation $true -Scope $containerScope
        }
        finally {
            # Defensive: never leave the image attached.
            if ((Test-FslMntDiskImageAttached -ImagePath $target) -eq $true) {
                try { Dismount-DiskImage -ImagePath $target -ErrorAction Stop -Confirm:$false -WhatIf:$false | Out-Null }
                catch { Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "Final Dismount-DiskImage '$target'" }
            }
        }
    }

    New-FslResult -Category $category -Check 'ShrinkSummary' -Status 'Info' -Target $(if ($Path) { $Path -join '; ' } else { 'Configured storage locations' }) `
        -Value "Found: $($containers.Count); Processed: $processed; Succeeded: $succeeded; Failed: $failed; Skipped: $skipped; Reclaimed: $(ConvertTo-FslMntGigabyte -Bytes $totalReclaimed) GB" `
        -Expected "MinimumSizeGB >= $MinimumSizeGB; DaysSinceLastWrite >= $DaysSinceLastWrite (toolkit defaults unless specified)" `
        -Message "Container compaction finished. Total reclaimed: $(ConvertTo-FslMntGigabyte -Bytes $totalReclaimed) GB." -Source $methodSource -RequiresElevation $true -Scope $runScope
}
