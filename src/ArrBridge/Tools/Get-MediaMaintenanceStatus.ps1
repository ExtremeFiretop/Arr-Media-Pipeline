[CmdletBinding()]
param(
    [ValidateRange(1, 50)]
    [int]$Recent = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$MaintenanceRoot = Join-Path $PSScriptRoot "Maintenance"
$ReportsRoot = Join-Path $MaintenanceRoot "reports"
$AuditLog = Join-Path $MaintenanceRoot "maintenance.jsonl"

Write-Host ""
Write-Host "Reqestra Media Maintenance Status"
Write-Host "================================="
Write-Host ""

if (-not (Test-Path -LiteralPath $ReportsRoot)) {
    Write-Host "No maintenance reports yet."
    return
}

$reports = @(
    Get-ChildItem -LiteralPath $ReportsRoot -Filter "maintenance-*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First $Recent
)

if ($reports.Count -eq 0) {
    Write-Host "No maintenance reports yet."
    return
}

$rows = foreach ($file in $reports) {
    try {
        $r = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

        [pscustomobject][ordered]@{
            Mode = [string]$r.mode
            CompletedUtc = [string]$r.completedUtc
            BackupsFound = [int]$r.summary.backupsFound
            BackupsEligible = [int]$r.summary.backupsEligible
            BackupsDeleted = [int]$r.summary.backupsDeleted
            TempsFound = [int]$r.summary.tempArtifactsFound
            TempsEligible = [int]$r.summary.tempArtifactsEligible
            TempsDeleted = [int]$r.summary.tempArtifactsDeleted
            Report = $file.Name
        }
    }
    catch {
        [pscustomobject][ordered]@{
            Mode = "UNREADABLE"
            CompletedUtc = ""
            BackupsFound = 0
            BackupsEligible = 0
            BackupsDeleted = 0
            TempsFound = 0
            TempsEligible = 0
            TempsDeleted = 0
            Report = $file.Name
        }
    }
}

$rows | Format-Table -AutoSize -Wrap

if (Test-Path -LiteralPath $AuditLog -PathType Leaf) {
    $auditCount = @(Get-Content -LiteralPath $AuditLog -ErrorAction SilentlyContinue).Count
    Write-Host ""
    Write-Host ("Deletion audit events: {0}" -f $auditCount)
}
