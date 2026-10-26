[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ToolsRoot = $PSScriptRoot
$IntegrationRoot = Split-Path -Parent $ToolsRoot
. (Join-Path $IntegrationRoot "QueueCommon.ps1")

$settings = Get-NormalizationWorkerSettings -IntegrationRoot $IntegrationRoot

Write-Host ""
Write-Host "Reqestra Normalization Worker Mode"
Write-Host "=================================="
Write-Host ""
$settings | Format-List configExists, requestedMode, effectiveMode, automaticWritesAuthorized, configStatus, reason, configPath
