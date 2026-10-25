[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ })]
    [string]$Path,

    [ValidateSet("Auto", "Movie", "TV")]
    [string]$LibraryType = "Auto",

    [string]$PreferredLanguage = "",

    [string]$OriginalLanguage = "",

    [string]$FfprobePath = "ffprobe",

    [string]$PolicyPath = (Join-Path $PSScriptRoot "validator-policy.json"),

    [string]$JsonOut = "",

    [string]$LogPath = "",

    [ValidateSet("Human", "Json")]
    [string]$OutputFormat = "Human",

    [string]$AuditOutputDirectory = "",

    [int]$MaxFiles = 0,

    [switch]$NoRecurse,

    [ValidateRange(1, 600)]
    [int]$ProbeTimeoutSeconds = 15,

    [switch]$ExitZero
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ValidatorVersion = "0.2.6"
$SchemaVersion = "1.1"

trap {
    $line = $_.InvocationInfo.ScriptLineNumber
    $position = $_.InvocationInfo.PositionMessage
    Write-Host ""
    Write-Host "Validator internal error" -ForegroundColor Red
    Write-Host ("Line: {0}" -f $line) -ForegroundColor Red
    Write-Host ("Message: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($position) {
        Write-Host $position -ForegroundColor DarkGray
    }
    exit 99
}

function Get-Prop {
    param(
        [Parameter(Mandatory = $true)]$Object,
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

    switch ($Language.Trim().ToLowerInvariant()) {
        { $_ -in @("en", "eng", "english") } { return "eng" }
        { $_ -in @("fr", "fra", "fre", "french", "francais", "français") } { return "fra" }
        { $_ -in @("ja", "jpn", "japanese") } { return "jpn" }
        { $_ -in @("es", "spa", "spanish") } { return "spa" }
        { $_ -in @("de", "deu", "ger", "german") } { return "deu" }
        { $_ -in @("it", "ita", "italian") } { return "ita" }
        default { return $Language.Trim().ToLowerInvariant() }
    }
}

function Get-DispositionValue {
    param(
        $Stream,
        [string]$Name
    )

    $disposition = Get-Prop $Stream "disposition"
    if ($null -eq $disposition) {
        return 0
    }

    $value = Get-Prop $disposition $Name 0
    try {
        return [int]$value
    }
    catch {
        return 0
    }
}

function Get-TagValue {
    param(
        $Stream,
        [string]$Name
    )

    $tags = Get-Prop $Stream "tags"
    if ($null -eq $tags) {
        return ""
    }

    $value = Get-Prop $tags $Name ""
    if ($null -eq $value) {
        return ""
    }

    return [string]$value
}

function Resolve-LibraryType {
    param(
        [string]$RequestedType,
        [string]$MediaPath
    )

    if ($RequestedType -ne "Auto") {
        return $RequestedType
    }

    if ($MediaPath -match '(?i)[\\/](Movies?)[\\/]') {
        return "Movie"
    }

    if ($MediaPath -match '(?i)[\\/](TV Shows?|Television)[\\/]') {
        return "TV"
    }

    return "Unknown"
}

function Get-HdrType {
    param(
        $VideoStream
    )

    $sideDataList = @(Get-Prop $VideoStream "side_data_list" @())

    foreach ($sideData in $sideDataList) {
        $sideDataType = [string](Get-Prop $sideData "side_data_type" "")

        if ($sideDataType -match '(?i)\bDOVI\b|Dolby Vision') {
            return "Dolby Vision"
        }

        $dvProfile = Get-Prop $sideData "dv_profile" $null
        if ($null -ne $dvProfile -and [string]$dvProfile -ne "") {
            return "Dolby Vision"
        }
    }

    foreach ($sideData in $sideDataList) {
        $sideDataType = [string](Get-Prop $sideData "side_data_type" "")

        if ($sideDataType -match '(?i)HDR Dynamic Metadata SMPTE2094-40|HDR10\+') {
            return "HDR10+"
        }
    }

    $transfer = [string](Get-Prop $VideoStream "color_transfer" "")
    $primaries = [string](Get-Prop $VideoStream "color_primaries" "")

    if ($transfer -eq "smpte2084") {
        if ($primaries -eq "bt2020") {
            return "HDR10"
        }
        return "PQ HDR"
    }

    if ($transfer -eq "arib-std-b67") {
        return "HLG"
    }

    if ([string]::IsNullOrWhiteSpace($transfer) -or $transfer -eq "unknown") {
        return "Unknown"
    }

    return "SDR"
}

function New-Finding {
    param(
        [ValidateSet("INFO", "NORMALIZE", "REVIEW", "REACQUIRE")]
        [string]$Severity,
        [string]$Code,
        [string]$Message,
        $Details = $null
    )

    $item = [ordered]@{
        severity = $Severity
        code = $Code
        message = $Message
    }

    if ($null -ne $Details) {
        $item["details"] = $Details
    }

    return [pscustomobject]$item
}

function Get-Outcome {
    param([object[]]$Findings)

    $severityRank = @{
        "INFO" = 0
        "NORMALIZE" = 1
        "REVIEW" = 2
        "REACQUIRE" = 3
    }

    $outcome = "PASS"
    $highestRank = 0

    foreach ($finding in @($Findings)) {
        $rank = $severityRank[[string]$finding.severity]
        if ($rank -gt $highestRank) {
            $highestRank = $rank
            $outcome = [string]$finding.severity
        }
    }

    return $outcome
}

function Get-OutcomeExitCode {
    param([string]$Outcome)

    switch ($Outcome) {
        "PASS" { return 0 }
        "NORMALIZE" { return 10 }
        "REVIEW" { return 20 }
        "REACQUIRE" { return 30 }
        default { return 99 }
    }
}

function Get-LegacyFingerprints {
    param(
        [string]$MediaPath,
        [object[]]$AudioSummaries
    )

    $fingerprints = @()

    if ([System.IO.Path]::GetFileName($MediaPath) -match '(?i)\.ACConverted(?:\.|$)') {
        $fingerprints += "filename.acconverted"
    }

    foreach ($audio in @($AudioSummaries)) {
        if ([string]$audio.title -match '(?i)^\s*Transcoded Compatibility Track\s*$') {
            $fingerprints += "audio.transcoded_compatibility_track"
            break
        }
    }

    return @($fingerprints | Select-Object -Unique)
}


function ConvertTo-NativeArgument {
    param([string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    # Win32 command-line quoting for paths/arguments with spaces.
    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-FfprobeWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $argumentString = (@($Arguments | ForEach-Object {
        ConvertTo-NativeArgument -Argument ([string]$_)
    })) -join " "

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = $argumentString
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
    }
    catch {
        return [pscustomobject][ordered]@{
            stdout = ""
            stderr = $_.Exception.Message
            exitCode = -1
            timedOut = $false
        }
    }

    # Read both pipes asynchronously so a noisy/corrupt file cannot deadlock
    # because stdout or stderr fills its OS pipe buffer.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $finished = $process.WaitForExit($TimeoutSeconds * 1000)

    if (-not $finished) {
        try {
            $process.Kill()
        }
        catch {
        }

        try {
            [void]$process.WaitForExit(5000)
        }
        catch {
        }

        $stdout = ""
        $stderr = ""

        try { $stdout = $stdoutTask.Result } catch {}
        try { $stderr = $stderrTask.Result } catch {}

        $process.Dispose()

        return [pscustomobject][ordered]@{
            stdout = $stdout
            stderr = $stderr
            exitCode = -2
            timedOut = $true
        }
    }

    # Flush asynchronous stream readers after process exit.
    $process.WaitForExit()

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()

    return [pscustomobject][ordered]@{
        stdout = $stdout
        stderr = $stderr
        exitCode = $exitCode
        timedOut = $false
    }
}


function Convert-RationalToDouble {
    param($Value)

    if ($null -eq $Value) {
        return 0.0
    }

    $textValue = [string]$Value
    if ([string]::IsNullOrWhiteSpace($textValue) -or $textValue -eq "0/0") {
        return 0.0
    }

    if ($textValue -match '^\s*(-?\d+(?:\.\d+)?)\s*/\s*(-?\d+(?:\.\d+)?)\s*$') {
        $numerator = 0.0
        $denominator = 0.0

        if ([double]::TryParse($Matches[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$numerator) -and
            [double]::TryParse($Matches[2], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$denominator) -and
            $denominator -ne 0) {
            return $numerator / $denominator
        }

        return 0.0
    }

    $parsed = 0.0
    if ([double]::TryParse($textValue, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }

    return 0.0
}

function Test-AuxiliaryVideoStream {
    param($Stream)

    if ((Get-DispositionValue $Stream "attached_pic") -eq 1) {
        return $true
    }

    $codec = ([string](Get-Prop $Stream "codec_name" "")).ToLowerInvariant()

    # These codecs can represent motion video, so codec alone is never enough
    # to classify them as artwork. Require strong still/thumbnail evidence.
    $imageLikeCodecs = @(
        "png",
        "mjpeg",
        "mjpegb",
        "jpeg2000",
        "bmp",
        "gif",
        "webp",
        "tiff"
    )

    if ($codec -notin $imageLikeCodecs) {
        return $false
    }

    $isDefault = (Get-DispositionValue $Stream "default") -eq 1
    if ($isDefault) {
        return $false
    }

    # Non-default PNG streams in this movie/TV library are auxiliary image
    # data, not alternate motion-picture presentations.
    if ($codec -eq "png") {
        return $true
    }

    $frameCount = 0L
    $frameCountKnown = $false
    $frameCountRaw = Get-Prop $Stream "nb_frames" $null

    if ($null -ne $frameCountRaw) {
        $frameCountKnown = [long]::TryParse([string]$frameCountRaw, [ref]$frameCount)
    }

    $avgFrameRate = Convert-RationalToDouble (Get-Prop $Stream "avg_frame_rate" "")
    $nominalFrameRate = Convert-RationalToDouble (Get-Prop $Stream "r_frame_rate" "")

    # A handful of frames spread across an episode is thumbnail/chapter-art
    # behavior, not a second presentation of the episode.
    if ($frameCountKnown -and $frameCount -ge 0 -and $frameCount -le 10) {
        return $true
    }

    # Very-low-rate image streams are likewise treated as auxiliary.
    if ($avgFrameRate -gt 0 -and $avgFrameRate -le 0.5) {
        return $true
    }

    if ($avgFrameRate -le 0 -and $nominalFrameRate -gt 0 -and $nominalFrameRate -le 1.0) {
        return $true
    }

    # Sparse image-like streams can be reported with no meaningful average
    # frame rate but an implausibly high nominal rate (observed: MJPEG 1000fps,
    # one packet in a 10-second sample). Treat that pattern as auxiliary.
    if ($avgFrameRate -le 0 -and $nominalFrameRate -ge 120.0) {
        return $true
    }

    return $false
}

function Invoke-MediaValidation {
    param(
        [Parameter(Mandatory = $true)][string]$MediaPath,
        [Parameter(Mandatory = $true)]$Policy,
        [Parameter(Mandatory = $true)][string]$RequestedLibraryType,
        [Parameter(Mandatory = $true)][string]$PreferredLanguageNormalized,
        [Parameter(Mandatory = $true)][string]$OriginalLanguageNormalized,
        [Parameter(Mandatory = $true)][string]$FfprobeExecutable,
        [Parameter(Mandatory = $true)][int]$FfprobeTimeoutSeconds
    )

    $resolvedPath = (Resolve-Path -LiteralPath $MediaPath).Path
    $resolvedLibraryType = Resolve-LibraryType -RequestedType $RequestedLibraryType -MediaPath $resolvedPath

    $ffprobeEntries = @(
        "stream=index,codec_type,codec_name,profile,width,height,pix_fmt,color_range,color_space,color_transfer,color_primaries,channels,channel_layout,bit_rate,r_frame_rate,avg_frame_rate,nb_frames,duration",
        "stream_tags=language,title",
        "stream_disposition=default,forced,hearing_impaired,comment,attached_pic",
        "stream_side_data",
        "format=format_name,format_long_name,duration,size,bit_rate"
    ) -join ":"

    $ffprobeArgs = @(
        "-v", "error",
        "-print_format", "json",
        "-show_entries", $ffprobeEntries,
        $resolvedPath
    )

    $probeExecution = Invoke-FfprobeWithTimeout `
        -Executable $FfprobeExecutable `
        -Arguments $ffprobeArgs `
        -TimeoutSeconds $FfprobeTimeoutSeconds

    $rawProbe = [string]$probeExecution.stdout
    $probeStderr = [string]$probeExecution.stderr
    $ffprobeExitCode = [int]$probeExecution.exitCode

    if ($probeExecution.timedOut) {
        $timeoutFinding = New-Finding -Severity "REVIEW" -Code "probe.timeout" -Message "ffprobe exceeded the per-file probe timeout and was terminated so the audit could continue." -Details @{
            timeoutSeconds = $FfprobeTimeoutSeconds
            stderr = $probeStderr
        }

        return [pscustomobject][ordered]@{
            schemaVersion = $SchemaVersion
            validatorVersion = $ValidatorVersion
            timestampUtc = [DateTime]::UtcNow.ToString("o")
            path = $resolvedPath
            libraryType = $resolvedLibraryType
            preferredLanguage = if ($PreferredLanguageNormalized -eq "und") { $null } else { $PreferredLanguageNormalized }
            originalLanguage = if ($OriginalLanguageNormalized -eq "und") { $null } else { $OriginalLanguageNormalized }
            outcome = "REVIEW"
            exitCode = 20
            summary = [ordered]@{
                videoStreams = 0
                audioStreams = 0
                subtitleStreams = 0
            }
            format = $null
            video = @()
            auxiliaryVideo = @()
            audio = @()
            subtitles = @()
            probe = [ordered]@{
                exitCode = $ffprobeExitCode
                stderr = $probeStderr
                timedOut = $true
                timeoutSeconds = $FfprobeTimeoutSeconds
            }
            legacy = [ordered]@{
                detected = $false
                fingerprints = @()
            }
            findings = @($timeoutFinding)
        }
    }

    if ($ffprobeExitCode -ne 0) {
        $failureFinding = New-Finding -Severity "REVIEW" -Code "probe.failed" -Message "ffprobe could not read the file." -Details @{
            exitCode = $ffprobeExitCode
            stderr = $probeStderr
        }

        return [pscustomobject][ordered]@{
            schemaVersion = $SchemaVersion
            validatorVersion = $ValidatorVersion
            timestampUtc = [DateTime]::UtcNow.ToString("o")
            path = $resolvedPath
            libraryType = $resolvedLibraryType
            preferredLanguage = if ($PreferredLanguageNormalized -eq "und") { $null } else { $PreferredLanguageNormalized }
            originalLanguage = if ($OriginalLanguageNormalized -eq "und") { $null } else { $OriginalLanguageNormalized }
            outcome = "REVIEW"
            exitCode = 20
            summary = [ordered]@{
                videoStreams = 0
                audioStreams = 0
                subtitleStreams = 0
            }
            format = $null
            video = @()
            auxiliaryVideo = @()
            audio = @()
            subtitles = @()
            probe = [ordered]@{
                exitCode = $ffprobeExitCode
                stderr = $probeStderr
                timedOut = $false
                timeoutSeconds = $FfprobeTimeoutSeconds
            }
            legacy = [ordered]@{
                detected = $false
                fingerprints = @()
            }
            findings = @($failureFinding)
        }
    }

    try {
        $probe = $rawProbe | ConvertFrom-Json
    }
    catch {
        $jsonFinding = New-Finding -Severity "REVIEW" -Code "probe.invalid_json" -Message "ffprobe returned restricted stdout that could not be parsed as JSON." -Details @{
            parseError = $_.Exception.Message
            stderr = $probeStderr
            stdoutPreview = if ($rawProbe.Length -gt 1000) { $rawProbe.Substring(0, 1000) } else { $rawProbe }
        }

        return [pscustomobject][ordered]@{
            schemaVersion = $SchemaVersion
            validatorVersion = $ValidatorVersion
            timestampUtc = [DateTime]::UtcNow.ToString("o")
            path = $resolvedPath
            libraryType = $resolvedLibraryType
            preferredLanguage = if ($PreferredLanguageNormalized -eq "und") { $null } else { $PreferredLanguageNormalized }
            originalLanguage = if ($OriginalLanguageNormalized -eq "und") { $null } else { $OriginalLanguageNormalized }
            outcome = "REVIEW"
            exitCode = 20
            summary = [ordered]@{
                videoStreams = 0
                audioStreams = 0
                subtitleStreams = 0
            }
            format = $null
            video = @()
            auxiliaryVideo = @()
            audio = @()
            subtitles = @()
            probe = [ordered]@{
                exitCode = $ffprobeExitCode
                stderr = $probeStderr
                timedOut = $false
                timeoutSeconds = $FfprobeTimeoutSeconds
            }
            legacy = [ordered]@{
                detected = $false
                fingerprints = @()
            }
            findings = @($jsonFinding)
        }
    }

    $streams = @(Get-Prop $probe "streams" @())

    $allVideoStreams = @($streams | Where-Object {
        (Get-Prop $_ "codec_type" "") -eq "video"
    })

    $auxiliaryVideoStreams = @($allVideoStreams | Where-Object {
        Test-AuxiliaryVideoStream $_
    })

    $videoStreams = @($allVideoStreams | Where-Object {
        -not (Test-AuxiliaryVideoStream $_)
    })

    $audioStreams = @($streams | Where-Object { (Get-Prop $_ "codec_type" "") -eq "audio" })
    $subtitleStreams = @($streams | Where-Object { (Get-Prop $_ "codec_type" "") -eq "subtitle" })

    $findings = @()

    if (-not [string]::IsNullOrWhiteSpace($probeStderr)) {
        $findings += New-Finding -Severity "REVIEW" -Code "probe.diagnostic_error" -Message "ffprobe produced error-level diagnostics while still returning parseable media metadata." -Details @{
            stderr = $probeStderr.Trim()
            exitCode = $ffprobeExitCode
        }
    }

    if ($videoStreams.Count -eq 0) {
        $findings += New-Finding -Severity "REVIEW" -Code "video.missing" -Message "No playable video stream was detected."
    }
    elseif ($videoStreams.Count -gt 1) {
        $findings += New-Finding -Severity "REVIEW" -Code "video.multiple" -Message "Multiple playable video streams were detected." -Details @{
            count = $videoStreams.Count
        }
    }

    $videoSummaries = @()

    foreach ($video in $videoStreams) {
        $codec = ([string](Get-Prop $video "codec_name" "")).ToLowerInvariant()
        $index = Get-Prop $video "index" -1
        $width = Get-Prop $video "width" 0
        $height = Get-Prop $video "height" 0
        $profile = [string](Get-Prop $video "profile" "")
        $pixelFormat = [string](Get-Prop $video "pix_fmt" "")
        $hdrType = Get-HdrType -VideoStream $video
        $bitDepth = $null

        if ($pixelFormat -match '(?<depth>10|12)') {
            $bitDepth = [int]$Matches["depth"]
        }
        elseif ($pixelFormat) {
            $bitDepth = 8
        }

        $videoSummaries += [pscustomobject][ordered]@{
            index = $index
            codec = $codec
            profile = $profile
            width = $width
            height = $height
            pixelFormat = $pixelFormat
            bitDepth = $bitDepth
            hdr = $hdrType
            colorPrimaries = [string](Get-Prop $video "color_primaries" "")
            colorTransfer = [string](Get-Prop $video "color_transfer" "")
            colorSpace = [string](Get-Prop $video "color_space" "")
        }

        if ($hdrType -eq "Dolby Vision") {
            $findings += New-Finding -Severity "REACQUIRE" -Code "video.dolby_vision" -Message "Dolby Vision metadata was detected in the actual video stream." -Details @{
                streamIndex = $index
            }
        }

        $hardRejectCodecs = @($Policy.video.hardRejectCodecs | ForEach-Object { ([string]$_).ToLowerInvariant() })
        if ($codec -and $codec -in $hardRejectCodecs) {
            $findings += New-Finding -Severity "REACQUIRE" -Code "video.codec_prohibited" -Message "The video codec '$codec' is prohibited by media policy." -Details @{
                streamIndex = $index
                codec = $codec
            }
        }

        if (-not $codec) {
            $findings += New-Finding -Severity "REVIEW" -Code "video.codec_unknown" -Message "The video codec could not be identified." -Details @{
                streamIndex = $index
            }
        }

        if ($height -and $height -lt 360) {
            $findings += New-Finding -Severity "INFO" -Code "video.unusually_low_resolution" -Message "Video resolution is unusually low; retained as inventory information only." -Details @{
                streamIndex = $index
                width = $width
                height = $height
            }
        }
    }

    $auxiliaryVideoSummaries = @()

    foreach ($video in $auxiliaryVideoStreams) {
        $auxiliaryVideoSummaries += [pscustomobject][ordered]@{
            index = Get-Prop $video "index" -1
            codec = ([string](Get-Prop $video "codec_name" "")).ToLowerInvariant()
            width = Get-Prop $video "width" 0
            height = Get-Prop $video "height" 0
            attachedPic = (Get-DispositionValue $video "attached_pic") -eq 1
            default = (Get-DispositionValue $video "default") -eq 1
            frameCount = Get-Prop $video "nb_frames" $null
            averageFrameRate = [string](Get-Prop $video "avg_frame_rate" "")
            nominalFrameRate = [string](Get-Prop $video "r_frame_rate" "")
            durationSeconds = Get-Prop $video "duration" $null
        }
    }

    $audioSummaries = @()

    foreach ($audio in $audioStreams) {
        $index = Get-Prop $audio "index" -1
        $language = Normalize-Language (Get-TagValue $audio "language")
        $title = Get-TagValue $audio "title"
        $isDefault = (Get-DispositionValue $audio "default") -eq 1
        $isCommentaryDisposition = (Get-DispositionValue $audio "comment") -eq 1
        $isCommentaryTitle = $false

        foreach ($pattern in @($Policy.audio.commentaryPatterns)) {
            if ($title -match [regex]::Escape([string]$pattern)) {
                $isCommentaryTitle = $true
                break
            }
        }

        $isCommentary = $isCommentaryDisposition -or $isCommentaryTitle

        $audioSummaries += [pscustomobject][ordered]@{
            index = $index
            codec = [string](Get-Prop $audio "codec_name" "")
            profile = [string](Get-Prop $audio "profile" "")
            language = $language
            title = $title
            channels = Get-Prop $audio "channels" 0
            channelLayout = [string](Get-Prop $audio "channel_layout" "")
            bitRate = Get-Prop $audio "bit_rate" $null
            default = $isDefault
            commentary = $isCommentary
        }

        if ($isDefault -and $isCommentary) {
            $findings += New-Finding -Severity "NORMALIZE" -Code "audio.commentary_default" -Message "A commentary audio track is marked as default." -Details @{
                streamIndex = $index
                language = $language
                title = $title
            }
        }
    }

    if ($audioStreams.Count -eq 0) {
        $findings += New-Finding -Severity "REACQUIRE" -Code "audio.missing" -Message "No audio stream was detected."
    }
    else {
        $defaultAudio = @($audioSummaries | Where-Object { $_.default })

        if ($defaultAudio.Count -eq 0) {
            $findings += New-Finding -Severity "NORMALIZE" -Code "audio.no_default" -Message "No audio track is marked as default."
        }
        elseif ($defaultAudio.Count -gt 1) {
            $findings += New-Finding -Severity "NORMALIZE" -Code "audio.multiple_defaults" -Message "Multiple audio tracks are marked as default." -Details @{
                streamIndexes = @($defaultAudio | ForEach-Object { $_.index })
            }
        }

        if ($PreferredLanguageNormalized -ne "und") {
            $preferredTracks = @($audioSummaries | Where-Object {
                $_.language -eq $PreferredLanguageNormalized -and -not $_.commentary
            })
            $preferredDefaults = @($preferredTracks | Where-Object { $_.default })

            if ($preferredTracks.Count -gt 0 -and $preferredDefaults.Count -eq 0) {
                $findings += New-Finding -Severity "NORMALIZE" -Code "audio.preferred_language_not_default" -Message "A preferred-language audio track exists but is not the default." -Details @{
                    preferredLanguage = $PreferredLanguageNormalized
                    candidateStreamIndexes = @($preferredTracks | ForEach-Object { $_.index })
                }
            }
            elseif ($preferredTracks.Count -eq 0) {
                $findings += New-Finding -Severity "INFO" -Code "audio.preferred_language_missing" -Message "No non-commentary preferred-language audio track was found." -Details @{
                    preferredLanguage = $PreferredLanguageNormalized
                }
            }
        }
    }

    $subtitleSummaries = @()

    foreach ($subtitle in $subtitleStreams) {
        $codec = ([string](Get-Prop $subtitle "codec_name" "")).ToLowerInvariant()
        $index = Get-Prop $subtitle "index" -1
        $language = Normalize-Language (Get-TagValue $subtitle "language")
        $title = Get-TagValue $subtitle "title"

        $subtitleSummaries += [pscustomobject][ordered]@{
            index = $index
            codec = $codec
            language = $language
            title = $title
            default = (Get-DispositionValue $subtitle "default") -eq 1
            forced = (Get-DispositionValue $subtitle "forced") -eq 1
            hearingImpaired = (Get-DispositionValue $subtitle "hearing_impaired") -eq 1
        }
    }

    if ($subtitleStreams.Count -gt 0) {
        $textSubtitleCodecs = @($Policy.subtitles.textCodecs | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $imageSubtitleCodecs = @($Policy.subtitles.imageCodecs | ForEach-Object { ([string]$_).ToLowerInvariant() })

        $textSubs = @($subtitleSummaries | Where-Object { $_.codec -in $textSubtitleCodecs })
        $imageSubs = @($subtitleSummaries | Where-Object { $_.codec -in $imageSubtitleCodecs })

        if ($imageSubs.Count -gt 0 -and $textSubs.Count -eq 0) {
            $findings += New-Finding -Severity "INFO" -Code "subtitle.image_only" -Message "Only image-based subtitles were detected; a text subtitle may improve client compatibility." -Details @{
                imageSubtitleCount = $imageSubs.Count
            }
        }
    }

    $formatObject = Get-Prop $probe "format"
    $formatSummary = [pscustomobject][ordered]@{
        name = [string](Get-Prop $formatObject "format_name" "")
        longName = [string](Get-Prop $formatObject "format_long_name" "")
        durationSeconds = Get-Prop $formatObject "duration" $null
        sizeBytes = Get-Prop $formatObject "size" $null
        bitRate = Get-Prop $formatObject "bit_rate" $null
    }

    $legacyFingerprints = @(Get-LegacyFingerprints -MediaPath $resolvedPath -AudioSummaries $audioSummaries)
    $outcome = Get-Outcome -Findings $findings
    $exitCode = Get-OutcomeExitCode -Outcome $outcome

    return [pscustomobject][ordered]@{
        schemaVersion = $SchemaVersion
        validatorVersion = $ValidatorVersion
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        path = $resolvedPath
        libraryType = $resolvedLibraryType
        preferredLanguage = if ($PreferredLanguageNormalized -eq "und") { $null } else { $PreferredLanguageNormalized }
        originalLanguage = if ($OriginalLanguageNormalized -eq "und") { $null } else { $OriginalLanguageNormalized }
        outcome = $outcome
        exitCode = $exitCode
        summary = [pscustomobject][ordered]@{
            videoStreams = $videoStreams.Count
            auxiliaryVideoStreams = $auxiliaryVideoStreams.Count
            audioStreams = $audioStreams.Count
            subtitleStreams = $subtitleStreams.Count
        }
        format = $formatSummary
        video = @($videoSummaries)
        auxiliaryVideo = @($auxiliaryVideoSummaries)
        audio = @($audioSummaries)
        subtitles = @($subtitleSummaries)
        probe = [pscustomobject][ordered]@{
            exitCode = $ffprobeExitCode
            stderr = $probeStderr
            timedOut = $false
            timeoutSeconds = $FfprobeTimeoutSeconds
        }
        legacy = [pscustomobject][ordered]@{
            detected = $legacyFingerprints.Count -gt 0
            fingerprints = @($legacyFingerprints)
        }
        findings = @($findings)
    }
}

function Write-SingleHumanResult {
    param($Result)

    $color = switch ([string]$Result.outcome) {
        "PASS" { "Green" }
        "NORMALIZE" { "Cyan" }
        "REVIEW" { "Yellow" }
        "REACQUIRE" { "Red" }
        default { "White" }
    }

    Write-Host ""
    Write-Host ("Reqestra Media Validator v{0}" -f $ValidatorVersion) -ForegroundColor DarkGray
    Write-Host ("Outcome: {0}" -f $Result.outcome) -ForegroundColor $color
    Write-Host ("File:    {0}" -f $Result.path)
    Write-Host ("Library: {0}" -f $Result.libraryType)
    Write-Host ""

    foreach ($video in @($Result.video)) {
        Write-Host ("VIDEO #{0}: {1} {2}x{3} {4} {5}" -f $video.index, $video.codec, $video.width, $video.height, $video.pixelFormat, $video.hdr)
    }

    foreach ($video in @($Result.auxiliaryVideo)) {
        Write-Host ("AUXVID #{0}: {1} {2}x{3} frames={4} avgfps={5} attached_pic={6}" -f `
            $video.index, $video.codec, $video.width, $video.height, $video.frameCount, $video.averageFrameRate, $video.attachedPic) -ForegroundColor DarkGray
    }

    foreach ($audio in @($Result.audio)) {
        $flags = @()
        if ($audio.default) { $flags += "default" }
        if ($audio.commentary) { $flags += "commentary" }
        $flagText = if ($flags.Count) { " [" + ($flags -join ", ") + "]" } else { "" }

        Write-Host ("AUDIO #{0}: {1} {2} {3}ch {4}{5}" -f $audio.index, $audio.codec, $audio.language, $audio.channels, $audio.title, $flagText)
    }

    foreach ($subtitle in @($Result.subtitles)) {
        $flags = @()
        if ($subtitle.default) { $flags += "default" }
        if ($subtitle.forced) { $flags += "forced" }
        if ($subtitle.hearingImpaired) { $flags += "SDH" }
        $flagText = if ($flags.Count) { " [" + ($flags -join ", ") + "]" } else { "" }

        Write-Host ("SUB   #{0}: {1} {2} {3}{4}" -f $subtitle.index, $subtitle.codec, $subtitle.language, $subtitle.title, $flagText)
    }

    if ($Result.legacy.detected) {
        Write-Host ""
        Write-Host ("Legacy fingerprints: {0}" -f (@($Result.legacy.fingerprints) -join ", ")) -ForegroundColor DarkYellow
    }

    if (@($Result.findings).Count -gt 0) {
        Write-Host ""
        Write-Host "Findings:"
        foreach ($finding in @($Result.findings)) {
            Write-Host ("  [{0}] {1}: {2}" -f $finding.severity, $finding.code, $finding.message)
        }
    }
    else {
        Write-Host ""
        Write-Host "No policy violations or normalization issues detected." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host ("Exit code: {0}" -f $Result.exitCode) -ForegroundColor DarkGray
}

function Add-JsonLine {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    ($Object | ConvertTo-Json -Depth 20 -Compress) | Add-Content -LiteralPath $OutputPath -Encoding UTF8
}

function Convert-ResultToCsvRow {
    param($Result)

    $video = @($Result.video)
    $auxiliaryVideo = @($Result.auxiliaryVideo)
    $audio = @($Result.audio)
    $subs = @($Result.subtitles)
    $findings = @($Result.findings)

    $videoCodecs = @($video | ForEach-Object { $_.codec } | Where-Object { $_ } | Select-Object -Unique)
    $hdrTypes = @($video | ForEach-Object { $_.hdr } | Where-Object { $_ } | Select-Object -Unique)
    $audioCodecs = @($audio | ForEach-Object { $_.codec } | Where-Object { $_ } | Select-Object -Unique)
    $audioLanguages = @($audio | ForEach-Object { $_.language } | Where-Object { $_ } | Select-Object -Unique)
    $subtitleCodecs = @($subs | ForEach-Object { $_.codec } | Where-Object { $_ } | Select-Object -Unique)
    $findingCodes = @($findings | ForEach-Object { $_.code } | Select-Object -Unique)

    return [pscustomobject][ordered]@{
        Path = $Result.path
        LibraryType = $Result.libraryType
        Outcome = $Result.outcome
        VideoCodecs = ($videoCodecs -join ";")
        Resolution = (@($video | ForEach-Object { if ($_.width -and $_.height) { "{0}x{1}" -f $_.width, $_.height } }) -join ";")
        HDR = ($hdrTypes -join ";")
        AuxiliaryVideoCount = $auxiliaryVideo.Count
        AuxiliaryVideoCodecs = (@($auxiliaryVideo | ForEach-Object { $_.codec } | Where-Object { $_ } | Select-Object -Unique) -join ";")
        AudioCodecs = ($audioCodecs -join ";")
        AudioLanguages = ($audioLanguages -join ";")
        SubtitleCodecs = ($subtitleCodecs -join ";")
        LegacyDetected = [bool]$Result.legacy.detected
        LegacyFingerprints = (@($Result.legacy.fingerprints) -join ";")
        FindingCodes = ($findingCodes -join ";")
        FindingCount = $findings.Count
    }
}

function Write-AuditSummaryText {
    param(
        $Summary,
        [string]$OutputPath
    )

    $lines = @()
    $lines += "Reqestra Media Validator v$ValidatorVersion - Audit Summary"
    $lines += ""
    $lines += "Root: $($Summary.root)"
    $lines += "Library type: $($Summary.libraryType)"
    $lines += "Started (UTC): $($Summary.startedUtc)"
    $lines += "Completed (UTC): $($Summary.completedUtc)"
    $lines += "Duration seconds: $($Summary.durationSeconds)"
    $lines += "Files scanned: $($Summary.filesScanned)"
    $lines += ""
    $lines += "Outcomes:"
    $lines += ("  PASS:       {0}" -f $Summary.outcomes.PASS)
    $lines += ("  NORMALIZE:  {0}" -f $Summary.outcomes.NORMALIZE)
    $lines += ("  REVIEW:     {0}" -f $Summary.outcomes.REVIEW)
    $lines += ("  REACQUIRE:  {0}" -f $Summary.outcomes.REACQUIRE)
    $lines += ""
    $lines += ("Legacy fingerprint files: {0}" -f $Summary.legacyFingerprintFiles)
    $lines += ""
    $lines += "Finding codes:"

    foreach ($property in @($Summary.findingCodes.PSObject.Properties | Sort-Object Name)) {
        $lines += ("  {0}: {1}" -f $property.Name, $property.Value)
    }

    $lines | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
    throw "Policy file not found: $PolicyPath"
}

try {
    $policy = Get-Content -LiteralPath $PolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    throw "Unable to load policy file '$PolicyPath': $($_.Exception.Message)"
}

$preferredLanguageNormalized = Normalize-Language $PreferredLanguage
$originalLanguageNormalized = Normalize-Language $OriginalLanguage
$resolvedInputPath = (Resolve-Path -LiteralPath $Path).Path
$isDirectory = Test-Path -LiteralPath $resolvedInputPath -PathType Container

if (-not $isDirectory) {
    $result = Invoke-MediaValidation `
        -MediaPath $resolvedInputPath `
        -Policy $policy `
        -RequestedLibraryType $LibraryType `
        -PreferredLanguageNormalized $preferredLanguageNormalized `
        -OriginalLanguageNormalized $originalLanguageNormalized `
        -FfprobeExecutable $FfprobePath `
        -FfprobeTimeoutSeconds $ProbeTimeoutSeconds

    $json = $result | ConvertTo-Json -Depth 20

    if ($JsonOut) {
        $jsonDirectory = Split-Path -Parent $JsonOut
        if ($jsonDirectory -and -not (Test-Path -LiteralPath $jsonDirectory)) {
            New-Item -ItemType Directory -Path $jsonDirectory -Force | Out-Null
        }
        $json | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    }

    if ($LogPath) {
        $logDirectory = Split-Path -Parent $LogPath
        if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        Add-JsonLine -Object $result -OutputPath $LogPath
    }

    if ($OutputFormat -eq "Json") {
        $json
    }
    else {
        Write-SingleHumanResult -Result $result
    }

    if ($ExitZero) {
        exit 0
    }

    exit [int]$result.exitCode
}

# -----------------------------
# Audit mode (directory input)
# -----------------------------

$started = Get-Date

if ([string]::IsNullOrWhiteSpace($AuditOutputDirectory)) {
    $stamp = $started.ToString("yyyyMMdd-HHmmss")
    $AuditOutputDirectory = Join-Path $PSScriptRoot ("audit-" + $stamp)
}

if (-not (Test-Path -LiteralPath $AuditOutputDirectory)) {
    New-Item -ItemType Directory -Path $AuditOutputDirectory -Force | Out-Null
}

$resultsJsonlPath = Join-Path $AuditOutputDirectory "results.jsonl"
$resultsCsvPath = Join-Path $AuditOutputDirectory "results.csv"
$findingsCsvPath = Join-Path $AuditOutputDirectory "findings.csv"
$legacyCsvPath = Join-Path $AuditOutputDirectory "legacy-fingerprints.csv"
$summaryJsonPath = Join-Path $AuditOutputDirectory "summary.json"
$summaryTextPath = Join-Path $AuditOutputDirectory "summary.txt"

foreach ($outputFile in @(
    $resultsJsonlPath,
    $resultsCsvPath,
    $findingsCsvPath,
    $legacyCsvPath,
    $summaryJsonPath,
    $summaryTextPath
)) {
    if (Test-Path -LiteralPath $outputFile) {
        Remove-Item -LiteralPath $outputFile -Force
    }
}

$extensions = @($policy.audit.extensions | ForEach-Object { ([string]$_).ToLowerInvariant() })

$gciArgs = @{
    LiteralPath = $resolvedInputPath
    File = $true
}

if (-not $NoRecurse) {
    $gciArgs["Recurse"] = $true
}

$mediaFiles = @(Get-ChildItem @gciArgs | Where-Object {
    $_.Extension.ToLowerInvariant() -in $extensions
} | Sort-Object FullName)

if ($MaxFiles -gt 0) {
    $mediaFiles = @($mediaFiles | Select-Object -First $MaxFiles)
}

Write-Host ""
Write-Host ("Reqestra Media Validator v{0} - READ-ONLY AUDIT" -f $ValidatorVersion) -ForegroundColor Cyan
Write-Host ("Root: {0}" -f $resolvedInputPath)
Write-Host ("Files: {0}" -f $mediaFiles.Count)
Write-Host ("Output: {0}" -f $AuditOutputDirectory)

if ($preferredLanguageNormalized -eq "und") {
    Write-Host "Preferred language: not enforced in this audit" -ForegroundColor DarkGray
}
else {
    Write-Host ("Preferred language: {0}" -f $preferredLanguageNormalized) -ForegroundColor DarkGray
}

Write-Host ""

$outcomeCounts = [ordered]@{
    PASS = 0
    NORMALIZE = 0
    REVIEW = 0
    REACQUIRE = 0
}

$findingCounts = @{}
$videoCodecCounts = @{}
$hdrCounts = @{}
$legacyFingerprintFiles = 0
$csvRows = New-Object System.Collections.ArrayList
$findingRows = New-Object System.Collections.ArrayList
$legacyRows = New-Object System.Collections.ArrayList

$current = 0

foreach ($file in $mediaFiles) {
    $current++

    $percent = 0
    if ($mediaFiles.Count -gt 0) {
        $percent = [math]::Floor(($current / $mediaFiles.Count) * 100)
    }

    Write-Progress `
        -Activity "Reqestra media audit" `
        -Status ("{0}/{1}: {2}" -f $current, $mediaFiles.Count, $file.Name) `
        -PercentComplete $percent

    $result = Invoke-MediaValidation `
        -MediaPath $file.FullName `
        -Policy $policy `
        -RequestedLibraryType $LibraryType `
        -PreferredLanguageNormalized $preferredLanguageNormalized `
        -OriginalLanguageNormalized $originalLanguageNormalized `
        -FfprobeExecutable $FfprobePath `
        -FfprobeTimeoutSeconds $ProbeTimeoutSeconds

    Add-JsonLine -Object $result -OutputPath $resultsJsonlPath
    [void]$csvRows.Add((Convert-ResultToCsvRow -Result $result))

    $outcomeCounts[[string]$result.outcome] = [int]$outcomeCounts[[string]$result.outcome] + 1

    foreach ($finding in @($result.findings)) {
        $code = [string]$finding.code

        if (-not $findingCounts.ContainsKey($code)) {
            $findingCounts[$code] = 0
        }
        $findingCounts[$code] = [int]$findingCounts[$code] + 1

        [void]$findingRows.Add([pscustomobject][ordered]@{
            Path = $result.path
            Outcome = $result.outcome
            Severity = $finding.severity
            Code = $finding.code
            Message = $finding.message
        })
    }

    foreach ($video in @($result.video)) {
        $codec = [string]$video.codec
        if ($codec) {
            if (-not $videoCodecCounts.ContainsKey($codec)) {
                $videoCodecCounts[$codec] = 0
            }
            $videoCodecCounts[$codec] = [int]$videoCodecCounts[$codec] + 1
        }

        $hdr = [string]$video.hdr
        if ($hdr) {
            if (-not $hdrCounts.ContainsKey($hdr)) {
                $hdrCounts[$hdr] = 0
            }
            $hdrCounts[$hdr] = [int]$hdrCounts[$hdr] + 1
        }
    }

    if ($result.legacy.detected) {
        $legacyFingerprintFiles++
        [void]$legacyRows.Add([pscustomobject][ordered]@{
            Path = $result.path
            Outcome = $result.outcome
            Fingerprints = (@($result.legacy.fingerprints) -join ";")
        })
    }

    if (($current % 100) -eq 0 -or $current -eq $mediaFiles.Count) {
        Write-Host ("Scanned {0}/{1} | PASS {2} | NORMALIZE {3} | REVIEW {4} | REACQUIRE {5}" -f `
            $current,
            $mediaFiles.Count,
            $outcomeCounts.PASS,
            $outcomeCounts.NORMALIZE,
            $outcomeCounts.REVIEW,
            $outcomeCounts.REACQUIRE
        )
    }
}

Write-Progress -Activity "Reqestra media audit" -Completed

if ($csvRows.Count -gt 0) {
    $csvRows | Export-Csv -LiteralPath $resultsCsvPath -NoTypeInformation -Encoding UTF8
}
else {
    "" | Set-Content -LiteralPath $resultsCsvPath -Encoding UTF8
}

if ($findingRows.Count -gt 0) {
    $findingRows | Export-Csv -LiteralPath $findingsCsvPath -NoTypeInformation -Encoding UTF8
}
else {
    "" | Set-Content -LiteralPath $findingsCsvPath -Encoding UTF8
}

if ($legacyRows.Count -gt 0) {
    $legacyRows | Export-Csv -LiteralPath $legacyCsvPath -NoTypeInformation -Encoding UTF8
}
else {
    "" | Set-Content -LiteralPath $legacyCsvPath -Encoding UTF8
}

$findingCountsObject = [ordered]@{}
foreach ($key in @($findingCounts.Keys | Sort-Object)) {
    $findingCountsObject[$key] = $findingCounts[$key]
}

$videoCodecCountsObject = [ordered]@{}
foreach ($key in @($videoCodecCounts.Keys | Sort-Object)) {
    $videoCodecCountsObject[$key] = $videoCodecCounts[$key]
}

$hdrCountsObject = [ordered]@{}
foreach ($key in @($hdrCounts.Keys | Sort-Object)) {
    $hdrCountsObject[$key] = $hdrCounts[$key]
}

$completed = Get-Date
$durationSeconds = [math]::Round(($completed - $started).TotalSeconds, 2)

$summary = [pscustomobject][ordered]@{
    schemaVersion = $SchemaVersion
    validatorVersion = $ValidatorVersion
    root = $resolvedInputPath
    libraryType = $LibraryType
    preferredLanguage = if ($preferredLanguageNormalized -eq "und") { $null } else { $preferredLanguageNormalized }
    startedUtc = $started.ToUniversalTime().ToString("o")
    completedUtc = $completed.ToUniversalTime().ToString("o")
    durationSeconds = $durationSeconds
    filesScanned = $mediaFiles.Count
    outcomes = [pscustomobject]$outcomeCounts
    legacyFingerprintFiles = $legacyFingerprintFiles
    findingCodes = [pscustomobject]$findingCountsObject
    videoCodecs = [pscustomobject]$videoCodecCountsObject
    hdrTypes = [pscustomobject]$hdrCountsObject
    outputs = [pscustomobject][ordered]@{
        jsonl = $resultsJsonlPath
        resultsCsv = $resultsCsvPath
        findingsCsv = $findingsCsvPath
        legacyCsv = $legacyCsvPath
    }
}

$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryJsonPath -Encoding UTF8
Write-AuditSummaryText -Summary $summary -OutputPath $summaryTextPath

Write-Host ""
Write-Host "Audit complete." -ForegroundColor Green
Write-Host ("PASS:                 {0}" -f $outcomeCounts.PASS)
Write-Host ("NORMALIZE:            {0}" -f $outcomeCounts.NORMALIZE)
Write-Host ("REVIEW:               {0}" -f $outcomeCounts.REVIEW)
Write-Host ("REACQUIRE:            {0}" -f $outcomeCounts.REACQUIRE)
Write-Host ("Legacy fingerprints:  {0}" -f $legacyFingerprintFiles)
Write-Host ""
Write-Host ("Summary: {0}" -f $summaryTextPath)
Write-Host ("CSV:     {0}" -f $resultsCsvPath)
Write-Host ("JSONL:   {0}" -f $resultsJsonlPath)
Write-Host ""

# Audit mode is intentionally non-failing in dry-run operation.
exit 0
