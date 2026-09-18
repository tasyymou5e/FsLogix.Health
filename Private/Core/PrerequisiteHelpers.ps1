# Private helpers for Initialize-FslPrerequisites (Agent 1).

function Join-FslCoreMessage {
    <#
    .SYNOPSIS
        Joins non-empty message fragments with a space.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text
    )

    return (@($Text | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) }) -join ' ')
}

function Get-FslCoreCompatibilityNote {
    <#
    .SYNOPSIS
        Returns a note when a module was loaded through Windows PowerShell Compatibility (implicit remoting).
    .DESCRIPTION
        about_Windows_PowerShell_Compatibility: the feature generates a proxy module in $env:TEMP in a folder
        named remoteIpMoProxy_<ModuleName>_<ModuleVersion>_localhost_<SessionGuid> and runs the module in the
        WinPSCompatSession session.
        https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_windows_powershell_compatibility
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo] $Module
    )

    try {
        $modulePath = [string]$Module.Path
        $moduleBase = [string]$Module.ModuleBase
        if ($modulePath -like '*remoteIpMoProxy_*' -or $moduleBase -like '*remoteIpMoProxy_*') {
            return 'Loaded through Windows PowerShell Compatibility (WinPSCompatSession); commands run in Windows PowerShell 5.1 and return deserialized objects.'
        }
    }
    catch { $null = $_ }
    return $null
}

function Import-FslCorePrerequisiteModule {
    <#
    .SYNOPSIS
        Imports a module by name or by manifest path and returns a Pass or Error Result.
    .DESCRIPTION
        -ManifestPath imports that exact manifest (Import-Module -Name <path>, no -SkipEditionCheck: for manifests in the
        Windows PowerShell module folder that do not declare the Core edition, PowerShell 7 loads them through
        WinPSCompatSession - about_Windows_PowerShell_Compatibility). The Message states where the module was loaded from
        (Local Modules folder | PSModulePath | Windows module folder | WinPSCompatSession).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ModuleName,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $ManifestPath,

        [AllowNull()]
        [version] $MinimumVersion,

        [Parameter(Mandatory)]
        [string] $Check,

        [string] $Expected,

        [string] $Reference,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Notes,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Recommendation,

        [string] $PrefixMessage = 'Module imported.',

        [AllowNull()]
        [AllowEmptyString()]
        [string] $SuffixMessage
    )

    $importName = if ([string]::IsNullOrEmpty($ManifestPath)) { $ModuleName } else { $ManifestPath }
    try {
        $importParams = @{ Name = $importName; PassThru = $true; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
        if ($null -ne $MinimumVersion) { $importParams['MinimumVersion'] = $MinimumVersion }
        $imported = Import-Module @importParams | Select-Object -First 1
        if ($null -eq $imported) {
            $imported = Get-Module -Name $ModuleName | Sort-Object -Property Version -Descending | Select-Object -First 1
        }

        $version = $null
        $compatNote = $null
        $locationText = $null
        if ($null -ne $imported) {
            $version = $imported.Version.ToString()
            $compatNote = Get-FslCoreCompatibilityNote -Module $imported
            $location = Get-FslCoreModuleLocation -Module $imported
            $locationText = "Loaded from: $location ($($imported.ModuleBase))."
        }
        Write-FslLog -Message "$Check - imported $version from $importName" -Level Info -Component 'Core'
        New-FslResult -Category 'Core' -Check $Check -Status 'Pass' -Target $ModuleName -Value $version -Expected $Expected `
            -Message (Join-FslCoreMessage -Text $PrefixMessage, $locationText, $compatNote, $SuffixMessage, $Notes) -Source $Reference
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Importing module $ModuleName"
        New-FslResult -Category 'Core' -Check $Check -Status 'Error' -Target $ModuleName -Expected $Expected `
            -Message (Join-FslCoreMessage -Text "Import failed ($importName): $($_.Exception.Message)", $SuffixMessage, $Notes) -Recommendation $Recommendation -Source $Reference
    }
}

function Get-FslCoreMissingModuleStatus {
    <#
    .SYNOPSIS
        Maps a missing module to a Result status: Required -> Fail; optional with Fallback -> Info; otherwise Warn.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [bool] $Required,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Fallback
    )

    if ($Required) { return 'Fail' }
    if (-not [string]::IsNullOrWhiteSpace($Fallback)) { return 'Info' }
    return 'Warn'
}

function Get-FslCoreMissingModuleImpact {
    <#
    .SYNOPSIS
        Builds the "what still works" sentence for a missing module.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [bool] $Required,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Fallback,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $UsedBy
    )

    $areas = (@($UsedBy | Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) }) -join ', ')
    if ([string]::IsNullOrEmpty($areas)) { $areas = 'the features that use it' }
    if (-not [string]::IsNullOrWhiteSpace($Fallback)) { return "Without it: $Fallback" }
    if ($Required) { return "Checks in $areas that need it return Error or Skipped results; other health check areas still run." }
    return "Unavailable without it: $areas. All other health checks still run."
}

function Get-FslCoreAvailableModule {
    <#
    .SYNOPSIS
        Get-Module -ListAvailable -Name <Name> filtered by MinimumVersion, newest first.
    .DESCRIPTION
        -ListAvailable only searches folders on $env:PSModulePath; -SkipEditionCheck (Windows) only disables the
        CompatiblePSEditions filter for Windows PowerShell module folder modules (Get-Module help).
        https://learn.microsoft.com/powershell/module/microsoft.powershell.core/get-module
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSModuleInfo])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [AllowNull()]
        [version] $MinimumVersion,

        [switch] $SkipEditionCheck
    )

    $listParams = @{ Name = $Name; ListAvailable = $true; ErrorAction = 'Stop' }
    if ($SkipEditionCheck.IsPresent) { $listParams['SkipEditionCheck'] = $true }
    Get-Module @listParams |
        Where-Object -FilterScript { $null -eq $MinimumVersion -or $_.Version -ge $MinimumVersion } |
        Sort-Object -Property Version -Descending
}

function Resolve-FslCoreInstallDestination {
    <#
    .SYNOPSIS
        Decides where -AllowInstall puts a PSGallery module: LocalModules (Save-PSResource) or CurrentUser.
    .DESCRIPTION
        LocalModules falls back to CurrentUser when Save-PSResource is not available or the Modules folder (or, when it
        does not exist yet, its parent folder) is not writable. Nothing is created here (safe under -WhatIf).
        Returns @{ Destination; Action; Note }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ModulesRoot,

        [ValidateSet('LocalModules', 'CurrentUser')]
        [string] $Destination = 'LocalModules'
    )

    $note = $null
    $target = $Destination
    if ($target -eq 'LocalModules') {
        if ($null -eq (Get-Command -Name 'Save-PSResource' -ErrorAction Ignore)) {
            $target = 'CurrentUser'
            $note = 'Save-PSResource (Microsoft.PowerShell.PSResourceGet) is not available; installed for the current user instead of the local Modules folder.'
        }
        elseif ([string]::IsNullOrEmpty($ModulesRoot)) {
            $target = 'CurrentUser'
            $note = 'The local Modules folder could not be determined; installed for the current user instead.'
        }
        else {
            $probeFolder = $ModulesRoot
            if (-not (Test-Path -LiteralPath $ModulesRoot -PathType Container)) { $probeFolder = Split-Path -Path $ModulesRoot -Parent }
            $writable = $false
            if (-not [string]::IsNullOrEmpty($probeFolder) -and (Test-Path -LiteralPath $probeFolder -PathType Container)) {
                $writable = Test-FslCoreWritableFolder -Path $probeFolder
            }
            if (-not $writable) {
                $target = 'CurrentUser'
                $note = "The local Modules folder '$ModulesRoot' is not writable; installed for the current user instead."
            }
        }
    }
    $action = if ($target -eq 'LocalModules') { "Save module from PSGallery to the local Modules folder ($ModulesRoot)" } else { 'Install module from PSGallery (Scope CurrentUser)' }
    return @{ Destination = $target; Action = $action; Note = $note }
}

function Install-FslCorePrerequisiteModule {
    <#
    .SYNOPSIS
        Downloads a PSGallery module (after ShouldProcess in the caller) and imports it. Returns one Result.
    .DESCRIPTION
        LocalModules: Save-PSResource -Name -Path <ModulesRoot> -Repository PSGallery -TrustRepository -Confirm:$false [-Version '[min, ]'];
        modules are saved as <ModulesRoot>/<Name>/<Version>/ (PSResourceGet InstallHelper.cs), then imported by manifest
        path. CurrentUser: Install-PSResource -Scope CurrentUser -TrustRepository -Confirm:$false (or Install-Module), then imported by name.
        PSResourceGet treats a bare version as exact; '[x, ]' is the minimum-inclusive range (Save-PSResource help).
        https://learn.microsoft.com/powershell/module/microsoft.powershell.psresourceget/save-psresource
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ImportParameters,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $ModulesRoot,

        [ValidateSet('LocalModules', 'CurrentUser')]
        [string] $Destination = 'LocalModules',

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Note
    )

    $moduleName = [string]$ImportParameters['ModuleName']
    $minimumVersion = $ImportParameters['MinimumVersion']
    try {
        if ($Destination -eq 'LocalModules') {
            if (-not (Test-Path -LiteralPath $ModulesRoot -PathType Container)) {
                $null = New-Item -Path $ModulesRoot -ItemType Directory -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
            }
            # Confirm:$false - the caller already confirmed with ShouldProcess; avoids a second prompt from the cmdlet's own
            # ShouldProcess when -Confirm lowered $ConfirmPreference (Save-PSResource ConfirmImpact Low).
            $saveParams = @{ Name = $moduleName; Path = $ModulesRoot; Repository = 'PSGallery'; TrustRepository = $true; Confirm = $false; ErrorAction = 'Stop' }
            if ($null -ne $minimumVersion) { $saveParams['Version'] = "[$minimumVersion, ]" }
            Save-PSResource @saveParams
            $null = Add-FslCoreLocalModulePath -Path $ModulesRoot
            Write-FslLog -Message "$($ImportParameters['Check']) - saved from PSGallery to $ModulesRoot" -Level Info -Component 'Core'
        }
        elseif ($null -ne (Get-Command -Name 'Install-PSResource' -ErrorAction Ignore)) {
            # TrustRepository: PSGallery is untrusted by default and the trust prompt fails in non-interactive runs
            # (Install-PSResource help); consent was given by -AllowInstall + ShouldProcess in the caller.
            $installParams = @{ Name = $moduleName; Repository = 'PSGallery'; Scope = 'CurrentUser'; TrustRepository = $true; Confirm = $false; ErrorAction = 'Stop' }
            if ($null -ne $minimumVersion) { $installParams['Version'] = "[$minimumVersion, ]" }
            Install-PSResource @installParams
            Write-FslLog -Message "$($ImportParameters['Check']) - installed from PSGallery (CurrentUser)" -Level Info -Component 'Core'
        }
        else {
            $installParams = @{ Name = $moduleName; Repository = 'PSGallery'; Scope = 'CurrentUser'; ErrorAction = 'Stop' }
            if ($null -ne $minimumVersion) { $installParams['MinimumVersion'] = $minimumVersion.ToString() }
            Install-Module @installParams
            Write-FslLog -Message "$($ImportParameters['Check']) - installed from PSGallery (CurrentUser, Install-Module)" -Level Info -Component 'Core'
        }
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Downloading module $moduleName from PSGallery ($Destination)"
        New-FslResult -Category 'Core' -Check ([string]$ImportParameters['Check']) -Status 'Error' -Target $moduleName -Expected ([string]$ImportParameters['Expected']) `
            -Message (Join-FslCoreMessage -Text "Download failed ($Destination): $($_.Exception.Message)", $Note) `
            -Recommendation ([string]$ImportParameters['Recommendation']) -Source ([string]$ImportParameters['Reference'])
        return
    }

    if ($Destination -eq 'LocalModules') {
        $available = @(Get-FslCoreAvailableModule -Name $moduleName -MinimumVersion $minimumVersion -SkipEditionCheck:(Test-FslIsWindows))
        $local = @($available | Where-Object -FilterScript { Test-FslCorePathUnderFolder -Path $_.ModuleBase -Folder $ModulesRoot })
        if ($local.Count -eq 0) {
            New-FslResult -Category 'Core' -Check ([string]$ImportParameters['Check']) -Status 'Error' -Target $moduleName -Expected ([string]$ImportParameters['Expected']) `
                -Message "Save-PSResource completed but no '$moduleName' module was found under '$ModulesRoot'." `
                -Recommendation ([string]$ImportParameters['Recommendation']) -Source ([string]$ImportParameters['Reference'])
            return
        }
        Import-FslCorePrerequisiteModule @ImportParameters -ManifestPath ([string]$local[0].Path) -PrefixMessage 'Module saved to the local Modules folder and imported.' -SuffixMessage $Note
        return
    }
    Import-FslCorePrerequisiteModule @ImportParameters -PrefixMessage 'Module installed (CurrentUser) and imported.' -SuffixMessage $Note
}
