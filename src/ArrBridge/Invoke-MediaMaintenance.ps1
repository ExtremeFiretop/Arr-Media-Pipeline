[CmdletBinding()]
param(
    [switch]$Execute,

    [ValidateRange(0, 3650)]
    [int]$BackupRetentionDays = 7,

    [ValidateRange(0, 87600)]
    [int]$TempRetentionHours = 24,

    [string]$JsonOut = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$MaintenanceVersion = "0.1.1"
$IntegrationRoot = $PSScriptRoot
$ValidatorRoot = Split-Path -Parent $IntegrationRoot
$ValidatorPath = Join-Path $ValidatorRoot "MediaValidator.ps1"
$PolicyPath = Join-Path $ValidatorRoot "validator-policy.json"
$ContextValidatorPath = Join-Path $IntegrationRoot "ContextValidator.ps1"
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"
$CommonPath = Join-Path $IntegrationRoot "MaintenanceCommon.ps1"
$MaintenanceRoot = Join-Path $IntegrationRoot "Maintenance"
$ReportsRoot = Join-Path $MaintenanceRoot "reports"
$WorkRoot = Join-Path $MaintenanceRoot "work"
$AuditLog = Join-Path $MaintenanceRoot "maintenance.jsonl"

if (-not (Test-Path -LiteralPath $CommonPath -PathType Leaf)) {
    throw "MaintenanceCommon.ps1 not found: $CommonPath"
}

. $CommonPath

foreach ($path in @($MaintenanceRoot, $ReportsRoot, $WorkRoot)) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

$runId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + ([guid]::NewGuid().ToString("N").Substring(0, 8))
$runWork = Join-Path $WorkRoot $runId
New-Item -ItemType Directory -Path $runWork -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($JsonOut)) {
    $JsonOut = Join-Path $ReportsRoot ("maintenance-" + $runId + ".json")
}

function Get-PropertyValue {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
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

function Get-OutcomeRank {
    param([string]$Outcome)

    switch ($Outcome) {
        "PASS"      { return 0 }
        "NORMALIZE" { return 1 }
        "REVIEW"    { return 2 }
        "REACQUIRE" { return 3 }
        default     { return 4 }
    }
}

function Get-HigherOutcome {
    param([string]$First, [string]$Second)

    if ((Get-OutcomeRank $Second) -gt (Get-OutcomeRank $First)) {
        return $Second
    }

    return $First
}

function Invoke-CurrentMediaValidation {
    param(
        [Parameter(Mandatory = $true)][string]$MediaPath,
        [Parameter(Mandatory = $true)][string]$ContextPath,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    $context = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $libraryType = [string](Get-PropertyValue -Object $context -Name "libraryType" -Default "")

    if ($libraryType -notin @("Movie", "TV")) {
        throw "Invalid libraryType in context: $libraryType"
    }

    $powerShellExe = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
        $powerShellExe = "powershell.exe"
    }

    $validatorJson = Join-Path $runWork ($Prefix + "-validator.json")
    $validatorStdout = Join-Path $runWork ($Prefix + "-validator-stdout.txt")
    $validatorStderr = Join-Path $runWork ($Prefix + "-validator-stderr.txt")

    $validatorArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ValidatorPath,
        $MediaPath,
        "-LibraryType", $libraryType,
        "-PolicyPath", $PolicyPath,
        "-JsonOut", $validatorJson,
        "-OutputFormat", "Json",
        "-ExitZero"
    )

    [void](Invoke-CapturedProcess `
        -FileName $powerShellExe `
        -Arguments $validatorArgs `
        -StdoutPath $validatorStdout `
        -StderrPath $validatorStderr)

    if (-not (Test-Path -LiteralPath $validatorJson -PathType Leaf)) {
        throw "Current media validator did not produce JSON."
    }

    $validator = Get-Content -LiteralPath $validatorJson -Raw -Encoding UTF8 | ConvertFrom-Json

    $contextualJson = Join-Path $runWork ($Prefix + "-contextual.json")
    $contextualStdout = Join-Path $runWork ($Prefix + "-contextual-stdout.txt")
    $contextualStderr = Join-Path $runWork ($Prefix + "-contextual-stderr.txt")

    $contextualArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ContextValidatorPath,
        "-ContextPath", $ContextPath,
        "-ValidatorResultPath", $validatorJson,
        "-JsonOut", $contextualJson,
        "-ExitZero"
    )

    [void](Invoke-CapturedProcess `
        -FileName $powerShellExe `
        -Arguments $contextualArgs `
        -StdoutPath $contextualStdout `
        -StderrPath $contextualStderr)

    if (-not (Test-Path -LiteralPath $contextualJson -PathType Leaf)) {
        throw "Context validator did not produce JSON."
    }

    $contextual = Get-Content -LiteralPath $contextualJson -Raw -Encoding UTF8 | ConvertFrom-Json

    $genericOutcome = [string](Get-PropertyValue -Object $validator -Name "outcome" -Default "REVIEW")
    $contextualOutcome = if ([string](Get-PropertyValue -Object $contextual -Name "status" -Default "") -eq "APPLIED") {
        [string](Get-PropertyValue -Object $contextual -Name "outcome" -Default "REVIEW")
    }
    else {
        "PASS"
    }

    $effective = Get-HigherOutcome -First $genericOutcome -Second $contextualOutcome

    return [pscustomobject][ordered]@{
        genericOutcome = $genericOutcome
        contextualStatus = [string](Get-PropertyValue -Object $contextual -Name "status" -Default "")
        contextualOutcome = $contextualOutcome
        effectiveOutcome = $effective
        passed = ($effective -eq "PASS")
        validatorResultPath = $validatorJson
        contextualResultPath = $contextualJson
    }
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
    }
}

function Get-CurrentArrFileCheck {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$MediaPath
    )

    $source = [string](Get-PropertyValue -Object $Context -Name "source" -Default "")
    if ($source -notin @("Sonarr", "Radarr")) {
        throw "Unsupported context source: $source"
    }

    $file = Get-PropertyValue -Object $Context -Name "file"
    $fileId = [int](Get-PropertyValue -Object $file -Name "id" -Default 0)
    if ($fileId -le 0) {
        throw "$source context does not contain a valid file id."
    }

    $connection = Get-ArrConnection -Source $source
    $resource = if ($source -eq "Sonarr") { "episodefile/$fileId" } else { "moviefile/$fileId" }
    $uri = $connection.baseUrl + "/api/v3/" + $resource
    $headers = @{ "X-Api-Key" = $connection.apiKey }

    $arrFile = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 30

    $actual = Get-Item -LiteralPath $MediaPath
    $arrPath = [string](Get-PropertyValue -Object $arrFile -Name "path" -Default "")
    $arrBytes = [int64](Get-PropertyValue -Object $arrFile -Name "size" -Default -1)

    $pathMatches = Test-PathEquivalent -First $actual.FullName -Second $arrPath
    $sizeMatches = ([int64]$actual.Length -eq $arrBytes)

    return [pscustomobject][ordered]@{
        source = $source
        fileId = $fileId
        actualPath = $actual.FullName
        arrPath = $arrPath
        pathMatches = $pathMatches
        actualBytes = [int64]$actual.Length
        arrBytes = $arrBytes
        sizeMatches = $sizeMatches
        passed = ($pathMatches -and $sizeMatches)
    }
}

function Write-AuditEvent {
    param(
        [Parameter(Mandatory = $true)]
        $Object
    )

    Add-Content `
        -LiteralPath $AuditLog `
        -Value ($Object | ConvertTo-Json -Depth 20 -Compress) `
        -Encoding UTF8
}

$report = [ordered]@{
    schemaVersion = "1.0"
    maintenanceVersion = $MaintenanceVersion
    runId = $runId
    startedUtc = [DateTime]::UtcNow.ToString("o")
    completedUtc = $null
    mode = if ($Execute) { "EXECUTE" } else { "DRY_RUN" }
    policy = [ordered]@{
        backupRetentionDays = $BackupRetentionDays
        tempRetentionHours = $TempRetentionHours
        requireCurrentValidationPass = $true
        requireArrPathAndSizeMatch = $true
        failedReplacementTempsAutoDelete = $false
    }
    backupCandidates = @()
    tempCandidates = @()
    summary = $null
}

$maintenanceMutex = $null
$maintenanceMutexAcquired = $false
$normalizationMutex = $null
$normalizationMutexAcquired = $false

try {
    if ($Execute) {
        $maintenanceMutex = New-Object System.Threading.Mutex($false, "ReqestraMediaMaintenance")
        $maintenanceMutexAcquired = $maintenanceMutex.WaitOne(0)
        if (-not $maintenanceMutexAcquired) {
            throw "Another media-maintenance execution is already running."
        }

        # Never delete artifacts while an actual normalization owns the write mutex.
        $normalizationMutex = New-Object System.Threading.Mutex($false, "ReqestraMediaNormalization")
        $normalizationMutexAcquired = $normalizationMutex.WaitOne(0)
        if (-not $normalizationMutexAcquired) {
            throw "A media normalization is currently running. Maintenance deletion was not started."
        }
    }

    # -----------------------------------------------------------------
    # Backup discovery
    # -----------------------------------------------------------------
    $executionResultFiles = @()

    $eventsRoot = Join-Path $IntegrationRoot "logs\events"
    if (Test-Path -LiteralPath $eventsRoot) {
        $executionResultFiles += @(
            Get-ChildItem -LiteralPath $eventsRoot `
                -Filter "normalization-execution.json" `
                -File -Recurse -ErrorAction SilentlyContinue
        )
    }

    $queueResults = Join-Path $IntegrationRoot "Queue\results"
    if (Test-Path -LiteralPath $queueResults) {
        $executionResultFiles += @(
            Get-ChildItem -LiteralPath $queueResults `
                -Filter "*.json" `
                -File -ErrorAction SilentlyContinue
        )
    }

    $seenBackups = @{}
    $candidateIndex = 0

    foreach ($resultFile in $executionResultFiles) {
        try {
            $execution = Get-Content -LiteralPath $resultFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            continue
        }

        $backupPath = [string](Get-PropertyValue -Object $execution -Name "backupPath" -Default "")
        if ([string]::IsNullOrWhiteSpace($backupPath)) {
            continue
        }

        $backupKey = $backupPath.ToLowerInvariant()
        if ($seenBackups.ContainsKey($backupKey)) {
            continue
        }
        $seenBackups[$backupKey] = $true
        $candidateIndex++

        $mediaPath = [string](Get-PropertyValue -Object $execution -Name "mediaPath" -Default "")
        $backupExists = Test-Path -LiteralPath $backupPath -PathType Leaf
        $mediaExists = Test-Path -LiteralPath $mediaPath -PathType Leaf

        $completedUtc = $null
        try {
            $completedUtc = [DateTime]::Parse(
                [string](Get-PropertyValue -Object $execution -Name "completedUtc" -Default ""),
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime()
        }
        catch {
            $completedUtc = [DateTime]::UtcNow
        }

        $ageDays = ([DateTime]::UtcNow - $completedUtc).TotalDays
        if ($ageDays -lt 0) { $ageDays = 0 }

        try {
            $static = Get-BackupStaticDecision `
                -Execution $execution `
                -BackupExists $backupExists `
                -MediaExists $mediaExists `
                -AgeDays $ageDays `
                -RetentionDays $BackupRetentionDays
        }
        catch {
            $static = [pscustomobject]@{
                eligible = $false
                reason = "historical_result_schema_error"
            }
        }

        $entry = [ordered]@{
            resultFile = $resultFile.FullName
            executionId = [string](Get-PropertyValue -Object $execution -Name "executionId" -Default "")
            mediaPath = $mediaPath
            backupPath = $backupPath
            ageDays = [math]::Round($ageDays, 3)
            retentionDays = $BackupRetentionDays
            executionHasArrReconciliation = ($null -ne (Get-PropertyValue -Object $execution -Name "arrReconciliation" -Default $null))
            staticEligible = [bool]$static.eligible
            currentValidation = $null
            arrCheck = $null
            eligible = $false
            action = "KEEP"
            reason = [string]$static.reason
            deleted = $false
        }

        if ([bool]$static.eligible) {
            try {
                $planPath = [string](Get-PropertyValue -Object $execution -Name "planPath" -Default "")
                if ([string]::IsNullOrWhiteSpace($planPath) -or -not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
                    throw "Execution plan file is unavailable."
                }

                $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $sourceFiles = Get-PropertyValue -Object $plan -Name "sourceFiles"
                $contextPath = [string](Get-PropertyValue -Object $sourceFiles -Name "contextPath" -Default "")

                if ([string]::IsNullOrWhiteSpace($contextPath) -or -not (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
                    throw "Original context file is unavailable."
                }

                $prefix = "backup-" + $candidateIndex
                $validation = Invoke-CurrentMediaValidation `
                    -MediaPath $mediaPath `
                    -ContextPath $contextPath `
                    -Prefix $prefix

                $entry.currentValidation = $validation

                if (-not [bool]$validation.passed) {
                    $entry.reason = "current_media_validation_not_pass"
                }
                else {
                    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $arrCheck = Get-CurrentArrFileCheck -Context $context -MediaPath $mediaPath
                    $entry.arrCheck = $arrCheck

                    if (-not [bool]$arrCheck.passed) {
                        $entry.reason = "current_arr_record_mismatch"
                    }
                    else {
                        $entry.eligible = $true
                        $entry.action = if ($Execute) { "DELETE" } else { "WOULD_DELETE" }
                        $entry.reason = $null

                        if ($Execute) {
                            Remove-Item -LiteralPath $backupPath -Force
                            $entry.deleted = (-not (Test-Path -LiteralPath $backupPath -PathType Leaf))

                            if (-not $entry.deleted) {
                                $entry.action = "KEEP"
                                $entry.eligible = $false
                                $entry.reason = "backup_delete_verification_failed"
                            }
                            else {
                                Write-AuditEvent ([pscustomobject][ordered]@{
                                    timestampUtc = [DateTime]::UtcNow.ToString("o")
                                    event = "BACKUP_DELETED"
                                    executionId = $entry.executionId
                                    mediaPath = $mediaPath
                                    backupPath = $backupPath
                                    retentionDays = $BackupRetentionDays
                                    currentValidation = $validation.effectiveOutcome
                                    arrPathMatches = $arrCheck.pathMatches
                                    arrSizeMatches = $arrCheck.sizeMatches
                                })
                            }
                        }
                    }
                }
            }
            catch {
                $entry.eligible = $false
                $entry.action = "KEEP"
                $entry.reason = "verification_error"
                $entry.verificationError = $_.Exception.Message
            }
        }

        $report.backupCandidates += [pscustomobject]$entry
    }

    # -----------------------------------------------------------------
    # Temp discovery: derive exact expected artifacts from executor work
    # directories instead of crawling the media libraries.
    # -----------------------------------------------------------------
    if (Test-Path -LiteralPath $eventsRoot) {
        $workDirectories = @(
            Get-ChildItem -LiteralPath $eventsRoot `
                -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "normalization-execution-*" }
        )

        foreach ($workDirectory in $workDirectories) {
            $executionId = $workDirectory.Name.Substring("normalization-execution-".Length)
            $eventDirectory = Split-Path -Parent $workDirectory.FullName
            $planPath = Join-Path $eventDirectory "normalization-plan.json"

            if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
                continue
            }

            try {
                $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $mediaPath = [string](Get-PropertyValue -Object $plan -Name "mediaPath" -Default "")
            }
            catch {
                continue
            }

            if ([string]::IsNullOrWhiteSpace($mediaPath)) {
                continue
            }

            $mediaDirectory = Split-Path -Parent $mediaPath
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($mediaPath)

            $artifacts = @(
                [pscustomobject]@{
                    kind = "ORDINARY_TEMP"
                    path = Join-Path $mediaDirectory ($baseName + ".reqestra-" + $executionId + ".tmp")
                },
                [pscustomobject]@{
                    kind = "FAILED_REPLACEMENT"
                    path = Join-Path $mediaDirectory ($baseName + ".reqestra-failed-" + $executionId + ".tmp")
                }
            )

            foreach ($artifact in $artifacts) {
                $exists = Test-Path -LiteralPath $artifact.path -PathType Leaf
                if (-not $exists) {
                    continue
                }

                $item = Get-Item -LiteralPath $artifact.path
                $ageHours = ([DateTime]::UtcNow - $item.LastWriteTimeUtc).TotalHours
                if ($ageHours -lt 0) { $ageHours = 0 }

                $decision = Get-TempStaticDecision `
                    -ArtifactKind $artifact.kind `
                    -Exists $true `
                    -AgeHours $ageHours `
                    -RetentionHours $TempRetentionHours

                $entry = [ordered]@{
                    artifactKind = $artifact.kind
                    mediaPath = $mediaPath
                    artifactPath = $artifact.path
                    executionId = $executionId
                    ageHours = [math]::Round($ageHours, 3)
                    retentionHours = $TempRetentionHours
                    eligible = [bool]$decision.eligible
                    action = "KEEP"
                    reason = [string]$decision.reason
                    deleted = $false
                }

                if ([bool]$decision.eligible) {
                    $entry.action = if ($Execute) { "DELETE" } else { "WOULD_DELETE" }
                    $entry.reason = $null

                    if ($Execute) {
                        Remove-Item -LiteralPath $artifact.path -Force
                        $entry.deleted = (-not (Test-Path -LiteralPath $artifact.path -PathType Leaf))

                        if (-not $entry.deleted) {
                            $entry.action = "KEEP"
                            $entry.eligible = $false
                            $entry.reason = "temp_delete_verification_failed"
                        }
                        else {
                            Write-AuditEvent ([pscustomobject][ordered]@{
                                timestampUtc = [DateTime]::UtcNow.ToString("o")
                                event = "ABANDONED_TEMP_DELETED"
                                executionId = $executionId
                                mediaPath = $mediaPath
                                artifactPath = $artifact.path
                                retentionHours = $TempRetentionHours
                            })
                        }
                    }
                }

                $report.tempCandidates += [pscustomobject]$entry
            }
        }
    }

    $backupEligible = @($report.backupCandidates | Where-Object { $_.eligible }).Count
    $backupDeleted = @($report.backupCandidates | Where-Object { $_.deleted }).Count
    $tempEligible = @($report.tempCandidates | Where-Object { $_.eligible }).Count
    $tempDeleted = @($report.tempCandidates | Where-Object { $_.deleted }).Count
    $failedProtected = @(
        $report.tempCandidates |
            Where-Object { $_.artifactKind -eq "FAILED_REPLACEMENT" }
    ).Count

    $report.summary = [ordered]@{
        backupsFound = @($report.backupCandidates).Count
        backupsEligible = $backupEligible
        backupsDeleted = $backupDeleted
        tempArtifactsFound = @($report.tempCandidates).Count
        tempArtifactsEligible = $tempEligible
        tempArtifactsDeleted = $tempDeleted
        failedReplacementArtifactsProtected = $failedProtected
    }
}
finally {
    if ($normalizationMutexAcquired -and $null -ne $normalizationMutex) {
        try { $normalizationMutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $normalizationMutex) {
        $normalizationMutex.Dispose()
    }

    if ($maintenanceMutexAcquired -and $null -ne $maintenanceMutex) {
        try { $maintenanceMutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $maintenanceMutex) {
        $maintenanceMutex.Dispose()
    }

    $report.completedUtc = [DateTime]::UtcNow.ToString("o")
    $report | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $JsonOut -Encoding UTF8

    Write-Host ""
    Write-Host "Reqestra Media Maintenance"
    Write-Host "=========================="
    Write-Host ""
    Write-Host ("Mode:                  {0}" -f $report.mode)
    Write-Host ("Backup retention:      {0} day(s)" -f $BackupRetentionDays)
    Write-Host ("Temp retention:        {0} hour(s)" -f $TempRetentionHours)
    Write-Host ("Backups found:         {0}" -f @($report.backupCandidates).Count)
    Write-Host ("Backups eligible:      {0}" -f @($report.backupCandidates | Where-Object { $_.eligible }).Count)
    Write-Host ("Backups deleted:       {0}" -f @($report.backupCandidates | Where-Object { $_.deleted }).Count)
    Write-Host ("Temp artifacts found:  {0}" -f @($report.tempCandidates).Count)
    Write-Host ("Temp artifacts eligible:{0}" -f @($report.tempCandidates | Where-Object { $_.eligible }).Count)
    Write-Host ("Temp artifacts deleted:{0}" -f @($report.tempCandidates | Where-Object { $_.deleted }).Count)
    Write-Host ("Report:                 {0}" -f $JsonOut)
}
