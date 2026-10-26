[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ContextPath,

    [Parameter(Mandatory = $true)]
    [string]$ValidatorResultPath,

    [string]$ContextualResultPath = "",

    [string]$AutomaticEscalationReason = "",

    [Parameter(Mandatory = $true)]
    [string]$JsonOut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PlannerVersion = "0.1.2"

function Get-PropertyValue {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Normalize-Language {
    param([string]$Language)

    if ([string]::IsNullOrWhiteSpace($Language)) { return "und" }

    switch ($Language.Trim().ToLowerInvariant()) {
        "en"  { return "eng" }
        "eng" { return "eng" }
        "fr"  { return "fre" }
        "fre" { return "fre" }
        "fra" { return "fre" }
        "ja"  { return "jpn" }
        "jpn" { return "jpn" }
        "es"  { return "spa" }
        "spa" { return "spa" }
        "de"  { return "ger" }
        "deu" { return "ger" }
        "ger" { return "ger" }
        "it"  { return "ita" }
        "ita" { return "ita" }
        "pt"  { return "por" }
        "por" { return "por" }
        "ko"  { return "kor" }
        "kor" { return "kor" }
        "zh"  { return "chi" }
        "zho" { return "chi" }
        "chi" { return "chi" }
        default { return $Language.Trim().ToLowerInvariant() }
    }
}

function Get-FindingCodes {
    param($Result)

    return @(
        @(Get-PropertyValue -Object $Result -Name "findings" -Default @()) |
            Where-Object { $null -ne $_ } |
            ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "code" -Default "") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-FindingCodesBySeverity {
    param($Result, [string]$Severity)

    return @(
        @(Get-PropertyValue -Object $Result -Name "findings" -Default @()) |
            Where-Object {
                $null -ne $_ -and
                [string](Get-PropertyValue -Object $_ -Name "severity" -Default "") -eq $Severity
            } |
            ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "code" -Default "") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Test-AutomaticEscalationReason {
    param([string]$Reason)

    return $Reason -in @(
        "multiple_preferred_audio_candidates",
        "ambiguous_default_audio_target",
        "preferred_audio_candidate_missing",
        "container_not_supported"
    )
}

function Get-HigherOutcome {
    param([string]$First, [string]$Second)

    $rank = @{
        "PASS" = 0
        "NORMALIZE" = 1
        "REVIEW" = 2
        "REACQUIRE" = 3
    }

    if (-not $rank.ContainsKey($First)) { $First = "PASS" }
    if (-not $rank.ContainsKey($Second)) { return $First }

    if ($rank[$Second] -gt $rank[$First]) { return $Second }
    return $First
}

function Get-StreamFingerprint {
    param($ValidatorResult)

    function SafeValue {
        param($Object, [string]$Name, $Default = $null)
        return Get-PropertyValue -Object $Object -Name $Name -Default $Default
    }

    $normalized = [ordered]@{
        video = @(
            @(SafeValue $ValidatorResult "video" @()) | ForEach-Object {
                [ordered]@{
                    codec = [string](SafeValue $_ "codec" "")
                    width = SafeValue $_ "width"
                    height = SafeValue $_ "height"
                    pixFmt = [string](SafeValue $_ "pixFmt" "")
                    language = Normalize-Language ([string](SafeValue $_ "language" ""))
                    title = [string](SafeValue $_ "title" "")
                }
            }
        )
        auxiliaryVideo = @(
            @(SafeValue $ValidatorResult "auxiliaryVideo" @()) | ForEach-Object {
                [ordered]@{
                    codec = [string](SafeValue $_ "codec" "")
                    width = SafeValue $_ "width"
                    height = SafeValue $_ "height"
                    language = Normalize-Language ([string](SafeValue $_ "language" ""))
                    title = [string](SafeValue $_ "title" "")
                }
            }
        )
        audio = @(
            @(SafeValue $ValidatorResult "audio" @()) | ForEach-Object {
                [ordered]@{
                    codec = [string](SafeValue $_ "codec" "")
                    language = Normalize-Language ([string](SafeValue $_ "language" ""))
                    title = [string](SafeValue $_ "title" "")
                    channels = SafeValue $_ "channels"
                    commentary = [bool](SafeValue $_ "commentary" $false)
                }
            }
        )
        subtitles = @(
            @(SafeValue $ValidatorResult "subtitles" @()) | ForEach-Object {
                [ordered]@{
                    codec = [string](SafeValue $_ "codec" "")
                    language = Normalize-Language ([string](SafeValue $_ "language" ""))
                    title = [string](SafeValue $_ "title" "")
                    forced = [bool](SafeValue $_ "forced" $false)
                }
            }
        )
    }

    $json = $normalized | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return ([BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
}

function Get-SourceSnapshot {
    param([string]$MediaPath, $ValidatorResult)

    if (-not (Test-Path -LiteralPath $MediaPath -PathType Leaf)) { return $null }

    $item = Get-Item -LiteralPath $MediaPath

    return [pscustomobject][ordered]@{
        lengthBytes = [int64]$item.Length
        lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString("o")
        streamFingerprint = Get-StreamFingerprint -ValidatorResult $ValidatorResult
    }
}

function Get-Sha256 {
    param([string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return ([BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
}

function Write-Result {
    param($Result)

    $Result | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    $Result | ConvertTo-Json -Depth 40
}

$context = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
$validator = Get-Content -LiteralPath $ValidatorResultPath -Raw -Encoding UTF8 | ConvertFrom-Json

$contextual = $null
if (-not [string]::IsNullOrWhiteSpace($ContextualResultPath) -and
    (Test-Path -LiteralPath $ContextualResultPath -PathType Leaf)) {
    $contextual = Get-Content -LiteralPath $ContextualResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

$source = [string](Get-PropertyValue -Object $context -Name "source" -Default "")
$mediaPath = [string](Get-PropertyValue -Object (Get-PropertyValue -Object $context -Name "file") -Name "path" -Default "")
$entity = Get-PropertyValue -Object $context -Name "entity"
$file = Get-PropertyValue -Object $context -Name "file"
$release = Get-PropertyValue -Object $context -Name "release"

$genericOutcome = [string](Get-PropertyValue -Object $validator -Name "outcome" -Default "PASS")
$contextualOutcome = "PASS"
if ($null -ne $contextual -and [string](Get-PropertyValue -Object $contextual -Name "status" -Default "") -eq "APPLIED") {
    $contextualOutcome = [string](Get-PropertyValue -Object $contextual -Name "outcome" -Default "PASS")
}

$detectedEffectiveOutcome = Get-HigherOutcome -First $genericOutcome -Second $contextualOutcome
$effectiveOutcome = $detectedEffectiveOutcome

$genericFindings = @(Get-FindingCodes -Result $validator)
$contextualFindings = @(Get-FindingCodes -Result $contextual)
$allFindings = @($genericFindings + $contextualFindings | Sort-Object -Unique)
$genericNormalizeFindings = @(Get-FindingCodesBySeverity -Result $validator -Severity "NORMALIZE")
$contextualNormalizeFindings = @(Get-FindingCodesBySeverity -Result $contextual -Severity "NORMALIZE")
$normalizeFindings = @($genericNormalizeFindings + $contextualNormalizeFindings | Sort-Object -Unique)

$automaticEscalationApplied = (
    $detectedEffectiveOutcome -eq "NORMALIZE" -and
    (Test-AutomaticEscalationReason -Reason $AutomaticEscalationReason) -and
    $normalizeFindings.Count -gt 0
)

if ($automaticEscalationApplied) {
    $effectiveOutcome = "REACQUIRE"
}

$supportedCodes = @(
    "video.dolby_vision",
    "video.codec_prohibited",
    "audio.missing",
    "language.preferred_missing",
    "probe.diagnostic_error"
)

$triggerFindings = if ($automaticEscalationApplied) {
    @($normalizeFindings)
}
else {
    @($allFindings | Where-Object { $supportedCodes -contains $_ })
}
$unsupportedReacquireFindings = @(
    $allFindings |
        Where-Object {
            $_ -notin $supportedCodes -and
            (
                $_ -like "video.*" -or
                $_ -like "audio.*" -or
                $_ -like "language.*"
            )
        }
)

$entityId = Get-PropertyValue -Object $entity -Name "id"
$fileId = Get-PropertyValue -Object $file -Name "id"
$downloadId = [string](Get-PropertyValue -Object $release -Name "downloadId" -Default "")
$releaseTitle = [string](Get-PropertyValue -Object $release -Name "title" -Default "")
$sceneName = [string](Get-PropertyValue -Object $file -Name "sceneName" -Default "")
$releaseGroup = [string](Get-PropertyValue -Object $file -Name "releaseGroup" -Default "")
$indexer = [string](Get-PropertyValue -Object $release -Name "indexer" -Default "")
$quality = [string](Get-PropertyValue -Object $file -Name "quality" -Default "")
$preferredLanguage = if ($null -ne $contextual) {
    [string](Get-PropertyValue -Object $contextual -Name "preferredLanguage" -Default "")
}
else { "" }

$releaseIdentityStrength = "NONE"
$primaryReleaseIdentity = $null

if (-not [string]::IsNullOrWhiteSpace($downloadId)) {
    $releaseIdentityStrength = "STRONG"
    $primaryReleaseIdentity = "downloadId:" + $downloadId
}
elseif (-not [string]::IsNullOrWhiteSpace($releaseTitle)) {
    $releaseIdentityStrength = "MEDIUM"
    $primaryReleaseIdentity = "releaseTitle:" + $releaseTitle
}
elseif (-not [string]::IsNullOrWhiteSpace($sceneName)) {
    $releaseIdentityStrength = "MEDIUM"
    $primaryReleaseIdentity = "sceneName:" + $sceneName
}
elseif (-not [string]::IsNullOrWhiteSpace($releaseGroup)) {
    $releaseIdentityStrength = "WEAK"
    $primaryReleaseIdentity = "releaseGroup:" + $releaseGroup
}

$sourceSnapshot = Get-SourceSnapshot -MediaPath $mediaPath -ValidatorResult $validator

$status = "NOT_NEEDED"
$reason = "effective_outcome_not_reacquire"

if ($effectiveOutcome -eq "REACQUIRE") {
    $status = "PLANNED"
    $reason = $null

    if ($source -notin @("Radarr", "Sonarr")) {
        $status = "BLOCKED"
        $reason = "unsupported_arr_source"
    }
    elseif ($null -eq $entityId -or [int]$entityId -le 0) {
        $status = "BLOCKED"
        $reason = "arr_entity_id_missing"
    }
    elseif ($null -eq $fileId -or [int]$fileId -le 0) {
        $status = "BLOCKED"
        $reason = "arr_file_id_missing"
    }
    elseif ([string]::IsNullOrWhiteSpace($mediaPath) -or $null -eq $sourceSnapshot) {
        $status = "BLOCKED"
        $reason = "source_snapshot_unavailable"
    }
    elseif ($triggerFindings.Count -eq 0) {
        $status = "BLOCKED"
        $reason = "unsupported_reacquire_finding"
    }
    elseif ($releaseIdentityStrength -in @("NONE", "WEAK")) {
        $status = "BLOCKED"
        $reason = "release_identity_not_strong_enough"
    }
}

$episode = Get-PropertyValue -Object $context -Name "episode"
$episodeIds = @()
if ($null -ne $episode) {
    $episodeIds = @(
        @(Get-PropertyValue -Object $episode -Name "ids" -Default @()) |
            ForEach-Object {
                $parsed = 0
                if ([int]::TryParse([string]$_, [ref]$parsed)) { $parsed }
            }
    )
}

$loopIdentity = [ordered]@{
    source = $source
    entityId = $entityId
    mediaPath = if ([string]::IsNullOrWhiteSpace($mediaPath)) { $null } else { $mediaPath.ToLowerInvariant() }
    releaseIdentity = $primaryReleaseIdentity
    findingCodes = @($triggerFindings | Sort-Object)
}
$loopKey = Get-Sha256 -Text ($loopIdentity | ConvertTo-Json -Depth 10 -Compress)

$result = [pscustomobject][ordered]@{
    schemaVersion = "1.0"
    plannerVersion = $PlannerVersion
    timestampUtc = [DateTime]::UtcNow.ToString("o")
    status = $status
    reason = $reason
    source = $source
    detectedEffectiveOutcome = $detectedEffectiveOutcome
    effectiveOutcome = $effectiveOutcome
    automaticEscalation = if ($automaticEscalationApplied) {
        [ordered]@{
            type = "NORMALIZATION_NOT_SAFELY_ACTIONABLE"
            from = "NORMALIZE"
            to = "REACQUIRE"
            reason = $AutomaticEscalationReason
            findingCodes = @($normalizeFindings)
        }
    }
    else { $null }
    mediaPath = $mediaPath
    entity = [ordered]@{
        id = $entityId
        title = Get-PropertyValue -Object $entity -Name "title"
        type = Get-PropertyValue -Object $entity -Name "type"
    }
    file = [ordered]@{
        id = $fileId
        quality = $quality
        sceneName = if ([string]::IsNullOrWhiteSpace($sceneName)) { $null } else { $sceneName }
        releaseGroup = if ([string]::IsNullOrWhiteSpace($releaseGroup)) { $null } else { $releaseGroup }
    }
    episodeIds = @($episodeIds)
    preferredLanguage = if ([string]::IsNullOrWhiteSpace($preferredLanguage)) { $null } else { $preferredLanguage }
    triggerFindingCodes = @($triggerFindings)
    allFindingCodes = @($allFindings)
    unsupportedFindingCodes = @($unsupportedReacquireFindings)
    sourceSnapshot = $sourceSnapshot
    releaseIdentity = [ordered]@{
        strength = $releaseIdentityStrength
        primary = $primaryReleaseIdentity
        downloadId = if ([string]::IsNullOrWhiteSpace($downloadId)) { $null } else { $downloadId }
        releaseTitle = if ([string]::IsNullOrWhiteSpace($releaseTitle)) { $null } else { $releaseTitle }
        sceneName = if ([string]::IsNullOrWhiteSpace($sceneName)) { $null } else { $sceneName }
        releaseGroup = if ([string]::IsNullOrWhiteSpace($releaseGroup)) { $null } else { $releaseGroup }
        indexer = if ([string]::IsNullOrWhiteSpace($indexer)) { $null } else { $indexer }
    }
    loopPrevention = [ordered]@{
        loopKey = $loopKey
        maxAutomaticAttempts = 3
        requireDifferentRelease = $true
        requireRevalidationAfterImport = $true
    }
    proposedActions = if ($status -eq "PLANNED") {
        @(
            [ordered]@{
                order = 1
                action = "locate_exact_import_history"
                mutating = $false
            },
            [ordered]@{
                order = 2
                action = "mark_history_failed"
                mutating = $true
                enabledInThisVersion = $false
            },
            [ordered]@{
                order = 3
                action = if ($source -eq "Radarr") { "MoviesSearch" } else { "EpisodeSearch" }
                mutating = $true
                enabledInThisVersion = $false
            },
            [ordered]@{
                order = 4
                action = "revalidate_replacement"
                mutating = $false
            }
        )
    }
    else { @() }
    sourceFiles = [ordered]@{
        contextPath = $ContextPath
        validatorResultPath = $ValidatorResultPath
        contextualResultPath = if ([string]::IsNullOrWhiteSpace($ContextualResultPath)) { $null } else { $ContextualResultPath }
    }
    executionEnabled = $false
}

Write-Result -Result $result
exit 0
