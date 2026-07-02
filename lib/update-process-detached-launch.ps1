# Relaunch integration for automatic process restart during updates.
#
# Start-Process normally creates an independent process on Windows, but some
# desktop apps can still remain associated with the updater terminal's console
# lifetime. Delegating the launch to the interactive Windows shell gives the
# restarted app the same ownership model as launching it from Explorer.

function Start-ScoopDetachedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String] $FilePath,
        [Parameter(Mandatory = $true)]
        [String] $WorkingDirectory
    )

    $shell = $null
    try {
        $shell = New-Object -ComObject 'Shell.Application' -ErrorAction Stop
        $shell.ShellExecute($FilePath, '', $WorkingDirectory, 'open', 1)
    } catch {
        Write-Debug "Windows shell launch failed for '$FilePath'; falling back to Start-Process: $($_.Exception.Message)"
        Start-Process -FilePath $FilePath -WorkingDirectory $WorkingDirectory
    } finally {
        if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
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
        Start-ScoopDetachedProcess -FilePath $targetPath -WorkingDirectory (Split-Path -Parent $targetPath)
    }
}
