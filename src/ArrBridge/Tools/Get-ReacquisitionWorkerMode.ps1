[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$common = Join-Path $PSScriptRoot "ReacquisitionQueueCommon.ps1"
. $common

# IMPORTANT: Return the actual settings object.
# Do not pipe through Format-List here: callers must be able to inspect
# properties such as effectiveMode and automaticWritesAuthorized.
Get-ReacquisitionWorkerSettings -IntegrationRoot $PSScriptRoot
