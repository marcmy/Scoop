# Usage: scoop autoclose [add|remove|rm|list|clear] [<app>...]
# Summary: Manage apps allowed to close automatically during updates
# Help: With no arguments, lists configured apps. Adding apps requires the explicit `add` subcommand.
#
# Examples:
#     scoop autoclose
#     scoop autoclose add sharex-dev jackett
#     scoop autoclose rm jackett
#     scoop autoclose clear
#
# The shorter command alias `scoop ac` accepts the same arguments.

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

$exitCode = Invoke-ScoopProcessPolicyCommand -Policy Close -SubCommand $SubCommand -Arguments $Args
exit $exitCode
