function Update-ScoopBucketForInstall {
    param([String] $Name)
    $bucketRoot = Find-BucketDirectory $Name -Root
    Invoke-Git -Path $bucketRoot -ArgumentList @('fetch', '-q', 'origin') | Out-Null
    if ($LASTEXITCODE -ne 0) { return 1 }
    Invoke-Git -Path $bucketRoot -ArgumentList @('merge', '--ff-only', '-q', '@{u}') | Out-Null
    return $LASTEXITCODE
}
