[CmdletBinding()]
param(
    [int[]]$MovieId = @(),
    [ValidateRange(0,100000)][int]$MaxMovies = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SweepVersion = "0.1.0"
$IntegrationRoot = $PSScriptRoot
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"
$BridgePath = Join-Path $IntegrationRoot "ReqestraArrBridge.ps1"

function Get-Prop {
    param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $Default }
    $p=$Object.PSObject.Properties[$Name]; if ($null -eq $p) { return $Default }; return $p.Value
}
function To-Array {
    param($Value)
    $items = @()
    foreach ($x in $Value) { $items += $x }
    return @($items)
}
function Invoke-RadarrGet {
    param($Connection,[string]$Path)
    Invoke-RestMethod -Method Get -Uri ($Connection.baseUrl+"/api/v3/"+$Path.TrimStart('/')) -Headers @{"X-Api-Key"=$Connection.apiKey} -TimeoutSec 60
}
function Get-HistoryRecords { param($Response)
    if ($null -eq $Response) { return @() }
    $records=Get-Prop $Response "records" $null
    if ($null -ne $records) { return @(To-Array $records) }
    return @(To-Array $Response)
}
function Get-HistoryFileId { param($Record)
    $data=Get-Prop $Record "data" $null
    foreach($name in @("movieFileId","fileId")) {
        $raw=Get-Prop $data $name $null; $n=0
        if ($null -ne $raw -and [int]::TryParse([string]$raw,[ref]$n)) { return $n }
    }
    return 0
}
function Find-ImportRecord {
    param($Connection,[int]$MovieId,[int]$FileId,[string]$MediaPath)
    try { $response=Invoke-RadarrGet $Connection ("history/movie?movieId={0}&includeMovie=false" -f $MovieId) }
    catch { return $null }
    $records=@(Get-HistoryRecords $response | Where-Object { [string](Get-Prop $_ "eventType" "") -eq "downloadFolderImported" })
    $matches=@($records | Where-Object { (Get-HistoryFileId $_) -eq $FileId } | Sort-Object { [datetime](Get-Prop $_ "date" "1900-01-01") } -Descending)
    if ($matches.Count -gt 0) { return $matches[0] }
    $matches=@($records | Where-Object {
        $data=Get-Prop $_ "data" $null
        $p=[string](Get-Prop $data "importedPath" "")
        -not [string]::IsNullOrWhiteSpace($p) -and [string]::Equals($p,$MediaPath,[System.StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object { [datetime](Get-Prop $_ "date" "1900-01-01") } -Descending)
    if ($matches.Count -gt 0) { return $matches[0] }
    return $null
}
function Set-EnvValue {
    param([hashtable]$Saved,[string]$Name,$Value)
    if (-not $Saved.ContainsKey($Name)) { $Saved[$Name]=[Environment]::GetEnvironmentVariable($Name,"Process") }
    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    [Environment]::SetEnvironmentVariable($Name,$text,"Process")
}
function Restore-Environment { param([hashtable]$Saved)
    foreach($k in $Saved.Keys){ [Environment]::SetEnvironmentVariable($k,$Saved[$k],"Process") }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Integration config missing: $ConfigPath" }
if (-not (Test-Path -LiteralPath $BridgePath -PathType Leaf)) { throw "Bridge missing: $BridgePath" }
$config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$radarr=Get-Prop $config "radarr" $null
$connection=[pscustomobject]@{ baseUrl=([string](Get-Prop $radarr "baseUrl" "")).TrimEnd('/'); apiKey=[string](Get-Prop $radarr "apiKey" "") }
if ([string]::IsNullOrWhiteSpace($connection.baseUrl) -or [string]::IsNullOrWhiteSpace($connection.apiKey)) { throw "Radarr baseUrl/apiKey missing." }

$movieResponse=Invoke-RadarrGet $connection "movie"
$movies=@(To-Array $movieResponse | Where-Object { [bool](Get-Prop $_ "hasFile" $false) })
if ($MovieId.Count -gt 0) { $movies=@($movies | Where-Object { [int](Get-Prop $_ "id" 0) -in $MovieId }) }
$movies=@($movies | Sort-Object { [string](Get-Prop $_ "sortTitle" (Get-Prop $_ "title" "")) })
if ($MaxMovies -gt 0) { $movies=@($movies | Select-Object -First $MaxMovies) }

$results=@()
foreach($movie in $movies) {
    $id=[int](Get-Prop $movie "id" 0)
    $file=Get-Prop $movie "movieFile" $null
    if ($null -eq $file -or [int](Get-Prop $file "id" 0) -le 0) {
        try {
            $files=@(To-Array (Invoke-RadarrGet $connection ("moviefile?movieId={0}" -f $id)))
            $file=$files | Select-Object -First 1
        } catch { $file=$null }
    }
    if ($null -eq $file) { $results += [pscustomobject]@{movieId=$id;title=[string](Get-Prop $movie "title" "");status="SKIPPED";reason="movie_file_not_resolved"}; continue }

    $fileId=[int](Get-Prop $file "id" 0)
    $mediaPath=[string](Get-Prop $file "path" "")
    if ([string]::IsNullOrWhiteSpace($mediaPath)) {
        $relative=[string](Get-Prop $file "relativePath" "")
        $mediaPath=Join-Path ([string](Get-Prop $movie "path" "")) $relative
    }
    if (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) { $results += [pscustomobject]@{movieId=$id;title=[string](Get-Prop $movie "title" "");status="SKIPPED";reason="media_missing"}; continue }

    $history=Find-ImportRecord -Connection $connection -MovieId $id -FileId $fileId -MediaPath $mediaPath
    $saved=@{}
    try {
        Set-EnvValue $saved "radarr_eventtype" "RemediationSweep"
        Set-EnvValue $saved "radarr_movie_id" $id
        Set-EnvValue $saved "radarr_movie_title" (Get-Prop $movie "title" "")
        Set-EnvValue $saved "radarr_movie_year" (Get-Prop $movie "year" "")
        $orig=Get-Prop $movie "originalLanguage" $null
        Set-EnvValue $saved "radarr_movie_originallanguage" (Get-Prop $orig "name" (Get-Prop $movie "originalLanguage" ""))
        Set-EnvValue $saved "radarr_movie_path" (Get-Prop $movie "path" "")
        Set-EnvValue $saved "radarr_movie_imdbid" (Get-Prop $movie "imdbId" "")
        Set-EnvValue $saved "radarr_movie_tmdbid" (Get-Prop $movie "tmdbId" "")
        Set-EnvValue $saved "radarr_movie_tags" ((@(Get-Prop $movie "tags" @()) | ForEach-Object {[string]$_}) -join '|')

        Set-EnvValue $saved "radarr_moviefile_id" $fileId
        Set-EnvValue $saved "radarr_moviefile_path" $mediaPath
        Set-EnvValue $saved "radarr_moviefile_relativepath" (Get-Prop $file "relativePath" ([IO.Path]::GetFileName($mediaPath)))
        $quality=Get-Prop (Get-Prop $file "quality" $null) "quality" $null
        Set-EnvValue $saved "radarr_moviefile_quality" (Get-Prop $quality "name" "")
        Set-EnvValue $saved "radarr_moviefile_qualityversion" (Get-Prop (Get-Prop $file "quality" $null) "revision" "")
        Set-EnvValue $saved "radarr_moviefile_releasegroup" (Get-Prop $file "releaseGroup" "")
        Set-EnvValue $saved "radarr_moviefile_scenename" (Get-Prop $file "sceneName" "")

        Set-EnvValue $saved "radarr_release_title" (Get-Prop $history "sourceTitle" (Get-Prop $file "sceneName" ""))
        Set-EnvValue $saved "radarr_release_indexer" (Get-Prop (Get-Prop $history "data" $null) "indexer" "")
        Set-EnvValue $saved "radarr_download_id" (Get-Prop $history "downloadId" "")
        Set-EnvValue $saved "radarr_isupgrade" "false"

        & $BridgePath -Source Radarr -DeferWorkerStart
        $results += [pscustomobject]@{movieId=$id;title=[string](Get-Prop $movie "title" "");status="SUBMITTED";reason=$null}
    }
    catch {
        $results += [pscustomobject]@{movieId=$id;title=[string](Get-Prop $movie "title" "");status="ERROR";reason=$_.Exception.Message}
    }
    finally { Restore-Environment $saved }
}

# Start each worker once after the sweep has queued all remediation events.
$normalizationWorkerStart=$null
$reacquisitionWorkerStart=$null
try {
    . (Join-Path $IntegrationRoot "QueueCommon.ps1")
    . (Join-Path $IntegrationRoot "ReacquisitionQueueCommon.ps1")
    $normalizationWorkerStart=Start-NormalizationQueueWorker -IntegrationRoot $IntegrationRoot
    $reacquisitionWorkerStart=Start-ReacquisitionQueueWorker -IntegrationRoot $IntegrationRoot
}
catch {
    # Jobs remain durably queued; a later hook/sweep can start the workers.
}

[pscustomobject][ordered]@{
    schemaVersion="1.0"
    sweepVersion=$SweepVersion
    timestampUtc=[DateTime]::UtcNow.ToString("o")
    submitted=@($results | Where-Object {$_.status -eq "SUBMITTED"}).Count
    skipped=@($results | Where-Object {$_.status -eq "SKIPPED"}).Count
    errors=@($results | Where-Object {$_.status -eq "ERROR"}).Count
    normalizationWorkerStart=$normalizationWorkerStart
    reacquisitionWorkerStart=$reacquisitionWorkerStart
    results=@($results)
} | ConvertTo-Json -Depth 20
