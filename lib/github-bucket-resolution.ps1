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
