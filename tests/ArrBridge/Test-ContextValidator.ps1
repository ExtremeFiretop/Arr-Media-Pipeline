[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ContextValidatorPath = Join-Path $PSScriptRoot "ContextValidator.ps1"

if (-not (Test-Path -LiteralPath $ContextValidatorPath -PathType Leaf)) {
    throw "ContextValidator.ps1 not found: $ContextValidatorPath"
}

function New-AudioTrack {
    param(
        [int]$Index,
        [string]$Language,
        [bool]$Default,
        [bool]$Commentary = $false
    )

    return [pscustomobject][ordered]@{
        index = $Index
        codec = "aac"
        language = $Language
        channels = 2
        default = $Default
        commentary = $Commentary
    }
}

$cases = @(
    [pscustomobject]@{
        Name = "English profile / English default"
        ProfileStatus = "OK"
        ProfileName = "English"
        OriginalLanguage = "eng"
        Audio = @(
            (New-AudioTrack 0 "eng" $true)
        )
        ExpectedStatus = "APPLIED"
        ExpectedOutcome = "PASS"
        ExpectedCode = $null
    },
    [pscustomobject]@{
        Name = "English profile / French default / English present"
        ProfileStatus = "OK"
        ProfileName = "English"
        OriginalLanguage = "eng"
        Audio = @(
            (New-AudioTrack 0 "fre" $true),
            (New-AudioTrack 1 "eng" $false)
        )
        ExpectedStatus = "APPLIED"
        ExpectedOutcome = "NORMALIZE"
        ExpectedCode = "language.preferred_not_default"
    },
    [pscustomobject]@{
        Name = "English profile / English missing"
        ProfileStatus = "OK"
        ProfileName = "English"
        OriginalLanguage = "eng"
        Audio = @(
            (New-AudioTrack 0 "fre" $true)
        )
        ExpectedStatus = "APPLIED"
        ExpectedOutcome = "REACQUIRE"
        ExpectedCode = "language.preferred_missing"
    },
    [pscustomobject]@{
        Name = "English profile / only unknown-language audio"
        ProfileStatus = "OK"
        ProfileName = "English"
        OriginalLanguage = "eng"
        Audio = @(
            (New-AudioTrack 0 "und" $true)
        )
        ExpectedStatus = "APPLIED"
        ExpectedOutcome = "REVIEW"
        ExpectedCode = "language.preferred_unverifiable"
    },
    [pscustomobject]@{
        Name = "French profile / French default"
        ProfileStatus = "OK"
        ProfileName = "French"
        OriginalLanguage = "eng"
        Audio = @(
            (New-AudioTrack 0 "fre" $true),
            (New-AudioTrack 1 "eng" $false)
        )
        ExpectedStatus = "APPLIED"
        ExpectedOutcome = "PASS"
        ExpectedCode = $null
    },
    [pscustomobject]@{
        Name = "French profile / English default / French present"
        ProfileStatus = "OK"
        ProfileName = "French"
        OriginalLanguage = "eng"
        Audio = @(
            (New-AudioTrack 0 "eng" $true),
            (New-AudioTrack 1 "fre" $false)
        )
        ExpectedStatus = "APPLIED"
        ExpectedOutcome = "NORMALIZE"
        ExpectedCode = "language.preferred_not_default"
    },
    [pscustomobject]@{
        Name = "Original Language / Japanese default"
        ProfileStatus = "OK"
        ProfileName = "Original Language"
        OriginalLanguage = "jpn"
        Audio = @(
            (New-AudioTrack 0 "jpn" $true),
            (New-AudioTrack 1 "eng" $false)
        )
        ExpectedStatus = "APPLIED"
        ExpectedOutcome = "PASS"
        ExpectedCode = $null
    },
    [pscustomobject]@{
        Name = "Original Language / Japanese missing"
        ProfileStatus = "OK"
        ProfileName = "Original Language"
        OriginalLanguage = "jpn"
        Audio = @(
            (New-AudioTrack 0 "eng" $true)
        )
        ExpectedStatus = "APPLIED"
        ExpectedOutcome = "REACQUIRE"
        ExpectedCode = "language.preferred_missing"
    },
    [pscustomobject]@{
        Name = "Original Language / Sonarr original language unknown"
        ProfileStatus = "OK"
        ProfileName = "Original Language"
        OriginalLanguage = ""
        Audio = @(
            (New-AudioTrack 0 "eng" $true)
        )
        ExpectedStatus = "APPLIED"
        ExpectedOutcome = "REVIEW"
        ExpectedCode = "language.original_unknown"
    },
    [pscustomobject]@{
        Name = "English only exists as commentary"
        ProfileStatus = "OK"
        ProfileName = "English"
        OriginalLanguage = "eng"
        Audio = @(
            (New-AudioTrack 0 "fre" $true),
            (New-AudioTrack 1 "eng" $false $true)
        )
        ExpectedStatus = "APPLIED"
        ExpectedOutcome = "REACQUIRE"
        ExpectedCode = "language.preferred_missing"
    },
    [pscustomobject]@{
        Name = "Profile API unavailable"
        ProfileStatus = "API_ERROR"
        ProfileName = "English"
        OriginalLanguage = "eng"
        Audio = @(
            (New-AudioTrack 0 "fre" $true)
        )
        ExpectedStatus = "SKIPPED"
        ExpectedOutcome = $null
        ExpectedCode = $null
    },
    [pscustomobject]@{
        Name = "Unmapped Sonarr profile"
        ProfileStatus = "OK"
        ProfileName = "Some Other Profile"
        OriginalLanguage = "eng"
        Audio = @(
            (New-AudioTrack 0 "eng" $true)
        )
        ExpectedStatus = "SKIPPED"
        ExpectedOutcome = $null
        ExpectedCode = $null
    }
)

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ReqestraContextValidatorSelfTest-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$results = @()

try {
    $caseNumber = 0

    foreach ($case in $cases) {
        $caseNumber++
        $caseDir = Join-Path $tempRoot ("case-" + $caseNumber.ToString("00"))
        New-Item -ItemType Directory -Path $caseDir -Force | Out-Null

        $contextPath = Join-Path $caseDir "context.json"
        $validatorPath = Join-Path $caseDir "validator-result.json"
        $outputPath = Join-Path $caseDir "contextual-result.json"

        $context = [pscustomobject][ordered]@{
            schemaVersion = "1.0"
            source = "Sonarr"
            entity = [ordered]@{
                originalLanguage = $case.OriginalLanguage
            }
            profile = [ordered]@{
                status = $case.ProfileStatus
                qualityProfileName = $case.ProfileName
            }
        }

        $validator = [pscustomobject][ordered]@{
            schemaVersion = "1.0"
            validatorVersion = "self-test"
            outcome = "PASS"
            exitCode = 0
            audio = @($case.Audio)
            findings = @()
        }

        $context | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $contextPath -Encoding UTF8
        $validator | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $validatorPath -Encoding UTF8

        $powershellExe = Join-Path $PSHOME "powershell.exe"
        if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
            $powershellExe = "powershell.exe"
        }

        & $powershellExe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $ContextValidatorPath `
            -ContextPath $contextPath `
            -ValidatorResultPath $validatorPath `
            -JsonOut $outputPath `
            -ExitZero

        if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw "Case '$($case.Name)' did not produce contextual-result.json."
        }

        $actual = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $codes = @($actual.findings | ForEach-Object { $_.code })

        $statusOk = ([string]$actual.status -eq [string]$case.ExpectedStatus)

        if ($null -eq $case.ExpectedOutcome) {
            $outcomeOk = ($null -eq $actual.outcome -or [string]::IsNullOrWhiteSpace([string]$actual.outcome))
        }
        else {
            $outcomeOk = ([string]$actual.outcome -eq [string]$case.ExpectedOutcome)
        }

        if ($null -eq $case.ExpectedCode) {
            $codeOk = ($codes.Count -eq 0)
        }
        else {
            $codeOk = ($codes -contains [string]$case.ExpectedCode)
        }

        $passed = $statusOk -and $outcomeOk -and $codeOk

        $results += [pscustomobject][ordered]@{
            Case = $case.Name
            Passed = $passed
            ExpectedStatus = $case.ExpectedStatus
            ActualStatus = $actual.status
            ExpectedOutcome = $case.ExpectedOutcome
            ActualOutcome = $actual.outcome
            ExpectedCode = $case.ExpectedCode
            ActualCodes = ($codes -join ", ")
        }
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Reqestra Context Validator Self-Test"
Write-Host "===================================="
Write-Host ""

$results | Format-Table -AutoSize -Wrap

$failed = @($results | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} contextual policy tests passed." -f $results.Count, $results.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} tests failed." -f $failed.Count, $results.Count)
Write-Host ""
$failed | Format-List *
exit 1
