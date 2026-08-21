<#
.SYNOPSIS outputs 아래 로컬 산출물을 삭제 없이 분류하고 보존 상태를 집계한다.
.DESCRIPTION Git 추적 원본, canonical JSON, 민감 증거, 파생 보고서, 런타임 marker와 미분류 파일을 구분한다.
.INPUTS 저장소 루트와 그 안의 산출물 루트. 기본값은 현재 저장소의 outputs 폴더다.
.OUTPUTS 분류별 파일 수와 바이트 수, 선택적으로 상대 경로만 포함한 JSON 또는 PowerShell 객체.
.NOTES 파일을 이동·수정·삭제하지 않으며 절대 로컬 경로를 출력하지 않는다.
#>
param(
    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$ArtifactRoot = '',
    [switch]$IncludeFiles,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$repositoryFull = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $ArtifactRoot = Join-Path $repositoryFull 'outputs'
}
$artifactFull = [IO.Path]::GetFullPath($ArtifactRoot).TrimEnd('\')
$repositoryPrefix = $repositoryFull + '\'
if (-not ($artifactFull + '\').StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "ARTIFACT_ROOT_OUTSIDE_REPOSITORY: $ArtifactRoot"
}

# 상대 경로와 추적 여부만으로 삭제 없는 보존 분류를 결정한다.
function Get-HtsArtifactClassification {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][bool]$Tracked
    )

    $normalized = $RelativePath.Replace('\', '/')
    $name = [IO.Path]::GetFileName($normalized)
    $extension = [IO.Path]::GetExtension($name).ToLowerInvariant()

    if ($Tracked) {
        return [pscustomobject]@{ category = 'TRACKED_SOURCE'; disposition = 'KEEP'; reason = 'Git 추적 원본 또는 승인 파일' }
    }
    if ($normalized -match '(?i)(^|/)([^/]*(manual|testcases?)[^/]*|archive|report-template)(/|$)' -or
        $name -match '(?i)\.dataset\.json$|approval.*\.json$|source.*\.(xlsx|xlsm)$') {
        return [pscustomobject]@{ category = 'PROTECTED_SOURCE_OR_APPROVAL'; disposition = 'KEEP'; reason = '원본 Dataset, 승인 또는 수동 보존 자료' }
    }
    if ($name -match '(?i)^(summary|case-results|test-results|observations|expanded-cases|compiled-plan|physical-plan|binding-catalog|control-plan)\.json$') {
        return [pscustomobject]@{ category = 'CANONICAL_RUN_JSON'; disposition = 'KEEP_UNTIL_REVIEW'; reason = '리포트와 재현의 기준 JSON' }
    }
    if ($extension -in @('.png', '.jpg', '.jpeg', '.bmp', '.gif', '.mp4', '.avi', '.mov')) {
        return [pscustomobject]@{ category = 'SENSITIVE_MEDIA_EVIDENCE'; disposition = 'REVIEW_BEFORE_DELETE'; reason = '화면·계좌·로컬 환경 정보가 포함될 수 있는 증거' }
    }
    if ($extension -in @('.ndjson', '.log', '.txt')) {
        return [pscustomobject]@{ category = 'RAW_EXECUTION_EVIDENCE'; disposition = 'REVIEW_BEFORE_DELETE'; reason = '실행 추적 또는 원시 로그' }
    }
    if ($extension -in @('.xlsx', '.xlsm')) {
        return [pscustomobject]@{ category = 'DERIVED_REPORT'; disposition = 'DELETE_CANDIDATE_AFTER_JSON_CHECK'; reason = 'canonical JSON에서 재생성 가능한 파생 보고서' }
    }
    if ($extension -in @('.start', '.stop', '.pid')) {
        return [pscustomobject]@{ category = 'RUNTIME_MARKER'; disposition = 'DELETE_CANDIDATE_AFTER_PROCESS_CHECK'; reason = '종료된 로컬 프로세스의 재생성 가능한 marker' }
    }
    if ($extension -eq '.json') {
        return [pscustomobject]@{ category = 'OTHER_JSON'; disposition = 'PENDING_REVIEW'; reason = '원본·중간물 여부를 자동 판별할 수 없는 JSON' }
    }
    return [pscustomobject]@{ category = 'UNKNOWN'; disposition = 'PENDING_REVIEW'; reason = '재생성 가능성을 자동 판별할 수 없음' }
}

$tracked = @{}
if (Test-Path -LiteralPath (Join-Path $repositoryFull '.git')) {
    $artifactRelative = $artifactFull.Substring($repositoryFull.Length).TrimStart('\').Replace('\', '/')
    $safeDirectory = $repositoryFull.Replace('\', '/')
    $trackedOutput = @(& git -c "safe.directory=$safeDirectory" ls-files -- $artifactRelative)
    if ($LASTEXITCODE -ne 0) {
        throw "GIT_TRACKED_FILE_QUERY_FAILED: exit=$LASTEXITCODE"
    }
    foreach ($path in $trackedOutput) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $tracked[[string]$path.Replace('\', '/')] = $true
        }
    }
}

$items = @()
if (Test-Path -LiteralPath $artifactFull -PathType Container) {
    foreach ($file in Get-ChildItem -LiteralPath $artifactFull -Recurse -File -Force) {
        $relative = $file.FullName.Substring($repositoryFull.Length).TrimStart('\').Replace('\', '/')
        $classification = Get-HtsArtifactClassification -RelativePath $relative -Tracked $tracked.ContainsKey($relative)
        $items += [pscustomobject]@{
            relativePath = $relative
            bytes = [Int64]$file.Length
            lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
            category = $classification.category
            disposition = $classification.disposition
            reason = $classification.reason
        }
    }
}

$groups = @($items | Group-Object category, disposition | ForEach-Object {
    [pscustomobject]@{
        category = [string]$_.Group[0].category
        disposition = [string]$_.Group[0].disposition
        fileCount = [int]$_.Count
        totalBytes = [Int64](($_.Group | Measure-Object bytes -Sum).Sum)
    }
} | Sort-Object category)

$result = [ordered]@{
    schemaVersion = '1.0'
    artifactRoot = $artifactFull.Substring($repositoryFull.Length).TrimStart('\').Replace('\', '/')
    readOnly = $true
    fileCount = [int]$items.Count
    totalBytes = [Int64](($items | Measure-Object bytes -Sum).Sum)
    deletionCandidateCount = [int]@($items | Where-Object { $_.disposition -like 'DELETE_CANDIDATE_*' }).Count
    groups = $groups
}
if ($IncludeFiles) {
    $result.files = @($items | Sort-Object relativePath)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
} else {
    [pscustomobject]$result
}
