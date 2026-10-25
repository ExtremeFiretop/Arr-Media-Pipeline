# Architecture

Arr Media Pipeline adds a policy and validation layer around the normal Radarr/Sonarr import lifecycle.

## Design goal

The system is designed around one rule:

> Preserve a good master whenever possible. Correct cheap metadata problems safely. Reacquire genuinely bad media. Let Plex adapt at playback time for client-specific limitations.

It is not intended to be a blanket transcoding pipeline.

## End-to-end flow

```text
Reqestra
   |
   v
Radarr / Sonarr
   |
   v
Indexer / download client
   |
   v
Completed download
   |
   v
Arr import
   |
   +-----------------------------+
   |                             |
   v                             v
Generic Media Validator     Arr API context
   |                             |
   +-------------+---------------+
                 |
                 v
          Context Validator
                 |
                 v
          Effective Outcome
                 |
       +---------+---------+----------------+
       |                   |                |
      PASS             NORMALIZE        REVIEW / REACQUIRE
                           |
                           v
                 Normalization Planner
                           |
                           v
                    Persistent Queue
                           |
                           v
                   Worker Preflight
                           |
                           v
             optional gated AUTO_EXECUTE
                           |
                           v
                 Guarded MKV Executor
                           |
             +-------------+-------------+
             |                           |
             v                           v
      Final validation             Arr reconciliation
             |                           |
             +-------------+-------------+
                           |
                           v
                    Retained backup
```

## Components

### Media Validator

`src/MediaValidator/MediaValidator.ps1`

Generic, read-only classifier. It knows media structure and policy but does not know why Radarr/Sonarr selected a release.

### Arr Bridge

`src/ArrBridge/ReqestraArrBridge.ps1`

Entry point for Arr Connect events. It collects event context, invokes validation, enriches the result with Arr metadata, asks the planner for a safe action, and enqueues work when appropriate.

### Context Validator

`src/ArrBridge/ContextValidator.ps1`

Applies information that the generic validator deliberately does not assume, especially Sonarr language-profile intent.

### Normalization Planner

`src/ArrBridge/NormalizationPlanner.ps1`

Transforms supported `NORMALIZE` findings into a concrete, conservative action plan. It never mutates media.

### Normalization Executor

`src/ArrBridge/Invoke-Normalization.ps1`

Performs guarded MKV metadata normalization. It revalidates the plan immediately before execution, remuxes without transcoding, validates the temporary output, atomically replaces the source, and reconciles the result with Radarr/Sonarr.

### Queue Worker

`src/ArrBridge/NormalizationWorker.ps1`

Processes persistent normalization jobs outside the Arr Connect callback. Supports fail-closed dry-run operation and explicitly gated automatic execution.

### Maintenance

`Invoke-MediaMaintenance.ps1` and `MaintenanceCommon.ps1`

Implements evidence-based backup retention and safe abandoned-temp cleanup.

## Classification boundaries

### PASS

The current media satisfies all active generic and contextual policy checks.

### NORMALIZE

The media is structurally acceptable and can be corrected without reacquiring or transcoding, such as fixing audio default flags.

### REVIEW

The media cannot be classified safely enough for automatic action.

### REACQUIRE

The master itself is unacceptable or incomplete and metadata normalization cannot fix it.

Examples include prohibited video formats or missing audio.

## Generic vs contextual validation

The generic validator is intentionally reusable and conservative.

For example, it can determine:

- which languages exist
- which tracks are default
- which tracks appear to be commentary
- whether Dolby Vision is present

It does not globally assume that every TV series must default to English.

The contextual validator can then apply Sonarr intent:

```text
English profile  -> preferred language = eng
French profile   -> preferred language = fre
Original profile -> preferred language = series original language
```

The effective outcome is the higher severity of the generic and contextual results.

## Runtime layout

The tested installation layout is:

```text
MediaValidator\
├─ MediaValidator.ps1
├─ validator-policy.json
└─ Integration\
   ├─ ReqestraArrBridge.ps1
   ├─ ContextValidator.ps1
   ├─ NormalizationPlanner.ps1
   ├─ Invoke-Normalization.ps1
   ├─ NormalizationWorker.ps1
   ├─ QueueCommon.ps1
   ├─ MaintenanceCommon.ps1
   ├─ Queue\
   ├─ Maintenance\
   └─ logs\
```

Runtime directories are machine state and must not be packaged as source.

## Safety boundaries

The architecture deliberately separates:

```text
observe
  ↓
classify
  ↓
plan
  ↓
queue
  ↓
preflight
  ↓
mutate
  ↓
verify
  ↓
reconcile
  ↓
retain backup
```

No earlier stage is allowed to silently skip the later safety checks.

## Concurrency

Named mutexes prevent conflicting operations:

- normalization worker: only one active queue worker
- media normalization: only one active media replacement
- maintenance: only one active cleanup execution
- maintenance also respects the normalization mutex before deleting artifacts

## Future architecture

Planned major additions:

- controlled reacquisition engine
- deeper corruption/health validation
- subtitle lifecycle automation
- Plex/Reqestra observability
- scheduled operational maintenance
