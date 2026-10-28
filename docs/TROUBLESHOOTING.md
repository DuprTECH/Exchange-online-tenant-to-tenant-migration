# Troubleshooting

Logs to check first:

- `work/jobs/<JobName>/job.log`: run starts and ends, worker errors
- `work/jobs/<JobName>/<pair>/run.log`: folder mapping, skipped folders, fatal errors
- `work/jobs/<JobName>/<pair>/failed.log`: items that could not be migrated

## Script requires PowerShell 7.2

```
The script 'MailboxMigrator.ps1' cannot be run because it contained a "#requires" statement for Windows PowerShell 7.2
```

You are on an old version of the script. The current version relaunches itself in `pwsh` automatically. If PowerShell 7 is missing, install it with `winget install Microsoft.PowerShell`.

## Setup: `NoBackingApplicationObject`

```
The appId '...' of the service principal does not reference a valid application object.
```

Entra ID had not replicated the new app registration yet when the service principal was created. Current versions wait and retry. Run option 2 (or 3) again: setup reuses the app and certificate it already created and only completes the missing steps.

## `Tenant 'source' is not configured`

The setup did not finish, so the app details were never saved to the config. Run option 2 (and option 3 for tenant-to-tenant) again. The header of the menu shows the tenant name once setup has succeeded.

## A permission shows `Granted = False` in the pre-flight check

Permission changes can take several minutes to reach the token service. Wait a few minutes and run option 4 again. If it is still missing, check the app in Entra admin center → App registrations → `Mailbox Migrator (…)` → API permissions, and grant admin consent.

## `The property 'type' is required when creating the entity`

An older version tried to create system folders without a folder class (Infected Items, Detected Items …). Current versions skip such folders and always send a type when creating a folder. Update the code and rerun. Nothing was created in the target by the failed attempt.

## The migration keeps running after the wizard is closed, or items appear two or three times

Older versions did not stop their thread jobs when the wizard was interrupted. Starting the wizard again then added another worker on the same mailbox, and each worker imported the same items.

Current versions prevent this:
- a job runs only once at a time (`run.lock`),
- a mailbox pair is migrated by one worker only (`pair.lock`),
- Ctrl+C stops the workers before the wizard exits.

To clean up a mailbox that already has duplicates:
1. Close every `pwsh` window that ran the wizard.
2. In the target mailbox, permanently delete (Shift+Del) the affected folders.
3. Reset the pair state (option 8).
4. Start the migration again (option 5).

## `Job '...' is already running in another window or in the background`

Another process holds `run.lock`. Stop the migration there (`Q`) or close that window. If no other window exists, close all `pwsh` processes; the lock is released when the process holding it ends.

## The console beeps on every progress refresh

Older versions used `Write-Progress`, and on some PowerShell 7.6 consoles every refresh beeped, even with `$PSStyle.Progress.UseOSCIndicator` turned off. Current versions draw the status as plain text, which cannot beep. If you still hear a sound at irregular intervals, it is probably Outlook announcing the imported items in a target mailbox that is open in Outlook.

## Items in `failed.log`

| Error | Meaning |
|---|---|
| `Item too large (… MB)` | Above `MaxItemSizeMB`. Raise the limit or move the item manually. |
| `Export: ...` | The source item could not be exported (corrupt or inaccessible item). |
| `Import: ...` | The target rejected the item. Check the message; transient errors are retried by a delta pass. |

Run a delta pass (option 6) to retry all failed items.

## Throttling and slow progress

Exchange Online throttles per mailbox and per app. The tool honours `Retry-After` automatically, so short pauses are normal. If throughput is low for long periods, lower `Parallelism`. Very large mailboxes (hundreds of thousands of items) take hours; you can stop with `Q` at any time and resume later.
