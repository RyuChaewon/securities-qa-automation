<#
.SYNOPSIS 0101 물리 바인딩 1.1의 실행 가능한 시나리오를 TC_ID 기준으로 관리자 권한 녹화 검증한다.
.DESCRIPTION 기본값은 비거래 검증이며 명시적 옵션으로 승인된 테스트 계좌의 거래 확인창까지 제출할 수 있다.
#>
param(
    [string]$SuiteDir = "",
    [string]$CaseIdsCsv = '',
    [string]$SourceTestCaseIdsCsv = '0101-CMD-0901,0101-CTL-0101',
    [int]$MaxCases = 1,
    [string]$CompiledPlanPath = '',
    [switch]$SubmitTransactionalDialogs
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $SuiteDir) {
    $SuiteDir = Join-Path $root ("outputs\0101_automation\live-validation-v2-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

if (-not $CompiledPlanPath) {
    $CompiledPlanPath = Join-Path $root 'outputs\0101_automation\representative-plan\compiled-plan.json'
}
$compiledPlanPath = if ([IO.Path]::IsPathRooted($CompiledPlanPath)) { $CompiledPlanPath } else { Join-Path $root $CompiledPlanPath }
if (-not (Test-Path -LiteralPath $compiledPlanPath -PathType Leaf)) {
    throw "컴파일 계획을 찾을 수 없습니다: $compiledPlanPath"
}
if (-not $CaseIdsCsv) {
    $requestedTcIds = @($SourceTestCaseIdsCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($requestedTcIds.Count -eq 0) { throw '실행할 TC_ID 또는 Case ID가 필요합니다.' }
    $compiledPlan = Get-Content -LiteralPath $compiledPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $selectedCases = @($compiledPlan.cases | Where-Object { $requestedTcIds -contains [string]$_.sourceTestCaseId })
    $missingTcIds = @($requestedTcIds | Where-Object { $selectedCases.sourceTestCaseId -notcontains $_ })
    if ($missingTcIds.Count -gt 0) { throw "컴파일 계획에 없는 TC_ID입니다: $($missingTcIds -join ', ')" }
    $CaseIdsCsv = @($selectedCases.caseId) -join ','
    $MaxCases = [Math]::Max($MaxCases, $selectedCases.Count)
}

$runner = Join-Path $PSScriptRoot 'run-target-rule-suite-recorded.ps1'
$runArguments = @{
    DatasetPath = Join-Path $root 'outputs\0101_automation\0101.dataset.json'
    ScenarioPlanPath = $compiledPlanPath
    RefreshPhysicalPlanBeforeRun = $true
    AllowPartialScenarioPlan = $true
    ReuseExistingTargetScreen = $true
    PreserveTargetScreenAfterRun = $true
    VisiblePointerMotion = $true
    PointerDwellMilliseconds = 800
    ShowCursor = $true
    CaseIdsCsv = $CaseIdsCsv
    MaxCases = $MaxCases
    MaxDurationSeconds = 600
    ActionTimeoutSeconds = 480
    Fps = 4
    AllowElevatedActionPrompt = $true
    SuiteDir = $SuiteDir
}
if ($SubmitTransactionalDialogs) { $runArguments.SubmitTransactionalDialogs = $true }
& $runner @runArguments

$completionFile = @(Get-ChildItem -LiteralPath $SuiteDir -Filter '*.json' -File | Where-Object {
    try {
        $candidate = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $candidate.PSObject.Properties.Name -contains 'pipelineCompleted' -and
            $candidate.PSObject.Properties.Name -contains 'suiteDir'
    } catch { $false }
} | Select-Object -First 1)
if ($completionFile.Count -eq 0) {
    throw "Recorded validation completion marker was not created: $SuiteDir"
}
$completionPath = $completionFile[0].FullName
$completion = Get-Content -LiteralPath $completionPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not [bool]$completion.pipelineCompleted) {
    throw "Recorded validation pipeline did not complete: $([string]$completion.status) / $([string]$completion.actionSummary.error)"
}
Write-Host "0101 live validation output: $SuiteDir"
exit 0
