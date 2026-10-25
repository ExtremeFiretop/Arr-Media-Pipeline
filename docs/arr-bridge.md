# Arr Bridge

Current bridge release: **v0.8.0**

The Arr Bridge connects Radarr/Sonarr import events to the generic validator, contextual policy, normalization planner, and persistent queue.

## Entry points

```text
RadarrValidator.cmd
SonarrValidator.cmd
```

Both wrappers call:

```text
ReqestraArrBridge.ps1
```

with the appropriate source.

## Responsibilities

The bridge:

1. captures the Arr event environment
2. resolves the imported media path
3. runs the generic media validator
4. enriches the event with Arr API data
5. runs contextual validation
6. calculates the effective outcome
7. asks the normalization planner for a safe plan
8. queues a `PLANNED` normalization
9. starts the independent queue worker
10. persists event artifacts and logs

It does not perform long remux work synchronously inside the Arr Connect callback.

## Arr API enrichment

The bridge can use:

- movie/series ID
- media file ID
- quality profile ID/name
- series original language
- current Arr file path/size

Live API credentials are read from:

```text
Integration\integration-config.json
```

API keys are machine-local configuration and must not be committed.

## Contextual validation

### Sonarr

Known profile mappings:

```text
English           -> eng
French            -> fre
Original          -> series original language
Original Language -> series original language
```

Only non-commentary audio satisfies the preferred-language requirement.

Behavior:

```text
preferred exists + is default       -> PASS
preferred exists + not default      -> NORMALIZE
preferred definitely absent         -> REACQUIRE
preferred cannot be verified        -> REVIEW
original language unavailable       -> REVIEW
API/profile unavailable             -> SKIPPED
unmapped profile                    -> SKIPPED
```

### Radarr

Radarr contextual language enforcement is intentionally skipped at present.

The generic validator still applies codec, audio-presence, default-track, structural, and other media rules.

## Effective outcome

The bridge uses the higher severity of:

```text
generic outcome
contextual outcome
```

Severity order:

```text
PASS < NORMALIZE < REVIEW < REACQUIRE
```

## Event artifacts

Each event receives its own directory beneath:

```text
Integration\logs\events\
```

Typical artifacts include:

```text
environment.json
context.json
validator-result.json
contextual-result.json
normalization-plan.json
bridge-result.json
```

Normalization execution may create a nested work directory:

```text
normalization-execution-<executionId>\
```

These artifacts form the audit trail used by later maintenance and troubleshooting.

## Queue handoff

Only a planner result with:

```text
status = PLANNED
```

is eligible for queueing.

The bridge records queue information in `bridge-result.json`, including:

- queue status
- job ID
- queue mode
- worker-start result

Queue failure does not fail the original Arr import.

## Non-blocking design

A remux may take minutes.

Therefore:

```text
Arr Connect callback
    -> validate / plan / enqueue
    -> return

independent worker
    -> preflight
    -> optional execute
```

This prevents Sonarr/Radarr from waiting for the entire normalization operation.

## Relationship to other components

- generic inspection: [Media Validator](media-validator.md)
- normalization planning/execution: [Normalization](normalization.md)
- persistent automation: [Queue and Recovery](queue-and-recovery.md)
