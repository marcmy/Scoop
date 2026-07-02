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
