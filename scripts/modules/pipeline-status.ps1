<#
.SYNOPSIS 파이프라인 완료 상태와 테스트 결과 상태를 독립 계약으로 정규화한다.
.DESCRIPTION 기존 status 값을 유지하면서 pipelineStatus, pipelineCompleted, testStatus와 실제 액션 실행 증거를 한 곳에서 계산한다.
.INPUTS 기존 호환 상태, 테스트 상태, 인프라 완료 증거와 액션 실행 증거.
.OUTPUTS 외부 상태 파일에 그대로 기록할 수 있는 순수 상태 객체.
.NOTES 파일이나 프로세스를 읽지 않으며 알 수 없는 상태와 모순된 테스트 상태는 계약 위반으로 거부한다.
#>

# 공개 가능한 PipelineStatus/TestStatus 값과 완료 호환 상태를 단일 계약으로 제공한다.
function Get-RulePipelineStatusContract {
    [pscustomobject]@{
        PipelineStatuses = @('RUNNING', 'PENDING', 'DONE', 'ERROR')
        TestStatuses = @('PASS', 'FAIL', 'ERROR', 'PENDING')
        CompletedCompatibilityStatuses = @('DONE', 'DONE_WITH_TEST_FAILURES', 'DONE_WITH_TEST_ERRORS', 'DONE_WITH_PENDING')
    }
}

# 호환 status와 명시된 TestStatus를 독립적인 canonical 상태로 변환한다.
function Resolve-RulePipelineState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [AllowEmptyString()]
        [string]$TestStatus = '',
        [bool]$ActualScenarioActionsExecuted = $false
    )

    $normalizedStatus = $Status.Trim().ToUpperInvariant()
    if (-not $normalizedStatus) { throw 'Pipeline status는 비어 있을 수 없습니다.' }

    $normalizedTestStatus = $TestStatus.Trim().ToUpperInvariant()
    $allowedTestStatuses = @('PASS', 'FAIL', 'ERROR', 'PENDING')
    if ($normalizedTestStatus -and $allowedTestStatuses -notcontains $normalizedTestStatus) {
        throw "알 수 없는 TestStatus입니다: $TestStatus"
    }

    $impliedTestStatus = switch ($normalizedStatus) {
        'DONE_WITH_TEST_FAILURES' { 'FAIL' }
        'DONE_WITH_TEST_ERRORS' { 'ERROR' }
        'DONE_WITH_PENDING' { 'PENDING' }
        default { '' }
    }
    if ($impliedTestStatus -and $normalizedTestStatus -and $impliedTestStatus -ne $normalizedTestStatus) {
        throw "호환 status와 TestStatus가 모순됩니다: $normalizedStatus / $normalizedTestStatus"
    }
    if (-not $normalizedTestStatus) {
        $normalizedTestStatus = if ($impliedTestStatus) { $impliedTestStatus } else { 'PENDING' }
    }

    $pipelineStatus = switch -Regex ($normalizedStatus) {
        '^(DONE|DONE_WITH_TEST_FAILURES|DONE_WITH_TEST_ERRORS|DONE_WITH_PENDING|COMPLETED|STATIC_PLAN_READY|PHYSICAL_PLAN_READY)$' { 'DONE'; break }
        '^STARTED$' { 'RUNNING'; break }
        '^PENDING_' { 'PENDING'; break }
        '^(ERROR|LAUNCH_ERROR|TIMEOUT|REPORT_ERROR|CURSOR_AUDIT_ERROR|VIDEO_ERROR)$' { 'ERROR'; break }
        default { throw "알 수 없는 PipelineStatus 호환 값입니다: $Status" }
    }

    [pscustomobject]@{
        Status = $normalizedStatus
        PipelineStatus = $pipelineStatus
        PipelineCompleted = $pipelineStatus -eq 'DONE'
        TestStatus = $normalizedTestStatus
        TestPassed = $normalizedTestStatus -eq 'PASS'
        ActualScenarioActionsExecuted = [bool]$ActualScenarioActionsExecuted
    }
}

# 명시 플래그나 summary의 FlaUI 시도 횟수 중 하나라도 실행을 증명하면 true를 보존한다.
function Get-RuleActualScenarioActionsExecuted {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$RecordedValue = $null,
        [AllowNull()]
        [object]$Summary = $null
    )

    $recordedTrue = $RecordedValue -is [bool] -and [bool]$RecordedValue
    if (-not $recordedTrue -and $null -ne $RecordedValue) {
        $recordedTrue = ([string]$RecordedValue).Equals('true', [StringComparison]::OrdinalIgnoreCase)
    }
    if ($recordedTrue) { return $true }
    if (-not $Summary) { return $false }

    $summaryFlag = $Summary.PSObject.Properties['actualScenarioActionsExecuted']
    if ($summaryFlag -and [bool]$summaryFlag.Value) { return $true }
    $attempts = $Summary.PSObject.Properties['flaUiActionAttempts']
    return $attempts -and [int]$attempts.Value -gt 0
}

# 녹화 실행의 인프라 증거와 TestStatus를 결합하되 테스트 실패를 파이프라인 실패로 바꾸지 않는다.
function Resolve-RuleRecordedPipelineState {
    [CmdletBinding()]
    param(
        [string]$ActionStatus = '',
        [string]$TestStatus = '',
        [bool]$HasSummary = $false,
        [int]$TotalTests = 0,
        [bool]$VideoOk = $false,
        [bool]$CursorAuditOk = $false,
        [string]$ExcelStatus = '',
        [string]$LaunchError = '',
        [bool]$TimedOut = $false,
        [bool]$ActualScenarioActionsExecuted = $false
    )

    $normalizedActionStatus = $ActionStatus.Trim().ToUpperInvariant()
    $normalizedTestStatus = $TestStatus.Trim().ToUpperInvariant()
    $safeTestStatus = if ($normalizedTestStatus -in @('PASS', 'FAIL', 'ERROR', 'PENDING')) { $normalizedTestStatus } else { 'PENDING' }
    if ($normalizedActionStatus -like 'PENDING_*') {
        return Resolve-RulePipelineState -Status $normalizedActionStatus -TestStatus 'PENDING' -ActualScenarioActionsExecuted $ActualScenarioActionsExecuted
    }
    if ($LaunchError) {
        return Resolve-RulePipelineState -Status 'LAUNCH_ERROR' -TestStatus 'PENDING' -ActualScenarioActionsExecuted $ActualScenarioActionsExecuted
    }
    if ($TimedOut) {
        return Resolve-RulePipelineState -Status 'TIMEOUT' -TestStatus 'PENDING' -ActualScenarioActionsExecuted $ActualScenarioActionsExecuted
    }
    if ($normalizedActionStatus -ne 'DONE') {
        return Resolve-RulePipelineState -Status 'ERROR' -TestStatus $safeTestStatus -ActualScenarioActionsExecuted $ActualScenarioActionsExecuted
    }
    if (-not $HasSummary -or $TotalTests -le 0) {
        return Resolve-RulePipelineState -Status 'ERROR' -TestStatus 'PENDING' -ActualScenarioActionsExecuted $ActualScenarioActionsExecuted
    }
    if ($ExcelStatus -ne 'DONE') {
        return Resolve-RulePipelineState -Status 'REPORT_ERROR' -TestStatus $safeTestStatus -ActualScenarioActionsExecuted $ActualScenarioActionsExecuted
    }
    if (-not $CursorAuditOk) {
        return Resolve-RulePipelineState -Status 'CURSOR_AUDIT_ERROR' -TestStatus $safeTestStatus -ActualScenarioActionsExecuted $ActualScenarioActionsExecuted
    }
    if (-not $VideoOk) {
        return Resolve-RulePipelineState -Status 'VIDEO_ERROR' -TestStatus $safeTestStatus -ActualScenarioActionsExecuted $ActualScenarioActionsExecuted
    }

    $completionStatus = switch ($normalizedTestStatus) {
        'PASS' { 'DONE' }
        'FAIL' { 'DONE_WITH_TEST_FAILURES' }
        'ERROR' { 'DONE_WITH_TEST_ERRORS' }
        'PENDING' { 'DONE_WITH_PENDING' }
        default { return Resolve-RulePipelineState -Status 'ERROR' -TestStatus 'PENDING' -ActualScenarioActionsExecuted $ActualScenarioActionsExecuted }
    }
    Resolve-RulePipelineState -Status $completionStatus -TestStatus $safeTestStatus -ActualScenarioActionsExecuted $ActualScenarioActionsExecuted
}

# 호환 status에 맞는 사용자 메시지를 제공해 호출 스크립트의 상태 switch 중복을 없앤다.
function Get-RulePipelineStatusMessage([string]$Status) {
    switch ($Status.Trim().ToUpperInvariant()) {
        'DONE' { '전체 HTS 화면 녹화와 테스트 실행을 완료했으며 테스트가 통과했습니다.' }
        'DONE_WITH_TEST_ERRORS' { '녹화와 결과 생성을 완료했으며 테스트 결과에 ERROR가 있습니다.' }
        'DONE_WITH_TEST_FAILURES' { '녹화와 결과 생성을 완료했으며 테스트 결과에 FAIL이 있습니다.' }
        'DONE_WITH_PENDING' { '녹화와 결과 생성을 완료했으며 판정 보류 항목이 있습니다.' }
        'PENDING_ADMIN_RUNNER_REQUIRED' { 'HTS와 같은 권한의 실행기가 필요해 파이프라인을 시작하지 않았습니다.' }
        'PENDING_ADMIN_APPROVAL_DECLINED' { '관리자 권한 승인이 취소되어 파이프라인을 시작하지 않았습니다.' }
        default { '프로세스 시작, 파일, 예외 또는 실행 계약을 확인해야 합니다.' }
    }
}
