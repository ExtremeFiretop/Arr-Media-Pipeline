[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$MovieId,

    [string]$JsonOut = "",

    [switch]$Execute,

    [string]$ConfirmChainId = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "0.1.0"
$IntegrationRoot = $PSScriptRoot
$CommonPath = Join-Path $IntegrationRoot "ReacquisitionChainCommon.ps1"
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"
$ValidatorPath = Join-Path (Split-Path -Parent $IntegrationRoot) "MediaValidator.ps1"
$PolicyPath = Join-Path (Split-Path -Parent $IntegrationRoot) "validator-policy.json"
$WorkRoot = Join-Path $IntegrationRoot "Reacquisition\repair-work"

. $CommonPath

function Write-Result {
    param($Object)
    if (-not [string]::IsNullOrWhiteSpace($JsonOut)) {
        $Object | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    }
    $Object | ConvertTo-Json -Depth 60
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
    param($Connection, [string]$RelativePath)
    $headers = @{ "X-Api-Key" = $Connection.apiKey }
    $uri = $Connection.baseUrl + "/api/v3/" + $RelativePath.TrimStart("/")
    return Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 60
}

function Get-RecordArray {
    param($Response)
    if ($null -eq $Response) { return @() }
    $records = Get-PropertyValue -Object $Response -Name "records" -Default $null
    if ($null -ne $records) { return @($records) }
    return @($Response)
}

$result = [ordered]@{
    schemaVersion = "1.0"
    scriptVersion = $ScriptVersion
    timestampUtc = [DateTime]::UtcNow.ToString("o")
    mode = if ($Execute) { "EXECUTE" } else { "DRY_RUN" }
    status = "BLOCKED"
    reason = $null
    movieId = $MovieId
    chainId = $null
    chainPath = $null
    chainStatus = $null
    failedAttemptCount = $null
    maxAttempts = $null
    priorRollbackPath = $null
    currentLibraryFile = $null
    rollbackVerification = $null
    mutation = [ordered]@{
        chainStateUpdated = $false
        quarantineStateUpdated = $false
    }
}

try {
    if ($MovieId -le 0) { $result.reason = "movie_id_invalid"; Write-Result ([pscustomobject]$result); exit 0 }

    $chainPath = Get-ReacquisitionChainPath -IntegrationRoot $IntegrationRoot -Source "Radarr" -EntityId $MovieId
    $result.chainPath = $chainPath
    if (-not (Test-Path -LiteralPath $chainPath -PathType Leaf)) {
        $result.reason = "reacquisition_chain_missing"; Write-Result ([pscustomobject]$result); exit 0
    }

    $chain = Get-Content -LiteralPath $chainPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $chainId = [string](Get-PropertyValue -Object $chain -Name "chainId" -Default "")
    $chainStatus = [string](Get-PropertyValue -Object $chain -Name "status" -Default "")
    $failedAttemptCount = [int](Get-PropertyValue -Object $chain -Name "failedAttemptCount" -Default 0)
    $maxAttempts = [int](Get-PropertyValue -Object $chain -Name "maxAttempts" -Default 3)
    $rollback = Get-PropertyValue -Object $chain -Name "rollback"
    $priorRollbackPath = [string](Get-PropertyValue -Object $rollback -Name "path" -Default "")

    $result.chainId = $chainId
    $result.chainStatus = $chainStatus
    $result.failedAttemptCount = $failedAttemptCount
    $result.maxAttempts = $maxAttempts
    $result.priorRollbackPath = $priorRollbackPath

    if ($chainStatus -ne "TERMINAL_REVIEW_REQUIRED") {
        $result.reason = "chain_not_terminal_review_required"; Write-Result ([pscustomobject]$result); exit 0
    }
    if ($failedAttemptCount -lt $maxAttempts) {
        $result.reason = "chain_attempt_ceiling_not_reached"; Write-Result ([pscustomobject]$result); exit 0
    }

    $connection = Get-RadarrConnection
    $files = @(Get-RecordArray -Response (Invoke-Radarr -Connection $connection -RelativePath ("moviefile?movieId={0}" -f $MovieId)))
    if ($files.Count -ne 1) {
        $result.reason = "expected_exactly_one_current_movie_file"; Write-Result ([pscustomobject]$result); exit 0
    }

    $current = $files[0]
    $currentPath = [string](Get-PropertyValue -Object $current -Name "path" -Default "")
    $currentBytes = [int64](Get-PropertyValue -Object $current -Name "size" -Default -1)
    $currentFileId = [int](Get-PropertyValue -Object $current -Name "id" -Default 0)
    $expectedBytes = [int64](Get-PropertyValue -Object $rollback -Name "lengthBytes" -Default -1)
    $expectedFingerprint = [string](Get-PropertyValue -Object $rollback -Name "streamFingerprint" -Default "")

    if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
        $result.reason = "current_library_file_missing"; Write-Result ([pscustomobject]$result); exit 0
    }

    $snapshot = Invoke-ValidatorSnapshot -MediaPath $currentPath -LibraryType "Movie" -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -WorkRoot $WorkRoot
    $fingerprintMatches = [string]::Equals($snapshot.streamFingerprint, $expectedFingerprint, [System.StringComparison]::Ordinal)
    $sizeMatches = ($currentBytes -eq $expectedBytes -and [int64](Get-Item -LiteralPath $currentPath).Length -eq $expectedBytes)
    $verified = ($sizeMatches -and $fingerprintMatches)

    $result.currentLibraryFile = [ordered]@{
        fileId = $currentFileId
        path = $currentPath
        bytes = $currentBytes
    }
    $result.rollbackVerification = [ordered]@{
        expectedBytes = $expectedBytes
        actualBytes = $currentBytes
        sizeMatches = $sizeMatches
        expectedFingerprint = $expectedFingerprint
        actualFingerprint = $snapshot.streamFingerprint
        fingerprintMatches = $fingerprintMatches
        verified = $verified
    }

    if (-not $verified) {
        $result.reason = "current_library_file_does_not_match_canonical_rollback"; Write-Result ([pscustomobject]$result); exit 0
    }

    if (-not $Execute) {
        $result.status = "DRY_RUN_READY"
        $result.reason = $null
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($ConfirmChainId) -or
        -not [string]::Equals($ConfirmChainId, $chainId, [System.StringComparison]::Ordinal)) {
        $result.reason = "execute_chain_id_confirmation_required"; Write-Result ([pscustomobject]$result); exit 0
    }

    $rollback.path = $currentPath
    $rollback | Add-Member -NotePropertyName "originalQuarantinePath" -NotePropertyValue $priorRollbackPath -Force
    $rollback | Add-Member -NotePropertyName "status" -NotePropertyValue "RESTORED_TO_LIBRARY_TERMINAL" -Force
    $rollback | Add-Member -NotePropertyName "restoredLibraryPath" -NotePropertyValue $currentPath -Force
    $rollback | Add-Member -NotePropertyName "restoredFileId" -NotePropertyValue $currentFileId -Force
    $rollback | Add-Member -NotePropertyName "restoredUtc" -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
    $chain.updatedUtc = [DateTime]::UtcNow.ToString("o")
    Write-AtomicJson -Path $chainPath -Object $chain
    $result.mutation.chainStateUpdated = $true

    $quarantineStatePath = [string](Get-PropertyValue -Object $rollback -Name "sourceQuarantineStatePath" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($quarantineStatePath) -and (Test-Path -LiteralPath $quarantineStatePath -PathType Leaf)) {
        $q = Get-Content -LiteralPath $quarantineStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $q.status = "RESTORED_TO_LIBRARY_TERMINAL"
        $q.stage = "CHAIN_TERMINAL_ROLLBACK_RESTORED"
        $q.updatedUtc = [DateTime]::UtcNow.ToString("o")
        $q.completedUtc = [DateTime]::UtcNow.ToString("o")
        $q | Add-Member -NotePropertyName "restoredLibraryPath" -NotePropertyValue $currentPath -Force
        $q | Add-Member -NotePropertyName "restoredFileId" -NotePropertyValue $currentFileId -Force
        Write-AtomicJson -Path $quarantineStatePath -Object $q
        $result.mutation.quarantineStateUpdated = $true
    }

    $result.status = "CHAIN_ROLLBACK_RECONCILED"
    $result.reason = $null
    Write-Result ([pscustomobject]$result)
    exit 0
}
catch {
    $result.status = "FAILED"
    $result.reason = "chain_rollback_repair_exception"
    $result.error = $_.Exception.Message
    Write-Result ([pscustomobject]$result)
    exit 0
}
