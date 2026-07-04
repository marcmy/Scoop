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
