Set-StrictMode -Version Latest

function Get-TerminalDvRemediationDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ChainStatus,
        [Parameter(Mandatory = $true)][int]$FailedAttemptCount,
        [Parameter(Mandatory = $true)][int]$MaxAttempts,
        [Parameter(Mandatory = $true)][bool]$RollbackVerified,
        [Parameter(Mandatory = $true)][string]$CurrentOutcome,
        [Parameter(Mandatory = $true)][string[]]$FindingCodes,
        [Parameter(Mandatory = $true)][int]$DvProfile,
        [Parameter(Mandatory = $true)][int]$CompatibilityId,
        [Parameter(Mandatory = $true)][bool]$RpuPresent,
        [Parameter(Mandatory = $true)][bool]$EnhancementLayerPresent,
        [Parameter(Mandatory = $true)][bool]$BaseLayerPresent,
        [Parameter(Mandatory = $true)][string]$ColorTransfer,
        [Parameter(Mandatory = $true)][string]$ColorPrimaries,
        [string]$Profile7LayerType = ""
    )

    function Block {
        param([string]$Reason)
        return [pscustomobject][ordered]@{
            eligible = $false
            reason = $Reason
            remediationClass = $null
            localRemediationType = $null
            videoReencoded = $false
            hdr10BaseLayerRetained = $false
            enhancementLayerDiscarded = $false
            felResidualDiscarded = $false
            terminalFallbackOnly = $false
        }
    }

    function Allow {
        param(
            [string]$RemediationClass,
            [string]$LocalRemediationType,
            [bool]$EnhancementLayerDiscarded,
            [bool]$FelResidualDiscarded,
            [bool]$TerminalFallbackOnly
        )
        return [pscustomobject][ordered]@{
            eligible = $true
            reason = $null
            remediationClass = $RemediationClass
            localRemediationType = $LocalRemediationType
            videoReencoded = $false
            hdr10BaseLayerRetained = $true
            enhancementLayerDiscarded = $EnhancementLayerDiscarded
            felResidualDiscarded = $FelResidualDiscarded
            terminalFallbackOnly = $TerminalFallbackOnly
        }
    }

    # Every local DV remediation branch is terminal-only. Normal reacquisition
    # must already have exhausted its attempt ceiling and restored the verified
    # canonical rollback before this path is even considered.
    if ($ChainStatus -ne "TERMINAL_REVIEW_REQUIRED") {
        return (Block -Reason "chain_not_terminal_review_required")
    }
    if ($MaxAttempts -le 0 -or $FailedAttemptCount -lt $MaxAttempts) {
        return (Block -Reason "chain_attempt_ceiling_not_reached")
    }
    if (-not $RollbackVerified) {
        return (Block -Reason "terminal_rollback_not_verified")
    }
    if ($CurrentOutcome -ne "REACQUIRE" -or $FindingCodes -notcontains "video.dolby_vision") {
        return (Block -Reason "current_media_not_dolby_vision_reacquire")
    }

    # All supported local branches retain the source HEVC HDR10 base layer.
    # Refuse ambiguous/non-HDR10 base signaling before making any profile-
    # specific decision.
    if ($ColorTransfer -ne "smpte2084" -or $ColorPrimaries -ne "bt2020") {
        return (Block -Reason "base_layer_not_hdr10_signaled")
    }

    if ($DvProfile -eq 8) {
        if ($CompatibilityId -ne 1) {
            return (Block -Reason "dv_base_layer_not_hdr10_compatible")
        }
        if (-not $RpuPresent -or -not $BaseLayerPresent -or $EnhancementLayerPresent) {
            return (Block -Reason "dv_layer_layout_not_supported_profile8")
        }

        return (Allow `
            -RemediationClass "PROFILE8_HDR10_BASE" `
            -LocalRemediationType "DOLBY_VISION_PROFILE8_TO_HDR10_LOSSLESS" `
            -EnhancementLayerDiscarded $false `
            -FelResidualDiscarded $false `
            -TerminalFallbackOnly $false)
    }

    if ($DvProfile -eq 7) {
        # The user's UHD-BD Profile 7 population reports compatibility id 6.
        # Candidate validation still independently requires clean HDR10 PQ/
        # BT.2020 output after dovi_tool removes EL/RPU.
        if ($CompatibilityId -ne 6) {
            return (Block -Reason "dv_profile7_compatibility_id_not_supported")
        }
        if (-not $RpuPresent -or -not $BaseLayerPresent -or -not $EnhancementLayerPresent) {
            return (Block -Reason "dv_layer_layout_not_supported_profile7")
        }

        $layerType = $Profile7LayerType.Trim().ToUpperInvariant()
        if ($layerType -eq "MEL") {
            return (Allow `
                -RemediationClass "PROFILE7_MEL_HDR10_BASE" `
                -LocalRemediationType "DOLBY_VISION_PROFILE7_MEL_TO_HDR10_BASE_LAYER" `
                -EnhancementLayerDiscarded $true `
                -FelResidualDiscarded $false `
                -TerminalFallbackOnly $false)
        }
        if ($layerType -eq "FEL") {
            # FEL carries real residual enhancement data. This is intentionally
            # permitted only here, after the normal reacquisition chain is
            # terminal/exhausted, and is recorded distinctly as a fallback.
            return (Allow `
                -RemediationClass "PROFILE7_FEL_HDR10_BASE_TERMINAL_FALLBACK" `
                -LocalRemediationType "DOLBY_VISION_PROFILE7_FEL_TO_HDR10_BASE_LAYER_FALLBACK" `
                -EnhancementLayerDiscarded $true `
                -FelResidualDiscarded $true `
                -TerminalFallbackOnly $true)
        }

        return (Block -Reason "dv_profile7_layer_type_not_classified")
    }

    return (Block -Reason "dv_profile_not_supported_local_remediation")
}

# Backward-compatible wrapper retained for any local callers from v0.9.23.
function Get-TerminalDvLosslessDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ChainStatus,
        [Parameter(Mandatory = $true)][int]$FailedAttemptCount,
        [Parameter(Mandatory = $true)][int]$MaxAttempts,
        [Parameter(Mandatory = $true)][bool]$RollbackVerified,
        [Parameter(Mandatory = $true)][string]$CurrentOutcome,
        [Parameter(Mandatory = $true)][string[]]$FindingCodes,
        [Parameter(Mandatory = $true)][int]$DvProfile,
        [Parameter(Mandatory = $true)][int]$CompatibilityId,
        [Parameter(Mandatory = $true)][bool]$RpuPresent,
        [Parameter(Mandatory = $true)][bool]$EnhancementLayerPresent,
        [Parameter(Mandatory = $true)][bool]$BaseLayerPresent,
        [Parameter(Mandatory = $true)][string]$ColorTransfer,
        [Parameter(Mandatory = $true)][string]$ColorPrimaries,
        [string]$Profile7LayerType = ""
    )

    Get-TerminalDvRemediationDecision `
        -ChainStatus $ChainStatus `
        -FailedAttemptCount $FailedAttemptCount `
        -MaxAttempts $MaxAttempts `
        -RollbackVerified $RollbackVerified `
        -CurrentOutcome $CurrentOutcome `
        -FindingCodes $FindingCodes `
        -DvProfile $DvProfile `
        -CompatibilityId $CompatibilityId `
        -RpuPresent $RpuPresent `
        -EnhancementLayerPresent $EnhancementLayerPresent `
        -BaseLayerPresent $BaseLayerPresent `
        -ColorTransfer $ColorTransfer `
        -ColorPrimaries $ColorPrimaries `
        -Profile7LayerType $Profile7LayerType
}
