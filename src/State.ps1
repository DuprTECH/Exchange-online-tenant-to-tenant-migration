# Crash-safe per-mailbox-pair state on disk.
#   folders.json   folder mapping + per-folder completion (written atomically)
#   done.log       append-only list of migrated source item IDs (one per line)
#   failed.log     append-only TSV of items that failed after retries
#   progress.json  live progress snapshot for the dashboard
#   run.log        human-readable log

function Get-PairKey {
    param($Pair)
    $s = $Pair.SourceMailbox + $(if ($Pair.SourceArchive) { '-archive' })
    $t = $Pair.TargetMailbox + $(if ($Pair.TargetArchive) { '-archive' })
    ("${s}__${t}" -replace '[^\w\.\-@]', '_')
}

function Get-JobDir {
    param($Config)
    $dir = Join-Path $Config.WorkDir (Join-Path 'jobs' $Config.JobName)
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $dir
}

function Get-PairDir {
    param($Config, $Pair)
    $dir = Join-Path (Get-JobDir $Config) (Get-PairKey $Pair)
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $dir
}

function Write-JsonAtomic {
    param([string]$Path, $Object)
    $tmp = "$Path.tmp"
    $Object | ConvertTo-Json -Depth 20 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $Path -Force
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { Get-Content -Path $Path -Raw | ConvertFrom-Json -Depth 20 } catch { $null }
}

function Read-DoneSet {
    param([string]$PairDir)
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $path = Join-Path $PairDir 'done.log'
    if (Test-Path $path) {
        foreach ($line in [IO.File]::ReadLines($path)) { if ($line) { $null = $set.Add($line) } }
    }
    , $set
}

function Add-DoneItem {
    param([string]$PairDir, [string]$ItemId)
    # Retry briefly: antivirus/OneDrive can hold the file for a moment.
    for ($i = 1; ; $i++) {
        try { [IO.File]::AppendAllText((Join-Path $PairDir 'done.log'), "$ItemId`n"); return }
        catch [System.IO.IOException] { if ($i -ge 20) { throw }; Start-Sleep -Milliseconds 250 }
    }
}

# Exclusive lock held for the lifetime of a run; the OS releases it if the process dies.
# Returns the open FileStream, or $null when another process/thread already holds it.
function Lock-StateFile {
    param([Parameter(Mandatory)][string]$Path)
    try {
        [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch [System.IO.IOException] { $null }
}

function Add-FailedItem {
    param([string]$PairDir, [string]$FolderPath, [string]$ItemId, [string]$ErrorText)
    $line = "{0}`t{1}`t{2}`t{3}`n" -f (Get-Date -Format o), $FolderPath, $ItemId, ($ErrorText -replace '[\r\n\t]', ' ')
    [IO.File]::AppendAllText((Join-Path $PairDir 'failed.log'), $line)
}

function Write-PairLog {
    param([string]$PairDir, [string]$Message, [string]$Level = 'INFO')
    [IO.File]::AppendAllText((Join-Path $PairDir 'run.log'), ("{0} [{1}] {2}`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message))
}

function Test-StopRequested {
    param($Config)
    Test-Path (Join-Path (Get-JobDir $Config) 'STOP')
}

function Get-PairProgress {
    param($Config, $Pair)
    Read-JsonFile (Join-Path (Get-PairDir $Config $Pair) 'progress.json')
}
