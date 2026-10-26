Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$IntegrationRoot = $PSScriptRoot
. (Join-Path $IntegrationRoot "ReacquisitionChainCommon.ps1")
. (Join-Path $IntegrationRoot "SonarrReacquisitionCommon.ps1")
. (Join-Path $IntegrationRoot "SonarrReacquisitionSuccessCommon.ps1")

$results = New-Object System.Collections.Generic.List[object]
function Add-TestResult {
    param([string]$Name, [bool]$Passed)
    $results.Add([pscustomobject]@{ Test = $Name; Passed = $Passed }) | Out-Null
}

Write-Host ""
Write-Host "Reqestra Sonarr Reacquisition Parity Contract Test"
Write-Host "=================================================="
Write-Host ""

# 1. Exact EpisodeSearch set is preserved.
$search = Get-SonarrSearchCommandBody -EpisodeIds @(101,102,103)
Add-TestResult "EpisodeSearch preserves exact episode-ID set" (
    $search.name -eq "EpisodeSearch" -and
    @($search.episodeIds).Count -eq 3 -and
    $search.episodeIds[0] -eq 101 -and
    $search.episodeIds[2] -eq 103
)

# 2. RescanSeries uses the exact series ID.
$rescan = Get-SonarrRescanCommandBody -SeriesId 77
Add-TestResult "Rollback reconciliation uses RescanSeries" (
    $rescan.name -eq "RescanSeries" -and $rescan.seriesId -eq 77
)

# 3. Single-episode release search is safe.
Add-TestResult "Single-episode interactive search uses episodeId" (
    (Get-SonarrReleaseSearchRelativePath -EpisodeIds @(501)) -eq "release?episodeId=501"
)

# 4. Multi-episode release list is intentionally not faked.
Add-TestResult "Multi-episode files skip single-episode interactive candidate gate" (
    $null -eq (Get-SonarrReleaseSearchRelativePath -EpisodeIds @(501,502))
)

# Sonarr chain storage must not collide for two episode files in the same series.
$keyA = Get-SonarrEpisodeSetKey -EpisodeIds @(501)
$keyB = Get-SonarrEpisodeSetKey -EpisodeIds @(502)
$pathA = Get-ReacquisitionChainPath -IntegrationRoot $IntegrationRoot -Source "Sonarr" -EntityId 77 -Discriminator $keyA
$pathB = Get-ReacquisitionChainPath -IntegrationRoot $IntegrationRoot -Source "Sonarr" -EntityId 77 -Discriminator $keyB
Add-TestResult "Same-series episode files receive independent chain paths" (
    $keyA -ne $keyB -and $pathA -ne $pathB -and
    [IO.Path]::GetFileName($pathA) -match '^Sonarr-77-episodes-'
)

$multiKeyForward = Get-SonarrEpisodeSetKey -EpisodeIds @(501,502)
$multiKeyReverse = Get-SonarrEpisodeSetKey -EpisodeIds @(502,501,501)
Add-TestResult "Episode-set chain identity is order-independent and duplicate-safe" (
    $multiKeyForward -eq $multiKeyReverse
)

# 5. Queue records must match the same series and, when present, episode set.
$q1 = [pscustomobject]@{ seriesId = 77; episodeId = 501 }
$q2 = [pscustomobject]@{ seriesId = 77; episodeId = 999 }
$q3 = [pscustomobject]@{ seriesId = 88; episodeId = 501 }
Add-TestResult "Queue activity is scoped to series and episode identity" (
    (Test-SonarrQueueRecordMatches -Record $q1 -SeriesId 77 -EpisodeIds @(501,502)) -and
    -not (Test-SonarrQueueRecordMatches -Record $q2 -SeriesId 77 -EpisodeIds @(501,502)) -and
    -not (Test-SonarrQueueRecordMatches -Record $q3 -SeriesId 77 -EpisodeIds @(501,502))
)

# 6. Success retirement accepts a valid Sonarr PASS replacement.
$chain = [pscustomobject]@{
    source = "Sonarr"
    entityId = 77
    status = "ACTIVE"
    maxAttempts = 3
    failedAttemptCount = 1
    episodeIds = @(501)
}
$bridge = [pscustomobject]@{ status = "VALIDATED"; effectiveOutcome = "PASS" }
$context = [pscustomobject]@{
    source = "Sonarr"
    entity = [pscustomobject]@{ id = 77 }
    episode = [pscustomobject]@{ ids = @(501) }
    file = [pscustomobject]@{ id = 9001; path = "V:\TV\Series\Season 01\Series S01E01.mkv" }
}
$current = [pscustomobject]@{
    mediaPath = "V:\TV\Series\Season 01\Series S01E01.mkv"
    lengthBytes = 123456789
    streamFingerprint = "abc123"
}
$arrFile = [pscustomobject]@{
    id = 9001
    path = "V:\TV\Series\Season 01\Series S01E01.mkv"
    size = 123456789
}
$rollback = [pscustomobject]@{
    verified = $true
    path = "V:\Reqestra Quarantine\Sonarr\77\rollback\Series S01E01.mkv"
}
$decision = Get-ReacquisitionSuccessDecision -Chain $chain -Bridge $bridge -Context $context `
    -CurrentSnapshot $current -CurrentEffectiveOutcome "PASS" -ArrFile $arrFile `
    -RollbackCheck $rollback -EventFingerprint "abc123"
Add-TestResult "Validated PASS replacement can retire Sonarr rollback" ($decision.eligible -eq $true)

# 7. Restored rollback cannot masquerade as success.
$rollbackSame = [pscustomobject]@{ verified = $true; path = $current.mediaPath }
$decisionSame = Get-ReacquisitionSuccessDecision -Chain $chain -Bridge $bridge -Context $context `
    -CurrentSnapshot $current -CurrentEffectiveOutcome "PASS" -ArrFile $arrFile `
    -RollbackCheck $rollbackSame -EventFingerprint "abc123"
Add-TestResult "Restored Sonarr rollback cannot be mistaken for success" (
    -not $decisionSame.eligible -and $decisionSame.reason -eq "current_file_is_canonical_rollback"
)

$wrongEpisodeContext = [pscustomobject]@{
    source = "Sonarr"
    entity = [pscustomobject]@{ id = 77 }
    episode = [pscustomobject]@{ ids = @(502) }
    file = [pscustomobject]@{ id = 9001; path = "V:\TV\Series\Season 01\Series S01E01.mkv" }
}
$wrongEpisodeDecision = Get-ReacquisitionSuccessDecision -Chain $chain -Bridge $bridge -Context $wrongEpisodeContext `
    -CurrentSnapshot $current -CurrentEffectiveOutcome "PASS" -ArrFile $arrFile `
    -RollbackCheck $rollback -EventFingerprint "abc123"
Add-TestResult "Successful replacement must cover the exact chain episode set" (
    -not $wrongEpisodeDecision.eligible -and $wrongEpisodeDecision.reason -eq "replacement_episode_set_does_not_match_chain"
)

# Verify mutation scripts contain the required Sonarr-specific authorities.
$markFailedText = Get-Content (Join-Path $IntegrationRoot "Invoke-Reacquisition.ps1") -Raw
$quarantineText = Get-Content (Join-Path $IntegrationRoot "Invoke-SonarrReacquisitionQuarantine.ps1") -Raw
$retryText = Get-Content (Join-Path $IntegrationRoot "Invoke-SonarrReacquisitionRetry.ps1") -Raw
$successText = Get-Content (Join-Path $IntegrationRoot "Complete-SonarrReacquisitionSuccess.ps1") -Raw
$chainText = Get-Content (Join-Path $IntegrationRoot "Initialize-SonarrReacquisitionChain.ps1") -Raw

Add-TestResult "MarkFailed executor allows Sonarr mutation" (
    $markFailedText -notmatch 'execute_supported_for_radarr_only' -and
    $markFailedText -match 'history/series\?seriesId=' -and
    $markFailedText -match 'history/failed/\$failureTargetHistoryId'
)

$logicalRows = @(
    [pscustomobject]@{
        id = 101; episodeId = 501; downloadId = "same-download"; sourceTitle = "Series.S01E01-E02.Group"
        data = [pscustomobject]@{ fileId = "9001"; importedPath = "V:\TV\Series\Season 01\Series S01E01-E02.mkv" }
    },
    [pscustomobject]@{
        id = 102; episodeId = 502; downloadId = "same-download"; sourceTitle = "Series.S01E01-E02.Group"
        data = [pscustomobject]@{ fileId = "9001"; importedPath = "V:\TV\Series\Season 01\Series S01E01-E02.mkv" }
    }
)
$logicalResolved = Resolve-SonarrLogicalHistoryMatch -Records $logicalRows -Role "import" `
    -ExpectedFileId 9001 -ExpectedPath "V:\TV\Series\Season 01\Series S01E01-E02.mkv" -ExpectedEpisodeIds @(501,502)
$conflictingRows = @($logicalRows[0], [pscustomobject]@{
    id = 103; episodeId = 999; downloadId = "different-download"; sourceTitle = "Other.Release"
    data = [pscustomobject]@{ fileId = "9002"; importedPath = "V:\TV\Series\Season 01\Other.mkv" }
})
$logicalRejected = Resolve-SonarrLogicalHistoryMatch -Records $conflictingRows -Role "import" `
    -ExpectedFileId 9001 -ExpectedPath "V:\TV\Series\Season 01\Series S01E01-E02.mkv" -ExpectedEpisodeIds @(501,502)
Add-TestResult "Multi-episode history rows collapse only for one consistent release identity" (
    $logicalResolved.resolved -and $logicalResolved.logicalMatchCount -eq 1 -and
    $logicalResolved.physicalMatchCount -eq 2 -and
    -not $logicalRejected.resolved -and $logicalRejected.ambiguous -and
    $logicalRejected.reason -eq "sonarr_history_rows_disagree_on_release_identity"
)

Add-TestResult "Sonarr quarantine deletes episodefile and searches exact episodes" (
    $quarantineText -match 'episodefile/\{0\}' -and
    $quarantineText -match 'Get-SonarrSearchCommandBody -EpisodeIds \$episodeIds' -and
    $quarantineText -match 'RescanSeries'
)

Add-TestResult "Sonarr retry preserves TV validation and terminal rollback restore" (
    $retryText -match 'LibraryType "TV"' -and
    $retryText -match 'TERMINAL_REVIEW_REQUIRED' -and
    $retryText -match 'Restore-ChainRollback'
)

Add-TestResult "Sonarr chain stores TV rollback identity" (
    $chainText -match 'source = "Sonarr"' -and
    $chainText -match 'libraryType = "TV"' -and
    $chainText -match 'episodeIds = @\(\$episodeIds\)'
)

Add-TestResult "Sonarr success retirement verifies episodefile ownership" (
    $successText -match 'episodefile/\{0\}' -and
    $successText -match 'COMPLETED_SUCCESS' -and
    $successText -match 'rollbackDeleted = \$false'
)

Add-TestResult "Sonarr quarantine accepts suppressed-redownload MarkFailed success" (
    $quarantineText -match 'SUCCESS_SEARCH_SUPPRESSED'
)

Add-TestResult "Sonarr first quarantine auto-initializes a verified active chain" (
    $quarantineText -match 'Initialize-SonarrChainFromQuarantine' -and
    $quarantineText -match 'CHAIN_INITIALIZATION_PENDING' -and
    $quarantineText -match 'chainStateInitialized' -and
    $quarantineText -match 'chain_initialization_failed_after_replacement_start'
)

$results | Format-Table -AutoSize
$passed = @($results | Where-Object Passed).Count
$total = $results.Count
Write-Host ""
if ($passed -eq $total) {
    Write-Host ("PASS: {0}/{1} Sonarr reacquisition parity contract tests passed." -f $passed, $total)
    exit 0
}
else {
    Write-Host ("FAIL: {0}/{1} Sonarr reacquisition parity contract tests passed." -f $passed, $total)
    exit 1
}
