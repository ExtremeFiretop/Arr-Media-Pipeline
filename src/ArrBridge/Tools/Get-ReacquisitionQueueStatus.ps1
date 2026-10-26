[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$common = Join-Path $PSScriptRoot "ReacquisitionQueueCommon.ps1"
. $common
Get-ReacquisitionQueueSummary -IntegrationRoot $PSScriptRoot | Format-List
