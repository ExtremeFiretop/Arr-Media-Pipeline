[CmdletBinding()]
param(
    [ValidateRange(1, 50)]
    [int]$MaxItems = 5,

    [string]$PlanningCsv = "",

    [string]$OutputRoot = "",

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BatchVersion = "0.1.1"
$ToolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$IntegrationRoot = Split-Path -Parent $ToolsRoot
$ValidatorRoot = Split-Path -Parent $IntegrationRoot
$ValidatorScript = Join-Path $ValidatorRoot "MediaValidator.ps1"
$PlannerScript = Join-Path $IntegrationRoot "NormalizationPlanner.ps1"
$ExecutorScript = Join-Path $IntegrationRoot "Invoke-Normalization.ps1"
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"

if ([string]::IsNullOrWhiteSpace($PlanningCsv)) {
    $PlanningCsv = Join-Path $IntegrationRoot "Audit\normalization-planning\movies-normalization-planning-latest.csv"
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $IntegrationRoot "Audit\normalization-batches"
}

function Get-SafeValue {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $Property = $Object.PSObject.Properties[$Name]
    if ($null -eq $Property) {
        return $Default
    }

    return $Property.Value
}

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    try {
        return ([IO.Path]::GetFullPath($Path)).TrimEnd("\").ToLowerInvariant()
    }
    catch {
        return $Path.TrimEnd("\").ToLowerInvariant()
    }
}

function Get-FindingCodes {
    param($ValidatorResult)

    return @(
        @(Get-SafeValue -Object $ValidatorResult -Name "findings" -Default @()) |
            Where-Object { $null -ne $_ } |
            ForEach-Object { [string](Get-SafeValue -Object $_ -Name "code" -Default "") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Normalize-Language {
    param([string]$Language)

    if ([string]::IsNullOrWhiteSpace($Language)) {
        return ""
    }

    switch ($Language.Trim().ToLowerInvariant()) {
        { $_ -in @("en", "eng", "english") } { return "eng" }
        { $_ -in @("fr", "fra", "fre", "french", "francais", "français") } { return "fre" }
        { $_ -in @("ja", "jpn", "japanese") } { return "jpn" }
        { $_ -in @("es", "spa", "spanish") } { return "spa" }
        { $_ -in @("de", "deu", "ger", "german") } { return "ger" }
        { $_ -in @("it", "ita", "italian") } { return "ita" }
        { $_ -in @("pt", "por", "portuguese") } { return "por" }
        default { return $Language.Trim().ToLowerInvariant() }
    }
}

function Get-RadarrOriginalLanguageName {
    param($Movie)

    $Original = Get-SafeValue -Object $Movie -Name "originalLanguage" -Default $null

    if ($null -eq $Original) {
        return ""
    }

    if ($Original -is [string]) {
        return [string]$Original
    }

    return [string](Get-SafeValue -Object $Original -Name "name" -Default "")
}

function Resolve-PreferredLanguageFromProfile {
    param(
        [string]$ProfileName,
        [string]$OriginalLanguage
    )

    switch -Regex ($ProfileName) {
        '(?i)^English$' { return "eng" }
        '(?i)^French$' { return "fre" }
        '(?i)^Original(?:\s+Lang(?:uage)?)?$' {
            return Normalize-Language $OriginalLanguage
        }
        default { return "" }
    }
}

foreach ($Required in @($PlanningCsv, $ValidatorScript, $PlannerScript, $ExecutorScript, $ConfigPath)) {
    if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) {
        throw "Required file not found: $Required"
    }
}

$Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Radarr = Get-SafeValue -Object $Config -Name "radarr"
$RadarrBase = [string](Get-SafeValue -Object $Radarr -Name "baseUrl" -Default "")
$RadarrApiKey = [string](Get-SafeValue -Object $Radarr -Name "apiKey" -Default "")

if ([string]::IsNullOrWhiteSpace($RadarrBase) -or [string]::IsNullOrWhiteSpace($RadarrApiKey)) {
    throw "Radarr baseUrl/apiKey are required in integration-config.json."
}

$RadarrBase = $RadarrBase.TrimEnd("/")
$Headers = @{ "X-Api-Key" = $RadarrApiKey }

$PlanningRows = @(Import-Csv -LiteralPath $PlanningCsv)
$Selected = @(
    $PlanningRows |
        Where-Object { [string]$_.plannerStatus -eq "PLANNED" } |
        Sort-Object @{ Expression = { [int64]$_.lengthBytes } }, path |
        Select-Object -First $MaxItems
)

if ($Selected.Count -eq 0) {
    throw "No PLANNED normalization rows were found in: $PlanningCsv"
}

# PowerShell 5.1 note: do not wrap Invoke-RestMethod itself in @().
# A top-level JSON array can otherwise become one nested array object.
$RadarrMovies = Invoke-RestMethod `
    -Uri "$RadarrBase/api/v3/movie" `
    -Headers $Headers `
    -Method Get

$RadarrProfiles = Invoke-RestMethod `
    -Uri "$RadarrBase/api/v3/qualityprofile" `
    -Headers $Headers `
    -Method Get

$ProfileById = @{}
foreach ($Profile in $RadarrProfiles) {
    $ProfileIdRaw = Get-SafeValue -Object $Profile -Name "id" -Default $null
    if ($null -ne $ProfileIdRaw) {
        $ProfileById[[int]$ProfileIdRaw] = [string](Get-SafeValue -Object $Profile -Name "name" -Default "")
    }
}

$RunStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$RunRoot = Join-Path $OutputRoot ("movies-batch-" + $RunStamp)
New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null

$Results = @()
$Index = 0

foreach ($Row in $Selected) {
    $Index++
    $MediaPath = [string]$Row.path
    $CaseRoot = Join-Path $RunRoot ("{0:D2}" -f $Index)
    New-Item -ItemType Directory -Path $CaseRoot -Force | Out-Null

    $ContextPath = Join-Path $CaseRoot "context.json"
    $ContextualPath = Join-Path $CaseRoot "profile-contextual.json"
    $ValidatorPath = Join-Path $CaseRoot "validator.json"
    $PlanPath = Join-Path $CaseRoot "normalization-plan.json"
    $PreflightPath = Join-Path $CaseRoot "normalization-preflight.json"
    $ExecutePath = Join-Path $CaseRoot "normalization-execute.json"
    $PostValidatorPath = Join-Path $CaseRoot "validator-after.json"

    Write-Host ("[{0}/{1}] {2}" -f $Index, $Selected.Count, $MediaPath)

    $Result = [ordered]@{
        index = $Index
        path = $MediaPath
        lengthBytes = [int64]$Row.lengthBytes
        planningAuditPlanPath = [string]$Row.planPath
        radarrMovieId = $null
        radarrFileId = $null
        radarrTitle = $null
        currentQualityProfileName = $null
        currentOriginalLanguage = $null
        plannedPreferredLanguage = [string](Get-SafeValue -Object $Row -Name "preferredLanguage" -Default "")
        currentPreferredLanguage = $null
        plannerStatus = $null
        plannerReason = $null
        actionCount = 0
        preflightStatus = $null
        preflightReason = $null
        executeRequested = [bool]$Execute
        executeStatus = $null
        executeReason = $null
        finalOutcome = $null
        finalFindingCodes = $null
        caseRoot = $CaseRoot
        executablePlanPath = $PlanPath
        error = $null
    }

    try {
        if (-not (Test-Path -LiteralPath $MediaPath -PathType Leaf)) {
            throw "Source file does not exist."
        }

        $MovieFolder = Split-Path -Parent $MediaPath
        $MovieMatches = @(
            $RadarrMovies |
                Where-Object {
                    [string]::Equals(
                        (Get-NormalizedPath ([string]$_.path)),
                        (Get-NormalizedPath $MovieFolder),
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
        )

        if ($MovieMatches.Count -ne 1) {
            throw "Expected exactly one Radarr movie folder match; found $($MovieMatches.Count)."
        }

        $Movie = $MovieMatches[0]
        $Result.radarrMovieId = [int]$Movie.id
        $Result.radarrTitle = [string]$Movie.title

        $CurrentProfileIdRaw = Get-SafeValue -Object $Movie -Name "qualityProfileId" -Default $null
        $CurrentProfileName = ""
        if ($null -ne $CurrentProfileIdRaw -and $ProfileById.ContainsKey([int]$CurrentProfileIdRaw)) {
            $CurrentProfileName = [string]$ProfileById[[int]$CurrentProfileIdRaw]
        }

        $CurrentOriginalLanguage = Get-RadarrOriginalLanguageName -Movie $Movie
        $CurrentPreferredLanguage = Resolve-PreferredLanguageFromProfile `
            -ProfileName $CurrentProfileName `
            -OriginalLanguage $CurrentOriginalLanguage

        $Result.currentQualityProfileName = $CurrentProfileName
        $Result.currentOriginalLanguage = $CurrentOriginalLanguage
        $Result.currentPreferredLanguage = $CurrentPreferredLanguage

        $PlannedPreferredLanguage = Normalize-Language ([string](Get-SafeValue -Object $Row -Name "preferredLanguage" -Default ""))
        $UseProfileAwareContext = -not [string]::IsNullOrWhiteSpace($PlannedPreferredLanguage)

        if ($UseProfileAwareContext) {
            if ([string]::IsNullOrWhiteSpace($CurrentPreferredLanguage)) {
                throw "Current Radarr quality profile does not map to a preferred language; refusing to rebuild a profile-aware plan."
            }

            if ($CurrentPreferredLanguage -ne $PlannedPreferredLanguage) {
                throw ("Radarr preferred-language context changed since planning: planned={0}, current={1}." -f `
                    $PlannedPreferredLanguage, $CurrentPreferredLanguage)
            }
        }

        $MovieFilesRaw = Invoke-RestMethod `
            -Uri "$RadarrBase/api/v3/moviefile?movieId=$($Movie.id)" `
            -Headers $Headers `
            -Method Get

        $MovieFiles = @($MovieFilesRaw)
        $FileMatches = @(
            $MovieFiles |
                Where-Object {
                    $ArrPath = [string]$_.path
                    if ([string]::IsNullOrWhiteSpace($ArrPath) -and
                        -not [string]::IsNullOrWhiteSpace([string]$_.relativePath)) {
                        $ArrPath = Join-Path ([string]$Movie.path) ([string]$_.relativePath)
                    }

                    [string]::Equals(
                        (Get-NormalizedPath $ArrPath),
                        (Get-NormalizedPath $MediaPath),
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
        )

        if ($FileMatches.Count -ne 1) {
            throw "Expected exactly one Radarr movie-file match; found $($FileMatches.Count)."
        }

        $MovieFile = $FileMatches[0]
        $Result.radarrFileId = [int]$MovieFile.id

        $Item = Get-Item -LiteralPath $MediaPath
        if ([int64]$Item.Length -ne [int64]$MovieFile.size) {
            throw "Radarr/filesystem size mismatch before planning."
        }

        $Context = [ordered]@{
            schemaVersion = "1.0"
            source = "Radarr"
            libraryType = "Movie"
            entity = [ordered]@{
                type = "movie"
                id = [int]$Movie.id
                title = [string]$Movie.title
                originalLanguage = $CurrentOriginalLanguage
                path = [string]$Movie.path
            }
            file = [ordered]@{
                id = [int]$MovieFile.id
                path = $MediaPath
                relativePath = [string]$MovieFile.relativePath
            }
            profile = [ordered]@{
                status = "OK"
                qualityProfileId = [int]$Movie.qualityProfileId
                qualityProfileName = $CurrentProfileName
            }
        }

        $Context |
            ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $ContextPath -Encoding UTF8

        if ($UseProfileAwareContext) {
            [pscustomobject][ordered]@{
                schemaVersion = "1.0"
                status = "APPLIED"
                source = "radarr_quality_profile_live_rebuild"
                qualityProfileName = $CurrentProfileName
                originalLanguage = $CurrentOriginalLanguage
                preferredLanguage = $CurrentPreferredLanguage
                findings = @()
            } |
                ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $ContextualPath -Encoding UTF8
        }

        & $ValidatorScript `
            -Path $MediaPath `
            -LibraryType Movie `
            -JsonOut $ValidatorPath `
            -OutputFormat Json `
            -ExitZero | Out-Null

        $PlannerArguments = @{
            ContextPath = $ContextPath
            ValidatorResultPath = $ValidatorPath
            JsonOut = $PlanPath
        }

        if ($UseProfileAwareContext) {
            $PlannerArguments["ContextualResultPath"] = $ContextualPath
        }

        & $PlannerScript @PlannerArguments | Out-Null

        $Plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $Result.plannerStatus = [string](Get-SafeValue -Object $Plan -Name "status" -Default "")
        $Result.plannerReason = [string](Get-SafeValue -Object $Plan -Name "reason" -Default "")
        $Result.actionCount = @((Get-SafeValue -Object $Plan -Name "actions" -Default @())).Count

        if ($Result.plannerStatus -ne "PLANNED") {
            Write-Host ("  PLAN {0} / {1}" -f $Result.plannerStatus, $Result.plannerReason)
            $Results += [pscustomobject]$Result
            continue
        }

        & $ExecutorScript `
            -PlanPath $PlanPath `
            -JsonOut $PreflightPath | Out-Null

        $Preflight = Get-Content -LiteralPath $PreflightPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $Result.preflightStatus = [string](Get-SafeValue -Object $Preflight -Name "status" -Default "")
        $Result.preflightReason = [string](Get-SafeValue -Object $Preflight -Name "reason" -Default "")

        if ($Result.preflightStatus -ne "DRY_RUN_READY") {
            Write-Host ("  PREFLIGHT {0} / {1}" -f $Result.preflightStatus, $Result.preflightReason)
            $Results += [pscustomobject]$Result
            continue
        }

        Write-Host ("  DRY_RUN_READY / actions={0}" -f $Result.actionCount)

        if (-not $Execute) {
            $Results += [pscustomobject]$Result
            continue
        }

        & $ExecutorScript `
            -PlanPath $PlanPath `
            -JsonOut $ExecutePath `
            -Execute | Out-Null

        $Execution = Get-Content -LiteralPath $ExecutePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $Result.executeStatus = [string](Get-SafeValue -Object $Execution -Name "status" -Default "")
        $Result.executeReason = [string](Get-SafeValue -Object $Execution -Name "reason" -Default "")

        if ($Result.executeStatus -eq "SUCCESS") {
            & $ValidatorScript `
                -Path $MediaPath `
                -LibraryType Movie `
                -JsonOut $PostValidatorPath `
                -OutputFormat Json `
                -ExitZero | Out-Null

            $After = Get-Content -LiteralPath $PostValidatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $Result.finalOutcome = [string](Get-SafeValue -Object $After -Name "outcome" -Default "")
            $Result.finalFindingCodes = (@(Get-FindingCodes -ValidatorResult $After) -join ";")
        }

        Write-Host ("  EXECUTE {0} / final={1}" -f $Result.executeStatus, $Result.finalOutcome)
    }
    catch {
        $Result.error = $_.Exception.Message
        Write-Host ("  ERROR / {0}" -f $Result.error)
    }

    $Results += [pscustomobject]$Result
}

$CsvPath = Join-Path $RunRoot "results.csv"
$JsonPath = Join-Path $RunRoot "results.json"
$SummaryPath = Join-Path $RunRoot "summary.json"
$LatestCsv = Join-Path $OutputRoot "movies-normalization-batch-latest.csv"
$LatestSummary = Join-Path $OutputRoot "movies-normalization-batch-latest-summary.json"

@($Results) | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
@($Results) | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $JsonPath -Encoding UTF8

$Summary = [pscustomobject][ordered]@{
    schemaVersion = "1.0"
    batchVersion = $BatchVersion
    generatedUtc = [DateTime]::UtcNow.ToString("o")
    mode = if ($Execute) { "EXECUTE" } else { "DRY_RUN" }
    planningCsv = $PlanningCsv
    runRoot = $RunRoot
    selectedCount = @($Selected).Count
    rebuiltPlannedCount = @($Results | Where-Object { $_.plannerStatus -eq "PLANNED" }).Count
    dryRunReadyCount = @($Results | Where-Object { $_.preflightStatus -eq "DRY_RUN_READY" }).Count
    successCount = @($Results | Where-Object { $_.executeStatus -eq "SUCCESS" }).Count
    finalPassCount = @($Results | Where-Object { $_.finalOutcome -eq "PASS" }).Count
    errorCount = @($Results | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.error) }).Count
}

$Summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
Copy-Item -LiteralPath $CsvPath -Destination $LatestCsv -Force
Copy-Item -LiteralPath $SummaryPath -Destination $LatestSummary -Force

Write-Host ""
Write-Host "Reqestra Normalization Planned Batch"
Write-Host "===================================="
$Summary | Format-List mode, selectedCount, rebuiltPlannedCount, dryRunReadyCount, successCount, finalPassCount, errorCount, runRoot

Write-Host "Results:"
@($Results) |
    Select-Object index, path, plannerStatus, preflightStatus, executeStatus, finalOutcome, error |
    Format-Table -AutoSize -Wrap

$Summary
