function Remove-FslStaleContainer {
    <#
    .SYNOPSIS
        Archives or deletes stale (and optionally orphaned) FSLogix containers.

    .DESCRIPTION
        Takes Container objects from Get-FslContainer (pipeline or -Container) or discovers them with
        Get-FslContainer, and selects containers whose file has not been written for at least StaleDays
        days (re-read from the file system) and, with -OrphanedOnly, whose AccountStatus is Orphaned.

        * With -ArchivePath: the whole user folder is moved to ArchivePath, keeping the folder name
          (Move-Item -LiteralPath; ArchivePath is created when missing). A folder is moved only when every
          VHD/VHDX file in it is eligible; an existing destination folder is never overwritten. When a
          container file sits directly in its storage location root, only the file is moved.
        * Without -ArchivePath: the container file is deleted with Remove-Item, and its folder is deleted only
          when it is empty afterwards (never a storage location root).

        Safety: containers whose IsLocked is not $false (locked or unknown) are never touched; objects that
        fail validation are never touched; each file is opened exclusively (read-only, then closed) right
        before acting to confirm it is not in use. ShouldProcess (ConfirmImpact High) is called per item and
        -WhatIf is honored. Elevation is not required up front: access-denied failures are reported as
        Skipped with RequiresElevation = $true.

        Result Scope: results about a single container carry the container Scope (Unknown -> General); results
        about a user folder carry the scope shared by all its eligible containers (mixed -> General); discovery
        errors and the summary are General. Microsoft Entra ID SIDs (S-1-12-1-...) are never reported Orphaned by
        Get-FslContainer, so -OrphanedOnly never selects them.

    .PARAMETER Container
        Container objects (FSLogixToolkit.Container) from Get-FslContainer. When omitted, Get-FslContainer
        is called with its defaults.

    .PARAMETER StaleDays
        Minimum number of days since the container file was last written.
        Toolkit default: Containers.StaleDays in Config/Settings.psd1.

    .PARAMETER OrphanedOnly
        Only process containers whose AccountStatus is Orphaned (the SID no longer resolves to an account).

    .PARAMETER ArchivePath
        Folder to move stale user folders into instead of deleting them.

    .EXAMPLE
        Get-FslContainer -Path '\\fileserver\profiles' | Remove-FslStaleContainer -StaleDays 180 -WhatIf

        Shows which containers would be deleted.

    .EXAMPLE
        Remove-FslStaleContainer -StaleDays 120 -OrphanedOnly -ArchivePath '\\fileserver\archive\profiles'

        Moves orphaned user folders not written for 120 days into the archive share (with confirmation).

    .NOTES
        RequiresElevation: No (only when the current account lacks rights on the share; reported per item).
        Toolkit defaults (StaleDays) are not Microsoft guidance.
        Sources:
          https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/move-item
          https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/remove-item
          https://learn.microsoft.com/en-us/dotnet/api/system.io.fileshare
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowEmptyCollection()]
        [object[]] $Container,

        [Parameter()]
        [ValidateRange(0, 36500)]
        [int] $StaleDays,

        [Parameter()]
        [switch] $OrphanedOnly,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ArchivePath
    )

    begin {
        $sources = Get-FslMntSource
        $category = 'Maintenance'
        $check = 'StaleContainerRemoval'
        $collected = [System.Collections.Generic.List[object]]::new()
        # Pipeline input (even an empty pipeline) or -Container means: never fall back to discovery.
        $containerSupplied = $PSBoundParameters.ContainsKey('Container') -or $MyInvocation.ExpectingInput
    }

    process {
        if ($PSBoundParameters.ContainsKey('Container')) {
            $containerSupplied = $true
            foreach ($item in @($Container)) {
                if ($null -ne $item) { $collected.Add($item) }
            }
        }
    }

    end {
        if (-not $PSBoundParameters.ContainsKey('StaleDays')) {
            $StaleDays = [int](Get-FslMntConfigValue -Section 'Containers' -Name 'StaleDays' -Default 90)
        }
        $extensions = @(Get-FslMntConfigValue -Section 'Containers' -Name 'Extensions' -Default @('.vhd', '.vhdx'))
        $actionSource = if ($ArchivePath) { $sources.MoveItem } else { $sources.RemoveItem }
        $filterText = "DaysSinceLastWrite >= $StaleDays" + $(if ($OrphanedOnly) { '; AccountStatus = Orphaned' } else { '' })

        if (-not $containerSupplied) {
            try {
                foreach ($item in @(Get-FslContainer)) {
                    if ($null -ne $item) { $collected.Add($item) }
                }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context 'Get-FslContainer for stale container removal'
                New-FslResult -Category $category -Check $check -Status 'Error' -Target 'Configured storage locations' `
                    -Message "Container discovery failed: $($_.Exception.Message)" -Source 'Toolkit default' -RequiresElevation $false
                return
            }
        }

        $archiveFull = $null
        if ($ArchivePath) {
            $archiveFull = Get-FslMntNormalizedPath -Path $ArchivePath
            if ($null -eq $archiveFull) {
                New-FslResult -Category $category -Check $check -Status 'Error' -Target $ArchivePath `
                    -Message 'ArchivePath is not a valid path.' -Source $sources.MoveItem -RequiresElevation $false
                return
            }
            if (Test-Path -LiteralPath $archiveFull -PathType Leaf) {
                New-FslResult -Category $category -Check $check -Status 'Error' -Target $archiveFull `
                    -Message 'ArchivePath points to an existing file, not a folder.' -Source $sources.MoveItem -RequiresElevation $false
                return
            }
        }

        $eligible = [System.Collections.Generic.List[object]]::new()
        $notEligible = 0
        $skipped = 0
        $done = 0
        $failed = 0

        foreach ($item in $collected) {
            $itemScope = ConvertTo-FslMntResultScope -Scope ([string](Get-FslMntPropertyValue -InputObject $item -Name 'Scope'))
            $validation = Test-FslMntContainerObject -Container $item -AllowedExtension $extensions
            $target = if ($validation.FullName) { $validation.FullName } else { '<invalid object>' }
            if (-not $validation.IsValid) {
                $skipped++
                New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $target `
                    -Message "Not processed - validation failed: $($validation.Reason)" -Source 'Toolkit default' -RequiresElevation $false -Scope $itemScope
                continue
            }

            $file = $validation.File
            $days = [int][math]::Floor(((Get-Date) - $file.LastWriteTime).TotalDays)
            $accountStatus = [string](Get-FslMntPropertyValue -InputObject $item -Name 'AccountStatus')
            if ($days -lt $StaleDays -or ($OrphanedOnly -and $accountStatus -ne 'Orphaned')) {
                $notEligible++
                continue
            }

            $isLocked = Get-FslMntPropertyValue -InputObject $item -Name 'IsLocked'
            if ($isLocked -ne $false) {
                $skipped++
                $lockText = if ($null -eq $isLocked) { 'unknown' } else { [string]$isLocked }
                New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $target -Value "IsLocked=$lockText" -Expected 'IsLocked=False' `
                    -Message 'Container is locked or its lock state is unknown; it was not touched.' -Source 'Toolkit default' -RequiresElevation $false -Scope $itemScope
                continue
            }

            if ($archiveFull -and (Test-FslMntPathUnder -Path $archiveFull -ParentPath $file.DirectoryName)) {
                $skipped++
                New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $target -Value $archiveFull `
                    -Message 'ArchivePath is inside the container folder; the folder cannot be moved into itself.' -Source $sources.MoveItem -RequiresElevation $false -Scope $itemScope
                continue
            }

            $eligible.Add([pscustomobject]@{
                    Container       = $item
                    File            = $file
                    Days            = $days
                    UserName        = [string](Get-FslMntPropertyValue -InputObject $item -Name 'UserName')
                    AccountStatus   = $accountStatus
                    StorageLocation = [string](Get-FslMntPropertyValue -InputObject $item -Name 'StorageLocation')
                    Scope           = $itemScope
                })
        }

        if ($ArchivePath) {
            # Archive: one operation per user folder.
            $groups = $eligible | Group-Object -Property { Get-FslMntNormalizedPath -Path $_.File.DirectoryName }
            foreach ($group in $groups) {
                $folder = [string]$group.Name
                $members = @($group.Group)
                $memberNames = @($members | ForEach-Object -Process { $_.File.FullName })
                $description = ($members | ForEach-Object -Process { "$($_.File.Name) (User: $($_.UserName); $($_.Days) days; $($_.AccountStatus))" }) -join ', '
                $memberScopes = @($members | ForEach-Object -Process { [string]$_.Scope } | Select-Object -Unique)
                $groupScope = if ($memberScopes.Count -eq 1) { $memberScopes[0] } else { 'General' }

                try {
                    # Folder is a storage root (or has no parent)? Then move only the files.
                    $parent = [System.IO.Path]::GetDirectoryName($folder)
                    $isRoot = [string]::IsNullOrEmpty($parent) -or
                        @($members | Where-Object -FilterScript { Test-FslMntPathEqual -Path $_.StorageLocation -OtherPath $folder }).Count -gt 0

                    # All container files in the folder must be eligible before the folder is moved.
                    if (-not $isRoot) {
                        $folderContainers = @(Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction Stop |
                                Where-Object -FilterScript { $extensions -contains $_.Extension.ToLowerInvariant() })
                        $notCovered = @($folderContainers | Where-Object -FilterScript {
                                $candidate = $_.FullName
                                -not ($memberNames | Where-Object -FilterScript { Test-FslMntPathEqual -Path $_ -OtherPath $candidate })
                            })
                        if ($notCovered.Count -gt 0) {
                            $skipped += $members.Count
                            New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $folder `
                                -Value (($notCovered | ForEach-Object -Process { $_.Name }) -join '; ') `
                                -Message 'Folder also contains container files that are not eligible (not stale, not orphaned, locked or invalid); the folder was not moved.' `
                                -Source 'Toolkit default' -RequiresElevation $false -Scope $groupScope
                            continue
                        }
                    }

                    # Confirm nothing is in use right before acting.
                    $blocked = $null
                    foreach ($member in $members) {
                        $lockTest = Test-FslMntFileInUse -LiteralPath $member.File.FullName
                        if ($lockTest.InUse -ne $false) { $blocked = [pscustomobject]@{ File = $member.File.FullName; Test = $lockTest }; break }
                    }
                    if ($null -ne $blocked) {
                        $skipped += $members.Count
                        New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $blocked.File `
                            -Message "Container could not be opened exclusively; nothing in this folder was moved. $($blocked.Test.Reason)" `
                            -Source 'Toolkit default' -RequiresElevation ([bool]$blocked.Test.AccessDenied) -Scope $groupScope
                        continue
                    }

                    if ($isRoot) {
                        foreach ($member in $members) {
                            $destination = Join-Path -Path $archiveFull -ChildPath $member.File.Name
                            if (Test-Path -LiteralPath $destination) {
                                $skipped++
                                New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $member.File.FullName -Value $destination `
                                    -Message 'Destination already exists in ArchivePath; nothing was overwritten.' -Source $sources.MoveItem -RequiresElevation $false -Scope $member.Scope
                                continue
                            }
                            $action = "Move stale container file (User: $($member.UserName); $($member.Days) days; $($member.AccountStatus)) to '$destination'"
                            if (-not $PSCmdlet.ShouldProcess($member.File.FullName, $action)) {
                                $skipped++
                                New-FslResult -Category $category -Check $check -Status $(if ($WhatIfPreference) { 'Info' } else { 'Skipped' }) -Target $member.File.FullName -Value $destination `
                                    -Message $(if ($WhatIfPreference) { "WhatIf: would move the container file to the archive ($filterText)." } else { 'Move was not confirmed.' }) `
                                    -Source $sources.MoveItem -RequiresElevation $false -Scope $member.Scope
                                continue
                            }
                            try {
                                if (-not (Test-Path -LiteralPath $archiveFull -PathType Container)) {
                                    $null = New-Item -ItemType Directory -Path $archiveFull -Force -ErrorAction Stop -Confirm:$false
                                }
                                Move-Item -LiteralPath $member.File.FullName -Destination $destination -ErrorAction Stop -Confirm:$false
                                $done++
                                Write-FslLog -Message "Moved stale container '$($member.File.FullName)' to '$destination'" -Level Info -Component 'Maintenance'
                                New-FslResult -Category $category -Check $check -Status 'Pass' -Target $member.File.FullName -Value $destination `
                                    -Message "Stale container file moved to the archive ($($member.Days) days since last write; $($member.AccountStatus))." `
                                    -Source $sources.MoveItem -RequiresElevation $false -Scope $member.Scope
                            }
                            catch {
                                if (Test-FslMntUnauthorizedError -ErrorRecord $_) {
                                    $skipped++
                                    Write-FslLog -Message "Access denied moving '$($member.File.FullName)': $($_.Exception.Message)" -Level Warning -Component 'Maintenance'
                                    New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $member.File.FullName -Value $destination `
                                        -Message "Access denied: $($_.Exception.Message)" -Recommendation 'Run with an account that has modify rights on the share and archive (for example an elevated session).' `
                                        -Source $sources.MoveItem -RequiresElevation $true -Scope $member.Scope
                                }
                                else {
                                    $failed++
                                    Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "Moving '$($member.File.FullName)' to archive"
                                    New-FslResult -Category $category -Check $check -Status 'Error' -Target $member.File.FullName -Value $destination `
                                        -Message "Move failed: $($_.Exception.Message)" -Source $sources.MoveItem -RequiresElevation $false -Scope $member.Scope
                                }
                            }
                        }
                        continue
                    }

                    $folderName = Split-Path -Path $folder -Leaf
                    $destination = Join-Path -Path $archiveFull -ChildPath $folderName
                    if (Test-Path -LiteralPath $destination) {
                        $skipped += $members.Count
                        New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $folder -Value $destination `
                            -Message 'A folder with the same name already exists in ArchivePath; nothing was overwritten.' -Source $sources.MoveItem -RequiresElevation $false -Scope $groupScope
                        continue
                    }

                    $action = "Move stale user folder containing $description to '$destination'"
                    if (-not $PSCmdlet.ShouldProcess($folder, $action)) {
                        $skipped += $members.Count
                        New-FslResult -Category $category -Check $check -Status $(if ($WhatIfPreference) { 'Info' } else { 'Skipped' }) -Target $folder -Value $destination `
                            -Message $(if ($WhatIfPreference) { "WhatIf: would move the user folder to the archive: $description ($filterText)." } else { 'Move was not confirmed.' }) `
                            -Source $sources.MoveItem -RequiresElevation $false -Scope $groupScope
                        continue
                    }

                    if (-not (Test-Path -LiteralPath $archiveFull -PathType Container)) {
                        $null = New-Item -ItemType Directory -Path $archiveFull -Force -ErrorAction Stop -Confirm:$false
                    }
                    Move-Item -LiteralPath $folder -Destination $destination -ErrorAction Stop -Confirm:$false
                    $done += $members.Count
                    Write-FslLog -Message "Moved stale user folder '$folder' to '$destination'" -Level Info -Component 'Maintenance'
                    New-FslResult -Category $category -Check $check -Status 'Pass' -Target $folder -Value $destination `
                        -Message "Stale user folder moved to the archive: $description." -Source $sources.MoveItem -RequiresElevation $false -Scope $groupScope
                }
                catch {
                    if (Test-FslMntUnauthorizedError -ErrorRecord $_) {
                        $skipped += $members.Count
                        Write-FslLog -Message "Access denied archiving '$folder': $($_.Exception.Message)" -Level Warning -Component 'Maintenance'
                        New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $folder `
                            -Message "Access denied: $($_.Exception.Message)" -Recommendation 'Run with an account that has modify rights on the share and archive (for example an elevated session).' `
                            -Source $sources.MoveItem -RequiresElevation $true -Scope $groupScope
                    }
                    else {
                        $failed += $members.Count
                        Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "Archiving folder '$folder'"
                        New-FslResult -Category $category -Check $check -Status 'Error' -Target $folder `
                            -Message "Archive failed: $($_.Exception.Message)" -Source $sources.MoveItem -RequiresElevation $false -Scope $groupScope
                    }
                }
            }
        }
        else {
            # Delete: one operation per container file.
            foreach ($member in $eligible) {
                $target = $member.File.FullName
                $folder = $member.File.DirectoryName
                $action = "Delete stale container (User: $($member.UserName); $($member.Days) days; $($member.AccountStatus); $(ConvertTo-FslMntGigabyte -Bytes $member.File.Length) GB) and its folder if left empty"
                if (-not $PSCmdlet.ShouldProcess($target, $action)) {
                    $skipped++
                    New-FslResult -Category $category -Check $check -Status $(if ($WhatIfPreference) { 'Info' } else { 'Skipped' }) -Target $target `
                        -Value "$($member.Days) days" -Message $(if ($WhatIfPreference) { "WhatIf: would delete this container ($filterText)." } else { 'Deletion was not confirmed.' }) `
                        -Source $sources.RemoveItem -RequiresElevation $false -Scope $member.Scope
                    continue
                }

                $lockTest = Test-FslMntFileInUse -LiteralPath $target
                if ($lockTest.InUse -ne $false) {
                    $skipped++
                    New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $target `
                        -Message "Container could not be opened exclusively; it was not deleted. $($lockTest.Reason)" `
                        -Source 'Toolkit default' -RequiresElevation ([bool]$lockTest.AccessDenied) -Scope $member.Scope
                    continue
                }

                try {
                    Remove-Item -LiteralPath $target -ErrorAction Stop -Confirm:$false
                    $done++
                    Write-FslLog -Message "Deleted stale container '$target'" -Level Info -Component 'Maintenance'
                    $folderMessage = ''
                    $isRoot = Test-FslMntPathEqual -Path $member.StorageLocation -OtherPath $folder
                    if (-not $isRoot -and (Test-Path -LiteralPath $folder -PathType Container)) {
                        try {
                            $remaining = @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop)
                            if ($remaining.Count -eq 0) {
                                Remove-Item -LiteralPath $folder -ErrorAction Stop -Confirm:$false
                                $folderMessage = ' The empty user folder was removed.'
                            }
                            else {
                                $folderMessage = " The user folder was kept because it still contains $($remaining.Count) item(s)."
                            }
                        }
                        catch {
                            Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "Removing empty folder '$folder'"
                            $folderMessage = " The user folder could not be removed: $($_.Exception.Message)"
                        }
                    }
                    New-FslResult -Category $category -Check $check -Status 'Pass' -Target $target -Value "$($member.Days) days" `
                        -Message "Stale container deleted ($($member.AccountStatus)).$folderMessage" -Source $sources.RemoveItem -RequiresElevation $false -Scope $member.Scope
                }
                catch {
                    if (Test-FslMntUnauthorizedError -ErrorRecord $_) {
                        $skipped++
                        Write-FslLog -Message "Access denied deleting '$target': $($_.Exception.Message)" -Level Warning -Component 'Maintenance'
                        New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $target `
                            -Message "Access denied: $($_.Exception.Message)" -Recommendation 'Run with an account that has modify rights on the share (for example an elevated session).' `
                            -Source $sources.RemoveItem -RequiresElevation $true -Scope $member.Scope
                    }
                    else {
                        $failed++
                        Add-FslError -ErrorRecord $_ -Component 'Maintenance' -Context "Deleting '$target'"
                        New-FslResult -Category $category -Check $check -Status 'Error' -Target $target `
                            -Message "Delete failed: $($_.Exception.Message)" -Source $sources.RemoveItem -RequiresElevation $false -Scope $member.Scope
                    }
                }
            }
        }

        New-FslResult -Category $category -Check 'StaleContainerSummary' -Status 'Info' `
            -Target $(if ($archiveFull) { $archiveFull } else { 'Delete' }) `
            -Value "Evaluated: $($collected.Count); Eligible: $($eligible.Count); NotEligible: $notEligible; Completed: $done; Skipped: $skipped; Failed: $failed" `
            -Expected "$filterText (StaleDays toolkit default unless specified)" `
            -Message $(if ($WhatIfPreference) { 'WhatIf run: no containers were changed.' } else { 'Stale container processing finished.' }) `
            -Source $actionSource -RequiresElevation $false
    }
}
