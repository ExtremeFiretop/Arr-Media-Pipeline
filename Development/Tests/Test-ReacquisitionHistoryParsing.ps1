[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Reacquisition History Parsing Test"
Write-Host "==========================================="
Write-Host ""

function Get-PropertyValue {
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function ConvertTo-RecordArray {
    param($Response)

    if ($null -eq $Response) { return @() }

    $records = Get-PropertyValue -Object $Response -Name "records" -Default $null
    if ($null -ne $records) { return @($records) }

    return @($Response)
}

function Get-HistoryFileId {
    param($HistoryRecord)

    $data = Get-PropertyValue -Object $HistoryRecord -Name "data"
    if ($null -eq $data) { return 0 }

    $raw = Get-PropertyValue -Object $data -Name "fileId" -Default $null
    if ($null -eq $raw) {
        $raw = Get-PropertyValue -Object $data -Name "FileId" -Default $null
    }

    $parsed = 0
    if ([int]::TryParse([string]$raw, [ref]$parsed)) { return $parsed }
    return 0
}

$record = [pscustomobject]@{
    id = 101
    eventType = "downloadFolderImported"
    downloadId = "abc123"
    sourceTitle = "Example.Release"
    data = [pscustomobject]@{
        FileId = "8129"
        importedPath = "M:\Movies\Example\Example.mkv"
    }
}

$arrayResponse = @($record)
$pagedResponse = [pscustomobject]@{
    page = 1
    pageSize = 10
    totalRecords = 1
    records = @($record)
}

$arrayParsed = @(ConvertTo-RecordArray $arrayResponse)
$pagedParsed = @(ConvertTo-RecordArray $pagedResponse)

$tests = @(
    [pscustomobject]@{
        Test = "Raw history array is normalized"
        Passed = ($arrayParsed.Count -eq 1 -and $arrayParsed[0].id -eq 101)
    },
    [pscustomobject]@{
        Test = "Paged history .records is normalized"
        Passed = ($pagedParsed.Count -eq 1 -and $pagedParsed[0].id -eq 101)
    },
    [pscustomobject]@{
        Test = "History FileId is parsed"
        Passed = ((Get-HistoryFileId $record) -eq 8129)
    },
    [pscustomobject]@{
        Test = "Import event type is retained"
        Passed = ([string]::Equals($record.eventType, "downloadFolderImported", [System.StringComparison]::OrdinalIgnoreCase))
    }
)

$tests | Format-Table -AutoSize -Wrap

$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} reacquisition history parsing tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} history parsing tests failed." -f $failed.Count, $tests.Count)
exit 1
