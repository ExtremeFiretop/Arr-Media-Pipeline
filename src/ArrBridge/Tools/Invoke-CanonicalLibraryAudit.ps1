[CmdletBinding()]
param(
    [ValidateSet("Movies","TV","All")]
    [string]$Library = "All",

    [string]$MovieRoot = "M:\Movies",
    [string]$TvRoot = "V:\TV Shows",

    [string]$PolicyPath = "",
    [string]$StateRoot = "",

    [switch]$Fresh,
    [int]$ProgressEvery = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$IntegrationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ValidatorRoot = Split-Path -Parent $IntegrationRoot
$ValidatorPath = Join-Path $ValidatorRoot "MediaValidator.ps1"

if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
    $PolicyPath = Join-Path $ValidatorRoot "validator-policy.json"
}
if ([string]::IsNullOrWhiteSpace($StateRoot)) {
    $StateRoot = Join-Path $IntegrationRoot "Audit\canonical-current"
}

function Get-SafePropertyValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Get-PathKey {
    param([string]$Path)
    try { return ([System.IO.Path]::GetFullPath($Path)).ToLowerInvariant() }
    catch { return ([string]$Path).ToLowerInvariant() }
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-AuditContract {
    param(
        [string]$LibraryName,
        [string]$Root,
        [string]$LibraryType
    )

    return [pscustomobject][ordered]@{
        schemaVersion = "1.0"
        library = $LibraryName
        libraryType = $LibraryType
        rootKey = (Get-PathKey $Root)
        validatorPath = $ValidatorPath
        validatorSha256 = (Get-Sha256 $ValidatorPath)
        policyPath = $PolicyPath
        policySha256 = (Get-Sha256 $PolicyPath)
    }
}

function Assert-ResumeContract {
    param(
        [string]$ManifestPath,
        [string]$JsonlPath,
        $CurrentContract
    )

    $hasResults = (Test-Path -LiteralPath $JsonlPath -PathType Leaf) -and ((Get-Item -LiteralPath $JsonlPath).Length -gt 0)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        if ($hasResults) {
            throw "Existing audit results have no resume manifest. Re-run with -Fresh so the canonical state can be bound to the current validator and policy."
        }
        $CurrentContract | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
        return
    }

    $saved = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $mismatches = @()

    foreach ($name in @("library","libraryType","rootKey","validatorSha256","policySha256")) {
        $oldValue = [string](Get-SafePropertyValue $saved $name "")
        $newValue = [string](Get-SafePropertyValue $CurrentContract $name "")
        if ($oldValue -ne $newValue) {
            $mismatches += ("{0}: '{1}' -> '{2}'" -f $name,$oldValue,$newValue)
        }
    }

    if ($mismatches.Count -gt 0) {
        throw ("Audit resume contract changed. Use -Fresh to begin a new canonical audit under the current rules. " + ($mismatches -join "; "))
    }
}

function Get-VideoFiles {
    param([string]$Root)

    $extensions = @{
        ".mkv"=$true; ".mp4"=$true; ".m4v"=$true; ".avi"=$true;
        ".mov"=$true; ".wmv"=$true; ".ts"=$true; ".m2ts"=$true;
        ".mpg"=$true; ".mpeg"=$true; ".webm"=$true
    }

    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $extensions.ContainsKey($_.Extension.ToLowerInvariant()) }
    )
}

function Load-LatestRecords {
    param([string]$JsonlPath)

    $map = @{}
    if (-not (Test-Path -LiteralPath $JsonlPath -PathType Leaf)) { return $map }

    foreach ($line in [System.IO.File]::ReadLines($JsonlPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $record = $line | ConvertFrom-Json
            $path = [string](Get-SafePropertyValue $record "path" "")
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            $map[(Get-PathKey $path)] = $record
        }
        catch {
            # A partially-written final line after interruption is ignored.
        }
    }
    return $map
}

function Write-AuditSummary {
    param(
        [string]$LibraryName,
        [string]$Root,
        [hashtable]$Records,
        [int]$DiscoveredCount,
        [int]$AuditedThisRun,
        [int]$SkippedUnchanged,
        [int]$StaleRecordsIgnored,
        [string]$SummaryPath,
        [string]$CsvPath,
        [string]$StartedUtc,
        [bool]$Complete
    )

    $rows = @($Records.Values)
    $outcomeCounts = [ordered]@{ PASS=0; NORMALIZE=0; REVIEW=0; REACQUIRE=0; UNKNOWN=0 }
    $findingCounts = @{}
    $errorCount = 0

    foreach ($row in $rows) {
        $outcome = [string](Get-SafePropertyValue $row "outcome" "")
        if ($outcomeCounts.Contains($outcome)) { $outcomeCounts[$outcome]++ }
        else { $outcomeCounts["UNKNOWN"]++ }

        $err = [string](Get-SafePropertyValue $row "error" "")
        if (-not [string]::IsNullOrWhiteSpace($err)) { $errorCount++ }

        foreach ($code in @(Get-SafePropertyValue $row "findingCodes" @())) {
            $text = [string]$code
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            if (-not $findingCounts.ContainsKey($text)) { $findingCounts[$text] = 0 }
            $findingCounts[$text]++
        }
    }

    $findingRows = @(
        $findingCounts.GetEnumerator() |
            Sort-Object -Property @{Expression='Value';Descending=$true}, @{Expression='Name';Descending=$false} |
            ForEach-Object { [pscustomobject][ordered]@{ code=$_.Name; count=[int]$_.Value } }
    )

    $summary = [pscustomobject][ordered]@{
        schemaVersion = "1.0"
        generatedUtc = [DateTime]::UtcNow.ToString("o")
        startedUtc = $StartedUtc
        complete = $Complete
        library = $LibraryName
        root = $Root
        discoveredVideoFiles = $DiscoveredCount
        latestRecordCount = $rows.Count
        auditedThisRun = $AuditedThisRun
        skippedUnchangedThisRun = $SkippedUnchanged
        staleRecordsIgnored = $StaleRecordsIgnored
        errorCount = $errorCount
        outcomes = [pscustomobject]$outcomeCounts
        findings = $findingRows
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8

    $rows |
        Sort-Object path |
        Select-Object path,lengthBytes,lastWriteTimeUtc,libraryType,outcome,
            @{N="findingCodes";E={ @($_.findingCodes) -join ";" }},recordedUtc,error |
        Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8

    return $summary
}

function Invoke-OneLibraryAudit {
    param(
        [string]$LibraryName,
        [string]$Root,
        [ValidateSet("Movie","TV")][string]$LibraryType
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "$LibraryName root does not exist: $Root"
    }

    $slug = $LibraryName.ToLowerInvariant()
    $jsonlPath = Join-Path $StateRoot ("{0}-results.jsonl" -f $slug)
    $summaryPath = Join-Path $StateRoot ("{0}-summary.json" -f $slug)
    $csvPath = Join-Path $StateRoot ("{0}-latest.csv" -f $slug)
    $manifestPath = Join-Path $StateRoot ("{0}-manifest.json" -f $slug)
    $tempRoot = Join-Path $StateRoot ("temp-{0}" -f $slug)

    if ($Fresh) {
        Remove-Item -LiteralPath $jsonlPath,$summaryPath,$csvPath,$manifestPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    New-Item -ItemType Directory -Path $StateRoot,$tempRoot -Force | Out-Null

    $contract = Get-AuditContract -LibraryName $LibraryName -Root $Root -LibraryType $LibraryType
    Assert-ResumeContract -ManifestPath $manifestPath -JsonlPath $jsonlPath -CurrentContract $contract

    Write-Host ""
    Write-Host ("=== {0} CANONICAL AUDIT ===" -f $LibraryName.ToUpperInvariant())
    Write-Host "Root: $Root"
    Write-Host "Results: $jsonlPath"
    Write-Host "Mode: read-only / resumable"
    Write-Host ""

    $files = @(Get-VideoFiles -Root $Root)
    $records = Load-LatestRecords -JsonlPath $jsonlPath

    # JSONL is intentionally append-only, but the canonical summary must represent
    # only files that exist in the library now. Old records for moved/deleted files
    # remain in history and are excluded from the current in-memory view.
    $currentKeys = @{}
    foreach ($file in $files) { $currentKeys[(Get-PathKey $file.FullName)] = $true }
    $staleKeys = @($records.Keys | Where-Object { -not $currentKeys.ContainsKey($_) })
    foreach ($staleKey in $staleKeys) { $records.Remove($staleKey) }
    $staleRecordsIgnored = $staleKeys.Count

    $startedUtc = [DateTime]::UtcNow.ToString("o")
    $auditedThisRun = 0
    $skippedUnchanged = 0
    $processed = 0
    $complete = $false

    Write-Host ("Video files discovered: {0}" -f $files.Count)
    Write-Host ("Existing current records: {0}" -f $records.Count)
    Write-Host ("Stale historical records ignored: {0}" -f $staleRecordsIgnored)
    Write-Host ("Resume manifest: {0}" -f $manifestPath)

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $stream = New-Object -TypeName System.IO.FileStream -ArgumentList @($jsonlPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $writer = New-Object -TypeName System.IO.StreamWriter -ArgumentList @($stream, $utf8NoBom)
    $writer.AutoFlush = $true

    try {
        foreach ($file in $files) {
            $processed++
            $key = Get-PathKey $file.FullName
            $lastWrite = $file.LastWriteTimeUtc.ToString("o")
            $existing = if ($records.ContainsKey($key)) { $records[$key] } else { $null }

            if ($null -ne $existing -and
                [int64](Get-SafePropertyValue $existing "lengthBytes" -1) -eq [int64]$file.Length -and
                [string](Get-SafePropertyValue $existing "lastWriteTimeUtc" "") -eq $lastWrite) {
                $skippedUnchanged++
                if ($ProgressEvery -gt 0 -and (($processed % $ProgressEvery) -eq 0)) {
                    Write-Host ("Processed {0}/{1} | audited now {2} | resumed {3}" -f $processed,$files.Count,$auditedThisRun,$skippedUnchanged)
                }
                continue
            }

            $runId = [guid]::NewGuid().ToString("N")
            $validatorJson = Join-Path $tempRoot ($runId + ".json")
            $stdoutPath = Join-Path $tempRoot ($runId + ".stdout.txt")
            $stderrPath = Join-Path $tempRoot ($runId + ".stderr.txt")
            $errorText = $null
            $outcome = "REVIEW"
            $findingCodes = @("audit.validator_failed")

            try {
                $powerShellExe = Join-Path $PSHOME "powershell.exe"
                if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) { $powerShellExe = "powershell.exe" }

                $args = @(
                    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ValidatorPath,
                    $file.FullName,
                    "-LibraryType", $LibraryType,
                    "-PolicyPath", $PolicyPath,
                    "-JsonOut", $validatorJson,
                    "-OutputFormat", "Json",
                    "-ExitZero"
                )

                $argumentString = ($args | ForEach-Object {
                    $text = [string]$_
                    if ($text -match '[\s"]') { '"' + $text.Replace('"','\\"') + '"' } else { $text }
                }) -join ' '

                $p = Start-Process -FilePath $powerShellExe -ArgumentList $argumentString -Wait -PassThru -NoNewWindow `
                    -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

                if (-not (Test-Path -LiteralPath $validatorJson -PathType Leaf)) {
                    $stderrText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { "" }
                    throw "Validator produced no JSON. ExitCode=$($p.ExitCode). $stderrText"
                }

                $validator = Get-Content -LiteralPath $validatorJson -Raw -Encoding UTF8 | ConvertFrom-Json
                $outcome = [string](Get-SafePropertyValue $validator "outcome" "REVIEW")
                $findingCodes = @(
                    @(Get-SafePropertyValue $validator "findings" @()) |
                        ForEach-Object { [string](Get-SafePropertyValue $_ "code" "") } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )
            }
            catch {
                $errorText = $_.Exception.Message
                $outcome = "REVIEW"
                $findingCodes = @("audit.validator_failed")
            }
            finally {
                Remove-Item -LiteralPath $validatorJson,$stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue
            }

            $record = [pscustomobject][ordered]@{
                schemaVersion = "1.0"
                path = $file.FullName
                lengthBytes = [int64]$file.Length
                lastWriteTimeUtc = $lastWrite
                library = $LibraryName
                libraryType = $LibraryType
                outcome = $outcome
                findingCodes = @($findingCodes)
                recordedUtc = [DateTime]::UtcNow.ToString("o")
                error = $errorText
            }

            $writer.WriteLine(($record | ConvertTo-Json -Depth 6 -Compress))
            $records[$key] = $record
            $auditedThisRun++

            if ($ProgressEvery -gt 0 -and (($processed % $ProgressEvery) -eq 0)) {
                Write-Host ("Processed {0}/{1} | audited now {2} | resumed {3}" -f $processed,$files.Count,$auditedThisRun,$skippedUnchanged)
            }
        }
        $complete = $true
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }

        $summary = Write-AuditSummary -LibraryName $LibraryName -Root $Root -Records $records `
            -DiscoveredCount $files.Count -AuditedThisRun $auditedThisRun -SkippedUnchanged $skippedUnchanged `
            -StaleRecordsIgnored $staleRecordsIgnored -SummaryPath $summaryPath -CsvPath $csvPath -StartedUtc $startedUtc -Complete $complete

        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

        Write-Host ""
        Write-Host ("=== {0} SUMMARY ===" -f $LibraryName.ToUpperInvariant())
        $summary.outcomes | Format-List
        Write-Host ("Errors: {0}" -f $summary.errorCount)
        Write-Host ("Complete: {0}" -f $summary.complete)
        Write-Host "Summary: $summaryPath"
        Write-Host "Latest CSV: $csvPath"
        Write-Host ""
        Write-Host "Top findings:"
        @($summary.findings | Select-Object -First 20) | Format-Table -AutoSize
    }
}

if (-not (Test-Path -LiteralPath $ValidatorPath -PathType Leaf)) {
    throw "MediaValidator.ps1 was not found: $ValidatorPath"
}
if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
    throw "Validator policy was not found: $PolicyPath"
}

switch ($Library) {
    "Movies" { Invoke-OneLibraryAudit -LibraryName "Movies" -Root $MovieRoot -LibraryType "Movie" }
    "TV"     { Invoke-OneLibraryAudit -LibraryName "TV" -Root $TvRoot -LibraryType "TV" }
    "All" {
        Invoke-OneLibraryAudit -LibraryName "Movies" -Root $MovieRoot -LibraryType "Movie"
        Invoke-OneLibraryAudit -LibraryName "TV" -Root $TvRoot -LibraryType "TV"
    }
}
