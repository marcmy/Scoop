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

    return "$bucket/$($request.App)"
}
