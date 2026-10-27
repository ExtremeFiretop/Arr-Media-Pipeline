[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Planner = Join-Path $Root "Integration\ReacquisitionPlanner.ps1"
$Temp = Join-Path $env:TEMP ("reqestra-legacy-id-test-"+[guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Temp -Force | Out-Null
try {
    $media = Join-Path $Temp "legacy.mkv"
    [IO.File]::WriteAllBytes($media, [byte[]](1..64))
    $context = [pscustomobject]@{
        source="Radarr"; libraryType="Movie"
        entity=[pscustomobject]@{id=123;title="Legacy";type="movie"}
        file=[pscustomobject]@{id=456;path=$media;quality="Bluray-2160p";sceneName=$null;releaseGroup=$null}
        release=[pscustomobject]@{downloadId=$null;title=$null;indexer=$null}
    }
    $validator=[pscustomobject]@{
        outcome="REACQUIRE"
        findings=@([pscustomobject]@{severity="REACQUIRE";code="video.dolby_vision";message="DV"})
        video=@([pscustomobject]@{codec="hevc";width=3840;height=2160;pixFmt="yuv420p10le";language="und";title=""})
        auxiliaryVideo=@();audio=@();subtitles=@()
    }
    $cp=Join-Path $Temp "context.json"; $vp=Join-Path $Temp "validator.json"; $op=Join-Path $Temp "plan.json"
    $context|ConvertTo-Json -Depth 20|Set-Content $cp -Encoding UTF8
    $validator|ConvertTo-Json -Depth 20|Set-Content $vp -Encoding UTF8
    & $Planner -ContextPath $cp -ValidatorResultPath $vp -JsonOut $op | Out-Null
    $plan=Get-Content $op -Raw -Encoding UTF8|ConvertFrom-Json
    $passed=([string]$plan.status -eq "PLANNED" -and [string]$plan.releaseIdentity.initialBlocklistMode -eq "SKIP_UNAVAILABLE_LEGACY_IDENTITY" -and -not [bool]$plan.releaseIdentity.initialBlocklistRequired)
    [pscustomobject]@{Test="legacy identity missing still plans";Passed=$passed;Status=$plan.status;Mode=$plan.releaseIdentity.initialBlocklistMode}|Format-Table -AutoSize
    if(-not $passed){throw "Legacy identity reacquisition planning regression failed."}
    Write-Host "PASS: legacy identity missing is safely planned without an initial exact blocklist."
}
finally { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
