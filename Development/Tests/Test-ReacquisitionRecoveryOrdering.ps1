[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Reacquisition Recovery Ordering Test"
Write-Host "============================================="
Write-Host ""

function Get-Decision {
    param(
        [bool]$Execute,
        [bool]$AlreadyBlocklisted,
        [bool]$RecoverablePriorMutation,
        [bool]$PersistedFailedHistory,
        [bool]$RecoverRequested
    )

    if (-not $Execute) {
        if ($AlreadyBlocklisted) { return "BLOCKED_EXISTING" }
        return "DRY_RUN_READY"
    }

    # Recovery evidence must be considered before the duplicate-write guard.
    if ($RecoverablePriorMutation -and $AlreadyBlocklisted -and $PersistedFailedHistory) {
        if ($RecoverRequested) { return "SUCCESS_RECOVERED" }
        return "RECOVERY_READY"
    }

    if ($AlreadyBlocklisted) {
        return "BLOCKED_EXISTING"
    }

    return "NEW_EXECUTION_ALLOWED"
}

$tests = @(
    [pscustomobject]@{
        Test = "Dry-run remains blocked for already blocklisted release"
        Passed = ((Get-Decision $false $true $false $false $false) -eq "BLOCKED_EXISTING")
    },
    [pscustomobject]@{
        Test = "Existing successful mutation reaches recovery before block guard"
        Passed = ((Get-Decision $true $true $true $true $false) -eq "RECOVERY_READY")
    },
    [pscustomobject]@{
        Test = "Recover flag finalizes existing successful mutation"
        Passed = ((Get-Decision $true $true $true $true $true) -eq "SUCCESS_RECOVERED")
    },
    [pscustomobject]@{
        Test = "Fresh duplicate execute remains blocked"
        Passed = ((Get-Decision $true $true $false $false $false) -eq "BLOCKED_EXISTING")
    },
    [pscustomobject]@{
        Test = "Unblocked fresh release may proceed to new execution"
        Passed = ((Get-Decision $true $false $false $false $false) -eq "NEW_EXECUTION_ALLOWED")
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} reacquisition recovery-ordering tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} reacquisition recovery-ordering tests failed." -f $failed.Count, $tests.Count)
exit 1
