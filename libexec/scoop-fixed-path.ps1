# Usage: scoop fixed-path <subcommand> [options] [<app>]
# Summary: Manage fixed application paths
# Help: Available subcommands: add, remove, rm, rebuild, list.
#
# Fixed paths are opt-in hardlink clones whose directory does not change when an
# app version changes. Scoop shims, Start Menu shortcuts, and manifest PATH/env
# entries are redirected to the fixed path.
#
# Examples:
#     scoop fixed-path add qbittorrent
#     scoop fixed-path add --global some-app
#     scoop fixed-path rebuild qbittorrent
#     scoop fixed-path remove qbittorrent
#     scoop fixed-path list
#
# The shorter command alias `scoop fp` accepts the same arguments.
#
# Options:
#   -g, --global  Manage a globally installed app

param($SubCommand)

. "$PSScriptRoot\..\lib\getopt.ps1"
. "$PSScriptRoot\..\lib\json.ps1"
. "$PSScriptRoot\..\lib\manifest.ps1"
. "$PSScriptRoot\..\lib\system.ps1"
. "$PSScriptRoot\..\lib\install.ps1"
. "$PSScriptRoot\..\lib\shortcuts.ps1"
. "$PSScriptRoot\..\lib\versions.ps1"
. "$PSScriptRoot\..\lib\fixed-path.ps1"

$subCommands = @('add', 'remove', 'rm', 'rebuild', 'list')
if ($SubCommand -notin $subCommands) {
    if (!$SubCommand) {
        error '<subcommand> missing'
    } else {
        error "'$SubCommand' is not one of available subcommands: $($subCommands -join ', ')"
    }
    my_usage
    exit 1
}

$opt, $apps, $err = getopt $Args 'g' 'global'
if ($err) {
    error "scoop fixed-path: $err"
    exit 1
}

$global = $opt.g -or $opt.global

if ($SubCommand -eq 'list') {
    if ($apps) {
        error "Subcommand 'list' does not accept an app name."
        exit 1
    }
    $entries = @(Get-ScoopFixedPathEntries)
    if ($entries.Count -eq 0) {
        info 'No fixed application paths are configured.'
    } else {
        $entries | Format-Table App, Scope, Status, Path -AutoSize
    }
    exit 0
}

if (!$apps) {
    error '<app> missing'
    exit 1
}
if (@($apps).Count -ne 1) {
    error 'Specify exactly one app.'
    exit 1
}

$app, $null, $null = parse_app $apps[0]
if ([String]::IsNullOrWhiteSpace($app) -or $app -eq 'scoop') {
    error "'$app' cannot use a fixed application path."
    exit 1
}

if ($global -and !(is_admin)) {
    error 'You need admin rights to manage a global fixed application path.'
    exit 1
}

$installation = @(Confirm-InstallationStatus -Apps @($app) -Global:$global)
if ($installation.Count -eq 0) {
    exit 1
}
($app, $global) = $installation[0]

$version = Select-CurrentVersion -AppName $app -Global:$global
$manifest = installed_manifest $app $version $global
$install = install_info $app $version $global
$architecture = Format-ArchitectureString $install.architecture

switch ($SubCommand) {
    'add' {
        $alreadyEnabled = Test-ScoopFixedPathEnabled -App $app -Global $global
        if ($alreadyEnabled -and !(Assert-ScoopFixedPathNotRunning -App $app -Global $global)) {
            exit 1
        }

        Set-ScoopFixedPathEnabled -App $app -Global $global -Enabled $true
        try {
            Sync-ScoopFixedPath -App $app -Global $global -Manifest $manifest -Architecture $architecture -UpdateLaunchers | Out-Null
        } catch {
            if (!$alreadyEnabled) {
                Set-ScoopFixedPathEnabled -App $app -Global $global -Enabled $false
            }
            error $_.Exception.Message
            exit 1
        }
        success "Fixed path enabled for '$app'."
    }
    'rebuild' {
        if (!(Test-ScoopFixedPathEnabled -App $app -Global $global)) {
            error "'$app' does not have a fixed path configured. Run 'scoop fp add $app' first."
            exit 1
        }
        if (!(Assert-ScoopFixedPathNotRunning -App $app -Global $global)) {
            exit 1
        }
        try {
            Sync-ScoopFixedPath -App $app -Global $global -Manifest $manifest -Architecture $architecture -UpdateLaunchers | Out-Null
        } catch {
            error $_.Exception.Message
            exit 1
        }
        success "Fixed path rebuilt for '$app'."
    }
    { $_ -in @('remove', 'rm') } {
        if (!(Test-ScoopFixedPathEnabled -App $app -Global $global)) {
            warn "'$app' does not have a fixed path configured."
            exit 0
        }
        if (!(Assert-ScoopFixedPathNotRunning -App $app -Global $global)) {
            exit 1
        }
        try {
            Restore-ScoopCurrentPathLaunchers -App $app -Global $global -Manifest $manifest -Architecture $architecture
            Remove-ScoopFixedPath -App $app -Global $global
            Set-ScoopFixedPathEnabled -App $app -Global $global -Enabled $false
        } catch {
            error "Failed to remove fixed path for '$app': $($_.Exception.Message)"
            exit 1
        }
        success "Fixed path disabled for '$app'."
    }
}

exit 0
