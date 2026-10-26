[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CommonPath = Join-Path $PSScriptRoot "ReacquisitionSuccessCommon.ps1"
. $CommonPath

function New-BaseFixture {
    $chain = [pscustomobject]@{
        source = "Radarr"
        entityId = 1458
        status = "ACTIVE"
        maxAttempts = 3
        failedAttemptCount = 1
    }
    $bridge = [pscustomobject]@{ status = "VALIDATED"; effectiveOutcome = "PASS" }
    $context = [pscustomobject]@{
        source = "Radarr"
        entity = [pscustomobject]@{ id = 1458 }
        file = [pscustomobject]@{ id = 9001; path = "M:\Movies\Movie\good.mkv" }
    }
    $snapshot = [pscustomobject]@{
        mediaPath = "M:\Movies\Movie\good.mkv"
        lengthBytes = 1000
        streamFingerprint = "good-fingerprint"
    }
    $arr = [pscustomobject]@{ id = 9001; path = "M:\Movies\Movie\good.mkv"; size = 1000 }
    $rollback = [pscustomobject]@{ verified = $true; path = "M:\Reqestra Quarantine\Radarr\1458\abc\bad.mkv" }
    return [pscustomobject]@{ chain=$chain; bridge=$bridge; context=$context; snapshot=$snapshot; arr=$arr; rollback=$rollback; eventFingerprint="good-fingerprint" }
}

$tests = @()
function Add-Test([string]$Name, [bool]$Passed) {
    $script:tests += [pscustomobject]@{ Test = $Name; Passed = $Passed }
}
function Decide($f) {
    Get-ReacquisitionSuccessDecision -Chain $f.chain -Bridge $f.bridge -Context $f.context `
        -CurrentSnapshot $f.snapshot -CurrentEffectiveOutcome "PASS" -ArrFile $f.arr `
        -RollbackCheck $f.rollback -EventFingerprint $f.eventFingerprint
}

$f = New-BaseFixture
$d = Decide $f
Add-Test "Validated PASS replacement on active Radarr chain is eligible" ($d.eligible -and $d.nextAttemptNumber -eq 2)

$f = New-BaseFixture
$f.bridge.effectiveOutcome = "NORMALIZE"
$d = Decide $f
Add-Test "NORMALIZE import does not retire rollback" (-not $d.eligible -and $d.reason -eq "event_effective_outcome_not_pass")

$f = New-BaseFixture
$d = Get-ReacquisitionSuccessDecision -Chain $f.chain -Bridge $f.bridge -Context $f.context -CurrentSnapshot $f.snapshot `
    -CurrentEffectiveOutcome "REVIEW" -ArrFile $f.arr -RollbackCheck $f.rollback -EventFingerprint $f.eventFingerprint
Add-Test "Current contextual REVIEW blocks retirement" (-not $d.eligible -and $d.reason -eq "current_effective_outcome_not_pass")

$f = New-BaseFixture
$f.chain.status = "TERMINAL_REVIEW_REQUIRED"
$d = Decide $f
Add-Test "Terminal rollback restoration cannot be mistaken for success" (-not $d.eligible -and $d.reason -eq "reacquisition_chain_not_active")

$f = New-BaseFixture
$f.chain.status = "COMPLETED_SUCCESS"
$d = Decide $f
Add-Test "Completed success is idempotent" (-not $d.eligible -and $d.idempotent -and $d.reason -eq "chain_already_completed_success")

$f = New-BaseFixture
$f.rollback.verified = $false
$d = Decide $f
Add-Test "Unverified rollback is never deleted" (-not $d.eligible -and $d.reason -eq "canonical_rollback_not_verified")

$f = New-BaseFixture
$f.arr.size = 999
$d = Decide $f
Add-Test "Radarr file size mismatch blocks retirement" (-not $d.eligible -and $d.reason -eq "radarr_replacement_file_mismatch")

$f = New-BaseFixture
$f.eventFingerprint = "old-fingerprint"
$d = Decide $f
Add-Test "Replacement changed since event validation blocks retirement" (-not $d.eligible -and $d.reason -eq "replacement_changed_since_validated_event")

$f = New-BaseFixture
$f.rollback.path = $f.context.file.path
$d = Decide $f
Add-Test "Canonical rollback itself cannot be retired as successful replacement" (-not $d.eligible -and $d.reason -eq "current_file_is_canonical_rollback")

$f = New-BaseFixture
$f.context.entity.id = 999
$d = Decide $f
Add-Test "Replacement must belong to the same chain entity" (-not $d.eligible -and $d.reason -eq "replacement_does_not_match_chain_entity")

$f = New-BaseFixture
$f.chain.failedAttemptCount = 3
$d = Decide $f
Add-Test "Attempt ceiling already reached blocks success retirement on an ACTIVE-corrupt chain" (-not $d.eligible -and $d.reason -eq "chain_attempt_ceiling_already_reached")

Write-Host ""
Write-Host "Reqestra Reacquisition Success Retirement Contract Test"
Write-Host "======================================================"
Write-Host ""
$tests | Format-Table -AutoSize
Write-Host ""
$passed = @($tests | Where-Object Passed).Count
$total = $tests.Count
if ($passed -ne $total) {
    Write-Host ("FAIL: {0}/{1} reacquisition success-retirement contract tests passed." -f $passed, $total)
    exit 1
}
Write-Host ("PASS: {0}/{1} reacquisition success-retirement contract tests passed." -f $passed, $total)
exit 0
