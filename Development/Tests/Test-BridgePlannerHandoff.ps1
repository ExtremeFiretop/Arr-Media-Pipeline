[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Bridge Planner Handoff Regression Test"
Write-Host "==============================================="
Write-Host ""

$record = [ordered]@{
    contextual = [ordered]@{
        status = "APPLIED"
        outcome = "NORMALIZE"
        resultFile = "C:\Temp\contextual-result.json"
    }
}

$contextualPathForPlanner = ""

if ($null -ne $record.contextual) {
    $contextualResultFile = $null

    if ($record.contextual -is [System.Collections.IDictionary]) {
        if ($record.contextual.Contains("resultFile")) {
            $contextualResultFile = $record.contextual["resultFile"]
        }
    }
    else {
        $resultFileProperty = $record.contextual.PSObject.Properties["resultFile"]
        if ($null -ne $resultFileProperty) {
            $contextualResultFile = $resultFileProperty.Value
        }
    }

    if ($null -ne $contextualResultFile -and
        -not [string]::IsNullOrWhiteSpace([string]$contextualResultFile)) {
        $contextualPathForPlanner = [string]$contextualResultFile
    }
}

if ($contextualPathForPlanner -eq "C:\Temp\contextual-result.json") {
    Write-Host "PASS: OrderedDictionary contextual result path is forwarded to the planner."
    exit 0
}

Write-Host "FAIL: Contextual result path was not resolved."
Write-Host "Resolved value: '$contextualPathForPlanner'"
exit 1
