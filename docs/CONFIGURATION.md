# Configuration

The wizard (option 1) writes `migration.config.json` next to `MailboxMigrator.ps1`. You can also edit the file by hand, or keep several config files and select one with `-ConfigPath`.

`migration.config.json` and `mapping.csv` are listed in `.gitignore` because they contain tenant and app identifiers.

## Example

```json
{
  "JobName": "Contoso-Fabrikam",
  "WorkDir": "./work",
  "MappingCsv": "./mapping.csv",
  "GraphApiVersion": "beta",
  "SameTenant": false,
  "Parallelism": 4,
  "MaxItemSizeMB": 150,
  "IncludeFolderTypes": ["IPF.Note", "IPF.Appointment", "IPF.Contact", "IPF.Task", "IPF.StickyNote", "IPF.Journal"],
  "ExcludeFolderNames": ["Conversation Action Settings", "Quick Step Settings", "RSS Feeds"],
  "Source": {
    "TenantId": "00000000-0000-0000-0000-000000000000",
    "TenantName": "Contoso",
    "ClientId": "00000000-0000-0000-0000-000000000000",
    "CertificateThumbprint": "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
    "ClientSecretEncrypted": null
  },
  "Target": { "...": "same structure as Source" }
}
```

## Settings

| Setting | Default | Description |
|---|---|---|
| `JobName` | `Migration-<date>` | Name of the state folder `work/jobs/<JobName>`. Same name = resume, new name = start from scratch. Do not change it during a migration. |
| `WorkDir` | `./work` | Where state and logs are stored. A relative path is resolved against the config file location. |
| `MappingCsv` | `./mapping.csv` | Mailbox pairs to migrate. A relative path is resolved against the config file location. |
| `GraphApiVersion` | `beta` | Graph endpoint version. The mailbox import/export API is currently only in `beta`. |
| `SameTenant` | `false` | `true` = source and target are in the same tenant and share one app (`Mailbox Migrator (Both)`). |
| `Parallelism` | `4` | Number of mailbox pairs migrated at the same time. Higher values are faster but more likely to hit Exchange throttling. |
| `MaxItemSizeMB` | `150` | Larger items are skipped and written to `failed.log`. `0` disables the limit. |
| `IncludeFolderTypes` | mail, calendar, contacts, tasks, notes, journal | Folder classes that are migrated. Sub-classes such as `IPF.Appointment.Birthday` must be listed explicitly to be included. |
| `ExcludeFolderNames` | client artefacts (RSS, Quick Steps …) | Folder names that are skipped at any level, case-insensitive. Outbox, Sync Issues, hidden folders and untyped system folders are skipped regardless of this list. |
| `Source` / `Target` | – | Filled in by setup (options 2 and 3). Use either `CertificateThumbprint` or `ClientSecretEncrypted`. |

## Mapping CSV

| Column | Required | Description |
|---|---|---|
| `SourceMailbox` | yes | UPN or primary SMTP address of the source mailbox |
| `TargetMailbox` | yes | UPN or primary SMTP address of the target mailbox |
| `SourceArchive` | no | `true` = read from the source archive mailbox |
| `TargetArchive` | no | `true` = write into the target archive mailbox |
| `TargetRootFolder` | no | Place all content under this top-level folder in the target |

Boolean columns accept `true`/`false`, `1`/`0` and `yes`/`no`. Rows without both mailboxes are ignored.

## Command-line parameters

| Parameter | Description |
|---|---|
| `-ConfigPath <path>` | Config file to use (default: `migration.config.json` next to the script) |
| `-Run` | Start or resume the migration without the menu. Exits with code 1 if the configuration is incomplete. |
| `-Run -Rescan` | Delta pass: re-list all folders, migrate new items and retry failed ones |
| `-Status` | Print the status table and exit |
