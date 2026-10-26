[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OriginalPlanPath,

    [string]$JsonOut = "",

    [switch]$Execute,

    [string]$ConfirmChainId = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "0.1.1"
$IntegrationRoot = $PSScriptRoot
$CommonPath = Join-Path $IntegrationRoot "ReacquisitionChainCommon.ps1"
$ValidatorPath = Join-Path (Split-Path -Parent $IntegrationRoot) "MediaValidator.ps1"
$PolicyPath = Join-Path (Split-Path -Parent $IntegrationRoot) "validator-policy.json"
$QuarantineStateRoot = Join-Path $IntegrationRoot "Reacquisition\quarantine-state"
$LogsRoot = Join-Path $IntegrationRoot "logs\events"
$WorkRoot = Join-Path $IntegrationRoot "Reacquisition\chain-work"

. $CommonPath

function Write-Result {
    param($Object)
    if (-not [string]::IsNullOrWhiteSpace($JsonOut)) {
        $Object | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    }
    $Object | ConvertTo-Json -Depth 60
}

$result = [ordered]@{
    schemaVersion = "1.0"
    scriptVersion = $ScriptVersion
    timestampUtc = [DateTime]::UtcNow.ToString("o")
    mode = if ($Execute) { "EXECUTE" } else { "DRY_RUN" }
    status = "BLOCKED"
    reason = $null
    chainId = $null
    chainPath = $null
    source = $null
    movieId = $null
    originalLoopKey = $null
    rollback = $null
    failedAttemptCount = 0
    maxAttempts = 0
    redundantQuarantines = @()
    mutation = [ordered]@{
        chainStateWritten = $false
        redundantFilesDeleted = 0
        redundantStateFilesUpdated = 0
    }
}

try {
    if (-not (Test-Path -LiteralPath $OriginalPlanPath -PathType Leaf)) {
        $result.reason = "original_plan_missing"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if (-not (Test-Path -LiteralPath $ValidatorPath -PathType Leaf)) {
        $result.reason = "validator_missing"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
        $result.reason = "validator_policy_missing"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $originalPlan = Get-Content -LiteralPath $OriginalPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $source = [string](Get-PropertyValue -Object $originalPlan -Name "source" -Default "")
    $entity = Get-PropertyValue -Object $originalPlan -Name "entity"
    $loopPrevention = Get-PropertyValue -Object $originalPlan -Name "loopPrevention"
    $sourceSnapshot = Get-PropertyValue -Object $originalPlan -Name "sourceSnapshot"
    $releaseIdentity = Get-PropertyValue -Object $originalPlan -Name "releaseIdentity"

    $movieId = [int](Get-PropertyValue -Object $entity -Name "id" -Default 0)
    $originalLoopKey = [string](Get-PropertyValue -Object $loopPrevention -Name "loopKey" -Default "")
    $maxAttempts = [int](Get-PropertyValue -Object $loopPrevention -Name "maxAutomaticAttempts" -Default 3)

    $result.source = $source
    $result.movieId = $movieId
    $result.originalLoopKey = $originalLoopKey
    $result.maxAttempts = $maxAttempts

    if ($source -ne "Radarr" -or $movieId -le 0 -or [string]::IsNullOrWhiteSpace($originalLoopKey)) {
        $result.reason = "original_plan_identity_invalid"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $chainId = "radarr-{0}-{1}" -f $movieId, $originalLoopKey.Substring(0, [Math]::Min(12, $originalLoopKey.Length))
    $chainPath = Get-ReacquisitionChainPath -IntegrationRoot $IntegrationRoot -Source "Radarr" -EntityId $movieId
    $result.chainId = $chainId
    $result.chainPath = $chainPath

    $originalStatePath = Join-Path $QuarantineStateRoot ($originalLoopKey + ".json")
    if (-not (Test-Path -LiteralPath $originalStatePath -PathType Leaf)) {
        $result.reason = "original_quarantine_state_missing"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $originalState = Get-Content -LiteralPath $originalStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $originalQuarantinePath = [string](Get-PropertyValue -Object $originalState -Name "quarantinePath" -Default "")
    $expectedBytes = [int64](Get-PropertyValue -Object $sourceSnapshot -Name "lengthBytes" -Default -1)
    $expectedFingerprint = [string](Get-PropertyValue -Object $sourceSnapshot -Name "streamFingerprint" -Default "")

    $rollbackDescriptor = [pscustomobject][ordered]@{
        originalLoopKey = $originalLoopKey
        path = $originalQuarantinePath
        lengthBytes = $expectedBytes
        streamFingerprint = $expectedFingerprint
        releaseTitle = [string](Get-PropertyValue -Object $releaseIdentity -Name "releaseTitle" -Default "")
        releaseGroup = [string](Get-PropertyValue -Object $releaseIdentity -Name "releaseGroup" -Default "")
        sourcePlanPath = [System.IO.Path]::GetFullPath($OriginalPlanPath)
        sourceQuarantineStatePath = $originalStatePath
    }

    $rollbackCheck = Test-ReacquisitionRollback `
        -Rollback $rollbackDescriptor `
        -ValidatorPath $ValidatorPath `
        -PolicyPath $PolicyPath `
        -WorkRoot $WorkRoot

    $result.rollback = [ordered]@{
        path = $rollbackDescriptor.path
        exists = $rollbackCheck.exists
        expectedBytes = $rollbackCheck.expectedBytes
        actualBytes = $rollbackCheck.actualBytes
        sizeMatches = $rollbackCheck.sizeMatches
        expectedFingerprint = $rollbackCheck.expectedFingerprint
        actualFingerprint = $rollbackCheck.actualFingerprint
        fingerprintMatches = $rollbackCheck.fingerprintMatches
        verified = $rollbackCheck.verified
    }

    if (-not $rollbackCheck.verified) {
        $result.reason = "original_rollback_not_verified"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $quarantineStates = @()
    if (Test-Path -LiteralPath $QuarantineStateRoot) {
        foreach ($file in @(Get-ChildItem -LiteralPath $QuarantineStateRoot -File -Filter "*.json" -ErrorAction SilentlyContinue)) {
            try {
                $state = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([int](Get-PropertyValue -Object $state -Name "movieId" -Default 0) -ne $movieId) { continue }
                $loopKey = [string](Get-PropertyValue -Object $state -Name "loopKey" -Default "")
                if ([string]::Equals($loopKey, $originalLoopKey, [System.StringComparison]::Ordinal)) { continue }

                $path = [string](Get-PropertyValue -Object $state -Name "quarantinePath" -Default "")
                $bytes = [int64](Get-PropertyValue -Object $state -Name "expectedBytes" -Default -1)
                $exists = (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf))
                $sizeMatches = $false
                $actualBytes = $null
                if ($exists) {
                    $item = Get-Item -LiteralPath $path
                    $actualBytes = [int64]$item.Length
                    $sizeMatches = ($actualBytes -eq $bytes)
                }

                $planMatches = @(Get-PlanForLoopKey -LogsRoot $LogsRoot -LoopKey $loopKey)
                $retryPlan = if ($planMatches.Count -gt 0) { $planMatches[0].plan } else { $null }
                $retryRelease = if ($null -ne $retryPlan) { Get-PropertyValue -Object $retryPlan -Name "releaseIdentity" } else { $null }

                $quarantineStates += [pscustomobject][ordered]@{
                    loopKey = $loopKey
                    statePath = $file.FullName
                    status = [string](Get-PropertyValue -Object $state -Name "status" -Default "")
                    startedUtc = [string](Get-PropertyValue -Object $state -Name "startedUtc" -Default "")
                    quarantinePath = $path
                    expectedBytes = $bytes
                    actualBytes = $actualBytes
                    exists = $exists
                    sizeMatches = $sizeMatches
                    releaseTitle = [string](Get-PropertyValue -Object $retryRelease -Name "releaseTitle" -Default "")
                    releaseGroup = [string](Get-PropertyValue -Object $retryRelease -Name "releaseGroup" -Default "")
                    planPath = if ($planMatches.Count -gt 0) { $planMatches[0].path } else { $null }
                }
            }
            catch {}
        }
    }

    $redundant = @(
        $quarantineStates |
            Where-Object {
                $_.exists -and
                $_.sizeMatches -and
                $_.status -eq "QUARANTINED_REPLACEMENT_STARTED"
            } |
            Sort-Object {
                try { [DateTime]::Parse([string]$_.startedUtc) }
                catch { [DateTime]::MaxValue }
            }
    )

    $result.redundantQuarantines = @($redundant)

    $attempts = @(
        [pscustomobject][ordered]@{
            attemptNumber = 1
            loopKey = $originalLoopKey
            releaseTitle = $rollbackDescriptor.releaseTitle
            releaseGroup = $rollbackDescriptor.releaseGroup
            disposition = "ROLLBACK_PRESERVED"
            quarantinePath = $rollbackDescriptor.path
        }
    )

    $nextAttempt = 2
    foreach ($retry in $redundant) {
        $attempts += [pscustomobject][ordered]@{
            attemptNumber = $nextAttempt
            loopKey = $retry.loopKey
            releaseTitle = $retry.releaseTitle
            releaseGroup = $retry.releaseGroup
            disposition = "REDUNDANT_QUARANTINE"
            quarantinePath = $retry.quarantinePath
        }
        $nextAttempt++
    }

    $result.failedAttemptCount = $attempts.Count

    $chainState = [pscustomobject][ordered]@{
        schemaVersion = "1.0"
        chainVersion = $ScriptVersion
        chainId = $chainId
        source = "Radarr"
        entityId = $movieId
        status = "INITIALIZING"
        maxAttempts = $maxAttempts
        failedAttemptCount = $attempts.Count
        createdUtc = [DateTime]::UtcNow.ToString("o")
        updatedUtc = [DateTime]::UtcNow.ToString("o")
        rollback = [pscustomobject][ordered]@{
            originalLoopKey = $originalLoopKey
            path = $rollbackDescriptor.path
            lengthBytes = $rollbackDescriptor.lengthBytes
            streamFingerprint = $rollbackDescriptor.streamFingerprint
            releaseTitle = $rollbackDescriptor.releaseTitle
            releaseGroup = $rollbackDescriptor.releaseGroup
            sourcePlanPath = $rollbackDescriptor.sourcePlanPath
            verifiedUtc = [DateTime]::UtcNow.ToString("o")
        }
        attempts = @($attempts)
    }

    if (-not $Execute) {
        $result.status = "DRY_RUN_READY"
        $result.reason = $null
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($ConfirmChainId) -or
        -not [string]::Equals($ConfirmChainId, $chainId, [System.StringComparison]::Ordinal)) {
        $result.reason = "execute_chain_id_confirmation_required"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if (Test-Path -LiteralPath $chainPath -PathType Leaf) {
        $existing = Get-Content -LiteralPath $chainPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $existingId = [string](Get-PropertyValue -Object $existing -Name "chainId" -Default "")
        if (-not [string]::Equals($existingId, $chainId, [System.StringComparison]::Ordinal)) {
            $result.reason = "different_chain_already_exists_for_movie"
            Write-Result ([pscustomobject]$result)
            exit 0
        }
    }

    Write-AtomicJson -Path $chainPath -Object $chainState
    $result.mutation.chainStateWritten = $true

    foreach ($retry in $redundant) {
        if (-not (Test-Path -LiteralPath $retry.quarantinePath -PathType Leaf)) { continue }
        if (-not $retry.sizeMatches) {
            throw "Redundant quarantine size changed before cleanup: $($retry.quarantinePath)"
        }
        if (Test-PathEquivalent -First $retry.quarantinePath -Second $rollbackDescriptor.path) {
            throw "Refusing to delete canonical rollback copy."
        }

        Remove-Item -LiteralPath $retry.quarantinePath -Force
        $result.mutation.redundantFilesDeleted++

        try {
            $parent = Split-Path -Parent $retry.quarantinePath
            if ((Test-Path -LiteralPath $parent) -and
                @((Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)).Count -eq 0) {
                Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}

        if (Test-Path -LiteralPath $retry.statePath -PathType Leaf) {
            $retryState = Get-Content -LiteralPath $retry.statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $retryState.status = "REDUNDANT_REMOVED_BY_CHAIN_INIT"
            $retryState.stage = "CHAIN_ROLLBACK_DEDUPLICATED"
            $retryState.updatedUtc = [DateTime]::UtcNow.ToString("o")
            $retryState.completedUtc = [DateTime]::UtcNow.ToString("o")
            Write-AtomicJson -Path $retry.statePath -Object $retryState
            $result.mutation.redundantStateFilesUpdated++
        }
    }

    foreach ($attempt in @($chainState.attempts)) {
        if ([string](Get-PropertyValue -Object $attempt -Name "disposition" -Default "") -eq "REDUNDANT_QUARANTINE") {
            $attempt.disposition = "FAILED_RETRY_DISCARDED"
            $attempt.quarantinePath = $null
        }
    }

    $chainState.status = "ACTIVE"
    $chainState.updatedUtc = [DateTime]::UtcNow.ToString("o")
    Write-AtomicJson -Path $chainPath -Object $chainState

    $result.status = "CHAIN_INITIALIZED"
    $result.reason = $null
    Write-Result ([pscustomobject]$result)
    exit 0
}
catch {
    $result.status = "FAILED"
    $result.reason = "chain_initializer_exception"
    $result.error = $_.Exception.Message
    Write-Result ([pscustomobject]$result)
    exit 0
}
