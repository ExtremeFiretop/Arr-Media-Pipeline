Set-StrictMode -Version Latest

function Normalize-ReacquisitionReleaseText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $normalized = $Value.Trim().ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, '[\s\.\-_]+', ' ')
    $normalized = [regex]::Replace($normalized, '[^a-z0-9+ ]', '')
    $normalized = [regex]::Replace($normalized, '\s+', ' ')
    return $normalized.Trim()
}

function Get-ReacquisitionReleaseGroup {
    param($Release)

    $group = [string](Get-PropertyValue -Object $Release -Name "releaseGroup" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($group)) { return $group.Trim() }

    $title = [string](Get-PropertyValue -Object $Release -Name "title" -Default "")
    if ($title -match '-([A-Za-z0-9][A-Za-z0-9._]{1,31})$') {
        return $matches[1]
    }

    return ""
}

function Get-ReacquisitionFailedReleaseContext {
    param($Chain)

    $groups = @()
    $titles = @()

    if ($null -ne $Chain) {
        foreach ($attempt in @(Get-PropertyValue -Object $Chain -Name "attempts" -Default @())) {
            $group = [string](Get-PropertyValue -Object $attempt -Name "releaseGroup" -Default "")
            if (-not [string]::IsNullOrWhiteSpace($group)) {
                $groups += $group.Trim().ToLowerInvariant()
            }

            $title = [string](Get-PropertyValue -Object $attempt -Name "releaseTitle" -Default "")
            $normalizedTitle = Normalize-ReacquisitionReleaseText $title
            if (-not [string]::IsNullOrWhiteSpace($normalizedTitle)) {
                $titles += $normalizedTitle
            }
        }
    }

    return [pscustomobject][ordered]@{
        groups = @($groups | Select-Object -Unique)
        titles = @($titles | Select-Object -Unique)
    }
}

function Test-ReacquisitionDiskOnlyRejection {
    param($Release)

    if ([bool](Get-PropertyValue -Object $Release -Name "approved" -Default $false)) { return $false }
    $rejections = @(Get-PropertyValue -Object $Release -Name "rejections" -Default @())
    if ($rejections.Count -eq 0) { return $false }

    $patterns = @(
        '^Existing file on disk is of equal or higher preference:',
        '^Existing file on disk is of equal or higher revision:',
        '^Existing file on disk has a equal or higher Custom Format score:',
        '^Existing file on disk has Custom Format score within Custom Format score increment:',
        '^Existing file on disk meets quality cutoff:',
        '^Existing file on disk meets Custom Format cutoff:',
        '^Existing file meets cutoff:',
        "^Existing file on disk and Quality Profile '.*' does not allow upgrades$"
    )

    foreach ($rejection in $rejections) {
        $reason = if ($null -ne (Get-PropertyValue -Object $rejection -Name "reason" -Default $null)) {
            [string](Get-PropertyValue -Object $rejection -Name "reason" -Default "")
        }
        else {
            [string]$rejection
        }

        $matched = $false
        foreach ($pattern in $patterns) {
            if ($reason -match $pattern) { $matched = $true; break }
        }
        if (-not $matched) { return $false }
    }

    return $true
}

function Get-ReacquisitionPredictedCandidatePool {
    param([Parameter(Mandatory = $true)][object[]]$Releases)

    # Preserve Radarr's original release ordering while predicting what will be
    # eligible once the current MovieFile is removed. A release belongs in the
    # predicted pool when it is already approved OR every current rejection is
    # attributable only to the existing file on disk.
    return @(
        $Releases | Where-Object {
            [bool](Get-PropertyValue -Object $_ -Name "approved" -Default $false) -or
            (Test-ReacquisitionDiskOnlyRejection -Release $_)
        }
    )
}

function Get-DolbyVisionReplacementEvidence {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [string[]]$FailedReleaseGroups = @(),
        [string[]]$FailedReleaseTitles = @(),
        [int]$RadarrRank = 0
    )

    $title = [string](Get-PropertyValue -Object $Release -Name "title" -Default "")
    $normalizedTitle = Normalize-ReacquisitionReleaseText $title
    $group = Get-ReacquisitionReleaseGroup -Release $Release
    $groupNormalized = if ([string]::IsNullOrWhiteSpace($group)) { "" } else { $group.Trim().ToLowerInvariant() }

    # Explicit DV wording is a hard local safety exclusion even if a Radarr
    # custom-format rule ever misses it. This is intentionally title evidence,
    # not a replacement for post-import ffprobe validation.
    $hasExplicitDv = ($title -match '(?i)(^|[\s._\-\[\(])(?:dovi|dv|dolby[\s._-]?vision)(?=$|[\s._\-\]\)])')
    $hasHdr10Plus = ($title -match '(?i)(^|[\s._\-\[\(])hdr10(?:\+|plus|p)(?=$|[\s._\-\]\)])')
    $hasHdr10 = (-not $hasHdr10Plus -and $title -match '(?i)(^|[\s._\-\[\(])hdr10(?=$|[\s._\-\]\)])')
    $hasSdr = ($title -match '(?i)(^|[\s._\-\[\(])sdr(?=$|[\s._\-\]\)])')
    $hasHdr = (-not $hasHdr10Plus -and -not $hasHdr10 -and $title -match '(?i)(^|[\s._\-\[\(])hdr(?=$|[\s._\-\]\)])')
    $isWeb = ($title -match '(?i)(^|[\s._\-])web(?:[\s._-]?dl|rip)?(?=$|[\s._\-])')
    $isUhdBluray = ($title -match '(?i)(uhd.*blu[ ._-]?ray|blu[ ._-]?ray.*2160p|2160p.*blu[ ._-]?ray)')

    $failedTitleMatch = (-not [string]::IsNullOrWhiteSpace($normalizedTitle) -and $FailedReleaseTitles -contains $normalizedTitle)
    $failedGroupMatch = (-not [string]::IsNullOrWhiteSpace($groupNormalized) -and $FailedReleaseGroups -contains $groupNormalized)

    $excluded = $false
    $exclusionReason = $null
    $tier = 99
    $evidence = "UNKNOWN"

    if ($hasExplicitDv) {
        $excluded = $true
        $exclusionReason = "explicit_dolby_vision_title"
        $evidence = "EXPLICIT_DOLBY_VISION"
    }
    elseif ($failedTitleMatch) {
        # A previously failed exact release title is never deliberately selected
        # again, even if it appears from another indexer.
        $excluded = $true
        $exclusionReason = "previously_failed_exact_release_title"
        $evidence = "PREVIOUSLY_FAILED_RELEASE"
    }
    elseif ($hasHdr10Plus) {
        $tier = 0
        $evidence = "EXPLICIT_HDR10_PLUS"
    }
    elseif ($hasHdr10) {
        $tier = 0
        $evidence = "EXPLICIT_HDR10"
    }
    elseif ($hasSdr) {
        $tier = 1
        $evidence = "EXPLICIT_SDR"
    }
    elseif ($hasHdr) {
        $tier = 2
        $evidence = "EXPLICIT_HDR_GENERIC"
    }
    elseif ($isWeb) {
        $tier = 3
        $evidence = "UNKNOWN_WEB"
    }
    elseif ($isUhdBluray) {
        # This is intentionally last among unknowns for a DV reacquisition.
        # The real Fantastic Four chain demonstrated that generic UHD BluRay
        # release names can repeatedly hide Dolby Vision.
        $tier = 5
        $evidence = "UNKNOWN_UHD_BLURAY"
    }
    else {
        $tier = 4
        $evidence = "UNKNOWN_OTHER"
    }

    # Failed groups are not permanently banned: an explicitly-labelled HDR10,
    # HDR or SDR release from the same group may still be useful. For unknown
    # releases, however, prefer a different group before trying that group again.
    $failedGroupPenalty = 0
    if ($failedGroupMatch -and $tier -ge 3) {
        $failedGroupPenalty = 1
    }

    return [pscustomobject][ordered]@{
        release = $Release
        title = $title
        releaseGroup = $group
        customFormatScore = [int](Get-PropertyValue -Object $Release -Name "customFormatScore" -Default 0)
        indexer = [string](Get-PropertyValue -Object $Release -Name "indexer" -Default "")
        protocol = [string](Get-PropertyValue -Object $Release -Name "protocol" -Default "")
        size = [int64](Get-PropertyValue -Object $Release -Name "size" -Default 0)
        approved = [bool](Get-PropertyValue -Object $Release -Name "approved" -Default $false)
        evidence = $evidence
        safetyTier = $tier
        failedGroupMatch = $failedGroupMatch
        failedGroupPenalty = $failedGroupPenalty
        radarrRank = $RadarrRank
        excluded = $excluded
        exclusionReason = $exclusionReason
    }
}

function Select-ReacquisitionRelease {
    param(
        [Parameter(Mandatory = $true)][object[]]$Releases,
        [string[]]$TriggerFindingCodes = @(),
        $Chain = $null
    )

    $isDolbyVisionReacquisition = ($TriggerFindingCodes -contains "video.dolby_vision")
    if (-not $isDolbyVisionReacquisition) {
        return [pscustomobject][ordered]@{
            strategy = "RADARR_NATIVE"
            ranked = @()
            selected = $null
            selectedRelease = $null
            eligibleCount = $Releases.Count
            excludedCount = 0
        }
    }

    $failedContext = Get-ReacquisitionFailedReleaseContext -Chain $Chain
    $ranked = @()
    for ($i = 0; $i -lt $Releases.Count; $i++) {
        $ranked += Get-DolbyVisionReplacementEvidence `
            -Release $Releases[$i] `
            -FailedReleaseGroups $failedContext.groups `
            -FailedReleaseTitles $failedContext.titles `
            -RadarrRank $i
    }

    $eligible = @(
        $ranked |
            Where-Object { -not $_.excluded } |
            Sort-Object `
                @{ Expression = { $_.safetyTier }; Ascending = $true },
                @{ Expression = { $_.failedGroupPenalty }; Ascending = $true },
                @{ Expression = { $_.radarrRank }; Ascending = $true }
    )

    $selected = if ($eligible.Count -gt 0) { $eligible[0] } else { $null }

    return [pscustomobject][ordered]@{
        strategy = "DOLBY_VISION_SAFE_EVIDENCE_V1"
        ranked = @($eligible)
        selected = $selected
        selectedRelease = if ($null -ne $selected) { $selected.release } else { $null }
        eligibleCount = $eligible.Count
        excludedCount = @($ranked | Where-Object { $_.excluded }).Count
    }
}

function ConvertTo-ReacquisitionReleaseSummary {
    param($Candidate)

    if ($null -eq $Candidate) { return $null }

    return [pscustomobject][ordered]@{
        title = $Candidate.title
        releaseGroup = $Candidate.releaseGroup
        evidence = $Candidate.evidence
        safetyTier = $Candidate.safetyTier
        failedGroupMatch = $Candidate.failedGroupMatch
        failedGroupPenalty = $Candidate.failedGroupPenalty
        radarrRank = $Candidate.radarrRank
        customFormatScore = $Candidate.customFormatScore
        indexer = $Candidate.indexer
        protocol = $Candidate.protocol
        size = $Candidate.size
    }
}
