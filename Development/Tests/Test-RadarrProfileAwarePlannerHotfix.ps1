[CmdletBinding()]
param([string]$IntegrationRoot = $PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Planner = Join-Path $IntegrationRoot 'NormalizationPlanner.ps1'
if (-not (Test-Path -LiteralPath $Planner -PathType Leaf)) { throw "Planner missing: $Planner" }
$text = Get-Content -LiteralPath $Planner -Raw -Encoding UTF8

$tests = @(
    [pscustomobject]@{ Test='Planner version is 0.2.3'; Passed=($text -match '\$PlannerVersion\s*=\s*"0\.2\.3"') },
    [pscustomobject]@{ Test='Preferred-language existing-default preservation exists'; Passed=($text -match '\$preferredDefaults') },
    [pscustomobject]@{ Test='Legacy compatibility target exclusion exists'; Passed=($text -match 'Transcoded Compatibility Track') },
    [pscustomobject]@{ Test='Ambiguous preferred candidates still block'; Passed=($text -match 'multiple_preferred_audio_candidates') },
    [pscustomobject]@{ Test='No codec ranking added'; Passed=(-not ($text -match 'codecRank|bitrateRank|channelRank|truehd.*eac3.*dts')) },
    [pscustomobject]@{ Test='Stale-plan stream fingerprint remains present'; Passed=($text -match 'streamFingerprint') }
)

Write-Host 'Radarr Profile-Aware Planner Hotfix Test'
Write-Host '========================================'
$tests | Format-Table Test,Passed -AutoSize
$passed = @($tests | Where-Object Passed).Count
if ($passed -ne $tests.Count) { throw "FAIL: $passed/$($tests.Count) checks passed." }
Write-Host "`nPASS: $passed/$($tests.Count) planner hotfix checks passed." -ForegroundColor Green
