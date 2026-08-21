<# .SYNOPSIS Verifies read-only artifact classification and conservative deletion boundaries. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$auditScript = Join-Path $root 'scripts\dev\audit-local-artifacts.ps1'

# 참 조건을 검증하고 회귀 assertion 수를 집계한다.
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_TRUE failed: $Message" }
    $script:assertions++
}

# 문자열로 정규화한 기대값과 실제값을 비교한다.
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) { throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'" }
    $script:assertions++
}

$script:assertions = 0
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('hts-artifact-retention-' + [guid]::NewGuid().ToString('N'))
$artifactRoot = Join-Path $tempRoot 'outputs'
try {
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
    '{}' | Set-Content -LiteralPath (Join-Path $artifactRoot 'sample.dataset.json') -Encoding UTF8
    '{}' | Set-Content -LiteralPath (Join-Path $artifactRoot 'summary.json') -Encoding UTF8
    '{}' | Set-Content -LiteralPath (Join-Path $artifactRoot 'other.json') -Encoding UTF8
    'trace' | Set-Content -LiteralPath (Join-Path $artifactRoot 'execution.ndjson') -Encoding UTF8
    [IO.File]::WriteAllBytes((Join-Path $artifactRoot 'screenshot.png'), [byte[]](1,2,3))
    [IO.File]::WriteAllBytes((Join-Path $artifactRoot 'full-run.mp4'), [byte[]](4,5,6))
    [IO.File]::WriteAllBytes((Join-Path $artifactRoot 'report.xlsx'), [byte[]](7,8,9))
    '' | Set-Content -LiteralPath (Join-Path $artifactRoot 'runner.stop') -Encoding ASCII
    [IO.File]::WriteAllBytes((Join-Path $artifactRoot 'unknown.bin'), [byte[]](10))
    $manualRoot = Join-Path $artifactRoot 'manual-testcases'
    New-Item -ItemType Directory -Path $manualRoot -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $manualRoot 'source.xlsx'), [byte[]](11,12))

    $json = & $auditScript -RepositoryRoot $tempRoot -ArtifactRoot $artifactRoot -IncludeFiles -AsJson
    $result = $json | ConvertFrom-Json
    $byName = @{}
    foreach ($item in @($result.files)) { $byName[[IO.Path]::GetFileName([string]$item.relativePath)] = $item }

    Assert-True ([bool]$result.readOnly) 'audit declares read-only behavior'
    Assert-Equal 10 $result.fileCount 'all fixture artifacts are inventoried'
    Assert-Equal 2 $result.deletionCandidateCount 'only derived report and runtime marker are deletion candidates'
    Assert-Equal 'PROTECTED_SOURCE_OR_APPROVAL' $byName['sample.dataset.json'].category 'dataset is protected'
    Assert-Equal 'CANONICAL_RUN_JSON' $byName['summary.json'].category 'summary is canonical JSON'
    Assert-Equal 'PENDING_REVIEW' $byName['other.json'].disposition 'unknown JSON is not deleted'
    Assert-Equal 'RAW_EXECUTION_EVIDENCE' $byName['execution.ndjson'].category 'raw trace requires review'
    Assert-Equal 'SENSITIVE_MEDIA_EVIDENCE' $byName['screenshot.png'].category 'screenshot is sensitive evidence'
    Assert-Equal 'SENSITIVE_MEDIA_EVIDENCE' $byName['full-run.mp4'].category 'video is sensitive evidence'
    Assert-Equal 'DELETE_CANDIDATE_AFTER_JSON_CHECK' $byName['report.xlsx'].disposition 'derived workbook needs canonical JSON check'
    Assert-Equal 'DELETE_CANDIDATE_AFTER_PROCESS_CHECK' $byName['runner.stop'].disposition 'runtime marker needs process check'
    Assert-Equal 'PENDING_REVIEW' $byName['unknown.bin'].disposition 'unknown file stays pending'
    Assert-Equal 'PROTECTED_SOURCE_OR_APPROVAL' $byName['source.xlsx'].category 'manual testcase workbook is protected'

    $outside = Join-Path ([IO.Path]::GetTempPath()) ('outside-' + [guid]::NewGuid().ToString('N'))
    $outsideBlocked = $false
    try { & $auditScript -RepositoryRoot $tempRoot -ArtifactRoot $outside | Out-Null } catch { $outsideBlocked = $_.Exception.Message -like 'ARTIFACT_ROOT_OUTSIDE_REPOSITORY:*' }
    Assert-True $outsideBlocked 'artifact root outside repository is rejected'
    Write-Output "ARTIFACT_RETENTION_TESTS=PASS assertions=$script:assertions"
}
finally {
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    if ($resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
