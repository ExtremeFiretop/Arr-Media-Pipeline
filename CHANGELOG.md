# Changelog

All notable changes to **Arr Media Pipeline** are documented here.

## [0.8.0] - 2026-10-25

### Added
- Gated automatic normalization with `AUTO_DRY_RUN` and `AUTO_EXECUTE`.
- Explicit automatic-write authorization.
- Dry-run preflight before automatic writes.
- Gate recheck immediately before execution.
- Mode-specific queue identities.
- Conservative execute crash recovery with `RECOVERY_REQUIRED`.
- Worker-mode inspection/control scripts.
- Automatic Sonarr normalization validated end-to-end.

### Existing capabilities
- ffprobe-based media validation.
- Sonarr/Radarr context enrichment.
- Safe normalization planning.
- Guarded MKV remux without transcoding.
- Atomic replacement, rollback, and retained backups.
- Sonarr/Radarr reconciliation.
- Persistent queue with duplicate suppression/recovery.
- Backup retention and safe temp cleanup.

### Safety
Automatic writes remain disabled unless explicitly enabled. Missing or invalid worker configuration fails closed to `AUTO_DRY_RUN`.
