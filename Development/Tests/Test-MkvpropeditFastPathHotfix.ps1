[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$IntegrationRoot = $PSScriptRoot
$ExecutorPath = Join-Path $IntegrationRoot "Invoke-Normalization.ps1"

if (-not (Test-Path -LiteralPath $ExecutorPath -PathType Leaf)) {
    throw "Executor not found: $ExecutorPath"
}

$text = Get-Content -LiteralPath $ExecutorPath -Raw -Encoding UTF8
$tests = @()

function Add-Test {
    param([string]$Name, [bool]$Passed)
    $script:tests += [pscustomobject]@{ Test = $Name; Passed = $Passed }
}

Add-Test "Executor version is 0.2.3" ($text -match '\$ExecutorVersion\s*=\s*"0\.2\.3"')
Add-Test "mkvpropedit resolver exists" ($text -match 'function\s+Resolve-Mkvpropedit')
Add-Test "Source is staged with File.Copy before edit" ($text -match '\[System\.IO\.File\]::Copy\(\$mediaPath,\s*\$tempPath')
Add-Test "Fast path edits staged temp path, not media path" ($text -match '\$propeditArgs\s*=\s*@\(\$tempPath\)')
Add-Test "Audio ordinal selector is used" ($text -match 'track:a\{0\}')
Add-Test "Only flag-default is set by fast path" ($text -match 'flag-default=\{0\}')
Add-Test "Strict temp fingerprint gate remains" ($text -match '\$tempFingerprint\s*-ne\s*\$expectedFingerprint')
Add-Test "Atomic File.Replace promotion remains" ($text -match '\[System\.IO\.File\]::Replace\(\$tempPath,\s*\$mediaPath,\s*\$backupPath')
Add-Test "Large-file free-space arithmetic remains" ($text -match '\$freeSpaceReserveBytes' -and $text -match '\[int64\]\$item\.Length\s*\+\s*\$freeSpaceReserveBytes')
Add-Test "Full mkvmerge remux path removed" ($text -notmatch '\$mkvmergeArgs\s*=\s*@\("-o"')

Write-Host "MKVPropEdit Fast-Path Hotfix Test"
Write-Host "================================="
Write-Host ""
$tests | Format-Table Test,Passed -AutoSize

$failed = @($tests | Where-Object { -not $_.Passed })
Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{0} fast-path hotfix checks passed." -f $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} checks failed." -f $failed.Count, $tests.Count)
exit 1
