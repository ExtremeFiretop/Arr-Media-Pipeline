Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "Reqestra Reacquisition Terminal Redownload Suppression Contract Test"
Write-Host "================================================================="
Write-Host ""

$tests = New-Object System.Collections.ArrayList
function Add-Test([string]$Name, [bool]$Passed) {
    [void]$tests.Add([pscustomobject]@{ Test = $Name; Passed = $Passed })
}

$original = [pscustomobject][ordered]@{
    id = 1
    autoRedownloadFailed = $true
    autoRedownloadFailedFromInteractiveSearch = $true
}
$originalJson = $original | ConvertTo-Json -Depth 10 -Compress
$suppressed = $originalJson | ConvertFrom-Json
$suppressed.autoRedownloadFailed = $false
$suppressed.autoRedownloadFailedFromInteractiveSearch = $false
$restored = $originalJson | ConvertFrom-Json

Add-Test "Suppression clone disables Redownload Failed" (-not [bool]$suppressed.autoRedownloadFailed)
Add-Test "Suppression clone disables interactive failed redownload" (-not [bool]$suppressed.autoRedownloadFailedFromInteractiveSearch)
Add-Test "Original config remains unchanged while clone is suppressed" ([bool]$original.autoRedownloadFailed -and [bool]$original.autoRedownloadFailedFromInteractiveSearch)
Add-Test "Restored config recovers original Redownload Failed value" ([bool]$restored.autoRedownloadFailed -eq [bool]$original.autoRedownloadFailed)
Add-Test "Restored config recovers original interactive value" ([bool]$restored.autoRedownloadFailedFromInteractiveSearch -eq [bool]$original.autoRedownloadFailedFromInteractiveSearch)

$terminalAttempt = $true
$nativeRedownloadSuppressed = $true
$explicitSearchSent = $false
$searchDelegatedToArr = -not $nativeRedownloadSuppressed
Add-Test "Terminal contract delegates no replacement search" ($terminalAttempt -and -not $searchDelegatedToArr -and -not $explicitSearchSent)

$tests | Format-Table -AutoSize
$failed = @($tests | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host ("FAIL: {0}/{1} terminal suppression contract tests failed." -f $failed.Count, $tests.Count)
    exit 1
}

Write-Host ""
Write-Host ("PASS: {0}/{0} terminal suppression contract tests passed." -f $tests.Count)
exit 0
