# Architecture

This document explains how Mailbox Migrator works internally. It is meant for anyone who maintains or extends the code.

## Overview

```
MailboxMigrator.ps1 (wizard / CLI)
        │
        ▼
Start-Migration (Orchestrator.ps1) ── takes run.lock, renders progress, handles Q / Ctrl+C
        │  one thread job per mailbox pair (up to Parallelism)
        ▼
Invoke-PairMigration (Engine.ps1) ── takes pair.lock
        │
        ├─ Get-MailboxId                 users/{upn}/settings/exchange
        ├─ Resolve-FolderMapping         admin/exchange/mailboxes/{id}/folders (+ childFolders)
        ├─ New-ImportSession             .../createImportSession
        └─ per folder, per page of items
              ├─ exportItems (≤ 20 items, ≤ 30 MB per batch)
              ├─ POST importUrl (one item at a time)
              └─ append item ID to done.log
```

All Graph traffic goes through `Invoke-Graph` (Graph.ps1). It handles token refresh on 401, honours `Retry-After` on 429/503, and retries transient errors (408, 5xx, network) with exponential backoff.

## Authentication

- **Setup** (`Install-MigrationApp`) signs in an administrator with the device code flow, using the public *Microsoft Graph Command Line Tools* client. With that token it creates or updates the app registration, its service principal and the app role assignments (admin consent). Each step is idempotent and retries Entra ID replication delays, so setup can be rerun safely.
- **Migration** uses app-only client credentials. With a certificate, `New-ClientAssertion` builds and signs a JWT client assertion (RS256) using the private key from `Cert:\CurrentUser\My` or `Cert:\LocalMachine\My`. With a client secret, the secret is stored DPAPI-encrypted in the config file.
- Tokens are cached per tenant context and refreshed 5 minutes before they expire.

## Mailbox import/export API

| Call | Purpose |
|---|---|
| `GET users/{upn}/settings/exchange` | `primaryMailboxId` / `archiveMailboxId` |
| `GET admin/exchange/mailboxes/{id}/folders`, `.../folders/{fid}/childFolders` | folder tree incl. `type`, `wellKnownName`, `isHidden`, `totalItemCount` |
| `POST admin/exchange/mailboxes/{id}/folders`, `.../childFolders` | create target folders (`type` is required) |
| `GET admin/exchange/mailboxes/{id}/folders/{fid}/items` | item IDs and sizes, paged |
| `POST admin/exchange/mailboxes/{id}/exportItems` | full-fidelity export (FTS, base64), up to 20 items |
| `POST admin/exchange/mailboxes/{id}/createImportSession` | returns `importUrl` and its expiry |
| `POST {importUrl}` | imports one item into a folder (`Mode: create`) |

The import session is recreated shortly before it expires or when the import URL starts returning 401/403/404/410. The import URL is called without a bearer token first; on 401 the token is added and kept for the rest of the session.

## Folder mapping

`Resolve-FolderMapping` walks the source tree in pre-order, so parents are always handled before their children:

1. `Get-FolderSkipReason` drops Outbox and Sync Issues (by `wellKnownName`), hidden folders, folders without a type that are not default folders, types not in `IncludeFolderTypes`, and names in `ExcludeFolderNames`. Children of a skipped folder are skipped too.
2. With `TargetRootFolder`, everything is placed under that folder by path.
3. Otherwise a folder with a `wellKnownName` maps to the target folder with the same `wellKnownName`, which makes the mapping independent of mailbox language.
4. Other folders map to `<mapped parent path>/<name>`. A missing target folder is created with the source folder's type, or `IPF.Note` when the source has none.

With `-Preview` nothing is created. The function then returns the plan for every source folder, which the pre-flight check displays.

## State and resume

Everything a run needs to resume is in `work/jobs/<JobName>/<pair>/`:

- `done.log` is append-only and gets each source item ID right after a successful import. It is loaded into a `HashSet` at start, and items already in it are skipped.
- `folders.json` lists completed folder IDs and is written atomically (temporary file, then move). Completed folders are not listed again unless the run is a delta pass (`-Rescan`).
- `failed.log` collects items that failed after retries. They are not in `done.log`, so a delta pass retries them automatically.
- `progress.json` is rewritten at most every 2 seconds and read by the orchestrator to render progress.

Folder creation is idempotent because target folders are matched before anything is created. Rerunning a pair therefore never duplicates folders. Items are duplicated only in the narrow window between a successful import and the `done.log` append.

## Concurrency

- `Start-Migration` holds `run.lock` (an exclusive `FileStream`) for the whole run. A second wizard window running the same job cannot start. The lock is taken before an old `STOP` file is removed, so a second window cannot cancel a pending stop request.
- Each worker holds `pair.lock` while it migrates its pair. A pair is therefore never migrated by two workers at once, which would import every item twice.
- The OS releases both locks if the process dies, so a crash never leaves a stale lock.
- Stopping is cooperative: `Q`, Ctrl+C or `Request-MigrationStop` creates `STOP`. Workers check for it between batches and pages, and return `Stopped`. On Ctrl+C the orchestrator's `finally` block creates `STOP` and waits up to 3 minutes for workers to finish before it removes the jobs.

## Extending

- **New target types** (e.g. file export or another mail system) belong next to `Invoke-ItemBatch`. The state, locking, progress and orchestration layers do not depend on how an item is written.
- **New permissions** go into `$script:RequiredPermissions` in Setup.ps1. Rerunning setup adds them to the existing app.
- Keep `MailboxMigrator.ps1` parseable by Windows PowerShell 5.1 (no `??`, ternary or other PS7-only syntax), otherwise the automatic relaunch in `pwsh` never runs.
