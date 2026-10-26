[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Reacquisition Chain Contract Test"
Write-Host "==========================================="
Write-Host ""

. (Join-Path $PSScriptRoot "ReacquisitionChainCommon.ps1")


function Get-RetryDecision {
    param(
        [bool]$ChainExists,
        [bool]$RollbackVerified,
        [int]$FailedAttemptCount,
        [int]$MaxAttempts,
        [bool]$CurrentAlreadyRecorded
    )

    if (-not $ChainExists) { return "BLOCK_NO_CHAIN" }
    if (-not $RollbackVerified) { return "BLOCK_ROLLBACK" }
    if ($CurrentAlreadyRecorded) { return "BLOCK_DUPLICATE" }

    $attemptNumber = $FailedAttemptCount + 1
    if ($attemptNumber -gt $MaxAttempts) { return "BLOCK_MAX" }
    if ($attemptNumber -eq $MaxAttempts) { return "DELETE_RESTORE_TERMINAL" }
    return "DELETE_RETRY"
}

function Get-RollbackSelection {
    param([object[]]$Candidates)

    $eligible = @(
        $Candidates |
            Where-Object { $_.exists -and $_.sizeMatches } |
            Sort-Object startedUtc
    )

    if ($eligible.Count -eq 0) { return $null }
    return $eligible[0]
}

$selection = Get-RollbackSelection @(
    [pscustomobject]@{ name = "second"; startedUtc = [DateTime]"2026-10-25T04:18:00Z"; exists = $true; sizeMatches = $true },
    [pscustomobject]@{ name = "original"; startedUtc = [DateTime]"2026-10-25T03:45:00Z"; exists = $true; sizeMatches = $true }
)

$tests = @(
    [pscustomobject]@{
        Test = "Earliest verified quarantine becomes rollback"
        Passed = ($null -ne $selection -and $selection.name -eq "original")
    },
    [pscustomobject]@{
        Test = "Missing chain blocks retry deletion"
        Passed = ((Get-RetryDecision $false $true 1 3 $false) -eq "BLOCK_NO_CHAIN")
    },
    [pscustomobject]@{
        Test = "Unverified rollback blocks retry deletion"
        Passed = ((Get-RetryDecision $true $false 1 3 $false) -eq "BLOCK_ROLLBACK")
    },
    [pscustomobject]@{
        Test = "Second failed release can be deleted with one rollback preserved"
        Passed = ((Get-RetryDecision $true $true 1 3 $false) -eq "DELETE_RETRY")
    },
    [pscustomobject]@{
        Test = "Third failed release is deleted, rollback restored, then chain terminates"
        Passed = ((Get-RetryDecision $true $true 2 3 $false) -eq "DELETE_RESTORE_TERMINAL")
    },
    [pscustomobject]@{
        Test = "Attempt beyond chain ceiling is blocked"
        Passed = ((Get-RetryDecision $true $true 3 3 $false) -eq "BLOCK_MAX")
    },
    [pscustomobject]@{
        Test = "Already-recorded loop key is not processed twice"
        Passed = ((Get-RetryDecision $true $true 1 3 $true) -eq "BLOCK_DUPLICATE")
    },
    [pscustomobject]@{
        Test = "German ISO-639 alias matches planner fingerprint normalization"
        Passed = ((Normalize-Language "deu") -eq "ger" -and (Normalize-Language "de") -eq "ger")
    },
    [pscustomobject]@{
        Test = "Chinese ISO-639 alias matches planner fingerprint normalization"
        Passed = ((Normalize-Language "zho") -eq "chi" -and (Normalize-Language "zh") -eq "chi")
    },
    [pscustomobject]@{
        Test = "Japanese language alias matches planner fingerprint normalization"
        Passed = ((Normalize-Language "ja") -eq "jpn")
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} reacquisition chain contract tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} reacquisition chain contract tests failed." -f $failed.Count, $tests.Count)
exit 1
