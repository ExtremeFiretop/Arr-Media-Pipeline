[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$QueueCommonPath = Join-Path $ProjectRoot "Integration\ReacquisitionQueueCommon.ps1"
if (-not (Test-Path -LiteralPath $QueueCommonPath -PathType Leaf)) {
    throw "ReacquisitionQueueCommon.ps1 not found: $QueueCommonPath"
}

$source = Get-Content -LiteralPath $QueueCommonPath -Raw -Encoding UTF8
$tests = @(
    [pscustomobject]@{ Test = "Worker launcher does not assign PowerShell reserved PID variable"; Passed = ($source -notmatch '(?im)^\s*\$pid\s*=') },
    [pscustomobject]@{ Test = "Worker launcher captures child process ID in non-reserved variable"; Passed = ($source -match '\$processId\s*=\s*\$p\.Id') },
    [pscustomobject]@{ Test = "Worker launcher reports captured processId"; Passed = ($source -match 'processId\s*=\s*\$processId') },
    [pscustomobject]@{ Test = "Worker process is started before process ID capture"; Passed = ($source -match '\[void\]\$p\.Start\(\)[\s\S]*\$processId\s*=\s*\$p\.Id') }
)

Write-Host ""
Write-Host "Reacquisition Worker Launcher Contract Test"
Write-Host "==========================================="
Write-Host ""
$tests | Format-Table -AutoSize
$failed = @($tests | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host ("FAIL: {0}/{1} tests failed." -f $failed.Count,$tests.Count)
    exit 1
}
Write-Host ""
Write-Host ("PASS: {0}/{0} reacquisition worker launcher tests passed." -f $tests.Count)
exit 0
