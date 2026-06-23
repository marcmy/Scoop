# Shared command implementation for per-app automatic close/restart policies.

function Get-ScoopProcessPolicyCommandMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Close', 'Restart')]
        [String] $Policy
    )

    if ($Policy -eq 'Restart') {
        return [PSCustomObject]@{
            ConfigName = 'AUTO_RESTART_RUNNING_APPS'
            Label      = 'automatic restart'
            Verb       = 'restart'
        }
    }

    return [PSCustomObject]@{
        ConfigName = 'AUTO_CLOSE_RUNNING_APPS'
        Label      = 'automatic close'
        Verb       = 'close'
    }
}

function Get-ScoopProcessPolicyApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Close', 'Restart')]
        [String] $Policy
    )

    $metadata = Get-ScoopProcessPolicyCommandMetadata -Policy $Policy
    return @(ConvertTo-ScoopAppAllowlist (get_config $metadata.ConfigName))
}

function Set-ScoopProcessPolicyApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Close', 'Restart')]
        [String] $Policy,
        [String[]] $Apps
    )

    $metadata = Get-ScoopProcessPolicyCommandMetadata -Policy $Policy
    $normalized = @(ConvertTo-ScoopAppAllowlist @($Apps))

    # Using the per-app commands migrates away from the legacy all-app switches,
    # so clearing both lists cannot unexpectedly re-enable global close/restart.
    set_config AUTO_CLOSE_RUNNING_PROCESSES $null | Out-Null
    set_config AUTO_RESTART_RUNNING_PROCESSES $null | Out-Null

    if ($normalized.Count -eq 0) {
        set_config $metadata.ConfigName $null | Out-Null
    } else {
        set_config $metadata.ConfigName ($normalized -join ',') | Out-Null
    }
}

function Resolve-ScoopProcessPolicyCommandApps {
    [CmdletBinding()]
    param([String[]] $Arguments)

    $resolved = @()
    foreach ($argument in @($Arguments)) {
        $candidate = ("$argument").Trim()
        if ([String]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $app, $null, $null = parse_app $candidate
        if ([String]::IsNullOrWhiteSpace($app)) {
            continue
        }
        if ($app -eq 'scoop') {
            return [PSCustomObject]@{
                Success = $false
                Error   = "'scoop' cannot be managed by an update process policy."
                Apps    = @()
            }
        }
        $resolved += $app
    }

    return [PSCustomObject]@{
        Success = $true
        Error   = $null
        Apps    = @(ConvertTo-ScoopAppAllowlist $resolved)
    }
}

function Show-ScoopProcessPolicyApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Close', 'Restart')]
        [String] $Policy
    )

    if ($Policy -eq 'Restart') {
        $apps = @(Get-ScoopProcessPolicyApps -Policy Restart)
        if ($apps.Count -eq 0) {
            info 'No apps are configured for automatic restart.'
            return
        }

        $apps | ForEach-Object {
            [PSCustomObject]@{ App = $_ }
        } | Format-Table -AutoSize
        return
    }

    $closeApps = @(Get-ScoopProcessPolicyApps -Policy Close)
    $restartApps = @(Get-ScoopProcessPolicyApps -Policy Restart)
    $apps = @(ConvertTo-ScoopAppAllowlist (@($closeApps) + @($restartApps)))
    if ($apps.Count -eq 0) {
        info 'No apps are configured for automatic close.'
        return
    }

    $apps | ForEach-Object {
        $explicitClose = $_ -in $closeApps
        $restart = $_ -in $restartApps
        $mode = if ($explicitClose -and $restart) {
            'close + restart'
        } elseif ($restart) {
            'restart'
        } else {
            'close'
        }

        [PSCustomObject]@{
            App  = $_
            Mode = $mode
        }
    } | Format-Table -AutoSize
}

function Invoke-ScoopProcessPolicyCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Close', 'Restart')]
        [String] $Policy,
        [String] $SubCommand,
        [String[]] $Arguments
    )

    $metadata = Get-ScoopProcessPolicyCommandMetadata -Policy $Policy
    $knownSubCommands = @('add', 'remove', 'rm', 'list', 'clear')

    if ([String]::IsNullOrWhiteSpace($SubCommand)) {
        Show-ScoopProcessPolicyApps -Policy $Policy | Out-Host
        return 0
    }

    switch ($SubCommand) {
        'list' {
            if (@($Arguments).Count -gt 0) {
                error "Subcommand 'list' does not accept app names."
                return 1
            }
            Show-ScoopProcessPolicyApps -Policy $Policy | Out-Host
            return 0
        }
        'clear' {
            if (@($Arguments).Count -gt 0) {
                error "Subcommand 'clear' does not accept app names."
                return 1
            }
            Set-ScoopProcessPolicyApps -Policy $Policy -Apps @()
            success "Cleared the $($metadata.Label) app list."
            if ($Policy -eq 'Close') {
                $restartApps = @(Get-ScoopProcessPolicyApps -Policy Restart)
                if ($restartApps.Count -gt 0) {
                    warn "Apps configured for automatic restart remain eligible for automatic close: $($restartApps -join ', ')."
                }
            }
            return 0
        }
    }

    $resolution = Resolve-ScoopProcessPolicyCommandApps -Arguments $Arguments
    if (!$resolution.Success) {
        error $resolution.Error
        return 1
    }

    $apps = @($resolution.Apps)
    if ($apps.Count -eq 0) {
        error '<app> missing'
        return 1
    }

    $current = @(Get-ScoopProcessPolicyApps -Policy $Policy)
    if ($SubCommand -eq 'add') {
        $updated = @(ConvertTo-ScoopAppAllowlist (@($current) + @($apps)))
        Set-ScoopProcessPolicyApps -Policy $Policy -Apps $updated
        success "Enabled $($metadata.Label) for: $($apps -join ', ')."
        if ($Policy -eq 'Restart') {
            info 'Automatic restart also permits automatic close for these apps.'
        }
        return 0
    }

    $updated = @($current | Where-Object { $_ -notin $apps })
    Set-ScoopProcessPolicyApps -Policy $Policy -Apps $updated
    success "Disabled the $($metadata.Label) policy for: $($apps -join ', ')."

    if ($Policy -eq 'Close') {
        $restartApps = @(Get-ScoopProcessPolicyApps -Policy Restart)
        $stillEffective = @($apps | Where-Object { $_ -in $restartApps })
        if ($stillEffective.Count -gt 0) {
            warn "These apps remain eligible for automatic close because automatic restart is enabled: $($stillEffective -join ', ')."
        }
    }

    return 0
}
