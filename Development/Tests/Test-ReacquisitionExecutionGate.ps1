[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Manual Reacquisition Execution Gate Test"
Write-Host "================================================="
Write-Host ""

function Test-ExecutionGate {
    param(
        [string]$Source,
        [string]$ExpectedLoopKey,
        [string]$SuppliedLoopKey,
        [int]$PriorAttempts,
        [int]$MaxAttempts,
        [bool]$IncompleteAttempt,
        [bool]$AlreadyFailed,
        [bool]$AlreadyBlocked
    )

    if ($Source -notin @("Radarr", "Sonarr")) { return "BLOCKED_SOURCE" }
    if ([string]::IsNullOrWhiteSpace($SuppliedLoopKey) -or $SuppliedLoopKey -ne $ExpectedLoopKey) { return "BLOCKED_CONFIRMATION" }
    if ($IncompleteAttempt) { return "RECOVERY_REQUIRED" }
    if ($PriorAttempts -ge $MaxAttempts) { return "BLOCKED_ATTEMPTS" }
    if ($AlreadyFailed) { return "BLOCKED_ALREADY_FAILED" }
    if ($AlreadyBlocked) { return "BLOCKED_ALREADY_BLOCKED" }
    return "AUTHORIZED"
}

$key = "abc123"

$tests = @(
    [pscustomobject]@{
        Test = "Radarr exact loop key authorizes"
        Passed = ((Test-ExecutionGate "Radarr" $key $key 0 3 $false $false $false) -eq "AUTHORIZED")
    },
    [pscustomobject]@{
        Test = "Missing loop key blocks"
        Passed = ((Test-ExecutionGate "Radarr" $key "" 0 3 $false $false $false) -eq "BLOCKED_CONFIRMATION")
    },
    [pscustomobject]@{
        Test = "Wrong loop key blocks"
        Passed = ((Test-ExecutionGate "Radarr" $key "wrong" 0 3 $false $false $false) -eq "BLOCKED_CONFIRMATION")
    },
    [pscustomobject]@{
        Test = "Sonarr exact loop key authorizes"
        Passed = ((Test-ExecutionGate "Sonarr" $key $key 0 3 $false $false $false) -eq "AUTHORIZED")
    },
    [pscustomobject]@{
        Test = "Unsupported source remains blocked"
        Passed = ((Test-ExecutionGate "Lidarr" $key $key 0 3 $false $false $false) -eq "BLOCKED_SOURCE")
    },
    [pscustomobject]@{
        Test = "Incomplete prior attempt requires recovery"
        Passed = ((Test-ExecutionGate "Radarr" $key $key 0 3 $true $false $false) -eq "RECOVERY_REQUIRED")
    },
    [pscustomobject]@{
        Test = "Attempt limit blocks"
        Passed = ((Test-ExecutionGate "Radarr" $key $key 3 3 $false $false $false) -eq "BLOCKED_ATTEMPTS")
    },
    [pscustomobject]@{
        Test = "Already failed history blocks replay"
        Passed = ((Test-ExecutionGate "Radarr" $key $key 1 3 $false $true $false) -eq "BLOCKED_ALREADY_FAILED")
    },
    [pscustomobject]@{
        Test = "Already blocklisted release blocks replay"
        Passed = ((Test-ExecutionGate "Radarr" $key $key 1 3 $false $false $true) -eq "BLOCKED_ALREADY_BLOCKED")
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} manual reacquisition gate tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} manual reacquisition gate tests failed." -f $failed.Count, $tests.Count)
exit 1
