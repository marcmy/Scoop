# Usage: scoop fp <subcommand> [options] [<app>]
# Summary: Alias for 'scoop fixed-path'
# Help: `scoop fp` is the short form of `scoop fixed-path`.
#
# Examples:
#     scoop fp add qbittorrent
#     scoop fp rebuild qbittorrent
#     scoop fp remove qbittorrent
#     scoop fp list

& "$PSScriptRoot\scoop-fixed-path.ps1" @args
exit $LASTEXITCODE
