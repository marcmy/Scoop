function ConvertTo-ScoopBoolean($Value) {
    if ($Value -is [Boolean]) {
        return $Value
    }
    if ([String]::IsNullOrWhiteSpace("$Value")) {
        return $false
    }
    try {
        return [Convert]::ToBoolean($Value)
    } catch {
        return $false
    }
}

function Test-ScoopPathWithinRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String] $Root,
        [Parameter(Mandatory = $true)]
        [String] $Path
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

function Get-ScoopRelativeExecutablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String] $AppRoot,
        [Parameter(Mandatory = $true)]
        [String] $ExecutablePath
    )

    if (!(Test-ScoopPathWithinRoot -Root $AppRoot -Path $ExecutablePath)) {
        return $null
    }

    $separators = [Char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $rootPath = [IO.Path]::GetFullPath($AppRoot).TrimEnd($separators)
    $processPath = [IO.Path]::GetFullPath($ExecutablePath)
    $relativePath = $processPath.Substring($rootPath.Length).TrimStart($separators)
    $parts = $relativePath -split '[\\/]', 2

    if ($parts.Length -lt 2) {
        return $null
    }

    return $parts[1]
}

function Get-ScoopRootProcessInfo {
    [CmdletBinding()]
    param(
        [Object[]] $ProcessInfo
    )

    $processIds = @{}
    foreach ($process in @($ProcessInfo)) {
        if ($null -ne $process.ProcessId) {
            $processIds[[Int32]$process.ProcessId] = $true
        }
    }

    return @($ProcessInfo | Where-Object {
            !$processIds.ContainsKey([Int32]$_.ParentProcessId)
        })
}

function Get-ScoopUpdateProcessSettings {
    $restart = ConvertTo-ScoopBoolean (get_config AUTO_RESTART_RUNNING_PROCESSES $false)
    $close = (ConvertTo-ScoopBoolean (get_config AUTO_CLOSE_RUNNING_PROCESSES $false)) -or $restart

    return [PSCustomObject]@{
        Close   = $close
        Restart = $restart
    }
}

function Get-ScoopUpdateTargets {
    [CmdletBinding()]
    param(
        [String[]] $Arguments
    )

    $opt, $apps, $err = getopt $Arguments 'gfiksqa' 'global', 'force', 'independent', 'no-cache', 'skip-hash-check', 'quiet', 'all'
    if ($err) {
        return @()
    }

    $global = $opt.g -or $opt.global
    $force = $opt.f -or $opt.force
    $all = $opt.a -or $opt.all
    $requestedApps = @($apps)
    $candidates = @()

    if (($requestedApps -contains '*') -or $all) {
        foreach ($app in @(installed_apps $false)) {
            $candidates += [PSCustomObject]@{ App = $app; Global = $false }
        }
        if ($global) {
            foreach ($app in @(installed_apps $true)) {
                $candidates += [PSCustomObject]@{ App = $app; Global = $true }
            }
        }
    } elseif ($requestedApps.Count -gt 0) {
        foreach ($requestedApp in $requestedApps) {
            if ($requestedApp -eq 'scoop') {
                continue
            }

            $app, $null, $null = parse_app $requestedApp
            if ([String]::IsNullOrWhiteSpace($app)) {
                continue
            }

            if ($global) {
                if (!(installed $app $true)) {
                    continue
                }
                $scope = $true
            } elseif (installed $app $false) {
                $scope = $false
            } else {
                continue
            }

            $candidates += [PSCustomObject]@{ App = $app; Global = $scope }
        }
    }

    $targets = @()
    $seen = @{}
    foreach ($candidate in $candidates) {
        $key = "{0}:{1}" -f ([Int32]$candidate.Global), $candidate.App.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true

        try {
            $status = app_status $candidate.App $candidate.Global
        } catch {
            continue
        }

        if ($status.installed -and !$status.hold -and ($force -or $status.outdated)) {
            $targets += $candidate
        }
    }

    return $targets
}

function Get-ScoopAppRunningProcesses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String] $App,
        [Boolean] $Global
    )

    $appRoot = appdir $App $Global
    if (!(Test-Path $appRoot)) {
        return @()
    }

    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try {
                $_.Path -and (Test-ScoopPathWithinRoot -Root $appRoot -Path $_.Path)
            } catch {
                $false
            }
        })
}

function Test-ScoopProcessesIncludeService {
    [CmdletBinding()]
    param(
        [Object[]] $Processes
    )

    $processIds = @($Processes | ForEach-Object { [Int32]$_.Id })
    if ($processIds.Count -eq 0) {
        return $false
    }

    try {
        return [Boolean](Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
                [Int32]$_.ProcessId -in $processIds
            } | Select-Object -First 1)
    } catch {
        warn "Unable to verify whether matching processes are Windows services; automatic close is being skipped."
        return $true
    }
}

function Get-ScoopProcessInfo {
    [CmdletBinding()]
    param(
        [Object[]] $Processes
    )

    $processIds = @($Processes | ForEach-Object { [Int32]$_.Id })
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                [Int32]$_.ProcessId -in $processIds
            })
    } catch {
        return @($Processes | ForEach-Object {
                $path = $null
                try { $path = $_.Path } catch { }
                [PSCustomObject]@{
                    ProcessId       = [Int32]$_.Id
                    ParentProcessId = 0
                    ExecutablePath  = $path
                }
            })
    }
}

function New-ScoopAppUpdateProcessState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $Target,
        [Parameter(Mandatory = $true)]
        [Object[]] $Processes
    )

    $appRoot = appdir $Target.App $Target.Global
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

        $relativePath = Get-ScoopRelativeExecutablePath -AppRoot $appRoot -ExecutablePath $path
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
            $relativePath = Get-ScoopRelativeExecutablePath -AppRoot $appRoot -ExecutablePath $path
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

    $newPath = Join-Path (currentdir $State.App $State.Global) $RestartExecutable.RelativePath
    if ($PreferOriginalPath -and (Test-Path $RestartExecutable.OriginalPath -PathType Leaf)) {
        return $RestartExecutable.OriginalPath
    }
    if (Test-Path $newPath -PathType Leaf) {
        return $newPath
    }
    if (Test-Path $RestartExecutable.OriginalPath -PathType Leaf) {
        return $RestartExecutable.OriginalPath
    }

    $appRoot = appdir $State.App $State.Global
    $candidate = Get-ChildItem $appRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'current' } |
        Sort-Object LastWriteTimeUtc -Descending |
        ForEach-Object { Join-Path $_.FullName $RestartExecutable.RelativePath } |
        Where-Object { Test-Path $_ -PathType Leaf } |
        Select-Object -First 1

    return $candidate
}

function Test-ScoopAppExecutableRunning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $State,
        [Parameter(Mandatory = $true)]
        [String] $RelativePath
    )

    $appRoot = appdir $State.App $State.Global
    foreach ($process in @(Get-ScoopAppRunningProcesses -App $State.App -Global $State.Global)) {
        $path = $null
        try { $path = $process.Path } catch { }
        if (!$path) {
            continue
        }
        $runningRelativePath = Get-ScoopRelativeExecutablePath -AppRoot $appRoot -ExecutablePath $path
        if ($runningRelativePath -and $runningRelativePath.Equals($RelativePath, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Start-ScoopAppAfterUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $State,
        [Switch] $PreferOriginalPath
    )

    foreach ($restartExecutable in @($State.RestartExecutables)) {
        if (Test-ScoopAppExecutableRunning -State $State -RelativePath $restartExecutable.RelativePath) {
            continue
        }

        $targetPath = Resolve-ScoopRestartExecutable -State $State -RestartExecutable $restartExecutable -PreferOriginalPath:$PreferOriginalPath
        if (!$targetPath) {
            warn "Could not restart '$($State.App)': executable not found."
            continue
        }

        Write-Host "Restarting '$($State.App)': $(friendly_path $targetPath)"
        Start-Process -FilePath $targetPath -WorkingDirectory (Split-Path $targetPath)
    }
}

function Stop-ScoopAppForUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $Target
    )

    $processes = @(Get-ScoopAppRunningProcesses -App $Target.App -Global $Target.Global)
    if ($processes.Count -eq 0) {
        return $null
    }

    if (Test-ScoopProcessesIncludeService -Processes $processes) {
        warn "Automatic close skipped for '$($Target.App)' because a matching process may be a Windows service."
        return $null
    }

    $state = New-ScoopAppUpdateProcessState -Target $Target -Processes $processes
    Write-Host "Stopping running instances of '$($Target.App)'..."
    Write-Host ($processes | Format-Table -AutoSize | Out-String)

    try {
        $processes | Stop-Process -Force -ErrorAction Stop
        foreach ($process in $processes) {
            try { Wait-Process -Id $process.Id -ErrorAction SilentlyContinue } catch { }
        }
    } catch {
        warn "Could not stop all instances of '$($Target.App)': $($_.Exception.Message)"
        Start-ScoopAppAfterUpdate -State $state -PreferOriginalPath
        return $null
    }

    if (@(Get-ScoopAppRunningProcesses -App $Target.App -Global $Target.Global).Count -gt 0) {
        warn "One or more instances of '$($Target.App)' are still running."
        Start-ScoopAppAfterUpdate -State $state -PreferOriginalPath
        return $null
    }

    return $state
}

function Invoke-ScoopUpdateWithProcessManagement {
    [CmdletBinding()]
    param(
        [String[]] $Arguments
    )

    $settings = Get-ScoopUpdateProcessSettings
    if (!$settings.Close) {
        exec 'update' $Arguments
        return
    }

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
        foreach ($target in $targets) {
            $state = Stop-ScoopAppForUpdate -Target $target
            if ($state) {
                $states += $state
            }
        }
        exec 'update' $Arguments
    } finally {
        if ($settings.Restart) {
            foreach ($state in $states) {
                Start-ScoopAppAfterUpdate -State $state
            }
        }
    }
}
