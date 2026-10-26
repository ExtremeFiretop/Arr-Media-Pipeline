[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("AUTO_DRY_RUN","AUTO_EXECUTE")]
    [string]$Mode,
    [switch]$EnableAutomaticWrites,
    [switch]$EnableTerminalDvRemediation,
    [switch]$EnableFelResidualDiscard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($EnableFelResidualDiscard -and -not $EnableTerminalDvRemediation) {
    throw "-EnableFelResidualDiscard requires -EnableTerminalDvRemediation."
}
if ($Mode -eq "AUTO_EXECUTE" -and -not $EnableAutomaticWrites) {
    throw "AUTO_EXECUTE requires -EnableAutomaticWrites."
}

$config = [ordered]@{
    mode = $Mode
    allowAutomaticWrites = ($Mode -eq "AUTO_EXECUTE" -and $EnableAutomaticWrites)
    safetyAcknowledgement = if ($Mode -eq "AUTO_EXECUTE" -and $EnableAutomaticWrites) { "REQESTRA_AUTO_REACQUISITION_CAN_DELETE_AND_REPLACE_MEDIA" } else { "" }
    allowTerminalDvRemediation = [bool]$EnableTerminalDvRemediation
    terminalDvAcknowledgement = if ($EnableTerminalDvRemediation) { "REQESTRA_AUTO_TERMINAL_DV_REMOVES_DOLBY_VISION" } else { "" }
    allowFelResidualDiscard = [bool]$EnableFelResidualDiscard
    felResidualDiscardAcknowledgement = if ($EnableFelResidualDiscard) { "REQESTRA_AUTO_FEL_DISCARDS_DOLBY_VISION_RESIDUAL" } else { "" }
}

$path = Join-Path $PSScriptRoot "reacquisition-worker-config.json"
$config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Host "Reacquisition worker configuration written: $path"
Write-Host "Mode: $Mode"
Write-Host "Automatic writes: $($config.allowAutomaticWrites)"
Write-Host "Terminal DV remediation: $($config.allowTerminalDvRemediation)"
Write-Host "FEL residual discard: $($config.allowFelResidualDiscard)"
