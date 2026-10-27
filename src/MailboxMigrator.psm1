#Requires -Version 7.2

foreach ($file in 'Auth', 'Graph', 'State', 'Setup', 'Engine', 'Orchestrator') {
    . (Join-Path $PSScriptRoot "$file.ps1")
}

Export-ModuleMember -Function *
