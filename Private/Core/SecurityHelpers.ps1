# Core security helpers (Agent P3-2, contract PHASE 3 P3.1 item 3): toolkit folder ACL/owner evaluation and account display.
# Evaluation is done by SID (never by localized account names).
# Sources:
#   https://learn.microsoft.com/dotnet/api/system.security.accesscontrol.filesystemrights
#   https://learn.microsoft.com/dotnet/api/system.security.accesscontrol.propagationflags
#   https://learn.microsoft.com/dotnet/api/system.io.filesystemaclextensions.getaccesscontrol
#   https://learn.microsoft.com/dotnet/api/system.security.accesscontrol.commonobjectsecurity.getaccessrules
#   https://learn.microsoft.com/dotnet/api/system.security.accesscontrol.objectsecurity.getowner
#   https://learn.microsoft.com/windows/win32/secauthz/access-mask
#   https://learn.microsoft.com/windows/win32/fileio/file-security-and-access-rights
#   https://learn.microsoft.com/windows/win32/fileio/file-access-rights-constants
#     (FILE_DELETE_CHILD, 64 (0x40): "For a directory, the right to delete a directory and all the files it contains,
#      including read-only files." - why every folder ABOVE the toolkit root is checked with the 'Replace' right set.)
#   https://learn.microsoft.com/windows-server/identity/ad-ds/manage/understand-security-identifiers

# Principals allowed to hold write-type rights / ownership (contract P3.1 item 3).
#   S-1-5-32-544 Administrators, S-1-5-18 SYSTEM (understand-security-identifiers),
#   S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464 NT SERVICE\TrustedInstaller (service SID = S-1-5-80 +
#   SHA-1 of the upper-case service name; value recomputed locally for 'TRUSTEDINSTALLER' during the build).
$script:FslCoreTrustedSids = @(
    'S-1-5-32-544'
    'S-1-5-18'
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
)
# CREATOR OWNER (S-1-3-0) is accepted only on inherit-only ACEs.
$script:FslCoreCreatorOwnerSid = 'S-1-3-0'

# Write-type access mask bits (ACCESS_MASK / FileSystemRights). Any of these on an Allow ACE is "write-type".
$script:FslCoreWriteRightBits = [ordered]@{
    'WriteData/CreateFiles'          = [long]0x00000002
    'AppendData/CreateDirectories'   = [long]0x00000004
    'WriteExtendedAttributes'        = [long]0x00000010
    'DeleteSubdirectoriesAndFiles'   = [long]0x00000040
    'WriteAttributes'                = [long]0x00000100
    'Delete'                         = [long]0x00010000
    'ChangePermissions'              = [long]0x00040000
    'TakeOwnership'                  = [long]0x00080000
    'AccessSystemSecurity'           = [long]0x01000000
    'MaximumAllowed'                 = [long]0x02000000
    'Reserved(bits 26-27)'           = [long]0x0C000000
    'GenericAll'                     = [long]0x10000000
    'GenericWrite'                   = [long]0x40000000
}

# Rights that let a principal REPLACE a child object of a folder without holding any right on the child itself:
# FILE_DELETE_CHILD deletes/renames the child subtree, WRITE_DAC and WRITE_OWNER lead to it, GENERIC_ALL and
# MAXIMUM_ALLOWED contain them. Used for the parent of the toolkit root only: the default C:\ ACL grants
# BUILTIN\Users "create folders / append data", which is a write-type right but does not allow replacing the toolkit.
$script:FslCoreReplaceRightBits = [ordered]@{
    'DeleteSubdirectoriesAndFiles' = [long]0x00000040
    'ChangePermissions'            = [long]0x00040000
    'TakeOwnership'                = [long]0x00080000
    'MaximumAllowed'               = [long]0x02000000
    'GenericAll'                   = [long]0x10000000
}

function ConvertTo-FslCoreAccessMask {
    <#
    .SYNOPSIS
        Converts a FileSystemRights value (or number) to an unsigned 32-bit access mask stored in [long].
    .DESCRIPTION
        GENERIC_READ (bit 31) makes the signed enum value negative; the bytes are reinterpreted as UInt32.
        Returns $null when the value cannot be converted. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Rights
    )

    try {
        if ($null -eq $Rights) { return $null }
        $asLong = [long]0
        if ($Rights -is [System.Enum]) { $asLong = [long][int]$Rights }
        elseif ($Rights -is [int] -or $Rights -is [long] -or $Rights -is [uint32] -or $Rights -is [int16] -or $Rights -is [byte]) { $asLong = [long]$Rights }
        elseif ($Rights -is [string]) {
            if (-not [long]::TryParse($Rights, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$asLong)) { return $null }
        }
        else { return $null }
        if ($asLong -lt [int]::MinValue -or $asLong -gt [uint32]::MaxValue) { return $null }
        if ($asLong -lt 0) {
            return [long][BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$asLong), 0)
        }
        return $asLong
    }
    catch {
        return $null
    }
}

function Get-FslCoreWriteRightName {
    <#
    .SYNOPSIS
        Returns the names of the relevant rights contained in an access mask (empty when none).
    .PARAMETER RightSet
        Write (default): every write-type right. Replace: only the rights that let a principal replace a child object
        of this folder (used for the parent of the toolkit root).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [long] $Mask,

        [ValidateSet('Write', 'Replace')]
        [string] $RightSet = 'Write'
    )

    $bits = if ($RightSet -eq 'Replace') { $script:FslCoreReplaceRightBits } else { $script:FslCoreWriteRightBits }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $bits.GetEnumerator()) {
        if (($Mask -band [long]$entry.Value) -ne 0) { $names.Add([string]$entry.Key) }
    }
    return [string[]]$names.ToArray()
}

function Test-FslCoreAclEntrySet {
    <#
    .SYNOPSIS
        Pure evaluation of an owner SID and access rules against the toolkit folder security policy.
    .DESCRIPTION
        Input is plain data (no Windows APIs), so the logic is testable on any platform.
        -Rule items (hashtable or object) carry:
          Sid               SID string (S-1-...) or $null/empty when the identity could not be resolved to a SID
          Rights            access mask (FileSystemRights value or number)
          AccessControlType 'Allow' | 'Deny'
          PropagationFlags  number or PropagationFlags value (InheritOnly = 2)
          InheritanceFlags  number or InheritanceFlags value (optional)
        Rules:
          - Deny ACEs never grant access and are ignored.
          - Allow ACEs whose mask contains any write-type bit (WriteData/CreateFiles, AppendData/CreateDirectories,
            WriteExtendedAttributes, DeleteSubdirectoriesAndFiles, WriteAttributes, Delete, ChangePermissions,
            TakeOwnership, GENERIC_WRITE, GENERIC_ALL, plus ACCESS_SYSTEM_SECURITY / MAXIMUM_ALLOWED / reserved bits as a
            safe default) are findings unless the SID is Administrators, SYSTEM or TrustedInstaller, or the SID is
            CREATOR OWNER on an inherit-only ACE.
          - Inherit-only ACEs are evaluated on containers (they reach child items); on files (no children) they are ignored.
          - Unresolvable SID, unknown ACE type or unreadable mask -> finding (safe default).
          - Owner must be Administrators, SYSTEM or TrustedInstaller; unknown owner -> finding.
        Returns [pscustomobject] IsSecure (bool), OwnerSid, OwnerOk (bool), Findings (object[]: Sid, Rights (long),
        RightNames (string), InheritOnly (bool), Reason).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $OwnerSid,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Rule,

        [bool] $IsContainer = $true,

        [ValidateSet('Write', 'Replace')]
        [string] $RightSet = 'Write'
    )

    $sidPattern = '^S-1-\d+(-\d+)+$'
    $findings = [System.Collections.Generic.List[object]]::new()

    $ownerOk = $false
    if (-not [string]::IsNullOrWhiteSpace($OwnerSid) -and $OwnerSid.Trim() -match $sidPattern) {
        $ownerOk = $script:FslCoreTrustedSids -contains $OwnerSid.Trim().ToUpperInvariant()
    }

    foreach ($item in @($Rule)) {
        if ($null -eq $item) { continue }
        $get = {
            param($Name)
            if ($item -is [System.Collections.IDictionary]) { if ($item.Contains($Name)) { return $item[$Name] } else { return $null } }
            $property = $item.PSObject.Properties[$Name]
            if ($null -ne $property) { return $property.Value }
            return $null
        }

        $sid = [string](& $get 'Sid')
        $typeText = [string](& $get 'AccessControlType')
        $mask = ConvertTo-FslCoreAccessMask -Rights (& $get 'Rights')
        $propagationValue = & $get 'PropagationFlags'
        $propagation = 0
        if ($null -ne $propagationValue) {
            $converted = ConvertTo-FslCoreAccessMask -Rights $propagationValue
            if ($null -ne $converted) { $propagation = [long]$converted }
        }
        $inheritOnly = (($propagation -band 2) -ne 0)

        if ($typeText -eq 'Deny') { continue }

        if ($typeText -ne 'Allow') {
            $findings.Add([pscustomobject]@{ Sid = $sid; Rights = $mask; RightNames = ''; InheritOnly = $inheritOnly; Reason = "Unknown access control type '$typeText' (treated as unsafe)." })
            continue
        }
        if ($null -eq $mask) {
            $findings.Add([pscustomobject]@{ Sid = $sid; Rights = $null; RightNames = ''; InheritOnly = $inheritOnly; Reason = 'Access mask could not be read (treated as unsafe).' })
            continue
        }

        $rightNames = @(Get-FslCoreWriteRightName -Mask $mask -RightSet $RightSet)
        if ($rightNames.Count -eq 0) { continue }

        if ([string]::IsNullOrWhiteSpace($sid) -or $sid.Trim() -notmatch $sidPattern) {
            $findings.Add([pscustomobject]@{ Sid = $sid; Rights = $mask; RightNames = ($rightNames -join ', '); InheritOnly = $inheritOnly; Reason = 'Principal could not be resolved to a SID (treated as unsafe).' })
            continue
        }
        $sidUpper = $sid.Trim().ToUpperInvariant()

        if ($inheritOnly -and -not $IsContainer) { continue }   # no child objects: an inherit-only ACE has no effect on a file
        if ($script:FslCoreTrustedSids -contains $sidUpper) { continue }
        if ($sidUpper -eq $script:FslCoreCreatorOwnerSid -and $inheritOnly) { continue }

        $rightKind = if ($RightSet -eq 'Replace') { 'Rights that allow replacing the toolkit folder' } else { 'Write-type rights' }
        $reason = if ($inheritOnly) { "$rightKind inherited by child items (inherit-only ACE)." } else { "$rightKind granted to a principal that is not Administrators, SYSTEM or TrustedInstaller." }
        $findings.Add([pscustomobject]@{ Sid = $sidUpper; Rights = $mask; RightNames = ($rightNames -join ', '); InheritOnly = $inheritOnly; Reason = $reason })
    }

    [pscustomobject]@{
        IsSecure = ($ownerOk -and $findings.Count -eq 0)
        OwnerSid = $OwnerSid
        OwnerOk  = $ownerOk
        Findings = [object[]]$findings.ToArray()
    }
}

function Resolve-FslCoreSidDisplayName {
    <#
    .SYNOPSIS
        Returns 'NAME (SID)' for display (Windows only); the SID itself when translation fails. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Sid
    )

    if ([string]::IsNullOrWhiteSpace($Sid)) { return '<unresolved principal>' }
    if (-not (Test-FslIsWindows)) { return $Sid }
    try {
        $identifier = [System.Security.Principal.SecurityIdentifier]::new($Sid)
        $account = $identifier.Translate([System.Security.Principal.NTAccount])
        return ('{0} ({1})' -f $account.Value, $Sid)
    }
    catch {
        return $Sid
    }
}

function Get-FslCoreItemSecurityData {
    <#
    .SYNOPSIS
        Reads owner SID and access rules of a file or folder as plain data for Test-FslCoreAclEntrySet (Windows only).
    .DESCRIPTION
        Uses FileSystemAclExtensions.GetAccessControl with AccessControlSections Owner|Access, ObjectSecurity.GetOwner and
        CommonObjectSecurity.GetAccessRules(includeExplicit, includeInherited, [SecurityIdentifier]) so identities are
        SIDs. Throws on failure (caller records the error and reports Error/Fail).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LiteralPath
    )

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    $sections = [System.Security.AccessControl.AccessControlSections]::Owner -bor [System.Security.AccessControl.AccessControlSections]::Access
    $isContainer = [bool]$item.PSIsContainer
    $security = if ($isContainer) {
        [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.DirectoryInfo]$item, $sections)
    }
    else {
        [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.FileInfo]$item, $sections)
    }

    $ownerSid = $null
    try {
        $owner = $security.GetOwner([System.Security.Principal.SecurityIdentifier])
        if ($null -ne $owner) { $ownerSid = $owner.Value }
    }
    catch { $ownerSid = $null }

    $rules = foreach ($rule in $security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        $sid = $null
        try { $sid = [string]$rule.IdentityReference.Value } catch { $sid = $null }
        @{
            Sid               = $sid
            Rights            = $rule.FileSystemRights
            AccessControlType = [string]$rule.AccessControlType
            PropagationFlags  = [int]$rule.PropagationFlags
            InheritanceFlags  = [int]$rule.InheritanceFlags
        }
    }

    [pscustomobject]@{
        FullName    = $item.FullName
        IsContainer = $isContainer
        OwnerSid    = $ownerSid
        Rules       = @($rules)
    }
}

function Get-FslCoreToolkitSecurityTarget {
    <#
    .SYNOPSIS
        Returns the toolkit paths checked by Test-FslToolkitPathSecurity (contract P3.1 item 3).
    .DESCRIPTION
        Named targets: module root; Modules, Config, Public, Private, GUI folders; Start-FSLogixToolkit.ps1,
        FSLogixToolkit.psm1, FSLogixToolkit.psd1. Plus EVERY ANCESTOR of the module root up to the drive/share root,
        evaluated with the 'Replace' right set only: a principal that can delete or rename the toolkit folder - or any
        folder above it - can replace every file in it without holding a single right on the folder itself
        (FILE_DELETE_CHILD is documented as "the right to delete a directory and all the files it contains", so the
        whole chain matters, not only the immediate parent). The immediate parent keeps the name ModuleRootParent;
        higher ancestors are reported as ModuleRootAncestor (the path is in Target). Returns objects: Name, Path, Kind
        (Container|Leaf), Descend (bool: descendants are also checked because the module dot-sources/loads them),
        RightSet (Write|Replace).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Root
    )

    $separators = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $current = $Root
    $isImmediateParent = $true
    # Walk up to the drive / UNC share root. GetDirectoryName returns $null at the root, so the loop always ends;
    # the guard on repeated values protects against a path shape that does not shrink.
    for ($depth = 0; $depth -lt 64; $depth++) {
        $parent = $null
        try { $parent = [System.IO.Path]::GetDirectoryName($current.TrimEnd($separators)) } catch { $parent = $null }
        if ([string]::IsNullOrWhiteSpace($parent)) { break }
        if (-not $seen.Add($parent.TrimEnd($separators))) { break }
        $name = if ($isImmediateParent) { 'ModuleRootParent' } else { 'ModuleRootAncestor' }
        [pscustomobject]@{ Name = $name; Path = $parent; Kind = 'Container'; Descend = $false; RightSet = 'Replace' }
        $isImmediateParent = $false
        $current = $parent
    }
    [pscustomobject]@{ Name = 'ModuleRoot'; Path = $Root; Kind = 'Container'; Descend = $false; RightSet = 'Write' }
    foreach ($folder in @('Modules', 'Config', 'Public', 'Private', 'GUI')) {
        [pscustomobject]@{ Name = $folder; Path = (Join-Path -Path $Root -ChildPath $folder); Kind = 'Container'; Descend = $true; RightSet = 'Write' }
    }
    foreach ($file in @('Start-FSLogixToolkit.ps1', 'FSLogixToolkit.psm1', 'FSLogixToolkit.psd1')) {
        [pscustomobject]@{ Name = $file; Path = (Join-Path -Path $Root -ChildPath $file); Kind = 'Leaf'; Descend = $false; RightSet = 'Write' }
    }
}

function Format-FslCoreAclFinding {
    <#
    .SYNOPSIS
        Formats an evaluation result as text: owner problem and offending principals with rights.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Evaluation
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    if (-not $Evaluation.OwnerOk) {
        $parts.Add(('Owner {0} is not Administrators, SYSTEM or TrustedInstaller' -f (Resolve-FslCoreSidDisplayName -Sid $Evaluation.OwnerSid)))
    }
    foreach ($finding in @($Evaluation.Findings)) {
        $rightsText = if ([string]::IsNullOrEmpty([string]$finding.RightNames)) { 'unknown rights' } else { [string]$finding.RightNames }
        $maskText = if ($null -ne $finding.Rights) { ' [0x{0:X8}]' -f [long]$finding.Rights } else { '' }
        $parts.Add(('{0}: {1}{2}{3}' -f (Resolve-FslCoreSidDisplayName -Sid $finding.Sid), $rightsText, $maskText, $(if ($finding.InheritOnly) { ' (inherit-only)' } else { '' })))
    }
    return ($parts -join '; ')
}

function Test-FslCoreToolkitPathSecure {
    <#
    .SYNOPSIS
        Returns $true only when the toolkit folder passes Test-FslToolkitPathSecurity (gate G3). Never throws.
    .DESCRIPTION
        $false on non-Windows (cannot be verified), on any Fail/Error result, or when the check itself fails.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    try {
        if (-not (Test-FslIsWindows)) { return $false }
        $params = @{}
        if ($PSBoundParameters.ContainsKey('Path')) { $params['Path'] = $Path }
        $results = @(Test-FslToolkitPathSecurity @params)
        if ($results.Count -eq 0) { return $false }
        $bad = @($results | Where-Object -FilterScript { $_.Status -notin @('Pass', 'Info') })
        return ($bad.Count -eq 0)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Test-FslCoreToolkitPathSecure'
        return $false
    }
}

function Get-FslCoreCurrentAccount {
    <#
    .SYNOPSIS
        Returns the account running this process as DOMAIN\User (Windows: WindowsIdentity.Name). Never throws.
    .NOTES
        Sources:
          https://learn.microsoft.com/dotnet/api/system.security.principal.windowsidentity.getcurrent
          https://learn.microsoft.com/dotnet/api/system.environment.userdomainname
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        if (Test-FslIsWindows) {
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            try { return [string]$identity.Name } finally { $identity.Dispose() }
        }
    }
    catch { $null = $_ }
    try {
        $domain = [Environment]::UserDomainName
        if ([string]::IsNullOrEmpty($domain)) { return [Environment]::UserName }
        return ('{0}\{1}' -f $domain, [Environment]::UserName)
    }
    catch {
        return '<unknown>'
    }
}
