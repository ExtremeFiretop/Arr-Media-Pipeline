[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ToolsRoot = $PSScriptRoot
$IntegrationRoot = Split-Path -Parent $ToolsRoot
$common = Join-Path $IntegrationRoot "ReacquisitionQueueCommon.ps1"
. $common

# IMPORTANT: Return the actual settings object.
# Do not pipe through Format-List here: callers must be able to inspect
# properties such as effectiveMode and automaticWritesAuthorized.
Get-ReacquisitionWorkerSettings -IntegrationRoot $IntegrationRoot
