[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ValidatorPath = Join-Path $Root "MediaValidator.ps1"
$Source = Get-Content -LiteralPath $ValidatorPath -Raw -Encoding UTF8

$tests = @(
    [pscustomobject]@{
        Test = "PolicyPath parameter default no longer evaluates Join-Path during binding"
        Passed = (
            $Source -match '\[string\]\$PolicyPath\s*=\s*""' -and
            $Source -notmatch '\[string\]\$PolicyPath\s*=\s*\(Join-Path\s+\$PSScriptRoot'
        )
    },
    [pscustomobject]@{
        Test = "default policy path is resolved after parameter binding"
        Passed = (
            $Source -match '\[string\]::IsNullOrWhiteSpace\(\$PolicyPath\)' -and
            $Source -match '\$PolicyPath\s*=\s*Join-Path\s+\$RuntimeScriptRoot\s+"validator-policy\.json"'
        )
    },
    [pscustomobject]@{
        Test = "runtime script root has MyInvocation fallback"
        Passed = (
            $Source -match '\$RuntimeScriptRoot\s*=\s*\[string\]\$PSScriptRoot' -and
            $Source -match '\$MyInvocation\.MyCommand\.Path'
        )
    },
    [pscustomobject]@{
        Test = "validator version advanced for binding fix"
        Passed = ($Source -match '\$ValidatorVersion\s*=\s*"0\.2\.10"')
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} validator policy-path binding tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} validator policy-path binding tests failed." -f $failed.Count, $tests.Count)
exit 1
