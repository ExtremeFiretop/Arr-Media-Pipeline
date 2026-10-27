[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Worker = Get-Content -LiteralPath (Join-Path $Root "Integration\ReacquisitionWorker.ps1") -Raw -Encoding UTF8
$RadarrRetry = Get-Content -LiteralPath (Join-Path $Root "Integration\Invoke-ReacquisitionRetry.ps1") -Raw -Encoding UTF8
$SonarrRetry = Get-Content -LiteralPath (Join-Path $Root "Integration\Invoke-SonarrReacquisitionRetry.ps1") -Raw -Encoding UTF8

$activeRetryStart = $Worker.IndexOf('elseif ($outcome -eq "REACQUIRE")')
$markPre = $Worker.IndexOf('retry-markfailed-preflight', $activeRetryStart)
$markInvoke = $Worker.IndexOf('Invoke-Reacquisition.ps1', $markPre)
$retryPre = $Worker.IndexOf('retry-preflight', $activeRetryStart)

$checks = @(
    [pscustomobject]@{ Name = "active-chain retry has failed-replacement MarkFailed stage"; Passed = ($activeRetryStart -ge 0 -and $markPre -gt $activeRetryStart -and $markInvoke -gt $markPre) },
    [pscustomobject]@{ Name = "failed replacement is blocklisted before retry preflight"; Passed = ($markInvoke -ge 0 -and $retryPre -gt $markInvoke) },
    [pscustomobject]@{ Name = "worker suppresses native Arr redownload during replacement MarkFailed"; Passed = ($Worker.Substring($markPre, [Math]::Min(5000, $Worker.Length-$markPre)) -match 'SuppressNativeRedownload') },
    [pscustomobject]@{ Name = "already-blocklisted replacement is idempotent"; Passed = ($Worker.Substring($activeRetryStart, [Math]::Min(7000, $Worker.Length-$activeRetryStart)) -match 'current_release_already_blocklisted' -and $Worker -match '\$markAlreadyBlocked') },
    [pscustomobject]@{ Name = "replacement without release identity fails closed"; Passed = ($Worker -match 'replacement_release_identity_unavailable') },
    [pscustomobject]@{ Name = "Radarr retry supports exact-blocklist evidence when state missing"; Passed = ($RadarrRetry -match 'EXACT_BLOCKLIST_ONLY' -and $RadarrRetry -match 'reacquisitionStateEvidence') },
    [pscustomobject]@{ Name = "Sonarr retry supports exact-blocklist evidence when state missing"; Passed = ($SonarrRetry -match 'EXACT_BLOCKLIST_ONLY' -and $SonarrRetry -match 'reacquisitionStateEvidence') },
    [pscustomobject]@{ Name = "existing incomplete state still fails closed Radarr"; Passed = ($RadarrRetry -match 'successful_reacquisition_blocklist_state_not_found') },
    [pscustomobject]@{ Name = "existing incomplete state still fails closed Sonarr"; Passed = ($SonarrRetry -match 'successful_reacquisition_blocklist_state_not_found') }
)
$checks | Format-Table -AutoSize
$failed = @($checks | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) { throw ("Active-chain failed-replacement retry regression failed: " + (($failed.Name) -join ', ')) }
Write-Host ("PASS: {0}/{0} active-chain failed-replacement retry checks passed." -f $checks.Count) -ForegroundColor Green
