# Reqestra Media Validator v0.2.6

Read-only media policy validator and library auditor.

## Safety

v0.2.6 does **not**:

- rename media;
- edit metadata;
- remux media;
- transcode media;
- delete media;
- call Radarr/Sonarr APIs;
- blocklist releases;
- reacquire media;
- refresh Plex.

It only reads files with `ffprobe` and writes reports.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- `ffprobe` in `PATH`, or use `-FfprobePath`

## Single-file mode

Existing v0.1 behavior is preserved:

```powershell
.\MediaValidator.ps1 "M:\Movies\Example (2026)\Example.mkv" -LibraryType Movie -PreferredLanguage eng
```

Outcomes / process exit codes:

| Outcome | Exit |
| --- | ---: |
| PASS | 0 |
| NORMALIZE | 10 |
| REVIEW | 20 |
| REACQUIRE | 30 |

For a future integration that should never fail the parent hook, add:

```powershell
-ExitZero
```

The result still contains the actual classification and actual `exitCode`, but the PowerShell process exits 0.

## Directory audit mode

Passing a directory automatically enables read-only audit mode.

### Recommended first test

Scan 25 movie files:

```powershell
.\MediaValidator.ps1 "M:\Movies" -LibraryType Movie -MaxFiles 25
```

Scan 25 TV files:

```powershell
.\MediaValidator.ps1 "V:\TV Shows" -LibraryType TV -MaxFiles 25
```

### Full movie audit

```powershell
.\MediaValidator.ps1 "M:\Movies" -LibraryType Movie
```

### Full TV audit

```powershell
.\MediaValidator.ps1 "V:\TV Shows" -LibraryType TV
```

Audit mode is recursive by default. Use `-NoRecurse` to inspect only the supplied directory.

Audit mode always exits 0 after a completed scan, regardless of how many files are classified as NORMALIZE / REVIEW / REACQUIRE.

## Preferred language warning

Do **not** use one global `-PreferredLanguage` when auditing a library that contains multiple Radarr/Sonarr language profiles.

For example, do not blindly run:

```powershell
.\MediaValidator.ps1 "V:\TV Shows" -PreferredLanguage eng
```

if some series intentionally use French or Original Language profiles.

Without `-PreferredLanguage`, the audit still checks codecs, Dolby Vision, stream health, default/commentary consistency, subtitles, and legacy fingerprints, but it does not judge whether the default audio is the correct language.

Profile-aware language validation will be added when the validator is connected to Radarr/Sonarr metadata.

## Audit output

By default each audit creates:

```text
audit-YYYYMMDD-HHMMSS\
    results.jsonl
    results.csv
    findings.csv
    legacy-fingerprints.csv
    summary.json
    summary.txt
```

You can choose another destination:

```powershell
.\MediaValidator.ps1 "M:\Movies" -AuditOutputDirectory "C:\MediaAudit\Movies"
```

### results.jsonl

Full machine-readable result for every file, one JSON object per line.

### results.csv

Flat one-row-per-file inventory suitable for Excel.

### findings.csv

One row per policy finding.

### legacy-fingerprints.csv

Files with strong evidence of the old compatibility processor:

- filename contains `.ACConverted`
- audio title is `Transcoded Compatibility Track`

These fingerprints are informational and do not change policy outcome.

### summary.json / summary.txt

Aggregate counts including:

- PASS / NORMALIZE / REVIEW / REACQUIRE
- finding-code counts
- video codec counts
- HDR type counts
- number of files containing legacy fingerprints

## v0.2 policy outcomes

### REACQUIRE

- actual Dolby Vision metadata;
- AV1 video;
- VVC/H.266 video.

### NORMALIZE

- commentary audio marked default;
- no default audio;
- multiple default audio streams;
- preferred-language audio exists but is not default (only when `-PreferredLanguage` is supplied).

### REVIEW

- ffprobe failure;
- invalid ffprobe JSON;
- missing video;
- missing audio;
- multiple playable video streams;
- unknown video codec;
- extremely low video resolution.

### INFO

- preferred language missing;
- image subtitles without any text subtitle.

## Legacy processor fingerprinting

v0.2 does not assume every file created by FFmpeg came from the legacy script.

Only strong fingerprints are currently recorded:

- `.ACConverted` filename suffix;
- exact `Transcoded Compatibility Track` audio title.

This avoids misclassifying third-party releases that were also encoded with FFmpeg.

## Recommended rollout

1. Replace v0.1.1 with v0.2.6.
2. Re-run one known single-file validation to confirm behavior.
3. Run `-MaxFiles 25` against Movies.
4. Run `-MaxFiles 25` against TV.
5. Inspect `summary.txt`, `findings.csv`, and `results.csv`.
6. Only then run the full libraries.

No automatic action should be enabled until the audit results have been reviewed.


## v0.2.6 reliability changes

- ffprobe stdout and stderr are now captured separately.
- Only stdout is parsed as JSON.
- ffprobe diagnostics are retained in the result under `probe.stderr`.
- Dolby Vision/HDR10+ detection now inspects video-stream side-data rather than searching the complete ffprobe JSON blob.
- Policy outcomes are otherwise unchanged.


## v0.2.6 reliability changes

- ffprobe output is restricted to fields the validator actually uses.
- Arbitrary stream/container tags are no longer parsed, avoiding Windows PowerShell 5.1 JSON-property edge cases.
- Native ffprobe stderr no longer becomes a false PowerShell terminating error.
- ffprobe exit code and stderr are handled explicitly.
- Error-level ffprobe diagnostics with parseable metadata now produce `REVIEW / probe.diagnostic_error`.
- `audio.missing` remains REVIEW until title/application metadata can establish whether audio is expected.


## v0.2.6 audit-hang protection

- Every ffprobe process now has a hard per-file timeout.
- Default timeout: 15 seconds.
- Configure with `-ProbeTimeoutSeconds`.
- A timed-out file becomes `REVIEW / probe.timeout`.
- The stalled ffprobe process is terminated and the audit continues.
- stdout/stderr are read asynchronously to avoid native pipe-buffer deadlocks.

Example:

```powershell
.\MediaValidator.ps1 "M:\Movies" -LibraryType Movie -ProbeTimeoutSeconds 10
```


## v0.2.6 policy change

- `audio.missing` is now `REACQUIRE` instead of `REVIEW`.
- Rationale: this validator is scoped to normal movie/TV library media; a file with no audio stream is an incomplete master and cannot be fixed by metadata normalization.
- No other classification rules changed.


## v0.2.6 TV audit refinement

- `video.unusually_low_resolution` is now `INFO` instead of `REVIEW`.
  - Old SD/DVD media remains visible in audit findings but no longer fails validation solely because of resolution.
- `video.multiple` now counts only real playable/motion-video streams.
- Auxiliary video/image streams are excluded when strong evidence shows they are artwork or thumbnail/chapter-image tracks:
  - `attached_pic=1`, or
  - non-default image-like codec with 10 or fewer frames, or
  - non-default image-like codec with a very low average/nominal frame rate.
- Image-like codecs are **not** excluded merely because of codec name; MJPEG and similar codecs can be legitimate motion video.
- Auxiliary streams are retained in JSON under `auxiliaryVideo` and exposed in audit CSV as `AuxiliaryVideoCount` / `AuxiliaryVideoCodecs`.
- Genuine multiple motion-video streams still produce `REVIEW / video.multiple`.


## v0.2.6 freeze-candidate refinements

- Non-default PNG video streams are treated as auxiliary image data.
- Sparse image-like streams with no meaningful average frame rate and an implausibly high nominal frame rate (>=120 fps) are treated as auxiliary.
- Genuine H.264/H.264 alternate motion-video streams remain `REVIEW / video.multiple`.
- No changes to Dolby Vision, AV1/VVC, missing-audio, audio-default, subtitle, or diagnostic-error policy.
- Intended as the generic read-only classifier freeze candidate before Radarr/Sonarr-aware integration.
