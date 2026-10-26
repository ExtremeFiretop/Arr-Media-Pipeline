[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ContextPath,

    [Parameter(Mandatory = $true)]
    [string]$ValidatorResultPath,

    [string]$ContextualResultPath = "",

    [Parameter(Mandatory = $true)]
    [string]$JsonOut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PlannerVersion = "0.2.3"

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $false)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function Normalize-Language {
    param([string]$Language)

    if ([string]::IsNullOrWhiteSpace($Language)) {
        return "und"
    }

    $value = $Language.Trim().ToLowerInvariant()

    switch ($value) {
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
        "und" { return "und" }
        default { return $value }
    }
}

function Get-FindingCodes {
    param($Result)

    if ($null -eq $Result) {
        return @()
    }

    return @(
        @(Get-PropertyValue -Object $Result -Name "findings" -Default @()) |
            Where-Object { $null -ne $_ } |
            ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "code" -Default "") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}


function Get-StreamFingerprint {
    param($ValidatorResult)

    function SafeValue {
        param($Object, [string]$Name, $Default = $null)
        if ($null -eq $Object) { return $Default }
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $Default }
        return $property.Value
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
                    default = [bool](SafeValue $_ "default" $false)
                    forced = [bool](SafeValue $_ "forced" $false)
                    hearingImpaired = [bool](SafeValue $_ "hearingImpaired" $false)
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
    param(
        [string]$MediaPath,
        $ValidatorResult
    )

    if (-not (Test-Path -LiteralPath $MediaPath -PathType Leaf)) {
        return $null
    }

    $item = Get-Item -LiteralPath $MediaPath

    return [pscustomobject][ordered]@{
        lengthBytes = [int64]$item.Length
        lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString("o")
        streamFingerprint = Get-StreamFingerprint -ValidatorResult $ValidatorResult
    }
}

function New-PlanResult {
    param(
        [string]$Status,
        [string]$Reason,
        [string]$MediaPath,
        [string]$PreferredLanguage,
        [object[]]$Actions,
        [object[]]$CandidateTracks,
        [string]$CommandPreview,
        $SourceSnapshot = $null,
        [object[]]$PlannedFindingCodes = @()
    )

    return [pscustomobject][ordered]@{
        schemaVersion = "1.0"
        plannerVersion = $PlannerVersion
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        status = $Status
        reason = if ([string]::IsNullOrWhiteSpace($Reason)) { $null } else { $Reason }
        mediaPath = $MediaPath
        container = if ([string]::IsNullOrWhiteSpace($MediaPath)) { $null } else { [System.IO.Path]::GetExtension($MediaPath).TrimStart('.').ToLowerInvariant() }
        strategy = if ($Status -eq "PLANNED") { "guarded_mkvmerge_remux" } else { $null }
        preferredLanguage = if ([string]::IsNullOrWhiteSpace($PreferredLanguage)) { $null } else { $PreferredLanguage }
        candidateTracks = @($CandidateTracks)
        actions = @($Actions)
        plannedFindingCodes = @($PlannedFindingCodes)
        sourceSnapshot = $SourceSnapshot
        sourceFiles = [ordered]@{
            contextPath = $ContextPath
            validatorResultPath = $ValidatorResultPath
            contextualResultPath = if ([string]::IsNullOrWhiteSpace($ContextualResultPath)) { $null } else { $ContextualResultPath }
        }
        commandPreview = if ([string]::IsNullOrWhiteSpace($CommandPreview)) { $null } else { $CommandPreview }
        mutatesMedia = $false
    }
}

function Write-Plan {
    param($Result)

    $Result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    exit 0
}

function Quote-PreviewArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + ($Value -replace '"', '\"') + '"'
}

try {
    $context = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $validator = Get-Content -LiteralPath $ValidatorResultPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $contextual = $null
    if (-not [string]::IsNullOrWhiteSpace($ContextualResultPath) -and
        (Test-Path -LiteralPath $ContextualResultPath -PathType Leaf)) {
        $contextual = Get-Content -LiteralPath $ContextualResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $file = Get-PropertyValue -Object $context -Name "file"
    $mediaPath = [string](Get-PropertyValue -Object $file -Name "path" -Default "")
    $sourceSnapshot = Get-SourceSnapshot -MediaPath $mediaPath -ValidatorResult $validator

    if ([string]::IsNullOrWhiteSpace($mediaPath)) {
        Write-Plan (New-PlanResult -Status "SKIPPED" -Reason "media_path_missing" -MediaPath "" -PreferredLanguage "" -Actions @() -CandidateTracks @() -CommandPreview "")
    }

    $extension = [System.IO.Path]::GetExtension($mediaPath).ToLowerInvariant()
    if ($extension -ne ".mkv") {
        Write-Plan (New-PlanResult -Status "SKIPPED" -Reason "container_not_supported" -MediaPath $mediaPath -PreferredLanguage "" -Actions @() -CandidateTracks @() -CommandPreview "")
    }

    $genericCodes = @(Get-FindingCodes -Result $validator)
    $contextualCodes = @(Get-FindingCodes -Result $contextual)

    $normalizableCodes = @(
        "audio.no_default",
        "audio.multiple_defaults",
        "audio.commentary_default",
        "audio.preferred_language_not_default",
        "language.preferred_not_default"
    )

    $supportedFindingCodes = @(
        @($genericCodes + $contextualCodes) |
            Where-Object { $normalizableCodes -contains $_ } |
            Select-Object -Unique
    )

    $needsNormalization = ($supportedFindingCodes.Count -gt 0)

    if (-not $needsNormalization) {
        Write-Plan (New-PlanResult -Status "NOT_NEEDED" -Reason "no_supported_normalization_findings" -MediaPath $mediaPath -PreferredLanguage "" -Actions @() -CandidateTracks @() -CommandPreview "")
    }

    $audio = @(
        @(Get-PropertyValue -Object $validator -Name "audio" -Default @()) |
            Where-Object { $null -ne $_ }
    )

    if ($audio.Count -eq 0) {
        Write-Plan (New-PlanResult -Status "BLOCKED" -Reason "audio_tracks_missing" -MediaPath $mediaPath -PreferredLanguage "" -Actions @() -CandidateTracks @() -CommandPreview "")
    }

    # Add a stable audio-track ordinal. mkvpropedit track:a1/a2 selectors are
    # audio ordinals, not ffprobe's global stream indexes.
    $audioTracks = @()
    for ($i = 0; $i -lt $audio.Count; $i++) {
        $track = $audio[$i]
        $audioTracks += [pscustomobject][ordered]@{
            audioOrdinal = $i + 1
            ffprobeStreamIndex = Get-PropertyValue -Object $track -Name "index" -Default -1
            language = Normalize-Language ([string](Get-PropertyValue -Object $track -Name "language" -Default ""))
            title = [string](Get-PropertyValue -Object $track -Name "title" -Default "")
            codec = [string](Get-PropertyValue -Object $track -Name "codec" -Default "")
            channels = Get-PropertyValue -Object $track -Name "channels"
            default = [bool](Get-PropertyValue -Object $track -Name "default" -Default $false)
            commentary = [bool](Get-PropertyValue -Object $track -Name "commentary" -Default $false)
            legacyCompatibility = [string]::Equals(
                ([string](Get-PropertyValue -Object $track -Name "title" -Default "")).Trim(),
                "Transcoded Compatibility Track",
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
    }

    $mainAudio = @($audioTracks | Where-Object { -not $_.commentary })
    if ($mainAudio.Count -eq 0) {
        Write-Plan (New-PlanResult -Status "BLOCKED" -Reason "no_non_commentary_audio" -MediaPath $mediaPath -PreferredLanguage "" -Actions @() -CandidateTracks @($audioTracks) -CommandPreview "")
    }

    $preferredLanguage = ""
    $contextualStatus = ""
    if ($null -ne $contextual) {
        $contextualStatus = [string](Get-PropertyValue -Object $contextual -Name "status" -Default "")
        if ($contextualStatus -eq "APPLIED") {
            $preferredLanguage = Normalize-Language ([string](Get-PropertyValue -Object $contextual -Name "preferredLanguage" -Default ""))
            if ($preferredLanguage -eq "und") {
                $preferredLanguage = ""
            }
        }
    }

    $target = $null
    $candidateTracks = @()

    if (-not [string]::IsNullOrWhiteSpace($preferredLanguage)) {
        $allPreferredTracks = @($mainAudio | Where-Object { $_.language -eq $preferredLanguage })
        $nonLegacyPreferredTracks = @(
            $allPreferredTracks | Where-Object {
                ([string]$_.title) -notmatch '(?i)^\s*Transcoded Compatibility Track\s*$'
            }
        )
        if ($nonLegacyPreferredTracks.Count -gt 0) { $candidateTracks = @($nonLegacyPreferredTracks) }
        else { $candidateTracks = @($allPreferredTracks) }

        if ($candidateTracks.Count -eq 1) {
            $target = $candidateTracks[0]
        }
        elseif ($candidateTracks.Count -gt 1) {
            $preferredDefaults = @($candidateTracks | Where-Object { $_.default })
            if ($preferredDefaults.Count -eq 1) {
                $target = $preferredDefaults[0]
                $candidateTracks = @($preferredDefaults)
            }
            else {
                Write-Plan (New-PlanResult -Status "BLOCKED" -Reason "multiple_preferred_audio_candidates" -MediaPath $mediaPath -PreferredLanguage $preferredLanguage -Actions @() -CandidateTracks @($candidateTracks) -CommandPreview "")
            }
        }
        else {
            Write-Plan (New-PlanResult -Status "BLOCKED" -Reason "preferred_audio_candidate_missing" -MediaPath $mediaPath -PreferredLanguage $preferredLanguage -Actions @() -CandidateTracks @($mainAudio) -CommandPreview "")
        }
    }
    else {
        $nonCommentaryDefaults = @($mainAudio | Where-Object { $_.default })

        if ($mainAudio.Count -eq 1) {
            $target = $mainAudio[0]
            $candidateTracks = @($mainAudio)
        }
        elseif ($nonCommentaryDefaults.Count -eq 1) {
            # Safe for cases such as commentary-default cleanup where one
            # existing non-commentary default is clearly the main track.
            $target = $nonCommentaryDefaults[0]
            $candidateTracks = @($nonCommentaryDefaults)
        }
        elseif ($nonCommentaryDefaults.Count -gt 1) {
            # Legacy compatibility processors created an AC-3 track named
            # exactly "Transcoded Compatibility Track" and could leave both
            # that fallback and the original program track marked default.
            # Do not choose a track by codec/quality. Only resolve the ambiguity
            # when exactly one *already-default* non-legacy program track exists
            # and every other non-commentary default is the known legacy track.
            $nonLegacyDefaults = @($nonCommentaryDefaults | Where-Object { -not $_.legacyCompatibility })
            $legacyDefaults = @($nonCommentaryDefaults | Where-Object { $_.legacyCompatibility })

            if ($nonLegacyDefaults.Count -eq 1 -and $legacyDefaults.Count -ge 1) {
                $target = $nonLegacyDefaults[0]
                $candidateTracks = @($nonCommentaryDefaults)
            }
            else {
                Write-Plan (New-PlanResult -Status "BLOCKED" -Reason "ambiguous_default_audio_target" -MediaPath $mediaPath -PreferredLanguage "" -Actions @() -CandidateTracks @($mainAudio) -CommandPreview "")
            }
        }
        else {
            Write-Plan (New-PlanResult -Status "BLOCKED" -Reason "ambiguous_default_audio_target" -MediaPath $mediaPath -PreferredLanguage "" -Actions @() -CandidateTracks @($mainAudio) -CommandPreview "")
        }
    }

    if ($null -eq $target) {
        Write-Plan (New-PlanResult -Status "BLOCKED" -Reason "audio_target_not_resolved" -MediaPath $mediaPath -PreferredLanguage $preferredLanguage -Actions @() -CandidateTracks @($candidateTracks) -CommandPreview "")
    }

    $actions = @()

    foreach ($track in $audioTracks) {
        $desiredDefault = ($track.audioOrdinal -eq $target.audioOrdinal)

        if ($track.default -ne $desiredDefault) {
            $actions += [pscustomobject][ordered]@{
                action = "set_audio_default_flag"
                audioOrdinal = $track.audioOrdinal
                mkvpropeditSelector = ("track:a{0}" -f $track.audioOrdinal)
                ffprobeStreamIndex = $track.ffprobeStreamIndex
                language = $track.language
                commentary = $track.commentary
                from = $track.default
                to = $desiredDefault
                reason = if ($desiredDefault) { "selected_default_audio" } else { "clear_other_default_audio" }
            }
        }
    }

    if ($actions.Count -eq 0) {
        Write-Plan (New-PlanResult -Status "NOT_NEEDED" -Reason "target_audio_already_exclusive_default" -MediaPath $mediaPath -PreferredLanguage $preferredLanguage -Actions @() -CandidateTracks @($candidateTracks) -CommandPreview "")
    }

    $preview = "Guarded mkvmerge remux; input track IDs are resolved and re-verified at execution time."

    Write-Plan (New-PlanResult `
        -Status "PLANNED" `
        -Reason "" `
        -MediaPath $mediaPath `
        -PreferredLanguage $preferredLanguage `
        -Actions @($actions) `
        -CandidateTracks @($candidateTracks) `
        -CommandPreview $preview `
        -SourceSnapshot $sourceSnapshot `
        -PlannedFindingCodes @($supportedFindingCodes))
}
catch {
    $failure = [pscustomobject][ordered]@{
        schemaVersion = "1.0"
        plannerVersion = $PlannerVersion
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        status = "ERROR"
        reason = "planner_error"
        error = $_.Exception.Message
        mutatesMedia = $false
    }

    $failure | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    exit 0
}
