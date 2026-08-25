<#
.SYNOPSIS Single approved case execution and raw evidence collection.
.DESCRIPTION Runs variables and case restoration, then delegates canonical verdict and JSON creation to the finalizer.
#>

# Collects one case action and checkpoint observations without assigning PASS or FAIL.
function Invoke-HtsRuleSuiteCase {
    param(
        [Parameter(Mandatory = $true)]$RunSpec,
        [Parameter(Mandatory = $true)]$RunServices,
        [Parameter(Mandatory = $true)]$RunState,
        [Parameter(Mandatory = $true)][object[]]$Cases,
        [Parameter(Mandatory = $true)][int]$CaseIndex
    )

    $dataset = $RunSpec.Dataset
    $testPack = $RunSpec.TestPack
    $scenarioMode = [bool]$RunSpec.ScenarioMode
    $scenarioPlan = $RunSpec.ScenarioPlan
    $physicalPlan = $RunSpec.PhysicalPlan
    $mapCatalog = $RunSpec.MapCatalog
    $PlanOnly = [bool]$RunSpec.Input.PlanOnly
    $ReuseExistingTargetScreen = [bool]$RunSpec.Input.ReuseExistingTargetScreen
    $RequireExistingTargetScreen = [bool]$RunSpec.Input.RequireExistingTargetScreen
    $PreserveTargetScreenAfterRun = [bool]$RunSpec.Input.PreserveTargetScreenAfterRun
    $reuseExistingTargetScreenRequested = [bool]$RunSpec.ReuseExistingTargetScreenRequested
    $ReportDir = [string]$RunSpec.ReportDir
    $screenshotsDir = [string]$RunSpec.ScreenshotsDir
    $runId = [string]$RunSpec.RunId
    $cliProject = [string]$RunSpec.CliProject
    $resultEvaluationTestPackPath = [string]$RunSpec.ResultEvaluationTestPackPath
    $resultEvaluationWorkingDirectory = [string]$RunSpec.ResultEvaluationWorkingDirectory

    $RuntimeContext = $RunServices.RuntimeContext
    $automationMetrics = $RunServices.AutomationMetrics
    $sessionContext = $RunServices.SessionContext
    $targetRuleContext = $RunServices.TargetRuleContext
    $discoveryContext = $RunServices.DiscoveryContext
    $bindingContext = $RunServices.BindingContext
    $actionContext = $RunServices.ActionContext
    $observationContext = $RunServices.ObservationContext
    $evaluationAdapterContext = $RunServices.EvaluationAdapterContext
    $safetyContext = $RunServices.SafetyContext
    $navigationContext = $RunServices.NavigationContext
    $reportingContext = $RunServices.ReportingContext

    $cases = $Cases
    $caseIndex = $CaseIndex
    $main = $RunState.Main
    $screenEdit = $RunState.ScreenEdit
    $errorRegex = $RunState.ErrorRegex
    $RunState.CurrentCase = [string]$cases[$caseIndex].caseId
    $RunState.CurrentScreen = [string]$cases[$caseIndex].screen.screenNumber

    $case = $cases[$caseIndex]
    $datasetInteractionStrategy = [string]$dataset.autoExploration.interactionStrategy
    $targetRuleContext.CurrentInteractionStrategy = if ($scenarioMode -and [string]$case.scenarioCase.executionOrder) {
        [string]$case.scenarioCase.executionOrder
    } elseif ($datasetInteractionStrategy) {
        $datasetInteractionStrategy
    } else {
        'RuntimeTabOrder'
    }
    $previousCase = if ($caseIndex -gt 0) { $cases[$caseIndex-1] } else { $null }
    $nextCase = if ($caseIndex + 1 -lt $cases.Count) { $cases[$caseIndex+1] } else { $null }
    $reuseScenarioScreen = $scenarioMode -and $previousCase -and [string]$previousCase.screen.screenNumber -eq [string]$case.screen.screenNumber
    $retainScenarioScreen = $scenarioMode -and $nextCase -and [string]$nextCase.screen.screenNumber -eq [string]$case.screen.screenNumber
    $started = Get-Date
    $actions = New-Object Collections.Generic.List[object]
    $pendingReasons = New-Object Collections.Generic.List[string]
    $errors = New-Object Collections.Generic.List[string]
    $automationIssues = New-Object Collections.Generic.List[string]
    $discoveredControls = New-Object Collections.Generic.List[object]
    $controlTests = New-Object Collections.Generic.List[object]
    $popupObservations = New-Object Collections.Generic.List[object]
    $oracleEvents = New-Object Collections.Generic.List[object]
    $currentResultEvaluationCases = New-Object Collections.Generic.List[object]
    $currentSignalEvaluationGroups = @{}
    $flaUiActionAttemptsBeforeCase = [int]$automationMetrics.FlaUiActionAttempts
    $executedExpectationPatterns = New-Object Collections.Generic.List[string]
    $requiredExpectations = New-Object Collections.Generic.List[object]
    [void](Reset-HtsObservationCaseContext -Context $observationContext -ResultEvaluationCases $currentResultEvaluationCases -SignalEvaluationGroups $currentSignalEvaluationGroups -RequiredExpectations $requiredExpectations)
    $queryRequiredExpectations = New-Object Collections.Generic.List[object]
    $claimedHwnds = @{}
    $tabOrderQueryControl = $null
    $executorException = $false
    $executorDiagnostic = ""
    $automationContractFailure = $false
    $automationContractErrorCode = ''
    $externalInterruption = $false
    $screenOpenFailure = $false
    $existingScreenRequiredMissing = $false
    $usedExistingTargetScreen = $false
    $openedTargetScreenForRun = $false
    $transactionAccountVerified = $false
    $transactionAccountEvidence = ''
    $transactionAccountCandidate = $null
    $transactionAccountFingerprint = ''
    $inputMode = if ($case.account.inputMode) { [string]$case.account.inputMode } else { "Prefilled" }
    $queryTrigger = if ($case.screen.queryTrigger) { [string]$case.screen.queryTrigger } else { "F12" }
    $secret = if ($inputMode -eq "Explicit" -and $case.account.passwordSecret) {
        [Environment]::GetEnvironmentVariable([string]$case.account.passwordSecret.key)
    } else { "" }
    $logBefore = @{}
    $beforeErrorTexts = @()
    $screen = $null
    $mapModel = Get-HtsDiscoveryMapScreenModel -Context $discoveryContext -ScreenNumber ([string]$case.screen.screenNumber) -MapScreenCode $(if($scenarioMode){[string]$case.scenarioCase.mapScreenCode}else{''})
    $mapOracle = if ($mapModel) { $mapModel.errorOracle } else { $null }
    $mapBehavior = if ($mapModel) { $mapModel.behavior } else { $null }
    $mapQueryExecuted = $false
    $mapReboundControls = 0
    $caseErrorRegex = Get-HtsObservationErrorRegex -Context $observationContext $errorRegex $mapOracle

    $frame = [pscustomobject]@{
        Case = $case
        ReuseScenarioScreen = [bool]$reuseScenarioScreen
        RetainScenarioScreen = [bool]$retainScenarioScreen
        Main = $main
        Screen = $screen
        ScreenEdit = $screenEdit
        Secret = $secret
        QueryTrigger = $queryTrigger
        Actions = $actions
        PendingReasons = $pendingReasons
        Errors = $errors
        AutomationIssues = $automationIssues
        DiscoveredControls = $discoveredControls
        ControlTests = $controlTests
        PopupObservations = $popupObservations
        OracleEvents = $oracleEvents
        ClaimedHwnds = $claimedHwnds
        CaseErrorRegex = $caseErrorRegex
        ExecutedExpectationPatterns = $executedExpectationPatterns
        RequiredExpectations = $requiredExpectations
        QueryRequiredExpectations = $queryRequiredExpectations
        LogBefore = $logBefore
        InputMode = $inputMode
        MapModel = $mapModel
        MapOracle = $mapOracle
        MapBehavior = $mapBehavior
        MapQueryExecuted = $mapQueryExecuted
        MapReboundControls = $mapReboundControls
        TabOrderQueryControl = $tabOrderQueryControl
        TransactionAccountVerified = $transactionAccountVerified
        TransactionAccountEvidence = $transactionAccountEvidence
        TransactionAccountCandidate = $transactionAccountCandidate
        TransactionAccountFingerprint = $transactionAccountFingerprint
        AutomationContractFailure = $automationContractFailure
        AutomationContractErrorCode = $automationContractErrorCode
        ExecutorException = $executorException
        ExecutorDiagnostic = $executorDiagnostic
        ExternalInterruption = $externalInterruption
        ScreenOpenFailure = $screenOpenFailure
        ExistingScreenRequiredMissing = $existingScreenRequiredMissing
        UsedExistingTargetScreen = $usedExistingTargetScreen
        OpenedTargetScreenForRun = $openedTargetScreenForRun
        FlaUiActionAttemptsBeforeCase = $flaUiActionAttemptsBeforeCase
        Started = $started
        Screenshot = ''
        AutoPendingReasons = $null
    }

    try {
        $frame.Main = $main
        $frame.Screen = $screen
        $frame.ScreenEdit = $screenEdit
        $frame.ExistingScreenRequiredMissing = [bool]$existingScreenRequiredMissing
        $frame.UsedExistingTargetScreen = [bool]$usedExistingTargetScreen
        $frame.OpenedTargetScreenForRun = [bool]$openedTargetScreenForRun
        [void](Enter-HtsRuleSuiteCaseScreen -RunSpec $RunSpec -RunServices $RunServices -RunState $RunState -Frame $frame)
        $main = $frame.Main
        $screen = $frame.Screen
        $screenEdit = $frame.ScreenEdit
        $existingScreenRequiredMissing = [bool]$frame.ExistingScreenRequiredMissing
        $usedExistingTargetScreen = [bool]$frame.UsedExistingTargetScreen
        $openedTargetScreenForRun = [bool]$frame.OpenedTargetScreenForRun
        if (-not $screen) {
            $openConnectionDialogs = @(Get-HtsConnectionDialogs $observationContext $RuntimeContext $main $secret)
            if ($openConnectionDialogs.Count -gt 0) {
                throw "HTS_CONNECTION_LOST: 화면 열기 중 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$openConnectionDialogs[0].text)"
            }
            if (-not $existingScreenRequiredMissing) {
                $screenOpenFailure = $true
                $automationContractFailure = $true
                $automationContractErrorCode = 'SCREEN_NOT_VISIBLE'
                Add-HtsActionRecord $reportingContext $actions "openScreen" "FAIL" ([string]$case.screen.screenNumber) "화면 창이 표시되지 않았습니다." "SCREEN_NOT_VISIBLE"
                $errors.Add("화면을 연 뒤 대상 창이 표시되지 않았습니다.")
            }
            foreach ($dialog in @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)) {
                if ($dialog.text) { $errors.Add($dialog.text) }
            }
        } else {
            if(-not (Focus-HtsRequestedScreen $navigationContext $main $screen ([string]$case.screen.screenNumber))){
                throw "INPUT_SCOPE_BLOCKED: [$($case.screen.screenNumber)] 대상 화면을 활성 입력 표면으로 고정하지 못했습니다."
            }
            Add-HtsActionRecord $reportingContext $actions "openScreen" "PASS" ([string]$case.screen.screenNumber) $(if($usedExistingTargetScreen){'기존 화면을 재호출하지 않고 활성화했습니다.'}else{'화면 창이 열렸습니다.'})
            if ($mapOracle) {
                $oracleMessageCount = @($mapOracle.messageBoxes).Count
                $oracleErrorCount = @($mapOracle.messageBoxes | Where-Object isExplicitError).Count
                $oracleValidationCount = @($mapOracle.messageBoxes | Where-Object classification -eq 'InputValidation').Count
                Add-HtsActionRecord $reportingContext $actions 'loadMapErrorOracle' 'PASS' ([string]$case.screen.screenNumber) "MAP 오류 오라클을 적용했습니다: 메시지 $oracleMessageCount개(명시 오류 $oracleErrorCount, 입력 검증 $oracleValidationCount), 오류 핸들러 $(@($mapOracle.errorHandlers).Count)개, 통신 식별자 $(@($mapOracle.requestNames).Count + @($mapOracle.transactionCodes).Count)개."
            } else {
                Add-HtsActionRecord $reportingContext $actions 'loadMapErrorOracle' 'PENDING' ([string]$case.screen.screenNumber) '화면별 MAP 오류 오라클이 없어 공통 오류 규칙만 적용합니다.' 'MAP_ERROR_ORACLE_NOT_FOUND'
            }
            if ($mapBehavior) {
                Add-HtsActionRecord $reportingContext $actions 'loadMapBehavior' 'PASS' ([string]$case.screen.screenNumber) "MAP 동작 모델을 적용했습니다: 이벤트 $(@($mapBehavior.eventHandlers).Count)개, 조회 $(@($mapBehavior.queryControls).Count)개, 자동조회 $(@($mapBehavior.autoQueryControls).Count)개, 상태제어 $(@($mapBehavior.stateControllerControls).Count)개, 입력 $(@($mapBehavior.inputControls).Count)개, 결과 $(@($mapBehavior.resultControls).Count)개."
            } else {
                Add-HtsActionRecord $reportingContext $actions 'loadMapBehavior' 'PENDING' ([string]$case.screen.screenNumber) '화면별 MAP 동작 모델이 없어 런타임 발견 정보만 사용합니다.' 'MAP_BEHAVIOR_NOT_FOUND'
            }
            if($mapModel -and $mapCatalog.installationFingerprint){
                $canonicalTitle=if($mapModel.registry){[string]$mapModel.registry.title}else{[string]$mapModel.screenName}
                $integrityStatus=if($mapModel.integrity){[string]$mapModel.integrity.status}else{'MANIFEST_MISSING'}
                $installStatus=if($integrityStatus -eq 'MATCH'){'PASS'}else{'PENDING'}
                Add-HtsActionRecord $reportingContext $actions 'loadInstallationCatalog' $installStatus ([string]$case.screen.screenNumber) "설치 기준 '$canonicalTitle'을 적용했습니다: 탭 형제 $(@($mapModel.tabSiblings).Count)개, 연결 정의 $(@($mapModel.dependencies).Count)개, 데이터 사전 $(@($mapModel.dataReferences).Count)개, 무결성 $integrityStatus." $(if($installStatus-eq'PASS'){''}else{'INSTALLATION_MODEL_DRIFT'})
                if($installStatus-ne'PASS'){$pendingReasons.Add("설치 무결성: $integrityStatus")}
            }
            if($requestedScreenWindow -and $screen.hwnd -ne $requestedScreenWindow.hwnd){
                Add-HtsActionRecord $reportingContext $actions 'resolveContentSurface' 'PASS' ([string]$screen.rawTitle) "요청 화면과 같은 번호이거나 화면 열기 뒤 새로 생성된 콘텐츠 표면만 선택했습니다."
            }
            if ($inputMode -eq "Prefilled") {
                Add-HtsActionRecord $reportingContext $actions "usePrefilledInputs" "PASS" "prefilled inputs" "현재 화면에 기본 입력된 값을 변경하지 않고 사용했습니다."
            } else {
                $accountStrategies = if ($case.screen.locators -and $case.screen.locators.account) { $case.screen.locators.account } else { $dataset.defaultLocators.account }
                $accountControl = Resolve-HtsRoleControl -Context $bindingContext -Screen $screen -Role 'account' -Strategies $accountStrategies
                if ($accountControl -and [Int64]$accountControl.hwnd -ne 0) { $claimedHwnds[[Int64]$accountControl.hwnd] = $true }
                if ($accountControl -and (Set-AutomationText $actionContext $accountControl ([string]$case.account.accountNumber))) {
                    Add-HtsActionRecord $reportingContext $actions "setAccount" "PASS" "account" "계좌번호를 입력했으며 결과에는 마스킹했습니다."
                } else {
                    Add-HtsActionRecord $reportingContext $actions "setAccount" "PENDING" "account" "신뢰도 높은 계좌 입력칸을 찾지 못했습니다." "LOCATOR_NOT_RESOLVED"
                    $pendingReasons.Add("계좌 입력칸")
                }

                $passwordStrategies = if ($case.screen.locators -and $case.screen.locators.password) { $case.screen.locators.password } else { $dataset.defaultLocators.password }
                $passwordControl = Resolve-HtsRoleControl -Context $bindingContext -Screen $screen -Role 'password' -Strategies $passwordStrategies
                if ($passwordControl -and [Int64]$passwordControl.hwnd -ne 0) { $claimedHwnds[[Int64]$passwordControl.hwnd] = $true }
                if (-not $secret) {
                    Add-HtsActionRecord $reportingContext $actions "setPassword" "PENDING" "password" "비밀번호 환경 변수가 설정되지 않았습니다." "SECRET_NOT_SET"
                    $pendingReasons.Add("비밀번호 환경 변수")
                } elseif ($passwordControl -and (Set-AutomationText $actionContext $passwordControl $secret -Sensitive)) {
                    Add-HtsActionRecord $reportingContext $actions "setPassword" "PASS" "password" "비밀번호를 입력했으며 값은 기록하지 않았습니다."
                } else {
                    Add-HtsActionRecord $reportingContext $actions "setPassword" "PENDING" "password" "신뢰도 높은 비밀번호 입력칸을 찾지 못했습니다." "LOCATOR_NOT_RESOLVED"
                    $pendingReasons.Add("비밀번호 입력칸")
                }
            }

            if (-not $scenarioMode) { foreach ($name in @($case.variables.Keys | Sort-Object)) {
                $dimensionRows = @($dataset.variables | Where-Object { $_.name -eq $name } | Select-Object -First 1)
                $dimension = if ($dimensionRows.Count -gt 0) { $dimensionRows[0] } else { [pscustomobject]@{name=$name;targetRole="condition:$name";controlKind="Auto";valueMatch="Value";required=$true;triggerQueryAfterChange=$true;sensitive=$false} }
                $variableExpectation=if($case.variableExpectedOutcomes -and $case.variableExpectedOutcomes.ContainsKey($name)){$case.variableExpectedOutcomes[$name]}else{$null}
                $variableOption=[pscustomobject]@{id="dataset-variable:$name";expectedOutcome=$variableExpectation}
                $resolvedVariableExpectation=Get-HtsExpectedOutcome $variableOption @($case.screen.expectedPopupPatterns)
                foreach($pattern in @($resolvedVariableExpectation.messagePatterns)){
                    if($pattern -and -not $executedExpectationPatterns.Contains([string]$pattern)){$executedExpectationPatterns.Add([string]$pattern)}
                }
                $role = if ($dimension.targetRole) { [string]$dimension.targetRole } else { "condition:$name" }
                $strategies = $null
                if ($case.screen.locators -and $case.screen.locators.PSObject.Properties.Name -contains $role) { $strategies = $case.screen.locators.$role }
                $control = Resolve-HtsRoleControl -Context $bindingContext -Screen $screen -Role $role -Strategies $strategies
                if ($control -and [Int64]$control.hwnd -ne 0) { $claimedHwnds[[Int64]$control.hwnd] = $true }
                $kind = if ($dimension.controlKind) { [string]$dimension.controlKind } else { "Auto" }
                $valueMatch = if ($dimension.valueMatch) { [string]$dimension.valueMatch } else { "Value" }
                if ($control -and (Invoke-HtsDatasetVariableAction -Context $actionContext -Window $control -ControlKind $kind -Value ([string]$case.variables[$name]) -ValueMatch $valueMatch -MaxOptions ([int]$dataset.autoExploration.maxOptionsPerControl))) {
                    Add-HtsActionRecord $reportingContext $actions "setCondition" "PASS" $name "$kind 방식으로 데이터셋 조건값을 적용했습니다. 기대 계약: $([string]$resolvedVariableExpectation.type) / $([string]$resolvedVariableExpectation.source) / $([string]$resolvedVariableExpectation.confidence)."
                    $variableRequirementRecord=$null
                    if([string]$resolvedVariableExpectation.type -in @('ValidationRequired','FailureRequired')){
                        $variableRequirementRecord=[pscustomobject]@{controlId="dataset-variable:$name";optionId=[string]$resolvedVariableExpectation.expectationId;outcome=$resolvedVariableExpectation;observations=(New-Object Collections.Generic.List[object])}
                        $variableRequirementRecord.observations.Add([pscustomobject]@{observationId="dataset-variable:$name-completion";kind='Success';executed=$true;evidencePresent=$true;evidenceRole='Action';checkpointRequired=$false;message='데이터셋 조건값 적용을 완료했습니다.';sourceCode='';source='dataset variable completion'})
                        $requiredExpectations.Add($variableRequirementRecord)
                    }
                    if($resolvedVariableExpectation.queryShouldComplete -eq $true){
                        $queryRequiredExpectations.Add([pscustomobject]@{name=$name;outcome=$resolvedVariableExpectation})
                    }
                    $variableDialogs=@(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
                    if($variableDialogs.Count -gt 0){
                        Add-PopupObservations $observationContext $popupObservations $variableDialogs $main $case.caseId ([string]$case.screen.screenNumber) $ReportDir @($resolvedVariableExpectation.messagePatterns) $mapOracle
                        $variableConnectionDialogs = @($variableDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                        if ($variableConnectionDialogs.Count -gt 0) {
                            throw "HTS_CONNECTION_LOST: 조건 입력 직후 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$variableConnectionDialogs[0].text)"
                        }
                        foreach($dialog in $variableDialogs){
                            $observation=New-HtsDialogObservation -Context $observationContext $dialog $mapOracle $resolvedVariableExpectation $caseErrorRegex
                            Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'dataset-variable' "dataset-variable:$name" ([string]$resolvedVariableExpectation.expectationId)
                        }
                        [void](Dismiss-HtsDialogs $actionContext $observationContext $RuntimeContext $main $secret)
                    }
                } else {
                    $required = ($null -eq $dimension.required -or [bool]$dimension.required)
                    Add-HtsActionRecord $reportingContext $actions "setCondition" $(if ($required) { "PENDING" } else { "PASS" }) $name "조건 컨트롤을 찾지 못했거나 지정값을 적용하지 못했습니다." "LOCATOR_OR_VALUE_NOT_RESOLVED"
                    if ($required) { $pendingReasons.Add("조건 컨트롤 $name") }
                }
            } }

            $frame.Main = $main
            $frame.Screen = $screen
            $frame.ScreenEdit = $screenEdit
            $frame.LogBefore = $logBefore
            $frame.TabOrderQueryControl = $tabOrderQueryControl
            $frame.TransactionAccountVerified = $transactionAccountVerified
            $frame.TransactionAccountEvidence = $transactionAccountEvidence
            $frame.TransactionAccountCandidate = $transactionAccountCandidate
            $frame.TransactionAccountFingerprint = $transactionAccountFingerprint
            [void](Invoke-HtsCaseAutoExploration -RunSpec $RunSpec -RunServices $RunServices -RunState $RunState -Frame $frame)
            [void](Invoke-HtsCaseLegacyQuery -RunSpec $RunSpec -RunServices $RunServices -RunState $RunState -Frame $frame)
            $main = $frame.Main
            $screen = $frame.Screen
            $screenEdit = $frame.ScreenEdit
            $mapQueryExecuted = [bool]$frame.MapQueryExecuted
            $mapReboundControls = [int]$frame.MapReboundControls
            $tabOrderQueryControl = $frame.TabOrderQueryControl
            $transactionAccountVerified = [bool]$frame.TransactionAccountVerified
            $transactionAccountEvidence = [string]$frame.TransactionAccountEvidence
            $transactionAccountCandidate = $frame.TransactionAccountCandidate
            $transactionAccountFingerprint = [string]$frame.TransactionAccountFingerprint
            $automationContractFailure = [bool]$frame.AutomationContractFailure
            $automationContractErrorCode = [string]$frame.AutomationContractErrorCode
        }

        $caseExpectedOutcome=Get-HtsExpectedOutcome $null @(@($case.screen.expectedPopupPatterns)+@($executedExpectationPatterns))
        $finalDialogs = @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
        if ($finalDialogs.Count -gt 0) {
            Add-PopupObservations $observationContext $popupObservations $finalDialogs $main $case.caseId ([string]$case.screen.screenNumber) $ReportDir @($caseExpectedOutcome.messagePatterns) $mapOracle
            $finalConnectionDialogs = @($finalDialogs | Where-Object { Test-HtsConnectionDialog $_ })
            if ($finalConnectionDialogs.Count -gt 0) {
                throw "HTS_CONNECTION_LOST: 케이스 종료 전 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$finalConnectionDialogs[0].text)"
            }
            foreach ($dialog in $finalDialogs) {
                $observation=New-HtsDialogObservation -Context $observationContext $dialog $mapOracle $caseExpectedOutcome $caseErrorRegex
                Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'final-dialog'
            }
        }
        $windowErrors = @(Get-ExplicitWindowErrors $observationContext $main $beforeErrorTexts $caseErrorRegex $secret $mapOracle)
        $logErrors = @(Get-LogErrors $observationContext $logBefore $caseErrorRegex $secret $mapOracle)
        foreach ($message in $windowErrors) {
            $observation=New-HtsSignalObservation -Context $observationContext ([string]$message) $mapOracle $caseExpectedOutcome $caseErrorRegex
            Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'window-text'
        }
        foreach ($message in $logErrors) {
            $observation=New-HtsSignalObservation -Context $observationContext ([string]$message) $mapOracle $caseExpectedOutcome $caseErrorRegex
            Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'log'
        }
        # Windows PowerShell 5.1은 빈 제네릭 List<object>를 @()로 감쌀 때 바인더 예외를 낼 수 있어 배열로 명시 변환한다.
        foreach($queryRequired in $queryRequiredExpectations.ToArray()){
            if(-not $mapQueryExecuted){
                $pendingReasons.Add("입력 또는 시나리오 단계 '$([string]$queryRequired.name)'의 기대 계약은 조회 완료가 필요하지만 조회를 실행하지 못했습니다: QUERY_EXPECTATION_NOT_EXECUTED")
            }
        }
        $signalGroupEvaluationCases=New-Object Collections.Generic.List[object]
        $signalGroupsByCaseId=@{}
        foreach($signalGroupKey in @($observationContext.CurrentSignalEvaluationGroups.Keys | Sort-Object)){
            $signalGroup=$observationContext.CurrentSignalEvaluationGroups[$signalGroupKey]
            $signalGroupCaseId="signal-group-{0:D6}" -f (Get-HtsNextObservationSequence -Context $observationContext)
            $signalGroupCase=[pscustomobject]@{caseId=$signalGroupCaseId;executed=$true;expectedResult=$signalGroup.expectedResult;observations=@($signalGroup.observations.ToArray())}
            $signalGroupEvaluationCases.Add($signalGroupCase)
            $observationContext.CurrentResultEvaluationCases.Add($signalGroupCase)
            $signalGroupsByCaseId[$signalGroupCaseId]=$signalGroup
        }
        if($signalGroupEvaluationCases.Count -gt 0){
            $signalGroupEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId="$($case.caseId)-signals";cases=@($signalGroupEvaluationCases.ToArray())}
            $signalGroupEvaluationOutput=Invoke-HtsRuleSuiteEvaluation -RunSpec $RunSpec -EvaluationDocument $signalGroupEvaluationDocument -InvocationId 'signal-groups'
            foreach($signalTestResult in @($signalGroupEvaluationOutput.results)){
                $signalGroup=$signalGroupsByCaseId[[string]$signalTestResult.caseId]
                $sourceObservation=$signalGroup.observation
                $oracleEvents.Add([pscustomobject]@{eventKey="evaluation|$([string]$signalTestResult.caseId)";stage=[string]$signalGroup.stage;controlId=[string]$signalGroup.controlId;optionId=[string]$signalGroup.optionId;eventType='SignalEvaluation';disposition=[string]$signalTestResult.disposition;expectedOutcomeType=[string]$sourceObservation.expectedOutcomeType;expectedOutcomeSource=[string]$sourceObservation.expectedOutcomeSource;expectedOutcomeConfidence=[string]$sourceObservation.expectedOutcomeConfidence;expectedOutcomeEvidence=@($sourceObservation.expectedOutcomeEvidence);expectationId=[string]$sourceObservation.expectationId;source='ResultEvaluator';sourceCode=[string]$signalTestResult.code;evaluationCode=[string]$signalTestResult.code;testStatus=[string]$signalTestResult.status;message=[string]$signalTestResult.reason;productDefect=[bool]$signalTestResult.productDefectDetected;requiresReview=[bool]$signalTestResult.requiresReview;testResult=$signalTestResult;detectedAt=(Get-Date).ToString('o')})
            }
        }
        $requiredEvaluationCases=New-Object Collections.Generic.List[object]
        $requiredRecordsByCaseId=@{}
        foreach($required in $requiredExpectations.ToArray()){
            $requiredCaseId="required-expectation-{0:D6}" -f (Get-HtsNextObservationSequence -Context $observationContext)
            $requiredEvaluationCase=[pscustomobject]@{
                caseId=$requiredCaseId;executed=$true
                expectedResult=[pscustomobject]@{
                    expectationId=[string]$required.outcome.expectationId;type=[string]$required.outcome.type
                    description=@($required.outcome.evidence) -join '; ';messagePatterns=@($required.outcome.messagePatterns);errorCodes=@($required.outcome.errorCodes)
                }
                observations=@($required.observations.ToArray())
            }
            $requiredEvaluationCases.Add($requiredEvaluationCase)
            $observationContext.CurrentResultEvaluationCases.Add($requiredEvaluationCase)
            $requiredRecordsByCaseId[$requiredCaseId]=$required
        }
        if($requiredEvaluationCases.Count -gt 0){
            $requiredEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId="$($case.caseId)-required-expectations";cases=@($requiredEvaluationCases.ToArray())}
            $requiredEvaluationOutput=Invoke-HtsRuleSuiteEvaluation -RunSpec $RunSpec -EvaluationDocument $requiredEvaluationDocument -InvocationId 'required-expectations'
            foreach($requiredTestResult in @($requiredEvaluationOutput.results)){
                $required=$requiredRecordsByCaseId[[string]$requiredTestResult.caseId]
                $requiredMessage="필수 기대 반응 평가: $([string]$required.outcome.type)/$([string]$required.controlId)/$([string]$required.optionId)"
                $oracleEvents.Add([pscustomobject]@{eventKey="required|$([string]$required.controlId)|$([string]$required.optionId)";stage='expectation';controlId=[string]$required.controlId;optionId=[string]$required.optionId;eventType='ExpectedOutcomeEvaluation';disposition=[string]$requiredTestResult.disposition;expectedOutcomeType=[string]$required.outcome.type;expectedOutcomeSource=[string]$required.outcome.source;expectedOutcomeConfidence=[string]$required.outcome.confidence;expectedOutcomeEvidence=@($required.outcome.evidence);expectationId=[string]$required.outcome.expectationId;source='ResultEvaluator';sourceCode=[string]$requiredTestResult.code;evaluationCode=[string]$requiredTestResult.code;testStatus=[string]$requiredTestResult.status;message=$requiredMessage;productDefect=[bool]$requiredTestResult.productDefectDetected;requiresReview=[bool]$requiredTestResult.requiresReview;testResult=$requiredTestResult;detectedAt=(Get-Date).ToString('o')})
            }
        }
        $currentMain = Get-WindowInfo ([IntPtr][Int64]$main.hwnd)
        if ($currentMain.hung) { $errors.Add("HTS 메인 창이 응답하지 않습니다.") }
        $signalEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId="$($case.caseId)-signals";cases=@($observationContext.CurrentResultEvaluationCases.ToArray())}
        $signalEvaluationOutput=Invoke-HtsRuleSuiteEvaluation -RunSpec $RunSpec -EvaluationDocument $signalEvaluationDocument -InvocationId 'case-signals'
        Add-HtsActionRecord $reportingContext $actions "evaluateExplicitErrors" ([string]$signalEvaluationOutput.overallResult.status) "popup/process/log" ([string]$signalEvaluationOutput.overallResult.reason)
    } catch {
        $executorException = $true
        # 예외 원문만으로는 PowerShell 바인딩 오류 위치를 알 수 없으므로 형식·행·스택을 실행 증거에 남긴다.
        $exceptionType = $_.Exception.GetType().FullName
        $exceptionLine = if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) { [int]$_.InvocationInfo.ScriptLineNumber } else { 0 }
        $exceptionStack = if ($_.ScriptStackTrace) { [string]$_.ScriptStackTrace } else { "" }
        $executorDiagnostic = Protect-Text ("{0} / line {1} / {2}" -f $exceptionType, $exceptionLine, $exceptionStack) $secret
        $safeExceptionMessage = Protect-Text $_.Exception.Message $secret
        if ($safeExceptionMessage -like 'HTS_CONNECTION_LOST:*') {
            $externalInterruption = $true
            $automationContractErrorCode = 'HTS_CONNECTION_LOST'
        } elseif ($safeExceptionMessage -like 'HTS_UI_ACCESS_DENIED:*' -or $safeExceptionMessage -like 'SCREEN_NAVIGATION_INPUT_UNAVAILABLE:*' -or $safeExceptionMessage -like 'SCREEN_NAVIGATION_TEXT_UNVERIFIED:*') {
            $automationContractFailure = $true
            $automationContractErrorCode = if ($safeExceptionMessage -like 'HTS_UI_ACCESS_DENIED:*') { 'HTS_UI_ACCESS_DENIED' } else { 'SCREEN_NAVIGATION_TEXT_UNVERIFIED' }
            $automationIssues.Add('HTS 화면번호 입력 결과를 업무 화면 생성으로 검증하지 못해 실제 화면 전환을 차단했습니다.')
        }
        $errors.Add($safeExceptionMessage)
        $automationIssues.Add("실행기 예외 위치: $executorDiagnostic")
        Add-HtsActionRecord $reportingContext $actions "executor" "ERROR" "runtime" $(if($externalInterruption){'HTS 연결 장애를 감지해 재접속·종료 버튼을 누르지 않고 실행을 중단했습니다.'}elseif($automationContractErrorCode -eq 'HTS_UI_ACCESS_DENIED'){'HTS UI 권한 경계로 화면 전환을 차단했습니다.'}elseif($automationContractErrorCode -eq 'SCREEN_NAVIGATION_TEXT_UNVERIFIED'){'HTS 화면번호 입력의 종단 간 검증을 완료하지 못해 화면 전환을 차단했습니다.'}else{"룰 실행기에서 예외가 발생했습니다: $executorDiagnostic"}) $(if($externalInterruption){'HTS_CONNECTION_LOST'}elseif($automationContractErrorCode -eq 'HTS_UI_ACCESS_DENIED'){'HTS_UI_ACCESS_DENIED'}elseif($automationContractErrorCode -eq 'SCREEN_NAVIGATION_TEXT_UNVERIFIED'){'SCREEN_NAVIGATION_TEXT_UNVERIFIED'}else{'EXECUTOR_EXCEPTION'})
        if (-not $main -or -not [TargetRuleNative]::IsWindow([IntPtr][Int64]$main.hwnd)) { $main = $null }
    }

    $screenshot = ""
    if ($errors.Count -gt 0) {
        $candidateScreenshot = Join-Path $screenshotsDir ("error-{0}-{1}.png" -f $case.screen.screenNumber, $case.caseId)
        if ($main -and [TargetRuleNative]::IsWindow([IntPtr][Int64]$main.hwnd) -and (Capture-HtsScreenshot $observationContext $main $candidateScreenshot)) {
            $screenshot = $candidateScreenshot
        }
    }
    $frame.Main = $main
    $frame.Screen = $screen
    $frame.ScreenEdit = $screenEdit
    $frame.ExistingScreenRequiredMissing = [bool]$existingScreenRequiredMissing
    $frame.UsedExistingTargetScreen = [bool]$usedExistingTargetScreen
    $frame.OpenedTargetScreenForRun = [bool]$openedTargetScreenForRun
    [void](Exit-HtsRuleSuiteCaseScreen -RunSpec $RunSpec -RunServices $RunServices -RunState $RunState -Frame $frame)
    $main = $frame.Main
    $screen = $frame.Screen
    $screenEdit = $frame.ScreenEdit
    $frame.Main = $main
    $frame.Screen = $screen
    $frame.ScreenEdit = $screenEdit
    $frame.Screenshot = $screenshot
    $frame.MapQueryExecuted = [bool]$mapQueryExecuted
    $frame.MapReboundControls = [int]$mapReboundControls
    $frame.AutomationContractFailure = [bool]$automationContractFailure
    $frame.AutomationContractErrorCode = [string]$automationContractErrorCode
    $frame.ExecutorException = [bool]$executorException
    $frame.ExecutorDiagnostic = [string]$executorDiagnostic
    $frame.ExternalInterruption = [bool]$externalInterruption
    $frame.ScreenOpenFailure = [bool]$screenOpenFailure
    $frame.ExistingScreenRequiredMissing = [bool]$existingScreenRequiredMissing
    $frame.UsedExistingTargetScreen = [bool]$usedExistingTargetScreen
    $frame.OpenedTargetScreenForRun = [bool]$openedTargetScreenForRun

    $caseCompletion = Complete-HtsRuleSuiteCaseResult -RunSpec $RunSpec -RunServices $RunServices -RunState $RunState -Frame $frame -TotalCases $cases.Count
    $RunState.Main = $main
    $RunState.ScreenEdit = $screenEdit
    [pscustomobject]@{
        CaseId = [string]$case.caseId
        ScreenNumber = [string]$case.screen.screenNumber
        StopRequested = [bool]$caseCompletion.StopRequested
    }
}
