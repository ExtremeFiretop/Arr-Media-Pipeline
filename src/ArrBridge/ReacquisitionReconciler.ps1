[CmdletBinding()]
param(
    [switch]$Execute,
    [ValidateRange(0,1000)][int]$MaxChains = 0,
    [ValidateRange(1,60)][int]$MaxImportReplays = 5,
    [ValidateRange(30,3600)][int]$ImportReplayBackoffSeconds = 120,
    [int[]]$TargetMovieId = @(),
    [string]$JsonOut = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "0.1.0"
$IntegrationRoot = $PSScriptRoot
$ValidatorRoot = Split-Path -Parent $IntegrationRoot
$ChainCommonPath = Join-Path $IntegrationRoot "ReacquisitionChainCommon.ps1"
$QueueCommonPath = Join-Path $IntegrationRoot "ReacquisitionQueueCommon.ps1"
$BridgePath = Join-Path $IntegrationRoot "ReqestraArrBridge.ps1"
$AcquisitionRetryPath = Join-Path $IntegrationRoot "Invoke-ReacquisitionAcquisitionRetry.ps1"
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"
$ChainRoot = Join-Path $IntegrationRoot "Reacquisition\chains"
$QuarantineStateRoot = Join-Path $IntegrationRoot "Reacquisition\quarantine-state"
$RetryStateRoot = Join-Path $IntegrationRoot "Reacquisition\retry-state"
$ReconcileRoot = Join-Path $IntegrationRoot "Reacquisition\reconciliation"
$ReconcileStateRoot = Join-Path $ReconcileRoot "state"
$ReconcileLog = Join-Path $ReconcileRoot "reconciliation.jsonl"

. $ChainCommonPath
. $QueueCommonPath

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-Result {
    param($Object)
    if (-not [string]::IsNullOrWhiteSpace($JsonOut)) {
        $Object | ConvertTo-Json -Depth 70 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    }
    $Object | ConvertTo-Json -Depth 70
}

function Write-ReconcileLog {
    param($Object)
    Ensure-Directory -Path $ReconcileRoot
    Add-Content -LiteralPath $ReconcileLog -Value ($Object | ConvertTo-Json -Depth 50 -Compress) -Encoding UTF8
}

function Read-JsonSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Get-UtcDate {
    param($Value)
    if ($null -eq $Value) { return [DateTime]::MinValue }
    try {
        return [DateTime]::Parse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    }
    catch { return [DateTime]::MinValue }
}

function Get-RadarrConnection {
    $config=Read-JsonSafe -Path $ConfigPath
    if ($null -eq $config) { throw "Integration config missing or unreadable: $ConfigPath" }
    $radarr=Get-PropertyValue -Object $config -Name "radarr" -Default $null
    $baseUrl=[string](Get-PropertyValue -Object $radarr -Name "baseUrl" -Default "")
    $apiKey=[string](Get-PropertyValue -Object $radarr -Name "apiKey" -Default "")
    if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Radarr integration config requires baseUrl and apiKey."
    }
    return [pscustomobject]@{ baseUrl=$baseUrl.TrimEnd("/"); apiKey=$apiKey }
}

function Invoke-Radarr {
    param($Connection,[string]$RelativePath)
    $headers=@{ "X-Api-Key"=$Connection.apiKey }
    $uri=$Connection.baseUrl+"/api/v3/"+$RelativePath.TrimStart("/")
    return Invoke-RestMethod -Uri $uri -Headers $headers -Method GET -TimeoutSec 60
}

function Get-RecordArray {
    param($Response)
    if ($null -eq $Response) { return @() }
    $records=Get-PropertyValue -Object $Response -Name "records" -Default $null
    if ($null -ne $records) { return @($records) }
    return @($Response)
}

function Get-HistoryData {
    param($Record)
    return Get-PropertyValue -Object $Record -Name "data" -Default $null
}

function Get-HistoryDownloadId {
    param($Record)
    $direct=[string](Get-PropertyValue -Object $Record -Name "downloadId" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($direct)) { return $direct }
    $data=Get-HistoryData -Record $Record
    return [string](Get-PropertyValue -Object $data -Name "downloadId" -Default "")
}

function Get-HistoryFileId {
    param($Record)
    $data=Get-HistoryData -Record $Record
    foreach ($name in @("movieFileId","fileId","FileId")) {
        $raw=Get-PropertyValue -Object $data -Name $name -Default $null
        if ($null -ne $raw) {
            $n=0
            if ([int]::TryParse([string]$raw,[ref]$n)) { return $n }
        }
    }
    return 0
}

function Get-HistoryImportedPath {
    param($Record)
    $data=Get-HistoryData -Record $Record
    return [string](Get-PropertyValue -Object $data -Name "importedPath" -Default "")
}

function Get-ImportIdentity {
    param($Record,[int]$FileId,[string]$FilePath)
    $id=[string](Get-PropertyValue -Object $Record -Name "id" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($id)) { return "history-id:"+$id }
    return "import:"+$FileId+"|"+[string](Get-PropertyValue -Object $Record -Name "date" -Default "")+"|"+(Get-HistoryDownloadId -Record $Record)+"|"+$FilePath
}

function Get-LatestWaitingTransaction {
    param([int]$MovieId)
    $records=@()
    foreach ($root in @($QuarantineStateRoot,$RetryStateRoot)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
            $state=Read-JsonSafe -Path $file.FullName
            if ($null -eq $state) { continue }
            if ([int](Get-PropertyValue -Object $state -Name "movieId" -Default 0) -ne $MovieId) { continue }
            if ([string](Get-PropertyValue -Object $state -Name "stage" -Default "") -ne "WAITING_FOR_REPLACEMENT_IMPORT") { continue }
            $records += [pscustomobject]@{
                path=$file.FullName; state=$state; updated=Get-UtcDate (Get-PropertyValue -Object $state -Name "updatedUtc" -Default "")
            }
        }
    }
    if ($records.Count -eq 0) { return $null }
    return @($records | Sort-Object updated -Descending)[0]
}

function Get-CurrentMovieFile {
    param($Connection,[int]$MovieId)
    $files=@(Get-RecordArray -Response (Invoke-Radarr -Connection $Connection -RelativePath ("moviefile?movieId={0}" -f $MovieId)))
    if ($files.Count -eq 0) { return $null }
    if ($files.Count -gt 1) { throw "Movie $MovieId has multiple Radarr movie files; reconciliation refuses ambiguity." }
    return $files[0]
}

function Get-LatestImportForFile {
    param([object[]]$History,[int]$FileId,[string]$FilePath)
    $imports=@($History | Where-Object {
        if ([string](Get-PropertyValue -Object $_ -Name "eventType" -Default "") -ne "downloadFolderImported") { return $false }
        $historyFileId=Get-HistoryFileId -Record $_
        $importedPath=Get-HistoryImportedPath -Record $_
        if ($FileId -gt 0 -and $historyFileId -eq $FileId) { return $true }
        if (-not [string]::IsNullOrWhiteSpace($FilePath) -and (Test-PathEquivalent -First $importedPath -Second $FilePath)) { return $true }
        return $false
    } | Sort-Object { Get-UtcDate (Get-PropertyValue -Object $_ -Name "date" -Default "") } -Descending)
    if ($imports.Count -eq 0) { return $null }
    return $imports[0]
}

function Get-LatestDownloadFailureAfter {
    param([object[]]$History,[DateTime]$AfterUtc)
    $matches=@($History | Where-Object {
        if ([string](Get-PropertyValue -Object $_ -Name "eventType" -Default "") -ne "downloadFailed") { return $false }
        return (Get-UtcDate (Get-PropertyValue -Object $_ -Name "date" -Default "")) -ge $AfterUtc
    } | Sort-Object { Get-UtcDate (Get-PropertyValue -Object $_ -Name "date" -Default "") } -Descending)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Convert-CustomFormatsToPipeList {
    param($File)
    $formats=@(Get-PropertyValue -Object $File -Name "customFormats" -Default @())
    $names=@($formats | ForEach-Object {
        if ($_ -is [string]) { [string]$_ }
        else { [string](Get-PropertyValue -Object $_ -Name "name" -Default "") }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return ($names -join "|")
}

function Convert-ValueToSlashList {
    param($Value)
    if ($null -eq $Value) { return "" }
    if ($Value -is [string]) { return [string]$Value }
    return (@($Value) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "/"
}

function Set-EnvValue {
    param([hashtable]$Backup,[string]$Name,$Value)
    $item=Get-Item -LiteralPath ("Env:"+$Name) -ErrorAction SilentlyContinue
    if ($null -eq $item) { $Backup[$Name]=$null } else { $Backup[$Name]=[string]$item.Value }
    Set-Item -LiteralPath ("Env:"+$Name) -Value ([string]$Value)
}

function Restore-Environment {
    param([hashtable]$Backup)
    foreach ($name in @($Backup.Keys)) {
        if ($null -eq $Backup[$name]) { Remove-Item -LiteralPath ("Env:"+$name) -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath ("Env:"+$name) -Value $Backup[$name] }
    }
}

function Invoke-RadarrBridgeReplay {
    param($Movie,$File,$ImportRecord)

    $backup=@{}
    try {
        $movieId=[int](Get-PropertyValue -Object $Movie -Name "id" -Default 0)
        $fileId=[int](Get-PropertyValue -Object $File -Name "id" -Default 0)
        $filePath=[string](Get-PropertyValue -Object $File -Name "path" -Default "")
        $quality=Get-PropertyValue -Object $File -Name "quality" -Default $null
        $qualityInner=Get-PropertyValue -Object $quality -Name "quality" -Default $null
        $revision=Get-PropertyValue -Object $quality -Name "revision" -Default $null
        $mediaInfo=Get-PropertyValue -Object $File -Name "mediaInfo" -Default $null
        $data=Get-HistoryData -Record $ImportRecord

        Set-EnvValue $backup "radarr_eventtype" "Download"
        Set-EnvValue $backup "radarr_movie_id" $movieId
        Set-EnvValue $backup "radarr_movie_title" ([string](Get-PropertyValue -Object $Movie -Name "title" -Default ""))
        Set-EnvValue $backup "radarr_movie_year" ([string](Get-PropertyValue -Object $Movie -Name "year" -Default ""))
        Set-EnvValue $backup "radarr_movie_originallanguage" ([string](Get-PropertyValue -Object $Movie -Name "originalLanguage" -Default ""))
        Set-EnvValue $backup "radarr_movie_path" ([string](Get-PropertyValue -Object $Movie -Name "path" -Default ""))
        Set-EnvValue $backup "radarr_movie_imdbid" ([string](Get-PropertyValue -Object $Movie -Name "imdbId" -Default ""))
        Set-EnvValue $backup "radarr_movie_tmdbid" ([string](Get-PropertyValue -Object $Movie -Name "tmdbId" -Default ""))
        Set-EnvValue $backup "radarr_movie_tags" ((@(Get-PropertyValue -Object $Movie -Name "tags" -Default @())) -join "|")

        Set-EnvValue $backup "radarr_moviefile_id" $fileId
        Set-EnvValue $backup "radarr_moviefile_path" $filePath
        Set-EnvValue $backup "radarr_moviefile_relativepath" ([string](Get-PropertyValue -Object $File -Name "relativePath" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_quality" ([string](Get-PropertyValue -Object $qualityInner -Name "name" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_qualityversion" ([string](Get-PropertyValue -Object $revision -Name "version" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_releasegroup" ([string](Get-PropertyValue -Object $File -Name "releaseGroup" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_scenename" ([string](Get-PropertyValue -Object $File -Name "sceneName" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_customformat" (Convert-CustomFormatsToPipeList -File $File)
        Set-EnvValue $backup "radarr_moviefile_customformatscore" ([string](Get-PropertyValue -Object $File -Name "customFormatScore" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_mediainfo_width" ([string](Get-PropertyValue -Object $mediaInfo -Name "width" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_mediainfo_height" ([string](Get-PropertyValue -Object $mediaInfo -Name "height" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_mediainfo_videocodec" ([string](Get-PropertyValue -Object $mediaInfo -Name "videoCodec" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_mediainfo_videodynamicrangetype" ([string](Get-PropertyValue -Object $mediaInfo -Name "videoDynamicRangeType" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_mediainfo_audiocodec" ([string](Get-PropertyValue -Object $mediaInfo -Name "audioCodec" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_mediainfo_audiochannels" ([string](Get-PropertyValue -Object $mediaInfo -Name "audioChannels" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_mediainfo_audiolanguages" (Convert-ValueToSlashList (Get-PropertyValue -Object $mediaInfo -Name "audioLanguages" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_mediainfo_languages" (Convert-ValueToSlashList (Get-PropertyValue -Object $mediaInfo -Name "languages" -Default ""))
        Set-EnvValue $backup "radarr_moviefile_mediainfo_subtitles" (Convert-ValueToSlashList (Get-PropertyValue -Object $mediaInfo -Name "subtitles" -Default ""))

        Set-EnvValue $backup "radarr_release_title" ([string](Get-PropertyValue -Object $ImportRecord -Name "sourceTitle" -Default ""))
        Set-EnvValue $backup "radarr_release_indexer" ([string](Get-PropertyValue -Object $data -Name "indexer" -Default ""))
        Set-EnvValue $backup "radarr_release_size" ([string](Get-PropertyValue -Object $File -Name "size" -Default ""))
        Set-EnvValue $backup "radarr_download_client" ([string](Get-PropertyValue -Object $data -Name "downloadClient" -Default ""))
        Set-EnvValue $backup "radarr_download_client_type" ([string](Get-PropertyValue -Object $data -Name "downloadClientType" -Default ""))
        Set-EnvValue $backup "radarr_download_id" (Get-HistoryDownloadId -Record $ImportRecord)
        Set-EnvValue $backup "radarr_isupgrade" ([string](Get-PropertyValue -Object $data -Name "isUpgrade" -Default "False"))
        $sourcePath=[string](Get-PropertyValue -Object $data -Name "droppedPath" -Default "")
        Set-EnvValue $backup "radarr_moviefile_sourcepath" $sourcePath
        Set-EnvValue $backup "radarr_moviefile_sourcefolder" $(if ([string]::IsNullOrWhiteSpace($sourcePath)) { "" } else { Split-Path -Parent $sourcePath })

        $bridgeOutput=@(& $BridgePath -Source Radarr -DeferWorkerStart -PassThru)
        $bridgeObjects=@($bridgeOutput | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties["eventId"] })
        if ($bridgeObjects.Count -ne 1) { throw "Bridge replay did not return exactly one event result object." }
        return $bridgeObjects[0]
    }
    finally { Restore-Environment -Backup $backup }
}

function Invoke-AcquisitionRetryPreflight {
    param([int]$MovieId,[string]$ResultPath)
    & $AcquisitionRetryPath -MovieId $MovieId -JsonOut $ResultPath | Out-Null
    return Read-JsonSafe -Path $ResultPath
}

function Invoke-AcquisitionRetryExecute {
    param([int]$MovieId,[string]$ChainId,[string]$ResultPath)
    & $AcquisitionRetryPath -MovieId $MovieId -Execute -ConfirmChainId $ChainId -JsonOut $ResultPath | Out-Null
    return Read-JsonSafe -Path $ResultPath
}

Ensure-Directory -Path $ReconcileRoot
Ensure-Directory -Path $ReconcileStateRoot

$result=[ordered]@{
    schemaVersion="1.0"
    scriptVersion=$ScriptVersion
    timestampUtc=[DateTime]::UtcNow.ToString("o")
    mode=if ($Execute) { "EXECUTE" } else { "DRY_RUN" }
    status="STARTED"
    reason=$null
    workerSettings=$null
    queue=$null
    activeChains=0
    actions=@()
    workerStart=$null
    error=$null
}

$mutex=New-Object System.Threading.Mutex($false,"ReqestraReacquisitionReconciler")
$held=$false
try {
    $held=$mutex.WaitOne(0)
    if (-not $held) {
        $result.status="SKIPPED_ALREADY_RUNNING"; $result.reason="reconciler_mutex_held"; Write-Result ([pscustomobject]$result); exit 0
    }

    $settings=Get-ReacquisitionWorkerSettings -IntegrationRoot $IntegrationRoot
    $result.workerSettings=$settings
    $queueSummary=Get-ReacquisitionQueueSummary -IntegrationRoot $IntegrationRoot
    $result.queue=$queueSummary
    if ([int]$queueSummary.pending -gt 0 -or [int]$queueSummary.running -gt 0) {
        $result.status="DEFERRED_QUEUE_BUSY"; $result.reason="reacquisition_queue_not_idle"; Write-ReconcileLog ([pscustomobject]$result); Write-Result ([pscustomobject]$result); exit 0
    }

    if ($Execute -and (-not [bool]$settings.automaticWritesAuthorized -or [string]$settings.effectiveMode -ne "AUTO_EXECUTE")) {
        $result.status="BLOCKED_AUTO_EXECUTE_NOT_AUTHORIZED"; $result.reason=[string]$settings.reason; Write-ReconcileLog ([pscustomobject]$result); Write-Result ([pscustomobject]$result); exit 0
    }

    $connection=Get-RadarrConnection
    $globalQueue=@(Get-RecordArray -Response (Invoke-Radarr -Connection $connection -RelativePath "queue?page=1&pageSize=1000&includeUnknownMovieItems=true"))
    $chains=@(Get-ChildItem -LiteralPath $ChainRoot -Filter "Radarr-*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
        $chain=Read-JsonSafe -Path $_.FullName
        if ($null -ne $chain -and [string](Get-PropertyValue -Object $chain -Name "status" -Default "") -eq "ACTIVE") {
            $id=[int](Get-PropertyValue -Object $chain -Name "entityId" -Default 0)
            if ($TargetMovieId.Count -eq 0 -or $TargetMovieId -contains $id) {
                [pscustomobject]@{ path=$_.FullName; chain=$chain }
            }
        }
    })
    if ($MaxChains -gt 0) { $chains=@($chains | Select-Object -First $MaxChains) }
    $result.activeChains=$chains.Count
    $queuedByReplay=$false

    foreach ($entry in $chains) {
        $chain=$entry.chain
        $movieId=[int](Get-PropertyValue -Object $chain -Name "entityId" -Default 0)
        $chainId=[string](Get-PropertyValue -Object $chain -Name "chainId" -Default "")
        $action=[ordered]@{ movieId=$movieId; chainId=$chainId; classification=$null; status=$null; reason=$null; detail=$null }
        try {
            $movie=Invoke-Radarr -Connection $connection -RelativePath ("movie/{0}" -f $movieId)
            $currentFile=Get-CurrentMovieFile -Connection $connection -MovieId $movieId
            $queueForMovie=@($globalQueue | Where-Object { [int](Get-PropertyValue -Object $_ -Name "movieId" -Default 0) -eq $movieId })
            if ($queueForMovie.Count -gt 0) {
                $action.classification="RADARR_QUEUE_PRESENT"; $action.status="WAITING"; $action.detail=@($queueForMovie | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "title" -Default "") }); $result.actions += [pscustomobject]$action; continue
            }

            $history=@(Get-RecordArray -Response (Invoke-Radarr -Connection $connection -RelativePath ("history/movie?movieId={0}&includeMovie=false" -f $movieId)))
            $transaction=Get-LatestWaitingTransaction -MovieId $movieId
            $transactionUpdated=if ($null -eq $transaction) { Get-UtcDate (Get-PropertyValue -Object $chain -Name "updatedUtc" -Default "") } else { $transaction.updated }

            if ($null -ne $currentFile) {
                $fileId=[int](Get-PropertyValue -Object $currentFile -Name "id" -Default 0)
                $filePath=[string](Get-PropertyValue -Object $currentFile -Name "path" -Default "")
                $import=Get-LatestImportForFile -History $history -FileId $fileId -FilePath $filePath
                if ($null -ne $import) {
                    $importDate=Get-UtcDate (Get-PropertyValue -Object $import -Name "date" -Default "")
                    if ($importDate -gt $transactionUpdated) {
                        $identity=Get-ImportIdentity -Record $import -FileId $fileId -FilePath $filePath
                        $statePath=Join-Path $ReconcileStateRoot ("Radarr-{0}.json" -f $movieId)
                        $state=Read-JsonSafe -Path $statePath
                        $priorIdentity=[string](Get-PropertyValue -Object $state -Name "importIdentity" -Default "")
                        $replayCount=if ($priorIdentity -eq $identity) { [int](Get-PropertyValue -Object $state -Name "replayCount" -Default 0) } else { 0 }
                        $lastReplay=if ($priorIdentity -eq $identity) { Get-UtcDate (Get-PropertyValue -Object $state -Name "lastReplayUtc" -Default "") } else { [DateTime]::MinValue }

                        if ($replayCount -ge $MaxImportReplays) {
                            $action.classification="IMPORTED_RECONCILIATION_EXHAUSTED"; $action.status="RECOVERY_REQUIRED"; $action.reason="import_replay_limit_reached"
                            if ($Execute) {
                                $chain.status="RECOVERY_REQUIRED"
                                $chain | Add-Member -NotePropertyName "recoveryReason" -NotePropertyValue "import_replay_limit_reached" -Force
                                $chain.updatedUtc=[DateTime]::UtcNow.ToString("o")
                                Write-AtomicJson -Path $entry.path -Object $chain
                            }
                            $result.actions += [pscustomobject]$action; continue
                        }

                        if ($lastReplay -ne [DateTime]::MinValue -and [DateTime]::UtcNow -lt $lastReplay.AddSeconds($ImportReplayBackoffSeconds)) {
                            $action.classification="IMPORTED_REPLAY_BACKOFF"; $action.status="WAITING"; $action.reason="replay_backoff_active"; $result.actions += [pscustomobject]$action; continue
                        }

                        $action.classification="IMPORTED_CHAIN_REPLAY"
                        if (-not $Execute) {
                            $action.status="DRY_RUN_READY"; $action.detail=$identity; $result.actions += [pscustomobject]$action; continue
                        }

                        $bridge=Invoke-RadarrBridgeReplay -Movie $movie -File $currentFile -ImportRecord $import
                        $rq=Get-PropertyValue -Object $bridge -Name "reacquisitionQueue" -Default $null
                        $queueStatus=[string](Get-PropertyValue -Object $rq -Name "status" -Default "")
                        $replayCount++
                        $state=[pscustomobject][ordered]@{
                            schemaVersion="1.0"; movieId=$movieId; chainId=$chainId; importIdentity=$identity; fileId=$fileId; filePath=$filePath
                            replayCount=$replayCount; lastReplayUtc=[DateTime]::UtcNow.ToString("o"); bridgeEventId=[string](Get-PropertyValue -Object $bridge -Name "eventId" -Default "")
                            bridgeStatus=[string](Get-PropertyValue -Object $bridge -Name "status" -Default ""); queueStatus=$queueStatus
                        }
                        Write-AtomicJson -Path $statePath -Object $state
                        $action.status=$queueStatus; $action.detail=$state.bridgeEventId
                        if ($queueStatus -eq "ENQUEUED") { $queuedByReplay=$true }
                        $result.actions += [pscustomobject]$action; continue
                    }
                }
            }

            $failure=Get-LatestDownloadFailureAfter -History $history -AfterUtc $transactionUpdated
            if ($null -ne $failure) {
                $action.classification="FAILED_DOWNLOAD_RECONCILIATION"
                $prePath=Join-Path $ReconcileRoot ("acquisition-preflight-{0}-{1}.json" -f $movieId,[DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ"))
                $pre=Invoke-AcquisitionRetryPreflight -MovieId $movieId -ResultPath $prePath
                $preStatus=[string](Get-PropertyValue -Object $pre -Name "status" -Default "FAILED")
                if (-not $Execute) {
                    $action.status=$preStatus; $action.reason=[string](Get-PropertyValue -Object $pre -Name "reason" -Default ""); $action.detail=$prePath; $result.actions += [pscustomobject]$action; continue
                }
                if ($preStatus -notin @("DRY_RUN_READY","DRY_RUN_TERMINAL_REVIEW_READY")) {
                    $action.status=$preStatus; $action.reason=[string](Get-PropertyValue -Object $pre -Name "reason" -Default ""); $action.detail=$prePath; $result.actions += [pscustomobject]$action; continue
                }
                $execPath=Join-Path $ReconcileRoot ("acquisition-execute-{0}-{1}.json" -f $movieId,[DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ"))
                $exec=Invoke-AcquisitionRetryExecute -MovieId $movieId -ChainId $chainId -ResultPath $execPath
                $action.status=[string](Get-PropertyValue -Object $exec -Name "status" -Default "FAILED")
                $action.reason=[string](Get-PropertyValue -Object $exec -Name "reason" -Default "")
                $action.detail=$execPath
                $result.actions += [pscustomobject]$action; continue
            }

            $action.classification="ACTIVE_NO_ACTIONABLE_RECONCILIATION"
            $action.status="WAITING"
            $action.reason="no_new_import_no_failed_download_no_queue"
            $result.actions += [pscustomobject]$action
        }
        catch {
            $action.classification="RECONCILIATION_EXCEPTION"
            $action.status="FAILED"
            $action.reason=$_.Exception.Message
            $result.actions += [pscustomobject]$action
        }
    }

    if ($Execute -and $queuedByReplay) {
        $result.workerStart=Start-ReacquisitionQueueWorker -IntegrationRoot $IntegrationRoot
    }

    $failures=@($result.actions | Where-Object { [string](Get-PropertyValue -Object $_ -Name "status" -Default "") -eq "FAILED" })
    $result.status=if ($failures.Count -gt 0) { "COMPLETED_WITH_ERRORS" } else { "COMPLETED" }
    $result.reason=$null
    Write-ReconcileLog ([pscustomobject]$result)
    Write-Result ([pscustomobject]$result)
    exit 0
}
catch {
    $result.status="FAILED"
    $result.reason="reconciler_exception"
    $result.error=$_.Exception.Message
    try { Write-ReconcileLog ([pscustomobject]$result) } catch {}
    Write-Result ([pscustomobject]$result)
    exit 0
}
finally {
    if ($held) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
}
