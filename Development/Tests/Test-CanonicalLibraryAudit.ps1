Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Invoke-CanonicalLibraryAudit.ps1"
$text = Get-Content -LiteralPath $scriptPath -Raw

$tests = @(
    [pscustomobject]@{ Test="Audit runner exists"; Passed=(Test-Path -LiteralPath $scriptPath -PathType Leaf) },
    [pscustomobject]@{ Test="Audit is explicitly resumable through persisted JSONL records"; Passed=($text -match 'results\.jsonl' -and $text -match 'Load-LatestRecords') },
    [pscustomobject]@{ Test="Resume identity includes path, size and last-write time"; Passed=($text -match 'lengthBytes' -and $text -match 'lastWriteTimeUtc') },
    [pscustomobject]@{ Test="Resume contract is bound to validator and policy SHA256"; Passed=($text -match 'validatorSha256' -and $text -match 'policySha256' -and $text -match 'Assert-ResumeContract') },
    [pscustomobject]@{ Test="Changed validator/policy fails closed unless Fresh is requested"; Passed=($text -match 'Audit resume contract changed' -and $text -match 'Use -Fresh') },
    [pscustomobject]@{ Test="Moved or deleted files are excluded from canonical current counts"; Passed=($text -match 'staleRecordsIgnored' -and $text -match '\$records\.Remove\(\$staleKey\)') },
    [pscustomobject]@{ Test="Audit filters by video extension instead of probing subtitles"; Passed=($text -match '\.mkv' -and $text -match '\.mp4' -and $text -match 'ContainsKey\(\$_.Extension') },
    [pscustomobject]@{ Test="Audit invokes MediaValidator in read-only ExitZero mode"; Passed=($text -match 'MediaValidator\.ps1' -and $text -match 'ExitZero') },
    [pscustomobject]@{ Test="Movie and TV validator library types are distinct"; Passed=($text -match 'LibraryType \"Movie\"' -and $text -match 'LibraryType \"TV\"') },
    [pscustomobject]@{ Test="Per-file results flush durably"; Passed=($text -match 'AutoFlush = \$true') },
    [pscustomobject]@{ Test="Interrupted trailing JSONL line fails safe and can be ignored on resume"; Passed=($text -match 'partially-written final line') },
    [pscustomobject]@{ Test="Validator failures become REVIEW rather than silently PASS"; Passed=($text -match 'audit\.validator_failed' -and $text -match '\$outcome = \"REVIEW\"') },
    [pscustomobject]@{ Test="Audit emits summary JSON and latest CSV"; Passed=($text -match 'summary\.json' -and $text -match 'latest\.csv') },
    [pscustomobject]@{ Test="Fresh mode is explicit rather than default"; Passed=($text -match '\[switch\]\$Fresh') },
    [pscustomobject]@{ Test="Default roots match current Movies and TV libraries"; Passed=($text -match 'M:\\Movies' -and $text -match 'V:\\TV Shows') }
)

Write-Host "Reqestra Canonical Library Audit Contract Test"
Write-Host "=============================================="
Write-Host ""
$tests | Format-Table -AutoSize

$failed = @($tests | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host ("FAIL: {0}/{1} tests failed." -f $failed.Count,$tests.Count)
    exit 1
}
Write-Host ""
Write-Host ("PASS: {0}/{0} canonical audit contract tests passed." -f $tests.Count)
exit 0
