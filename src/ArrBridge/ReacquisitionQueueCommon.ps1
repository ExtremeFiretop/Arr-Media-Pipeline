Set-StrictMode -Version Latest

$script:ReacquisitionQueueVersion = "0.1.0"
$script:ReacquisitionDefaultMode = "AUTO_DRY_RUN"
$script:ReacquisitionAutomaticWriteAcknowledgement = "REQESTRA_AUTO_REACQUISITION_CAN_DELETE_AND_REPLACE_MEDIA"
$script:TerminalDvAcknowledgement = "REQESTRA_AUTO_TERMINAL_DV_REMOVES_DOLBY_VISION"
$script:FelDiscardAcknowledgement = "REQESTRA_AUTO_FEL_DISCARDS_DOLBY_VISION_RESIDUAL"

function Get-ReacquisitionSafePropertyValue {
    param($Object, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Get-ReacquisitionWorkerSettings {
    param([Parameter(Mandatory = $true)][string]$IntegrationRoot)

    $configPath = Join-Path $IntegrationRoot "reacquisition-worker-config.json"
    $settings = [ordered]@{
        configPath = $configPath
        configExists = $false
        requestedMode = "AUTO_DRY_RUN"
        effectiveMode = "AUTO_DRY_RUN"
        allowAutomaticWrites = $false
        acknowledgementValid = $false
        automaticWritesAuthorized = $false
        allowTerminalDvRemediation = $false
        terminalDvAcknowledgementValid = $false
        terminalDvAuthorized = $false
        allowFelResidualDiscard = $false
        felDiscardAcknowledgementValid = $false
        felDiscardAuthorized = $false
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

    $requestedMode = ([string](Get-ReacquisitionSafePropertyValue $config "mode" "AUTO_DRY_RUN")).Trim().ToUpperInvariant()
    $allowWrites = [bool](Get-ReacquisitionSafePropertyValue $config "allowAutomaticWrites" $false)
    $ack = [string](Get-ReacquisitionSafePropertyValue $config "safetyAcknowledgement" "")
    $allowTerminal = [bool](Get-ReacquisitionSafePropertyValue $config "allowTerminalDvRemediation" $false)
    $terminalAck = [string](Get-ReacquisitionSafePropertyValue $config "terminalDvAcknowledgement" "")
    $allowFel = [bool](Get-ReacquisitionSafePropertyValue $config "allowFelResidualDiscard" $false)
    $felAck = [string](Get-ReacquisitionSafePropertyValue $config "felResidualDiscardAcknowledgement" "")

    $settings.requestedMode = $requestedMode
    $settings.allowAutomaticWrites = $allowWrites
    $settings.acknowledgementValid = ($ack -ceq $script:ReacquisitionAutomaticWriteAcknowledgement)
    $settings.allowTerminalDvRemediation = $allowTerminal
    $settings.terminalDvAcknowledgementValid = ($terminalAck -ceq $script:TerminalDvAcknowledgement)
    $settings.allowFelResidualDiscard = $allowFel
    $settings.felDiscardAcknowledgementValid = ($felAck -ceq $script:FelDiscardAcknowledgement)

    if ($requestedMode -eq "AUTO_DRY_RUN") {
        $settings.configStatus = "CONFIGURED_DRY_RUN"
        return [pscustomobject]$settings
    }

    if ($requestedMode -ne "AUTO_EXECUTE") {
        $settings.configStatus = "INVALID_MODE_FAIL_CLOSED"
        $settings.reason = "mode_must_be_AUTO_DRY_RUN_or_AUTO_EXECUTE"
        return [pscustomobject]$settings
    }

    if (-not $allowWrites -or -not $settings.acknowledgementValid) {
        $settings.configStatus = "AUTO_EXECUTE_GATE_NOT_SATISFIED"
        $settings.reason = if (-not $allowWrites) { "allowAutomaticWrites_is_not_true" } else { "safetyAcknowledgement_is_missing_or_invalid" }
        return [pscustomobject]$settings
    }

    $settings.effectiveMode = "AUTO_EXECUTE"
    $settings.automaticWritesAuthorized = $true
    $settings.configStatus = "AUTO_EXECUTE_AUTHORIZED"

    $settings.terminalDvAuthorized = (
        $allowTerminal -and $settings.terminalDvAcknowledgementValid
    )
    $settings.felDiscardAuthorized = (
        $settings.terminalDvAuthorized -and $allowFel -and $settings.felDiscardAcknowledgementValid
    )

    return [pscustomobject]$settings
}

function Get-ReacquisitionQueuePaths {
    param([Parameter(Mandatory = $true)][string]$IntegrationRoot)
    $root = Join-Path $IntegrationRoot "ReacquisitionQueue"
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

function Initialize-ReacquisitionQueue {
    param([Parameter(Mandatory = $true)][string]$IntegrationRoot)
    $paths = Get-ReacquisitionQueuePaths -IntegrationRoot $IntegrationRoot
    foreach ($p in @($paths.root,$paths.pending,$paths.running,$paths.history,$paths.results,$paths.logs)) {
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    return $paths
}

function Write-ReacquisitionQueueLog {
    param([Parameter(Mandatory = $true)]$Object,[Parameter(Mandatory = $true)][string]$LogPath)
    Add-Content -LiteralPath $LogPath -Value ($Object | ConvertTo-Json -Depth 30 -Compress) -Encoding UTF8
}

function Get-ReacquisitionQueueJobId {
    param(
        [Parameter(Mandatory = $true)][string]$EventId,
        [Parameter(Mandatory = $true)][ValidateSet("AUTO_DRY_RUN","AUTO_EXECUTE")][string]$QueueMode
    )
    $identity = "$QueueMode`n$EventId"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($identity)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return ([BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
}

function Find-ReacquisitionQueueJob {
    param($Paths,[string]$JobId)
    foreach ($entry in @(
        [pscustomobject]@{ State="QUEUED"; Path=(Join-Path $Paths.pending ($JobId+".json")) },
        [pscustomobject]@{ State="RUNNING"; Path=(Join-Path $Paths.running ($JobId+".json")) },
        [pscustomobject]@{ State="HISTORY"; Path=(Join-Path $Paths.history ($JobId+".json")) }
    )) {
        if (Test-Path -LiteralPath $entry.Path -PathType Leaf) { return $entry }
    }
    return $null
}

function Enqueue-ReacquisitionBridgeEvent {
    param(
        [Parameter(Mandatory = $true)][string]$IntegrationRoot,
        [Parameter(Mandatory = $true)][ValidateSet("Radarr","Sonarr")][string]$Source,
        [Parameter(Mandatory = $true)][string]$EventId,
        [Parameter(Mandatory = $true)][string]$BridgeResultPath,
        [Parameter(Mandatory = $true)][string]$EffectiveOutcome
    )

    $settings = Get-ReacquisitionWorkerSettings -IntegrationRoot $IntegrationRoot
    $mode = [string]$settings.effectiveMode
    $paths = Initialize-ReacquisitionQueue -IntegrationRoot $IntegrationRoot
    $jobId = Get-ReacquisitionQueueJobId -EventId $EventId -QueueMode $mode

    $mutex = New-Object System.Threading.Mutex($false, "ReqestraReacquisitionQueueEnqueue")
    $held = $false
    try {
        $held = $mutex.WaitOne(10000)
        if (-not $held) { throw "Timed out acquiring reacquisition enqueue mutex." }
        $existing = Find-ReacquisitionQueueJob -Paths $paths -JobId $jobId
        if ($null -ne $existing) {
            return [pscustomobject][ordered]@{
                status="DUPLICATE"; reason="equivalent_event_already_queued"; jobId=$jobId; jobFile=$existing.Path;
                existingState=$existing.State; queueMode=$mode; requestedMode=[string]$settings.requestedMode; configStatus=[string]$settings.configStatus
            }
        }

        $now = [DateTime]::UtcNow.ToString("o")
        $job = [pscustomobject][ordered]@{
            schemaVersion="1.0"; queueVersion=$script:ReacquisitionQueueVersion; jobId=$jobId; state="QUEUED";
            queueMode=$mode; requestedModeAtEnqueue=[string]$settings.requestedMode; configStatusAtEnqueue=[string]$settings.configStatus;
            automaticWritesAuthorizedAtEnqueue=[bool]$settings.automaticWritesAuthorized; source=$Source; eventId=$EventId;
            effectiveOutcome=$EffectiveOutcome; bridgeResultPath=$BridgeResultPath; enqueuedUtc=$now; updatedUtc=$now;
            writeAttempted=$false; workerVersion=$null; action=$null; executorStatus=$null; reason=$null; resultPath=$null;
            completedUtc=$null; error=$null
        }
        $pending = Join-Path $paths.pending ($jobId+".json")
        $tmp = $pending + ".tmp-" + [guid]::NewGuid().ToString("N")
        $job | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $pending -Force
        Write-ReacquisitionQueueLog -LogPath $paths.queueLog -Object ([pscustomobject][ordered]@{
            timestampUtc=$now; event="ENQUEUED"; jobId=$jobId; source=$Source; eventId=$EventId; effectiveOutcome=$EffectiveOutcome;
            queueMode=$mode; requestedMode=[string]$settings.requestedMode; configStatus=[string]$settings.configStatus
        })
        return [pscustomobject][ordered]@{
            status="ENQUEUED"; reason=$null; jobId=$jobId; jobFile=$pending; queueMode=$mode;
            requestedMode=[string]$settings.requestedMode; configStatus=[string]$settings.configStatus
        }
    }
    finally {
        if ($held) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function Start-ReacquisitionQueueWorker {
    param([Parameter(Mandatory = $true)][string]$IntegrationRoot)
    $worker = Join-Path $IntegrationRoot "ReacquisitionWorker.ps1"
    if (-not (Test-Path -LiteralPath $worker -PathType Leaf)) {
        return [pscustomobject]@{ started=$false; reason="worker_script_missing"; processId=$null }
    }
    $powershell = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) { $powershell = "powershell.exe" }
    try {
        $si = New-Object System.Diagnostics.ProcessStartInfo
        $si.FileName = $powershell
        $si.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $worker + '"'
        $si.UseShellExecute = $false
        $si.CreateNoWindow = $true
        $si.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $si
        [void]$p.Start()
        $pid = $p.Id
        $p.Dispose()
        return [pscustomobject]@{ started=$true; reason=$null; processId=$pid }
    }
    catch { return [pscustomobject]@{ started=$false; reason=$_.Exception.Message; processId=$null } }
}

function Get-ReacquisitionQueueSummary {
    param([Parameter(Mandatory = $true)][string]$IntegrationRoot)
    $paths = Initialize-ReacquisitionQueue -IntegrationRoot $IntegrationRoot
    $settings = Get-ReacquisitionWorkerSettings -IntegrationRoot $IntegrationRoot
    $pendingFiles = @(Get-ChildItem -LiteralPath $paths.pending -Filter "*.json" -File -ErrorAction SilentlyContinue)
    $runningFiles = @(Get-ChildItem -LiteralPath $paths.running -Filter "*.json" -File -ErrorAction SilentlyContinue)
    $historyFiles = @(Get-ChildItem -LiteralPath $paths.history -Filter "*.json" -File -ErrorAction SilentlyContinue)
    return [pscustomobject][ordered]@{
        queueVersion = $script:ReacquisitionQueueVersion
        requestedMode = [string]$settings.requestedMode
        effectiveMode = [string]$settings.effectiveMode
        automaticWritesAuthorized = [bool]$settings.automaticWritesAuthorized
        terminalDvAuthorized = [bool]$settings.terminalDvAuthorized
        felDiscardAuthorized = [bool]$settings.felDiscardAuthorized
        configStatus = [string]$settings.configStatus
        configReason = $settings.reason
        pending = $pendingFiles.Count
        running = $runningFiles.Count
        history = $historyFiles.Count
        queueRoot = $paths.root
    }
}
