[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Radarr", "Sonarr")]
    [string]$Source
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BridgeVersion = "0.8.0"
$Prefix = $Source.ToLowerInvariant() + "_"
$IntegrationRoot = $PSScriptRoot
$ValidatorRoot = Split-Path -Parent $IntegrationRoot
$ValidatorPath = Join-Path $ValidatorRoot "MediaValidator.ps1"
$ContextValidatorPath = Join-Path $IntegrationRoot "ContextValidator.ps1"
$NormalizationPlannerPath = Join-Path $IntegrationRoot "NormalizationPlanner.ps1"
$QueueCommonPath = Join-Path $IntegrationRoot "QueueCommon.ps1"
$PolicyPath = Join-Path $ValidatorRoot "validator-policy.json"
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"
$LogRoot = Join-Path $IntegrationRoot "logs"
$EventRoot = Join-Path $LogRoot "events"
$MainLogPath = Join-Path $LogRoot "integration.jsonl"
$ErrorLogPath = Join-Path $LogRoot "bridge-errors.log"

function Get-HigherOutcome {
    param(
        [string]$First,
        [string]$Second
    )

    $rank = @{
        "PASS" = 0
        "NORMALIZE" = 1
        "REVIEW" = 2
        "REACQUIRE" = 3
    }

    if (-not $rank.ContainsKey($First)) {
        $First = "PASS"
    }

    if (-not $rank.ContainsKey($Second)) {
        return $First
    }

    if ($rank[$Second] -gt $rank[$First]) {
        return $Second
    }

    return $First
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-JsonLine {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $json = $Object | ConvertTo-Json -Depth 40 -Compress
    Add-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Get-EnvironmentSnapshot {
    param([string]$VariablePrefix)

    $snapshot = [ordered]@{}
    Get-ChildItem Env: |
        Where-Object { $_.Name.StartsWith($VariablePrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object Name |
        ForEach-Object {
            $snapshot[$_.Name] = $_.Value
        }

    return [pscustomobject]$snapshot
}

function Get-EnvironmentValue {
    param([string]$Name)

    $item = Get-Item -LiteralPath ("Env:" + $Name) -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return ""
    }

    return [string]$item.Value
}

function Split-PipeList {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @(
        $Value -split '\|' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Split-SlashList {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @(
        $Value -split '\s*/\s*' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function To-NullableInt {
    param([string]$Value)

    $parsed = 0
    if ([int]::TryParse($Value, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function To-NullableInt64 {
    param([string]$Value)

    $parsed = [int64]0
    if ([int64]::TryParse($Value, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function To-NullableBool {
    param([string]$Value)

    $parsed = $false
    if ([bool]::TryParse($Value, [ref]$parsed)) {
        return $parsed
    }

    return $null
}


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

function Read-IntegrationConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-SourceConfig {
    param($Config)

    if ($null -eq $Config) {
        return $null
    }

    if ($Source -eq "Radarr") {
        return $Config.radarr
    }

    return $Config.sonarr
}

function Get-ApiKey {
    param($SourceConfig)

    $envName = if ($Source -eq "Radarr") { "REQESTRA_RADARR_API_KEY" } else { "REQESTRA_SONARR_API_KEY" }
    $envValue = Get-EnvironmentValue $envName
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return $envValue
    }

    if ($null -ne $SourceConfig -and $null -ne $SourceConfig.apiKey) {
        $configured = [string]$SourceConfig.apiKey
        if (-not [string]::IsNullOrWhiteSpace($configured)) {
            return $configured
        }
    }

    return ""
}

function Get-ApplicationUrl {
    param($SourceConfig)

    if ($null -ne $SourceConfig -and $null -ne $SourceConfig.baseUrl) {
        $configured = [string]$SourceConfig.baseUrl
        if (-not [string]::IsNullOrWhiteSpace($configured)) {
            return $configured.TrimEnd('/')
        }
    }

    $envName = if ($Source -eq "Radarr") { "radarr_applicationurl" } else { "sonarr_applicationurl" }
    $value = Get-EnvironmentValue $envName
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ""
    }

    return $value.TrimEnd('/')
}

function Invoke-ApiGet {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ApiKey
    )

    $headers = @{
        "X-Api-Key" = $ApiKey
        "Accept" = "application/json"
    }

    return Invoke-RestMethod -Method Get -Uri $Url -Headers $headers -UseBasicParsing -TimeoutSec 10
}

function Resolve-ApiVersion {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        $SourceConfig
    )

    if ($null -ne $SourceConfig -and $null -ne $SourceConfig.apiVersion) {
        $configured = ([string]$SourceConfig.apiVersion).Trim()
        if (-not [string]::IsNullOrWhiteSpace($configured) -and $configured -ne "auto") {
            if ($configured.StartsWith("v")) {
                return $configured
            }
            return "v" + $configured
        }
    }

    try {
        $apiInfo = Invoke-ApiGet -Url ($BaseUrl + "/api") -ApiKey $ApiKey
        if ($null -ne $apiInfo.current) {
            $current = ([string]$apiInfo.current).Trim()
            if (-not [string]::IsNullOrWhiteSpace($current)) {
                if ($current.StartsWith("v")) {
                    return $current
                }
                return "v" + $current
            }
        }
    }
    catch {
        # Fall through to conservative compatibility defaults.
    }

    # Sonarr v3/v4 use API v3. Radarr's current public API is v3.
    return "v3"
}

function Get-ProfileEnrichment {
    param(
        [Parameter(Mandatory = $true)][string]$EntityId
    )

    $result = [ordered]@{
        status = "NOT_CONFIGURED"
        apiVersion = $null
        qualityProfileId = $null
        qualityProfileName = $null
        upgradeAllowed = $null
        cutoff = $null
        minFormatScore = $null
        cutoffFormatScore = $null
        formatScores = @()
        error = $null
    }

    $config = Read-IntegrationConfig
    $sourceConfig = Get-SourceConfig -Config $config
    $apiKey = Get-ApiKey -SourceConfig $sourceConfig
    $baseUrl = Get-ApplicationUrl -SourceConfig $sourceConfig

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        $result.status = "API_KEY_MISSING"
        return [pscustomobject]$result
    }

    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $result.status = "BASE_URL_MISSING"
        return [pscustomobject]$result
    }

    try {
        $apiVersion = Resolve-ApiVersion -BaseUrl $baseUrl -ApiKey $apiKey -SourceConfig $sourceConfig
        $result.apiVersion = $apiVersion

        if ($Source -eq "Radarr") {
            $entityUrl = "{0}/api/{1}/movie/{2}" -f $baseUrl, $apiVersion, $EntityId
        }
        else {
            $entityUrl = "{0}/api/{1}/series/{2}" -f $baseUrl, $apiVersion, $EntityId
        }

        $entity = Invoke-ApiGet -Url $entityUrl -ApiKey $apiKey
        if ($null -eq $entity.qualityProfileId) {
            $result.status = "QUALITY_PROFILE_ID_MISSING"
            return [pscustomobject]$result
        }

        $profileId = [int]$entity.qualityProfileId
        $profileUrl = "{0}/api/{1}/qualityprofile/{2}" -f $baseUrl, $apiVersion, $profileId
        $profile = Invoke-ApiGet -Url $profileUrl -ApiKey $apiKey

        $formatScores = @()
        $profileFormatItems = Get-PropertyValue -Object $profile -Name "formatItems" -Default @()
        if ($null -ne $profileFormatItems) {
            $formatScores = @(
                $profileFormatItems | ForEach-Object {
                    $flatFormatId = Get-PropertyValue -Object $_ -Name "format"
                    $flatName = Get-PropertyValue -Object $_ -Name "name"
                    $scoreValue = Get-PropertyValue -Object $_ -Name "score" -Default 0

                    # Current Servarr API resources expose:
                    #   format: <integer custom-format id>
                    #   name:   <custom-format name>
                    #   score:  <integer>
                    #
                    # Retain compatibility with any nested format object a future
                    # or older API might return without relying on StrictMode-unsafe
                    # direct property access.
                    $formatId = $null
                    $formatName = $null

                    if ($null -ne $flatFormatId -and $flatFormatId -isnot [System.Management.Automation.PSCustomObject]) {
                        $parsedFormatId = 0
                        if ([int]::TryParse([string]$flatFormatId, [ref]$parsedFormatId)) {
                            $formatId = $parsedFormatId
                        }
                    }
                    elseif ($null -ne $flatFormatId) {
                        $nestedId = Get-PropertyValue -Object $flatFormatId -Name "id"
                        $nestedName = Get-PropertyValue -Object $flatFormatId -Name "name"
                        $parsedNestedId = 0
                        if ($null -ne $nestedId -and [int]::TryParse([string]$nestedId, [ref]$parsedNestedId)) {
                            $formatId = $parsedNestedId
                        }
                        if ($null -ne $nestedName) {
                            $formatName = [string]$nestedName
                        }
                    }

                    if ($null -ne $flatName -and -not [string]::IsNullOrWhiteSpace([string]$flatName)) {
                        $formatName = [string]$flatName
                    }

                    [pscustomobject][ordered]@{
                        format = $formatName
                        formatId = $formatId
                        score = [int]$scoreValue
                    }
                }
            )
        }

        $result.status = "OK"
        $result.qualityProfileId = $profileId
        $result.qualityProfileName = [string](Get-PropertyValue -Object $profile -Name "name" -Default "")
        $result.upgradeAllowed = Get-PropertyValue -Object $profile -Name "upgradeAllowed"
        $result.cutoff = Get-PropertyValue -Object $profile -Name "cutoff"
        $result.minFormatScore = Get-PropertyValue -Object $profile -Name "minFormatScore"
        $result.cutoffFormatScore = Get-PropertyValue -Object $profile -Name "cutoffFormatScore"
        $result.formatScores = @($formatScores)

        return [pscustomobject]$result
    }
    catch {
        $result.status = "API_ERROR"
        $result.error = $_.Exception.Message
        return [pscustomobject]$result
    }
}

function Build-NormalizedContext {
    param(
        [Parameter(Mandatory = $true)][string]$EventId,
        [Parameter(Mandatory = $true)][string]$EventType,
        [Parameter(Mandatory = $true)][string]$MediaPath
    )

    if ($Source -eq "Radarr") {
        $entityId = Get-EnvironmentValue "radarr_movie_id"
        $profile = Get-ProfileEnrichment -EntityId $entityId

        return [pscustomobject][ordered]@{
            schemaVersion = "1.0"
            bridgeVersion = $BridgeVersion
            eventId = $EventId
            source = "Radarr"
            eventType = $EventType
            libraryType = "Movie"
            entity = [ordered]@{
                type = "movie"
                id = To-NullableInt $entityId
                title = Get-EnvironmentValue "radarr_movie_title"
                year = To-NullableInt (Get-EnvironmentValue "radarr_movie_year")
                originalLanguage = Get-EnvironmentValue "radarr_movie_originallanguage"
                path = Get-EnvironmentValue "radarr_movie_path"
                imdbId = Get-EnvironmentValue "radarr_movie_imdbid"
                tmdbId = To-NullableInt (Get-EnvironmentValue "radarr_movie_tmdbid")
                tags = @(Split-PipeList (Get-EnvironmentValue "radarr_movie_tags"))
            }
            file = [ordered]@{
                id = To-NullableInt (Get-EnvironmentValue "radarr_moviefile_id")
                path = $MediaPath
                relativePath = Get-EnvironmentValue "radarr_moviefile_relativepath"
                quality = Get-EnvironmentValue "radarr_moviefile_quality"
                qualityVersion = To-NullableInt (Get-EnvironmentValue "radarr_moviefile_qualityversion")
                releaseGroup = Get-EnvironmentValue "radarr_moviefile_releasegroup"
                sceneName = Get-EnvironmentValue "radarr_moviefile_scenename"
                customFormats = @(Split-PipeList (Get-EnvironmentValue "radarr_moviefile_customformat"))
                customFormatScore = To-NullableInt (Get-EnvironmentValue "radarr_moviefile_customformatscore")
                mediaInfo = [ordered]@{
                    width = To-NullableInt (Get-EnvironmentValue "radarr_moviefile_mediainfo_width")
                    height = To-NullableInt (Get-EnvironmentValue "radarr_moviefile_mediainfo_height")
                    videoCodec = Get-EnvironmentValue "radarr_moviefile_mediainfo_videocodec"
                    dynamicRangeType = Get-EnvironmentValue "radarr_moviefile_mediainfo_videodynamicrangetype"
                    audioCodec = Get-EnvironmentValue "radarr_moviefile_mediainfo_audiocodec"
                    audioChannels = Get-EnvironmentValue "radarr_moviefile_mediainfo_audiochannels"
                    audioLanguages = @(Split-SlashList (Get-EnvironmentValue "radarr_moviefile_mediainfo_audiolanguages"))
                    languages = @(Split-SlashList (Get-EnvironmentValue "radarr_moviefile_mediainfo_languages"))
                    subtitles = @(Split-SlashList (Get-EnvironmentValue "radarr_moviefile_mediainfo_subtitles"))
                }
            }
            release = [ordered]@{
                title = Get-EnvironmentValue "radarr_release_title"
                indexer = Get-EnvironmentValue "radarr_release_indexer"
                sizeBytes = To-NullableInt64 (Get-EnvironmentValue "radarr_release_size")
                downloadClient = Get-EnvironmentValue "radarr_download_client"
                downloadClientType = Get-EnvironmentValue "radarr_download_client_type"
                downloadId = Get-EnvironmentValue "radarr_download_id"
                isUpgrade = To-NullableBool (Get-EnvironmentValue "radarr_isupgrade")
                sourceFolder = Get-EnvironmentValue "radarr_moviefile_sourcefolder"
                sourcePath = Get-EnvironmentValue "radarr_moviefile_sourcepath"
            }
            profile = $profile
        }
    }

    $entityId = Get-EnvironmentValue "sonarr_series_id"
    $profile = Get-ProfileEnrichment -EntityId $entityId

    return [pscustomobject][ordered]@{
        schemaVersion = "1.0"
        bridgeVersion = $BridgeVersion
        eventId = $EventId
        source = "Sonarr"
        eventType = $EventType
        libraryType = "TV"
        entity = [ordered]@{
            type = "series"
            id = To-NullableInt $entityId
            title = Get-EnvironmentValue "sonarr_series_title"
            year = To-NullableInt (Get-EnvironmentValue "sonarr_series_year")
            originalLanguage = Get-EnvironmentValue "sonarr_series_originallanguage"
            path = Get-EnvironmentValue "sonarr_series_path"
            imdbId = Get-EnvironmentValue "sonarr_series_imdbid"
            tmdbId = To-NullableInt (Get-EnvironmentValue "sonarr_series_tmdbid")
            tvdbId = To-NullableInt (Get-EnvironmentValue "sonarr_series_tvdbid")
            tvMazeId = To-NullableInt (Get-EnvironmentValue "sonarr_series_tvmazeid")
            seriesType = Get-EnvironmentValue "sonarr_series_type"
            tags = @(Split-PipeList (Get-EnvironmentValue "sonarr_series_tags"))
        }
        episode = [ordered]@{
            ids = @(Split-PipeList (Get-EnvironmentValue "sonarr_episodefile_episodeids"))
            seasonNumber = To-NullableInt (Get-EnvironmentValue "sonarr_episodefile_seasonnumber")
            episodeNumbers = @(Split-PipeList (Get-EnvironmentValue "sonarr_episodefile_episodenumbers"))
            titles = @(Split-PipeList (Get-EnvironmentValue "sonarr_episodefile_episodetitles"))
            count = To-NullableInt (Get-EnvironmentValue "sonarr_episodefile_episodecount")
        }
        file = [ordered]@{
            id = To-NullableInt (Get-EnvironmentValue "sonarr_episodefile_id")
            path = $MediaPath
            relativePath = Get-EnvironmentValue "sonarr_episodefile_relativepath"
            quality = Get-EnvironmentValue "sonarr_episodefile_quality"
            qualityVersion = To-NullableInt (Get-EnvironmentValue "sonarr_episodefile_qualityversion")
            releaseGroup = Get-EnvironmentValue "sonarr_episodefile_releasegroup"
            sceneName = Get-EnvironmentValue "sonarr_episodefile_scenename"
            customFormats = @(Split-PipeList (Get-EnvironmentValue "sonarr_episodefile_customformat"))
            customFormatScore = To-NullableInt (Get-EnvironmentValue "sonarr_episodefile_customformatscore")
            mediaInfo = [ordered]@{
                width = To-NullableInt (Get-EnvironmentValue "sonarr_episodefile_mediainfo_width")
                height = To-NullableInt (Get-EnvironmentValue "sonarr_episodefile_mediainfo_height")
                videoCodec = Get-EnvironmentValue "sonarr_episodefile_mediainfo_videocodec"
                dynamicRangeType = Get-EnvironmentValue "sonarr_episodefile_mediainfo_videodynamicrangetype"
                audioCodec = Get-EnvironmentValue "sonarr_episodefile_mediainfo_audiocodec"
                audioChannels = Get-EnvironmentValue "sonarr_episodefile_mediainfo_audiochannels"
                audioLanguages = @(Split-SlashList (Get-EnvironmentValue "sonarr_episodefile_mediainfo_audiolanguages"))
                languages = @(Split-SlashList (Get-EnvironmentValue "sonarr_episodefile_mediainfo_languages"))
                subtitles = @(Split-SlashList (Get-EnvironmentValue "sonarr_episodefile_mediainfo_subtitles"))
            }
        }
        release = [ordered]@{
            title = Get-EnvironmentValue "sonarr_release_title"
            indexer = Get-EnvironmentValue "sonarr_release_indexer"
            releaseType = Get-EnvironmentValue "sonarr_release_releasetype"
            sizeBytes = To-NullableInt64 (Get-EnvironmentValue "sonarr_release_size")
            downloadClient = Get-EnvironmentValue "sonarr_download_client"
            downloadClientType = Get-EnvironmentValue "sonarr_download_client_type"
            downloadId = Get-EnvironmentValue "sonarr_download_id"
            isUpgrade = To-NullableBool (Get-EnvironmentValue "sonarr_isupgrade")
            sourceFolder = Get-EnvironmentValue "sonarr_episodefile_sourcefolder"
            sourcePath = Get-EnvironmentValue "sonarr_episodefile_sourcepath"
        }
        profile = $profile
    }
}

function Quote-ProcessArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-ValidatorProcess {
    param(
        [Parameter(Mandatory = $true)][string]$MediaPath,
        [Parameter(Mandatory = $true)][string]$LibraryType,
        [Parameter(Mandatory = $true)][string]$JsonOutPath,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath
    )

    $powerShellExe = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
        $powerShellExe = "powershell.exe"
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ValidatorPath,
        $MediaPath,
        "-LibraryType", $LibraryType,
        "-PolicyPath", $PolicyPath,
        "-JsonOut", $JsonOutPath,
        "-OutputFormat", "Json",
        "-ExitZero"
    )

    $argumentString = (@($arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) })) -join " "

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellExe
    $startInfo.Arguments = $argumentString
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $processExitCode = $process.ExitCode
    $process.Dispose()

    $stdout | Set-Content -LiteralPath $StdoutPath -Encoding UTF8
    $stderr | Set-Content -LiteralPath $StderrPath -Encoding UTF8

    return $processExitCode
}


function Invoke-ContextValidatorProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ContextPath,
        [Parameter(Mandatory = $true)][string]$ValidatorResultPath,
        [Parameter(Mandatory = $true)][string]$JsonOutPath,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath
    )

    $powerShellExe = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
        $powerShellExe = "powershell.exe"
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ContextValidatorPath,
        "-ContextPath", $ContextPath,
        "-ValidatorResultPath", $ValidatorResultPath,
        "-JsonOut", $JsonOutPath,
        "-ExitZero"
    )

    $argumentString = (@($arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) })) -join " "

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellExe
    $startInfo.Arguments = $argumentString
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $processExitCode = $process.ExitCode
    $process.Dispose()

    $stdout | Set-Content -LiteralPath $StdoutPath -Encoding UTF8
    $stderr | Set-Content -LiteralPath $StderrPath -Encoding UTF8

    return $processExitCode
}


function Invoke-NormalizationPlannerProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ContextPath,
        [Parameter(Mandatory = $true)][string]$ValidatorResultPath,
        [string]$ContextualResultPath,
        [Parameter(Mandatory = $true)][string]$JsonOutPath,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath
    )

    $powerShellExe = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
        $powerShellExe = "powershell.exe"
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $NormalizationPlannerPath,
        "-ContextPath", $ContextPath,
        "-ValidatorResultPath", $ValidatorResultPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ContextualResultPath)) {
        $arguments += @("-ContextualResultPath", $ContextualResultPath)
    }

    $arguments += @("-JsonOut", $JsonOutPath)

    $argumentString = (@($arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) })) -join " "

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellExe
    $startInfo.Arguments = $argumentString
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $processExitCode = $process.ExitCode
    $process.Dispose()

    $stdout | Set-Content -LiteralPath $StdoutPath -Encoding UTF8
    $stderr | Set-Content -LiteralPath $StderrPath -Encoding UTF8

    return $processExitCode
}

Ensure-Directory $LogRoot
Ensure-Directory $EventRoot

$startedUtc = [DateTime]::UtcNow
$eventId = $startedUtc.ToString("yyyyMMddTHHmmssfffZ") + "-" + $Source.ToLowerInvariant() + "-" + ([Guid]::NewGuid().ToString("N").Substring(0, 8))
$dayDirectory = Join-Path $EventRoot $startedUtc.ToString("yyyy-MM-dd")
$eventDirectory = Join-Path $dayDirectory $eventId
Ensure-Directory $dayDirectory
Ensure-Directory $eventDirectory

try {
    $environment = Get-EnvironmentSnapshot -VariablePrefix $Prefix
    $environmentPath = Join-Path $eventDirectory "environment.json"
    $environment | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $environmentPath -Encoding UTF8

    if ($Source -eq "Radarr") {
        $eventType = Get-EnvironmentValue "radarr_eventtype"
        $mediaPath = Get-EnvironmentValue "radarr_moviefile_path"
        $libraryType = "Movie"
    }
    else {
        $eventType = Get-EnvironmentValue "sonarr_eventtype"
        $mediaPath = Get-EnvironmentValue "sonarr_episodefile_path"
        $libraryType = "TV"
    }

    $record = [ordered]@{
        schemaVersion = "1.5"
        bridgeVersion = $BridgeVersion
        eventId = $eventId
        source = $Source
        eventType = $eventType
        startedUtc = $startedUtc.ToString("o")
        completedUtc = $null
        importedPath = if ([string]::IsNullOrWhiteSpace($mediaPath)) { $null } else { $mediaPath }
        libraryType = $libraryType
        status = "RECEIVED"
        profileStatus = $null
        qualityProfileId = $null
        qualityProfileName = $null
        contextFile = $null
        validator = $null
        contextual = $null
        effectiveOutcome = $null
        normalizationPlan = $null
        normalizationQueue = $null
        environmentFile = $environmentPath
        eventDirectory = $eventDirectory
    }

    if ([string]::IsNullOrWhiteSpace($mediaPath)) {
        $record.status = "NO_MEDIA_PATH"
        $record.completedUtc = [DateTime]::UtcNow.ToString("o")
        Write-JsonLine -Object ([pscustomobject]$record) -Path $MainLogPath
        ([pscustomobject]$record) | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $eventDirectory "bridge-result.json") -Encoding UTF8
        exit 0
    }

    if (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) {
        $record.status = "MEDIA_PATH_NOT_FOUND"
        $record.completedUtc = [DateTime]::UtcNow.ToString("o")
        Write-JsonLine -Object ([pscustomobject]$record) -Path $MainLogPath
        ([pscustomobject]$record) | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $eventDirectory "bridge-result.json") -Encoding UTF8
        exit 0
    }

    if (-not (Test-Path -LiteralPath $ValidatorPath -PathType Leaf)) {
        throw "MediaValidator.ps1 was not found at expected path: $ValidatorPath"
    }

    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
        throw "validator-policy.json was not found at expected path: $PolicyPath"
    }

    if (-not (Test-Path -LiteralPath $ContextValidatorPath -PathType Leaf)) {
        throw "ContextValidator.ps1 was not found at expected path: $ContextValidatorPath"
    }

    if (-not (Test-Path -LiteralPath $NormalizationPlannerPath -PathType Leaf)) {
        throw "NormalizationPlanner.ps1 was not found at expected path: $NormalizationPlannerPath"
    }

    if (-not (Test-Path -LiteralPath $QueueCommonPath -PathType Leaf)) {
        throw "QueueCommon.ps1 was not found at expected path: $QueueCommonPath"
    }

    . $QueueCommonPath

    $context = Build-NormalizedContext -EventId $eventId -EventType $eventType -MediaPath $mediaPath
    $contextPath = Join-Path $eventDirectory "context.json"
    $context | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $contextPath -Encoding UTF8

    $record.contextFile = $contextPath
    $record.profileStatus = $context.profile.status
    $record.qualityProfileId = $context.profile.qualityProfileId
    $record.qualityProfileName = $context.profile.qualityProfileName

    $validatorJsonPath = Join-Path $eventDirectory "validator-result.json"
    $validatorStdoutPath = Join-Path $eventDirectory "validator-stdout.txt"
    $validatorStderrPath = Join-Path $eventDirectory "validator-stderr.txt"

    $childExitCode = Invoke-ValidatorProcess `
        -MediaPath $mediaPath `
        -LibraryType $libraryType `
        -JsonOutPath $validatorJsonPath `
        -StdoutPath $validatorStdoutPath `
        -StderrPath $validatorStderrPath

    if (Test-Path -LiteralPath $validatorJsonPath -PathType Leaf) {
        $validatorResult = Get-Content -LiteralPath $validatorJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $findingCodes = @($validatorResult.findings | ForEach-Object { $_.code })

        $record.status = "VALIDATED"
        $record.validator = [ordered]@{
            outcome = [string]$validatorResult.outcome
            validatorVersion = [string]$validatorResult.validatorVersion
            validatorExitCode = [int]$validatorResult.exitCode
            processExitCode = [int]$childExitCode
            findingCodes = @($findingCodes)
            resultFile = $validatorJsonPath
            stdoutFile = $validatorStdoutPath
            stderrFile = $validatorStderrPath
        }

        $contextualJsonPath = Join-Path $eventDirectory "contextual-result.json"
        $contextualStdoutPath = Join-Path $eventDirectory "contextual-stdout.txt"
        $contextualStderrPath = Join-Path $eventDirectory "contextual-stderr.txt"

        $contextualProcessExitCode = Invoke-ContextValidatorProcess `
            -ContextPath $contextPath `
            -ValidatorResultPath $validatorJsonPath `
            -JsonOutPath $contextualJsonPath `
            -StdoutPath $contextualStdoutPath `
            -StderrPath $contextualStderrPath

        if (Test-Path -LiteralPath $contextualJsonPath -PathType Leaf) {
            $contextualResult = Get-Content -LiteralPath $contextualJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $contextualFindingCodes = @($contextualResult.findings | ForEach-Object { $_.code })

            $record.contextual = [ordered]@{
                status = [string]$contextualResult.status
                reason = $contextualResult.reason
                outcome = $contextualResult.outcome
                contextValidatorVersion = [string]$contextualResult.contextValidatorVersion
                preferredLanguage = $contextualResult.preferredLanguage
                policyMode = $contextualResult.policyMode
                processExitCode = [int]$contextualProcessExitCode
                findingCodes = @($contextualFindingCodes)
                resultFile = $contextualJsonPath
                stdoutFile = $contextualStdoutPath
                stderrFile = $contextualStderrPath
            }

            if ([string]$contextualResult.status -eq "APPLIED" -and $null -ne $contextualResult.outcome) {
                $record.effectiveOutcome = Get-HigherOutcome `
                    -First ([string]$validatorResult.outcome) `
                    -Second ([string]$contextualResult.outcome)
            }
            else {
                $record.effectiveOutcome = [string]$validatorResult.outcome
            }
        }
        else {
            $record.contextual = [ordered]@{
                status = "NO_RESULT"
                processExitCode = [int]$contextualProcessExitCode
                stdoutFile = $contextualStdoutPath
                stderrFile = $contextualStderrPath
            }
            $record.effectiveOutcome = [string]$validatorResult.outcome
        }
    }
    else {
        $record.status = "VALIDATOR_NO_RESULT"
        $record.validator = [ordered]@{
            processExitCode = [int]$childExitCode
            stdoutFile = $validatorStdoutPath
            stderrFile = $validatorStderrPath
        }
    }

    if ($record.status -eq "VALIDATED") {
        $planJsonPath = Join-Path $eventDirectory "normalization-plan.json"
        $planStdoutPath = Join-Path $eventDirectory "normalization-planner-stdout.txt"
        $planStderrPath = Join-Path $eventDirectory "normalization-planner-stderr.txt"

        $contextualPathForPlanner = ""
        if ($null -ne $record.contextual) {
            # $record.contextual is an OrderedDictionary. Its dictionary keys
            # are accessible by indexer/dot notation, but they are not reliably
            # exposed through PSObject.Properties. The v0.4.0/v0.4.1 check used
            # PSObject.Properties and therefore silently failed to pass the
            # contextual result into the normalization planner.
            $contextualResultFile = $null

            if ($record.contextual -is [System.Collections.IDictionary]) {
                if ($record.contextual.Contains("resultFile")) {
                    $contextualResultFile = $record.contextual["resultFile"]
                }
            }
            else {
                $resultFileProperty = $record.contextual.PSObject.Properties["resultFile"]
                if ($null -ne $resultFileProperty) {
                    $contextualResultFile = $resultFileProperty.Value
                }
            }

            if ($null -ne $contextualResultFile -and
                -not [string]::IsNullOrWhiteSpace([string]$contextualResultFile)) {
                $contextualPathForPlanner = [string]$contextualResultFile
            }
        }

        $plannerExitCode = Invoke-NormalizationPlannerProcess `
            -ContextPath $contextPath `
            -ValidatorResultPath $validatorJsonPath `
            -ContextualResultPath $contextualPathForPlanner `
            -JsonOutPath $planJsonPath `
            -StdoutPath $planStdoutPath `
            -StderrPath $planStderrPath

        if (Test-Path -LiteralPath $planJsonPath -PathType Leaf) {
            $planResult = Get-Content -LiteralPath $planJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $record.normalizationPlan = [ordered]@{
                status = [string]$planResult.status
                reason = $planResult.reason
                plannerVersion = [string]$planResult.plannerVersion
                actionCount = @($planResult.actions).Count
                processExitCode = [int]$plannerExitCode
                resultFile = $planJsonPath
                stdoutFile = $planStdoutPath
                stderrFile = $planStderrPath
            }

            if ([string]$planResult.status -eq "PLANNED") {
                try {
                    $queueResult = Enqueue-NormalizationPlan `
                        -IntegrationRoot $IntegrationRoot `
                        -PlanPath $planJsonPath `
                        -Source $Source `
                        -EventId $eventId

                    $workerStart = $null
                    if ([string]$queueResult.status -eq "ENQUEUED") {
                        $workerStart = Start-NormalizationQueueWorker -IntegrationRoot $IntegrationRoot
                    }

                    $record.normalizationQueue = [ordered]@{
                        status = [string]$queueResult.status
                        reason = $queueResult.reason
                        jobId = $queueResult.jobId
                        jobFile = $queueResult.jobFile
                        queueMode = $queueResult.queueMode
                        requestedMode = if ($queueResult.PSObject.Properties["requestedMode"]) { $queueResult.requestedMode } else { $null }
                        configStatus = if ($queueResult.PSObject.Properties["configStatus"]) { $queueResult.configStatus } else { $null }
                        existingState = if ($queueResult.PSObject.Properties["existingState"]) { $queueResult.existingState } else { $null }
                        workerStarted = if ($null -ne $workerStart) { [bool]$workerStart.started } else { $false }
                        workerProcessId = if ($null -ne $workerStart) { $workerStart.processId } else { $null }
                        workerStartReason = if ($null -ne $workerStart) { $workerStart.reason } else { $null }
                    }
                }
                catch {
                    # Queue automation is intentionally non-blocking. Validation
                    # results remain authoritative and the Arr import must not fail
                    # because queueing or worker startup encountered an error.
                    $record.normalizationQueue = [ordered]@{
                        status = "QUEUE_ERROR"
                        reason = $_.Exception.Message
                        jobId = $null
                        jobFile = $null
                        queueMode = "AUTO_DRY_RUN"
                        requestedMode = $null
                        configStatus = "QUEUE_ERROR_FAIL_CLOSED"
                        workerStarted = $false
                    }

                    Add-Content -LiteralPath $ErrorLogPath -Value (
                        "{0} [{1}] {2}: normalization queue error: {3}" -f
                        ([DateTime]::UtcNow.ToString("o")),
                        $Source,
                        $eventId,
                        $_.Exception.Message
                    ) -Encoding UTF8
                }
            }
        }
        else {
            $record.normalizationPlan = [ordered]@{
                status = "NO_RESULT"
                processExitCode = [int]$plannerExitCode
                stdoutFile = $planStdoutPath
                stderrFile = $planStderrPath
            }
        }
    }

    $record.completedUtc = [DateTime]::UtcNow.ToString("o")
    Write-JsonLine -Object ([pscustomobject]$record) -Path $MainLogPath
    ([pscustomobject]$record) | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $eventDirectory "bridge-result.json") -Encoding UTF8

    # Observational only: validation or enrichment findings never fail the import.
    exit 0
}
catch {
    $message = "{0} [{1}] {2}: {3}" -f ([DateTime]::UtcNow.ToString("o")), $Source, $eventId, $_.Exception.Message
    Add-Content -LiteralPath $ErrorLogPath -Value $message -Encoding UTF8

    try {
        $failure = [pscustomobject][ordered]@{
            schemaVersion = "1.5"
            bridgeVersion = $BridgeVersion
            eventId = $eventId
            source = $Source
            eventType = ""
            startedUtc = $startedUtc.ToString("o")
            completedUtc = [DateTime]::UtcNow.ToString("o")
            importedPath = $null
            libraryType = if ($Source -eq "Radarr") { "Movie" } else { "TV" }
            status = "BRIDGE_ERROR"
            error = $_.Exception.Message
            eventDirectory = $eventDirectory
        }
        Write-JsonLine -Object $failure -Path $MainLogPath
        $failure | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $eventDirectory "bridge-result.json") -Encoding UTF8
    }
    catch {
        # Last-resort: do not let logging failure break the media import.
    }

    exit 0
}
