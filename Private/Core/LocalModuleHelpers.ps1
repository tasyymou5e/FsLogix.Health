# Private helpers for the project Modules folder and module location lookup (Core).
# Sources:
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_psmodulepath
#     ("temporarily add ... to $Env:PSModulePath for the current session"; ';' on Windows, ':' elsewhere;
#      PowerShell searches <Folder>/<ModuleName>/<Version>/ and loads the highest version by default)
#   https://learn.microsoft.com/dotnet/api/system.io.path.pathseparator
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_windows_powershell_compatibility
#     (modules in %windir%\system32\WindowsPowerShell\v1.0\Modules without a Core manifest load in WinPSCompatSession)
#   https://learn.microsoft.com/dotnet/api/system.environment.systemdirectory
#   https://github.com/PowerShell/PowerShell/blob/master/src/System.Management.Automation/engine/Modules/ModuleIntrinsics.cs
#   https://github.com/PowerShell/PSResourceGet/blob/master/src/code/InstallHelper.cs (saved modules: <Path>/<Name>/<Version>)

function Test-FslCorePathInList {
    <#
    .SYNOPSIS
        Returns $true when a PSModulePath-style list contains the folder (case-insensitive, trailing separators ignored).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $PathList,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Folder
    )

    if ([string]::IsNullOrEmpty($PathList)) { return $false }
    $trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $wanted = $Folder.TrimEnd($trimChars)
    foreach ($entry in $PathList.Split([System.IO.Path]::PathSeparator)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ([string]::Equals($entry.Trim().TrimEnd($trimChars), $wanted, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-FslCoreModulesRoot {
    <#
    .SYNOPSIS
        Returns the project Modules folder (<ModuleRoot>/Modules), from the session when set.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $root = $null
    if ($script:FslSession.Contains('ModulesRoot')) { $root = [string]$script:FslSession['ModulesRoot'] }
    if ([string]::IsNullOrEmpty($root)) {
        $root = Join-Path -Path ([string]$script:FslSession['ModuleRoot']) -ChildPath 'Modules'
        try { $root = [System.IO.Path]::GetFullPath($root) } catch { $null = $_ }
        $script:FslSession['ModulesRoot'] = $root
    }
    return $root
}

function Add-FslCoreLocalModulePath {
    <#
    .SYNOPSIS
        Prepends the project Modules folder to the PROCESS $env:PSModulePath (idempotent).
    .DESCRIPTION
        Stores the folder in $script:FslSession['ModulesRoot'] and returns it. When the folder does not exist nothing is
        changed. When the folder is already on PSModulePath (case-insensitive comparison, trailing separators ignored) the
        variable is left unchanged. Only the current process environment is modified (never the registry / User / Machine
        scope). Runspaces in the same process (dashboard background runspace) see the same value. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Path
    )

    try {
        if ([string]::IsNullOrEmpty($Path)) { $Path = Get-FslCoreModulesRoot }
        else {
            try { $Path = [System.IO.Path]::GetFullPath($Path) } catch { $null = $_ }
            $script:FslSession['ModulesRoot'] = $Path
        }
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Write-FslLog -Message "Local Modules folder not found (not added to PSModulePath): $Path" -Level Verbose -Component 'Core'
            return $Path
        }
        $current = [System.Environment]::GetEnvironmentVariable('PSModulePath')
        if (Test-FslCorePathInList -PathList $current -Folder $Path) { return $Path }
        $newValue = if ([string]::IsNullOrEmpty($current)) { $Path } else { $Path + [System.IO.Path]::PathSeparator + $current }
        $env:PSModulePath = $newValue
        Write-FslLog -Message "Local Modules folder prepended to process PSModulePath: $Path" -Level Verbose -Component 'Core'
        return $Path
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Adding the local Modules folder to PSModulePath'
        return $Path
    }
}

function Test-FslCorePathUnderFolder {
    <#
    .SYNOPSIS
        Returns $true when Path is Folder or below it (case-insensitive).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Path,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Folder
    )

    if ([string]::IsNullOrEmpty($Path) -or [string]::IsNullOrEmpty($Folder)) { return $false }
    $trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $base = $Folder.TrimEnd($trimChars)
    $candidate = $Path.TrimEnd($trimChars)
    if ([string]::Equals($candidate, $base, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    foreach ($separator in $trimChars) {
        if ($candidate.StartsWith($base + $separator, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-FslCoreWindowsModuleFolder {
    <#
    .SYNOPSIS
        Returns <SystemDirectory>\WindowsPowerShell\v1.0\Modules on Windows, otherwise $null.
    .DESCRIPTION
        Environment.SystemDirectory is the value the PowerShell engine uses for its Windows PowerShell module path
        (ModuleIntrinsics.cs). Documented as %windir%\system32\WindowsPowerShell\v1.0\Modules
        (about_Windows_PowerShell_Compatibility).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not (Test-FslIsWindows)) { return $null }
    $systemDirectory = [System.Environment]::SystemDirectory
    if ([string]::IsNullOrEmpty($systemDirectory)) { return $null }
    return (Join-Path -Path $systemDirectory -ChildPath 'WindowsPowerShell\v1.0\Modules')
}

function Get-FslCoreWindowsModuleManifest {
    <#
    .SYNOPSIS
        Returns the manifest path <WindowsModuleFolder>\<Name>\[<Version>\]<Name>.psd1 when it exists, otherwise $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    $folder = Get-FslCoreWindowsModuleFolder
    if ([string]::IsNullOrEmpty($folder)) { return $null }
    return (Find-FslCoreModuleManifest -ModuleFolder (Join-Path -Path $folder -ChildPath $Name) -Name $Name)
}

function Find-FslCoreModuleManifest {
    <#
    .SYNOPSIS
        Finds <ModuleFolder>/<Name>.psd1, or the highest <ModuleFolder>/<Version>/<Name>.psd1 (versioned layout,
        about_PSModulePath "Module search behavior"; e.g. Hyper-V\2.0.0.0\Hyper-V.psd1). Returns $null when none exists.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ModuleFolder,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    if (-not (Test-Path -LiteralPath $ModuleFolder -PathType Container)) { return $null }
    $flat = Join-Path -Path $ModuleFolder -ChildPath "$Name.psd1"
    if (Test-Path -LiteralPath $flat -PathType Leaf) { return $flat }
    $candidates = foreach ($directory in @(Get-ChildItem -LiteralPath $ModuleFolder -Directory -ErrorAction SilentlyContinue)) {
        $parsed = $null
        if ([version]::TryParse($directory.Name, [ref]$parsed)) {
            $manifest = Join-Path -Path $directory.FullName -ChildPath "$Name.psd1"
            if (Test-Path -LiteralPath $manifest -PathType Leaf) { [pscustomobject]@{ Version = $parsed; Path = $manifest } }
        }
    }
    $best = @($candidates) | Sort-Object -Property Version -Descending | Select-Object -First 1
    if ($null -ne $best) { return [string]$best.Path }
    return $null
}

function Add-FslCoreWindowsModulePath {
    <#
    .SYNOPSIS
        Appends the Windows PowerShell module folder to the PROCESS $env:PSModulePath when it is missing.
    .DESCRIPTION
        Appended (not prepended) so PowerShell 7 module folders keep precedence, matching the normal PowerShell 7 order
        where the System32 path comes from the Machine PSModulePath at the end (about_PSModulePath). Lets command
        autoloading and Get-Command checks find inbox modules for the rest of this process. Never writes the registry.
        Returns $true when the value was changed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Folder
    )

    try {
        $current = [System.Environment]::GetEnvironmentVariable('PSModulePath')
        if (Test-FslCorePathInList -PathList $current -Folder $Folder) { return $false }
        $env:PSModulePath = if ([string]::IsNullOrEmpty($current)) { $Folder } else { $current.TrimEnd([System.IO.Path]::PathSeparator) + [System.IO.Path]::PathSeparator + $Folder }
        Write-FslLog -Message "Windows PowerShell module folder appended to process PSModulePath: $Folder" -Level Info -Component 'Core'
        return $true
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Appending the Windows PowerShell module folder to PSModulePath'
        return $false
    }
}

function Get-FslCoreModuleLocation {
    <#
    .SYNOPSIS
        Describes where a loaded module came from: Local Modules folder | WinPSCompatSession | Windows module folder | PSModulePath.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo] $Module
    )

    $base = [string]$Module.ModuleBase
    if ($null -ne (Get-FslCoreCompatibilityNote -Module $Module)) { return 'WinPSCompatSession' }
    if (Test-FslCorePathUnderFolder -Path $base -Folder (Get-FslCoreModulesRoot)) { return 'Local Modules folder' }
    $windowsFolder = Get-FslCoreWindowsModuleFolder
    if (Test-FslCorePathUnderFolder -Path $base -Folder $windowsFolder) { return 'Windows module folder' }
    return 'PSModulePath'
}
