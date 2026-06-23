# Extend Scoop's ordinary running-process guard to include fixed app paths.

function test_running_process($app, $global) {
    $roots = @(
        (appdir $app $global),
        (Join-Path (basedir $global) "fixed\$app")
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $runningProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $path = $null
            try { $path = $_.Path } catch { }
            if (!$path) {
                return $false
            }

            foreach ($root in $roots) {
                if ($path.StartsWith(
                        ([IO.Path]::GetFullPath($root).TrimEnd('\') + '\'),
                        [StringComparison]::OrdinalIgnoreCase
                    )) {
                    return $true
                }
            }
            return $false
        })

    if ($runningProcesses.Count -gt 0) {
        $formatted = $runningProcesses | Format-Table -AutoSize | Out-String
        if (get_config IGNORE_RUNNING_PROCESSES) {
            warn "The following instances of `"$app`" are still running. Scoop is configured to ignore this condition."
            Write-Host $formatted
            return $false
        }

        error "The following instances of `"$app`" are still running. Close them and try again."
        Write-Host $formatted
        return $true
    }

    return $false
}
