<#
.SYNOPSIS 캘리브레이션과 주문 시나리오 Core CLI를 연결하는 얇은 orchestration adapter다.
.DESCRIPTION 기존 read-only capture 산출물을 세션/검토/검증/compile/DryRun 명령에 전달한다.
.NOTES locator, risk, approval, verdict를 PowerShell에서 재판정하지 않으며 UI Action을 호출하지 않는다.
#>

# 주입된 Core CLI 호출자와 zero-action audit counter를 묶는다.
function New-HtsOrderAuthoringContext {
    param([Parameter(Mandatory = $true)][scriptblock]$InvokeCli)
    [pscustomobject]@{ InvokeCli=$InvokeCli; UiActionCount=0; TransactionalActionCount=0 }
}

# 인수 배열을 주입된 CLI adapter에 그대로 전달한다.
function Invoke-HtsOrderAuthoringCli {
    param([Parameter(Mandatory = $true)]$Context,[Parameter(Mandatory = $true)][string[]]$Arguments)
    if (-not ($Context.InvokeCli -is [scriptblock])) { throw 'ORDER_AUTHORING_CLI_REQUIRED' }
    & $Context.InvokeCli $Arguments
}

# read-only capture 경로 목록으로 캘리브레이션 세션 작성 명령을 구성한다.
function New-HtsOrderCalibrationSession {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string[]]$CapturePaths,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$TargetProfileId,
        [Parameter(Mandatory = $true)][string]$RepositoryId,
        [Parameter(Mandatory = $true)][string]$Screen,
        [Parameter(Mandatory = $true)][string]$StateContext,
        [Parameter(Mandatory = $true)][string]$Reviewer,
        [string]$Map='', [string]$Out=''
    )
    $arguments=@('create-calibration-session','--captures',($CapturePaths -join ','),'--session-id',$SessionId,
        '--target-profile-id',$TargetProfileId,'--repository-id',$RepositoryId,'--screen',$Screen,
        '--state-context',$StateContext,'--reviewer',$Reviewer)
    if ($Map) { $arguments += @('--map',$Map) }
    if ($Out) { $arguments += @('--out',$Out) }
    Invoke-HtsOrderAuthoringCli -Context $Context -Arguments $arguments
}

# calibration session의 canonical Core 검증 결과를 그대로 요청한다.
function Test-HtsOrderCalibrationSession {
    param([Parameter(Mandatory = $true)]$Context,[Parameter(Mandatory = $true)][string]$Session,[string]$Out='')
    $arguments=@('validate-calibration-session','--file',$Session)
    if ($Out) { $arguments += @('--out',$Out) }
    Invoke-HtsOrderAuthoringCli -Context $Context -Arguments $arguments
}

# 사람이 확인한 logical key, risk, action, anchor를 review 명령에 전달한다.
function New-HtsOrderCalibrationReview {
    param(
        [Parameter(Mandatory = $true)]$Context,[Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$LogicalName,[string]$Anchor='',
        [Parameter(Mandatory = $true)][string]$RiskClass,[Parameter(Mandatory = $true)][string[]]$AllowedActions,
        [Parameter(Mandatory = $true)][string[]]$ForbiddenActions,[Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string[]]$Evidence,[string]$BusinessRole='',
        [string]$TransactionalRole='None',[string]$Out=''
    )
    $arguments=@('create-calibration-review','--session',$Session,'--logical-name',$LogicalName,'--anchor',$Anchor,
        '--risk-class',$RiskClass,'--allowed-actions',($AllowedActions -join ','),'--forbidden-actions',($ForbiddenActions -join ','),
        '--source',$Source,'--evidence',($Evidence -join ','))
    if ($Out) { $arguments += @('--out',$Out) }
    if ($BusinessRole) { $arguments += @('--business-role',$BusinessRole) }
    if ($TransactionalRole) { $arguments += @('--transactional-role',$TransactionalRole) }
    Invoke-HtsOrderAuthoringCli -Context $Context -Arguments $arguments
}

# Core static validator 결과를 요청하며 PowerShell에서 상태를 바꾸지 않는다.
function Test-HtsOrderScenario {
    param([Parameter(Mandatory = $true)]$Context,[Parameter(Mandatory = $true)][string]$InputPath,[string]$Out='')

    $arguments=@('validate-order-scenario','--input',$InputPath)
    if ($Out) { $arguments += @('--out',$Out) }
    Invoke-HtsOrderAuthoringCli -Context $Context -Arguments $arguments
}

# Core가 생성한 environment authorization approval template만 요청한다.
function New-HtsExecutionAuthorizationApproval {
    param([Parameter(Mandatory = $true)]$Context,[Parameter(Mandatory = $true)][string]$Request,[string]$Out='')
    $arguments=@('create-execution-authorization-approval','--request',$Request)
    if ($Out) { $arguments += @('--out',$Out) }
    Invoke-HtsOrderAuthoringCli -Context $Context -Arguments $arguments
}

# 사람이 편집한 기존 approval overlay를 Core 검증에 전달한다.
function Set-HtsExecutionAuthorizationApproval {
    param([Parameter(Mandatory = $true)]$Context,[Parameter(Mandatory = $true)][string]$Request,
        [Parameter(Mandatory = $true)][string]$Approval,[string]$Out='')
    $arguments=@('apply-execution-authorization-approval','--request',$Request,'--approval',$Approval)
    if ($Out) { $arguments += @('--out',$Out) }
    Invoke-HtsOrderAuthoringCli -Context $Context -Arguments $arguments
}

# 현재 fingerprint, scope, control contract를 Core 단일 authorization service로 확인한다.
function Test-HtsExecutionAuthorization {
    param([Parameter(Mandatory = $true)]$Context,[Parameter(Mandatory = $true)][string]$Request,
        [Parameter(Mandatory = $true)][string]$CheckedAt,[string]$Out='')
    $arguments=@('check-execution-authorization','--request',$Request,'--checked-at',$CheckedAt)
    if ($Out) { $arguments += @('--out',$Out) }
    Invoke-HtsOrderAuthoringCli -Context $Context -Arguments $arguments
}

# 기존 approval overlay가 승인한 entry를 새 repository 출력으로 명시 등록한다.
function Add-HtsApprovedControlRepositoryEntry {
    param([Parameter(Mandatory = $true)]$Context,[Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Entry,[Parameter(Mandatory = $true)][string]$Out)
    Invoke-HtsOrderAuthoringCli -Context $Context -Arguments @('register-control-repository-entry','--repository',$Repository,'--entry',$Entry,'--out',$Out)
}

# 등록이 끝난 canonical approval hash를 calibration session provenance에 고정한다.
function Complete-HtsOrderCalibrationSession {
    param([Parameter(Mandatory = $true)]$Context,[Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$Repository,[Parameter(Mandatory = $true)][string]$LogicalName,
        [Parameter(Mandatory = $true)][string]$Out)
    Invoke-HtsOrderAuthoringCli -Context $Context -Arguments @('finalize-calibration-session','--session',$Session,
        '--repository',$Repository,'--logical-name',$LogicalName,'--out',$Out)
}

# 검증된 입력을 immutable DryRun run plan으로 compile하도록 요청한다.
function New-HtsOrderScenarioRunPlan {
    param([Parameter(Mandatory = $true)]$Context,[Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$Out,[string]$CompiledAt='')
    $arguments=@('compile-order-scenario','--input',$InputPath,'--out',$Out)
    if ($CompiledAt) { $arguments += @('--compiled-at',$CompiledAt) }
    Invoke-HtsOrderAuthoringCli -Context $Context -Arguments $arguments
}

# DryRun 결과를 그대로 반환하고 adapter의 action counter가 0인지 확인한다.
function Invoke-HtsOrderScenarioDryRun {
    param([Parameter(Mandatory = $true)]$Context,[Parameter(Mandatory = $true)][string]$Plan,[string]$Out='')
    $arguments=@('dry-run-order-scenario','--plan',$Plan)
    if ($Out) { $arguments += @('--out',$Out) }
    $result=Invoke-HtsOrderAuthoringCli -Context $Context -Arguments $arguments
    if ([int]$Context.UiActionCount -ne 0 -or [int]$Context.TransactionalActionCount -ne 0) {
        throw 'ORDER_DRY_RUN_ACTION_COUNT_NONZERO'
    }
    $result
}
