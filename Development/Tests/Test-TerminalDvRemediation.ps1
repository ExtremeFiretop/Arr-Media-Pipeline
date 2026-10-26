[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Terminal Dolby Vision Remediation Contract Test"
Write-Host "========================================================="
Write-Host ""

. (Join-Path $PSScriptRoot "TerminalDvRemediationCommon.ps1")

function Decide {
    param(
        [string]$ChainStatus = "TERMINAL_REVIEW_REQUIRED",
        [int]$FailedAttemptCount = 3,
        [int]$MaxAttempts = 3,
        [bool]$RollbackVerified = $true,
        [string]$CurrentOutcome = "REACQUIRE",
        [string[]]$FindingCodes = @("video.dolby_vision"),
        [int]$DvProfile = 8,
        [int]$CompatibilityId = 1,
        [bool]$RpuPresent = $true,
        [bool]$EnhancementLayerPresent = $false,
        [bool]$BaseLayerPresent = $true,
        [string]$ColorTransfer = "smpte2084",
        [string]$ColorPrimaries = "bt2020",
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

$invokePath = Join-Path $PSScriptRoot "Invoke-TerminalDvRemediation.ps1"
$invokeText = Get-Content -LiteralPath $invokePath -Raw -Encoding UTF8

$p8 = Decide
$p7Mel = Decide -DvProfile 7 -CompatibilityId 6 -EnhancementLayerPresent $true -Profile7LayerType "MEL"
$p7Fel = Decide -DvProfile 7 -CompatibilityId 6 -EnhancementLayerPresent $true -Profile7LayerType "FEL"

$tests = @(
    [pscustomobject]@{ Test = "Terminal Profile 8.1 HDR10-base DV is remediation eligible"; Passed = ($p8.eligible -eq $true) },
    [pscustomobject]@{ Test = "Profile 8.1 is recorded as the existing lossless remediation type"; Passed = ($p8.localRemediationType -eq "DOLBY_VISION_PROFILE8_TO_HDR10_LOSSLESS") },
    [pscustomobject]@{ Test = "Active chain is not terminal-remediation eligible"; Passed = ((Decide -ChainStatus "ACTIVE").reason -eq "chain_not_terminal_review_required") },
    [pscustomobject]@{ Test = "Attempt ceiling must already be reached"; Passed = ((Decide -FailedAttemptCount 2).reason -eq "chain_attempt_ceiling_not_reached") },
    [pscustomobject]@{ Test = "Unverified restored rollback blocks remediation"; Passed = ((Decide -RollbackVerified $false).reason -eq "terminal_rollback_not_verified") },
    [pscustomobject]@{ Test = "Non-DV reacquire is not routed into DV remediation"; Passed = ((Decide -FindingCodes @("video.codec_prohibited")).reason -eq "current_media_not_dolby_vision_reacquire") },
    [pscustomobject]@{ Test = "Profile 5 remains outside local remediation"; Passed = ((Decide -DvProfile 5).reason -eq "dv_profile_not_supported_local_remediation") },
    [pscustomobject]@{ Test = "Profile 8 without HDR10 compatibility is blocked"; Passed = ((Decide -CompatibilityId 0).reason -eq "dv_base_layer_not_hdr10_compatible") },
    [pscustomobject]@{ Test = "Profile 8 enhancement-layer layout is blocked"; Passed = ((Decide -EnhancementLayerPresent $true).reason -eq "dv_layer_layout_not_supported_profile8") },
    [pscustomobject]@{ Test = "All local branches require HDR10 PQ/BT2020 signaling"; Passed = ((Decide -ColorTransfer "arib-std-b67").reason -eq "base_layer_not_hdr10_signaled") },

    [pscustomobject]@{ Test = "Terminal Profile 7 MEL is HDR10-base remediation eligible"; Passed = ($p7Mel.eligible -eq $true) },
    [pscustomobject]@{ Test = "Profile 7 MEL records a distinct base-layer remediation class"; Passed = ($p7Mel.remediationClass -eq "PROFILE7_MEL_HDR10_BASE" -and -not $p7Mel.felResidualDiscarded) },
    [pscustomobject]@{ Test = "Terminal Profile 7 FEL is eligible only as terminal fallback"; Passed = ($p7Fel.eligible -eq $true -and $p7Fel.terminalFallbackOnly -eq $true) },
    [pscustomobject]@{ Test = "Profile 7 FEL explicitly records discarded FEL residual"; Passed = ($p7Fel.felResidualDiscarded -eq $true -and $p7Fel.localRemediationType -match "FEL.*FALLBACK") },
    [pscustomobject]@{ Test = "Profile 7 FEL still fails closed before terminal chain state"; Passed = ((Decide -DvProfile 7 -CompatibilityId 6 -EnhancementLayerPresent $true -Profile7LayerType "FEL" -ChainStatus "ACTIVE").reason -eq "chain_not_terminal_review_required") },
    [pscustomobject]@{ Test = "Profile 7 without MEL/FEL classification is blocked"; Passed = ((Decide -DvProfile 7 -CompatibilityId 6 -EnhancementLayerPresent $true).reason -eq "dv_profile7_layer_type_not_classified") },
    [pscustomobject]@{ Test = "Unsupported Profile 7 compatibility id is blocked"; Passed = ((Decide -DvProfile 7 -CompatibilityId 1 -EnhancementLayerPresent $true -Profile7LayerType "MEL").reason -eq "dv_profile7_compatibility_id_not_supported") },
    [pscustomobject]@{ Test = "Profile 7 must actually carry an enhancement layer"; Passed = ((Decide -DvProfile 7 -CompatibilityId 6 -EnhancementLayerPresent $false -Profile7LayerType "MEL").reason -eq "dv_layer_layout_not_supported_profile7") },

    [pscustomobject]@{ Test = "Executor samples only 10 RPU frames for MEL/FEL classification"; Passed = ($invokeText -match 'extract-rpu\s+--limit\s+10') },
    [pscustomobject]@{ Test = "Executor recognizes both MEL and FEL classifications"; Passed = ($invokeText -match 'layerType = "MEL"' -and $invokeText -match 'layerType = "FEL"') },
    [pscustomobject]@{ Test = "Executor requires explicit chain and source-fingerprint confirmations"; Passed = ($invokeText -match 'ConfirmChainId' -and $invokeText -match 'ConfirmSourceFingerprint') },
    [pscustomobject]@{ Test = "Executor uses dovi_tool remove and MKVToolNix remux without video encode"; Passed = ($invokeText -match 'dovi_tool remove' -and $invokeText -match 'mkvmerge' -and $invokeText -notmatch 'libx265|hevc_nvenc|ffmpeg\.exe.*-c:v') },
    [pscustomobject]@{ Test = "Executor verifies MediaValidator PASS before replacement"; Passed = ($invokeText -match 'candidate_not_validator_pass') },
    [pscustomobject]@{ Test = "Executor keeps same-volume backup until Radarr reconciliation succeeds"; Passed = ($invokeText -match 'backupDeleted' -and $invokeText -match 'RescanMovie' -and $invokeText -match 'Restore-Original') },
    [pscustomobject]@{ Test = "Transaction state records FEL residual discard and terminal fallback policy"; Passed = ($invokeText -match 'felResidualDiscarded' -and $invokeText -match 'terminalFallbackOnly') },
    [pscustomobject]@{ Test = "Completed chain records dynamic local-remediation type rather than hard-coding Profile 8"; Passed = ($invokeText -match 'type = \[string\]\$decision\.localRemediationType' -and $invokeText -match 'COMPLETED_LOCAL_REMEDIATION') }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} terminal DV remediation contract tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} terminal DV remediation contract tests failed." -f ($tests.Count - $failed.Count), $tests.Count)
exit 1
