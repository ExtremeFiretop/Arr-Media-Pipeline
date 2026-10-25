# Maintenance

Maintenance manages retained normalization backups and abandoned normalization temp artifacts.

Current maintenance behavior is deliberately conservative.

## Defaults

```text
backup retention: 7 days
ordinary temp retention: 24 hours
mode: DRY_RUN
```

Actual deletion requires:

```powershell
.\Integration\Invoke-MediaMaintenance.ps1 -Execute
```

## Backup eligibility

Age alone is not enough.

A backup may become eligible only when all required evidence is present:

1. original normalization mode was `EXECUTE`
2. original execution status was `SUCCESS`
3. no rollback is recorded
4. original Arr reconciliation succeeded
5. backup still exists
6. current normalized media still exists
7. retention period has elapsed
8. current generic validation succeeds
9. current contextual validation leaves an effective `PASS`
10. current Arr file path matches disk
11. current Arr file size matches disk

If any condition is not proven, the backup is kept.

## Historical schema behavior

Older execution records may predate recorded Arr reconciliation.

These are not guessed safe.

Example reason:

```text
arr_reconciliation_not_confirmed
```

The backup remains protected.

## Temp cleanup

Ordinary normalization temp:

```text
<media>.reqestra-<executionId>.tmp
```

may become eligible after the temp-retention period.

Failed replacement artifact:

```text
<media>.reqestra-failed-<executionId>.tmp
```

is never automatically deleted by maintenance.

## Artifact discovery

Maintenance derives known temp paths from recorded normalization execution work rather than blindly scanning every media directory for arbitrary files.

## Concurrency

Execute-mode maintenance obtains:

```text
ReqestraMediaMaintenance
ReqestraMediaNormalization
```

If normalization currently owns the media-write mutex, deletion does not proceed.

## Reports

Every maintenance run writes a JSON report beneath:

```text
Integration\Maintenance\reports\
```

Deletion events are also audited in:

```text
Integration\Maintenance\maintenance.jsonl
```

## Status

```powershell
.\Integration\Get-MediaMaintenanceStatus.ps1
```

## Dry-run examples

Normal policy:

```powershell
.\Integration\Invoke-MediaMaintenance.ps1
```

Force the retention threshold to zero for eligibility testing without deleting anything:

```powershell
.\Integration\Invoke-MediaMaintenance.ps1 `
    -BackupRetentionDays 0
```

Do not combine a zero-day test threshold with `-Execute` unless immediate deletion is genuinely intended.

## Current validated behavior

Real retained backups have demonstrated all three expected cases:

- historical backup lacking recorded reconciliation -> `KEEP`
- healthy Sonarr-normalized backup -> eligible after retention
- healthy Radarr-normalized backup -> eligible after retention

No automatic scheduled cleanup is required for the core normalization path; scheduling is a later operational phase.
