function Get-FslDataFile {
    <#
    .SYNOPSIS
        Loads Config/<Name>.psd1 with Import-PowerShellDataFile and returns the hashtable.
    .DESCRIPTION
        Name is restricted to a simple file name (no path separators). The '.psd1' extension is optional.
        Returns an empty hashtable on failure (error recorded). Never throws.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidatePattern('^[A-Za-z0-9_\-]+(\.psd1)?$')]
        [string] $Name
    )

    try {
        $baseName = $Name -replace '\.psd1$', ''
        $path = Join-Path -Path $script:FslSession['ModuleRoot'] -ChildPath ("Config/{0}.psd1" -f $baseName)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-FslLog -Message "Data file not found: $path" -Level Warning -Component 'Core'
            return @{}
        }
        return (Import-PowerShellDataFile -LiteralPath $path -ErrorAction Stop)
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component 'Core' -Context "Loading data file Config/$Name"
        return @{}
    }
}
