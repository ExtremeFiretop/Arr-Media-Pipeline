[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Automatic Execute Recovery Policy Test"
Write-Host "================================================"
Write-Host ""

function Get-RecoveryPolicy {
    param(
        [string]$QueueMode,
        [bool]$WriteAttempted,
        [bool]$CompleteExecutionResultExists
    )

    if ($QueueMode -ne "AUTO_EXECUTE") {
        return "REQUEUE"
    }

    if (-not $WriteAttempted) {
        return "REQUEUE"
    }

    if ($CompleteExecutionResultExists) {
        return "FINALIZE_FROM_RESULT"
    }

    return "RECOVERY_REQUIRED"
}

$tests = @(
    [pscustomobject]@{
        Test = "Dry-run interruption can requeue"
        Passed = ((Get-RecoveryPolicy "AUTO_DRY_RUN" $false $false) -eq "REQUEUE")
    },
    [pscustomobject]@{
        Test = "Execute job before write launch can requeue"
        Passed = ((Get-RecoveryPolicy "AUTO_EXECUTE" $false $false) -eq "REQUEUE")
    },
    [pscustomobject]@{
        Test = "Execute job after write launch never blindly requeues"
        Passed = ((Get-RecoveryPolicy "AUTO_EXECUTE" $true $false) -eq "RECOVERY_REQUIRED")
    },
    [pscustomobject]@{
        Test = "Completed executor result can finalize interrupted execute job"
        Passed = ((Get-RecoveryPolicy "AUTO_EXECUTE" $true $true) -eq "FINALIZE_FROM_RESULT")
    }
)

$tests | Format-Table -AutoSize -Wrap

$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} automatic execute recovery policy tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} tests failed." -f $failed.Count, $tests.Count)
exit 1
