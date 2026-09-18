function Initialize-FslPrerequisites {
    <#
    .SYNOPSIS
        Checks, imports and (optionally) downloads the PowerShell modules used by the toolkit.
    .DESCRIPTION
        Reads Config/Prerequisites.psd1 and emits one Result (Category Core) per module. Resolution order:
          0. Windows-only module on a non-Windows OS                        -> Skipped
          1. already loaded (meets MinimumVersion)                          -> Pass
          2. found in the project Modules folder (<ModuleRoot>/Modules)     -> Import-Module <manifest path> -> Pass
          3. found on PSModulePath (Get-Module -ListAvailable; on Windows with -SkipEditionCheck)
                                                                            -> Import-Module -> Pass
          4. Windows only, InboxWindowsModule entries: manifest in the Windows PowerShell module folder
             (<SystemDirectory>\WindowsPowerShell\v1.0\Modules\<Name>\<Name>.psd1)
                                                                            -> Import-Module <manifest path> -> Pass
             The Message states that the folder was not on PSModulePath (diagnostic) and the folder is appended to the
             PROCESS PSModulePath so command autoloading works for the rest of the session (registry never changed).
          5. missing, Source PSGallery, -AllowInstall and ShouldProcess confirmed
               -Destination LocalModules (default): Save-PSResource -Path <ModuleRoot>/Modules -Repository PSGallery
                 -TrustRepository, then import from there. If the Modules folder is not writable or Save-PSResource is
                 not available, falls back to a CurrentUser install.
               -Destination CurrentUser: Install-PSResource (or Install-Module) -Scope CurrentUser, then import.
          6. otherwise: Required -> Fail; optional with a Fallback in the data file -> Info; optional without -> Warn.
             The Message says what still works.
        The Result Value is the module version; the Message says where the module was loaded from (Local Modules folder,
        PSModulePath, Windows module folder or WinPSCompatSession).
        Importing by manifest path does not use -SkipEditionCheck: modules in the Windows PowerShell module folder whose
        manifest does not declare the Core edition are loaded through Windows PowerShell Compatibility (WinPSCompatSession,
        deserialized objects), which is noted in the Message. Windows features, optional features and RSAT capabilities
        are never installed, and inbox Windows modules are never downloaded (they are not on the PowerShell Gallery).
    .PARAMETER Name
        Only process the named modules (must exist in Config/Prerequisites.psd1).
    .PARAMETER AllowInstall
        Allows downloading missing PSGallery modules (still subject to -WhatIf/-Confirm).
    .PARAMETER Destination
        Where -AllowInstall puts PSGallery modules: LocalModules (default, the project Modules folder via Save-PSResource)
        or CurrentUser (Install-PSResource -Scope CurrentUser).
    .EXAMPLE
        Initialize-FslPrerequisites

        Checks and imports all prerequisite modules without downloading anything.
    .EXAMPLE
        Initialize-FslPrerequisites -Name PSScriptAnalyzer -AllowInstall -Confirm

        Saves PSScriptAnalyzer from the PowerShell Gallery into the project Modules folder after confirmation and imports it.
    .EXAMPLE
        Initialize-FslPrerequisites -Name PSScriptAnalyzer -AllowInstall -Destination CurrentUser

        Installs PSScriptAnalyzer for the current user instead of the project Modules folder.
    .NOTES
        RequiresElevation: No (Modules folder saves and CurrentUser installs only)
        Sources:
          https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_windows_powershell_compatibility
          https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_psmodulepath
          https://learn.microsoft.com/powershell/windows/module-compatibility
          https://learn.microsoft.com/powershell/module/microsoft.powershell.core/get-module
          https://learn.microsoft.com/powershell/module/microsoft.powershell.core/import-module
          https://learn.microsoft.com/powershell/module/microsoft.powershell.psresourceget/save-psresource
          https://learn.microsoft.com/powershell/module/microsoft.powershell.psresourceget/install-psresource
          https://learn.microsoft.com/powershell/gallery/powershellget/install-powershellget
          https://github.com/PowerShell/PSResourceGet/blob/master/src/code/InstallHelper.cs
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Public name fixed by CONTRACT.md and the module manifest.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name,

        [switch] $AllowInstall,

        [ValidateSet('LocalModules', 'CurrentUser')]
        [string] $Destination = 'LocalModules'
    )

    $category = 'Core'
    $onWindows = Test-FslIsWindows

    $data = Get-FslDataFile -Name 'Prerequisites'
    $modules = @()
    if ($data.ContainsKey('Modules')) { $modules = @($data['Modules']) }
    if ($modules.Count -eq 0) {
        New-FslResult -Category $category -Check 'Prerequisite definitions' -Status 'Error' -Target 'Config/Prerequisites.psd1' `
            -Message 'No module definitions could be loaded from Config/Prerequisites.psd1.' -Source 'Toolkit default'
        return
    }

    if ($PSBoundParameters.ContainsKey('Name')) {
        $known = @($modules | ForEach-Object -Process { $_['Name'] })
        foreach ($requested in $Name) {
            if ($known -notcontains $requested) {
                New-FslResult -Category $category -Check "Prerequisite module: $requested" -Status 'Warn' -Target $requested `
                    -Message 'Module is not defined in Config/Prerequisites.psd1.' -Source 'Toolkit default'
            }
        }
        $modules = @($modules | Where-Object -FilterScript { $Name -contains $_['Name'] })
    }

    # Project Modules folder first on the process PSModulePath (idempotent, no-op when the folder is missing).
    $modulesRoot = Add-FslCoreLocalModulePath

    foreach ($module in $modules) {
        $moduleName = [string]$module['Name']
        $check = "Prerequisite module: $moduleName"
        $required = [bool]$module['Required']
        $sourceType = [string]$module['Source']
        $installHint = [string]$module['InstallHint']
        $reference = if ($module['Reference']) { [string]$module['Reference'] } else { 'Toolkit default' }
        $notes = [string]$module['Notes']
        $fallback = [string]$module['Fallback']
        $inboxWindowsModule = [bool]$module['InboxWindowsModule']
        $usedBy = @($module['UsedBy'] | ForEach-Object -Process { [string]$_ })
        $minimumVersion = $null
        if ($module['MinimumVersion']) { $minimumVersion = [version][string]$module['MinimumVersion'] }
        $expected = if ($null -ne $minimumVersion) { ">= $minimumVersion" } else { 'Available' }
        $importCommon = @{
            ModuleName     = $moduleName
            MinimumVersion = $minimumVersion
            Check          = $check
            Expected       = $expected
            Reference      = $reference
            Notes          = $notes
            Recommendation = $installHint
        }

        try {
            if ([bool]$module['Windows'] -and -not $onWindows) {
                New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $moduleName -Expected $expected `
                    -Message 'Windows-only module; not applicable on this operating system.' -Source $reference
                continue
            }

            # 1. Already loaded?
            $loaded = Get-Module -Name $moduleName | Sort-Object -Property Version -Descending | Select-Object -First 1
            if ($null -ne $loaded -and ($null -eq $minimumVersion -or $loaded.Version -ge $minimumVersion)) {
                $location = Get-FslCoreModuleLocation -Module $loaded
                $message = Join-FslCoreMessage -Text "Module already loaded. Loaded from: $location ($($loaded.ModuleBase)).", (Get-FslCoreCompatibilityNote -Module $loaded), $notes
                Write-FslLog -Message "$check - loaded $($loaded.Version)" -Level Verbose -Component 'Core'
                New-FslResult -Category $category -Check $check -Status 'Pass' -Target $moduleName -Value $loaded.Version.ToString() `
                    -Expected $expected -Message $message -Source $reference
                continue
            }

            # 2./3. Local Modules folder first, then anywhere else on PSModulePath.
            $available = @(Get-FslCoreAvailableModule -Name $moduleName -MinimumVersion $minimumVersion -SkipEditionCheck:$onWindows)
            $local = @($available | Where-Object -FilterScript { Test-FslCorePathUnderFolder -Path $_.ModuleBase -Folder $modulesRoot })
            if ($local.Count -gt 0) {
                Import-FslCorePrerequisiteModule @importCommon -ManifestPath ([string]$local[0].Path) -PrefixMessage 'Module imported.'
                continue
            }
            if ($available.Count -gt 0) {
                Import-FslCorePrerequisiteModule @importCommon -PrefixMessage 'Module imported.'
                continue
            }

            # 4. Windows inbox module folder (not on PSModulePath) - import by manifest path.
            if ($onWindows -and $inboxWindowsModule) {
                $manifest = Get-FslCoreWindowsModuleManifest -Name $moduleName
                if (-not [string]::IsNullOrEmpty($manifest)) {
                    $windowsFolder = Get-FslCoreWindowsModuleFolder
                    $folderOnPath = Test-FslCorePathInList -PathList $env:PSModulePath -Folder $windowsFolder
                    $diagnostic = if ($folderOnPath) {
                        "Get-Module -ListAvailable did not list it although '$windowsFolder' is on PSModulePath; imported by manifest path."
                    }
                    else {
                        "Diagnostic: the Windows PowerShell module folder '$windowsFolder' was not on PSModulePath in this process (check the Machine/User PSModulePath and the program that started pwsh - see README Troubleshooting); it was appended to the process PSModulePath for this session only."
                    }
                    $result = Import-FslCorePrerequisiteModule @importCommon -ManifestPath $manifest -PrefixMessage 'Module imported by manifest path.' -SuffixMessage $diagnostic
                    if ($null -ne $result -and $result.Status -eq 'Pass' -and -not $folderOnPath) {
                        $null = Add-FslCoreWindowsModulePath -Folder $windowsFolder
                        Write-FslLog -Message "$check - '$windowsFolder' is not on PSModulePath; module imported by manifest path." -Level Warning -Component 'Core'
                    }
                    $result
                    continue
                }
            }

            # 5. Missing - download only PSGallery modules with explicit permission.
            if ($sourceType -eq 'PSGallery' -and $AllowInstall.IsPresent) {
                $plan = Resolve-FslCoreInstallDestination -ModulesRoot $modulesRoot -Destination $Destination
                if ($PSCmdlet.ShouldProcess($moduleName, [string]$plan['Action'])) {
                    Install-FslCorePrerequisiteModule -ImportParameters $importCommon -ModulesRoot $modulesRoot -Destination ([string]$plan['Destination']) -Note ([string]$plan['Note'])
                }
                else {
                    New-FslResult -Category $category -Check $check -Status 'Skipped' -Target $moduleName -Expected $expected `
                        -Message (Join-FslCoreMessage -Text 'Module missing; download was not confirmed (WhatIf or declined).', ([string]$plan['Note'])) -Recommendation $installHint -Source $reference
                }
                continue
            }

            # 6. Not available.
            $missingStatus = Get-FslCoreMissingModuleStatus -Required $required -Fallback $fallback
            $missingMessage = 'Module not found in the local Modules folder or on PSModulePath.'
            if ($sourceType -eq 'PSGallery') {
                $missingMessage += ' Use -AllowInstall (or Start-FSLogixToolkit.ps1 -DownloadModules) to save it to the Modules folder.'
            }
            elseif ($onWindows -and $inboxWindowsModule) {
                $missingMessage += " Not found in the Windows PowerShell module folder ($(Get-FslCoreWindowsModuleFolder)) either."
            }
            if ($sourceType -in @('WindowsCapability', 'WindowsFeature')) {
                $missingMessage += ' Windows features/capabilities are not installed by the toolkit and are not available from the PowerShell Gallery.'
            }
            elseif ($inboxWindowsModule) {
                $missingMessage += ' It is an inbox Windows module and cannot be downloaded from the PowerShell Gallery.'
            }
            $impact = Get-FslCoreMissingModuleImpact -Required $required -Fallback $fallback -UsedBy $usedBy
            $logLevel = if ($missingStatus -eq 'Info') { 'Info' } else { 'Warning' }
            Write-FslLog -Message "$check - not found ($missingStatus)" -Level $logLevel -Component 'Core'
            New-FslResult -Category $category -Check $check -Status $missingStatus -Target $moduleName -Expected $expected `
                -Message (Join-FslCoreMessage -Text $missingMessage, $impact, $notes) -Recommendation $installHint -Source $reference
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Checking prerequisite module $moduleName"
            New-FslResult -Category $category -Check $check -Status 'Error' -Target $moduleName -Expected $expected `
                -Message $_.Exception.Message -Recommendation $installHint -Source $reference
        }
    }
}
