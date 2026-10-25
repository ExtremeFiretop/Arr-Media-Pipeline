[CmdletBinding()]
param(
    [ValidateRange(1, 1000)]
    [int]$MaxJobs = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerVersion = "0.2.0"
$IntegrationRoot = $PSScriptRoot
$ExecutorPath = Join-Path $IntegrationRoot "Invoke-Normalization.ps1"
$QueueCommonPath = Join-Path $IntegrationRoot "QueueCommon.ps1"

if (-not (Test-Path -LiteralPath $QueueCommonPath -PathType Leaf)) {
    exit 0
}

. $QueueCommonPath

$paths = Initialize-NormalizationQueue -IntegrationRoot $IntegrationRoot
$workerLog = Join-Path $paths.logs ("worker-" + [DateTime]::UtcNow.ToString("yyyy-MM-dd") + ".log")

function Write-WorkerLog {
    param([string]$Message)

    $line = "{0} {1}" -f ([DateTime]::UtcNow.ToString("o")), $Message
    Add-Content -LiteralPath $workerLog -Value $line -Encoding UTF8
}

function Set-JobProperty {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($Job.PSObject.Properties[$Name]) {
        $Job.$Name = $Value
    }
    else {
        $Job | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Save-Job {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Set-JobProperty -Job $Job -Name "updatedUtc" -Value ([DateTime]::UtcNow.ToString("o"))
    $Job | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Move-JobToHistory {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][string]$RunningPath
    )

    Save-Job -Job $Job -Path $RunningPath
    $historyPath = Join-Path $paths.history (([string]$Job.jobId) + ".json")
    Move-Item -LiteralPath $RunningPath -Destination $historyPath -Force
    return $historyPath
}

function Invoke-Executor {
    param(
        [Parameter(Mandatory = $true)][string]$PlanPath,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [switch]$Execute
    )

    $powerShellExe = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
        $powerShellExe = "powershell.exe"
    }

    $argumentParts = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $ExecutorPath),
        "-PlanPath", ('"{0}"' -f $PlanPath),
        "-JsonOut", ('"{0}"' -f $ResultPath)
    )

    if ($Execute) {
        $argumentParts += "-Execute"
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellExe
    $startInfo.Arguments = ($argumentParts -join " ")
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

    return $exitCode
}

function Get-TerminalJobStateFromExecution {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutorStatus
    )

    switch ($ExecutorStatus) {
        "SUCCESS"                           { return "SUCCESS" }
        "DRY_RUN_READY"                     { return "DRY_RUN_READY" }
        "BLOCKED"                           { return "BLOCKED" }
        "NORMALIZED_RECONCILIATION_FAILED" { return "NORMALIZED_RECONCILIATION_FAILED" }
        "ROLLED_BACK"                       { return "ROLLED_BACK" }
        "ROLLBACK_FAILED"                   { return "ROLLBACK_FAILED" }
        "FAILED"                            { return "FAILED" }
        default                             { return "FAILED" }
    }
}

function Finalize-JobFromExecutionResult {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)]$Execution,
        [Parameter(Mandatory = $true)][string]$ResultPath
    )

    $executorStatus = [string](Get-SafePropertyValue -Object $Execution -Name "status" -Default "FAILED")
    $reason = Get-SafePropertyValue -Object $Execution -Name "reason" -Default $null

    Set-JobProperty -Job $Job -Name "executorStatus" -Value $executorStatus
    Set-JobProperty -Job $Job -Name "resultPath" -Value $ResultPath
    Set-JobProperty -Job $Job -Name "state" -Value (Get-TerminalJobStateFromExecution -ExecutorStatus $executorStatus)
    Set-JobProperty -Job $Job -Name "reason" -Value $reason
    Set-JobProperty -Job $Job -Name "completedUtc" -Value ([DateTime]::UtcNow.ToString("o"))
    Set-JobProperty -Job $Job -Name "workerVersion" -Value $WorkerVersion
}

function Finalize-RecoveryRequired {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][string]$RunningPath,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    Set-JobProperty -Job $Job -Name "state" -Value "RECOVERY_REQUIRED"
    Set-JobProperty -Job $Job -Name "reason" -Value $Reason
    Set-JobProperty -Job $Job -Name "completedUtc" -Value ([DateTime]::UtcNow.ToString("o"))
    Set-JobProperty -Job $Job -Name "workerVersion" -Value $WorkerVersion

    [void](Move-JobToHistory -Job $Job -RunningPath $RunningPath)

    Write-NormalizationQueueLog -LogPath $paths.queueLog -Object ([pscustomobject][ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        event = "RECOVERY_REQUIRED"
        jobId = [string]$Job.jobId
        queueMode = [string](Get-SafePropertyValue -Object $Job -Name "queueMode" -Default "AUTO_DRY_RUN")
        reason = $Reason
        executionResultPath = Get-SafePropertyValue -Object $Job -Name "executionResultPath" -Default $null
    })
}

$mutex = New-Object System.Threading.Mutex($false, "ReqestraNormalizationWorker")
$acquired = $false

try {
    $acquired = $mutex.WaitOne(0)

    if (-not $acquired) {
        exit 0
    }

    $startupSettings = Get-NormalizationWorkerSettings -IntegrationRoot $IntegrationRoot
    Write-WorkerLog (
        "Worker {0} started. RequestedMode={1}; EffectiveMode={2}; ConfigStatus={3}; WritesAuthorized={4}" -f
        $WorkerVersion,
        $startupSettings.requestedMode,
        $startupSettings.effectiveMode,
        $startupSettings.configStatus,
        $startupSettings.automaticWritesAuthorized
    )

    # Crash recovery:
    # - dry-run jobs can always be safely requeued
    # - execute-mode jobs can be requeued only if the execute subprocess was
    #   never launched
    # - after write launch, never blindly replay. If a complete executor result
    #   exists, finalize from it; otherwise require manual recovery review.
    foreach ($runningFile in @(Get-ChildItem -LiteralPath $paths.running -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        try {
            $job = Get-Content -LiteralPath $runningFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $queueMode = [string](Get-SafePropertyValue -Object $job -Name "queueMode" -Default "AUTO_DRY_RUN")
            $writeAttempted = [bool](Get-SafePropertyValue -Object $job -Name "writeAttempted" -Default $false)
            $executionResultPath = [string](Get-SafePropertyValue -Object $job -Name "executionResultPath" -Default "")

            $existingRecoveryCount = [int](Get-SafePropertyValue -Object $job -Name "recoveryCount" -Default 0)
            Set-JobProperty -Job $job -Name "recoveryCount" -Value ($existingRecoveryCount + 1)

            if ($queueMode -eq "AUTO_EXECUTE" -and $writeAttempted) {
                if (-not [string]::IsNullOrWhiteSpace($executionResultPath) -and
                    (Test-Path -LiteralPath $executionResultPath -PathType Leaf)) {
                    try {
                        $execution = Get-Content -LiteralPath $executionResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        $status = [string](Get-SafePropertyValue -Object $execution -Name "status" -Default "")

                        if (-not [string]::IsNullOrWhiteSpace($status) -and $status -ne "STARTED") {
                            Finalize-JobFromExecutionResult `
                                -Job $job `
                                -Execution $execution `
                                -ResultPath $executionResultPath

                            [void](Move-JobToHistory -Job $job -RunningPath $runningFile.FullName)

                            Write-NormalizationQueueLog -LogPath $paths.queueLog -Object ([pscustomobject][ordered]@{
                                timestampUtc = [DateTime]::UtcNow.ToString("o")
                                event = "RECOVERED_FROM_COMPLETED_EXECUTOR_RESULT"
                                jobId = [string]$job.jobId
                                executorStatus = [string]$job.executorStatus
                                state = [string]$job.state
                            })

                            continue
                        }
                    }
                    catch {
                        # Fall through to RECOVERY_REQUIRED.
                    }
                }

                Finalize-RecoveryRequired `
                    -Job $job `
                    -RunningPath $runningFile.FullName `
                    -Reason "automatic_execute_interrupted_after_write_launch"

                continue
            }

            Set-JobProperty -Job $job -Name "state" -Value "QUEUED"
            Set-JobProperty -Job $job -Name "reason" -Value "recovered_after_worker_interruption"

            $pendingPath = Join-Path $paths.pending $runningFile.Name
            Save-Job -Job $job -Path $runningFile.FullName
            Move-Item -LiteralPath $runningFile.FullName -Destination $pendingPath -Force

            Write-NormalizationQueueLog -LogPath $paths.queueLog -Object ([pscustomobject][ordered]@{
                timestampUtc = [DateTime]::UtcNow.ToString("o")
                event = "RECOVERED"
                jobId = [string]$job.jobId
                queueMode = $queueMode
                recoveryCount = [int]$job.recoveryCount
            })
        }
        catch {
            Write-WorkerLog ("Failed to recover running job {0}: {1}" -f $runningFile.FullName, $_.Exception.Message)
        }
    }

    $processed = 0

    while ($processed -lt $MaxJobs) {
        $next = Get-ChildItem -LiteralPath $paths.pending -Filter "*.json" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc, Name |
            Select-Object -First 1

        if ($null -eq $next) {
            break
        }

        $runningPath = Join-Path $paths.running $next.Name

        try {
            Move-Item -LiteralPath $next.FullName -Destination $runningPath -ErrorAction Stop
        }
        catch {
            continue
        }

        $processed++

        try {
            $job = Get-Content -LiteralPath $runningPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $queueMode = [string](Get-SafePropertyValue -Object $job -Name "queueMode" -Default "AUTO_DRY_RUN")

            if ($queueMode -notin @("AUTO_DRY_RUN", "AUTO_EXECUTE")) {
                Set-JobProperty -Job $job -Name "state" -Value "BLOCKED"
                Set-JobProperty -Job $job -Name "reason" -Value "invalid_job_queue_mode"
                Set-JobProperty -Job $job -Name "completedUtc" -Value ([DateTime]::UtcNow.ToString("o"))
                Set-JobProperty -Job $job -Name "workerVersion" -Value $WorkerVersion
                [void](Move-JobToHistory -Job $job -RunningPath $runningPath)
                continue
            }

            Set-JobProperty -Job $job -Name "state" -Value "PREFLIGHT"
            Set-JobProperty -Job $job -Name "attempts" -Value ([int](Get-SafePropertyValue -Object $job -Name "attempts" -Default 0) + 1)
            Set-JobProperty -Job $job -Name "reason" -Value $null
            Save-Job -Job $job -Path $runningPath

            $jobId = [string]$job.jobId
            $timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")
            $preflightResultPath = Join-Path $paths.results ($jobId + "-" + $timestamp + "-preflight.json")
            $preflightStdoutPath = Join-Path $paths.results ($jobId + "-" + $timestamp + "-preflight-stdout.txt")
            $preflightStderrPath = Join-Path $paths.results ($jobId + "-" + $timestamp + "-preflight-stderr.txt")

            Set-JobProperty -Job $job -Name "preflightResultPath" -Value $preflightResultPath
            Save-Job -Job $job -Path $runningPath

            Write-NormalizationQueueLog -LogPath $paths.queueLog -Object ([pscustomobject][ordered]@{
                timestampUtc = [DateTime]::UtcNow.ToString("o")
                event = "PREFLIGHT_STARTED"
                jobId = $jobId
                attempt = [int]$job.attempts
                queueMode = $queueMode
                planPath = [string]$job.planPath
            })

            $preflightExitCode = Invoke-Executor `
                -PlanPath ([string]$job.planPath) `
                -ResultPath $preflightResultPath `
                -StdoutPath $preflightStdoutPath `
                -StderrPath $preflightStderrPath

            if (-not (Test-Path -LiteralPath $preflightResultPath -PathType Leaf)) {
                Set-JobProperty -Job $job -Name "state" -Value "FAILED"
                Set-JobProperty -Job $job -Name "preflightExecutorStatus" -Value "NO_RESULT"
                Set-JobProperty -Job $job -Name "executorStatus" -Value "NO_RESULT"
                Set-JobProperty -Job $job -Name "reason" -Value "preflight_executor_result_missing"
                Set-JobProperty -Job $job -Name "completedUtc" -Value ([DateTime]::UtcNow.ToString("o"))
                Set-JobProperty -Job $job -Name "workerVersion" -Value $WorkerVersion
                Set-JobProperty -Job $job -Name "executorProcessExitCode" -Value ([int]$preflightExitCode)
                Set-JobProperty -Job $job -Name "executorStdoutPath" -Value $preflightStdoutPath
                Set-JobProperty -Job $job -Name "executorStderrPath" -Value $preflightStderrPath
                [void](Move-JobToHistory -Job $job -RunningPath $runningPath)
                continue
            }

            $preflightExecution = Get-Content -LiteralPath $preflightResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $preflightStatus = [string](Get-SafePropertyValue -Object $preflightExecution -Name "status" -Default "FAILED")
            Set-JobProperty -Job $job -Name "preflightExecutorStatus" -Value $preflightStatus

            if ($preflightStatus -ne "DRY_RUN_READY") {
                Finalize-JobFromExecutionResult `
                    -Job $job `
                    -Execution $preflightExecution `
                    -ResultPath $preflightResultPath

                Set-JobProperty -Job $job -Name "executorProcessExitCode" -Value ([int]$preflightExitCode)
                Set-JobProperty -Job $job -Name "executorStdoutPath" -Value $preflightStdoutPath
                Set-JobProperty -Job $job -Name "executorStderrPath" -Value $preflightStderrPath

                [void](Move-JobToHistory -Job $job -RunningPath $runningPath)
                continue
            }

            if ($queueMode -eq "AUTO_DRY_RUN") {
                Finalize-JobFromExecutionResult `
                    -Job $job `
                    -Execution $preflightExecution `
                    -ResultPath $preflightResultPath

                Set-JobProperty -Job $job -Name "executorProcessExitCode" -Value ([int]$preflightExitCode)
                Set-JobProperty -Job $job -Name "executorStdoutPath" -Value $preflightStdoutPath
                Set-JobProperty -Job $job -Name "executorStderrPath" -Value $preflightStderrPath

                [void](Move-JobToHistory -Job $job -RunningPath $runningPath)

                Write-NormalizationQueueLog -LogPath $paths.queueLog -Object ([pscustomobject][ordered]@{
                    timestampUtc = [DateTime]::UtcNow.ToString("o")
                    event = "JOB_COMPLETED"
                    jobId = $jobId
                    queueMode = $queueMode
                    state = [string]$job.state
                    executorStatus = [string]$job.executorStatus
                    reason = $job.reason
                    resultPath = $job.resultPath
                })

                continue
            }

            # AUTO_EXECUTE gate is re-read immediately before write launch.
            $writeSettings = Get-NormalizationWorkerSettings -IntegrationRoot $IntegrationRoot

            if ([string]$writeSettings.effectiveMode -ne "AUTO_EXECUTE" -or
                -not [bool]$writeSettings.automaticWritesAuthorized) {
                Set-JobProperty -Job $job -Name "state" -Value "BLOCKED"
                Set-JobProperty -Job $job -Name "executorStatus" -Value "BLOCKED"
                Set-JobProperty -Job $job -Name "reason" -Value "auto_execute_gate_not_currently_enabled"
                Set-JobProperty -Job $job -Name "resultPath" -Value $preflightResultPath
                Set-JobProperty -Job $job -Name "completedUtc" -Value ([DateTime]::UtcNow.ToString("o"))
                Set-JobProperty -Job $job -Name "workerVersion" -Value $WorkerVersion
                [void](Move-JobToHistory -Job $job -RunningPath $runningPath)

                Write-NormalizationQueueLog -LogPath $paths.queueLog -Object ([pscustomobject][ordered]@{
                    timestampUtc = [DateTime]::UtcNow.ToString("o")
                    event = "AUTO_EXECUTE_BLOCKED_BY_GATE"
                    jobId = $jobId
                    requestedMode = [string]$writeSettings.requestedMode
                    effectiveMode = [string]$writeSettings.effectiveMode
                    configStatus = [string]$writeSettings.configStatus
                    reason = $writeSettings.reason
                })

                continue
            }

            $executeTimestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")
            $executionResultPath = Join-Path $paths.results ($jobId + "-" + $executeTimestamp + "-execute.json")
            $executionStdoutPath = Join-Path $paths.results ($jobId + "-" + $executeTimestamp + "-execute-stdout.txt")
            $executionStderrPath = Join-Path $paths.results ($jobId + "-" + $executeTimestamp + "-execute-stderr.txt")

            Set-JobProperty -Job $job -Name "state" -Value "RUNNING"
            Set-JobProperty -Job $job -Name "executionResultPath" -Value $executionResultPath
            Set-JobProperty -Job $job -Name "resultPath" -Value $executionResultPath
            Set-JobProperty -Job $job -Name "writeAttempted" -Value $true
            Set-JobProperty -Job $job -Name "writeAuthorizedUtc" -Value ([DateTime]::UtcNow.ToString("o"))
            Save-Job -Job $job -Path $runningPath

            Write-NormalizationQueueLog -LogPath $paths.queueLog -Object ([pscustomobject][ordered]@{
                timestampUtc = [DateTime]::UtcNow.ToString("o")
                event = "AUTO_EXECUTE_STARTED"
                jobId = $jobId
                planPath = [string]$job.planPath
                configStatus = [string]$writeSettings.configStatus
            })

            $executeExitCode = Invoke-Executor `
                -PlanPath ([string]$job.planPath) `
                -ResultPath $executionResultPath `
                -StdoutPath $executionStdoutPath `
                -StderrPath $executionStderrPath `
                -Execute

            if (-not (Test-Path -LiteralPath $executionResultPath -PathType Leaf)) {
                Set-JobProperty -Job $job -Name "state" -Value "RECOVERY_REQUIRED"
                Set-JobProperty -Job $job -Name "executorStatus" -Value "NO_RESULT"
                Set-JobProperty -Job $job -Name "reason" -Value "execute_result_missing_after_write_launch"
                Set-JobProperty -Job $job -Name "completedUtc" -Value ([DateTime]::UtcNow.ToString("o"))
                Set-JobProperty -Job $job -Name "workerVersion" -Value $WorkerVersion
                Set-JobProperty -Job $job -Name "executorProcessExitCode" -Value ([int]$executeExitCode)
                Set-JobProperty -Job $job -Name "executorStdoutPath" -Value $executionStdoutPath
                Set-JobProperty -Job $job -Name "executorStderrPath" -Value $executionStderrPath
                [void](Move-JobToHistory -Job $job -RunningPath $runningPath)
                continue
            }

            $execution = Get-Content -LiteralPath $executionResultPath -Raw -Encoding UTF8 | ConvertFrom-Json

            Finalize-JobFromExecutionResult `
                -Job $job `
                -Execution $execution `
                -ResultPath $executionResultPath

            Set-JobProperty -Job $job -Name "executorProcessExitCode" -Value ([int]$executeExitCode)
            Set-JobProperty -Job $job -Name "executorStdoutPath" -Value $executionStdoutPath
            Set-JobProperty -Job $job -Name "executorStderrPath" -Value $executionStderrPath

            [void](Move-JobToHistory -Job $job -RunningPath $runningPath)

            Write-NormalizationQueueLog -LogPath $paths.queueLog -Object ([pscustomobject][ordered]@{
                timestampUtc = [DateTime]::UtcNow.ToString("o")
                event = "JOB_COMPLETED"
                jobId = $jobId
                queueMode = $queueMode
                state = [string]$job.state
                executorStatus = [string]$job.executorStatus
                reason = $job.reason
                resultPath = $job.resultPath
            })
        }
        catch {
            try {
                if (Test-Path -LiteralPath $runningPath -PathType Leaf) {
                    $job = Get-Content -LiteralPath $runningPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $queueMode = [string](Get-SafePropertyValue -Object $job -Name "queueMode" -Default "AUTO_DRY_RUN")
                    $writeAttempted = [bool](Get-SafePropertyValue -Object $job -Name "writeAttempted" -Default $false)

                    if ($queueMode -eq "AUTO_EXECUTE" -and $writeAttempted) {
                        Set-JobProperty -Job $job -Name "state" -Value "RECOVERY_REQUIRED"
                        Set-JobProperty -Job $job -Name "reason" -Value "worker_error_after_write_launch"
                    }
                    else {
                        Set-JobProperty -Job $job -Name "state" -Value "FAILED"
                        Set-JobProperty -Job $job -Name "reason" -Value "worker_error"
                    }

                    Set-JobProperty -Job $job -Name "error" -Value $_.Exception.Message
                    Set-JobProperty -Job $job -Name "completedUtc" -Value ([DateTime]::UtcNow.ToString("o"))
                    Set-JobProperty -Job $job -Name "workerVersion" -Value $WorkerVersion
                    [void](Move-JobToHistory -Job $job -RunningPath $runningPath)

                    Write-NormalizationQueueLog -LogPath $paths.queueLog -Object ([pscustomobject][ordered]@{
                        timestampUtc = [DateTime]::UtcNow.ToString("o")
                        event = if ($queueMode -eq "AUTO_EXECUTE" -and $writeAttempted) { "RECOVERY_REQUIRED" } else { "JOB_FAILED" }
                        jobId = [string]$job.jobId
                        reason = [string]$job.reason
                        error = $_.Exception.Message
                    })
                }
            }
            catch {
                Write-WorkerLog ("Failed to persist job failure for {0}: {1}" -f $runningPath, $_.Exception.Message)
            }
        }
    }

    Write-WorkerLog ("Worker completed. Processed {0} job(s)." -f $processed)
}
catch {
    Write-WorkerLog ("Worker fatal error: {0}" -f $_.Exception.Message)
}
finally {
    if ($acquired) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    $mutex.Dispose()
}

exit 0
