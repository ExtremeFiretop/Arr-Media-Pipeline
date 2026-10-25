# Queue and Recovery

The persistent queue moves normalization work out of the Radarr/Sonarr Connect callback.

Current queue version: **0.2.0**

## Runtime structure

```text
Integration\Queue\
├─ pending\
├─ running\
├─ history\
├─ results\
├─ logs\
└─ queue.jsonl
```

These are runtime artifacts and should not be committed or packaged into a clean release.

## Deterministic job identity

A job ID is derived from evidence including:

- queue mode
- media path
- source file length
- source timestamp
- stream fingerprint
- planned finding codes
- exact normalization actions

Equivalent unchanged work is therefore suppressed.

`AUTO_DRY_RUN` and `AUTO_EXECUTE` are intentionally different identities, so a proven historical dry-run does not suppress a later explicitly authorized execute-mode job.

## Worker

`NormalizationWorker.ps1`

Only one worker is active at a time through:

```text
ReqestraNormalizationWorker
```

Multiple Arr events may attempt to start workers; only one claims the worker mutex.

## Modes

### AUTO_DRY_RUN

Default/fail-closed behavior.

The worker runs the guarded executor without `-Execute`.

Successful safe preflight ends:

```text
DRY_RUN_READY
```

### AUTO_EXECUTE

Requires all configured write gates.

The worker first runs the same dry-run preflight.

Only after:

```text
preflight = DRY_RUN_READY
```

does it re-read the live worker configuration.

If writes are no longer authorized, the job is blocked without launching the write subprocess.

## Fail-closed configuration

Missing or invalid configuration produces:

```text
effectiveMode = AUTO_DRY_RUN
automaticWritesAuthorized = false
```

Inspect:

```powershell
.\Integration\Get-NormalizationWorkerMode.ps1
```

Enable explicitly:

```powershell
.\Integration\Set-NormalizationWorkerMode.ps1 `
    -Mode AUTO_EXECUTE `
    -EnableAutomaticWrites
```

Disable:

```powershell
.\Integration\Set-NormalizationWorkerMode.ps1 `
    -Mode AUTO_DRY_RUN
```

## Queue states

Common states include:

```text
QUEUED
PREFLIGHT
RUNNING
DRY_RUN_READY
SUCCESS
BLOCKED
FAILED
NORMALIZED_RECONCILIATION_FAILED
ROLLED_BACK
ROLLBACK_FAILED
RECOVERY_REQUIRED
```

## Dry-run crash recovery

A dry-run job is safe to replay because it has not been authorized to mutate media.

An abandoned `running` dry-run job can be moved back to `pending` on worker startup.

## Execute-mode crash recovery

Execute jobs use stricter rules.

### Interruption before write launch

Safe to requeue.

### Interruption after write launch with a complete executor result

Finalize the job from the recorded executor result.

### Interruption after write launch without a complete result

Do not replay blindly.

Final state:

```text
RECOVERY_REQUIRED
```

This prevents duplicate or unknown media mutation after a process crash.

## Result persistence

Per-job artifacts include:

- executor JSON
- stdout
- stderr
- process exit code
- worker version
- attempt count
- recovery count

These are retained in queue history/results for troubleshooting and audit.

## Queue status

```powershell
.\Integration\Get-NormalizationQueueStatus.ps1
```

This displays:

- requested/effective mode
- write authorization
- pending count
- running count
- history count
- recent terminal jobs

## Proven recovery behavior

The queue has recovered a real abandoned dry-run job after an earlier worker persistence failure.

That incident drove the schema-safe job-property handling used by the current worker.
