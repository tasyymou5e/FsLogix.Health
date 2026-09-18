# Private helpers for Invoke-FslBestPracticeAnalyzer: setting lookup, operator evaluation and rule evaluation.
# Rule data: Config/BestPractices.psd1. Sources are recorded per rule in that file.

function ConvertTo-FslBpaResultScope {
    <# Maps a setting scope to a Result scope (contract P2.2): Profiles -> Profiles, ODFC -> ODFC, anything else -> General. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $SettingScope)
    switch ($SettingScope) {
        'Profiles' { return 'Profiles' }
        'ODFC' { return 'ODFC' }
    }
    return 'General'
}

function Get-FslBpaPropertyValue {
    <# Returns a property/key value from a hashtable or object, or $null when absent (StrictMode safe). #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return , $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return , $property.Value
}

function Get-FslBpaSetting {
    <# Finds the Setting object (contract 5.2) for a scope and value name (case-insensitive). Returns $null when not configured. #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Setting,
        [Parameter(Mandatory)] [string] $Scope,
        [Parameter(Mandatory)] [string] $Name
    )
    foreach ($item in @($Setting)) {
        if ($null -eq $item) { continue }
        $itemScope = [string](Get-FslBpaPropertyValue -InputObject $item -Name 'Scope')
        $itemName = [string](Get-FslBpaPropertyValue -InputObject $item -Name 'Name')
        if ($itemScope -eq $Scope -and $itemName -eq $Name) { return $item }
    }
    return $null
}

function ConvertTo-FslBpaDisplayString {
    <# Converts a value (scalar or array) to a display string; arrays are joined with '; '. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowNull()] [object] $Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return ((@($Value) | ForEach-Object -Process { [string]$_ }) -join '; ')
    }
    return [string]$Value
}

function ConvertTo-FslBpaNumber {
    <# Attempts to convert a value to [long]. Returns $null when the value is not a single integer. #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)] [AllowNull()] [object] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @($Value)
        if ($items.Count -ne 1) { return $null }
        $Value = $items[0]
    }
    $number = [long]0
    if ([long]::TryParse(([string]$Value).Trim(), [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }
    return $null
}

function Test-FslBpaValueEqual {
    <# Compares two values: numerically when both are integers, otherwise case-insensitive string comparison. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Actual,
        [Parameter(Mandatory)] [AllowNull()] [object] $Expected
    )
    $actualNumber = ConvertTo-FslBpaNumber -Value $Actual
    $expectedNumber = ConvertTo-FslBpaNumber -Value $Expected
    if ($null -ne $actualNumber -and $null -ne $expectedNumber) { return ($actualNumber -eq $expectedNumber) }
    $actualText = ConvertTo-FslBpaDisplayString -Value $Actual
    $expectedText = ConvertTo-FslBpaDisplayString -Value $Expected
    return [string]::Equals($actualText.Trim(), $expectedText.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-FslBpaOperator {
    <# Evaluates Operator against an actual value. IsConfigured drives Exists/NotExists. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [ValidateSet('Equals', 'NotEquals', 'Exists', 'NotExists', 'GreaterOrEqual', 'LessOrEqual', 'In')] [string] $Operator,
        [Parameter(Mandatory)] [AllowNull()] [object] $Actual,
        [Parameter(Mandatory)] [AllowNull()] [object] $Expected,
        [Parameter(Mandatory)] [bool] $IsConfigured
    )
    switch ($Operator) {
        'Exists' { return $IsConfigured }
        'NotExists' { return (-not $IsConfigured) }
        'Equals' { return (Test-FslBpaValueEqual -Actual $Actual -Expected $Expected) }
        'NotEquals' { return (-not (Test-FslBpaValueEqual -Actual $Actual -Expected $Expected)) }
        'In' {
            foreach ($candidate in @($Expected)) {
                if (Test-FslBpaValueEqual -Actual $Actual -Expected $candidate) { return $true }
            }
            return $false
        }
        'GreaterOrEqual' {
            $a = ConvertTo-FslBpaNumber -Value $Actual
            $e = ConvertTo-FslBpaNumber -Value $Expected
            if ($null -eq $a -or $null -eq $e) { return $false }
            return ($a -ge $e)
        }
        'LessOrEqual' {
            $a = ConvertTo-FslBpaNumber -Value $Actual
            $e = ConvertTo-FslBpaNumber -Value $Expected
            if ($null -eq $a -or $null -eq $e) { return $false }
            return ($a -le $e)
        }
    }
    return $false
}

function Get-FslBpaExpectedText {
    <# Builds the human-readable Expected string for a rule. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Operator,
        [Parameter(Mandatory)] [AllowNull()] [object] $Expected
    )
    $text = ConvertTo-FslBpaDisplayString -Value $Expected
    switch ($Operator) {
        'Equals' { return $text }
        'NotEquals' { return "Not $text" }
        'Exists' { return 'Configured' }
        'NotExists' { return 'Not configured' }
        'GreaterOrEqual' { return ">= $text" }
        'LessOrEqual' { return "<= $text" }
        'In' { return "One of: $text" }
    }
    return $text
}

function Test-FslBpaAppliesWhen {
    <#
        Evaluates a rule's AppliesWhen: $null (always applies), one condition hashtable, or an array of
        condition hashtables (all must be true). Conditions are evaluated in the rule's scope; an unconfigured
        setting uses the condition's DefaultValue when present.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $AppliesWhen,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Setting,
        [Parameter(Mandatory)] [string] $Scope
    )
    if ($null -eq $AppliesWhen) { return $true }
    $conditions = if ($AppliesWhen -is [System.Collections.IDictionary]) { , $AppliesWhen } else { @($AppliesWhen) }
    foreach ($condition in $conditions) {
        if ($null -eq $condition) { continue }
        $name = [string](Get-FslBpaPropertyValue -InputObject $condition -Name 'Setting')
        $operator = [string](Get-FslBpaPropertyValue -InputObject $condition -Name 'Operator')
        $expected = Get-FslBpaPropertyValue -InputObject $condition -Name 'Expected'
        $found = Get-FslBpaSetting -Setting $Setting -Scope $Scope -Name $name
        $isConfigured = ($null -ne $found)
        $actual = if ($isConfigured) { Get-FslBpaPropertyValue -InputObject $found -Name 'Value' } else { Get-FslBpaPropertyValue -InputObject $condition -Name 'DefaultValue' }
        if (-not (Test-FslBpaOperator -Operator $operator -Actual $actual -Expected $expected -IsConfigured $isConfigured)) {
            return $false
        }
    }
    return $true
}

function Test-FslBpaRuleDefinition {
    <# Validates the shape of a rule from Config/BestPractices.psd1. Returns a list of problems (empty when valid). #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [AllowNull()] [object] $Rule)
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($Rule -isnot [System.Collections.IDictionary]) {
        $problems.Add('Rule is not a hashtable.')
        return $problems.ToArray()
    }
    foreach ($key in @('Id', 'Scope', 'Setting', 'Operator', 'Severity', 'Title', 'Recommendation', 'Source')) {
        if (-not $Rule.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$Rule[$key])) { $problems.Add("Missing key '$key'.") }
    }
    if ($Rule.Contains('Scope') -and [string]$Rule['Scope'] -notin @('Profiles', 'ODFC', 'Logging', 'Apps')) { $problems.Add("Invalid Scope '$($Rule['Scope'])'.") }
    if ($Rule.Contains('Operator') -and [string]$Rule['Operator'] -notin @('Equals', 'NotEquals', 'Exists', 'NotExists', 'GreaterOrEqual', 'LessOrEqual', 'In')) { $problems.Add("Invalid Operator '$($Rule['Operator'])'.") }
    if ($Rule.Contains('Severity') -and [string]$Rule['Severity'] -notin @('Fail', 'Warn', 'Info')) { $problems.Add("Invalid Severity '$($Rule['Severity'])'.") }
    if ($Rule.Contains('Source') -and -not ([string]$Rule['Source']).StartsWith('https://learn.microsoft.com/', [System.StringComparison]::OrdinalIgnoreCase)) { $problems.Add('Source must be a learn.microsoft.com URL.') }
    return $problems.ToArray()
}

function Invoke-FslBpaRule {
    <#
        Evaluates one best-practice rule against Setting objects and returns a Result (Category BestPractice),
        or nothing when the rule's AppliesWhen condition is not met.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Rule,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Setting
    )
    $scope = [string]$Rule['Scope']
    $name = [string]$Rule['Setting']
    $operator = [string]$Rule['Operator']
    $expected = if ($Rule.Contains('Expected')) { $Rule['Expected'] } else { $null }
    $defaultValue = if ($Rule.Contains('DefaultValue')) { $Rule['DefaultValue'] } else { $null }
    $appliesWhen = if ($Rule.Contains('AppliesWhen')) { $Rule['AppliesWhen'] } else { $null }
    $target = '{0}\{1}' -f $scope, $name
    $expectedText = Get-FslBpaExpectedText -Operator $operator -Expected $expected

    if (-not (Test-FslBpaAppliesWhen -AppliesWhen $appliesWhen -Setting $Setting -Scope $scope)) {
        Write-FslLog -Message "Rule $($Rule['Id']) ($target) not applicable - AppliesWhen condition not met." -Level Verbose -Component 'BestPractice'
        return
    }

    $found = Get-FslBpaSetting -Setting $Setting -Scope $scope -Name $name
    $isConfigured = ($null -ne $found)
    $status = [string]$Rule['Severity']
    $valueText = 'Not configured'

    if ($isConfigured) {
        $actual = Get-FslBpaPropertyValue -InputObject $found -Name 'Value'
        $valueText = ConvertTo-FslBpaDisplayString -Value $actual
        $origin = [string](Get-FslBpaPropertyValue -InputObject $found -Name 'Source')
        $passed = Test-FslBpaOperator -Operator $operator -Actual $actual -Expected $expected -IsConfigured $true
        $message = if ($origin) { "Configured value '$valueText' (source: $origin)." } else { "Configured value '$valueText'." }
        if (-not $passed -and $operator -in @('GreaterOrEqual', 'LessOrEqual') -and $null -eq (ConvertTo-FslBpaNumber -Value $actual)) {
            $message += ' Value is not numeric.'
        }
    }
    elseif ($operator -in @('Exists', 'NotExists')) {
        $passed = Test-FslBpaOperator -Operator $operator -Actual $null -Expected $expected -IsConfigured $false
        $message = 'Not configured.'
    }
    elseif ($null -ne $defaultValue) {
        $passed = Test-FslBpaOperator -Operator $operator -Actual $defaultValue -Expected $expected -IsConfigured $false
        $message = "Not configured - using documented default $(ConvertTo-FslBpaDisplayString -Value $defaultValue)."
    }
    else {
        $passed = $false
        $status = 'Info'
        $message = 'Not configured - no documented default; cannot evaluate.'
    }

    if ($passed) { $status = 'Pass' }
    $message = "[$($Rule['Id'])] $message"

    New-FslResult -Category 'BestPractice' -Check ([string]$Rule['Title']) -Status $status -Target $target `
        -Value $valueText -Expected $expectedText -Message $message -Recommendation ([string]$Rule['Recommendation']) `
        -Source ([string]$Rule['Source']) -RequiresElevation $false -Scope (ConvertTo-FslBpaResultScope -SettingScope $scope)
}
