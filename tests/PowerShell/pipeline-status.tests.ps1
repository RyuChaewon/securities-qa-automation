<#
.SYNOPSIS 파이프라인 완료 상태와 테스트 결과 상태 분리 계약을 외부 모듈 없이 회귀 검증한다.
.DESCRIPTION 공통 상태 모듈을 직접 불러 필수 DONE 변환과 인프라 예외, 부분 실행 증거 보존을 확인한다.
.OUTPUTS 모든 검증 성공 시 PIPELINE_STATUS_TESTS=PASS와 assertion 수를 출력한다.
#>
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\pipeline-status.ps1')
$script:assertions = 0

# 값이 다르면 즉시 종료해 독립 실행에서도 비정상 종료 코드가 보존되게 한다.
function Assert-Equal([object]$Expected, [object]$Actual, [string]$Message) {
    $script:assertions++
    if ($Expected -ne $Actual) {
        throw "$Message expected=[$Expected] actual=[$Actual]"
    }
}

$contract = Get-RulePipelineStatusContract
Assert-Equal $true ($contract.PipelineStatuses -contains 'DONE') 'PipelineStatus DONE 계약'
Assert-Equal $true ($contract.TestStatuses -contains 'PENDING') 'TestStatus PENDING 계약'

$done = Resolve-RulePipelineState -Status 'DONE'
Assert-Equal $true $done.PipelineCompleted 'DONE 완료 여부'
Assert-Equal 'DONE' $done.PipelineStatus 'DONE canonical 상태'

$failed = Resolve-RulePipelineState -Status 'DONE_WITH_TEST_FAILURES'
Assert-Equal $true $failed.PipelineCompleted 'FAIL 결과 파이프라인 완료 여부'
Assert-Equal 'FAIL' $failed.TestStatus 'FAIL 결과 상태'

$errored = Resolve-RulePipelineState -Status 'DONE_WITH_TEST_ERRORS'
Assert-Equal $true $errored.PipelineCompleted 'ERROR 결과 파이프라인 완료 여부'
Assert-Equal 'ERROR' $errored.TestStatus 'ERROR 결과 상태'

$pending = Resolve-RulePipelineState -Status 'DONE_WITH_PENDING'
Assert-Equal $true $pending.PipelineCompleted 'PENDING 결과 파이프라인 완료 여부'
Assert-Equal 'PENDING' $pending.TestStatus 'PENDING 결과 상태'

$infrastructureError = Resolve-RulePipelineState -Status 'ERROR' -TestStatus 'PENDING'
Assert-Equal $false $infrastructureError.PipelineCompleted '인프라 예외 완료 여부'
Assert-Equal 'ERROR' $infrastructureError.PipelineStatus '인프라 예외 canonical 상태'

$recordedInfrastructureError = Resolve-RuleRecordedPipelineState -ActionStatus 'ERROR' -TestStatus 'ERROR' -HasSummary $true -TotalTests 1 -VideoOk $true -CursorAuditOk $true -ExcelStatus 'DONE' -ActualScenarioActionsExecuted $true
Assert-Equal $false $recordedInfrastructureError.PipelineCompleted '녹화 인프라 예외 완료 여부'
Assert-Equal 'ERROR' $recordedInfrastructureError.PipelineStatus '녹화 인프라 예외 canonical 상태'
Assert-Equal $true $recordedInfrastructureError.ActualScenarioActionsExecuted '녹화 인프라 예외 액션 기록'

$partialSummary = [pscustomobject]@{ status = 'ERROR'; flaUiActionAttempts = 2 }
$actionsExecuted = Get-RuleActualScenarioActionsExecuted -RecordedValue $false -Summary $partialSummary
$partialFailure = Resolve-RulePipelineState -Status 'ERROR' -TestStatus 'ERROR' -ActualScenarioActionsExecuted $actionsExecuted
Assert-Equal $true $partialFailure.ActualScenarioActionsExecuted '일부 액션 후 예외 실행 기록'
Assert-Equal $false $partialFailure.PipelineCompleted '일부 액션 후 예외 완료 여부'

$recordedFailure = Resolve-RuleRecordedPipelineState -ActionStatus 'DONE' -TestStatus 'FAIL' -HasSummary $true -TotalTests 1 -VideoOk $true -CursorAuditOk $true -ExcelStatus 'DONE' -ActualScenarioActionsExecuted $true
Assert-Equal 'DONE_WITH_TEST_FAILURES' $recordedFailure.Status '녹화 실행 FAIL 호환 상태'
Assert-Equal 'DONE' $recordedFailure.PipelineStatus '녹화 실행 FAIL pipeline 상태'
Assert-Equal $true $recordedFailure.PipelineCompleted '녹화 실행 FAIL 완료 여부'

$integrationFiles = @(
    'scripts\run-target-rule-suite-recorded.ps1',
    'scripts\run-auto-scenario-pipeline.ps1',
    'scripts\invoke-scenario-pipeline.ps1'
)
foreach ($relativePath in $integrationFiles) {
    $source = Get-Content -LiteralPath (Join-Path $root $relativePath) -Raw -Encoding UTF8
    Assert-Equal $true ($source.Contains('modules\pipeline-status.ps1')) "$relativePath 공통 상태 모듈 연결"
}

"PIPELINE_STATUS_TESTS=PASS assertions=$script:assertions"
