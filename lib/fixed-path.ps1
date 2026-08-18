# Functions for managing opt-in fixed application paths.

function fixedpathroot($app, $global) {
    "$(basedir $global)\fixed\$app"
}

function fixedpathdir($app, $global) {
    # Keep the launch root at the same lexical depth as apps\<app>\current.
    # Portable applications may persist paths relative to their executable or
    # profile directory, so changing the number of parent components can change
    # what those stored paths resolve to.
    "$(fixedpathroot $app $global)\current"
}

function fixedpathmarker($app, $global) {
    "$(fixedpathroot $app $global)\.scoop-fixed-layout-v2"
}

function Test-ScoopFixedPathCurrentLayout {
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global
    )

    return [Boolean](
        (Test-Path -LiteralPath (fixedpathmarker $App $Global) -PathType Leaf) -and
        (Test-Path -LiteralPath (fixedpathdir $App $Global) -PathType Container)
    )
}

function Test-ScoopLegacyFixedPathLayout {
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global
    )

    $root = fixedpathroot $App $Global
    return [Boolean](
        (Test-Path -LiteralPath $root -PathType Container) -and
        !(Test-Path -LiteralPath (fixedpathmarker $App $Global) -PathType Leaf)
    )
}

function Get-ScoopFixedPathNames {
    param([Object[]] $Names)

    $seen = @{}
    $result = @()
    foreach ($name in @($Names)) {
        if ([String]::IsNullOrWhiteSpace("$name")) {
            continue
        }
        $normalized = "$name".Trim().ToLowerInvariant()
        if (!$seen.ContainsKey($normalized)) {
            $seen[$normalized] = $true
            $result += $normalized
        }
    }
    return @($result | Sort-Object)
}

function Get-ScoopFixedPathConfig {
    $value = get_config FIXED_PATH_APPS
    $userApps = @()
    $globalApps = @()

    if ($null -ne $value) {
        if (($value -is [String]) -or ($value -is [Array])) {
            # Compatibility with early/manual list-only configurations.
            $userApps = @($value)
        } else {
            if ($null -ne $value.user) {
                $userApps = @($value.user)
            }
            if ($null -ne $value.global) {
                $globalApps = @($value.global)
            }
        }
    }

    return [PSCustomObject]@{
        user   = @(Get-ScoopFixedPathNames $userApps)
        global = @(Get-ScoopFixedPathNames $globalApps)
    }
}

function Set-ScoopFixedPathConfig {
    param([Parameter(Mandatory = $true)] [PSCustomObject] $Config)

    $Config.user = @(Get-ScoopFixedPathNames $Config.user)
    $Config.global = @(Get-ScoopFixedPathNames $Config.global)

    if ($Config.user.Count -eq 0 -and $Config.global.Count -eq 0) {
        set_config FIXED_PATH_APPS $null | Out-Null
    } else {
        set_config FIXED_PATH_APPS $Config | Out-Null
    }
}

function Test-ScoopFixedPathEnabled {
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global
    )

    $config = Get-ScoopFixedPathConfig
    $scope = if ($Global) { @($config.global) } else { @($config.user) }
    return [Boolean]($scope | Where-Object { $_ -ieq $App } | Select-Object -First 1)
}

function Set-ScoopFixedPathEnabled {
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global,
        [Parameter(Mandatory = $true)] [Boolean] $Enabled
    )

    $appName = $App.ToLowerInvariant()
    $config = Get-ScoopFixedPathConfig
    $property = if ($Global) { 'global' } else { 'user' }
    $names = @($config.$property)

    if ($Enabled) {
        if (!($names | Where-Object { $_ -ieq $appName })) {
            $names += $appName
        }
    } else {
        $names = @($names | Where-Object { $_ -ine $appName })
    }

    $config.$property = @(Get-ScoopFixedPathNames $names)
    Set-ScoopFixedPathConfig $config
}

function Test-ScoopFixedPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)] [String] $Root,
        [Parameter(Mandatory = $true)] [String] $Path
    )

    try {
        $separators = [Char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd($separators)
        $candidatePath = [IO.Path]::GetFullPath($Path)
    } catch {
        return $false
    }

    if ($candidatePath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    foreach ($separator in ($separators | Select-Object -Unique)) {
        if ($candidatePath.StartsWith("$rootPath$separator", [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-ScoopFixedPathRunningProcesses {
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global
    )

    # Inspect the parent fixed root so legacy-layout executables and any stale
    # migration artifacts cannot escape running-process protection.
    $root = fixedpathroot $App $Global
    if (!(Test-Path -LiteralPath $root)) {
        return @()
    }

    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try {
                $_.Path -and (Test-ScoopFixedPathWithinRoot -Root $root -Path $_.Path)
            } catch {
                $false
            }
        })
}

function Assert-ScoopFixedPathNotRunning {
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global
    )

    $processes = @(Get-ScoopFixedPathRunningProcesses -App $App -Global $Global)
    if ($processes.Count -gt 0) {
        error "The following instances of `"$App`" are running from its fixed path. Close them and try again."
        Write-Host ($processes | Format-Table -AutoSize | Out-String)
        return $false
    }
    return $true
}

function New-ScoopFixedPathTree {
    param(
        [Parameter(Mandatory = $true)] [String] $Source,
        [Parameter(Mandatory = $true)] [String] $Destination
    )

    New-Item -Path $Destination -ItemType Directory -ErrorAction Stop | Out-Null

    foreach ($entry in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        $destinationEntry = Join-Path $Destination $entry.Name
        $isReparsePoint = [Boolean]($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)

        if ($isReparsePoint) {
            $linkTarget = @($entry.Target) | Select-Object -First 1
            if ([String]::IsNullOrWhiteSpace("$linkTarget")) {
                throw "Unable to determine link target for '$($entry.FullName)'."
            }

            if ($entry.LinkType -eq 'Junction') {
                New-DirectoryJunction $destinationEntry $linkTarget | Out-Null
                attrib $destinationEntry +R /L
            } else {
                New-Item -Path $destinationEntry -ItemType SymbolicLink -Value $linkTarget -ErrorAction Stop | Out-Null
            }
            continue
        }

        if ($entry.PSIsContainer) {
            New-ScoopFixedPathTree -Source $entry.FullName -Destination $destinationEntry
        } else {
            New-Item -Path $destinationEntry -ItemType HardLink -Value $entry.FullName -ErrorAction Stop | Out-Null
        }
    }
}

function Remove-ScoopFixedPathItem {
    param(
        [Parameter(Mandatory = $true)]
        [String] $Path
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (!$item) {
        return
    }

    $isReparsePoint = [Boolean](
        $item.Attributes -band [IO.FileAttributes]::ReparsePoint
    )

    if ($isReparsePoint) {
        if ($item.PSIsContainer) {
            # Scoop marks persisted junctions read-only.
            & attrib.exe -R /L $item.FullName 2>$null
            Remove-Item -LiteralPath $item.FullName `
                -Recurse -Force -ErrorAction Stop
        } else {
            Remove-Item -LiteralPath $item.FullName `
                -Force -ErrorAction Stop
        }

        return
    }

    if ($item.PSIsContainer) {
        foreach ($child in @(
            Get-ChildItem -LiteralPath $item.FullName `
                -Force -ErrorAction Stop
        )) {
            Remove-ScoopFixedPathItem -Path $child.FullName
        }
    }

    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
}

function Remove-ScoopFixedPathDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [String] $Path
    )

    Remove-ScoopFixedPathItem -Path $Path
}

function Remove-ScoopLegacyFixedPathArtifacts {
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global
    )

    $root = fixedpathroot $App $Global
    if (!(Test-Path -LiteralPath $root -PathType Container)) {
        return
    }

    $keep = @('current', '.scoop-fixed-layout-v2')
    foreach ($entry in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)) {
        if ($entry.Name -in $keep) {
            continue
        }
        try {
            Remove-ScoopFixedPathItem -Path $entry.FullName
        } catch {
            warn "Could not remove legacy fixed-path artifact '$($entry.FullName)': $($_.Exception.Message)"
        }
    }
}

function Set-ScoopAppLaunchersToDirectory {
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global,
        [Parameter(Mandatory = $true)] [PSCustomObject] $Manifest,
        [Parameter(Mandatory = $true)] [String] $Architecture,
        [Parameter(Mandatory = $true)] [String] $Directory
    )

    $version = Select-CurrentVersion -AppName $App -Global:$Global
    $original_dir = versiondir $App $version $Global
    $persist_dir = persistdir $App $Global
    $current = currentdir $App $Global
    $fixed = fixedpathdir $App $Global
    $fixedRoot = fixedpathroot $App $Global
    $dir = $Directory

    rm_shims $App $Manifest $Global $Architecture
    rm_startmenu_shortcuts $Manifest $Global $Architecture

    # Remove normal, current-layout fixed, and legacy fixed path variants before
    # adding the selected launcher root.
    env_rm_path $Manifest $current $Global $Architecture
    env_rm_path $Manifest $fixed $Global $Architecture
    env_rm_path $Manifest $fixedRoot $Global $Architecture
    env_rm $Manifest $Global $Architecture

    create_shims $Manifest $dir $Global $Architecture
    create_startmenu_shortcuts $Manifest $dir $Global $Architecture
    env_add_path $Manifest $dir $Global $Architecture
    env_set $Manifest $Global $Architecture
}

function Convert-ScoopLegacyFixedPathLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global,
        [Parameter(Mandatory = $true)] [String] $Source,
        [Parameter(Mandatory = $true)] [PSCustomObject] $Manifest,
        [Parameter(Mandatory = $true)] [String] $Architecture,
        [Switch] $UpdateLaunchers
    )

    $root = fixedpathroot $App $Global
    $fixed = fixedpathdir $App $Global
    $marker = fixedpathmarker $App $Global
    $staging = Join-Path $root '.scoop-v2.new'
    $legacyCurrent = Join-Path $root '.scoop-v1-current'

    Remove-ScoopFixedPathDirectory $staging
    if (Test-Path -LiteralPath $legacyCurrent) {
        if (!(Test-Path -LiteralPath $fixed)) {
            Move-Item -LiteralPath $legacyCurrent -Destination $fixed -ErrorAction Stop
        } else {
            Remove-ScoopFixedPathDirectory $legacyCurrent
        }
    }

    Write-Host "Migrating fixed path for '$App' to relative-path-safe layout: $(friendly_path $fixed)"

    try {
        New-ScoopFixedPathTree -Source $Source -Destination $staging
    } catch {
        Remove-ScoopFixedPathDirectory $staging
        throw "Failed to stage fixed path migration for '$App': $($_.Exception.Message)"
    }

    $hadLegacyCurrent = Test-Path -LiteralPath $fixed
    if ($hadLegacyCurrent) {
        Move-Item -LiteralPath $fixed -Destination $legacyCurrent -ErrorAction Stop
    }

    # Commit the filesystem layout first. If that fails, restore any top-level
    # 'current' directory that belonged to the legacy app tree.
    try {
        Move-Item -LiteralPath $staging -Destination $fixed -ErrorAction Stop
        Set-Content -LiteralPath $marker -Value '2' -Encoding Ascii -Force
    } catch {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        Remove-ScoopFixedPathDirectory $fixed
        if ($hadLegacyCurrent -and (Test-Path -LiteralPath $legacyCurrent)) {
            Move-Item -LiteralPath $legacyCurrent -Destination $fixed -ErrorAction SilentlyContinue
        }
        Remove-ScoopFixedPathDirectory $staging
        throw "Failed to migrate fixed path for '$App': $($_.Exception.Message)"
    }

    # Launcher redirection is a separate transaction. The legacy root files are
    # intentionally still present here, so a failure can restore old launchers.
    if ($UpdateLaunchers) {
        try {
            Set-ScoopAppLaunchersToDirectory -App $App -Global $Global -Manifest $Manifest -Architecture $Architecture -Directory $fixed
        } catch {
            $launcherError = $_
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            Remove-ScoopFixedPathDirectory $fixed
            if ($hadLegacyCurrent -and (Test-Path -LiteralPath $legacyCurrent)) {
                Move-Item -LiteralPath $legacyCurrent -Destination $fixed -ErrorAction SilentlyContinue
            }
            try {
                Set-ScoopAppLaunchersToDirectory -App $App -Global $Global -Manifest $Manifest -Architecture $Architecture -Directory $root
            } catch {
                warn "Could not restore legacy launchers for '$App' after migration failure: $($_.Exception.Message)"
            }
            throw "Failed to migrate fixed path for '$App': $($launcherError.Exception.Message)"
        }
    }

    Remove-ScoopLegacyFixedPathArtifacts -App $App -Global $Global
    return $fixed
}

function Sync-ScoopFixedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global,
        [Parameter(Mandatory = $true)] [PSCustomObject] $Manifest,
        [Parameter(Mandatory = $true)] [String] $Architecture,
        [Switch] $UpdateLaunchers
    )

    $source = currentdir $App $Global
    if (!(Test-Path -LiteralPath $source -PathType Container)) {
        throw "Cannot create a fixed path for '$App': current installation directory was not found."
    }

    if (Test-ScoopLegacyFixedPathLayout -App $App -Global $Global) {
        return Convert-ScoopLegacyFixedPathLayout -App $App -Global $Global -Source $source -Manifest $Manifest -Architecture $Architecture -UpdateLaunchers:$UpdateLaunchers
    }

    $root = fixedpathroot $App $Global
    $fixed = fixedpathdir $App $Global
    $staging = "$fixed.new"
    $old = "$fixed.old"
    ensure $root | Out-Null

    Remove-ScoopFixedPathDirectory $staging
    Remove-ScoopFixedPathDirectory $old

    Write-Host "Building fixed path for '$App': $(friendly_path $fixed)"
    try {
        New-ScoopFixedPathTree -Source $source -Destination $staging

        $hadExisting = Test-Path -LiteralPath $fixed
        if ($hadExisting) {
            Move-Item -LiteralPath $fixed -Destination $old -ErrorAction Stop
        }

        try {
            Move-Item -LiteralPath $staging -Destination $fixed -ErrorAction Stop
        } catch {
            if ($hadExisting -and (Test-Path -LiteralPath $old) -and !(Test-Path -LiteralPath $fixed)) {
                Move-Item -LiteralPath $old -Destination $fixed -ErrorAction SilentlyContinue
            }
            throw
        }

        Set-Content -LiteralPath (fixedpathmarker $App $Global) -Value '2' -Encoding Ascii -Force

        if (Test-Path -LiteralPath $old) {
            Remove-ScoopFixedPathDirectory $old
        }
    } catch {
        if (Test-Path -LiteralPath $staging) {
            Remove-ScoopFixedPathDirectory $staging
        }
        throw "Failed to build fixed path for '$App': $($_.Exception.Message)"
    }

    if ($UpdateLaunchers) {
        Set-ScoopAppLaunchersToDirectory -App $App -Global $Global -Manifest $Manifest -Architecture $Architecture -Directory $fixed
    }

    Remove-ScoopLegacyFixedPathArtifacts -App $App -Global $Global
    return $fixed
}

function Restore-ScoopCurrentPathLaunchers {
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global,
        [Parameter(Mandatory = $true)] [PSCustomObject] $Manifest,
        [Parameter(Mandatory = $true)] [String] $Architecture
    )

    Set-ScoopAppLaunchersToDirectory -App $App -Global $Global -Manifest $Manifest -Architecture $Architecture -Directory (currentdir $App $Global)
}

function Remove-ScoopFixedPath {
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global
    )

    $root = fixedpathroot $App $Global
    if (Test-Path -LiteralPath $root) {
        Remove-ScoopFixedPathDirectory $root
    }
}

function Get-ScoopPreferredLaunchRoot {
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global
    )

    if (Test-ScoopFixedPathEnabled -App $App -Global $Global) {
        if (Test-ScoopFixedPathCurrentLayout -App $App -Global $Global) {
            return fixedpathdir $App $Global
        }
        if (Test-ScoopLegacyFixedPathLayout -App $App -Global $Global) {
            return fixedpathroot $App $Global
        }
    }
    return currentdir $App $Global
}

function Get-ScoopFixedPathEntries {
    $config = Get-ScoopFixedPathConfig
    $entries = @()

    foreach ($scope in @(
            [PSCustomObject]@{ Names = @($config.user); Global = $false; Label = 'user' },
            [PSCustomObject]@{ Names = @($config.global); Global = $true; Label = 'global' }
        )) {
        foreach ($app in $scope.Names) {
            $installed = installed $app $scope.Global
            $fixed = fixedpathdir $app $scope.Global
            $legacy = fixedpathroot $app $scope.Global
            if (!$installed) {
                $status = 'app not installed'
                $path = if (Test-ScoopLegacyFixedPathLayout -App $app -Global $scope.Global) { $legacy } else { $fixed }
            } elseif (Test-ScoopFixedPathCurrentLayout -App $app -Global $scope.Global) {
                $status = 'ready'
                $path = $fixed
            } elseif (Test-ScoopLegacyFixedPathLayout -App $app -Global $scope.Global) {
                $status = 'migration required'
                $path = $legacy
            } else {
                $status = 'rebuild required'
                $path = $fixed
            }
            $entries += [PSCustomObject]@{
                App       = $app
                Scope     = $scope.Label
                Installed = $installed
                Status    = $status
                Path      = $path
            }
        }
    }

    return @($entries | Sort-Object Scope, App)
}
