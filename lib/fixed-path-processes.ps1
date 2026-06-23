# Fixed-path integration for automatic process close/restart during updates.
# This file is loaded after update-processes.ps1 and intentionally extends a
# few of its functions so fixed-path processes are treated as app processes.

function Get-ScoopAppRunningProcesses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String] $App,
        [Boolean] $Global
    )

    $roots = @((appdir $App $Global))
    $fixed = fixedpathdir $App $Global
    if (Test-Path -LiteralPath $fixed) {
        $roots += $fixed
    }

    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $path = $null
            try { $path = $_.Path } catch { }
            if (!$path) {
                return $false
            }
            foreach ($root in $roots) {
                if ((Test-Path -LiteralPath $root) -and (Test-ScoopPathWithinRoot -Root $root -Path $path)) {
                    return $true
                }
            }
            return $false
        })
}

function Get-ScoopAppRelativeExecutablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [String] $App,
        [Boolean] $Global,
        [Parameter(Mandatory = $true)] [String] $ExecutablePath
    )

    $fixed = fixedpathdir $App $Global
    if ((Test-Path -LiteralPath $fixed) -and (Test-ScoopPathWithinRoot -Root $fixed -Path $ExecutablePath)) {
        $separators = [Char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $fixedRoot = [IO.Path]::GetFullPath($fixed).TrimEnd($separators)
        return ([IO.Path]::GetFullPath($ExecutablePath)).Substring($fixedRoot.Length).TrimStart($separators)
    }

    return Get-ScoopRelativeExecutablePath -AppRoot (appdir $App $Global) -ExecutablePath $ExecutablePath
}

function New-ScoopAppUpdateProcessState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $Target,
        [Parameter(Mandatory = $true)]
        [Object[]] $Processes
    )

    $processInfo = @(Get-ScoopProcessInfo -Processes $Processes)
    $rootProcesses = @(Get-ScoopRootProcessInfo -ProcessInfo $processInfo)
    if ($rootProcesses.Count -eq 0) {
        $rootProcesses = $processInfo
    }

    $restartExecutables = @()
    $seen = @{}
    foreach ($rootProcess in $rootProcesses) {
        $process = $Processes | Where-Object { [Int32]$_.Id -eq [Int32]$rootProcess.ProcessId } | Select-Object -First 1
        $path = $null
        if ($process) {
            try { $path = $process.Path } catch { }
        }
        if (!$path) {
            $path = $rootProcess.ExecutablePath
        }
        if (!$path) {
            continue
        }

        $relativePath = Get-ScoopAppRelativeExecutablePath -App $Target.App -Global $Target.Global -ExecutablePath $path
        if (!$relativePath) {
            continue
        }

        $key = $relativePath.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true

        $restartExecutables += [PSCustomObject]@{
            RelativePath = $relativePath
            OriginalPath = $path
        }
    }

    if ($restartExecutables.Count -eq 0) {
        $fallback = @($Processes | Where-Object { $_.MainWindowHandle -ne 0 })
        if ($fallback.Count -eq 0) {
            $fallback = @($Processes | Select-Object -First 1)
        }
        foreach ($process in $fallback) {
            $path = $null
            try { $path = $process.Path } catch { }
            if (!$path) {
                continue
            }
            $relativePath = Get-ScoopAppRelativeExecutablePath -App $Target.App -Global $Target.Global -ExecutablePath $path
            if ($relativePath) {
                $restartExecutables += [PSCustomObject]@{
                    RelativePath = $relativePath
                    OriginalPath = $path
                }
            }
        }
    }

    return [PSCustomObject]@{
        App                = $Target.App
        Global             = $Target.Global
        Processes          = @($Processes)
        RestartExecutables = @($restartExecutables)
    }
}

function Resolve-ScoopRestartExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $State,
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $RestartExecutable,
        [Switch] $PreferOriginalPath
    )

    if ($PreferOriginalPath -and (Test-Path $RestartExecutable.OriginalPath -PathType Leaf)) {
        return $RestartExecutable.OriginalPath
    }

    $newPath = Join-Path (Get-ScoopPreferredLaunchRoot -App $State.App -Global $State.Global) $RestartExecutable.RelativePath
    if (Test-Path $newPath -PathType Leaf) {
        return $newPath
    }
    if (Test-Path $RestartExecutable.OriginalPath -PathType Leaf) {
        return $RestartExecutable.OriginalPath
    }

    $appRoot = appdir $State.App $State.Global
    return Get-ChildItem $appRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'current' } |
        Sort-Object LastWriteTimeUtc -Descending |
        ForEach-Object { Join-Path $_.FullName $RestartExecutable.RelativePath } |
        Where-Object { Test-Path $_ -PathType Leaf } |
        Select-Object -First 1
}

function Test-ScoopAppExecutableRunning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $State,
        [Parameter(Mandatory = $true)]
        [String] $RelativePath
    )

    foreach ($process in @(Get-ScoopAppRunningProcesses -App $State.App -Global $State.Global)) {
        $path = $null
        try { $path = $process.Path } catch { }
        if (!$path) {
            continue
        }
        $runningRelativePath = Get-ScoopAppRelativeExecutablePath -App $State.App -Global $State.Global -ExecutablePath $path
        if ($runningRelativePath -and $runningRelativePath.Equals($RelativePath, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Sync-ScoopFixedPathsAfterUpdate {
    [CmdletBinding()]
    param([PSCustomObject[]] $Targets)

    foreach ($target in @($Targets)) {
        if (!(Test-ScoopFixedPathEnabled -App $target.App -Global $target.Global)) {
            continue
        }
        if (!(installed $target.App $target.Global)) {
            continue
        }

        $version = Select-CurrentVersion -AppName $target.App -Global:$target.Global
        $manifest = installed_manifest $target.App $version $target.Global
        $install = install_info $target.App $version $target.Global
        $architecture = Format-ArchitectureString $install.architecture

        try {
            Sync-ScoopFixedPath -App $target.App -Global $target.Global -Manifest $manifest -Architecture $architecture -UpdateLaunchers | Out-Null
        } catch {
            error $_.Exception.Message
            throw
        }
    }
}

function Invoke-ScoopUpdateWithProcessManagement {
    [CmdletBinding()]
    param([String[]] $Arguments)

    $settings = Get-ScoopUpdateProcessSettings

    $opt, $apps, $err = getopt $Arguments 'gfiksqa' 'global', 'force', 'independent', 'no-cache', 'skip-hash-check', 'quiet', 'all'
    if ($err) {
        exec 'update' $Arguments
        return
    }

    $global = $opt.g -or $opt.global
    $all = $opt.a -or $opt.all
    $appArguments = @($apps | Where-Object { $_ -ne 'scoop' })
    if (!$all -and $appArguments.Count -eq 0) {
        exec 'update' $Arguments
        return
    }

    if ($global -and !(is_admin)) {
        exec 'update' $Arguments
        return
    }

    if (($apps -contains 'scoop') -or (is_scoop_outdated)) {
        exec 'update' @()
    }

    $targets = @(Get-ScoopUpdateTargets -Arguments $Arguments)
    if ($targets.Count -eq 0) {
        exec 'update' $Arguments
        return
    }

    $states = @()
    try {
        if ($settings.Close) {
            foreach ($target in $targets) {
                $state = Stop-ScoopAppForUpdate -Target $target
                if ($state) {
                    $states += $state
                }
            }
        }

        $blockedFixedApps = @($targets | Where-Object {
                (Test-ScoopFixedPathEnabled -App $_.App -Global $_.Global) -and
                (@(Get-ScoopAppRunningProcesses -App $_.App -Global $_.Global).Count -gt 0)
            })
        if ($blockedFixedApps.Count -gt 0) {
            foreach ($target in $blockedFixedApps) {
                error "'$($target.App)' is still running from its fixed path. Close it and try again."
            }
            return
        }

        exec 'update' $Arguments
        Sync-ScoopFixedPathsAfterUpdate -Targets $targets
    } finally {
        if ($settings.Restart) {
            foreach ($state in $states) {
                Start-ScoopAppAfterUpdate -State $state
            }
        }
    }
}
