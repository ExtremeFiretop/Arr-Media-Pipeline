[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlanPath,

    [string]$QuarantineRoot = "",

    [string]$JsonOut = "",

    [switch]$Execute,

    [string]$ConfirmLoopKey = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ExecutorVersion = "0.1.1"
$IntegrationRoot = $PSScriptRoot
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"
$StateRoot = Join-Path $IntegrationRoot "Reacquisition\quarantine-state"
$SonarrCommonPath = Join-Path $IntegrationRoot "SonarrReacquisitionCommon.ps1"
$ChainCommonPath = Join-Path $IntegrationRoot "ReacquisitionChainCommon.ps1"
$ValidatorPath = Join-Path (Split-Path -Parent $IntegrationRoot) "MediaValidator.ps1"
$PolicyPath = Join-Path (Split-Path -Parent $IntegrationRoot) "validator-policy.json"
$ChainWorkRoot = Join-Path $IntegrationRoot "Reacquisition\chain-work"
. $ChainCommonPath
. $SonarrCommonPath

function Get-PropertyValue {
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Test-PathEquivalent {
    param([string]$First, [string]$Second)

    if ([string]::IsNullOrWhiteSpace($First) -or [string]::IsNullOrWhiteSpace($Second)) {
        return $false
    }

    try {
        $a = [System.IO.Path]::GetFullPath($First).TrimEnd("\")
        $b = [System.IO.Path]::GetFullPath($Second).TrimEnd("\")
        return [string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return [string]::Equals($First, $Second, [System.StringComparison]::OrdinalIgnoreCase)
    }
}

function Test-IsChildPath {
    param([string]$Candidate, [string]$Parent)

    try {
        $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd("\") + "\"
        $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd("\") + "\"

        return $candidateFull.StartsWith(
            $parentFull,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temp = $Path + ".tmp-" + [guid]::NewGuid().ToString("N")
    try {
        $Object | ConvertTo-Json -Depth 50 |
            Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-Result {
    param($Object)

    if (-not [string]::IsNullOrWhiteSpace($JsonOut)) {
        $Object | ConvertTo-Json -Depth 50 |
            Set-Content -LiteralPath $JsonOut -Encoding UTF8
    }

    $Object | ConvertTo-Json -Depth 50
}

function Get-RecordArray {
    param($Response)

    if ($null -eq $Response) { return @() }

    $records = Get-PropertyValue -Object $Response -Name "records" -Default $null
    if ($null -ne $records) {
        return @($records)
    }

    return @($Response)
}


function Normalize-ReleaseTitle {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    $normalized = [System.Text.RegularExpressions.Regex]::Replace(
        $normalized,
        '[\s\.\-_]+',
        ' '
    )
    $normalized = [System.Text.RegularExpressions.Regex]::Replace(
        $normalized,
        '[^a-z0-9 ]',
        ''
    )
    $normalized = [System.Text.RegularExpressions.Regex]::Replace(
        $normalized,
        '\s+',
        ' '
    )

    return $normalized.Trim()
}

function Test-MatchingBlocklist {
    param(
        [object[]]$Records,
        [int]$SeriesId,
        [string]$SourceTitle
    )

    $expectedTitle = Normalize-ReleaseTitle $SourceTitle

    return @(
        $Records |
            Where-Object {
                $recordSeriesId = [int](
                    Get-PropertyValue -Object $_ -Name "seriesId" -Default 0
                )
                $recordTitle = [string](
                    Get-PropertyValue -Object $_ -Name "sourceTitle" -Default ""
                )
                $normalizedRecordTitle = Normalize-ReleaseTitle $recordTitle

                $seriesMatches = (
                    $SeriesId -le 0 -or
                    $recordSeriesId -eq 0 -or
                    $recordSeriesId -eq $SeriesId
                )

                $titleMatches = (
                    -not [string]::IsNullOrWhiteSpace($expectedTitle) -and
                    -not [string]::IsNullOrWhiteSpace($normalizedRecordTitle) -and
                    [string]::Equals(
                        $normalizedRecordTitle,
                        $expectedTitle,
                        [System.StringComparison]::Ordinal
                    )
                )

                $seriesMatches -and $titleMatches
            }
    )
}

function Test-DiskOnlyRejection {
    param($Release)

    if ([bool](Get-PropertyValue -Object $Release -Name "approved" -Default $false)) {
        return $false
    }

    $rejections = @(
        Get-PropertyValue -Object $Release -Name "rejections" -Default @()
    )

    if ($rejections.Count -eq 0) {
        return $false
    }

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
        $matched = $false
        foreach ($pattern in $patterns) {
            if ([string]$rejection -match $pattern) {
                $matched = $true
                break
            }
        }

        if (-not $matched) {
            return $false
        }
    }

    return $true
}

function Get-ApprovedReleases {
    param($Connection, [int[]]$EpisodeIds)

    $relativePath = Get-SonarrReleaseSearchRelativePath -EpisodeIds $EpisodeIds
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        return [pscustomobject]@{
            mode = "MULTI_EPISODE_SEARCH_ONLY"
            all = @()
            approved = @()
            diskOnly = @()
        }
    }

    $response = Invoke-SonarrApi `
        -Connection $Connection `
        -RelativePath $relativePath `
        -Method GET

    $releases = @(Get-RecordArray -Response $response)

    return [pscustomobject]@{
        mode = "SINGLE_EPISODE_RELEASE_SEARCH"
        all = @($releases)
        approved = @(
            $releases |
                Where-Object {
                    [bool](Get-PropertyValue -Object $_ -Name "approved" -Default $false)
                }
        )
        diskOnly = @(
            $releases |
                Where-Object { Test-DiskOnlyRejection -Release $_ }
        )
    }
}

function Get-EpisodeFiles {
    param($Connection, [int]$SeriesId)

    $response = Invoke-SonarrApi `
        -Connection $Connection `
        -RelativePath ("episodefile?seriesId={0}" -f $SeriesId) `
        -Method GET

    return @(
        Get-RecordArray -Response $response
    )
}

function Find-EpisodeFileByPath {
    param([object[]]$Files, [string]$Path)

    return @(
        $Files |
            Where-Object {
                Test-PathEquivalent `
                    -First ([string](Get-PropertyValue -Object $_ -Name "path" -Default "")) `
                    -Second $Path
            }
    )
}

function Invoke-Rollback {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][int]$SeriesId,
        [Parameter(Mandatory = $true)][string]$OriginalPath,
        [Parameter(Mandatory = $true)][string]$QuarantinePath,
        [Parameter(Mandatory = $true)][int64]$ExpectedBytes
    )

    $rollback = [ordered]@{
        attempted = $true
        physicalFileRestored = $false
        rescanCommandId = $null
        rescanStatus = $null
        sonarrFileRestored = $false
        restoredFileId = $null
        pathMatches = $false
        sizeMatches = $false
        error = $null
    }

    try {
        if (Test-Path -LiteralPath $OriginalPath -PathType Leaf) {
            throw "Rollback destination already contains a file: $OriginalPath"
        }

        if (-not (Test-Path -LiteralPath $QuarantinePath -PathType Leaf)) {
            throw "Quarantine file is missing during rollback: $QuarantinePath"
        }

        $originalDirectory = Split-Path -Parent $OriginalPath
        if (-not (Test-Path -LiteralPath $originalDirectory)) {
            New-Item -ItemType Directory -Path $originalDirectory -Force | Out-Null
        }

        Move-Item `
            -LiteralPath $QuarantinePath `
            -Destination $OriginalPath

        $restored = Get-Item -LiteralPath $OriginalPath
        if ([int64]$restored.Length -ne $ExpectedBytes) {
            throw "Restored file size does not match expected size."
        }

        $rollback.physicalFileRestored = $true

        $command = Invoke-SonarrApi `
            -Connection $Connection `
            -RelativePath "command" `
            -Method POST `
            -Body ([ordered]@{
                name = "RescanSeries"
                seriesId = $SeriesId
            })

        $commandId = [int](Get-PropertyValue -Object $command -Name "id" -Default 0)
        $rollback.rescanCommandId = $commandId

        if ($commandId -le 0) {
            throw "Sonarr did not return a valid RescanSeries command id."
        }

        $completed = Wait-SonarrCommand `
            -Connection $Connection `
            -CommandId $commandId

        $rollback.rescanStatus = [string](
            Get-PropertyValue -Object $completed -Name "status" -Default ""
        )

        if ($rollback.rescanStatus -ne "completed") {
            throw "Sonarr RescanSeries did not complete successfully."
        }

        $files = @(Get-EpisodeFiles -Connection $Connection -SeriesId $SeriesId)
        $matching = @(Find-EpisodeFileByPath -Files $files -Path $OriginalPath)

        if ($matching.Count -ne 1) {
            throw "Sonarr did not rediscover exactly one restored episode file."
        }

        $file = $matching[0]
        $arrBytes = [int64](Get-PropertyValue -Object $file -Name "size" -Default -1)

        $rollback.restoredFileId = [int](
            Get-PropertyValue -Object $file -Name "id" -Default 0
        )
        $rollback.pathMatches = $true
        $rollback.sizeMatches = ($arrBytes -eq $ExpectedBytes)
        $rollback.sonarrFileRestored = (
            $rollback.pathMatches -and $rollback.sizeMatches
        )

        if (-not $rollback.sonarrFileRestored) {
            throw "Sonarr restored-file reconciliation failed."
        }
    }
    catch {
        $rollback.error = $_.Exception.Message
    }

    return [pscustomobject]$rollback
}


function Initialize-SonarrChainFromQuarantine {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$PlanPath,
        [Parameter(Mandatory = $true)][string]$QuarantineStatePath,
        [Parameter(Mandatory = $true)][string]$QuarantinePath,
        [Parameter(Mandatory = $true)][string]$ValidatorPath,
        [Parameter(Mandatory = $true)][string]$PolicyPath,
        [Parameter(Mandatory = $true)][string]$WorkRoot
    )

    $entity = Get-PropertyValue -Object $Plan -Name "entity"
    $snapshot = Get-PropertyValue -Object $Plan -Name "sourceSnapshot"
    $releaseIdentity = Get-PropertyValue -Object $Plan -Name "releaseIdentity"
    $loopPrevention = Get-PropertyValue -Object $Plan -Name "loopPrevention"

    $seriesId = [int](Get-PropertyValue -Object $entity -Name "id" -Default 0)
    $episodeIds = @(Get-SonarrEpisodeIdsFromPlan -Plan $Plan)
    $loopKey = [string](Get-PropertyValue -Object $loopPrevention -Name "loopKey" -Default "")
    $maxAttempts = [int](Get-PropertyValue -Object $loopPrevention -Name "maxAutomaticAttempts" -Default 3)

    if ($seriesId -le 0 -or @($episodeIds).Count -eq 0 -or [string]::IsNullOrWhiteSpace($loopKey)) {
        throw "Cannot initialize Sonarr chain from incomplete plan identity."
    }

    $chainId = "sonarr-{0}-{1}" -f $seriesId, $loopKey.Substring(0, [Math]::Min(12, $loopKey.Length))
    $chainPath = Get-ReacquisitionChainPath `
        -IntegrationRoot $IntegrationRoot `
        -Source "Sonarr" `
        -EntityId $seriesId `
        -Discriminator (Get-SonarrEpisodeSetKey -EpisodeIds $episodeIds)

    $rollback = [pscustomobject][ordered]@{
        originalLoopKey = $loopKey
        source = "Sonarr"
        libraryType = "TV"
        path = $QuarantinePath
        lengthBytes = [int64](Get-PropertyValue -Object $snapshot -Name "lengthBytes" -Default -1)
        streamFingerprint = [string](Get-PropertyValue -Object $snapshot -Name "streamFingerprint" -Default "")
        releaseTitle = [string](Get-PropertyValue -Object $releaseIdentity -Name "releaseTitle" -Default "")
        releaseGroup = [string](Get-PropertyValue -Object $releaseIdentity -Name "releaseGroup" -Default "")
        sourcePlanPath = [System.IO.Path]::GetFullPath($PlanPath)
        sourceQuarantineStatePath = $QuarantineStatePath
    }

    $rollbackCheck = Test-ReacquisitionRollback `
        -Rollback $rollback `
        -ValidatorPath $ValidatorPath `
        -PolicyPath $PolicyPath `
        -WorkRoot $WorkRoot

    if (-not $rollbackCheck.verified) {
        throw "Quarantined Sonarr rollback failed verification during automatic chain initialization."
    }

    if (Test-Path -LiteralPath $chainPath -PathType Leaf) {
        $existing = Get-Content -LiteralPath $chainPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $existingId = [string](Get-PropertyValue -Object $existing -Name "chainId" -Default "")
        $existingSource = [string](Get-PropertyValue -Object $existing -Name "source" -Default "")
        $existingEntityId = [int](Get-PropertyValue -Object $existing -Name "entityId" -Default 0)
        $existingEpisodeIds = @(
            @(Get-PropertyValue -Object $existing -Name "episodeIds" -Default @()) |
                ForEach-Object { [int]$_ } |
                Sort-Object -Unique
        )
        $expectedEpisodeIds = @($episodeIds | Sort-Object -Unique)
        $episodeSetMatches = (($existingEpisodeIds -join ",") -eq ($expectedEpisodeIds -join ","))
        $existingStatus = [string](Get-PropertyValue -Object $existing -Name "status" -Default "")
        $existingRollback = Get-PropertyValue -Object $existing -Name "rollback"
        $existingRollbackPath = [string](Get-PropertyValue -Object $existingRollback -Name "path" -Default "")
        $existingRollbackBytes = [int64](Get-PropertyValue -Object $existingRollback -Name "lengthBytes" -Default -1)
        $existingRollbackFingerprint = [string](Get-PropertyValue -Object $existingRollback -Name "streamFingerprint" -Default "")
        $rollbackIdentityMatches = (
            (Test-PathEquivalent -First $existingRollbackPath -Second $rollback.path) -and
            $existingRollbackBytes -eq $rollback.lengthBytes -and
            [string]::Equals(
                $existingRollbackFingerprint,
                $rollback.streamFingerprint,
                [System.StringComparison]::Ordinal
            )
        )

        if (-not [string]::Equals($existingId, $chainId, [System.StringComparison]::Ordinal) -or
            $existingSource -ne "Sonarr" -or
            $existingEntityId -ne $seriesId -or
            -not $episodeSetMatches -or
            -not $rollbackIdentityMatches -or
            $existingStatus -ne "ACTIVE") {
            throw "An incompatible Sonarr reacquisition chain already exists for this episode set."
        }

        return [pscustomobject][ordered]@{
            chainId = $chainId
            chainPath = $chainPath
            status = "EXISTING_VERIFIED"
            written = $false
            rollbackVerified = $true
        }
    }

    $now = [DateTime]::UtcNow.ToString("o")
    $chainState = [pscustomobject][ordered]@{
        schemaVersion = "1.0"
        chainVersion = "0.1.1"
        chainId = $chainId
        source = "Sonarr"
        entityId = $seriesId
        episodeIds = @($episodeIds)
        status = "ACTIVE"
        maxAttempts = $maxAttempts
        failedAttemptCount = 1
        createdUtc = $now
        updatedUtc = $now
        rollback = [pscustomobject][ordered]@{
            originalLoopKey = $loopKey
            source = "Sonarr"
            libraryType = "TV"
            path = $rollback.path
            lengthBytes = $rollback.lengthBytes
            streamFingerprint = $rollback.streamFingerprint
            releaseTitle = $rollback.releaseTitle
            releaseGroup = $rollback.releaseGroup
            sourcePlanPath = $rollback.sourcePlanPath
            verifiedUtc = $now
        }
        attempts = @(
            [pscustomobject][ordered]@{
                attemptNumber = 1
                loopKey = $loopKey
                releaseTitle = $rollback.releaseTitle
                releaseGroup = $rollback.releaseGroup
                disposition = "ROLLBACK_PRESERVED"
                quarantinePath = $rollback.path
            }
        )
    }

    Write-AtomicJson -Path $chainPath -Object $chainState

    return [pscustomobject][ordered]@{
        chainId = $chainId
        chainPath = $chainPath
        status = "INITIALIZED"
        written = $true
        rollbackVerified = $true
    }
}

$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 |
    ConvertFrom-Json

$result = [ordered]@{
    schemaVersion = "1.0"
    executorVersion = $ExecutorVersion
    timestampUtc = [DateTime]::UtcNow.ToString("o")
    mode = if ($Execute) { "EXECUTE" } else { "DRY_RUN" }
    status = "BLOCKED"
    reason = $null
    source = [string](Get-PropertyValue -Object $plan -Name "source" -Default "")
    mediaPath = [string](Get-PropertyValue -Object $plan -Name "mediaPath" -Default "")
    seriesId = $null
    episodeIds = @()
    fileId = $null
    loopKey = $null
    sourceSnapshotMatches = $false
    arrFileMatches = $false
    reacquisitionStateVerified = $false
    blocklistVerified = $false
    blocklist = $null
    preRemovalSearch = $null
    predictedDiskBlockedCandidateCount = 0
    quarantine = $null
    mutation = [ordered]@{
        fileMoved = $false
        episodeFileRecordDeleted = $false
        episodeSearchSent = $false
        mutatingRequestsSent = 0
        chainStateInitialized = $false
        chainStateAlreadyPresent = $false
    }
    postRemovalSearch = $null
    replacementActivity = $null
    chainInitialization = $null
    rollback = $null
    statePath = $null
}

try {
    if ($result.source -ne "Sonarr") {
        $result.reason = "sonarr_only"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if ([string](Get-PropertyValue -Object $plan -Name "status" -Default "") -ne "PLANNED") {
        $result.reason = "plan_not_planned"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if ([string](Get-PropertyValue -Object $plan -Name "effectiveOutcome" -Default "") -ne "REACQUIRE") {
        $result.reason = "plan_not_reacquire"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $entity = Get-PropertyValue -Object $plan -Name "entity"
    $file = Get-PropertyValue -Object $plan -Name "file"
    $snapshot = Get-PropertyValue -Object $plan -Name "sourceSnapshot"
    $releaseIdentity = Get-PropertyValue -Object $plan -Name "releaseIdentity"
    $loopPrevention = Get-PropertyValue -Object $plan -Name "loopPrevention"

    $seriesId = [int](Get-PropertyValue -Object $entity -Name "id" -Default 0)
    $fileId = [int](Get-PropertyValue -Object $file -Name "id" -Default 0)
    $loopKey = [string](Get-PropertyValue -Object $loopPrevention -Name "loopKey" -Default "")
    $downloadId = [string](Get-PropertyValue -Object $releaseIdentity -Name "downloadId" -Default "")
    $sourceTitle = [string](Get-PropertyValue -Object $releaseIdentity -Name "releaseTitle" -Default "")
    $episodeIds = @(Get-SonarrEpisodeIdsFromPlan -Plan $plan)

    $result.seriesId = $seriesId
    $result.fileId = $fileId
    $result.loopKey = $loopKey
    $result.episodeIds = @($episodeIds)

    if ($seriesId -le 0 -or $fileId -le 0 -or @($episodeIds).Count -eq 0 -or [string]::IsNullOrWhiteSpace($loopKey)) {
        $result.reason = "plan_identity_incomplete"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if (-not (Test-Path -LiteralPath $result.mediaPath -PathType Leaf)) {
        $result.reason = "current_media_missing"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $mediaItem = Get-Item -LiteralPath $result.mediaPath
    $expectedBytes = [int64](
        Get-PropertyValue -Object $snapshot -Name "lengthBytes" -Default -1
    )
    $expectedLastWrite = [DateTime]::Parse(
        [string](Get-PropertyValue -Object $snapshot -Name "lastWriteTimeUtc" -Default ""),
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()

    $result.sourceSnapshotMatches = (
        [int64]$mediaItem.Length -eq $expectedBytes -and
        $mediaItem.LastWriteTimeUtc -eq $expectedLastWrite
    )

    if (-not $result.sourceSnapshotMatches) {
        $result.reason = "source_snapshot_changed"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $connection = Get-SonarrConnection -ConfigPath $ConfigPath

    $arrFile = Invoke-SonarrApi `
        -Connection $connection `
        -RelativePath ("episodefile/{0}" -f $fileId) `
        -Method GET

    $arrPath = [string](Get-PropertyValue -Object $arrFile -Name "path" -Default "")
    $arrBytes = [int64](Get-PropertyValue -Object $arrFile -Name "size" -Default -1)

    $result.arrFileMatches = (
        (Test-PathEquivalent -First $arrPath -Second $result.mediaPath) -and
        $arrBytes -eq $expectedBytes
    )

    if (-not $result.arrFileMatches) {
        $result.reason = "current_arr_file_mismatch"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $reacqStatePath = Join-Path `
        (Join-Path $IntegrationRoot "Reacquisition\state") `
        ($loopKey + ".json")

    if (-not (Test-Path -LiteralPath $reacqStatePath -PathType Leaf)) {
        $result.reason = "reacquisition_state_missing"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $reacqState = Get-Content -LiteralPath $reacqStatePath -Raw -Encoding UTF8 |
        ConvertFrom-Json

    $successfulAttempts = @(
        @(Get-PropertyValue -Object $reacqState -Name "attempts" -Default @()) |
            Where-Object {
                [string](Get-PropertyValue -Object $_ -Name "status" -Default "") -in @(
                    "SUCCESS",
                    "SUCCESS_RECOVERED",
                    "SUCCESS_SEARCH_SUPPRESSED"
                ) -and
                [bool](Get-PropertyValue -Object $_ -Name "blocklistVerified" -Default $false)
            }
    )

    $result.reacquisitionStateVerified = ($successfulAttempts.Count -gt 0)

    if (-not $result.reacquisitionStateVerified) {
        $result.reason = "successful_reacquisition_blocklist_state_not_found"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $blocklistResponse = Invoke-SonarrApi `
        -Connection $connection `
        -RelativePath (Get-SonarrBlocklistRelativePath -SeriesId $seriesId) `
        -Method GET

    $blocklist = @(
        Get-RecordArray -Response $blocklistResponse
    )

    $matchingBlocklist = @(
        Test-MatchingBlocklist `
            -Records $blocklist `
            -SeriesId $seriesId `
            -SourceTitle $sourceTitle
    )

    $result.blocklistVerified = ($matchingBlocklist.Count -gt 0)
    $result.blocklist = [ordered]@{
        recordCount = $blocklist.Count
        matchingCount = $matchingBlocklist.Count
        expectedSourceTitle = $sourceTitle
        expectedSourceTitleNormalized = (Normalize-ReleaseTitle $sourceTitle)
        samples = @(
            $blocklist |
                Select-Object -First 5 |
                ForEach-Object {
                    [ordered]@{
                        id = Get-PropertyValue -Object $_ -Name "id"
                        seriesId = Get-PropertyValue -Object $_ -Name "seriesId"
                        sourceTitle = [string](
                            Get-PropertyValue -Object $_ -Name "sourceTitle" -Default ""
                        )
                        sourceTitleNormalized = (
                            Normalize-ReleaseTitle (
                                [string](Get-PropertyValue -Object $_ -Name "sourceTitle" -Default "")
                            )
                        )
                        protocol = [string](
                            Get-PropertyValue -Object $_ -Name "protocol" -Default ""
                        )
                        indexer = [string](
                            Get-PropertyValue -Object $_ -Name "indexer" -Default ""
                        )
                        date = Get-PropertyValue -Object $_ -Name "date"
                    }
                }
        )
    }

    if (-not $result.blocklistVerified) {
        $result.reason = "failed_release_not_currently_blocklisted"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $series = Invoke-SonarrApi `
        -Connection $connection `
        -RelativePath ("series/{0}" -f $seriesId) `
        -Method GET

    $seriesPath = [string](Get-PropertyValue -Object $series -Name "path" -Default "")

    if ([string]::IsNullOrWhiteSpace($QuarantineRoot)) {
        $driveRoot = [System.IO.Path]::GetPathRoot($result.mediaPath)
        $QuarantineRoot = Join-Path $driveRoot "Reqestra Quarantine"
    }

    $sourceRoot = [System.IO.Path]::GetPathRoot(
        [System.IO.Path]::GetFullPath($result.mediaPath)
    )
    $quarantineDrive = [System.IO.Path]::GetPathRoot(
        [System.IO.Path]::GetFullPath($QuarantineRoot)
    )

    if (-not [string]::Equals(
        $sourceRoot,
        $quarantineDrive,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        $result.reason = "quarantine_must_be_on_same_volume"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if (Test-IsChildPath -Candidate $QuarantineRoot -Parent $seriesPath) {
        $result.reason = "quarantine_root_inside_series_folder"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $quarantinePath = Join-Path `
        (Join-Path `
            (Join-Path $QuarantineRoot "Sonarr") `
            ([string]$seriesId)
        ) `
        (Join-Path $loopKey ([System.IO.Path]::GetFileName($result.mediaPath)))

    $result.quarantine = [ordered]@{
        root = [System.IO.Path]::GetFullPath($QuarantineRoot)
        path = [System.IO.Path]::GetFullPath($quarantinePath)
        sameVolume = $true
        sourceSeriesPath = $seriesPath
        outsideSeriesFolder = (-not (
            Test-IsChildPath -Candidate $quarantinePath -Parent $seriesPath
        ))
        destinationExists = (Test-Path -LiteralPath $quarantinePath)
    }

    if (-not $result.quarantine.outsideSeriesFolder) {
        $result.reason = "quarantine_destination_inside_series_folder"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $quarantineStatePath = Join-Path $StateRoot ($loopKey + ".json")
    $result.statePath = $quarantineStatePath

    if (Test-Path -LiteralPath $quarantineStatePath -PathType Leaf) {
        $existingQuarantineState = Get-Content `
            -LiteralPath $quarantineStatePath `
            -Raw -Encoding UTF8 |
            ConvertFrom-Json

        $existingStatus = [string](
            Get-PropertyValue -Object $existingQuarantineState -Name "status" -Default ""
        )

        if ($existingStatus -notin @("ROLLED_BACK","COMPLETED")) {
            $result.reason = "existing_quarantine_transaction_requires_recovery"
            Write-Result ([pscustomobject]$result)
            exit 0
        }
    }

    if (Test-Path -LiteralPath $quarantinePath -PathType Leaf) {
        $result.reason = "quarantine_destination_already_exists"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $preSearch = Get-ApprovedReleases `
        -Connection $connection `
        -EpisodeIds $episodeIds

    $result.preRemovalSearch = [ordered]@{
        mode = $preSearch.mode
        totalReleaseCount = $preSearch.all.Count
        approvedCandidateCount = $preSearch.approved.Count
        diskOnlyBlockedCandidateCount = $preSearch.diskOnly.Count
    }
    $result.predictedDiskBlockedCandidateCount = $preSearch.diskOnly.Count

    if ($preSearch.mode -eq "SINGLE_EPISODE_RELEASE_SEARCH" -and ($preSearch.approved.Count + $preSearch.diskOnly.Count) -le 0) {
        $result.reason = "no_predicted_candidates_before_quarantine"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if (-not $Execute) {
        $result.status = "DRY_RUN_READY"
        $result.reason = $null
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($ConfirmLoopKey) -or
        -not [string]::Equals(
            $ConfirmLoopKey,
            $loopKey,
            [System.StringComparison]::Ordinal
        )) {
        $result.reason = "execute_loop_key_confirmation_required"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $mutex = New-Object System.Threading.Mutex(
        $false,
        "ReqestraMediaReacquisitionQuarantine"
    )
    $mutexHeld = $false

    try {
        $mutexHeld = $mutex.WaitOne(0)
        if (-not $mutexHeld) {
            $result.reason = "quarantine_mutex_busy"
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        # Re-read the current Sonarr file immediately before mutation.
        $freshFile = Invoke-SonarrApi `
            -Connection $connection `
            -RelativePath ("episodefile/{0}" -f $fileId) `
            -Method GET

        $freshPath = [string](
            Get-PropertyValue -Object $freshFile -Name "path" -Default ""
        )
        $freshBytes = [int64](
            Get-PropertyValue -Object $freshFile -Name "size" -Default -1
        )

        if (-not (Test-PathEquivalent -First $freshPath -Second $result.mediaPath) -or
            $freshBytes -ne $expectedBytes) {
            $result.reason = "arr_file_changed_before_execute"
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        $transactionId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") +
            "-" + [guid]::NewGuid().ToString("N").Substring(0,8)

        $state = [pscustomobject][ordered]@{
            schemaVersion = "1.0"
            executorVersion = $ExecutorVersion
            transactionId = $transactionId
            loopKey = $loopKey
            seriesId = $seriesId
            episodeIds = @($episodeIds)
            originalFileId = $fileId
            originalPath = $result.mediaPath
            quarantinePath = $quarantinePath
            expectedBytes = $expectedBytes
            startedUtc = [DateTime]::UtcNow.ToString("o")
            updatedUtc = [DateTime]::UtcNow.ToString("o")
            completedUtc = $null
            status = "STARTED"
            stage = "PREPARED"
            predictedDiskBlockedCandidateCount = $preSearch.diskOnly.Count
            releaseSearchMode = $preSearch.mode
            approvedCandidateCountAfterRemoval = $null
            searchCommandId = $null
            replacementGrabbed = $false
            replacementQueued = $false
            rollback = $null
        }

        Write-AtomicJson -Path $quarantineStatePath -Object $state

        $destinationDirectory = Split-Path -Parent $quarantinePath
        New-Item -ItemType Directory -Path $destinationDirectory -Force |
            Out-Null

        Move-Item `
            -LiteralPath $result.mediaPath `
            -Destination $quarantinePath

        if (Test-Path -LiteralPath $result.mediaPath -PathType Leaf) {
            throw "Source still exists after quarantine move."
        }

        if (-not (Test-Path -LiteralPath $quarantinePath -PathType Leaf)) {
            throw "Quarantine destination missing after move."
        }

        $quarantinedItem = Get-Item -LiteralPath $quarantinePath
        if ([int64]$quarantinedItem.Length -ne $expectedBytes) {
            throw "Quarantined file size does not match source snapshot."
        }

        $result.mutation.fileMoved = $true
        $state.stage = "QUARANTINED"
        $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
        Write-AtomicJson -Path $quarantineStatePath -Object $state

        try {
            [void](Invoke-SonarrApi `
                -Connection $connection `
                -RelativePath ("episodefile/{0}" -f $fileId) `
                -Method DELETE)

            $result.mutation.episodeFileRecordDeleted = $true
            $result.mutation.mutatingRequestsSent++
        }
        catch {
            $rollback = Invoke-Rollback `
                -Connection $connection `
                -SeriesId $seriesId `
                -OriginalPath $result.mediaPath `
                -QuarantinePath $quarantinePath `
                -ExpectedBytes $expectedBytes

            $result.rollback = $rollback
            $state.rollback = $rollback
            $state.status = if ($rollback.sonarrFileRestored) {
                "ROLLED_BACK"
            }
            else {
                "RECOVERY_REQUIRED"
            }
            $state.stage = "DELETE_EPISODEFILE_FAILED"
            $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
            $state.completedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $quarantineStatePath -Object $state

            $result.status = $state.status
            $result.reason = "episodefile_delete_failed"
            $result.error = $_.Exception.Message
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        $state.stage = "SONARR_FILE_RECORD_REMOVED"
        $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
        Write-AtomicJson -Path $quarantineStatePath -Object $state

        $filesAfterDelete = @(Get-EpisodeFiles -Connection $connection -SeriesId $seriesId)
        $oldIdStillPresent = @(
            $filesAfterDelete |
                Where-Object {
                    [int](Get-PropertyValue -Object $_ -Name "id" -Default 0) -eq $fileId
                }
        ).Count -gt 0

        if ($oldIdStillPresent) {
            throw "Sonarr episode-file record still exists after DELETE."
        }

        $postSearch = Get-ApprovedReleases `
            -Connection $connection `
            -EpisodeIds $episodeIds

        $approved = @($postSearch.approved)

        $result.postRemovalSearch = [ordered]@{
            mode = $postSearch.mode
            totalReleaseCount = $postSearch.all.Count
            approvedCandidateCount = $approved.Count
            approvedSamples = @(
                $approved |
                    Select-Object -First 10 |
                    ForEach-Object {
                        [ordered]@{
                            title = [string](
                                Get-PropertyValue -Object $_ -Name "title" -Default ""
                            )
                            customFormatScore = Get-PropertyValue `
                                -Object $_ -Name "customFormatScore"
                            indexer = [string](
                                Get-PropertyValue -Object $_ -Name "indexer" -Default ""
                            )
                            protocol = [string](
                                Get-PropertyValue -Object $_ -Name "protocol" -Default ""
                            )
                            size = Get-PropertyValue -Object $_ -Name "size"
                        }
                    }
            )
        }

        $state.approvedCandidateCountAfterRemoval = $approved.Count
        $state.stage = "POST_REMOVAL_SEARCH_COMPLETE"
        $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
        Write-AtomicJson -Path $quarantineStatePath -Object $state

        if ($postSearch.mode -eq "SINGLE_EPISODE_RELEASE_SEARCH" -and $approved.Count -le 0) {
            $rollback = Invoke-Rollback `
                -Connection $connection `
                -SeriesId $seriesId `
                -OriginalPath $result.mediaPath `
                -QuarantinePath $quarantinePath `
                -ExpectedBytes $expectedBytes

            $result.rollback = $rollback
            $state.rollback = $rollback
            $state.status = if ($rollback.sonarrFileRestored) {
                "ROLLED_BACK"
            }
            else {
                "RECOVERY_REQUIRED"
            }
            $state.stage = "NO_APPROVED_CANDIDATES"
            $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
            $state.completedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $quarantineStatePath -Object $state

            $result.status = $state.status
            $result.reason = "no_approved_candidates_after_quarantine"
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        $searchStartedUtc = [DateTime]::UtcNow

        try {
            $command = Invoke-SonarrApi `
                -Connection $connection `
                -RelativePath "command" `
                -Method POST `
                -Body (Get-SonarrSearchCommandBody -EpisodeIds $episodeIds)

            $commandId = [int](
                Get-PropertyValue -Object $command -Name "id" -Default 0
            )

            if ($commandId -le 0) {
                throw "Sonarr did not return a valid EpisodeSearch command id."
            }

            $result.mutation.episodeSearchSent = $true
            $result.mutation.mutatingRequestsSent++
            $state.searchCommandId = $commandId
            $state.stage = "SEARCH_SENT"
            $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $quarantineStatePath -Object $state

            $completed = Wait-SonarrCommand `
                -Connection $connection `
                -CommandId $commandId `
                -TimeoutSeconds 300

            $commandStatus = [string](
                Get-PropertyValue -Object $completed -Name "status" -Default ""
            )

            if ($commandStatus -ne "completed") {
                throw "EpisodeSearch command ended with status '$commandStatus'."
            }
        }
        catch {
            $rollback = Invoke-Rollback `
                -Connection $connection `
                -SeriesId $seriesId `
                -OriginalPath $result.mediaPath `
                -QuarantinePath $quarantinePath `
                -ExpectedBytes $expectedBytes

            $result.rollback = $rollback
            $state.rollback = $rollback
            $state.status = if ($rollback.sonarrFileRestored) {
                "ROLLED_BACK"
            }
            else {
                "RECOVERY_REQUIRED"
            }
            $state.stage = "SEARCH_COMMAND_FAILED"
            $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
            $state.completedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $quarantineStatePath -Object $state

            $result.status = $state.status
            $result.reason = "episode_search_failed"
            $result.error = $_.Exception.Message
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        $grabbed = @()
        $queued = @()
        $activityDeadline = [DateTime]::UtcNow.AddSeconds(45)

        do {
            $historyResponse = Invoke-SonarrApi `
                -Connection $connection `
                -RelativePath ("history/series?seriesId={0}&includeSeries=false" -f $seriesId) `
                -Method GET

            $history = @(
                Get-RecordArray -Response $historyResponse
            )

            $grabbed = @(
                $history |
                    Where-Object {
                        if (-not [string]::Equals(
                            [string](Get-PropertyValue -Object $_ -Name "eventType" -Default ""),
                            "grabbed",
                            [System.StringComparison]::OrdinalIgnoreCase
                        )) {
                            return $false
                        }

                        $dateText = [string](
                            Get-PropertyValue -Object $_ -Name "date" -Default ""
                        )

                        try {
                            $date = [DateTime]::Parse(
                                $dateText,
                                [System.Globalization.CultureInfo]::InvariantCulture,
                                [System.Globalization.DateTimeStyles]::RoundtripKind
                            ).ToUniversalTime()

                            if ($date -lt $searchStartedUtc.AddSeconds(-1)) { return $false }
                            $historyEpisodeId = [int](Get-PropertyValue -Object $_ -Name "episodeId" -Default 0)
                            return ($historyEpisodeId -le 0 -or @($episodeIds) -contains $historyEpisodeId)
                        }
                        catch {
                            return $false
                        }
                    }
            )

            $queueResponse = Invoke-SonarrApi `
                -Connection $connection `
                -RelativePath "queue?page=1&pageSize=100&includeUnknownSeriesItems=true" `
                -Method GET

            $queued = @(
                @(Get-RecordArray -Response $queueResponse) |
                    Where-Object {
                        Test-SonarrQueueRecordMatches -Record $_ -SeriesId $seriesId -EpisodeIds $episodeIds
                    }
            )

            if ($grabbed.Count -gt 0 -or $queued.Count -gt 0) {
                break
            }

            Start-Sleep -Seconds 3
        }
        while ([DateTime]::UtcNow -lt $activityDeadline)

        $result.replacementActivity = [ordered]@{
            grabbed = ($grabbed.Count -gt 0)
            grabbedCount = $grabbed.Count
            grabbedTitles = @(
                $grabbed |
                    ForEach-Object {
                        [string](Get-PropertyValue -Object $_ -Name "sourceTitle" -Default "")
                    }
            )
            queued = ($queued.Count -gt 0)
            queueCount = $queued.Count
            queueTitles = @(
                $queued |
                    ForEach-Object {
                        [string](Get-PropertyValue -Object $_ -Name "title" -Default "")
                    }
            )
        }

        $state.replacementGrabbed = ($grabbed.Count -gt 0)
        $state.replacementQueued = ($queued.Count -gt 0)

        if ($grabbed.Count -eq 0 -and $queued.Count -eq 0) {
            $rollback = Invoke-Rollback `
                -Connection $connection `
                -SeriesId $seriesId `
                -OriginalPath $result.mediaPath `
                -QuarantinePath $quarantinePath `
                -ExpectedBytes $expectedBytes

            $result.rollback = $rollback
            $state.rollback = $rollback
            $state.status = if ($rollback.sonarrFileRestored) {
                "ROLLED_BACK"
            }
            else {
                "RECOVERY_REQUIRED"
            }
            $state.stage = "NO_REPLACEMENT_ACTIVITY"
            $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
            $state.completedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $quarantineStatePath -Object $state

            $result.status = $state.status
            $result.reason = "no_replacement_grab_or_queue_detected"
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        $state.status = "QUARANTINED_REPLACEMENT_STARTED"
        $state.stage = "CHAIN_INITIALIZATION_PENDING"
        $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
        Write-AtomicJson -Path $quarantineStatePath -Object $state

        try {
            $chainInit = Initialize-SonarrChainFromQuarantine `
                -Plan $plan `
                -PlanPath $PlanPath `
                -QuarantineStatePath $quarantineStatePath `
                -QuarantinePath $quarantinePath `
                -ValidatorPath $ValidatorPath `
                -PolicyPath $PolicyPath `
                -WorkRoot $ChainWorkRoot

            $result.chainInitialization = [ordered]@{
                chainId = $chainInit.chainId
                chainPath = $chainInit.chainPath
                status = $chainInit.status
                rollbackVerified = $chainInit.rollbackVerified
            }
            $result.mutation.chainStateInitialized = [bool]$chainInit.written
            $result.mutation.chainStateAlreadyPresent = (-not [bool]$chainInit.written)

            $state | Add-Member -NotePropertyName chainId -NotePropertyValue $chainInit.chainId -Force
            $state | Add-Member -NotePropertyName chainPath -NotePropertyValue $chainInit.chainPath -Force
            $state.stage = "WAITING_FOR_REPLACEMENT_IMPORT"
            $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $quarantineStatePath -Object $state
        }
        catch {
            $state.status = "RECOVERY_REQUIRED"
            $state.stage = "CHAIN_INITIALIZATION_FAILED"
            $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
            $state | Add-Member -NotePropertyName chainInitializationError -NotePropertyValue $_.Exception.Message -Force
            Write-AtomicJson -Path $quarantineStatePath -Object $state

            $result.status = "RECOVERY_REQUIRED"
            $result.reason = "chain_initialization_failed_after_replacement_start"
            $result.error = $_.Exception.Message
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        $result.status = "QUARANTINED_REPLACEMENT_STARTED"
        $result.reason = $null
        Write-Result ([pscustomobject]$result)
        exit 0
    }
    finally {
        if ($mutexHeld) {
            try { $mutex.ReleaseMutex() } catch {}
        }

        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}
catch {
    $result.status = "FAILED"
    $result.reason = "quarantine_executor_exception"
    $result.error = $_.Exception.Message
    Write-Result ([pscustomobject]$result)
    exit 0
}
