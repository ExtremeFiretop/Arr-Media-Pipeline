# Arr Media Pipeline Documentation

This directory documents the current behavior of the project. Historical implementation notes belong in the root [`CHANGELOG.md`](../CHANGELOG.md).

## Start here

- [Architecture](architecture.md) — components, boundaries, and end-to-end flow
- [Installation](installation.md) — source layout, release layout, deployment, configuration
- [Media Validator](media-validator.md) — generic classifier, outcomes, audit mode
- [Arr Bridge](arr-bridge.md) — Radarr/Sonarr events, contextual validation, event artifacts
- [Normalization](normalization.md) — planner, executor, atomic replacement, reconciliation
- [Queue and Recovery](queue-and-recovery.md) — queue states, automatic modes, crash recovery
- [Maintenance](maintenance.md) — backup retention and safe temp cleanup

## Documentation principle

The documentation describes the **current system**, not the chronological history of how it was built.

Use [`CHANGELOG.md`](../CHANGELOG.md) for version history and migration notes.
