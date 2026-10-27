# Migration engine for one source -> target mailbox pair, using the Graph mailbox import/export API
# (full-fidelity FTS export/import: mail, calendar, contacts, tasks, notes).
# Idempotent: folders are matched by wellKnownName/path, migrated item IDs are recorded in done.log, so a rerun resumes.

function Get-MailboxId {
    param([hashtable]$Context, [string]$User, [switch]$Archive)
    $s = Invoke-Graph -Context $Context -Uri "users/$([uri]::EscapeDataString($User))/settings/exchange"
    $id = if ($Archive) { $s.archiveMailboxId } else { $s.primaryMailboxId }
    if (-not $id) { throw "Mailbox ID not found for '$User' (archive: $([bool]$Archive)). Is the mailbox licensed/provisioned$(if ($Archive) { ' and archive enabled' })?" }
    $id
}

function Get-MailboxFolderTree {
    param([hashtable]$Context, [string]$MailboxId)
    $list = [System.Collections.Generic.List[object]]::new()
    $walk = {
        param($Folders, $ParentPath, $Depth)
        foreach ($f in $Folders) {
            $path = if ($ParentPath) { "$ParentPath/$($f.displayName)" } else { $f.displayName }
            $list.Add([pscustomobject]@{
                    Id             = $f.id
                    ParentId       = $f.parentFolderId
                    Name           = $f.displayName
                    Path           = $path
                    Type           = $f.type
                    WellKnownName  = $f.wellKnownName
                    IsHidden       = [bool]$f.isHidden
                    TotalItemCount = [int]$f.totalItemCount
                    Depth          = $Depth
                })
            if ([int]$f.childFolderCount -gt 0) {
                $children = @(Invoke-GraphPaged -Context $Context -Uri "admin/exchange/mailboxes/$MailboxId/folders/$([uri]::EscapeDataString($f.id))/childFolders?`$top=250")
                & $walk $children $path ($Depth + 1)
            }
        }
    }
    $top = @(Invoke-GraphPaged -Context $Context -Uri "admin/exchange/mailboxes/$MailboxId/folders?`$top=250")
    & $walk $top $null 0
    , $list
}

function New-MailboxFolder {
    param([hashtable]$Context, [string]$MailboxId, [string]$ParentId, [string]$Name, [string]$Type)
    $uri = if ($ParentId) { "admin/exchange/mailboxes/$MailboxId/folders/$([uri]::EscapeDataString($ParentId))/childFolders" }
           else { "admin/exchange/mailboxes/$MailboxId/folders" }
    # The API requires a folder class; folders without one are treated as mail folders.
    Invoke-Graph -Context $Context -Method POST -Uri $uri -Body @{ displayName = $Name; type = ($Type ? $Type : 'IPF.Note') }
}

# Default folders that are never migrated (would send mail, or are client sync artefacts).
$script:ExcludedWellKnownFolders = 'outbox', 'syncissues', 'conflicts', 'localfailures', 'serverfailures'

# Decides whether a source folder is migrated; returns the reason when it is skipped.
function Get-FolderSkipReason {
    param($Folder, [string[]]$IncludeTypes, [string[]]$ExcludeNames)
    if ($Folder.WellKnownName -in $script:ExcludedWellKnownFolders) { return "excluded default folder ($($Folder.WellKnownName))" }
    if ($Folder.IsHidden) { return 'hidden folder' }
    if ($ExcludeNames -contains $Folder.Name.ToLowerInvariant()) { return 'excluded by name' }
    # System folders without a class (Infected Items, Detected Items ...) - only default ones like Conversation History are kept.
    if (-not $Folder.Type -and -not $Folder.WellKnownName) { return 'system folder without type' }
    if ($Folder.Type -and $IncludeTypes -notcontains $Folder.Type) { return "type $($Folder.Type) not included" }
    $null
}

# Returns ordered list of { Source folder, TargetId, TargetPath } and creates missing target folders.
# Default folders are paired by wellKnownName (language independent: Doručená pošta <-> Inbox),
# custom folders by path under their mapped parent.
# -Preview creates nothing and returns the plan for every source folder (Action: Default/Existing/Create/Skip).
function Resolve-FolderMapping {
    param(
        $Config, $Pair,
        [hashtable]$Src, [hashtable]$Tgt,
        [string]$SrcMbx, [string]$TgtMbx,
        [string]$PairDir,
        [switch]$Preview
    )
    $log = { param($Message, $Level = 'INFO') if (-not $Preview) { Write-PairLog $PairDir $Message $Level } }
    $plan = [System.Collections.Generic.List[object]]::new()
    $srcTree = Get-MailboxFolderTree -Context $Src -MailboxId $SrcMbx
    $tgtTree = Get-MailboxFolderTree -Context $Tgt -MailboxId $TgtMbx

    $tgtByPath = @{}
    $tgtByWk = @{}
    foreach ($t in $tgtTree) {
        $tgtByPath[$t.Path.ToLowerInvariant()] = $t
        if ($t.WellKnownName) { $tgtByWk[$t.WellKnownName] = $t }
    }

    $includeTypes = @($Config.IncludeFolderTypes)
    $exclude = @($Config.ExcludeFolderNames | ForEach-Object { $_.ToLowerInvariant() })
    $mapped = @{}       # sourceId -> mapping
    $skipped = [System.Collections.Generic.HashSet[string]]::new()
    $result = [System.Collections.Generic.List[object]]::new()

    $rootId = $null; $rootPath = $null
    if ($Pair.TargetRootFolder) {
        $rootPath = $Pair.TargetRootFolder.Trim('/')
        $existing = $tgtByPath[$rootPath.ToLowerInvariant()]
        if ($existing) { $rootId = $existing.Id }
        elseif ($Preview) { $rootId = "new:$rootPath" }
        else {
            $created = New-MailboxFolder -Context $Tgt -MailboxId $TgtMbx -ParentId $null -Name $rootPath -Type 'IPF.Note'
            $rootId = $created.id
            & $log "Created target root folder '$rootPath'"
        }
    }

    foreach ($sf in $srcTree) {
        $reason = if ($sf.ParentId -and $skipped.Contains($sf.ParentId)) { 'parent skipped' }
                  else { Get-FolderSkipReason -Folder $sf -IncludeTypes $includeTypes -ExcludeNames $exclude }
        if ($reason) {
            $null = $skipped.Add($sf.Id)
            $level = if ($sf.TotalItemCount -gt 0) { 'WARN' } else { 'INFO' }
            & $log "Skipped '$($sf.Path)' ($($sf.TotalItemCount) items): $reason" $level
            $plan.Add([pscustomobject]@{ SourcePath = $sf.Path; Type = $sf.Type; Items = $sf.TotalItemCount; Action = "Skip: $reason"; TargetPath = '' })
            continue
        }

        $parentMap = $mapped[$sf.ParentId]
        $tf = $null
        $action = 'Existing'
        $name = $sf.Name
        if ($rootId) {
            $targetParentId = if ($parentMap) { $parentMap.TargetId } else { $rootId }
            $targetPath = if ($parentMap) { "$($parentMap.TargetPath)/$name" } else { "$rootPath/$name" }
        }
        elseif ($sf.WellKnownName -and $tgtByWk[$sf.WellKnownName]) {
            $tf = $tgtByWk[$sf.WellKnownName]
            $targetPath = $tf.Path
            $action = "Default ($($sf.WellKnownName))"
        }
        elseif ($parentMap) {
            $targetParentId = $parentMap.TargetId
            $targetPath = "$($parentMap.TargetPath)/$name"
        }
        else {
            $targetParentId = $null
            $targetPath = $name
        }

        if (-not $tf) { $tf = $tgtByPath[$targetPath.ToLowerInvariant()] }
        if (-not $tf) {
            $action = 'Create'
            $newId = if ($Preview) { "new:$targetPath" }
                     else { (New-MailboxFolder -Context $Tgt -MailboxId $TgtMbx -ParentId $targetParentId -Name $name -Type $sf.Type).id }
            $tf = [pscustomobject]@{ Id = $newId; Path = $targetPath }
            $tgtByPath[$targetPath.ToLowerInvariant()] = $tf
            & $log "Created target folder '$targetPath' ($($sf.Type))"
        }
        $plan.Add([pscustomobject]@{ SourcePath = $sf.Path; Type = $sf.Type; Items = $sf.TotalItemCount; Action = $action; TargetPath = $targetPath })

        $m = [pscustomobject]@{
            SourceId   = $sf.Id
            SourcePath = $sf.Path
            Type       = $sf.Type
            Total      = $sf.TotalItemCount
            TargetId   = $tf.Id
            TargetPath = $targetPath
        }
        $mapped[$sf.Id] = $m
        $result.Add($m)
    }
    & $log "Folder mapping: $($result.Count) migrated, $($skipped.Count) skipped"
    if ($Preview) { return , $plan }
    , $result
}

function New-ImportSession {
    param([hashtable]$Tgt, [string]$TgtMbx)
    $s = Invoke-Graph -Context $Tgt -Method POST -Uri "admin/exchange/mailboxes/$TgtMbx/createImportSession"
    @{
        Url       = $s.importUrl
        Expires   = if ($s.expirationDateTime) { [DateTime]$s.expirationDateTime } else { (Get-Date).AddMinutes(50) }
        NeedsAuth = $false
    }
}

function Import-MailboxItemData {
    param([hashtable]$Tgt, [string]$TgtMbx, [hashtable]$Session, [string]$FolderId, [string]$Data)

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($Session.Expires -lt (Get-Date).AddMinutes(5)) {
            $new = New-ImportSession -Tgt $Tgt -TgtMbx $TgtMbx
            $Session.Url = $new.Url; $Session.Expires = $new.Expires
        }
        try {
            return Invoke-Graph -Context $Tgt -Method POST -Uri $Session.Url -NoAuth:(-not $Session.NeedsAuth) `
                -Body @{ FolderId = $FolderId; Mode = 'create'; Data = $Data }
        }
        catch {
            $code = $_.Exception.Data['StatusCode']
            if ($code -eq 401 -and -not $Session.NeedsAuth) { $Session.NeedsAuth = $true; continue }
            if ($code -in 401, 403, 404, 410 -and $attempt -lt 3) { $Session.Expires = [DateTime]::MinValue; continue }
            throw
        }
    }
}

function Invoke-PairMigration {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Pair,
        [switch]$Rescan     # re-list folders already completed (delta pass / retry of failed items)
    )
    $pairDir = Get-PairDir $Config $Pair
    $progressPath = Join-Path $pairDir 'progress.json'

    # Two workers on the same pair would import every item twice.
    $lock = Lock-StateFile (Join-Path $pairDir 'pair.lock')
    if (-not $lock) {
        Write-PairLog $pairDir 'Another run is already migrating this mailbox pair - not started.' 'WARN'
        return [pscustomobject]@{ Status = 'AlreadyRunning'; Message = 'This mailbox pair is already being migrated in another window/process.' }
    }
    try {
        Invoke-PairMigrationCore -Config $Config -Pair $Pair -Rescan:$Rescan -PairDir $pairDir -ProgressPath $progressPath
    }
    finally { $lock.Dispose() }
}

function Invoke-PairMigrationCore {
    param($Config, $Pair, [switch]$Rescan, [string]$PairDir, [string]$ProgressPath)
    $pairDir = $PairDir
    $progressPath = $ProgressPath
    $stats = [ordered]@{
        Source = $Pair.SourceMailbox; Target = $Pair.TargetMailbox
        Status = 'Starting'; Message = ''; CurrentFolder = ''
        FoldersTotal = 0; FoldersDone = 0
        ItemsTotal = 0; ItemsDone = 0; ItemsFailedThisRun = 0; BytesThisRun = 0
        StartedAt = (Get-Date).ToString('o'); UpdatedAt = (Get-Date).ToString('o')
    }
    $timer = @{ LastWrite = [DateTime]::MinValue }
    $save = {
        param([switch]$Force)
        if ($Force -or ((Get-Date) - $timer.LastWrite).TotalSeconds -ge 2) {
            $stats.UpdatedAt = (Get-Date).ToString('o')
            Write-JsonAtomic $progressPath $stats
            $timer.LastWrite = Get-Date
        }
    }
    & $save -Force

    try {
        $src = New-TenantContext -TenantConfig $Config.Source -GraphApiVersion $Config.GraphApiVersion -Name 'source'
        $tgt = if ($Config.SameTenant) { $src } else { New-TenantContext -TenantConfig $Config.Target -GraphApiVersion $Config.GraphApiVersion -Name 'target' }

        Write-PairLog $pairDir "=== Run started (rescan: $([bool]$Rescan)) ==="
        $srcMbx = Get-MailboxId -Context $src -User $Pair.SourceMailbox -Archive:$Pair.SourceArchive
        $tgtMbx = Get-MailboxId -Context $tgt -User $Pair.TargetMailbox -Archive:$Pair.TargetArchive
        if ($srcMbx -eq $tgtMbx) { throw 'Source and target mailbox are identical.' }

        $stats.Status = 'Mapping folders'; & $save -Force
        $folders = Resolve-FolderMapping -Config $Config -Pair $Pair -Src $src -Tgt $tgt -SrcMbx $srcMbx -TgtMbx $tgtMbx -PairDir $pairDir

        $folderStatePath = Join-Path $pairDir 'folders.json'
        $doneFolders = @{}
        $prev = Read-JsonFile $folderStatePath
        if ($prev -and -not $Rescan) { foreach ($id in @($prev.DoneFolderIds)) { $doneFolders[$id] = $true } }

        $done = Read-DoneSet $pairDir
        $stats.FoldersTotal = $folders.Count
        $stats.FoldersDone = @($folders | Where-Object { $doneFolders[$_.SourceId] }).Count
        $stats.ItemsTotal = ($folders | Measure-Object Total -Sum).Sum
        $stats.ItemsDone = $done.Count
        $stats.Status = 'Migrating'
        & $save -Force

        $session = New-ImportSession -Tgt $tgt -TgtMbx $tgtMbx
        $maxBytes = [long]$Config.MaxItemSizeMB * 1MB
        $batchBytesLimit = 30MB

        foreach ($f in $folders) {
            if ($doneFolders[$f.SourceId]) { continue }
            if (Test-StopRequested $Config) { $stats.Status = 'Stopped'; break }
            $stats.CurrentFolder = $f.SourcePath; & $save -Force
            Write-PairLog $pairDir "Folder '$($f.SourcePath)' -> '$($f.TargetPath)' ($($f.Total) items)"

            $batch = [System.Collections.Generic.List[object]]::new()
            $batchBytes = 0
            $flush = {
                if ($batch.Count -eq 0) { return }
                Invoke-ItemBatch -Src $src -Tgt $tgt -SrcMbx $srcMbx -TgtMbx $tgtMbx -Session $session `
                    -Items $batch.ToArray() -Folder $f -PairDir $pairDir -Stats $stats -Done $done
                $batch.Clear()
                & $save
            }

            $next = "admin/exchange/mailboxes/$srcMbx/folders/$([uri]::EscapeDataString($f.SourceId))/items?`$top=100"
            while ($next) {
                $page = Invoke-Graph -Context $src -Uri $next
                foreach ($it in @($page.value)) {
                    if ($done.Contains($it.id)) { continue }
                    $size = [long]($it.size ?? 0)
                    if ($maxBytes -gt 0 -and $size -gt $maxBytes) {
                        Add-FailedItem $pairDir $f.SourcePath $it.id "Item too large ($([math]::Round($size / 1MB, 1)) MB)"
                        $stats.ItemsFailedThisRun++
                        continue
                    }
                    if ($batch.Count -ge 20 -or ($batch.Count -gt 0 -and $batchBytes + $size -gt $batchBytesLimit)) {
                        & $flush; $batchBytes = 0
                    }
                    $batch.Add($it); $batchBytes += $size
                }
                if (Test-StopRequested $Config) { break }
                $next = $page.'@odata.nextLink'
            }
            & $flush

            if (Test-StopRequested $Config) { $stats.Status = 'Stopped'; break }
            $doneFolders[$f.SourceId] = $true
            $stats.FoldersDone++
            Write-JsonAtomic $folderStatePath @{ DoneFolderIds = @($doneFolders.Keys); UpdatedAt = (Get-Date).ToString('o') }
        }

        if ($stats.Status -ne 'Stopped') {
            $stats.Status = if ($stats.ItemsFailedThisRun -gt 0) { 'CompletedWithErrors' } else { 'Completed' }
        }
        $stats.CurrentFolder = ''
        Write-PairLog $pairDir "=== Run finished: $($stats.Status), failed this run: $($stats.ItemsFailedThisRun) ==="
    }
    catch {
        $stats.Status = 'Failed'
        $stats.Message = $_.Exception.Message
        Write-PairLog $pairDir "FATAL: $($_.Exception.Message)" 'ERROR'
    }
    & $save -Force
    [pscustomobject]$stats
}

function Invoke-ItemBatch {
    param(
        [hashtable]$Src, [hashtable]$Tgt, [string]$SrcMbx, [string]$TgtMbx, [hashtable]$Session,
        [object[]]$Items, $Folder, [string]$PairDir, $Stats,
        [System.Collections.Generic.HashSet[string]]$Done
    )
    $sizes = @{}
    foreach ($i in $Items) { $sizes[$i.id] = [long]($i.size ?? 0) }

    $exported = $null
    try {
        $exported = @((Invoke-Graph -Context $Src -Method POST -Uri "admin/exchange/mailboxes/$SrcMbx/exportItems" -Body @{ itemIds = @($Items.id) }).value)
    }
    catch {
        # Batch-level failure: fall back to one item at a time so a single bad item does not block the rest.
        if ($Items.Count -gt 1) {
            foreach ($i in $Items) {
                Invoke-ItemBatch -Src $Src -Tgt $Tgt -SrcMbx $SrcMbx -TgtMbx $TgtMbx -Session $Session `
                    -Items @($i) -Folder $Folder -PairDir $PairDir -Stats $Stats -Done $Done
            }
            return
        }
        Add-FailedItem $PairDir $Folder.SourcePath $Items[0].id "Export: $($_.Exception.Message)"
        $Stats.ItemsFailedThisRun++
        return
    }

    foreach ($r in $exported) {
        if ($r.error -or -not $r.data) {
            Add-FailedItem $PairDir $Folder.SourcePath $r.itemId "Export: $($r.error.code) $($r.error.message)"
            $Stats.ItemsFailedThisRun++
            continue
        }
        try {
            $null = Import-MailboxItemData -Tgt $Tgt -TgtMbx $TgtMbx -Session $Session -FolderId $Folder.TargetId -Data $r.data
            Add-DoneItem $PairDir $r.itemId
            $null = $Done.Add($r.itemId)
            $Stats.ItemsDone++
            $Stats.BytesThisRun += $sizes[$r.itemId]
        }
        catch {
            Add-FailedItem $PairDir $Folder.SourcePath $r.itemId "Import: $($_.Exception.Message)"
            $Stats.ItemsFailedThisRun++
        }
    }
}
