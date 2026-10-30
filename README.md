# Mailbox Migrator for Exchange Online

A PowerShell wizard that migrates Exchange Online mailbox content:

- **tenant → tenant** (e.g. contoso.com → fabrikam.com),
- **mailbox → another mailbox in the same tenant** (optionally into a subfolder such as `Migrated - info`),
- primary mailboxes and **archives** (In-Place Archive).

It migrates **mail, calendar (including recurring meetings), contacts, tasks and notes**. Items are copied at full fidelity through the Microsoft Graph **mailbox import/export API** (FTS format, not MIME), so attachments, flags, categories and calendar properties are preserved.

## Features

| | |
|---|---|
| Wizard | console menu, or non-interactive `-Run` / `-Status` |
| Graph permissions | creates the app registration and a self-signed certificate, and grants admin consent |
| Progress | overall progress bar (items, items/min, ETA) plus one bar per mailbox |
| Parallelism | several mailboxes at once (thread jobs); configurable |
| Resume after a crash | state is saved after every item. After a crash, reboot, Ctrl+C or `Q`, the next run continues where it stopped |
| Duplicate protection | locks prevent the same job or mailbox pair from running twice at the same time (e.g. in two windows) |
| Delta pass | syncs new items (e.g. right before cutover) and retries failed ones |
| Folder plan | the pre-flight check shows, for every folder, where it goes, whether it will be created, or why it is skipped. It changes nothing. |
| Throttling | honours `Retry-After` (429/503), retries with exponential backoff and refreshes the token |
| Any language | default folders are paired by the API's `wellKnownName`, so e.g. Slovak `Doručená pošta` maps to English `Inbox` |

## Requirements

- **PowerShell 7.2+** (`winget install Microsoft.PowerShell`). If you start the script from Windows PowerShell 5.1, it relaunches itself in `pwsh`.
- To create the app: a **Global Administrator**, or **Application Administrator + Privileged Role Administrator**, in each tenant.
- Target mailboxes must **already exist and be licensed**. The tool does not create them.

## Quick start

```powershell
.\MailboxMigrator.ps1
```

1. **Configuration**: mode (tenant → tenant / within tenant), job name and mapping CSV path. The wizard can create a sample CSV. If you pick option 2 first, it asks for the configuration on its own.
2. **Source tenant**: device code sign-in. Creates the app `Mailbox Migrator (Source)` (or `Mailbox Migrator (Both)` in within-tenant mode), a certificate in `Cert:\CurrentUser\My`, and grants admin consent. Safe to rerun: it reuses the existing app and certificate and only adds what is missing.
3. **Target tenant**: the same for the target tenant. Skipped in within-tenant mode.
4. **Pre-flight check**: verifies granted permissions and mailboxes, and shows the folder plan with item counts.
5. **Start / resume**: runs the migration with live progress. `Q` or Ctrl+C stops it safely.
6. **Delta pass**: before cutover (after the MX switch), syncs the difference and retries failed items.
7. **Status and report**: status table of all mailbox pairs, with optional CSV export.
8. **Reset state**: forgets what was migrated for one mailbox pair. The next run starts from scratch, so watch out for duplicates in the target.

Non-interactive, e.g. from Task Scheduler:

```powershell
pwsh ./MailboxMigrator.ps1 -ConfigPath ./migration.config.json -Run   # start / resume
pwsh ./MailboxMigrator.ps1 -Run -Rescan                                # delta pass
pwsh ./MailboxMigrator.ps1 -Status
```

## Mapping CSV

```csv
SourceMailbox,TargetMailbox,SourceArchive,TargetArchive,TargetRootFolder
jan.novak@contoso.com,jan.novak@fabrikam.com,false,false,
eva.mala@contoso.com,eva.mala@fabrikam.com,true,true,
info@contoso.com,office@fabrikam.com,false,false,Migrated - info
```

- `SourceArchive` / `TargetArchive`: `true` uses the archive mailbox. Primary and archive are two separate rows.
- `TargetRootFolder`: when set, everything goes under this folder in the target (useful when merging mailboxes in one tenant). When empty, folders are mapped 1:1.

## Folder mapping

- **Default folders** (Inbox, Sent Items, Calendar, Contacts, Tasks, Notes …) are paired by `wellKnownName`, regardless of mailbox language.
- **Custom folders** are created under the matching parent in the target, with the same folder type (mail, calendar, contacts …). An existing folder with the same path is reused.
- **Skipped:**
  - Outbox, so nothing gets sent,
  - Sync Issues and its subfolders,
  - hidden folders (Yammer …),
  - system folders without a type (Infected Items, Detected Items …),
  - types not listed in `IncludeFolderTypes` (e.g. Birthdays),
  - names listed in `ExcludeFolderNames`.

  Every skipped folder is written to `run.log`, as `WARN` when it contains items.

## Graph permissions (application)

| Source | Target |
|---|---|
| User.Read.All | User.Read.All |
| MailboxFolder.Read.All | MailboxFolder.ReadWrite.All |
| MailboxItem.Read.All | MailboxItem.Read.All |
| MailboxItem.ImportExport.All | MailboxItem.ImportExport.All |

**Recommendation:** application permissions apply to **every mailbox in the tenant**. Scope the app to the migrated mailboxes only with [RBAC for Applications](https://learn.microsoft.com/exchange/permissions-exo/application-rbac) in Exchange Online, and delete the app registration and certificate when the migration is finished.

To run the migration from another computer, export the certificate with its private key (`Export-PfxCertificate`) and import it there into `CurrentUser\My`. A client secret is stored encrypted with DPAPI, so it only works for the same user on the same computer.

## How resume works

State lives in `work/jobs/<JobName>/<source>__<target>/`:

| File | Content |
|---|---|
| `done.log` | ID of every successfully migrated item (append-only, written right after each import) |
| `folders.json` | completed folders (written atomically) |
| `failed.log` | items that failed after retries (TSV: time, folder, ID, error) |
| `progress.json` | live status for the progress display |
| `run.log` | detailed log |
| `pair.lock` | lock held by the worker migrating this pair |

`work/jobs/<JobName>/` also holds `job.log` (run starts and ends), `run.lock` (job-wide lock) and, temporarily, `STOP` (stop request).

On the next run, completed folders and items are skipped. Target folders are matched by `wellKnownName` or path, so they are never created twice. Completed mailbox pairs are skipped entirely, except in a delta pass.

Locks are held by the operating system and are released automatically if the process dies. If the same job is already running in another window, the wizard refuses to start a second run. On Ctrl+C, the wizard first lets workers finish their current batch, so nothing keeps running in the background.

**Edge cases:**
- If the process dies exactly between importing an item and writing it to `done.log`, that single item may appear twice in the target.
- If a user moves a message to another folder in the source between runs, its ID changes and the delta pass copies it again.

## Important notes

- **The mailbox import/export API is in Microsoft Graph `beta`** (configurable through `GraphApiVersion`). Before a production migration, **test with 1–2 pilot mailboxes** and check the current API documentation, permissions and any API charges.
- Source mailboxes are **never modified**, only read.
- Items larger than `MaxItemSizeMB` (default 150 MB) are skipped and written to `failed.log`.
- Not migrated: inbox rules, mailbox and folder permissions, delegates, signatures, automatic replies.
- For large migrations (hundreds of mailboxes, terabytes of data), also consider Microsoft's native [cross-tenant mailbox migration](https://learn.microsoft.com/microsoft-365/enterprise/cross-tenant-mailbox-migration). It requires the Cross-Tenant User Data Migration license and MailUser objects in the target.

## Further documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the tool works internally (migration flow, API calls, state, parallelism)
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md): every setting in `migration.config.json`
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md): known errors and how to fix them

## Project layout

```
MailboxMigrator.ps1      wizard / CLI
mapping.sample.csv
docs/                    detailed documentation
src/
  MailboxMigrator.psm1   module loader
  Auth.ps1               app-only token (certificate/secret), device code for setup
  Graph.ps1              HTTP calls with retry/throttling
  Setup.ps1              app registration, permissions, admin consent
  State.ps1              on-disk state (resume, locks)
  Engine.ps1             folder mapping, item export/import
  Orchestrator.ps1       parallel run, progress, status, report, pre-flight
```

I'm adding more tools and templates over time, so feel free to [follow me on GitHub](https://github.com/DuprTECH) to see what's new.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/duprtech)

## License

[MIT](LICENSE)
