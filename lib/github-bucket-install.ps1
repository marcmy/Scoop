# GitHub bucket-qualified install support.

function ConvertFrom-ScoopGitHubBucketInstallSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory)][String] $Spec)

    if ([String]::IsNullOrWhiteSpace($Spec)) { return $null }

    $candidate = $Spec.Trim()
    if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) { return $null }

    $fullUrlPattern = '^https://github[.]com/(?<owner>[A-Za-z0-9-]+)/(?<repository>[A-Za-z0-9._-]+)/(?<app>[A-Za-z0-9._-]+)$'
    $shortPattern = '^(?<owner>[A-Za-z0-9-]+)/(?<repository>[A-Za-z0-9._-]+)/(?<app>[A-Za-z0-9._-]+)$'
    if (($candidate -notmatch $fullUrlPattern) -and ($candidate -notmatch $shortPattern)) { return $null }

    return [PSCustomObject]@{
        Owner = $Matches.owner
        Repository = $Matches.repository
        App = $Matches.app
        RepositoryUrl = "https://github.com/$($Matches.owner)/$($Matches.repository)"
    }
}
