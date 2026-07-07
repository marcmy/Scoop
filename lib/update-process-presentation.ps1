# Concise presentation overrides for managed updates.
# Loaded after update-processes.ps1 and fixed-path.ps1.

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
    $processLabel = if ($processes.Count -eq 1) { 'process' } else { 'processes' }
    Write-Host "Stopping '$($Target.App)' ($($processes.Count) $processLabel)..."
    Write-Verbose ($processes | Format-Table -AutoSize | Out-String)

    # Some tray applications replace one process with another while shutting down.
    # Retry against the current process set so a replacement PID cannot race the
    # final running-process check and trigger the recovery restart path.
    $maxStopAttempts = 50
    $stopPollMilliseconds = 100
    $remainingProcesses = @($processes)

    for ($attempt = 1; $attempt -le $maxStopAttempts -and $remainingProcesses.Count -gt 0; $attempt++) {
        foreach ($process in $remainingProcesses) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
            } catch {
                Write-Verbose "Could not stop process ID $($process.Id) for '$($Target.App)' on attempt $attempt`: $($_.Exception.Message)"
            }
        }

        Start-Sleep -Milliseconds $stopPollMilliseconds
        $remainingProcesses = @(Get-ScoopAppRunningProcesses -App $Target.App -Global $Target.Global)
    }

    if ($remainingProcesses.Count -gt 0) {
        $waitSeconds = ($maxStopAttempts * $stopPollMilliseconds) / 1000
        warn "One or more instances of '$($Target.App)' are still running after waiting $waitSeconds seconds."
        Start-ScoopAppAfterUpdate -State $state -PreferOriginalPath
        return $null
    }

    return $state
}

function Set-ScoopAppLaunchersToDirectory {
    [CmdletBinding()]
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

    Write-Host "Updating launchers for '$App': $(friendly_path $Directory)"

    # Preserve the existing remove/recreate behavior without flooding normal output.
    rm_shims $App $Manifest $Global $Architecture | Out-Null
    & { rm_startmenu_shortcuts $Manifest $Global $Architecture } 6>$null

    # Remove both possible path variants before adding the selected one.
    env_rm_path $Manifest $current $Global $Architecture
    env_rm_path $Manifest $fixed $Global $Architecture
    env_rm $Manifest $Global $Architecture

    create_shims $Manifest $dir $Global $Architecture | Out-Null
    & { create_startmenu_shortcuts $Manifest $dir $Global $Architecture } 6>$null
    env_add_path $Manifest $dir $Global $Architecture
    env_set $Manifest $Global $Architecture
}
