function Get-FslKnownIssue {
    <#
    .SYNOPSIS
        Lists documented FSLogix known issues that apply to the installed (or specified) FSLogix version.
    .DESCRIPTION
        Loads Config/KnownIssues.psd1 (populated from the Microsoft Learn FSLogix known issues page and release
        notes) and compares each entry with the FSLogix build version using [version] comparison.
        Applicable issues are returned with the entry Severity as Status (Warn/Fail/Info) plus an Info summary.
        When the version is unknown (not installed, not detected, or not parseable) every issue is returned
        with Status Info.
    .PARAMETER Version
        FSLogix build version to evaluate (for example 3.25.401.15305). When omitted, the installed version from
        Find-FslInstallation is used.
    .PARAMETER Scope
        Container scopes to include: Profiles, ODFC (default both). Entries tagged General or CloudCache in
        Config/KnownIssues.psd1 are always included; Profiles/ODFC entries only when their scope is requested.
        Result Scope is the entry scope (CloudCache and General -> General). Summary results are General.
    .EXAMPLE
        Get-FslKnownIssue
    .EXAMPLE
        Get-FslKnownIssue -Scope ODFC
    .EXAMPLE
        Get-FslKnownIssue -Version '3.25.202.4223' | Where-Object Status -eq 'Fail'
    .NOTES
        RequiresElevation: No.
        Sources:
          https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues
          https://learn.microsoft.com/en-us/fslogix/overview-release-notes
        Severity values are a toolkit classification, not a Microsoft rating.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Version,

        [Parameter()]
        [ValidateSet('Profiles', 'ODFC')]
        [string[]] $Scope = @('Profiles', 'ODFC')
    )

    $category = 'Diagnostics'
    $knownIssuesSource = 'https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues'

    try {
        $data = Get-FslDataFile -Name 'KnownIssues'
        $allIssues = @($data['Issues'])
        # General and CloudCache entries are always included; entries without a Scope key count as General.
        $issues = @($allIssues | Where-Object -FilterScript { (Get-FslDiagIssueScope -Issue $_) -in (@('General', 'CloudCache') + @($Scope)) })
    }
    catch {
        Add-FslError -ErrorRecord $_ -Component $category -Context 'Loading Config/KnownIssues.psd1'
        New-FslResult -Category $category -Check 'Known issues' -Status 'Error' -Message "Unable to load known issues data: $($_.Exception.Message)" -Source $knownIssuesSource -Scope 'General'
        return
    }

    $versionText = $Version
    $versionNote = 'specified with -Version'
    if (-not $PSBoundParameters.ContainsKey('Version')) {
        $versionNote = 'detected by Find-FslInstallation'
        try {
            $installation = Find-FslInstallation
            if ($null -ne $installation -and $installation.IsInstalled -and $null -ne $installation.Version) {
                $versionText = [string]$installation.Version
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $category -Context 'Detecting installed FSLogix version'
        }
    }

    $parsedVersion = ConvertTo-FslDiagVersion -InputObject $versionText
    $dataDate = [string]$data['DataVerifiedOn']

    if ($null -eq $parsedVersion) {
        $reason = if ([string]::IsNullOrWhiteSpace($versionText)) { 'FSLogix version could not be determined (not installed or not detected)' } else { "Version '$versionText' is not a valid build version" }
        Write-FslLog -Message "$reason; listing all known issues as Info." -Level Warning -Component $category
        New-FslResult -Category $category -Check 'Known issues' -Status 'Info' -Target 'FSLogix' -Value $versionText `
            -Message ("{0}. Listing all {1} documented issue(s) for scope(s) {2} plus General (data verified {3})." -f $reason, $issues.Count, ($Scope -join ', '), $dataDate) `
            -Source $knownIssuesSource -Scope 'General'
        foreach ($issue in $issues) {
            New-FslResult -Category $category -Check ("Known issue {0}" -f $issue['Id']) -Status 'Info' -Target $issue['Title'] `
                -Expected (Get-FslDiagIssueRangeText -Issue $issue) -Message $issue['Description'] `
                -Recommendation $issue['Workaround'] -Source $issue['Source'] -Scope (ConvertTo-FslDiagResultScope -Scope (Get-FslDiagIssueScope -Issue $issue))
        }
        return
    }

    $applicable = 0
    foreach ($issue in $issues) {
        try {
            if (-not (Test-FslDiagIssueApplicable -Issue $issue -Version $parsedVersion)) { continue }
            $applicable++
            $status = if (@('Warn', 'Fail', 'Info') -contains $issue['Severity']) { [string]$issue['Severity'] } else { 'Warn' }
            New-FslResult -Category $category -Check ("Known issue {0}" -f $issue['Id']) -Status $status -Target $issue['Title'] `
                -Value $parsedVersion.ToString() -Expected (Get-FslDiagIssueRangeText -Issue $issue) -Message $issue['Description'] `
                -Recommendation $issue['Workaround'] -Source $issue['Source'] -Scope (ConvertTo-FslDiagResultScope -Scope (Get-FslDiagIssueScope -Issue $issue))
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component $category -Context "Evaluating known issue $($issue['Id'])"
            New-FslResult -Category $category -Check ("Known issue {0}" -f $issue['Id']) -Status 'Error' -Message $_.Exception.Message -Source $issue['Source'] -Scope 'General'
        }
    }

    New-FslResult -Category $category -Check 'Known issues' -Status 'Info' -Target 'FSLogix' -Value $parsedVersion.ToString() `
        -Message ("{0} of {1} documented issue(s) for scope(s) {2} plus General apply to FSLogix {3} ({4}; data verified {5})." -f $applicable, $issues.Count, ($Scope -join ', '), $parsedVersion, $versionNote, $dataDate) `
        -Recommendation 'Microsoft require customers to install and use the latest FSLogix version.' `
        -Source 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes' -Scope 'General'
}
