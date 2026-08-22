<#
.SYNOPSIS Verifies that an existing result JSON set can be rendered without mutating the source files.
.DESCRIPTION Copies top-level JSON files to an isolated temp directory, runs the reporter, and compares source SHA-256 hashes.
.INPUTS A result directory containing summary.json and case-results.json.
.OUTPUTS A read-only verification object with source contract, process result, workbook size, and hash comparison.
.NOTES Does not start HTS or FlaUI and deletes only its validated system-temp directory.
#>
param(
    [Parameter(Mandatory = $true)][string]$ReportDir,
    [switch]$RenderPreviews
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

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('hts-report-readonly-' + [guid]::NewGuid().ToString('N'))
$verification = $null
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $sourceFiles | Copy-Item -Destination $tempRoot

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
    if ($workbookExists) {
        $bytes = [IO.File]::ReadAllBytes($workbookPath)
        $workbookBytes = [Int64]$bytes.Length
        $zipSignatureValid = $bytes.Length -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and $bytes[2] -eq 0x03 -and $bytes[3] -eq 0x04
    }

    $summary = Get-Content -LiteralPath (Join-Path $reportFull 'summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $caseResultsDocument = Get-Content -LiteralPath (Join-Path $reportFull 'case-results.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $caseCount = if ($caseResultsDocument -is [System.Array]) {
        [int]$caseResultsDocument.Length
    } elseif ($caseResultsDocument.PSObject.Properties.Name -contains 'cases') {
        [int]@($caseResultsDocument.cases).Count
    } else {
        1
    }
    $canonicalSource = if (Test-Path -LiteralPath (Join-Path $reportFull 'test-results.json')) { 'test-results.json' } else { 'LEGACY_CASE_RESULTS_COMPATIBILITY' }
    $verification = [pscustomobject]@{
        schemaVersion = '1.0'
        readOnly = $true
        sourceJsonCount = [int]$sourceFiles.Count
        originalJsonChanged = [int]$changed.Count
        canonicalSource = $canonicalSource
        reportStatus = [string]$summary.status
        dryRun = [bool]$summary.dryRun
        caseCount = $caseCount
        flaUiActionAttempts = [int]$summary.flaUiActionAttempts
        flaUiActionSuccesses = [int]$summary.flaUiActionSuccesses
        nodeExitCode = [int]$nodeExitCode
        workbookExists = [bool]$workbookExists
        workbookBytes = $workbookBytes
        workbookZipSignatureValid = [bool]$zipSignatureValid
        previewFiles = [int]@(Get-ChildItem -LiteralPath $tempRoot -File -Filter '*.png' -ErrorAction SilentlyContinue).Count
    }

    if ($nodeExitCode -ne 0) { throw "REPORTER_PROCESS_FAILED: exit=$nodeExitCode" }
    if ($changed.Count -ne 0) { throw "SOURCE_JSON_MUTATED: $($changed -join ',')" }
    if (-not $workbookExists -or -not $zipSignatureValid) { throw 'WORKBOOK_OUTPUT_INVALID' }
}
finally {
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}

$verification
