Set-StrictMode -Version Latest

function Get-ReacquisitionSuccessDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Chain,
        [Parameter(Mandatory = $true)]$Bridge,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$CurrentSnapshot,
        [Parameter(Mandatory = $true)][string]$CurrentEffectiveOutcome,
        [Parameter(Mandatory = $true)]$ArrFile,
        [Parameter(Mandatory = $true)]$RollbackCheck,
        [Parameter(Mandatory = $true)][string]$EventFingerprint
    )

    function Value($Object, [string]$Name, $Default = $null) {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $Default }
        return $property.Value
    }

    function PathEqual([string]$First, [string]$Second) {
        if ([string]::IsNullOrWhiteSpace($First) -or [string]::IsNullOrWhiteSpace($Second)) { return $false }
        try {
            $a = [System.IO.Path]::GetFullPath($First).TrimEnd("\")
            $b = [System.IO.Path]::GetFullPath($Second).TrimEnd("\")
            return [string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            return [string]::Equals($First, $Second, [System.StringComparison]::OrdinalIgnoreCase)
        }
    }

    $chainStatus = [string](Value $Chain "status" "")
    if ($chainStatus -eq "COMPLETED_SUCCESS") {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $true; reason = "chain_already_completed_success" }
    }
    if ($chainStatus -ne "ACTIVE") {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $false; reason = "reacquisition_chain_not_active" }
    }

    if ([string](Value $Bridge "status" "") -ne "VALIDATED") {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $false; reason = "bridge_event_not_validated" }
    }
    if ([string](Value $Bridge "effectiveOutcome" "") -ne "PASS") {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $false; reason = "event_effective_outcome_not_pass" }
    }
    if ($CurrentEffectiveOutcome -ne "PASS") {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $false; reason = "current_effective_outcome_not_pass" }
    }

    $source = [string](Value $Context "source" "")
    $entity = Value $Context "entity"
    $file = Value $Context "file"
    $seriesId = [int](Value $entity "id" 0)
    $fileId = [int](Value $file "id" 0)
    $mediaPath = [string](Value $file "path" "")

    if ($source -ne "Sonarr" -or $seriesId -le 0 -or $fileId -le 0 -or [string]::IsNullOrWhiteSpace($mediaPath)) {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $false; reason = "replacement_context_identity_invalid" }
    }
    if ([string](Value $Chain "source" "") -ne "Sonarr" -or [int](Value $Chain "entityId" 0) -ne $seriesId) {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $false; reason = "replacement_does_not_match_chain_entity" }
    }

    $episode = Value $Context "episode"
    $contextEpisodeIds = @(
        @(Value $episode "ids" @()) | ForEach-Object {
            $parsed = 0
            if ([int]::TryParse([string]$_, [ref]$parsed) -and $parsed -gt 0) { $parsed }
        } | Sort-Object -Unique
    )
    $chainEpisodeIds = @(
        @(Value $Chain "episodeIds" @()) | ForEach-Object {
            $parsed = 0
            if ([int]::TryParse([string]$_, [ref]$parsed) -and $parsed -gt 0) { $parsed }
        } | Sort-Object -Unique
    )
    if ($contextEpisodeIds.Count -eq 0 -or $chainEpisodeIds.Count -eq 0 -or
        $contextEpisodeIds.Count -ne $chainEpisodeIds.Count -or
        (($contextEpisodeIds -join ",") -ne ($chainEpisodeIds -join ","))) {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $false; reason = "replacement_episode_set_does_not_match_chain" }
    }

    $currentPath = [string](Value $CurrentSnapshot "mediaPath" "")
    $currentBytes = [int64](Value $CurrentSnapshot "lengthBytes" -1)
    $currentFingerprint = [string](Value $CurrentSnapshot "streamFingerprint" "")
    if (-not (PathEqual $mediaPath $currentPath) -or $currentBytes -le 0 -or [string]::IsNullOrWhiteSpace($currentFingerprint)) {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $false; reason = "current_replacement_snapshot_invalid" }
    }
    if ([string]::IsNullOrWhiteSpace($EventFingerprint) -or
        -not [string]::Equals($EventFingerprint, $currentFingerprint, [System.StringComparison]::Ordinal)) {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $false; reason = "replacement_changed_since_validated_event" }
    }

    $arrId = [int](Value $ArrFile "id" 0)
    $arrPath = [string](Value $ArrFile "path" "")
    $arrBytes = [int64](Value $ArrFile "size" -1)
    if ($arrId -ne $fileId -or -not (PathEqual $arrPath $mediaPath) -or $arrBytes -ne $currentBytes) {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $false; reason = "sonarr_replacement_file_mismatch" }
    }

    if (-not [bool](Value $RollbackCheck "verified" $false)) {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $false; reason = "canonical_rollback_not_verified" }
    }
    $rollbackPath = [string](Value $RollbackCheck "path" "")
    if (PathEqual $rollbackPath $mediaPath) {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $false; reason = "current_file_is_canonical_rollback" }
    }

    $maxAttempts = [int](Value $Chain "maxAttempts" 3)
    $failedAttemptCount = [int](Value $Chain "failedAttemptCount" 0)
    if ($failedAttemptCount -ge $maxAttempts) {
        return [pscustomobject][ordered]@{ eligible = $false; idempotent = $false; reason = "chain_attempt_ceiling_already_reached" }
    }

    return [pscustomobject][ordered]@{
        eligible = $true
        idempotent = $false
        reason = $null
        seriesId = $seriesId
        episodeIds = @($contextEpisodeIds)
        fileId = $fileId
        mediaPath = $mediaPath
        lengthBytes = $currentBytes
        streamFingerprint = $currentFingerprint
        nextAttemptNumber = $failedAttemptCount + 1
    }
}
