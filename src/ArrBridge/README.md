# Integration runtime

This directory is the production runtime surface for Arr Media Pipeline v0.9.29.13.

## Automatic production entry points

- `RadarrValidator.cmd` -> `ReqestraArrBridge.ps1 -Source Radarr`
- `SonarrValidator.cmd` -> `ReqestraArrBridge.ps1 -Source Sonarr`

Every normal import/upgrade is intended to flow through the same coordinator:

`Arr import -> validate -> PASS / NORMALIZE / REACQUIRE / REVIEW -> remediate -> validate again`

## Production components

- `ReqestraArrBridge.ps1` — event normalization, validator/context/planner coordination, queue handoff.
- `NormalizationPlanner.ps1`, `Invoke-Normalization.ps1`, `NormalizationWorker.ps1` — safe local remediation.
- `ReacquisitionPlanner.ps1`, `Invoke-Reacquisition.ps1`, `ReacquisitionWorker.ps1` — bad-release replacement, retry chain, and terminal-DV routing.
- `Complete-*`, `Initialize-*`, `Invoke-*Retry`, `Invoke-*Quarantine`, and `*Common.ps1` — transaction/chain support.

## Runtime/state directories

These are intentionally preserved by upgrades but are not release code:

- `Audit/`
- `Inventory/`
- `Maintenance/`
- `Queue/`
- `Reacquisition/`
- `ReacquisitionQueue/`
- `logs/`

## Operator/admin tools

Human-invoked tools live under `Tools/`. The one-time existing-library entry point is:

```powershell
.\Integration\Tools\Invoke-LibraryRemediation.ps1 -Library Movies
.\Integration\Tools\Invoke-LibraryRemediation.ps1 -Library TV
```

The command feeds existing files through the same bridge and workers used by future Arr imports. It is resumable after interruption and does not contain a separate remediation policy.

After a completed run, use `-RetryActionable` to re-submit only the previous run's non-PASS actionable items (`NORMALIZE`, `REACQUIRE`, or `REVIEW`) after a policy/runtime fix, instead of rescanning the whole library:

```powershell
.\Integration\Tools\Invoke-LibraryRemediation.ps1 -Library Movies -RetryActionable
```

Development tests live under `Development/Tests` and are not required in the production Integration root.
