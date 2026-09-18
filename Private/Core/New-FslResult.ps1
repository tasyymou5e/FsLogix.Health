function ConvertTo-FslCoreResultString {
    <#
    .SYNOPSIS
        Converts a value to a flat CSV-safe string (collections joined with '; ').
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) { return $InputObject }
    if ($InputObject -is [datetime]) { return $InputObject.ToString('o') }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $pairs = foreach ($key in $InputObject.Keys) { '{0}={1}' -f $key, [string]$InputObject[$key] }
        return (@($pairs) -join '; ')
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = foreach ($item in $InputObject) { [string]$item }
        return (@($items) -join '; ')
    }
    return [string]$InputObject
}

function New-FslResult {
    <#
    .SYNOPSIS
        Creates an FSLogixToolkit.Result object (contract 5.1).
    .DESCRIPTION
        Property order: Timestamp, ComputerName, Category, Check, Status, Target, Value, Expected, Message,
        Recommendation, Source, RequiresElevation, Scope (contract 5.1 v2 / P2.3: Scope is always the LAST
        property; General|ODFC|Profiles, default General). Value/Expected are converted to strings (arrays
        joined with '; '). Text fields are passed through secret redaction.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only; name fixed by contract.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Environment', 'Policy', 'BestPractice', 'Containers', 'Performance', 'Network', 'Maintenance', 'Diagnostics', 'Core', 'Discovery', 'Daily', 'Repair')]
        [string] $Category,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Check,

        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Warn', 'Fail', 'Info', 'Skipped', 'Error')]
        [string] $Status,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Target,

        [AllowNull()]
        [object] $Value,

        [AllowNull()]
        [object] $Expected,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Message,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Recommendation,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Source,

        [bool] $RequiresElevation = $false,

        [ValidateSet('General', 'ODFC', 'Profiles')]
        [string] $Scope = 'General'
    )

    # ValidateSet matching is case-insensitive; normalize to the canonical spelling.
    $canonicalScope = switch ($Scope) {
        'ODFC' { 'ODFC' }
        'Profiles' { 'Profiles' }
        default { 'General' }
    }

    [pscustomobject]@{
        PSTypeName        = 'FSLogixToolkit.Result'
        Timestamp         = (Get-Date).ToString('o')
        ComputerName      = [Environment]::MachineName
        Category          = $Category
        Check             = $Check
        Status            = $Status
        Target            = ConvertTo-FslCoreRedactedText -Text $Target
        Value             = ConvertTo-FslCoreRedactedText -Text (ConvertTo-FslCoreResultString -InputObject $Value)
        Expected          = ConvertTo-FslCoreRedactedText -Text (ConvertTo-FslCoreResultString -InputObject $Expected)
        Message           = ConvertTo-FslCoreRedactedText -Text $Message
        Recommendation    = ConvertTo-FslCoreRedactedText -Text $Recommendation
        Source            = $Source
        RequiresElevation = $RequiresElevation
        Scope             = $canonicalScope
    }
}
