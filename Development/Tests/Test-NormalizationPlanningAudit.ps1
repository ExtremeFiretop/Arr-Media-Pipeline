[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$IntegrationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetPath = Join-Path $IntegrationRoot "Invoke-NormalizationPlanningAudit.ps1"

Write-Host "Reqestra Normalization Planning Audit Contract Test"
Write-Host "===================================================="
Write-Host ""

if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
    throw "Invoke-NormalizationPlanningAudit.ps1 not found."
}

$Text = Get-Content -LiteralPath $TargetPath -Raw -Encoding UTF8
$Tests = @()

function Add-Test {
    param(
        [string]$Name,
        [bool]$Passed
    )

    $script:Tests += [pscustomobject]@{
        Test = $Name
        Passed = $Passed
    }
}

Add-Test "Audit consumes canonical movie CSV" ($Text -match 'movies-latest\.csv')
Add-Test "Audit selects NORMALIZE entries only" ($Text -match 'outcome.*NORMALIZE')
Add-Test "Manual triage paths can be added explicitly" ($Text -match '\[string\[\]\]\$AdditionalPath')
Add-Test "Audit runs MediaValidator in ExitZero mode" (($Text -match 'MediaValidator\.ps1') -and ($Text -match '-ExitZero'))
Add-Test "Audit invokes existing NormalizationPlanner" ($Text -match 'NormalizationPlanner\.ps1')
Add-Test "Audit never invokes normalization executor" (-not ($Text -match 'Invoke-Normalization\.ps1'))
Add-Test "Audit contains no Execute switch" (-not ($Text -match '(?m)^\s*-Execute\b'))
Add-Test "Audit contains no media replacement call" (-not ($Text -match 'System\.IO\.File\.Replace'))
Add-Test "Audit contains no Move-Item" (-not ($Text -match '\bMove-Item\b'))
Add-Test "Audit contains no Remove-Item" (-not ($Text -match '\bRemove-Item\b'))
Add-Test "Audit writes a latest CSV" ($Text -match 'movies-normalization-planning-latest\.csv')
Add-Test "Audit writes a latest summary JSON" ($Text -match 'movies-normalization-planning-latest-summary\.json')
Add-Test "Audit reports PLANNED count" ($Text -match 'plannedCount')
Add-Test "Audit reports BLOCKED count" ($Text -match 'blockedCount')
Add-Test "Audit reports NOT_NEEDED count" ($Text -match 'notNeededCount')
Add-Test "Audit reports SKIPPED count" ($Text -match 'skippedCount')
Add-Test "Audit reports ERROR count" ($Text -match 'errorCount')
Add-Test "Audit groups blocked reasons" ($Text -match 'blockedReasons')
Add-Test "Audit fresh-validates current files" ($Text -match 'currentFindingCodes')

$Tests | Format-Table Test, Passed -AutoSize

$Passed = @($Tests | Where-Object Passed).Count
$Total = $Tests.Count

Write-Host ""
if ($Passed -eq $Total) {
    Write-Host ("PASS: {0}/{1} normalization planning audit contracts passed." -f $Passed, $Total)
    exit 0
}

Write-Host ("FAIL: {0}/{1} normalization planning audit contracts passed." -f $Passed, $Total)
exit 1
