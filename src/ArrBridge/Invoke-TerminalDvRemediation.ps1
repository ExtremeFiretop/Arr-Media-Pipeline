[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$MovieId,

    [string]$CandidatePath = "",

    [string]$TemporaryHevcPath = "",

    [string]$JsonOut = "",

    [switch]$BuildCandidate,

    [switch]$Execute,

    [string]$ConfirmChainId = "",

    [string]$ConfirmSourceFingerprint = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "0.2.0"
$IntegrationRoot = $PSScriptRoot
$CommonPath = Join-Path $IntegrationRoot "ReacquisitionChainCommon.ps1"
$DvCommonPath = Join-Path $IntegrationRoot "TerminalDvRemediationCommon.ps1"
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"
$ValidatorPath = Join-Path (Split-Path -Parent $IntegrationRoot) "MediaValidator.ps1"
$PolicyPath = Join-Path (Split-Path -Parent $IntegrationRoot) "validator-policy.json"
$WorkRoot = Join-Path $IntegrationRoot "Reacquisition\terminal-dv-work"
$StateRoot = Join-Path $IntegrationRoot "Reacquisition\terminal-dv-state"

. $CommonPath
. $DvCommonPath

function Write-Result {
    param($Object)
    if (-not [string]::IsNullOrWhiteSpace($JsonOut)) {
        $Object | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    }
    $Object | ConvertTo-Json -Depth 80
}

function Get-RadarrConnection {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Integration config not found: $ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $radarr = Get-PropertyValue -Object $config -Name "radarr"
    $baseUrl = [string](Get-PropertyValue -Object $radarr -Name "baseUrl" -Default "")
    $apiKey = [string](Get-PropertyValue -Object $radarr -Name "apiKey" -Default "")
    if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Radarr integration config requires baseUrl and apiKey."
    }

    return [pscustomobject]@{ baseUrl = $baseUrl.TrimEnd("/"); apiKey = $apiKey }
}

function Invoke-Radarr {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [ValidateSet("GET","POST","PUT","DELETE")][string]$Method = "GET",
        $Body = $null
    )

    $headers = @{ "X-Api-Key" = $Connection.apiKey }
    $uri = $Connection.baseUrl + "/api/v3/" + $RelativePath.TrimStart("/")
    $args = @{ Uri = $uri; Headers = $headers; Method = $Method; TimeoutSec = 60 }
    if ($null -ne $Body) {
        $args["Body"] = ($Body | ConvertTo-Json -Depth 30)
        $args["ContentType"] = "application/json"
    }
    return Invoke-RestMethod @args
}

function Get-RecordArray {
    param($Response)
    if ($null -eq $Response) { return @() }
    $records = Get-PropertyValue -Object $Response -Name "records" -Default $null
    if ($null -ne $records) { return @($records) }
    return @($Response)
}

function Wait-RadarrCommand {
    param($Connection, [int]$CommandId, [int]$TimeoutSeconds = 300)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $last = Invoke-Radarr -Connection $Connection -RelativePath ("command/{0}" -f $CommandId) -Method GET
        $status = [string](Get-PropertyValue -Object $last -Name "status" -Default "")
        if ($status -notin @("queued","started")) { return $last }
    }
    while ([DateTime]::UtcNow -lt $deadline)

    throw "Timed out waiting for Radarr command $CommandId."
}

function Get-DvVideoInspection {
    param([Parameter(Mandatory = $true)][string]$Path)

    $json = (& ffprobe.exe `
        -v error `
        -select_streams v:0 `
        -show_streams `
        -show_entries "stream=index,codec_name,profile,pix_fmt,width,height,color_range,color_space,color_transfer,color_primaries,side_data_list:format=duration,size" `
        -of json `
        $Path | Out-String) | ConvertFrom-Json

    $video = @($json.streams)[0]
    [object[]]$sideData = @()
    if ($null -ne $video -and $video.PSObject.Properties["side_data_list"]) {
        [object[]]$sideData = @($video.side_data_list)
    }

    $dovi = @(
        $sideData | Where-Object {
            [string](Get-PropertyValue -Object $_ -Name "side_data_type" -Default "") -eq "DOVI configuration record"
        }
    )
    $doviRecord = if ($dovi.Count -gt 0) { $dovi[0] } else { $null }

    return [pscustomobject][ordered]@{
        video = $video
        format = Get-PropertyValue -Object $json -Name "format"
        sideDataCount = @($sideData).Count
        doviCount = $dovi.Count
        dvProfile = [int](Get-PropertyValue -Object $doviRecord -Name "dv_profile" -Default 0)
        dvLevel = [int](Get-PropertyValue -Object $doviRecord -Name "dv_level" -Default 0)
        compatibilityId = [int](Get-PropertyValue -Object $doviRecord -Name "dv_bl_signal_compatibility_id" -Default 0)
        rpuPresent = ([int](Get-PropertyValue -Object $doviRecord -Name "rpu_present_flag" -Default 0) -eq 1)
        enhancementLayerPresent = ([int](Get-PropertyValue -Object $doviRecord -Name "el_present_flag" -Default 0) -eq 1)
        baseLayerPresent = ([int](Get-PropertyValue -Object $doviRecord -Name "bl_present_flag" -Default 0) -eq 1)
        codec = [string](Get-PropertyValue -Object $video -Name "codec_name" -Default "")
        profile = [string](Get-PropertyValue -Object $video -Name "profile" -Default "")
        pixelFormat = [string](Get-PropertyValue -Object $video -Name "pix_fmt" -Default "")
        width = [int](Get-PropertyValue -Object $video -Name "width" -Default 0)
        height = [int](Get-PropertyValue -Object $video -Name "height" -Default 0)
        colorRange = [string](Get-PropertyValue -Object $video -Name "color_range" -Default "")
        colorSpace = [string](Get-PropertyValue -Object $video -Name "color_space" -Default "")
        colorTransfer = [string](Get-PropertyValue -Object $video -Name "color_transfer" -Default "")
        colorPrimaries = [string](Get-PropertyValue -Object $video -Name "color_primaries" -Default "")
        durationSeconds = [double](Get-PropertyValue -Object (Get-PropertyValue -Object $json -Name "format") -Name "duration" -Default 0)
    }
}

function Get-DvProfile7LayerClassification {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $WorkRoot)) {
        New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    }

    $rpuPath = Join-Path $WorkRoot ("profile7-rpu-{0}.bin" -f ([guid]::NewGuid().ToString("N")))
    try {
        # MEL/FEL is encoded in the RPU profile metadata. Ten frames are enough
        # to classify the stream and avoid reading a 40-80 GB movie end-to-end.
        & dovi_tool extract-rpu --limit 10 -i $Path -o $rpuPath | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $rpuPath -PathType Leaf)) {
            throw "dovi_tool extract-rpu sample failed."
        }

        $summary = (& dovi_tool info -s -i $rpuPath 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "dovi_tool info failed for sampled Profile 7 RPU."
        }

        $layerType = "UNKNOWN"
        if ($summary -match 'Profile:\s*7\s*\(MEL\)') {
            $layerType = "MEL"
        }
        elseif ($summary -match 'Profile:\s*7\s*\(FEL\)') {
            $layerType = "FEL"
        }

        if ($layerType -eq "UNKNOWN") {
            throw "Profile 7 stream could not be classified as MEL or FEL from sampled RPU metadata."
        }

        return [pscustomobject][ordered]@{
            layerType = $layerType
            sampledFrames = 10
        }
    }
    finally {
        Remove-Item -LiteralPath $rpuPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-TrackSignature {
    param($Track)
    $p = Get-PropertyValue -Object $Track -Name "properties"
    return [pscustomobject][ordered]@{
        Type = [string](Get-PropertyValue -Object $Track -Name "type" -Default "")
        Codec = [string](Get-PropertyValue -Object $Track -Name "codec" -Default "")
        Language = [string](Get-PropertyValue -Object $p -Name "language" -Default "")
        Default = [bool](Get-PropertyValue -Object $p -Name "default_track" -Default $false)
        Forced = [bool](Get-PropertyValue -Object $p -Name "forced_track" -Default $false)
        Name = [string](Get-PropertyValue -Object $p -Name "track_name" -Default "")
    }
}

function Get-MkvStructure {
    param([Parameter(Mandatory = $true)][string]$Path)
    $json = (& mkvmerge.exe -J $Path | Out-String) | ConvertFrom-Json
    $tracks = @(Get-PropertyValue -Object $json -Name "tracks" -Default @())
    return [pscustomobject][ordered]@{
        raw = $json
        tracks = $tracks
        videoCount = @($tracks | Where-Object { [string](Get-PropertyValue -Object $_ -Name "type" -Default "") -eq "video" }).Count
        audioCount = @($tracks | Where-Object { [string](Get-PropertyValue -Object $_ -Name "type" -Default "") -eq "audio" }).Count
        subtitleCount = @($tracks | Where-Object { [string](Get-PropertyValue -Object $_ -Name "type" -Default "") -eq "subtitles" }).Count
        attachmentCount = @((Get-PropertyValue -Object $json -Name "attachments" -Default @())).Count
        chapterCount = @((Get-PropertyValue -Object $json -Name "chapters" -Default @())).Count
        nonVideo = @(
            $tracks |
                Where-Object { [string](Get-PropertyValue -Object $_ -Name "type" -Default "") -ne "video" } |
                ForEach-Object { Get-TrackSignature $_ }
        )
    }
}

function Test-Candidate {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)]$SourceInspection,
        [Parameter(Mandatory = $true)]$SourceStructure
    )

    $check = [ordered]@{
        exists = $false
        validatorPass = $false
        outcome = $null
        findingCodes = @()
        doviCount = $null
        hdr10 = $false
        videoMatches = $false
        durationDeltaSeconds = $null
        trackParity = $false
        counts = $null
        sourceFingerprint = $null
        candidateFingerprint = $null
        verified = $false
        reason = $null
    }

    if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
        $check.reason = "candidate_missing"
        return [pscustomobject]$check
    }
    $check.exists = $true

    $snapshot = Invoke-ValidatorSnapshot -MediaPath $Candidate -LibraryType "Movie" -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
    $check.outcome = $snapshot.outcome
    $check.findingCodes = @($snapshot.findingCodes)
    $check.candidateFingerprint = $snapshot.streamFingerprint
    $check.validatorPass = ($snapshot.outcome -eq "PASS")
    if (-not $check.validatorPass) {
        $check.reason = "candidate_not_validator_pass"
        return [pscustomobject]$check
    }

    $inspection = Get-DvVideoInspection -Path $Candidate
    $check.doviCount = $inspection.doviCount
    $check.hdr10 = (
        $inspection.doviCount -eq 0 -and
        $inspection.codec -eq "hevc" -and
        $inspection.colorTransfer -eq "smpte2084" -and
        $inspection.colorPrimaries -eq "bt2020"
    )
    if (-not $check.hdr10) {
        $check.reason = "candidate_not_clean_hdr10"
        return [pscustomobject]$check
    }

    $check.videoMatches = (
        $inspection.codec -eq $SourceInspection.codec -and
        $inspection.profile -eq $SourceInspection.profile -and
        $inspection.pixelFormat -eq $SourceInspection.pixelFormat -and
        $inspection.width -eq $SourceInspection.width -and
        $inspection.height -eq $SourceInspection.height -and
        $inspection.colorSpace -eq $SourceInspection.colorSpace -and
        $inspection.colorTransfer -eq $SourceInspection.colorTransfer -and
        $inspection.colorPrimaries -eq $SourceInspection.colorPrimaries
    )
    if (-not $check.videoMatches) {
        $check.reason = "candidate_video_properties_changed"
        return [pscustomobject]$check
    }

    $check.durationDeltaSeconds = [Math]::Abs([double]$SourceInspection.durationSeconds - [double]$inspection.durationSeconds)
    if ($check.durationDeltaSeconds -ge 0.100) {
        $check.reason = "candidate_duration_changed"
        return [pscustomobject]$check
    }

    $candidateStructure = Get-MkvStructure -Path $Candidate
    $difference = Compare-Object `
        -ReferenceObject @($SourceStructure.nonVideo) `
        -DifferenceObject @($candidateStructure.nonVideo) `
        -Property Type,Codec,Language,Default,Forced,Name

    $countsMatch = (
        $SourceStructure.videoCount -eq $candidateStructure.videoCount -and
        $SourceStructure.audioCount -eq $candidateStructure.audioCount -and
        $SourceStructure.subtitleCount -eq $candidateStructure.subtitleCount -and
        $SourceStructure.attachmentCount -eq $candidateStructure.attachmentCount -and
        $SourceStructure.chapterCount -eq $candidateStructure.chapterCount
    )

    $check.counts = [ordered]@{
        sourceVideo = $SourceStructure.videoCount
        candidateVideo = $candidateStructure.videoCount
        sourceAudio = $SourceStructure.audioCount
        candidateAudio = $candidateStructure.audioCount
        sourceSubtitles = $SourceStructure.subtitleCount
        candidateSubtitles = $candidateStructure.subtitleCount
        sourceAttachments = $SourceStructure.attachmentCount
        candidateAttachments = $candidateStructure.attachmentCount
        sourceChapters = $SourceStructure.chapterCount
        candidateChapters = $candidateStructure.chapterCount
    }
    $check.trackParity = ($countsMatch -and $null -eq $difference)
    if (-not $check.trackParity) {
        $check.reason = "candidate_nonvideo_structure_changed"
        return [pscustomobject]$check
    }

    $check.verified = $true
    $check.reason = $null
    return [pscustomobject]$check
}

function New-Candidate {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$TargetCandidate,
        [Parameter(Mandatory = $true)][string]$RawHevcPath,
        [Parameter(Mandatory = $true)]$SourceStructure
    )

    if (Test-Path -LiteralPath $TargetCandidate) { throw "Candidate already exists: $TargetCandidate" }
    if (Test-Path -LiteralPath $RawHevcPath) { throw "Temporary HEVC already exists: $RawHevcPath" }

    $directory = Split-Path -Parent $TargetCandidate
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    & dovi_tool remove -i $SourcePath -o $RawHevcPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $RawHevcPath -PathType Leaf)) {
        throw "dovi_tool remove failed."
    }

    $sourceVideo = @($SourceStructure.tracks | Where-Object { [string](Get-PropertyValue -Object $_ -Name "type" -Default "") -eq "video" })[0]
    $videoProps = Get-PropertyValue -Object $sourceVideo -Name "properties"
    $language = [string](Get-PropertyValue -Object $videoProps -Name "language" -Default "und")
    $defaultFlag = if ([bool](Get-PropertyValue -Object $videoProps -Name "default_track" -Default $false)) { "yes" } else { "no" }
    $forcedFlag = if ([bool](Get-PropertyValue -Object $videoProps -Name "forced_track" -Default $false)) { "yes" } else { "no" }
    $trackName = [string](Get-PropertyValue -Object $videoProps -Name "track_name" -Default "")

    $container = Get-PropertyValue -Object $SourceStructure.raw -Name "container"
    $containerProps = Get-PropertyValue -Object $container -Name "properties"
    $segmentTitle = [string](Get-PropertyValue -Object $containerProps -Name "title" -Default "")

    $args = @("-o", $TargetCandidate)
    if (-not [string]::IsNullOrWhiteSpace($segmentTitle)) { $args += @("--title", $segmentTitle) }
    $args += @("--language", ("0:{0}" -f $language), "--default-track-flag", ("0:{0}" -f $defaultFlag), "--forced-display-flag", ("0:{0}" -f $forcedFlag))
    if (-not [string]::IsNullOrWhiteSpace($trackName)) { $args += @("--track-name", ("0:{0}" -f $trackName)) }
    $args += @($RawHevcPath, "--no-video", $SourcePath)

    & mkvmerge.exe @args
    if ($LASTEXITCODE -gt 1 -or -not (Test-Path -LiteralPath $TargetCandidate -PathType Leaf)) {
        throw "mkvmerge candidate creation failed."
    }
}

function Restore-Original {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$CandidateOriginalPath,
        [Parameter(Mandatory = $true)][int]$ExpectedMovieId,
        [Parameter(Mandatory = $true)][int64]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$ExpectedFingerprint
    )

    $restore = [ordered]@{
        attempted = $true
        candidatePreserved = $false
        originalRestored = $false
        rescanCompleted = $false
        fingerprintVerified = $false
        error = $null
    }

    try {
        if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
            if (-not (Test-Path -LiteralPath $CandidateOriginalPath)) {
                Move-Item -LiteralPath $SourcePath -Destination $CandidateOriginalPath
                $restore.candidatePreserved = $true
            }
            else {
                $failedPath = $CandidateOriginalPath + ".failed-" + [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")
                Move-Item -LiteralPath $SourcePath -Destination $failedPath
                $restore.candidatePreserved = $true
            }
        }

        if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) { throw "Original backup missing during rollback." }
        Move-Item -LiteralPath $BackupPath -Destination $SourcePath
        $restore.originalRestored = $true

        $command = Invoke-Radarr -Connection $Connection -RelativePath "command" -Method POST -Body ([ordered]@{ name = "RescanMovie"; movieId = $ExpectedMovieId })
        $commandId = [int](Get-PropertyValue -Object $command -Name "id" -Default 0)
        if ($commandId -le 0) { throw "Radarr did not return a RescanMovie command id during rollback." }
        $done = Wait-RadarrCommand -Connection $Connection -CommandId $commandId
        if ([string](Get-PropertyValue -Object $done -Name "status" -Default "") -ne "completed") { throw "Rollback RescanMovie did not complete." }
        $restore.rescanCompleted = $true

        $item = Get-Item -LiteralPath $SourcePath
        if ([int64]$item.Length -ne $ExpectedBytes) { throw "Restored original size mismatch." }
        $snap = Invoke-ValidatorSnapshot -MediaPath $SourcePath -LibraryType "Movie" -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
        if (-not [string]::Equals($snap.streamFingerprint, $ExpectedFingerprint, [System.StringComparison]::Ordinal)) { throw "Restored original fingerprint mismatch." }
        $restore.fingerprintVerified = $true
    }
    catch {
        $restore.error = $_.Exception.Message
    }

    return [pscustomobject]$restore
}

if ($BuildCandidate -and $Execute) {
    throw "-BuildCandidate and -Execute are separate phases and cannot be combined."
}

$result = [ordered]@{
    schemaVersion = "1.0"
    scriptVersion = $ScriptVersion
    timestampUtc = [DateTime]::UtcNow.ToString("o")
    mode = if ($Execute) { "EXECUTE" } elseif ($BuildCandidate) { "BUILD_CANDIDATE" } else { "DRY_RUN" }
    status = "BLOCKED"
    reason = $null
    movieId = $MovieId
    chainId = $null
    chainPath = $null
    source = $null
    sourceSnapshot = $null
    dv = $null
    remediationDecision = $null
    candidatePath = $null
    temporaryHevcPath = $null
    candidate = $null
    arrFileMatches = $false
    mutation = [ordered]@{
        candidateBuilt = $false
        sourceBackedUp = $false
        candidatePromoted = $false
        radarrRescanSent = $false
        radarrReconciled = $false
        backupDeleted = $false
        temporaryHevcDeleted = $false
        chainUpdated = $false
        stateWritten = $false
    }
    rollback = $null
    statePath = $null
    error = $null
}

try {
    if ($MovieId -le 0) { $result.reason = "movie_id_invalid"; Write-Result ([pscustomobject]$result); exit 0 }
    foreach ($tool in @("ffprobe.exe", "mkvmerge.exe", "dovi_tool")) {
        if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) {
            $result.reason = "required_tool_missing_$tool"; Write-Result ([pscustomobject]$result); exit 0
        }
    }
    if (-not (Test-Path -LiteralPath $ValidatorPath -PathType Leaf)) { $result.reason = "validator_missing"; Write-Result ([pscustomobject]$result); exit 0 }
    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) { $result.reason = "validator_policy_missing"; Write-Result ([pscustomobject]$result); exit 0 }

    $chainPath = Get-ReacquisitionChainPath -IntegrationRoot $IntegrationRoot -Source "Radarr" -EntityId $MovieId
    $result.chainPath = $chainPath
    if (-not (Test-Path -LiteralPath $chainPath -PathType Leaf)) { $result.reason = "reacquisition_chain_missing"; Write-Result ([pscustomobject]$result); exit 0 }

    $chain = Get-Content -LiteralPath $chainPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $chainId = [string](Get-PropertyValue -Object $chain -Name "chainId" -Default "")
    $chainStatus = [string](Get-PropertyValue -Object $chain -Name "status" -Default "")
    $maxAttempts = [int](Get-PropertyValue -Object $chain -Name "maxAttempts" -Default 3)
    $failedAttemptCount = [int](Get-PropertyValue -Object $chain -Name "failedAttemptCount" -Default 0)
    $rollback = Get-PropertyValue -Object $chain -Name "rollback"
    $rollbackStatus = [string](Get-PropertyValue -Object $rollback -Name "status" -Default "")
    $sourcePath = [string](Get-PropertyValue -Object $rollback -Name "path" -Default "")
    $result.chainId = $chainId
    $result.source = $sourcePath

    if ($chainStatus -ne "TERMINAL_REVIEW_REQUIRED") { $result.reason = "chain_not_terminal_review_required"; Write-Result ([pscustomobject]$result); exit 0 }
    if ($failedAttemptCount -lt $maxAttempts) { $result.reason = "chain_attempt_ceiling_not_reached"; Write-Result ([pscustomobject]$result); exit 0 }
    if ($rollbackStatus -ne "RESTORED_TO_LIBRARY_TERMINAL") { $result.reason = "terminal_rollback_not_restored_to_library"; Write-Result ([pscustomobject]$result); exit 0 }

    $rollbackCheck = Test-ReacquisitionRollback -Rollback $rollback -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
    if (-not $rollbackCheck.verified) { $result.reason = "terminal_rollback_not_verified"; Write-Result ([pscustomobject]$result); exit 0 }

    $sourceSnapshot = Invoke-ValidatorSnapshot -MediaPath $sourcePath -LibraryType "Movie" -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
    $result.sourceSnapshot = [ordered]@{
        lengthBytes = $sourceSnapshot.lengthBytes
        streamFingerprint = $sourceSnapshot.streamFingerprint
        outcome = $sourceSnapshot.outcome
        findingCodes = @($sourceSnapshot.findingCodes)
    }

    $sourceInspection = Get-DvVideoInspection -Path $sourcePath
    $profile7LayerType = ""
    $profile7SampledFrames = $null
    if ($sourceInspection.dvProfile -eq 7) {
        try {
            $profile7Classification = Get-DvProfile7LayerClassification -Path $sourcePath
            $profile7LayerType = [string]$profile7Classification.layerType
            $profile7SampledFrames = [int]$profile7Classification.sampledFrames
        }
        catch {
            $result.reason = "dv_profile7_layer_classification_failed"
            $result.error = $_.Exception.Message
            Write-Result ([pscustomobject]$result)
            exit 0
        }
    }

    $result.dv = [ordered]@{
        profile = $sourceInspection.dvProfile
        level = $sourceInspection.dvLevel
        compatibilityId = $sourceInspection.compatibilityId
        rpuPresent = $sourceInspection.rpuPresent
        enhancementLayerPresent = $sourceInspection.enhancementLayerPresent
        baseLayerPresent = $sourceInspection.baseLayerPresent
        profile7LayerType = if ($sourceInspection.dvProfile -eq 7) { $profile7LayerType } else { $null }
        profile7ClassificationSampleFrames = $profile7SampledFrames
        colorTransfer = $sourceInspection.colorTransfer
        colorPrimaries = $sourceInspection.colorPrimaries
        colorSpace = $sourceInspection.colorSpace
    }

    $decision = Get-TerminalDvRemediationDecision `
        -ChainStatus $chainStatus `
        -FailedAttemptCount $failedAttemptCount `
        -MaxAttempts $maxAttempts `
        -RollbackVerified $rollbackCheck.verified `
        -CurrentOutcome $sourceSnapshot.outcome `
        -FindingCodes @($sourceSnapshot.findingCodes) `
        -DvProfile $sourceInspection.dvProfile `
        -CompatibilityId $sourceInspection.compatibilityId `
        -RpuPresent $sourceInspection.rpuPresent `
        -EnhancementLayerPresent $sourceInspection.enhancementLayerPresent `
        -BaseLayerPresent $sourceInspection.baseLayerPresent `
        -ColorTransfer $sourceInspection.colorTransfer `
        -ColorPrimaries $sourceInspection.colorPrimaries `
        -Profile7LayerType $profile7LayerType

    $result.remediationDecision = [ordered]@{
        remediationClass = $decision.remediationClass
        localRemediationType = $decision.localRemediationType
        videoReencoded = $decision.videoReencoded
        hdr10BaseLayerRetained = $decision.hdr10BaseLayerRetained
        enhancementLayerDiscarded = $decision.enhancementLayerDiscarded
        felResidualDiscarded = $decision.felResidualDiscarded
        terminalFallbackOnly = $decision.terminalFallbackOnly
    }

    if (-not $decision.eligible) { $result.reason = $decision.reason; Write-Result ([pscustomobject]$result); exit 0 }

    $connection = Get-RadarrConnection
    $files = @(Get-RecordArray -Response (Invoke-Radarr -Connection $connection -RelativePath ("moviefile?movieId={0}" -f $MovieId) -Method GET))
    $matching = @($files | Where-Object {
        Test-PathEquivalent -First ([string](Get-PropertyValue -Object $_ -Name "path" -Default "")) -Second $sourcePath
    })
    $result.arrFileMatches = ($matching.Count -eq 1 -and [int64](Get-PropertyValue -Object $matching[0] -Name "size" -Default -1) -eq [int64]$sourceSnapshot.lengthBytes)
    if (-not $result.arrFileMatches) { $result.reason = "radarr_terminal_file_mismatch"; Write-Result ([pscustomobject]$result); exit 0 }

    $sourceStructure = Get-MkvStructure -Path $sourcePath
    if ($sourceStructure.videoCount -ne 1) { $result.reason = "source_video_track_count_not_one"; Write-Result ([pscustomobject]$result); exit 0 }

    $sourceDriveRoot = [System.IO.Path]::GetPathRoot($sourcePath)
    $defaultRoot = Join-Path $sourceDriveRoot ("Reqestra Remediation\TerminalDV\{0}" -f $chainId)
    if ([string]::IsNullOrWhiteSpace($CandidatePath)) { $CandidatePath = Join-Path $defaultRoot "candidate.mkv" }
    if ([string]::IsNullOrWhiteSpace($TemporaryHevcPath)) { $TemporaryHevcPath = Join-Path $defaultRoot "base-layer.hevc" }
    $CandidatePath = [System.IO.Path]::GetFullPath($CandidatePath)
    $TemporaryHevcPath = [System.IO.Path]::GetFullPath($TemporaryHevcPath)
    $result.candidatePath = $CandidatePath
    $result.temporaryHevcPath = $TemporaryHevcPath

    if (Test-PathEquivalent -First $CandidatePath -Second $sourcePath) { $result.reason = "candidate_must_not_be_source_path"; Write-Result ([pscustomobject]$result); exit 0 }
    if ((Split-Path -Qualifier $CandidatePath) -ne (Split-Path -Qualifier $sourcePath)) { $result.reason = "candidate_must_be_same_volume_for_atomic_promotion"; Write-Result ([pscustomobject]$result); exit 0 }

    if ($BuildCandidate) {
        if ([string]::IsNullOrWhiteSpace($ConfirmChainId) -or $ConfirmChainId -ne $chainId -or
            [string]::IsNullOrWhiteSpace($ConfirmSourceFingerprint) -or $ConfirmSourceFingerprint -ne $sourceSnapshot.streamFingerprint) {
            $result.reason = "build_chain_and_source_confirmation_required"
            Write-Result ([pscustomobject]$result)
            exit 0
        }

        New-Candidate -SourcePath $sourcePath -TargetCandidate $CandidatePath -RawHevcPath $TemporaryHevcPath -SourceStructure $sourceStructure
        $result.mutation.candidateBuilt = $true
        $candidateCheck = Test-Candidate -SourcePath $sourcePath -Candidate $CandidatePath -SourceInspection $sourceInspection -SourceStructure $sourceStructure
        $result.candidate = $candidateCheck
        if (-not $candidateCheck.verified) { $result.reason = $candidateCheck.reason; Write-Result ([pscustomobject]$result); exit 0 }
        $result.status = "CANDIDATE_BUILT"
        $result.reason = $null
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $candidateCheck = Test-Candidate -SourcePath $sourcePath -Candidate $CandidatePath -SourceInspection $sourceInspection -SourceStructure $sourceStructure
    $result.candidate = $candidateCheck
    if (-not $candidateCheck.verified) {
        if ($candidateCheck.reason -eq "candidate_missing") {
            $result.status = "DRY_RUN_READY_BUILD"
            $result.reason = $null
        }
        else {
            $result.reason = $candidateCheck.reason
        }
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if (-not $Execute) {
        $result.status = "DRY_RUN_READY_REPLACE"
        $result.reason = $null
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($ConfirmChainId) -or $ConfirmChainId -ne $chainId -or
        [string]::IsNullOrWhiteSpace($ConfirmSourceFingerprint) -or $ConfirmSourceFingerprint -ne $sourceSnapshot.streamFingerprint) {
        $result.reason = "execute_chain_and_source_confirmation_required"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $mutex = New-Object System.Threading.Mutex($false, "ReqestraTerminalDvRemediation")
    $mutexHeld = $false
    try {
        $mutexHeld = $mutex.WaitOne(0)
        if (-not $mutexHeld) { $result.reason = "terminal_dv_mutex_busy"; Write-Result ([pscustomobject]$result); exit 0 }

        $freshChain = Get-Content -LiteralPath $chainPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string](Get-PropertyValue -Object $freshChain -Name "status" -Default "") -ne "TERMINAL_REVIEW_REQUIRED") {
            $result.reason = "chain_changed_before_execute"; Write-Result ([pscustomobject]$result); exit 0
        }
        $freshRollback = Get-PropertyValue -Object $freshChain -Name "rollback"
        $freshRollbackCheck = Test-ReacquisitionRollback -Rollback $freshRollback -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
        if (-not $freshRollbackCheck.verified) { $result.reason = "source_changed_before_execute"; Write-Result ([pscustomobject]$result); exit 0 }
        $freshSource = Invoke-ValidatorSnapshot -MediaPath $sourcePath -LibraryType "Movie" -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
        if (-not [string]::Equals($freshSource.streamFingerprint, $ConfirmSourceFingerprint, [System.StringComparison]::Ordinal)) {
            $result.reason = "source_fingerprint_changed_before_execute"; Write-Result ([pscustomobject]$result); exit 0
        }
        $freshCandidate = Test-Candidate -SourcePath $sourcePath -Candidate $CandidatePath -SourceInspection $sourceInspection -SourceStructure $sourceStructure
        if (-not $freshCandidate.verified) { $result.reason = "candidate_changed_before_execute"; Write-Result ([pscustomobject]$result); exit 0 }

        if (-not (Test-Path -LiteralPath $StateRoot)) { New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null }
        $statePath = Join-Path $StateRoot ($chainId + ".json")
        $result.statePath = $statePath
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $existingState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $existingStatus = [string](Get-PropertyValue -Object $existingState -Name "status" -Default "")
            if ($existingStatus -eq "COMPLETED") {
                $result.status = "TERMINAL_DV_REMEDIATION_ALREADY_COMPLETED"
                $result.reason = $null
                Write-Result ([pscustomobject]$result)
                exit 0
            }
            if ($existingStatus -notin @("ROLLED_BACK","RECOVERY_REQUIRED")) {
                $result.reason = "existing_terminal_dv_transaction_requires_recovery"; Write-Result ([pscustomobject]$result); exit 0
            }
        }

        $backupPath = $sourcePath + ".reqestra-dv-backup-" + [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")
        $state = [pscustomobject][ordered]@{
            schemaVersion = "1.0"
            scriptVersion = $ScriptVersion
            chainId = $chainId
            movieId = $MovieId
            status = "STARTED"
            stage = "PREPARED"
            sourcePath = $sourcePath
            sourceLengthBytes = [int64]$freshSource.lengthBytes
            sourceFingerprint = [string]$freshSource.streamFingerprint
            remediationClass = [string]$decision.remediationClass
            localRemediationType = [string]$decision.localRemediationType
            dvProfile = [int]$sourceInspection.dvProfile
            dvProfile7LayerType = if ($sourceInspection.dvProfile -eq 7) { $profile7LayerType } else { $null }
            enhancementLayerDiscarded = [bool]$decision.enhancementLayerDiscarded
            felResidualDiscarded = [bool]$decision.felResidualDiscarded
            terminalFallbackOnly = [bool]$decision.terminalFallbackOnly
            candidatePath = $CandidatePath
            candidateLengthBytes = [int64](Get-Item -LiteralPath $CandidatePath).Length
            candidateFingerprint = [string]$freshCandidate.candidateFingerprint
            backupPath = $backupPath
            startedUtc = [DateTime]::UtcNow.ToString("o")
            updatedUtc = [DateTime]::UtcNow.ToString("o")
            completedUtc = $null
            rollback = $null
        }
        Write-AtomicJson -Path $statePath -Object $state
        $result.mutation.stateWritten = $true

        Move-Item -LiteralPath $sourcePath -Destination $backupPath
        $result.mutation.sourceBackedUp = $true
        $state.stage = "SOURCE_BACKED_UP"
        $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
        Write-AtomicJson -Path $statePath -Object $state

        try {
            Move-Item -LiteralPath $CandidatePath -Destination $sourcePath
            $result.mutation.candidatePromoted = $true
            $state.stage = "CANDIDATE_PROMOTED"
            $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $statePath -Object $state

            $command = Invoke-Radarr -Connection $connection -RelativePath "command" -Method POST -Body ([ordered]@{ name = "RescanMovie"; movieId = $MovieId })
            $commandId = [int](Get-PropertyValue -Object $command -Name "id" -Default 0)
            if ($commandId -le 0) { throw "Radarr did not return a valid RescanMovie command id." }
            $result.mutation.radarrRescanSent = $true
            $done = Wait-RadarrCommand -Connection $connection -CommandId $commandId
            if ([string](Get-PropertyValue -Object $done -Name "status" -Default "") -ne "completed") { throw "RescanMovie did not complete." }

            $promotedItem = Get-Item -LiteralPath $sourcePath
            $filesAfter = @(Get-RecordArray -Response (Invoke-Radarr -Connection $connection -RelativePath ("moviefile?movieId={0}" -f $MovieId) -Method GET))
            $arrAfter = @($filesAfter | Where-Object {
                Test-PathEquivalent -First ([string](Get-PropertyValue -Object $_ -Name "path" -Default "")) -Second $sourcePath
            })
            if ($arrAfter.Count -ne 1 -or [int64](Get-PropertyValue -Object $arrAfter[0] -Name "size" -Default -1) -ne [int64]$promotedItem.Length) {
                throw "Radarr did not reconcile the promoted HDR10 file."
            }

            $finalSnapshot = Invoke-ValidatorSnapshot -MediaPath $sourcePath -LibraryType "Movie" -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
            if ($finalSnapshot.outcome -ne "PASS") { throw "Promoted file failed MediaValidator after replacement." }
            if (-not [string]::Equals($finalSnapshot.streamFingerprint, $freshCandidate.candidateFingerprint, [System.StringComparison]::Ordinal)) {
                throw "Promoted file fingerprint differs from validated candidate."
            }
            $finalInspection = Get-DvVideoInspection -Path $sourcePath
            if ($finalInspection.doviCount -ne 0 -or $finalInspection.colorTransfer -ne "smpte2084" -or $finalInspection.colorPrimaries -ne "bt2020") {
                throw "Promoted file is not clean HDR10 after replacement."
            }
            $result.mutation.radarrReconciled = $true

            Remove-Item -LiteralPath $backupPath -Force
            $result.mutation.backupDeleted = $true

            if (-not [string]::IsNullOrWhiteSpace($TemporaryHevcPath) -and (Test-Path -LiteralPath $TemporaryHevcPath -PathType Leaf)) {
                Remove-Item -LiteralPath $TemporaryHevcPath -Force
                $result.mutation.temporaryHevcDeleted = $true
            }

            $freshChain.status = "COMPLETED_LOCAL_REMEDIATION"
            $freshChain.updatedUtc = [DateTime]::UtcNow.ToString("o")
            $freshChain | Add-Member -NotePropertyName "localRemediation" -NotePropertyValue ([pscustomobject][ordered]@{
                type = [string]$decision.localRemediationType
                remediationClass = [string]$decision.remediationClass
                completedUtc = [DateTime]::UtcNow.ToString("o")
                sourceFingerprint = $freshSource.streamFingerprint
                replacementFingerprint = $finalSnapshot.streamFingerprint
                replacementPath = $sourcePath
                dvProfile = [int]$sourceInspection.dvProfile
                dvProfile7LayerType = if ($sourceInspection.dvProfile -eq 7) { $profile7LayerType } else { $null }
                videoReencoded = [bool]$decision.videoReencoded
                hdr10BaseLayerRetained = [bool]$decision.hdr10BaseLayerRetained
                enhancementLayerDiscarded = [bool]$decision.enhancementLayerDiscarded
                felResidualDiscarded = [bool]$decision.felResidualDiscarded
                terminalFallbackOnly = [bool]$decision.terminalFallbackOnly
                doviToolVersion = (& dovi_tool --version | Out-String).Trim()
                result = "PASS"
            }) -Force

            $chainRollback = Get-PropertyValue -Object $freshChain -Name "rollback"
            $chainRollback | Add-Member -NotePropertyName "status" -NotePropertyValue "RETIRED_AFTER_LOCAL_REMEDIATION" -Force
            $chainRollback | Add-Member -NotePropertyName "retiredUtc" -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
            Write-AtomicJson -Path $chainPath -Object $freshChain
            $result.mutation.chainUpdated = $true

            $state.status = "COMPLETED"
            $state.stage = "RADARR_RECONCILED_BACKUP_RETIRED"
            $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
            $state.completedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $statePath -Object $state

            $result.status = "TERMINAL_DV_REMEDIATED"
            $result.reason = $null
            $result.sourceSnapshot = [ordered]@{
                lengthBytes = $finalSnapshot.lengthBytes
                streamFingerprint = $finalSnapshot.streamFingerprint
                outcome = $finalSnapshot.outcome
                findingCodes = @($finalSnapshot.findingCodes)
            }
            Write-Result ([pscustomobject]$result)
            exit 0
        }
        catch {
            $restore = Restore-Original `
                -Connection $connection `
                -SourcePath $sourcePath `
                -BackupPath $backupPath `
                -CandidateOriginalPath $CandidatePath `
                -ExpectedMovieId $MovieId `
                -ExpectedBytes ([int64]$freshSource.lengthBytes) `
                -ExpectedFingerprint ([string]$freshSource.streamFingerprint)
            $result.rollback = $restore
            $state.rollback = $restore
            $state.status = if ($restore.originalRestored -and $restore.fingerprintVerified) { "ROLLED_BACK" } else { "RECOVERY_REQUIRED" }
            $state.stage = "POST_PROMOTION_FAILURE"
            $state.updatedUtc = [DateTime]::UtcNow.ToString("o")
            $state.completedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $statePath -Object $state
            $result.status = $state.status
            $result.reason = "post_promotion_verification_failed"
            $result.error = $_.Exception.Message
            Write-Result ([pscustomobject]$result)
            exit 0
        }
    }
    finally {
        if ($mutexHeld) { $mutex.ReleaseMutex() | Out-Null }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}
catch {
    $result.status = "ERROR"
    $result.reason = "unhandled_exception"
    $result.error = $_.Exception.Message
    Write-Result ([pscustomobject]$result)
    exit 1
}
