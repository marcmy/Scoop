BeforeAll {
    . "$PSScriptRoot\Scoop-TestLib.ps1"
    . "$PSScriptRoot\..\lib\core.ps1"
    . "$PSScriptRoot\..\lib\github-bucket-install.ps1"
}

Describe 'ConvertFrom-ScoopGitHubBucketInstallSpec' -Tag 'Scoop' {
    It 'parses the abbreviated owner/repository/app form' {
        $result = ConvertFrom-ScoopGitHubBucketInstallSpec 'Arama0517/scoop-bucket-x/mpcvideorenderer'

        $result.Owner | Should -Be 'Arama0517'
        $result.Repository | Should -Be 'scoop-bucket-x'
        $result.App | Should -Be 'mpcvideorenderer'
        $result.RepositoryUrl | Should -Be 'https://github.com/Arama0517/scoop-bucket-x'
    }

    It 'parses the full GitHub URL form' {
        $result = ConvertFrom-ScoopGitHubBucketInstallSpec 'https://github.com/Arama0517/scoop-bucket-x/mpcvideorenderer'

        $result.Owner | Should -Be 'Arama0517'
        $result.Repository | Should -Be 'scoop-bucket-x'
        $result.App | Should -Be 'mpcvideorenderer'
    }

    It 'does not reinterpret normal bucket-qualified apps' {
        ConvertFrom-ScoopGitHubBucketInstallSpec 'extras/firefox' | Should -BeNullOrEmpty
    }

    It 'does not reinterpret an existing local manifest path' {
        $manifestPath = Join-Path $TestDrive 'owner/repository/app'
        New-Item -ItemType Directory -Path (Split-Path $manifestPath) -Force | Out-Null
        New-Item -ItemType File -Path $manifestPath | Out-Null

        ConvertFrom-ScoopGitHubBucketInstallSpec $manifestPath | Should -BeNullOrEmpty
    }
}
