Set-StrictMode -Version Latest

$script:MediaMaintenanceVersion = "0.1.1"

function Get-MaintenanceDefaults {
    return [pscustomobject][ordered]@{
        backupRetentionDays = 7
        tempRetentionHours = 24
    }
}

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

function Test-PathEquivalent {
    param(
        [string]$First,
        [string]$Second
    )

    if ([string]::IsNullOrWhiteSpace($First) -or [string]::IsNullOrWhiteSpace($Second)) {
        return $false
    }

    try {
        $a = [System.IO.Path]::GetFullPath($First).TrimEnd("\")
        $b = [System.IO.Path]::GetFullPath($Second).TrimEnd("\")
        return [string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return [string]::Equals($First, $Second, [System.StringComparison]::OrdinalIgnoreCase)
    }
}

function Get-BackupStaticDecision {
    param(
        [Parameter(Mandatory = $true)]$Execution,
        [Parameter(Mandatory = $true)][bool]$BackupExists,
        [Parameter(Mandatory = $true)][bool]$MediaExists,
        [Parameter(Mandatory = $true)][double]$AgeDays,
        [Parameter(Mandatory = $true)][int]$RetentionDays
    )

    $mode = [string](Get-SafePropertyValue -Object $Execution -Name "mode" -Default "")
    $status = [string](Get-SafePropertyValue -Object $Execution -Name "status" -Default "")
    $backupDeleted = [bool](Get-SafePropertyValue -Object $Execution -Name "backupDeleted" -Default $false)
    $backupPath = [string](Get-SafePropertyValue -Object $Execution -Name "backupPath" -Default "")
    $rollback = Get-SafePropertyValue -Object $Execution -Name "rollback" -Default $null
    $arrReconciliation = Get-SafePropertyValue -Object $Execution -Name "arrReconciliation" -Default $null
    $arrSucceeded = $false

    if ($null -ne $arrReconciliation) {
        $arrSucceeded = [bool](Get-SafePropertyValue `
            -Object $arrReconciliation `
            -Name "succeeded" `
            -Default $false)
    }

    if ($mode -ne "EXECUTE") {
        return [pscustomobject]@{ eligible = $false; reason = "not_execute_result" }
    }

    if ($status -ne "SUCCESS") {
        return [pscustomobject]@{ eligible = $false; reason = "execution_not_success" }
    }

    if ($backupDeleted) {
        return [pscustomobject]@{ eligible = $false; reason = "backup_already_marked_deleted" }
    }

    if ([string]::IsNullOrWhiteSpace($backupPath)) {
        return [pscustomobject]@{ eligible = $false; reason = "backup_path_missing" }
    }

    if (-not $BackupExists) {
        return [pscustomobject]@{ eligible = $false; reason = "backup_file_missing" }
    }

    if (-not $MediaExists) {
        return [pscustomobject]@{ eligible = $false; reason = "current_media_missing" }
    }

    if ($null -ne $rollback) {
        return [pscustomobject]@{ eligible = $false; reason = "rollback_record_present" }
    }

    if (-not $arrSucceeded) {
        return [pscustomobject]@{ eligible = $false; reason = "arr_reconciliation_not_confirmed" }
    }

    if ($AgeDays -lt $RetentionDays) {
        return [pscustomobject]@{ eligible = $false; reason = "retention_period_not_met" }
    }

    return [pscustomobject]@{ eligible = $true; reason = $null }
}

function Get-TempStaticDecision {
    param(
        [Parameter(Mandatory = $true)][string]$ArtifactKind,
        [Parameter(Mandatory = $true)][bool]$Exists,
        [Parameter(Mandatory = $true)][double]$AgeHours,
        [Parameter(Mandatory = $true)][int]$RetentionHours
    )

    if (-not $Exists) {
        return [pscustomobject]@{ eligible = $false; reason = "temp_file_missing" }
    }

    if ($ArtifactKind -eq "FAILED_REPLACEMENT") {
        return [pscustomobject]@{ eligible = $false; reason = "failed_replacement_protected" }
    }

    if ($ArtifactKind -ne "ORDINARY_TEMP") {
        return [pscustomobject]@{ eligible = $false; reason = "unknown_temp_artifact_kind" }
    }

    if ($AgeHours -lt $RetentionHours) {
        return [pscustomobject]@{ eligible = $false; reason = "temp_retention_period_not_met" }
    }

    return [pscustomobject]@{ eligible = $true; reason = $null }
}
