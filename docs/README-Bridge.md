# Reqestra Arr Validator Bridge v0.8.0

Phase 5B2 introduces the persistent automatic normalization queue.

## Safety boundary

**Automatic media writes are impossible through the v0.6.0 queue worker.**

The worker is hard-coded to call `Invoke-Normalization.ps1` without `-Execute`.

Manual execution through `Invoke-Normalization.ps1 -Execute` remains available exactly as in v0.5.2, but the new automatic pipeline only performs dry-run preflight.

## Automatic lifecycle

```text
Radarr / Sonarr import
        |
        +--> generic validation
        |
        +--> contextual validation
        |
        +--> normalization planner
        |
        +--> if plan == PLANNED:
                 enqueue persistent job
                         |
                         +--> start independent worker
                                  |
                                  +--> one job at a time
                                  +--> guarded executor DRY RUN
                                  +--> persist result
```

The Connect callback does not wait for remux/normalization work.

## Queue location

Created automatically at runtime:

```text
Integration\Queue\
    pending\
    running\
    history\
    results\
    logs\
    queue.jsonl
```

These directories are intentionally not included in the ZIP, so extracting future upgrades will not overwrite queue history.

## Duplicate suppression

The job id is a deterministic SHA-256 identity derived from:

- queue mode (`AUTO_DRY_RUN`)
- media path
- source length
- source LastWriteTimeUtc
- stream fingerprint
- planned finding codes
- exact normalization actions

Replaying the same unchanged event therefore does not create another job.

## Crash recovery

The worker uses a named mutex:

`ReqestraNormalizationWorker`

Only one worker processes jobs at a time.

When a worker starts after an interrupted previous worker, any orphaned files in `Queue\running` are returned to `Queue\pending`.

This is safe in v0.6.0 because automatic jobs are dry-run only.

## Queue job states

Pending:
- `QUEUED`

During worker processing:
- `PREFLIGHT`

Final history states:
- `DRY_RUN_READY`
- `BLOCKED`
- `FAILED`

The executor's detailed JSON result is retained under `Queue\results`.

## Auto-start

Every newly enqueued job causes the bridge to launch a hidden independent worker process.

Multiple imports may launch multiple worker processes, but the worker mutex means only one becomes active. The others exit immediately.

## Bridge result

For a `PLANNED` event, `bridge-result.json` now contains:

```text
normalizationQueue:
    status: ENQUEUED | DUPLICATE | QUEUE_ERROR
    jobId: ...
    queueMode: AUTO_DRY_RUN
    workerStarted: true | false
```

Queue failures never fail a Radarr/Sonarr import.

## Tests

Existing tests remain:

```powershell
.\Integration\Test-ContextValidator.ps1
.\Integration\Test-NormalizationPlanner.ps1
.\Integration\Test-BridgePlannerHandoff.ps1
.\Integration\Test-ArrReconciliationContract.ps1
```

New queue test:

```powershell
.\Integration\Test-NormalizationQueue.ps1
```

Expected:

`PASS: 5/5 normalization queue tests passed.`

## Queue status

```powershell
.\Integration\Get-NormalizationQueueStatus.ps1
```

This displays queue counts and recent completed jobs.

## Manual worker start

Normally unnecessary because the bridge auto-starts the worker.

If a queued job remains after an unexpected process-launch problem:

```powershell
.\Integration\NormalizationWorker.ps1
```

It still performs dry-run only.

## Existing manual executor

The proven v0.5.2 executor behavior remains intact:

- explicit `-Execute`
- guarded mkvmerge remux
- temp validation
- atomic replacement
- backup
- final validation
- Sonarr `RescanSeries`
- Radarr `RescanMovie`
- path/size reconciliation
- rollback semantics

## Upgrade

Extract over:

`C:\Program Files\MKVToolNix\Custom Scripts\MediaValidator\`

The archive does not include:
- your live `integration-config.json`
- queue runtime state
- logs
- backups


## v0.6.1

Fixes a worker job-persistence bug discovered during the first real automatic queue test.

### Symptom

The executor successfully produced its dry-run result, but the worker left the queue job in:

`Queue\running` with `state = PREFLIGHT`

The worker log reported that a property such as `error` could not be found on the job object.

### Cause

PowerShell `PSCustomObject` instances cannot safely receive arbitrary new properties through direct assignment when those properties were not part of the deserialized object schema.

The v0.6.0 worker attempted to add bookkeeping fields such as:

- `workerVersion`
- `executorProcessExitCode`
- `executorStdoutPath`
- `executorStderrPath`
- `error`

using direct property assignment.

### Fix

v0.6.1:

- adds those fields to newly queued job documents
- uses a schema-safe `Set-JobProperty` helper for existing/older queue jobs
- makes crash-recovery bookkeeping compatible with older job files
- bumps queue version to `0.1.1`
- bumps worker version to `0.1.1`

### Existing stranded jobs

No manual queue-file editing is required.

On the next worker start, the existing file in `Queue\running` is automatically returned to `Queue\pending`, its recovery count is incremented, and it is reprocessed.

Because the automatic worker is still hard-coded `AUTO_DRY_RUN`, replaying the recovered job has no media-write side effects.


# Phase 5C — v0.7.0 media artifact retention

v0.7.0 adds guarded cleanup for normalization backups and abandoned ordinary remux temp files.

## Safety model

`Invoke-MediaMaintenance.ps1` is **DRY_RUN by default**.

Actual deletion requires:

```powershell
.\Integration\Invoke-MediaMaintenance.ps1 -Execute
```

No automatic/scheduled deletion is enabled in v0.7.0.

## Backup retention

Default retention: **7 days**.

A backup is not eligible merely because it is old.

Every backup must satisfy all of these conditions:

1. its normalization execution was `EXECUTE`
2. execution status was `SUCCESS`
3. no rollback record exists
4. Arr reconciliation succeeded
5. the backup file still exists
6. the normalized media still exists
7. the retention period has elapsed
8. the current media is re-run through the generic validator
9. the current contextual validator also leaves the effective result at `PASS`
10. the current Sonarr/Radarr file record still points to the same path
11. the current Sonarr/Radarr recorded size exactly equals disk

Only then is the backup `WOULD_DELETE` in dry-run mode or deleted under `-Execute`.

Deletion events are written to:

```text
Integration\Maintenance\maintenance.jsonl
```

The original execution log is not rewritten.

## Temp cleanup

Default ordinary temp retention: **24 hours**.

Instead of crawling the entire movie and TV libraries, maintenance derives exact temp paths from known normalization execution work directories:

```text
normalization-execution-<executionId>
```

Eligible ordinary artifact:

```text
<media>.reqestra-<executionId>.tmp
```

Protected artifact:

```text
<media>.reqestra-failed-<executionId>.tmp
```

Failed replacement artifacts are **never automatically deleted**, regardless of age.

## Concurrency

Deletion mode obtains:

- `ReqestraMediaMaintenance`
- `ReqestraMediaNormalization`

If an actual normalization owns the normalization mutex, maintenance refuses to delete anything.

## Reports

Every run writes a JSON report under:

```text
Integration\Maintenance\reports\
```

The runtime Maintenance directory is not included in upgrade ZIPs.

View recent reports:

```powershell
.\Integration\Get-MediaMaintenanceStatus.ps1
```

## Test

```powershell
.\Integration\Test-MediaMaintenance.ps1
```

Expected:

```text
PASS: 8/8 media maintenance tests passed.
```

## First live validation

Keep the real backups for now and run:

```powershell
.\Integration\Invoke-MediaMaintenance.ps1
```

With the default seven-day retention, the recent Grease, Star Trek, and Crawlers backups should be discovered but retained because they are too young.

To validate the full eligibility checks without deleting anything, temporarily override retention in **dry-run only**:

```powershell
.\Integration\Invoke-MediaMaintenance.ps1 -BackupRetentionDays 0
```

This performs the fresh media validation and Arr verification and should mark healthy test backups `WOULD_DELETE`.

Do not use `-Execute -BackupRetentionDays 0` for the initial test.


## v0.7.1 — historical execution compatibility fix

The first live maintenance scan exposed a mixed-schema issue.

Older normalization execution results, including executions created before Arr reconciliation was added to the executor, may not contain an `arrReconciliation` property at all.

Under PowerShell StrictMode, v0.7.0 attempted to access that missing property directly and stopped the maintenance scan.

v0.7.1 now:

- reads historical result properties defensively
- treats a missing reconciliation record as **not confirmed**
- protects that backup with:
  `arr_reconciliation_not_confirmed`
- allows the maintenance scan to continue across mixed executor versions
- prevents one malformed historical result from aborting the entire scan
- records whether each backup execution actually contains an Arr reconciliation record

This is intentionally conservative. A backup is not made deletion-eligible merely because reconciliation may have been performed manually later.

For the existing test backups this means:

- Grease S01E07: expected to remain protected because its original executor result predates recorded Arr reconciliation
- Star Trek: Prodigy S01E10: eligible for normal retention verification
- Crawlers (2026): eligible for normal retention verification

Run:

```powershell
.\Integration\Test-MediaMaintenance.ps1
```

Expected:

```text
PASS: 9/9 media maintenance tests passed.
```


# Phase 5D — v0.8.0 gated automatic normalization execution

v0.8.0 adds an explicit automatic-execution mode on top of the proven queue, executor, reconciliation, and retention systems.

## Fail-closed default

If `normalization-worker-config.json` does not exist, is malformed, contains an invalid mode, or fails any execute gate:

```text
effectiveMode = AUTO_DRY_RUN
automaticWritesAuthorized = false
```

Automatic writes are therefore not enabled merely by installing v0.8.0.

## Modes

Supported requested modes:

```text
AUTO_DRY_RUN
AUTO_EXECUTE
```

`AUTO_EXECUTE` becomes the effective mode only when all three config conditions are true:

1. `mode = AUTO_EXECUTE`
2. `allowAutomaticWrites = true`
3. exact safety acknowledgement is present

Use the provided setter instead of editing JSON manually.

Dry-run:

```powershell
.\Integration\Set-NormalizationWorkerMode.ps1 -Mode AUTO_DRY_RUN
```

Automatic execution:

```powershell
.\Integration\Set-NormalizationWorkerMode.ps1 `
    -Mode AUTO_EXECUTE `
    -EnableAutomaticWrites
```

Inspect the effective state:

```powershell
.\Integration\Get-NormalizationWorkerMode.ps1
```

The live config is intentionally excluded from upgrade ZIPs.

## Execute-mode lifecycle

Every `AUTO_EXECUTE` job still receives an executor dry-run first:

```text
QUEUED
  ↓
PREFLIGHT
  ↓
executor DRY_RUN
  ↓
must return DRY_RUN_READY
  ↓
re-read automatic-write gate
  ↓
RUNNING
  ↓
executor -Execute
  ↓
SUCCESS
  | BLOCKED
  | NORMALIZED_RECONCILIATION_FAILED
  | ROLLED_BACK
  | ROLLBACK_FAILED
  | FAILED
```

The executor itself repeats all source, fingerprint, finding, Arr, track-mapping, and free-space checks immediately before writing.

Backups remain retained. v0.8.0 never passes `-DeleteBackupOnSuccess`.

## Mode is part of job identity

A historical `AUTO_DRY_RUN` result does not suppress a future `AUTO_EXECUTE` job for the same unchanged media.

This makes it possible to prove a plan in dry-run mode and later receive a distinct execute-mode job.

## Gate is checked again immediately before write launch

An execute-mode job does not rely only on the configuration that existed when it was enqueued.

Immediately after its successful dry-run preflight, the worker reloads the config.

If automatic writes were disabled in the meantime, the job ends:

```text
BLOCKED
reason = auto_execute_gate_not_currently_enabled
```

No write subprocess is launched.

## Execute crash recovery

Dry-run recovery remains automatically retryable.

Execute-mode recovery is more conservative:

- interruption before write launch → safe to requeue
- interruption after write launch + complete executor result → finalize from that result
- interruption after write launch without a complete result → `RECOVERY_REQUIRED`

The worker never blindly reruns an execute job after writes may have begun.

## Tests

Run:

```powershell
.\Integration\Test-NormalizationQueue.ps1
.\Integration\Test-NormalizationWorkerPersistence.ps1
.\Integration\Test-AutomaticNormalizationGate.ps1
.\Integration\Test-AutomaticExecuteRecovery.ps1
```

Expected:

```text
PASS: 5/5 normalization queue tests passed.
PASS: 4/4 worker persistence regression tests passed.
PASS: 6/6 automatic normalization gate tests passed.
PASS: 4/4 automatic execute recovery policy tests passed.
```

## Recommended validation sequence

Do not enable writes immediately after installation.

1. install v0.8.0
2. confirm effective mode is `AUTO_DRY_RUN`
3. run all tests
4. replay or wait for a real `PLANNED` event and confirm dry-run behavior is unchanged
5. explicitly switch to `AUTO_EXECUTE`
6. use one controlled normalization candidate
7. verify the resulting queue job reaches `SUCCESS`
8. switch back to `AUTO_DRY_RUN` while reviewing the first automatic write

Backup cleanup remains separate and manual under Phase 5C.
