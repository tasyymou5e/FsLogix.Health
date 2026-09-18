# Private handlers for the Office container reset repair action FIX-ODFC-02 (Agent P3-6, prefix *-FslFix*).
#
# Handler interface (contract PHASE 3 P3.5):
#   Detect   Get-FslFixContainerResetState  param([hashtable]$Definition, [hashtable]$Parameters)
#   Apply    Invoke-FslFixContainerReset    param([hashtable]$Definition, [pscustomobject]$Action, [hashtable]$BeforeState)
#   Rollback Undo-FslFixContainerReset      param([hashtable]$Definition, [hashtable]$BeforeState, [hashtable]$AfterState)
#
# What the action does: the selected user's Office container (ODFC) VHD/VHDX file is COPIED to an operator-chosen
# archive folder, the copy is verified (length + SHA256) and only then is the source FILE removed. The per-user folder
# and every other file in it are never touched. FSLogix creates a new, empty Office container at the user's next sign-in.
# Rollback (MoveBack) copies the archived file back, but only when no container exists again at the original path.
#
# Sources verified 2026-09-17:
#   https://learn.microsoft.com/en-us/fslogix/concepts-container-types
#     ODFC container: "Most data contained in the ODFC container is sourced from other remote systems and is easily
#     replaced should the ODFC container become corrupted or deleted."; default ODFC content list (Office Activation,
#     Outlook, Outlook personalization, SharePoint, OneDrive, Skype for Business); "ODFC container is not backed up or
#     replicated to alternate locations since the data is recoverable from the source."
#   https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
#     ODFC settings live under HKLM\SOFTWARE\Policies\FSLogix\ODFC; Enabled default 0; VHDLocations / CCDLocations.
#   https://learn.microsoft.com/en-us/fslogix/troubleshooting-container-locked
#     "FSLogix maintains an exclusive lock on the user's container while they're connected to a virtual machine and
#     concurrent connections is disabled."
#   https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/e8fb45c1-a03d-44ca-b7ae-47385cfd7997
#     SMB2 CREATE ShareAccess: a sharing mode is part of every open, so a file server refuses an open whose sharing
#     mode conflicts with an existing open (including opens from other SMB clients).
#   https://learn.microsoft.com/en-us/dotnet/api/system.io.fileshare
#     FileShare.None: "Declines sharing of the current file. Any request to open the file (by this process or another
#     process) will fail until the file is closed."
#   https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/copy-item
#     -LiteralPath is used exactly as typed; -Destination is the new location; -Force copies over read-only files.
#   https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/remove-item
#     -LiteralPath is used exactly as typed (parameter set confirmed with Get-Command on PowerShell 7.5.2).
#   https://learn.microsoft.com/en-us/dotnet/api/system.io.directory.createdirectory
#   https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-filehash
#     Default algorithm SHA256; -LiteralPath is used exactly as typed; Hash is upper-case hex.
#   https://learn.microsoft.com/en-us/dotnet/api/system.io.driveinfo.availablefreespace
#   https://learn.microsoft.com/en-us/dotnet/api/system.io.path.getinvalidfilenamechars
#   https://learn.microsoft.com/en-us/powershell/module/storage/get-diskimage (attachment test, when available)
#
# Lock detection note: the exclusive-open test (FileShare.None) detects handles held by other session hosts only as far
# as the file server enforces SMB sharing modes for that share. It is never a substitute for the operator confirming
# that the user is signed out of every session host (gate -UserSignedOutConfirmed).

$script:FslFixContainerActionId = 'FIX-ODFC-02'
$script:FslFixContainerExtensions = @('.vhd', '.vhdx')
$script:FslFixContainerHashAlgorithm = 'SHA256'

function Get-FslFixContainerSource {
    <#
    .SYNOPSIS
        Returns the verified source URLs used by the Office container reset handlers.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        ContainerTypes  = 'https://learn.microsoft.com/en-us/fslogix/concepts-container-types'
        ConfigSettings  = 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings'
        ContainerLocked = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-container-locked'
        CopyItem        = 'https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/copy-item'
        RemoveItem      = 'https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/remove-item'
        GetFileHash     = 'https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-filehash'
        GetDiskImage    = 'https://learn.microsoft.com/en-us/powershell/module/storage/get-diskimage'
    }
}

function Get-FslFixContainerWarningText {
    <#
    .SYNOPSIS
        Returns the operator warning about re-synced vs local-only Office container data.
    .DESCRIPTION
        Quotes concepts-container-types ("Most data contained in the ODFC container is sourced from other remote
        systems and is easily replaced should the ODFC container become corrupted or deleted") and states plainly that
        anything in the container that is not synced from a remote system exists only in the archived file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return @(
        'The user must be signed out of every session host. The container file is copied to the archive folder and only removed after the copy is verified (length + SHA256); the per-user folder and all other files in it are left untouched.',
        'FSLogix creates a new, empty Office container at the next sign-in. Microsoft states: "Most data contained in the ODFC container is sourced from other remote systems and is easily replaced should the ODFC container become corrupted or deleted" - Outlook, SharePoint and OneDrive content is re-synced from Microsoft 365.',
        'Data in the container that is NOT synced from a remote system (for example local-only OneNote notebooks, OneDrive files that never finished syncing, Office settings that are not roamed) exists only in the archived file and will NOT be in the new container. Keep the archive until the user confirms their data is complete; the undo (MoveBack) only works while no new container exists at the original path.'
    ) -join ' '
}

function ConvertTo-FslFixContainerSafeName {
    <#
    .SYNOPSIS
        Returns a name usable as a folder name: invalid file-name characters and spaces replaced with '-'.
    .NOTES
        Source: https://learn.microsoft.com/en-us/dotnet/api/system.io.path.getinvalidfilenamechars
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $builder = [System.Text.StringBuilder]::new()
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($character in $Name.ToCharArray()) {
        if ($invalid -contains $character -or $character -eq ' ') { $null = $builder.Append('-') }
        else { $null = $builder.Append($character) }
    }
    return $builder.ToString().Trim('-')
}

function Resolve-FslFixContainerParameter {
    <#
    .SYNOPSIS
        Normalizes the FIX-ODFC-02 parameters (UserName, UserSid, ArchivePath, UserSignedOutConfirmed, ChangeReference).
    .DESCRIPTION
        StrictMode-safe read of the engine's -Parameters hashtable. UserName accepts DOMAIN\user or user@domain and is
        reduced to the account name for folder matching. Nothing here reads or stores secrets.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [hashtable] $Parameters
    )

    $userName = [string](Get-FslFixValue -InputObject $Parameters -Name 'UserName')
    $userSid = [string](Get-FslFixValue -InputObject $Parameters -Name 'UserSid')
    $archivePath = [string](Get-FslFixValue -InputObject $Parameters -Name 'ArchivePath')
    $changeReference = [string](Get-FslFixValue -InputObject $Parameters -Name 'ChangeReference')
    $signedOut = Get-FslFixValue -InputObject $Parameters -Name 'UserSignedOutConfirmed'

    $accountName = $userName
    if (-not [string]::IsNullOrWhiteSpace($accountName)) {
        $accountName = $accountName.Trim()
        if ($accountName.Contains('\')) { $accountName = $accountName.Split('\')[-1] }
        elseif ($accountName.Contains('@')) { $accountName = $accountName.Split('@')[0] }
    }

    $selection = $null
    if (-not [string]::IsNullOrWhiteSpace($userSid)) { $selection = "SID '$($userSid.Trim())'" }
    elseif (-not [string]::IsNullOrWhiteSpace($userName)) { $selection = "user '$($userName.Trim())'" }

    return @{
        UserName               = if ([string]::IsNullOrWhiteSpace($userName)) { $null } else { $userName.Trim() }
        AccountName            = if ([string]::IsNullOrWhiteSpace($accountName)) { $null } else { $accountName }
        UserSid                = if ([string]::IsNullOrWhiteSpace($userSid)) { $null } else { $userSid.Trim() }
        ArchivePath            = if ([string]::IsNullOrWhiteSpace($archivePath)) { $null } else { $archivePath.Trim() }
        ChangeReference        = if ([string]::IsNullOrWhiteSpace($changeReference)) { $null } else { $changeReference.Trim() }
        UserSignedOutConfirmed = [bool]$signedOut
        HasSelection           = (-not [string]::IsNullOrWhiteSpace($userSid)) -or (-not [string]::IsNullOrWhiteSpace($userName))
        SelectionText          = $selection
    }
}

function Resolve-FslFixContainerArchiveRoot {
    <#
    .SYNOPSIS
        Returns the archive root: the -Parameters ArchivePath, else Settings Repair.ContainerArchivePath ($null when unset).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ArchivePath
    )

    if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) { return $ArchivePath.Trim() }

    $configured = $null
    try {
        $config = Get-FslConfig -Section 'Repair'
        if ($null -ne $config) { $configured = [string](Get-FslFixValue -InputObject $config -Name 'ContainerArchivePath') }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Reading Repair.ContainerArchivePath'
    }
    if ([string]::IsNullOrWhiteSpace($configured)) { return $null }
    return [Environment]::ExpandEnvironmentVariables($configured.Trim())
}

function Test-FslFixContainerSettingState {
    <#
    .SYNOPSIS
        Reads the ODFC/Profiles Enabled values and the ODFC CCDLocations value and returns the gate result.
    .DESCRIPTION
        Gate (contract P3.6): ODFC Enabled = 1, Profiles Enabled <> 1 (Office containers only) and no ODFC CCDLocations
        value (no Cloud Cache). Documented default for both Enabled values is 0 (reference-configuration-settings), so
        an absent value counts as 0. Reasons are returned as complete sentences for the RepairAction BlockReason.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $state = @{
        Ok              = $false
        Reasons         = @()
        OdfcEnabled     = $null
        ProfilesEnabled = $null
        CloudCache      = $false
    }
    $reasons = [System.Collections.Generic.List[string]]::new()

    $settings = @()
    try {
        $settings = @(Get-FslEffectiveSetting -Scope 'ODFC', 'Profiles')
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Reading FSLogix settings for FIX-ODFC-02'
        $state['Reasons'] = @('The FSLogix ODFC and Profiles settings could not be read, so the Office container reset gates cannot be evaluated.')
        return $state
    }

    # Documented default for both Enabled values is 0 (reference-configuration-settings), so an absent value is 0.
    $odfcEnabled = 0
    $profilesEnabled = 0
    foreach ($setting in $settings) {
        $name = [string](Get-FslFixValue -InputObject $setting -Name 'Name')
        $scope = [string](Get-FslFixValue -InputObject $setting -Name 'Scope')
        $value = Get-FslFixValue -InputObject $setting -Name 'Value'
        if ($name -eq 'CCDLocations' -and $scope -eq 'ODFC') {
            $state['CloudCache'] = $true
            continue
        }
        if ($name -ne 'Enabled' -or $scope -notin @('ODFC', 'Profiles')) { continue }
        $numeric = $null
        try { $numeric = [int]$value }
        catch {
            Write-FslLog -Message "FIX-ODFC-02: the $scope Enabled value is not numeric ('$value'); it is treated as not enabled." -Level Warning -Component 'Repair'
            $numeric = -1
        }
        if ($scope -eq 'ODFC') { $odfcEnabled = $numeric } else { $profilesEnabled = $numeric }
    }
    $state['OdfcEnabled'] = $odfcEnabled
    $state['ProfilesEnabled'] = $profilesEnabled

    if ($odfcEnabled -ne 1) {
        $reasons.Add("Office containers are not enabled on this computer (ODFC Enabled = $odfcEnabled; documented default 0). The Office container reset only runs where FSLogix Office containers are in use.")
    }
    if ($profilesEnabled -eq 1) {
        $reasons.Add('Profile containers are enabled on this computer (Profiles Enabled = 1). This repair is only offered on hosts that use Office containers only, where the container holds Office data that is re-synced from Microsoft 365.')
    }
    if ($state['CloudCache']) {
        $reasons.Add('The ODFC scope has a CCDLocations value (Cloud Cache). The Office container reset does not support Cloud Cache containers.')
    }

    $state['Reasons'] = $reasons.ToArray()
    $state['Ok'] = ($reasons.Count -eq 0)
    return $state
}

function Get-FslFixContainerCandidate {
    <#
    .SYNOPSIS
        Returns the ODFC containers of Get-FslContainer that match the selected user name and/or SID.
    .DESCRIPTION
        SID match: exact (case-insensitive). User name match: the container UserName, or the per-user folder name
        containing the account name as a whole '_' separated token (documented folder patterns %sid%_%username% and
        %username%_%sid%). Both filters are applied when both are supplied.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [string] $UserName,

        [Parameter()]
        [AllowNull()]
        [string] $UserSid
    )

    $containers = @()
    try {
        $containers = @(Get-FslContainer -Scope 'ODFC')
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Enumerating ODFC containers for FIX-ODFC-02'
        return @()
    }

    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($container in $containers) {
        if ($null -eq $container) { continue }
        $containerSid = [string](Get-FslFixValue -InputObject $container -Name 'SID')
        $containerUser = [string](Get-FslFixValue -InputObject $container -Name 'UserName')
        $folderPath = [string](Get-FslFixValue -InputObject $container -Name 'FolderPath')

        if (-not [string]::IsNullOrWhiteSpace($UserSid)) {
            if (-not [string]::Equals($containerSid, $UserSid, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        }
        if (-not [string]::IsNullOrWhiteSpace($UserName)) {
            $nameMatch = [string]::Equals($containerUser, $UserName, [System.StringComparison]::OrdinalIgnoreCase)
            if (-not $nameMatch -and -not [string]::IsNullOrWhiteSpace($folderPath)) {
                $folderName = [System.IO.Path]::GetFileName($folderPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
                $pattern = '(^|_)' + [regex]::Escape($UserName) + '($|_)'
                $nameMatch = [regex]::IsMatch($folderName, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            }
            if (-not $nameMatch) { continue }
        }
        $matched.Add($container)
    }
    return $matched.ToArray()
}

function Test-FslFixContainerAvailability {
    <#
    .SYNOPSIS
        Tests that a container file is not in use (exclusive open) and not attached on this computer.
    .DESCRIPTION
        Uses Test-FslMntFileInUse (FileShare.None open, nothing is written) and, when the Storage module's
        Get-DiskImage is available, Test-FslMntDiskImageAttached. The exclusive-open test detects handles held by other
        session hosts only as far as the file server enforces SMB sharing modes; operator attestation is still required.
        Returns Ok, Reasons, InUse ($true/$false/$null), Attached ($true/$false/$null) and AttachmentChecked.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LiteralPath
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $inUse = $null
    $attached = $null
    $attachmentChecked = $false

    try {
        $lock = Test-FslMntFileInUse -LiteralPath $LiteralPath
        $inUse = Get-FslFixValue -InputObject $lock -Name 'InUse'
        $reason = [string](Get-FslFixValue -InputObject $lock -Name 'Reason')
        if ($true -eq $inUse) {
            $reasons.Add("The container file '$LiteralPath' is in use: an exclusive open failed ($reason). FSLogix keeps an exclusive lock on a container while the user is connected to a virtual machine.")
        }
        elseif ($null -eq $inUse) {
            $reasons.Add("It could not be verified that the container file '$LiteralPath' is free: the exclusive-open test did not complete ($reason).")
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Exclusive-open test on $LiteralPath"
        $reasons.Add("It could not be verified that the container file '$LiteralPath' is free: the exclusive-open test failed.")
    }

    if (Test-FslIsWindows) {
        $diskImageCommand = Get-Command -Name 'Get-DiskImage' -ErrorAction SilentlyContinue
        if ($null -ne $diskImageCommand) {
            $attachmentChecked = $true
            $attached = Test-FslMntDiskImageAttached -ImagePath $LiteralPath
            if ($true -eq $attached) {
                $reasons.Add("The container file '$LiteralPath' is attached as a disk image on this computer. Sign the user out and let FSLogix detach the container first.")
            }
        }
    }

    return @{
        Ok                = ($reasons.Count -eq 0)
        Reasons           = $reasons.ToArray()
        InUse             = $inUse
        Attached          = $attached
        AttachmentChecked = $attachmentChecked
    }
}

function Get-FslFixContainerFreeSpaceByte {
    <#
    .SYNOPSIS
        Returns the available free bytes for a local rooted path, or $null when it cannot be determined.
    .DESCRIPTION
        Uses System.IO.DriveInfo.AvailableFreeSpace, which needs a drive (a local root). Free space on a UNC path is
        not read (no documented inbox way to query it), so the result is $null and callers must not block on it.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        if ([string]::IsNullOrEmpty($full)) { return $null }
        if ($full.StartsWith('\\') -or $full.StartsWith('//')) { return $null }
        $root = [System.IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrEmpty($root)) { return $null }
        return [long]([System.IO.DriveInfo]::new($root)).AvailableFreeSpace
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Reading free space for $Path"
        return $null
    }
}

function Get-FslFixContainerHash {
    <#
    .SYNOPSIS
        Returns the SHA256 hash (upper-case hex) of a file, or $null when it cannot be computed.
    .NOTES
        Source: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-filehash
        (default algorithm SHA256; the file is read as a stream, which matters for multi-GB containers).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LiteralPath
    )

    try {
        $hash = Get-FileHash -LiteralPath $LiteralPath -Algorithm $script:FslFixContainerHashAlgorithm -ErrorAction Stop
        return [string]$hash.Hash
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Computing SHA256 of $LiteralPath"
        return $null
    }
}

function Test-FslFixContainerArchiveRoot {
    <#
    .SYNOPSIS
        Checks the archive root: supplied, reachable, a folder, outside the container folder and with enough free space.
    .DESCRIPTION
        Write access is proved when the timestamped archive folder is created during Apply (creating a probe file
        during planning would be a change). Free space is only checked for local paths; on a UNC path it is reported as
        unknown and never blocks (see Get-FslFixContainerFreeSpaceByte).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowNull()]
        [string] $ArchiveRoot,

        [Parameter()]
        [AllowNull()]
        [string] $ContainerFolderPath,

        [Parameter()]
        [AllowNull()]
        [string] $StorageLocation,

        [Parameter()]
        [long] $RequiredBytes = 0
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $freeSpace = $null

    if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) {
        $reasons.Add('No archive path was supplied. Pass -ArchivePath (or set Repair.ContainerArchivePath in Config/Settings.psd1) to a folder outside the FSLogix container storage location.')
        return @{ Ok = $false; Reasons = $reasons.ToArray(); FreeSpaceBytes = $null }
    }

    $exists = $false
    try {
        $exists = Test-Path -LiteralPath $ArchiveRoot -PathType Container -ErrorAction Stop
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Testing archive path $ArchiveRoot"
    }
    if (-not $exists) {
        $reasons.Add("The archive path '$ArchiveRoot' was not found or is not reachable from this computer. Create it (with permissions for the account that runs the repair) before running the Office container reset.")
        return @{ Ok = $false; Reasons = $reasons.ToArray(); FreeSpaceBytes = $null }
    }

    foreach ($protected in @($ContainerFolderPath, $StorageLocation)) {
        if ([string]::IsNullOrWhiteSpace($protected)) { continue }
        if (Test-FslMntPathUnder -Path $ArchiveRoot -ParentPath $protected) {
            $reasons.Add("The archive path '$ArchiveRoot' is inside the FSLogix container storage location '$protected'. Choose a folder outside the container storage location so the archived file is never mistaken for a container.")
            break
        }
    }

    $freeSpace = Get-FslFixContainerFreeSpaceByte -Path $ArchiveRoot
    if ($null -ne $freeSpace -and $RequiredBytes -gt 0 -and [long]$freeSpace -lt $RequiredBytes) {
        $requiredMb = [math]::Round($RequiredBytes / 1MB, 0)
        $freeMb = [math]::Round([long]$freeSpace / 1MB, 0)
        $reasons.Add("The archive path '$ArchiveRoot' has $freeMb MB free; the copy needs $requiredMb MB (container size plus the configured free-space margin).")
    }

    return @{
        Ok             = ($reasons.Count -eq 0)
        Reasons        = $reasons.ToArray()
        FreeSpaceBytes = $freeSpace
    }
}

function Clear-FslFixContainerPartialCopy {
    <#
    .SYNOPSIS
        Removes a partial archive copy (and the archive folder when this run created it and it is empty).
    .DESCRIPTION
        Called only on the failure path of Apply/Rollback, after the caller's ShouldProcess was already confirmed, so
        it must not be skipped by an inherited -WhatIf/-Confirm. Never removes a folder that still holds files.
        Returns the paths that could NOT be removed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Failure-path cleanup of a partial copy this run just created, inside an already confirmed change; must not be skipped by an inherited WhatIf/Confirm preference.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [string] $FilePath,

        [Parameter()]
        [AllowNull()]
        [string] $FolderPath,

        [Parameter()]
        [switch] $FolderCreated
    )

    $remaining = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        try {
            if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
                Remove-Item -LiteralPath $FilePath -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Removing partial archive copy $FilePath"
            $remaining.Add($FilePath)
        }
    }

    if ($FolderCreated -and -not [string]::IsNullOrWhiteSpace($FolderPath)) {
        try {
            if (Test-Path -LiteralPath $FolderPath -PathType Container) {
                $children = @(Get-ChildItem -LiteralPath $FolderPath -Force -ErrorAction Stop)
                if ($children.Count -eq 0) {
                    Remove-Item -LiteralPath $FolderPath -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
                }
                else {
                    $remaining.Add($FolderPath)
                }
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Removing archive folder $FolderPath"
            $remaining.Add($FolderPath)
        }
    }

    return $remaining.ToArray()
}

function Get-FslFixContainerResetState {
    <#
    .SYNOPSIS
        Detect handler for FIX-ODFC-02: resolves the selected user's Office container and evaluates every gate.
    .DESCRIPTION
        Handler interface (contract P3.5 / P3.6). The action is operator-selected: without a UserName or UserSid
        parameter nothing is needed. With a selection, the handler resolves exactly one ODFC container through
        Get-FslContainer -Scope ODFC (more than one match is Blocked and lists the candidates) and checks the gates:
        Windows, elevated, ODFC Enabled = 1, Profiles Enabled <> 1, no ODFC CCDLocations, the target is an ODFC-scope
        VHD/VHDX, the file is not in use (exclusive open) and not attached on this computer, the operator confirmed the
        user is signed out (-UserSignedOutConfirmed), a change reference was supplied, and the archive path is
        reachable, outside the container storage location and has enough free space (local paths only).

        BeforeState carries the original full path, size, last write time (UTC, ISO 8601), the archive root and the
        container folder. SHA256 is deliberately NOT computed here: hashing a multi-GB container over SMB during
        planning would take minutes for every preview. Apply computes it and stores the hash in AfterState, and drift
        between the plan and Apply is still detected because the engine fingerprints the before-state JSON, which
        contains SizeBytes and LastWriteTimeUtc.
    .PARAMETER Definition
        The Config/Repairs.psd1 action definition (Source and Guidance are used when present).
    .PARAMETER Parameters
        Engine parameters: UserName, UserSid, ArchivePath, UserSignedOutConfirmed, ChangeReference.
    .OUTPUTS
        pscustomobject with Needed, CurrentValue, ProposedValue, Target, BeforeState, BlockReason, GuidanceOnly, Guidance, Message.
    .NOTES
        RequiresElevation: Yes (gate). Never throws.
        Sources:
          https://learn.microsoft.com/en-us/fslogix/concepts-container-types
          https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings
          https://learn.microsoft.com/en-us/fslogix/troubleshooting-container-locked
          https://learn.microsoft.com/en-us/dotnet/api/system.io.fileshare
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [hashtable] $Definition,

        [Parameter(Position = 1)]
        [AllowNull()]
        [hashtable] $Parameters
    )

    $sources = Get-FslFixContainerSource
    $guidance = '{0} Source: {1}' -f (Get-FslFixContainerWarningText), $sources['ContainerTypes']
    $definitionGuidance = [string](Get-FslFixValue -InputObject $Definition -Name 'Guidance')
    if (-not [string]::IsNullOrWhiteSpace($definitionGuidance)) { $guidance = "$definitionGuidance $guidance" }

    $state = [ordered]@{
        Needed        = $false
        CurrentValue  = $null
        ProposedValue = $null
        Target        = $null
        BeforeState   = $null
        BlockReason   = $null
        GuidanceOnly  = $false
        Guidance      = $guidance
        Message       = $null
    }

    try {
        $options = Resolve-FslFixContainerParameter -Parameters $Parameters
        if (-not $options['HasSelection']) {
            $state['Message'] = 'No user selected. The Office container reset is only planned when the operator selects a user (parameter UserName or UserSid).'
            return [pscustomobject]$state
        }

        $state['Needed'] = $true
        $state['Target'] = [string]$options['SelectionText']
        $reasons = [System.Collections.Generic.List[string]]::new()

        if (-not (Test-FslIsWindows)) {
            $reasons.Add('The Office container reset runs on Windows only.')
            $state['Message'] = "Office container reset for $($options['SelectionText']) cannot be evaluated on this platform."
            $state['BlockReason'] = ($reasons -join ' ')
            return [pscustomobject]$state
        }
        if (-not (Test-FslElevation)) {
            $reasons.Add('Not elevated: the Office container reset requires an elevated session (run the toolkit as an administrator, or use File > Relaunch).')
        }

        $settingState = Test-FslFixContainerSettingState
        foreach ($reason in @($settingState['Reasons'])) { $reasons.Add($reason) }
        $attachmentNote = ''

        $candidates = @(Get-FslFixContainerCandidate -UserName $options['AccountName'] -UserSid $options['UserSid'])
        $container = $null
        if ($candidates.Count -eq 0) {
            # Nothing to reset. When every hard prerequisite (platform, elevation, ODFC/Profiles/Cloud Cache
            # settings) is satisfied, a missing container is NOT a blocked action - it is an action that is not
            # needed. This is also the state a successful reset leaves behind, and the engine's post-change
            # verification (contract P3.5 gate G21) re-detects and requires Needed = $false with no BlockReason.
            if ($reasons.Count -eq 0) {
                $state['Needed'] = $false
                $state['CurrentValue'] = "(no Office container for $($options['SelectionText']))"
                $state['Message'] = "No Office container exists for $($options['SelectionText']) in the configured ODFC storage locations; there is nothing to reset. FSLogix creates a new, empty Office container at the user's next sign-in."
                return [pscustomobject]$state
            }
            $reasons.Add("No Office container was found for $($options['SelectionText']) in the configured ODFC storage locations.")
        }
        elseif ($candidates.Count -gt 1) {
            $list = (@($candidates | ForEach-Object -Process { [string](Get-FslFixValue -InputObject $_ -Name 'FullName') }) -join '; ')
            $reasons.Add("More than one Office container matches $($options['SelectionText']): $list. Select the user by SID (parameter UserSid) so exactly one container is targeted.")
        }
        else {
            $container = $candidates[0]
        }

        $archiveRoot = Resolve-FslFixContainerArchiveRoot -ArchivePath ([string]$options['ArchivePath'])

        if ($null -ne $container) {
            $fullName = [string](Get-FslFixValue -InputObject $container -Name 'FullName')
            $folderPath = [string](Get-FslFixValue -InputObject $container -Name 'FolderPath')
            $fileName = [string](Get-FslFixValue -InputObject $container -Name 'FileName')
            $extension = [string](Get-FslFixValue -InputObject $container -Name 'Extension')
            $containerScope = [string](Get-FslFixValue -InputObject $container -Name 'Scope')
            $storageLocation = [string](Get-FslFixValue -InputObject $container -Name 'StorageLocation')
            $sizeBytes = [long](Get-FslFixValue -InputObject $container -Name 'SizeBytes')
            $containerUser = [string](Get-FslFixValue -InputObject $container -Name 'UserName')
            $containerSid = [string](Get-FslFixValue -InputObject $container -Name 'SID')
            $state['Target'] = $fullName

            if ($containerScope -ne 'ODFC' -or $extension -notin $script:FslFixContainerExtensions) {
                $reasons.Add("The file '$fullName' is not an ODFC-scope VHD/VHDX container (scope '$containerScope', extension '$extension').")
            }

            $fileInfo = $null
            try {
                $fileInfo = Get-Item -LiteralPath $fullName -ErrorAction Stop
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Reading container $fullName"
            }
            if ($null -eq $fileInfo) {
                $reasons.Add("The container file '$fullName' could not be read.")
            }
            else {
                $sizeBytes = [long]$fileInfo.Length
            }

            $availability = Test-FslFixContainerAvailability -LiteralPath $fullName
            foreach ($reason in @($availability['Reasons'])) { $reasons.Add($reason) }

            $margin = 0L
            try {
                $repairConfig = Get-FslConfig -Section 'Repair'
                $configuredMargin = Get-FslFixValue -InputObject $repairConfig -Name 'MinFreeSpaceMB'
                if ($null -ne $configuredMargin) { $margin = [long]$configuredMargin * 1MB }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Reading Repair.MinFreeSpaceMB'
            }

            $archiveState = Test-FslFixContainerArchiveRoot -ArchiveRoot $archiveRoot -ContainerFolderPath $folderPath `
                -StorageLocation $storageLocation -RequiredBytes ($sizeBytes + $margin)
            foreach ($reason in @($archiveState['Reasons'])) { $reasons.Add($reason) }

            $lastWriteUtc = $null
            if ($null -ne $fileInfo) { $lastWriteUtc = $fileInfo.LastWriteTimeUtc.ToString('o') }

            # Only stable facts belong in BeforeState: the engine fingerprints its JSON, so a value that changes
            # between the preview and the apply (a timestamp, the free space on the archive share) would look like
            # drift. SizeBytes + LastWriteTimeUtc are what make real drift visible.
            $state['BeforeState'] = @{
                ActionId          = $script:FslFixContainerActionId
                ComputerName      = [System.Environment]::MachineName
                Scope             = 'ODFC'
                UserName          = $containerUser
                Sid               = $containerSid
                SourcePath        = $fullName
                FolderPath        = $folderPath
                FileName          = $fileName
                StorageLocation   = $storageLocation
                SizeBytes         = $sizeBytes
                LastWriteTimeUtc  = $lastWriteUtc
                Sha256            = $null
                HashAlgorithm     = $script:FslFixContainerHashAlgorithm
                ArchiveRootPath   = $archiveRoot
                ArchiveFolderPath = $null
                ArchiveFilePath   = $null
            }
            if (-not $availability['AttachmentChecked']) {
                $attachmentNote = 'Whether the container is attached on this computer was not checked (the Storage module''s Get-DiskImage is not available here); the exclusive-open test still passed.'
            }

            $sizeGb = [math]::Round($sizeBytes / 1GB, 2)
            $state['CurrentValue'] = "$fullName ($sizeGb GB, last write $lastWriteUtc UTC)"
            $archiveText = if ([string]::IsNullOrWhiteSpace($archiveRoot)) { '<archive path>' } else { $archiveRoot }
            $state['ProposedValue'] = "Copy to $archiveText\<yyyyMMdd_HHmmss>_<ComputerName>_<UserFolder>\$fileName, verify length and SHA256, then remove $fullName (the folder and all other files stay)."
        }

        if (-not $options['UserSignedOutConfirmed']) {
            $reasons.Add('The operator has not confirmed that the user is signed out of every session host (-UserSignedOutConfirmed).')
        }
        if ([string]::IsNullOrWhiteSpace($options['ChangeReference'])) {
            $reasons.Add('No change reference was supplied (-ChangeReference). The Office container reset is a disruptive (risk tier 3) change.')
        }
        if ($null -eq $container -and [string]::IsNullOrWhiteSpace($archiveRoot)) {
            $reasons.Add('No archive path was supplied. Pass -ArchivePath (or set Repair.ContainerArchivePath in Config/Settings.psd1) to a folder outside the FSLogix container storage location.')
        }

        if ($reasons.Count -gt 0) {
            $state['BlockReason'] = ($reasons -join ' ')
            $state['Message'] = "Office container reset for $($state['Target']) is blocked: $($reasons.Count) gate(s) failed."
        }
        else {
            $state['Message'] = "Office container reset is ready for $($state['Target']). The container file is archived and removed; FSLogix creates a new, empty Office container at the next sign-in. $attachmentNote".Trim()
        }
        return [pscustomobject]$state
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Detecting FIX-ODFC-02 (Office container reset)'
        $state['BlockReason'] = "The Office container reset could not be evaluated: $($_.Exception.Message)"
        $state['Message'] = 'The Office container reset state could not be determined.'
        $state['Guidance'] = $guidance
        return [pscustomobject]$state
    }
}

function Invoke-FslFixContainerReset {
    <#
    .SYNOPSIS
        Apply handler for FIX-ODFC-02: archives the user's Office container file and removes the source file.
    .DESCRIPTION
        Every gate is evaluated again immediately before acting (Get-FslFixContainerResetState with the action's own
        parameters) and the resolved container must still be the one in BeforeState with the same size and last write
        time; anything else is refused without a change.

        Then: the archive folder <ArchivePath>\<yyyyMMdd_HHmmss>_<ComputerName>_<UserFolder> is created (this is also
        the write-access test), the container file is copied into it with Copy-Item -LiteralPath, the copy is verified
        (length and SHA256 of source and copy must match) and only then is the SOURCE FILE removed with Remove-Item
        -LiteralPath. The per-user folder and every other file in it are never touched.

        On any failure before the removal the source is left untouched, the partial copy (and the folder this run
        created, when empty) is removed, and Success = $false is returned with the reason.
    .PARAMETER Definition
        The Config/Repairs.psd1 action definition.
    .PARAMETER Action
        The FSLogixToolkit.RepairAction being applied (its Parameters are used for the gate re-check).
    .PARAMETER BeforeState
        The before-state hashtable produced by the Detect handler and stored in the rollback store.
    .OUTPUTS
        hashtable with Success, AfterState, Created, Message.
    .NOTES
        RequiresElevation: Yes. Never throws.
        Sources:
          https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/copy-item
          https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/remove-item
          https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-filehash
          https://learn.microsoft.com/en-us/fslogix/concepts-container-types
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [hashtable] $Definition,

        [Parameter(Position = 1)]
        [AllowNull()]
        [pscustomobject] $Action,

        [Parameter(Position = 2)]
        [AllowNull()]
        [hashtable] $BeforeState
    )

    $result = @{ Success = $false; AfterState = $null; Created = @(); Message = '' }
    $archiveFolder = $null
    $archiveFile = $null
    $folderCreated = $false

    try {
        $sourcePath = [string](Get-FslFixValue -InputObject $BeforeState -Name 'SourcePath')
        if ([string]::IsNullOrWhiteSpace($sourcePath)) {
            $result['Message'] = 'The before-state does not contain the container path (SourcePath); nothing was changed.'
            return $result
        }

        # The action's own parameters drive the gate re-check; the before-state only fills in what the engine did not
        # pass (the caller's hashtable is never modified).
        $actionParameters = Get-FslFixValue -InputObject $Action -Name 'Parameters'
        $parameters = @{}
        if ($actionParameters -is [System.Collections.IDictionary]) {
            foreach ($key in @($actionParameters.Keys)) { $parameters[[string]$key] = $actionParameters[$key] }
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-FslFixValue -InputObject $parameters -Name 'UserSid')) -and
            [string]::IsNullOrWhiteSpace([string](Get-FslFixValue -InputObject $parameters -Name 'UserName'))) {
            $parameters['UserSid'] = [string](Get-FslFixValue -InputObject $BeforeState -Name 'Sid')
            $parameters['UserName'] = [string](Get-FslFixValue -InputObject $BeforeState -Name 'UserName')
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-FslFixValue -InputObject $parameters -Name 'ArchivePath'))) {
            $parameters['ArchivePath'] = [string](Get-FslFixValue -InputObject $BeforeState -Name 'ArchiveRootPath')
        }

        # G17/G10: re-run every gate immediately before acting.
        $current = Get-FslFixContainerResetState -Definition $Definition -Parameters $parameters
        if (-not $current.Needed) {
            $result['Message'] = 'The Office container reset is no longer applicable (no user selected); nothing was changed.'
            return $result
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$current.BlockReason)) {
            $result['Message'] = "Refused immediately before applying: $($current.BlockReason) Nothing was changed."
            return $result
        }

        $currentBefore = $current.BeforeState
        $currentPath = [string](Get-FslFixValue -InputObject $currentBefore -Name 'SourcePath')
        if (-not (Test-FslMntPathEqual -Path $currentPath -OtherPath $sourcePath)) {
            $result['Message'] = "The container resolved now ('$currentPath') is not the one in the plan ('$sourcePath'); nothing was changed."
            return $result
        }
        $plannedSize = [long](Get-FslFixValue -InputObject $BeforeState -Name 'SizeBytes')
        $currentSize = [long](Get-FslFixValue -InputObject $currentBefore -Name 'SizeBytes')
        $plannedWrite = [string](Get-FslFixValue -InputObject $BeforeState -Name 'LastWriteTimeUtc')
        $currentWrite = [string](Get-FslFixValue -InputObject $currentBefore -Name 'LastWriteTimeUtc')
        if ($plannedSize -ne $currentSize -or $plannedWrite -ne $currentWrite) {
            $result['Message'] = "The container changed since the plan was created (size $plannedSize -> $currentSize, last write $plannedWrite -> $currentWrite); nothing was changed. Preview the repair again."
            return $result
        }

        $archiveRoot = [string](Get-FslFixValue -InputObject $currentBefore -Name 'ArchiveRootPath')
        if ([string]::IsNullOrWhiteSpace($archiveRoot)) {
            $result['Message'] = 'No archive path is available; nothing was changed.'
            return $result
        }

        $fileName = [System.IO.Path]::GetFileName($sourcePath)
        $folderPath = [string](Get-FslFixValue -InputObject $currentBefore -Name 'FolderPath')
        $userFolder = ConvertTo-FslFixContainerSafeName -Name ([System.IO.Path]::GetFileName($folderPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)))
        if ([string]::IsNullOrWhiteSpace($userFolder)) {
            $userFolder = ConvertTo-FslFixContainerSafeName -Name ([string](Get-FslFixValue -InputObject $currentBefore -Name 'Sid'))
        }
        if ([string]::IsNullOrWhiteSpace($userFolder)) { $userFolder = 'OfficeContainer' }

        $computerName = ConvertTo-FslFixContainerSafeName -Name ([System.Environment]::MachineName)
        $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $archiveFolder = Join-Path -Path $archiveRoot -ChildPath ('{0}_{1}_{2}' -f $timestamp, $computerName, $userFolder)
        $archiveFile = Join-Path -Path $archiveFolder -ChildPath $fileName

        $target = "Office container '$sourcePath'"
        $operation = "Archive to '$archiveFile' (verified copy) and remove the source file"
        if (-not $PSCmdlet.ShouldProcess($target, $operation)) {
            $result['Message'] = 'Office container reset was not confirmed; nothing was changed.'
            return $result
        }

        if (Test-Path -LiteralPath $archiveFolder) {
            $result['Message'] = "The archive folder '$archiveFolder' already exists; nothing was changed."
            return $result
        }
        # Directory.CreateDirectory is used instead of New-Item because New-Item has no -LiteralPath: an archive path
        # containing [ or ] would otherwise be treated as a wildcard. Creating the folder is also the write-access test.
        $null = [System.IO.Directory]::CreateDirectory($archiveFolder)
        $folderCreated = $true
        Write-FslLog -Message "FIX-ODFC-02: created archive folder $archiveFolder" -Level Info -Component 'Repair'

        Copy-Item -LiteralPath $sourcePath -Destination $archiveFile -ErrorAction Stop -WhatIf:$false -Confirm:$false

        if (-not (Test-Path -LiteralPath $archiveFile -PathType Leaf)) {
            $null = Clear-FslFixContainerPartialCopy -FilePath $archiveFile -FolderPath $archiveFolder -FolderCreated:$folderCreated
            $result['Message'] = "The archive copy '$archiveFile' was not created; the container was not touched."
            return $result
        }

        $sourceInfo = Get-Item -LiteralPath $sourcePath -ErrorAction Stop
        $archiveInfo = Get-Item -LiteralPath $archiveFile -ErrorAction Stop
        if ([long]$sourceInfo.Length -ne [long]$archiveInfo.Length) {
            $null = Clear-FslFixContainerPartialCopy -FilePath $archiveFile -FolderPath $archiveFolder -FolderCreated:$folderCreated
            $result['Message'] = "The archive copy is $($archiveInfo.Length) bytes but the container is $($sourceInfo.Length) bytes; the copy was removed and the container was not touched."
            return $result
        }

        $sourceHash = Get-FslFixContainerHash -LiteralPath $sourcePath
        $archiveHash = Get-FslFixContainerHash -LiteralPath $archiveFile
        if ([string]::IsNullOrWhiteSpace($sourceHash) -or [string]::IsNullOrWhiteSpace($archiveHash) -or
            -not [string]::Equals($sourceHash, $archiveHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            $null = Clear-FslFixContainerPartialCopy -FilePath $archiveFile -FolderPath $archiveFolder -FolderCreated:$folderCreated
            $result['Message'] = "The SHA256 of the archive copy does not match the container (source '$sourceHash', copy '$archiveHash'); the copy was removed and the container was not touched."
            return $result
        }

        Write-FslLog -Message "FIX-ODFC-02: verified archive copy $archiveFile (SHA256 $archiveHash)" -Level Info -Component 'Repair'

        $removeFailed = $null
        try {
            Remove-Item -LiteralPath $sourcePath -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Removing container $sourcePath"
            $removeFailed = $_.Exception.Message
        }

        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            $remaining = @(Clear-FslFixContainerPartialCopy -FilePath $archiveFile -FolderPath $archiveFolder -FolderCreated:$folderCreated)
            # 'Created' lists what the rollback must undo. Nothing was changed here, so it stays empty; leftovers that
            # could not be cleaned up are named in the message instead.
            $result['Created'] = @()
            $detail = if ($null -ne $removeFailed) { " ($removeFailed)" } else { '' }
            $leftover = if ($remaining.Count -gt 0) { " Left behind (remove manually): $($remaining -join '; ')." } else { '' }
            $result['Message'] = "The container file '$sourcePath' could not be removed$detail; the verified archive copy was removed again and nothing was changed.$leftover"
            return $result
        }

        $result['AfterState'] = @{
            ActionId          = $script:FslFixContainerActionId
            ComputerName      = [System.Environment]::MachineName
            Scope             = 'ODFC'
            UserName          = [string](Get-FslFixValue -InputObject $currentBefore -Name 'UserName')
            Sid               = [string](Get-FslFixValue -InputObject $currentBefore -Name 'Sid')
            SourcePath        = $sourcePath
            SourceExists      = $false
            FolderPath        = $folderPath
            FileName          = $fileName
            ArchiveRootPath   = $archiveRoot
            ArchiveFolderPath = $archiveFolder
            ArchiveFilePath   = $archiveFile
            SizeBytes         = [long]$archiveInfo.Length
            LastWriteTimeUtc  = $currentWrite
            SourceSha256      = $sourceHash
            ArchiveSha256     = $archiveHash
            HashAlgorithm     = $script:FslFixContainerHashAlgorithm
            ArchivedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
        }
        $result['Created'] = @($archiveFolder)
        $result['Success'] = $true
        $result['Message'] = "The Office container '$sourcePath' was copied to '$archiveFile' (SHA256 $archiveHash verified) and the source file was removed. FSLogix creates a new, empty Office container at the user's next sign-in. $(Get-FslFixContainerWarningText)"
        Write-FslLog -Message "FIX-ODFC-02: archived and removed $sourcePath" -Level Info -Component 'Repair'
        return $result
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Applying FIX-ODFC-02 (Office container reset)'
        $remaining = @(Clear-FslFixContainerPartialCopy -FilePath $archiveFile -FolderPath $archiveFolder -FolderCreated:$folderCreated)
        $result['Created'] = @()
        $result['Success'] = $false
        $leftover = if ($remaining.Count -gt 0) { " Left behind (remove manually): $($remaining -join '; ')." } else { '' }
        $result['Message'] = "The Office container reset failed: $($_.Exception.Message). The container file was not removed.$leftover"
        return $result
    }
}

function Undo-FslFixContainerReset {
    <#
    .SYNOPSIS
        Rollback handler (MoveBack) for FIX-ODFC-02: copies the archived Office container back to its original path.
    .DESCRIPTION
        Refused when a file already exists at the original path (FSLogix created a new Office container since the
        repair - restoring would overwrite the user's current data), when the per-user folder no longer exists (it must
        be recreated with the correct permissions first), when the archived file is missing, or when its SHA256 no
        longer matches the hash recorded at apply time.

        Otherwise the archived file is copied back, the restored file is verified (length and SHA256), and only then is
        the archive copy removed. The archive folder is removed as well when it is left empty. If the verification
        fails, the partial restored file is removed and the archive is kept.
    .PARAMETER Definition
        The Config/Repairs.psd1 action definition (not required).
    .PARAMETER BeforeState
        The before-state hashtable stored when the repair was applied.
    .PARAMETER AfterState
        The after-state hashtable stored when the repair was applied (archive path and hash).
    .OUTPUTS
        hashtable with Success and Message.
    .NOTES
        RequiresElevation: Yes. Never throws.
        Sources:
          https://learn.microsoft.com/en-us/fslogix/concepts-container-types
          https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/copy-item
          https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-filehash
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [hashtable] $Definition,

        [Parameter(Position = 1)]
        [AllowNull()]
        [hashtable] $BeforeState,

        [Parameter(Position = 2)]
        [AllowNull()]
        [hashtable] $AfterState
    )

    $result = @{ Success = $false; Message = '' }

    try {
        $null = $Definition
        $sourcePath = [string](Get-FslFixValue -InputObject $AfterState -Name 'SourcePath')
        if ([string]::IsNullOrWhiteSpace($sourcePath)) { $sourcePath = [string](Get-FslFixValue -InputObject $BeforeState -Name 'SourcePath') }
        $archiveFile = [string](Get-FslFixValue -InputObject $AfterState -Name 'ArchiveFilePath')
        $archiveFolder = [string](Get-FslFixValue -InputObject $AfterState -Name 'ArchiveFolderPath')
        $expectedHash = [string](Get-FslFixValue -InputObject $AfterState -Name 'ArchiveSha256')
        $expectedSize = [long](Get-FslFixValue -InputObject $AfterState -Name 'SizeBytes')

        if ([string]::IsNullOrWhiteSpace($sourcePath) -or [string]::IsNullOrWhiteSpace($archiveFile)) {
            $result['Message'] = 'The rollback state does not contain the container path and the archive path; nothing was changed.'
            return $result
        }

        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            $result['Message'] = "An Office container exists again at '$sourcePath' (FSLogix created a new container after the repair). The archived container is NOT restored, because restoring it would overwrite the user's current Office data. Move the new container aside manually if the archived one must be restored."
            return $result
        }

        $folderPath = [string](Get-FslFixValue -InputObject $AfterState -Name 'FolderPath')
        if ([string]::IsNullOrWhiteSpace($folderPath)) { $folderPath = [System.IO.Path]::GetDirectoryName($sourcePath) }
        if ([string]::IsNullOrWhiteSpace($folderPath) -or -not (Test-Path -LiteralPath $folderPath -PathType Container)) {
            $result['Message'] = "The container folder '$folderPath' no longer exists. Recreate it with the correct permissions before undoing this repair; the archived container is kept at '$archiveFile'."
            return $result
        }

        if (-not (Test-Path -LiteralPath $archiveFile -PathType Leaf)) {
            $result['Message'] = "The archived container '$archiveFile' was not found; nothing was changed."
            return $result
        }

        $archiveInfo = Get-Item -LiteralPath $archiveFile -ErrorAction Stop
        if ($expectedSize -gt 0 -and [long]$archiveInfo.Length -ne $expectedSize) {
            $result['Message'] = "The archived container '$archiveFile' is $($archiveInfo.Length) bytes but $expectedSize bytes were archived; it is not restored."
            return $result
        }

        $archiveHash = Get-FslFixContainerHash -LiteralPath $archiveFile
        if ([string]::IsNullOrWhiteSpace($archiveHash)) {
            $result['Message'] = "The SHA256 of the archived container '$archiveFile' could not be computed; it is not restored."
            return $result
        }
        if (-not [string]::IsNullOrWhiteSpace($expectedHash) -and
            -not [string]::Equals($archiveHash, $expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            $result['Message'] = "The archived container '$archiveFile' changed since the repair (SHA256 '$archiveHash', expected '$expectedHash'); it is not restored."
            return $result
        }

        if (-not $PSCmdlet.ShouldProcess("Office container '$sourcePath'", "Restore the archived container from '$archiveFile'")) {
            $result['Message'] = 'The Office container restore was not confirmed; nothing was changed.'
            return $result
        }

        Copy-Item -LiteralPath $archiveFile -Destination $sourcePath -ErrorAction Stop -WhatIf:$false -Confirm:$false

        $restoredHash = $null
        $restoredLength = -1L
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            $restoredInfo = Get-Item -LiteralPath $sourcePath -ErrorAction Stop
            $restoredLength = [long]$restoredInfo.Length
            $restoredHash = Get-FslFixContainerHash -LiteralPath $sourcePath
        }
        if ($restoredLength -ne [long]$archiveInfo.Length -or [string]::IsNullOrWhiteSpace($restoredHash) -or
            -not [string]::Equals($restoredHash, $archiveHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            $null = Clear-FslFixContainerPartialCopy -FilePath $sourcePath
            $result['Message'] = "The restored container at '$sourcePath' could not be verified (SHA256 '$restoredHash', expected '$archiveHash'); the partial copy was removed and the archive at '$archiveFile' was kept."
            return $result
        }

        $archiveRemoved = $true
        try {
            Remove-Item -LiteralPath $archiveFile -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Removing archive copy $archiveFile"
            $archiveRemoved = $false
        }
        if ($archiveRemoved -and -not [string]::IsNullOrWhiteSpace($archiveFolder)) {
            $null = Clear-FslFixContainerPartialCopy -FolderPath $archiveFolder -FolderCreated
        }

        $result['Success'] = $true
        $suffix = if ($archiveRemoved) { "the archive copy was removed" } else { "the archive copy at '$archiveFile' could not be removed and is still there" }
        $result['Message'] = "The Office container was restored to '$sourcePath' (SHA256 $restoredHash verified) and $suffix."
        Write-FslLog -Message "FIX-ODFC-02: restored $sourcePath from $archiveFile" -Level Info -Component 'Repair'
        return $result
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Rolling back FIX-ODFC-02 (Office container reset)'
        $result['Success'] = $false
        $result['Message'] = "The Office container could not be restored: $($_.Exception.Message)"
        return $result
    }
}
