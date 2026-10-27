[CmdletBinding()]
param(
    [ValidateSet("Movies","TV","Both")]
    [string]$Library = "Movies",

    [int[]]$MovieId = @(),
    [int[]]$SeriesId = @(),

    [ValidateRange(0,1000000)]
    [int]$MaxItems = 0,

    [switch]$Fresh,

    [switch]$RetryActionable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CommandVersion = "0.3.1"
$ToolsRoot = $PSScriptRoot
$IntegrationRoot = Split-Path -Parent $ToolsRoot
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"
$BridgePath = Join-Path $IntegrationRoot "ReqestraArrBridge.ps1"
$AuditRoot = Join-Path $IntegrationRoot "Audit\library-remediation"
$WorkerKickInterval = 250

function Get-Prop {
    param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function To-Array {
    param($Value)
    $items = @()
    if ($null -eq $Value) { return @() }
    foreach ($x in $Value) { $items += $x }
    return @($items)
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-ArrGet {
    param($Connection,[string]$Path)
    return Invoke-RestMethod -Method Get `
        -Uri ($Connection.baseUrl + "/api/v3/" + $Path.TrimStart('/')) `
        -Headers @{"X-Api-Key"=$Connection.apiKey} `
        -TimeoutSec 60
}

function Get-Connection {
    param($Config,[ValidateSet("Radarr","Sonarr")][string]$Source)
    $nodeName = $Source.ToLowerInvariant()
    $node = Get-Prop $Config $nodeName $null
    $baseUrl = ([string](Get-Prop $node "baseUrl" "")).TrimEnd('/')
    $apiKey = [string](Get-Prop $node "apiKey" "")
    if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) {
        throw "$Source baseUrl/apiKey missing from integration-config.json"
    }
    return [pscustomobject]@{ source=$Source; baseUrl=$baseUrl; apiKey=$apiKey }
}

function Set-EnvValue {
    param([hashtable]$Saved,[string]$Name,$Value)
    if (-not $Saved.ContainsKey($Name)) {
        $Saved[$Name] = [Environment]::GetEnvironmentVariable($Name,"Process")
    }
    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    [Environment]::SetEnvironmentVariable($Name,$text,"Process")
}

function Restore-Environment {
    param([hashtable]$Saved)
    foreach ($k in $Saved.Keys) {
        [Environment]::SetEnvironmentVariable($k,$Saved[$k],"Process")
    }
}

function Get-HistoryRecords {
    param($Response)
    if ($null -eq $Response) { return @() }
    $records = Get-Prop $Response "records" $null
    if ($null -ne $records) { return @(To-Array $records) }
    return @(To-Array $Response)
}

function Get-HistoryFileId {
    param($Record)
    $data = Get-Prop $Record "data" $null
    foreach ($name in @("movieFileId","fileId","FileId")) {
        $raw = Get-Prop $data $name $null
        $parsed = 0
        if ($null -ne $raw -and [int]::TryParse([string]$raw,[ref]$parsed)) { return $parsed }
    }
    return 0
}

function Get-HistoryImportedPath {
    param($Record)
    $data = Get-Prop $Record "data" $null
    return [string](Get-Prop $data "importedPath" "")
}

function Find-LatestImportRecord {
    param(
        [object[]]$Records,
        [int]$FileId,
        [string]$MediaPath
    )

    $imports = @(
        $Records |
            Where-Object { [string](Get-Prop $_ "eventType" "") -eq "downloadFolderImported" }
    )

    $matches = @(
        $imports |
            Where-Object { (Get-HistoryFileId $_) -eq $FileId } |
            Sort-Object { [datetime](Get-Prop $_ "date" "1900-01-01") } -Descending
    )
    if ($matches.Count -gt 0) { return $matches[0] }

    $matches = @(
        $imports |
            Where-Object {
                $p = Get-HistoryImportedPath $_
                -not [string]::IsNullOrWhiteSpace($p) -and
                [string]::Equals($p,$MediaPath,[System.StringComparison]::OrdinalIgnoreCase)
            } |
            Sort-Object { [datetime](Get-Prop $_ "date" "1900-01-01") } -Descending
    )
    if ($matches.Count -gt 0) { return $matches[0] }

    return $null
}

function Get-FormatNames {
    param($File)
    $names = @()
    foreach ($cf in @(To-Array (Get-Prop $File "customFormats" @()))) {
        $name = [string](Get-Prop $cf "name" "")
        if (-not [string]::IsNullOrWhiteSpace($name)) { $names += $name }
    }
    return @($names)
}

function Get-RevisionVersion {
    param($QualityRecord)
    $revision = Get-Prop $QualityRecord "revision" $null
    $raw = Get-Prop $revision "version" $revision
    $parsed = 0
    if ($null -ne $raw -and [int]::TryParse([string]$raw,[ref]$parsed)) { return $parsed }
    return 0
}

function Get-ProfileCache {
    param($Connection)
    $cache = @{}
    $profiles = @(To-Array (Invoke-ArrGet $Connection "qualityprofile"))
    foreach ($profile in $profiles) {
        $id = [int](Get-Prop $profile "id" 0)
        if ($id -le 0) { continue }
        $formatScores = @()
        foreach ($item in @(To-Array (Get-Prop $profile "formatItems" @()))) {
            $formatIdRaw = Get-Prop $item "format" $null
            $formatId = $null
            $parsed = 0
            if ($null -ne $formatIdRaw -and [int]::TryParse([string]$formatIdRaw,[ref]$parsed)) { $formatId = $parsed }
            $formatScores += [pscustomobject][ordered]@{
                format = [string](Get-Prop $item "name" "")
                formatId = $formatId
                score = [int](Get-Prop $item "score" 0)
            }
        }
        $cache[$id] = [pscustomobject][ordered]@{
            status = "OK"
            apiVersion = "v3"
            qualityProfileId = $id
            qualityProfileName = [string](Get-Prop $profile "name" "")
            upgradeAllowed = Get-Prop $profile "upgradeAllowed" $null
            cutoff = Get-Prop $profile "cutoff" $null
            minFormatScore = Get-Prop $profile "minFormatScore" $null
            cutoffFormatScore = Get-Prop $profile "cutoffFormatScore" $null
            formatScores = @($formatScores)
            error = $null
        }
    }
    return $cache
}

function Get-ProfileOverride {
    param([hashtable]$Cache,$Entity)
    $profileId = [int](Get-Prop $Entity "qualityProfileId" 0)
    if ($profileId -gt 0 -and $Cache.ContainsKey($profileId)) { return $Cache[$profileId] }
    return $null
}

function Write-Checkpoint {
    param([string]$Path,$Record)
    $line = $Record | ConvertTo-Json -Depth 30 -Compress
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Read-CompletedKeys {
    param([string]$Path)
    $done = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $done }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $r = $line | ConvertFrom-Json
            $key = [string](Get-Prop $r "key" "")
            $status = [string](Get-Prop $r "status" "")
            if (-not [string]::IsNullOrWhiteSpace($key) -and $status -in @("SUBMITTED","SKIPPED")) {
                $done[$key] = $true
            }
        }
        catch {}
    }
    return $done
}


function Read-LatestCheckpointRecords {
    param([string]$Path)
    $latest = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $r = $line | ConvertFrom-Json
            $key = [string](Get-Prop $r "key" "")
            if (-not [string]::IsNullOrWhiteSpace($key)) { $latest[$key] = $r }
        }
        catch {}
    }
    return @($latest.Values)
}

function Get-RetryTargetKeys {
    param([Parameter(Mandatory = $true)][string]$SourceRunRoot)

    $sourceCheckpoint = Join-Path $SourceRunRoot "checkpoint.jsonl"
    if (-not (Test-Path -LiteralPath $sourceCheckpoint -PathType Leaf)) {
        throw "Retry source checkpoint missing: $sourceCheckpoint"
    }

    $targets = @{}
    foreach ($record in @(Read-LatestCheckpointRecords -Path $sourceCheckpoint)) {
        $key = [string](Get-Prop $record "key" "")
        $status = [string](Get-Prop $record "status" "")
        $outcome = [string](Get-Prop $record "effectiveOutcome" "")
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($status -eq "SUBMITTED" -and $outcome -in @("NORMALIZE","REACQUIRE","REVIEW")) {
            $targets[$key] = $true
        }
    }
    return $targets
}

function Get-RadarrRetryChainDisposition {
    param([int]$MovieId)
    if ($MovieId -le 0) { return $null }
    $chainPath = Join-Path $IntegrationRoot ("Reacquisition\chains\Radarr-{0}.json" -f $MovieId)
    if (-not (Test-Path -LiteralPath $chainPath -PathType Leaf)) { return $null }
    try {
        $chain = Get-Content -LiteralPath $chainPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $status = [string](Get-Prop $chain "status" "")
        $suppress = $status -in @(
            "ACTIVE",
            "STARTED",
            "QUARANTINED_REPLACEMENT_STARTED",
            "COMPLETED",
            "COMPLETED_SUCCESS",
            "COMPLETED_LOCAL_REMEDIATION",
            "RETIRED_AFTER_SUCCESS"
        )
        return [pscustomobject]@{ status=$status; suppressRetry=$suppress; chainPath=$chainPath }
    }
    catch { return $null }
}

function Get-RunSignature {
    $moviePart = (@($MovieId | Sort-Object) -join ',')
    $seriesPart = (@($SeriesId | Sort-Object) -join ',')
    return "Library=$Library;MovieId=$moviePart;SeriesId=$seriesPart;MaxItems=$MaxItems"
}

function Save-RunMetadata {
    param(
        [string]$Path,
        [string]$Status,
        [string]$RunRoot,
        [string]$Signature,
        [int]$Processed,
        [int]$Submitted,
        [int]$Skipped,
        [int]$Errors,
        [bool]$IsRetryActionable = $false,
        [string]$RetrySourceRunRoot = ""
    )
    [pscustomobject][ordered]@{
        schemaVersion = "1.0"
        commandVersion = $CommandVersion
        status = $Status
        library = $Library
        signature = $Signature
        runRoot = $RunRoot
        retryActionable = $IsRetryActionable
        retrySourceRunRoot = if ([string]::IsNullOrWhiteSpace($RetrySourceRunRoot)) { $null } else { $RetrySourceRunRoot }
        processed = $Processed
        submitted = $Submitted
        skipped = $Skipped
        errors = $Errors
        updatedUtc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Start-RemediationWorkers {
    $result = [ordered]@{ normalization=$null; reacquisition=$null }
    try {
        . (Join-Path $IntegrationRoot "QueueCommon.ps1")
        . (Join-Path $IntegrationRoot "ReacquisitionQueueCommon.ps1")
        $result.normalization = Start-NormalizationQueueWorker -IntegrationRoot $IntegrationRoot
        $result.reacquisition = Start-ReacquisitionQueueWorker -IntegrationRoot $IntegrationRoot
    }
    catch {
        $result.normalization = [pscustomobject]@{ started=$false; reason=$_.Exception.Message }
        $result.reacquisition = [pscustomobject]@{ started=$false; reason=$_.Exception.Message }
    }
    return [pscustomobject]$result
}

function Set-RadarrEnvironment {
    param([hashtable]$Saved,$Movie,$File,$History)
    $id = [int](Get-Prop $Movie "id" 0)
    $mediaPath = [string](Get-Prop $File "path" "")
    if ([string]::IsNullOrWhiteSpace($mediaPath)) {
        $mediaPath = Join-Path ([string](Get-Prop $Movie "path" "")) ([string](Get-Prop $File "relativePath" ""))
    }
    $orig = Get-Prop $Movie "originalLanguage" $null
    $qualityRecord = Get-Prop $File "quality" $null
    $quality = Get-Prop $qualityRecord "quality" $null
    $mediaInfo = Get-Prop $File "mediaInfo" $null
    $historyData = Get-Prop $History "data" $null

    Set-EnvValue $Saved "radarr_eventtype" "LibraryRemediation"
    Set-EnvValue $Saved "radarr_movie_id" $id
    Set-EnvValue $Saved "radarr_movie_title" (Get-Prop $Movie "title" "")
    Set-EnvValue $Saved "radarr_movie_year" (Get-Prop $Movie "year" "")
    Set-EnvValue $Saved "radarr_movie_originallanguage" (Get-Prop $orig "name" (Get-Prop $Movie "originalLanguage" ""))
    Set-EnvValue $Saved "radarr_movie_path" (Get-Prop $Movie "path" "")
    Set-EnvValue $Saved "radarr_movie_imdbid" (Get-Prop $Movie "imdbId" "")
    Set-EnvValue $Saved "radarr_movie_tmdbid" (Get-Prop $Movie "tmdbId" "")
    Set-EnvValue $Saved "radarr_movie_tags" ((@(To-Array (Get-Prop $Movie "tags" @())) | ForEach-Object {[string]$_}) -join '|')

    Set-EnvValue $Saved "radarr_moviefile_id" (Get-Prop $File "id" "")
    Set-EnvValue $Saved "radarr_moviefile_path" $mediaPath
    Set-EnvValue $Saved "radarr_moviefile_relativepath" (Get-Prop $File "relativePath" ([IO.Path]::GetFileName($mediaPath)))
    Set-EnvValue $Saved "radarr_moviefile_quality" (Get-Prop $quality "name" "")
    Set-EnvValue $Saved "radarr_moviefile_qualityversion" (Get-RevisionVersion $qualityRecord)
    Set-EnvValue $Saved "radarr_moviefile_releasegroup" (Get-Prop $File "releaseGroup" "")
    Set-EnvValue $Saved "radarr_moviefile_scenename" (Get-Prop $File "sceneName" "")
    Set-EnvValue $Saved "radarr_moviefile_customformat" ((Get-FormatNames $File) -join '|')
    Set-EnvValue $Saved "radarr_moviefile_customformatscore" (Get-Prop $File "customFormatScore" "")
    Set-EnvValue $Saved "radarr_moviefile_mediainfo_width" (Get-Prop $mediaInfo "width" "")
    Set-EnvValue $Saved "radarr_moviefile_mediainfo_height" (Get-Prop $mediaInfo "height" "")
    Set-EnvValue $Saved "radarr_moviefile_mediainfo_videocodec" (Get-Prop $mediaInfo "videoCodec" "")
    Set-EnvValue $Saved "radarr_moviefile_mediainfo_videodynamicrangetype" (Get-Prop $mediaInfo "videoDynamicRangeType" "")
    Set-EnvValue $Saved "radarr_moviefile_mediainfo_audiocodec" (Get-Prop $mediaInfo "audioCodec" "")
    Set-EnvValue $Saved "radarr_moviefile_mediainfo_audiochannels" (Get-Prop $mediaInfo "audioChannels" "")
    Set-EnvValue $Saved "radarr_moviefile_mediainfo_audiolanguages" (Get-Prop $mediaInfo "audioLanguages" "")
    Set-EnvValue $Saved "radarr_moviefile_mediainfo_languages" (Get-Prop $mediaInfo "languages" "")
    Set-EnvValue $Saved "radarr_moviefile_mediainfo_subtitles" (Get-Prop $mediaInfo "subtitles" "")

    Set-EnvValue $Saved "radarr_release_title" (Get-Prop $History "sourceTitle" (Get-Prop $File "sceneName" ""))
    Set-EnvValue $Saved "radarr_release_indexer" (Get-Prop $historyData "indexer" "")
    Set-EnvValue $Saved "radarr_release_size" (Get-Prop $historyData "size" "")
    Set-EnvValue $Saved "radarr_download_id" (Get-Prop $History "downloadId" "")
    Set-EnvValue $Saved "radarr_isupgrade" "false"
    return $mediaPath
}

function Set-SonarrEnvironment {
    param([hashtable]$Saved,$Series,$File,[object[]]$Episodes,$History)
    $seriesId = [int](Get-Prop $Series "id" 0)
    $mediaPath = [string](Get-Prop $File "path" "")
    if ([string]::IsNullOrWhiteSpace($mediaPath)) {
        $mediaPath = Join-Path ([string](Get-Prop $Series "path" "")) ([string](Get-Prop $File "relativePath" ""))
    }
    $orig = Get-Prop $Series "originalLanguage" $null
    $qualityRecord = Get-Prop $File "quality" $null
    $quality = Get-Prop $qualityRecord "quality" $null
    $mediaInfo = Get-Prop $File "mediaInfo" $null
    $historyData = Get-Prop $History "data" $null
    $episodeIds = @($Episodes | ForEach-Object { [int](Get-Prop $_ "id" 0) } | Where-Object { $_ -gt 0 })
    $episodeNumbers = @($Episodes | ForEach-Object { [string](Get-Prop $_ "episodeNumber" "") })
    $episodeTitles = @($Episodes | ForEach-Object { [string](Get-Prop $_ "title" "") })
    $seasonNumber = Get-Prop $File "seasonNumber" $null
    if ($null -eq $seasonNumber -and $Episodes.Count -gt 0) { $seasonNumber = Get-Prop $Episodes[0] "seasonNumber" "" }

    Set-EnvValue $Saved "sonarr_eventtype" "LibraryRemediation"
    Set-EnvValue $Saved "sonarr_series_id" $seriesId
    Set-EnvValue $Saved "sonarr_series_title" (Get-Prop $Series "title" "")
    Set-EnvValue $Saved "sonarr_series_year" (Get-Prop $Series "year" "")
    Set-EnvValue $Saved "sonarr_series_originallanguage" (Get-Prop $orig "name" (Get-Prop $Series "originalLanguage" ""))
    Set-EnvValue $Saved "sonarr_series_path" (Get-Prop $Series "path" "")
    Set-EnvValue $Saved "sonarr_series_imdbid" (Get-Prop $Series "imdbId" "")
    Set-EnvValue $Saved "sonarr_series_tmdbid" (Get-Prop $Series "tmdbId" "")
    Set-EnvValue $Saved "sonarr_series_tvdbid" (Get-Prop $Series "tvdbId" "")
    Set-EnvValue $Saved "sonarr_series_tvmazeid" (Get-Prop $Series "tvMazeId" "")
    Set-EnvValue $Saved "sonarr_series_type" (Get-Prop $Series "seriesType" "")
    Set-EnvValue $Saved "sonarr_series_tags" ((@(To-Array (Get-Prop $Series "tags" @())) | ForEach-Object {[string]$_}) -join '|')

    Set-EnvValue $Saved "sonarr_episodefile_episodeids" ($episodeIds -join '|')
    Set-EnvValue $Saved "sonarr_episodefile_seasonnumber" $seasonNumber
    Set-EnvValue $Saved "sonarr_episodefile_episodenumbers" ($episodeNumbers -join '|')
    Set-EnvValue $Saved "sonarr_episodefile_episodetitles" ($episodeTitles -join '|')
    Set-EnvValue $Saved "sonarr_episodefile_episodecount" $episodeIds.Count
    Set-EnvValue $Saved "sonarr_episodefile_id" (Get-Prop $File "id" "")
    Set-EnvValue $Saved "sonarr_episodefile_path" $mediaPath
    Set-EnvValue $Saved "sonarr_episodefile_relativepath" (Get-Prop $File "relativePath" ([IO.Path]::GetFileName($mediaPath)))
    Set-EnvValue $Saved "sonarr_episodefile_quality" (Get-Prop $quality "name" "")
    Set-EnvValue $Saved "sonarr_episodefile_qualityversion" (Get-RevisionVersion $qualityRecord)
    Set-EnvValue $Saved "sonarr_episodefile_releasegroup" (Get-Prop $File "releaseGroup" "")
    Set-EnvValue $Saved "sonarr_episodefile_scenename" (Get-Prop $File "sceneName" "")
    Set-EnvValue $Saved "sonarr_episodefile_customformat" ((Get-FormatNames $File) -join '|')
    Set-EnvValue $Saved "sonarr_episodefile_customformatscore" (Get-Prop $File "customFormatScore" "")
    Set-EnvValue $Saved "sonarr_episodefile_mediainfo_width" (Get-Prop $mediaInfo "width" "")
    Set-EnvValue $Saved "sonarr_episodefile_mediainfo_height" (Get-Prop $mediaInfo "height" "")
    Set-EnvValue $Saved "sonarr_episodefile_mediainfo_videocodec" (Get-Prop $mediaInfo "videoCodec" "")
    Set-EnvValue $Saved "sonarr_episodefile_mediainfo_videodynamicrangetype" (Get-Prop $mediaInfo "videoDynamicRangeType" "")
    Set-EnvValue $Saved "sonarr_episodefile_mediainfo_audiocodec" (Get-Prop $mediaInfo "audioCodec" "")
    Set-EnvValue $Saved "sonarr_episodefile_mediainfo_audiochannels" (Get-Prop $mediaInfo "audioChannels" "")
    Set-EnvValue $Saved "sonarr_episodefile_mediainfo_audiolanguages" (Get-Prop $mediaInfo "audioLanguages" "")
    Set-EnvValue $Saved "sonarr_episodefile_mediainfo_languages" (Get-Prop $mediaInfo "languages" "")
    Set-EnvValue $Saved "sonarr_episodefile_mediainfo_subtitles" (Get-Prop $mediaInfo "subtitles" "")

    Set-EnvValue $Saved "sonarr_release_title" (Get-Prop $History "sourceTitle" (Get-Prop $File "sceneName" ""))
    Set-EnvValue $Saved "sonarr_release_indexer" (Get-Prop $historyData "indexer" "")
    Set-EnvValue $Saved "sonarr_release_releasetype" (Get-Prop $historyData "releaseType" "")
    Set-EnvValue $Saved "sonarr_release_size" (Get-Prop $historyData "size" "")
    Set-EnvValue $Saved "sonarr_download_id" (Get-Prop $History "downloadId" "")
    Set-EnvValue $Saved "sonarr_isupgrade" "false"
    return $mediaPath
}

function Invoke-BridgeSubmission {
    param(
        [ValidateSet("Radarr","Sonarr")][string]$Source,
        $ProfileOverride
    )
    if ($null -ne $ProfileOverride) {
        $result = & $BridgePath -Source $Source -DeferWorkerStart -ProfileOverride $ProfileOverride -PassThru
        return $result
    }
    else {
        $result = & $BridgePath -Source $Source -DeferWorkerStart -PassThru
        return $result
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Integration config missing: $ConfigPath" }
if (-not (Test-Path -LiteralPath $BridgePath -PathType Leaf)) { throw "Bridge missing: $BridgePath" }
Ensure-Directory $AuditRoot

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($RetryActionable -and $Fresh) { throw "-RetryActionable and -Fresh cannot be used together." }
if ($RetryActionable -and $MaxItems -gt 0) { throw "-RetryActionable must process its complete actionable set; do not combine it with -MaxItems." }

$baseSignature = Get-RunSignature
$signature = $baseSignature
$scopeName = $Library.ToLowerInvariant()
$scopeRoot = Join-Path $AuditRoot $scopeName
Ensure-Directory $scopeRoot
$latestPath = Join-Path $scopeRoot "latest.json"
$runRoot = $null
$retrySourceRunRoot = $null
$retryTargetKeys = @{}

if ($RetryActionable) {
    if (-not (Test-Path -LiteralPath $latestPath -PathType Leaf)) {
        throw "No prior $Library library-remediation run exists to retry."
    }

    try {
        $latest = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $candidate = [string](Get-Prop $latest "runRoot" "")
        $candidateRun = Join-Path $candidate "run.json"
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidateRun -PathType Leaf)) {
            throw "Latest remediation run metadata is unavailable."
        }

        $meta = Get-Content -LiteralPath $candidateRun -Raw -Encoding UTF8 | ConvertFrom-Json
        $metaStatus = [string](Get-Prop $meta "status" "")
        $metaRetry = [bool](Get-Prop $meta "retryActionable" $false)

        if ($metaStatus -eq "RUNNING" -and $metaRetry) {
            $runRoot = $candidate
            $retrySourceRunRoot = [string](Get-Prop $meta "retrySourceRunRoot" "")
        }
        elseif ($metaStatus -eq "COMPLETED") {
            $retrySourceRunRoot = $candidate
        }
        else {
            throw "Latest remediation run is not a completed source run or resumable actionable retry."
        }
    }
    catch {
        throw "Unable to resolve actionable retry source: $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($retrySourceRunRoot)) {
        throw "Actionable retry source run could not be resolved."
    }

    $retryTargetKeys = Get-RetryTargetKeys -SourceRunRoot $retrySourceRunRoot
    if ($retryTargetKeys.Count -eq 0) {
        throw "The source run contains no NORMALIZE, REACQUIRE, or REVIEW items to retry."
    }

    $signature = "$baseSignature;RetryActionable=true;RetrySource=$retrySourceRunRoot"
}
elseif (-not $Fresh -and (Test-Path -LiteralPath $latestPath -PathType Leaf)) {
    try {
        $latest = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $candidate = [string](Get-Prop $latest "runRoot" "")
        $candidateRun = Join-Path $candidate "run.json"
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidateRun -PathType Leaf)) {
            $meta = Get-Content -LiteralPath $candidateRun -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string](Get-Prop $meta "status" "") -eq "RUNNING" -and [string](Get-Prop $meta "signature" "") -eq $signature) {
                $runRoot = $candidate
            }
        }
    }
    catch {}
}

if ([string]::IsNullOrWhiteSpace([string]$runRoot)) {
    $runRoot = Join-Path $scopeRoot ("run-" + [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ") + "-" + [Guid]::NewGuid().ToString("N").Substring(0,8))
    Ensure-Directory $runRoot
}

$runPath = Join-Path $runRoot "run.json"
$checkpointPath = Join-Path $runRoot "checkpoint.jsonl"
$summaryPath = Join-Path $runRoot "summary.json"
$completedKeys = Read-CompletedKeys $checkpointPath

[pscustomobject]@{ runRoot=$runRoot; signature=$signature; status="RUNNING"; updatedUtc=[DateTime]::UtcNow.ToString("o") } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $latestPath -Encoding UTF8

$processed = 0
$submitted = 0
$skipped = 0
$errors = 0
$workerKicks = 0
$lastWorkerStart = $null
$retrySuppressedByChain = 0
Save-RunMetadata -Path $runPath -Status "RUNNING" -RunRoot $runRoot -Signature $signature -Processed 0 -Submitted 0 -Skipped 0 -Errors 0 -IsRetryActionable ([bool]$RetryActionable) -RetrySourceRunRoot $retrySourceRunRoot

function Record-Result {
    param([string]$Key,[string]$Source,[string]$Title,[string]$Path,[string]$Status,[string]$Reason,$BridgeResult=$null)
    $record = [pscustomobject][ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        key = $Key
        source = $Source
        title = $Title
        path = $Path
        status = $Status
        reason = $Reason
        bridgeStatus = if ($null -ne $BridgeResult) { [string](Get-Prop $BridgeResult "status" "") } else { $null }
        effectiveOutcome = if ($null -ne $BridgeResult) { [string](Get-Prop $BridgeResult "effectiveOutcome" "") } else { $null }
        normalizationPlanStatus = if ($null -ne $BridgeResult) { [string](Get-Prop (Get-Prop $BridgeResult "normalizationPlan" $null) "status" "") } else { $null }
        normalizationQueueStatus = if ($null -ne $BridgeResult) { [string](Get-Prop (Get-Prop $BridgeResult "normalizationQueue" $null) "status" "") } else { $null }
        reacquisitionPlanStatus = if ($null -ne $BridgeResult) { [string](Get-Prop (Get-Prop $BridgeResult "reacquisitionPlan" $null) "status" "") } else { $null }
        reacquisitionQueueStatus = if ($null -ne $BridgeResult) { [string](Get-Prop (Get-Prop $BridgeResult "reacquisitionQueue" $null) "status" "") } else { $null }
        eventDirectory = if ($null -ne $BridgeResult) { [string](Get-Prop $BridgeResult "eventDirectory" "") } else { $null }
    }
    Write-Checkpoint -Path $checkpointPath -Record $record
}

function Maybe-KickWorkers {
    if ($submitted -gt 0 -and ($submitted % $WorkerKickInterval) -eq 0) {
        $script:lastWorkerStart = Start-RemediationWorkers
        $script:workerKicks++
    }
}

try {
    if ($Library -in @("Movies","Both")) {
        $radarrConnection = Get-Connection -Config $config -Source "Radarr"
        $radarrProfiles = Get-ProfileCache -Connection $radarrConnection
        $movies = @(To-Array (Invoke-ArrGet $radarrConnection "movie") | Where-Object { [bool](Get-Prop $_ "hasFile" $false) })
        if ($MovieId.Count -gt 0) { $movies = @($movies | Where-Object { [int](Get-Prop $_ "id" 0) -in $MovieId }) }
        $movies = @($movies | Sort-Object { [string](Get-Prop $_ "sortTitle" (Get-Prop $_ "title" "")) })

        foreach ($movie in $movies) {
            if ($MaxItems -gt 0 -and $processed -ge $MaxItems) { break }
            $id = [int](Get-Prop $movie "id" 0)
            $file = Get-Prop $movie "movieFile" $null
            if ($null -eq $file -or [int](Get-Prop $file "id" 0) -le 0) {
                try {
                    $files = @(To-Array (Invoke-ArrGet $radarrConnection ("moviefile?movieId={0}" -f $id)))
                    $file = $files | Select-Object -First 1
                }
                catch { $file = $null }
            }
            $fileId = if ($null -ne $file) { [int](Get-Prop $file "id" 0) } else { 0 }
            $key = "Radarr:movieFile:$fileId"
            if ($RetryActionable -and -not $retryTargetKeys.ContainsKey($key)) { continue }
            if ($RetryActionable) {
                $chainDisposition = Get-RadarrRetryChainDisposition -MovieId $id
                if ($null -ne $chainDisposition -and [bool]$chainDisposition.suppressRetry) {
                    $retrySuppressedByChain++
                    continue
                }
            }
            if ($fileId -gt 0 -and $completedKeys.ContainsKey($key)) { continue }
            $processed++
            $title = [string](Get-Prop $movie "title" "")

            if ($null -eq $file -or $fileId -le 0) {
                $skipped++
                Record-Result -Key ("Radarr:movie:"+$id) -Source "Radarr" -Title $title -Path "" -Status "SKIPPED" -Reason "movie_file_not_resolved"
                continue
            }

            $mediaPath = [string](Get-Prop $file "path" "")
            if ([string]::IsNullOrWhiteSpace($mediaPath)) { $mediaPath = Join-Path ([string](Get-Prop $movie "path" "")) ([string](Get-Prop $file "relativePath" "")) }
            if (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) {
                $skipped++
                Record-Result -Key $key -Source "Radarr" -Title $title -Path $mediaPath -Status "SKIPPED" -Reason "media_missing"
                continue
            }

            $history = $null
            try {
                $historyResponse = Invoke-ArrGet $radarrConnection ("history/movie?movieId={0}&includeMovie=false" -f $id)
                $history = Find-LatestImportRecord -Records @(Get-HistoryRecords $historyResponse) -FileId $fileId -MediaPath $mediaPath
            }
            catch {}

            $saved = @{}
            try {
                [void](Set-RadarrEnvironment -Saved $saved -Movie $movie -File $file -History $history)
                $profile = Get-ProfileOverride -Cache $radarrProfiles -Entity $movie
                $bridgeResult = Invoke-BridgeSubmission -Source "Radarr" -ProfileOverride $profile
                if ([string](Get-Prop $bridgeResult "status" "") -eq "BRIDGE_ERROR") {
                    $errors++
                    Record-Result -Key $key -Source "Radarr" -Title $title -Path $mediaPath -Status "ERROR" -Reason ([string](Get-Prop $bridgeResult "error" "bridge_error")) -BridgeResult $bridgeResult
                }
                else {
                    $submitted++
                    Record-Result -Key $key -Source "Radarr" -Title $title -Path $mediaPath -Status "SUBMITTED" -Reason $null -BridgeResult $bridgeResult
                    Maybe-KickWorkers
                }
            }
            catch {
                $errors++
                Record-Result -Key $key -Source "Radarr" -Title $title -Path $mediaPath -Status "ERROR" -Reason $_.Exception.Message
            }
            finally { Restore-Environment $saved }

            if (($processed % 50) -eq 0) {
                Write-Host ("Movies: processed={0} submitted={1} skipped={2} errors={3}" -f $processed,$submitted,$skipped,$errors)
            }
        }
    }

    if ($Library -in @("TV","Both") -and ($MaxItems -eq 0 -or $processed -lt $MaxItems)) {
        $sonarrConnection = Get-Connection -Config $config -Source "Sonarr"
        $sonarrProfiles = Get-ProfileCache -Connection $sonarrConnection
        $seriesItems = @(To-Array (Invoke-ArrGet $sonarrConnection "series"))
        if ($SeriesId.Count -gt 0) { $seriesItems = @($seriesItems | Where-Object { [int](Get-Prop $_ "id" 0) -in $SeriesId }) }
        $seriesItems = @($seriesItems | Sort-Object { [string](Get-Prop $_ "sortTitle" (Get-Prop $_ "title" "")) })

        foreach ($series in $seriesItems) {
            if ($MaxItems -gt 0 -and $processed -ge $MaxItems) { break }
            $seriesIdValue = [int](Get-Prop $series "id" 0)
            if ($seriesIdValue -le 0) { continue }

            $episodeFiles = @()
            $episodes = @()
            $historyRecords = @()
            try { $episodeFiles = @(To-Array (Invoke-ArrGet $sonarrConnection ("episodefile?seriesId={0}" -f $seriesIdValue))) } catch {}
            if ($episodeFiles.Count -eq 0) { continue }
            try { $episodes = @(To-Array (Invoke-ArrGet $sonarrConnection ("episode?seriesId={0}" -f $seriesIdValue))) } catch {}
            try { $historyRecords = @(Get-HistoryRecords (Invoke-ArrGet $sonarrConnection ("history/series?seriesId={0}&includeSeries=false" -f $seriesIdValue))) } catch {}

            $episodesByFile = @{}
            foreach ($episode in $episodes) {
                $episodeFileId = [int](Get-Prop $episode "episodeFileId" 0)
                if ($episodeFileId -le 0) { continue }
                if (-not $episodesByFile.ContainsKey($episodeFileId)) { $episodesByFile[$episodeFileId] = @() }
                $episodesByFile[$episodeFileId] = @($episodesByFile[$episodeFileId]) + @($episode)
            }

            foreach ($file in $episodeFiles) {
                if ($MaxItems -gt 0 -and $processed -ge $MaxItems) { break }
                $fileId = [int](Get-Prop $file "id" 0)
                if ($fileId -le 0) { continue }
                $key = "Sonarr:episodeFile:$fileId"
                if ($RetryActionable -and -not $retryTargetKeys.ContainsKey($key)) { continue }
                if ($completedKeys.ContainsKey($key)) { continue }
                $processed++

                $title = [string](Get-Prop $series "title" "")
                $mediaPath = [string](Get-Prop $file "path" "")
                if ([string]::IsNullOrWhiteSpace($mediaPath)) { $mediaPath = Join-Path ([string](Get-Prop $series "path" "")) ([string](Get-Prop $file "relativePath" "")) }
                if (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) {
                    $skipped++
                    Record-Result -Key $key -Source "Sonarr" -Title $title -Path $mediaPath -Status "SKIPPED" -Reason "media_missing"
                    continue
                }

                $fileEpisodes = @()
                if ($episodesByFile.ContainsKey($fileId)) { $fileEpisodes = @($episodesByFile[$fileId]) }
                if ($fileEpisodes.Count -eq 0) {
                    $skipped++
                    Record-Result -Key $key -Source "Sonarr" -Title $title -Path $mediaPath -Status "SKIPPED" -Reason "episode_ids_not_resolved"
                    continue
                }

                $history = Find-LatestImportRecord -Records $historyRecords -FileId $fileId -MediaPath $mediaPath
                $saved = @{}
                try {
                    [void](Set-SonarrEnvironment -Saved $saved -Series $series -File $file -Episodes $fileEpisodes -History $history)
                    $profile = Get-ProfileOverride -Cache $sonarrProfiles -Entity $series
                    $bridgeResult = Invoke-BridgeSubmission -Source "Sonarr" -ProfileOverride $profile
                    if ([string](Get-Prop $bridgeResult "status" "") -eq "BRIDGE_ERROR") {
                        $errors++
                        Record-Result -Key $key -Source "Sonarr" -Title $title -Path $mediaPath -Status "ERROR" -Reason ([string](Get-Prop $bridgeResult "error" "bridge_error")) -BridgeResult $bridgeResult
                    }
                    else {
                        $submitted++
                        Record-Result -Key $key -Source "Sonarr" -Title $title -Path $mediaPath -Status "SUBMITTED" -Reason $null -BridgeResult $bridgeResult
                        Maybe-KickWorkers
                    }
                }
                catch {
                    $errors++
                    Record-Result -Key $key -Source "Sonarr" -Title $title -Path $mediaPath -Status "ERROR" -Reason $_.Exception.Message
                }
                finally { Restore-Environment $saved }

                if (($processed % 100) -eq 0) {
                    Write-Host ("TV: processed={0} submitted={1} skipped={2} errors={3}" -f $processed,$submitted,$skipped,$errors)
                }
            }
        }
    }

    $lastWorkerStart = Start-RemediationWorkers
    $workerKicks++

    $allRecords = @(Read-LatestCheckpointRecords $checkpointPath)
    $totalSubmitted = @($allRecords | Where-Object { [string](Get-Prop $_ "status" "") -eq "SUBMITTED" }).Count
    $totalSkipped = @($allRecords | Where-Object { [string](Get-Prop $_ "status" "") -eq "SKIPPED" }).Count
    $totalErrors = @($allRecords | Where-Object { [string](Get-Prop $_ "status" "") -eq "ERROR" }).Count
    $outcomeCounts = @(
        $allRecords |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-Prop $_ "effectiveOutcome" "")) } |
            Group-Object effectiveOutcome |
            Sort-Object Name |
            ForEach-Object { [pscustomobject]@{ outcome=$_.Name; count=$_.Count } }
    )

    Save-RunMetadata -Path $runPath -Status "COMPLETED" -RunRoot $runRoot -Signature $signature -Processed $allRecords.Count -Submitted $totalSubmitted -Skipped $totalSkipped -Errors $totalErrors -IsRetryActionable ([bool]$RetryActionable) -RetrySourceRunRoot $retrySourceRunRoot

    $summary = [pscustomobject][ordered]@{
        schemaVersion = "1.0"
        commandVersion = $CommandVersion
        status = "COMPLETED"
        library = $Library
        runRoot = $runRoot
        checkpointPath = $checkpointPath
        retryActionable = [bool]$RetryActionable
        retrySourceRunRoot = if ([string]::IsNullOrWhiteSpace($retrySourceRunRoot)) { $null } else { $retrySourceRunRoot }
        retryTargetCount = if ($RetryActionable) { $retryTargetKeys.Count } else { 0 }
        retrySuppressedByActiveOrCompletedChain = $retrySuppressedByChain
        processedThisInvocation = $processed
        submittedThisInvocation = $submitted
        skippedThisInvocation = $skipped
        errorsThisInvocation = $errors
        totalUniqueItems = $allRecords.Count
        totalSubmitted = $totalSubmitted
        totalSkipped = $totalSkipped
        totalErrors = $totalErrors
        outcomeCounts = @($outcomeCounts)
        workerKicks = $workerKicks
        finalWorkerStart = $lastWorkerStart
        completedUtc = [DateTime]::UtcNow.ToString("o")
    }
    $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    [pscustomobject]@{ runRoot=$runRoot; signature=$signature; status="COMPLETED"; updatedUtc=[DateTime]::UtcNow.ToString("o") } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $latestPath -Encoding UTF8

    Write-Host ""
    Write-Host "Library remediation submission complete." -ForegroundColor Green
    Write-Host ("Library   : {0}" -f $Library)
    Write-Host ("Processed : {0}" -f $processed)
    Write-Host ("Submitted : {0}" -f $submitted)
    Write-Host ("Skipped   : {0}" -f $skipped)
    Write-Host ("Errors    : {0}" -f $errors)
    Write-Host ("Run root  : {0}" -f $runRoot)
    if ($RetryActionable) {
        Write-Host ("Retry from: {0}" -f $retrySourceRunRoot)
        Write-Host ("Retry set : {0} actionable item(s)" -f $retryTargetKeys.Count)
        Write-Host ("Chain skip: {0} active/completed item(s)" -f $retrySuppressedByChain)
    }
    if ($outcomeCounts.Count -gt 0) {
        Write-Host "Outcomes  :"
        $outcomeCounts | Format-Table outcome,count -AutoSize
    }
    Write-Host ""
    Write-Host "The production normalization/reacquisition workers were started to drain any queued remediation work."
    Write-Host "Rerun the same command after an interruption to resume the latest incomplete run; use -Fresh to force a new run."

    $summary | ConvertTo-Json -Depth 20
}
catch {
    Save-RunMetadata -Path $runPath -Status "RUNNING" -RunRoot $runRoot -Signature $signature -Processed $processed -Submitted $submitted -Skipped $skipped -Errors ($errors + 1) -IsRetryActionable ([bool]$RetryActionable) -RetrySourceRunRoot $retrySourceRunRoot
    throw
}
