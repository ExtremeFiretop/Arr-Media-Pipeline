[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BridgeResultPath,

    [string]$JsonOut = "",

    [switch]$Execute,

    [string]$ConfirmChainId = "",

    [string]$ConfirmReplacementFingerprint = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "0.1.0"
$IntegrationRoot = $PSScriptRoot
$ChainCommonPath = Join-Path $IntegrationRoot "ReacquisitionChainCommon.ps1"
$SuccessCommonPath = Join-Path $IntegrationRoot "SonarrReacquisitionSuccessCommon.ps1"
$SonarrCommonPath = Join-Path $IntegrationRoot "SonarrReacquisitionCommon.ps1"
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"
$ContextValidatorPath = Join-Path $IntegrationRoot "ContextValidator.ps1"
$ValidatorPath = Join-Path (Split-Path -Parent $IntegrationRoot) "MediaValidator.ps1"
$PolicyPath = Join-Path (Split-Path -Parent $IntegrationRoot) "validator-policy.json"
$WorkRoot = Join-Path $IntegrationRoot "Reacquisition\success-work"
$SuccessStateRoot = Join-Path $IntegrationRoot "Reacquisition\success-state"
$QuarantineStateRoot = Join-Path $IntegrationRoot "Reacquisition\quarantine-state"

. $ChainCommonPath
. $SuccessCommonPath
. $SonarrCommonPath

function Write-Result {
    param($Object)
    if (-not [string]::IsNullOrWhiteSpace($JsonOut)) {
        $Object | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    }
    $Object | ConvertTo-Json -Depth 60
}

function Get-HigherOutcome {
    param([string]$First, [string]$Second)
    $rank = @{ "PASS" = 0; "NORMALIZE" = 1; "REVIEW" = 2; "REACQUIRE" = 3 }
    if (-not $rank.ContainsKey($First)) { $First = "PASS" }
    if (-not $rank.ContainsKey($Second)) { return $First }
    if ($rank[$Second] -gt $rank[$First]) { return $Second }
    return $First
}

function Invoke-CurrentContextOutcome {
    param([string]$ContextPath, [string]$ValidatorResultPath)

    $runId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + [guid]::NewGuid().ToString("N").Substring(0,8)
    $work = Join-Path $WorkRoot ("context-" + $runId)
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $jsonPath = Join-Path $work "contextual.json"
    $stdoutPath = Join-Path $work "stdout.txt"
    $stderrPath = Join-Path $work "stderr.txt"

    $powerShellExe = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) { $powerShellExe = "powershell.exe" }
    $args = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ContextValidatorPath,
        "-ContextPath", $ContextPath,
        "-ValidatorResultPath", $ValidatorResultPath,
        "-JsonOut", $jsonPath
    )
    $argumentString = ($args | ForEach-Object {
        $text = [string]$_
        if ($text -match '[\s"]') { '"' + $text.Replace('"','\\"') + '"' } else { $text }
    }) -join ' '

    $process = Start-Process -FilePath $powerShellExe -ArgumentList $argumentString -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
        throw "ContextValidator did not produce JSON. ExitCode=$($process.ExitCode)"
    }
    return Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Remove-EmptyQuarantineParents {
    param([string]$RetiredPath, [int]$SeriesId)
    $removed = @()
    # Only walk two directories upward from the release-specific quarantine folder.
    # Never remove the Sonarr quarantine root itself.
    $parent = Split-Path -Parent $RetiredPath
    for ($i = 0; $i -lt 2; $i++) {
        if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) { break }
        if (@(Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue).Count -ne 0) { break }
        $toRemove = $parent
        $parent = Split-Path -Parent $parent
        Remove-Item -LiteralPath $toRemove -Force -ErrorAction Stop
        $removed += $toRemove
    }
    return @($removed)
}

$result = [ordered]@{
    schemaVersion = "1.0"
    scriptVersion = $ScriptVersion
    timestampUtc = [DateTime]::UtcNow.ToString("o")
    mode = if ($Execute) { "EXECUTE" } else { "DRY_RUN" }
    status = "BLOCKED"
    reason = $null
    bridgeResultPath = $BridgeResultPath
    eventId = $null
    chainId = $null
    chainPath = $null
    seriesId = $null
    episodeIds = @()
    replacement = $null
    rollback = $null
    currentEffectiveOutcome = $null
    sourceSnapshotMatches = $false
    arrFileMatches = $false
    mutation = [ordered]@{
        rollbackDeleted = $false
        quarantineStateUpdated = $false
        chainStateUpdated = $false
        successStateWritten = $false
        emptyDirectoriesRemoved = @()
        emptyDirectoryCleanupError = $null
    }
    statePath = $null
    missingPath = $null
    error = $null
}

try {
    foreach ($required in @($BridgeResultPath, $ValidatorPath, $PolicyPath, $ContextValidatorPath, $ChainCommonPath, $SuccessCommonPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            $result.reason = "required_file_missing"
            $result.missingPath = $required
            Write-Result ([pscustomobject]$result)
            exit 0
        }
    }

    $bridge = Get-Content -LiteralPath $BridgeResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $result.eventId = [string](Get-PropertyValue -Object $bridge -Name "eventId" -Default "")
    $contextPath = [string](Get-PropertyValue -Object $bridge -Name "contextFile" -Default "")
    $validatorRecord = Get-PropertyValue -Object $bridge -Name "validator"
    $eventValidatorPath = [string](Get-PropertyValue -Object $validatorRecord -Name "resultFile" -Default "")

    if ([string]::IsNullOrWhiteSpace($contextPath) -or -not (Test-Path -LiteralPath $contextPath -PathType Leaf) -or
        [string]::IsNullOrWhiteSpace($eventValidatorPath) -or -not (Test-Path -LiteralPath $eventValidatorPath -PathType Leaf)) {
        $result.reason = "bridge_context_or_validator_result_missing"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $eventValidator = Get-Content -LiteralPath $eventValidatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $eventFingerprint = Get-StreamFingerprint -ValidatorResult $eventValidator

    $entity = Get-PropertyValue -Object $context -Name "entity"
    $file = Get-PropertyValue -Object $context -Name "file"
    $seriesId = [int](Get-PropertyValue -Object $entity -Name "id" -Default 0)
    $fileId = [int](Get-PropertyValue -Object $file -Name "id" -Default 0)
    $episode = Get-PropertyValue -Object $context -Name "episode"
    $episodeIds = @(@(Get-PropertyValue -Object $episode -Name "ids" -Default @()) | ForEach-Object { $n = 0; if ([int]::TryParse([string]$_, [ref]$n) -and $n -gt 0) { $n } } | Select-Object -Unique)
    $mediaPath = [string](Get-PropertyValue -Object $file -Name "path" -Default "")
    $result.seriesId = $seriesId
    $result.episodeIds = @($episodeIds)

    if ([string](Get-PropertyValue -Object $context -Name "source" -Default "") -ne "Sonarr" -or $seriesId -le 0 -or $fileId -le 0 -or @($episodeIds).Count -eq 0) {
        $result.reason = "replacement_context_identity_invalid"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $chainPath = Get-ReacquisitionChainPath -IntegrationRoot $IntegrationRoot -Source "Sonarr" -EntityId $seriesId -Discriminator (Get-SonarrEpisodeSetKey -EpisodeIds $episodeIds)
    $result.chainPath = $chainPath
    if (-not (Test-Path -LiteralPath $chainPath -PathType Leaf)) {
        $result.reason = "reacquisition_chain_missing"
        Write-Result ([pscustomobject]$result)
        exit 0
    }
    $chain = Get-Content -LiteralPath $chainPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $chainId = [string](Get-PropertyValue -Object $chain -Name "chainId" -Default "")
    $result.chainId = $chainId

    if ([string](Get-PropertyValue -Object $chain -Name "status" -Default "") -eq "COMPLETED_SUCCESS") {
        $success = Get-PropertyValue -Object $chain -Name "success"
        $result.status = "ALREADY_COMPLETED_SUCCESS"
        $result.reason = $null
        $result.replacement = $success
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) {
        $result.reason = "replacement_media_missing"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $currentSnapshot = Invoke-ValidatorSnapshot -MediaPath $mediaPath -LibraryType "TV" -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
    $currentContextual = Invoke-CurrentContextOutcome -ContextPath $contextPath -ValidatorResultPath $currentSnapshot.validatorResultPath
    $contextualOutcome = if ([string](Get-PropertyValue -Object $currentContextual -Name "status" -Default "") -eq "APPLIED") {
        [string](Get-PropertyValue -Object $currentContextual -Name "outcome" -Default "PASS")
    } else { "PASS" }
    $currentEffectiveOutcome = Get-HigherOutcome -First $currentSnapshot.outcome -Second $contextualOutcome
    $result.currentEffectiveOutcome = $currentEffectiveOutcome
    $result.sourceSnapshotMatches = [string]::Equals($eventFingerprint, $currentSnapshot.streamFingerprint, [System.StringComparison]::Ordinal)

    $connection = Get-SonarrConnection -ConfigPath $ConfigPath
    try {
        $arrFile = Invoke-SonarrApi -Connection $connection -RelativePath ("episodefile/{0}" -f $fileId)
    }
    catch {
        $result.reason = "sonarr_replacement_file_not_found"
        Write-Result ([pscustomobject]$result)
        exit 0
    }
    $result.arrFileMatches = (
        [int](Get-PropertyValue -Object $arrFile -Name "id" -Default 0) -eq $fileId -and
        (Test-PathEquivalent -First ([string](Get-PropertyValue -Object $arrFile -Name "path" -Default "")) -Second $mediaPath) -and
        [int64](Get-PropertyValue -Object $arrFile -Name "size" -Default -1) -eq [int64]$currentSnapshot.lengthBytes
    )

    $rollbackDescriptor = Get-PropertyValue -Object $chain -Name "rollback"
    $rollbackCheck = Test-ReacquisitionRollback -Rollback $rollbackDescriptor -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
    $result.rollback = [ordered]@{
        path = $rollbackCheck.path
        exists = $rollbackCheck.exists
        sizeMatches = $rollbackCheck.sizeMatches
        fingerprintMatches = $rollbackCheck.fingerprintMatches
        verified = $rollbackCheck.verified
    }

    $decision = Get-ReacquisitionSuccessDecision -Chain $chain -Bridge $bridge -Context $context `
        -CurrentSnapshot $currentSnapshot -CurrentEffectiveOutcome $currentEffectiveOutcome `
        -ArrFile $arrFile -RollbackCheck $rollbackCheck -EventFingerprint $eventFingerprint

    $release = Get-PropertyValue -Object $context -Name "release"
    $replacement = [ordered]@{
        eventId = $result.eventId
        fileId = $fileId
        mediaPath = $mediaPath
        lengthBytes = [int64]$currentSnapshot.lengthBytes
        eventFingerprint = $eventFingerprint
        currentFingerprint = $currentSnapshot.streamFingerprint
        fingerprintMatchesEvent = $result.sourceSnapshotMatches
        effectiveOutcome = $currentEffectiveOutcome
        arrVerified = $result.arrFileMatches
        releaseTitle = [string](Get-PropertyValue -Object $release -Name "title" -Default "")
        releaseGroup = [string](Get-PropertyValue -Object $file -Name "releaseGroup" -Default "")
        downloadId = [string](Get-PropertyValue -Object $release -Name "downloadId" -Default "")
    }
    $result.replacement = $replacement

    if (-not $decision.eligible) {
        if ($decision.idempotent) {
            $result.status = "ALREADY_COMPLETED_SUCCESS"
            $result.reason = $null
        }
        else {
            $result.reason = $decision.reason
        }
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if (-not $Execute) {
        $result.status = "DRY_RUN_READY"
        $result.reason = $null
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($ConfirmChainId) -or $ConfirmChainId -ne $chainId -or
        [string]::IsNullOrWhiteSpace($ConfirmReplacementFingerprint) -or $ConfirmReplacementFingerprint -ne $currentSnapshot.streamFingerprint) {
        $result.reason = "execute_chain_and_replacement_fingerprint_confirmation_required"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if (-not (Test-Path -LiteralPath $SuccessStateRoot)) { New-Item -ItemType Directory -Path $SuccessStateRoot -Force | Out-Null }
    $stateKey = if ([string]::IsNullOrWhiteSpace($result.eventId)) { $currentSnapshot.streamFingerprint } else { $result.eventId }
    $statePath = Join-Path $SuccessStateRoot ($stateKey + ".json")
    $result.statePath = $statePath

    $mutex = New-Object System.Threading.Mutex($false, "ReqestraMediaReacquisitionRetry")
    $mutexHeld = $false
    try {
        $mutexHeld = $mutex.WaitOne(0)
        if (-not $mutexHeld) {
            $result.reason = "reacquisition_chain_mutation_mutex_busy"
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        # Re-read every mutable authority immediately before deleting rollback.
        $freshChain = Get-Content -LiteralPath $chainPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string](Get-PropertyValue -Object $freshChain -Name "chainId" -Default "") -ne $chainId -or
            [string](Get-PropertyValue -Object $freshChain -Name "status" -Default "") -ne "ACTIVE") {
            $result.reason = "reacquisition_chain_changed_before_execute"
            Write-Result ([pscustomobject]$result)
            exit 0
        }
        $freshRollbackDescriptor = Get-PropertyValue -Object $freshChain -Name "rollback"
        $freshRollback = Test-ReacquisitionRollback -Rollback $freshRollbackDescriptor -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
        if (-not $freshRollback.verified) {
            $result.reason = "canonical_rollback_changed_before_execute"
            Write-Result ([pscustomobject]$result)
            exit 0
        }
        $freshSnapshot = Invoke-ValidatorSnapshot -MediaPath $mediaPath -LibraryType "TV" -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
        if (-not [string]::Equals($freshSnapshot.streamFingerprint, $ConfirmReplacementFingerprint, [System.StringComparison]::Ordinal) -or
            $freshSnapshot.outcome -ne "PASS") {
            $result.reason = "replacement_changed_before_execute"
            Write-Result ([pscustomobject]$result)
            exit 0
        }
        $freshContextual = Invoke-CurrentContextOutcome -ContextPath $contextPath -ValidatorResultPath $freshSnapshot.validatorResultPath
        $freshContextualOutcome = if ([string](Get-PropertyValue -Object $freshContextual -Name "status" -Default "") -eq "APPLIED") {
            [string](Get-PropertyValue -Object $freshContextual -Name "outcome" -Default "PASS")
        } else { "PASS" }
        if ((Get-HigherOutcome -First $freshSnapshot.outcome -Second $freshContextualOutcome) -ne "PASS") {
            $result.reason = "replacement_effective_outcome_changed_before_execute"
            Write-Result ([pscustomobject]$result)
            exit 0
        }
        $freshArr = Invoke-SonarrApi -Connection $connection -RelativePath ("episodefile/{0}" -f $fileId)
        if (-not (Test-PathEquivalent -First ([string](Get-PropertyValue -Object $freshArr -Name "path" -Default "")) -Second $mediaPath) -or
            [int64](Get-PropertyValue -Object $freshArr -Name "size" -Default -1) -ne [int64]$freshSnapshot.lengthBytes) {
            $result.reason = "sonarr_replacement_changed_before_execute"
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        $transaction = [pscustomobject][ordered]@{
            schemaVersion = "1.0"
            scriptVersion = $ScriptVersion
            chainId = $chainId
            eventId = $result.eventId
            seriesId = $seriesId
            episodeIds = @($episodeIds)
            fileId = $fileId
            mediaPath = $mediaPath
            streamFingerprint = $freshSnapshot.streamFingerprint
            rollbackPath = $freshRollback.path
            status = "PREPARED"
            startedUtc = [DateTime]::UtcNow.ToString("o")
            updatedUtc = [DateTime]::UtcNow.ToString("o")
            completedUtc = $null
        }
        Write-AtomicJson -Path $statePath -Object $transaction
        $result.mutation.successStateWritten = $true

        $retiredRollbackPath = [string]$freshRollback.path
        Remove-Item -LiteralPath $retiredRollbackPath -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $retiredRollbackPath -PathType Leaf) {
            throw "Canonical rollback still exists after retirement delete."
        }
        $result.mutation.rollbackDeleted = $true
        $transaction.status = "ROLLBACK_RETIRED"
        $transaction.updatedUtc = [DateTime]::UtcNow.ToString("o")
        Write-AtomicJson -Path $statePath -Object $transaction

        $originalLoopKey = [string](Get-PropertyValue -Object $freshRollbackDescriptor -Name "originalLoopKey" -Default "")
        if (-not [string]::IsNullOrWhiteSpace($originalLoopKey)) {
            $quarantineStatePath = Join-Path $QuarantineStateRoot ($originalLoopKey + ".json")
            if (Test-Path -LiteralPath $quarantineStatePath -PathType Leaf) {
                $quarantineState = Get-Content -LiteralPath $quarantineStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                $quarantineState.status = "RETIRED_AFTER_SUCCESS"
                $quarantineState.stage = "SUCCESS_REPLACEMENT_VALIDATED"
                $quarantineState.updatedUtc = [DateTime]::UtcNow.ToString("o")
                $quarantineState.completedUtc = [DateTime]::UtcNow.ToString("o")
                $quarantineState | Add-Member -NotePropertyName "retiredQuarantinePath" -NotePropertyValue $retiredRollbackPath -Force
                $quarantineState | Add-Member -NotePropertyName "retiredByEventId" -NotePropertyValue $result.eventId -Force
                Write-AtomicJson -Path $quarantineStatePath -Object $quarantineState
                $result.mutation.quarantineStateUpdated = $true
            }
        }

        try {
            $result.mutation.emptyDirectoriesRemoved = @(Remove-EmptyQuarantineParents -RetiredPath $retiredRollbackPath -SeriesId $seriesId)
        }
        catch {
            # Empty-directory cleanup is cosmetic. Do not make a validated success
            # unsafe because an empty parent directory could not be removed.
            $result.mutation.emptyDirectoryCleanupError = $_.Exception.Message
        }

        $attempts = @(Get-PropertyValue -Object $freshChain -Name "attempts" -Default @())
        $failedAttemptCount = [int](Get-PropertyValue -Object $freshChain -Name "failedAttemptCount" -Default $attempts.Count)
        $attempts += [pscustomobject][ordered]@{
            attemptNumber = $failedAttemptCount + 1
            eventId = $result.eventId
            fileId = $fileId
            releaseTitle = $replacement.releaseTitle
            releaseGroup = $replacement.releaseGroup
            disposition = "SUCCESS_REPLACEMENT_RETAINED"
            streamFingerprint = $freshSnapshot.streamFingerprint
            completedUtc = [DateTime]::UtcNow.ToString("o")
        }
        $freshChain.attempts = @($attempts)
        $freshChain.status = "COMPLETED_SUCCESS"
        $freshChain.updatedUtc = [DateTime]::UtcNow.ToString("o")
        $freshChain | Add-Member -NotePropertyName "completedUtc" -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
        $freshChain | Add-Member -NotePropertyName "success" -NotePropertyValue ([pscustomobject][ordered]@{
            eventId = $result.eventId
            fileId = $fileId
            episodeIds = @($episodeIds)
            mediaPath = $mediaPath
            lengthBytes = [int64]$freshSnapshot.lengthBytes
            streamFingerprint = $freshSnapshot.streamFingerprint
            effectiveOutcome = "PASS"
            releaseTitle = $replacement.releaseTitle
            releaseGroup = $replacement.releaseGroup
            downloadId = $replacement.downloadId
            bridgeResultPath = [System.IO.Path]::GetFullPath($BridgeResultPath)
            validatorResultPath = $freshSnapshot.validatorResultPath
            completedUtc = [DateTime]::UtcNow.ToString("o")
        }) -Force
        $rollbackState = Get-PropertyValue -Object $freshChain -Name "rollback"
        $rollbackState | Add-Member -NotePropertyName "status" -NotePropertyValue "RETIRED_AFTER_SUCCESS" -Force
        $rollbackState | Add-Member -NotePropertyName "retiredPath" -NotePropertyValue $retiredRollbackPath -Force
        $rollbackState | Add-Member -NotePropertyName "retiredUtc" -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
        $rollbackState | Add-Member -NotePropertyName "retiredByEventId" -NotePropertyValue $result.eventId -Force
        Write-AtomicJson -Path $chainPath -Object $freshChain
        $result.mutation.chainStateUpdated = $true

        $transaction.status = "COMPLETED_SUCCESS"
        $transaction.updatedUtc = [DateTime]::UtcNow.ToString("o")
        $transaction.completedUtc = [DateTime]::UtcNow.ToString("o")
        Write-AtomicJson -Path $statePath -Object $transaction

        $result.status = "REACQUISITION_COMPLETED_SUCCESS"
        $result.reason = $null
        Write-Result ([pscustomobject]$result)
        exit 0
    }
    catch {
        if ($result.mutation.rollbackDeleted -and -not $result.mutation.chainStateUpdated) {
            try {
                $recoveryChain = Get-Content -LiteralPath $chainPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $recoveryChain.status = "RECOVERY_REQUIRED"
                $recoveryChain.updatedUtc = [DateTime]::UtcNow.ToString("o")
                $recoveryChain | Add-Member -NotePropertyName "recoveryReason" -NotePropertyValue "rollback_retired_before_success_state_commit" -Force
                Write-AtomicJson -Path $chainPath -Object $recoveryChain
            }
            catch {}
            $result.status = "RECOVERY_REQUIRED"
            $result.reason = "success_retirement_partial_commit"
        }
        else {
            $result.status = "FAILED"
            $result.reason = "success_retirement_exception"
        }
        $result.error = $_.Exception.Message
        Write-Result ([pscustomobject]$result)
        exit 0
    }
    finally {
        if ($mutexHeld) { try { $mutex.ReleaseMutex() } catch {} }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}
catch {
    $result.status = "FAILED"
    $result.reason = "success_finalizer_exception"
    $result.error = $_.Exception.Message
    Write-Result ([pscustomobject]$result)
    exit 0
}
