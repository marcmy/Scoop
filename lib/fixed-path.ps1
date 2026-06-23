# Functions for managing opt-in fixed application paths.

function fixedpathdir($app, $global) {
    "$(basedir $global)\fixed\$app"
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

    $root = fixedpathdir $App $Global
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

function Remove-ScoopFixedPathDirectory {
    param([Parameter(Mandatory = $true)] [String] $Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
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
    $dir = $Directory

    rm_shims $App $Manifest $Global $Architecture
    rm_startmenu_shortcuts $Manifest $Global $Architecture

    # Remove both possible path variants before adding the selected one.
    env_rm_path $Manifest $current $Global $Architecture
    env_rm_path $Manifest $fixed $Global $Architecture
    env_rm $Manifest $Global $Architecture

    create_shims $Manifest $dir $Global $Architecture
    create_startmenu_shortcuts $Manifest $dir $Global $Architecture
    env_add_path $Manifest $dir $Global $Architecture
    env_set $Manifest $Global $Architecture
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

    $fixed = fixedpathdir $App $Global
    $parent = Split-Path $fixed
    $staging = "$fixed.new"
    $old = "$fixed.old"
    ensure $parent | Out-Null

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

        if (Test-Path -LiteralPath $old) {
            Remove-ScoopFixedPathDirectory $old
        }
    } catch {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw "Failed to build fixed path for '$App': $($_.Exception.Message)"
    }

    if ($UpdateLaunchers) {
        Set-ScoopAppLaunchersToDirectory -App $App -Global $Global -Manifest $Manifest -Architecture $Architecture -Directory $fixed
    }

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

    $fixed = fixedpathdir $App $Global
    foreach ($path in @($fixed, "$fixed.new", "$fixed.old")) {
        if (Test-Path -LiteralPath $path) {
            Remove-ScoopFixedPathDirectory $path
        }
    }
}

function Get-ScoopPreferredLaunchRoot {
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global
    )

    $fixed = fixedpathdir $App $Global
    if ((Test-ScoopFixedPathEnabled -App $App -Global $Global) -and (Test-Path -LiteralPath $fixed -PathType Container)) {
        return $fixed
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
            $path = fixedpathdir $app $scope.Global
            $status = if (!$installed) {
                'app not installed'
            } elseif (Test-Path -LiteralPath $path -PathType Container) {
                'ready'
            } else {
                'rebuild required'
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
