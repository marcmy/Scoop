# Per-app policy helpers for automatic process close/restart during updates.

function ConvertTo-ScoopAppAllowlist {
    [CmdletBinding()]
    param([Object] $Value)

    if ($null -eq $Value) {
        return @()
    }

    $items = @()
    if ($Value -is [String]) {
        $text = $Value.Trim()
        if ([String]::IsNullOrWhiteSpace($text)) {
            return @()
        }

        if ($text.StartsWith('[')) {
            try {
                $items = @(ConvertFrom-Json -InputObject $text -ErrorAction Stop)
            } catch {
                $items = @($text)
            }
        } else {
            $items = @($text -split '[,;\s]+' | Where-Object { $_ })
        }
    } elseif ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
    } else {
        $items = @($Value)
    }

    $seen = @{}
    $apps = @()
    foreach ($item in $items) {
        if ([String]::IsNullOrWhiteSpace("$item")) {
            continue
        }

        $app, $null, $null = parse_app "$item".Trim()
        if ([String]::IsNullOrWhiteSpace($app) -or $app -eq 'scoop') {
            continue
        }

        $normalized = $app.ToLowerInvariant()
        if (!$seen.ContainsKey($normalized)) {
            $seen[$normalized] = $true
            $apps += $normalized
        }
    }

    return @($apps | Sort-Object)
}

function Test-ScoopConfigDefined {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [String] $Name)

    if ($null -eq $scoopConfig) {
        return $false
    }

    return [Boolean]($scoopConfig.PSObject.Properties.Name -contains $Name.ToLowerInvariant())
}

function Get-ScoopUpdateProcessSettings {
    $hasCloseAllowlist = Test-ScoopConfigDefined AUTO_CLOSE_RUNNING_APPS
    $hasRestartAllowlist = Test-ScoopConfigDefined AUTO_RESTART_RUNNING_APPS
    $useAllowlists = $hasCloseAllowlist -or $hasRestartAllowlist

    $closeApps = if ($hasCloseAllowlist) {
        @(ConvertTo-ScoopAppAllowlist (get_config AUTO_CLOSE_RUNNING_APPS))
    } else {
        @()
    }
    $restartApps = if ($hasRestartAllowlist) {
        @(ConvertTo-ScoopAppAllowlist (get_config AUTO_RESTART_RUNNING_APPS))
    } else {
        @()
    }

    $restartAll = $false
    $closeAll = $false
    if (!$useAllowlists) {
        $restartAll = ConvertTo-ScoopBoolean (get_config AUTO_RESTART_RUNNING_PROCESSES $false)
        $closeAll = (ConvertTo-ScoopBoolean (get_config AUTO_CLOSE_RUNNING_PROCESSES $false)) -or $restartAll
    }

    return [PSCustomObject]@{
        UseAllowlists = $useAllowlists
        CloseAll      = $closeAll
        RestartAll    = $restartAll
        CloseApps     = @($closeApps)
        RestartApps   = @($restartApps)
    }
}

function Get-ScoopUpdateProcessPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject] $Settings,
        [Parameter(Mandatory = $true)] [PSCustomObject] $Target
    )

    if ($Settings.UseAllowlists) {
        $app = $Target.App.ToLowerInvariant()
        $restart = $Settings.RestartApps -contains $app
        $close = $restart -or ($Settings.CloseApps -contains $app)
    } else {
        $restart = [Boolean]$Settings.RestartAll
        $close = [Boolean]($Settings.CloseAll -or $restart)
    }

    return [PSCustomObject]@{
        Close   = $close
        Restart = $restart
    }
}
