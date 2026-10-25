[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "MaintenanceCommon.ps1")

Write-Host ""
Write-Host "Reqestra Media Maintenance Self-Test"
Write-Host "===================================="
Write-Host ""

function New-Execution {
    param(
        [string]$Mode = "EXECUTE",
        [string]$Status = "SUCCESS",
        [bool]$BackupDeleted = $false,
        [bool]$ArrSucceeded = $true,
        $Rollback = $null
    )

    return [pscustomobject][ordered]@{
        mode = $Mode
        status = $Status
        backupPath = "M:\Movies\Test\Test.reqestra-backup.bak"
        backupDeleted = $BackupDeleted
        rollback = $Rollback
        arrReconciliation = [pscustomobject]@{
            succeeded = $ArrSucceeded
        }
    }
}

$tests = @()

$d = Get-BackupStaticDecision -Execution (New-Execution) -BackupExists $true -MediaExists $true -AgeDays 8 -RetentionDays 7
$tests += [pscustomobject]@{ Test = "Successful reconciled backup becomes eligible after retention"; Passed = ($d.eligible -and $null -eq $d.reason) }

$d = Get-BackupStaticDecision -Execution (New-Execution) -BackupExists $true -MediaExists $true -AgeDays 6.9 -RetentionDays 7
$tests += [pscustomobject]@{ Test = "Young backup is retained"; Passed = (-not $d.eligible -and $d.reason -eq "retention_period_not_met") }

$d = Get-BackupStaticDecision -Execution (New-Execution -Status "NORMALIZED_RECONCILIATION_FAILED" -ArrSucceeded $false) -BackupExists $true -MediaExists $true -AgeDays 30 -RetentionDays 7
$tests += [pscustomobject]@{ Test = "Reconciliation failure protects backup"; Passed = (-not $d.eligible) }

$d = Get-BackupStaticDecision -Execution (New-Execution -Rollback ([pscustomobject]@{ succeeded = $true })) -BackupExists $true -MediaExists $true -AgeDays 30 -RetentionDays 7
$tests += [pscustomobject]@{ Test = "Rollback record protects backup"; Passed = (-not $d.eligible -and $d.reason -eq "rollback_record_present") }

$d = Get-BackupStaticDecision -Execution (New-Execution) -BackupExists $true -MediaExists $false -AgeDays 30 -RetentionDays 7
$tests += [pscustomobject]@{ Test = "Missing current media protects backup"; Passed = (-not $d.eligible -and $d.reason -eq "current_media_missing") }

$t = Get-TempStaticDecision -ArtifactKind "ORDINARY_TEMP" -Exists $true -AgeHours 25 -RetentionHours 24
$tests += [pscustomobject]@{ Test = "Old ordinary temp becomes eligible"; Passed = ($t.eligible) }

$t = Get-TempStaticDecision -ArtifactKind "ORDINARY_TEMP" -Exists $true -AgeHours 23 -RetentionHours 24
$tests += [pscustomobject]@{ Test = "Young ordinary temp is retained"; Passed = (-not $t.eligible -and $t.reason -eq "temp_retention_period_not_met") }

$t = Get-TempStaticDecision -ArtifactKind "FAILED_REPLACEMENT" -Exists $true -AgeHours 10000 -RetentionHours 24
$tests += [pscustomobject]@{ Test = "Failed replacement temp is always protected"; Passed = (-not $t.eligible -and $t.reason -eq "failed_replacement_protected") }

$legacyExecution = [pscustomobject][ordered]@{
    mode = "EXECUTE"
    status = "SUCCESS"
    backupPath = "V:\TV Shows\Legacy\Legacy.reqestra-backup.bak"
}

$d = Get-BackupStaticDecision `
    -Execution $legacyExecution `
    -BackupExists $true `
    -MediaExists $true `
    -AgeDays 30 `
    -RetentionDays 7

$tests += [pscustomobject]@{
    Test = "Legacy result missing reconciliation is safely retained"
    Passed = (-not $d.eligible -and $d.reason -eq "arr_reconciliation_not_confirmed")
}

$tests | Format-Table -AutoSize -Wrap

$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} media maintenance tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} tests failed." -f $failed.Count, $tests.Count)
exit 1
