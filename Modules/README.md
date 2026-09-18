# Modules folder

This folder is put **first** on the process `PSModulePath` by `Start-FSLogixToolkit.ps1` (before the toolkit
module is imported) and by `Initialize-FslSession`. Only the current PowerShell process is changed; the
registry, User and Machine `PSModulePath` values are never modified.

## What goes here

PowerShell Gallery modules listed in `Config\Prerequisites.psd1` with `Source = 'PSGallery'` (currently
PSScriptAnalyzer, used only by `Tests\Invoke-FslValidation.ps1`). They are saved with `Save-PSResource`, which
stores modules as `<Name>\<Version>\`, for example:

```
Modules\
  PSScriptAnalyzer\
    1.25.0\
      PSScriptAnalyzer.psd1
```

To download them:

```powershell
.\Start-FSLogixToolkit.ps1 -DownloadModules            # then continues with the GUI / console run
Initialize-FslPrerequisites -AllowInstall               # same, from an imported module (default -Destination LocalModules)
```

For an offline machine, run `Save-PSResource -Name <Name> -Repository PSGallery -Path <this folder>` on a
connected machine and copy the `<Name>\<Version>` folder here.

`Initialize-FslPrerequisites` resolves each module in this order: already loaded -> this folder -> other
`PSModulePath` folders -> (Windows inbox modules only) the Windows PowerShell module folder. Nothing is bundled in
the repository; this folder is empty (`.gitkeep`) until you download modules.

## What does NOT go here

- **Windows inbox modules** - `Storage`, `SmbShare`, `ScheduledTasks` - are part of Windows and live in
  `%SystemRoot%\system32\WindowsPowerShell\v1.0\Modules`. They are not published on the PowerShell Gallery. If
  PowerShell 7 cannot find them, that folder is missing from `PSModulePath`; the toolkit then imports them from the
  Windows folder by manifest path and says so in the prerequisite result (see README Troubleshooting).
- **Modules that ship with PowerShell 7** - `CimCmdlets`, `Microsoft.PowerShell.Diagnostics`,
  `Microsoft.PowerShell.PSResourceGet` - are in `$PSHOME\Modules`.
- **Windows feature modules** - `Hyper-V` - are installed with the Windows optional feature
  (`Microsoft-Hyper-V-Management-PowerShell` on client, `Hyper-V-PowerShell` on Server). The toolkit never installs
  Windows features; without Hyper-V, container shrink uses diskpart.

Sources:
- PowerShell 7 module compatibility (inbox / feature / built-in modules):
  https://learn.microsoft.com/powershell/windows/module-compatibility
- about_PSModulePath (session changes, module search, PowerShell 7 PSModulePath construction):
  https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_psmodulepath
- about_Windows_PowerShell_Compatibility (modules in `system32\WindowsPowerShell\v1.0\Modules`):
  https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_windows_powershell_compatibility
- Save-PSResource: https://learn.microsoft.com/powershell/module/microsoft.powershell.psresourceget/save-psresource
- Saved layout `<Path>\<Name>\<Version>`: https://github.com/PowerShell/PSResourceGet/blob/master/src/code/InstallHelper.cs
