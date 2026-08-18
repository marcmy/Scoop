BeforeAll {
    function basedir($global) {
        return $script:fixedPathTestBase
    }

    function currentdir($app, $global) {
        return Join-Path $script:fixedPathTestBase "apps\$app\current"
    }

    function ensure($path) {
        if (!(Test-Path -LiteralPath $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
        return (Get-Item -LiteralPath $path).FullName
    }

    function friendly_path($path) {
        return $path
    }

    function warn($message) {
        Write-Warning $message
    }

    . "$PSScriptRoot\..\lib\fixed-path.ps1"
}

Describe 'fixed application path layout' -Tag 'Scoop' {
    It 'keeps portable relative paths stable between fixed and current launch roots' {
        $script:fixedPathTestBase = 'C:\Users\marcm\scoop'

        $legacyProfile = Join-Path (fixedpathroot 'qbittorrent-custom' $false) 'profile\qBittorrent'
        $fixedProfile = Join-Path (fixedpathdir 'qbittorrent-custom' $false) 'profile\qBittorrent'
        $currentProfile = Join-Path (currentdir 'qbittorrent-custom' $false) 'profile\qBittorrent'
        $target = 'C:\Users\marcm\Desktop\New folder'

        # The v1 fixed root was one directory shallower. A path made relative
        # there resolves one level too deep when the same profile is opened from
        # apps\<app>\current, reproducing C:\Users\marcm\scoop\Desktop\...
        $legacyRelative = '..\..\..\..\..\Desktop\New folder'
        [IO.Path]::GetFullPath((Join-Path $legacyProfile $legacyRelative)) | Should -Be $target
        [IO.Path]::GetFullPath((Join-Path $currentProfile $legacyRelative)) | Should -Be 'C:\Users\marcm\scoop\Desktop\New folder'

        # The v2 fixed launch root has the same depth as apps\<app>\current, so
        # the portable relative path has identical meaning from either root.
        $safeRelative = '..\..\..\..\..\..\Desktop\New folder'
        [IO.Path]::GetFullPath((Join-Path $fixedProfile $safeRelative)) | Should -Be $target
        [IO.Path]::GetFullPath((Join-Path $currentProfile $safeRelative)) | Should -Be $target
    }

    It 'migrates a legacy fixed tree into the current child without losing app contents' {
        $script:fixedPathTestBase = Join-Path $TestDrive 'scoop'
        $app = 'portable-test'
        $source = currentdir $app $false
        $legacyRoot = fixedpathroot $app $false
        $fixed = fixedpathdir $app $false

        New-Item -Path $source -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'app.exe') -Value 'new executable'
        New-Item -Path (Join-Path $source 'current') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'current\payload.txt') -Value 'nested current payload'

        New-Item -Path $legacyRoot -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $legacyRoot 'app.exe') -Value 'legacy executable'
        New-Item -Path (Join-Path $legacyRoot 'current') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $legacyRoot 'current\legacy.txt') -Value 'legacy current directory'

        $result = Sync-ScoopFixedPath `
            -App $app `
            -Global $false `
            -Manifest ([PSCustomObject]@{}) `
            -Architecture '64bit'

        $result | Should -Be $fixed
        Test-ScoopFixedPathCurrentLayout -App $app -Global $false | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixed 'app.exe') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixed 'current\payload.txt') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $legacyRoot 'app.exe') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $legacyRoot '.scoop-v1-current') | Should -BeFalse
    }
}
