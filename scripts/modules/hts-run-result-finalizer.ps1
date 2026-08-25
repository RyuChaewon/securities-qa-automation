<#
.SYNOPSIS Canonical case and run result finalization.
.DESCRIPTION Delegates verdicts to ResultEvaluator and writes existing JSON schemas without rejudging evidence.
#>

# Sends one immutable evaluation document to the canonical C# ResultEvaluator adapter.
function Invoke-HtsRuleSuiteEvaluation {
    param(
        [Parameter(Mandatory = $true)]$RunSpec,
        [Parameter(Mandatory = $true)]$EvaluationDocument,
        [Parameter(Mandatory = $true)][string]$InvocationId
    )

    Invoke-RuleResultEvaluation `
        -CliProject $RunSpec.CliProject `
        -TestPackPath $RunSpec.ResultEvaluationTestPackPath `
        -EvaluationDocument $EvaluationDocument `
        -WorkingDirectory $RunSpec.ResultEvaluationWorkingDirectory `
        -InvocationId $InvocationId
}

# Converts a failed UI environment precheck into canonical evaluator input and existing artifacts.
function Complete-HtsEnvironmentPrecheckFailure {
    param(
        [Parameter(Mandatory = $true)]$RunSpec,
        [Parameter(Mandatory = $true)]$RunServices,
        [Parameter(Mandatory = $true)]$RunState,
        [Parameter(Mandatory = $true)]$ErrorRecord
    )

    $dataset = $RunSpec.Dataset
    $testPack = $RunSpec.TestPack
    $cases = @($RunState.Cases)
    $ReportDir = [string]$RunSpec.ReportDir
    $runId = [string]$RunSpec.RunId
    $cliProject = [string]$RunSpec.CliProject
    $resolvedTestPackPath = [string]$RunSpec.ResolvedTestPackPath
    $resultEvaluationTestPackPath = [string]$RunSpec.ResultEvaluationTestPackPath
    $resultEvaluationWorkingDirectory = [string]$RunSpec.ResultEvaluationWorkingDirectory
    $automationMetrics = $RunServices.AutomationMetrics

    $ErrorRecord.Exception.ToString() | Set-Content -LiteralPath (Join-Path $ReportDir '환경사전점검오류.txt') -Encoding UTF8
    $precheckMessage = Protect-Text $ErrorRecord.Exception.Message
    $precheckExpectation = [pscustomobject]@{ type = 'Success'; expectationId = 'environment-precheck'; messagePatterns = @(); errorCodes = @(); evidence = @('HTS/FlaUI 환경 사전점검') }
    $precheckEvaluationCases = @($cases | ForEach-Object {
        New-RuleSignalEvaluationCase -CaseId ([string]$_.caseId) -EventType 'InfrastructureError' -Text $precheckMessage -SourceCode 'ENVIRONMENT_HTS_NOT_ACCESSIBLE' -Source 'environment precheck' -Executed $false -EvidencePresent $true -ExpectedOutcome $precheckExpectation
    })
    $precheckEvaluationDocument = [pscustomobject]@{ schemaVersion = '1.0'; testPackId = [string]$testPack.testPackId; aggregateId = "$runId-precheck"; cases = $precheckEvaluationCases }
    $precheckEvaluationOutput = Invoke-HtsRuleSuiteEvaluation -RunSpec $RunSpec -EvaluationDocument $precheckEvaluationDocument -InvocationId 'environment-precheck'
    $precheckTestResults = @{}
    foreach ($testResult in @($precheckEvaluationOutput.results)) { $precheckTestResults[[string]$testResult.caseId] = $testResult }
    $precheckResults = @($cases | ForEach-Object {
        $caseRow = $_
        $caseTestResult = $precheckTestResults[[string]$caseRow.caseId]
        $safeVariables = [ordered]@{}
        foreach ($name in @($caseRow.variables.Keys | Sort-Object)) {
            $dimension = @($dataset.variables | Where-Object { $_.name -eq $name } | Select-Object -First 1)
            $safeVariables[$name] = if ($dimension.Count -gt 0 -and $dimension[0].sensitive) { '******' } else { [string]$caseRow.variables[$name] }
        }
        [pscustomobject]@{
            runId = $runId; caseId = $caseRow.caseId; datasetId = [string]$dataset.datasetId
            screenNumber = [string]$caseRow.screen.screenNumber; screenName = [string]$caseRow.screen.screenName; inputMode = $(if ([string]$caseRow.account.inputMode -eq 'Explicit') { '데이터셋 명시 입력' } else { '화면 기본값' })
            accountId = [string]$caseRow.account.id; accountMasked = (Get-MaskedAccount ([string]$caseRow.account.accountNumber)); accountFingerprint = (Get-AccountFingerprint ([string]$caseRow.account.accountNumber)); accountOwner = [string]$caseRow.account.owner
            inputVariables = $safeVariables; status = [string]$caseTestResult.status; errorDetected = $false; productDefectDetected = [bool]$caseTestResult.productDefectDetected; actualScenarioActionsExecuted = $false; testResult = $caseTestResult; errorCode = [string]$caseTestResult.code
            errorMessage = ''; outputSummary = [string]$caseTestResult.reason; screenshotPath = ''
            actions = @([pscustomobject]@{ action = 'environmentPrecheck'; status = 'PENDING'; target = 'hfrun'; output = $precheckMessage; errorCode = 'ENVIRONMENT_HTS_NOT_ACCESSIBLE'; elapsedMs = 0 })
            startedAt = (Get-Date).ToString('o'); endedAt = (Get-Date).ToString('o'); elapsedMs = 0
        }
    })
    $precheckResults | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ReportDir 'case-results.json') -Encoding UTF8
    $precheckEvaluationOutput | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ReportDir 'test-results.json') -Encoding UTF8
    [pscustomobject]@{
        runId = $runId; testPackId = [string]$testPack.testPackId; testPackPath = $resolvedTestPackPath; datasetId = [string]$dataset.datasetId; datasetPath = [string]$testPack.datasetSource; status = [string]$precheckEvaluationOutput.overallResult.status; total = $precheckResults.Count
        pass = [int]$precheckEvaluationOutput.summary.pass; fail = [int]$precheckEvaluationOutput.summary.fail; error = [int]$precheckEvaluationOutput.summary.error; pending = [int]$precheckEvaluationOutput.summary.pending; dryRun = $false; explicitErrorsDetected = 0
        automationEngine = 'FlaUI.UIA3'; automationEngineVersion = '5.0.0'; flaUiDiscoveryCalls = $automationMetrics.FlaUiDiscoveryCalls; flaUiActionAttempts = $automationMetrics.FlaUiActionAttempts
        flaUiActionSuccesses = $automationMetrics.FlaUiActionSuccesses; flaUiFallbackRequests = $automationMetrics.FlaUiFallbackRequests; flaUiFallbackReasons = @($automationMetrics.FlaUiFallbackReasons)
        environmentStatus = 'HTS_NOT_ACCESSIBLE'; finishedAt = (Get-Date).ToString('o'); executionMode = $(if ($RunSpec.Input.SubmitTransactionalDialogs) { '승인된 테스트계좌 거래 제출' } else { '조회 전용' }); inputMode = '화면 기본값 또는 데이터셋 명시 입력'; planner = '결정론적 규칙'
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReportDir 'summary.json') -Encoding UTF8

    $RunState.EarlyExit = $true
    $RunState.OutputReady = $true
    $RunState.OutputPath = $ReportDir
    $RunState.UiActionCount = [int]$automationMetrics.FlaUiActionAttempts
    $RunState.TransactionalActionCount = 0
    $RunState
}

# Sends raw case observations to the canonical evaluator and writes compatible checkpoint artifacts.
function Complete-HtsRuleSuiteCaseResult {
    param(
        [Parameter(Mandatory = $true)]$RunSpec,
        [Parameter(Mandatory = $true)]$RunServices,
        [Parameter(Mandatory = $true)]$RunState,
        [Parameter(Mandatory = $true)]$Frame,
        [Parameter(Mandatory = $true)][int]$TotalCases
    )

    $dataset = $RunSpec.Dataset
    $testPack = $RunSpec.TestPack
    $scenarioMode = [bool]$RunSpec.ScenarioMode
    $scenarioPlan = $RunSpec.ScenarioPlan
    $physicalPlan = $RunSpec.PhysicalPlan
    $mapCatalog = $RunSpec.MapCatalog
    $PlanOnly = [bool]$RunSpec.Input.PlanOnly
    $ReportDir = [string]$RunSpec.ReportDir
    $runId = [string]$RunSpec.RunId
    $cliProject = [string]$RunSpec.CliProject
    $resultEvaluationTestPackPath = [string]$RunSpec.ResultEvaluationTestPackPath
    $resultEvaluationWorkingDirectory = [string]$RunSpec.ResultEvaluationWorkingDirectory

    $RuntimeContext = $RunServices.RuntimeContext
    $automationMetrics = $RunServices.AutomationMetrics
    $targetRuleContext = $RunServices.TargetRuleContext
    $observationContext = $RunServices.ObservationContext
    $evaluationAdapterContext = $RunServices.EvaluationAdapterContext

    $case = $Frame.Case
    $main = $Frame.Main
    $screen = $Frame.Screen
    $secret = [string]$Frame.Secret
    $inputMode = [string]$Frame.InputMode
    $actions = $Frame.Actions
    $pendingReasons = $Frame.PendingReasons
    $errors = $Frame.Errors
    $automationIssues = $Frame.AutomationIssues
    $discoveredControls = $Frame.DiscoveredControls
    $controlTests = $Frame.ControlTests
    $popupObservations = $Frame.PopupObservations
    $oracleEvents = $Frame.OracleEvents
    $mapModel = $Frame.MapModel
    $mapOracle = $Frame.MapOracle
    $mapBehavior = $Frame.MapBehavior
    $mapQueryExecuted = [bool]$Frame.MapQueryExecuted
    $mapReboundControls = [int]$Frame.MapReboundControls
    $automationContractFailure = [bool]$Frame.AutomationContractFailure
    $automationContractErrorCode = [string]$Frame.AutomationContractErrorCode
    $executorException = [bool]$Frame.ExecutorException
    $executorDiagnostic = [string]$Frame.ExecutorDiagnostic
    $externalInterruption = [bool]$Frame.ExternalInterruption
    $screenOpenFailure = [bool]$Frame.ScreenOpenFailure
    $existingScreenRequiredMissing = [bool]$Frame.ExistingScreenRequiredMissing
    $flaUiActionAttemptsBeforeCase = [int]$Frame.FlaUiActionAttemptsBeforeCase
    $started = $Frame.Started
    $screenshot = [string]$Frame.Screenshot
    $results = $RunState.Results
    $cases = @($RunState.Cases)

    if ($PlanOnly -and $pendingReasons.Count -eq 0) { $pendingReasons.Add("계획 전용 실행") }
    $ended = Get-Date
    # 실행기는 사실만 Observation으로 기록하고 최종 상태는 Core ResultEvaluator 출력에서 복사한다.
    $actualCaseActionsExecuted = -not $PlanOnly -and (([int]$automationMetrics.FlaUiActionAttempts -gt $flaUiActionAttemptsBeforeCase) -or $observationContext.CurrentResultEvaluationCases.Count -gt 0)
    $completionObservationKind = if ($externalInterruption -or $executorException -or $automationContractFailure) { 'InfrastructureError' } elseif ($errors.Count -gt 0) { 'ProductFailure' } elseif ($pendingReasons.Count -gt 0) { 'EvidenceMissing' } else { 'Success' }
    $completionObservationCode = if ($externalInterruption) { 'HTS_CONNECTION_LOST' } elseif ($automationContractFailure -and $automationContractErrorCode) { $automationContractErrorCode } elseif ($executorException) { 'EXECUTOR_EXCEPTION' } elseif ($screenOpenFailure) { 'SCREEN_NOT_VISIBLE' } elseif ($errors.Count -gt 0) { 'PRODUCT_DEFECT_DETECTED' } elseif ($existingScreenRequiredMissing) { 'EXISTING_SCREEN_REQUIRED' } elseif ($pendingReasons.Count -gt 0) { 'PRECONDITION_PENDING' } else { '' }
    $completionMessage = if ($errors.Count -gt 0) { @($errors | Select-Object -Unique) -join ' | ' } elseif ($pendingReasons.Count -gt 0) { @($pendingReasons | Select-Object -Unique) -join ' | ' } else { '케이스 실행 및 증거 수집을 완료했습니다.' }
    $completionExpectation = [pscustomobject]@{
        type='Success';expectationId="case-completion:$($case.caseId)";messagePatterns=@();errorCodes=@()
        evidence=@($(if($scenarioMode){[string]$case.scenarioCase.expectedResult}else{'케이스 실행 완료 계약'}))
    }
    $completionEvaluation = Invoke-HtsRawObservationEvaluation -Context $evaluationAdapterContext `
        $completionObservationKind `
        $completionMessage `
        $completionObservationCode `
        $completionExpectation `
        $actualCaseActionsExecuted `
        ($completionObservationKind -ne 'EvidenceMissing') `
        'case-completion' `
        'Action' `
        $false
    $caseEvaluationDocument = [pscustomobject]@{
        schemaVersion='1.0';testPackId=[string]$testPack.testPackId
        aggregateId=[string]$case.caseId;cases=@($observationContext.CurrentResultEvaluationCases.ToArray())
    }
    $caseEvaluationOutput = Invoke-HtsRuleSuiteEvaluation -RunSpec $RunSpec -EvaluationDocument $caseEvaluationDocument -InvocationId ("case-{0}" -f $case.caseId)
    $caseTestResult = $caseEvaluationOutput.overallResult
    $status = [string]$caseTestResult.status
    $safeVariables = [ordered]@{}
    foreach ($name in @($case.variables.Keys | Sort-Object)) {
        $dimension = @($dataset.variables | Where-Object { $_.name -eq $name } | Select-Object -First 1)
        $safeVariables[$name] = if ($dimension.Count -gt 0 -and $dimension[0].sensitive) { "******" } else { [string]$case.variables[$name] }
    }
    $resultRow = [pscustomobject]@{
        runId=$runId; caseId=$case.caseId; datasetId=[string]$dataset.datasetId
        automationEngine='FlaUI.UIA3';automationEngineVersion='5.0.0'
        scenarioMode=[bool]$scenarioMode;scenarioId=$(if($scenarioMode){[string]$case.scenarioCase.scenarioId}else{''});scenarioTitle=$(if($scenarioMode){[string]$case.scenarioCase.scenarioTitle}else{''})
        sourceTestCaseId=$(if($scenarioMode){[string]$case.scenarioCase.sourceTestCaseId}else{''});mapScreenCode=$(if($scenarioMode){[string]$case.scenarioCase.mapScreenCode}else{''});transactional=$(if($scenarioMode){[bool]$case.scenarioCase.transactional}else{$false})
        interactionStrategy=[string]$targetRuleContext.CurrentInteractionStrategy
        expectedResult=$(if($scenarioMode){[string]$case.scenarioCase.expectedResult}else{''})
        scenarioPriority=$(if($scenarioMode){[string]$case.scenarioCase.priority}else{''});scenarioCategory=$(if($scenarioMode){[string]$case.scenarioCase.category}else{''})
        logicalPlanId=$(if($scenarioMode){[string]$scenarioPlan.planId}else{''});physicalPlanId=$(if($physicalPlan){[string]$physicalPlan.physicalPlanId}else{''})
        screenNumber=[string]$case.screen.screenNumber; screenName=[string]$case.screen.screenName; inputMode=$(if ($inputMode -eq "Explicit") { "데이터셋 명시 입력" } else { "화면 기본값" })
        accountId=[string]$case.account.id; accountMasked=(Get-MaskedAccount ([string]$case.account.accountNumber)); accountFingerprint=(Get-AccountFingerprint ([string]$case.account.accountNumber)); accountOwner=[string]$case.account.owner
        inputVariables=$safeVariables; status=$status; errorDetected=($errors.Count -gt 0);productDefectDetected=[bool]$caseTestResult.productDefectDetected
        actualScenarioActionsExecuted=[bool]$actualCaseActionsExecuted;testResult=$caseTestResult;testResults=@($caseEvaluationOutput.results)
        automationContractFailure=[bool]$automationContractFailure;externalInterruption=[bool]$externalInterruption
        errorCode=[string]$caseTestResult.code
        errorMessage=Protect-Text (@($errors | Select-Object -Unique) -join " | ") $secret
        executorDiagnostic=$executorDiagnostic
        automationIssues=@($automationIssues | Select-Object -Unique)
        outputSummary=[string]$caseTestResult.reason
        screenshotPath=if ($screenshot) { Get-RelativeFilePath $ReportDir $screenshot } else { "" }
        actions=$actions.ToArray()
        discoveredControls=@($discoveredControls | ForEach-Object {
            [pscustomobject]@{
                controlId=$_.controlId;controlKind=$_.controlKind;name=$_.name;className=$_.className
                automationId=$(if($_.PSObject.Properties.Name -contains 'automationId'){[string]$_.automationId}else{''})
                uiaRuntimeId=$(if($_.PSObject.Properties.Name -contains 'uiaRuntimeId'){[string]$_.uiaRuntimeId}else{''})
                uiaControlType=$(if($_.PSObject.Properties.Name -contains 'uiaControlType'){[string]$_.uiaControlType}else{''})
                automationEngine=$(if($_.PSObject.Properties.Name -contains 'automationEngine'){[string]$_.automationEngine}else{'Win32/MAP'})
                supportedActions=$(if($_.PSObject.Properties.Name -contains 'supportedActions'){@($_.supportedActions)}else{@()})
                locatorSignature=$_.locatorSignature
                initialValue=$_.initialValue;tabOrder=$_.tabOrder;tabStop=$_.tabStop;stateContext=$_.stateContext;mapScreenCode=$_.mapScreenCode;regionRole=$_.regionRole
                # 선택지가 하나여도 JSON 객체로 붕괴되지 않도록 명시적인 배열 계약을 유지한다.
                claimedByDataset=$_.claimedByDataset;dataRequired=$_.dataRequired;pendingReason=$_.pendingReason;options=@($_.options);relativeRect=$_.relativeRect
                definitionSource=$_.definitionSource;runtimeName=$_.runtimeName;runtimeControlKind=$_.runtimeControlKind;mapModelId=$_.mapModelId
                mapTypeCode=$_.mapTypeCode;mapKind=$_.mapKind;mapDefinitionOrder=$_.mapDefinitionOrder;mapMatched=$_.mapMatched;mapMatchDistance=$_.mapMatchDistance
                mapGeometryDelta=$(if($_.PSObject.Properties.Name -contains 'mapGeometryDelta'){$_.mapGeometryDelta}else{$null})
                mapGeometryExact=$(if($_.PSObject.Properties.Name -contains 'mapGeometryExact'){[bool]$_.mapGeometryExact}else{$false})
                mapHostRequired=$(if($_.PSObject.Properties.Name -contains 'mapHostRequired'){[bool]$_.mapHostRequired}else{$false})
                mapHostMatched=$(if($_.PSObject.Properties.Name -contains 'mapHostMatched'){[bool]$_.mapHostMatched}else{$false})
                mapHostId=$(if($_.PSObject.Properties.Name -contains 'mapHostId'){[string]$_.mapHostId}else{''})
                runtimeIdentityUnique=$(if($_.PSObject.Properties.Name -contains 'runtimeIdentityUnique'){[bool]$_.runtimeIdentityUnique}else{$true})
                allowOwnerDrawnKindOverride=$(if($_.PSObject.Properties.Name -contains 'allowOwnerDrawnKindOverride'){[bool]$_.allowOwnerDrawnKindOverride}else{$false})
                mapEvents=$_.mapEvents;mapSemanticRole=$_.mapSemanticRole;mapTriggeredRequests=$_.mapTriggeredRequests;mapReadControls=$_.mapReadControls
                mapAffectedControls=$_.mapAffectedControls;mapResultControls=$_.mapResultControls;mapInvokedHandlers=$_.mapInvokedHandlers
                mapNavigationTargets=$_.mapNavigationTargets;mapOptionSource=$_.mapOptionSource;mapRect=$_.mapRect
            }
        })
        controlTests=$controlTests.ToArray(); popupObservations=$popupObservations.ToArray();oracleEvents=$oracleEvents.ToArray()
        mapErrorOracle=$(if($mapOracle){[pscustomobject]@{
            sourceFile=[string]$mapModel.sourceFile;sourceSha256=[string]$mapModel.sourceSha256
            hasReceiveErrorParameters=[bool]$mapOracle.hasReceiveErrorParameters;hasOnErrorHandler=[bool]$mapOracle.hasOnErrorHandler
            errorHandlers=@($mapOracle.errorHandlers);messageBoxes=@($mapOracle.messageBoxes)
            requestNames=@($mapOracle.requestNames);transactionCodes=@($mapOracle.transactionCodes)
        }}else{$null})
        mapBehavior=$(if($mapBehavior){[pscustomobject]@{
            eventHandlerCount=@($mapBehavior.eventHandlers).Count;queryControls=@($mapBehavior.queryControls);autoQueryControls=@($mapBehavior.autoQueryControls)
            paginationControls=@($mapBehavior.paginationControls);exportControls=@($mapBehavior.exportControls);navigationControls=@($mapBehavior.navigationControls)
            stateControllerControls=@($mapBehavior.stateControllerControls);inputControls=@($mapBehavior.inputControls);resultControls=@($mapBehavior.resultControls)
            queryExecuted=[bool]$mapQueryExecuted;reboundControls=[int]$mapReboundControls
        }}else{$null})
        installationModel=$(if($mapModel -and $mapCatalog.installationFingerprint){[pscustomobject]@{
            fingerprint=[string]$mapCatalog.installationFingerprint;canonicalTitle=$(if($mapModel.registry){[string]$mapModel.registry.title}else{[string]$mapModel.screenName})
            tabGroups=@($mapModel.tabGroups);tabSiblings=@($mapModel.tabSiblings);dependencies=@($mapModel.dependencies)
            dataReferences=@($mapModel.dataReferences);integrity=$mapModel.integrity
        }}else{$null})
        startedAt=$started.ToString("o"); endedAt=$ended.ToString("o"); elapsedMs=[int64]($ended-$started).TotalMilliseconds
    }
    Protect-RuleReportedSensitiveValues $resultRow
    $results.Add($resultRow)
    $checkpointResults=@($results.ToArray())
    ConvertTo-Json -InputObject $checkpointResults -Depth 12 | Set-Content -LiteralPath (Join-Path $ReportDir "case-results.json") -Encoding UTF8
    $checkpointEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId="$runId-checkpoint";cases=@();completedResults=@($checkpointResults | ForEach-Object {$_.testResult})}
    $checkpointEvaluationOutput=Invoke-HtsRuleSuiteEvaluation -RunSpec $RunSpec -EvaluationDocument $checkpointEvaluationDocument -InvocationId 'checkpoint'
    $checkpointResultSummary=$checkpointEvaluationOutput.summary
    [pscustomobject]@{
        runId=$runId;completed=$checkpointResults.Count;total=$cases.Count;lastCaseId=$case.caseId;lastScreenNumber=[string]$case.screen.screenNumber
        pass=[int]$checkpointResultSummary.pass;fail=[int]$checkpointResultSummary.fail
        error=[int]$checkpointResultSummary.error;pending=[int]$checkpointResultSummary.pending;updatedAt=(Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReportDir "checkpoint-summary.json") -Encoding UTF8

    foreach ($actionEvidence in @($actions.ToArray())) { $RunState.ActionEvidence.Add($actionEvidence) }
    foreach ($checkpointEvidence in @($observationContext.CurrentResultEvaluationCases.ToArray() | Where-Object { [string]$_.evidenceRole -eq 'Checkpoint' })) { $RunState.CheckpointEvidence.Add($checkpointEvidence) }
    $RunState.UiActionCount = [int]$automationMetrics.FlaUiActionAttempts
    [pscustomobject]@{
        StopRequested = [bool]($dataset.executionPolicy.stopOnFirstError -and [string]$caseTestResult.status -in @('FAIL', 'ERROR'))
        TestStatus = [string]$caseTestResult.status
    }
}

# Aggregates canonical case results and writes existing run-level artifacts.
function Complete-HtsRuleSuiteResult {
    param(
        [Parameter(Mandatory = $true)]$RunSpec,
        [Parameter(Mandatory = $true)]$RunServices,
        [Parameter(Mandatory = $true)]$RunState
    )

    $dataset = $RunSpec.Dataset
    $testPack = $RunSpec.TestPack
    $targetContext = $RunSpec.TargetContext
    $scenarioMode = [bool]$RunSpec.ScenarioMode
    $scenarioPlan = $RunSpec.ScenarioPlan
    $physicalPlan = $RunSpec.PhysicalPlan
    $mapCatalog = $RunSpec.MapCatalog
    $mapInitializationIssue = [string]$RunSpec.MapInitializationIssue
    $PlanOnly = [bool]$RunSpec.Input.PlanOnly
    $SubmitTransactionalDialogs = [bool]$RunSpec.Input.SubmitTransactionalDialogs
    $RequireExistingTargetScreen = [bool]$RunSpec.Input.RequireExistingTargetScreen
    $PreserveTargetScreenAfterRun = [bool]$RunSpec.Input.PreserveTargetScreenAfterRun
    $reuseExistingTargetScreenRequested = [bool]$RunSpec.ReuseExistingTargetScreenRequested
    $ReportDir = [string]$RunSpec.ReportDir
    $runId = [string]$RunSpec.RunId
    $resolvedTestPackPath = [string]$RunSpec.ResolvedTestPackPath
    $cliProject = [string]$RunSpec.CliProject
    $resultEvaluationTestPackPath = [string]$RunSpec.ResultEvaluationTestPackPath
    $resultEvaluationWorkingDirectory = [string]$RunSpec.ResultEvaluationWorkingDirectory

    $RuntimeContext = $RunServices.RuntimeContext
    $automationMetrics = $RunServices.AutomationMetrics
    $safetyContext = $RunServices.SafetyContext
    $results = $RunState.Results
    $initialScreensClosed = [int]$RunState.InitialScreensClosed
    $initialScreensPreserved = [int]$RunState.InitialScreensPreserved
    $initialSearchOverlaysClosed = [int]$RunState.InitialSearchOverlaysClosed

$resultArray = $results.ToArray()
$resultArray | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ReportDir "case-results.json") -Encoding UTF8
$controlPlanRows = @($resultArray | ForEach-Object {
    [pscustomobject]@{caseId=$_.caseId;scenarioId=$_.scenarioId;scenarioTitle=$_.scenarioTitle;screenNumber=$_.screenNumber;screenName=$_.screenName;discoveredControls=$_.discoveredControls;controlTests=$_.controlTests}
})
# 화면이 한 개여도 소비자 스키마의 RuntimeControlPlanRow[] 계약이 유지되도록 파이프라인 직렬화를 피한다.
ConvertTo-Json -InputObject $controlPlanRows -Depth 12 | Set-Content -LiteralPath (Join-Path $ReportDir "control-plan.json") -Encoding UTF8
$inputAuditRows=if(Test-Path -LiteralPath $safetyContext.AuditPath){@([IO.File]::ReadAllLines($safetyContext.AuditPath,[Text.Encoding]::UTF8) | Where-Object {$_} | ForEach-Object {$_ | ConvertFrom-Json})}else{@()}
$runEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId=$runId;cases=@();completedResults=@($resultArray | ForEach-Object {$_.testResult})}
$runEvaluationOutput=Invoke-HtsRuleSuiteEvaluation -RunSpec $RunSpec -EvaluationDocument $runEvaluationDocument -InvocationId 'run-summary'
$runEvaluationOutput | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ReportDir 'test-results.json') -Encoding UTF8
$runResultSummary=$runEvaluationOutput.summary
$summaryStatus=[string]$runEvaluationOutput.overallResult.status
[pscustomobject]@{
    runId=$runId; testPackId=[string]$testPack.testPackId;testPackPath=$resolvedTestPackPath;datasetId=[string]$dataset.datasetId; datasetPath=[string]$testPack.datasetSource; targetProfileId=$targetContext.ProfileId; targetDisplayName=$targetContext.DisplayName; status=$summaryStatus; total=$resultArray.Count
    pass=[int]$runResultSummary.pass; fail=[int]$runResultSummary.fail
    error=[int]$runResultSummary.error; pending=[int]$runResultSummary.pending
    dryRun=$false; explicitErrorsDetected=@($resultArray | Where-Object productDefectDetected).Count
    automationEngine='FlaUI.UIA3';automationEngineVersion='5.0.0'
    flaUiDiscoveryCalls=$automationMetrics.FlaUiDiscoveryCalls;flaUiElementsDiscovered=$automationMetrics.FlaUiElementsDiscovered
    flaUiActionAttempts=$automationMetrics.FlaUiActionAttempts;flaUiActionSuccesses=$automationMetrics.FlaUiActionSuccesses
    flaUiFallbackRequests=$automationMetrics.FlaUiFallbackRequests;flaUiFallbackReasons=@($automationMetrics.FlaUiFallbackReasons)
    finishedAt=(Get-Date).ToString("o"); executionMode=$(if ($PlanOnly) {"계획 전용"} elseif($SubmitTransactionalDialogs){"승인된 테스트계좌 거래 제출"} elseif($scenarioMode){"승인된 시나리오 기반 조작"} else {"대상 화면 규칙 기반 전체 조작"}); inputMode="화면 기본값 또는 데이터셋 명시 입력"; planner=[string]$testPack.generatorVersion
    scenarioMode=[bool]$scenarioMode;logicalPlanId=$(if($scenarioMode){[string]$scenarioPlan.planId}else{''});physicalPlanId=$(if($physicalPlan){[string]$physicalPlan.physicalPlanId}else{''})
    scenarioGenerationMode=$(if($scenarioMode){[string]$scenarioPlan.scenarioGenerationMode}else{''});scenarioGenerator=$(if($scenarioMode){[string]$scenarioPlan.scenarioGenerator}else{''});scenarioGeneratorVersion=$(if($scenarioMode){[string]$scenarioPlan.scenarioGeneratorVersion}else{''});runtimeDiscoveryUsed=$(if($scenarioMode){[bool]$scenarioPlan.runtimeDiscoveryUsed}else{$false})
    scenarioCount=$(if($scenarioMode){@($resultArray.scenarioId | Sort-Object -Unique).Count}else{0});scenarioStepTests=$(if($scenarioMode){@($resultArray | ForEach-Object {@($_.controlTests | Where-Object scenarioStepId).Count} | Measure-Object -Sum).Sum}else{0})
    coordinateFocusSteps=@($resultArray | ForEach-Object { @($_.controlTests | Where-Object coordinateFocusUsed).Count } | Measure-Object -Sum).Sum
    coordinateFocusVerified=@($resultArray | ForEach-Object { @($_.controlTests | Where-Object coordinateFocusVerified).Count } | Measure-Object -Sum).Sum
    discoveredControls=@($resultArray | ForEach-Object { @($_.discoveredControls).Count } | Measure-Object -Sum).Sum
    controlTests=@($resultArray | ForEach-Object { @($_.controlTests).Count } | Measure-Object -Sum).Sum
    popupObservations=@($resultArray | ForEach-Object { @($_.popupObservations).Count } | Measure-Object -Sum).Sum
    expectedEvents=@($resultArray | ForEach-Object { @($_.oracleEvents | Where-Object disposition -eq 'Expected').Count } | Measure-Object -Sum).Sum
    reviewEvents=@($resultArray | ForEach-Object { @($_.oracleEvents | Where-Object requiresReview).Count } | Measure-Object -Sum).Sum
    productDefects=@($resultArray | Where-Object productDefectDetected).Count
    automationContractFailures=@($resultArray | Where-Object automationContractFailure).Count
    externalInterruptions=@($resultArray | Where-Object externalInterruption).Count
    inputBoundaryAllowed=@($inputAuditRows | Where-Object status -eq 'ALLOWED').Count
    inputBoundaryBlocked=@($inputAuditRows | Where-Object status -eq 'BLOCKED').Count
    mouseClicksAllowed=@($inputAuditRows | Where-Object { $_.inputType -eq 'MouseClick' -and $_.status -eq 'ALLOWED' }).Count
    mouseClicksBlocked=@($inputAuditRows | Where-Object { $_.inputType -eq 'MouseClick' -and $_.status -eq 'BLOCKED' }).Count
    mapModels=@($mapCatalog.screens).Count
    mapDefinedControls=@($resultArray | ForEach-Object { @($_.discoveredControls | Where-Object { $_.definitionSource -in @('MAP','MAP+Runtime') }).Count } | Measure-Object -Sum).Sum
    mapBoundControls=@($resultArray | ForEach-Object { @($_.discoveredControls | Where-Object definitionSource -eq 'MAP+Runtime').Count } | Measure-Object -Sum).Sum
    mapUnboundControls=@($resultArray | ForEach-Object { @($_.discoveredControls | Where-Object definitionSource -eq 'MAP').Count } | Measure-Object -Sum).Sum
    runtimeOnlyControls=@($resultArray | ForEach-Object { @($_.discoveredControls | Where-Object definitionSource -eq 'RuntimeOnly').Count } | Measure-Object -Sum).Sum
    mapOracleScreens=$(if($mapCatalog){@($mapCatalog.screens | Where-Object errorOracle).Count}else{0})
    mapOracleMessages=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.errorOracle.messageBoxes).Count } | Measure-Object -Sum).Sum}else{0})
    mapOracleExplicitErrors=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.errorOracle.messageBoxes | Where-Object isExplicitError).Count } | Measure-Object -Sum).Sum}else{0})
    mapOracleValidationMessages=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.errorOracle.messageBoxes | Where-Object classification -eq 'InputValidation').Count } | Measure-Object -Sum).Sum}else{0})
    mapOracleMatchedPopups=@($resultArray | ForEach-Object { @($_.popupObservations | Where-Object oracleSource -eq 'MAP').Count } | Measure-Object -Sum).Sum
    mapBehaviorHandlers=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.behavior.eventHandlers).Count } | Measure-Object -Sum).Sum}else{0})
    mapQueryControls=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.behavior.queryControls).Count } | Measure-Object -Sum).Sum}else{0})
    mapStateControllers=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.behavior.stateControllerControls).Count } | Measure-Object -Sum).Sum}else{0})
    mapResultControls=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.behavior.resultControls).Count } | Measure-Object -Sum).Sum}else{0})
    mapReboundControls=@($resultArray | ForEach-Object { if($_.mapBehavior){[int]$_.mapBehavior.reboundControls}else{0} } | Measure-Object -Sum).Sum
    installationFingerprint=$(if($mapCatalog){[string]$mapCatalog.installationFingerprint}else{''})
    dependencyModels=$(if($mapCatalog){@($mapCatalog.dependencyScreens).Count}else{0})
    mapDependencies=$(if($mapCatalog){@($mapCatalog.dependencies).Count}else{0})
    unresolvedDependencies=$(if($mapCatalog){@($mapCatalog.dependencies | Where-Object { -not $_.isDynamic -and -not $_.targetExists }).Count}else{0})
    staticDataReferences=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object {@($_.dataReferences).Count} | Measure-Object -Sum).Sum}else{0})
    officialOptionControls=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object {@($_.controls | Where-Object {@($_.staticOptions).Count -gt 0}).Count} | Measure-Object -Sum).Sum}else{0})
    installedErrorCodes=$(if($mapCatalog){@($mapCatalog.errorCodes).Count}else{0})
    integrityMatched=$(if($mapCatalog){@($mapCatalog.integrityEntries | Where-Object status -eq 'MATCH').Count}else{0})
    integrityFailed=$(if($mapCatalog){@($mapCatalog.integrityEntries | Where-Object status -ne 'MATCH').Count}else{0})
    mapInitializationIssue=$mapInitializationIssue
    planOnly=[bool]$PlanOnly; reuseExistingTargetScreen=[bool]$reuseExistingTargetScreenRequested; requireExistingTargetScreen=[bool]$RequireExistingTargetScreen
    preserveTargetScreenAfterRun=[bool]$PreserveTargetScreenAfterRun;visiblePointerMotion=[bool]$RuntimeContext.VisiblePointerMotion;pointerDwellMilliseconds=[int]$RuntimeContext.PointerDwellMilliseconds
    initialScreensClosed=$initialScreensClosed; initialScreensPreserved=$initialScreensPreserved; initialSearchOverlaysClosed=$initialSearchOverlaysClosed
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReportDir "summary.json") -Encoding UTF8

    $RunState.OutputReady = $true
    $RunState.OutputPath = $ReportDir
    $RunState.UiActionCount = [int]$automationMetrics.FlaUiActionAttempts
    $RunState
}
