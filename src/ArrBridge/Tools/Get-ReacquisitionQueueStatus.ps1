[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ToolsRoot = $PSScriptRoot
$IntegrationRoot = Split-Path -Parent $ToolsRoot
$common = Join-Path $IntegrationRoot "ReacquisitionQueueCommon.ps1"
. $common
Get-ReacquisitionQueueSummary -IntegrationRoot $IntegrationRoot | Format-List
