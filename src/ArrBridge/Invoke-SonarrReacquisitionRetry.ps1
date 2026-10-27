[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlanPath,

    [string]$JsonOut = "",

    [switch]$Execute,

    [string]$ConfirmChainId = "",

    [string]$ConfirmLoopKey = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ExecutorVersion = "0.1.2"
$IntegrationRoot = $PSScriptRoot
$CommonPath = Join-Path $IntegrationRoot "ReacquisitionChainCommon.ps1"
$SelectorPath = Join-Path $IntegrationRoot "ReacquisitionReleaseSelector.ps1"
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"
$ValidatorPath = Join-Path (Split-Path -Parent $IntegrationRoot) "MediaValidator.ps1"
$PolicyPath = Join-Path (Split-Path -Parent $IntegrationRoot) "validator-policy.json"
$WorkRoot = Join-Path $IntegrationRoot "Reacquisition\retry-work"
$RetryStateRoot = Join-Path $IntegrationRoot "Reacquisition\retry-state"
$SonarrCommonPath = Join-Path $IntegrationRoot "SonarrReacquisitionCommon.ps1"

. $CommonPath
. $SonarrCommonPath
. $SelectorPath

function Write-Result {
    param($Object)
    if (-not [string]::IsNullOrWhiteSpace($JsonOut)) {
        $Object | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    }
    $Object | ConvertTo-Json -Depth 60
}

function Normalize-ReleaseTitle {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $normalized = $Value.Trim().ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, '[\s\.\-_]+', ' ')
    $normalized = [regex]::Replace($normalized, '[^a-z0-9 ]', '')
    $normalized = [regex]::Replace($normalized, '\s+', ' ')
    return $normalized.Trim()
}

function Test-MatchingBlocklist {
    param([object[]]$Records, [int]$SeriesId, [string]$SourceTitle)

    $expectedTitle = Normalize-ReleaseTitle $SourceTitle
    return @(
        $Records | Where-Object {
            $recordSeriesId = [int](Get-PropertyValue -Object $_ -Name "seriesId" -Default 0)
            $recordTitle = Normalize-ReleaseTitle ([string](Get-PropertyValue -Object $_ -Name "sourceTitle" -Default ""))
            $seriesMatches = ($recordSeriesId -eq 0 -or $recordSeriesId -eq $SeriesId)
            $titleMatches = (-not [string]::IsNullOrWhiteSpace($expectedTitle) -and $recordTitle -eq $expectedTitle)
            $seriesMatches -and $titleMatches
        }
    )
}

function Test-DiskOnlyRejection {
    param($Release)

    if ([bool](Get-PropertyValue -Object $Release -Name "approved" -Default $false)) { return $false }
    $rejections = @(Get-PropertyValue -Object $Release -Name "rejections" -Default @())
    if ($rejections.Count -eq 0) { return $false }

    $patterns = @(
        '^Existing file on disk is of equal or higher preference:',
        '^Existing file on disk is of equal or higher revision:',
        '^Existing file on disk has a equal or higher Custom Format score:',
        '^Existing file on disk has Custom Format score within Custom Format score increment:',
        '^Existing file on disk meets quality cutoff:',
        '^Existing file on disk meets Custom Format cutoff:',
        '^Existing file meets cutoff:',
        "^Existing file on disk and Quality Profile '.*' does not allow upgrades$"
    )

    foreach ($rejection in $rejections) {
        $matched = $false
        foreach ($pattern in $patterns) {
            if ([string]$rejection -match $pattern) { $matched = $true; break }
        }
        if (-not $matched) { return $false }
    }
    return $true
}

function Get-ReleaseSearch {
    param($Connection, [int[]]$EpisodeIds)

    $relativePath = Get-SonarrReleaseSearchRelativePath -EpisodeIds $EpisodeIds
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        return [pscustomobject]@{
            mode = "MULTI_EPISODE_SEARCH_ONLY"
            all = @()
            approved = @()
            diskOnly = @()
            predicted = @()
        }
    }

    $response = Invoke-SonarrApi -Connection $Connection -RelativePath $relativePath -Method GET
    $all = @(Get-SonarrRecordArray -Response $response)
    $approved = @($all | Where-Object { [bool](Get-PropertyValue -Object $_ -Name "approved" -Default $false) })
    $diskOnly = @($all | Where-Object { Test-DiskOnlyRejection -Release $_ })

    return [pscustomobject]@{
        mode = "SINGLE_EPISODE_RELEASE_SEARCH"
        all = $all
        approved = $approved
        diskOnly = $diskOnly
        predicted = @($approved + $diskOnly)
    }
}

function Restore-ChainRollback {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)]$ChainState,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $rollback = Get-PropertyValue -Object $ChainState -Name "rollback"
    $rollbackPath = [string](Get-PropertyValue -Object $rollback -Name "path" -Default "")
    $expectedBytes = [int64](Get-PropertyValue -Object $rollback -Name "lengthBytes" -Default -1)
    $seriesId = [int](Get-PropertyValue -Object $ChainState -Name "entityId" -Default 0)

    $result = [ordered]@{
        attempted = $true
        physicalRestored = $false
        rescanCommandId = $null
        rescanStatus = $null
        sonarrRediscovered = $false
        restoredFileId = $null
        sizeMatches = $false
        error = $null
    }

    try {
        if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
            throw "Rollback destination already exists: $DestinationPath"
        }
        if (-not (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) {
            throw "Canonical rollback is missing: $rollbackPath"
        }

        $destinationDirectory = Split-Path -Parent $DestinationPath
        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        }

        Move-Item -LiteralPath $rollbackPath -Destination $DestinationPath
        $item = Get-Item -LiteralPath $DestinationPath
        if ([int64]$item.Length -ne $expectedBytes) { throw "Restored rollback size mismatch." }
        $result.physicalRestored = $true
        $result.sizeMatches = $true

        $command = Invoke-SonarrApi -Connection $Connection -RelativePath "command" -Method POST -Body ([ordered]@{
            name = "RescanSeries"
            seriesId = $seriesId
        })
        $commandId = [int](Get-PropertyValue -Object $command -Name "id" -Default 0)
        if ($commandId -le 0) { throw "Sonarr did not return a valid RescanSeries command id." }
        $result.rescanCommandId = $commandId

        $completed = Wait-SonarrCommand -Connection $Connection -CommandId $commandId
        $result.rescanStatus = [string](Get-PropertyValue -Object $completed -Name "status" -Default "")
        if ($result.rescanStatus -ne "completed") { throw "RescanSeries did not complete." }

        $files = @(Get-SonarrRecordArray -Response (Invoke-SonarrApi -Connection $Connection -RelativePath (Get-SonarrEpisodeFilesRelativePath -SeriesId $seriesId) -Method GET))
        $matching = @($files | Where-Object {
            Test-PathEquivalent -First ([string](Get-PropertyValue -Object $_ -Name "path" -Default "")) -Second $DestinationPath
        })
        if ($matching.Count -ne 1) { throw "Sonarr did not rediscover exactly one rollback file." }
        $arrBytes = [int64](Get-PropertyValue -Object $matching[0] -Name "size" -Default -1)
        if ($arrBytes -ne $expectedBytes) { throw "Rediscovered rollback size mismatch." }

        $result.sonarrRediscovered = $true
        $result.restoredFileId = [int](Get-PropertyValue -Object $matching[0] -Name "id" -Default 0)
    }
    catch {
        $result.error = $_.Exception.Message
    }

    return [pscustomobject]$result
}

$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
$result = [ordered]@{
    schemaVersion = "1.0"
    executorVersion = $ExecutorVersion
    timestampUtc = [DateTime]::UtcNow.ToString("o")
    mode = if ($Execute) { "EXECUTE" } else { "DRY_RUN" }
    status = "BLOCKED"
    reason = $null
    source = [string](Get-PropertyValue -Object $plan -Name "source" -Default "")
    mediaPath = [string](Get-PropertyValue -Object $plan -Name "mediaPath" -Default "")
    seriesId = $null
    episodeIds = @()
    fileId = $null
    loopKey = $null
    chainId = $null
    chainPath = $null
    chainAttemptNumber = $null
    maxChainAttempts = $null
    terminalAfterCurrent = $false
    rollback = $null
    sourceSnapshotMatches = $false
    streamFingerprintMatches = $false
    arrFileMatches = $false
    reacquisitionStateVerified = $false
    reacquisitionStateEvidence = $null
    blocklistVerified = $false
    preRemovalSearch = $null
    disposition = "DELETE_RETRY"
    selectionStrategy = $null
    releaseSelection = $null
    mutation = [ordered]@{
        episodeFileDeleted = $false
        episodeSearchSent = $false
        releaseGrabSent = $false
        mutatingRequestsSent = 0
    }
    postRemovalSearch = $null
    replacementActivity = $null
    rollbackRestore = $null
    statePath = $null
}

try {
    if ($result.source -ne "Sonarr") { $result.reason = "sonarr_only"; Write-Result ([pscustomobject]$result); exit 0 }
    if ([string](Get-PropertyValue -Object $plan -Name "status" -Default "") -ne "PLANNED") { $result.reason = "plan_not_planned"; Write-Result ([pscustomobject]$result); exit 0 }
    if ([string](Get-PropertyValue -Object $plan -Name "effectiveOutcome" -Default "") -ne "REACQUIRE") { $result.reason = "plan_not_reacquire"; Write-Result ([pscustomobject]$result); exit 0 }

    $entity = Get-PropertyValue -Object $plan -Name "entity"
    $file = Get-PropertyValue -Object $plan -Name "file"
    $snapshot = Get-PropertyValue -Object $plan -Name "sourceSnapshot"
    $releaseIdentity = Get-PropertyValue -Object $plan -Name "releaseIdentity"
    $loopPrevention = Get-PropertyValue -Object $plan -Name "loopPrevention"
    $triggerFindingCodes = @(Get-PropertyValue -Object $plan -Name "triggerFindingCodes" -Default @())
    $isDolbyVisionReacquisition = $false

    $seriesId = [int](Get-PropertyValue -Object $entity -Name "id" -Default 0)
    $episodeIds = @(Get-SonarrEpisodeIdsFromPlan -Plan $plan)
    $fileId = [int](Get-PropertyValue -Object $file -Name "id" -Default 0)
    $loopKey = [string](Get-PropertyValue -Object $loopPrevention -Name "loopKey" -Default "")
    $sourceTitle = [string](Get-PropertyValue -Object $releaseIdentity -Name "releaseTitle" -Default "")
    $expectedBytes = [int64](Get-PropertyValue -Object $snapshot -Name "lengthBytes" -Default -1)
    $expectedFingerprint = [string](Get-PropertyValue -Object $snapshot -Name "streamFingerprint" -Default "")

    $result.seriesId = $seriesId
    $result.episodeIds = @($episodeIds)
    $result.fileId = $fileId
    $result.loopKey = $loopKey

    if ($seriesId -le 0 -or $fileId -le 0 -or @($episodeIds).Count -eq 0 -or [string]::IsNullOrWhiteSpace($loopKey)) {
        $result.reason = "plan_identity_incomplete"; Write-Result ([pscustomobject]$result); exit 0
    }

    if (-not (Test-Path -LiteralPath $result.mediaPath -PathType Leaf)) {
        $result.reason = "current_media_missing"; Write-Result ([pscustomobject]$result); exit 0
    }

    $item = Get-Item -LiteralPath $result.mediaPath
    $expectedLastWrite = [DateTime]::Parse(
        [string](Get-PropertyValue -Object $snapshot -Name "lastWriteTimeUtc" -Default ""),
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
    $result.sourceSnapshotMatches = ([int64]$item.Length -eq $expectedBytes -and $item.LastWriteTimeUtc -eq $expectedLastWrite)
    if (-not $result.sourceSnapshotMatches) { $result.reason = "source_snapshot_changed"; Write-Result ([pscustomobject]$result); exit 0 }

    $currentSnapshot = Invoke-ValidatorSnapshot -MediaPath $result.mediaPath -LibraryType "TV" -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
    $result.streamFingerprintMatches = [string]::Equals($currentSnapshot.streamFingerprint, $expectedFingerprint, [System.StringComparison]::Ordinal)
    if (-not $result.streamFingerprintMatches) { $result.reason = "stream_fingerprint_changed"; Write-Result ([pscustomobject]$result); exit 0 }
    if ($currentSnapshot.outcome -ne "REACQUIRE") { $result.reason = "current_media_no_longer_requires_reacquisition"; Write-Result ([pscustomobject]$result); exit 0 }

    $connection = Get-SonarrConnection -ConfigPath $ConfigPath
    $arrFile = Invoke-SonarrApi -Connection $connection -RelativePath ("episodefile/{0}" -f $fileId) -Method GET
    $arrPath = [string](Get-PropertyValue -Object $arrFile -Name "path" -Default "")
    $arrBytes = [int64](Get-PropertyValue -Object $arrFile -Name "size" -Default -1)
    $result.arrFileMatches = ((Test-PathEquivalent -First $arrPath -Second $result.mediaPath) -and $arrBytes -eq $expectedBytes)
    if (-not $result.arrFileMatches) { $result.reason = "current_arr_file_mismatch"; Write-Result ([pscustomobject]$result); exit 0 }

    $reacqStatePath = Join-Path (Join-Path $IntegrationRoot "Reacquisition\state") ($loopKey + ".json")
    $reacqStateExists = Test-Path -LiteralPath $reacqStatePath -PathType Leaf
    if ($reacqStateExists) {
        $reacqState = Get-Content -LiteralPath $reacqStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $successfulAttempts = @(@(Get-PropertyValue -Object $reacqState -Name "attempts" -Default @()) | Where-Object {
            [string](Get-PropertyValue -Object $_ -Name "status" -Default "") -in @("SUCCESS","SUCCESS_RECOVERED","SUCCESS_SEARCH_SUPPRESSED") -and
            [bool](Get-PropertyValue -Object $_ -Name "blocklistVerified" -Default $false)
        })
        $result.reacquisitionStateVerified = ($successfulAttempts.Count -gt 0)
        if ($result.reacquisitionStateVerified) { $result.reacquisitionStateEvidence = "PIPELINE_STATE" }
    }

    $blocklist = @(Get-SonarrRecordArray -Response (Invoke-SonarrApi -Connection $connection -RelativePath (Get-SonarrBlocklistRelativePath -SeriesId $seriesId) -Method GET))
    $matchingBlocklist = @(Test-MatchingBlocklist -Records $blocklist -SeriesId $seriesId -SourceTitle $sourceTitle)
    $result.blocklistVerified = ($matchingBlocklist.Count -gt 0)
    if (-not $result.blocklistVerified) {
        $result.reason = if ($reacqStateExists) { "failed_release_not_currently_blocklisted" } else { "reacquisition_state_missing" }
        Write-Result ([pscustomobject]$result); exit 0
    }
    if (-not $result.reacquisitionStateVerified) {
        if ($reacqStateExists) {
            $result.reason = "successful_reacquisition_blocklist_state_not_found"; Write-Result ([pscustomobject]$result); exit 0
        }
        $result.reacquisitionStateVerified = $true
        $result.reacquisitionStateEvidence = "EXACT_BLOCKLIST_ONLY"
    }

    $chainPath = Get-ReacquisitionChainPath -IntegrationRoot $IntegrationRoot -Source "Sonarr" -EntityId $seriesId -Discriminator (Get-SonarrEpisodeSetKey -EpisodeIds $episodeIds)
    $result.chainPath = $chainPath
    if (-not (Test-Path -LiteralPath $chainPath -PathType Leaf)) { $result.reason = "reacquisition_chain_missing"; Write-Result ([pscustomobject]$result); exit 0 }

    $chain = Get-Content -LiteralPath $chainPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $chainId = [string](Get-PropertyValue -Object $chain -Name "chainId" -Default "")
    $chainStatus = [string](Get-PropertyValue -Object $chain -Name "status" -Default "")
    $maxAttempts = [int](Get-PropertyValue -Object $chain -Name "maxAttempts" -Default 3)
    $attempts = @(Get-PropertyValue -Object $chain -Name "attempts" -Default @())
    $failedAttemptCount = [int](Get-PropertyValue -Object $chain -Name "failedAttemptCount" -Default $attempts.Count)
    $currentAlreadyRecorded = @($attempts | Where-Object { [string](Get-PropertyValue -Object $_ -Name "loopKey" -Default "") -eq $loopKey }).Count -gt 0

    $result.chainId = $chainId
    $result.maxChainAttempts = $maxAttempts
    $result.chainAttemptNumber = $failedAttemptCount + 1
    $result.terminalAfterCurrent = ($result.chainAttemptNumber -eq $maxAttempts)
    if ($result.terminalAfterCurrent) { $result.disposition = "DELETE_RETRY_TERMINAL" }

    if ($chainStatus -ne "ACTIVE") { $result.reason = "reacquisition_chain_not_active"; Write-Result ([pscustomobject]$result); exit 0 }
    if ($currentAlreadyRecorded) { $result.reason = "current_loop_key_already_recorded_in_chain"; Write-Result ([pscustomobject]$result); exit 0 }
    if ($result.chainAttemptNumber -gt $maxAttempts) { $result.reason = "maximum_chain_attempts_exceeded"; Write-Result ([pscustomobject]$result); exit 0 }

    $rollbackDescriptor = Get-PropertyValue -Object $chain -Name "rollback"
    $rollbackCheck = Test-ReacquisitionRollback -Rollback $rollbackDescriptor -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
    $result.rollback = [ordered]@{
        path = [string](Get-PropertyValue -Object $rollbackDescriptor -Name "path" -Default "")
        exists = $rollbackCheck.exists
        sizeMatches = $rollbackCheck.sizeMatches
        fingerprintMatches = $rollbackCheck.fingerprintMatches
        verified = $rollbackCheck.verified
    }
    if (-not $rollbackCheck.verified) { $result.reason = "canonical_rollback_not_verified"; Write-Result ([pscustomobject]$result); exit 0 }

    if ($result.terminalAfterCurrent) {
        $result.preRemovalSearch = [ordered]@{
            skipped = $true
            reason = "terminal_attempt_no_replacement_search"
        }
    }
    else {
        $preSearch = Get-ReleaseSearch -Connection $connection -EpisodeIds $episodeIds
        if ($preSearch.mode -eq "MULTI_EPISODE_SEARCH_ONLY") {
            $result.preRemovalSearch = [ordered]@{
                mode = $preSearch.mode
                skippedInteractiveCandidateGate = $true
                reason = "multi_episode_file_requires_exact_episode_set_search"
                episodeIds = @($episodeIds)
            }
        }
        else {
            $prePool = @($preSearch.approved + $preSearch.diskOnly)
            $preSelection = Select-ReacquisitionRelease -Releases $prePool -TriggerFindingCodes $triggerFindingCodes -Chain $chain
            $result.selectionStrategy = $preSelection.strategy
            $result.releaseSelection = ConvertTo-ReacquisitionReleaseSummary -Candidate $preSelection.selected
            $result.preRemovalSearch = [ordered]@{
                mode = $preSearch.mode
                totalReleaseCount = $preSearch.all.Count
                approvedCandidateCount = $preSearch.approved.Count
                diskOnlyBlockedCandidateCount = $preSearch.diskOnly.Count
                predictedCandidateCount = $preSearch.predicted.Count
                candidatePoolMode = "PREDICTED_AFTER_CURRENT_FILE_REMOVAL"
                selectionStrategy = $preSelection.strategy
                predictedSelectedCandidate = ConvertTo-ReacquisitionReleaseSummary -Candidate $preSelection.selected
            }
            if ($prePool.Count -le 0) { $result.reason = "no_predicted_candidates_after_current_file_removal"; Write-Result ([pscustomobject]$result); exit 0 }
        }
    }

    if (-not $Execute) {
        $result.status = "DRY_RUN_READY"
        $result.reason = $null
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($ConfirmChainId) -or $ConfirmChainId -ne $chainId -or
        [string]::IsNullOrWhiteSpace($ConfirmLoopKey) -or $ConfirmLoopKey -ne $loopKey) {
        $result.reason = "execute_chain_and_loop_confirmation_required"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $mutex = New-Object System.Threading.Mutex($false, "ReqestraMediaReacquisitionRetry")
    $mutexHeld = $false
    try {
        $mutexHeld = $mutex.WaitOne(0)
        if (-not $mutexHeld) { $result.reason = "retry_mutex_busy"; Write-Result ([pscustomobject]$result); exit 0 }

        # Re-verify the canonical rollback and current Arr file immediately before deletion.
        $freshRollback = Test-ReacquisitionRollback -Rollback $rollbackDescriptor -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
        if (-not $freshRollback.verified) { $result.reason = "canonical_rollback_changed_before_execute"; Write-Result ([pscustomobject]$result); exit 0 }
        $freshFile = Invoke-SonarrApi -Connection $connection -RelativePath ("episodefile/{0}" -f $fileId) -Method GET
        if (-not (Test-PathEquivalent -First ([string](Get-PropertyValue -Object $freshFile -Name "path" -Default "")) -Second $result.mediaPath) -or
            [int64](Get-PropertyValue -Object $freshFile -Name "size" -Default -1) -ne $expectedBytes) {
            $result.reason = "arr_file_changed_before_execute"; Write-Result ([pscustomobject]$result); exit 0
        }

        $statePath = Join-Path $RetryStateRoot ($loopKey + ".json")
        $result.statePath = $statePath
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $existing = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $existingStatus = [string](Get-PropertyValue -Object $existing -Name "status" -Default "")
            if ($existingStatus -notin @("ROLLED_BACK","COMPLETED")) {
                $result.reason = "existing_retry_transaction_requires_recovery"; Write-Result ([pscustomobject]$result); exit 0
            }
        }

        $transaction = [pscustomobject][ordered]@{
            schemaVersion = "1.0"
            executorVersion = $ExecutorVersion
            transactionId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + [guid]::NewGuid().ToString("N").Substring(0,8)
            chainId = $chainId
            loopKey = $loopKey
            seriesId = $seriesId
            episodeIds = @($episodeIds)
            fileId = $fileId
            mediaPath = $result.mediaPath
            releaseTitle = $sourceTitle
            startedUtc = [DateTime]::UtcNow.ToString("o")
            updatedUtc = [DateTime]::UtcNow.ToString("o")
            completedUtc = $null
            status = "STARTED"
            stage = "PREPARED"
            rollbackPath = [string](Get-PropertyValue -Object $rollbackDescriptor -Name "path" -Default "")
            searchCommandId = $null
            selectionStrategy = $result.selectionStrategy
            selectedRelease = $result.releaseSelection
            replacementGrabbed = $false
            replacementQueued = $false
            rollbackRestore = $null
        }
        Write-AtomicJson -Path $statePath -Object $transaction

        [void](Invoke-SonarrApi -Connection $connection -RelativePath ("episodefile/{0}" -f $fileId) -Method DELETE)
        $result.mutation.episodeFileDeleted = $true
        $result.mutation.mutatingRequestsSent++
        $transaction.stage = "FAILED_RETRY_DELETED"
        $transaction.updatedUtc = [DateTime]::UtcNow.ToString("o")
        Write-AtomicJson -Path $statePath -Object $transaction

        if (Test-Path -LiteralPath $result.mediaPath -PathType Leaf) { throw "Sonarr DELETE did not remove failed retry file." }
        $filesAfterDelete = @(Get-SonarrRecordArray -Response (Invoke-SonarrApi -Connection $connection -RelativePath (Get-SonarrEpisodeFilesRelativePath -SeriesId $seriesId) -Method GET))
        if (@($filesAfterDelete | Where-Object { [int](Get-PropertyValue -Object $_ -Name "id" -Default 0) -eq $fileId }).Count -gt 0) {
            throw "Sonarr episode-file record still exists after DELETE."
        }

        if ($result.terminalAfterCurrent) {
            # Terminal exhaustion must not leave the library empty. Restore the one
            # canonical rollback copy and verify Sonarr rediscovered it before the
            # chain is allowed to settle in TERMINAL_REVIEW_REQUIRED.
            $restore = Restore-ChainRollback -Connection $connection -ChainState $chain -DestinationPath $result.mediaPath
            $result.rollbackRestore = $restore
            $transaction.rollbackRestore = $restore

            if (-not $restore.sonarrRediscovered) {
                $chain.status = "RECOVERY_REQUIRED"
                $chain.updatedUtc = [DateTime]::UtcNow.ToString("o")
                Write-AtomicJson -Path $chainPath -Object $chain

                $transaction.status = "RECOVERY_REQUIRED"
                $transaction.stage = "TERMINAL_ROLLBACK_RESTORE_FAILED"
                $transaction.updatedUtc = [DateTime]::UtcNow.ToString("o")
                $transaction.completedUtc = [DateTime]::UtcNow.ToString("o")
                Write-AtomicJson -Path $statePath -Object $transaction

                $result.status = "RECOVERY_REQUIRED"
                $result.reason = "terminal_rollback_restore_failed"
                Write-Result ([pscustomobject]$result)
                exit 0
            }

            $attempts += [pscustomobject][ordered]@{
                attemptNumber = $result.chainAttemptNumber
                loopKey = $loopKey
                releaseTitle = $sourceTitle
                releaseGroup = [string](Get-PropertyValue -Object $releaseIdentity -Name "releaseGroup" -Default "")
                disposition = "FAILED_RETRY_DELETED_TERMINAL_ROLLBACK_RESTORED"
                deletedUtc = [DateTime]::UtcNow.ToString("o")
            }
            $chain.attempts = @($attempts)
            $chain.failedAttemptCount = $failedAttemptCount + 1
            $chain.status = "TERMINAL_REVIEW_REQUIRED"
            $chain.updatedUtc = [DateTime]::UtcNow.ToString("o")

            $rollbackState = Get-PropertyValue -Object $chain -Name "rollback"
            $originalRollbackPath = [string](Get-PropertyValue -Object $rollbackState -Name "path" -Default "")
            $rollbackState.path = $result.mediaPath
            $rollbackState | Add-Member -NotePropertyName "originalQuarantinePath" -NotePropertyValue $originalRollbackPath -Force
            $rollbackState | Add-Member -NotePropertyName "status" -NotePropertyValue "RESTORED_TO_LIBRARY_TERMINAL" -Force
            $rollbackState | Add-Member -NotePropertyName "restoredLibraryPath" -NotePropertyValue $result.mediaPath -Force
            $rollbackState | Add-Member -NotePropertyName "restoredFileId" -NotePropertyValue $restore.restoredFileId -Force
            $rollbackState | Add-Member -NotePropertyName "restoredUtc" -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
            Write-AtomicJson -Path $chainPath -Object $chain

            $transaction.status = "TERMINAL_REVIEW_REQUIRED"
            $transaction.stage = "MAX_CHAIN_ATTEMPTS_REACHED_ROLLBACK_RESTORED"
            $transaction.updatedUtc = [DateTime]::UtcNow.ToString("o")
            $transaction.completedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $statePath -Object $transaction

            $result.status = "TERMINAL_REVIEW_REQUIRED"
            $result.reason = "maximum_chain_attempts_reached_rollback_restored"
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        $postSearch = Get-ReleaseSearch -Connection $connection -EpisodeIds $episodeIds
        if ($postSearch.mode -eq "MULTI_EPISODE_SEARCH_ONLY") {
            $result.postRemovalSearch = [ordered]@{
                mode = $postSearch.mode
                skippedInteractiveCandidateGate = $true
                reason = "multi_episode_file_requires_exact_episode_set_search"
                episodeIds = @($episodeIds)
            }
        }
        else {
            $postSelection = Select-ReacquisitionRelease -Releases $postSearch.approved -TriggerFindingCodes $triggerFindingCodes -Chain $chain
            $result.selectionStrategy = $postSelection.strategy
            $result.releaseSelection = ConvertTo-ReacquisitionReleaseSummary -Candidate $postSelection.selected
            $result.postRemovalSearch = [ordered]@{
                mode = $postSearch.mode
                totalReleaseCount = $postSearch.all.Count
                approvedCandidateCount = $postSearch.approved.Count
                selectionStrategy = $postSelection.strategy
                selectedCandidate = ConvertTo-ReacquisitionReleaseSummary -Candidate $postSelection.selected
                topRankedCandidates = @(
                    @($postSelection.ranked | Select-Object -First 10) |
                        ForEach-Object { ConvertTo-ReacquisitionReleaseSummary -Candidate $_ }
                )
            }

            if ($postSearch.approved.Count -le 0) {
                $restore = Restore-ChainRollback -Connection $connection -ChainState $chain -DestinationPath $result.mediaPath
                $result.rollbackRestore = $restore
                $transaction.rollbackRestore = $restore
                $transaction.status = if ($restore.sonarrRediscovered) { "ROLLED_BACK" } else { "RECOVERY_REQUIRED" }
                $transaction.stage = "NO_APPROVED_CANDIDATES"
                $transaction.updatedUtc = [DateTime]::UtcNow.ToString("o")
                $transaction.completedUtc = [DateTime]::UtcNow.ToString("o")
                Write-AtomicJson -Path $statePath -Object $transaction
                $chain.status = if ($restore.sonarrRediscovered) { "ROLLED_BACK" } else { "RECOVERY_REQUIRED" }
                $chain.updatedUtc = [DateTime]::UtcNow.ToString("o")
                Write-AtomicJson -Path $chainPath -Object $chain
                $result.status = $transaction.status
                $result.reason = "no_approved_candidates_after_retry_delete"
                Write-Result ([pscustomobject]$result)
                exit 0
            }
        }

        $searchStartedUtc = [DateTime]::UtcNow
        try {
            $command = Invoke-SonarrApi -Connection $connection -RelativePath "command" -Method POST -Body (Get-SonarrSearchCommandBody -EpisodeIds $episodeIds)
            $commandId = [int](Get-PropertyValue -Object $command -Name "id" -Default 0)
            if ($commandId -le 0) { throw "Sonarr did not return a valid EpisodeSearch command id." }
            $result.mutation.episodeSearchSent = $true
            $result.mutation.mutatingRequestsSent++
            $transaction.searchCommandId = $commandId
            $transaction.stage = "SEARCH_SENT"
            $transaction.updatedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $statePath -Object $transaction
            $completed = Wait-SonarrCommand -Connection $connection -CommandId $commandId
            if ([string](Get-PropertyValue -Object $completed -Name "status" -Default "") -ne "completed") {
                throw "EpisodeSearch command did not complete."
            }
        }
        catch {
            $restore = Restore-ChainRollback -Connection $connection -ChainState $chain -DestinationPath $result.mediaPath
            $result.rollbackRestore = $restore
            $transaction.rollbackRestore = $restore
            $transaction.status = if ($restore.sonarrRediscovered) { "ROLLED_BACK" } else { "RECOVERY_REQUIRED" }
            $transaction.stage = "SEARCH_COMMAND_FAILED"
            $transaction.updatedUtc = [DateTime]::UtcNow.ToString("o")
            $transaction.completedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $statePath -Object $transaction
            $chain.status = if ($restore.sonarrRediscovered) { "ROLLED_BACK" } else { "RECOVERY_REQUIRED" }
            $chain.updatedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $chainPath -Object $chain
            $result.status = $transaction.status
            $result.reason = "episode_search_failed"
            $result.error = $_.Exception.Message
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        $grabbed = @()
        $queued = @()
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        do {
            $history = @(Get-SonarrRecordArray -Response (Invoke-SonarrApi -Connection $connection -RelativePath ("history/series?seriesId={0}&includeSeries=false" -f $seriesId) -Method GET))
            $grabbed = @($history | Where-Object {
                if ([string](Get-PropertyValue -Object $_ -Name "eventType" -Default "") -ne "grabbed") { return $false }
                try {
                    $date = [DateTime]::Parse([string](Get-PropertyValue -Object $_ -Name "date" -Default ""), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                    if ($date -lt $searchStartedUtc.AddSeconds(-1)) { return $false }
                    $historyEpisodeId = [int](Get-PropertyValue -Object $_ -Name "episodeId" -Default 0)
                    return ($historyEpisodeId -le 0 -or @($episodeIds) -contains $historyEpisodeId)
                }
                catch { return $false }
            })
            $queue = @(Get-SonarrRecordArray -Response (Invoke-SonarrApi -Connection $connection -RelativePath "queue?page=1&pageSize=100&includeUnknownSeriesItems=true" -Method GET))
            $queued = @($queue | Where-Object { Test-SonarrQueueRecordMatches -Record $_ -SeriesId $seriesId -EpisodeIds $episodeIds })
            if ($grabbed.Count -gt 0 -or $queued.Count -gt 0) { break }
            Start-Sleep -Seconds 3
        }
        while ([DateTime]::UtcNow -lt $deadline)

        $result.replacementActivity = [ordered]@{
            grabbed = ($grabbed.Count -gt 0)
            grabbedCount = $grabbed.Count
            grabbedTitles = @($grabbed | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "sourceTitle" -Default "") })
            queued = ($queued.Count -gt 0)
            queueCount = $queued.Count
            queueTitles = @($queued | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "title" -Default "") })
        }

        if ($grabbed.Count -eq 0 -and $queued.Count -eq 0) {
            $restore = Restore-ChainRollback -Connection $connection -ChainState $chain -DestinationPath $result.mediaPath
            $result.rollbackRestore = $restore
            $transaction.rollbackRestore = $restore
            $transaction.status = if ($restore.sonarrRediscovered) { "ROLLED_BACK" } else { "RECOVERY_REQUIRED" }
            $transaction.stage = "NO_REPLACEMENT_ACTIVITY"
            $transaction.updatedUtc = [DateTime]::UtcNow.ToString("o")
            $transaction.completedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $statePath -Object $transaction
            $chain.status = if ($restore.sonarrRediscovered) { "ROLLED_BACK" } else { "RECOVERY_REQUIRED" }
            $chain.updatedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $chainPath -Object $chain
            $result.status = $transaction.status
            $result.reason = "no_replacement_grab_or_queue_detected"
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        $attempts += [pscustomobject][ordered]@{
            attemptNumber = $result.chainAttemptNumber
            loopKey = $loopKey
            releaseTitle = $sourceTitle
            releaseGroup = [string](Get-PropertyValue -Object $releaseIdentity -Name "releaseGroup" -Default "")
            disposition = "FAILED_RETRY_DELETED"
            deletedUtc = [DateTime]::UtcNow.ToString("o")
        }
        $chain.attempts = @($attempts)
        $chain.failedAttemptCount = $failedAttemptCount + 1
        $chain.updatedUtc = [DateTime]::UtcNow.ToString("o")
        Write-AtomicJson -Path $chainPath -Object $chain

        $transaction.replacementGrabbed = ($grabbed.Count -gt 0)
        $transaction.replacementQueued = ($queued.Count -gt 0)
        $transaction.status = "RETRY_DELETED_REPLACEMENT_STARTED"
        $transaction.stage = "WAITING_FOR_REPLACEMENT_IMPORT"
        $transaction.updatedUtc = [DateTime]::UtcNow.ToString("o")
        Write-AtomicJson -Path $statePath -Object $transaction

        $result.status = "RETRY_DELETED_REPLACEMENT_STARTED"
        $result.reason = $null
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
    $result.reason = "reacquisition_retry_exception"
    $result.error = $_.Exception.Message
    Write-Result ([pscustomobject]$result)
    exit 0
}
