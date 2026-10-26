[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ContextPath,

    [Parameter(Mandatory = $true)]
    [string]$ValidatorResultPath,

    [Parameter(Mandatory = $true)]
    [string]$JsonOut,

    [switch]$ExitZero
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ContextValidatorVersion = "0.1.0"

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $false)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function Normalize-Language {
    param([string]$Language)

    if ([string]::IsNullOrWhiteSpace($Language)) {
        return "und"
    }

    $value = $Language.Trim().ToLowerInvariant()

    switch ($value) {
        "en"  { return "eng" }
        "eng" { return "eng" }
        "fr"  { return "fre" }
        "fre" { return "fre" }
        "fra" { return "fre" }
        "ja"  { return "jpn" }
        "jpn" { return "jpn" }
        "es"  { return "spa" }
        "spa" { return "spa" }
        "de"  { return "ger" }
        "deu" { return "ger" }
        "ger" { return "ger" }
        "it"  { return "ita" }
        "ita" { return "ita" }
        "pt"  { return "por" }
        "por" { return "por" }
        "ko"  { return "kor" }
        "kor" { return "kor" }
        "zh"  { return "chi" }
        "zho" { return "chi" }
        "chi" { return "chi" }
        "und" { return "und" }
        default { return $value }
    }
}

function New-Finding {
    param(
        [Parameter(Mandatory = $true)][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        $Details = $null
    )

    return [pscustomobject][ordered]@{
        severity = $Severity
        code = $Code
        message = $Message
        details = $Details
    }
}

function Get-Outcome {
    param([object[]]$Findings)

    $rank = @{
        "PASS" = 0
        "INFO" = 0
        "NORMALIZE" = 1
        "REVIEW" = 2
        "REACQUIRE" = 3
    }

    $highest = 0

    foreach ($finding in @($Findings)) {
        $severity = [string](Get-PropertyValue -Object $finding -Name "severity" -Default "INFO")
        if ($rank.ContainsKey($severity) -and $rank[$severity] -gt $highest) {
            $highest = $rank[$severity]
        }
    }

    switch ($highest) {
        3 { return "REACQUIRE" }
        2 { return "REVIEW" }
        1 { return "NORMALIZE" }
        default { return "PASS" }
    }
}

function Get-OutcomeExitCode {
    param([string]$Outcome)

    switch ($Outcome) {
        "PASS"      { return 0 }
        "NORMALIZE" { return 10 }
        "REVIEW"    { return 20 }
        "REACQUIRE" { return 30 }
        default     { return 0 }
    }
}

function Write-ResultAndExit {
    param($Result)

    $Result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $JsonOut -Encoding UTF8

    if ($ExitZero) {
        exit 0
    }

    if ($null -eq $Result.outcome) {
        exit 0
    }

    exit (Get-OutcomeExitCode -Outcome ([string]$Result.outcome))
}

$timestampUtc = [DateTime]::UtcNow.ToString("o")

try {
    $context = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $validator = Get-Content -LiteralPath $ValidatorResultPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $source = [string](Get-PropertyValue -Object $context -Name "source" -Default "")
    $profile = Get-PropertyValue -Object $context -Name "profile"
    $profileStatus = [string](Get-PropertyValue -Object $profile -Name "status" -Default "")
    $profileName = [string](Get-PropertyValue -Object $profile -Name "qualityProfileName" -Default "")
    $entity = Get-PropertyValue -Object $context -Name "entity"
    $originalLanguage = Normalize-Language ([string](Get-PropertyValue -Object $entity -Name "originalLanguage" -Default ""))

    $resultBase = [ordered]@{
        schemaVersion = "1.0"
        contextValidatorVersion = $ContextValidatorVersion
        timestampUtc = $timestampUtc
        source = $source
        profileName = if ([string]::IsNullOrWhiteSpace($profileName)) { $null } else { $profileName }
        status = "SKIPPED"
        reason = $null
        policyMode = $null
        preferredLanguage = $null
        outcome = $null
        exitCode = 0
        findings = @()
    }

    # Current language intent is intentionally scoped to Sonarr because these
    # are the user's Sonarr language-aware quality profiles. Radarr remains
    # governed by the frozen generic validator until an explicit movie-language
    # policy is defined.
    if ($source -ne "Sonarr") {
        $resultBase.reason = "source_not_language_profiled"
        Write-ResultAndExit -Result ([pscustomobject]$resultBase)
    }

    if ($profileStatus -ne "OK") {
        $resultBase.reason = "profile_unavailable"
        Write-ResultAndExit -Result ([pscustomobject]$resultBase)
    }

    $profileKey = $profileName.Trim().ToLowerInvariant()
    $policyMode = $null
    $preferredLanguage = $null

    switch ($profileKey) {
        "english" {
            $policyMode = "fixed"
            $preferredLanguage = "eng"
        }
        "french" {
            $policyMode = "fixed"
            $preferredLanguage = "fre"
        }
        "original" {
            $policyMode = "original"
            $preferredLanguage = $originalLanguage
        }
        "original language" {
            $policyMode = "original"
            $preferredLanguage = $originalLanguage
        }
        default {
            $resultBase.reason = "profile_not_language_mapped"
            Write-ResultAndExit -Result ([pscustomobject]$resultBase)
        }
    }

    $resultBase.status = "APPLIED"
    $resultBase.reason = $null
    $resultBase.policyMode = $policyMode
    $resultBase.preferredLanguage = $preferredLanguage

    $findings = @()

    if ($policyMode -eq "original" -and $preferredLanguage -eq "und") {
        $findings += New-Finding `
            -Severity "REVIEW" `
            -Code "language.original_unknown" `
            -Message "The series uses an Original Language profile, but Sonarr did not provide a usable original language."

        $resultBase.findings = @($findings)
        $resultBase.outcome = Get-Outcome -Findings $findings
        $resultBase.exitCode = Get-OutcomeExitCode -Outcome $resultBase.outcome
        Write-ResultAndExit -Result ([pscustomobject]$resultBase)
    }

    $audio = @(
        @(Get-PropertyValue -Object $validator -Name "audio" -Default @()) |
            Where-Object { $null -ne $_ }
    )

    # Generic MediaValidator owns audio.missing. Do not duplicate that finding.
    if ($audio.Count -gt 0) {
        $mainAudio = @(
            $audio | Where-Object {
                -not [bool](Get-PropertyValue -Object $_ -Name "commentary" -Default $false)
            }
        )

        $preferredTracks = @(
            $mainAudio | Where-Object {
                (Normalize-Language ([string](Get-PropertyValue -Object $_ -Name "language" -Default ""))) -eq $preferredLanguage
            }
        )

        $unknownTracks = @(
            $mainAudio | Where-Object {
                (Normalize-Language ([string](Get-PropertyValue -Object $_ -Name "language" -Default ""))) -eq "und"
            }
        )

        $preferredDefaults = @(
            $preferredTracks | Where-Object {
                [bool](Get-PropertyValue -Object $_ -Name "default" -Default $false)
            }
        )

        if ($preferredTracks.Count -eq 0) {
            if ($unknownTracks.Count -gt 0) {
                $findings += New-Finding `
                    -Severity "REVIEW" `
                    -Code "language.preferred_unverifiable" `
                    -Message "No explicitly tagged preferred-language audio track was found, but one or more non-commentary audio tracks have unknown language metadata." `
                    -Details ([ordered]@{
                        preferredLanguage = $preferredLanguage
                        unknownStreamIndexes = @($unknownTracks | ForEach-Object { Get-PropertyValue -Object $_ -Name "index" -Default -1 })
                    })
            }
            else {
                $knownLanguages = @(
                    $mainAudio |
                        ForEach-Object {
                            Normalize-Language ([string](Get-PropertyValue -Object $_ -Name "language" -Default ""))
                        } |
                        Where-Object { $_ -ne "und" } |
                        Select-Object -Unique
                )

                $findings += New-Finding `
                    -Severity "REACQUIRE" `
                    -Code "language.preferred_missing" `
                    -Message "The audio streams do not contain the language required by the assigned Sonarr profile." `
                    -Details ([ordered]@{
                        preferredLanguage = $preferredLanguage
                        availableLanguages = @($knownLanguages)
                    })
            }
        }
        elseif ($preferredDefaults.Count -eq 0) {
            $findings += New-Finding `
                -Severity "NORMALIZE" `
                -Code "language.preferred_not_default" `
                -Message "A preferred-language non-commentary audio track exists but is not marked as default." `
                -Details ([ordered]@{
                    preferredLanguage = $preferredLanguage
                    candidateStreamIndexes = @($preferredTracks | ForEach-Object { Get-PropertyValue -Object $_ -Name "index" -Default -1 })
                })
        }
    }

    $resultBase.findings = @($findings)
    $resultBase.outcome = Get-Outcome -Findings $findings
    $resultBase.exitCode = Get-OutcomeExitCode -Outcome $resultBase.outcome

    Write-ResultAndExit -Result ([pscustomobject]$resultBase)
}
catch {
    $failure = [pscustomobject][ordered]@{
        schemaVersion = "1.0"
        contextValidatorVersion = $ContextValidatorVersion
        timestampUtc = $timestampUtc
        source = $null
        profileName = $null
        status = "ERROR"
        reason = "context_validator_error"
        policyMode = $null
        preferredLanguage = $null
        outcome = $null
        exitCode = 0
        findings = @()
        error = $_.Exception.Message
    }

    Write-ResultAndExit -Result $failure
}
