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
                $scope = $true
            } elseif (installed $app $false) {
                $scope = $false
            } elseif (installed $app $true) {
                $scope = $true
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
        return $false
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
    $processIds = @($Processes | ForEach-Object { [Int32]$_.Id })
    $processInfo = @()

    try {
        $processInfo = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                [Int32]$_.ProcessId -in $processIds
            })
    } catch {
        $processInfo = @($Processes | ForEach-Object {
                [PSCustomObject]@{
                    ProcessId       = [Int32]$_.Id
                    ParentProcessId = 0
                    ExecutablePath  = try { $_.Path } catch { $null }
                }
            })
    }

    $rootProcesses = @(Get-ScoopRootProcessInfo -ProcessInfo $processInfo)
    if ($rootProcesses.Count -eq 0) {
        $rootProcesses = $processInfo
    }

    $restartExecutables = @()
    $seen = @{}
    foreach ($rootProcess in $rootProcesses) {
        $process = $Processes | Where-Object { [Int32]$_.Id -eq [Int32]$rootProcess.ProcessId } | Select-Object -First 1
        $path = if ($process) {
            try { $process.Path } catch { $null }
        } else {
            $rootProcess.ExecutablePath
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
            $path = try { $process.Path } catch { $null }
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

function Start-ScoopAppAfterUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $State,
        [Switch] $PreferOriginalPath
    )

    $currentRoot = currentdir $State.App $State.Global
    foreach ($restartExecutable in @($State.RestartExecutables)) {
        $newPath = Join-Path $currentRoot $restartExecutable.RelativePath
        if (!$PreferOriginalPath -and (Test-Path $newPath -PathType Leaf)) {
            $targetPath = $newPath
        } elseif (Test-Path $restartExecutable.OriginalPath -PathType Leaf) {
            $targetPath = $restartExecutable.OriginalPath
        } elseif (Test-Path $newPath -PathType Leaf) {
            $targetPath = $newPath
        } else {
            warn "Could not restart '$($State.App)': executable not found."
            continue
        }

        $alreadyRunning = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
                try {
                    $_.Path -and $_.Path.Equals($targetPath, [StringComparison]::OrdinalIgnoreCase)
                } catch {
                    $false
                }
            }).Count -gt 0
        if ($alreadyRunning) {
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
        warn "Automatic close skipped for '$($Target.App)' because a matching process is a Windows service."
        return $null
    }

    $state = New-ScoopAppUpdateProcessState -Target $Target -Processes $processes
    Write-Host "Stopping running instances of '$($Target.App)'..."
    Write-Host ($processes | Format-Table -AutoSize | Out-String)

    try {
        $processes | Stop-Process -Force -ErrorAction Stop
        foreach ($process in $processes) {
            try { $process.WaitForExit() } catch { }
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
