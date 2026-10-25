[CmdletBinding()]
param(
    [string]$Destination = "C:\Program Files\MKVToolNix\Custom Scripts\MediaValidator",
    [switch]$ForceExampleConfigs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PackageRoot = $PSScriptRoot
$PackageIntegration = Join-Path $PackageRoot "Integration"

foreach ($required in @(
    (Join-Path $PackageRoot "MediaValidator.ps1"),
    (Join-Path $PackageRoot "validator-policy.json"),
    (Join-Path $PackageIntegration "ReqestraArrBridge.ps1"),
    (Join-Path $PackageIntegration "NormalizationWorker.ps1")
)) {
    if (-not (Test-Path $required -PathType Leaf)) {
        throw "Not a valid Arr Media Pipeline release. Missing: $required"
    }
}

$DestinationIntegration = Join-Path $Destination "Integration"
New-Item -ItemType Directory -Path $DestinationIntegration -Force | Out-Null

foreach ($runtime in @("Queue","Maintenance","logs")) {
    $path = Join-Path $DestinationIntegration $runtime
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

Copy-Item (Join-Path $PackageRoot "MediaValidator.ps1") (Join-Path $Destination "MediaValidator.ps1") -Force
Copy-Item (Join-Path $PackageRoot "validator-policy.json") (Join-Path $Destination "validator-policy.json") -Force

$protected = @(
    "integration-config.json",
    "normalization-worker-config.json",
    "maintenance-config.json"
)

Get-ChildItem $PackageIntegration -File | ForEach-Object {
    if ($protected -contains $_.Name) { return }

    $dest = Join-Path $DestinationIntegration $_.Name

    if ($_.Name -like "*.example.json" -and
        (Test-Path $dest -PathType Leaf) -and
        -not $ForceExampleConfigs) {
        return
    }

    Copy-Item $_.FullName $dest -Force
}

Write-Host ""
Write-Host "Arr Media Pipeline installed"
Write-Host "============================"
Write-Host "Destination: $Destination"
Write-Host ""
Write-Host "Existing live config and runtime state were preserved."
Write-Host ""
Write-Host "Check:"
Write-Host "  .\Integration\Get-NormalizationWorkerMode.ps1"
Write-Host "  .\Integration\Get-NormalizationQueueStatus.ps1"
