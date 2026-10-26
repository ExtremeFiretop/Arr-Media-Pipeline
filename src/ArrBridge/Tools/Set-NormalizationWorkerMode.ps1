[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("AUTO_DRY_RUN", "AUTO_EXECUTE")]
    [string]$Mode,

    [switch]$EnableAutomaticWrites
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ToolsRoot = $PSScriptRoot
$IntegrationRoot = Split-Path -Parent $ToolsRoot
$QueueCommonPath = Join-Path $IntegrationRoot "QueueCommon.ps1"
$ConfigPath = Join-Path $IntegrationRoot "normalization-worker-config.json"

. $QueueCommonPath

if ($Mode -eq "AUTO_EXECUTE" -and -not $EnableAutomaticWrites) {
    throw "AUTO_EXECUTE requires the explicit -EnableAutomaticWrites switch."
}

$config = if ($Mode -eq "AUTO_EXECUTE") {
    [ordered]@{
        schemaVersion = "1.0"
        mode = "AUTO_EXECUTE"
        allowAutomaticWrites = $true
        safetyAcknowledgement = $script:AutomaticWriteAcknowledgement
        updatedUtc = [DateTime]::UtcNow.ToString("o")
    }
}
else {
    [ordered]@{
        schemaVersion = "1.0"
        mode = "AUTO_DRY_RUN"
        allowAutomaticWrites = $false
        safetyAcknowledgement = $null
        updatedUtc = [DateTime]::UtcNow.ToString("o")
    }
}

$tempPath = $ConfigPath + "." + [guid]::NewGuid().ToString("N") + ".tmp"
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tempPath -Encoding UTF8
Move-Item -LiteralPath $tempPath -Destination $ConfigPath -Force

$settings = Get-NormalizationWorkerSettings -IntegrationRoot $IntegrationRoot

Write-Host ""
Write-Host "Reqestra Normalization Worker Mode"
Write-Host "=================================="
Write-Host ""
$settings | Format-List requestedMode, effectiveMode, automaticWritesAuthorized, configStatus, reason, configPath
