Set-StrictMode -Version Latest

function Get-SonarrConnection {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Integration config not found: $ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sonarr = Get-PropertyValue -Object $config -Name "sonarr"
    $baseUrl = [string](Get-PropertyValue -Object $sonarr -Name "baseUrl" -Default "")
    $apiKey = [string](Get-PropertyValue -Object $sonarr -Name "apiKey" -Default "")

    if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Sonarr integration config requires baseUrl and apiKey."
    }

    return [pscustomobject]@{
        baseUrl = $baseUrl.TrimEnd("/")
        apiKey = $apiKey
    }
}

function Invoke-SonarrApi {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [ValidateSet("GET","POST","PUT","DELETE")][string]$Method = "GET",
        $Body = $null
    )

    $headers = @{ "X-Api-Key" = $Connection.apiKey }
    $uri = $Connection.baseUrl + "/api/v3/" + $RelativePath.TrimStart("/")

    $args = @{
        Uri = $uri
        Headers = $headers
        Method = $Method
        TimeoutSec = 60
    }

    if ($null -ne $Body) {
        $args["Body"] = ($Body | ConvertTo-Json -Depth 40)
        $args["ContentType"] = "application/json"
    }

    return Invoke-RestMethod @args
}

function Wait-SonarrCommand {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][int]$CommandId,
        [int]$TimeoutSeconds = 300
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $last = Invoke-SonarrApi -Connection $Connection -RelativePath ("command/{0}" -f $CommandId)
        $status = [string](Get-PropertyValue -Object $last -Name "status" -Default "")
        if ($status -notin @("queued","started")) { return $last }
    }
    while ([DateTime]::UtcNow -lt $deadline)

    throw "Timed out waiting for Sonarr command $CommandId."
}

function Get-SonarrRecordArray {
    param($Response)
    if ($null -eq $Response) { return @() }
    $records = Get-PropertyValue -Object $Response -Name "records" -Default $null
    if ($null -ne $records) { return @($records) }
    return @($Response)
}

function Get-SonarrHistoryEpisodeId {
    param($HistoryRecord)

    $raw = Get-PropertyValue -Object $HistoryRecord -Name "episodeId" -Default $null
    if ($null -eq $raw) {
        $data = Get-PropertyValue -Object $HistoryRecord -Name "data"
        if ($null -ne $data) {
            $raw = Get-PropertyValue -Object $data -Name "episodeId" -Default $null
        }
    }

    $parsed = 0
    if ([int]::TryParse([string]$raw, [ref]$parsed)) { return $parsed }
    return 0
}

function Get-SonarrHistoryFileId {
    param($HistoryRecord)

    $data = Get-PropertyValue -Object $HistoryRecord -Name "data"
    if ($null -eq $data) { return 0 }
    $raw = Get-PropertyValue -Object $data -Name "fileId" -Default $null
    if ($null -eq $raw) { $raw = Get-PropertyValue -Object $data -Name "FileId" -Default $null }
    $parsed = 0
    if ([int]::TryParse([string]$raw, [ref]$parsed)) { return $parsed }
    return 0
}

function Get-SonarrHistoryImportedPath {
    param($HistoryRecord)
    $data = Get-PropertyValue -Object $HistoryRecord -Name "data"
    if ($null -eq $data) { return "" }
    return [string](Get-PropertyValue -Object $data -Name "importedPath" -Default "")
}

function Resolve-SonarrLogicalHistoryMatch {
    param(
        [object[]]$Records,
        [ValidateSet("import", "grabbed")][string]$Role,
        [int]$ExpectedFileId,
        [string]$ExpectedPath,
        [int[]]$ExpectedEpisodeIds
    )

    $items = @($Records)
    if ($items.Count -le 1) {
        return [pscustomobject]@{
            resolved = ($items.Count -eq 1)
            ambiguous = $false
            selected = if ($items.Count -eq 1) { $items[0] } else { $null }
            physicalMatchCount = $items.Count
            logicalMatchCount = $items.Count
            reason = $null
        }
    }

    $downloadIds = @(
        $items | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "downloadId" -Default "") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique
    )
    $sourceTitles = @(
        $items | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "sourceTitle" -Default "") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique
    )
    $episodeIds = @(
        $items | ForEach-Object { Get-SonarrHistoryEpisodeId $_ } |
            Where-Object { $_ -gt 0 } | Select-Object -Unique
    )

    $identityConsistent = ($downloadIds.Count -le 1 -and $sourceTitles.Count -le 1)
    $episodeSetSafe = $true
    $expectedSet = @($ExpectedEpisodeIds | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    if ($episodeIds.Count -gt 0 -and $expectedSet.Count -gt 0) {
        foreach ($episodeId in $episodeIds) {
            if ($expectedSet -notcontains $episodeId) { $episodeSetSafe = $false; break }
        }
    }

    $roleSafe = $true
    if ($Role -eq "import") {
        $fileIds = @($items | ForEach-Object { Get-SonarrHistoryFileId $_ } |
            Where-Object { $_ -gt 0 } | Select-Object -Unique)
        $paths = @($items | ForEach-Object { Get-SonarrHistoryImportedPath $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($fileIds.Count -gt 0 -and ($fileIds.Count -ne 1 -or $fileIds[0] -ne $ExpectedFileId)) {
            $roleSafe = $false
        }
        if ($paths.Count -gt 0) {
            foreach ($path in $paths) {
                if (-not (Test-PathEquivalent $path $ExpectedPath)) { $roleSafe = $false; break }
            }
        }
    }

    if (-not $identityConsistent -or -not $episodeSetSafe -or -not $roleSafe) {
        return [pscustomobject]@{
            resolved = $false
            ambiguous = $true
            selected = $null
            physicalMatchCount = $items.Count
            logicalMatchCount = $items.Count
            reason = "sonarr_history_rows_disagree_on_release_identity"
        }
    }

    $selected = @($items | Sort-Object { [int](Get-PropertyValue -Object $_ -Name "id" -Default 0) } -Descending)[0]
    return [pscustomobject]@{
        resolved = $true
        ambiguous = $false
        selected = $selected
        physicalMatchCount = $items.Count
        logicalMatchCount = 1
        reason = $null
    }
}

function Get-SonarrEpisodeIdsFromPlan {
    param($Plan)
    return @(
        @(Get-PropertyValue -Object $Plan -Name "episodeIds" -Default @()) |
            ForEach-Object {
                $parsed = 0
                if ([int]::TryParse([string]$_, [ref]$parsed) -and $parsed -gt 0) { $parsed }
            } |
            Select-Object -Unique
    )
}

function Get-SonarrEpisodeSetKey {
    param([Parameter(Mandatory = $true)][int[]]$EpisodeIds)

    $normalized = @(
        $EpisodeIds | Where-Object { $_ -gt 0 } | Sort-Object -Unique
    )
    if ($normalized.Count -eq 0) { throw "At least one Sonarr episode ID is required." }

    $identity = $normalized -join ","
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($identity)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    $hex = ([BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
    return "episodes-" + $hex.Substring(0, 12)
}

function Get-SonarrBlocklistRelativePath {
    param([Parameter(Mandatory = $true)][int]$SeriesId)
    return "blocklist?page=1&pageSize=1000&seriesIds=$SeriesId"
}

function Get-SonarrHistoryRelativePath {
    param([Parameter(Mandatory = $true)][int]$SeriesId)
    return "history/series?seriesId=$SeriesId&includeSeries=false"
}

function Get-SonarrEpisodeFilesRelativePath {
    param([Parameter(Mandatory = $true)][int]$SeriesId)
    return "episodefile?seriesId=$SeriesId"
}

function Get-SonarrSearchCommandBody {
    param([Parameter(Mandatory = $true)][int[]]$EpisodeIds)
    if (@($EpisodeIds).Count -eq 0) { throw "At least one Sonarr episode ID is required." }
    return [ordered]@{
        name = "EpisodeSearch"
        episodeIds = @($EpisodeIds)
    }
}

function Get-SonarrRescanCommandBody {
    param([Parameter(Mandatory = $true)][int]$SeriesId)
    return [ordered]@{
        name = "RescanSeries"
        seriesId = $SeriesId
    }
}

function Get-SonarrReleaseSearchRelativePath {
    param([Parameter(Mandatory = $true)][int[]]$EpisodeIds)
    if (@($EpisodeIds).Count -ne 1) { return $null }
    return "release?episodeId=$($EpisodeIds[0])"
}

function Test-SonarrQueueRecordMatches {
    param(
        $Record,
        [Parameter(Mandatory = $true)][int]$SeriesId,
        [Parameter(Mandatory = $true)][int[]]$EpisodeIds
    )

    if ([int](Get-PropertyValue -Object $Record -Name "seriesId" -Default 0) -ne $SeriesId) {
        return $false
    }

    $queueEpisodeId = [int](Get-PropertyValue -Object $Record -Name "episodeId" -Default 0)
    if ($queueEpisodeId -le 0) { return $true }
    return (@($EpisodeIds) -contains $queueEpisodeId)
}
