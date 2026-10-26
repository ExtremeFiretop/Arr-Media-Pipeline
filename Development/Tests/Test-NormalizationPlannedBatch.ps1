[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptPath = Join-Path $PSScriptRoot "Invoke-NormalizationPlannedBatch.ps1"
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "Batch script not found: $ScriptPath"
}

$Text = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
$Tests = @()

function Add-Test {
    param([string]$Name, [bool]$Passed)
    $script:Tests += [pscustomobject]@{ Test = $Name; Passed = $Passed }
}

Add-Test "Batch consumes latest normalization planning CSV" ($Text -match 'movies-normalization-planning-latest\.csv')
Add-Test "Batch selects PLANNED rows only" ($Text -match 'plannerStatus -eq \"PLANNED\"')
Add-Test "Default batch size is five" ($Text -match '\[int\]\$MaxItems = 5')
Add-Test "Batch defaults to dry-run" ($Text -match '\[switch\]\$Execute')
Add-Test "Media writes require explicit Execute switch" ($Text -match 'if \(-not \$Execute\)')
Add-Test "Batch resolves Radarr movie identity" ($Text -match '/api/v3/movie\"')
Add-Test "Batch avoids wrapping bulk Invoke-RestMethod in array syntax" ($Text -match 'PowerShell 5\.1 note')
Add-Test "Batch resolves Radarr movie-file identity" ($Text -match '/api/v3/moviefile\?movieId=')
Add-Test "Movie matching uses exact normalized folder path" ($Text -match 'Expected exactly one Radarr movie folder match')
Add-Test "Movie-file matching uses exact normalized file path" ($Text -match 'Expected exactly one Radarr movie-file match')
Add-Test "Batch checks Radarr and filesystem size before planning" ($Text -match 'Radarr/filesystem size mismatch before planning')
Add-Test "Batch fresh-validates each selected movie" ($Text -match '-LibraryType Movie')
Add-Test "Batch rebuilds executable normalization plans" ($Text -match 'NormalizationPlanner\.ps1')
Add-Test "Batch always runs executor preflight before execute" ($Text -match 'DRY_RUN_READY')
Add-Test "Execute path invokes existing executor with Execute switch" ($Text -match '-Execute \| Out-Null')
Add-Test "Successful execution gets independent post-validation" ($Text -match 'validator-after\.json')
Add-Test "Batch records final PASS count" ($Text -match 'finalPassCount')
Add-Test "Batch writes CSV results" ($Text -match 'Export-Csv')
Add-Test "Batch writes JSON summary" ($Text -match 'summary\.json')
Add-Test "Batch does not contain Remove-Item media cleanup" (-not ($Text -match 'Remove-Item'))
Add-Test "Batch does not contain File.Replace itself" (-not ($Text -match 'File\.Replace'))
Add-Test "Batch does not contain Move-Item media replacement" (-not ($Text -match 'Move-Item'))

Write-Host "Reqestra Normalization Planned Batch Contract Test"
Write-Host "=================================================="
Write-Host ""
$Tests | Format-Table -AutoSize
Write-Host ""

$Passed = @($Tests | Where-Object Passed).Count
$Total = @($Tests).Count

if ($Passed -ne $Total) {
    throw "FAIL: $Passed/$Total normalization planned batch contracts passed."
}

Write-Host "PASS: $Passed/$Total normalization planned batch contracts passed."
