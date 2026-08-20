<#
.SYNOPSIS 화면별로 나뉜 룰 실행 결과와 영상을 하나의 인수 폴더로 병합한다.
.DESCRIPTION 케이스·요약 통계를 재계산하고 Excel/영상 병합기를 호출하되 개별 원본 실행 폴더는 보존한다.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$BaseReportDir,
    [Parameter(Mandatory=$true)]
    [string[]]$OverrideReportDirs,
    [string]$OutputDir = "",
    [switch]$SkipExcel
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "modules\report-sanitization.ps1")
. (Join-Path $PSScriptRoot "modules\result-evaluator.ps1")

# 상대·절대 보고서 경로를 정규화하고 병합에 필요한 두 JSON 파일을 선검증한다.
function Resolve-ReportDir([string]$Path) {
    $full = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
    foreach ($file in @("summary.json", "case-results.json")) {
        if (-not (Test-Path -LiteralPath (Join-Path $full $file))) { throw "$full 폴더에서 $file 파일을 찾을 수 없습니다." }
    }
    $full
}

# 단일 실행의 case-results.json을 항상 행 배열로 반환한다.
function Read-ResultRows([string]$ReportDir) {
    $parsed = Get-Content -LiteralPath (Join-Path $ReportDir "case-results.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    @($parsed | ForEach-Object { $_ })
}

$baseDir = Resolve-ReportDir $BaseReportDir
$overrideDirs = @($OverrideReportDirs | ForEach-Object { Resolve-ReportDir $_ })
if (-not $OutputDir) { $OutputDir = Join-Path (Join-Path $root "reports") ("target-rule-merged-" + (Get-Date -Format "yyyyMMdd-HHmmss")) }
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
if (Test-Path -LiteralPath (Join-Path $OutputDir "case-results.json")) { throw "병합 출력 폴더에 기존 결과가 있습니다: $OutputDir" }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$screenshotsDir = Join-Path $OutputDir "screenshots"
New-Item -ItemType Directory -Force -Path $screenshotsDir | Out-Null

$baseSummary = Get-Content -LiteralPath (Join-Path $baseDir "summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$rowsByCase = @{}
$sourceByCase = @{}
$orderedCaseIds = New-Object Collections.Generic.List[string]
foreach ($row in @(Read-ResultRows $baseDir)) {
    if ($rowsByCase.ContainsKey([string]$row.caseId)) { throw "기본 결과에 중복 케이스 ID가 있습니다: $($row.caseId)" }
    $rowsByCase[[string]$row.caseId] = $row
    $sourceByCase[[string]$row.caseId] = $baseDir
    $orderedCaseIds.Add([string]$row.caseId)
}

$replacementCount = 0
$replacementRuns = New-Object Collections.Generic.List[object]
foreach ($overrideDir in $overrideDirs) {
    $replacedInRun = 0
    foreach ($row in @(Read-ResultRows $overrideDir)) {
        $caseId = [string]$row.caseId
        if (-not $rowsByCase.ContainsKey($caseId)) { throw "재실행 결과에 기본 데이터셋에 없는 케이스가 있습니다: $caseId" }
        $rowsByCase[$caseId] = $row
        $sourceByCase[$caseId] = $overrideDir
        $replacementCount++
        $replacedInRun++
    }
    $replacementRuns.Add([pscustomobject]@{ reportDir=$overrideDir; replacedCases=$replacedInRun })
}

$selected = New-Object Collections.Generic.List[object]
foreach ($caseId in $orderedCaseIds) {
    $row = $rowsByCase[$caseId]
    Protect-RuleReportedSensitiveValues $row
    $sourceDir = [string]$sourceByCase[$caseId]
    if ($row.screenshotPath) {
        $sourceScreenshot = Join-Path $sourceDir ([string]$row.screenshotPath)
        if (Test-Path -LiteralPath $sourceScreenshot) {
            $sourceRun = ([string]$row.runId -replace '[^A-Za-z0-9._-]', '_')
            $destinationName = "$($row.screenNumber)-$($row.caseId)-$sourceRun.png"
            Copy-Item -LiteralPath $sourceScreenshot -Destination (Join-Path $screenshotsDir $destinationName)
            $row.screenshotPath = "screenshots\$destinationName"
        }
    }
    $evidenceIndex = 0
    foreach ($item in @(@($row.controlTests) + @($row.popupObservations))) {
        if (-not $item -or -not $item.screenshotPath) { continue }
        $evidenceIndex++
        $sourceEvidence = Join-Path $sourceDir ([string]$item.screenshotPath)
        if (Test-Path -LiteralPath $sourceEvidence) {
            $extension = [IO.Path]::GetExtension($sourceEvidence)
            $destinationName = "$($row.screenNumber)-$($row.caseId)-evidence-$('{0:000}' -f $evidenceIndex)$extension"
            Copy-Item -LiteralPath $sourceEvidence -Destination (Join-Path $screenshotsDir $destinationName)
            $item.screenshotPath = "screenshots\$destinationName"
        }
    }
    $selected.Add($row)
}
$resultArray = $selected.ToArray()
$runId = "target-rule-merged-" + (Get-Date -Format "yyyyMMdd-HHmmss")
$cliProject = Join-Path $root 'src\HtsQa.Cli\HtsQa.Cli.csproj'
$compiledPlanPath = Join-Path $baseDir 'compiled-plan.json'
$mergeTestPackPath = if (Test-Path -LiteralPath $compiledPlanPath) { $compiledPlanPath } else { Join-Path $baseDir 'summary.json' }
$completedResults = @($resultArray | Where-Object { $_.PSObject.Properties.Name -contains 'testResult' -and $_.testResult } | ForEach-Object { $_.testResult })
$missingResultCases = @($resultArray | Where-Object { -not ($_.PSObject.Properties.Name -contains 'testResult') -or -not $_.testResult } | ForEach-Object {
    [pscustomobject]@{caseId=[string]$_.caseId;executed=$false;expectedResult=@{type='Success';description='Legacy merged row without completed TestResult';messagePatterns=@();errorCodes=@()};observations=@()}
})
$mergeEvaluationDocument = [pscustomobject]@{schemaVersion='1.0';testPackId=[string]$baseSummary.datasetId;aggregateId=$runId;cases=$missingResultCases;completedResults=$completedResults}
$mergeEvaluationOutput = Invoke-RuleResultEvaluation -CliProject $cliProject -TestPackPath $mergeTestPackPath -EvaluationDocument $mergeEvaluationDocument -WorkingDirectory (Join-Path $OutputDir 'result-evaluation') -InvocationId 'merge-summary'
$resultsByCase=@{}
foreach($testResult in @($mergeEvaluationOutput.results)){$resultsByCase[[string]$testResult.caseId]=$testResult}
foreach($row in $resultArray){$row | Add-Member -NotePropertyName testResult -NotePropertyValue $resultsByCase[[string]$row.caseId] -Force;$row.status=[string]$row.testResult.status}
$mergeEvaluationOutput | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDir 'test-results.json') -Encoding UTF8
$pass = [int]$mergeEvaluationOutput.summary.pass
$fail = [int]$mergeEvaluationOutput.summary.fail
$errorCount = [int]$mergeEvaluationOutput.summary.error
$pending = [int]$mergeEvaluationOutput.summary.pending
$status = [string]$mergeEvaluationOutput.overallResult.status

ConvertTo-Json -InputObject $resultArray -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDir "case-results.json") -Encoding UTF8
$resultArray | ForEach-Object {
    [pscustomobject]@{caseId=$_.caseId;screenNumber=$_.screenNumber;screenName=$_.screenName;discoveredControls=$_.discoveredControls;controlTests=$_.controlTests}
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDir "control-plan.json") -Encoding UTF8
[pscustomobject]@{
    runId=$runId
    datasetId=[string]$baseSummary.datasetId
    status=$status
    total=$resultArray.Count
    pass=$pass
    fail=$fail
    error=$errorCount
    pending=$pending
    dryRun=$false
    explicitErrorsDetected=@($resultArray | Where-Object errorDetected -eq $true).Count
    discoveredControls=@($resultArray | ForEach-Object { @($_.discoveredControls).Count } | Measure-Object -Sum).Sum
    controlTests=@($resultArray | ForEach-Object { @($_.controlTests).Count } | Measure-Object -Sum).Sum
    popupObservations=@($resultArray | ForEach-Object { @($_.popupObservations).Count } | Measure-Object -Sum).Sum
    executionMode="대상 화면 규칙 기반 전체 조작 병합 결과"
    inputMode="화면 기본값 또는 데이터셋 명시 입력"
    planner="결정론적 규칙"
    merged=$true
    replacementCount=$replacementCount
    finishedAt=(Get-Date).ToString("o")
    note="기본 전체 실행에 후속 재실행 결과를 케이스 ID 기준으로 적용했습니다. 각 행의 실행 ID가 실제 출처 실행을 나타냅니다."
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDir "summary.json") -Encoding UTF8

[pscustomobject]@{
    status="DONE"
    message="대상 화면 룰 기반 실행 결과를 병합했습니다."
    baseReportDir=$baseDir
    overrideRuns=$replacementRuns.ToArray()
    replacementCount=$replacementCount
    finalCaseCount=$resultArray.Count
    outputDir=$OutputDir
    finishedAt=(Get-Date).ToString("o")
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDir "병합내역.json") -Encoding UTF8

if (-not $SkipExcel) {
    & (Join-Path $PSScriptRoot "export-rule-results-xlsx.ps1") -ReportDir $OutputDir | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "병합 결과 엑셀 생성에 실패했습니다." }
}

Write-Output $OutputDir
