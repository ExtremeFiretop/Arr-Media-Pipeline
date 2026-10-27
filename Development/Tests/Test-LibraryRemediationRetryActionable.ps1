[CmdletBinding()]
param([string]$ReleaseRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

$path=Join-Path $ReleaseRoot "Integration\Tools\Invoke-LibraryRemediation.ps1"
$text=Get-Content -LiteralPath $path -Raw -Encoding UTF8
$checks=@(
    [pscustomobject]@{Test="RetryActionable switch exists";Passed=($text -match '\[switch\]\$RetryActionable')},
    [pscustomobject]@{Test="Retry targets only non-PASS actionable outcomes";Passed=($text -match '@\("NORMALIZE","REACQUIRE","REVIEW"\)')},
    [pscustomobject]@{Test="Movies are filtered by retry target key";Passed=($text -match '\$RetryActionable\s+-and\s+-not\s+\$retryTargetKeys\.ContainsKey\(\$key\)')},
    [pscustomobject]@{Test="Retry skips active/completed Radarr chains";Passed=($text -match 'Get-RadarrRetryChainDisposition' -and $text -match 'retrySuppressedByActiveOrCompletedChain')},
    [pscustomobject]@{Test="Retry source is persisted";Passed=($text -match 'retrySourceRunRoot')},
    [pscustomobject]@{Test="Retry and Fresh are mutually exclusive";Passed=($text -match '-RetryActionable and -Fresh cannot be used together')},
    [pscustomobject]@{Test="Retry cannot be truncated by MaxItems";Passed=($text -match '-RetryActionable must process its complete actionable set')}
)
$checks|Format-Table -AutoSize
$failed=@($checks|Where-Object{-not $_.Passed})
if($failed.Count){throw "$($failed.Count) actionable retry release check(s) failed."}
Write-Host "PASS: $($checks.Count)/$($checks.Count) actionable retry checks passed." -ForegroundColor Green
