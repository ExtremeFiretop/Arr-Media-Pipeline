[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Worker Property Persistence Regression Test"
Write-Host "===================================================="
Write-Host ""

$job = [pscustomobject][ordered]@{
    state = "PREFLIGHT"
    reason = $null
    completedUtc = $null
}

function Set-JobProperty {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($Job.PSObject.Properties[$Name]) {
        $Job.$Name = $Value
    }
    else {
        $Job | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

Set-JobProperty -Job $job -Name "workerVersion" -Value "0.1.1"
Set-JobProperty -Job $job -Name "executorProcessExitCode" -Value 0
Set-JobProperty -Job $job -Name "executorStdoutPath" -Value "stdout.txt"
Set-JobProperty -Job $job -Name "executorStderrPath" -Value "stderr.txt"
Set-JobProperty -Job $job -Name "error" -Value "example"
Set-JobProperty -Job $job -Name "error" -Value $null

$tests = @(
    [pscustomobject]@{
        Test = "Adds missing workerVersion property"
        Passed = ($job.workerVersion -eq "0.1.1")
    },
    [pscustomobject]@{
        Test = "Adds missing executorProcessExitCode property"
        Passed = ($job.executorProcessExitCode -eq 0)
    },
    [pscustomobject]@{
        Test = "Adds missing stdout/stderr properties"
        Passed = ($job.executorStdoutPath -eq "stdout.txt" -and $job.executorStderrPath -eq "stderr.txt")
    },
    [pscustomobject]@{
        Test = "Adds and updates missing error property"
        Passed = ($job.PSObject.Properties["error"] -and $null -eq $job.error)
    }
)

$tests | Format-Table -AutoSize

$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} worker persistence regression tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} tests failed." -f $failed.Count, $tests.Count)
exit 1
