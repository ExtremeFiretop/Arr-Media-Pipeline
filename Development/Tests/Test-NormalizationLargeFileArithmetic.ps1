[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ExecutorPath = Join-Path $PSScriptRoot "Invoke-Normalization.ps1"
$ExecutorText = Get-Content -LiteralPath $ExecutorPath -Raw

$tests = New-Object System.Collections.Generic.List[object]

function Add-Test {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ""
    )

    $tests.Add([pscustomobject]@{
        Test = $Name
        Passed = $Passed
        Details = $Details
    }) | Out-Null
}

$largeBytes = [int64]40309802397
$largeReserve = [int64][Math]::Ceiling([Math]::Max([double]1073741824, ([double]$largeBytes * 0.10)))
$largeRequired = [int64]$largeBytes + $largeReserve

$smallBytes = [int64]7038596876
$smallReserve = [int64][Math]::Ceiling([Math]::Max([double]1073741824, ([double]$smallBytes * 0.10)))
$smallRequired = [int64]$smallBytes + $smallReserve

Add-Test "Executor version is 0.2.2" ($ExecutorText -match '\$ExecutorVersion\s*=\s*"0\.2\.2"')
Add-Test "Old ambiguous Math.Max expression is absent" (-not $ExecutorText.Contains('[Math]::Max(1073741824, [double]$item.Length * 0.10)'))
Add-Test "Executor explicitly selects double Math.Max overload" ($ExecutorText.Contains('[Math]::Max([double]1073741824, ([double]$item.Length * 0.10))'))
Add-Test "Blade-size reserve exceeds Int32 safely" ($largeReserve -eq [int64]4030980240) ("reserve={0}" -f $largeReserve)
Add-Test "Blade-size required free bytes are Int64-safe" ($largeRequired -eq [int64]44340782637) ("required={0}" -f $largeRequired)
Add-Test "One GiB minimum reserve is retained for smaller files" ($smallReserve -eq [int64]1073741824) ("reserve={0}" -f $smallReserve)
Add-Test "Smaller-file total remains exact" ($smallRequired -eq [int64]8112338700) ("required={0}" -f $smallRequired)

Write-Host "Reqestra Normalization Large-File Arithmetic Test"
Write-Host "=================================================="
Write-Host ""
$tests | Format-Table -AutoSize

$failed = @($tests | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host ("FAIL: {0}/{1} large-file arithmetic contracts failed." -f $failed.Count, $tests.Count)
    exit 1
}

Write-Host ""
Write-Host ("PASS: {0}/{0} normalization large-file arithmetic contracts passed." -f $tests.Count)
exit 0
