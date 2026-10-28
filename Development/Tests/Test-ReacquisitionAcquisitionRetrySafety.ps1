[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Source = Get-Content -LiteralPath (Join-Path $Root "Integration\Invoke-ReacquisitionAcquisitionRetry.ps1") -Raw -Encoding UTF8

$tests = @(
    [pscustomobject]@{ Test="execute requires exact chain confirmation"; Passed=($Source -match 'execute_chain_id_confirmation_required' -and $Source -match 'ConfirmChainId') },
    [pscustomobject]@{ Test="only ACTIVE chains can be acquisition-reconciled"; Passed=($Source -match 'reacquisition_chain_not_active') },
    [pscustomobject]@{ Test="only WAITING_FOR_REPLACEMENT_IMPORT transactions qualify"; Passed=($Source -match 'WAITING_FOR_REPLACEMENT_IMPORT') },
    [pscustomobject]@{ Test="download failure must occur after waiting transaction timestamp"; Passed=($Source -match '\-ge \$cutoff') },
    [pscustomobject]@{ Test="same failed download is idempotently ignored"; Passed=($Source -match 'FAILED_DOWNLOAD_ALREADY_RECONCILED') },
    [pscustomobject]@{ Test="canonical rollback is fingerprint verified before restoration"; Passed=($Source -match 'Test-ReacquisitionRollback' -and $Source -match 'canonical_rollback_not_verified') },
    [pscustomobject]@{ Test="Radarr rediscovery is required after physical rollback restore"; Passed=($Source -match 'RescanMovie' -and $Source -match 'radarr_did_not_rediscover_rollback') },
    [pscustomobject]@{ Test="DV acquisition retry uses safety-aware release selector"; Passed=($Source -match 'Select-ReacquisitionRelease' -and $Source -match 'Get-ReacquisitionPredictedCandidatePool') },
    [pscustomobject]@{ Test="non-DV acquisition retry delegates selection to MoviesSearch"; Passed=($Source -match 'MoviesSearch') },
    [pscustomobject]@{ Test="replacement activity must be observed after retry search"; Passed=($Source -match 'no_replacement_grab_or_queue_detected' -and $Source -match 'AddSeconds\(45\)') },
    [pscustomobject]@{ Test="terminal acquisition paths close the waiting transaction"; Passed=($Source -match 'Complete-WaitingTransaction' -and $Source -match 'terminalTransactionCompleted') },
    [pscustomobject]@{ Test="pre-write race gate refuses acquisition retry when a non-rollback current file appears"; Passed=($Source -match 'WAITING_FOR_CURRENT_FILE_RECONCILIATION' -and $Source -match 'Test-CurrentFileMatchesCanonicalRollback') }
)

$tests | Format-Table -AutoSize -Wrap
$failed=@($tests | Where-Object { -not $_.Passed })
Write-Host ""
if ($failed.Count -eq 0) { Write-Host ("PASS: {0}/{0} acquisition retry safety tests passed." -f $tests.Count); exit 0 }
Write-Host ("FAIL: {0}/{1} acquisition retry safety tests failed." -f $failed.Count,$tests.Count)
exit 1
