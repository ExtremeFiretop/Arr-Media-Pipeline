# Arr Media Pipeline

Policy-driven media validation, normalization, reconciliation, and lifecycle automation for **Radarr, Sonarr, Plex, and Reqestra**.

> **Project status:** pre-1.0. Validation, context-aware planning, guarded normalization, queueing, reconciliation, backup retention, and gated automatic execution are implemented. Controlled reacquisition, deeper corruption analysis, subtitle lifecycle automation, and broader observability are still in development.

## Why this exists

Traditional media automation mostly stops after Radarr or Sonarr imports a release. Arr Media Pipeline adds a validation and correction layer after import so decisions are based on the **actual media streams that arrived**, not only release names or indexer metadata.

The core philosophy is:

> Acquire the right master, validate what actually arrived, preserve quality, correct cheap metadata problems, reacquire genuinely bad sources, and let Plex handle client-specific adaptation.

The project intentionally avoids mass transcoding and avoids permanently degrading a good master just to satisfy one weak playback client.

## Current capabilities

- Generic `ffprobe`-based media validation
- `PASS`, `NORMALIZE`, `REVIEW`, and `REACQUIRE` classifications
- Sonarr/Radarr-aware validation context
- Sonarr language-profile validation
- Safe normalization planning
- MKV default-track normalization without video/audio transcoding
- Source snapshot and stream-fingerprint protection
- Temporary-output validation before replacement
- Atomic replacement with retained backups
- Sonarr `RescanSeries` reconciliation
- Radarr `RescanMovie` reconciliation
- Persistent normalization queue
- Deterministic duplicate suppression
- Worker crash recovery
- Fail-closed `AUTO_DRY_RUN`
- Explicitly gated `AUTO_EXECUTE`
- Backup retention and abandoned-temp cleanup
- Structured event, queue, execution, and maintenance logs

## Architecture

```text
Reqestra
   |
Radarr / Sonarr
   |
Download client
   |
Arr import
   |
   +--> Media Validator
   |      |
   |      +--> PASS
   |      +--> NORMALIZE
   |      +--> REVIEW
   |      +--> REACQUIRE
   |
   +--> Arr Bridge context
          |
          +--> Context Validator
          |
          +--> Normalization Planner
                  |
                  +--> Persistent Queue
                         |
                         +--> DRY-RUN preflight
                         |
                         +--> optional gated AUTO_EXECUTE
                                  |
                                  +--> MKV remux
                                  +--> temp validation
                                  +--> atomic replacement
                                  +--> final validation
                                  +--> Arr reconciliation
                                  +--> retained backup
```

See [Architecture](docs/architecture.md) for the complete component and data-flow description.

## Repository layout

The repository is organized for development:

```text
Arr-Media-Pipeline/
├─ src/
│  ├─ MediaValidator/
│  └─ ArrBridge/
├─ config/
├─ tests/
├─ docs/
├─ scripts/
├─ README.md
├─ CHANGELOG.md
└─ LICENSE
```

The tested deployment layout is intentionally different:

```text
MediaValidator/
├─ MediaValidator.ps1
├─ validator-policy.json
└─ Integration/
   ├─ ReqestraArrBridge.ps1
   ├─ ContextValidator.ps1
   ├─ NormalizationPlanner.ps1
   ├─ Invoke-Normalization.ps1
   ├─ NormalizationWorker.ps1
   ├─ QueueCommon.ps1
   ├─ MaintenanceCommon.ps1
   ├─ RadarrValidator.cmd
   ├─ SonarrValidator.cmd
   └─ ...
```

Use the release/build tooling to transform the source tree into the runtime layout rather than running `src/ArrBridge` directly.

## Requirements

Current tested deployment:

- Windows
- Windows PowerShell 5.1+ or PowerShell 7+
- `ffprobe`
- MKVToolNix / `mkvmerge`
- Radarr API v3
- Sonarr API v3
- read/write access to the media libraries for normalization
- enough temporary free space to remux a candidate safely

Plex is not required for the validator itself, but it is part of the intended downstream media workflow.

## Installation

See [Installation](docs/installation.md).

At a high level:

```powershell
.\scripts\Build-Release.ps1 -Version 0.8.0
```

Then extract the resulting release and run:

```powershell
.\Install.ps1
```

The current tested destination is:

```text
C:\Program Files\MKVToolNix\Custom Scripts\MediaValidator
```

## Automatic write safety

Automatic media mutation is **off by default**.

Missing, invalid, or incomplete worker configuration fails closed to:

```text
effectiveMode = AUTO_DRY_RUN
automaticWritesAuthorized = false
```

Enabling automatic writes requires an explicit mode change and write authorization:

```powershell
.\Integration\Set-NormalizationWorkerMode.ps1 `
    -Mode AUTO_EXECUTE `
    -EnableAutomaticWrites
```

Every execute-mode job still receives a complete dry-run preflight before a write can begin.

See [Queue and Recovery](docs/queue-and-recovery.md) and [Normalization](docs/normalization.md).

## Media policy

Current high-level policy:

- Dolby Vision: prohibited
- AV1: prohibited
- VVC/H.266: prohibited
- HDR10: preferred canonical HDR format
- SDR: accepted
- HDR10+: accepted
- premium audio: preserved
- commentary: preserved but should not become default
- subtitles: must not be incidentally removed
- acceptable video: do not recompress unnecessarily
- MKV: preferred normalization target
- ambiguous normalization: block rather than guess

See [Media Validator](docs/media-validator.md) for classifier behavior.

## Documentation

- [Documentation index](docs/README.md)
- [Architecture](docs/architecture.md)
- [Installation](docs/installation.md)
- [Media Validator](docs/media-validator.md)
- [Arr Bridge](docs/arr-bridge.md)
- [Normalization](docs/normalization.md)
- [Queue and Recovery](docs/queue-and-recovery.md)
- [Maintenance](docs/maintenance.md)
- [Changelog](CHANGELOG.md)

## Development tests

Regression tests live under:

```text
tests/
```

They are development assets and are not required in a normal production deployment.

## Current validation status

The normalization path has been proven end-to-end with real Sonarr media, including automatic execution, final validation, retained backup, and Sonarr reconciliation.

The Radarr reconciliation path has been proven manually. One real Radarr `AUTO_EXECUTE` queue run remains before the automatic normalization subsystem is considered fully validated end-to-end for both Arr applications.

## License

See [LICENSE](LICENSE).
