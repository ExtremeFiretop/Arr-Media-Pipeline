[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlanPath,

    [switch]$Execute,

    [switch]$DeleteBackupOnSuccess,

    [string]$JsonOut = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ExecutorVersion = "0.2.0"
$IntegrationRoot = $PSScriptRoot
$ValidatorRoot = Split-Path -Parent $IntegrationRoot
$ValidatorPath = Join-Path $ValidatorRoot "MediaValidator.ps1"
$PolicyPath = Join-Path $ValidatorRoot "validator-policy.json"
$ContextValidatorPath = Join-Path $IntegrationRoot "ContextValidator.ps1"
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $false)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Normalize-Language {
    param([string]$Language)

    if ([string]::IsNullOrWhiteSpace($Language)) { return "und" }
    $value = $Language.Trim().ToLowerInvariant()

    switch ($value) {
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
        "und" { return "und" }
        default { return $value }
    }
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
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][object[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath
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

    return [pscustomobject][ordered]@{
        exitCode = $exitCode
        stdout = $stdout
        stderr = $stderr
    }
}

function Get-StreamFingerprint {
    param($ValidatorResult)

    $normalized = [ordered]@{
        video = @(
            @(Get-PropertyValue -Object $ValidatorResult -Name "video" -Default @()) | ForEach-Object {
                [ordered]@{
                    codec = [string](Get-PropertyValue -Object $_ -Name "codec" -Default "")
                    width = Get-PropertyValue -Object $_ -Name "width"
                    height = Get-PropertyValue -Object $_ -Name "height"
                    pixFmt = [string](Get-PropertyValue -Object $_ -Name "pixFmt" -Default "")
                    language = Normalize-Language ([string](Get-PropertyValue -Object $_ -Name "language" -Default ""))
                    title = [string](Get-PropertyValue -Object $_ -Name "title" -Default "")
                }
            }
        )
        auxiliaryVideo = @(
            @(Get-PropertyValue -Object $ValidatorResult -Name "auxiliaryVideo" -Default @()) | ForEach-Object {
                [ordered]@{
                    codec = [string](Get-PropertyValue -Object $_ -Name "codec" -Default "")
                    width = Get-PropertyValue -Object $_ -Name "width"
                    height = Get-PropertyValue -Object $_ -Name "height"
                    language = Normalize-Language ([string](Get-PropertyValue -Object $_ -Name "language" -Default ""))
                    title = [string](Get-PropertyValue -Object $_ -Name "title" -Default "")
                }
            }
        )
        audio = @(
            @(Get-PropertyValue -Object $ValidatorResult -Name "audio" -Default @()) | ForEach-Object {
                [ordered]@{
                    codec = [string](Get-PropertyValue -Object $_ -Name "codec" -Default "")
                    language = Normalize-Language ([string](Get-PropertyValue -Object $_ -Name "language" -Default ""))
                    title = [string](Get-PropertyValue -Object $_ -Name "title" -Default "")
                    channels = Get-PropertyValue -Object $_ -Name "channels"
                    commentary = [bool](Get-PropertyValue -Object $_ -Name "commentary" -Default $false)
                }
            }
        )
        subtitles = @(
            @(Get-PropertyValue -Object $ValidatorResult -Name "subtitles" -Default @()) | ForEach-Object {
                [ordered]@{
                    codec = [string](Get-PropertyValue -Object $_ -Name "codec" -Default "")
                    language = Normalize-Language ([string](Get-PropertyValue -Object $_ -Name "language" -Default ""))
                    title = [string](Get-PropertyValue -Object $_ -Name "title" -Default "")
                    forced = [bool](Get-PropertyValue -Object $_ -Name "forced" -Default $false)
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

function Get-FileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$ValidatorResult
    )

    $item = Get-Item -LiteralPath $Path

    return [pscustomobject][ordered]@{
        lengthBytes = [int64]$item.Length
        lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString("o")
        streamFingerprint = Get-StreamFingerprint -ValidatorResult $ValidatorResult
    }
}

function Get-FindingCodes {
    param($Result)

    if ($null -eq $Result) { return @() }

    return @(
        @(Get-PropertyValue -Object $Result -Name "findings" -Default @()) |
            Where-Object { $null -ne $_ } |
            ForEach-Object { [string](Get-PropertyValue -Object $_ -Name "code" -Default "") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-OutcomeRank {
    param([string]$Outcome)
    switch ($Outcome) {
        "PASS"      { return 0 }
        "NORMALIZE" { return 1 }
        "REVIEW"    { return 2 }
        "REACQUIRE" { return 3 }
        default     { return 0 }
    }
}

function Get-HigherOutcome {
    param([string]$First, [string]$Second)

    if ((Get-OutcomeRank $Second) -gt (Get-OutcomeRank $First)) {
        return $Second
    }

    return $First
}

function Resolve-Mkvmerge {
    $customScriptsRoot = Split-Path -Parent $ValidatorRoot
    $mkvToolNixRoot = Split-Path -Parent $customScriptsRoot
    $candidate = Join-Path $mkvToolNixRoot "mkvmerge.exe"

    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    $command = Get-Command "mkvmerge.exe" -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    return ""
}

function Invoke-MediaValidator {
    param(
        [string]$MediaPath,
        [string]$LibraryType,
        [string]$JsonOutPath,
        [string]$StdoutPath,
        [string]$StderrPath
    )

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
        "-JsonOut", $JsonOutPath,
        "-OutputFormat", "Json",
        "-ExitZero"
    )

    return Invoke-CapturedProcess -FileName $powerShellExe -Arguments $args -StdoutPath $StdoutPath -StderrPath $StderrPath
}

function Invoke-ContextValidator {
    param(
        [string]$ContextPath,
        [string]$ValidatorResultPath,
        [string]$JsonOutPath,
        [string]$StdoutPath,
        [string]$StderrPath
    )

    $powerShellExe = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
        $powerShellExe = "powershell.exe"
    }

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ContextValidatorPath,
        "-ContextPath", $ContextPath,
        "-ValidatorResultPath", $ValidatorResultPath,
        "-JsonOut", $JsonOutPath,
        "-ExitZero"
    )

    return Invoke-CapturedProcess -FileName $powerShellExe -Arguments $args -StdoutPath $StdoutPath -StderrPath $StderrPath
}


function Get-ArrConnection {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Sonarr", "Radarr")]
        [string]$Source
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Integration config not found: $ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sectionName = $Source.ToLowerInvariant()
    $section = Get-PropertyValue -Object $config -Name $sectionName

    if ($null -eq $section) {
        throw "Integration config is missing section '$sectionName'."
    }

    $baseUrl = [string](Get-PropertyValue -Object $section -Name "baseUrl" -Default "")
    $apiKey = [string](Get-PropertyValue -Object $section -Name "apiKey" -Default "")

    if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) {
        throw "$Source integration config requires baseUrl and apiKey."
    }

    return [pscustomobject][ordered]@{
        source = $Source
        baseUrl = $baseUrl.TrimEnd("/")
        apiKey = $apiKey
        apiVersion = "v3"
    }
}

function Invoke-ArrRequest {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [ValidateSet("GET", "POST")]
        [string]$Method = "GET",
        $Body = $null
    )

    $uri = $Connection.baseUrl + "/api/" + $Connection.apiVersion + "/" + $RelativePath.TrimStart("/")
    $headers = @{
        "X-Api-Key" = $Connection.apiKey
    }

    if ($Method -eq "POST") {
        $headers["Content-Type"] = "application/json"
        $jsonBody = if ($null -eq $Body) { "{}" } else { $Body | ConvertTo-Json -Depth 10 }

        return Invoke-RestMethod `
            -Uri $uri `
            -Headers $headers `
            -Method Post `
            -Body $jsonBody `
            -TimeoutSec 30
    }

    return Invoke-RestMethod `
        -Uri $uri `
        -Headers $headers `
        -Method Get `
        -TimeoutSec 30
}

function Get-ArrTarget {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Sonarr", "Radarr")]
        [string]$Source,
        [Parameter(Mandatory = $true)]$Context
    )

    $entity = Get-PropertyValue -Object $Context -Name "entity"
    $file = Get-PropertyValue -Object $Context -Name "file"

    $entityId = [int](Get-PropertyValue -Object $entity -Name "id" -Default 0)
    $fileId = [int](Get-PropertyValue -Object $file -Name "id" -Default 0)

    if ($entityId -le 0 -or $fileId -le 0) {
        throw "$Source context is missing a valid entity id or file id."
    }

    if ($Source -eq "Sonarr") {
        return [pscustomobject][ordered]@{
            source = "Sonarr"
            entityId = $entityId
            fileId = $fileId
            fileResource = "episodefile/$fileId"
            commandName = "RescanSeries"
            commandEntityKey = "seriesId"
        }
    }

    return [pscustomobject][ordered]@{
        source = "Radarr"
        entityId = $entityId
        fileId = $fileId
        fileResource = "moviefile/$fileId"
        commandName = "RescanMovie"
        commandEntityKey = "movieId"
    }
}

function Test-PathEquivalent {
    param(
        [string]$First,
        [string]$Second
    )

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

function Wait-ArrCommand {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][int]$CommandId,
        [int]$TimeoutSeconds = 300
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $last = $null

    do {
        Start-Sleep -Seconds 2
        $last = Invoke-ArrRequest -Connection $Connection -RelativePath ("command/{0}" -f $CommandId) -Method GET
        $status = [string](Get-PropertyValue -Object $last -Name "status" -Default "")

        if ($status -notin @("queued", "started")) {
            return $last
        }
    }
    while ([DateTime]::UtcNow -lt $deadline)

    throw "Timed out waiting for Arr command $CommandId after $TimeoutSeconds seconds."
}

function Invoke-ArrReconciliation {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$MediaPath
    )

    $body = [ordered]@{
        name = $Target.commandName
    }
    $body[$Target.commandEntityKey] = $Target.entityId

    $command = Invoke-ArrRequest `
        -Connection $Connection `
        -RelativePath "command" `
        -Method POST `
        -Body $body

    $commandId = [int](Get-PropertyValue -Object $command -Name "id" -Default 0)
    if ($commandId -le 0) {
        throw "$($Target.source) did not return a valid command id."
    }

    $completed = Wait-ArrCommand -Connection $Connection -CommandId $commandId
    $commandStatus = [string](Get-PropertyValue -Object $completed -Name "status" -Default "")

    if ($commandStatus -ne "completed") {
        return [pscustomobject][ordered]@{
            succeeded = $false
            reason = "arr_rescan_command_not_completed"
            source = $Target.source
            commandName = $Target.commandName
            commandId = $commandId
            commandStatus = $commandStatus
            entityId = $Target.entityId
            fileId = $Target.fileId
            actualBytes = [int64](Get-Item -LiteralPath $MediaPath).Length
            arrBytes = $null
            sizeMatches = $false
            pathMatches = $false
        }
    }

    $arrFile = Invoke-ArrRequest `
        -Connection $Connection `
        -RelativePath $Target.fileResource `
        -Method GET

    $actual = Get-Item -LiteralPath $MediaPath
    $arrBytes = [int64](Get-PropertyValue -Object $arrFile -Name "size" -Default -1)
    $arrPath = [string](Get-PropertyValue -Object $arrFile -Name "path" -Default "")

    $sizeMatches = ([int64]$actual.Length -eq $arrBytes)
    $pathMatches = Test-PathEquivalent -First $actual.FullName -Second $arrPath

    return [pscustomobject][ordered]@{
        succeeded = ($sizeMatches -and $pathMatches)
        reason = if ($sizeMatches -and $pathMatches) { $null } elseif (-not $pathMatches) { "arr_path_mismatch_after_rescan" } else { "arr_size_mismatch_after_rescan" }
        source = $Target.source
        commandName = $Target.commandName
        commandId = $commandId
        commandStatus = $commandStatus
        entityId = $Target.entityId
        fileId = $Target.fileId
        actualBytes = [int64]$actual.Length
        arrBytes = $arrBytes
        sizeMatches = $sizeMatches
        actualPath = $actual.FullName
        arrPath = $arrPath
        pathMatches = $pathMatches
    }
}

function Get-FreeBytesForPath {
    param([string]$Path)

    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if ([string]::IsNullOrWhiteSpace($root)) { return $null }

        if ($root -match '^([A-Za-z]):\\$') {
            $driveName = $matches[1]
            $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
            return [int64]$drive.Free
        }
    }
    catch {
        return $null
    }

    return $null
}

function Write-ExecutionResult {
    param($Result)

    $Result | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    $Result | ConvertTo-Json -Depth 12
}

if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
    throw "Plan file not found: $PlanPath"
}

$PlanPath = (Resolve-Path -LiteralPath $PlanPath).Path
$planDirectory = Split-Path -Parent $PlanPath

if ([string]::IsNullOrWhiteSpace($JsonOut)) {
    $JsonOut = Join-Path $planDirectory "normalization-execution.json"
}

$executionId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + ([Guid]::NewGuid().ToString("N").Substring(0, 8))
$workDirectory = Join-Path $planDirectory ("normalization-execution-" + $executionId)
New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null

$result = [ordered]@{
    schemaVersion = "1.0"
    executorVersion = $ExecutorVersion
    executionId = $executionId
    startedUtc = [DateTime]::UtcNow.ToString("o")
    completedUtc = $null
    mode = if ($Execute) { "EXECUTE" } else { "DRY_RUN" }
    planPath = $PlanPath
    status = "STARTED"
    reason = $null
    mediaPath = $null
    preflight = $null
    mappedActions = @()
    tempPath = $null
    backupPath = $null
    replacementMethod = "System.IO.File.Replace"
    backupDeleted = $false
    rollback = $null
    arrReconciliation = $null
    workDirectory = $workDirectory
}

$mutex = $null
$mutexAcquired = $false
$replacementCompleted = $false
$mediaValidationSucceeded = $false
$originalCreationTimeUtc = $null
$originalLastWriteTimeUtc = $null
$mediaPath = ""
$backupPath = ""
$failedNewPath = ""

try {
    $plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if ([string](Get-PropertyValue -Object $plan -Name "status" -Default "") -ne "PLANNED") {
        $result.status = "BLOCKED"
        $result.reason = "plan_not_planned"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    $mediaPath = [string](Get-PropertyValue -Object $plan -Name "mediaPath" -Default "")
    $result.mediaPath = $mediaPath

    if ([string]::IsNullOrWhiteSpace($mediaPath) -or -not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) {
        $result.status = "BLOCKED"
        $result.reason = "media_file_missing"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    if ([System.IO.Path]::GetExtension($mediaPath).ToLowerInvariant() -ne ".mkv") {
        $result.status = "BLOCKED"
        $result.reason = "container_not_supported"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    $sourceSnapshot = Get-PropertyValue -Object $plan -Name "sourceSnapshot"
    if ($null -eq $sourceSnapshot) {
        $result.status = "BLOCKED"
        $result.reason = "plan_missing_source_snapshot"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    $sourceFiles = Get-PropertyValue -Object $plan -Name "sourceFiles"
    $contextPath = [string](Get-PropertyValue -Object $sourceFiles -Name "contextPath" -Default "")

    if ([string]::IsNullOrWhiteSpace($contextPath) -or -not (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
        $result.status = "BLOCKED"
        $result.reason = "context_file_missing"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $libraryType = [string](Get-PropertyValue -Object $context -Name "libraryType" -Default "")
    if ($libraryType -ne "Movie" -and $libraryType -ne "TV") {
        $result.status = "BLOCKED"
        $result.reason = "library_type_invalid"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    $source = [string](Get-PropertyValue -Object $context -Name "source" -Default "")
    if ($source -notin @("Sonarr", "Radarr")) {
        $result.status = "BLOCKED"
        $result.reason = "arr_source_invalid"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    if (($source -eq "Sonarr" -and $libraryType -ne "TV") -or
        ($source -eq "Radarr" -and $libraryType -ne "Movie")) {
        $result.status = "BLOCKED"
        $result.reason = "arr_source_library_type_mismatch"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    try {
        $arrConnection = Get-ArrConnection -Source $source
        $arrTarget = Get-ArrTarget -Source $source -Context $context
        $arrFileBefore = Invoke-ArrRequest `
            -Connection $arrConnection `
            -RelativePath $arrTarget.fileResource `
            -Method GET
    }
    catch {
        $result.status = "BLOCKED"
        $result.reason = "arr_preflight_unavailable"
        $result.arrReconciliation = [ordered]@{
            source = $source
            stage = "preflight"
            succeeded = $false
            error = $_.Exception.Message
        }
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    $arrPathBefore = [string](Get-PropertyValue -Object $arrFileBefore -Name "path" -Default "")
    $arrBytesBefore = [int64](Get-PropertyValue -Object $arrFileBefore -Name "size" -Default -1)
    $arrPathMatchesBefore = Test-PathEquivalent -First $mediaPath -Second $arrPathBefore
    $actualBytesBefore = [int64](Get-Item -LiteralPath $mediaPath).Length
    $arrSizeMatchesBefore = ($actualBytesBefore -eq $arrBytesBefore)

    if (-not $arrPathMatchesBefore) {
        $result.status = "BLOCKED"
        $result.reason = "arr_preflight_path_mismatch"
        $result.arrReconciliation = [ordered]@{
            source = $source
            stage = "preflight"
            succeeded = $false
            fileId = $arrTarget.fileId
            actualPath = $mediaPath
            arrPath = $arrPathBefore
            pathMatches = $false
        }
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    if (-not $arrSizeMatchesBefore) {
        $result.status = "BLOCKED"
        $result.reason = "arr_preflight_size_mismatch"
        $result.arrReconciliation = [ordered]@{
            source = $source
            stage = "preflight"
            succeeded = $false
            fileId = $arrTarget.fileId
            actualBytes = $actualBytesBefore
            arrBytes = $arrBytesBefore
            sizeMatches = $false
            pathMatches = $true
        }
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    if (-not (Test-Path -LiteralPath $ValidatorPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $PolicyPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $ContextValidatorPath -PathType Leaf)) {
        $result.status = "BLOCKED"
        $result.reason = "validator_components_missing"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    $mkvmergePath = Resolve-Mkvmerge
    if ([string]::IsNullOrWhiteSpace($mkvmergePath)) {
        $result.status = "BLOCKED"
        $result.reason = "mkvmerge_not_found"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    # Snapshot before any expensive work.
    $item = Get-Item -LiteralPath $mediaPath
    $expectedLength = [int64](Get-PropertyValue -Object $sourceSnapshot -Name "lengthBytes" -Default -1)
    $expectedLastWrite = [string](Get-PropertyValue -Object $sourceSnapshot -Name "lastWriteTimeUtc" -Default "")

    if ([int64]$item.Length -ne $expectedLength -or
        $item.LastWriteTimeUtc.ToString("o") -ne $expectedLastWrite) {
        $result.status = "BLOCKED"
        $result.reason = "stale_plan_file_metadata_changed"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    # Re-run generic + contextual validation now.
    $preflightValidatorPath = Join-Path $workDirectory "preflight-validator.json"
    $preflightValidatorStdout = Join-Path $workDirectory "preflight-validator-stdout.txt"
    $preflightValidatorStderr = Join-Path $workDirectory "preflight-validator-stderr.txt"

    $preflightProcess = Invoke-MediaValidator `
        -MediaPath $mediaPath `
        -LibraryType $libraryType `
        -JsonOutPath $preflightValidatorPath `
        -StdoutPath $preflightValidatorStdout `
        -StderrPath $preflightValidatorStderr

    if (-not (Test-Path -LiteralPath $preflightValidatorPath -PathType Leaf)) {
        $result.status = "BLOCKED"
        $result.reason = "preflight_validator_failed"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    $preflightValidator = Get-Content -LiteralPath $preflightValidatorPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $preflightContextualPath = Join-Path $workDirectory "preflight-contextual.json"
    $preflightContextualStdout = Join-Path $workDirectory "preflight-contextual-stdout.txt"
    $preflightContextualStderr = Join-Path $workDirectory "preflight-contextual-stderr.txt"

    $preflightContextualProcess = Invoke-ContextValidator `
        -ContextPath $contextPath `
        -ValidatorResultPath $preflightValidatorPath `
        -JsonOutPath $preflightContextualPath `
        -StdoutPath $preflightContextualStdout `
        -StderrPath $preflightContextualStderr

    $preflightContextual = Get-Content -LiteralPath $preflightContextualPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $currentSnapshot = Get-FileSnapshot -Path $mediaPath -ValidatorResult $preflightValidator
    $expectedFingerprint = [string](Get-PropertyValue -Object $sourceSnapshot -Name "streamFingerprint" -Default "")

    if ([string]::IsNullOrWhiteSpace($expectedFingerprint) -or
        $currentSnapshot.streamFingerprint -ne $expectedFingerprint) {
        $result.status = "BLOCKED"
        $result.reason = "stale_plan_stream_layout_changed"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    $preflightGenericOutcome = [string](Get-PropertyValue -Object $preflightValidator -Name "outcome" -Default "PASS")
    $preflightContextualOutcome = if ([string](Get-PropertyValue -Object $preflightContextual -Name "status" -Default "") -eq "APPLIED") {
        [string](Get-PropertyValue -Object $preflightContextual -Name "outcome" -Default "PASS")
    } else {
        "PASS"
    }
    $preflightEffectiveOutcome = Get-HigherOutcome -First $preflightGenericOutcome -Second $preflightContextualOutcome

    $plannedFindingCodes = @(
        @(Get-PropertyValue -Object $plan -Name "plannedFindingCodes" -Default @()) |
            ForEach-Object { [string]$_ }
    )

    $currentFindingCodes = @(
        @(Get-FindingCodes -Result $preflightValidator) +
        @(Get-FindingCodes -Result $preflightContextual) |
            Select-Object -Unique
    )

    foreach ($code in $plannedFindingCodes) {
        if ($currentFindingCodes -notcontains $code) {
            $result.status = "BLOCKED"
            $result.reason = "planned_finding_no_longer_present"
            throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
        }
    }

    $audio = @(
        @(Get-PropertyValue -Object $preflightValidator -Name "audio" -Default @()) |
            Where-Object { $null -ne $_ }
    )

    $actions = @(
        @(Get-PropertyValue -Object $plan -Name "actions" -Default @()) |
            Where-Object { $null -ne $_ }
    )

    if ($actions.Count -eq 0) {
        $result.status = "BLOCKED"
        $result.reason = "plan_has_no_actions"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    foreach ($action in $actions) {
        if ([string](Get-PropertyValue -Object $action -Name "action" -Default "") -ne "set_audio_default_flag") {
            $result.status = "BLOCKED"
            $result.reason = "action_not_allowlisted"
            throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
        }

        $ordinal = [int](Get-PropertyValue -Object $action -Name "audioOrdinal" -Default 0)
        if ($ordinal -lt 1 -or $ordinal -gt $audio.Count) {
            $result.status = "BLOCKED"
            $result.reason = "audio_ordinal_out_of_range"
            throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
        }

        $track = $audio[$ordinal - 1]
        $currentDefault = [bool](Get-PropertyValue -Object $track -Name "default" -Default $false)
        $expectedFrom = [bool](Get-PropertyValue -Object $action -Name "from" -Default $false)
        $currentLanguage = Normalize-Language ([string](Get-PropertyValue -Object $track -Name "language" -Default ""))
        $expectedLanguage = Normalize-Language ([string](Get-PropertyValue -Object $action -Name "language" -Default ""))
        $currentCommentary = [bool](Get-PropertyValue -Object $track -Name "commentary" -Default $false)
        $expectedCommentary = [bool](Get-PropertyValue -Object $action -Name "commentary" -Default $false)

        if ($currentDefault -ne $expectedFrom -or
            $currentLanguage -ne $expectedLanguage -or
            $currentCommentary -ne $expectedCommentary) {
            $result.status = "BLOCKED"
            $result.reason = "action_precondition_changed"
            throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
        }
    }

    # Resolve actual mkvmerge input track IDs.
    $identifyStdout = Join-Path $workDirectory "mkvmerge-identify.json"
    $identifyStderr = Join-Path $workDirectory "mkvmerge-identify-stderr.txt"
    $identifyResult = Invoke-CapturedProcess `
        -FileName $mkvmergePath `
        -Arguments @("-J", $mediaPath) `
        -StdoutPath $identifyStdout `
        -StderrPath $identifyStderr

    if ($identifyResult.exitCode -ne 0) {
        $result.status = "BLOCKED"
        $result.reason = "mkvmerge_identify_failed"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    $identification = $identifyResult.stdout | ConvertFrom-Json
    $mkvAudioTracks = @(
        @($identification.tracks) | Where-Object { [string]$_.type -eq "audio" }
    )

    if ($mkvAudioTracks.Count -ne $audio.Count) {
        $result.status = "BLOCKED"
        $result.reason = "mkvmerge_audio_count_mismatch"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    $mappedActions = @()

    foreach ($action in $actions) {
        $ordinal = [int]$action.audioOrdinal
        $mkvTrack = $mkvAudioTracks[$ordinal - 1]
        $trackId = [int]$mkvTrack.id
        $props = $mkvTrack.properties

        $mkvLanguage = Normalize-Language ([string](Get-PropertyValue -Object $props -Name "language" -Default ""))
        $expectedLanguage = Normalize-Language ([string]$action.language)
        $mkvDefault = [bool](Get-PropertyValue -Object $props -Name "default_track" -Default $true)

        if ($mkvLanguage -ne $expectedLanguage -or $mkvDefault -ne [bool]$action.from) {
            $result.status = "BLOCKED"
            $result.reason = "mkvmerge_track_mapping_precondition_failed"
            throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
        }

        $mappedActions += [pscustomobject][ordered]@{
            audioOrdinal = $ordinal
            ffprobeStreamIndex = $action.ffprobeStreamIndex
            mkvmergeTrackId = $trackId
            language = $expectedLanguage
            from = [bool]$action.from
            to = [bool]$action.to
        }
    }

    $freeBytes = Get-FreeBytesForPath -Path $mediaPath
    $requiredFreeBytes = [int64]$item.Length + [int64][Math]::Max(1073741824, [double]$item.Length * 0.10)

    $result.preflight = [ordered]@{
        sourceSnapshotMatches = $true
        streamFingerprintMatches = $true
        preflightEffectiveOutcome = $preflightEffectiveOutcome
        plannedFindingCodes = @($plannedFindingCodes)
        currentFindingCodes = @($currentFindingCodes)
        mkvmergePath = $mkvmergePath
        mkvmergeIdentifyExitCode = $identifyResult.exitCode
        freeBytes = $freeBytes
        requiredFreeBytes = $requiredFreeBytes
        arrSource = $source
        arrEntityId = $arrTarget.entityId
        arrFileId = $arrTarget.fileId
        arrPathMatches = $arrPathMatchesBefore
        arrSizeMatches = $arrSizeMatchesBefore
        actualBytesBefore = $actualBytesBefore
        arrBytesBefore = $arrBytesBefore
        arrPathBefore = $arrPathBefore
    }
    $result.mappedActions = @($mappedActions)

    if (-not $Execute) {
        $result.status = "DRY_RUN_READY"
        $result.reason = $null

        # Do not emit here. The finally block is the single output path for all
        # modes, which prevents dry-run results from being printed twice.
        throw [System.InvalidOperationException]::new("DRY_RUN_COMPLETE")
    }

    if ($null -eq $freeBytes -or $freeBytes -lt $requiredFreeBytes) {
        $result.status = "BLOCKED"
        $result.reason = "insufficient_or_unknown_free_space"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    $mutex = New-Object System.Threading.Mutex($false, "ReqestraMediaNormalization")
    $mutexAcquired = $mutex.WaitOne(0)
    if (-not $mutexAcquired) {
        $result.status = "BLOCKED"
        $result.reason = "another_normalization_is_running"
        throw [System.InvalidOperationException]::new("BLOCKED_RESULT")
    }

    $directory = Split-Path -Parent $mediaPath
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($mediaPath)
    $tempPath = Join-Path $directory ($baseName + ".reqestra-" + $executionId + ".tmp")
    $backupPath = Join-Path $directory ($baseName + ".reqestra-backup-" + [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ") + ".bak")
    $failedNewPath = Join-Path $directory ($baseName + ".reqestra-failed-" + $executionId + ".tmp")

    $result.tempPath = $tempPath
    $result.backupPath = $backupPath

    $mkvmergeArgs = @("-o", $tempPath, "--disable-track-statistics-tags")
    foreach ($mapped in $mappedActions) {
        $flag = if ($mapped.to) { "1" } else { "0" }
        $mkvmergeArgs += @("--default-track-flag", ("{0}:{1}" -f $mapped.mkvmergeTrackId, $flag))
    }
    $mkvmergeArgs += $mediaPath

    $muxStdout = Join-Path $workDirectory "mkvmerge-stdout.txt"
    $muxStderr = Join-Path $workDirectory "mkvmerge-stderr.txt"
    $muxResult = Invoke-CapturedProcess -FileName $mkvmergePath -Arguments $mkvmergeArgs -StdoutPath $muxStdout -StderrPath $muxStderr

    if ($muxResult.exitCode -gt 1 -or -not (Test-Path -LiteralPath $tempPath -PathType Leaf)) {
        $result.status = "FAILED"
        $result.reason = "mkvmerge_failed"
        throw [System.InvalidOperationException]::new("EXECUTION_FAILED")
    }

    # Validate temporary output before replacement.
    $tempValidatorPath = Join-Path $workDirectory "temp-validator.json"
    $tempValidatorStdout = Join-Path $workDirectory "temp-validator-stdout.txt"
    $tempValidatorStderr = Join-Path $workDirectory "temp-validator-stderr.txt"

    [void](Invoke-MediaValidator `
        -MediaPath $tempPath `
        -LibraryType $libraryType `
        -JsonOutPath $tempValidatorPath `
        -StdoutPath $tempValidatorStdout `
        -StderrPath $tempValidatorStderr)

    if (-not (Test-Path -LiteralPath $tempValidatorPath -PathType Leaf)) {
        $result.status = "FAILED"
        $result.reason = "temp_validation_failed"
        throw [System.InvalidOperationException]::new("EXECUTION_FAILED")
    }

    $tempValidator = Get-Content -LiteralPath $tempValidatorPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $tempContextualPath = Join-Path $workDirectory "temp-contextual.json"
    $tempContextualStdout = Join-Path $workDirectory "temp-contextual-stdout.txt"
    $tempContextualStderr = Join-Path $workDirectory "temp-contextual-stderr.txt"

    [void](Invoke-ContextValidator `
        -ContextPath $contextPath `
        -ValidatorResultPath $tempValidatorPath `
        -JsonOutPath $tempContextualPath `
        -StdoutPath $tempContextualStdout `
        -StderrPath $tempContextualStderr)

    $tempContextual = Get-Content -LiteralPath $tempContextualPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $tempFingerprint = Get-StreamFingerprint -ValidatorResult $tempValidator
    if ($tempFingerprint -ne $expectedFingerprint) {
        $result.status = "FAILED"
        $result.reason = "temp_stream_layout_changed"
        throw [System.InvalidOperationException]::new("EXECUTION_FAILED")
    }

    $tempFindingCodes = @(
        @(Get-FindingCodes -Result $tempValidator) +
        @(Get-FindingCodes -Result $tempContextual) |
            Select-Object -Unique
    )

    foreach ($code in $plannedFindingCodes) {
        if ($tempFindingCodes -contains $code) {
            $result.status = "FAILED"
            $result.reason = "planned_finding_still_present_in_temp"
            throw [System.InvalidOperationException]::new("EXECUTION_FAILED")
        }
    }

    $tempGenericOutcome = [string](Get-PropertyValue -Object $tempValidator -Name "outcome" -Default "PASS")
    $tempContextualOutcome = if ([string](Get-PropertyValue -Object $tempContextual -Name "status" -Default "") -eq "APPLIED") {
        [string](Get-PropertyValue -Object $tempContextual -Name "outcome" -Default "PASS")
    } else {
        "PASS"
    }
    $tempEffectiveOutcome = Get-HigherOutcome -First $tempGenericOutcome -Second $tempContextualOutcome

    if ((Get-OutcomeRank $tempEffectiveOutcome) -gt (Get-OutcomeRank $preflightEffectiveOutcome)) {
        $result.status = "FAILED"
        $result.reason = "temp_validation_worsened"
        throw [System.InvalidOperationException]::new("EXECUTION_FAILED")
    }

    # Ensure source did not change while the remux was running.
    $beforeReplace = Get-Item -LiteralPath $mediaPath
    if ([int64]$beforeReplace.Length -ne $expectedLength -or
        $beforeReplace.LastWriteTimeUtc.ToString("o") -ne $expectedLastWrite) {
        $result.status = "FAILED"
        $result.reason = "source_changed_during_remux"
        throw [System.InvalidOperationException]::new("EXECUTION_FAILED")
    }

    $originalCreationTimeUtc = $beforeReplace.CreationTimeUtc
    $originalLastWriteTimeUtc = $beforeReplace.LastWriteTimeUtc

    [System.IO.File]::Replace($tempPath, $mediaPath, $backupPath, $true)
    $replacementCompleted = $true

    # Preserve filesystem timestamps expected by Radarr/Sonarr/Plex workflows.
    [System.IO.File]::SetCreationTimeUtc($mediaPath, $originalCreationTimeUtc)
    [System.IO.File]::SetLastWriteTimeUtc($mediaPath, $originalLastWriteTimeUtc)

    # Final validation from the actual final path.
    $finalValidatorPath = Join-Path $workDirectory "final-validator.json"
    $finalValidatorStdout = Join-Path $workDirectory "final-validator-stdout.txt"
    $finalValidatorStderr = Join-Path $workDirectory "final-validator-stderr.txt"

    [void](Invoke-MediaValidator `
        -MediaPath $mediaPath `
        -LibraryType $libraryType `
        -JsonOutPath $finalValidatorPath `
        -StdoutPath $finalValidatorStdout `
        -StderrPath $finalValidatorStderr)

    $finalValidator = Get-Content -LiteralPath $finalValidatorPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $finalContextualPath = Join-Path $workDirectory "final-contextual.json"
    $finalContextualStdout = Join-Path $workDirectory "final-contextual-stdout.txt"
    $finalContextualStderr = Join-Path $workDirectory "final-contextual-stderr.txt"

    [void](Invoke-ContextValidator `
        -ContextPath $contextPath `
        -ValidatorResultPath $finalValidatorPath `
        -JsonOutPath $finalContextualPath `
        -StdoutPath $finalContextualStdout `
        -StderrPath $finalContextualStderr)

    $finalContextual = Get-Content -LiteralPath $finalContextualPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $finalFingerprint = Get-StreamFingerprint -ValidatorResult $finalValidator
    $finalFindingCodes = @(
        @(Get-FindingCodes -Result $finalValidator) +
        @(Get-FindingCodes -Result $finalContextual) |
            Select-Object -Unique
    )

    $finalOk = ($finalFingerprint -eq $expectedFingerprint)
    foreach ($code in $plannedFindingCodes) {
        if ($finalFindingCodes -contains $code) {
            $finalOk = $false
        }
    }

    if (-not $finalOk) {
        # Roll back atomically using the backup created by File.Replace.
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            [System.IO.File]::Replace($backupPath, $mediaPath, $failedNewPath, $true)
            [System.IO.File]::SetCreationTimeUtc($mediaPath, $originalCreationTimeUtc)
            [System.IO.File]::SetLastWriteTimeUtc($mediaPath, $originalLastWriteTimeUtc)
            $replacementCompleted = $false

            $result.status = "ROLLED_BACK"
            $result.reason = "final_validation_failed"
            $result.rollback = [ordered]@{
                succeeded = $true
                failedReplacementPreservedAt = $failedNewPath
            }
        }
        else {
            $result.status = "ROLLBACK_FAILED"
            $result.reason = "final_validation_failed_backup_missing"
            $result.rollback = [ordered]@{ succeeded = $false }
        }

        throw [System.InvalidOperationException]::new("EXECUTION_FAILED")
    }

    $mediaValidationSucceeded = $true
    $result.preflight.tempEffectiveOutcome = $tempEffectiveOutcome
    $result.preflight.finalFindingCodes = @($finalFindingCodes)

    # The media is now known-good. Reconcile Arr's database separately.
    try {
        $reconciliation = Invoke-ArrReconciliation `
            -Connection $arrConnection `
            -Target $arrTarget `
            -MediaPath $mediaPath

        $result.arrReconciliation = $reconciliation

        if (-not [bool]$reconciliation.succeeded) {
            $result.status = "NORMALIZED_RECONCILIATION_FAILED"
            $result.reason = [string]$reconciliation.reason
            throw [System.InvalidOperationException]::new("RECONCILIATION_FAILED")
        }
    }
    catch {
        if ($_.Exception.Message -eq "RECONCILIATION_FAILED") {
            throw
        }

        $result.status = "NORMALIZED_RECONCILIATION_FAILED"
        $result.reason = "arr_reconciliation_error"
        $result.arrReconciliation = [ordered]@{
            source = $source
            stage = "post_normalization"
            succeeded = $false
            commandName = $arrTarget.commandName
            entityId = $arrTarget.entityId
            fileId = $arrTarget.fileId
            error = $_.Exception.Message
        }

        throw [System.InvalidOperationException]::new("RECONCILIATION_FAILED")
    }

    if ($DeleteBackupOnSuccess -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        Remove-Item -LiteralPath $backupPath -Force
        $result.backupDeleted = $true
    }

    $result.status = "SUCCESS"
    $result.reason = $null
}
catch {
    if ($_.Exception.Message -ne "BLOCKED_RESULT" -and
        $_.Exception.Message -ne "EXECUTION_FAILED" -and
        $_.Exception.Message -ne "DRY_RUN_COMPLETE" -and
        $_.Exception.Message -ne "RECONCILIATION_FAILED" -and
        $result.status -eq "STARTED") {
        $result.status = "FAILED"
        $result.reason = "unexpected_error"
    }

    # If an unexpected exception occurs after replacement but before a clean
    # success, try to restore the original.
    if ($replacementCompleted -and
        -not $mediaValidationSucceeded -and
        $result.status -ne "SUCCESS" -and
        (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        try {
            [System.IO.File]::Replace($backupPath, $mediaPath, $failedNewPath, $true)
            if ($null -ne $originalCreationTimeUtc) {
                [System.IO.File]::SetCreationTimeUtc($mediaPath, $originalCreationTimeUtc)
            }
            if ($null -ne $originalLastWriteTimeUtc) {
                [System.IO.File]::SetLastWriteTimeUtc($mediaPath, $originalLastWriteTimeUtc)
            }

            $replacementCompleted = $false
            $result.status = "ROLLED_BACK"
            $result.rollback = [ordered]@{
                succeeded = $true
                failedReplacementPreservedAt = $failedNewPath
            }
        }
        catch {
            $result.status = "ROLLBACK_FAILED"
            $result.rollback = [ordered]@{
                succeeded = $false
                error = $_.Exception.Message
            }
        }
    }

    if ($result.reason -eq "unexpected_error") {
        $result.error = $_.Exception.Message
    }
}
finally {
    if ($mutexAcquired -and $null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }

    # Remove incomplete temp output only if it still exists and is not a
    # preserved failed replacement.
    if (-not [string]::IsNullOrWhiteSpace([string]$result.tempPath) -and
        (Test-Path -LiteralPath ([string]$result.tempPath) -PathType Leaf)) {
        Remove-Item -LiteralPath ([string]$result.tempPath) -Force -ErrorAction SilentlyContinue
    }

    $result.completedUtc = [DateTime]::UtcNow.ToString("o")
    Write-ExecutionResult -Result ([pscustomobject]$result)
}
