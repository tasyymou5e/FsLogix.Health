# FSLogixToolkit module loader
Set-StrictMode -Version Latest

$script:FslSession = [ordered]@{
    ModuleRoot   = $PSScriptRoot
    LogRoot      = $null
    ReportRoot   = $null
    LogPath      = $null
    DebugLogging = $false
    Errors       = [System.Collections.Generic.List[object]]::new()
    Config       = $null
    Initialized  = $false
    ModulesRoot  = (Join-Path -Path $PSScriptRoot -ChildPath 'Modules')   # project Modules folder (Add-FslCoreLocalModulePath)
}

foreach ($folder in @('Private', 'Public')) {
    $folderPath = Join-Path -Path $PSScriptRoot -ChildPath $folder
    if (-not (Test-Path -LiteralPath $folderPath)) { continue }
    $files = Get-ChildItem -LiteralPath $folderPath -Filter '*.ps1' -File -Recurse | Sort-Object -Property FullName
    foreach ($file in $files) {
        try {
            . $file.FullName
        }
        catch {
            throw "FSLogixToolkit: failed to load '$($file.FullName)': $($_.Exception.Message)"
        }
    }
}
