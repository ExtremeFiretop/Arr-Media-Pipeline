[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [string]$OutputRoot = "",
    [switch]$IncludeTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepoRoot "dist"
}

$MediaValidatorSource = Join-Path $RepoRoot "src\MediaValidator"
$ArrBridgeSource = Join-Path $RepoRoot "src\ArrBridge"
$ConfigSource = Join-Path $RepoRoot "config"
$TestsSource = Join-Path $RepoRoot "tests"

$ReleaseName = "Arr-Media-Pipeline-v$Version"
$StageRoot = Join-Path $OutputRoot $ReleaseName
$IntegrationDestination = Join-Path $StageRoot "Integration"
$ZipPath = Join-Path $OutputRoot ($ReleaseName + ".zip")

foreach ($required in @($MediaValidatorSource, $ArrBridgeSource, $ConfigSource)) {
    if (-not (Test-Path -LiteralPath $required -PathType Container)) {
        throw "Required repository directory not found: $required"
    }
}

if (Test-Path $StageRoot) { Remove-Item $StageRoot -Recurse -Force }
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

New-Item -ItemType Directory -Path $IntegrationDestination -Force | Out-Null

Copy-Item (Join-Path $MediaValidatorSource "MediaValidator.ps1") $StageRoot
Copy-Item (Join-Path $MediaValidatorSource "validator-policy.json") $StageRoot

$bridgeFiles = @(
    "ReqestraArrBridge.ps1",
    "ContextValidator.ps1",
    "NormalizationPlanner.ps1",
    "Invoke-Normalization.ps1",
    "NormalizationWorker.ps1",
    "QueueCommon.ps1",
    "MaintenanceCommon.ps1",
    "RadarrValidator.cmd",
    "SonarrValidator.cmd",
    "Get-NormalizationQueueStatus.ps1",
    "Get-NormalizationWorkerMode.ps1",
    "Set-NormalizationWorkerMode.ps1",
    "Invoke-MediaMaintenance.ps1",
    "Get-MediaMaintenanceStatus.ps1"
)

foreach ($name in $bridgeFiles) {
    $source = Join-Path $ArrBridgeSource $name
    if (-not (Test-Path $source -PathType Leaf)) {
        throw "Expected ArrBridge file missing: $source"
    }
    Copy-Item $source (Join-Path $IntegrationDestination $name)
}

foreach ($name in @(
    "integration-config.example.json",
    "normalization-worker-config.example.json",
    "maintenance-config.example.json"
)) {
    $source = Join-Path $ConfigSource $name
    if (Test-Path $source -PathType Leaf) {
        Copy-Item $source (Join-Path $IntegrationDestination $name)
    }
}

foreach ($name in @("README.md","CHANGELOG.md","LICENSE")) {
    $source = Join-Path $RepoRoot $name
    if (Test-Path $source -PathType Leaf) {
        Copy-Item $source $StageRoot
    }
}

$docs = Join-Path $RepoRoot "docs"
if (Test-Path $docs -PathType Container) {
    Copy-Item $docs (Join-Path $StageRoot "docs") -Recurse
}

$install = Join-Path $PSScriptRoot "Install.ps1"
Copy-Item $install (Join-Path $StageRoot "Install.ps1")

if ($IncludeTests -and (Test-Path $TestsSource -PathType Container)) {
    Copy-Item $TestsSource (Join-Path $StageRoot "tests") -Recurse
}

foreach ($forbidden in @(
    "integration-config.json",
    "normalization-worker-config.json",
    "maintenance-config.json",
    "Queue",
    "Maintenance",
    "logs"
)) {
    $found = @(Get-ChildItem $StageRoot -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $forbidden })
    if ($found.Count -gt 0) {
        throw "Release safety check failed: '$forbidden' was staged."
    }
}

Compress-Archive -Path (Join-Path $StageRoot "*") -DestinationPath $ZipPath -CompressionLevel Optimal

Write-Host ""
Write-Host "Arr Media Pipeline release built"
Write-Host "================================"
Write-Host "Version:   $Version"
Write-Host "Directory: $StageRoot"
Write-Host "Archive:   $ZipPath"
