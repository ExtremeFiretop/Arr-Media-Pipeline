[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Reacquisition Timestamp Precision Test"
Write-Host "==============================================="
Write-Host ""

function Floor-ToSecondUtc {
    param([DateTime]$Value)

    $utc = $Value.ToUniversalTime()
    return $utc.AddTicks(-($utc.Ticks % [TimeSpan]::TicksPerSecond))
}

$attemptStart = [DateTime]::Parse(
    "2026-10-25T03:26:15.6917749Z",
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::RoundtripKind
).ToUniversalTime()

$correctEvent = [DateTime]::Parse(
    "2026-10-25T03:26:15Z",
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::RoundtripKind
).ToUniversalTime()

$oldWrongEvent = [DateTime]::Parse(
    "2026-10-25T03:21:16Z",
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::RoundtripKind
).ToUniversalTime()

$threshold = Floor-ToSecondUtc $attemptStart

$tests = @(
    [pscustomobject]@{
        Test = "Attempt timestamp floors to Radarr second precision"
        Passed = ($threshold.ToString("o") -eq "2026-10-25T03:26:15.0000000Z")
    },
    [pscustomobject]@{
        Test = "Same-second Radarr event is accepted"
        Passed = ($correctEvent -ge $threshold)
    },
    [pscustomobject]@{
        Test = "Earlier wrong-target event remains excluded"
        Passed = (-not ($oldWrongEvent -ge $threshold))
    },
    [pscustomobject]@{
        Test = "Unfloored comparison demonstrates original false negative"
        Passed = (-not ($correctEvent -ge $attemptStart))
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} reacquisition timestamp-precision tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} reacquisition timestamp-precision tests failed." -f $failed.Count, $tests.Count)
exit 1
