[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ValidatorPath = Join-Path $PSScriptRoot "MediaValidator.ps1"
$PolicyPath = Join-Path $PSScriptRoot "validator-policy.json"

$validatorText = Get-Content -LiteralPath $ValidatorPath -Raw -Encoding UTF8
$policy = Get-Content -LiteralPath $PolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json

$results = @(
    [pscustomobject]@{ Test = "Validator version is 0.2.7"; Passed = ($validatorText -match '\$ValidatorVersion\s*=\s*"0\.2\.7"') },
    [pscustomobject]@{ Test = "Subtitle summaries expose default"; Passed = ($validatorText -match 'default\s*=\s*\(Get-DispositionValue \$subtitle "default"\)') },
    [pscustomobject]@{ Test = "Subtitle summaries expose forced"; Passed = ($validatorText -match 'forced\s*=\s*\(Get-DispositionValue \$subtitle "forced"\)') },
    [pscustomobject]@{ Test = "Subtitle summaries expose hearing-impaired"; Passed = ($validatorText -match 'hearingImpaired\s*=\s*\(Get-DispositionValue \$subtitle "hearing_impaired"\)') },
    [pscustomobject]@{ Test = "Image-only subtitles remain INFO"; Passed = ($validatorText -match 'Severity "INFO" -Code "subtitle\.image_only"') },
    [pscustomobject]@{ Test = "Unclassified subtitle codecs are INFO-only"; Passed = ($validatorText -match 'Severity "INFO" -Code "subtitle\.codec_unclassified"') },
    [pscustomobject]@{ Test = "Policy contains text subtitle codecs"; Passed = (@($policy.subtitles.textCodecs).Count -gt 0) },
    [pscustomobject]@{ Test = "Policy contains image subtitle codecs"; Passed = (@($policy.subtitles.imageCodecs).Count -gt 0) }
)

Write-Host ""
Write-Host "Reqestra MediaValidator Subtitle Policy Test"
Write-Host "============================================"
Write-Host ""
$results | Format-Table -AutoSize -Wrap

$failed = @($results | Where-Object { -not $_.Passed })
Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} subtitle policy contracts passed." -f $results.Count, $results.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} subtitle policy contracts failed." -f $failed.Count, $results.Count)
$failed | Format-List *
exit 1
