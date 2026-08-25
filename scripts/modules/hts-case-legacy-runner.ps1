<#
.SYNOPSIS Legacy non-scenario query compatibility phase for one case.
.DESCRIPTION Preserves the existing query trigger behavior without owning screen order, verdicts, or reports.
#>

# Runs the approved legacy query path and records raw observations in the shared case frame.
function Invoke-HtsCaseLegacyQuery {
    param(
        [Parameter(Mandatory = $true)]$RunSpec,
        [Parameter(Mandatory = $true)]$RunServices,
        [Parameter(Mandatory = $true)]$RunState,
        [Parameter(Mandatory = $true)]$Frame
    )

    $dataset = $RunSpec.Dataset
    $scenarioMode = [bool]$RunSpec.ScenarioMode
    $PlanOnly = [bool]$RunSpec.Input.PlanOnly
    $ReportDir = [string]$RunSpec.ReportDir

    $RuntimeContext = $RunServices.RuntimeContext
    $targetRuleContext = $RunServices.TargetRuleContext
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
    $queryTrigger = [string]$Frame.QueryTrigger
    $actions = $Frame.Actions
    $pendingReasons = $Frame.PendingReasons
    $errors = $Frame.Errors
    $automationIssues = $Frame.AutomationIssues
    $controlTests = $Frame.ControlTests
    $popupObservations = $Frame.PopupObservations
    $oracleEvents = $Frame.OracleEvents
    $caseErrorRegex = $Frame.CaseErrorRegex
    $executedExpectationPatterns = $Frame.ExecutedExpectationPatterns
    $mapOracle = $Frame.MapOracle
    $mapBehavior = $Frame.MapBehavior
    $mapQueryExecuted = [bool]$Frame.MapQueryExecuted
    $tabOrderQueryControl = $Frame.TabOrderQueryControl
    $autoPendingReasons = $Frame.AutoPendingReasons

            if (-not $PlanOnly -and -not $scenarioMode) {
                $requestedScreenNumber=[string]$case.screen.screenNumber
                if(-not (Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)){
                    $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                }
                $queryStrategies = if ($case.screen.locators -and $case.screen.locators.query) { $case.screen.locators.query } else { $dataset.defaultLocators.query }
                $queryControls = if(Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber){@(Get-HtsRequiredQueryControls -Context $bindingContext -Screen $screen -Strategies $queryStrategies)}else{@()}
                if($tabOrderQueryControl -and (Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber)){
                    $liveTabQuery=Resolve-RuleLiveControl $targetRuleContext $navigationContext $screen $tabOrderQueryControl
                    if($liveTabQuery){$queryControls=@($liveTabQuery)+@($queryControls)}
                }
                $queryControls=@($queryControls | Group-Object { "{0}:{1}" -f [int](($_.rect.left+$_.rect.right)/2),[int](($_.rect.top+$_.rect.bottom)/2) } | ForEach-Object {$_.Group[0]})
                if ($queryControls.Count -gt 0) {
                    for ($queryIndex=0; $queryIndex -lt $queryControls.Count; $queryIndex++) {
                        $queryStarted=Get-Date
                        $queryControl=$queryControls[$queryIndex]
                        if(-not (Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)){
                            $automationIssues.Add('필수 조회 직전에 대상 화면을 활성화하지 못했습니다: TARGET_SCREEN_NOT_ACTIVE')
                            break
                        }
                        try {
                            $queryResult=Invoke-FlaUiControlAction $actionContext $queryControl 'invoke'
                            $queryActionEngine=if([bool]$queryResult.success -and [bool]$queryResult.verified){'FlaUI.UIA3'}else{'Win32 fallback'}
                            if($queryActionEngine -eq 'Win32 fallback'){Click-Center $actionContext $queryControl}
                            $mapQueryExecuted = $true
                        } catch {
                            $guardMessage=Protect-Text $_.Exception.Message $secret
                            $queryExpectation = [pscustomobject]@{type='Success';expectationId="required-query-$queryIndex";messagePatterns=@();errorCodes=@();evidence=@('필수 조회 실행 계약')}
                            $guardEvaluation = Invoke-HtsRawObservationEvaluation -Context $evaluationAdapterContext 'EvidenceMissing' $guardMessage 'INPUT_GUARD_BLOCKED' $queryExpectation $false $false 'required-query-guard' 'Action' $false
                            $guardTestResult = $guardEvaluation.testResult
                            $controlTests.Add([pscustomobject]@{
                                planItemId="REQUIRED-QUERY-$queryIndex";controlId="REQUIRED-QUERY-$queryIndex";controlKind="Button";controlName='조회'
                                optionId='click';inputValue='';displayValue='조회';status=[string]$guardTestResult.status;queryTriggered=$false;errorDetected=[bool]$guardTestResult.productDefectDetected;testResult=$guardTestResult
                                output="전경 안전 검증으로 필수 조회 입력을 차단했습니다: $guardMessage";errorCode=[string]$guardTestResult.code;screenshotPath='';elapsedMs=[int64]((Get-Date)-$queryStarted).TotalMilliseconds
                            })
                            Add-HtsActionRecord $reportingContext $actions 'invokeQuery' 'PENDING' '조회' '전경 안전 검증으로 필수 조회 입력을 차단했습니다.' 'INPUT_GUARD_BLOCKED'
                            $automationIssues.Add("필수 조회 입력 차단: $guardMessage")
                            break
                        }
                        Start-Sleep -Milliseconds ([Math]::Max(500,[int]$dataset.executionPolicy.actionTimeoutMs))

                        $queryDialogs=@(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
                        if($queryDialogs.Count -gt 0){
                            $caseExpectedOutcome=Get-HtsExpectedOutcome $null @(@($case.screen.expectedPopupPatterns)+@($executedExpectationPatterns))
                            Add-PopupObservations $observationContext $popupObservations $queryDialogs $main $case.caseId $requestedScreenNumber $ReportDir @($caseExpectedOutcome.messagePatterns) $mapOracle
                            $requiredQueryConnectionDialogs = @($queryDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                            if ($requiredQueryConnectionDialogs.Count -gt 0) {
                                throw "HTS_CONNECTION_LOST: 필수 조회 직후 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$requiredQueryConnectionDialogs[0].text)"
                            }
                            foreach($dialog in $queryDialogs){
                                $observation=New-HtsDialogObservation -Context $observationContext $dialog $mapOracle $caseExpectedOutcome $caseErrorRegex
                                Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'required-query'
                            }
                            [void](Dismiss-HtsDialogs $actionContext $observationContext $RuntimeContext $main $secret)
                        }
                        $queryLinkedScreens=@(Get-HtsLinkedScreens $navigationContext $main $requestedScreenNumber)
                        $queryNavigationHandled=$false
                        if($queryLinkedScreens.Count -gt 0){
                            Add-LinkedScreenObservations $observationContext $RuntimeContext $popupObservations $queryLinkedScreens $main $case.caseId $requestedScreenNumber $ReportDir $secret @($tabOrderQueryControl.mapNavigationTargets)
                            $queryLinkedClosed=Close-HtsLinkedScreens $navigationContext $main $requestedScreenNumber
                            $queryNavigationHandled=$true
                            $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                            if(-not $screen){
                                $screenEdit=Find-ScreenNumberEdit $RuntimeContext $main
                                Open-HtsScreen $navigationContext $main $screenEdit $requestedScreenNumber
                                $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                            }
                            if($screen){[void](Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)}
                            Add-HtsActionRecord $reportingContext $actions 'restoreAfterRequiredQuery' $(if(Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber){'PASS'}else{'PENDING'}) $requestedScreenNumber "필수 조회 후 열린 연계 화면 $queryLinkedClosed/$($queryLinkedScreens.Count)개를 닫고 대상 화면을 복원했습니다." $(if(Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber){''}else{'TARGET_RESTORE_FAILED'})
                        }
                        $queryAlive=Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber
                        if(-not $queryAlive -and -not $queryNavigationHandled){
                            Add-UnnumberedTransitionObservation $observationContext $RuntimeContext $popupObservations $main $case.caseId $requestedScreenNumber $ReportDir $secret
                            $queryNavigationHandled=$true
                            $screenEdit=Find-ScreenNumberEdit $RuntimeContext $main
                            Open-HtsScreen $navigationContext $main $screenEdit $requestedScreenNumber
                            $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                            if($screen){[void](Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)}
                            $queryAlive=Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber
                            Add-HtsActionRecord $reportingContext $actions 'restoreAfterRequiredQueryTransition' $(if($queryAlive){'PASS'}else{'PENDING'}) $requestedScreenNumber '필수 조회 후 번호 없는 콘텐츠 전환을 기록하고 대상 화면을 다시 열었습니다.' $(if($queryAlive){''}else{'TARGET_RESTORE_FAILED'})
                        }
                        $queryObservationKind=if($queryAlive){'Success'}elseif($queryNavigationHandled){'EvidenceMissing'}else{'ProductFailure'}
                        $queryObservationCode=if($queryAlive){''}elseif($queryNavigationHandled){'TARGET_RESTORE_FAILED'}else{'SCREEN_CLOSED_UNEXPECTEDLY'}
                        $queryName=if($queryControl.rawTitle){[string]$queryControl.rawTitle}elseif($tabOrderQueryControl){[string]$tabOrderQueryControl.name}else{"조회"}
                        $queryExpectation = [pscustomobject]@{type='Success';expectationId="required-query-$queryIndex";messagePatterns=@();errorCodes=@();evidence=@('필수 조회 실행 계약')}
                        $queryEvaluation = Invoke-HtsRawObservationEvaluation -Context $evaluationAdapterContext $queryObservationKind '활성화된 조회 버튼을 필수 단계에서 실제 클릭했습니다.' $queryObservationCode $queryExpectation $true ($queryObservationKind -ne 'EvidenceMissing') 'required-query' 'Action' $false
                        $queryTestResult = $queryEvaluation.testResult
                        $queryStatus = [string]$queryTestResult.status
                        $controlTests.Add([pscustomobject]@{
                            planItemId="REQUIRED-QUERY-$queryIndex";controlId="REQUIRED-QUERY-$queryIndex";controlKind="Button";controlName=$queryName
                            optionId="click";inputValue="";displayValue=$queryName;status=$queryStatus;queryTriggered=$true;errorDetected=[bool]$queryTestResult.productDefectDetected;testResult=$queryTestResult
                            automationEngine=$queryActionEngine
                            output="활성화된 조회 버튼을 필수 단계에서 실제 클릭했습니다.";errorCode=[string]$queryTestResult.code;screenshotPath="";elapsedMs=[int64]((Get-Date)-$queryStarted).TotalMilliseconds
                        })
                        Add-HtsActionRecord $reportingContext $actions "invokeQuery" $queryStatus $queryName "활성화된 조회 버튼을 필수 단계에서 실제 클릭했습니다." $(if($queryAlive){""}elseif($queryNavigationHandled){'TARGET_RESTORE_FAILED'}else{"SCREEN_CLOSED_UNEXPECTEDLY"})
                        if (-not $queryAlive -and -not $queryNavigationHandled) { $errors.Add("조회 버튼 클릭 후 [$requestedScreenNumber] 화면이 예기치 않게 닫혔습니다."); break }
                    }
                } elseif (@($controlTests | Where-Object { $_.controlKind -eq 'Button' -and $_.controlName -eq '조회(탭오더)' -and $_.queryTriggered -and -not $_.errorDetected }).Count -gt 0) {
                    $completedTabQueries=@($controlTests | Where-Object { $_.controlKind -eq 'Button' -and $_.controlName -eq '조회(탭오더)' -and $_.queryTriggered -and -not $_.errorDetected }).Count
                    $queryHistoryExpectation = [pscustomobject]@{type='Success';expectationId='required-query-history';messagePatterns=@();errorCodes=@();evidence=@('탭오더 조회 실행 이력')}
                    $queryHistoryEvaluation = Invoke-HtsRawObservationEvaluation -Context $evaluationAdapterContext 'Success' "탭오더 조회 버튼 $completedTabQueries개 실행 이력" '' $queryHistoryExpectation $true $true 'required-query-history' 'Action' $false
                    $queryHistoryTestResult = $queryHistoryEvaluation.testResult
                    $controlTests.Add([pscustomobject]@{
                        planItemId='REQUIRED-QUERY-HISTORY';controlId='REQUIRED-QUERY-HISTORY';controlKind='Button';controlName='조회(탭오더)'
                        optionId='verified';inputValue='';displayValue="탭오더 조회 버튼 $completedTabQueries개";status=[string]$queryHistoryTestResult.status;queryTriggered=$true;errorDetected=[bool]$queryHistoryTestResult.productDefectDetected;testResult=$queryHistoryTestResult
                        output="탭오더 순회 중 식별된 활성 조회 버튼 $completedTabQueries개를 실제 클릭했습니다.";errorCode=[string]$queryHistoryTestResult.code;screenshotPath='';elapsedMs=0
                    })
                    Add-HtsActionRecord $reportingContext $actions 'invokeQuery' 'PASS' '탭오더 조회 이력' "탭오더 순회 중 식별된 활성 조회 버튼 $completedTabQueries개를 실제 클릭했습니다."
                    $mapQueryExecuted = $true
                } else {
                    if(Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber){
                        Send-Key $actionContext ([byte]0x7B)
                        Start-Sleep -Milliseconds ([Math]::Max(500,[int]$dataset.executionPolicy.actionTimeoutMs))
                        Add-HtsActionRecord $reportingContext $actions "invokeQuery" "PASS" "F12" "활성 조회 버튼을 찾지 못해 화면의 F12 조회 단축키를 실행했습니다."
                        $mapQueryExecuted = $true
                        $automationIssues.Add("활성화된 조회 버튼을 찾지 못해 F12로 대체했습니다: QUERY_BUTTON_NOT_FOUND")
                    }else{
                        Add-HtsActionRecord $reportingContext $actions 'invokeQuery' 'PENDING' 'F12' '대상 화면을 활성화하지 못해 F12 입력을 차단했습니다.' 'TARGET_SCREEN_NOT_ACTIVE'
                        $automationIssues.Add('대상 화면을 활성화하지 못해 필수 조회를 실행하지 못했습니다: TARGET_SCREEN_NOT_ACTIVE')
                    }
                }
            } else {
                Add-HtsActionRecord $reportingContext $actions "invokeQuery" "PENDING" $queryTrigger "계획 전용 실행이므로 조회를 실행하지 않았습니다." "PLAN_ONLY"
            }
            if ($mapBehavior -and @($mapBehavior.queryControls).Count -gt 0) {
                if ($mapQueryExecuted) {
                    Add-HtsActionRecord $reportingContext $actions 'evaluateMapBehavior' 'PASS' (@($mapBehavior.queryControls) -join ', ') 'MAP이 정의한 조회 경로를 실제 컨트롤 조작 또는 조회 단축키로 실행했습니다.'
                } else {
                    Add-HtsActionRecord $reportingContext $actions 'evaluateMapBehavior' 'PENDING' (@($mapBehavior.queryControls) -join ', ') 'MAP이 정의한 조회 경로의 실행 증거를 확보하지 못했습니다.' 'MAP_QUERY_NOT_EXECUTED'
                    $autoPendingReasons.Add('MAP 조회 트리거 미실행')
                }
            } elseif ($mapBehavior) {
                Add-HtsActionRecord $reportingContext $actions 'evaluateMapBehavior' 'PASS' ([string]$case.screen.screenNumber) 'MAP에 별도 조회 역할 컨트롤이 정의되지 않은 화면입니다.'
            }
            foreach ($reason in $autoPendingReasons) { $pendingReasons.Add($reason) }
            if ($automationIssues.Count -gt 0) { $pendingReasons.Add("자동 컨트롤 조작 일부 미완료($($automationIssues.Count)건)") }

    $Frame.Main = $main
    $Frame.Screen = $screen
    $Frame.ScreenEdit = $screenEdit
    $Frame.MapQueryExecuted = [bool]$mapQueryExecuted
    $Frame
}
