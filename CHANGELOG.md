# Changelog

All notable changes to **Arr Media Pipeline** are documented here.

The project is pre-1.0; version numbers currently track major backend milestones rather than a stable public API.

## [0.8.0] - 2026-10-25

### Added

- `AUTO_DRY_RUN` and explicitly gated `AUTO_EXECUTE` worker modes.
- Separate automatic-write authorization.
- Safety acknowledgement requirement for automatic writes.
- Full executor dry-run preflight before automatic execution.
- Worker-mode configuration is re-read immediately before write launch.
- Queue mode included in deterministic job identity.
- `RECOVERY_REQUIRED` handling for interrupted execute-mode jobs.
- Worker mode inspection and control scripts.

### Validated

- First unattended Sonarr normalization completed successfully.
- Dry-run preflight returned `DRY_RUN_READY`.
- MKV normalization completed without transcoding.
- Final validation returned `PASS`.
- Backup was retained.
- Sonarr `RescanSeries` completed.
- Sonarr path and size matched the final file.
- Worker was returned to `AUTO_DRY_RUN` after validation.

### Remaining validation

- One real Radarr `AUTO_EXECUTE` queue job remains to validate the complete automatic Radarr path.

## [0.7.1] - 2026-10-25

### Fixed

- Maintenance now reads mixed historical execution schemas safely.
- Missing historical `arrReconciliation` no longer causes a StrictMode failure.
- Historical backups without recorded reconciliation are conservatively retained.

## [0.7.0] - 2026-10-25

### Added

- Backup-retention policy.
- Abandoned ordinary-temp cleanup.
- Fresh media revalidation before backup deletion.
- Current Arr path/size verification before backup deletion.
- Maintenance reports and deletion audit log.
- Normalization/maintenance concurrency protection.

### Safety

- Backup cleanup is dry-run by default.
- Failed replacement artifacts are never automatically deleted.
- Default backup retention is seven days.
- Default ordinary temp retention is 24 hours.

## [0.6.1] - 2026-10-25

### Fixed

- Queue worker persistence for deserialized PowerShell objects.
- Older queue schema compatibility.
- Crash-recovery bookkeeping.

### Validated

- Real interrupted queue job recovered from `running`.
- Recovered job completed `DRY_RUN_READY`.

## [0.6.0] - 2026-10-25

### Added

- Persistent normalization queue.
- `pending`, `running`, `history`, `results`, and queue logs.
- Independent background worker.
- Single-worker mutex.
- Deterministic duplicate suppression.
- Automatic dry-run normalization preflight.
- Abandoned dry-run job recovery.

## [0.5.2] - 2026-10-25

### Added

- Sonarr `RescanSeries` reconciliation.
- Radarr `RescanMovie` reconciliation.
- Post-rescan path/size validation.

### Validated

- Real Sonarr normalization and reconciliation.
- Real Radarr normalization and reconciliation.

## [0.5.0] - 2026-10-25

### Added

- Guarded manual normalization executor.
- Source snapshot checks.
- Stream fingerprint verification.
- MKVToolNix track mapping verification.
- Free-space checks.
- Same-directory temporary remux.
- Temporary output validation.
- Atomic `System.IO.File.Replace`.
- Retained backups.
- Rollback behavior.
- Timestamp restoration.

## [0.4.2] - 2026-10-25

### Fixed

- Bridge-to-planner contextual result handoff.

## [0.4.0] - 2026-10-25

### Added

- Conservative normalization planner.
- Explicit default-track actions.
- Ambiguity blocking.
- Planned finding codes and source snapshot.

## [0.3.x] - 2026-10-25

### Added

- Context-aware validation layer.
- Sonarr English, French, and Original Language handling.
- Preferred-language default-track checks.
- Combined generic/contextual effective outcome.

## [0.2.x] - 2026-10-25

### Added

- Arr API enrichment.
- Quality-profile lookup.
- Generic validator stabilization.
- Read-only directory audit mode.
- Legacy processor fingerprinting.
- Auxiliary-video filtering.

### Frozen classifier

The generic media validator was frozen at **v0.2.6** after real movie/TV audit validation.
