[CmdletBinding()]
param(
    [string]$ValidatorPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'MediaValidator.ps1'),
    [string]$MediaPath = 'M:\Movies\The Midnight Sky WEBDL-2160p (2020)\The Midnight Sky WEBDL-2160p.mkv'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tests = New-Object System.Collections.Generic.List[object]
function Add-Test {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    $tests.Add([pscustomobject]@{ Test = $Name; Passed = $Passed; Detail = $Detail })
}

if (-not (Test-Path -LiteralPath $ValidatorPath -PathType Leaf)) {
    throw "Validator not found: $ValidatorPath"
}

$text = Get-Content -LiteralPath $ValidatorPath -Raw
Add-Test 'ffprobe stdout is explicitly decoded as UTF-8' ($text -match '\$startInfo\.StandardOutputEncoding\s*=\s*\[System\.Text\.Encoding\]::UTF8')
Add-Test 'ffprobe stderr is explicitly decoded as UTF-8' ($text -match '\$startInfo\.StandardErrorEncoding\s*=\s*\[System\.Text\.Encoding\]::UTF8')
Add-Test 'Validator version is 0.2.9' ($text -match '(?m)^\$ValidatorVersion\s*=\s*"0\.2\.9"\s*$')

$executorPath = Join-Path (Split-Path $ValidatorPath -Parent) 'Integration\Invoke-Normalization.ps1'
if (Test-Path -LiteralPath $executorPath -PathType Leaf) {
    $executorText = Get-Content -LiteralPath $executorPath -Raw
    Add-Test 'stale-plan stream-layout safety gate still exists' ($executorText -match 'stale_plan_stream_layout_changed')
}
else {
    Add-Test 'stale-plan stream-layout safety gate still exists' $false 'Invoke-Normalization.ps1 not found'
}

if (Test-Path -LiteralPath $MediaPath -PathType Leaf) {
    $tempRoot = Join-Path $env:TEMP ('ReqestraUtf8ProbeTest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $json1 = Join-Path $tempRoot 'validator-1.json'
        $json2 = Join-Path $tempRoot 'validator-2.json'
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $validatorRoot = Split-Path $ValidatorPath -Parent
        $policyPath = Join-Path $validatorRoot 'validator-policy.json'

        if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
            throw "Validator policy not found: $policyPath"
        }

        foreach ($jsonOut in @($json1, $json2)) {
            $args = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', $ValidatorPath,
                '-Path', $MediaPath,
                '-LibraryType', 'Movie',
                '-PolicyPath', $policyPath,
                '-JsonOut', $jsonOut,
                '-OutputFormat', 'Json',
                '-ExitZero'
            )
            & $psExe @args | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Validator subprocess returned exit code $LASTEXITCODE"
            }
        }

        $a = Get-Content -LiteralPath $json1 -Raw -Encoding UTF8 | ConvertFrom-Json
        $b = Get-Content -LiteralPath $json2 -Raw -Encoding UTF8 | ConvertFrom-Json

        $aTitles = @($a.audio | ForEach-Object { [string]$_.title })
        $bTitles = @($b.audio | ForEach-Object { [string]$_.title })
        $sameTitles = (($aTitles | ConvertTo-Json -Compress) -eq ($bTitles | ConvertTo-Json -Compress))
        Add-Test 'Two independent validator runs produce identical audio titles' $sameTitles ((($aTitles -join ' | ') + ' <> ' + ($bTitles -join ' | ')))

        $expectedTitle = 'Inglés'
        $hasCorrectAccent = ($aTitles -contains $expectedTitle) -and ($bTitles -contains $expectedTitle)
        Add-Test 'Midnight Sky Spanish title decodes as Inglés' $hasCorrectAccent ($aTitles -join ' | ')
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
else {
    Add-Test 'Two independent validator runs produce identical audio titles' $false "Media file not found: $MediaPath"
    Add-Test 'Midnight Sky Spanish title decodes as Inglés' $false "Media file not found: $MediaPath"
}

Write-Host 'MediaValidator UTF-8 Probe Hotfix Test'
Write-Host '====================================='
Write-Host ''
$tests | Format-Table Test, Passed, Detail -AutoSize -Wrap

$passed = @($tests | Where-Object Passed).Count
$total = $tests.Count
Write-Host ''
if ($passed -eq $total) {
    Write-Host ("PASS: {0}/{1} UTF-8 probe hotfix checks passed." -f $passed, $total) -ForegroundColor Green
    exit 0
}

Write-Host ("FAIL: {0}/{1} UTF-8 probe hotfix checks passed." -f $passed, $total) -ForegroundColor Red
exit 1
