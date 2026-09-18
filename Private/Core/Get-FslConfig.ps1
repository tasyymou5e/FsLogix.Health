function Get-FslConfig {
    <#
    .SYNOPSIS
        Returns the toolkit settings hashtable (cached from Config/Settings.psd1), or one section of it.
    .DESCRIPTION
        Returns an empty hashtable when the file or section cannot be read (error recorded). Never throws.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Section
    )

    try {
        if ($null -eq $script:FslSession['Config']) {
            $settingsPath = Join-Path -Path $script:FslSession['ModuleRoot'] -ChildPath 'Config/Settings.psd1'
            $script:FslSession['Config'] = Import-PowerShellDataFile -LiteralPath $settingsPath -ErrorAction Stop
        }
        $config = $script:FslSession['Config']

        if (-not $PSBoundParameters.ContainsKey('Section')) { return $config }
        if ($config.ContainsKey($Section) -and $config[$Section] -is [hashtable]) { return $config[$Section] }

        Write-FslLog -Message "Settings section '$Section' not found in Config/Settings.psd1" -Level Warning -Component 'Core'
        return @{}
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context 'Loading Config/Settings.psd1'
        return @{}
    }
}
