function Get-FslLatestVersionInfo {
    <#
    .SYNOPSIS
        Returns the latest stable PowerShell 7 release and the latest FSLogix release.
    .DESCRIPTION
        Online mode (default):
          - PowerShell: GET of Settings Environment.PowerShellReleaseApi (GitHub REST 'releases/latest', which returns
            the most recent non-prerelease, non-draft release). Responses flagged prerelease/draft are ignored.
          - FSLogix: GET of the FSLogix release notes page on learn.microsoft.com; the first release heading with
            its 'Version:' and 'Date published:' list items is parsed. If the page structure does not match, the
            data file is used.
        Read-only GETs only, with a timeout and a User-Agent header. Nothing is downloaded or executed.
        -Offline, or any online failure, uses Config/KnownVersions.psd1.
        Retrieved is 'Online' only when both values came from the internet, otherwise 'Offline data file';
        PowerShellRetrieved / FSLogixRetrieved give per-product detail.
    .PARAMETER Offline
        Do not use the network; read Config/KnownVersions.psd1 only.
    .PARAMETER TimeoutSec
        Connection timeout in seconds for each online request. Defaults to Settings Environment.OnlineTimeoutSec (toolkit default).
    .EXAMPLE
        Get-FslLatestVersionInfo

        Queries GitHub and learn.microsoft.com, falling back to the data file.
    .EXAMPLE
        Get-FslLatestVersionInfo -Offline

        Uses Config/KnownVersions.psd1 only.
    .NOTES
        RequiresElevation: No
        Sources:
        https://docs.github.com/en/rest/releases/releases#get-the-latest-release
        https://github.com/PowerShell/PowerShell/releases
        https://learn.microsoft.com/en-us/fslogix/overview-release-notes
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/invoke-restmethod (ConnectionTimeoutSeconds replaced TimeoutSec in 7.4)
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/invoke-webrequest
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [switch] $Offline,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int] $TimeoutSec
    )

    $releaseNotesUrl = 'https://learn.microsoft.com/en-us/fslogix/overview-release-notes'
    $userAgent = 'FSLogixToolkit/0.1 (PowerShell/{0})' -f $PSVersionTable.PSVersion

    $environmentConfig = $null
    try { $environmentConfig = Get-FslConfig -Section 'Environment' }
    catch { Add-FslError -ErrorRecord $_ -Component 'Environment' -Context 'Read Environment settings' }

    if (-not $PSBoundParameters.ContainsKey('TimeoutSec')) {
        $TimeoutSec = 10
        if ($null -ne $environmentConfig -and $environmentConfig.ContainsKey('OnlineTimeoutSec')) { $TimeoutSec = [int]$environmentConfig.OnlineTimeoutSec }
    }
    $releaseApi = 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
    if ($null -ne $environmentConfig -and $environmentConfig.ContainsKey('PowerShellReleaseApi') -and -not [string]::IsNullOrWhiteSpace([string]$environmentConfig.PowerShellReleaseApi)) {
        $releaseApi = [string]$environmentConfig.PowerShellReleaseApi
    }

    $psLatest = $null; $psPublished = $null; $psSource = $null; $psRetrieved = 'Offline data file'
    $fslLatest = $null; $fslName = $null; $fslDate = $null; $fslSource = $null; $fslRetrieved = 'Offline data file'

    if (-not $Offline) {
        # PowerShell latest stable
        try {
            $release = Invoke-RestMethod -Uri $releaseApi -Method Get -ConnectionTimeoutSeconds $TimeoutSec -OperationTimeoutSeconds $TimeoutSec -UserAgent $userAgent -Headers @{ Accept = 'application/vnd.github+json' } -ErrorAction Stop
            $isPrerelease = ($null -ne $release.PSObject.Properties['prerelease']) -and [bool]$release.prerelease
            $isDraft = ($null -ne $release.PSObject.Properties['draft']) -and [bool]$release.draft
            $tagVersion = ConvertTo-FslEnvVersion -InputObject ([string]$release.tag_name)
            if ((-not $isPrerelease) -and (-not $isDraft) -and ($null -ne $tagVersion)) {
                $psLatest = [string]$tagVersion
                $published = $release.published_at
                if ($published -is [datetime]) { $psPublished = $published.ToUniversalTime().ToString('yyyy-MM-dd') }
                else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse([string]$published, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsedDate)) {
                        $psPublished = $parsedDate.ToString('yyyy-MM-dd')
                    }
                }
                $psSource = if (-not [string]::IsNullOrWhiteSpace([string]$release.html_url)) { [string]$release.html_url } else { $releaseApi }
                $psRetrieved = 'Online'
            }
            else {
                Write-FslLog -Message "PowerShell release API returned an unusable release (tag '$($release.tag_name)', prerelease=$isPrerelease, draft=$isDraft); using data file." -Level Warning -Component 'Environment'
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Environment' -Context "GET $releaseApi"
        }

        # FSLogix latest release from the release notes page
        try {
            $page = Invoke-WebRequest -Uri $releaseNotesUrl -Method Get -ConnectionTimeoutSeconds $TimeoutSec -OperationTimeoutSeconds $TimeoutSec -UserAgent $userAgent -ErrorAction Stop
            $pattern = '<h2[^>]*>\s*FSLogix\s+(?<name>[^<]+?)\s*</h2>\s*<ul>\s*<li>\s*<strong>\s*Version:\s*</strong>\s*(?<build>\d+\.\d+\.\d+\.\d+)\s*</li>\s*<li>\s*<strong>\s*Date published:\s*</strong>\s*(?<date>[^<]+?)\s*</li>'
            $match = [regex]::Match([string]$page.Content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success -and ($null -ne (ConvertTo-FslEnvVersion -InputObject $match.Groups['build'].Value))) {
                $fslLatest = $match.Groups['build'].Value
                $fslName = 'FSLogix ' + $match.Groups['name'].Value
                $parsedFslDate = [datetime]::MinValue
                if ([datetime]::TryParse($match.Groups['date'].Value, [System.Globalization.CultureInfo]::GetCultureInfo('en-US'), [System.Globalization.DateTimeStyles]::None, [ref]$parsedFslDate)) {
                    $fslDate = $parsedFslDate.ToString('yyyy-MM-dd')
                }
                $fslSource = $releaseNotesUrl
                $fslRetrieved = 'Online'
            }
            else {
                Write-FslLog -Message 'FSLogix release notes page structure not recognized; using data file.' -Level Warning -Component 'Environment'
            }
        }
        catch {
            Add-FslError -ErrorRecord $_ -Component 'Environment' -Context "GET $releaseNotesUrl"
        }
    }

    if ($psRetrieved -ne 'Online' -or $fslRetrieved -ne 'Online') {
        $known = Get-FslEnvKnownVersion
        if ($null -ne $known) {
            if ($psRetrieved -ne 'Online' -and $known.ContainsKey('PowerShell')) {
                $psLatest = [string]$known.PowerShell.LatestStable
                $psPublished = [string]$known.PowerShell.Published
                $psSource = [string]$known.PowerShell.Source
            }
            if ($fslRetrieved -ne 'Online' -and $known.ContainsKey('FSLogix')) {
                $latestKnown = @($known.FSLogix) | Select-Object -First 1
                if ($null -ne $latestKnown) {
                    $fslLatest = [string]$latestKnown.Build
                    $fslName = [string]$latestKnown.ReleaseName
                    $fslDate = [string]$latestKnown.ReleaseDate
                    $fslSource = [string]$latestKnown.Source
                }
            }
        }
    }

    $retrieved = if ($psRetrieved -eq 'Online' -and $fslRetrieved -eq 'Online') { 'Online' } else { 'Offline data file' }

    [pscustomobject][ordered]@{
        PowerShellLatest          = $psLatest
        PowerShellLatestPublished = $psPublished
        PowerShellSource          = $psSource
        FSLogixLatest             = $fslLatest
        FSLogixSource             = $fslSource
        Retrieved                 = $retrieved
        FSLogixLatestReleaseName  = $fslName
        FSLogixLatestPublished    = $fslDate
        PowerShellRetrieved       = $psRetrieved
        FSLogixRetrieved          = $fslRetrieved
    }
}
