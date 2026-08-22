<#
.SYNOPSIS Verifies that an existing result JSON set can be rendered without mutating the source files.
.DESCRIPTION Copies top-level JSON and optional referenced screenshots to temp, runs the reporter, and compares source SHA-256 hashes.
.INPUTS A result directory containing summary.json and case-results.json, plus an optional existing MP4 path.
.OUTPUTS A read-only verification object with source contract, workbook media count, MP4 signature, and hash comparison.
.NOTES Does not start HTS or FlaUI and deletes only its validated system-temp directory.
#>
param(
    [Parameter(Mandatory = $true)][string]$ReportDir,
    [switch]$RenderPreviews,
    [switch]$IncludeEvidenceMedia,
    [string]$VideoPath = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$reportFull = [IO.Path]::GetFullPath($ReportDir).TrimEnd('\')
foreach ($requiredName in @('summary.json', 'case-results.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $reportFull $requiredName) -PathType Leaf)) {
        throw "REQUIRED_REPORT_JSON_MISSING: $requiredName"
    }
}

$sourceFiles = @(Get-ChildItem -LiteralPath $reportFull -File -Filter '*.json' | Sort-Object Name)
$sourceHashes = @{}
foreach ($file in $sourceFiles) {
    $sourceHashes[$file.Name] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}

$caseResultsDocument = Get-Content -LiteralPath (Join-Path $reportFull 'case-results.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$caseItems = if ($caseResultsDocument -is [System.Array]) {
    [object[]]$caseResultsDocument
} elseif ($caseResultsDocument.PSObject.Properties.Name -contains 'cases') {
    [object[]]@($caseResultsDocument.cases)
} else {
    [object[]]@($caseResultsDocument)
}
$reportPrefix = $reportFull + '\'
$referencedScreenshotPaths = @($caseItems | ForEach-Object { [string]$_.screenshotPath } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
$screenshotFiles = @()
if ($IncludeEvidenceMedia) {
    foreach ($relativePath in $referencedScreenshotPaths) {
        $screenshotFull = [IO.Path]::GetFullPath((Join-Path $reportFull $relativePath))
        if (-not $screenshotFull.StartsWith($reportPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "SCREENSHOT_PATH_OUTSIDE_REPORT: $relativePath"
        }
        if (Test-Path -LiteralPath $screenshotFull -PathType Leaf) {
            $screenshotFiles += [pscustomobject]@{
                RelativePath = $relativePath
                FullName = $screenshotFull
                Sha256 = (Get-FileHash -LiteralPath $screenshotFull -Algorithm SHA256).Hash
            }
        }
    }
}

$videoFull = ''
$videoHashBefore = ''
$videoBytes = [Int64]0
$videoFtypValid = $false
if (-not [string]::IsNullOrWhiteSpace($VideoPath)) {
    $videoFull = [IO.Path]::GetFullPath($VideoPath)
    if (-not (Test-Path -LiteralPath $videoFull -PathType Leaf)) { throw 'VIDEO_FILE_MISSING' }
    $videoHashBefore = (Get-FileHash -LiteralPath $videoFull -Algorithm SHA256).Hash
    $videoBytes = [Int64](Get-Item -LiteralPath $videoFull).Length
    $stream = [IO.File]::OpenRead($videoFull)
    try {
        $header = New-Object byte[] 12
        [void]$stream.Read($header, 0, 12)
        $videoFtypValid = $header.Length -ge 8 -and [Text.Encoding]::ASCII.GetString($header, 4, 4) -eq 'ftyp'
    } finally {
        $stream.Dispose()
    }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('hts-report-readonly-' + [guid]::NewGuid().ToString('N'))
$verification = $null
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $sourceFiles | Copy-Item -Destination $tempRoot
    foreach ($screenshot in $screenshotFiles) {
        $destination = [IO.Path]::GetFullPath((Join-Path $tempRoot $screenshot.RelativePath))
        $tempPrefix = [IO.Path]::GetFullPath($tempRoot).TrimEnd('\') + '\'
        if (-not $destination.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "SCREENSHOT_DESTINATION_OUTSIDE_TEMP: $($screenshot.RelativePath)"
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $screenshot.FullName -Destination $destination
    }

    $reporter = Join-Path $root 'tools\build-rule-results-workbook.mjs'
    $arguments = @($reporter, $tempRoot, 'verified-existing-report.xlsx')
    if (-not $RenderPreviews) { $arguments += '--skip-previews' }
    & node @arguments | Out-Null
    $nodeExitCode = $LASTEXITCODE

    $changed = @()
    foreach ($file in $sourceFiles) {
        $currentHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if ($currentHash -ne $sourceHashes[$file.Name]) { $changed += $file.Name }
    }

    $workbookPath = Join-Path $tempRoot 'verified-existing-report.xlsx'
    $workbookExists = Test-Path -LiteralPath $workbookPath -PathType Leaf
    $zipSignatureValid = $false
    $workbookBytes = [Int64]0
    $embeddedWorkbookMedia = 0
    if ($workbookExists) {
        $bytes = [IO.File]::ReadAllBytes($workbookPath)
        $workbookBytes = [Int64]$bytes.Length
        $zipSignatureValid = $bytes.Length -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and $bytes[2] -eq 0x03 -and $bytes[3] -eq 0x04
        if ($IncludeEvidenceMedia -and $zipSignatureValid) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($workbookPath)
            try {
                $embeddedWorkbookMedia = [int]@($archive.Entries | Where-Object { $_.FullName -like 'xl/media/*' }).Count
            } finally {
                $archive.Dispose()
            }
        }
    }

    $summary = Get-Content -LiteralPath (Join-Path $reportFull 'summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $canonicalSource = if (Test-Path -LiteralPath (Join-Path $reportFull 'test-results.json')) { 'test-results.json' } else { 'LEGACY_CASE_RESULTS_COMPATIBILITY' }
    $mediaChanged = @($screenshotFiles | Where-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -ne $_.Sha256 }).Count
    $videoHashAfter = if ($videoFull) { (Get-FileHash -LiteralPath $videoFull -Algorithm SHA256).Hash } else { '' }
    if ($videoFull -and $videoHashAfter -ne $videoHashBefore) { $mediaChanged++ }
    $verification = [pscustomobject]@{
        schemaVersion = '1.0'
        readOnly = $true
        sourceJsonCount = [int]$sourceFiles.Count
        originalJsonChanged = [int]$changed.Count
        canonicalSource = $canonicalSource
        reportStatus = [string]$summary.status
        dryRun = [bool]$summary.dryRun
        caseCount = [int]$caseItems.Count
        flaUiActionAttempts = [int]$summary.flaUiActionAttempts
        flaUiActionSuccesses = [int]$summary.flaUiActionSuccesses
        nodeExitCode = [int]$nodeExitCode
        workbookExists = [bool]$workbookExists
        workbookBytes = $workbookBytes
        workbookZipSignatureValid = [bool]$zipSignatureValid
        previewFiles = [int]@(Get-ChildItem -LiteralPath $tempRoot -File -Filter '*.png' -ErrorAction SilentlyContinue).Count
        referencedScreenshots = [int]$referencedScreenshotPaths.Count
        copiedScreenshots = [int]$screenshotFiles.Count
        embeddedWorkbookMedia = [int]$embeddedWorkbookMedia
        originalMediaChanged = [int]$mediaChanged
        videoProvided = [bool]$videoFull
        videoBytes = $videoBytes
        videoFtypValid = [bool]$videoFtypValid
        videoSha256 = $videoHashBefore
    }

    if ($nodeExitCode -ne 0) { throw "REPORTER_PROCESS_FAILED: exit=$nodeExitCode" }
    if ($changed.Count -ne 0) { throw "SOURCE_JSON_MUTATED: $($changed -join ',')" }
    if (-not $workbookExists -or -not $zipSignatureValid) { throw 'WORKBOOK_OUTPUT_INVALID' }
    if ($IncludeEvidenceMedia -and $screenshotFiles.Count -ne $referencedScreenshotPaths.Count) { throw 'REFERENCED_SCREENSHOT_MISSING' }
    if ($IncludeEvidenceMedia -and $screenshotFiles.Count -gt 0 -and $embeddedWorkbookMedia -eq 0) { throw 'WORKBOOK_SCREENSHOT_NOT_EMBEDDED' }
    if ($mediaChanged -ne 0) { throw 'SOURCE_MEDIA_MUTATED' }
    if ($videoFull -and -not $videoFtypValid) { throw 'VIDEO_MP4_SIGNATURE_INVALID' }
}
finally {
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}

$verification
