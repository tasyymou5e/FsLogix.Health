#Requires -Version 7.4
<#
.SYNOPSIS
    Validates FSLogixToolkit source files: PowerShell parser, data-file/XAML parsing, PSScriptAnalyzer
    (PowerShell 7 syntax rules) and an advisory Windows PowerShell 7 command/type compatibility pass.
.PARAMETER Path
    Files or folders to validate. Defaults to the whole module.
.PARAMETER AnalyzerModulePath
    Path to PSScriptAnalyzer.psd1 when the module is not installed. When omitted (and FSL_PSSA_PATH is not set), the
    project Modules folder is put first on the process PSModulePath before Import-Module PSScriptAnalyzer.
.PARAMETER SkipCompatibility
    Skip the advisory compatibility pass.
.EXAMPLE
    pwsh -NoProfile -File ./Tests/Invoke-FslValidation.ps1 -Path ./Public/Core
#>
[CmdletBinding()]
param(
    [string[]] $Path = @((Split-Path -Path $PSScriptRoot -Parent)),
    [string] $AnalyzerModulePath = $env:FSL_PSSA_PATH,
    [switch] $SkipCompatibility
)

$ErrorActionPreference = 'Stop'
$settingsPath = Join-Path -Path $PSScriptRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'
$compatPath = Join-Path -Path $PSScriptRoot -ChildPath 'PSScriptAnalyzerCompatibility.psd1'

if ($AnalyzerModulePath) { Import-Module -Name $AnalyzerModulePath -Force }
else {
    # Project Modules folder first (Start-FSLogixToolkit.ps1 -DownloadModules saves PSScriptAnalyzer there).
    $projectModules = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Modules'
    if (Test-Path -LiteralPath $projectModules -PathType Container) {
        $onPath = @($env:PSModulePath.Split([System.IO.Path]::PathSeparator) | Where-Object -FilterScript {
                [string]::Equals($_.TrimEnd([char[]]@('/', '\')), $projectModules.TrimEnd([char[]]@('/', '\')), [System.StringComparison]::OrdinalIgnoreCase) })
        if ($onPath.Count -eq 0) { $env:PSModulePath = $projectModules + [System.IO.Path]::PathSeparator + $env:PSModulePath }
    }
    Import-Module -Name PSScriptAnalyzer
}

# pwsh -File passes "a,b" as one string; split when the combined string is not itself a path.
$Path = @(foreach ($p in $Path) {
        $exists = try { Test-Path -LiteralPath $p } catch { $false }   # very long joined strings throw 'path too long'
        if ((-not $exists) -and $p.Contains(',')) { $p.Split(',') } else { $p }
    })

$files = foreach ($p in $Path) {
    $item = Get-Item -LiteralPath $p
    if ($item.PSIsContainer) {
        Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.xaml'
    }
    else { $item }
}
# Third-party modules saved in the project Modules folder are not toolkit source.
$modulesExclude = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Modules') + [System.IO.Path]::DirectorySeparatorChar
$files = @($files | Where-Object -FilterScript { -not $_.FullName.StartsWith($modulesExclude, [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object -Property FullName -Unique)

$blocking = [System.Collections.Generic.List[object]]::new()
$advisory = [System.Collections.Generic.List[object]]::new()

foreach ($file in $files) {
    switch ($file.Extension) {
        '.xaml' {
            try { [void][xml](Get-Content -LiteralPath $file.FullName -Raw) }
            catch { $blocking.Add([pscustomobject]@{ File = $file.FullName; Line = 0; Rule = 'XamlParse'; Severity = 'ParseError'; Message = $_.Exception.Message }) }
            continue
        }
        '.psd1' {
            try { [void](Import-PowerShellDataFile -LiteralPath $file.FullName) }
            catch { $blocking.Add([pscustomobject]@{ File = $file.FullName; Line = 0; Rule = 'DataFileParse'; Severity = 'ParseError'; Message = $_.Exception.Message }) }
        }
    }

    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($e in $parseErrors) {
        $blocking.Add([pscustomobject]@{ File = $file.FullName; Line = $e.Extent.StartLineNumber; Rule = 'Parser'; Severity = 'ParseError'; Message = $e.Message })
    }
    if ($parseErrors.Count -gt 0) { continue }

    foreach ($d in (Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settingsPath)) {
        $blocking.Add([pscustomobject]@{ File = $file.FullName; Line = $d.Line; Rule = $d.RuleName; Severity = [string]$d.Severity; Message = $d.Message })
    }
    if (-not $SkipCompatibility -and $file.Extension -ne '.psd1') {
        foreach ($d in (Invoke-ScriptAnalyzer -Path $file.FullName -Settings $compatPath)) {
            $advisory.Add([pscustomobject]@{ File = $file.FullName; Line = $d.Line; Rule = $d.RuleName; Severity = [string]$d.Severity; Message = $d.Message })
        }
    }
}

"Validated $($files.Count) file(s)."
if ($blocking.Count -gt 0) {
    "BLOCKING ($($blocking.Count)):"
    $blocking | ForEach-Object { "{0}:{1} [{2}/{3}] {4}" -f $_.File, $_.Line, $_.Rule, $_.Severity, $_.Message }
}
else { 'BLOCKING: none' }
if ($advisory.Count -gt 0) {
    "ADVISORY compatibility vs Windows PowerShell 7 profile ($($advisory.Count)) - verify each against learn.microsoft.com; Windows-only modules (e.g. SmbShare, Storage, Hyper-V) may be absent from the profile:"
    $advisory | ForEach-Object { "{0}:{1} [{2}] {3}" -f $_.File, $_.Line, $_.Rule, $_.Message }
}
else { 'ADVISORY: none' }

if ($blocking.Count -gt 0) { exit 1 }
exit 0
