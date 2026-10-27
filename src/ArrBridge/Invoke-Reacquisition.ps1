[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlanPath,

    [string]$JsonOut = "",

    [switch]$Execute,

    [string]$ConfirmLoopKey = "",

    [switch]$Recover,

    [switch]$SuppressNativeRedownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ExecutorVersion = "0.2.9"
$IntegrationRoot = $PSScriptRoot
$ValidatorRoot = Split-Path -Parent $IntegrationRoot
$ValidatorPath = Join-Path $ValidatorRoot "MediaValidator.ps1"
$PolicyPath = Join-Path $ValidatorRoot "validator-policy.json"
$ContextValidatorPath = Join-Path $IntegrationRoot "ContextValidator.ps1"
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"
$WorkRoot = Join-Path $IntegrationRoot "Reacquisition\work"
$StateRoot = Join-Path $IntegrationRoot "Reacquisition\state"
$SonarrCommonPath = Join-Path $IntegrationRoot "SonarrReacquisitionCommon.ps1"

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

function Normalize-ReacquisitionIdentityTitle {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }

    $normalized = $Value.Trim().ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, '[\s\.\-_]+', ' ')
    $normalized = [regex]::Replace($normalized, '[^a-z0-9+ ]', '')
    $normalized = [regex]::Replace($normalized, '\s+', ' ')
    return $normalized.Trim()
}

function Quote-ProcessArgument {
    param([string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-CapturedProcess {
    param(
        [string]$FileName,
        [object[]]$Arguments,
        [string]$StdoutPath,
        [string]$StderrPath
    )

    $argumentString = (@($Arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) })) -join " "

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FileName
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
    $exitCode = $process.ExitCode
    $process.Dispose()

    $stdout | Set-Content -LiteralPath $StdoutPath -Encoding UTF8
    $stderr | Set-Content -LiteralPath $StderrPath -Encoding UTF8

    return [pscustomobject]@{
        exitCode = $exitCode
        stdout = $stdout
        stderr = $stderr
    }
}

function Get-ArrConnection {
    param([ValidateSet("Radarr", "Sonarr")][string]$Source)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Integration config not found: $ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $section = Get-PropertyValue -Object $config -Name $Source.ToLowerInvariant()

    $baseUrl = [string](Get-PropertyValue -Object $section -Name "baseUrl" -Default "")
    $apiKey = [string](Get-PropertyValue -Object $section -Name "apiKey" -Default "")

    if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) {
        throw "$Source integration config requires baseUrl and apiKey."
    }

    return [pscustomobject]@{
        baseUrl = $baseUrl.TrimEnd("/")
        apiKey = $apiKey
    }
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

function Test-AutomaticEscalationPlan {
    param($Plan)

    $auto = Get-PropertyValue -Object $Plan -Name "automaticEscalation" -Default $null
    if ($null -eq $auto) {
        return [pscustomobject]@{ present=$false; valid=$false; reason=$null }
    }

    $type = [string](Get-PropertyValue -Object $auto -Name "type" -Default "")
    $from = [string](Get-PropertyValue -Object $auto -Name "from" -Default "")
    $to = [string](Get-PropertyValue -Object $auto -Name "to" -Default "")
    $reason = [string](Get-PropertyValue -Object $auto -Name "reason" -Default "")
    $detected = [string](Get-PropertyValue -Object $Plan -Name "detectedEffectiveOutcome" -Default "")
    $effective = [string](Get-PropertyValue -Object $Plan -Name "effectiveOutcome" -Default "")
    $allowedReason = $reason -in @(
        "multiple_preferred_audio_candidates",
        "ambiguous_default_audio_target",
        "preferred_audio_candidate_missing",
        "container_not_supported"
    )

    $valid = (
        $type -eq "NORMALIZATION_NOT_SAFELY_ACTIONABLE" -and
        $from -eq "NORMALIZE" -and
        $to -eq "REACQUIRE" -and
        $detected -eq "NORMALIZE" -and
        $effective -eq "REACQUIRE" -and
        $allowedReason
    )

    return [pscustomobject]@{ present=$true; valid=$valid; reason=$reason }
}

function Get-FindingCodes {
    param($Result)

    return @(
        @(Get-PropertyValue -Object $Result -Name "findings" -Default @()) |
            ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "code" -Default "") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-HistoryImportedPath {
    param($HistoryRecord)

    $data = Get-PropertyValue -Object $HistoryRecord -Name "data"
    if ($null -eq $data) { return "" }
    return [string](Get-PropertyValue -Object $data -Name "importedPath" -Default "")
}

function Get-HistoryFileId {
    param($HistoryRecord)

    $data = Get-PropertyValue -Object $HistoryRecord -Name "data"
    if ($null -eq $data) { return 0 }

    $raw = Get-PropertyValue -Object $data -Name "fileId" -Default $null
    if ($null -eq $raw) {
        $raw = Get-PropertyValue -Object $data -Name "FileId" -Default $null
    }
    if ($null -eq $raw) {
        $raw = Get-PropertyValue -Object $data -Name "movieFileId" -Default $null
    }
    if ($null -eq $raw) {
        $raw = Get-PropertyValue -Object $data -Name "episodeFileId" -Default $null
    }

    $parsed = 0
    if ([int]::TryParse([string]$raw, [ref]$parsed)) {
        return $parsed
    }

    return 0
}


function ConvertTo-RecordArray {
    param($Response)

    if ($null -eq $Response) {
        return @()
    }

    $records = Get-PropertyValue -Object $Response -Name "records" -Default $null
    if ($null -ne $records) {
        return @($records)
    }

    return @($Response)
}

function Add-UniqueHistoryRecords {
    param(
        [System.Collections.ArrayList]$Target,
        [object[]]$Records
    )

    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }

        $id = [int](Get-PropertyValue -Object $record -Name "id" -Default 0)

        if ($id -gt 0) {
            $already = @(
                $Target |
                    Where-Object {
                        [int](Get-PropertyValue -Object $_ -Name "id" -Default 0) -eq $id
                    }
            ).Count -gt 0

            if ($already) { continue }
        }

        [void]$Target.Add($record)
    }
}

function Resolve-ReacquisitionImportHistoryMatch {
    param(
        [object[]]$ImportRecords,
        [int]$FileId,
        [string]$MediaPath,
        [string]$DownloadId,
        [string]$ReleaseTitle,
        [string]$SceneName
    )

    $records = @($ImportRecords)

    # Strongest match: Arr records the imported media-file ID in history data.
    $matches = @(
        $records |
            Where-Object {
                (Get-HistoryFileId $_) -eq $FileId
            }
    )
    $matchMethod = "fileId"

    if ($matches.Count -ne 1) {
        $matches = @(
            $records |
                Where-Object {
                    Test-PathEquivalent (Get-HistoryImportedPath $_) $MediaPath
                }
        )
        $matchMethod = "importedPath"
    }

    if ($matches.Count -ne 1 -and -not [string]::IsNullOrWhiteSpace($DownloadId)) {
        $matches = @(
            $records |
                Where-Object {
                    [string]::Equals(
                        [string](Get-PropertyValue -Object $_ -Name "downloadId" -Default ""),
                        $DownloadId,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
        $matchMethod = "downloadId"
    }

    $expectedSourceTitle = if (-not [string]::IsNullOrWhiteSpace($ReleaseTitle)) { $ReleaseTitle } else { $SceneName }

    if ($matches.Count -ne 1 -and -not [string]::IsNullOrWhiteSpace($expectedSourceTitle)) {
        $matches = @(
            $records |
                Where-Object {
                    [string]::Equals(
                        [string](Get-PropertyValue -Object $_ -Name "sourceTitle" -Default ""),
                        $expectedSourceTitle,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
        $matchMethod = "sourceTitle"
    }

    # Arr/download-client history can preserve the same release identity with
    # punctuation or separator differences (dots, spaces, underscores, dashes).
    # If raw sourceTitle equality found nothing, accept only a UNIQUE normalized
    # sourceTitle match. Zero matches still fail closed; multiple logical matches
    # remain ambiguous and are rejected by the caller.
    if ($matches.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($expectedSourceTitle)) {
        $expectedSourceTitleNormalized = Normalize-ReacquisitionIdentityTitle $expectedSourceTitle
        if (-not [string]::IsNullOrWhiteSpace($expectedSourceTitleNormalized)) {
            $matches = @(
                $records |
                    Where-Object {
                        $candidateSourceTitle = [string](Get-PropertyValue -Object $_ -Name "sourceTitle" -Default "")
                        (Normalize-ReacquisitionIdentityTitle $candidateSourceTitle) -eq $expectedSourceTitleNormalized
                    }
            )
            $matchMethod = "sourceTitleNormalized"
        }
    }

    return [pscustomobject]@{
        matches = @($matches)
        matchMethod = $matchMethod
    }
}

function Write-Result {
    param($Result)

    if (-not [string]::IsNullOrWhiteSpace($JsonOut)) {
        $Result | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    }

    $Result | ConvertTo-Json -Depth 50
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
        $Object | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ReacquisitionState {
    param(
        [string]$LoopKey,
        [int]$MaxAttempts
    )

    if (-not (Test-Path -LiteralPath $StateRoot)) {
        New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    }

    $path = Join-Path $StateRoot ($LoopKey + ".json")

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{
            path = $path
            state = $state
        }
    }

    $state = [pscustomobject][ordered]@{
        schemaVersion = "1.0"
        loopKey = $LoopKey
        maxAutomaticAttempts = $MaxAttempts
        createdUtc = [DateTime]::UtcNow.ToString("o")
        updatedUtc = [DateTime]::UtcNow.ToString("o")
        attempts = @()
    }

    return [pscustomobject]@{
        path = $path
        state = $state
    }
}

function Set-StateAttempt {
    param(
        [Parameter(Mandatory = $true)]$StateRecord,
        [Parameter(Mandatory = $true)]$Attempt
    )

    $attempts = @($StateRecord.state.attempts)

    $existingIndex = -1
    for ($i = 0; $i -lt $attempts.Count; $i++) {
        if ([string]$attempts[$i].attemptId -eq [string]$Attempt.attemptId) {
            $existingIndex = $i
            break
        }
    }

    if ($existingIndex -ge 0) {
        $attempts[$existingIndex] = $Attempt
    }
    else {
        $attempts += $Attempt
    }

    $StateRecord.state.attempts = @($attempts)
    $StateRecord.state.updatedUtc = [DateTime]::UtcNow.ToString("o")
    Write-AtomicJson -Path $StateRecord.path -Object $StateRecord.state
}

function Get-EntityHistoryRecords {
    param(
        [string]$Source,
        [int]$EntityId,
        $Connection,
        $Headers
    )

    $uri = if ($Source -eq "Radarr") {
        $Connection.baseUrl + "/api/v3/history/movie?movieId=$EntityId&includeMovie=false"
    }
    else {
        $Connection.baseUrl + "/api/v3/history/series?seriesId=$EntityId&includeSeries=false"
    }

    $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get -TimeoutSec 30
    return @(ConvertTo-RecordArray -Response $response)
}

function Test-MatchingFailedHistory {
    param(
        [object[]]$Records,
        [string]$DownloadId,
        [string]$SourceTitle
    )

    $matches = @(
        $Records |
            Where-Object {
                $eventType = [string](Get-PropertyValue -Object $_ -Name "eventType" -Default "")
                if (-not [string]::Equals($eventType, "downloadFailed", [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $false
                }

                $recordDownloadId = [string](Get-PropertyValue -Object $_ -Name "downloadId" -Default "")
                $recordSourceTitle = [string](Get-PropertyValue -Object $_ -Name "sourceTitle" -Default "")

                return (
                    -not [string]::IsNullOrWhiteSpace($DownloadId) -and
                    [string]::Equals($recordDownloadId, $DownloadId, [System.StringComparison]::OrdinalIgnoreCase)
                ) -or (
                    -not [string]::IsNullOrWhiteSpace($SourceTitle) -and
                    [string]::Equals($recordSourceTitle, $SourceTitle, [System.StringComparison]::OrdinalIgnoreCase)
                )
            }
    )

    return @($matches)
}


function Get-HistoryDataValue {
    param(
        $HistoryRecord,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    $data = Get-PropertyValue -Object $HistoryRecord -Name "data"
    if ($null -eq $data) { return $Default }

    return Get-PropertyValue -Object $data -Name $Name -Default $Default
}

function Test-MatchingFailedHistoryAfter {
    param(
        [object[]]$Records,
        [string]$DownloadId,
        [string]$SourceTitle,
        [DateTime]$NotBeforeUtc
    )

    # Radarr serializes history dates at whole-second precision while Reqestra
    # persists attempt timestamps with fractional seconds. Normalize the lower
    # bound to the same precision so an event created during the same second as
    # the POST is not incorrectly treated as older than the attempt.
    $thresholdUtc = $NotBeforeUtc.ToUniversalTime()
    $thresholdUtc = $thresholdUtc.AddTicks(
        -($thresholdUtc.Ticks % [TimeSpan]::TicksPerSecond)
    )

    $matches = @(
        Test-MatchingFailedHistory `
            -Records $Records `
            -DownloadId $DownloadId `
            -SourceTitle $SourceTitle |
            Where-Object {
                $dateText = [string](Get-PropertyValue -Object $_ -Name "date" -Default "")
                if ([string]::IsNullOrWhiteSpace($dateText)) {
                    return $false
                }

                try {
                    $date = [DateTime]::Parse(
                        $dateText,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind
                    ).ToUniversalTime()

                    return ($date -ge $thresholdUtc)
                }
                catch {
                    return $false
                }
            }
    )

    return @($matches)
}

function Test-MatchingBlocklistRecord {
    param(
        [object[]]$Records,
        [string]$DownloadId,
        [string]$SourceTitle
    )

    $matches = @(
        $Records |
            Where-Object {
                $recordDownloadId = [string](Get-PropertyValue -Object $_ -Name "downloadId" -Default "")
                $recordSourceTitle = [string](Get-PropertyValue -Object $_ -Name "sourceTitle" -Default "")

                return (
                    -not [string]::IsNullOrWhiteSpace($DownloadId) -and
                    [string]::Equals($recordDownloadId, $DownloadId, [System.StringComparison]::OrdinalIgnoreCase)
                ) -or (
                    -not [string]::IsNullOrWhiteSpace($SourceTitle) -and
                    [string]::Equals($recordSourceTitle, $SourceTitle, [System.StringComparison]::OrdinalIgnoreCase)
                )
            }
    )

    return @($matches)
}


. $SonarrCommonPath

$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json

$executionId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + [guid]::NewGuid().ToString("N").Substring(0,8)
$workDirectory = Join-Path $WorkRoot $executionId
New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null

$result = [ordered]@{
    schemaVersion = "1.0"
    executorVersion = $ExecutorVersion
    executionId = $executionId
    timestampUtc = [DateTime]::UtcNow.ToString("o")
    mode = if ($Execute) { "EXECUTE" } else { "DRY_RUN" }
    status = "BLOCKED"
    reason = $null
    planPath = $PlanPath
    mediaPath = [string](Get-PropertyValue -Object $plan -Name "mediaPath" -Default "")
    source = [string](Get-PropertyValue -Object $plan -Name "source" -Default "")
    sourceSnapshotMatches = $false
    streamFingerprintMatches = $false
    currentEffectiveOutcome = $null
    currentFindingCodes = @()
    automaticEscalation = $null
    arrFile = $null
    history = $null
    blocklist = $null
    proposedExecution = $null
    arrDownloadClientConfig = $null
    nativeRedownloadSuppression = $null
    executionGate = $null
    attemptState = $null
    verification = $null
    searchDelegatedToArr = $false
    mutatingRequestsSent = 0
    workDirectory = $workDirectory
}

try {
    if ([string](Get-PropertyValue -Object $plan -Name "status" -Default "") -ne "PLANNED") {
        $result.reason = "plan_not_planned"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if ($result.source -notin @("Radarr", "Sonarr")) {
        $result.reason = "unsupported_arr_source"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $automaticEscalationCheck = Test-AutomaticEscalationPlan -Plan $plan
    if ($automaticEscalationCheck.present) {
        $result.automaticEscalation = [ordered]@{
            valid = [bool]$automaticEscalationCheck.valid
            reason = [string]$automaticEscalationCheck.reason
        }
        if (-not $automaticEscalationCheck.valid) {
            $result.reason = "automatic_escalation_plan_invalid"
            Write-Result ([pscustomobject]$result)
            exit 0
        }
    }

    if (-not (Test-Path -LiteralPath $result.mediaPath -PathType Leaf)) {
        $result.reason = "current_media_missing"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $snapshot = Get-PropertyValue -Object $plan -Name "sourceSnapshot"
    $item = Get-Item -LiteralPath $result.mediaPath
    $expectedLength = [int64](Get-PropertyValue -Object $snapshot -Name "lengthBytes" -Default -1)
    $expectedLastWrite = [DateTime]::Parse(
        [string](Get-PropertyValue -Object $snapshot -Name "lastWriteTimeUtc" -Default ""),
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()

    $result.sourceSnapshotMatches = (
        [int64]$item.Length -eq $expectedLength -and
        $item.LastWriteTimeUtc -eq $expectedLastWrite
    )

    if (-not $result.sourceSnapshotMatches) {
        $result.reason = "source_snapshot_changed"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $sourceFiles = Get-PropertyValue -Object $plan -Name "sourceFiles"
    $contextPath = [string](Get-PropertyValue -Object $sourceFiles -Name "contextPath" -Default "")
    if ([string]::IsNullOrWhiteSpace($contextPath) -or -not (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
        $result.reason = "context_file_missing"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $libraryType = [string](Get-PropertyValue -Object $context -Name "libraryType" -Default "")
    $powerShellExe = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) { $powerShellExe = "powershell.exe" }

    $validatorJson = Join-Path $workDirectory "validator.json"
    $validatorStdout = Join-Path $workDirectory "validator-stdout.txt"
    $validatorStderr = Join-Path $workDirectory "validator-stderr.txt"

    $validatorArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ValidatorPath,
        $result.mediaPath,
        "-LibraryType", $libraryType,
        "-PolicyPath", $PolicyPath,
        "-JsonOut", $validatorJson,
        "-OutputFormat", "Json",
        "-ExitZero"
    )

    [void](Invoke-CapturedProcess -FileName $powerShellExe -Arguments $validatorArgs -StdoutPath $validatorStdout -StderrPath $validatorStderr)

    if (-not (Test-Path -LiteralPath $validatorJson -PathType Leaf)) {
        $result.reason = "validator_result_missing"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $validator = Get-Content -LiteralPath $validatorJson -Raw -Encoding UTF8 | ConvertFrom-Json

    $contextualJson = Join-Path $workDirectory "contextual.json"
    $contextualStdout = Join-Path $workDirectory "contextual-stdout.txt"
    $contextualStderr = Join-Path $workDirectory "contextual-stderr.txt"

    $contextualArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ContextValidatorPath,
        "-ContextPath", $contextPath,
        "-ValidatorResultPath", $validatorJson,
        "-JsonOut", $contextualJson,
        "-ExitZero"
    )

    [void](Invoke-CapturedProcess -FileName $powerShellExe -Arguments $contextualArgs -StdoutPath $contextualStdout -StderrPath $contextualStderr)

    $contextual = $null
    if (Test-Path -LiteralPath $contextualJson -PathType Leaf) {
        $contextual = Get-Content -LiteralPath $contextualJson -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $genericOutcome = [string](Get-PropertyValue -Object $validator -Name "outcome" -Default "PASS")
    $contextualOutcome = "PASS"
    if ($null -ne $contextual -and [string](Get-PropertyValue -Object $contextual -Name "status" -Default "") -eq "APPLIED") {
        $contextualOutcome = [string](Get-PropertyValue -Object $contextual -Name "outcome" -Default "PASS")
    }

    $result.currentEffectiveOutcome = Get-HigherOutcome $genericOutcome $contextualOutcome
    $result.currentFindingCodes = @(
        @(Get-FindingCodes $validator) + @(Get-FindingCodes $contextual) |
            Sort-Object -Unique
    )

    $expectedFingerprint = [string](Get-PropertyValue -Object $snapshot -Name "streamFingerprint" -Default "")
    $actualFingerprint = Get-StreamFingerprint -ValidatorResult $validator
    $result.streamFingerprintMatches = ($actualFingerprint -eq $expectedFingerprint)

    if (-not $result.streamFingerprintMatches) {
        $result.reason = "stream_fingerprint_changed"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $currentOutcomeEligible = ($result.currentEffectiveOutcome -eq "REACQUIRE")
    if ($automaticEscalationCheck.present -and $automaticEscalationCheck.valid) {
        $currentOutcomeEligible = ($result.currentEffectiveOutcome -eq "NORMALIZE")
    }

    if (-not $currentOutcomeEligible) {
        $result.reason = if ($automaticEscalationCheck.present) {
            "automatic_escalation_source_outcome_changed"
        }
        else {
            "current_media_no_longer_requires_reacquisition"
        }
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $plannedFindings = @(
        @(Get-PropertyValue -Object $plan -Name "triggerFindingCodes" -Default @()) |
            ForEach-Object { [string]$_ }
    )

    $missingPlannedFindings = @(
        $plannedFindings |
            Where-Object { $result.currentFindingCodes -notcontains $_ }
    )

    if ($missingPlannedFindings.Count -gt 0) {
        $result.reason = "planned_reacquire_finding_no_longer_present"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $connection = Get-ArrConnection -Source $result.source
    $headers = @{ "X-Api-Key" = $connection.apiKey }

    $file = Get-PropertyValue -Object $plan -Name "file"
    $fileId = [int](Get-PropertyValue -Object $file -Name "id" -Default 0)
    $entity = Get-PropertyValue -Object $plan -Name "entity"
    $entityId = [int](Get-PropertyValue -Object $entity -Name "id" -Default 0)
    $planEpisodeIds = @(
        @(Get-PropertyValue -Object $plan -Name "episodeIds" -Default @()) |
            ForEach-Object { $n = 0; if ([int]::TryParse([string]$_, [ref]$n) -and $n -gt 0) { $n } } |
            Select-Object -Unique
    )

    $fileResource = if ($result.source -eq "Radarr") { "moviefile/$fileId" } else { "episodefile/$fileId" }
    $arrFile = Invoke-RestMethod -Uri ($connection.baseUrl + "/api/v3/" + $fileResource) -Headers $headers -Method Get -TimeoutSec 30

    $arrPath = [string](Get-PropertyValue -Object $arrFile -Name "path" -Default "")
    $arrBytes = [int64](Get-PropertyValue -Object $arrFile -Name "size" -Default -1)

    $result.arrFile = [ordered]@{
        fileId = $fileId
        path = $arrPath
        bytes = $arrBytes
        pathMatches = Test-PathEquivalent $arrPath $result.mediaPath
        sizeMatches = ($arrBytes -eq [int64]$item.Length)
    }

    if (-not $result.arrFile.pathMatches -or -not $result.arrFile.sizeMatches) {
        $result.reason = "current_arr_file_mismatch"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $releaseIdentity = Get-PropertyValue -Object $plan -Name "releaseIdentity"
    $downloadId = [string](Get-PropertyValue -Object $releaseIdentity -Name "downloadId" -Default "")
    $releaseTitle = [string](Get-PropertyValue -Object $releaseIdentity -Name "releaseTitle" -Default "")
    $sceneName = [string](Get-PropertyValue -Object $releaseIdentity -Name "sceneName" -Default "")

    # Radarr/Sonarr versions and API wrappers can expose history either as a raw
    # array or as a paging object with a .records property. Normalize both.
    $historyCandidates = New-Object System.Collections.ArrayList
    $historySources = New-Object System.Collections.ArrayList

    $historyUri = if ($result.source -eq "Radarr") {
        $connection.baseUrl + "/api/v3/history/movie?movieId=$entityId&includeMovie=false"
    }
    else {
        $connection.baseUrl + "/api/v3/history/series?seriesId=$entityId&includeSeries=false"
    }

    try {
        $entityHistoryResponse = Invoke-RestMethod -Uri $historyUri -Headers $headers -Method Get -TimeoutSec 30
        $entityHistoryRecords = @(ConvertTo-RecordArray -Response $entityHistoryResponse)
        Add-UniqueHistoryRecords -Target $historyCandidates -Records $entityHistoryRecords
        [void]$historySources.Add([ordered]@{
            source = "entity_history"
            uri = $historyUri
            recordCount = $entityHistoryRecords.Count
        })
    }
    catch {
        [void]$historySources.Add([ordered]@{
            source = "entity_history"
            uri = $historyUri
            recordCount = 0
            error = $_.Exception.Message
        })
    }

    $importRecords = @(
        $historyCandidates |
            Where-Object {
                [string]::Equals(
                    [string](Get-PropertyValue -Object $_ -Name "eventType" -Default ""),
                    "downloadFolderImported",
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
    )

    # If the per-entity endpoint did not expose an import record, use the global
    # paged history endpoint. A strong downloadId is the narrowest safe fallback.
    if ($importRecords.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($downloadId)) {
        $encodedDownloadId = [System.Uri]::EscapeDataString($downloadId)
        $globalDownloadUri = $connection.baseUrl +
            "/api/v3/history?page=1&pageSize=100&sortKey=date&sortDirection=descending&downloadId=$encodedDownloadId"

        try {
            $globalDownloadResponse = Invoke-RestMethod -Uri $globalDownloadUri -Headers $headers -Method Get -TimeoutSec 30
            $globalDownloadRecords = @(ConvertTo-RecordArray -Response $globalDownloadResponse)
            Add-UniqueHistoryRecords -Target $historyCandidates -Records $globalDownloadRecords
            [void]$historySources.Add([ordered]@{
                source = "global_history_downloadId"
                uri = $globalDownloadUri
                recordCount = $globalDownloadRecords.Count
            })
        }
        catch {
            [void]$historySources.Add([ordered]@{
                source = "global_history_downloadId"
                uri = $globalDownloadUri
                recordCount = 0
                error = $_.Exception.Message
            })
        }

        $importRecords = @(
            $historyCandidates |
                Where-Object {
                    [string]::Equals(
                        [string](Get-PropertyValue -Object $_ -Name "eventType" -Default ""),
                        "downloadFolderImported",
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
    }

    # Last read-only fallback: query global history by entity ID. This handles
    # older/newer Arr API behavior where the per-entity route differs in shape.
    if ($importRecords.Count -eq 0) {
        $entityQuery = if ($result.source -eq "Radarr") {
            "movieIds=$entityId"
        }
        else {
            "seriesIds=$entityId"
        }

        $globalEntityUri = $connection.baseUrl +
            "/api/v3/history?page=1&pageSize=250&sortKey=date&sortDirection=descending&$entityQuery"

        try {
            $globalEntityResponse = Invoke-RestMethod -Uri $globalEntityUri -Headers $headers -Method Get -TimeoutSec 30
            $globalEntityRecords = @(ConvertTo-RecordArray -Response $globalEntityResponse)
            Add-UniqueHistoryRecords -Target $historyCandidates -Records $globalEntityRecords
            [void]$historySources.Add([ordered]@{
                source = "global_history_entity"
                uri = $globalEntityUri
                recordCount = $globalEntityRecords.Count
            })
        }
        catch {
            [void]$historySources.Add([ordered]@{
                source = "global_history_entity"
                uri = $globalEntityUri
                recordCount = 0
                error = $_.Exception.Message
            })
        }

        $importRecords = @(
            $historyCandidates |
                Where-Object {
                    [string]::Equals(
                        [string](Get-PropertyValue -Object $_ -Name "eventType" -Default ""),
                        "downloadFolderImported",
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
    }

    $importResolution = Resolve-ReacquisitionImportHistoryMatch `
        -ImportRecords $importRecords `
        -FileId $fileId `
        -MediaPath $result.mediaPath `
        -DownloadId $downloadId `
        -ReleaseTitle $releaseTitle `
        -SceneName $sceneName

    $matches = @($importResolution.matches)
    $matchMethod = [string]$importResolution.matchMethod

    # Radarr/Sonarr Connect can fire before the corresponding
    # downloadFolderImported history row is committed. Fresh production evidence
    # showed the exact matching row appearing roughly 5-9 seconds after the
    # Connect event. Preserve strong identity matching and use a bounded,
    # read-only consistency refresh rather than weakening identity.
    if ($matches.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($downloadId)) {
        $historyConsistencyMaxChecks = 7
        $historyConsistencyDelaySeconds = 2

        for (
            $historyConsistencyCheck = 1;
            $historyConsistencyCheck -le $historyConsistencyMaxChecks -and $matches.Count -eq 0;
            $historyConsistencyCheck++
        ) {
            if ($historyConsistencyCheck -gt 1) {
                Start-Sleep -Seconds $historyConsistencyDelaySeconds
            }

            $encodedRefreshDownloadId = [System.Uri]::EscapeDataString($downloadId)
            $historyRefreshUri = $connection.baseUrl +
                "/api/v3/history?page=1&pageSize=100&sortKey=date&sortDirection=descending&downloadId=$encodedRefreshDownloadId"

            try {
                $historyRefreshResponse = Invoke-RestMethod `
                    -Uri $historyRefreshUri `
                    -Headers $headers `
                    -Method Get `
                    -TimeoutSec 30

                $historyRefreshRecords = @(ConvertTo-RecordArray -Response $historyRefreshResponse)
                Add-UniqueHistoryRecords -Target $historyCandidates -Records $historyRefreshRecords

                [void]$historySources.Add([ordered]@{
                    source = "global_history_downloadId_consistency_refresh"
                    uri = $historyRefreshUri
                    check = $historyConsistencyCheck
                    recordCount = $historyRefreshRecords.Count
                })
            }
            catch {
                [void]$historySources.Add([ordered]@{
                    source = "global_history_downloadId_consistency_refresh"
                    uri = $historyRefreshUri
                    check = $historyConsistencyCheck
                    recordCount = 0
                    error = $_.Exception.Message
                })
            }

            $importRecords = @(
                $historyCandidates |
                    Where-Object {
                        [string]::Equals(
                            [string](Get-PropertyValue -Object $_ -Name "eventType" -Default ""),
                            "downloadFolderImported",
                            [System.StringComparison]::OrdinalIgnoreCase
                        )
                    }
            )

            $importResolution = Resolve-ReacquisitionImportHistoryMatch `
                -ImportRecords $importRecords `
                -FileId $fileId `
                -MediaPath $result.mediaPath `
                -DownloadId $downloadId `
                -ReleaseTitle $releaseTitle `
                -SceneName $sceneName

            $matches = @($importResolution.matches)
            $matchMethod = [string]$importResolution.matchMethod
        }
    }

    if ($matches.Count -eq 0) {
        $result.reason = "exact_import_history_not_found"
        $result.history = [ordered]@{
            candidateRecordCount = $historyCandidates.Count
            importRecordCount = $importRecords.Count
            exactMatchCount = 0
            logicalExactMatchCount = 0
            matchMethod = $matchMethod
            sources = @($historySources)
        }
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $importPhysicalMatchCount = $matches.Count
    $importLogicalMatchCount = $matches.Count
    if ($matches.Count -gt 1 -and $result.source -eq "Sonarr") {
        $logicalImport = Resolve-SonarrLogicalHistoryMatch -Records $matches -Role "import" `
            -ExpectedFileId $fileId -ExpectedPath $result.mediaPath -ExpectedEpisodeIds $planEpisodeIds
        if ($logicalImport.resolved) {
            $matches = @($logicalImport.selected)
            $importLogicalMatchCount = 1
        }
    }

    if ($matches.Count -gt 1) {
        $result.reason = "exact_import_history_ambiguous"
        $result.history = [ordered]@{
            candidateRecordCount = $historyCandidates.Count
            importRecordCount = $importRecords.Count
            exactMatchCount = $importPhysicalMatchCount
            logicalExactMatchCount = $importLogicalMatchCount
            matchMethod = $matchMethod
            sources = @($historySources)
        }
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $importHistoryMatch = $matches[0]
    $importHistoryId = [int](Get-PropertyValue -Object $importHistoryMatch -Name "id" -Default 0)
    $historyDownloadId = [string](Get-PropertyValue -Object $importHistoryMatch -Name "downloadId" -Default "")
    $historySourceTitle = [string](Get-PropertyValue -Object $importHistoryMatch -Name "sourceTitle" -Default "")

    # The imported record proves which release created the current file, but
    # Radarr's own UI only exposes "Mark as Failed" for the corresponding
    # grabbed record. The grabbed record carries protocol/publishedDate/indexer
    # data required by Radarr's DownloadFailedEvent/blocklist path.
    $grabbedRecords = @(
        $historyCandidates |
            Where-Object {
                [string]::Equals(
                    [string](Get-PropertyValue -Object $_ -Name "eventType" -Default ""),
                    "grabbed",
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
    )

    $grabbedMatches = @()
    $grabbedMatchMethod = "downloadId"

    if (-not [string]::IsNullOrWhiteSpace($historyDownloadId)) {
        $grabbedMatches = @(
            $grabbedRecords |
                Where-Object {
                    [string]::Equals(
                        [string](Get-PropertyValue -Object $_ -Name "downloadId" -Default ""),
                        $historyDownloadId,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
    }

    if ($grabbedMatches.Count -ne 1 -and -not [string]::IsNullOrWhiteSpace($historySourceTitle)) {
        $grabbedMatches = @(
            $grabbedRecords |
                Where-Object {
                    [string]::Equals(
                        [string](Get-PropertyValue -Object $_ -Name "sourceTitle" -Default ""),
                        $historySourceTitle,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
        $grabbedMatchMethod = "sourceTitle"
    }

    # If entity history did not include the grabbed event, query global history
    # by the strong downloadId and retry.
    if ($grabbedMatches.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($historyDownloadId)) {
        $encodedDownloadId = [System.Uri]::EscapeDataString($historyDownloadId)
        $grabbedGlobalUri = $connection.baseUrl +
            "/api/v3/history?page=1&pageSize=100&sortKey=date&sortDirection=descending&downloadId=$encodedDownloadId"

        try {
            $grabbedGlobalResponse = Invoke-RestMethod -Uri $grabbedGlobalUri -Headers $headers -Method Get -TimeoutSec 30
            $grabbedGlobalRecords = @(ConvertTo-RecordArray -Response $grabbedGlobalResponse)
            Add-UniqueHistoryRecords -Target $historyCandidates -Records $grabbedGlobalRecords
            [void]$historySources.Add([ordered]@{
                source = "global_history_grabbed_downloadId"
                uri = $grabbedGlobalUri
                recordCount = $grabbedGlobalRecords.Count
            })

            $grabbedRecords = @(
                $historyCandidates |
                    Where-Object {
                        [string]::Equals(
                            [string](Get-PropertyValue -Object $_ -Name "eventType" -Default ""),
                            "grabbed",
                            [System.StringComparison]::OrdinalIgnoreCase
                        )
                    }
            )

            $grabbedMatches = @(
                $grabbedRecords |
                    Where-Object {
                        [string]::Equals(
                            [string](Get-PropertyValue -Object $_ -Name "downloadId" -Default ""),
                            $historyDownloadId,
                            [System.StringComparison]::OrdinalIgnoreCase
                        )
                    }
            )
            $grabbedMatchMethod = "downloadId"
        }
        catch {
            [void]$historySources.Add([ordered]@{
                source = "global_history_grabbed_downloadId"
                uri = $grabbedGlobalUri
                recordCount = 0
                error = $_.Exception.Message
            })
        }
    }

    if ($grabbedMatches.Count -eq 0) {
        $result.reason = "matching_grabbed_history_not_found"
        $result.history = [ordered]@{
            candidateRecordCount = $historyCandidates.Count
            importRecordCount = $importRecords.Count
            grabbedRecordCount = $grabbedRecords.Count
            exactImportMatchCount = $importPhysicalMatchCount
            logicalExactImportMatchCount = 1
            grabbedMatchCount = 0
            logicalGrabbedMatchCount = 0
            importMatchMethod = $matchMethod
            grabbedMatchMethod = $grabbedMatchMethod
            sources = @($historySources)
            import = [ordered]@{
                historyId = $importHistoryId
                fileId = Get-HistoryFileId $importHistoryMatch
                sourceTitle = $historySourceTitle
                downloadId = $historyDownloadId
                importedPath = Get-HistoryImportedPath $importHistoryMatch
            }
        }
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $grabbedPhysicalMatchCount = $grabbedMatches.Count
    $grabbedLogicalMatchCount = $grabbedMatches.Count
    if ($grabbedMatches.Count -gt 1 -and $result.source -eq "Sonarr") {
        $logicalGrabbed = Resolve-SonarrLogicalHistoryMatch -Records $grabbedMatches -Role "grabbed" `
            -ExpectedFileId $fileId -ExpectedPath $result.mediaPath -ExpectedEpisodeIds $planEpisodeIds
        if ($logicalGrabbed.resolved) {
            $grabbedMatches = @($logicalGrabbed.selected)
            $grabbedLogicalMatchCount = 1
        }
    }

    if ($grabbedMatches.Count -gt 1) {
        $result.reason = "matching_grabbed_history_ambiguous"
        $result.history = [ordered]@{
            candidateRecordCount = $historyCandidates.Count
            importRecordCount = $importRecords.Count
            grabbedRecordCount = $grabbedRecords.Count
            exactImportMatchCount = $importPhysicalMatchCount
            logicalExactImportMatchCount = 1
            grabbedMatchCount = $grabbedPhysicalMatchCount
            logicalGrabbedMatchCount = $grabbedLogicalMatchCount
            importMatchMethod = $matchMethod
            grabbedMatchMethod = $grabbedMatchMethod
            sources = @($historySources)
        }
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $grabbedHistoryMatch = $grabbedMatches[0]
    $failureTargetHistoryId = [int](Get-PropertyValue -Object $grabbedHistoryMatch -Name "id" -Default 0)
    $grabbedProtocol = [string](Get-HistoryDataValue -HistoryRecord $grabbedHistoryMatch -Name "protocol" -Default "")
    $grabbedPublishedDate = [string](Get-HistoryDataValue -HistoryRecord $grabbedHistoryMatch -Name "publishedDate" -Default "")
    $grabbedIndexer = [string](Get-HistoryDataValue -HistoryRecord $grabbedHistoryMatch -Name "indexer" -Default "")

    if ([string]::IsNullOrWhiteSpace($grabbedProtocol) -or
        [string]::IsNullOrWhiteSpace($grabbedPublishedDate)) {
        $result.reason = "grabbed_history_missing_release_metadata"
        $result.history = [ordered]@{
            importHistoryId = $importHistoryId
            failureTargetHistoryId = $failureTargetHistoryId
            failureTargetProtocol = $grabbedProtocol
            failureTargetPublishedDate = $grabbedPublishedDate
            failureTargetIndexer = $grabbedIndexer
        }
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $result.history = [ordered]@{
        candidateRecordCount = $historyCandidates.Count
        importRecordCount = $importRecords.Count
        grabbedRecordCount = $grabbedRecords.Count
        exactImportMatchCount = $importPhysicalMatchCount
        logicalExactImportMatchCount = 1
        grabbedMatchCount = $grabbedPhysicalMatchCount
        logicalGrabbedMatchCount = 1
        importMatchMethod = $matchMethod
        grabbedMatchMethod = $grabbedMatchMethod
        sources = @($historySources)
        import = [ordered]@{
            historyId = $importHistoryId
            fileId = Get-HistoryFileId $importHistoryMatch
            eventType = [string](Get-PropertyValue -Object $importHistoryMatch -Name "eventType" -Default "")
            sourceTitle = $historySourceTitle
            downloadId = $historyDownloadId
            importedPath = Get-HistoryImportedPath $importHistoryMatch
            date = Get-PropertyValue -Object $importHistoryMatch -Name "date"
        }
        failureTarget = [ordered]@{
            historyId = $failureTargetHistoryId
            eventType = [string](Get-PropertyValue -Object $grabbedHistoryMatch -Name "eventType" -Default "")
            matchMethod = $grabbedMatchMethod
            sourceTitle = [string](Get-PropertyValue -Object $grabbedHistoryMatch -Name "sourceTitle" -Default "")
            downloadId = [string](Get-PropertyValue -Object $grabbedHistoryMatch -Name "downloadId" -Default "")
            date = Get-PropertyValue -Object $grabbedHistoryMatch -Name "date"
            protocol = $grabbedProtocol
            publishedDate = $grabbedPublishedDate
            indexer = $grabbedIndexer
        }
    }

    $blocklistUri = if ($result.source -eq "Radarr") {
        $connection.baseUrl + "/api/v3/blocklist/movie?movieId=$entityId"
    }
    else {
        $connection.baseUrl + "/api/v3/blocklist?page=1&pageSize=1000&seriesIds=$entityId"
    }
    $blocklistResponse = Invoke-RestMethod -Uri $blocklistUri -Headers $headers -Method Get -TimeoutSec 30
    $blocklistRecords = @(
        if ($null -ne (Get-PropertyValue -Object $blocklistResponse -Name "records" -Default $null)) {
            @(Get-PropertyValue -Object $blocklistResponse -Name "records" -Default @())
        }
        else {
            @($blocklistResponse)
        }
    )

    $alreadyBlocked = @(
        $blocklistRecords |
            Where-Object {
                $recordDownloadId = [string](Get-PropertyValue -Object $_ -Name "downloadId" -Default "")
                $recordSourceTitle = [string](Get-PropertyValue -Object $_ -Name "sourceTitle" -Default "")

                (
                    -not [string]::IsNullOrWhiteSpace($historyDownloadId) -and
                    [string]::Equals($recordDownloadId, $historyDownloadId, [System.StringComparison]::OrdinalIgnoreCase)
                ) -or (
                    -not [string]::IsNullOrWhiteSpace($historySourceTitle) -and
                    [string]::Equals($recordSourceTitle, $historySourceTitle, [System.StringComparison]::OrdinalIgnoreCase)
                )
            }
    ).Count -gt 0

    $result.blocklist = [ordered]@{
        checked = $true
        entityBlocklistCount = $blocklistRecords.Count
        currentReleaseAlreadyBlocked = $alreadyBlocked
    }

    $searchPayload = if ($result.source -eq "Radarr") {
        [ordered]@{
            name = "MoviesSearch"
            movieIds = @($entityId)
        }
    }
    else {
        [ordered]@{
            name = "EpisodeSearch"
            episodeIds = @(
                @(Get-PropertyValue -Object $plan -Name "episodeIds" -Default @()) |
                    ForEach-Object { [int]$_ }
            )
        }
    }

    if ($result.source -eq "Sonarr" -and @($searchPayload.episodeIds).Count -eq 0) {
        $result.reason = "sonarr_episode_ids_missing"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $loopPrevention = Get-PropertyValue -Object $plan -Name "loopPrevention"
    $loopKey = [string](Get-PropertyValue -Object $loopPrevention -Name "loopKey" -Default "")
    $maxAttempts = [int](Get-PropertyValue -Object $loopPrevention -Name "maxAutomaticAttempts" -Default 3)

    $downloadClientConfig = $null
    try {
        $downloadClientConfig = Invoke-RestMethod `
            -Uri ($connection.baseUrl + "/api/v3/config/downloadclient") `
            -Headers $headers `
            -Method Get `
            -TimeoutSec 30

        $result.arrDownloadClientConfig = [ordered]@{
            autoRedownloadFailed = [bool](Get-PropertyValue -Object $downloadClientConfig -Name "autoRedownloadFailed" -Default $false)
            autoRedownloadFailedFromInteractiveSearch = [bool](Get-PropertyValue -Object $downloadClientConfig -Name "autoRedownloadFailedFromInteractiveSearch" -Default $false)
        }
    }
    catch {
        $result.arrDownloadClientConfig = [ordered]@{
            available = $false
            error = $_.Exception.Message
        }
    }

    $downloadClientConfigId = 0
    if ($null -ne $downloadClientConfig) {
        $downloadClientConfigId = [int](Get-PropertyValue -Object $downloadClientConfig -Name "id" -Default 0)
    }

    $result.nativeRedownloadSuppression = [ordered]@{
        requested = [bool]$SuppressNativeRedownload
        configAvailable = ($null -ne $downloadClientConfig)
        configId = $downloadClientConfigId
        canSuppress = (-not $SuppressNativeRedownload -or ($null -ne $downloadClientConfig -and $downloadClientConfigId -gt 0))
        originalAutoRedownloadFailed = if ($null -ne $downloadClientConfig) { [bool](Get-PropertyValue -Object $downloadClientConfig -Name "autoRedownloadFailed" -Default $false) } else { $null }
        originalAutoRedownloadFailedFromInteractiveSearch = if ($null -ne $downloadClientConfig) { [bool](Get-PropertyValue -Object $downloadClientConfig -Name "autoRedownloadFailedFromInteractiveSearch" -Default $false) } else { $null }
        disabledVerified = $false
        restoredVerified = $false
        restoreError = $null
    }

    if ($SuppressNativeRedownload -and -not $result.nativeRedownloadSuppression.canSuppress) {
        $result.reason = "download_client_config_unavailable_for_redownload_suppression"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $result.proposedExecution = [ordered]@{
        step1 = [ordered]@{
            method = "POST"
            path = "/api/v3/history/failed/$failureTargetHistoryId"
            purpose = "publish_arr_download_failed_event_for_matching_grabbed_release"
            historyRole = "grabbed"
            importHistoryId = $importHistoryId
            failureTargetHistoryId = $failureTargetHistoryId
        }
        step2 = [ordered]@{
            action = "verify_downloadFailed_history_and_blocklist"
            mutating = $false
        }
        step3 = [ordered]@{
            action = if ($SuppressNativeRedownload) { "suppress_arr_native_failed_download_redownload_for_this_mutation" } else { "allow_arr_native_failed_download_redownload_policy" }
            mutating = [bool]$SuppressNativeRedownload
            explicitMoviesSearchSentByReqestra = $false
        }
        loopKey = $loopKey
        maxAutomaticAttempts = $maxAttempts
    }

    if (-not $Execute) {
        if ($alreadyBlocked) {
            $result.status = "BLOCKED"
            $result.reason = "current_release_already_blocklisted"
        }
        else {
            $result.status = "DRY_RUN_READY"
            $result.reason = $null
        }

        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $result.executionGate = [ordered]@{
        requiredLoopKey = $loopKey
        suppliedLoopKey = $ConfirmLoopKey
        matched = (-not [string]::IsNullOrWhiteSpace($ConfirmLoopKey) -and
            [string]::Equals($ConfirmLoopKey, $loopKey, [System.StringComparison]::Ordinal))
    }

    if (-not $result.executionGate.matched) {
        $result.status = "BLOCKED"
        $result.reason = "execute_loop_key_confirmation_required"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $mutex = New-Object System.Threading.Mutex($false, "ReqestraMediaReacquisition")
    $mutexHeld = $false

    try {
        $mutexHeld = $mutex.WaitOne(0)
        if (-not $mutexHeld) {
            $result.status = "BLOCKED"
            $result.reason = "reacquisition_mutex_busy"
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        $stateRecord = Get-ReacquisitionState -LoopKey $loopKey -MaxAttempts $maxAttempts
        $priorAttempts = @($stateRecord.state.attempts)

        # Reconcile a previously sent correct grabbed-history mutation without
        # sending another POST. Radarr's DownloadFailed history row intentionally
        # does not retain protocol/publishedDate, so success evidence is:
        #   1) mutation was sent to the correct grabbed history id
        #   2) matching blocklist now exists
        #   3) matching downloadFailed history exists at/after attempt start
        $recoverableCorrectAttempts = @(
            $priorAttempts |
                Where-Object {
                    [string]$_.status -eq "RECOVERY_REQUIRED" -and
                    [bool]$_.mutationSent -and
                    [int]$_.historyId -eq $failureTargetHistoryId
                }
        )

        if ($recoverableCorrectAttempts.Count -gt 0) {
            $latestRecoverable = @(
                $recoverableCorrectAttempts |
                    Sort-Object {
                        try {
                            [DateTime]::Parse(
                                [string]$_.startedUtc,
                                [System.Globalization.CultureInfo]::InvariantCulture,
                                [System.Globalization.DateTimeStyles]::RoundtripKind
                            )
                        }
                        catch {
                            [DateTime]::MinValue
                        }
                    } -Descending
            )[0]

            $attemptStartedUtc = [DateTime]::Parse(
                [string]$latestRecoverable.startedUtc,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime()

            $recoveryHistory = @(Get-EntityHistoryRecords `
                -Source $result.source `
                -EntityId $entityId `
                -Connection $connection `
                -Headers $headers)

            $recoveryFailedMatches = @(
                Test-MatchingFailedHistoryAfter `
                    -Records $recoveryHistory `
                    -DownloadId $historyDownloadId `
                    -SourceTitle $historySourceTitle `
                    -NotBeforeUtc $attemptStartedUtc
            )

            $recoveryBlocklistResponse = Invoke-RestMethod `
                -Uri $blocklistUri `
                -Headers $headers `
                -Method Get `
                -TimeoutSec 30

            $recoveryBlocklistRecords = @(
                if ($null -ne (Get-PropertyValue -Object $recoveryBlocklistResponse -Name "records" -Default $null)) {
                    @(Get-PropertyValue -Object $recoveryBlocklistResponse -Name "records" -Default @())
                }
                else {
                    @($recoveryBlocklistResponse)
                }
            )

            $recoveryBlocklistMatches = @(
                Test-MatchingBlocklistRecord `
                    -Records $recoveryBlocklistRecords `
                    -DownloadId $historyDownloadId `
                    -SourceTitle $historySourceTitle
            )

            if ($recoveryFailedMatches.Count -gt 0 -and $recoveryBlocklistMatches.Count -gt 0) {
                if (-not $Recover) {
                    $result.status = "RECOVERY_READY"
                    $result.reason = "successful_mutation_requires_state_reconciliation"
                    $result.verification = [ordered]@{
                        blocklistVerified = $true
                        matchingBlocklistCount = $recoveryBlocklistMatches.Count
                        failedHistoryVerified = $true
                        matchingFailedHistoryCount = $recoveryFailedMatches.Count
                        failedHistoryNotBeforeUtc = $attemptStartedUtc.ToString("o")
                        mutatingRequestRequired = $false
                    }
                    $result.attemptState = [ordered]@{
                        statePath = $stateRecord.path
                        recoverableAttemptId = $latestRecoverable.attemptId
                        recoverSwitchRequired = $true
                    }
                    Write-Result ([pscustomobject]$result)
                    exit 0
                }

                $latestRecoverable.status = "SUCCESS_RECOVERED"
                $latestRecoverable.completedUtc = [DateTime]::UtcNow.ToString("o")
                $latestRecoverable.blocklistVerified = $true
                $latestRecoverable.failedHistoryVerified = $true
                $latestRecoverable.searchDelegatedToArr = [bool](
                    Get-PropertyValue -Object $downloadClientConfig -Name "autoRedownloadFailed" -Default $false
                )
                $latestRecoverable | Add-Member `
                    -NotePropertyName "recoveryNote" `
                    -NotePropertyValue "v0.9.7 reconciled successful grabbed-history mutation from persisted Radarr evidence; no additional mutation sent" `
                    -Force

                Set-StateAttempt -StateRecord $stateRecord -Attempt $latestRecoverable

                $result.status = "SUCCESS_RECOVERED"
                $result.reason = $null
                $result.mutatingRequestsSent = 0
                $result.searchDelegatedToArr = [bool](
                    Get-PropertyValue -Object $downloadClientConfig -Name "autoRedownloadFailed" -Default $false
                )
                $result.verification = [ordered]@{
                    blocklistVerified = $true
                    matchingBlocklistCount = $recoveryBlocklistMatches.Count
                    failedHistoryVerified = $true
                    matchingFailedHistoryCount = $recoveryFailedMatches.Count
                    failedHistoryNotBeforeUtc = $attemptStartedUtc.ToString("o")
                    explicitSearchSentByReqestra = $false
                    currentMediaDeletedByReqestra = $false
                    mutatingRequestRequired = $false
                }
                $result.attemptState = [ordered]@{
                    statePath = $stateRecord.path
                    attemptId = $latestRecoverable.attemptId
                    finalAttemptStatus = "SUCCESS_RECOVERED"
                    reconciledWithoutMutation = $true
                }

                Write-Result ([pscustomobject]$result)
                exit 0
            }
        }

        # v0.9.3 incorrectly targeted the imported history record. Detect that
        # exact known failure mode so it can be repaired without manual JSON edits.
        $repairableLegacyAttempts = @(
            $priorAttempts |
                Where-Object {
                    [string]$_.status -eq "RECOVERY_REQUIRED" -and
                    [bool]$_.mutationSent -and
                    [bool]$_.failedHistoryVerified -and
                    -not [bool]$_.blocklistVerified -and
                    [int]$_.historyId -eq $importHistoryId -and
                    [int]$_.historyId -ne $failureTargetHistoryId
                }
        )

        if ($repairableLegacyAttempts.Count -gt 0 -and -not $Recover) {
            $result.status = "RECOVERY_READY"
            $result.reason = "legacy_import_history_failure_requires_grabbed_history_repair"
            $result.attemptState = [ordered]@{
                statePath = $stateRecord.path
                priorAttemptCount = $priorAttempts.Count
                repairableAttemptIds = @($repairableLegacyAttempts | ForEach-Object { $_.attemptId })
                previousHistoryId = $importHistoryId
                correctFailureTargetHistoryId = $failureTargetHistoryId
                recoverSwitchRequired = $true
            }
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        if ($repairableLegacyAttempts.Count -gt 0 -and $Recover) {
            foreach ($legacyAttempt in $repairableLegacyAttempts) {
                $legacyAttempt.status = "SUPERSEDED_WRONG_HISTORY_TARGET"
                $legacyAttempt.completedUtc = if ($null -eq $legacyAttempt.completedUtc) {
                    [DateTime]::UtcNow.ToString("o")
                }
                else {
                    $legacyAttempt.completedUtc
                }
                $legacyAttempt | Add-Member -NotePropertyName "countsTowardAttemptLimit" -NotePropertyValue $false -Force
                $legacyAttempt | Add-Member -NotePropertyName "recoveryNote" -NotePropertyValue (
                    "v0.9.3 targeted imported history id {0}; corrected grabbed history id is {1}" -f
                    $importHistoryId,
                    $failureTargetHistoryId
                ) -Force
                Set-StateAttempt -StateRecord $stateRecord -Attempt $legacyAttempt
            }

            $priorAttempts = @($stateRecord.state.attempts)
        }

        $unfinished = @(
            $priorAttempts |
                Where-Object { [string]$_.status -eq "STARTED" }
        )

        if ($unfinished.Count -gt 0) {
            $result.status = "RECOVERY_REQUIRED"
            $result.reason = "previous_reacquisition_attempt_incomplete"
            $result.attemptState = [ordered]@{
                statePath = $stateRecord.path
                priorAttemptCount = $priorAttempts.Count
                incompleteAttemptIds = @($unfinished | ForEach-Object { $_.attemptId })
            }
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        $countedAttempts = @(
            $priorAttempts |
                Where-Object {
                    $property = $_.PSObject.Properties["countsTowardAttemptLimit"]
                    $null -eq $property -or [bool]$property.Value
                }
        )

        if ($countedAttempts.Count -ge $maxAttempts) {
            $result.status = "BLOCKED"
            $result.reason = "maximum_reacquisition_attempts_reached"
            $result.attemptState = [ordered]@{
                statePath = $stateRecord.path
                priorAttemptCount = $priorAttempts.Count
                countedAttemptCount = $countedAttempts.Count
                maxAttempts = $maxAttempts
            }
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        # Re-read history and blocklist immediately before the write.
        $freshHistory = @(Get-EntityHistoryRecords `
            -Source $result.source `
            -EntityId $entityId `
            -Connection $connection `
            -Headers $headers)

        # A historical downloadFailed row by itself is insufficient to block
        # execution because v0.9.3 may have created one from the wrong imported
        # history record. The blocklist check below is authoritative for whether
        # Radarr actually rejected the release.

        $freshBlocklistResponse = Invoke-RestMethod `
            -Uri $blocklistUri `
            -Headers $headers `
            -Method Get `
            -TimeoutSec 30

        $freshBlocklistRecords = @(
            if ($null -ne (Get-PropertyValue -Object $freshBlocklistResponse -Name "records" -Default $null)) {
                @(Get-PropertyValue -Object $freshBlocklistResponse -Name "records" -Default @())
            }
            else {
                @($freshBlocklistResponse)
            }
        )

        $freshBlocked = @(
            Test-MatchingBlocklistRecord `
                -Records $freshBlocklistRecords `
                -DownloadId $historyDownloadId `
                -SourceTitle $historySourceTitle
        )

        if ($freshBlocked.Count -gt 0) {
            $result.status = "BLOCKED"
            $result.reason = "matching_release_already_blocklisted"
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        $attemptId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + [guid]::NewGuid().ToString("N").Substring(0,8)
        $attempt = [pscustomobject][ordered]@{
            attemptId = $attemptId
            startedUtc = [DateTime]::UtcNow.ToString("o")
            completedUtc = $null
            status = "STARTED"
            source = $result.source
            entityId = $entityId
            fileId = $fileId
            importHistoryId = $importHistoryId
            historyId = $failureTargetHistoryId
            historyRole = "grabbed"
            countsTowardAttemptLimit = $true
            downloadId = if ([string]::IsNullOrWhiteSpace($historyDownloadId)) { $null } else { $historyDownloadId }
            sourceTitle = $historySourceTitle
            mediaPath = $result.mediaPath
            findingCodes = @($result.currentFindingCodes)
            mutation = "POST /api/v3/history/failed/$failureTargetHistoryId"
            mutationSent = $false
            blocklistVerified = $false
            failedHistoryVerified = $false
            searchDelegatedToArr = $false
            error = $null
        }

        Set-StateAttempt -StateRecord $stateRecord -Attempt $attempt

        $suppressionOriginalJson = $null
        $suppressionRestoreRequired = $false
        $suppressionRestoreFailed = $false
        $markFailedError = $null

        try {
            if ($SuppressNativeRedownload) {
                $suppressionOriginalJson = $downloadClientConfig | ConvertTo-Json -Depth 30 -Compress
                $suppressedConfig = $suppressionOriginalJson | ConvertFrom-Json
                $suppressedConfig.autoRedownloadFailed = $false
                if ($null -ne $suppressedConfig.PSObject.Properties["autoRedownloadFailedFromInteractiveSearch"]) {
                    $suppressedConfig.autoRedownloadFailedFromInteractiveSearch = $false
                }

                [void](Invoke-RestMethod `
                    -Uri ($connection.baseUrl + "/api/v3/config/downloadclient/$downloadClientConfigId") `
                    -Headers $headers `
                    -Method Put `
                    -Body ($suppressedConfig | ConvertTo-Json -Depth 30) `
                    -ContentType "application/json" `
                    -TimeoutSec 30)
                $result.mutatingRequestsSent++
                $suppressionRestoreRequired = $true

                $disabledConfig = Invoke-RestMethod `
                    -Uri ($connection.baseUrl + "/api/v3/config/downloadclient") `
                    -Headers $headers `
                    -Method Get `
                    -TimeoutSec 30
                $disabledAuto = [bool](Get-PropertyValue -Object $disabledConfig -Name "autoRedownloadFailed" -Default $true)
                $disabledInteractive = [bool](Get-PropertyValue -Object $disabledConfig -Name "autoRedownloadFailedFromInteractiveSearch" -Default $true)
                $result.nativeRedownloadSuppression.disabledVerified = (-not $disabledAuto -and -not $disabledInteractive)
                if (-not $result.nativeRedownloadSuppression.disabledVerified) {
                    throw "Arr failed-download auto-redownload suppression could not be verified before Mark Failed."
                }
            }

            [void](Invoke-RestMethod `
                -Uri ($connection.baseUrl + "/api/v3/history/failed/$failureTargetHistoryId") `
                -Headers $headers `
                -Method Post `
                -ContentType "application/json" `
                -TimeoutSec 30)

            $result.mutatingRequestsSent++
            $attempt.mutationSent = $true
            Set-StateAttempt -StateRecord $stateRecord -Attempt $attempt
        }
        catch {
            $markFailedError = $_.Exception.Message
            $attempt.status = "FAILED"
            $attempt.completedUtc = [DateTime]::UtcNow.ToString("o")
            $attempt.error = $markFailedError
            Set-StateAttempt -StateRecord $stateRecord -Attempt $attempt
        }
        finally {
            if ($SuppressNativeRedownload -and $suppressionRestoreRequired -and -not [string]::IsNullOrWhiteSpace($suppressionOriginalJson)) {
                try {
                    $restoreConfig = $suppressionOriginalJson | ConvertFrom-Json
                    [void](Invoke-RestMethod `
                        -Uri ($connection.baseUrl + "/api/v3/config/downloadclient/$downloadClientConfigId") `
                        -Headers $headers `
                        -Method Put `
                        -Body ($restoreConfig | ConvertTo-Json -Depth 30) `
                        -ContentType "application/json" `
                        -TimeoutSec 30)
                    $result.mutatingRequestsSent++

                    $restoredConfig = Invoke-RestMethod `
                        -Uri ($connection.baseUrl + "/api/v3/config/downloadclient") `
                        -Headers $headers `
                        -Method Get `
                        -TimeoutSec 30
                    $restoredAuto = [bool](Get-PropertyValue -Object $restoredConfig -Name "autoRedownloadFailed" -Default $false)
                    $restoredInteractive = [bool](Get-PropertyValue -Object $restoredConfig -Name "autoRedownloadFailedFromInteractiveSearch" -Default $false)
                    $expectedAuto = [bool](Get-PropertyValue -Object $downloadClientConfig -Name "autoRedownloadFailed" -Default $false)
                    $expectedInteractive = [bool](Get-PropertyValue -Object $downloadClientConfig -Name "autoRedownloadFailedFromInteractiveSearch" -Default $false)
                    $result.nativeRedownloadSuppression.restoredVerified = ($restoredAuto -eq $expectedAuto -and $restoredInteractive -eq $expectedInteractive)
                    if (-not $result.nativeRedownloadSuppression.restoredVerified) {
                        $suppressionRestoreFailed = $true
                        $result.nativeRedownloadSuppression.restoreError = "Arr download-client auto-redownload settings did not match their original values after restore."
                    }
                }
                catch {
                    $suppressionRestoreFailed = $true
                    $result.nativeRedownloadSuppression.restoreError = $_.Exception.Message
                }
            }
            elseif (-not $SuppressNativeRedownload) {
                $result.nativeRedownloadSuppression.restoredVerified = $true
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($markFailedError)) {
            if ($suppressionRestoreFailed) {
                $result.status = "RECOVERY_REQUIRED"
                $result.reason = "mark_failed_error_and_download_client_config_restore_failed"
            }
            else {
                $result.status = "FAILED"
                $result.reason = "mark_history_failed_request_failed"
            }
            $result.attemptState = [ordered]@{
                statePath = $stateRecord.path
                attemptId = $attemptId
            }
            $result.error = $markFailedError
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        # Arr handles DownloadFailedEvent synchronously in normal operation, but poll defensively.
        $verifiedBlocklist = $false
        $verifiedFailedHistory = $false
        $matchingBlocklist = @()
        $matchingFailedHistory = @()

        for ($poll = 0; $poll -lt 8; $poll++) {
            if ($poll -gt 0) {
                Start-Sleep -Milliseconds 750
            }

            try {
                $postHistory = @(Get-EntityHistoryRecords `
                    -Source $result.source `
                    -EntityId $entityId `
                    -Connection $connection `
                    -Headers $headers)

                $attemptStartedUtc = [DateTime]::Parse(
                    [string]$attempt.startedUtc,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind
                ).ToUniversalTime()

                $matchingFailedHistory = @(
                    Test-MatchingFailedHistoryAfter `
                        -Records $postHistory `
                        -DownloadId $historyDownloadId `
                        -SourceTitle $historySourceTitle `
                        -NotBeforeUtc $attemptStartedUtc
                )

                $verifiedFailedHistory = ($matchingFailedHistory.Count -gt 0)
            }
            catch {
            }

            try {
                $postBlocklistResponse = Invoke-RestMethod `
                    -Uri $blocklistUri `
                    -Headers $headers `
                    -Method Get `
                    -TimeoutSec 30

                $postBlocklistRecords = @(
                    if ($null -ne (Get-PropertyValue -Object $postBlocklistResponse -Name "records" -Default $null)) {
                        @(Get-PropertyValue -Object $postBlocklistResponse -Name "records" -Default @())
                    }
                    else {
                        @($postBlocklistResponse)
                    }
                )

                $matchingBlocklist = @(
                    Test-MatchingBlocklistRecord `
                        -Records $postBlocklistRecords `
                        -DownloadId $historyDownloadId `
                        -SourceTitle $historySourceTitle
                )

                $verifiedBlocklist = ($matchingBlocklist.Count -gt 0)
            }
            catch {
            }

            if ($verifiedBlocklist -and $verifiedFailedHistory) {
                break
            }
        }

        $autoRedownloadFailed = $false
        if ($null -ne $downloadClientConfig) {
            $autoRedownloadFailed = [bool](Get-PropertyValue -Object $downloadClientConfig -Name "autoRedownloadFailed" -Default $false)
        }
        $effectiveAutoRedownloadFailed = if ($SuppressNativeRedownload) { $false } else { $autoRedownloadFailed }

        $attempt.blocklistVerified = $verifiedBlocklist
        $attempt.failedHistoryVerified = $verifiedFailedHistory
        $attempt.searchDelegatedToArr = $effectiveAutoRedownloadFailed
        $attempt.completedUtc = [DateTime]::UtcNow.ToString("o")

        $result.searchDelegatedToArr = $effectiveAutoRedownloadFailed
        $result.verification = [ordered]@{
            blocklistVerified = $verifiedBlocklist
            matchingBlocklistCount = $matchingBlocklist.Count
            failedHistoryVerified = $verifiedFailedHistory
            matchingFailedHistoryCount = $matchingFailedHistory.Count
            autoRedownloadFailed = $autoRedownloadFailed
            nativeRedownloadSuppressed = [bool]$SuppressNativeRedownload
            explicitSearchSentByReqestra = $false
            currentMediaDeletedByReqestra = $false
        }

        if ($suppressionRestoreFailed) {
            $attempt.status = "RECOVERY_REQUIRED"
            $result.status = "RECOVERY_REQUIRED"
            $result.reason = "download_client_config_restore_failed"
        }
        elseif ($verifiedBlocklist -and $verifiedFailedHistory) {
            if ($SuppressNativeRedownload) {
                $attempt.status = "SUCCESS_SEARCH_SUPPRESSED"
                $result.status = "SUCCESS_SEARCH_SUPPRESSED"
                $result.reason = $null
            }
            elseif ($autoRedownloadFailed) {
                $attempt.status = "SUCCESS"
                $result.status = "SUCCESS"
                $result.reason = $null
            }
            else {
                $attempt.status = "BLOCKLISTED_SEARCH_REQUIRED"
                $result.status = "BLOCKLISTED_SEARCH_REQUIRED"
                $result.reason = "arr_auto_redownload_failed_disabled"
            }
        }
        else {
            $attempt.status = "RECOVERY_REQUIRED"
            $result.status = "RECOVERY_REQUIRED"
            $result.reason = "mutation_sent_but_postconditions_not_fully_verified"
        }

        Set-StateAttempt -StateRecord $stateRecord -Attempt $attempt

        $result.attemptState = [ordered]@{
            statePath = $stateRecord.path
            attemptId = $attemptId
            priorAttemptCount = $priorAttempts.Count
            countedPriorAttemptCount = $countedAttempts.Count
            attemptNumber = ($countedAttempts.Count + 1)
            maxAttempts = $maxAttempts
            finalAttemptStatus = $attempt.status
        }

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
    $result.reason = "preflight_exception"
    $result.error = $_.Exception.Message
    Write-Result ([pscustomobject]$result)
    exit 0
}
