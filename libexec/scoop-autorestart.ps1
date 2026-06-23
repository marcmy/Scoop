# Usage: scoop autorestart [add|remove|rm|list|clear] [<app>...]
# Summary: Manage apps allowed to restart automatically after updates
# Help: With no arguments, lists configured apps. Adding apps requires the explicit `add` subcommand.
#
# Restart permission also permits automatic close for the same app.
#
# Examples:
#     scoop autorestart
#     scoop autorestart add sharex-dev jackett
#     scoop autorestart rm jackett
#     scoop autorestart clear
#
# The shorter command alias `scoop ar` accepts the same arguments.

param($SubCommand)

. "$PSScriptRoot\..\lib\json.ps1"
. "$PSScriptRoot\..\lib\update-processes.ps1"
. "$PSScriptRoot\..\lib\update-process-policies.ps1"
. "$PSScriptRoot\..\lib\update-process-policy-command.ps1"

$subCommands = @('add', 'remove', 'rm', 'list', 'clear')
if ($SubCommand -and $SubCommand -notin $subCommands) {
    error "'$SubCommand' is not one of available subcommands: $($subCommands -join ', ')"
    my_usage
    exit 1
}

$exitCode = Invoke-ScoopProcessPolicyCommand -Policy Restart -SubCommand $SubCommand -Arguments $Args
exit $exitCode
