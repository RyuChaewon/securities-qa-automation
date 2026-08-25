<#
.SYNOPSIS Approved control-plan action and checkpoint execution for one case.
.DESCRIPTION Executes existing plan items under safety policy and returns raw facts; it cannot decide the case verdict.
#>

# Executes the existing approved control-plan loop and updates the explicit case frame.
function Invoke-HtsCaseAutoExploration {
    param(
        [Parameter(Mandatory = $true)]$RunSpec,
        [Parameter(Mandatory = $true)]$RunServices,
        [Parameter(Mandatory = $true)]$RunState,
        [Parameter(Mandatory = $true)]$Frame
    )

    $dataset = $RunSpec.Dataset
    $testPack = $RunSpec.TestPack
    $scenarioMode = [bool]$RunSpec.ScenarioMode
    $scenarioPlan = $RunSpec.ScenarioPlan
    $physicalPlan = $RunSpec.PhysicalPlan
    $PlanOnly = [bool]$RunSpec.Input.PlanOnly
    $SubmitTransactionalDialogs = [bool]$RunSpec.Input.SubmitTransactionalDialogs
    $ReportDir = [string]$RunSpec.ReportDir
    $cliProject = [string]$RunSpec.CliProject
    $resultEvaluationTestPackPath = [string]$RunSpec.ResultEvaluationTestPackPath
    $resultEvaluationWorkingDirectory = [string]$RunSpec.ResultEvaluationWorkingDirectory
    $mapInitializationIssue = [string]$RunSpec.MapInitializationIssue
    $mapConfig = $dataset.autoExploration.mapBaseline

    $RuntimeContext = $RunServices.RuntimeContext
    $targetRuleContext = $RunServices.TargetRuleContext
    $targetStateErrorCodes = @($RunServices.TargetStateErrorCodes)
    $discoveryContext = $RunServices.DiscoveryContext
    $bindingContext = $RunServices.BindingContext
    $actionContext = $RunServices.ActionContext
    $observationContext = $RunServices.ObservationContext
    $evaluationAdapterContext = $RunServices.EvaluationAdapterContext
    $navigationContext = $RunServices.NavigationContext
    $reportingContext = $RunServices.ReportingContext

    $case = $Frame.Case
    $main = $Frame.Main
    $screen = $Frame.Screen
    $screenEdit = $Frame.ScreenEdit
    $secret = [string]$Frame.Secret
    $actions = $Frame.Actions
    $pendingReasons = $Frame.PendingReasons
    $errors = $Frame.Errors
    $automationIssues = $Frame.AutomationIssues
    $discoveredControls = $Frame.DiscoveredControls
    $controlTests = $Frame.ControlTests
    $popupObservations = $Frame.PopupObservations
    $oracleEvents = $Frame.OracleEvents
    $claimedHwnds = $Frame.ClaimedHwnds
    $caseErrorRegex = $Frame.CaseErrorRegex
    $executedExpectationPatterns = $Frame.ExecutedExpectationPatterns
    $requiredExpectations = $Frame.RequiredExpectations
    $queryRequiredExpectations = $Frame.QueryRequiredExpectations
    $logBefore = $Frame.LogBefore
    $inputMode = [string]$Frame.InputMode
    $mapModel = $Frame.MapModel
    $mapOracle = $Frame.MapOracle
    $mapBehavior = $Frame.MapBehavior
    $mapQueryExecuted = [bool]$Frame.MapQueryExecuted
    $mapReboundControls = [int]$Frame.MapReboundControls
    $tabOrderQueryControl = $Frame.TabOrderQueryControl
    $transactionAccountVerified = [bool]$Frame.TransactionAccountVerified
    $transactionAccountEvidence = [string]$Frame.TransactionAccountEvidence
    $transactionAccountCandidate = $Frame.TransactionAccountCandidate
    $transactionAccountFingerprint = [string]$Frame.TransactionAccountFingerprint
    $automationContractFailure = [bool]$Frame.AutomationContractFailure
    $automationContractErrorCode = [string]$Frame.AutomationContractErrorCode

            $autoPendingReasons = New-Object Collections.Generic.List[string]
            if ($dataset.autoExploration -and [bool]$dataset.autoExploration.enabled) {
                $initialControls = @(Get-HtsDiscoveredControls -Context $discoveryContext -Screen $screen -ScreenNumber ([string]$case.screen.screenNumber) -ClaimedHwnds $claimedHwnds)
                if ($scenarioMode -and [bool]$case.scenarioCase.transactional) {
                    $expectedAccount = ([string]$case.account.accountNumber -replace '\D','')
                    $allowObservedPrefilledAccount = [bool]$dataset.executionPolicy.allowObservedPrefilledTransactionalAccount -and $inputMode -eq 'Prefilled'
                    foreach ($accountCandidate in @($initialControls | Where-Object { [string]$_.mapKind -eq 'Account' -and [string]$_.definitionSource -eq 'MAP+Runtime' })) {
                        $accountLive = Resolve-RuleLiveControl $targetRuleContext $navigationContext $screen $accountCandidate
                        if (-not $accountLive) { continue }
                        $observedAccount = ([string]$accountLive.rawTitle -replace '\D','')
                        if (-not $observedAccount) { $observedAccount = ([string]$accountCandidate.initialValue -replace '\D','') }
                        if (-not $observedAccount) { continue }
                        $matchesConfiguredAccount = $expectedAccount -and $observedAccount -eq $expectedAccount
                        $matchesApprovedPrefilledPolicy = -not $expectedAccount -and $allowObservedPrefilledAccount -and $observedAccount.Length -ge 7
                        if ($matchesConfiguredAccount -or $matchesApprovedPrefilledPolicy) {
                            $transactionAccountVerified = $true
                            $transactionAccountCandidate = $accountCandidate
                            $transactionAccountFingerprint = Get-AccountFingerprint $observedAccount
                            $verificationMode = if ($matchesConfiguredAccount) { '데이터셋 계좌값 일치' } else { '승인된 사전입력 계좌 확인' }
                            $transactionAccountEvidence = "MAP $([string]$accountCandidate.mapScreenCode)/$([string]$accountCandidate.name) $verificationMode (지문 $transactionAccountFingerprint)"
                            break
                        }
                    }
                    Add-HtsActionRecord $reportingContext $actions 'verifyTransactionalAccount' $(if($transactionAccountVerified){'PASS'}else{'PENDING'}) ([string]$case.account.id) $(if($transactionAccountVerified){$transactionAccountEvidence}elseif(-not $expectedAccount -and -not $allowObservedPrefilledAccount){'데이터셋 계좌번호가 비어 있고 사전입력 계좌 실행 정책도 허용되지 않았습니다.'}else{'MAP Account 컨트롤에서 실행 가능한 계좌값을 확인하지 못했습니다.'}) $(if($transactionAccountVerified){''}else{'TRANSACTION_ACCOUNT_NOT_VERIFIED'})
                    if (-not $transactionAccountVerified) { $autoPendingReasons.Add('주문 실행 계좌 미확인') }
                }
                if ($mapModel) {
                    $mapDefinedCount=@($mapModel.controls | Where-Object isActionable).Count
                    $mapBoundCount=@($initialControls | Where-Object { $_.definitionSource -eq 'MAP+Runtime' -and [string]$_.mapScreenCode -eq [string]$mapModel.screenCode }).Count
                    $mapUnboundCount=@($initialControls | Where-Object { $_.definitionSource -eq 'MAP' -and -not $_.mapMatched -and [string]$_.mapScreenCode -eq [string]$mapModel.screenCode }).Count
                    if ($scenarioMode -and $physicalPlan) {
                        $fixedBindingCount = @($physicalPlan.resolvedBindings | Where-Object { [string]$_.scenarioId -eq [string]$case.scenarioCase.scenarioId }).Count
                        Add-HtsActionRecord $reportingContext $actions "bindMapModel" "PASS" ([string]$case.screen.screenNumber) "물리계획 1.1이 시나리오에 고정한 바인딩 $fixedBindingCount개를 실행 단계별로 재검증합니다. 전체 MAP 미결합 $mapUnboundCount개는 현재 시나리오 판정에 포함하지 않습니다."
                    } else {
                        Add-HtsActionRecord $reportingContext $actions "bindMapModel" $(if($mapUnboundCount-eq0){"PASS"}else{"PENDING"}) ([string]$case.screen.screenNumber) "MAP '$($mapModel.screenName)'의 조작 가능 컨트롤 $mapDefinedCount개 중 $mapBoundCount개를 HWND/UIA/탭 순회 결과에 결합했고 $mapUnboundCount개는 미결합으로 기록했습니다." $(if($mapUnboundCount-eq0){""}else{"MAP_CONTROL_NOT_BOUND"})
                        if($mapUnboundCount-gt0){$autoPendingReasons.Add("MAP 컨트롤 미결합 $mapUnboundCount개")}
                    }
                } elseif ($mapConfig -and [bool]$mapConfig.enabled) {
                    Add-HtsActionRecord $reportingContext $actions "bindMapModel" "PENDING" ([string]$case.screen.screenNumber) $(if($mapInitializationIssue){$mapInitializationIssue}else{"해당 화면 MAP 기준 모델을 찾지 못했습니다."}) "MAP_MODEL_NOT_FOUND"
                    $autoPendingReasons.Add("MAP 기준 모델 없음: $($case.screen.screenNumber)")
                }
                $tabQueryRows=@($initialControls | Where-Object { $_.controlKind -eq 'Button' -and ([string]$_.mapSemanticRole -eq 'Query' -or [string]$_.name -eq '조회(탭오더)' -or [string]$_.name -match '^BTN_(Comm|Search|Query)') } | Select-Object -First 1)
                if($tabQueryRows.Count -gt 0){$tabOrderQueryControl=$tabQueryRows[0]}
                foreach ($controlRow in $initialControls) { $discoveredControls.Add($controlRow) }
                $queue = New-Object Collections.ArrayList
                $controlById = @{}
                foreach ($controlRow in $initialControls) { $controlById[[string]$controlRow.controlId] = $controlRow }
                $scheduledPlanIds = @{}
                if ($scenarioMode) {
                    $initialPlans = @(Get-RuleScenarioPlanItems -Context $targetRuleContext -Controls $initialControls -ScenarioCase $case.scenarioCase)
                    foreach ($planRow in $initialPlans) {
                        if ($physicalPlan) { $planRow = Set-HtsScenarioPhysicalBinding -Context $bindingContext -PlanItem $planRow -ScenarioCase $case.scenarioCase -PhysicalPlan $physicalPlan }
                        [void]$queue.Add($planRow)
                        $scheduledPlanIds[[string]$planRow.planItemId] = $true
                    }
                    Add-HtsActionRecord $reportingContext $actions "discoverControls" "PASS" ([string]$case.screen.screenNumber) "콘텐츠 영역 컨트롤 $($initialControls.Count)개를 발견하고 시나리오 '$([string]$case.scenarioCase.scenarioId)'의 조작 단계 $($queue.Count)개만 계획했습니다."
                } else {
                    $initialPlans = @(Get-RuleControlPlanItems $targetRuleContext $initialControls)
                    $currentTabPlans = @($initialPlans | Where-Object {
                        $_.control.controlKind -eq "Tab" -and $_.option -and [string]$_.option.value -eq [string]$_.control.initialValue
                    })
                    $initialContentPlans = @($initialPlans | Where-Object { $_.control.controlKind -ne "Tab" })
                    $remainingTabPlans = @($initialPlans | Where-Object {
                        $_.control.controlKind -eq "Tab" -and -not ($_.option -and [string]$_.option.value -eq [string]$_.control.initialValue)
                    })
                    foreach ($planRow in @($currentTabPlans + $initialContentPlans + $remainingTabPlans)) {
                        [void]$queue.Add($planRow)
                        $scheduledPlanIds[[string]$planRow.planItemId] = $true
                    }
                    Add-HtsActionRecord $reportingContext $actions "discoverControls" "PASS" ([string]$case.screen.screenNumber) "콘텐츠 영역에서 컨트롤 $($initialControls.Count)개, 실행 계획 $($queue.Count)개를 생성했습니다."
                }

                $lastScenarioActionPopupHwnds = @()
                # Adapter가 선언한 상태 의존 동작은 Select + AssertSelected가 같은 케이스에서
                # 성공한 상태에서만 실행한다. 상태 전환 실패 뒤의 좌표 클릭을 차단한다.
                $verifiedTargetStateContexts = @{}
                $pendingTargetStateContexts = @{}
                for ($planIndex=0; $planIndex -lt $queue.Count; $planIndex++) {
                    $planItem = $queue[$planIndex]
                    if ($scenarioMode -and [string]$planItem.status -ne 'READY' -and (Test-HtsRequestedScreen $navigationContext $screen ([string]$case.screen.screenNumber))) {
                        $scenarioRefresh = @(Get-HtsDiscoveredControls -Context $discoveryContext -Screen $screen -ScreenNumber ([string]$case.screen.screenNumber) -ClaimedHwnds $claimedHwnds)
                        foreach ($refreshedControl in $scenarioRefresh) {
                            if (@($discoveredControls | Where-Object { [string]$_.controlId -eq [string]$refreshedControl.controlId -and [string]$_.stateContext -eq [string]$refreshedControl.stateContext }).Count -eq 0) {
                                $discoveredControls.Add($refreshedControl)
                            }
                        }
                        $replacement = @(Get-RuleScenarioPlanItems -Context $targetRuleContext -Controls $scenarioRefresh -ScenarioCase $case.scenarioCase | Where-Object scenarioStepId -eq ([string]$planItem.scenarioStepId) | Select-Object -First 1)
                        if ($replacement.Count -gt 0) {
                            if ($physicalPlan) { $replacement[0] = Set-HtsScenarioPhysicalBinding -Context $bindingContext -PlanItem $replacement[0] -ScenarioCase $case.scenarioCase -PhysicalPlan $physicalPlan }
                            if ([string]$replacement[0].status -eq 'READY') { $mapReboundControls++ }
                            $planItem = $replacement[0]
                            $queue[$planIndex] = $planItem
                        }
                    }
                    $planStarted = Get-Date
                    $option = $planItem.option
                    $expectedOutcome=Get-HtsExpectedOutcome $option @($case.screen.expectedPopupPatterns)
                    foreach($pattern in @($expectedOutcome.messagePatterns)){if($pattern -and -not $executedExpectationPatterns.Contains([string]$pattern)){$executedExpectationPatterns.Add([string]$pattern)}}
                    $requiredExpectationRecord=$null
                    if([string]$expectedOutcome.type -in @('ValidationRequired','FailureRequired')){
                        $requiredExpectationRecord=[pscustomobject]@{controlId=[string]$planItem.control.controlId;optionId=[string]$option.id;outcome=$expectedOutcome;observations=(New-Object Collections.Generic.List[object])}
                        $requiredExpectations.Add($requiredExpectationRecord)
                    }
                    if($expectedOutcome.queryShouldComplete -eq $true){
                        $queryRequiredExpectations.Add([pscustomobject]@{
                            name=$(if($scenarioMode){[string]$planItem.scenarioStepId}else{[string]$planItem.control.controlId})
                            outcome=$expectedOutcome
                        })
                    }
                    if ($PlanOnly -or $planItem.status -ne "READY") {
                        if (-not $PlanOnly -and $scenarioMode -and $physicalPlan) {
                            $automationContractFailure = $true
                            if (-not $automationContractErrorCode) { $automationContractErrorCode = if ([string]$planItem.errorCode) { [string]$planItem.errorCode } else { 'PHYSICAL_BINDING_DRIFT' } }
                            $automationIssues.Add("물리 실행 가능 시나리오의 단계가 실행 시점에 준비되지 않았습니다: $([string]$planItem.scenarioStepId)/$automationContractErrorCode")
                        }
                        $pendingCode = if ($PlanOnly) { "PLAN_ONLY" } else { [string]$planItem.errorCode }
                        $pendingOutput = if ($PlanOnly) { "계획 전용 실행이므로 조작하지 않았습니다." } else { [string]$planItem.control.pendingReason }
                        $controlEvaluation = Invoke-HtsRawObservationEvaluation -Context $evaluationAdapterContext `
                            $(if ($PlanOnly) { 'EvidenceMissing' } else { 'InfrastructureError' }) `
                            $pendingOutput `
                            $pendingCode `
                            $expectedOutcome `
                            $false `
                            $false `
                            'control-not-executed' `
                            $(if($scenarioMode -and [string]$planItem.scenarioAction -like 'Assert*'){'Checkpoint'}else{'Action'}) `
                            $(if($scenarioMode -and [string]$planItem.scenarioAction -like 'Assert*'){[bool]$planItem.checkpointRequired}else{$false})
                        $controlTestResult = $controlEvaluation.testResult
                        $controlTests.Add([pscustomobject]@{
                            scenarioId=$(if($scenarioMode){[string]$case.scenarioCase.scenarioId}else{''});scenarioTitle=$(if($scenarioMode){[string]$case.scenarioCase.scenarioTitle}else{''})
                            sourceTestCaseId=$(if($scenarioMode){[string]$case.scenarioCase.sourceTestCaseId}else{''});mapScreenCode=$(if($scenarioMode){[string]$planItem.mapScreenCode}else{''});stateContext=$(if($scenarioMode){[string]$planItem.stateContext}else{''});transactional=$(if($scenarioMode){[bool]$planItem.transactional}else{$false})
                            scenarioStepId=$(if($scenarioMode){[string]$planItem.scenarioStepId}else{''});scenarioSequence=$(if($scenarioMode){[int]$planItem.scenarioSequence}else{0});scenarioAction=$(if($scenarioMode){[string]$planItem.scenarioAction}else{''})
                            expectedObservation=$(if($scenarioMode){[string]$planItem.expectedObservation}else{''})
                            interactionStrategy=[string]$targetRuleContext.CurrentInteractionStrategy;coordinateFocusUsed=$false;coordinateFocusVerified=$false
                            planItemId=[string]$planItem.planItemId; controlId=[string]$planItem.control.controlId; controlKind=[string]$planItem.control.controlKind
                            controlName=[string]$planItem.control.name; optionId=$(if ($option) {[string]$option.id} else {""}); inputValue=$(if ($option) {[string]$option.value} else {""})
                            displayValue=$(if ($option) {[string]$option.displayValue} else {""}); status=[string]$controlTestResult.status; queryTriggered=$false; errorDetected=[bool]$controlTestResult.productDefectDetected
                            expectedOutcomeType=[string]$expectedOutcome.type;expectationSatisfied=[bool]$controlTestResult.expectationSatisfied;testResult=$controlTestResult
                            expectedOutcomeSource=[string]$expectedOutcome.source;expectedOutcomeConfidence=[string]$expectedOutcome.confidence;expectedOutcomeEvidence=@($expectedOutcome.evidence)
                            automationEngine='미실행'
                            output=$pendingOutput; errorCode=$pendingCode; screenshotPath=""; elapsedMs=[int64]((Get-Date)-$planStarted).TotalMilliseconds
                        })
                        $autoPendingReasons.Add("$($planItem.control.controlKind) $($planItem.control.name): $pendingCode")
                        continue
                    }

                    $requestedScreenNumber=[string]$case.screen.screenNumber
                    $errorCountBefore = $errors.Count
                    $popupCountBefore = $popupObservations.Count
                    $dialogHwndsBefore = if($scenarioMode){@(Get-HtsDialogs $observationContext $RuntimeContext $main $secret | ForEach-Object {[Int64]$_.window.hwnd} | Sort-Object -Unique)}else{@()}
                    $freshStepDialogs = @()
                    $transactionPreRecordedHwnds = @()
                    $assertedPopupScreenshot = ''
                    $queryTriggered = $false
                    $screenReopened = $false
                    $navigationHandled = $false
                    $restorationFailed = $false
                    $unexpectedScreenClose = $false
                    $targetStateContext = ''
                    $isTargetStateSelection = $false
                    $isTargetStateAssertion = $false

                    if(-not (Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)){
                        $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                    }
                    if(Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber){
                        [void](Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)
                        $mapStateBlockReason = ''
                        $planMapCode = ([string]$planItem.mapScreenCode).Trim().ToUpperInvariant()
                        if ($scenarioMode -and [string]$planItem.executionOrder -eq 'CoordinateFocus' -and $planMapCode -and
                            $RuntimeContext.InitiallyActiveMapScreenCodes.Count -gt 0 -and $RuntimeContext.InitiallyActiveMapScreenCodes -notcontains $planMapCode) {
                            $mapStateBlockReason = "내부화면 $planMapCode 는 현재 target의 초기 활성 MAP이 아니며 명시적 상태 전환 절차가 없습니다."
                        }
                        $transactionBlockReason = ''
                        if ([bool]$planItem.transactional) {
                            $policy = $dataset.executionPolicy
                            if (-not [bool]$policy.allowTransactionalActions) { $transactionBlockReason = '데이터셋이 주문/전송 실행을 허용하지 않았습니다.' }
                            elseif ([bool]$policy.requireApprovedPlanForTransactionalActions -and [string]$scenarioPlan.approvalStatus -ne 'Approved') { $transactionBlockReason = 'Approved 시나리오 계획이 아닙니다.' }
                            elseif (@($policy.allowedTransactionalAccountIds).Count -eq 0 -or @($policy.allowedTransactionalAccountIds) -notcontains [string]$case.account.id) { $transactionBlockReason = '현재 계좌 ID가 주문 실행 허용 목록에 없습니다.' }
                            elseif (@($policy.allowedTransactionalScreens).Count -eq 0 -or @($policy.allowedTransactionalScreens) -notcontains $requestedScreenNumber) { $transactionBlockReason = '현재 화면이 주문 실행 허용 목록에 없습니다.' }
                            elseif ([string]::IsNullOrWhiteSpace([string]$case.account.accountNumber) -and -not [bool]$policy.allowObservedPrefilledTransactionalAccount) { $transactionBlockReason = '테스트 계좌번호가 데이터셋에 없고 사전입력 계좌 실행 정책도 허용되지 않았습니다.' }
                            elseif (-not $transactionAccountVerified) { $transactionBlockReason = '현재 화면 계좌가 데이터셋 테스트 계좌와 일치한다고 확인되지 않았습니다.' }
                            elseif ($transactionAccountCandidate) {
                                $currentAccountLive = Resolve-RuleLiveControl $targetRuleContext $navigationContext $screen $transactionAccountCandidate
                                $currentAccountDigits = if ($currentAccountLive) { ([string]$currentAccountLive.rawTitle -replace '\D','') } else { '' }
                                if (-not $currentAccountDigits) { $currentAccountDigits = ([string]$transactionAccountCandidate.initialValue -replace '\D','') }
                                if (-not $currentAccountDigits -or (Get-AccountFingerprint $currentAccountDigits) -ne $transactionAccountFingerprint) {
                                    $transactionBlockReason = '주문 직전 계좌값이 사전 확인 상태와 달라졌습니다.'
                                }
                            }
                        }
                        $targetStateContext = [string]$planItem.stateContext
                        $statefulControl = Get-HtsTargetStatefulControlForContext $targetRuleContext.TargetAdapter $requestedScreenNumber $planMapCode $targetStateContext
                        $isTargetStateContext = $null -ne $statefulControl
                        $isTargetStateSelection = $isTargetStateContext -and [string]$planItem.controlLogicalName -eq [string]$statefulControl.logicalName -and [string]$planItem.scenarioAction -eq 'Select'
                        $isTargetStateAssertion = $isTargetStateContext -and [string]$planItem.controlLogicalName -eq [string]$statefulControl.logicalName -and [string]$planItem.scenarioAction -eq 'AssertSelected'
                        $requiresVerifiedTargetState = $isTargetStateContext -and -not $isTargetStateSelection -and -not $isTargetStateAssertion
                        if ($mapStateBlockReason) {
                            $invoke=[pscustomobject]@{success=$false;queryEligible=$false;errorCode='MAP_STATE_NOT_ACTIVATED';automationEngine='MAP state guard';output=$mapStateBlockReason}
                        } elseif ($requiresVerifiedTargetState -and -not $verifiedTargetStateContexts.ContainsKey($targetStateContext)) {
                            $invoke=[pscustomobject]@{success=$false;queryEligible=$false;errorCode=[string]$statefulControl.selectionRequiredErrorCode;automationEngine='Target state guard';output="Target state '$targetStateContext'의 Select + AssertSelected 성공 기록이 없어 해당 컨트롤 조작을 차단했습니다."}
                        } elseif ($transactionBlockReason) {
                            $invoke=[pscustomobject]@{success=$false;queryEligible=$false;errorCode='TRANSACTION_GUARD_BLOCKED';automationEngine='Transaction guard';output=$transactionBlockReason}
                        } elseif ([string]$planItem.scenarioAction -in @('AssertVisible','AssertEnabled','AssertSelected','AssertGrid')) {
                            $invoke = Invoke-RuleControlAssertion $targetRuleContext $navigationContext $screen $planItem
                        } elseif ([string]$planItem.scenarioAction -eq 'Restore') {
                            $restoreDialogs = @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
                            $restoreConnectionDialogs = @($restoreDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                            if ($restoreConnectionDialogs.Count -gt 0) {
                                throw "HTS_CONNECTION_LOST: 복구 단계에서 연결 장애 팝업을 발견해 자동 닫기를 중단했습니다."
                            }
                            if ($restoreDialogs.Count -eq 0) {
                                $invoke=[pscustomobject]@{success=$true;queryEligible=$false;errorCode='';automationEngine='Safe dialog restore';output='복구할 팝업이 없어 현재 target 상태를 유지했습니다.'}
                            } else {
                                $dismissedCount = Dismiss-HtsDialogs $actionContext $observationContext $RuntimeContext $main $secret
                                $remainingRestoreDialogs = @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret | Where-Object { -not (Test-HtsConnectionDialog $_) })
                                $restoreSucceeded = $remainingRestoreDialogs.Count -eq 0
                                $invoke=[pscustomobject]@{success=$restoreSucceeded;queryEligible=$false;errorCode=$(if($restoreSucceeded){''}else{'RESTORE_DIALOG_NOT_DISMISSED'});automationEngine='Safe dialog restore';output="dismissed=$dismissedCount, remaining=$($remainingRestoreDialogs.Count)"}
                            }
                        } elseif ([string]$planItem.scenarioAction -eq 'AssertPopup') {
                            Start-Sleep -Milliseconds 250
                            $activePopups = @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
                            $activePopupHwnds = @($activePopups | ForEach-Object {[Int64]$_.window.hwnd} | Sort-Object -Unique)
                            $matchedFreshHwnds = @($lastScenarioActionPopupHwnds | Where-Object {$activePopupHwnds -contains [Int64]$_} | Sort-Object -Unique)
                            $matchedObservation = @($popupObservations | Where-Object {$matchedFreshHwnds -contains [Int64]$_.windowHwnd} | Select-Object -Last 1)
                            if($matchedObservation.Count -gt 0){$assertedPopupScreenshot=[string]$matchedObservation[0].screenshotPath}
                            $popupAssertionSucceeded = $matchedFreshHwnds.Count -gt 0
                            $invoke=[pscustomobject]@{success=$popupAssertionSucceeded;queryEligible=$false;errorCode=$(if($popupAssertionSucceeded){''}else{'ASSERT_POPUP_NOT_OBSERVED'});automationEngine='Fresh popup observer';output="priorActionNewPopupCount=$($lastScenarioActionPopupHwnds.Count), activePopupCount=$($activePopupHwnds.Count), matchedFreshPopupCount=$($matchedFreshHwnds.Count), matchedHwnds=$($matchedFreshHwnds -join ',')"}
                        } elseif ([string]$planItem.scenarioAction -eq 'AssertNoTransmission') {
                            $transmissionDelta = Get-TransmissionDelta $observationContext $logBefore
                            $invoke=[pscustomobject]@{success=(-not [bool]$transmissionDelta.hasTransmission);queryEligible=$false;errorCode=$(if($transmissionDelta.hasTransmission){'ASSERT_TRANSMISSION_DETECTED'}else{''});automationEngine='Sensitive log delta';output=$(if($transmissionDelta.hasTransmission){"transmissionSources=$(@($transmissionDelta.sources)-join ',')"}else{'sensitiveTransmissionDelta=none'})}
                        } else {
                            $invoke = Invoke-HtsRuleControlPlanAction -Context $actionContext -NavigationContext $navigationContext -Screen $screen -PlanItem $planItem
                        }
                    }else{
                        $invoke=[pscustomobject]@{success=$false;queryEligible=$false;errorCode='TARGET_SCREEN_NOT_ACTIVE';output='대상 화면을 활성화하지 못해 좌표 입력을 차단했습니다.'}
                    }

                    # 실제 제출 모드는 주문 버튼 직후의 신규 확인창을 먼저 증적화한 뒤
                    # 입력 검증/오류가 아닌 명시적 거래 확인창 하나만 승인한다.
                    if ($invoke.success -and $SubmitTransactionalDialogs -and [bool]$planItem.transactional -and [string]$planItem.scenarioAction -in @('Click','DoubleClick')) {
                        $transactionDialogs = @()
                        for ($transactionDialogAttempt=0; $transactionDialogAttempt -lt 12; $transactionDialogAttempt++) {
                            Start-Sleep -Milliseconds 250
                            $transactionDialogs = @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret | Where-Object { $dialogHwndsBefore -notcontains [Int64]$_.window.hwnd })
                            if ($transactionDialogs.Count -gt 0) { break }
                        }
                        if ($transactionDialogs.Count -eq 0) {
                            $invoke.output = "$([string]$invoke.output); transactionSubmission=direct-or-no-confirmation-dialog"
                        } else {
                            Add-PopupObservations $observationContext -List $popupObservations -Dialogs $transactionDialogs -Main $main -CaseId $case.caseId -ScreenNumber $requestedScreenNumber -ReportBase $ReportDir -ExpectedPatterns @($expectedOutcome.messagePatterns) -MapOracle $mapOracle
                            $transactionPreRecordedHwnds = @($transactionDialogs | ForEach-Object { [Int64]$_.window.hwnd })
                            $eligibleTransactionDialogs = @($transactionDialogs | Where-Object { Test-HtsTransactionalConfirmationDialog $actionContext $_ $planItem })
                            if ($eligibleTransactionDialogs.Count -eq 1) {
                                $transactionSubmit = Submit-HtsTransactionalDialog $actionContext $eligibleTransactionDialogs[0] $planItem
                                $RunState.TransactionalActionCount = [int]$RunState.TransactionalActionCount + 1
                                $invoke.output = "$([string]$invoke.output); $([string]$transactionSubmit.output)"
                                if (-not [bool]$transactionSubmit.success) {
                                    $invoke.success = $false
                                    $invoke.errorCode = [string]$transactionSubmit.errorCode
                                }
                            } else {
                                foreach ($transactionDialog in $transactionDialogs) {
                                    $transactionObservation = New-HtsDialogObservation -Context $observationContext $transactionDialog $mapOracle $expectedOutcome $caseErrorRegex
                                    Add-HtsOracleObservation -Context $observationContext $oracleEvents $transactionObservation 'transaction-confirmation' ([string]$planItem.control.controlId) ([string]$option.id)
                                }
                                $invoke.success = $false
                                $invoke.errorCode = if ($eligibleTransactionDialogs.Count -gt 1) { 'TRANSACTION_CONFIRMATION_AMBIGUOUS' } else { 'TRANSACTION_CONFIRMATION_NOT_ELIGIBLE' }
                                $invoke.output = "$([string]$invoke.output); 입력 검증·오류 또는 모호한 팝업이어서 실제 승인하지 않았습니다. popupCount=$($transactionDialogs.Count), eligible=$($eligibleTransactionDialogs.Count)"
                            }
                        }
                    }
                    $isAssertionStep = [string]$planItem.scenarioAction -like 'Assert*'
                    if ($isTargetStateSelection) {
                        if ($invoke.success) { $pendingTargetStateContexts[$targetStateContext] = $true }
                        else { $pendingTargetStateContexts.Remove($targetStateContext); $verifiedTargetStateContexts.Remove($targetStateContext) }
                    }
                    if ($isTargetStateAssertion) {
                        if ($invoke.success -and $pendingTargetStateContexts.ContainsKey($targetStateContext)) { $verifiedTargetStateContexts[$targetStateContext] = $true }
                        else { $verifiedTargetStateContexts.Remove($targetStateContext) }
                    }
                    if ($isAssertionStep -and -not $invoke.success) {
                        $errors.Add("$([string]$planItem.scenarioAction) 실패: $([string]$planItem.expectedObservation) ($([string]$invoke.errorCode))")
                    }
                    $isExplicitScenarioQuery = $scenarioMode -and [string]$planItem.scenarioAction -eq 'Query'
                    if ($invoke.success -and ($isExplicitScenarioQuery -or [string]$planItem.control.mapSemanticRole -in @('Query','AutoQuery'))) {
                        $mapQueryExecuted = $true
                        $queryTriggered = $true
                        if($isExplicitScenarioQuery){
                            Start-Sleep -Milliseconds ([Math]::Max(500,[int]$dataset.executionPolicy.actionTimeoutMs))
                        }
                    }
                    if (-not $invoke.success) { $automationIssues.Add("컨트롤 '$($planItem.control.name)'의 '$($option.displayValue)' 동작을 완료하지 못했습니다: $($invoke.errorCode)") }
                    if (-not $invoke.success -and ([string]$invoke.errorCode -in @('PHYSICAL_BINDING_DRIFT','SCENARIO_CONTROL_NOT_BOUND','CONTROL_STALE','CONTROL_AMBIGUOUS','CONTROL_OUTSIDE_TARGET_SURFACE','CHECK_STATE_UNVERIFIABLE','INPUT_GUARD_BLOCKED','TARGET_SCREEN_NOT_ACTIVE','COORDINATE_FOCUS_SCREEN_CHANGED','COORDINATE_FOCUS_NOT_CONFIRMED','MAP_STATE_NOT_ACTIVATED','RESTORE_DIALOG_NOT_DISMISSED','TRANSACTION_CONFIRM_POLICY_NOT_FOUND','TRANSACTION_CONFIRM_BUTTON_NOT_FOUND','TRANSACTION_CONFIRM_DIALOG_REMAINED','TRANSACTION_CONFIRM_CLICK_FAILED','TRANSACTION_CONFIRMATION_AMBIGUOUS','TRANSACTION_CONFIRMATION_NOT_ELIGIBLE') -or $targetStateErrorCodes -contains [string]$invoke.errorCode)) {
                        $automationContractFailure = $true
                        if (-not $automationContractErrorCode) { $automationContractErrorCode = [string]$invoke.errorCode }
                    }

                    $stepDialogs = @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
                    if ($stepDialogs.Count -gt 0) {
                        $freshStepDialogs = @($stepDialogs | Where-Object {$dialogHwndsBefore -notcontains [Int64]$_.window.hwnd})
                        $dialogsToRecord = @(
                            if($scenarioMode){
                                if([string]$planItem.scenarioAction -ne 'AssertPopup'){@($freshStepDialogs | Where-Object { $transactionPreRecordedHwnds -notcontains [Int64]$_.window.hwnd })}
                            }else{$stepDialogs}
                        )
                        if(@($dialogsToRecord).Count -gt 0){
                            $popupRecordCountBefore=$popupObservations.Count
                            Add-PopupObservations $observationContext -List $popupObservations -Dialogs $dialogsToRecord -Main $main -CaseId $case.caseId -ScreenNumber $requestedScreenNumber -ReportBase $ReportDir -ExpectedPatterns @($expectedOutcome.messagePatterns) -MapOracle $mapOracle
                            $recordedPopupRows=@($popupObservations | Select-Object -Skip $popupRecordCountBefore)
                            if($recordedPopupRows.Count -ne $dialogsToRecord.Count){
                                throw "POPUP_EVIDENCE_RECORD_FAILED: 신규 팝업 $($dialogsToRecord.Count)건 중 $($recordedPopupRows.Count)건만 관찰 목록에 기록됐습니다."
                            }
                            if(@($recordedPopupRows | Where-Object {[string]::IsNullOrWhiteSpace([string]$_.screenshotPath)}).Count -gt 0){
                                throw 'POPUP_EVIDENCE_CAPTURE_FAILED: 신규 팝업의 실제 표시 스크린샷을 저장하지 못했습니다.'
                            }
                        }
                        $connectionDialogs = @($stepDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                        if ($connectionDialogs.Count -gt 0) {
                            throw "HTS_CONNECTION_LOST: 컨트롤 단계 직후 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$connectionDialogs[0].text)"
                        }
                        foreach ($dialog in $dialogsToRecord) {
                            $observation=New-HtsDialogObservation -Context $observationContext $dialog $mapOracle $expectedOutcome $caseErrorRegex
                            Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'control' ([string]$planItem.control.controlId) ([string]$option.id)
                        }
                        $nextScenarioAction = if ($scenarioMode -and $planIndex + 1 -lt $queue.Count) { [string]$queue[$planIndex + 1].scenarioAction } else { '' }
                        if ($nextScenarioAction -notin @('AssertPopup','Restore')) {
                            [void](Dismiss-HtsDialogs $actionContext $observationContext $RuntimeContext $main $secret)
                        }
                    }

                    $linkedScreens=@(Get-HtsLinkedScreens $navigationContext $main $requestedScreenNumber)
                    if($linkedScreens.Count -gt 0){
                        Add-LinkedScreenObservations $observationContext $RuntimeContext $popupObservations $linkedScreens $main $case.caseId $requestedScreenNumber $ReportDir $secret @($planItem.control.mapNavigationTargets)
                        $linkedTitles=@($linkedScreens | ForEach-Object { [string]$_.rawTitle }) -join ', '
                        $linkedClosed=Close-HtsLinkedScreens $navigationContext $main $requestedScreenNumber
                        $navigationHandled=$true
                        $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                        if(-not $screen){
                            $screenEdit=Find-ScreenNumberEdit $RuntimeContext $main
                            Open-HtsScreen $navigationContext $main $screenEdit $requestedScreenNumber
                            $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                            $screenReopened=($null -ne $screen)
                        }
                        if($screen){[void](Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)}
                        $restorationFailed=-not (Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber)
                        Add-HtsActionRecord $reportingContext $actions 'restoreAfterNavigation' $(if($restorationFailed){'PENDING'}else{'PASS'}) $requestedScreenNumber "연계 화면을 관찰하고 $linkedClosed/$($linkedScreens.Count)개를 닫은 뒤 대상 화면을 복원했습니다: $linkedTitles" $(if($restorationFailed){'TARGET_RESTORE_FAILED'}else{''})
                    }

                    $screenAlive=Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber
                    if(-not $screenAlive -and -not $navigationHandled){
                        $isButtonTransition=$invoke.success -and [string]$planItem.control.controlKind -eq 'Button' -and (
                            [string]$planItem.control.mapSemanticRole -eq 'Navigation' -or @($planItem.control.mapNavigationTargets).Count -gt 0
                        )
                        if($isButtonTransition){
                            Add-UnnumberedTransitionObservation $observationContext $RuntimeContext $popupObservations $main $case.caseId $requestedScreenNumber $ReportDir $secret
                            $navigationHandled=$true
                        }else{
                            $unexpectedScreenClose=$true
                            $errors.Add("컨트롤 조작 중 [$requestedScreenNumber] 화면이 예기치 않게 닫혔습니다.")
                        }
                        $screenEdit=Find-ScreenNumberEdit $RuntimeContext $main
                        Open-HtsScreen $navigationContext $main $screenEdit $requestedScreenNumber
                        $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                        $screenReopened=($null -ne $screen)
                        $screenAlive=Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber
                        if($isButtonTransition){
                            $restorationFailed=-not $screenAlive
                            Add-HtsActionRecord $reportingContext $actions 'restoreAfterUnnumberedTransition' $(if($restorationFailed){'PENDING'}else{'PASS'}) $requestedScreenNumber '버튼 조작으로 발생한 번호 없는 콘텐츠 전환을 기록하고 대상 화면을 다시 열었습니다.' $(if($restorationFailed){'TARGET_RESTORE_FAILED'}else{''})
                        }else{
                            Add-HtsActionRecord $reportingContext $actions 'reopenScreen' 'FAIL' $requestedScreenNumber '연계 화면 없이 대상 화면이 사라져 다시 열었습니다.' 'SCREEN_CLOSED_UNEXPECTEDLY'
                        }
                    }
                    if($screenReopened -and $screenAlive){$claimedHwnds=Get-HtsClaimedControlHwndMap -Context $bindingContext -Screen $screen -Case $case -Dataset $dataset}

                    $triggerQueryForPlanItem = if ($scenarioMode) { [bool]$planItem.triggerQueryAfterChange } else { [bool]$dataset.autoExploration.triggerQueryAfterStateChange }
                    if ($invoke.success -and $invoke.queryEligible -and -not $navigationHandled -and $screenAlive -and $triggerQueryForPlanItem) {
                        [void](Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)
                        $liveTabQuery=if($tabOrderQueryControl){Resolve-RuleLiveControl $targetRuleContext $navigationContext $screen $tabOrderQueryControl}else{$null}
                        if($liveTabQuery){
                            $queryResult=Invoke-FlaUiControlAction $actionContext $liveTabQuery 'invoke'
                            if(-not ([bool]$queryResult.success -and [bool]$queryResult.verified)){Click-Center $actionContext $liveTabQuery}
                        }else{Send-Key $actionContext ([byte]0x7B)}
                        Start-Sleep -Milliseconds ([Math]::Max(500,[int]$dataset.executionPolicy.actionTimeoutMs))
                        $queryTriggered = $true
                        $mapQueryExecuted = $true

                        $queryDialogs=@(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
                        if($queryDialogs.Count -gt 0){
                            Add-PopupObservations $observationContext $popupObservations $queryDialogs $main $case.caseId $requestedScreenNumber $ReportDir @($expectedOutcome.messagePatterns) $mapOracle
                            $queryConnectionDialogs = @($queryDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                            if ($queryConnectionDialogs.Count -gt 0) {
                                throw "HTS_CONNECTION_LOST: 조회 직후 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$queryConnectionDialogs[0].text)"
                            }
                            foreach($dialog in $queryDialogs){
                                $observation=New-HtsDialogObservation -Context $observationContext $dialog $mapOracle $expectedOutcome $caseErrorRegex
                                Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'query-after-control' ([string]$planItem.control.controlId) ([string]$option.id)
                            }
                            [void](Dismiss-HtsDialogs $actionContext $observationContext $RuntimeContext $main $secret)
                        }
                        $queryLinkedScreens=@(Get-HtsLinkedScreens $navigationContext $main $requestedScreenNumber)
                        if($queryLinkedScreens.Count -gt 0){
                            Add-LinkedScreenObservations $observationContext $RuntimeContext $popupObservations $queryLinkedScreens $main $case.caseId $requestedScreenNumber $ReportDir $secret @($planItem.control.mapNavigationTargets)
                            $queryLinkedClosed=Close-HtsLinkedScreens $navigationContext $main $requestedScreenNumber
                            $navigationHandled=$true
                            $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                            if(-not $screen){
                                $screenEdit=Find-ScreenNumberEdit $RuntimeContext $main
                                Open-HtsScreen $navigationContext $main $screenEdit $requestedScreenNumber
                                $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                                $screenReopened=($null -ne $screen)
                            }
                            if($screen){[void](Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)}
                            $restorationFailed=-not (Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber)
                            Add-HtsActionRecord $reportingContext $actions 'restoreAfterQueryNavigation' $(if($restorationFailed){'PENDING'}else{'PASS'}) $requestedScreenNumber "조회 후 열린 연계 화면 $queryLinkedClosed/$($queryLinkedScreens.Count)개를 닫고 대상 화면을 복원했습니다." $(if($restorationFailed){'TARGET_RESTORE_FAILED'}else{''})
                        }
                        $screenAlive=Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber
                        if(-not $screenAlive -and $queryLinkedScreens.Count -eq 0){
                            Add-UnnumberedTransitionObservation $observationContext $RuntimeContext $popupObservations $main $case.caseId $requestedScreenNumber $ReportDir $secret
                            $navigationHandled=$true
                            $screenEdit=Find-ScreenNumberEdit $RuntimeContext $main
                            Open-HtsScreen $navigationContext $main $screenEdit $requestedScreenNumber
                            $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                            $screenReopened=($null -ne $screen)
                            $screenAlive=Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber
                            $restorationFailed=-not $screenAlive
                            Add-HtsActionRecord $reportingContext $actions 'restoreAfterQueryTransition' $(if($restorationFailed){'PENDING'}else{'PASS'}) $requestedScreenNumber '조회 후 번호 없는 콘텐츠 전환을 기록하고 대상 화면을 다시 열었습니다.' $(if($restorationFailed){'TARGET_RESTORE_FAILED'}else{''})
                        }
                    }

                    if ($scenarioMode) {
                        if ([string]$planItem.scenarioAction -eq 'AssertPopup') {
                            $lastScenarioActionPopupHwnds = @()
                        } elseif ([string]$planItem.scenarioAction -notlike 'Assert*') {
                            $lastScenarioActionPopupHwnds = @($freshStepDialogs | ForEach-Object {[Int64]$_.window.hwnd} | Sort-Object -Unique)
                        }
                    }

                    $newErrors = $errors.Count -gt $errorCountBefore
                    $queryExpectationIncomplete = $false
                    $hasDeferredScenarioQuery = $false
                    if($scenarioMode -and $expectedOutcome.queryShouldComplete -eq $true -and -not $queryTriggered){
                        for($futurePlanIndex=$planIndex+1;$futurePlanIndex -lt $queue.Count;$futurePlanIndex++){
                            if([string]$queue[$futurePlanIndex].scenarioAction -eq 'Query'){
                                $hasDeferredScenarioQuery=$true
                                break
                            }
                        }
                    }
                    if ($expectedOutcome.queryShouldComplete -eq $true -and -not $queryTriggered -and -not $hasDeferredScenarioQuery) {
                        $queryExpectationIncomplete = $true
                        $automationIssues.Add("컨트롤 '$($planItem.control.name)'의 '$($option.displayValue)' 값은 조회 완료가 필요하지만 조회를 실행하지 못했습니다: QUERY_EXPECTATION_NOT_EXECUTED")
                        $autoPendingReasons.Add("$($planItem.control.controlKind) $($planItem.control.name): QUERY_EXPECTATION_NOT_EXECUTED")
                    }
                    $controlObservationKind = if ($unexpectedScreenClose -or $newErrors -or ($isAssertionStep -and -not $invoke.success)) { 'ProductFailure' } elseif (-not $invoke.success -or $restorationFailed -or $queryExpectationIncomplete) { 'EvidenceMissing' } else { 'Success' }
                    $controlObservationCode = if (-not $invoke.success) {[string]$invoke.errorCode} elseif ($restorationFailed) {'TARGET_RESTORE_FAILED'} elseif ($queryExpectationIncomplete) {'QUERY_EXPECTATION_NOT_EXECUTED'} elseif ($unexpectedScreenClose) {'SCREEN_CLOSED_UNEXPECTEDLY'} elseif ($newErrors) {'PRODUCT_DEFECT_DETECTED'} else {''}
                    $controlCompletionExpectation = [pscustomobject]@{ type='Success';expectationId=[string]$expectedOutcome.expectationId;messagePatterns=@();errorCodes=@();evidence=@('컨트롤 실행 완료 계약') }
                    $controlEvaluation = Invoke-HtsRawObservationEvaluation -Context $evaluationAdapterContext `
                        $controlObservationKind `
                        ([string]$invoke.output) `
                        $controlObservationCode `
                        $controlCompletionExpectation `
                        ([bool]($invoke.success -or $newErrors -or $isAssertionStep)) `
                        ($controlObservationKind -ne 'EvidenceMissing') `
                        'control-completion' `
                        $(if($isAssertionStep){'Checkpoint'}else{'Action'}) `
                        $(if($isAssertionStep){[bool]$planItem.checkpointRequired}else{$false})
                    $controlTestResult = $controlEvaluation.testResult
                    if($requiredExpectationRecord){$requiredExpectationRecord.observations.Add(@($controlEvaluation.evaluationCase.observations)[0])}
                    $status = [string]$controlTestResult.status
                    $shot = $assertedPopupScreenshot
                    if ($popupObservations.Count -gt $popupCountBefore) { $shot = [string]$popupObservations[$popupObservations.Count-1].screenshotPath }
                    $controlTests.Add([pscustomobject]@{
                        scenarioId=$(if($scenarioMode){[string]$case.scenarioCase.scenarioId}else{''});scenarioTitle=$(if($scenarioMode){[string]$case.scenarioCase.scenarioTitle}else{''})
                        sourceTestCaseId=$(if($scenarioMode){[string]$case.scenarioCase.sourceTestCaseId}else{''});mapScreenCode=$(if($scenarioMode){[string]$planItem.mapScreenCode}else{''});stateContext=$(if($scenarioMode){[string]$planItem.stateContext}else{''});transactional=$(if($scenarioMode){[bool]$planItem.transactional}else{$false})
                        scenarioStepId=$(if($scenarioMode){[string]$planItem.scenarioStepId}else{''});scenarioSequence=$(if($scenarioMode){[int]$planItem.scenarioSequence}else{0});scenarioAction=$(if($scenarioMode){[string]$planItem.scenarioAction}else{''})
                        expectedObservation=$(if($scenarioMode){[string]$planItem.expectedObservation}else{''})
                        interactionStrategy=$(if($invoke.PSObject.Properties.Name -contains 'interactionStrategy'){[string]$invoke.interactionStrategy}else{[string]$targetRuleContext.CurrentInteractionStrategy})
                        coordinateFocusUsed=$(if($invoke.PSObject.Properties.Name -contains 'coordinateFocusUsed'){[bool]$invoke.coordinateFocusUsed}else{$false})
                        coordinateFocusVerified=$(if($invoke.PSObject.Properties.Name -contains 'coordinateFocusVerified'){[bool]$invoke.coordinateFocusVerified}else{$false})
                        planItemId=[string]$planItem.planItemId; controlId=[string]$planItem.control.controlId; controlKind=[string]$planItem.control.controlKind
                        controlName=[string]$planItem.control.name; optionId=[string]$option.id; inputValue=$(if ($planItem.control.controlKind -in @("Text","Date")) {[string]$option.value} else {""})
                        displayValue=[string]$option.displayValue; status=$status; queryTriggered=$queryTriggered; errorDetected=[bool]$controlTestResult.productDefectDetected
                        expectedOutcomeType=[string]$expectedOutcome.type;expectationSatisfied=[bool]$controlTestResult.expectationSatisfied;testResult=$controlTestResult
                        expectedOutcomeSource=[string]$expectedOutcome.source;expectedOutcomeConfidence=[string]$expectedOutcome.confidence;expectedOutcomeEvidence=@($expectedOutcome.evidence)
                        automationEngine=$(if($invoke.PSObject.Properties.Name -contains 'automationEngine'){[string]$invoke.automationEngine}else{'Win32 fallback'})
                        bindingResolution=$(if($invoke.PSObject.Properties.Name -contains 'resolution'){$invoke.resolution}else{$null})
                        output=([string]$invoke.output + $(if($navigationHandled){' 연계 화면을 관찰·정리하고 원래 화면으로 복귀했습니다.'}elseif($screenReopened){' 화면을 다시 열어 다음 항목을 계속했습니다.'}else{''}))
                        errorCode=[string]$controlTestResult.code
                        screenshotPath=$shot; elapsedMs=[int64]((Get-Date)-$planStarted).TotalMilliseconds
                    })

                    if (-not $scenarioMode -and (Test-HtsRequestedScreen $navigationContext $screen ([string]$case.screen.screenNumber))) {
                        $refreshed = @(Get-HtsDiscoveredControls -Context $discoveryContext -Screen $screen -ScreenNumber ([string]$case.screen.screenNumber) -ClaimedHwnds $claimedHwnds)
                        $newPlans = New-Object Collections.Generic.List[object]
                        foreach ($refreshedControl in $refreshed) {
                            $controlId = [string]$refreshedControl.controlId
                            $controlForPlan = $refreshedControl
                            $isRuntimeUpgrade = $false
                            if ($controlById.ContainsKey($controlId)) {
                                $existingControl = $controlById[$controlId]
                                $isRuntimeUpgrade = (
                                    ([string]$existingControl.definitionSource -eq 'MAP' -and [string]$refreshedControl.definitionSource -eq 'MAP+Runtime') -or
                                    (@($existingControl.options).Count -lt @($refreshedControl.options).Count)
                                )
                                if ($isRuntimeUpgrade) {
                                    foreach ($property in $refreshedControl.PSObject.Properties) {
                                        $existingControl | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
                                    }
                                    $controlForPlan = $existingControl
                                    if ([string]$existingControl.mapModelId) { $mapReboundControls++ }
                                }
                            } else {
                                $controlById[$controlId] = $refreshedControl
                                $discoveredControls.Add($refreshedControl)
                                $isRuntimeUpgrade = $true
                            }
                            if (-not $isRuntimeUpgrade) { continue }
                            if($controlForPlan.controlKind -eq 'Button' -and ([string]$controlForPlan.mapSemanticRole -eq 'Query' -or [string]$controlForPlan.name -eq '조회(탭오더)' -or [string]$controlForPlan.name -match '^BTN_(Comm|Search|Query)')){$tabOrderQueryControl=$controlForPlan}
                            foreach ($newPlan in @(Get-RuleControlPlanItems $targetRuleContext @($controlForPlan))) {
                                if (-not $scheduledPlanIds.ContainsKey([string]$newPlan.planItemId)) {
                                    $scheduledPlanIds[[string]$newPlan.planItemId] = $true
                                    $newPlans.Add($newPlan)
                                }
                            }
                        }
                        for ($newIndex=$newPlans.Count-1; $newIndex -ge 0; $newIndex--) {
                            if ($queue.Count -lt [int]$dataset.autoExploration.maxActionsPerScreen) { [void]$queue.Insert($planIndex+1,$newPlans[$newIndex]) }
                        }
                    }
                }
                if ($mapReboundControls -gt 0) {
                    Add-HtsActionRecord $reportingContext $actions 'rediscoverMapControls' 'PASS' ([string]$case.screen.screenNumber) "상태 변경 뒤 새로 활성화되거나 선택지가 늘어난 MAP 컨트롤 $mapReboundControls건을 다시 결합해 실행 계획에 추가했습니다."
                } elseif ($mapBehavior -and @($mapBehavior.stateControllerControls).Count -gt 0) {
                    Add-HtsActionRecord $reportingContext $actions 'rediscoverMapControls' 'PASS' ([string]$case.screen.screenNumber) '상태 변경마다 MAP 컨트롤을 다시 탐색했으며 추가 활성화된 컨트롤은 없었습니다.'
                }
                $controlEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId="$($case.caseId)-controls";cases=@($observationContext.CurrentResultEvaluationCases.ToArray())}
                $controlEvaluationOutput=Invoke-HtsRuleSuiteEvaluation -RunSpec $RunSpec -EvaluationDocument $controlEvaluationDocument -InvocationId 'case-controls'
                Add-HtsActionRecord $reportingContext $actions "executeControlOptions" ([string]$controlEvaluationOutput.overallResult.status) "content controls" "컨트롤 선택지 $($controlTests.Count)개를 계획 또는 실행했습니다. $([string]$controlEvaluationOutput.overallResult.reason)"
            }

    $Frame.Main = $main
    $Frame.Screen = $screen
    $Frame.ScreenEdit = $screenEdit
    $Frame.AutoPendingReasons = $autoPendingReasons
    $Frame.MapQueryExecuted = [bool]$mapQueryExecuted
    $Frame.MapReboundControls = [int]$mapReboundControls
    $Frame.TabOrderQueryControl = $tabOrderQueryControl
    $Frame.TransactionAccountVerified = [bool]$transactionAccountVerified
    $Frame.TransactionAccountEvidence = [string]$transactionAccountEvidence
    $Frame.TransactionAccountCandidate = $transactionAccountCandidate
    $Frame.TransactionAccountFingerprint = [string]$transactionAccountFingerprint
    $Frame.AutomationContractFailure = [bool]$automationContractFailure
    $Frame.AutomationContractErrorCode = [string]$automationContractErrorCode
    $Frame
}
