<#
.SYNOPSIS
    Exchange Online mailbox migration wizard (tenant-to-tenant or mailbox-to-mailbox in the same tenant).

.EXAMPLE
    ./MailboxMigrator.ps1                                  # interactive wizard
    ./MailboxMigrator.ps1 -ConfigPath ./contoso.json -Run  # start/resume without menu
    ./MailboxMigrator.ps1 -Run -Rescan                     # delta pass: new items + retry failed
    ./MailboxMigrator.ps1 -Status
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'migration.config.json'),
    [switch]$Run,
    [switch]$Rescan,
    [switch]$Status
)

# Started from Windows PowerShell 5.1: relaunch the same command under PowerShell 7.
# Keep this file free of PS7-only syntax so 5.1 can parse it and reach this point.
if ($PSVersionTable.PSVersion -lt [version]'7.2') {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        Write-Host 'This tool requires PowerShell 7.2+. Install it with: winget install Microsoft.PowerShell' -ForegroundColor Red
        return
    }
    $argList = @('-NoProfile', '-File', $PSCommandPath, '-ConfigPath', $ConfigPath)
    if ($Run) { $argList += '-Run' }
    if ($Rescan) { $argList += '-Rescan' }
    if ($Status) { $argList += '-Status' }
    & $pwsh.Source @argList
    return
}

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/MailboxMigrator.psm1') -Force

function Read-Value {
    param([string]$Prompt, $Default)
    $suffix = if ("$Default" -ne '') { " [$Default]" } else { '' }
    $v = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($v)) { $Default } else { $v.Trim() }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $d = if ($Default) { 'Y/n' } else { 'y/N' }
    $v = Read-Host "$Prompt ($d)"
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    $v.Trim().ToLowerInvariant() -in 'y', 'yes'
}

function Get-Config {
    if (Test-Path $ConfigPath) { return Get-MigrationConfig -Path $ConfigPath }
    $null
}

function Save-Config {
    param($Config)
    Save-MigrationConfig -Config $Config -Path $ConfigPath
    Write-Host "Configuration saved: $ConfigPath" -ForegroundColor Green
}

function Edit-Configuration {
    $cfg = if (Test-Path $ConfigPath) { Get-Content $ConfigPath -Raw | ConvertFrom-Json -Depth 10 } else { New-MigrationConfig }
    Write-Host "`n--- Migration configuration (Enter = default value in brackets) ---" -ForegroundColor Cyan
    $cfg.SameTenant = Read-YesNo 'Migrate within the SAME tenant (mailbox -> another mailbox)? No = tenant -> tenant' ([bool]$cfg.SameTenant)
    Write-Host '  The job name selects the folder holding the migration state (work/jobs/<name>). Same name = resume,' -ForegroundColor DarkGray
    Write-Host '  new name = start from scratch. Do not change it in the middle of a migration.' -ForegroundColor DarkGray
    $cfg.JobName = Read-Value 'Migration job name' $cfg.JobName
    $cfg.MappingCsv = Read-Value 'Path to the mapping CSV' $cfg.MappingCsv
    $cfg.WorkDir = Read-Value 'Working directory (state, logs)' $cfg.WorkDir
    $cfg.Parallelism = [int](Read-Value 'Number of mailboxes migrated in parallel' $cfg.Parallelism)
    $cfg.MaxItemSizeMB = [int](Read-Value 'Max item size in MB (larger items are skipped and logged)' $cfg.MaxItemSizeMB)

    $base = Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))
    $csv = if ([IO.Path]::IsPathRooted($cfg.MappingCsv)) { $cfg.MappingCsv } else { Join-Path $base $cfg.MappingCsv }
    if (-not (Test-Path $csv) -and (Read-YesNo "CSV '$csv' does not exist. Create a sample?")) {
        Copy-Item (Join-Path $PSScriptRoot 'mapping.sample.csv') $csv
        Write-Host "Created: $csv - fill in your mailboxes, then run the pre-flight check (option 4)." -ForegroundColor Green
    }
    Save-Config $cfg
}

function Set-TenantApp {
    param([ValidateSet('Source', 'Target')][string]$Side)
    if (-not (Test-Path $ConfigPath)) {
        Write-Host 'No configuration yet - let us create it first.' -ForegroundColor Yellow
        Edit-Configuration
    }
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json -Depth 10
    $role = if ($cfg.SameTenant) { 'Both' } elseif ($Side -eq 'Source') { 'Source' } else { 'Target' }
    $label = if ($Side -eq 'Source') { 'SOURCE' } else { 'TARGET' }

    Write-Host "`n--- $label tenant: app registration and Graph permissions ($role) ---" -ForegroundColor Cyan
    Write-Host ('Permissions: ' + ((Get-RequiredPermissions -Role $role) -join ', '))
    Write-Host '1) Create the app registration automatically (Global/Application admin sign-in via device code)'
    Write-Host '2) Enter an existing app manually'
    $choice = Read-Value 'Choice' '1'

    if ($choice -eq '1') {
        $tenant = Read-Value 'Tenant (domain or ID), e.g. contoso.onmicrosoft.com' $cfg.$Side.TenantId
        $info = Install-MigrationApp -TenantId $tenant -Role $role
    }
    else {
        $info = [pscustomobject]@{
            TenantId              = Read-Value 'Tenant ID' $cfg.$Side.TenantId
            TenantName            = ''
            ClientId              = Read-Value 'Application (client) ID' $cfg.$Side.ClientId
            CertificateThumbprint = Read-Value 'Certificate thumbprint (empty = use a client secret)' $cfg.$Side.CertificateThumbprint
            ClientSecretEncrypted = $null
        }
        if (-not $info.CertificateThumbprint) {
            $sec = Read-Host 'Client secret' -AsSecureString
            $info.ClientSecretEncrypted = ConvertFrom-SecureString $sec   # DPAPI - only this user on this machine can decrypt
        }
    }
    $cfg.$Side = $info
    if ($cfg.SameTenant) { $cfg.Target = $info }
    Save-Config $cfg
}

# Returns $true when the config has everything needed to talk to the tenants; otherwise says which step is missing.
function Test-ConfigReady {
    param($Config)
    if (-not $Config) { Write-Host 'No configuration - run option 1 first.' -ForegroundColor Yellow; return $false }
    if (-not $Config.Source.ClientId) { Write-Host 'Source tenant is not set up - run option 2 first.' -ForegroundColor Yellow; return $false }
    if (-not $Config.SameTenant -and -not $Config.Target.ClientId) { Write-Host 'Target tenant is not set up - run option 3 first.' -ForegroundColor Yellow; return $false }
    if (-not (Test-Path $Config.MappingCsv)) { Write-Host "Mapping CSV not found: $($Config.MappingCsv) - create it in option 1." -ForegroundColor Yellow; return $false }
    $true
}

function Show-Status {
    $cfg = Get-Config
    if (-not $cfg) { Write-Warning 'No configuration found.'; return }
    Get-MigrationStatus $cfg | Format-Table Source, Target, Status, Percent, ItemsDone, ItemsTotal, Folders, FailedTotal, Updated -AutoSize | Out-Host
    $failed = Get-MigrationStatus $cfg | Where-Object { $_.Message }
    foreach ($f in $failed) { Write-Host "$($f.Source): $($f.Message)" -ForegroundColor Red }
}

function Reset-Pair {
    $cfg = Get-Config
    $pairs = @(Get-MigrationPairs $cfg)
    for ($i = 0; $i -lt $pairs.Count; $i++) { Write-Host ("{0}) {1} -> {2}" -f ($i + 1), $pairs[$i].SourceMailbox, $pairs[$i].TargetMailbox) }
    $n = [int](Read-Value 'Number of the pair to reset (0 = cancel)' 0)
    if ($n -lt 1 -or $n -gt $pairs.Count) { return }
    Write-Warning 'Reset forgets what has already been migrated. The next run copies all items again (duplicates in the target)!'
    if (Read-YesNo 'Really reset?' $false) {
        $moved = Reset-PairState -Config $cfg -Pair $pairs[$n - 1]
        Write-Host "State moved to $moved" -ForegroundColor Yellow
    }
}

# --- Non-interactive modes ---
if ($Status) { Show-Status; return }
if ($Run) {
    $cfg = Get-Config
    if (-not (Test-ConfigReady $cfg)) { exit 1 }
    Start-Migration -Config $cfg -Rescan:$Rescan
    return
}

# --- Wizard ---
while ($true) {
    $cfg = Get-Config
    Write-Host "`n==================== Mailbox Migrator ====================" -ForegroundColor Cyan
    if ($cfg) {
        $mode = if ($cfg.SameTenant) { 'within tenant' } else { 'tenant -> tenant' }
        $srcName = if ($cfg.Source.TenantName) { $cfg.Source.TenantName } else { $cfg.Source.TenantId }
        $tgtName = if ($cfg.Target.TenantName) { $cfg.Target.TenantName } else { $cfg.Target.TenantId }
        Write-Host "Job: $($cfg.JobName) | mode: $mode | source: $srcName | target: $tgtName" -ForegroundColor DarkGray
    }
    else { Write-Host "No configuration yet ($ConfigPath)" -ForegroundColor DarkGray }
    Write-Host ' 1) Configuration (job, mode, mapping CSV)'
    Write-Host ' 2) Source tenant - app registration and Graph permissions'
    Write-Host ' 3) Target tenant - app registration and Graph permissions'
    Write-Host ' 4) Pre-flight check (permissions, mailboxes, folder plan)'
    Write-Host ' 5) Start / resume migration'
    Write-Host ' 6) Delta pass (new items + retry failed)'
    Write-Host ' 7) Status and report'
    Write-Host ' 8) Reset state of one mailbox pair'
    Write-Host ' 0) Exit'
    $c = Read-Host 'Choice'
    try {
        switch ($c) {
            '1' { Edit-Configuration }
            '2' { Set-TenantApp -Side Source }
            '3' {
                if ($cfg.SameTenant) { Write-Host 'Within-tenant mode - the target uses the same app as the source.' -ForegroundColor Yellow }
                else { Set-TenantApp -Side Target }
            }
            '4' { if (Test-ConfigReady $cfg) { Test-MigrationReadiness -Config $cfg | Format-Table -AutoSize | Out-Host } }
            '5' { if (Test-ConfigReady $cfg) { Start-Migration -Config $cfg } }
            '6' { if (Test-ConfigReady $cfg) { Start-Migration -Config $cfg -Rescan } }
            '7' {
                Show-Status
                if (Read-YesNo 'Export a CSV report?' $false) { Write-Host "Report: $(Export-MigrationReport $cfg)" -ForegroundColor Green }
            }
            '8' { Reset-Pair }
            '0' { return }
        }
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}
