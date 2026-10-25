Set-StrictMode -Version Latest

$script:NormalizationQueueVersion = "0.2.0"
$script:NormalizationQueueDefaultMode = "AUTO_DRY_RUN"
$script:AutomaticWriteAcknowledgement = "REQESTRA_AUTO_NORMALIZATION_WRITES_MEDIA"

function Get-SafePropertyValue {
    param(
        $Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function Get-NormalizationWorkerSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IntegrationRoot
    )

    $configPath = Join-Path $IntegrationRoot "normalization-worker-config.json"

    $settings = [ordered]@{
        configPath = $configPath
        configExists = $false
        requestedMode = "AUTO_DRY_RUN"
        effectiveMode = "AUTO_DRY_RUN"
        allowAutomaticWrites = $false
        acknowledgementValid = $false
        automaticWritesAuthorized = $false
        configStatus = "DEFAULT_DRY_RUN_NO_CONFIG"
        reason = $null
    }

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return [pscustomobject]$settings
    }

    $settings.configExists = $true

    try {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $settings.configStatus = "CONFIG_PARSE_ERROR"
        $settings.reason = $_.Exception.Message
        return [pscustomobject]$settings
    }

    $requestedMode = ([string](Get-SafePropertyValue -Object $config -Name "mode" -Default "AUTO_DRY_RUN")).Trim().ToUpperInvariant()
    $allowAutomaticWrites = [bool](Get-SafePropertyValue -Object $config -Name "allowAutomaticWrites" -Default $false)
    $acknowledgement = [string](Get-SafePropertyValue -Object $config -Name "safetyAcknowledgement" -Default "")
    $acknowledgementValid = ($acknowledgement -ceq $script:AutomaticWriteAcknowledgement)

    $settings.requestedMode = $requestedMode
    $settings.allowAutomaticWrites = $allowAutomaticWrites
    $settings.acknowledgementValid = $acknowledgementValid

    if ($requestedMode -eq "AUTO_DRY_RUN") {
        $settings.effectiveMode = "AUTO_DRY_RUN"
        $settings.automaticWritesAuthorized = $false
        $settings.configStatus = "CONFIGURED_DRY_RUN"
        return [pscustomobject]$settings
    }

    if ($requestedMode -ne "AUTO_EXECUTE") {
        $settings.effectiveMode = "AUTO_DRY_RUN"
        $settings.automaticWritesAuthorized = $false
        $settings.configStatus = "INVALID_MODE_FAIL_CLOSED"
        $settings.reason = "mode_must_be_AUTO_DRY_RUN_or_AUTO_EXECUTE"
        return [pscustomobject]$settings
    }

    if (-not $allowAutomaticWrites) {
        $settings.effectiveMode = "AUTO_DRY_RUN"
        $settings.automaticWritesAuthorized = $false
        $settings.configStatus = "AUTO_EXECUTE_GATE_NOT_SATISFIED"
        $settings.reason = "allowAutomaticWrites_is_not_true"
        return [pscustomobject]$settings
    }

    if (-not $acknowledgementValid) {
        $settings.effectiveMode = "AUTO_DRY_RUN"
        $settings.automaticWritesAuthorized = $false
        $settings.configStatus = "AUTO_EXECUTE_GATE_NOT_SATISFIED"
        $settings.reason = "safetyAcknowledgement_is_missing_or_invalid"
        return [pscustomobject]$settings
    }

    $settings.effectiveMode = "AUTO_EXECUTE"
    $settings.automaticWritesAuthorized = $true
    $settings.configStatus = "AUTO_EXECUTE_AUTHORIZED"
    $settings.reason = $null

    return [pscustomobject]$settings
}

function Get-NormalizationQueuePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IntegrationRoot
    )

    $root = Join-Path $IntegrationRoot "Queue"

    return [pscustomobject][ordered]@{
        root = $root
        pending = Join-Path $root "pending"
        running = Join-Path $root "running"
        history = Join-Path $root "history"
        results = Join-Path $root "results"
        logs = Join-Path $root "logs"
        queueLog = Join-Path $root "queue.jsonl"
    }
}

function Initialize-NormalizationQueue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IntegrationRoot
    )

    $paths = Get-NormalizationQueuePaths -IntegrationRoot $IntegrationRoot

    foreach ($path in @(
        $paths.root,
        $paths.pending,
        $paths.running,
        $paths.history,
        $paths.results,
        $paths.logs
    )) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    return $paths
}

function Write-NormalizationQueueLog {
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $json = $Object | ConvertTo-Json -Depth 30 -Compress
    Add-Content -LiteralPath $LogPath -Value $json -Encoding UTF8
}

function Get-NormalizationQueueJobId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlanPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet("AUTO_DRY_RUN", "AUTO_EXECUTE")]
        [string]$QueueMode
    )

    $plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if ([string]$plan.status -ne "PLANNED") {
        throw "Only PLANNED normalization plans can be queued."
    }

    if ($null -eq $plan.sourceSnapshot) {
        throw "Normalization plan does not contain a sourceSnapshot."
    }

    $normalizedActions = @(
        @($plan.actions) | ForEach-Object {
            [ordered]@{
                action = [string]$_.action
                audioOrdinal = [int]$_.audioOrdinal
                ffprobeStreamIndex = [int]$_.ffprobeStreamIndex
                language = [string]$_.language
                commentary = [bool]$_.commentary
                from = [bool]$_.from
                to = [bool]$_.to
            }
        }
    )

    # Mode is deliberately part of identity. A dry-run history record must not
    # suppress a later execute-mode job for the same unchanged source.
    $identity = [ordered]@{
        queueMode = $QueueMode
        mediaPath = ([string]$plan.mediaPath).ToLowerInvariant()
        lengthBytes = [int64]$plan.sourceSnapshot.lengthBytes
        lastWriteTimeUtc = [string]$plan.sourceSnapshot.lastWriteTimeUtc
        streamFingerprint = [string]$plan.sourceSnapshot.streamFingerprint
        plannedFindingCodes = @(@($plan.plannedFindingCodes) | ForEach-Object { [string]$_ } | Sort-Object)
        actions = @($normalizedActions)
    }

    $json = $identity | ConvertTo-Json -Depth 20 -Compress
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

function Find-NormalizationQueueJob {
    param(
        [Parameter(Mandatory = $true)]
        $Paths,
        [Parameter(Mandatory = $true)]
        [string]$JobId
    )

    foreach ($entry in @(
        [pscustomobject]@{ State = "QUEUED"; Path = (Join-Path $Paths.pending ($JobId + ".json")) },
        [pscustomobject]@{ State = "RUNNING"; Path = (Join-Path $Paths.running ($JobId + ".json")) },
        [pscustomobject]@{ State = "HISTORY"; Path = (Join-Path $Paths.history ($JobId + ".json")) }
    )) {
        if (Test-Path -LiteralPath $entry.Path -PathType Leaf) {
            return $entry
        }
    }

    return $null
}

function Enqueue-NormalizationPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IntegrationRoot,
        [Parameter(Mandatory = $true)]
        [string]$PlanPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet("Radarr", "Sonarr")]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$EventId
    )

    $paths = Initialize-NormalizationQueue -IntegrationRoot $IntegrationRoot
    $settings = Get-NormalizationWorkerSettings -IntegrationRoot $IntegrationRoot
    $queueMode = [string]$settings.effectiveMode

    $resolvedPlanPath = (Resolve-Path -LiteralPath $PlanPath).Path
    $plan = Get-Content -LiteralPath $resolvedPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if ([string]$plan.status -ne "PLANNED") {
        return [pscustomobject][ordered]@{
            status = "NOT_QUEUED"
            reason = "plan_not_planned"
            jobId = $null
            jobFile = $null
            queueMode = $queueMode
            requestedMode = [string]$settings.requestedMode
            configStatus = [string]$settings.configStatus
        }
    }

    $jobId = Get-NormalizationQueueJobId -PlanPath $resolvedPlanPath -QueueMode $queueMode

    $mutex = New-Object System.Threading.Mutex($false, "ReqestraNormalizationQueueEnqueue")
    $acquired = $false

    try {
        $acquired = $mutex.WaitOne(10000)
        if (-not $acquired) {
            throw "Timed out acquiring normalization queue enqueue mutex."
        }

        $existing = Find-NormalizationQueueJob -Paths $paths -JobId $jobId
        if ($null -ne $existing) {
            return [pscustomobject][ordered]@{
                status = "DUPLICATE"
                reason = "equivalent_job_already_exists"
                jobId = $jobId
                jobFile = $existing.Path
                existingState = $existing.State
                queueMode = $queueMode
                requestedMode = [string]$settings.requestedMode
                configStatus = [string]$settings.configStatus
            }
        }

        $now = [DateTime]::UtcNow
        $job = [pscustomobject][ordered]@{
            schemaVersion = "1.1"
            queueVersion = $script:NormalizationQueueVersion
            queueMode = $queueMode
            requestedModeAtEnqueue = [string]$settings.requestedMode
            configStatusAtEnqueue = [string]$settings.configStatus
            automaticWritesAuthorizedAtEnqueue = [bool]$settings.automaticWritesAuthorized
            jobId = $jobId
            state = "QUEUED"
            source = $Source
            eventId = $EventId
            enqueuedUtc = $now.ToString("o")
            updatedUtc = $now.ToString("o")
            attempts = 0
            recoveryCount = 0
            planPath = $resolvedPlanPath
            mediaPath = [string]$plan.mediaPath
            plannerVersion = [string]$plan.plannerVersion
            plannedFindingCodes = @($plan.plannedFindingCodes)
            sourceSnapshot = $plan.sourceSnapshot
            preflightResultPath = $null
            preflightExecutorStatus = $null
            executionResultPath = $null
            resultPath = $null
            executorStatus = $null
            writeAttempted = $false
            writeAuthorizedUtc = $null
            reason = $null
            completedUtc = $null
            workerVersion = $null
            executorProcessExitCode = $null
            executorStdoutPath = $null
            executorStderrPath = $null
            error = $null
        }

        $pendingPath = Join-Path $paths.pending ($jobId + ".json")
        $tempPath = Join-Path $paths.pending ($jobId + "." + [guid]::NewGuid().ToString("N") + ".tmp")

        $job | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tempPath -Encoding UTF8
        Move-Item -LiteralPath $tempPath -Destination $pendingPath -Force

        Write-NormalizationQueueLog -LogPath $paths.queueLog -Object ([pscustomobject][ordered]@{
            timestampUtc = $now.ToString("o")
            event = "ENQUEUED"
            jobId = $jobId
            source = $Source
            eventId = $EventId
            planPath = $resolvedPlanPath
            mediaPath = [string]$plan.mediaPath
            queueMode = $queueMode
            requestedMode = [string]$settings.requestedMode
            configStatus = [string]$settings.configStatus
        })

        return [pscustomobject][ordered]@{
            status = "ENQUEUED"
            reason = $null
            jobId = $jobId
            jobFile = $pendingPath
            queueMode = $queueMode
            requestedMode = [string]$settings.requestedMode
            configStatus = [string]$settings.configStatus
        }
    }
    finally {
        if ($acquired) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        $mutex.Dispose()
    }
}

function Start-NormalizationQueueWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IntegrationRoot
    )

    $workerPath = Join-Path $IntegrationRoot "NormalizationWorker.ps1"
    if (-not (Test-Path -LiteralPath $workerPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            started = $false
            reason = "worker_script_missing"
            processId = $null
        }
    }

    $powerShellExe = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
        $powerShellExe = "powershell.exe"
    }

    try {
        $arguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", ('"{0}"' -f $workerPath)
        ) -join " "

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powerShellExe
        $startInfo.Arguments = $arguments
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo

        [void]$process.Start()
        $processId = $process.Id
        $process.Dispose()

        return [pscustomobject][ordered]@{
            started = $true
            reason = $null
            processId = $processId
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            started = $false
            reason = $_.Exception.Message
            processId = $null
        }
    }
}

function Get-NormalizationQueueSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IntegrationRoot
    )

    $paths = Initialize-NormalizationQueue -IntegrationRoot $IntegrationRoot
    $settings = Get-NormalizationWorkerSettings -IntegrationRoot $IntegrationRoot

    $pending = @(Get-ChildItem -LiteralPath $paths.pending -Filter "*.json" -File -ErrorAction SilentlyContinue)
    $running = @(Get-ChildItem -LiteralPath $paths.running -Filter "*.json" -File -ErrorAction SilentlyContinue)
    $history = @(Get-ChildItem -LiteralPath $paths.history -Filter "*.json" -File -ErrorAction SilentlyContinue)

    $historyStates = @{}
    foreach ($file in $history) {
        try {
            $job = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $state = [string]$job.state
            if (-not $historyStates.ContainsKey($state)) {
                $historyStates[$state] = 0
            }
            $historyStates[$state]++
        }
        catch {
            if (-not $historyStates.ContainsKey("UNREADABLE")) {
                $historyStates["UNREADABLE"] = 0
            }
            $historyStates["UNREADABLE"]++
        }
    }

    return [pscustomobject][ordered]@{
        queueVersion = $script:NormalizationQueueVersion
        requestedMode = [string]$settings.requestedMode
        effectiveMode = [string]$settings.effectiveMode
        automaticWritesAuthorized = [bool]$settings.automaticWritesAuthorized
        configStatus = [string]$settings.configStatus
        configReason = $settings.reason
        pending = $pending.Count
        running = $running.Count
        history = $history.Count
        historyStates = $historyStates
        queueRoot = $paths.root
    }
}
