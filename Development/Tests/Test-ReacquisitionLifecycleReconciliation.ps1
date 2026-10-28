[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Worker = Get-Content -LiteralPath (Join-Path $Root "Integration\ReacquisitionWorker.ps1") -Raw -Encoding UTF8
$Reconciler = Get-Content -LiteralPath (Join-Path $Root "Integration\ReacquisitionReconciler.ps1") -Raw -Encoding UTF8
$AcquisitionRetry = Get-Content -LiteralPath (Join-Path $Root "Integration\Invoke-ReacquisitionAcquisitionRetry.ps1") -Raw -Encoding UTF8
$Selector = Get-Content -LiteralPath (Join-Path $Root "Integration\ReacquisitionReleaseSelector.ps1") -Raw -Encoding UTF8

$tests = @(
    [pscustomobject]@{
        Test = "worker version advanced for lifecycle reconciliation"
        Passed = ($Worker -match '\$WorkerVersion\s*=\s*"0\.2\.3"')
    },
    [pscustomobject]@{
        Test = "history consistency expiry is deferred instead of permanent BLOCKED"
        Passed = ($Worker -match 'WAITING_HISTORY_CONSISTENCY' -and $Worker -match 'exact_import_history_not_found')
    },
    [pscustomobject]@{
        Test = "stale current-media decision is deferred for a fresh bridge replay"
        Passed = ($Worker -match 'WAITING_FRESH_REVALIDATION' -and $Worker -match 'current_media_no_longer_requires_reacquisition')
    },
    [pscustomobject]@{
        Test = "missing retry evidence is deferred for reconciliation"
        Passed = ($Worker -match 'WAITING_STATE_RECONCILIATION' -and $Worker -match 'reacquisition_state_missing')
    },
    [pscustomobject]@{
        Test = "no-candidate replacement state terminalizes instead of remaining ACTIVE"
        Passed = ($Worker -match 'TerminalizeNoCandidate' -and $Worker -match 'REVIEW_REQUIRED_ROLLBACK_RESTORED' -and $Worker -match 'TERMINAL_REVIEW_REQUIRED')
    },
    [pscustomobject]@{
        Test = "Radarr retry candidate gate includes approved plus disk-only predicted releases"
        Passed = ((Get-Content -LiteralPath (Join-Path $Root "Integration\Invoke-ReacquisitionRetry.ps1") -Raw -Encoding UTF8) -match '\$prePool\s*=\s*@\(\$preSearch\.predicted\)')
    },
    [pscustomobject]@{
        Test = "reconciler requires idle reacquisition queue"
        Passed = ($Reconciler -match 'DEFERRED_QUEUE_BUSY' -and $Reconciler -match 'reacquisition_queue_not_idle')
    },
    [pscustomobject]@{
        Test = "reconciler replays a fresh Radarr bridge for stranded imports"
        Passed = ($Reconciler -match 'Invoke-RadarrBridgeReplay' -and $Reconciler -match 'IMPORTED_CHAIN_REPLAY' -and $Reconciler -match 'ReqestraArrBridge\.ps1')
    },
    [pscustomobject]@{
        Test = "reconciler supports explicit movie canaries without changing scheduled all-chain behavior"
        Passed = ($Reconciler -match 'TargetMovieId' -and $Reconciler -match '\$TargetMovieId\s+-contains')
    },
    [pscustomobject]@{
        Test = "import replay is bounded and can escalate to RECOVERY_REQUIRED"
        Passed = ($Reconciler -match 'MaxImportReplays' -and $Reconciler -match 'IMPORTED_RECONCILIATION_EXHAUSTED' -and $Reconciler -match 'import_replay_limit_reached')
    },
    [pscustomobject]@{
        Test = "failed download without import routes to acquisition reconciliation"
        Passed = ($Reconciler -match 'FAILED_DOWNLOAD_RECONCILIATION' -and $Reconciler -match 'Invoke-ReacquisitionAcquisitionRetry\.ps1')
    },
    [pscustomobject]@{
        Test = "failed-download retries use their own bounded counter"
        Passed = ($AcquisitionRetry -match 'acquisitionFailures' -and $AcquisitionRetry -match 'acquisitionFailureCount' -and $AcquisitionRetry -match 'maxAcquisitionFailures')
    },
    [pscustomobject]@{
        Test = "DV selector excludes exact acquisition-failed release titles"
        Passed = ($Selector -match 'acquisitionFailures' -and $Selector -match 'sourceTitle')
    },
    [pscustomobject]@{
        Test = "failed-download retry does not increment media failedAttemptCount"
        Passed = ($AcquisitionRetry -notmatch '\.failedAttemptCount\s*=')
    },
    [pscustomobject]@{
        Test = "failed-download retry refuses a second search while Radarr queue exists"
        Passed = ($AcquisitionRetry -match 'WAITING_FOR_EXISTING_QUEUE')
    },
    [pscustomobject]@{
        Test = "failed-download exhaustion restores canonical rollback before terminal review"
        Passed = ($AcquisitionRetry -match 'Restore-CanonicalRollback' -and $AcquisitionRetry -match 'acquisition_failure_limit_reached')
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })
Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{0} lifecycle reconciliation tests passed." -f $tests.Count)
    exit 0
}
Write-Host ("FAIL: {0}/{1} lifecycle reconciliation tests failed." -f $failed.Count,$tests.Count)
exit 1
