[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Reacquisition Recovery Gate Test"
Write-Host "========================================="
Write-Host ""

function Get-RecoveryDecision {
    param(
        [bool]$HasRepairableLegacyAttempt,
        [bool]$RecoverRequested,
        [bool]$WrongTarget,
        [bool]$MutationSent,
        [bool]$FailedHistoryVerified,
        [bool]$BlocklistVerified
    )

    $repairable = (
        $HasRepairableLegacyAttempt -and
        $WrongTarget -and
        $MutationSent -and
        $FailedHistoryVerified -and
        -not $BlocklistVerified
    )

    if ($repairable -and -not $RecoverRequested) {
        return "RECOVERY_READY"
    }

    if ($repairable -and $RecoverRequested) {
        return "REPAIR_AUTHORIZED"
    }

    return "NORMAL"
}

$tests = @(
    [pscustomobject]@{
        Test = "Legacy wrong-target attempt requires explicit recovery"
        Passed = ((Get-RecoveryDecision $true $false $true $true $true $false) -eq "RECOVERY_READY")
    },
    [pscustomobject]@{
        Test = "Recover flag authorizes exact repair path"
        Passed = ((Get-RecoveryDecision $true $true $true $true $true $false) -eq "REPAIR_AUTHORIZED")
    },
    [pscustomobject]@{
        Test = "Verified blocklist is not treated as repairable"
        Passed = ((Get-RecoveryDecision $true $false $true $true $true $true) -eq "NORMAL")
    },
    [pscustomobject]@{
        Test = "Unsent mutation is not treated as repairable"
        Passed = ((Get-RecoveryDecision $true $false $true $false $false $false) -eq "NORMAL")
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} reacquisition recovery gate tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} reacquisition recovery gate tests failed." -f $failed.Count, $tests.Count)
exit 1
