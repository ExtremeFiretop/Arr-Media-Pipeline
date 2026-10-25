[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PlannerPath = Join-Path $PSScriptRoot "NormalizationPlanner.ps1"
$PowerShellExe = Join-Path $PSHOME "powershell.exe"
if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) {
    $PowerShellExe = "powershell.exe"
}

function New-Audio {
    param(
        [int]$Index,
        [string]$Language,
        [bool]$Default,
        [bool]$Commentary = $false
    )

    [pscustomobject][ordered]@{
        index = $Index
        codec = "aac"
        language = $Language
        channels = 2
        default = $Default
        commentary = $Commentary
    }
}

function New-Finding {
    param([string]$Code)
    [pscustomobject][ordered]@{
        severity = "NORMALIZE"
        code = $Code
        message = $Code
    }
}

$cases = @(
    [pscustomobject]@{
        Name = "English profile changes French default to English"
        Audio = @((New-Audio 1 "fre" $true), (New-Audio 2 "eng" $false))
        GenericCodes = @()
        ContextStatus = "APPLIED"
        Preferred = "eng"
        ContextCodes = @("language.preferred_not_default")
        ExpectedStatus = "PLANNED"
        ExpectedReason = ""
        ExpectedActions = 2
        ExpectedTargetOrdinal = 2
    },
    [pscustomobject]@{
        Name = "No default, one audio track"
        Audio = @((New-Audio 1 "eng" $false))
        GenericCodes = @("audio.no_default")
        ContextStatus = "SKIPPED"
        Preferred = ""
        ContextCodes = @()
        ExpectedStatus = "PLANNED"
        ExpectedReason = ""
        ExpectedActions = 1
        ExpectedTargetOrdinal = 1
    },
    [pscustomobject]@{
        Name = "Multiple defaults, unique preferred language"
        Audio = @((New-Audio 1 "fre" $true), (New-Audio 2 "eng" $true))
        GenericCodes = @("audio.multiple_defaults")
        ContextStatus = "APPLIED"
        Preferred = "eng"
        ContextCodes = @("language.preferred_not_default")
        ExpectedStatus = "PLANNED"
        ExpectedReason = ""
        ExpectedActions = 1
        ExpectedTargetOrdinal = 2
    },
    [pscustomobject]@{
        Name = "Commentary default cleared in favor of sole main track"
        Audio = @((New-Audio 1 "eng" $false), (New-Audio 2 "eng" $true $true))
        GenericCodes = @("audio.commentary_default")
        ContextStatus = "SKIPPED"
        Preferred = ""
        ContextCodes = @()
        ExpectedStatus = "PLANNED"
        ExpectedReason = ""
        ExpectedActions = 2
        ExpectedTargetOrdinal = 1
    },
    [pscustomobject]@{
        Name = "Two English candidates blocks"
        Audio = @((New-Audio 1 "fre" $true), (New-Audio 2 "eng" $false), (New-Audio 3 "eng" $false))
        GenericCodes = @()
        ContextStatus = "APPLIED"
        Preferred = "eng"
        ContextCodes = @("language.preferred_not_default")
        ExpectedStatus = "BLOCKED"
        ExpectedReason = "multiple_preferred_audio_candidates"
        ExpectedActions = 0
        ExpectedTargetOrdinal = 0
    },
    [pscustomobject]@{
        Name = "No profile, no default, multiple main tracks blocks"
        Audio = @((New-Audio 1 "eng" $false), (New-Audio 2 "fre" $false))
        GenericCodes = @("audio.no_default")
        ContextStatus = "SKIPPED"
        Preferred = ""
        ContextCodes = @()
        ExpectedStatus = "BLOCKED"
        ExpectedReason = "ambiguous_default_audio_target"
        ExpectedActions = 0
        ExpectedTargetOrdinal = 0
    },
    [pscustomobject]@{
        Name = "Clean file is not needed"
        Audio = @((New-Audio 1 "eng" $true))
        GenericCodes = @()
        ContextStatus = "APPLIED"
        Preferred = "eng"
        ContextCodes = @()
        ExpectedStatus = "NOT_NEEDED"
        ExpectedReason = "no_supported_normalization_findings"
        ExpectedActions = 0
        ExpectedTargetOrdinal = 0
    },
    [pscustomobject]@{
        Name = "Non-MKV skipped"
        Audio = @((New-Audio 1 "eng" $false))
        GenericCodes = @("audio.no_default")
        ContextStatus = "SKIPPED"
        Preferred = ""
        ContextCodes = @()
        Extension = ".mp4"
        ExpectedStatus = "SKIPPED"
        ExpectedReason = "container_not_supported"
        ExpectedActions = 0
        ExpectedTargetOrdinal = 0
    }
)

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ReqestraNormalizationPlannerSelfTest-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$results = @()

try {
    $n = 0
    foreach ($case in $cases) {
        $n++
        $dir = Join-Path $tempRoot ("case-" + $n.ToString("00"))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $ext = if ($case.PSObject.Properties["Extension"]) { [string]$case.Extension } else { ".mkv" }
        $mediaPath = "C:\Media\Test" + $ext

        $context = [pscustomobject][ordered]@{
            source = "Sonarr"
            file = [ordered]@{ path = $mediaPath }
        }

        $validator = [pscustomobject][ordered]@{
            validatorVersion = "self-test"
            audio = @($case.Audio)
            findings = @($case.GenericCodes | ForEach-Object { New-Finding $_ })
        }

        $contextual = [pscustomobject][ordered]@{
            status = $case.ContextStatus
            preferredLanguage = $case.Preferred
            findings = @($case.ContextCodes | ForEach-Object { New-Finding $_ })
        }

        $contextPath = Join-Path $dir "context.json"
        $validatorPath = Join-Path $dir "validator.json"
        $contextualPath = Join-Path $dir "contextual.json"
        $outPath = Join-Path $dir "plan.json"

        $context | ConvertTo-Json -Depth 20 | Set-Content $contextPath -Encoding UTF8
        $validator | ConvertTo-Json -Depth 20 | Set-Content $validatorPath -Encoding UTF8
        $contextual | ConvertTo-Json -Depth 20 | Set-Content $contextualPath -Encoding UTF8

        & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $PlannerPath `
            -ContextPath $contextPath `
            -ValidatorResultPath $validatorPath `
            -ContextualResultPath $contextualPath `
            -JsonOut $outPath

        $actual = Get-Content $outPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $actions = @($actual.actions)

        $passed =
            ([string]$actual.status -eq [string]$case.ExpectedStatus) -and
            ([string]$actual.reason -eq [string]$case.ExpectedReason -or
                ([string]::IsNullOrWhiteSpace([string]$actual.reason) -and [string]::IsNullOrWhiteSpace([string]$case.ExpectedReason))) -and
            ($actions.Count -eq [int]$case.ExpectedActions)

        if ($case.ExpectedTargetOrdinal -gt 0) {
            # Validate the *resulting* default state rather than requiring a
            # "set true" action. A correct plan may only need to clear an extra
            # default when the preferred target is already marked default.
            $finalDefaults = @{}

            for ($i = 0; $i -lt $case.Audio.Count; $i++) {
                $ordinal = $i + 1
                $finalDefaults[$ordinal] = [bool]$case.Audio[$i].default
            }

            foreach ($action in $actions) {
                if ([string]$action.action -eq "set_audio_default_flag") {
                    $finalDefaults[[int]$action.audioOrdinal] = [bool]$action.to
                }
            }

            $defaultOrdinals = @(
                $finalDefaults.GetEnumerator() |
                    Where-Object { $_.Value -eq $true } |
                    ForEach-Object { [int]$_.Key } |
                    Sort-Object
            )

            $passed = $passed -and
                ($defaultOrdinals.Count -eq 1) -and
                ($defaultOrdinals[0] -eq [int]$case.ExpectedTargetOrdinal)
        }

        $results += [pscustomobject][ordered]@{
            Case = $case.Name
            Passed = $passed
            ExpectedStatus = $case.ExpectedStatus
            ActualStatus = $actual.status
            ExpectedReason = $case.ExpectedReason
            ActualReason = $actual.reason
            Actions = $actions.Count
        }
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Reqestra Normalization Planner Self-Test"
Write-Host "========================================"
Write-Host ""
$results | Format-Table -AutoSize -Wrap

$failed = @($results | Where-Object { -not $_.Passed })
Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} normalization planner tests passed." -f $results.Count, $results.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} tests failed." -f $failed.Count, $results.Count)
$failed | Format-List *
exit 1
