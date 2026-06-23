# Usage: scoop autorestart [add|remove|rm|list|clear] [<app>...]
# Summary: Manage apps allowed to restart automatically after updates
# Help: With no arguments, lists configured apps. App names without a subcommand are added.
#
# Restart permission also permits automatic close for the same app.
#
# Examples:
#     scoop autorestart
#     scoop autorestart add sharex-dev jackett
#     scoop autorestart sharex-dev
#     scoop autorestart rm jackett
#     scoop autorestart clear
#
# The shorter command alias `scoop ar` accepts the same arguments.

param($SubCommand)

. "$PSScriptRoot\..\lib\json.ps1"
. "$PSScriptRoot\..\lib\update-processes.ps1"
. "$PSScriptRoot\..\lib\update-process-policies.ps1"
. "$PSScriptRoot\..\lib\update-process-policy-command.ps1"

$exitCode = Invoke-ScoopProcessPolicyCommand -Policy Restart -SubCommand $SubCommand -Arguments $Args
exit $exitCode
