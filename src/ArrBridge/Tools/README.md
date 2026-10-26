# Integration runtime

This directory is the production runtime surface for Arr Media Pipeline v0.9.29.10.

## Production flow

- `ReqestraArrBridge.ps1` — Radarr/Sonarr import entrypoint and remediation disposition coordinator.
- `NormalizationPlanner.ps1` + `Invoke-Normalization.ps1` + `NormalizationWorker.ps1` — safe local metadata/header remediation.
- `ReacquisitionPlanner.ps1` + `Invoke-Reacquisition.ps1` + `ReacquisitionWorker.ps1` — exact bad-release failure/blocklist, quarantine, replacement search, retry chain, and terminal DV routing.
- `Invoke-RadarrRemediationSweep.ps1` — existing-library safety-net sweep through the same coordinator.
- `Complete-*`, `Initialize-*`, `Invoke-*Retry`, `Invoke-*Quarantine`, and `*Common.ps1` — transaction/chain support modules.

## Non-runtime material

Admin and audit commands live in `Tools`. Tests live outside Integration under `Development/Tests` in the release package and are optional at install time.

No `Apply-*` hotfix scripts or `Payload` directory are required by this release.
