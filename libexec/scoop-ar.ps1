# Usage: scoop ar [add|remove|rm|list|clear] [<app>...]
# Summary: Alias for 'scoop autorestart'
# Help: `scoop ar` is the short form of `scoop autorestart`.

& "$PSScriptRoot\scoop-autorestart.ps1" @args
exit $LASTEXITCODE
