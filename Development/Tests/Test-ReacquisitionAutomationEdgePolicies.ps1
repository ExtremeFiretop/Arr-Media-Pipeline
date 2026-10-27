[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Planner = Get-Content -LiteralPath (Join-Path $Root "Integration\ReacquisitionPlanner.ps1") -Raw -Encoding UTF8
$Worker = Get-Content -LiteralPath (Join-Path $Root "Integration\ReacquisitionWorker.ps1") -Raw -Encoding UTF8
$Quarantine = Get-Content -LiteralPath (Join-Path $Root "Integration\Invoke-ReacquisitionQuarantine.ps1") -Raw -Encoding UTF8
$SonarrQuarantine = Get-Content -LiteralPath (Join-Path $Root "Integration\Invoke-SonarrReacquisitionQuarantine.ps1") -Raw -Encoding UTF8
$checks = @(
    [pscustomobject]@{Name="legacy Radarr identity can skip initial blocklist";Passed=($Planner -match 'SKIP_UNAVAILABLE_LEGACY_IDENTITY')},
    [pscustomobject]@{Name="already blocklisted treated idempotently";Passed=($Worker -match 'current_release_already_blocklisted' -and $Worker -match '\$alreadyBlocked')},
    [pscustomobject]@{Name="candidate preflight retries three times";Passed=($Worker -match '\$candidateCheck=1; \$candidateCheck -le 3')},
    [pscustomobject]@{Name="no-candidate DV enters terminal local path";Passed=($Worker -match 'New-DirectTerminalDvChainFromPlan' -and $Worker -match 'Invoke-TerminalDvAutomation')},
    [pscustomobject]@{Name="non-DV no-candidate preserves file for review";Passed=($Worker -match 'no_viable_replacement_current_file_preserved')},
    [pscustomobject]@{Name="Radarr quarantine accepts explicit legacy blocklist skip";Passed=($Quarantine -match 'skippedForLegacyIdentity' -and $Quarantine -match 'SKIP_UNAVAILABLE_LEGACY_IDENTITY')},
    [pscustomobject]@{Name="Sonarr quarantine accepts explicit legacy blocklist skip";Passed=($SonarrQuarantine -match 'skippedForLegacyIdentity' -and $SonarrQuarantine -match 'SKIP_UNAVAILABLE_LEGACY_IDENTITY')}
)
$checks | Format-Table -AutoSize
$failed=@($checks|Where-Object{-not $_.Passed})
if($failed.Count -gt 0){throw ("Automation edge-policy regression failed: "+(($failed.Name)-join ', '))}
Write-Host ("PASS: {0}/{0} reacquisition automation edge-policy checks passed." -f $checks.Count)
