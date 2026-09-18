function Get-FslContainer {
    <#
    .SYNOPSIS
        Inventories FSLogix profile and ODFC container files (size, last write, lock, account status).

    .DESCRIPTION
        Enumerates VHD/VHDX container files in FSLogix storage locations. For each location the files in
        the location root (NoProfileContainingFolder layout) and in each immediate subfolder (the default
        per-user '%sid%_%username%' folder, or '%username%_%sid%' when FlipFlopProfileDirectoryName = 1)
        are read. Enumeration is not recursive beyond that one folder level.

        Scope (Profiles / ODFC) is derived from the file name using the effective VHDNameMatch values
        (documented defaults 'Profile*' and 'ODFC*'); a file matching neither or both is 'Unknown'.
        SIDs are extracted from the folder name: Active Directory/local account SIDs (S-1-5-21-...) and
        Microsoft Entra ID SIDs (S-1-12-1-..., the prefix documented for Microsoft Entra SIDs in the
        LocalUsersAndGroups Policy CSP). They are translated to an account with
        System.Security.Principal.SecurityIdentifier.Translate: success = Resolved,
        IdentityNotMappedException = Orphaned, anything else (or non-Windows) = Unknown.
        Exception for Microsoft Entra ID SIDs: whether a host can translate them depends on its join state, which
        the toolkit cannot verify, so an untranslatable S-1-12-1 SID is reported as Unknown and is never Orphaned
        (Remove-FslStaleContainer -OrphanedOnly therefore never selects it).

        MaxSizeMB is the effective SizeInMBs for the scope (documented default 30000). PercentOfMax is the
        file size divided by MaxSizeMB and is only computed for dynamic disks (IsDynamic default 1); for
        fixed disks (IsDynamic = 0) the file is fully allocated so PercentOfMax is $null. Note that SizeInMBs
        applies to newly created containers and extends existing ones at sign-in, so an individual disk can
        differ from the configured value.

        IsLocked opens each file read-only with FileShare.None and disposes the handle immediately (the file
        is never modified): sharing violation = $true, opened = $false, access denied/other/non-Windows = $null.
        The handle is held only for the duration of the open call.

    .PARAMETER Path
        One or more folders (local or UNC) that contain containers. When omitted, SMB and Local locations
        from Get-FslStorageLocation (VHDLocations / CCDLocations) are used. Locations that still contain
        per-user variables such as %username% are skipped (logged as a warning).

    .PARAMETER Scope
        Scopes to return: Profiles, ODFC, Unknown. Also limits which storage locations are read when -Path
        is not supplied. Default: all.

    .EXAMPLE
        Get-FslContainer | Sort-Object -Property SizeBytes -Descending | Select-Object -First 10

    .EXAMPLE
        Get-FslContainer -Path '\\fileserver\profiles' -Scope Profiles

    .NOTES
        RequiresElevation: No (read access to the share/folders is required).
        Sources:
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
          https://learn.microsoft.com/en-us/dotnet/api/system.security.principal.securityidentifier.translate
          https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-localusersandgroups
          https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/understand-security-identifiers
          https://learn.microsoft.com/en-us/dotnet/standard/io/handling-io-errors
          https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-childitem
    #>
    [CmdletBinding()]
    [OutputType('FSLogixToolkit.Container')]
    param(
        [Parameter(ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path,

        [Parameter()]
        [ValidateSet('Profiles', 'ODFC', 'Unknown')]
        [string[]] $Scope = @('Profiles', 'ODFC', 'Unknown')
    )

    begin {
        $extensions = @('.vhd', '.vhdx')
        try {
            $config = Get-FslConfig -Section 'Containers'
            if ($null -ne $config -and $config.ContainsKey('Extensions') -and @($config['Extensions']).Count -gt 0) {
                $extensions = @($config['Extensions'])
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Containers' -Context 'Reading Containers settings'
        }

        # Read naming settings only for the requested container scopes (both when Unknown is requested,
        # because Unknown classification needs both VHDNameMatch values).
        $namingScopes = @($Scope | Where-Object -FilterScript { $_ -in @('Profiles', 'ODFC') } | Select-Object -Unique)
        if ($namingScopes.Count -eq 0 -or $Scope -contains 'Unknown') { $namingScopes = @('Profiles', 'ODFC') }
        $naming = Get-FslCtrNamingSetting -NamingScope $namingScopes
        $sidCache = @{}
        $locations = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($item in @($Path)) {
            if (-not [string]::IsNullOrWhiteSpace($item)) { $locations.Add($item) }
        }
    }

    end {
        if ($locations.Count -eq 0) {
            $locationScopes = @($Scope | Where-Object -FilterScript { $_ -in @('Profiles', 'ODFC') })
            if ($locationScopes.Count -eq 0) { $locationScopes = @('Profiles', 'ODFC') }
            # Get-FslCtrSearchLocation returns one string[] object (return , array); iterate its elements, not a wrapper array.
            foreach ($location in [string[]](Get-FslCtrSearchLocation -Scope $locationScopes)) {
                if (-not [string]::IsNullOrWhiteSpace($location)) { $locations.Add($location) }
            }
        }
        if ($locations.Count -eq 0) {
            Write-FslLog -Message 'No SMB/Local container locations found to enumerate.' -Level Warning -Component 'Containers'
            return
        }

        $nowUtc = [datetime]::UtcNow
        $seenLocations = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($location in $locations) {
            if (-not $seenLocations.Add($location)) { continue }

            $folders = [System.Collections.Generic.List[object]]::new()
            try {
                if (-not (Test-Path -LiteralPath $location -PathType Container -ErrorAction Stop)) {
                    Write-FslLog -Message "Container location not found or not accessible: $location" -Level Warning -Component 'Containers'
                    continue
                }
                $folders.Add((Get-Item -LiteralPath $location -ErrorAction Stop))
                foreach ($directory in @(Get-ChildItem -LiteralPath $location -Directory -ErrorAction Stop)) {
                    $folders.Add($directory)
                }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Containers' -Context "Enumerating folders in $location"
                if ($folders.Count -eq 0) { continue }
            }

            $isRoot = $true
            foreach ($folder in $folders) {
                $folderName = if ($isRoot) { '' } else { $folder.Name }
                $isRoot = $false

                $files = @()
                try {
                    $files = @(Get-ChildItem -LiteralPath $folder.FullName -File -ErrorAction Stop |
                            Where-Object -FilterScript { $_.Extension -in $extensions })
                }
                catch {
                    Add-FslError -ErrorRecord $_ -Component 'Containers' -Context "Enumerating files in $($folder.FullName)"
                    continue
                }

                foreach ($file in $files) {
                    try {
                        $fileScope = Get-FslCtrScope -FileName $file.Name -Naming $naming
                        if ($fileScope -notin $Scope) { continue }

                        $identity = Get-FslCtrIdentityFromName -FileName $file.Name -FolderName $folderName -Scope $fileScope -Naming $naming
                        $account = Resolve-FslCtrAccount -Sid $identity['SID'] -Cache $sidCache

                        $userName = $identity['UserName']
                        if ([string]::IsNullOrEmpty($userName) -and $account['AccountName']) {
                            $userName = ([string]$account['AccountName']).Split('\')[-1]
                        }

                        $sizeBytes = [long]$file.Length
                        $maxSizeMB = $null
                        $percentOfMax = $null
                        if ($fileScope -ne 'Unknown') {
                            $configuredMax = [long]$naming[$fileScope]['SizeInMBs']
                            if ($configuredMax -gt 0) {
                                $maxSizeMB = [int]$configuredMax
                                if ([long]$naming[$fileScope]['IsDynamic'] -ne 0) {
                                    $percentOfMax = [math]::Round(($sizeBytes / ($configuredMax * 1MB)) * 100, 1)
                                }
                            }
                        }

                        $lastWriteUtc = $file.LastWriteTimeUtc
                        [pscustomobject]@{
                            PSTypeName         = 'FSLogixToolkit.Container'
                            Scope              = $fileScope
                            UserName           = $userName
                            SID                = $identity['SID']
                            FolderPath         = $file.DirectoryName
                            FileName           = $file.Name
                            FullName           = $file.FullName
                            Extension          = $file.Extension
                            SizeBytes          = $sizeBytes
                            SizeGB             = [math]::Round($sizeBytes / 1GB, 2)
                            MaxSizeMB          = $maxSizeMB
                            PercentOfMax       = $percentOfMax
                            LastWriteTime      = $lastWriteUtc.ToLocalTime()
                            DaysSinceLastWrite = [int][math]::Max(0, [math]::Floor(($nowUtc - $lastWriteUtc).TotalDays))
                            IsLocked           = Test-FslCtrFileLock -LiteralPath $file.FullName
                            AccountStatus      = $account['AccountStatus']
                            StorageLocation    = $location
                        }
                    }
                    catch {
                        Add-FslError -ErrorRecord $_ -Component 'Containers' -Context "Reading container $($file.FullName)"
                    }
                }
            }
        }
    }
}
