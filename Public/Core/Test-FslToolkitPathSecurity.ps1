function Test-FslToolkitPathSecurity {
    <#
    .SYNOPSIS
        Checks that the toolkit folder cannot be changed by non-administrators (owner and Allow ACEs, evaluated by SID).
    .DESCRIPTION
        The module dot-sources every .ps1 under Private and Public and the launcher puts the Modules folder first on
        PSModulePath. When the toolkit runs elevated from a folder that standard users can write to, anyone with write
        access could plant code that runs as administrator. This function checks:
          - the module root; the Modules, Config, Public, Private and GUI folders; Start-FSLogixToolkit.ps1,
            FSLogixToolkit.psm1 and FSLogixToolkit.psd1 (one Result per item);
          - every file and subfolder below Modules, Config, Public, Private and GUI (one summary Result per folder,
            listing offending items), because those are loaded by the module or the launcher;
          - every folder above the module root, up to the drive or UNC share root (Check
            ToolkitPathSecurity:ModuleRootParent for the immediate parent, ToolkitPathSecurity:ModuleRootAncestor for
            the ones above it; the path is in Target), but only for the rights that let a principal replace the toolkit
            folder itself without holding any right on it: DeleteSubdirectoriesAndFiles (documented as "the right to
            delete a directory and all the files it contains"), ChangePermissions, TakeOwnership, MAXIMUM_ALLOWED,
            GENERIC_ALL, and the owner. The write-type rights the default C:\ ACL grants BUILTIN\Users (create folders /
            append data) are not reported there, because they do not allow deleting or renaming an existing subfolder.
        Fail when the owner is not Administrators (S-1-5-32-544), SYSTEM (S-1-5-18) or TrustedInstaller
        (S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464), or when any other principal has an Allow ACE with
        write-type rights: WriteData/CreateFiles, AppendData/CreateDirectories, WriteExtendedAttributes,
        DeleteSubdirectoriesAndFiles, WriteAttributes, Delete, ChangePermissions, TakeOwnership (these are contained in
        Write, Modify and FullControl), GENERIC_WRITE or GENERIC_ALL. CREATOR OWNER (S-1-3-0) is accepted on inherit-only
        ACEs only. Inherit-only ACEs of other principals on folders count (child items inherit them). Deny ACEs never grant
        access and are ignored. Principals that cannot be resolved to a SID, unreadable masks, ACCESS_SYSTEM_SECURITY,
        MAXIMUM_ALLOWED and reserved bits are treated as unsafe (safe default). Missing optional items are Info.
        Each offending principal is reported with its rights. Non-Windows: one Skipped Result. Never throws.
    .PARAMETER Path
        Toolkit root folder to check. Default: the folder this module was loaded from.
    .EXAMPLE
        Test-FslToolkitPathSecurity | Where-Object Status -ne 'Pass' | Format-List Target, Status, Value, Message

        Lists toolkit items that standard users could modify.
    .EXAMPLE
        Test-FslToolkitPathSecurity -Path 'C:\Program Files\FSLogixToolkit'
    .NOTES
        RequiresElevation: No (reading the security descriptor needs READ_CONTROL only; items that cannot be read are Error)
        Sources:
          https://learn.microsoft.com/dotnet/api/system.security.accesscontrol.filesystemrights
          https://learn.microsoft.com/dotnet/api/system.security.accesscontrol.propagationflags
          https://learn.microsoft.com/dotnet/api/system.io.filesystemaclextensions.getaccesscontrol
          https://learn.microsoft.com/windows/win32/secauthz/access-mask
          https://learn.microsoft.com/windows/win32/fileio/file-security-and-access-rights
          https://learn.microsoft.com/windows-server/identity/ad-ds/manage/understand-security-identifiers
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $check = 'ToolkitPathSecurity'
    $source = 'https://learn.microsoft.com/dotnet/api/system.security.accesscontrol.filesystemrights'
    $expected = 'Owner and write-type rights limited to Administrators, SYSTEM, TrustedInstaller (CREATOR OWNER inherit-only)'
    $recommendation = 'Install the toolkit in an admin-only folder such as C:\Program Files\FSLogixToolkit, or remove write-type rights of non-admin principals and set the owner to Administrators.'

    $root = if ($PSBoundParameters.ContainsKey('Path')) { $Path } else { [string]$script:FslSession['ModuleRoot'] }

    if (-not (Test-FslIsWindows)) {
        New-FslResult -Category 'Core' -Check $check -Status 'Skipped' -Target $root -Expected $expected -Message 'File system ACL checks are only available on Windows.' -Source $source
        return
    }

    try {
        $root = [System.IO.Path]::GetFullPath($root)
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            New-FslResult -Category 'Core' -Check $check -Status 'Error' -Target $root -Expected $expected -Message 'The toolkit folder was not found.' -Source $source
            return
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Test-FslToolkitPathSecurity: resolving '$root'"
        New-FslResult -Category 'Core' -Check $check -Status 'Error' -Target $root -Expected $expected -Message "The toolkit path could not be resolved: $($_.Exception.Message)" -Source $source
        return
    }

    foreach ($target in @(Get-FslCoreToolkitSecurityTarget -Root $root)) {
        $rightSet = [string]$target.RightSet
        $targetExpected = if ($rightSet -eq 'Replace') { 'Owner and rights that allow replacing the toolkit folder limited to Administrators, SYSTEM, TrustedInstaller' } else { $expected }
        $pathType = if ($target.Kind -eq 'Container') { 'Container' } else { 'Leaf' }
        if (-not (Test-Path -LiteralPath $target.Path -PathType $pathType)) {
            New-FslResult -Category 'Core' -Check "${check}:$($target.Name)" -Status 'Info' -Target $target.Path -Expected $targetExpected -Message 'Not present (nothing to check). The parent folder check covers who can create it.' -Source $source
            continue
        }

        try {
            $data = Get-FslCoreItemSecurityData -LiteralPath $target.Path
            $evaluation = Test-FslCoreAclEntrySet -OwnerSid $data.OwnerSid -Rule $data.Rules -IsContainer $data.IsContainer -RightSet $rightSet
            if ($evaluation.IsSecure) {
                $passMessage = if ($rightSet -eq 'Replace') { 'Only administrators can delete or replace the toolkit folder through this folder above it.' } else { 'Only administrators can change this item.' }
                New-FslResult -Category 'Core' -Check "${check}:$($target.Name)" -Status 'Pass' -Target $target.Path -Value ('Owner {0}' -f (Resolve-FslCoreSidDisplayName -Sid $data.OwnerSid)) -Expected $targetExpected -Message $passMessage -Source $source
            }
            else {
                $detail = Format-FslCoreAclFinding -Evaluation $evaluation
                $failMessage = if ($rightSet -eq 'Replace') {
                    "Non-admin principals can delete or replace the toolkit folder through this folder above it, so they can replace every file in it: $detail"
                }
                else { "Non-admin principals can change this item: $detail" }
                New-FslResult -Category 'Core' -Check "${check}:$($target.Name)" -Status 'Fail' -Target $target.Path -Value $detail -Expected $targetExpected -Message $failMessage -Recommendation $recommendation -Source $source
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Test-FslToolkitPathSecurity: reading ACL of '$($target.Path)'"
            New-FslResult -Category 'Core' -Check "${check}:$($target.Name)" -Status 'Error' -Target $target.Path -Expected $expected -Message "The security descriptor could not be read (treated as not secure): $($_.Exception.Message)" -Recommendation $recommendation -Source $source
            continue
        }

        if (-not $target.Descend) { continue }

        # Descendants: everything below the folder (loaded by the module / launcher).
        $checkedCount = 0
        $offending = [System.Collections.Generic.List[string]]::new()
        $errors = [System.Collections.Generic.List[string]]::new()
        try {
            $children = @(Get-ChildItem -LiteralPath $target.Path -Recurse -Force -ErrorAction Stop)
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Test-FslToolkitPathSecurity: enumerating '$($target.Path)'"
            New-FslResult -Category 'Core' -Check "${check}:$($target.Name)\*" -Status 'Error' -Target $target.Path -Expected $expected -Message "Child items could not be enumerated (treated as not secure): $($_.Exception.Message)" -Recommendation $recommendation -Source $source
            continue
        }
        foreach ($child in $children) {
            $checkedCount++
            try {
                $childData = Get-FslCoreItemSecurityData -LiteralPath $child.FullName
                $childEvaluation = Test-FslCoreAclEntrySet -OwnerSid $childData.OwnerSid -Rule $childData.Rules -IsContainer $childData.IsContainer
                if (-not $childEvaluation.IsSecure) {
                    $offending.Add(('{0} -> {1}' -f $child.FullName, (Format-FslCoreAclFinding -Evaluation $childEvaluation)))
                }
            }
            catch {
                Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Test-FslToolkitPathSecurity: reading ACL of '$($child.FullName)'"
                $errors.Add(('{0} -> {1}' -f $child.FullName, $_.Exception.Message))
            }
        }

        $childCheck = "${check}:$($target.Name)\*"
        if ($offending.Count -gt 0) {
            $shown = @($offending | Select-Object -First 20)
            $more = if ($offending.Count -gt 20) { " (+$($offending.Count - 20) more)" } else { '' }
            New-FslResult -Category 'Core' -Check $childCheck -Status 'Fail' -Target $target.Path -Value ($shown -join ' | ') -Expected $expected -Message "$($offending.Count) of $checkedCount child item(s) can be changed by non-admin principals$more." -Recommendation $recommendation -Source $source
        }
        elseif ($errors.Count -gt 0) {
            $shown = @($errors | Select-Object -First 20)
            New-FslResult -Category 'Core' -Check $childCheck -Status 'Error' -Target $target.Path -Value ($shown -join ' | ') -Expected $expected -Message "$($errors.Count) of $checkedCount child item(s) could not be checked (treated as not secure)." -Recommendation $recommendation -Source $source
        }
        else {
            New-FslResult -Category 'Core' -Check $childCheck -Status 'Pass' -Target $target.Path -Value "$checkedCount child item(s)" -Expected $expected -Message 'Only administrators can change the child items.' -Source $source
        }
    }
}
