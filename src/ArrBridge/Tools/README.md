# Operator and diagnostic tools

These scripts are intentionally separated from production import/runtime logic.

## Whole-library remediation

`Invoke-LibraryRemediation.ps1` is the supported one-time operator entry point for existing media:

```powershell
.\Integration\Tools\Invoke-LibraryRemediation.ps1 -Library Movies
.\Integration\Tools\Invoke-LibraryRemediation.ps1 -Library TV
.\Integration\Tools\Invoke-LibraryRemediation.ps1 -Library Both
```

It reconstructs Radarr/Sonarr context and feeds every existing Arr-owned file through `ReqestraArrBridge.ps1`, so the same production normalization/reacquisition logic is used. Progress is checkpointed under `Integration\Audit\library-remediation`; rerunning the same command resumes an incomplete run. Use `-Fresh` only when you intentionally want a new scan.

`-MovieId`, `-SeriesId`, and `-MaxItems` are diagnostic/development filters, not part of the normal operator workflow.

## Other tools

- `Invoke-CanonicalLibraryAudit.ps1` — read-only canonical audit.
- `Invoke-NormalizationPlanningAudit.ps1` / `Invoke-NormalizationPlannedBatch.ps1` — normalization diagnostics and controlled batch testing.
- `Get-*QueueStatus.ps1` — queue diagnostics.
- `Get-*WorkerMode.ps1` / `Set-*WorkerMode.ps1` — explicit worker-mode administration.
- `Get-ReacquisitionReleaseSelection.ps1` — reacquisition release-selection diagnostics.

These tools are for inspection, testing, recovery, or explicit administration; normal new imports should require no manual action.
