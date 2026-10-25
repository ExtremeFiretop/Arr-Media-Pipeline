# Arr Media Pipeline

Policy-driven media validation, normalization, reconciliation, and lifecycle automation for **Radarr, Sonarr, Plex, and Reqestra**.

> **Status:** pre-1.0. Validation, normalization, queueing, reconciliation, and retention are operational. Controlled reacquisition and broader lifecycle automation are still being developed.

## Repository layout

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

The Git layout is intentionally different from the tested deployment layout.

## Runtime layout

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

Use the build script to transform the repository source tree into that layout.

## Build

From the repository root:

```powershell
.\scripts\Build-Release.ps1 -Version 0.8.0
```

Output:

```text
dist\Arr-Media-Pipeline-v0.8.0\
dist\Arr-Media-Pipeline-v0.8.0.zip
```

Regression tests are excluded from production releases by default. To include them:

```powershell
.\scripts\Build-Release.ps1 -Version 0.8.0 -IncludeTests
```

## Install

Extract a release and run:

```powershell
.\Install.ps1
```

Default destination:

```text
C:\Program Files\MKVToolNix\Custom Scripts\MediaValidator
```

Or:

```powershell
.\Install.ps1 -Destination "D:\MediaValidator"
```

Upgrades preserve live configuration and runtime state:

```text
Integration\integration-config.json
Integration\normalization-worker-config.json
Integration\maintenance-config.json
Integration\Queue\
Integration\Maintenance\
Integration\logs\
```

## Requirements

- Windows / PowerShell 5.1+
- `ffprobe`
- MKVToolNix / `mkvmerge`
- Radarr v3 API
- Sonarr v3 API

## Configuration

Public examples live under `config/`. Never commit real API keys.

Automatic normalization fails closed to dry-run unless explicitly authorized.

```powershell
.\Integration\Get-NormalizationWorkerMode.ps1

.\Integration\Set-NormalizationWorkerMode.ps1 `
    -Mode AUTO_EXECUTE `
    -EnableAutomaticWrites

.\Integration\Set-NormalizationWorkerMode.ps1 `
    -Mode AUTO_DRY_RUN
```

## Tests

Development/regression tests live under `tests/` and are not required in the normal production deployment.

## Documentation

- `docs/README-MediaValidator.md`
- `docs/README-Bridge.md`

## Safety principles

- acquire the right master before repairing
- do not recompress acceptable video unnecessarily
- preserve premium audio and subtitles
- use actual stream metadata as authoritative
- block ambiguous normalization plans
- validate media before and after replacement
- retain backups
- fail closed for automatic writes
- never blindly replay interrupted write jobs

## License

See `LICENSE`.
