[CmdletBinding()]
param(
    [string]$AuditCsv = "",
    [string[]]$AdditionalPath = @(),
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "0.1.0"
$IntegrationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ValidatorRoot = Split-Path -Parent $IntegrationRoot
$ValidatorScript = Join-Path $ValidatorRoot "MediaValidator.ps1"
$PlannerScript = Join-Path $IntegrationRoot "NormalizationPlanner.ps1"

if ([string]::IsNullOrWhiteSpace($AuditCsv)) {
    $AuditCsv = Join-Path $IntegrationRoot "Audit\canonical-current\movies-latest.csv"
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $IntegrationRoot "Audit\normalization-planning"
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

function Get-FindingCodes {
    param($ValidatorResult)

    return @(
        @(Get-SafeValue -Object $ValidatorResult -Name "findings" -Default @()) |
            Where-Object { $null -ne $_ } |
            ForEach-Object { [string](Get-SafeValue -Object $_ -Name "code" -Default "") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-PathKey {
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

if (-not (Test-Path -LiteralPath $AuditCsv -PathType Leaf)) {
    throw "Canonical movie audit CSV not found: $AuditCsv"
}

if (-not (Test-Path -LiteralPath $ValidatorScript -PathType Leaf)) {
    throw "MediaValidator.ps1 not found: $ValidatorScript"
}

if (-not (Test-Path -LiteralPath $PlannerScript -PathType Leaf)) {
    throw "NormalizationPlanner.ps1 not found: $PlannerScript"
}

$AuditRows = @(Import-Csv -LiteralPath $AuditCsv)
$Candidates = @()
$Seen = @{}

foreach ($Row in $AuditRows) {
    if ([string](Get-SafeValue -Object $Row -Name "outcome" -Default "") -ne "NORMALIZE") {
        continue
    }

    $Path = [string](Get-SafeValue -Object $Row -Name "path" -Default "")
    if ([string]::IsNullOrWhiteSpace($Path)) {
        continue
    }

    $Key = Get-PathKey -Path $Path
    if ($Seen.ContainsKey($Key)) {
        continue
    }

    $Seen[$Key] = $true
    $Candidates += [pscustomobject][ordered]@{
        path = $Path
        source = "canonical_audit"
        auditOutcome = [string](Get-SafeValue -Object $Row -Name "outcome" -Default "")
        auditFindingCodes = [string](Get-SafeValue -Object $Row -Name "findingCodes" -Default "")
    }
}

foreach ($Path in @($AdditionalPath)) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        continue
    }

    $Key = Get-PathKey -Path $Path
    if ($Seen.ContainsKey($Key)) {
        continue
    }

    $Seen[$Key] = $true
    $Candidates += [pscustomobject][ordered]@{
        path = $Path
        source = "additional_path"
        auditOutcome = "MANUAL_INCLUDE"
        auditFindingCodes = ""
    }
}

$RunStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$RunRoot = Join-Path $OutputRoot ("movies-" + $RunStamp)
New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null

$Results = @()
$Index = 0
$Total = @($Candidates).Count

foreach ($Candidate in @($Candidates)) {
    $Index++
    $MediaPath = [string]$Candidate.path
    $CaseName = "{0:D4}" -f $Index
    $CaseRoot = Join-Path $RunRoot $CaseName
    New-Item -ItemType Directory -Path $CaseRoot -Force | Out-Null

    $ContextPath = Join-Path $CaseRoot "context.json"
    $ValidatorPath = Join-Path $CaseRoot "validator.json"
    $PlanPath = Join-Path $CaseRoot "normalization-plan.json"

    $PercentComplete = if ($Total -gt 0) { [int](($Index / [double]$Total) * 100) } else { 100 }

    Write-Progress `
        -Activity "Reqestra normalization planning audit" `
        -Status ("{0}/{1}: {2}" -f $Index, $Total, $MediaPath) `
        -PercentComplete $PercentComplete

    Write-Host ("[{0}/{1}] {2}" -f $Index, $Total, $MediaPath)

    $Result = [ordered]@{
        path = $MediaPath
        source = [string]$Candidate.source
        auditOutcome = [string]$Candidate.auditOutcome
        auditFindingCodes = [string]$Candidate.auditFindingCodes
        currentOutcome = $null
        currentFindingCodes = $null
        plannerStatus = "ERROR"
        plannerReason = "unprocessed"
        plannerVersion = $null
        actionCount = 0
        preferredLanguage = $null
        container = [IO.Path]::GetExtension($MediaPath).TrimStart('.').ToLowerInvariant()
        fileExists = $false
        lengthBytes = $null
        planPath = $PlanPath
        error = $null
    }

    try {
        if (-not (Test-Path -LiteralPath $MediaPath -PathType Leaf)) {
            $Result.plannerStatus = "ERROR"
            $Result.plannerReason = "source_file_missing"
            $Results += [pscustomobject]$Result
            Write-Host "  ERROR source_file_missing"
            continue
        }

        $Item = Get-Item -LiteralPath $MediaPath
        $Result.fileExists = $true
        $Result.lengthBytes = [int64]$Item.Length

        $Context = [ordered]@{
            schemaVersion = "1.0"
            source = "Radarr"
            libraryType = "Movie"
            entity = [ordered]@{
                type = "movie"
                id = $null
                title = [IO.Path]::GetFileNameWithoutExtension($MediaPath)
                path = Split-Path -Parent $MediaPath
            }
            file = [ordered]@{
                id = $null
                path = $MediaPath
                relativePath = [IO.Path]::GetFileName($MediaPath)
            }
            profile = [ordered]@{
                status = "NOT_REQUIRED_FOR_PLANNING"
            }
        }

        $Context |
            ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $ContextPath -Encoding UTF8

        & $ValidatorScript `
            -Path $MediaPath `
            -LibraryType Movie `
            -JsonOut $ValidatorPath `
            -OutputFormat Json `
            -ExitZero | Out-Null

        if (-not (Test-Path -LiteralPath $ValidatorPath -PathType Leaf)) {
            throw "Validator did not create output JSON."
        }

        $Validator = Get-Content -LiteralPath $ValidatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $Result.currentOutcome = [string](Get-SafeValue -Object $Validator -Name "outcome" -Default "")
        $Result.currentFindingCodes = (@(Get-FindingCodes -ValidatorResult $Validator) -join ";")

        & $PlannerScript `
            -ContextPath $ContextPath `
            -ValidatorResultPath $ValidatorPath `
            -JsonOut $PlanPath | Out-Null

        if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
            throw "Normalization planner did not create output JSON."
        }

        $Plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $Result.plannerStatus = [string](Get-SafeValue -Object $Plan -Name "status" -Default "ERROR")
        $Result.plannerReason = [string](Get-SafeValue -Object $Plan -Name "reason" -Default "")
        $Result.plannerVersion = [string](Get-SafeValue -Object $Plan -Name "plannerVersion" -Default "")
        $Result.preferredLanguage = [string](Get-SafeValue -Object $Plan -Name "preferredLanguage" -Default "")
        $Result.actionCount = @((Get-SafeValue -Object $Plan -Name "actions" -Default @())).Count

        Write-Host ("  {0}{1}" -f $Result.plannerStatus, $(if ([string]::IsNullOrWhiteSpace($Result.plannerReason)) { "" } else { " / " + $Result.plannerReason }))
    }
    catch {
        $Result.plannerStatus = "ERROR"
        $Result.plannerReason = "planning_error"
        $Result.error = $_.Exception.Message
        Write-Host ("  ERROR / {0}" -f $_.Exception.Message)
    }

    $Results += [pscustomobject]$Result
}

Write-Progress -Activity "Reqestra normalization planning audit" -Completed

$CsvPath = Join-Path $RunRoot "results.csv"
$JsonPath = Join-Path $RunRoot "results.json"
$SummaryPath = Join-Path $RunRoot "summary.json"
$LatestCsv = Join-Path $OutputRoot "movies-normalization-planning-latest.csv"
$LatestSummary = Join-Path $OutputRoot "movies-normalization-planning-latest-summary.json"

@($Results) | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
@($Results) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $JsonPath -Encoding UTF8

$StatusCounts = @(
    @($Results) |
        Group-Object plannerStatus |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject][ordered]@{
                status = $_.Name
                count = $_.Count
            }
        }
)

$BlockedReasons = @(
    @($Results) |
        Where-Object { $_.plannerStatus -eq "BLOCKED" } |
        Group-Object plannerReason |
        Sort-Object Count -Descending |
        ForEach-Object {
            [pscustomobject][ordered]@{
                reason = $_.Name
                count = $_.Count
            }
        }
)

$SkippedReasons = @(
    @($Results) |
        Where-Object { $_.plannerStatus -eq "SKIPPED" } |
        Group-Object plannerReason |
        Sort-Object Count -Descending |
        ForEach-Object {
            [pscustomobject][ordered]@{
                reason = $_.Name
                count = $_.Count
            }
        }
)

$Summary = [pscustomobject][ordered]@{
    schemaVersion = "1.0"
    auditVersion = $ScriptVersion
    generatedUtc = [DateTime]::UtcNow.ToString("o")
    auditCsv = $AuditCsv
    runRoot = $RunRoot
    candidateCount = $Total
    statusCounts = @($StatusCounts)
    blockedReasons = @($BlockedReasons)
    skippedReasons = @($SkippedReasons)
    plannedCount = @($Results | Where-Object { $_.plannerStatus -eq "PLANNED" }).Count
    blockedCount = @($Results | Where-Object { $_.plannerStatus -eq "BLOCKED" }).Count
    notNeededCount = @($Results | Where-Object { $_.plannerStatus -eq "NOT_NEEDED" }).Count
    skippedCount = @($Results | Where-Object { $_.plannerStatus -eq "SKIPPED" }).Count
    errorCount = @($Results | Where-Object { $_.plannerStatus -eq "ERROR" }).Count
}

$Summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
Copy-Item -LiteralPath $CsvPath -Destination $LatestCsv -Force
Copy-Item -LiteralPath $SummaryPath -Destination $LatestSummary -Force

Write-Host ""
Write-Host "Reqestra Normalization Planning Audit"
Write-Host "====================================="
Write-Host ("Candidates : {0}" -f $Summary.candidateCount)
Write-Host ("PLANNED    : {0}" -f $Summary.plannedCount)
Write-Host ("BLOCKED    : {0}" -f $Summary.blockedCount)
Write-Host ("NOT_NEEDED : {0}" -f $Summary.notNeededCount)
Write-Host ("SKIPPED    : {0}" -f $Summary.skippedCount)
Write-Host ("ERROR      : {0}" -f $Summary.errorCount)
Write-Host ""

if ($BlockedReasons.Count -gt 0) {
    Write-Host "Blocked reasons:"
    $BlockedReasons | Format-Table count, reason -AutoSize
}

if ($SkippedReasons.Count -gt 0) {
    Write-Host "Skipped reasons:"
    $SkippedReasons | Format-Table count, reason -AutoSize
}

Write-Host ("Latest CSV     : {0}" -f $LatestCsv)
Write-Host ("Latest summary : {0}" -f $LatestSummary)

$Summary
