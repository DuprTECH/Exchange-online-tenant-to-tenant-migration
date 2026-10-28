# Configuration, parallel orchestration with live progress, status and reporting.

function New-MigrationConfig {
    [pscustomobject]@{
        JobName            = 'Migration-' + (Get-Date -Format 'yyyyMMdd')
        WorkDir            = './work'
        MappingCsv         = './mapping.csv'
        GraphApiVersion    = 'beta'
        SameTenant         = $false
        Parallelism        = 4
        MaxItemSizeMB      = 150
        IncludeFolderTypes = @('IPF.Note', 'IPF.Appointment', 'IPF.Contact', 'IPF.Task', 'IPF.StickyNote', 'IPF.Journal')
        ExcludeFolderNames = @('Sync Issues', 'Conflicts', 'Local Failures', 'Server Failures',
                               'Problémy so synchronizáciou', 'Konflikty', 'Lokálne zlyhania', 'Zlyhania servera',
                               'Conversation Action Settings', 'Quick Step Settings', 'RSS Feeds', 'RSS Subscriptions',
                               'Yammer Root', 'ExternalContacts', 'PersonMetadata', 'Files', 'Social Activity Notifications')
        Source             = [pscustomobject]@{ TenantId = ''; TenantName = ''; ClientId = ''; CertificateThumbprint = ''; ClientSecretEncrypted = $null }
        Target             = [pscustomobject]@{ TenantId = ''; TenantName = ''; ClientId = ''; CertificateThumbprint = ''; ClientSecretEncrypted = $null }
    }
}

# Loads config and resolves relative paths against the config file location.
function Get-MigrationConfig {
    param([Parameter(Mandatory)][string]$Path)
    $cfg = Get-Content -Path $Path -Raw | ConvertFrom-Json -Depth 10
    $base = Split-Path -Parent (Resolve-Path $Path)
    foreach ($p in 'WorkDir', 'MappingCsv') {
        if ($cfg.$p -and -not [IO.Path]::IsPathRooted($cfg.$p)) {
            $cfg.$p = [IO.Path]::GetFullPath((Join-Path $base $cfg.$p))
        }
    }
    $cfg
}

function Save-MigrationConfig {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Path)
    $Config | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8
}

function ConvertTo-Bool {
    param($Value)
    "$Value".Trim().ToLowerInvariant() -in 'true', '1', 'yes', 'y', 'ano', 'áno', 'a'
}

function Get-MigrationPairs {
    param([Parameter(Mandatory)]$Config)
    if (-not (Test-Path $Config.MappingCsv)) { throw "Mapping CSV not found: $($Config.MappingCsv)" }
    $rows = Import-Csv -Path $Config.MappingCsv
    foreach ($r in $rows) {
        if (-not $r.SourceMailbox -or -not $r.TargetMailbox) { continue }
        [pscustomobject]@{
            SourceMailbox    = $r.SourceMailbox.Trim()
            TargetMailbox    = $r.TargetMailbox.Trim()
            SourceArchive    = ConvertTo-Bool $r.SourceArchive
            TargetArchive    = ConvertTo-Bool $r.TargetArchive
            TargetRootFolder = "$($r.TargetRootFolder)".Trim()
        }
    }
}

function Get-MigrationStatus {
    param([Parameter(Mandatory)]$Config)
    foreach ($p in Get-MigrationPairs $Config) {
        $dir = Get-PairDir $Config $p
        $pr = Read-JsonFile (Join-Path $dir 'progress.json')
        $failedLog = Join-Path $dir 'failed.log'
        $failed = if (Test-Path $failedLog) { @([IO.File]::ReadLines($failedLog)).Count } else { 0 }
        $total = [long]($pr.ItemsTotal ?? 0); $done = [long]($pr.ItemsDone ?? 0)
        [pscustomobject]@{
            Source      = $p.SourceMailbox + $(if ($p.SourceArchive) { ' (archive)' })
            Target      = $p.TargetMailbox + $(if ($p.TargetArchive) { ' (archive)' })
            Status      = $pr.Status ?? 'NotStarted'
            Percent     = if ($total -gt 0) { [math]::Min(100, [math]::Round(100 * $done / $total, 1)) } else { 0 }
            ItemsDone   = $done
            ItemsTotal  = $total
            Folders     = "$($pr.FoldersDone ?? 0)/$($pr.FoldersTotal ?? 0)"
            FailedTotal = $failed
            Updated     = $pr.UpdatedAt
            Message     = $pr.Message
            StateDir    = $dir
        }
    }
}

function Export-MigrationReport {
    param([Parameter(Mandatory)]$Config)
    $path = Join-Path (Get-JobDir $Config) ("report-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Get-MigrationStatus $Config | Export-Csv -Path $path -NoTypeInformation -Encoding utf8
    $path
}

function Reset-PairState {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Pair)
    $dir = Get-PairDir $Config $Pair
    $archive = "$dir.reset-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -Path $dir -Destination $archive
    $archive
}

function Start-Migration {
    param(
        [Parameter(Mandatory)]$Config,
        [switch]$Rescan,
        [switch]$IncludeCompleted
    )
    $modulePath = Join-Path $PSScriptRoot 'MailboxMigrator.psm1'
    $jobDir = Get-JobDir $Config
    # One orchestrator per job; must be taken before clearing STOP so a second window can't cancel a stop request.
    $runLock = Lock-StateFile (Join-Path $jobDir 'run.lock')
    if (-not $runLock) {
        Write-Host "Job '$($Config.JobName)' is already running in another window or in the background. Stop it there (Q) or close that window." -ForegroundColor Red
        return
    }
    try {
        Remove-Item (Join-Path $jobDir 'STOP') -ErrorAction SilentlyContinue
        Invoke-MigrationRun -Config $Config -JobDir $jobDir -ModulePath $modulePath -Rescan:$Rescan -IncludeCompleted:$IncludeCompleted
    }
    finally { $runLock.Dispose() }
}

# Live status is drawn as plain text at a fixed place in the console instead of Write-Progress:
# on some PowerShell 7.6 consoles every Write-Progress refresh beeps. Plain text without escape sequences cannot.
function Format-Bar {
    param([double]$Percent, [int]$Width = 20)
    $n = [int][math]::Round([math]::Max(0, [math]::Min(100, $Percent)) * $Width / 100)
    '[' + ('#' * $n) + ('-' * ($Width - $n)) + ']'
}

function Show-RunStatus {
    param([Parameter(Mandatory)][hashtable]$View, [string[]]$Lines)
    $w = [math]::Max(20, [Console]::BufferWidth - 1)
    if ($View.Top -ge 0) { [Console]::SetCursorPosition(0, $View.Top) }
    $count = [math]::Max($Lines.Count, $View.Lines)
    $sb = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $count; $i++) {
        $t = if ($i -lt $Lines.Count) { $Lines[$i] -replace '[\x00-\x1F\x7F]', ' ' } else { '' }
        if ($t.Length -gt $w) { $t = $t.Substring(0, $w) }
        [void]$sb.Append($t.PadRight($w)).Append("`n")
    }
    [Console]::Write($sb.ToString())
    $View.Top = [Console]::CursorTop - $count
    $View.Lines = $count
}

function Clear-RunStatus {
    param([Parameter(Mandatory)][hashtable]$View)
    if ($View.Top -lt 0) { return }
    $w = [math]::Max(20, [Console]::BufferWidth - 1)
    [Console]::SetCursorPosition(0, $View.Top)
    [Console]::Write(((' ' * $w) + "`n") * $View.Lines)
    [Console]::SetCursorPosition(0, $View.Top)
    $View.Top = -1
    $View.Lines = 0
}

function Invoke-MigrationRun {
    param($Config, [string]$JobDir, [string]$ModulePath, [switch]$Rescan, [switch]$IncludeCompleted)
    $jobDir = $JobDir
    $modulePath = $ModulePath

    $pairs = @(Get-MigrationPairs $Config)
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($p in $pairs) {
        $pr = Get-PairProgress $Config $p
        if (-not $Rescan -and -not $IncludeCompleted -and $pr.Status -eq 'Completed') { continue }
        $queue.Enqueue($p)
    }
    if ($queue.Count -eq 0) { Write-Host 'Nothing to do - all mailboxes are completed. Use the delta pass (rescan) to sync new items.' -ForegroundColor Yellow; return }

    $parallel = [math]::Max(1, [int]$Config.Parallelism)
    $running = @{}         # pair key -> @{ Job; Pair; Id }
    $started = Get-Date
    $initialDone = ($pairs | ForEach-Object { [long]((Get-PairProgress $Config $_).ItemsDone ?? 0) } | Measure-Object -Sum).Sum
    $stopNotified = $false

    $view = @{ Top = -1; Lines = 0 }
    $interactive = -not [Console]::IsOutputRedirected
    $lastPlainStatus = [datetime]::MinValue
    $cursorWasVisible = $null
    if ($interactive -and $IsWindows) { try { $cursorWasVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { } }

    Write-Host "Migrating $($queue.Count) mailbox pair(s), $parallel in parallel. Press Q to stop gracefully (state is kept, run again to resume)." -ForegroundColor Cyan
    Write-JobLog $jobDir "Run started: $($queue.Count) pair(s), parallel $parallel, rescan $([bool]$Rescan)"

    $finished = $false
    try {
        while ($queue.Count -gt 0 -or $running.Count -gt 0) {
            # Start new workers
            while (-not (Test-StopRequested $Config) -and $running.Count -lt $parallel -and $queue.Count -gt 0) {
                $p = $queue.Dequeue()
                $key = Get-PairKey $p
                $job = Start-ThreadJob -Name $key -ThrottleLimit $parallel -ArgumentList $modulePath, $Config, $p, ([bool]$Rescan) -ScriptBlock {
                    param($m, $c, $pair, $r)
                    Import-Module $m -Force
                    Invoke-PairMigration -Config $c -Pair $pair -Rescan:$r
                }
                $running[$key] = @{ Job = $job; Pair = $p }
            }
            if ((Test-StopRequested $Config) -and $queue.Count -gt 0) { $queue.Clear() }

            # Keyboard: Q = graceful stop
            try {
                while ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'Q') { Request-MigrationStop $Config }
                }
            }
            catch { }
            if ((Test-StopRequested $Config) -and -not $stopNotified) {
                $stopNotified = $true
                if ($interactive) { Clear-RunStatus $view }
                Write-Host 'Stop requested - finishing current batches...' -ForegroundColor Yellow
            }

            # Render progress
            $all = foreach ($p in $pairs) { Get-PairProgress $Config $p }
            $sumDone = ($all | ForEach-Object { [long]($_.ItemsDone ?? 0) } | Measure-Object -Sum).Sum
            $sumTotal = ($all | ForEach-Object { [long]($_.ItemsTotal ?? 0) } | Measure-Object -Sum).Sum
            $elapsed = (Get-Date) - $started
            $rate = if ($elapsed.TotalMinutes -gt 0.2) { ($sumDone - $initialDone) / $elapsed.TotalMinutes } else { 0 }
            $pct = if ($sumTotal -gt 0) { [math]::Min(100, 100 * $sumDone / $sumTotal) } else { 0 }
            $eta = if ($rate -gt 0 -and $sumTotal -gt $sumDone) { [TimeSpan]::FromMinutes(($sumTotal - $sumDone) / $rate).ToString('d\.hh\:mm\:ss') } else { '-' }
            $summary = "{0:N0} / {1:N0} items ({2:N1} %) | {3:N0} items/min | ETA {4} | running {5}, queued {6}" -f $sumDone, $sumTotal, $pct, $rate, $eta, $running.Count, $queue.Count
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add("Mailbox migration '$($Config.JobName)'  $(Format-Bar $pct)  Q = stop")
            $lines.Add("  $summary")

            foreach ($key in @($running.Keys)) {
                $r = $running[$key]
                $pr = Get-PairProgress $Config $r.Pair
                $ppct = if ($pr -and $pr.ItemsTotal -gt 0) { [math]::Min(100, 100 * $pr.ItemsDone / $pr.ItemsTotal) } else { 0 }
                $status = if ($pr) {
                    "{0} | {1:N0}/{2:N0} | folders {3}/{4} | {5:N1} MB | failed {6} | {7}" -f $pr.Status, $pr.ItemsDone, $pr.ItemsTotal,
                        $pr.FoldersDone, $pr.FoldersTotal, ($pr.BytesThisRun / 1MB), $pr.ItemsFailedThisRun, $pr.CurrentFolder
                } else { 'Starting' }

                if ($r.Job.State -in 'Completed', 'Failed', 'Stopped') {
                    $out = Receive-Job $r.Job -ErrorAction SilentlyContinue -ErrorVariable jobErr | Select-Object -Last 1
                    foreach ($e in $jobErr) { Write-JobLog $jobDir "[$key] job error: $e" }
                    Remove-Job $r.Job -Force
                    $running.Remove($key)
                    if ($interactive) { Clear-RunStatus $view }
                    $final = $out.Status ?? $pr.Status
                    $color = switch ($final) { 'Completed' { 'Green' } 'CompletedWithErrors' { 'Yellow' } 'Stopped' { 'Yellow' } default { 'Red' } }
                    Write-Host ("[{0}] {1} -> {2}: {3} {4}" -f (Get-Date -Format 'HH:mm:ss'), $r.Pair.SourceMailbox, $r.Pair.TargetMailbox, $final, ($out.Message -replace '[\x00-\x1F\x7F]', ' ')) -ForegroundColor $color
                    Write-JobLog $jobDir "$key finished: $final $($out.Message)"
                    continue
                }
                $lines.Add("  $($r.Pair.SourceMailbox) -> $($r.Pair.TargetMailbox)  $(Format-Bar $ppct) {0,5:N1} %" -f $ppct)
                $lines.Add("    $status")
            }
            if ($interactive) {
                Show-RunStatus $view $lines
            }
            elseif (((Get-Date) - $lastPlainStatus).TotalSeconds -ge 60) {
                # Redirected output (Task Scheduler, logs): one summary line per minute.
                Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $summary)
                $lastPlainStatus = Get-Date
            }
            Start-Sleep -Milliseconds 1000
        }
        $finished = $true
    }
    finally {
        # Ctrl+C or an error: workers are thread jobs that would keep running in the background - stop them cleanly.
        if ($interactive) { Clear-RunStatus $view }
        if (-not $finished -and $running.Count -gt 0) {
            Write-Host 'Interrupted - stopping running migrations (they finish the current batch)...' -ForegroundColor Yellow
            Request-MigrationStop $Config
            $jobs = @($running.Values | ForEach-Object { $_.Job })
            $null = Wait-Job -Job $jobs -Timeout 180
            $jobs | Stop-Job -ErrorAction SilentlyContinue
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
            Write-JobLog $jobDir 'Run interrupted - workers stopped'
        }
        if ($null -ne $cursorWasVisible) { try { [Console]::CursorVisible = $cursorWasVisible } catch { } }
    }
    Write-JobLog $jobDir 'Run finished'
    Get-MigrationStatus $Config | Format-Table Source, Target, Status, Percent, ItemsDone, ItemsTotal, Folders, FailedTotal -AutoSize
}

function Request-MigrationStop {
    param([Parameter(Mandatory)]$Config)
    Set-Content -Path (Join-Path (Get-JobDir $Config) 'STOP') -Value (Get-Date -Format o)
}

function Write-JobLog {
    param([string]$JobDir, [string]$Message)
    [IO.File]::AppendAllText((Join-Path $JobDir 'job.log'), ("{0} {1}`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message))
}

# Pre-flight: resolves every mailbox and sums item counts / folders without migrating anything.
function Test-MigrationReadiness {
    param([Parameter(Mandatory)]$Config)
    $src = New-TenantContext -TenantConfig $Config.Source -GraphApiVersion $Config.GraphApiVersion -Name 'source'
    $tgt = if ($Config.SameTenant) { $src } else { New-TenantContext -TenantConfig $Config.Target -GraphApiVersion $Config.GraphApiVersion -Name 'target' }

    Write-Host "`nPermissions - source tenant:" -ForegroundColor Cyan
    Test-MigrationApp -Context $src -Role $(if ($Config.SameTenant) { 'Both' } else { 'Source' }) | Format-Table -AutoSize | Out-Host
    if (-not $Config.SameTenant) {
        Write-Host 'Permissions - target tenant:' -ForegroundColor Cyan
        Test-MigrationApp -Context $tgt -Role Target | Format-Table -AutoSize | Out-Host
    }

    $pairs = @(Get-MigrationPairs $Config)
    $i = 0
    $rows = foreach ($p in $pairs) {
        $i++
        Write-Host "Checking $i/$($pairs.Count): $($p.SourceMailbox) -> $($p.TargetMailbox)" -ForegroundColor DarkGray
        $row = [ordered]@{ Source = $p.SourceMailbox; Target = $p.TargetMailbox; SourceOK = $false; TargetOK = $false; Folders = 0; Items = 0; Error = '' }
        try {
            $sm = Get-MailboxId -Context $src -User $p.SourceMailbox -Archive:$p.SourceArchive
            $row.SourceOK = $true
            $tm = Get-MailboxId -Context $tgt -User $p.TargetMailbox -Archive:$p.TargetArchive
            $row.TargetOK = $true

            $plan = Resolve-FolderMapping -Config $Config -Pair $p -Src $src -Tgt $tgt -SrcMbx $sm -TgtMbx $tm -Preview
            $inc = @($plan | Where-Object { $_.Action -notlike 'Skip*' })
            $row.Folders = $inc.Count
            $row.Items = [long]($inc | Measure-Object Items -Sum).Sum
            Write-Host "`nFolder plan: $($p.SourceMailbox) -> $($p.TargetMailbox)" -ForegroundColor Cyan
            $plan | Format-Table SourcePath, Type, Items, Action, TargetPath -AutoSize | Out-Host
        }
        catch { $row.Error = $_.Exception.Message }
        [pscustomobject]$row
    }
    $rows
}
