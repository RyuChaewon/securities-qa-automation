<#
.SYNOPSIS 실행 결과 JSON을 한국어 Excel 통합문서로 변환한다.
.DESCRIPTION 번들 Node와 artifact-tool을 사용하며 원본 JSON은 수정하지 않고 미리보기·검사 결과를 함께 생성한다.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ReportDir,
    [string]$OutputFileName = "",
    [string]$NodePath = "",
    [string]$NodeModulesPath = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$ReportDir = [IO.Path]::GetFullPath($ReportDir)
if (-not (Test-Path -LiteralPath (Join-Path $ReportDir "summary.json"))) { throw "$ReportDir 폴더에서 summary.json을 찾을 수 없습니다." }
if (-not (Test-Path -LiteralPath (Join-Path $ReportDir "case-results.json"))) { throw "$ReportDir 폴더에서 case-results.json을 찾을 수 없습니다." }
$summary = Get-Content -LiteralPath (Join-Path $ReportDir "summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $OutputFileName) {
    $datasetLabel = ([string]$summary.datasetId -replace '[<>:"/\\|?*]', '-' -replace '\s+', '-').Trim('-')
    $runLabel = ([string]$summary.runId -replace '[<>:"/\\|?*]', '-' -replace '\s+', '-').Trim('-')
    if (-not $datasetLabel) { $datasetLabel = "dataset" }
    if (-not $runLabel) { $runLabel = "run-" + (Get-Date -Format "yyyyMMdd-HHmmss") }
    $OutputFileName = "테스트결과-$datasetLabel-$runLabel.xlsx"
}

if (-not $NodePath) {
    $bundledNode = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
    if (Test-Path -LiteralPath $bundledNode) { $NodePath = $bundledNode }
    else { $NodePath = (Get-Command node -ErrorAction Stop).Source }
}
if (-not $NodeModulesPath) {
    if ($env:HTS_QA_NODE_MODULES) { $NodeModulesPath = $env:HTS_QA_NODE_MODULES }
    else { $NodeModulesPath = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\node_modules" }
}
if (-not (Test-Path -LiteralPath $NodePath)) { throw "Node.js 실행 파일을 찾을 수 없습니다: $NodePath" }
if (-not (Test-Path -LiteralPath (Join-Path $NodeModulesPath "@oai\artifact-tool"))) { throw "$NodeModulesPath 아래에서 @oai/artifact-tool을 찾을 수 없습니다." }

$junction = Join-Path $root "tools\node_modules"
if (-not (Test-Path -LiteralPath $junction)) {
    New-Item -ItemType Junction -Path $junction -Target $NodeModulesPath | Out-Null
}
$item = Get-Item -LiteralPath $junction
if (-not $item.LinkType) { throw "$junction 경로가 존재하지만 의존성 정션이 아닙니다." }

$outputPath = Join-Path $ReportDir $OutputFileName
& $NodePath (Join-Path $root "tools\build-rule-results-workbook.mjs") $ReportDir $OutputFileName
# artifact-tool 호스트가 LASTEXITCODE를 공백 객체로 돌려줄 수 있어 최종 XLSX의 실재와 크기로 성공을 판정한다.
if (-not (Test-Path -LiteralPath $outputPath) -or (Get-Item -LiteralPath $outputPath).Length -le 0) {
    throw "통합문서 생성기가 유효한 XLSX 파일을 만들지 못했습니다."
}
Write-Output $outputPath
