# Normalization

Normalization is reserved for media that is fundamentally acceptable but has safely correctable metadata/track-default problems.

It is not a transcoding subsystem.

## Supported normalization findings

Current planner support includes:

- `audio.no_default`
- `audio.multiple_defaults`
- `audio.commentary_default`
- preferred-language-not-default findings
- contextual `language.preferred_not_default`

## Planner

`NormalizationPlanner.ps1` is read-only.

It converts findings into explicit actions such as:

```text
set_audio_default_flag
```

Example:

```text
French audio:  default true  -> false
English audio: default false -> true
```

## Conservative candidate selection

When a preferred language is known:

```text
exactly one non-commentary candidate -> plan
multiple matching candidates         -> BLOCKED
no matching candidate                -> BLOCKED
```

Without an explicit preferred language, the planner only proceeds when the intended default can be determined safely.

Ambiguity is blocked rather than guessed.

## Source snapshot

A plan records evidence about the media at planning time, including:

- file length
- `LastWriteTimeUtc`
- structural stream fingerprint
- planned finding codes
- exact actions

The executor requires the source to still match this snapshot.

## Executor

`Invoke-Normalization.ps1`

Default mode:

```text
DRY_RUN
```

Actual mutation requires:

```powershell
-Execute
```

## Preflight checks

Before a write, the executor verifies:

- plan status is `PLANNED`
- source is MKV
- source file still exists
- source length matches
- source timestamp matches
- stream fingerprint matches
- planned findings still exist
- action type is allowlisted
- source track state still matches `from`
- language/commentary metadata still matches
- MKVToolNix track mapping agrees with ffprobe mapping
- current Arr record points to the same file
- current Arr size matches disk
- enough free space exists
- normalization mutex can be acquired

## Mutation

The executor uses `mkvmerge` to write a same-directory temporary file.

It does not intentionally transcode video or audio.

The temporary file uses a non-media extension so Radarr, Sonarr, Plex, and library scanners are less likely to treat it as a second library item.

## Temporary validation

Before replacement, the temporary output must satisfy:

- expected stream structure remains intact
- target finding is gone
- effective outcome does not worsen
- validation is acceptable

A failed temporary validation prevents replacement.

## Atomic replacement

Replacement uses:

```text
System.IO.File.Replace
```

The original media becomes a retained backup.

The executor restores the original creation and last-write timestamps after replacement.

## Final validation

The final path is validated again after replacement.

If final media validation fails, rollback behavior is available using the retained backup.

## Arr reconciliation

A successful media mutation is followed by Arr reconciliation.

### Sonarr

```text
RescanSeries
```

Then the executor re-reads the episode file and requires:

```text
Arr path == actual path
Arr size == actual size
```

### Radarr

```text
RescanMovie
```

Then the executor re-reads the movie file and requires the same path/size agreement.

## Reconciliation failure

If the media itself normalized successfully but Arr bookkeeping fails:

```text
NORMALIZED_RECONCILIATION_FAILED
```

The valid normalized media is not automatically rolled back merely because the API/database reconciliation step failed.

The backup remains available.

## Backups

Automatic queue execution does not request immediate backup deletion.

Retention is handled separately by the maintenance subsystem.

See [Maintenance](maintenance.md).

## Real validation status

The guarded executor has been proven manually with both Sonarr and Radarr.

The complete automatic execute path has been proven with Sonarr.

One real Radarr `AUTO_EXECUTE` queue run remains before automatic execution is considered fully validated for both applications.
