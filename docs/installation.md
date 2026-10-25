# Installation

## Source layout vs runtime layout

The Git repository is organized for development:

```text
src\
├─ MediaValidator\
└─ ArrBridge\
```

The scripts are not intended to run directly from that layout because the tested runtime paths expect:

```text
MediaValidator\
├─ MediaValidator.ps1
├─ validator-policy.json
└─ Integration\
   └─ ReqestraArrBridge.ps1
```

Build a release before deployment.

## Requirements

- Windows
- Windows PowerShell 5.1+ or PowerShell 7+
- `ffprobe`
- MKVToolNix / `mkvmerge`
- Radarr API v3
- Sonarr API v3
- file-system permissions for the media libraries
- sufficient free space for same-directory temporary remuxes

## Build a release

From the repository root:

```powershell
.\scripts\Build-Release.ps1 -Version 0.8.0
```

Expected output:

```text
dist\
├─ Arr-Media-Pipeline-v0.8.0\
└─ Arr-Media-Pipeline-v0.8.0.zip
```

Regression tests are development assets and are excluded from the normal production release unless explicitly requested by the build script.

## Install

Extract the release package and run:

```powershell
.\Install.ps1
```

Default destination:

```text
C:\Program Files\MKVToolNix\Custom Scripts\MediaValidator
```

Custom destination:

```powershell
.\Install.ps1 -Destination "D:\MediaValidator"
```

## Upgrade behavior

The installer may replace application code, but it must preserve machine-local state.

Protected live files:

```text
Integration\integration-config.json
Integration\normalization-worker-config.json
Integration\maintenance-config.json
```

Protected runtime directories:

```text
Integration\Queue\
Integration\Maintenance\
Integration\logs\
```

These should never be supplied as live values in a public release archive.

## Configure Arr API access

Start from:

```text
config\integration-config.example.json
```

Create the live runtime file:

```text
Integration\integration-config.json
```

The current integration uses local/base URLs and API keys for Radarr and Sonarr.

Do not commit this live file.

## Configure worker mode

The safest default is no live worker config at all.

With no config:

```text
requestedMode = AUTO_DRY_RUN
effectiveMode = AUTO_DRY_RUN
automaticWritesAuthorized = false
```

Inspect:

```powershell
.\Integration\Get-NormalizationWorkerMode.ps1
```

Explicitly configure dry-run:

```powershell
.\Integration\Set-NormalizationWorkerMode.ps1 `
    -Mode AUTO_DRY_RUN
```

Enable automatic execution only after validation:

```powershell
.\Integration\Set-NormalizationWorkerMode.ps1 `
    -Mode AUTO_EXECUTE `
    -EnableAutomaticWrites
```

## Radarr / Sonarr Connect integration

The runtime provides:

```text
Integration\RadarrValidator.cmd
Integration\SonarrValidator.cmd
```

These wrappers invoke the Arr Bridge with the appropriate source context.

Configure the corresponding Arr Connect/custom-script event to invoke the correct wrapper for imported media.

The bridge always treats queue/validation automation as non-blocking relative to the original Arr import. A queue failure should not turn an otherwise completed media import into an Arr import failure.

## Verify the installation

Check worker mode:

```powershell
.\Integration\Get-NormalizationWorkerMode.ps1
```

Check queue:

```powershell
.\Integration\Get-NormalizationQueueStatus.ps1
```

Check maintenance history:

```powershell
.\Integration\Get-MediaMaintenanceStatus.ps1
```

## Development tests

Tests live in the source repository under:

```text
tests\
```

They are useful for release validation but do not need to remain on the production host.

## Git hygiene

Never commit:

```text
integration-config.json
normalization-worker-config.json
maintenance-config.json
Queue\
Maintenance\
logs\
*.reqestra-*.tmp
*.reqestra-backup-*.bak
```

Commit only sanitized example configuration files.
