Set-StrictMode -Version Latest

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
        $Object | ConvertTo-Json -Depth 60 |
            Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
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

    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($Parent)) {
        return $false
    }

    try {
        $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd("\") + "\"
        $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd("\") + "\"
        return $candidateFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Get-Sha256String {
    param([string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return ([BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
}

function Normalize-Language {
    param([string]$Language)

    if ([string]::IsNullOrWhiteSpace($Language)) { return "und" }

    # IMPORTANT: This table must remain byte-for-byte semantically aligned with
    # ReacquisitionPlanner.ps1. Stream fingerprints written into plans are later
    # recomputed here after files move to quarantine; normalization drift would
    # make identical media appear to have changed.
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
    return Get-Sha256String -Text $json
}

function Invoke-ValidatorSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$MediaPath,
        [ValidateSet("Movie","TV")][string]$LibraryType = "Movie",
        [Parameter(Mandatory = $true)][string]$ValidatorPath,
        [Parameter(Mandatory = $true)][string]$PolicyPath,
        [Parameter(Mandatory = $true)][string]$WorkRoot
    )

    if (-not (Test-Path -LiteralPath $MediaPath -PathType Leaf)) {
        throw "Media file does not exist: $MediaPath"
    }

    if (-not (Test-Path -LiteralPath $WorkRoot)) {
        New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    }

    $runId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + [guid]::NewGuid().ToString("N").Substring(0,8)
    $work = Join-Path $WorkRoot $runId
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $jsonPath = Join-Path $work "validator.json"
    $stdoutPath = Join-Path $work "stdout.txt"
    $stderrPath = Join-Path $work "stderr.txt"

    $powerShellExe = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
        $powerShellExe = "powershell.exe"
    }

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ValidatorPath,
        $MediaPath,
        "-LibraryType", $LibraryType,
        "-PolicyPath", $PolicyPath,
        "-JsonOut", $jsonPath,
        "-OutputFormat", "Json",
        "-ExitZero"
    )

    $argumentString = ($args | ForEach-Object {
        $text = [string]$_
        if ($text -match '[\s"]') {
            '"' + $text.Replace('"', '\\"') + '"'
        }
        else {
            $text
        }
    }) -join ' '

    $process = Start-Process `
        -FilePath $powerShellExe `
        -ArgumentList $argumentString `
        -Wait `
        -PassThru `
        -NoNewWindow `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath

    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
        $stderr = if (Test-Path -LiteralPath $stderrPath) {
            Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
        }
        else { "" }
        throw "Validator did not produce JSON for '$MediaPath'. ExitCode=$($process.ExitCode). $stderr"
    }

    $validator = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $item = Get-Item -LiteralPath $MediaPath

    return [pscustomobject][ordered]@{
        mediaPath = $MediaPath
        lengthBytes = [int64]$item.Length
        lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString("o")
        outcome = [string](Get-PropertyValue -Object $validator -Name "outcome" -Default "")
        findingCodes = @(
            @(Get-PropertyValue -Object $validator -Name "findings" -Default @()) |
                ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "code" -Default "") } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        streamFingerprint = Get-StreamFingerprint -ValidatorResult $validator
        validatorResultPath = $jsonPath
        workDirectory = $work
    }
}

function Get-ReacquisitionChainPath {
    param(
        [Parameter(Mandatory = $true)][string]$IntegrationRoot,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][int]$EntityId,
        [string]$Discriminator = ""
    )

    $chainRoot = Join-Path $IntegrationRoot "Reacquisition\chains"
    if ([string]::IsNullOrWhiteSpace($Discriminator)) {
        return Join-Path $chainRoot (("{0}-{1}.json" -f $Source, $EntityId))
    }

    $safe = [regex]::Replace($Discriminator.Trim(), '[^A-Za-z0-9._-]', '_')
    return Join-Path $chainRoot (("{0}-{1}-{2}.json" -f $Source, $EntityId, $safe))
}

function Get-PlanForLoopKey {
    param(
        [Parameter(Mandatory = $true)][string]$LogsRoot,
        [Parameter(Mandatory = $true)][string]$LoopKey
    )

    $matches = @()
    if (-not (Test-Path -LiteralPath $LogsRoot)) { return @() }

    foreach ($file in @(Get-ChildItem -LiteralPath $LogsRoot -Recurse -File -Filter "reacquisition-plan.json" -ErrorAction SilentlyContinue)) {
        try {
            $plan = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $loop = Get-PropertyValue -Object (Get-PropertyValue -Object $plan -Name "loopPrevention") -Name "loopKey" -Default ""
            if ([string]::Equals([string]$loop, $LoopKey, [System.StringComparison]::Ordinal)) {
                $matches += [pscustomobject]@{ path = $file.FullName; plan = $plan }
            }
        }
        catch {}
    }

    return @($matches)
}

function Test-ReacquisitionRollback {
    param(
        [Parameter(Mandatory = $true)]$Rollback,
        [Parameter(Mandatory = $true)][string]$ValidatorPath,
        [Parameter(Mandatory = $true)][string]$PolicyPath,
        [Parameter(Mandatory = $true)][string]$WorkRoot
    )

    $path = [string](Get-PropertyValue -Object $Rollback -Name "path" -Default "")
    $expectedBytes = [int64](Get-PropertyValue -Object $Rollback -Name "lengthBytes" -Default -1)
    $expectedFingerprint = [string](Get-PropertyValue -Object $Rollback -Name "streamFingerprint" -Default "")

    $result = [ordered]@{
        exists = $false
        sizeMatches = $false
        fingerprintMatches = $false
        path = $path
        expectedBytes = $expectedBytes
        actualBytes = $null
        expectedFingerprint = $expectedFingerprint
        actualFingerprint = $null
        verified = $false
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]$result
    }

    $result.exists = $true
    $item = Get-Item -LiteralPath $path
    $result.actualBytes = [int64]$item.Length
    $result.sizeMatches = ([int64]$item.Length -eq $expectedBytes)

    if (-not $result.sizeMatches -or [string]::IsNullOrWhiteSpace($expectedFingerprint)) {
        return [pscustomobject]$result
    }

    $libraryType = [string](Get-PropertyValue -Object $Rollback -Name "libraryType" -Default "")
    if ([string]::IsNullOrWhiteSpace($libraryType)) {
        $rollbackSource = [string](Get-PropertyValue -Object $Rollback -Name "source" -Default "")
        $libraryType = if ($rollbackSource -eq "Sonarr") { "TV" } else { "Movie" }
    }
    if ($libraryType -notin @("Movie", "TV")) { $libraryType = "Movie" }

    $snapshot = Invoke-ValidatorSnapshot `
        -MediaPath $path `
        -LibraryType $libraryType `
        -ValidatorPath $ValidatorPath `
        -PolicyPath $PolicyPath `
        -WorkRoot $WorkRoot

    $result.actualFingerprint = $snapshot.streamFingerprint
    $result.fingerprintMatches = [string]::Equals(
        $snapshot.streamFingerprint,
        $expectedFingerprint,
        [System.StringComparison]::Ordinal
    )
    $result.verified = ($result.exists -and $result.sizeMatches -and $result.fingerprintMatches)

    return [pscustomobject]$result
}
