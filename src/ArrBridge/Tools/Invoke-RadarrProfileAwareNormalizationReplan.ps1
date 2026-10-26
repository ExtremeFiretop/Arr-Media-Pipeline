[CmdletBinding()]
param(
    [string]$IntegrationRoot = '',
    [string]$PlanningCsv = '',
    [string]$PlanningSummary = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ToolsRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($IntegrationRoot)) {
    $IntegrationRoot = Split-Path -Parent $ToolsRoot
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Normalize-MediaPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return $Path.Trim().Replace('/', '\').TrimEnd('\').ToLowerInvariant()
}

function Normalize-Language {
    param([string]$Language)
    if ([string]::IsNullOrWhiteSpace($Language)) { return '' }
    switch ($Language.Trim().ToLowerInvariant()) {
        { $_ -in @('en','eng','english') } { return 'eng' }
        { $_ -in @('fr','fra','fre','french','francais','français') } { return 'fre' }
        { $_ -in @('ja','jpn','japanese') } { return 'jpn' }
        { $_ -in @('es','spa','spanish') } { return 'spa' }
        { $_ -in @('de','deu','ger','german') } { return 'ger' }
        { $_ -in @('it','ita','italian') } { return 'ita' }
        { $_ -in @('pt','por','portuguese') } { return 'por' }
        default { return $Language.Trim().ToLowerInvariant() }
    }
}

$ValidatorRoot = Split-Path -Parent $IntegrationRoot
$PlannerPath = Join-Path $IntegrationRoot 'NormalizationPlanner.ps1'
$ConfigPath = Join-Path $IntegrationRoot 'integration-config.json'
$AuditRoot = Join-Path $IntegrationRoot 'Audit\normalization-planning'

if ([string]::IsNullOrWhiteSpace($PlanningCsv)) {
    $PlanningCsv = Join-Path $AuditRoot 'movies-normalization-planning-latest.csv'
}
if ([string]::IsNullOrWhiteSpace($PlanningSummary)) {
    $PlanningSummary = Join-Path $AuditRoot 'movies-normalization-planning-latest-summary.json'
}

foreach ($required in @($PlannerPath, $ConfigPath, $PlanningCsv)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required file not found: $required"
    }
}

$plannerText = Get-Content -LiteralPath $PlannerPath -Raw -Encoding UTF8
if ($plannerText -notmatch '\$PlannerVersion\s*=\s*"0\.2\.3"') {
    throw 'NormalizationPlanner 0.2.3 is required. Run Apply-RadarrProfileAwarePlannerHotfix.ps1 first.'
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$baseUrl = ([string](Get-Prop (Get-Prop $config 'radarr') 'baseUrl' '')).TrimEnd('/')
$apiKey = [string](Get-Prop (Get-Prop $config 'radarr') 'apiKey' '')
if ([string]::IsNullOrWhiteSpace($apiKey) -and -not [string]::IsNullOrWhiteSpace($env:REQESTRA_RADARR_API_KEY)) {
    $apiKey = $env:REQESTRA_RADARR_API_KEY
}
if ([string]::IsNullOrWhiteSpace($baseUrl)) { throw 'Radarr baseUrl is missing.' }
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'Radarr API key is missing.' }

$headers = @{ 'X-Api-Key' = $apiKey; 'Accept' = 'application/json' }

$moviesResponse = Invoke-RestMethod -Method Get -Uri "$baseUrl/api/v3/movie" -Headers $headers -UseBasicParsing -TimeoutSec 30
$movies = @(); foreach ($m in $moviesResponse) { $movies += $m }
$profilesResponse = Invoke-RestMethod -Method Get -Uri "$baseUrl/api/v3/qualityprofile" -Headers $headers -UseBasicParsing -TimeoutSec 30
$profiles = @(); foreach ($p in $profilesResponse) { $profiles += $p }

$profileById = @{}
foreach ($p in $profiles) {
    $idRaw = Get-Prop $p 'id' $null
    if ($null -ne $idRaw) { $profileById[[int]$idRaw] = [string](Get-Prop $p 'name' '') }
}

$rows = @(Import-Csv -LiteralPath $PlanningCsv)
$targets = @($rows | Where-Object {
    $_.plannerStatus -eq 'BLOCKED' -and $_.plannerReason -eq 'ambiguous_default_audio_target'
})

$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$runRoot = Join-Path $AuditRoot ("profile-aware-$stamp")
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

$report = @()
$index = 0
foreach ($row in $targets) {
    $index++
    $moviePath = [string]$row.path
    $folder = Normalize-MediaPath (Split-Path $moviePath -Parent)
    $movie = @($movies | Where-Object { (Normalize-MediaPath ([string](Get-Prop $_ 'path' ''))) -eq $folder }) | Select-Object -First 1

    $profileName = ''
    $originalLanguage = ''
    $preferredLanguage = ''
    $resultStatus = 'SKIPPED'
    $reason = ''
    $newPlanPath = ''

    if ($null -eq $movie) {
        $reason = 'radarr_movie_not_found'
    }
    else {
        $profileIdRaw = Get-Prop $movie 'qualityProfileId' $null
        if ($null -ne $profileIdRaw -and $profileById.ContainsKey([int]$profileIdRaw)) {
            $profileName = [string]$profileById[[int]$profileIdRaw]
        }

        $original = Get-Prop $movie 'originalLanguage' $null
        if ($original -is [string]) {
            $originalLanguage = [string]$original
        }
        elseif ($null -ne $original) {
            $originalLanguage = [string](Get-Prop $original 'name' '')
        }

        switch -Regex ($profileName) {
            '(?i)^English$' { $preferredLanguage = 'eng'; break }
            '(?i)^French$' { $preferredLanguage = 'fre'; break }
            '(?i)^Original(?:\s+Lang(?:uage)?)?$' {
                $preferredLanguage = Normalize-Language $originalLanguage
                break
            }
            default { $preferredLanguage = '' }
        }

        if ([string]::IsNullOrWhiteSpace($preferredLanguage)) {
            $reason = 'quality_profile_language_not_mapped'
        }
        else {
            $oldPlan = Get-Content -LiteralPath $row.planPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $contextPath = [string](Get-Prop (Get-Prop $oldPlan 'sourceFiles') 'contextPath' '')
            $validatorPath = [string](Get-Prop (Get-Prop $oldPlan 'sourceFiles') 'validatorResultPath' '')
            if ([string]::IsNullOrWhiteSpace($contextPath) -or -not (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
                throw "Context file missing for: $moviePath"
            }
            if ([string]::IsNullOrWhiteSpace($validatorPath) -or -not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
                throw "Validator result missing for: $moviePath"
            }

            $caseDir = Join-Path $runRoot ('{0:D4}' -f $index)
            New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
            $contextualPath = Join-Path $caseDir 'radarr-profile-contextual.json'
            $newPlanPath = Join-Path $caseDir 'normalization-plan.json'

            [pscustomobject][ordered]@{
                schemaVersion = '1.0'
                status = 'APPLIED'
                source = 'radarr_quality_profile'
                qualityProfileName = $profileName
                originalLanguage = $originalLanguage
                preferredLanguage = $preferredLanguage
                findings = @()
            } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $contextualPath -Encoding UTF8

            & $PlannerPath -ContextPath $contextPath -ValidatorResultPath $validatorPath -ContextualResultPath $contextualPath -JsonOut $newPlanPath | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Planner failed for: $moviePath" }

            $newPlan = Get-Content -LiteralPath $newPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $resultStatus = [string](Get-Prop $newPlan 'status' 'ERROR')
            $reason = [string](Get-Prop $newPlan 'reason' '')

            $row.plannerStatus = $resultStatus
            $row.plannerReason = $reason
            $row.plannerVersion = [string](Get-Prop $newPlan 'plannerVersion' '')
            $row.actionCount = @((Get-Prop $newPlan 'actions' @())).Count
            $row.preferredLanguage = $preferredLanguage
            $row.planPath = $newPlanPath
            $row.error = ''
        }
    }

    $report += [pscustomobject][ordered]@{
        path = $moviePath
        qualityProfile = $profileName
        originalLanguage = $originalLanguage
        preferredLanguage = $preferredLanguage
        plannerStatus = $resultStatus
        plannerReason = $reason
        planPath = $newPlanPath
    }
}

$backupCsv = "$PlanningCsv.pre-profile-aware-$stamp.bak"
Copy-Item -LiteralPath $PlanningCsv -Destination $backupCsv -Force
$rows | Export-Csv -LiteralPath $PlanningCsv -NoTypeInformation -Encoding UTF8

$reportPath = Join-Path $runRoot 'profile-aware-replan.csv'
$report | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8

$counts = @{}
foreach ($s in @('PLANNED','BLOCKED','NOT_NEEDED','SKIPPED','ERROR')) { $counts[$s] = 0 }
foreach ($r in $rows) {
    $s = [string]$r.plannerStatus
    if ($counts.ContainsKey($s)) { $counts[$s]++ }
}

if (Test-Path -LiteralPath $PlanningSummary -PathType Leaf) {
    $summary = Get-Content -LiteralPath $PlanningSummary -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($pair in (@{
        plannedCount = $counts['PLANNED']; blockedCount = $counts['BLOCKED']; notNeededCount = $counts['NOT_NEEDED']; skippedCount = $counts['SKIPPED']; errorCount = $counts['ERROR']
    }).GetEnumerator()) {
        if ($summary.PSObject.Properties[$pair.Key]) { $summary.($pair.Key) = $pair.Value }
        else { $summary | Add-Member -NotePropertyName $pair.Key -NotePropertyValue $pair.Value }
    }
    $statusCounts = @()
    foreach ($s in @('BLOCKED','NOT_NEEDED','PLANNED','SKIPPED','ERROR')) {
        if ($counts[$s] -gt 0) { $statusCounts += [pscustomobject]@{ status = $s; count = $counts[$s] } }
    }
    if ($summary.PSObject.Properties['statusCounts']) { $summary.statusCounts = $statusCounts }
    else { $summary | Add-Member -NotePropertyName statusCounts -NotePropertyValue $statusCounts }
    if ($summary.PSObject.Properties['generatedUtc']) { $summary.generatedUtc = [DateTime]::UtcNow.ToString('o') }
    $summary | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $PlanningSummary -Encoding UTF8
}

Write-Host ''
Write-Host 'Radarr Profile-Aware Normalization Replan'
Write-Host '========================================='
Write-Host ("Candidates reconsidered : {0}" -f $targets.Count)
Write-Host ("PLANNED                 : {0}" -f $counts['PLANNED'])
Write-Host ("BLOCKED                 : {0}" -f $counts['BLOCKED'])
Write-Host ("NOT_NEEDED              : {0}" -f $counts['NOT_NEEDED'])
Write-Host ("SKIPPED                 : {0}" -f $counts['SKIPPED'])
Write-Host ("ERROR                   : {0}" -f $counts['ERROR'])
Write-Host "Report                  : $reportPath"
Write-Host "CSV backup              : $backupCsv"
Write-Host ''
$report | Format-Table qualityProfile,preferredLanguage,plannerStatus,plannerReason,path -AutoSize -Wrap
