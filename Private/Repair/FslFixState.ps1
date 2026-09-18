# Private helpers for the Repair undo store (Agent P3-4, prefix *-FslFix*).
#
# Authoritative rollback store: <Repair.StateRoot>\<RunId>\rollback.json + manifest.sha256.
# StateRoot default (Config/Settings.psd1 Repair.StateRoot): %ProgramData%\FSLogixToolkit\RepairState (admin-only ACL).
# TEST-ONLY override: environment variable FSLOGIXTOOLKIT_REPAIR_STATEROOT replaces the StateRoot path. On Windows the
# same owner/ACL checks apply to the override path, so it cannot be used to weaken the store.
#
# Sources:
#   https://learn.microsoft.com/dotnet/api/system.io.filesystemaclextensions.create
#     ("Creates a new directory, ensuring it is created with the specified directory security. If the directory already
#      exists, nothing is done.") -> existing folders are verified separately.
#   https://learn.microsoft.com/dotnet/api/system.security.accesscontrol.objectsecurity.setaccessruleprotection
#   https://learn.microsoft.com/dotnet/api/system.security.accesscontrol.objectsecurity.getowner
#   https://learn.microsoft.com/dotnet/api/system.security.accesscontrol.filesystemrights (write-type right values)
#   https://learn.microsoft.com/dotnet/api/system.io.fileshare (FileShare.None: any other open fails until the file is closed)
#   https://learn.microsoft.com/dotnet/api/system.environment.expandenvironmentvariables (unset variables are left unchanged)
#   https://learn.microsoft.com/dotnet/api/system.security.cryptography.sha256.hashdata
#   https://learn.microsoft.com/dotnet/api/system.text.json.jsondocument

# Well-known SIDs (https://learn.microsoft.com/windows-server/identity/ad-ds/manage/understand-security-identifiers).
$script:FslFixSidAdministrators = 'S-1-5-32-544'
$script:FslFixSidSystem = 'S-1-5-18'
$script:FslFixSidTrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$script:FslFixSidCreatorOwner = 'S-1-3-0'

# Write-type FileSystemRights bits (FileSystemRights enum values): WriteData/CreateFiles 2, AppendData/CreateDirectories 4,
# WriteExtendedAttributes 16, DeleteSubdirectoriesAndFiles 64, WriteAttributes 256, Delete 65536, ChangePermissions 262144,
# TakeOwnership 524288. Generic ACE bits GENERIC_ALL 0x10000000 and GENERIC_WRITE 0x40000000 are also treated as write.
$script:FslFixWriteRightsMask = [int64](2 -bor 4 -bor 16 -bor 64 -bor 256 -bor 65536 -bor 262144 -bor 524288 -bor 0x10000000 -bor 0x40000000)

$script:FslFixRollbackFileName = 'rollback.json'
$script:FslFixManifestFileName = 'manifest.sha256'
$script:FslFixLockFileName = 'repair.lock'

function Get-FslFixConfig {
    <#
    .SYNOPSIS
        Returns the Repair settings section with toolkit defaults for missing keys.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $defaults = @{
        FolderName = 'Repair'
        StateRoot  = '%ProgramData%\FSLogixToolkit\RepairState'
        RetainDays = 180
    }
    $result = @{}
    foreach ($key in $defaults.Keys) { $result[$key] = $defaults[$key] }
    try {
        $section = Get-FslConfig -Section 'Repair'
        if ($section) {
            foreach ($key in $section.Keys) {
                if ($null -ne $section[$key] -and -not ($section[$key] -is [string] -and [string]::IsNullOrWhiteSpace($section[$key]) -and $defaults.ContainsKey($key))) {
                    $result[$key] = $section[$key]
                }
            }
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Read Repair settings'
    }
    return $result
}

function ConvertFrom-FslFixJson {
    <#
    .SYNOPSIS
        Parses JSON text into hashtables/arrays/primitives with System.Text.Json (no date conversion, identical on PS 7.4+).
    .DESCRIPTION
        ConvertFrom-Json converts date-like strings to DateTime; rollback values must round-trip exactly, so a
        JsonDocument walk is used instead. Numbers: Int64 when integral, otherwise Double.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Json
    )

    $document = [System.Text.Json.JsonDocument]::Parse($Json)
    try {
        return , (ConvertFrom-FslFixJsonElement -Element $document.RootElement)
    }
    finally {
        $document.Dispose()
    }
}

function ConvertFrom-FslFixJsonElement {
    <#
    .SYNOPSIS
        Recursively converts a System.Text.Json.JsonElement to PowerShell values.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Element
    )

    switch ($Element.ValueKind) {
        'Object' {
            $table = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                $table[$property.Name] = ConvertFrom-FslFixJsonElement -Element $property.Value
            }
            return , $table
        }
        'Array' {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) { $list.Add((ConvertFrom-FslFixJsonElement -Element $item)) }
            return , $list.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' {
            [int64] $longValue = 0
            if ($Element.TryGetInt64([ref]$longValue)) { return $longValue }
            return $Element.GetDouble()
        }
        'True' { return $true }
        'False' { return $false }
        default { return $null }
    }
}

function ConvertTo-FslFixJson {
    <#
    .SYNOPSIS
        Serializes an object to JSON (depth 20).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject,

        [switch] $Compress
    )

    return (ConvertTo-Json -InputObject $InputObject -Depth 20 -Compress:$Compress)
}

function Get-FslFixSha256 {
    <#
    .SYNOPSIS
        Returns the upper-case hex SHA256 of a file's bytes, or of a byte array.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory, ParameterSetName = 'Bytes')]
        [AllowEmptyCollection()]
        [byte[]] $Bytes
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') { $Bytes = [System.IO.File]::ReadAllBytes($Path) }
    return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes))
}

function Resolve-FslFixStateRoot {
    <#
    .SYNOPSIS
        Returns the full rollback store path (Repair.StateRoot expanded) or the test override.
    .DESCRIPTION
        Order: environment variable FSLOGIXTOOLKIT_REPAIR_STATEROOT (test-only override) > Settings Repair.StateRoot
        expanded with [Environment]::ExpandEnvironmentVariables. When a %VARIABLE% stays unexpanded (unset variable -
        e.g. %ProgramData% on non-Windows), non-Windows falls back to <LocalApplicationData>/FSLogixToolkit/RepairState
        (tests only); Windows throws because the path cannot be trusted.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $override = [Environment]::GetEnvironmentVariable('FSLOGIXTOOLKIT_REPAIR_STATEROOT')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($override))
    }

    $configured = [string](Get-FslFixConfig)['StateRoot']
    $expanded = [Environment]::ExpandEnvironmentVariables($configured)
    if ($expanded -match '%[^%\\/]+%') {
        if (Test-FslIsWindows) {
            throw "Repair.StateRoot '$configured' contains an environment variable that is not set."
        }
        $local = [Environment]::GetFolderPath('LocalApplicationData')
        if ([string]::IsNullOrWhiteSpace($local)) { $local = [System.IO.Path]::GetTempPath() }
        $expanded = Join-Path -Path (Join-Path -Path $local -ChildPath 'FSLogixToolkit') -ChildPath 'RepairState'
    }
    return [System.IO.Path]::GetFullPath($expanded)
}

function Get-FslFixCurrentUserSid {
    <#
    .SYNOPSIS
        Returns the current Windows user SID string, or $null (non-Windows / error).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not (Test-FslIsWindows)) { return $null }
    $identity = $null
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return $identity.User.Value
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Read current user SID'
        return $null
    }
    finally {
        if ($null -ne $identity) { $identity.Dispose() }
    }
}

function Test-FslFixFolderSecurity {
    <#
    .SYNOPSIS
        Windows: verifies a folder's owner is Administrators/SYSTEM/TrustedInstaller and no other principal has an Allow
        ACE with write-type rights (CREATOR OWNER allowed only when inherit-only). Returns @{ Ok; Message; Owner }.
    .DESCRIPTION
        Reparse points (junctions/symlinks) are refused. Deny ACEs are ignored (they only remove rights).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $trusted = @($script:FslFixSidAdministrators, $script:FslFixSidSystem, $script:FslFixSidTrustedInstaller)
    try {
        $info = [System.IO.DirectoryInfo]::new($Path)
        if (-not $info.Exists) { return @{ Ok = $false; Message = "Folder does not exist: $Path"; Owner = $null } }
        if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return @{ Ok = $false; Message = "Folder is a reparse point (junction/symbolic link) and is refused: $Path"; Owner = $null }
        }
        $sections = [System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
        $security = [System.IO.FileSystemAclExtensions]::GetAccessControl($info, $sections)
        $sidType = [System.Security.Principal.SecurityIdentifier]
        $owner = $security.GetOwner($sidType)
        $ownerSid = if ($null -ne $owner) { $owner.Value } else { $null }
        if ($trusted -notcontains $ownerSid) {
            return @{ Ok = $false; Message = "Folder owner '$ownerSid' is not Administrators, SYSTEM or TrustedInstaller: $Path"; Owner = $ownerSid }
        }
        foreach ($rule in $security.GetAccessRules($true, $true, $sidType)) {
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
            $sid = $rule.IdentityReference.Value
            if ($trusted -contains $sid) { continue }
            $rights = [int64]$rule.FileSystemRights
            if (($rights -band $script:FslFixWriteRightsMask) -eq 0) { continue }
            if ($sid -eq $script:FslFixSidCreatorOwner -and
                ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
            return @{ Ok = $false; Message = "Principal '$sid' has write-type rights ($rights) on $Path"; Owner = $ownerSid }
        }
        return @{ Ok = $true; Message = "Owner $ownerSid; no non-admin write rights: $Path"; Owner = $ownerSid }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Check folder security '$Path'"
        return @{ Ok = $false; Message = "Folder security could not be read: $Path ($($_.Exception.Message))"; Owner = $null }
    }
}

function New-FslFixProtectedDirectory {
    <#
    .SYNOPSIS
        Windows: creates a folder with SYSTEM + Administrators FullControl (inheritable), protected from inheritance, and
        sets the owner to Administrators. Returns @{ Ok; Message }.
    .DESCRIPTION
        Uses FileSystemAclExtensions.Create (does nothing if the folder exists - callers verify existing folders).
        Internal toolkit state; the calling repair run is already confirmed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal toolkit state/log write inside an already confirmed repair run; must not be skipped by an inherited WhatIf/Confirm preference.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    try {
        $admins = [System.Security.Principal.SecurityIdentifier]::new($script:FslFixSidAdministrators)
        $system = [System.Security.Principal.SecurityIdentifier]::new($script:FslFixSidSystem)
        $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $security = [System.Security.AccessControl.DirectorySecurity]::new()
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($system, $admins)) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, [System.Security.AccessControl.FileSystemRights]::FullControl,
                $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
            $security.AddAccessRule($rule)
        }
        $info = [System.IO.DirectoryInfo]::new($Path)
        [System.IO.FileSystemAclExtensions]::Create($info, $security)
        # Owner = Administrators so the creating account's implicit owner rights do not outlive elevation.
        try {
            $info.Refresh()
            $ownerSecurity = [System.IO.FileSystemAclExtensions]::GetAccessControl($info, [System.Security.AccessControl.AccessControlSections]::Owner)
            $ownerSecurity.SetOwner($admins)
            [System.IO.FileSystemAclExtensions]::SetAccessControl($info, $ownerSecurity)
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Set Administrators owner on '$Path'"
        }
        return @{ Ok = $true; Message = "Created admin-only folder: $Path" }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Create admin-only folder '$Path'"
        return @{ Ok = $false; Message = "Could not create admin-only folder '$Path': $($_.Exception.Message)" }
    }
}

function Test-FslFixStateRoot {
    <#
    .SYNOPSIS
        Verifies (and with -Create creates) the rollback store root. Returns @{ Ok; Message; Path; IsProtected }.
    .DESCRIPTION
        Windows: requires elevation for -Create; creates missing folders (toolkit parent and StateRoot) admin-only; an
        existing StateRoot or toolkit-created parent is refused when owned by a non-admin principal or when a non-admin
        principal has write-type rights or when it is a reparse point. A folder owned by the current elevated account is
        re-owned to Administrators (-Create only) and verified again.
        Non-Windows (tests only): plain folder, IsProtected = $false, reported in Message.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [switch] $Create
    )

    try {
        $root = Resolve-FslFixStateRoot
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Resolve repair StateRoot'
        return @{ Ok = $false; Message = $_.Exception.Message; Path = $null; IsProtected = $false }
    }

    if (-not (Test-FslIsWindows)) {
        try {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                if (-not $Create) { return @{ Ok = $false; Message = "StateRoot does not exist: $root"; Path = $root; IsProtected = $false } }
                $null = New-Item -Path $root -ItemType Directory -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
            }
            return @{ Ok = $true; Message = "Non-Windows: plain StateRoot folder without ACL protection (tests only): $root"; Path = $root; IsProtected = $false }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Create StateRoot '$root'"
            return @{ Ok = $false; Message = "StateRoot not available: $($_.Exception.Message)"; Path = $root; IsProtected = $false }
        }
    }

    $isElevated = [bool](Test-FslElevation)
    if ($Create -and -not $isElevated) {
        return @{ Ok = $false; Message = 'Creating the repair StateRoot requires elevation.'; Path = $root; IsProtected = $false }
    }

    # Folders to secure: the toolkit parent (when it is not a drive root / ProgramData itself) and the StateRoot.
    $folders = [System.Collections.Generic.List[string]]::new()
    $parent = [System.IO.Path]::GetDirectoryName($root.TrimEnd('\', '/'))
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    if (-not [string]::IsNullOrEmpty($parent) -and
        -not [string]::Equals($parent.TrimEnd('\'), [string]([System.IO.Path]::GetPathRoot($parent)).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::Equals($parent.TrimEnd('\'), ([string]$programData).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        $folders.Add($parent)
    }
    $folders.Add($root)

    $currentSid = Get-FslFixCurrentUserSid
    foreach ($folder in $folders) {
        if (-not [System.IO.Directory]::Exists($folder)) {
            if (-not $Create) { return @{ Ok = $false; Message = "StateRoot folder does not exist: $folder"; Path = $root; IsProtected = $false } }
            $grandParent = [System.IO.Path]::GetDirectoryName($folder)
            if (-not [string]::IsNullOrEmpty($grandParent) -and -not [System.IO.Directory]::Exists($grandParent)) {
                return @{ Ok = $false; Message = "Parent folder does not exist: $grandParent"; Path = $root; IsProtected = $false }
            }
            $created = New-FslFixProtectedDirectory -Path $folder
            if (-not $created['Ok']) { return @{ Ok = $false; Message = $created['Message']; Path = $root; IsProtected = $false } }
            Write-FslLog -Message $created['Message'] -Level Info -Component 'Repair'
        }
        $check = Test-FslFixFolderSecurity -Path $folder
        if (-not $check['Ok'] -and $Create -and $isElevated -and $null -ne $currentSid -and $check['Owner'] -eq $currentSid) {
            try {
                $info = [System.IO.DirectoryInfo]::new($folder)
                $ownerSecurity = [System.IO.FileSystemAclExtensions]::GetAccessControl($info, [System.Security.AccessControl.AccessControlSections]::Owner)
                $ownerSecurity.SetOwner([System.Security.Principal.SecurityIdentifier]::new($script:FslFixSidAdministrators))
                [System.IO.FileSystemAclExtensions]::SetAccessControl($info, $ownerSecurity)
                $check = Test-FslFixFolderSecurity -Path $folder
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Re-own '$folder' to Administrators"
            }
        }
        if (-not $check['Ok']) {
            Write-FslLog -Message "Repair StateRoot refused: $($check['Message'])" -Level Warning -Component 'Repair'
            return @{ Ok = $false; Message = "Repair StateRoot refused: $($check['Message'])"; Path = $root; IsProtected = $false }
        }
    }
    return @{ Ok = $true; Message = "StateRoot is admin-only: $root"; Path = $root; IsProtected = $true }
}

function Get-FslFixRunStatePath {
    <#
    .SYNOPSIS
        Returns <StateRoot>/<RunId> (RunId normalized to the 'D' GUID format).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [guid] $RunId
    )

    return (Join-Path -Path (Resolve-FslFixStateRoot) -ChildPath $RunId.ToString('D'))
}

function Enter-FslFixRunLock {
    <#
    .SYNOPSIS
        Takes the single-run lock: <StateRoot>/repair.lock opened with FileShare.None. Returns the FileStream or throws.
    .DESCRIPTION
        FileShare.None: "Any request to open the file (by this process or another process) will fail until the file is
        closed." The handle is released by Exit-FslFixRunLock or by the OS when the process ends (no stale lock).
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileStream])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StateRoot,

        [Parameter(Mandatory)]
        [guid] $RunId
    )

    $lockPath = Join-Path -Path $StateRoot -ChildPath $script:FslFixLockFileName
    try {
        $stream = [System.IO.FileStream]::new($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        throw "Another repair run holds the repair lock ($lockPath). Only one repair run at a time is allowed."
    }
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(('RunId={0}; ProcessId={1}; Started={2}' -f $RunId.ToString('D'), $PID, (Get-Date).ToString('o')))
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Write repair lock details'
    }
    return $stream
}

function Exit-FslFixRunLock {
    <#
    .SYNOPSIS
        Releases the single-run lock held by a run context (idempotent).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [object] $Run
    )

    try {
        if ($null -ne $Run.LockHandle) {
            $Run.LockHandle.Dispose()
            $Run.LockHandle = $null
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context 'Release repair lock'
    }
}

function Test-FslFixSecretFree {
    <#
    .SYNOPSIS
        Returns $true when no string inside the value would be changed by secret redaction.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) { return $true }
    $text = ConvertTo-FslFixJson -InputObject $InputObject -Compress
    return ([string](ConvertTo-FslCoreRedactedText -Text $text) -ceq [string]$text)
}

function Read-FslFixRollbackDocument {
    <#
    .SYNOPSIS
        Reads <StateRoot>/<RunId>/rollback.json as a hashtable. Verifies integrity first unless -SkipIntegrity.
        Returns $null when missing or when integrity fails (error recorded).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [guid] $RunId,

        [switch] $SkipIntegrity
    )

    try {
        $statePath = Get-FslFixRunStatePath -RunId $RunId
        $rollbackPath = Join-Path -Path $statePath -ChildPath $script:FslFixRollbackFileName
        if (-not [System.IO.File]::Exists($rollbackPath)) { return $null }
        if (-not $SkipIntegrity -and -not (Test-FslFixRollbackIntegrity -RunId $RunId)) {
            Write-FslLog -Message "Rollback store integrity check failed for run $RunId - entries not returned." -Level Error -Component 'Repair'
            return $null
        }
        return (ConvertFrom-FslFixJson -Json ([System.IO.File]::ReadAllText($rollbackPath)))
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Read rollback store for run $RunId"
        return $null
    }
}

function Write-FslFixRollbackDocument {
    <#
    .SYNOPSIS
        Writes rollback.json (temp file + replace) and manifest.sha256, then re-reads both and verifies. Throws on failure.
    .DESCRIPTION
        manifest.sha256 format: "<SHA256 hex>  rollback.json" (one line). Internal toolkit state write.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StatePath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Document
    )

    if (-not [System.IO.Directory]::Exists($StatePath)) {
        $null = New-Item -Path $StatePath -ItemType Directory -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
    }
    $rollbackPath = Join-Path -Path $StatePath -ChildPath $script:FslFixRollbackFileName
    $manifestPath = Join-Path -Path $StatePath -ChildPath $script:FslFixManifestFileName
    $tempPath = Join-Path -Path $StatePath -ChildPath ('rollback.{0}.tmp' -f [guid]::NewGuid().ToString('N'))

    $Document['UpdatedAt'] = (Get-Date).ToString('o')
    $json = ConvertTo-FslFixJson -InputObject $Document
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    $hash = Get-FslFixSha256 -Bytes $bytes
    try {
        [System.IO.File]::WriteAllBytes($tempPath, $bytes)
        [System.IO.File]::Move($tempPath, $rollbackPath, $true)
    }
    finally {
        if ([System.IO.File]::Exists($tempPath)) { try { [System.IO.File]::Delete($tempPath) } catch { $null = $_ } }
    }
    [System.IO.File]::WriteAllText($manifestPath, ('{0}  {1}' -f $hash, $script:FslFixRollbackFileName), [System.Text.UTF8Encoding]::new($false))

    # Re-read verification: stored bytes hash and manifest content must both match what was written.
    $readHash = Get-FslFixSha256 -Path $rollbackPath
    $manifestHash = Get-FslFixManifestHash -Path $manifestPath
    if ($readHash -ne $hash -or $manifestHash -ne $hash) {
        throw "Rollback store verification failed after write ($rollbackPath): written $hash, read $readHash, manifest $manifestHash."
    }
    return $hash
}

function Get-FslFixManifestHash {
    <#
    .SYNOPSIS
        Returns the hash recorded in manifest.sha256 (upper case) or $null when missing/malformed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (-not [System.IO.File]::Exists($Path)) { return $null }
    $line = ([System.IO.File]::ReadAllText($Path)).Trim()
    $match = [regex]::Match($line, '^(?<hash>[0-9A-Fa-f]{64})\s+rollback\.json$')
    if (-not $match.Success) { return $null }
    return $match.Groups['hash'].Value.ToUpperInvariant()
}

function New-FslFixRollbackDocument {
    <#
    .SYNOPSIS
        Creates the initial rollback.json + manifest for a run (Apply/Undo) and returns the SHA256.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal toolkit state/log write inside an already confirmed repair run; must not be skipped by an inherited WhatIf/Confirm preference.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Run
    )

    $document = [ordered]@{
        SchemaVersion   = 1
        RunId           = $Run.RunId
        ComputerName    = $Run.ComputerName
        Mode            = $Run.Mode
        RollbackOfRunId = $Run.RollbackOfRunId
        ChangeReference = $Run.ChangeReference
        Operator        = [ordered]@{ Name = $Run.Operator.Name; Sid = $Run.Operator.Sid }
        StartedAt       = $Run.StartedAt
        UpdatedAt       = $null
        Entries         = [ordered]@{}
    }
    return (Write-FslFixRollbackDocument -StatePath $Run.StatePath -Document $document)
}

function Save-FslFixRollbackEntry {
    <#
    .SYNOPSIS
        Writes/updates the rollback entry for an action in rollback.json and refreshes manifest.sha256 (verified re-read).
        Call BEFORE applying the change. Throws when the entry cannot be stored safely (the change must not proceed).
    .DESCRIPTION
        Entry: ActionId, BeforeState, AfterState, Created, Timestamp, Temporary, ExpiresAt, Reverted, RevertedByRunId,
        RevertedAt. Temporary = -Temporary or BeforeState/AfterState key 'Temporary' = $true (retention never prunes an
        unreverted temporary change). Refuses when the existing store fails integrity, when the run has no state folder
        (WhatIf runs) or when a state value contains secret patterns (values are never redacted in the store because
        they must restore exactly, so secrets are refused instead of stored).
        Returns [pscustomobject] RunId, ActionId, RollbackPath, ManifestPath, Sha256, RollbackRef.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal toolkit state/log write inside an already confirmed repair run; must not be skipped by an inherited WhatIf/Confirm preference.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Run,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ActionId,

        [Parameter(Mandatory)]
        [hashtable] $BeforeState,

        [hashtable] $AfterState,

        [AllowEmptyCollection()]
        [string[]] $Created = @(),

        [switch] $Temporary,

        [Nullable[datetime]] $ExpiresAt
    )

    if ([string]::IsNullOrEmpty([string]$Run.StatePath) -or $Run.Mode -eq 'WhatIf') {
        throw "Run $($Run.RunId) has no rollback store (mode $($Run.Mode)); rollback entries are written only for Apply/Undo runs."
    }
    if (-not (Test-FslFixSecretFree -InputObject $BeforeState) -or -not (Test-FslFixSecretFree -InputObject $AfterState) -or
        -not (Test-FslFixSecretFree -InputObject $Created)) {
        # The literal key names are NOT put in this message: it is written to the redacted repair log, where the
        # redaction pattern would garble them ("AccountKey=***REDACTED***").
        throw "Rollback state for $ActionId contains an Azure Storage secret (a storage account key, a shared access signature or a SAS signature parameter) and is not stored, so the change was not applied."
    }

    $runId = [guid]$Run.RunId
    $rollbackPath = Join-Path -Path $Run.StatePath -ChildPath $script:FslFixRollbackFileName
    $manifestPath = Join-Path -Path $Run.StatePath -ChildPath $script:FslFixManifestFileName
    if ([System.IO.File]::Exists($rollbackPath)) {
        if (-not (Test-FslFixRollbackIntegrity -RunId $runId)) {
            throw "Rollback store for run $runId failed integrity verification; refusing to update it."
        }
        $document = ConvertFrom-FslFixJson -Json ([System.IO.File]::ReadAllText($rollbackPath))
    }
    else {
        $null = New-FslFixRollbackDocument -Run $Run
        $document = ConvertFrom-FslFixJson -Json ([System.IO.File]::ReadAllText($rollbackPath))
    }
    if (-not $document.Contains('Entries') -or $null -eq $document['Entries']) { $document['Entries'] = [ordered]@{} }

    $isTemporary = [bool]$Temporary
    foreach ($state in @($BeforeState, $AfterState)) {
        if ($null -ne $state -and $state.ContainsKey('Temporary') -and [bool]$state['Temporary']) { $isTemporary = $true }
    }
    $existing = if ($document['Entries'].Contains($ActionId)) { $document['Entries'][$ActionId] } else { $null }
    $entry = [ordered]@{
        ActionId        = $ActionId
        BeforeState     = $BeforeState
        AfterState      = $AfterState
        Created         = @($Created)
        Timestamp       = (Get-Date).ToString('o')
        Temporary       = $isTemporary
        ExpiresAt       = if ($null -ne $ExpiresAt) { ([datetime]$ExpiresAt).ToString('o') } else { $null }
        Reverted        = $false
        RevertedByRunId = $null
        RevertedAt      = $null
    }
    if ($null -ne $existing) {
        if ($existing.Contains('Temporary') -and [bool]$existing['Temporary']) { $entry['Temporary'] = $true }
        if ($null -eq $ExpiresAt -and $existing.Contains('ExpiresAt')) { $entry['ExpiresAt'] = $existing['ExpiresAt'] }
    }
    $document['Entries'][$ActionId] = $entry

    $hash = Write-FslFixRollbackDocument -StatePath $Run.StatePath -Document $document
    Write-FslLog -Message "Rollback entry saved for $ActionId (run $runId, sha256 $hash)" -Level Info -Component 'Repair'
    [pscustomobject]@{
        RunId        = $runId.ToString('D')
        ActionId     = $ActionId
        RollbackPath = $rollbackPath
        ManifestPath = $manifestPath
        Sha256       = $hash
        RollbackRef  = ('{0}/{1}' -f $runId.ToString('D'), $ActionId)
    }
}

function Test-FslFixRollbackIntegrity {
    <#
    .SYNOPSIS
        Recomputes SHA256 of <StateRoot>/<RunId>/rollback.json and compares with manifest.sha256; also checks the stored
        RunId and (Windows) that the StateRoot is still admin-only. Returns [bool]. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [guid] $RunId
    )

    try {
        if (Test-FslIsWindows) {
            $rootCheck = Test-FslFixStateRoot
            if (-not $rootCheck['Ok']) {
                Write-FslLog -Message "Rollback integrity: StateRoot not trusted ($($rootCheck['Message']))" -Level Warning -Component 'Repair'
                return $false
            }
        }
        $statePath = Get-FslFixRunStatePath -RunId $RunId
        $rollbackPath = Join-Path -Path $statePath -ChildPath $script:FslFixRollbackFileName
        $manifestPath = Join-Path -Path $statePath -ChildPath $script:FslFixManifestFileName
        if (-not [System.IO.File]::Exists($rollbackPath) -or -not [System.IO.File]::Exists($manifestPath)) {
            Write-FslLog -Message "Rollback integrity: rollback.json or manifest.sha256 missing for run $RunId" -Level Warning -Component 'Repair'
            return $false
        }
        $expected = Get-FslFixManifestHash -Path $manifestPath
        $actual = Get-FslFixSha256 -Path $rollbackPath
        if ($null -eq $expected -or $expected -ne $actual) {
            Write-FslLog -Message "Rollback integrity: SHA256 mismatch for run $RunId (manifest $expected, actual $actual)" -Level Warning -Component 'Repair'
            return $false
        }
        $document = ConvertFrom-FslFixJson -Json ([System.IO.File]::ReadAllText($rollbackPath))
        if (-not ($document -is [System.Collections.IDictionary]) -or -not $document.Contains('RunId') -or
            -not [string]::Equals([string]$document['RunId'], $RunId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-FslLog -Message "Rollback integrity: RunId inside rollback.json does not match $RunId" -Level Warning -Component 'Repair'
            return $false
        }
        return $true
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Repair' -Context "Verify rollback integrity for run $RunId"
        return $false
    }
}

function Get-FslFixRollbackEntry {
    <#
    .SYNOPSIS
        Returns rollback entries (pscustomobject: RunId, ActionId, BeforeState, AfterState (hashtables), Created, Timestamp,
        Temporary, ExpiresAt, Reverted, RevertedByRunId, RevertedAt) for a run. Nothing is returned when integrity fails.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [guid] $RunId,

        [string[]] $ActionId
    )

    $document = Read-FslFixRollbackDocument -RunId $RunId
    if ($null -eq $document -or -not $document.Contains('Entries') -or $null -eq $document['Entries']) { return }
    foreach ($key in @($document['Entries'].Keys)) {
        if ($ActionId -and $ActionId -notcontains $key) { continue }
        $entry = $document['Entries'][$key]
        [pscustomobject]@{
            PSTypeName      = 'FSLogixToolkit.RollbackEntry'
            RunId           = $RunId.ToString('D')
            ActionId        = [string]$entry['ActionId']
            BeforeState     = ConvertTo-FslFixHashtable -InputObject $entry['BeforeState']
            AfterState      = ConvertTo-FslFixHashtable -InputObject $entry['AfterState']
            Created         = @($entry['Created'] | Where-Object -FilterScript { $null -ne $_ } | ForEach-Object -Process { [string]$_ })
            Timestamp       = [string]$entry['Timestamp']
            Temporary       = [bool]$entry['Temporary']
            ExpiresAt       = $entry['ExpiresAt']
            Reverted        = [bool]$entry['Reverted']
            RevertedByRunId = $entry['RevertedByRunId']
            RevertedAt      = $entry['RevertedAt']
        }
    }
}

function ConvertTo-FslFixHashtable {
    <#
    .SYNOPSIS
        Converts an ordered dictionary (from ConvertFrom-FslFixJson) to a [hashtable] (recursively); $null stays $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) { return $null }
    if (-not ($InputObject -is [System.Collections.IDictionary])) { return $null }
    $table = @{}
    foreach ($key in $InputObject.Keys) {
        $value = $InputObject[$key]
        if ($value -is [System.Collections.IDictionary]) { $value = ConvertTo-FslFixHashtable -InputObject $value }
        $table[$key] = $value
    }
    return $table
}

function Set-FslFixRollbackReverted {
    <#
    .SYNOPSIS
        Marks rollback entries of an original run as reverted by an Undo run (rollback.json + manifest refreshed).
        Refuses when integrity fails. Returns the number of entries marked.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal toolkit state/log write inside an already confirmed repair run; must not be skipped by an inherited WhatIf/Confirm preference.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [guid] $RunId,

        [Parameter(Mandatory)]
        [string[]] $ActionId,

        [Parameter(Mandatory)]
        [guid] $UndoRunId
    )

    $document = Read-FslFixRollbackDocument -RunId $RunId
    if ($null -eq $document) {
        Write-FslLog -Message "Cannot mark reverted actions: rollback store for run $RunId missing or failed integrity." -Level Warning -Component 'Repair'
        return 0
    }
    $count = 0
    foreach ($id in $ActionId) {
        if ($null -ne $document['Entries'] -and $document['Entries'].Contains($id)) {
            $document['Entries'][$id]['Reverted'] = $true
            $document['Entries'][$id]['RevertedByRunId'] = $UndoRunId.ToString('D')
            $document['Entries'][$id]['RevertedAt'] = (Get-Date).ToString('o')
            $count++
        }
    }
    if ($count -gt 0) {
        $null = Write-FslFixRollbackDocument -StatePath (Get-FslFixRunStatePath -RunId $RunId) -Document $document
    }
    return $count
}
