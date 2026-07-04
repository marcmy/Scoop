# GitHub bucket-qualified install support.

function ConvertFrom-ScoopGitHubBucketInstallSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory)][String] $Spec)

    if ([String]::IsNullOrWhiteSpace($Spec)) { return $null }

    $candidate = $Spec.Trim()
    if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) { return $null }

    $fullUrlPattern = '^https://github[.]com/(?<owner>[A-Za-z0-9-]+)/(?<repository>[A-Za-z0-9._-]+)/(?<target>[A-Za-z0-9._@-]+)/?$'
    $shortPattern = '^(?<owner>[A-Za-z0-9-]+)/(?<repository>[A-Za-z0-9._-]+)/(?<target>[A-Za-z0-9._@-]+)$'
    if (($candidate -notmatch $fullUrlPattern) -and ($candidate -notmatch $shortPattern)) { return $null }

    $owner = $Matches.owner
    $repository = $Matches.repository -replace '[.]git$', ''
    $target = $Matches.target
    $version = $null

    $versionSeparator = $target.LastIndexOf('@')
    if ($versionSeparator -gt 0) {
        $version = $target.Substring($versionSeparator + 1)
        $target = $target.Substring(0, $versionSeparator)
    }

    $app = $target -replace '[.]json$', ''
    if (!$repository -or !$app) { return $null }

    return [PSCustomObject]@{
        Owner         = $owner
        Repository    = $repository
        App           = $app
        Version       = $version
        RepositoryUrl = "https://github.com/$owner/$repository"
    }
}

function Find-ScoopBucketByRepository {
    [CmdletBinding()]
    param([Parameter(Mandatory)][String] $RepositoryUrl)

    $normalizedRepository = Convert-RepositoryUri -Uri $RepositoryUrl
    if (!$normalizedRepository) { return $null }

    foreach ($bucket in Get-LocalBucket) {
        $bucketRoot = Find-BucketDirectory $bucket -Root
        if (!(Test-Path (Join-Path $bucketRoot '.git'))) { continue }

        $remote = Invoke-Git -Path $bucketRoot -ArgumentList @('config', '--get', 'remote.origin.url')
        if (!$remote) { continue }

        if ((Convert-RepositoryUri -Uri $remote) -eq $normalizedRepository) {
            return $bucket
        }
    }

    return $null
}

function Get-ScoopAvailableBucketName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][String] $Owner,
        [Parameter(Mandatory)][String] $Repository
    )

    if (!(Test-Path (Find-BucketDirectory $Owner -Root))) { return $Owner }

    $baseName = "$Owner-$Repository" -replace '[^A-Za-z0-9._-]', '-'
    $candidate = $baseName
    $suffix = 2
    while (Test-Path (Find-BucketDirectory $candidate -Root)) {
        $candidate = "$baseName-$suffix"
        $suffix++
    }

    return $candidate
}

function Update-ScoopBucketForInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)][String] $Name)

    $bucketRoot = Find-BucketDirectory $Name -Root
    if (!(Test-Path (Join-Path $bucketRoot '.git'))) {
        error "Bucket '$Name' is not a Git repository and cannot be updated."
        return 1
    }

    $output = Invoke-Git -Path $bucketRoot -ArgumentList @('fetch', '--prune', '-q', 'origin') 2>&1
    if ($LASTEXITCODE -ne 0) {
        error "Failed to fetch bucket '$Name'.`n$output"
        return 1
    }

    $output = Invoke-Git -Path $bucketRoot -ArgumentList @('merge', '--ff-only', '-q', '@{u}') 2>&1
    if ($LASTEXITCODE -ne 0) {
        error "Failed to fast-forward bucket '$Name'.`n$output"
        return 1
    }

    return 0
}

function Resolve-ScoopGitHubBucketInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][String] $Spec,
        [Parameter(Mandatory)][Hashtable] $RepositoryCache
    )

    $request = ConvertFrom-ScoopGitHubBucketInstallSpec -Spec $Spec
    if (!$request) { return $Spec }

    $normalizedRepository = Convert-RepositoryUri -Uri $request.RepositoryUrl
    $repositoryKey = $normalizedRepository.ToLowerInvariant()

    if ($RepositoryCache.ContainsKey($repositoryKey)) {
        $bucket = $RepositoryCache[$repositoryKey]
    } else {
        $bucket = Find-ScoopBucketByRepository -RepositoryUrl $request.RepositoryUrl
        if ($bucket) {
            Write-Host "Updating bucket '$bucket'..."
            if ((Update-ScoopBucketForInstall -Name $bucket) -ne 0) {
                abort "Failed to update bucket '$bucket'."
            }
        } else {
            $bucket = Get-ScoopAvailableBucketName -Owner $request.Owner -Repository $request.Repository
            $status = add_bucket $bucket $request.RepositoryUrl
            if ($status -ne 0) {
                $bucket = Find-ScoopBucketByRepository -RepositoryUrl $request.RepositoryUrl
                if (!$bucket) {
                    abort "Failed to add GitHub bucket '$($request.RepositoryUrl)'."
                }
            }
        }

        $RepositoryCache[$repositoryKey] = $bucket
    }

    if (!(manifest $request.App $bucket)) {
        abort "Couldn't find manifest for '$($request.App)' in bucket '$bucket'."
    }

    $qualifiedApp = "$bucket/$($request.App)"
    if ($request.Version) { $qualifiedApp += "@$($request.Version)" }
    return $qualifiedApp
}
