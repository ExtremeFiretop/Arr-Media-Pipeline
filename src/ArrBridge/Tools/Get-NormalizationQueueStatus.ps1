[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$Recent = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$IntegrationRoot = $PSScriptRoot
$QueueCommonPath = Join-Path $IntegrationRoot "QueueCommon.ps1"

. $QueueCommonPath

$paths = Initialize-NormalizationQueue -IntegrationRoot $IntegrationRoot
$summary = Get-NormalizationQueueSummary -IntegrationRoot $IntegrationRoot

Write-Host ""
Write-Host "Reqestra Normalization Queue"
Write-Host "============================"
Write-Host ""
$summary | Format-List queueVersion, requestedMode, effectiveMode, automaticWritesAuthorized, configStatus, configReason, pending, running, history, queueRoot

$history = @(
    Get-ChildItem -LiteralPath $paths.history -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First $Recent |
        ForEach-Object {
            try {
                $job = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                [pscustomobject][ordered]@{
                    State = [string]$job.state
                    Source = [string]$job.source
                    Media = [System.IO.Path]::GetFileName([string]$job.mediaPath)
                    Findings = (@($job.plannedFindingCodes) -join ", ")
                    CompletedUtc = $job.completedUtc
                    Reason = $job.reason
                    JobId = ([string]$job.jobId).Substring(0, [Math]::Min(12, ([string]$job.jobId).Length))
                }
            }
            catch {
                [pscustomobject][ordered]@{
                    State = "UNREADABLE"
                    Source = ""
                    Media = $_.Name
                    Findings = ""
                    CompletedUtc = ""
                    Reason = $_.Exception.Message
                    JobId = ""
                }
            }
        }
)

if ($history.Count -gt 0) {
    Write-Host ""
    Write-Host "Recent history"
    Write-Host "--------------"
    $history | Format-Table -AutoSize -Wrap
}
