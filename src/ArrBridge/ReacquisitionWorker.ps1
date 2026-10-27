[CmdletBinding()]
param([ValidateRange(0,10000)][int]$MaxJobs = 0)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerVersion = "0.2.2"
$IntegrationRoot = $PSScriptRoot
$QueueCommonPath = Join-Path $IntegrationRoot "ReacquisitionQueueCommon.ps1"
$ChainCommonPath = Join-Path $IntegrationRoot "ReacquisitionChainCommon.ps1"
$SonarrCommonPath = Join-Path $IntegrationRoot "SonarrReacquisitionCommon.ps1"
. $QueueCommonPath
. $ChainCommonPath
. $SonarrCommonPath

$paths = Initialize-ReacquisitionQueue -IntegrationRoot $IntegrationRoot
$workerLog = Join-Path $paths.logs ("worker-" + [DateTime]::UtcNow.ToString("yyyy-MM-dd") + ".log")

function Write-WorkerLog { param([string]$Message) Add-Content -LiteralPath $workerLog -Value (([DateTime]::UtcNow.ToString("o"))+" "+$Message) -Encoding UTF8 }
function Set-JobProperty {
    param($Job,[string]$Name,$Value)
    if ($Job.PSObject.Properties[$Name]) { $Job.$Name = $Value }
    else { $Job | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}
function Save-Job { param($Job,[string]$Path) Set-JobProperty $Job "updatedUtc" ([DateTime]::UtcNow.ToString("o")); $Job | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $Path -Encoding UTF8 }
function Move-JobHistory {
    param($Job,[string]$RunningPath)
    Save-Job $Job $RunningPath
    $dest = Join-Path $paths.history (([string]$Job.jobId)+".json")
    Move-Item -LiteralPath $RunningPath -Destination $dest -Force
    return $dest
}
function Quote-Arg {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"','\"') + '"'
}
function Invoke-JsonScript {
    param([string]$ScriptName,[object[]]$Arguments,[string]$ResultPath,[string]$Prefix)
    $scriptPath = Join-Path $IntegrationRoot $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Required script missing: $scriptPath" }
    $powershell = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) { $powershell = "powershell.exe" }
    $stdout = Join-Path $paths.results ($Prefix+"-stdout.txt")
    $stderr = Join-Path $paths.results ($Prefix+"-stderr.txt")
    $allArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$scriptPath) + @($Arguments) + @("-JsonOut",$ResultPath)
    $argString = (@($allArgs | ForEach-Object { Quote-Arg ([string]$_) })) -join " "
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = $powershell; $si.Arguments = $argString; $si.UseShellExecute = $false; $si.CreateNoWindow = $true
    $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process; $p.StartInfo = $si
    [void]$p.Start(); $outTask=$p.StandardOutput.ReadToEndAsync(); $errTask=$p.StandardError.ReadToEndAsync(); $p.WaitForExit()
    $exit=$p.ExitCode; $out=$outTask.Result; $err=$errTask.Result; $p.Dispose()
    $out | Set-Content -LiteralPath $stdout -Encoding UTF8; $err | Set-Content -LiteralPath $stderr -Encoding UTF8
    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) { throw "$ScriptName produced no JSON result. ExitCode=$exit" }
    $json = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return [pscustomobject]@{ result=$json; exitCode=$exit; stdout=$stdout; stderr=$stderr }
}
function New-ResultPath { param([string]$JobId,[string]$Stage) Join-Path $paths.results ("$JobId-"+[DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")+"-$Stage.json") }
function Get-CurrentWriteSettings {
    $s = Get-ReacquisitionWorkerSettings -IntegrationRoot $IntegrationRoot
    if ([string]$s.effectiveMode -ne "AUTO_EXECUTE" -or -not [bool]$s.automaticWritesAuthorized) { return $null }
    return $s
}
function Get-ChainForContext {
    param($Context)
    $source = [string](Get-ReacquisitionSafePropertyValue $Context "source" "")
    $entity = Get-ReacquisitionSafePropertyValue $Context "entity" $null
    $entityId = [int](Get-ReacquisitionSafePropertyValue $entity "id" 0)
    if ($entityId -le 0) { return $null }
    if ($source -eq "Radarr") {
        $path = Get-ReacquisitionChainPath -IntegrationRoot $IntegrationRoot -Source "Radarr" -EntityId $entityId
    }
    elseif ($source -eq "Sonarr") {
        $episode = Get-ReacquisitionSafePropertyValue $Context "episode" $null
        [int[]]$ids = @(@(Get-ReacquisitionSafePropertyValue $episode "ids" @()) | ForEach-Object { [int]$_ } | Where-Object { $_ -gt 0 })
        if ($ids.Count -eq 0) { return $null }
        $key = Get-SonarrEpisodeSetKey -EpisodeIds $ids
        $path = Get-ReacquisitionChainPath -IntegrationRoot $IntegrationRoot -Source "Sonarr" -EntityId $entityId -Discriminator $key
    }
    else { return $null }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $chain = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    return [pscustomobject]@{ path=$path; chain=$chain }
}
function Complete-WorkerJob {
    param($Job,[string]$RunningPath,[string]$State,[string]$Action,[string]$Status,[string]$Reason,[string]$ResultPath)
    Set-JobProperty $Job "state" $State; Set-JobProperty $Job "action" $Action; Set-JobProperty $Job "executorStatus" $Status
    Set-JobProperty $Job "reason" $Reason; Set-JobProperty $Job "resultPath" $ResultPath; Set-JobProperty $Job "workerVersion" $WorkerVersion
    Set-JobProperty $Job "completedUtc" ([DateTime]::UtcNow.ToString("o")); [void](Move-JobHistory $Job $RunningPath)
}
function Invoke-TerminalDvAutomation {
    param($Job,[string]$RunningPath,[int]$MovieId,[string]$JobId)
    $prePath = New-ResultPath $JobId "terminal-dv-preflight"
    $pre = Invoke-JsonScript "Invoke-TerminalDvRemediation.ps1" @("-MovieId",$MovieId) $prePath ($JobId+"-terminal-preflight")
    $r = $pre.result
    $status = [string](Get-ReacquisitionSafePropertyValue $r "status" "BLOCKED")
    if ($status -notin @("DRY_RUN_READY_BUILD","DRY_RUN_READY_REPLACE")) {
        Complete-WorkerJob $Job $RunningPath "REVIEW_REQUIRED" "TERMINAL_DV" $status ([string](Get-ReacquisitionSafePropertyValue $r "reason" "terminal_dv_not_eligible")) $prePath
        return
    }

    if ([string]$Job.queueMode -eq "AUTO_DRY_RUN") {
        Complete-WorkerJob $Job $RunningPath "COMPLETED" "TERMINAL_DV_PREFLIGHT" $status $null $prePath
        return
    }

    $settings = Get-CurrentWriteSettings
    if ($null -eq $settings -or -not [bool]$settings.terminalDvAuthorized) {
        Complete-WorkerJob $Job $RunningPath "BLOCKED" "TERMINAL_DV" "TERMINAL_DV_GATE_DISABLED" "terminal_dv_automatic_gate_not_authorized" $prePath
        return
    }
    $decision = Get-ReacquisitionSafePropertyValue $r "remediationDecision" $null
    $felDiscard = [bool](Get-ReacquisitionSafePropertyValue $decision "felResidualDiscarded" $false)
    if ($felDiscard -and -not [bool]$settings.felDiscardAuthorized) {
        Complete-WorkerJob $Job $RunningPath "REVIEW_REQUIRED" "TERMINAL_DV_FEL" "FEL_DISCARD_GATE_DISABLED" "fel_residual_discard_requires_separate_authorization" $prePath
        return
    }

    $chainId = [string](Get-ReacquisitionSafePropertyValue $r "chainId" "")
    $sourceSnapshot = Get-ReacquisitionSafePropertyValue $r "sourceSnapshot" $null
    $fingerprint = [string](Get-ReacquisitionSafePropertyValue $sourceSnapshot "streamFingerprint" "")
    if ([string]::IsNullOrWhiteSpace($chainId) -or [string]::IsNullOrWhiteSpace($fingerprint)) { throw "Terminal DV preflight omitted required confirmations." }

    if ($status -eq "DRY_RUN_READY_BUILD") {
        $settings = Get-CurrentWriteSettings
        if ($null -eq $settings -or -not [bool]$settings.terminalDvAuthorized -or ($felDiscard -and -not [bool]$settings.felDiscardAuthorized)) {
            Complete-WorkerJob $Job $RunningPath "BLOCKED" "TERMINAL_DV_BUILD" "AUTO_EXECUTE_GATE_CHANGED" "automatic_write_gate_changed_before_candidate_build" $prePath
            return
        }
        Set-JobProperty $Job "writeAttempted" $true; Save-Job $Job $RunningPath
        $buildPath = New-ResultPath $JobId "terminal-dv-build"
        $build = Invoke-JsonScript "Invoke-TerminalDvRemediation.ps1" @("-MovieId",$MovieId,"-BuildCandidate","-ConfirmChainId",$chainId,"-ConfirmSourceFingerprint",$fingerprint) $buildPath ($JobId+"-terminal-build")
        if ([string](Get-ReacquisitionSafePropertyValue $build.result "status" "") -ne "CANDIDATE_BUILT") {
            Complete-WorkerJob $Job $RunningPath "RECOVERY_REQUIRED" "TERMINAL_DV_BUILD" ([string](Get-ReacquisitionSafePropertyValue $build.result "status" "FAILED")) ([string](Get-ReacquisitionSafePropertyValue $build.result "reason" "candidate_build_failed")) $buildPath
            return
        }
        $prePath = New-ResultPath $JobId "terminal-dv-recheck"
        $pre = Invoke-JsonScript "Invoke-TerminalDvRemediation.ps1" @("-MovieId",$MovieId) $prePath ($JobId+"-terminal-recheck")
        $r = $pre.result
        if ([string](Get-ReacquisitionSafePropertyValue $r "status" "") -ne "DRY_RUN_READY_REPLACE") {
            Complete-WorkerJob $Job $RunningPath "RECOVERY_REQUIRED" "TERMINAL_DV_RECHECK" ([string](Get-ReacquisitionSafePropertyValue $r "status" "FAILED")) ([string](Get-ReacquisitionSafePropertyValue $r "reason" "candidate_recheck_failed")) $prePath
            return
        }
    }

    $settings = Get-CurrentWriteSettings
    if ($null -eq $settings -or -not [bool]$settings.terminalDvAuthorized -or ($felDiscard -and -not [bool]$settings.felDiscardAuthorized)) {
        Complete-WorkerJob $Job $RunningPath "BLOCKED" "TERMINAL_DV_REPLACE" "AUTO_EXECUTE_GATE_CHANGED" "automatic_write_gate_changed_before_terminal_replacement" $prePath
        return
    }
    Set-JobProperty $Job "writeAttempted" $true; Save-Job $Job $RunningPath
    $execPath = New-ResultPath $JobId "terminal-dv-execute"
    $exec = Invoke-JsonScript "Invoke-TerminalDvRemediation.ps1" @("-MovieId",$MovieId,"-Execute","-ConfirmChainId",$chainId,"-ConfirmSourceFingerprint",$fingerprint) $execPath ($JobId+"-terminal-exec")
    $es = [string](Get-ReacquisitionSafePropertyValue $exec.result "status" "FAILED")
    $terminalState = if ($es -eq "TERMINAL_DV_REMEDIATED") { "COMPLETED" } else { "RECOVERY_REQUIRED" }
    Complete-WorkerJob $Job $RunningPath $terminalState "TERMINAL_DV_EXECUTE" $es ([string](Get-ReacquisitionSafePropertyValue $exec.result "reason" $null)) $execPath
}


function Get-HigherOutcome {
    param([string]$First,[string]$Second)
    $rank=@{ PASS=0; NORMALIZE=1; REVIEW=2; REACQUIRE=3 }
    if (-not $rank.ContainsKey($First)) { $First="PASS" }
    if (-not $rank.ContainsKey($Second)) { return $First }
    if ($rank[$Second] -gt $rank[$First]) { return $Second }
    return $First
}

function New-PostNormalizationBridgeResult {
    param($Bridge,$Context,[string]$JobId)

    $contextPath=[string](Get-ReacquisitionSafePropertyValue $Bridge "contextFile" "")
    $file=Get-ReacquisitionSafePropertyValue $Context "file" $null
    $mediaPath=[string](Get-ReacquisitionSafePropertyValue $file "path" "")
    $libraryType=[string](Get-ReacquisitionSafePropertyValue $Context "libraryType" "Movie")
    if (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) { throw "Post-normalization media missing: $mediaPath" }

    $validatorPath=New-ResultPath $JobId "post-normalize-validator"
    $validator=Invoke-JsonScript "..\MediaValidator.ps1" @($mediaPath,"-LibraryType",$libraryType,"-OutputFormat","Json","-ExitZero") $validatorPath ($JobId+"-postnorm-validator")

    $contextualPath=New-ResultPath $JobId "post-normalize-contextual"
    $contextual=Invoke-JsonScript "ContextValidator.ps1" @("-ContextPath",$contextPath,"-ValidatorResultPath",$validatorPath,"-ExitZero") $contextualPath ($JobId+"-postnorm-contextual")

    $genericOutcome=[string](Get-ReacquisitionSafePropertyValue $validator.result "outcome" "REVIEW")
    $contextualOutcome="PASS"
    if ([string](Get-ReacquisitionSafePropertyValue $contextual.result "status" "") -eq "APPLIED") {
        $contextualOutcome=[string](Get-ReacquisitionSafePropertyValue $contextual.result "outcome" "PASS")
    }
    $effectiveOutcome=Get-HigherOutcome $genericOutcome $contextualOutcome

    $syntheticPath=New-ResultPath $JobId "post-normalize-bridge"
    $synthetic=[pscustomobject][ordered]@{
        schemaVersion="1.0"
        bridgeVersion="worker-post-normalization"
        eventId=([string](Get-ReacquisitionSafePropertyValue $Bridge "eventId" $JobId))+"-postnormalize"
        source=[string](Get-ReacquisitionSafePropertyValue $Bridge "source" "")
        status="VALIDATED"
        contextFile=$contextPath
        effectiveOutcome=$effectiveOutcome
        validator=[ordered]@{ resultFile=$validatorPath; outcome=$genericOutcome }
        contextual=[ordered]@{ resultFile=$contextualPath; status=[string](Get-ReacquisitionSafePropertyValue $contextual.result "status" ""); outcome=$contextualOutcome }
        generatedBy="ReacquisitionWorker"
        generatedUtc=[DateTime]::UtcNow.ToString("o")
    }
    $synthetic | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $syntheticPath -Encoding UTF8
    return [pscustomobject]@{ path=$syntheticPath; effectiveOutcome=$effectiveOutcome; validator=$validator.result; contextual=$contextual.result }
}

function Invoke-ActiveChainNormalization {
    param($Job,[string]$RunningPath,$Bridge,$Context,[string]$JobId)

    $planRecord=Get-ReacquisitionSafePropertyValue $Bridge "normalizationPlan" $null
    $planPath=[string](Get-ReacquisitionSafePropertyValue $planRecord "resultFile" "")
    if ([string]::IsNullOrWhiteSpace($planPath) -or -not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        Complete-WorkerJob $Job $RunningPath "REVIEW_REQUIRED" "NORMALIZATION" "PLAN_MISSING" "active_chain_normalization_plan_missing" $null
        return
    }

    $prePath=New-ResultPath $JobId "normalization-preflight"
    $pre=Invoke-JsonScript "Invoke-Normalization.ps1" @("-PlanPath",$planPath) $prePath ($JobId+"-norm-pre")
    $preStatus=[string](Get-ReacquisitionSafePropertyValue $pre.result "status" "FAILED")
    if ($preStatus -ne "DRY_RUN_READY") {
        Complete-WorkerJob $Job $RunningPath "REVIEW_REQUIRED" "NORMALIZATION_PREFLIGHT" $preStatus ([string](Get-ReacquisitionSafePropertyValue $pre.result "reason" "normalization_preflight_not_ready")) $prePath
        return
    }

    if ([string]$Job.queueMode -eq "AUTO_DRY_RUN") {
        Complete-WorkerJob $Job $RunningPath "COMPLETED" "NORMALIZATION_PREFLIGHT" $preStatus $null $prePath
        return
    }

    if ($null -eq (Get-CurrentWriteSettings)) {
        Complete-WorkerJob $Job $RunningPath "BLOCKED" "NORMALIZATION" "AUTO_EXECUTE_GATE_CHANGED" "automatic_write_gate_not_currently_authorized" $prePath
        return
    }

    Set-JobProperty $Job "writeAttempted" $true
    Save-Job $Job $RunningPath
    $execPath=New-ResultPath $JobId "normalization-execute"
    $exec=Invoke-JsonScript "Invoke-Normalization.ps1" @("-PlanPath",$planPath,"-Execute") $execPath ($JobId+"-norm-exec")
    $execStatus=[string](Get-ReacquisitionSafePropertyValue $exec.result "status" "FAILED")
    if ($execStatus -ne "SUCCESS") {
        Complete-WorkerJob $Job $RunningPath "RECOVERY_REQUIRED" "NORMALIZATION" $execStatus ([string](Get-ReacquisitionSafePropertyValue $exec.result "reason" "normalization_failed")) $execPath
        return
    }

    $fresh=New-PostNormalizationBridgeResult -Bridge $Bridge -Context $Context -JobId $JobId
    if ([string]$fresh.effectiveOutcome -ne "PASS") {
        Complete-WorkerJob $Job $RunningPath "REVIEW_REQUIRED" "NORMALIZATION_REVALIDATION" "NOT_PASS" ("post_normalization_outcome_"+[string]$fresh.effectiveOutcome) $fresh.path
        return
    }

    $successPrePath=New-ResultPath $JobId "success-after-normalization-preflight"
    $successPre=Invoke-JsonScript "Complete-ReacquisitionSuccess.ps1" @("-BridgeResultPath",$fresh.path) $successPrePath ($JobId+"-success-postnorm-pre")
    if ([string](Get-ReacquisitionSafePropertyValue $successPre.result "status" "") -ne "DRY_RUN_READY") {
        Complete-WorkerJob $Job $RunningPath "RECOVERY_REQUIRED" "SUCCESS_AFTER_NORMALIZATION" ([string](Get-ReacquisitionSafePropertyValue $successPre.result "status" "FAILED")) ([string](Get-ReacquisitionSafePropertyValue $successPre.result "reason" "success_preflight_failed")) $successPrePath
        return
    }

    $chainId=[string](Get-ReacquisitionSafePropertyValue $successPre.result "chainId" "")
    $replacement=Get-ReacquisitionSafePropertyValue $successPre.result "replacement" $null
    $fingerprint=[string](Get-ReacquisitionSafePropertyValue $replacement "currentFingerprint" "")
    if ([string]::IsNullOrWhiteSpace($chainId) -or [string]::IsNullOrWhiteSpace($fingerprint)) {
        Complete-WorkerJob $Job $RunningPath "RECOVERY_REQUIRED" "SUCCESS_AFTER_NORMALIZATION" "CONFIRMATION_MISSING" "success_preflight_missing_chain_or_fingerprint" $successPrePath
        return
    }

    $successExecPath=New-ResultPath $JobId "success-after-normalization-execute"
    $successExec=Invoke-JsonScript "Complete-ReacquisitionSuccess.ps1" @("-BridgeResultPath",$fresh.path,"-Execute","-ConfirmChainId",$chainId,"-ConfirmReplacementFingerprint",$fingerprint) $successExecPath ($JobId+"-success-postnorm-exec")
    $successStatus=[string](Get-ReacquisitionSafePropertyValue $successExec.result "status" "FAILED")
    $state=if ($successStatus -eq "REACQUISITION_COMPLETED_SUCCESS") { "COMPLETED" } else { "RECOVERY_REQUIRED" }
    Complete-WorkerJob $Job $RunningPath $state "SUCCESS_AFTER_NORMALIZATION" $successStatus ([string](Get-ReacquisitionSafePropertyValue $successExec.result "reason" $null)) $successExecPath
}

$mutex = New-Object System.Threading.Mutex($false,"ReqestraReacquisitionWorker")
$held=$false
try {
    $held=$mutex.WaitOne(0)
    if (-not $held) { exit 0 }
    
function New-DirectTerminalDvChainFromPlan {
    param(
        [Parameter(Mandatory = $true)][string]$PlanPath,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][int]$MovieId
    )

    $loop = Get-ReacquisitionSafePropertyValue $Plan "loopPrevention" $null
    $loopKey = [string](Get-ReacquisitionSafePropertyValue $loop "loopKey" "")
    $maxAttempts = [int](Get-ReacquisitionSafePropertyValue $loop "maxAutomaticAttempts" 3)
    if ($maxAttempts -le 0) { $maxAttempts = 3 }
    $snapshot = Get-ReacquisitionSafePropertyValue $Plan "sourceSnapshot" $null
    $release = Get-ReacquisitionSafePropertyValue $Plan "releaseIdentity" $null
    $mediaPath = [string](Get-ReacquisitionSafePropertyValue $Plan "mediaPath" "")
    if ([string]::IsNullOrWhiteSpace($loopKey) -or [string]::IsNullOrWhiteSpace($mediaPath)) {
        throw "Cannot synthesize terminal DV chain from an incomplete plan."
    }

    $chainPath = Get-ReacquisitionChainPath -IntegrationRoot $IntegrationRoot -Source "Radarr" -EntityId $MovieId
    $chainId = "radarr-{0}-no-candidate-{1}" -f $MovieId,$loopKey.Substring(0,[Math]::Min(12,$loopKey.Length))
    $now = [DateTime]::UtcNow.ToString("o")
    $attempts = @()
    for ($n=1; $n -le $maxAttempts; $n++) {
        $attempts += [pscustomobject][ordered]@{
            attemptNumber = $n
            loopKey = $loopKey
            releaseTitle = [string](Get-ReacquisitionSafePropertyValue $release "releaseTitle" "")
            releaseGroup = [string](Get-ReacquisitionSafePropertyValue $release "releaseGroup" "")
            disposition = "NO_VIABLE_REPLACEMENT_CANDIDATE"
            quarantinePath = $null
        }
    }

    $chain = [pscustomobject][ordered]@{
        schemaVersion = "1.0"
        chainVersion = "direct-terminal-dv-1.0"
        chainId = $chainId
        source = "Radarr"
        entityId = $MovieId
        status = "TERMINAL_REVIEW_REQUIRED"
        maxAttempts = $maxAttempts
        failedAttemptCount = $maxAttempts
        createdUtc = $now
        updatedUtc = $now
        rollback = [pscustomobject][ordered]@{
            originalLoopKey = $loopKey
            path = $mediaPath
            lengthBytes = [int64](Get-ReacquisitionSafePropertyValue $snapshot "lengthBytes" -1)
            streamFingerprint = [string](Get-ReacquisitionSafePropertyValue $snapshot "streamFingerprint" "")
            releaseTitle = [string](Get-ReacquisitionSafePropertyValue $release "releaseTitle" "")
            releaseGroup = [string](Get-ReacquisitionSafePropertyValue $release "releaseGroup" "")
            sourcePlanPath = [System.IO.Path]::GetFullPath($PlanPath)
            status = "RESTORED_TO_LIBRARY_TERMINAL"
            restoredUtc = $now
            verifiedUtc = $now
        }
        attempts = @($attempts)
        terminalReason = "no_viable_replacement_after_candidate_searches"
    }

    $dir = Split-Path -Parent $chainPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $chainPath + ".tmp-" + [guid]::NewGuid().ToString("N")
    $chain | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $chainPath -Force
    return [pscustomobject]@{ chainPath=$chainPath; chainId=$chainId }
}

$processed=0
    while ($MaxJobs -eq 0 -or $processed -lt $MaxJobs) {
        $pending = @(Get-ChildItem -LiteralPath $paths.pending -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc | Select-Object -First 1)
        if ($pending.Count -eq 0) { break }
        $pendingPath=$pending[0].FullName
        $job=Get-Content -LiteralPath $pendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $jobId=[string]$job.jobId
        $runningPath=Join-Path $paths.running ($jobId+".json")
        Move-Item -LiteralPath $pendingPath -Destination $runningPath -Force
        Set-JobProperty $job "state" "RUNNING"; Set-JobProperty $job "workerVersion" $WorkerVersion; Save-Job $job $runningPath
        $processed++
        try {
            $bridgePath=[string]$job.bridgeResultPath
            if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) { throw "Bridge result missing: $bridgePath" }
            $bridge=Get-Content -LiteralPath $bridgePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $contextPath=[string](Get-ReacquisitionSafePropertyValue $bridge "contextFile" "")
            if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) { throw "Context missing: $contextPath" }
            $context=Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $source=[string](Get-ReacquisitionSafePropertyValue $bridge "source" "")
            $outcome=[string](Get-ReacquisitionSafePropertyValue $bridge "effectiveOutcome" "")
            $entity=Get-ReacquisitionSafePropertyValue $context "entity" $null
            $entityId=[int](Get-ReacquisitionSafePropertyValue $entity "id" 0)
            $chainInfo=Get-ChainForContext $context

            if ($null -eq $chainInfo) {
                if ($outcome -ne "REACQUIRE") {
                    Complete-WorkerJob $job $runningPath "SKIPPED" "NO_ACTIVE_CHAIN" "NOT_APPLICABLE" "no_active_reacquisition_chain" $null; continue
                }
                $planRecord=Get-ReacquisitionSafePropertyValue $bridge "reacquisitionPlan" $null
                $planPath=[string](Get-ReacquisitionSafePropertyValue $planRecord "resultFile" "")
                if ([string]::IsNullOrWhiteSpace($planPath) -or -not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
                    Complete-WorkerJob $job $runningPath "BLOCKED" "FIRST_FAILURE" "PLAN_MISSING" "reacquisition_plan_missing" $null; continue
                }
                $plan=Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $loop=[string](Get-ReacquisitionSafePropertyValue (Get-ReacquisitionSafePropertyValue $plan "loopPrevention" $null) "loopKey" "")
                $releaseIdentity=Get-ReacquisitionSafePropertyValue $plan "releaseIdentity" $null
                $initialBlocklistMode=[string](Get-ReacquisitionSafePropertyValue $releaseIdentity "initialBlocklistMode" "EXACT_RELEASE")

                if ($initialBlocklistMode -ne "SKIP_UNAVAILABLE_LEGACY_IDENTITY") {
                    $prePath=New-ResultPath $jobId "markfailed-preflight"
                    $pre=Invoke-JsonScript "Invoke-Reacquisition.ps1" @("-PlanPath",$planPath,"-SuppressNativeRedownload") $prePath ($jobId+"-markfailed-pre")
                    $preStatus=[string](Get-ReacquisitionSafePropertyValue $pre.result "status" "FAILED")
                    $preReason=[string](Get-ReacquisitionSafePropertyValue $pre.result "reason" "")
                    $alreadyBlocked=($preStatus -eq "BLOCKED" -and $preReason -eq "current_release_already_blocklisted")
                    if ($preStatus -ne "DRY_RUN_READY" -and -not $alreadyBlocked) {
                        Complete-WorkerJob $job $runningPath "BLOCKED" "MARK_FAILED_PREFLIGHT" $preStatus $preReason $prePath; continue
                    }
                    if ([string]$job.queueMode -eq "AUTO_DRY_RUN") {
                        $dryStatus=if ($alreadyBlocked) { "ALREADY_BLOCKLISTED" } else { $preStatus }
                        Complete-WorkerJob $job $runningPath "COMPLETED" "MARK_FAILED_PREFLIGHT" $dryStatus $null $prePath; continue
                    }
                    if (-not $alreadyBlocked) {
                        if ($null -eq (Get-CurrentWriteSettings)) {
                            Complete-WorkerJob $job $runningPath "BLOCKED" "MARK_FAILED" "AUTO_EXECUTE_GATE_CHANGED" "automatic_write_gate_not_currently_authorized" $prePath; continue
                        }
                        Set-JobProperty $job "writeAttempted" $true; Save-Job $job $runningPath
                        $execPath=New-ResultPath $jobId "markfailed-execute"
                        $exec=Invoke-JsonScript "Invoke-Reacquisition.ps1" @("-PlanPath",$planPath,"-Execute","-ConfirmLoopKey",$loop,"-SuppressNativeRedownload") $execPath ($jobId+"-markfailed-exec")
                        $markStatus=[string](Get-ReacquisitionSafePropertyValue $exec.result "status" "FAILED")
                        if ($markStatus -ne "SUCCESS_SEARCH_SUPPRESSED") {
                            Complete-WorkerJob $job $runningPath "RECOVERY_REQUIRED" "MARK_FAILED" $markStatus ([string](Get-ReacquisitionSafePropertyValue $exec.result "reason" "automatic_markfailed_did_not_suppress_search")) $execPath; continue
                        }
                    }
                }

                $qScript=if ($source -eq "Radarr") { "Invoke-ReacquisitionQuarantine.ps1" } else { "Invoke-SonarrReacquisitionQuarantine.ps1" }
                $qPre=$null; $qPrePath=$null
                for ($candidateCheck=1; $candidateCheck -le 3; $candidateCheck++) {
                    $qPrePath=New-ResultPath $jobId ("quarantine-preflight-"+$candidateCheck)
                    $qPre=Invoke-JsonScript $qScript @("-PlanPath",$planPath) $qPrePath ($jobId+"-q-pre-"+$candidateCheck)
                    $qStatus=[string](Get-ReacquisitionSafePropertyValue $qPre.result "status" "")
                    $qReason=[string](Get-ReacquisitionSafePropertyValue $qPre.result "reason" "")
                    if ($qStatus -eq "DRY_RUN_READY" -or $qReason -ne "no_candidates_blocked_only_by_current_disk_file") { break }
                    if ($candidateCheck -lt 3) { Start-Sleep -Seconds (2*$candidateCheck) }
                }
                $qStatus=[string](Get-ReacquisitionSafePropertyValue $qPre.result "status" "")
                $qReason=[string](Get-ReacquisitionSafePropertyValue $qPre.result "reason" "")
                if ($qStatus -ne "DRY_RUN_READY") {
                    if ($source -eq "Radarr" -and $qReason -eq "no_candidates_blocked_only_by_current_disk_file") {
                        $findings=@(Get-ReacquisitionSafePropertyValue $plan "triggerFindingCodes" @())
                        if ($findings -contains "video.dolby_vision") {
                            try { [void](New-DirectTerminalDvChainFromPlan -PlanPath $planPath -Plan $plan -MovieId $entityId) }
                            catch { Complete-WorkerJob $job $runningPath "REVIEW_REQUIRED" "NO_VIABLE_REPLACEMENT" "CURRENT_FILE_PRESERVED" ("terminal_chain_synthesis_failed: "+$_.Exception.Message) $qPrePath; continue }
                            Invoke-TerminalDvAutomation $job $runningPath $entityId $jobId; continue
                        }
                        Complete-WorkerJob $job $runningPath "REVIEW_REQUIRED" "NO_VIABLE_REPLACEMENT" "CURRENT_FILE_PRESERVED" "no_viable_replacement_current_file_preserved" $qPrePath; continue
                    }
                    Complete-WorkerJob $job $runningPath "RECOVERY_REQUIRED" "QUARANTINE_PREFLIGHT" $qStatus $qReason $qPrePath; continue
                }
                if ($null -eq (Get-CurrentWriteSettings)) {
                    Complete-WorkerJob $job $runningPath "BLOCKED" "QUARANTINE" "AUTO_EXECUTE_GATE_CHANGED" "automatic_write_gate_changed_before_quarantine" $qPrePath; continue
                }
                $qExecPath=New-ResultPath $jobId "quarantine-execute"
                $qExec=Invoke-JsonScript $qScript @("-PlanPath",$planPath,"-Execute","-ConfirmLoopKey",$loop) $qExecPath ($jobId+"-q-exec")
                if ([string](Get-ReacquisitionSafePropertyValue $qExec.result "status" "") -ne "QUARANTINED_REPLACEMENT_STARTED") {
                    Complete-WorkerJob $job $runningPath "RECOVERY_REQUIRED" "QUARANTINE" ([string](Get-ReacquisitionSafePropertyValue $qExec.result "status" "FAILED")) ([string](Get-ReacquisitionSafePropertyValue $qExec.result "reason" "quarantine_failed")) $qExecPath; continue
                }
                if ($source -eq "Radarr") {
                    $iPrePath=New-ResultPath $jobId "chain-init-preflight"
                    $iPre=Invoke-JsonScript "Initialize-ReacquisitionChain.ps1" @("-OriginalPlanPath",$planPath) $iPrePath ($jobId+"-init-pre")
                    if ([string](Get-ReacquisitionSafePropertyValue $iPre.result "status" "") -ne "DRY_RUN_READY") {
                        Complete-WorkerJob $job $runningPath "RECOVERY_REQUIRED" "CHAIN_INITIALIZE" ([string](Get-ReacquisitionSafePropertyValue $iPre.result "status" "FAILED")) ([string](Get-ReacquisitionSafePropertyValue $iPre.result "reason" "chain_init_preflight_failed")) $iPrePath; continue
                    }
                    $cid=[string](Get-ReacquisitionSafePropertyValue $iPre.result "chainId" "")
                    if ($null -eq (Get-CurrentWriteSettings)) { Complete-WorkerJob $job $runningPath "BLOCKED" "CHAIN_INITIALIZE" "AUTO_EXECUTE_GATE_CHANGED" "automatic_write_gate_changed_before_chain_initialization" $iPrePath; continue }
                    $iExecPath=New-ResultPath $jobId "chain-init-execute"
                    $iExec=Invoke-JsonScript "Initialize-ReacquisitionChain.ps1" @("-OriginalPlanPath",$planPath,"-Execute","-ConfirmChainId",$cid) $iExecPath ($jobId+"-init-exec")
                    if ([string](Get-ReacquisitionSafePropertyValue $iExec.result "status" "") -ne "CHAIN_INITIALIZED") {
                        Complete-WorkerJob $job $runningPath "RECOVERY_REQUIRED" "CHAIN_INITIALIZE" ([string](Get-ReacquisitionSafePropertyValue $iExec.result "status" "FAILED")) ([string](Get-ReacquisitionSafePropertyValue $iExec.result "reason" "chain_init_failed")) $iExecPath; continue
                    }
                }
                Complete-WorkerJob $job $runningPath "WAITING" "REPLACEMENT_SEARCH_STARTED" "WAITING_FOR_REPLACEMENT_IMPORT" $null $qExecPath; continue
            }

            $chain=$chainInfo.chain; $chainStatus=[string](Get-ReacquisitionSafePropertyValue $chain "status" "")
            if ($chainStatus -eq "ACTIVE") {
                if ($outcome -eq "PASS") {
                    $script=if ($source -eq "Radarr") { "Complete-ReacquisitionSuccess.ps1" } else { "Complete-SonarrReacquisitionSuccess.ps1" }
                    $prePath=New-ResultPath $jobId "success-preflight"
                    $pre=Invoke-JsonScript $script @("-BridgeResultPath",$bridgePath) $prePath ($jobId+"-success-pre")
                    $s=[string](Get-ReacquisitionSafePropertyValue $pre.result "status" "FAILED")
                    if ($s -ne "DRY_RUN_READY") { Complete-WorkerJob $job $runningPath "BLOCKED" "SUCCESS_PREFLIGHT" $s ([string](Get-ReacquisitionSafePropertyValue $pre.result "reason" "success_not_ready")) $prePath; continue }
                    if ([string]$job.queueMode -eq "AUTO_DRY_RUN") { Complete-WorkerJob $job $runningPath "COMPLETED" "SUCCESS_PREFLIGHT" $s $null $prePath; continue }
                    if ($null -eq (Get-CurrentWriteSettings)) { Complete-WorkerJob $job $runningPath "BLOCKED" "SUCCESS_FINALIZE" "AUTO_EXECUTE_GATE_CHANGED" "automatic_write_gate_not_currently_authorized" $prePath; continue }
                    $cid=[string](Get-ReacquisitionSafePropertyValue $pre.result "chainId" "")
                    $replacement=Get-ReacquisitionSafePropertyValue $pre.result "replacement" $null
                    $fp=[string](Get-ReacquisitionSafePropertyValue $replacement "currentFingerprint" "")
                    Set-JobProperty $job "writeAttempted" $true; Save-Job $job $runningPath
                    $execPath=New-ResultPath $jobId "success-execute"
                    $exec=Invoke-JsonScript $script @("-BridgeResultPath",$bridgePath,"-Execute","-ConfirmChainId",$cid,"-ConfirmReplacementFingerprint",$fp) $execPath ($jobId+"-success-exec")
                    $es=[string](Get-ReacquisitionSafePropertyValue $exec.result "status" "FAILED")
                    $successState = if ($es -eq "REACQUISITION_COMPLETED_SUCCESS") { "COMPLETED" } else { "RECOVERY_REQUIRED" }
                    Complete-WorkerJob $job $runningPath $successState "SUCCESS_FINALIZE" $es ([string](Get-ReacquisitionSafePropertyValue $exec.result "reason" $null)) $execPath; continue
                }
                elseif ($outcome -eq "REACQUIRE") {
                    $planRecord=Get-ReacquisitionSafePropertyValue $bridge "reacquisitionPlan" $null
                    $planPath=[string](Get-ReacquisitionSafePropertyValue $planRecord "resultFile" "")
                    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { Complete-WorkerJob $job $runningPath "BLOCKED" "RETRY" "PLAN_MISSING" "retry_reacquisition_plan_missing" $null; continue }
                    $plan=Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $loop=[string](Get-ReacquisitionSafePropertyValue (Get-ReacquisitionSafePropertyValue $plan "loopPrevention" $null) "loopKey" "")
                    $releaseIdentity=Get-ReacquisitionSafePropertyValue $plan "releaseIdentity" $null
                    $retryBlocklistMode=[string](Get-ReacquisitionSafePropertyValue $releaseIdentity "initialBlocklistMode" "EXACT_RELEASE")
                    if ($retryBlocklistMode -eq "SKIP_UNAVAILABLE_LEGACY_IDENTITY") {
                        Complete-WorkerJob $job $runningPath "REVIEW_REQUIRED" "RETRY_MARK_FAILED_PREFLIGHT" "BLOCKED" "replacement_release_identity_unavailable" $planPath; continue
                    }

                    # A replacement that still validates REACQUIRE must itself be MarkFailed/blocklisted
                    # before the retry executor is allowed to remove it. This creates the per-loop
                    # Reacquisition\state proof consumed by Invoke-*ReacquisitionRetry.ps1.
                    $markPrePath=New-ResultPath $jobId "retry-markfailed-preflight"
                    $markPre=Invoke-JsonScript "Invoke-Reacquisition.ps1" @("-PlanPath",$planPath,"-SuppressNativeRedownload") $markPrePath ($jobId+"-retry-markfailed-pre")
                    $markPreStatus=[string](Get-ReacquisitionSafePropertyValue $markPre.result "status" "FAILED")
                    $markPreReason=[string](Get-ReacquisitionSafePropertyValue $markPre.result "reason" "")
                    $markAlreadyBlocked=($markPreStatus -eq "BLOCKED" -and $markPreReason -eq "current_release_already_blocklisted")
                    if ($markPreStatus -ne "DRY_RUN_READY" -and -not $markAlreadyBlocked) {
                        Complete-WorkerJob $job $runningPath "BLOCKED" "RETRY_MARK_FAILED_PREFLIGHT" $markPreStatus $markPreReason $markPrePath; continue
                    }
                    if ([string]$job.queueMode -eq "AUTO_DRY_RUN") {
                        $dryStatus=if ($markAlreadyBlocked) { "ALREADY_BLOCKLISTED" } else { $markPreStatus }
                        Complete-WorkerJob $job $runningPath "COMPLETED" "RETRY_MARK_FAILED_PREFLIGHT" $dryStatus $null $markPrePath; continue
                    }
                    if (-not $markAlreadyBlocked) {
                        if ($null -eq (Get-CurrentWriteSettings)) {
                            Complete-WorkerJob $job $runningPath "BLOCKED" "RETRY_MARK_FAILED" "AUTO_EXECUTE_GATE_CHANGED" "automatic_write_gate_not_currently_authorized" $markPrePath; continue
                        }
                        Set-JobProperty $job "writeAttempted" $true; Save-Job $job $runningPath
                        $markExecPath=New-ResultPath $jobId "retry-markfailed-execute"
                        $markExec=Invoke-JsonScript "Invoke-Reacquisition.ps1" @("-PlanPath",$planPath,"-Execute","-ConfirmLoopKey",$loop,"-SuppressNativeRedownload") $markExecPath ($jobId+"-retry-markfailed-exec")
                        $markExecStatus=[string](Get-ReacquisitionSafePropertyValue $markExec.result "status" "FAILED")
                        if ($markExecStatus -ne "SUCCESS_SEARCH_SUPPRESSED") {
                            Complete-WorkerJob $job $runningPath "RECOVERY_REQUIRED" "RETRY_MARK_FAILED" $markExecStatus ([string](Get-ReacquisitionSafePropertyValue $markExec.result "reason" "replacement_markfailed_did_not_suppress_search")) $markExecPath; continue
                        }
                    }

                    $retryScript=if ($source -eq "Radarr") { "Invoke-ReacquisitionRetry.ps1" } else { "Invoke-SonarrReacquisitionRetry.ps1" }
                    $prePath=New-ResultPath $jobId "retry-preflight"
                    $pre=Invoke-JsonScript $retryScript @("-PlanPath",$planPath) $prePath ($jobId+"-retry-pre")
                    $s=[string](Get-ReacquisitionSafePropertyValue $pre.result "status" "FAILED")
                    if ($s -ne "DRY_RUN_READY") { Complete-WorkerJob $job $runningPath "BLOCKED" "RETRY_PREFLIGHT" $s ([string](Get-ReacquisitionSafePropertyValue $pre.result "reason" "retry_not_ready")) $prePath; continue }
                    if ($null -eq (Get-CurrentWriteSettings)) { Complete-WorkerJob $job $runningPath "BLOCKED" "RETRY" "AUTO_EXECUTE_GATE_CHANGED" "automatic_write_gate_not_currently_authorized" $prePath; continue }
                    $cid=[string](Get-ReacquisitionSafePropertyValue $pre.result "chainId" "")
                    Set-JobProperty $job "writeAttempted" $true; Save-Job $job $runningPath
                    $execPath=New-ResultPath $jobId "retry-execute"
                    $exec=Invoke-JsonScript $retryScript @("-PlanPath",$planPath,"-Execute","-ConfirmChainId",$cid,"-ConfirmLoopKey",$loop) $execPath ($jobId+"-retry-exec")
                    $es=[string](Get-ReacquisitionSafePropertyValue $exec.result "status" "FAILED")
                    if ($es -eq "RETRY_DELETED_REPLACEMENT_STARTED") { Complete-WorkerJob $job $runningPath "WAITING" "RETRY" $es $null $execPath; continue }
                    if ($es -eq "TERMINAL_REVIEW_REQUIRED" -and $source -eq "Radarr") { Invoke-TerminalDvAutomation $job $runningPath $entityId $jobId; continue }
                    $retryState = if ($es -eq "TERMINAL_REVIEW_REQUIRED") { "REVIEW_REQUIRED" } else { "RECOVERY_REQUIRED" }
                    Complete-WorkerJob $job $runningPath $retryState "RETRY" $es ([string](Get-ReacquisitionSafePropertyValue $exec.result "reason" $null)) $execPath; continue
                }
                elseif ($outcome -eq "NORMALIZE") { Invoke-ActiveChainNormalization $job $runningPath $bridge $context $jobId; continue }
                else { Complete-WorkerJob $job $runningPath "REVIEW_REQUIRED" "ACTIVE_CHAIN" "REVIEW_REQUIRED" "active_chain_replacement_not_pass_or_reacquire" $null; continue }
            }
            elseif ($chainStatus -eq "TERMINAL_REVIEW_REQUIRED" -and $source -eq "Radarr") { Invoke-TerminalDvAutomation $job $runningPath $entityId $jobId; continue }
            elseif ($chainStatus -in @("COMPLETED_SUCCESS","COMPLETED_LOCAL_REMEDIATION")) { Complete-WorkerJob $job $runningPath "SKIPPED" "CHAIN_COMPLETE" $chainStatus $null $chainInfo.path; continue }
            elseif ($chainStatus -eq "RECOVERY_REQUIRED") { Complete-WorkerJob $job $runningPath "RECOVERY_REQUIRED" "CHAIN_RECOVERY" $chainStatus "existing_chain_requires_recovery" $chainInfo.path; continue }
            else { Complete-WorkerJob $job $runningPath "REVIEW_REQUIRED" "CHAIN_STATE" $chainStatus "chain_state_not_automatically_actionable" $chainInfo.path; continue }
        }
        catch {
            try {
                $failureState = if ([bool](Get-ReacquisitionSafePropertyValue $job "writeAttempted" $false)) { "RECOVERY_REQUIRED" } else { "FAILED" }
                Set-JobProperty $job "state" $failureState
                Set-JobProperty $job "reason" "worker_exception"; Set-JobProperty $job "error" $_.Exception.Message; Set-JobProperty $job "workerVersion" $WorkerVersion
                Set-JobProperty $job "completedUtc" ([DateTime]::UtcNow.ToString("o")); [void](Move-JobHistory $job $runningPath)
            } catch { Write-WorkerLog ("Failed to persist worker error: "+$_.Exception.Message) }
        }
    }
    Write-WorkerLog ("Worker completed. Processed $processed job(s).")
}
catch { Write-WorkerLog ("Worker fatal error: "+$_.Exception.Message) }
finally { if ($held) { try { $mutex.ReleaseMutex() } catch {} }; $mutex.Dispose() }
exit 0
