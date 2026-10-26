[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$MovieId,

    [string[]]$TriggerFindingCode = @("video.dolby_vision"),

    [int]$Top = 10,

    [string]$JsonOut = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "0.1.1"
$ToolsRoot = $PSScriptRoot
$IntegrationRoot = Split-Path -Parent $ToolsRoot
$ConfigPath = Join-Path $IntegrationRoot "integration-config.json"
$CommonPath = Join-Path $IntegrationRoot "ReacquisitionChainCommon.ps1"
$SelectorPath = Join-Path $IntegrationRoot "ReacquisitionReleaseSelector.ps1"

. $CommonPath
. $SelectorPath

function Write-Result {
    param($Object)
    if (-not [string]::IsNullOrWhiteSpace($JsonOut)) {
        $Object | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    }
    $Object | ConvertTo-Json -Depth 60
}

function Invoke-RadarrGet {
    param([string]$RelativePath)

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

    return Invoke-RestMethod `
        -Uri ($baseUrl.TrimEnd("/") + "/api/v3/" + $RelativePath.TrimStart("/")) `
        -Headers @{ "X-Api-Key" = $apiKey } `
        -Method Get `
        -TimeoutSec 60
}

$result = [ordered]@{
    schemaVersion = "1.0"
    scriptVersion = $ScriptVersion
    timestampUtc = [DateTime]::UtcNow.ToString("o")
    mode = "READ_ONLY"
    status = "FAILED"
    reason = $null
    movieId = $MovieId
    triggerFindingCodes = @($TriggerFindingCode)
    chainId = $null
    candidatePoolMode = $null
    totalReleaseCount = 0
    approvedCandidateCount = 0
    diskOnlyBlockedCandidateCount = 0
    strategy = $null
    selected = $null
    ranked = @()
}

try {
    if ($MovieId -le 0) { throw "MovieId must be greater than zero." }
    if ($Top -lt 1) { $Top = 1 }
    if ($Top -gt 50) { $Top = 50 }

    $chainPath = Get-ReacquisitionChainPath -IntegrationRoot $IntegrationRoot -Source "Radarr" -EntityId $MovieId
    $chain = $null
    if (Test-Path -LiteralPath $chainPath -PathType Leaf) {
        $chain = Get-Content -LiteralPath $chainPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $result.chainId = [string](Get-PropertyValue -Object $chain -Name "chainId" -Default "")
    }

    $response = Invoke-RadarrGet -RelativePath ("release?movieId={0}" -f $MovieId)
    $recordsProperty = Get-PropertyValue -Object $response -Name "records" -Default $null
    $releases = if ($null -ne $recordsProperty) { @($recordsProperty) } else { @($response) }

    $approved = @($releases | Where-Object { [bool](Get-PropertyValue -Object $_ -Name "approved" -Default $false) })
    $diskOnly = @($releases | Where-Object { Test-ReacquisitionDiskOnlyRejection -Release $_ })

    $result.totalReleaseCount = $releases.Count
    $result.approvedCandidateCount = $approved.Count
    $result.diskOnlyBlockedCandidateCount = $diskOnly.Count

    $isDolbyVisionReacquisition = (@($TriggerFindingCode) -contains "video.dolby_vision")
    $pool = @()
    if ($isDolbyVisionReacquisition) {
        # A restored/current MovieFile can make the safest HDR10/SDR releases
        # appear rejected only because that file already satisfies cutoff. Rank
        # the pool that would exist after removing the current file instead of
        # allowing the small currently-approved subset to hide those releases.
        $pool = @(Get-ReacquisitionPredictedCandidatePool -Releases $releases)
        if ($pool.Count -gt 0) {
            $result.candidatePoolMode = if ($diskOnly.Count -gt 0) {
                "PREDICTED_AFTER_CURRENT_FILE_REMOVAL"
            }
            else {
                "APPROVED"
            }
        }
    }
    elseif ($approved.Count -gt 0) {
        $pool = $approved
        $result.candidatePoolMode = "APPROVED"
    }
    elseif ($diskOnly.Count -gt 0) {
        $pool = $diskOnly
        $result.candidatePoolMode = "PREDICTED_AFTER_CURRENT_FILE_REMOVAL"
    }

    if ($pool.Count -le 0) {
        $result.status = "NO_CANDIDATES"
        $result.reason = "no_approved_or_disk_only_candidates"
        Write-Result ([pscustomobject]$result)
        exit 0
    }

    $selection = Select-ReacquisitionRelease -Releases $pool -TriggerFindingCodes @($TriggerFindingCode) -Chain $chain
    $result.strategy = $selection.strategy
    $result.selected = ConvertTo-ReacquisitionReleaseSummary -Candidate $selection.selected
    $result.ranked = @(
        @($selection.ranked | Select-Object -First $Top) |
            ForEach-Object { ConvertTo-ReacquisitionReleaseSummary -Candidate $_ }
    )

    if ($selection.strategy -eq "DOLBY_VISION_SAFE_EVIDENCE_V1" -and $null -eq $selection.selected) {
        $result.status = "NO_SAFE_SELECTION"
        $result.reason = "no_dv_safe_candidate_after_local_ranking"
    }
    else {
        $result.status = "SELECTION_READY"
        $result.reason = $null
    }

    Write-Result ([pscustomobject]$result)
}
catch {
    $result.status = "FAILED"
    $result.reason = "release_selection_exception"
    $result.error = $_.Exception.Message
    Write-Result ([pscustomobject]$result)
    exit 0
}
