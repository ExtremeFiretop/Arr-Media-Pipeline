[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$MovieId,

    [string]$JsonOut = "",

    [switch]$Execute,

    [string]$ConfirmChainId = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "0.1.0"
$IntegrationRoot = $PSScriptRoot
$CommonPath = Join-Path $IntegrationRoot "ReacquisitionChainCommon.ps1"
$SelectorPath = Join-Path $IntegrationRoot "ReacquisitionReleaseSelector.ps1"
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"
$ValidatorPath = Join-Path (Split-Path -Parent $IntegrationRoot) "MediaValidator.ps1"
$PolicyPath = Join-Path (Split-Path -Parent $IntegrationRoot) "validator-policy.json"
$WorkRoot = Join-Path $IntegrationRoot "Reacquisition\acquisition-retry-work"
$QuarantineStateRoot = Join-Path $IntegrationRoot "Reacquisition\quarantine-state"
$RetryStateRoot = Join-Path $IntegrationRoot "Reacquisition\retry-state"

. $CommonPath
. $SelectorPath

function Write-Result {
    param($Object)
    if (-not [string]::IsNullOrWhiteSpace($JsonOut)) {
        $Object | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    }
    $Object | ConvertTo-Json -Depth 60
}

function Get-RadarrConnection {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Integration config not found: $ConfigPath"
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $radarr = Get-PropertyValue -Object $config -Name "radarr" -Default $null
    $baseUrl = [string](Get-PropertyValue -Object $radarr -Name "baseUrl" -Default "")
    $apiKey = [string](Get-PropertyValue -Object $radarr -Name "apiKey" -Default "")
    if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Radarr integration config requires baseUrl and apiKey."
    }
    return [pscustomobject]@{ baseUrl=$baseUrl.TrimEnd("/"); apiKey=$apiKey }
}

function Invoke-Radarr {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [ValidateSet("GET","POST","PUT","DELETE")][string]$Method = "GET",
        $Body = $null
    )
    $headers = @{ "X-Api-Key" = $Connection.apiKey }
    $uri = $Connection.baseUrl + "/api/v3/" + $RelativePath.TrimStart("/")
    $args = @{ Uri=$uri; Headers=$headers; Method=$Method; TimeoutSec=60 }
    if ($null -ne $Body) {
        $args["Body"] = ($Body | ConvertTo-Json -Depth 30)
        $args["ContentType"] = "application/json"
    }
    return Invoke-RestMethod @args
}

function Get-RecordArray {
    param($Response)
    if ($null -eq $Response) { return @() }
    $records = Get-PropertyValue -Object $Response -Name "records" -Default $null
    if ($null -ne $records) { return @($records) }
    return @($Response)
}

function Get-UtcDate {
    param($Value)
    if ($null -eq $Value) { return [DateTime]::MinValue }
    try {
        return [DateTime]::Parse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    }
    catch { return [DateTime]::MinValue }
}

function Wait-RadarrCommand {
    param($Connection,[int]$CommandId,[int]$TimeoutSeconds=300)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $last=Invoke-Radarr -Connection $Connection -RelativePath ("command/{0}" -f $CommandId) -Method GET
        $status=[string](Get-PropertyValue -Object $last -Name "status" -Default "")
        if ($status -notin @("queued","started")) { return $last }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for Radarr command $CommandId."
}

function Get-HistoryDownloadId {
    param($Record)
    $direct=[string](Get-PropertyValue -Object $Record -Name "downloadId" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($direct)) { return $direct }
    $data=Get-PropertyValue -Object $Record -Name "data" -Default $null
    return [string](Get-PropertyValue -Object $data -Name "downloadId" -Default "")
}

function Get-HistoryIdentity {
    param($Record)
    $id=[string](Get-PropertyValue -Object $Record -Name "id" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($id)) { return "history-id:"+$id }
    $date=[string](Get-PropertyValue -Object $Record -Name "date" -Default "")
    $title=[string](Get-PropertyValue -Object $Record -Name "sourceTitle" -Default "")
    $downloadId=Get-HistoryDownloadId -Record $Record
    return "history-fallback:"+$date+"|"+$downloadId+"|"+$title
}

function Get-LatestWaitingTransaction {
    param([int]$Id)
    $records=@()
    foreach ($root in @($QuarantineStateRoot,$RetryStateRoot)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
            try {
                $state=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([int](Get-PropertyValue -Object $state -Name "movieId" -Default 0) -ne $Id) { continue }
                $stage=[string](Get-PropertyValue -Object $state -Name "stage" -Default "")
                if ($stage -ne "WAITING_FOR_REPLACEMENT_IMPORT") { continue }
                $records += [pscustomobject]@{
                    path=$file.FullName
                    state=$state
                    updated=Get-UtcDate (Get-PropertyValue -Object $state -Name "updatedUtc" -Default "")
                }
            }
            catch {}
        }
    }
    if ($records.Count -eq 0) { return $null }
    return @($records | Sort-Object updated -Descending)[0]
}

function Get-OriginalMediaPath {
    param($Chain)
    $rollback=Get-PropertyValue -Object $Chain -Name "rollback" -Default $null
    $planPath=[string](Get-PropertyValue -Object $rollback -Name "sourcePlanPath" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($planPath) -and (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        try {
            $plan=Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $path=[string](Get-PropertyValue -Object $plan -Name "mediaPath" -Default "")
            if (-not [string]::IsNullOrWhiteSpace($path)) { return $path }
        }
        catch {}
    }
    return ""
}

function Get-TriggerFindingCodes {
    param($Chain)
    $rollback=Get-PropertyValue -Object $Chain -Name "rollback" -Default $null
    $planPath=[string](Get-PropertyValue -Object $rollback -Name "sourcePlanPath" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($planPath) -and (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        try {
            $plan=Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
            return @(Get-PropertyValue -Object $plan -Name "triggerFindingCodes" -Default @())
        }
        catch {}
    }
    return @()
}

function Test-CurrentFileMatchesCanonicalRollback {
    param($Chain,$CurrentFile)
    $rollback=Get-PropertyValue -Object $Chain -Name "rollback" -Default $null
    $expectedBytes=[int64](Get-PropertyValue -Object $rollback -Name "lengthBytes" -Default -1)
    $expectedFingerprint=[string](Get-PropertyValue -Object $rollback -Name "streamFingerprint" -Default "")
    $currentPath=[string](Get-PropertyValue -Object $CurrentFile -Name "path" -Default "")
    $result=[ordered]@{ matches=$false; path=$currentPath; sizeMatches=$false; fingerprintMatches=$false; reason=$null }
    if ([string]::IsNullOrWhiteSpace($currentPath) -or -not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
        $result.reason="current_movie_file_missing"; return [pscustomobject]$result
    }
    $actualBytes=[int64](Get-Item -LiteralPath $currentPath).Length
    $result.sizeMatches=($actualBytes -eq $expectedBytes)
    if (-not $result.sizeMatches) { $result.reason="current_file_size_differs_from_canonical_rollback"; return [pscustomobject]$result }
    $snapshot=Invoke-ValidatorSnapshot -MediaPath $currentPath -LibraryType "Movie" -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
    $actualFingerprint=[string](Get-PropertyValue -Object $snapshot -Name "streamFingerprint" -Default "")
    $result.fingerprintMatches=[string]::Equals($actualFingerprint,$expectedFingerprint,[System.StringComparison]::Ordinal)
    $result.matches=($result.sizeMatches -and $result.fingerprintMatches)
    if (-not $result.matches) { $result.reason="current_file_fingerprint_differs_from_canonical_rollback" }
    return [pscustomobject]$result
}

function Restore-CanonicalRollback {
    param($Connection,$Chain,[int]$Id)

    $rollback=Get-PropertyValue -Object $Chain -Name "rollback" -Default $null
    $rollbackPath=[string](Get-PropertyValue -Object $rollback -Name "path" -Default "")
    $expectedBytes=[int64](Get-PropertyValue -Object $rollback -Name "lengthBytes" -Default -1)
    $expectedFingerprint=[string](Get-PropertyValue -Object $rollback -Name "streamFingerprint" -Default "")
    $destination=Get-OriginalMediaPath -Chain $Chain

    $result=[ordered]@{
        attempted=$true; restored=$false; alreadyPresent=$false; path=$destination; fileId=$null; reason=$null
    }

    $currentFiles=@(Get-RecordArray -Response (Invoke-Radarr -Connection $Connection -RelativePath ("moviefile?movieId={0}" -f $Id) -Method GET))
    if ($currentFiles.Count -gt 0) {
        if ($currentFiles.Count -ne 1) { $result.reason="multiple_current_movie_files"; return [pscustomobject]$result }
        $current=$currentFiles[0]
        $currentPath=[string](Get-PropertyValue -Object $current -Name "path" -Default "")
        if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) { $result.reason="current_movie_file_missing"; return [pscustomobject]$result }
        $snapshot=Invoke-ValidatorSnapshot -MediaPath $currentPath -LibraryType "Movie" -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
        $sizeMatches=([int64](Get-Item -LiteralPath $currentPath).Length -eq $expectedBytes)
        $fpMatches=[string]::Equals($snapshot.streamFingerprint,$expectedFingerprint,[System.StringComparison]::Ordinal)
        if (-not ($sizeMatches -and $fpMatches)) { $result.reason="current_file_is_not_canonical_rollback"; return [pscustomobject]$result }
        $result.restored=$true; $result.alreadyPresent=$true; $result.path=$currentPath
        $result.fileId=[int](Get-PropertyValue -Object $current -Name "id" -Default 0)
        return [pscustomobject]$result
    }

    if ([string]::IsNullOrWhiteSpace($destination)) { $result.reason="original_media_path_unavailable"; return [pscustomobject]$result }
    $check=Test-ReacquisitionRollback -Rollback $rollback -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
    if (-not $check.verified) { $result.reason="canonical_rollback_not_verified"; return [pscustomobject]$result }
    if (Test-Path -LiteralPath $destination -PathType Leaf) { $result.reason="rollback_destination_already_contains_file"; return [pscustomobject]$result }

    $destDir=Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Move-Item -LiteralPath $rollbackPath -Destination $destination

    $command=Invoke-Radarr -Connection $Connection -RelativePath "command" -Method POST -Body ([ordered]@{ name="RescanMovie"; movieId=$Id })
    $commandId=[int](Get-PropertyValue -Object $command -Name "id" -Default 0)
    if ($commandId -le 0) { throw "Radarr did not return a RescanMovie command id." }
    [void](Wait-RadarrCommand -Connection $Connection -CommandId $commandId -TimeoutSeconds 300)

    $filesAfter=@(Get-RecordArray -Response (Invoke-Radarr -Connection $Connection -RelativePath ("moviefile?movieId={0}" -f $Id) -Method GET))
    $match=@($filesAfter | Where-Object {
        Test-PathEquivalent -First ([string](Get-PropertyValue -Object $_ -Name "path" -Default "")) -Second $destination
    })
    if ($match.Count -ne 1) { $result.reason="radarr_did_not_rediscover_rollback"; return [pscustomobject]$result }
    if ([int64](Get-PropertyValue -Object $match[0] -Name "size" -Default -1) -ne $expectedBytes) { $result.reason="rediscovered_rollback_size_mismatch"; return [pscustomobject]$result }

    $rollback | Add-Member -NotePropertyName "originalQuarantinePath" -NotePropertyValue $rollbackPath -Force
    $rollback.path=$destination
    $rollback | Add-Member -NotePropertyName "status" -NotePropertyValue "RESTORED_TO_LIBRARY_TERMINAL" -Force
    $rollback | Add-Member -NotePropertyName "restoredUtc" -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
    $rollback | Add-Member -NotePropertyName "restoredFileId" -NotePropertyValue ([int](Get-PropertyValue -Object $match[0] -Name "id" -Default 0)) -Force

    $result.restored=$true
    $result.path=$destination
    $result.fileId=[int](Get-PropertyValue -Object $match[0] -Name "id" -Default 0)
    return [pscustomobject]$result
}

function Set-ChainReviewRequired {
    param($Chain,[string]$ChainPath,[string]$Reason,$Connection,[int]$Id)
    $restore=Restore-CanonicalRollback -Connection $Connection -Chain $Chain -Id $Id
    if (-not $restore.restored) {
        $Chain.status="RECOVERY_REQUIRED"
        $Chain | Add-Member -NotePropertyName "recoveryReason" -NotePropertyValue ("terminal_rollback_restore_failed:"+$restore.reason) -Force
    }
    else {
        $Chain.status="REVIEW_REQUIRED"
        $Chain | Add-Member -NotePropertyName "terminalReason" -NotePropertyValue $Reason -Force
    }
    $Chain.updatedUtc=[DateTime]::UtcNow.ToString("o")
    Write-AtomicJson -Path $ChainPath -Object $Chain
    return $restore
}

function Complete-WaitingTransaction {
    param(
        $TransactionRecord,
        [string]$Status,
        [string]$Stage,
        [string]$Reason,
        $RollbackRestore = $null
    )
    if ($null -eq $TransactionRecord) { return $false }
    $state=Get-PropertyValue -Object $TransactionRecord -Name "state" -Default $null
    $path=[string](Get-PropertyValue -Object $TransactionRecord -Name "path" -Default "")
    if ($null -eq $state -or [string]::IsNullOrWhiteSpace($path)) { return $false }
    $state.status=$Status
    $state.stage=$Stage
    $state.updatedUtc=[DateTime]::UtcNow.ToString("o")
    $state.completedUtc=[DateTime]::UtcNow.ToString("o")
    $state | Add-Member -NotePropertyName "reconciliationReason" -NotePropertyValue $Reason -Force
    if ($null -ne $RollbackRestore) {
        $state | Add-Member -NotePropertyName "rollbackRestore" -NotePropertyValue $RollbackRestore -Force
    }
    Write-AtomicJson -Path $path -Object $state
    return $true
}

$result=[ordered]@{
    schemaVersion="1.0"
    scriptVersion=$ScriptVersion
    timestampUtc=[DateTime]::UtcNow.ToString("o")
    mode=if ($Execute) { "EXECUTE" } else { "DRY_RUN" }
    status="BLOCKED"
    reason=$null
    movieId=$MovieId
    chainId=$null
    chainPath=$null
    transactionPath=$null
    failedDownload=$null
    acquisitionFailureCount=0
    maxAcquisitionFailures=3
    triggerFindingCodes=@()
    selectionStrategy=$null
    selectedRelease=$null
    replacementActivity=$null
    currentFileGate=$null
    rollbackRestore=$null
    mutation=[ordered]@{ chainUpdated=$false; transactionUpdated=$false; searchSent=$false; releaseGrabSent=$false; terminalTransactionCompleted=$false }
    error=$null
}

try {
    if ($MovieId -le 0) { $result.reason="movie_id_invalid"; Write-Result ([pscustomobject]$result); exit 0 }

    $chainPath=Get-ReacquisitionChainPath -IntegrationRoot $IntegrationRoot -Source "Radarr" -EntityId $MovieId
    $result.chainPath=$chainPath
    if (-not (Test-Path -LiteralPath $chainPath -PathType Leaf)) { $result.reason="reacquisition_chain_missing"; Write-Result ([pscustomobject]$result); exit 0 }
    $chain=Get-Content -LiteralPath $chainPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $chainId=[string](Get-PropertyValue -Object $chain -Name "chainId" -Default "")
    $result.chainId=$chainId
    if ([string](Get-PropertyValue -Object $chain -Name "status" -Default "") -ne "ACTIVE") { $result.reason="reacquisition_chain_not_active"; Write-Result ([pscustomobject]$result); exit 0 }

    $transaction=Get-LatestWaitingTransaction -Id $MovieId
    if ($null -eq $transaction) { $result.reason="waiting_transaction_not_found"; Write-Result ([pscustomobject]$result); exit 0 }
    $result.transactionPath=$transaction.path

    $connection=Get-RadarrConnection
    $queue=@(Get-RecordArray -Response (Invoke-Radarr -Connection $connection -RelativePath "queue?page=1&pageSize=1000&includeUnknownMovieItems=true" -Method GET) | Where-Object {
        [int](Get-PropertyValue -Object $_ -Name "movieId" -Default 0) -eq $MovieId
    })
    if ($queue.Count -gt 0) { $result.status="WAITING_FOR_EXISTING_QUEUE"; $result.reason=$null; Write-Result ([pscustomobject]$result); exit 0 }

    $history=@(Get-RecordArray -Response (Invoke-Radarr -Connection $connection -RelativePath ("history/movie?movieId={0}&includeMovie=false" -f $MovieId) -Method GET))
    $cutoff=$transaction.updated
    $failures=@($history | Where-Object {
        if ([string](Get-PropertyValue -Object $_ -Name "eventType" -Default "") -ne "downloadFailed") { return $false }
        return (Get-UtcDate (Get-PropertyValue -Object $_ -Name "date" -Default "")) -ge $cutoff
    } | Sort-Object { Get-UtcDate (Get-PropertyValue -Object $_ -Name "date" -Default "") } -Descending)
    if ($failures.Count -eq 0) { $result.status="NO_FAILED_DOWNLOAD_TO_RECONCILE"; $result.reason=$null; Write-Result ([pscustomobject]$result); exit 0 }

    $failure=$failures[0]
    $failureIdentity=Get-HistoryIdentity -Record $failure
    $failureTitle=[string](Get-PropertyValue -Object $failure -Name "sourceTitle" -Default "")
    $failureDate=[string](Get-PropertyValue -Object $failure -Name "date" -Default "")
    $failureDownloadId=Get-HistoryDownloadId -Record $failure
    $result.failedDownload=[ordered]@{ identity=$failureIdentity; sourceTitle=$failureTitle; date=$failureDate; downloadId=$failureDownloadId }

    $existingFailures=@(Get-PropertyValue -Object $chain -Name "acquisitionFailures" -Default @())
    if (@($existingFailures | Where-Object { [string](Get-PropertyValue -Object $_ -Name "identity" -Default "") -eq $failureIdentity }).Count -gt 0) {
        $result.status="FAILED_DOWNLOAD_ALREADY_RECONCILED"; $result.reason=$null; $result.acquisitionFailureCount=$existingFailures.Count; Write-Result ([pscustomobject]$result); exit 0
    }

    $maxAcquisition=[int](Get-PropertyValue -Object $chain -Name "maxAcquisitionFailures" -Default 3)
    if ($maxAcquisition -le 0) { $maxAcquisition=3 }
    $nextFailureCount=$existingFailures.Count+1
    $result.acquisitionFailureCount=$nextFailureCount
    $result.maxAcquisitionFailures=$maxAcquisition
    $triggerCodes=@(Get-TriggerFindingCodes -Chain $chain)
    $result.triggerFindingCodes=@($triggerCodes)

    if (-not $Execute) {
        $result.status=if ($nextFailureCount -ge $maxAcquisition) { "DRY_RUN_TERMINAL_REVIEW_READY" } else { "DRY_RUN_READY" }
        $result.reason=$null
        Write-Result ([pscustomobject]$result); exit 0
    }

    if ([string]::IsNullOrWhiteSpace($ConfirmChainId) -or -not [string]::Equals($ConfirmChainId,$chainId,[System.StringComparison]::Ordinal)) {
        $result.reason="execute_chain_id_confirmation_required"; Write-Result ([pscustomobject]$result); exit 0
    }

    # Recheck live Radarr state immediately before any new search. A Connect/import
    # can race the reconciler after its initial read; if that happens, the fresh
    # import must be reconciled instead of launching another replacement search.
    $freshQueue=@(Get-RecordArray -Response (Invoke-Radarr -Connection $connection -RelativePath "queue?page=1&pageSize=1000&includeUnknownMovieItems=true" -Method GET) | Where-Object {
        [int](Get-PropertyValue -Object $_ -Name "movieId" -Default 0) -eq $MovieId
    })
    if ($freshQueue.Count -gt 0) {
        $result.status="WAITING_FOR_EXISTING_QUEUE"; $result.reason=$null; Write-Result ([pscustomobject]$result); exit 0
    }

    $freshFiles=@(Get-RecordArray -Response (Invoke-Radarr -Connection $connection -RelativePath ("moviefile?movieId={0}" -f $MovieId) -Method GET))
    if ($freshFiles.Count -gt 1) {
        $result.status="BLOCKED"; $result.reason="multiple_current_movie_files"; Write-Result ([pscustomobject]$result); exit 0
    }
    if ($freshFiles.Count -eq 1) {
        $currentGate=Test-CurrentFileMatchesCanonicalRollback -Chain $chain -CurrentFile $freshFiles[0]
        $result.currentFileGate=$currentGate
        if (-not $currentGate.matches) {
            $result.status="WAITING_FOR_CURRENT_FILE_RECONCILIATION"
            $result.reason="current_file_requires_import_reconciliation_before_acquisition_retry"
            Write-Result ([pscustomobject]$result); exit 0
        }
    }

    $existingFailures += [pscustomobject][ordered]@{
        identity=$failureIdentity
        sourceTitle=$failureTitle
        downloadId=$failureDownloadId
        failedUtc=$failureDate
        reconciledUtc=[DateTime]::UtcNow.ToString("o")
    }
    $chain | Add-Member -NotePropertyName "acquisitionFailures" -NotePropertyValue @($existingFailures) -Force
    $chain | Add-Member -NotePropertyName "acquisitionFailureCount" -NotePropertyValue $existingFailures.Count -Force
    $chain | Add-Member -NotePropertyName "maxAcquisitionFailures" -NotePropertyValue $maxAcquisition -Force

    if ($nextFailureCount -ge $maxAcquisition) {
        $result.rollbackRestore=Set-ChainReviewRequired -Chain $chain -ChainPath $chainPath -Reason "acquisition_failure_limit_reached" -Connection $connection -Id $MovieId
        $result.mutation.chainUpdated=$true
        $result.status=if ([string](Get-PropertyValue -Object $chain -Name "status" -Default "") -eq "REVIEW_REQUIRED") { "TERMINAL_REVIEW_REQUIRED" } else { "RECOVERY_REQUIRED" }
        $result.reason=if ($result.status -eq "TERMINAL_REVIEW_REQUIRED") { "acquisition_failure_limit_reached" } else { "terminal_rollback_restore_failed" }
        $terminalStage=if ($result.status -eq "TERMINAL_REVIEW_REQUIRED") { "ACQUISITION_FAILURE_LIMIT_ROLLBACK_RESTORED" } else { "ACQUISITION_FAILURE_LIMIT_ROLLBACK_RESTORE_FAILED" }
        $result.mutation.terminalTransactionCompleted=Complete-WaitingTransaction -TransactionRecord $transaction -Status $result.status -Stage $terminalStage -Reason $result.reason -RollbackRestore $result.rollbackRestore
        $result.mutation.transactionUpdated=$result.mutation.terminalTransactionCompleted
        Write-Result ([pscustomobject]$result); exit 0
    }

    $isDv=($triggerCodes -contains "video.dolby_vision")
    $searchStartedUtc=[DateTime]::UtcNow
    if ($isDv) {
        $releaseResponse=Invoke-Radarr -Connection $connection -RelativePath ("release?movieId={0}" -f $MovieId) -Method GET
        $all=@(Get-RecordArray -Response $releaseResponse)
        $predicted=@(Get-ReacquisitionPredictedCandidatePool -Releases $all)
        $selection=Select-ReacquisitionRelease -Releases $predicted -TriggerFindingCodes $triggerCodes -Chain $chain
        $result.selectionStrategy=$selection.strategy
        $result.selectedRelease=ConvertTo-ReacquisitionReleaseSummary -Candidate $selection.selected
        if ($null -eq $selection.selected) {
            $result.rollbackRestore=Set-ChainReviewRequired -Chain $chain -ChainPath $chainPath -Reason "no_dv_safe_candidate_after_download_failure" -Connection $connection -Id $MovieId
            $result.mutation.chainUpdated=$true
            $result.status=if ([string](Get-PropertyValue -Object $chain -Name "status" -Default "") -eq "REVIEW_REQUIRED") { "TERMINAL_REVIEW_REQUIRED" } else { "RECOVERY_REQUIRED" }
            $result.reason=if ($result.status -eq "TERMINAL_REVIEW_REQUIRED") { "no_dv_safe_candidate_after_download_failure" } else { "terminal_rollback_restore_failed" }
            $terminalStage=if ($result.status -eq "TERMINAL_REVIEW_REQUIRED") { "NO_DV_SAFE_CANDIDATE_ROLLBACK_RESTORED" } else { "NO_DV_SAFE_CANDIDATE_ROLLBACK_RESTORE_FAILED" }
            $result.mutation.terminalTransactionCompleted=Complete-WaitingTransaction -TransactionRecord $transaction -Status $result.status -Stage $terminalStage -Reason $result.reason -RollbackRestore $result.rollbackRestore
            $result.mutation.transactionUpdated=$result.mutation.terminalTransactionCompleted
            Write-Result ([pscustomobject]$result); exit 0
        }
        [void](Invoke-Radarr -Connection $connection -RelativePath "release" -Method POST -Body $selection.selectedRelease)
        $result.mutation.releaseGrabSent=$true
    }
    else {
        $command=Invoke-Radarr -Connection $connection -RelativePath "command" -Method POST -Body ([ordered]@{ name="MoviesSearch"; movieIds=@($MovieId) })
        $commandId=[int](Get-PropertyValue -Object $command -Name "id" -Default 0)
        if ($commandId -le 0) { throw "Radarr did not return a valid MoviesSearch command id." }
        $result.mutation.searchSent=$true
        [void](Wait-RadarrCommand -Connection $connection -CommandId $commandId -TimeoutSeconds 300)
    }

    $grabbed=@(); $queued=@(); $deadline=[DateTime]::UtcNow.AddSeconds(45)
    do {
        $freshHistory=@(Get-RecordArray -Response (Invoke-Radarr -Connection $connection -RelativePath ("history/movie?movieId={0}&includeMovie=false" -f $MovieId) -Method GET))
        $grabbed=@($freshHistory | Where-Object {
            if ([string](Get-PropertyValue -Object $_ -Name "eventType" -Default "") -ne "grabbed") { return $false }
            return (Get-UtcDate (Get-PropertyValue -Object $_ -Name "date" -Default "")) -ge $searchStartedUtc.AddSeconds(-1)
        })
        $queued=@(Get-RecordArray -Response (Invoke-Radarr -Connection $connection -RelativePath "queue?page=1&pageSize=1000&includeUnknownMovieItems=true" -Method GET) | Where-Object {
            [int](Get-PropertyValue -Object $_ -Name "movieId" -Default 0) -eq $MovieId
        })
        if ($grabbed.Count -gt 0 -or $queued.Count -gt 0) { break }
        Start-Sleep -Seconds 3
    } while ([DateTime]::UtcNow -lt $deadline)

    $result.replacementActivity=[ordered]@{
        grabbed=($grabbed.Count -gt 0); grabbedCount=$grabbed.Count
        grabbedTitles=@($grabbed | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "sourceTitle" -Default "") })
        queued=($queued.Count -gt 0); queueCount=$queued.Count
        queueTitles=@($queued | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "title" -Default "") })
    }

    if ($grabbed.Count -eq 0 -and $queued.Count -eq 0) {
        $result.rollbackRestore=Set-ChainReviewRequired -Chain $chain -ChainPath $chainPath -Reason "no_replacement_activity_after_failed_download_reconcile" -Connection $connection -Id $MovieId
        $result.mutation.chainUpdated=$true
        $result.status=if ([string](Get-PropertyValue -Object $chain -Name "status" -Default "") -eq "REVIEW_REQUIRED") { "TERMINAL_REVIEW_REQUIRED" } else { "RECOVERY_REQUIRED" }
        $result.reason=if ($result.status -eq "TERMINAL_REVIEW_REQUIRED") { "no_replacement_grab_or_queue_detected" } else { "terminal_rollback_restore_failed" }
        $terminalStage=if ($result.status -eq "TERMINAL_REVIEW_REQUIRED") { "NO_REPLACEMENT_ACTIVITY_ROLLBACK_RESTORED" } else { "NO_REPLACEMENT_ACTIVITY_ROLLBACK_RESTORE_FAILED" }
        $result.mutation.terminalTransactionCompleted=Complete-WaitingTransaction -TransactionRecord $transaction -Status $result.status -Stage $terminalStage -Reason $result.reason -RollbackRestore $result.rollbackRestore
        $result.mutation.transactionUpdated=$result.mutation.terminalTransactionCompleted
        Write-Result ([pscustomobject]$result); exit 0
    }

    $chain.updatedUtc=[DateTime]::UtcNow.ToString("o")
    Write-AtomicJson -Path $chainPath -Object $chain
    $result.mutation.chainUpdated=$true

    $state=$transaction.state
    $state | Add-Member -NotePropertyName "lastReconciledDownloadFailure" -NotePropertyValue $failureIdentity -Force
    $state | Add-Member -NotePropertyName "acquisitionFailureCount" -NotePropertyValue $existingFailures.Count -Force
    $state.status="ACQUISITION_RETRY_STARTED"
    $state.stage="WAITING_FOR_REPLACEMENT_IMPORT"
    $state.updatedUtc=[DateTime]::UtcNow.ToString("o")
    Write-AtomicJson -Path $transaction.path -Object $state
    $result.mutation.transactionUpdated=$true

    $result.status="ACQUISITION_RETRY_STARTED"
    $result.reason=$null
    Write-Result ([pscustomobject]$result)
    exit 0
}
catch {
    $result.status="FAILED"
    $result.reason="acquisition_retry_exception"
    $result.error=$_.Exception.Message
    Write-Result ([pscustomobject]$result)
    exit 0
}
