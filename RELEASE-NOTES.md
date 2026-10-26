# Arr Media Pipeline v0.9.29.10 — Clean Full Release

This release consolidates the active v0.9.29.x line into a full installable tree. It is not a hotfix installer.

## Canonical automation model

`Arr import -> validate actual media -> PASS / NORMALIZE / REACQUIRE / REVIEW -> remediate -> validate again -> Plex`

NORMALIZE is no longer a dead end when the normalization planner cannot safely act:

1. If normalization is safely planned, the normalization worker performs the local metadata/header fix.
2. If normalization is structurally not safe/actionable (`multiple_preferred_audio_candidates`, `ambiguous_default_audio_target`, `preferred_audio_candidate_missing`, or `container_not_supported`), the bridge automatically promotes the disposition to REACQUIRE.
3. The reacquisition pipeline uses the existing exact-release failure/blocklist, quarantine, smarter replacement search, and validation chain.
4. Replacement failures retry up to the existing three-attempt ceiling.
5. During an active reacquisition chain, a replacement that only needs a safe local normalization is normalized by the reacquisition worker itself; if it reaches PASS, the chain is completed and rollback is retired automatically.
6. Terminal Dolby Vision remediation remains the final fallback when the existing three-attempt chain reaches its terminal condition and the configured safety gates authorize local DV remediation.
7. Unknown/unclassified normalization failures still fail closed to REVIEW rather than deleting media.

There is no operator-specific NORMALIZE->REACQUIRE override in this release.

## Existing-library automation

`Integration/Invoke-RadarrRemediationSweep.ps1` feeds existing Radarr movie files back through the same bridge and worker pipeline used by new imports. It does not contain a second remediation implementation. The daily safety sweep can be installed by the clean installer.

## Queue behavior

Normalization and reacquisition workers now drain their queues by default. `-MaxJobs` remains available only as an optional admin/test limit.

## Runtime cleanup

The production `Integration` root contains runtime scripts only. Admin/audit commands are under `Integration/Tools`. Tests are under `Development/Tests` and are not installed unless `-IncludeDevelopmentAssets` is requested. `Apply-*.ps1`, `Test-*.ps1`, and `Payload` hotfix debris are moved to the release backup by the clean installer.

## Included active fixes

- MediaValidator 0.2.8 UTF-8 ffprobe decoding.
- NormalizationPlanner 0.2.3 profile-aware conservative preferred-language selection.
- Planned batch runner 0.1.1 profile-aware rebuild safety.
- Normalization executor 0.2.3 `mkvpropedit` metadata-only fast path.
- Automatic NORMALIZE -> REACQUIRE disposition when local normalization is not safely actionable.
- Active-chain local normalization and automatic success finalization.
- Existing-library Radarr remediation sweep.
- Queue-drain behavior for backlog processing.

## Installation

`Install-CleanRelease.ps1` backs up replaced runtime files, preserves state/config/audit/queue directories and the active validator policy, and removes hotfix/test debris from the production root.

Optional installer switches provide one-time go-live authorization:

- `-EnableAutomaticRemediation`
- `-EnableTerminalDvRemediation`
- `-EnableFelResidualDiscard`
- `-InstallDailySafetySweep`

Without those switches, existing production authorization settings are preserved unchanged.
