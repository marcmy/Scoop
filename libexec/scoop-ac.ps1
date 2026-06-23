# Usage: scoop ac [add|remove|rm|list|clear] [<app>...]
# Summary: Alias for 'scoop autoclose'
# Help: `scoop ac` is the short form of `scoop autoclose`.

& "$PSScriptRoot\scoop-autoclose.ps1" @args
exit $LASTEXITCODE
