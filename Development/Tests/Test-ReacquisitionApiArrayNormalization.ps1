[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Reacquisition API Array Normalization Test"
Write-Host "==================================================="
Write-Host ""

function Get-RecordArray {
    param($Response)

    if ($null -eq $Response) { return @() }

    $recordsProperty = $Response.PSObject.Properties["records"]
    if ($null -ne $recordsProperty) {
        return @($recordsProperty.Value)
    }

    return @($Response)
}

function Get-PropertyValue {
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }

    return $property.Value
}

function Test-DiskOnlyRejection {
    param($Release)

    if ([bool](Get-PropertyValue -Object $Release -Name "approved" -Default $false)) {
        return $false
    }

    $rejections = @(
        Get-PropertyValue -Object $Release -Name "rejections" -Default @()
    )

    $patterns = @(
        '^Existing file on disk is of equal or higher preference:',
        '^Existing file on disk is of equal or higher revision:',
        '^Existing file on disk has a equal or higher Custom Format score:',
        '^Existing file on disk has Custom Format score within Custom Format score increment:',
        '^Existing file on disk meets quality cutoff:',
        '^Existing file on disk meets Custom Format cutoff:',
        '^Existing file meets cutoff:',
        "^Existing file on disk and Quality Profile '.*' does not allow upgrades$"
    )

    if ($rejections.Count -eq 0) { return $false }

    foreach ($rejection in $rejections) {
        $matched = $false
        foreach ($pattern in $patterns) {
            if ([string]$rejection -match $pattern) {
                $matched = $true
                break
            }
        }

        if (-not $matched) { return $false }
    }

    return $true
}

$releaseArray = @(
    [pscustomobject]@{
        title = "Release A"
        approved = $false
        rejections = @(
            "Existing file on disk is of equal or higher revision: v2"
        )
    },
    [pscustomobject]@{
        title = "Release B"
        approved = $false
        rejections = @(
            "Existing file on disk is of equal or higher preference: Bluray-2160p v2"
        )
    },
    [pscustomobject]@{
        title = "Release C"
        approved = $false
        rejections = @(
            "Custom Formats Dolby Vision - Block All have score -10000 below Movie's profile minimum 0"
        )
    },
    [pscustomobject]@{
        title = "Release D"
        approved = $false
        rejections = @(
            "Existing file meets cutoff: WEB 2160p (WEBRip-2160p, WEBDL-2160p) [Multi Language, x265 (UHD Preferred)]"
        )
    },
    [pscustomobject]@{
        title = "Release E"
        approved = $false
        rejections = @(
            "Existing file meets cutoff: WEB 2160p (WEBRip-2160p, WEBDL-2160p) [Multi Language, x265 (UHD Preferred)]",
            "Custom Formats Dolby Vision - Block All have score -10000 below Movie's profile minimum 0"
        )
    }
)

$normalized = @(Get-RecordArray -Response $releaseArray)
$diskOnly = @(
    $normalized |
        Where-Object { Test-DiskOnlyRejection -Release $_ }
)

$paged = [pscustomobject]@{
    records = $releaseArray
}
$normalizedPaged = @(Get-RecordArray -Response $paged)

$tests = @(
    [pscustomobject]@{
        Test = "Raw release array normalizes to individual records"
        Passed = ($normalized.Count -eq 5)
    },
    [pscustomobject]@{
        Test = "Disk-only classifier sees individual release objects"
        Passed = ($diskOnly.Count -eq 3)
    },
    [pscustomobject]@{
        Test = "Non-disk rejection remains excluded"
        Passed = (@($diskOnly | Where-Object title -eq "Release C").Count -eq 0)
    },
    [pscustomobject]@{
        Test = "Cutoff plus non-disk rejection remains excluded"
        Passed = (@($diskOnly | Where-Object title -eq "Release E").Count -eq 0)
    },
    [pscustomobject]@{
        Test = "Paged .records response normalizes identically"
        Passed = ($normalizedPaged.Count -eq 5)
    },
    [pscustomobject]@{
        Test = "Per-release properties survive normalization"
        Passed = ($normalized[0].title -eq "Release A")
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} API array-normalization tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} API array-normalization tests failed." -f $failed.Count, $tests.Count)
exit 1
