<# .SYNOPSIS TC_ID 중심 실행결과를 별도 Excel 보고서로 만든다. #>
param(
    [Parameter(Mandatory=$true)][string]$ReportDir,
    [string]$OutputFileName = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$ReportDir = [IO.Path]::GetFullPath($ReportDir)
if (-not (Test-Path -LiteralPath (Join-Path $ReportDir "case-results.json"))) { throw "case-results.json을 찾을 수 없습니다." }
$summary = if (Test-Path -LiteralPath (Join-Path $ReportDir "summary.json")) { Get-Content -LiteralPath (Join-Path $ReportDir "summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
if (-not $OutputFileName) {
    $runLabel = if ($summary -and $summary.runId) { ([string]$summary.runId -replace '[<>:"/\\|?*]','-') } else { Get-Date -Format "yyyyMMdd-HHmmss" }
    $OutputFileName = "TC-results-$runLabel.xlsx"
}
$node = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
$nodeModules = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\node_modules"
if (-not (Test-Path -LiteralPath $node)) { throw "번들 Node.js를 찾을 수 없습니다." }
if (-not (Test-Path -LiteralPath (Join-Path $nodeModules "@oai\artifact-tool"))) { throw "번들 artifact-tool을 찾을 수 없습니다." }
$junction = Join-Path $root "tools\node_modules"
if (-not (Test-Path -LiteralPath $junction)) { New-Item -ItemType Junction -Path $junction -Target $nodeModules | Out-Null }
$outputPath = Join-Path $ReportDir $OutputFileName
& $node (Join-Path $root "tools\build-tc-results-workbook.mjs") $ReportDir $OutputFileName
if (-not (Test-Path -LiteralPath $outputPath) -or (Get-Item -LiteralPath $outputPath).Length -le 0) { throw "TC 실행결과 XLSX 생성에 실패했습니다." }
Write-Output $outputPath
