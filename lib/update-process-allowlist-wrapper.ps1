# Apply per-app close/restart policies while preserving fixed-path updates.
# Loaded after update-processes.ps1 and fixed-path-processes.ps1.

function New-ScoopTargetUpdateArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject] $Target,
        [Parameter(Mandatory = $true)] [Object] $Options
    )

    $arguments = @($Target.App)
    if ($Target.Global) {
        $arguments += '--global'
    }
    if ($Options.f -or $Options.force) {
        $arguments += '--force'
    }
    if ($Options.i -or $Options.independent) {
        $arguments += '--independent'
    }
    if ($Options.k -or $Options.'no-cache') {
        $arguments += '--no-cache'
    }
    if ($Options.s -or $Options.'skip-hash-check') {
        $arguments += '--skip-hash-check'
    }
    if ($Options.q -or $Options.quiet) {
        $arguments += '--quiet'
    }

    return @($arguments)
}

function Write-ScoopRunningProcessSkip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject] $Target,
        [Parameter(Mandatory = $true)] [Object[]] $Processes
    )

    error "The following instances of `"$($Target.App)`" are still running. Skipping its update."
    Write-Host ($Processes | Format-Table -AutoSize | Out-String)
}

function Invoke-ScoopLegacyUpdateProcessManagement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [String[]] $Arguments,
        [Parameter(Mandatory = $true)] [PSCustomObject[]] $Targets,
        [Parameter(Mandatory = $true)] [PSCustomObject] $Settings
    )

    $states = @()
    try {
        if ($Settings.CloseAll) {
            foreach ($target in $Targets) {
                $state = Stop-ScoopAppForUpdate -Target $target
                if ($state) {
                    $states += $state
                }
            }
        }

        $blockedFixedApps = @($Targets | Where-Object {
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
        Sync-ScoopFixedPathsAfterUpdate -Targets $Targets
    } finally {
        if ($Settings.RestartAll) {
            foreach ($state in $states) {
                Start-ScoopAppAfterUpdate -State $state
            }
        }
    }
}

function Invoke-ScoopAllowlistedUpdateProcessManagement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject[]] $Targets,
        [Parameter(Mandatory = $true)] [PSCustomObject] $Settings,
        [Parameter(Mandatory = $true)] [Object] $Options
    )

    foreach ($target in $Targets) {
        $policy = Get-ScoopUpdateProcessPolicy -Settings $Settings -Target $target
        $processes = @(Get-ScoopAppRunningProcesses -App $target.App -Global $target.Global)
        $state = $null

        if ($processes.Count -gt 0 -and $policy.Close) {
            $state = Stop-ScoopAppForUpdate -Target $target
            $processes = @(Get-ScoopAppRunningProcesses -App $target.App -Global $target.Global)
        }

        if ($processes.Count -gt 0) {
            Write-ScoopRunningProcessSkip -Target $target -Processes $processes
            continue
        }

        $restartState = if ($state -and $policy.Restart) { $state } else { $null }
        try {
            $targetArguments = New-ScoopTargetUpdateArguments -Target $target -Options $Options
            exec 'update' $targetArguments

            if ((Test-ScoopFixedPathEnabled -App $target.App -Global $target.Global) -and
                (installed $target.App $target.Global)) {
                Sync-ScoopFixedPathsAfterUpdate -Targets @($target)
            }
        } finally {
            if ($restartState) {
                Start-ScoopAppAfterUpdate -State $restartState
            }
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

    if ($settings.UseAllowlists) {
        Invoke-ScoopAllowlistedUpdateProcessManagement -Targets $targets -Settings $settings -Options $opt
    } else {
        Invoke-ScoopLegacyUpdateProcessManagement -Arguments $Arguments -Targets $targets -Settings $settings
    }
}
