# Media Validator

Current generic classifier: **v0.2.6**

`MediaValidator.ps1` is the generic, read-only inspection engine used by Arr Media Pipeline.

## Safety boundary

The validator does not:

- rename media
- edit metadata
- remux media
- transcode media
- delete media
- call Radarr/Sonarr APIs
- blocklist releases
- reacquire media
- modify Plex

It reads media with `ffprobe` and writes structured results.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- `ffprobe` in `PATH`, or an explicit `-FfprobePath`

## Outcomes

| Outcome | Meaning | Exit code |
| --- | --- | ---: |
| `PASS` | Acceptable under current generic policy | 0 |
| `NORMALIZE` | Safe metadata-level correction is possible | 10 |
| `REVIEW` | Ambiguous or suspicious; do not automate | 20 |
| `REACQUIRE` | Master is unacceptable/incomplete | 30 |

Use `-ExitZero` when the caller must never fail because of the classification.

## Current policy

### REACQUIRE

- Dolby Vision
- AV1
- VVC/H.266
- missing audio

### NORMALIZE

- commentary audio marked default
- no default audio
- multiple default audio streams
- preferred-language audio exists but is not default when `-PreferredLanguage` is explicitly supplied

### REVIEW

- ffprobe failure
- invalid ffprobe JSON
- probe diagnostic errors
- multiple real playable video streams
- unknown video codec

### INFO

- preferred language missing
- image-only subtitle situation
- unusually low resolution

INFO findings do not independently raise the policy outcome.

## Auxiliary video handling

Image/artwork streams are intentionally separated from real playable video.

Examples that may be classified as auxiliary:

- `attached_pic`
- non-default PNG
- sparse image-like streams with no meaningful average frame rate
- image-like streams with implausibly high nominal frame-rate metadata

These remain visible in result data but do not automatically trigger `video.multiple`.

A genuine second H.264/H.265 motion-video stream still produces `REVIEW / video.multiple`.

## Single-file mode

```powershell
.\MediaValidator.ps1 `
    "M:\Movies\Example (2026)\Example.mkv" `
    -LibraryType Movie
```

Optional explicit preferred language:

```powershell
.\MediaValidator.ps1 `
    "V:\TV Shows\Example\Example S01E01.mkv" `
    -LibraryType TV `
    -PreferredLanguage eng
```

## Directory audit mode

Passing a directory enables recursive read-only audit mode.

Movies:

```powershell
.\MediaValidator.ps1 "M:\Movies" -LibraryType Movie
```

TV:

```powershell
.\MediaValidator.ps1 "V:\TV Shows" -LibraryType TV
```

Small test:

```powershell
.\MediaValidator.ps1 "M:\Movies" -LibraryType Movie -MaxFiles 25
```

Audit mode exits 0 after a completed scan regardless of classification counts.

## Mixed-language library warning

Do not apply one global `-PreferredLanguage` to a library containing multiple intentional Sonarr language profiles.

Generic directory audits should normally omit preferred language and let the Arr contextual layer decide language intent during real import events.

## Audit output

Typical audit output:

```text
audit-YYYYMMDD-HHMMSS\
├─ results.jsonl
├─ results.csv
├─ findings.csv
├─ legacy-fingerprints.csv
├─ summary.json
└─ summary.txt
```

### `results.jsonl`

Full machine-readable result per media file.

### `results.csv`

Flat inventory suitable for spreadsheets.

### `findings.csv`

One row per policy finding.

### `legacy-fingerprints.csv`

Strong fingerprints from the old compatibility processor.

Current strong fingerprints:

- filename contains `.ACConverted`
- audio title exactly equals `Transcoded Compatibility Track`

Legacy fingerprints are informational only.

## Probe reliability

The validator:

- captures stdout/stderr separately
- parses only stdout as JSON
- records ffprobe diagnostics
- uses a hard per-file probe timeout
- terminates a stalled probe and continues an audit
- reads native output asynchronously to avoid pipe deadlocks

Default probe timeout:

```text
15 seconds
```

Override:

```powershell
-ProbeTimeoutSeconds 10
```

## Relationship to contextual validation

The generic validator deliberately does not infer Sonarr/Radarr intent.

For example, a French default track may be correct for one series and incorrect for another.

The Arr Bridge supplies that missing context through `ContextValidator.ps1`.

See [Arr Bridge](arr-bridge.md).
