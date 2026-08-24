<#
.SYNOPSIS 승인된 상태 그래프를 따라 상태별 control discovery와 baseline 복구를 조정한다.
.DESCRIPTION 상태명과 locator를 해석하지 않고 TargetAdapter 계약과 주입된 FlaUI/증거 의존성만 호출한다.
.NOTES 이 모듈은 결과를 저장하거나 canonical verdict를 계산하지 않으며 실제 화면별 literal을 포함하지 않는다.
#>

# 상태 순회에 필요한 adapter graph, 실행 컨텍스트와 외부 관측 의존성을 묶는다.
function New-HtsStateDiscoveryContext {
    param(
        [Parameter(Mandatory = $true)]$StateGraph,
        [Parameter(Mandatory = $true)]$Dependencies,
        $RuntimeContext = $null
    )

    [pscustomobject]@{
        StateGraph = $StateGraph
        Dependencies = $Dependencies
        RuntimeContext = $RuntimeContext
    }
}

# 이름으로 주입된 상태 관측·전환·증거 의존성을 명시적 인수로 호출한다.
function Invoke-HtsStateDiscoveryDependency {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [object[]]$Arguments = @(),
        [switch]$Optional
    )

    if (-not $Context.Dependencies -or -not ($Context.Dependencies.PSObject.Properties.Name -contains $Name)) {
        if ($Optional) { return $null }
        throw "HTS state discovery dependency가 없습니다: $Name"
    }
    $dependency = $Context.Dependencies.$Name
    if (-not ($dependency -is [scriptblock])) { throw "HTS state discovery dependency는 scriptblock이어야 합니다: $Name" }
    & $dependency @Arguments
}

# transition이 승인된 비거래 의미 action, semantic locator와 required arrival Checkpoint를 모두 가지는지 확인한다.
function Test-HtsStateTransitionPolicy {
    param([Parameter(Mandatory = $true)]$Transition)

    $forbiddenKinds = @('FinalSubmit','AmendSubmit','CancelSubmit','TradeConfirmation')
    $risk = [string]$Transition.riskClass
    $action = $Transition.action
    $locator = if ($action) { $action.locator } else { $null }
    $arrival = $Transition.arrivalCheckpoint
    if (-not $action -or -not $locator -or -not $arrival) {
        return [pscustomobject]@{ allowed=$false; reasonCode='STATE_TRANSITION_CONFIGURATION_REQUIRED' }
    }
    if ($risk -in @('Transactional','Prohibited') -or [string]$action.kind -in $forbiddenKinds) {
        return [pscustomobject]@{ allowed=$false; reasonCode='STATE_TRANSACTIONAL_ACTION_PROHIBITED' }
    }
    if ([string]::IsNullOrWhiteSpace([string]$action.targetControlId)) {
        return [pscustomobject]@{ allowed=$false; reasonCode='STATE_TARGET_CONTROL_REQUIRED' }
    }
    if (-not [bool]$action.allowlisted -or @($action.approvalEvidence).Count -eq 0) {
        return [pscustomobject]@{ allowed=$false; reasonCode='STATE_ACTION_APPROVAL_REQUIRED' }
    }
    if ([string]$locator.strategy -eq 'Coordinates') {
        return [pscustomobject]@{ allowed=$false; reasonCode='STATE_COORDINATE_LOCATOR_PROHIBITED' }
    }
    if ([string]$locator.confidence -ne 'High' -or [string]::IsNullOrWhiteSpace([string]$locator.source)) {
        return [pscustomobject]@{ allowed=$false; reasonCode='STATE_LOCATOR_EVIDENCE_REQUIRED' }
    }
    if (-not [bool]$arrival.required -or [string]::IsNullOrWhiteSpace([string]$arrival.checkpointId) -or @($arrival.evidenceRequirements).Count -eq 0) {
        return [pscustomobject]@{ allowed=$false; reasonCode='STATE_ARRIVAL_CHECKPOINT_REQUIRED' }
    }
    [pscustomobject]@{ allowed=$true; reasonCode='' }
}

# raw control을 상태 identity, 창·프로세스·DPI·증거와 결합하고 실행 가능성을 fail-closed로 정규화한다.
function ConvertTo-HtsStateControlSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Control,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Observation,
        [string]$ScreenshotRef = '',
        [string]$UiTreeRef = ''
    )

    $window = $Observation.stateObservation
    $visible = if ($Control.PSObject.Properties.Name -contains 'visible') { [bool]$Control.visible } elseif ($Control.PSObject.Properties.Name -contains 'isOffscreen') { -not [bool]$Control.isOffscreen } else { $false }
    $enabled = if ($Control.PSObject.Properties.Name -contains 'enabled') { [bool]$Control.enabled } elseif ($Control.PSObject.Properties.Name -contains 'isEnabled') { [bool]$Control.isEnabled } else { $false }
    $activeState = [string]::Equals([string]$Observation.currentStateId,[string]$State.stateId,[StringComparison]::OrdinalIgnoreCase)
    $locatorConfidence = if ($Control.PSObject.Properties.Name -contains 'locatorConfidence') { [string]$Control.locatorConfidence } else { 'Unspecified' }
    $locatorApproved = if ($Control.PSObject.Properties.Name -contains 'locatorApproved') { [bool]$Control.locatorApproved } else { $false }
    $requestedExecutable = if ($Control.PSObject.Properties.Name -contains 'runtimeActionable') { [bool]$Control.runtimeActionable } elseif ($Control.PSObject.Properties.Name -contains 'executable') { [bool]$Control.executable } else { $false }

    [pscustomobject][ordered]@{
        stateContextId = [string]$State.stateContextId
        hwnd = [Int64]$Control.hwnd
        uiaRuntimeId = [string]$Control.uiaRuntimeId
        mapControlId = [string]$Control.mapModelId
        runtimeControlId = [string]$Control.controlId
        mapScreenCode = [string]$Control.mapScreenCode
        mapHostKey = [string]$Control.mapHostId
        mapHostClientRect = $Control.mapHostClientRect
        processOwnership = [pscustomobject]@{
            processId = [int]$window.processId
            processName = if ($Observation.processName) { [string]$Observation.processName } else { [string]$window.processName }
            matchesExpectedOwner = [bool]$Observation.processOwnershipMatch
        }
        dpi = [int]$window.dpi
        windowFingerprint = [string]$window.windowFingerprint
        stateIdentity = [pscustomobject]@{
            expectedStateId = [string]$State.stateId
            observedStateId = [string]$Observation.currentStateId
            checkpointSatisfied = $activeState
            evidenceRefs = @($Observation.evidenceRefs)
        }
        observedAt = if ($window.observedAt) { [string]$window.observedAt } else { (Get-Date).ToString('o') }
        screenshotRef = $ScreenshotRef
        uiTreeRef = $UiTreeRef
        locatorEvidence = [pscustomobject]@{
            source = [string]$Control.locatorSource
            confidence = $locatorConfidence
            approved = $locatorApproved
            evidenceRefs = @($Control.locatorEvidenceRefs)
        }
        visible = $visible
        enabled = $enabled
        activeState = $activeState
        executable = $requestedExecutable -and $activeState -and $visible -and $enabled -and $locatorApproved -and $locatorConfidence -eq 'High'
    }
}

# 상태 실패 시 screenshot과 UI tree 참조를 한 번에 수집하며 수집 실패도 빈 성공으로 가장하지 않는다.
function Get-HtsStateFailureEvidence {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$ReasonCode
    )

    $captured = Invoke-HtsStateDiscoveryDependency -Context $Context -Name 'CaptureFailureEvidence' -Arguments @($Context.RuntimeContext,$State,$ReasonCode) -Optional
    if (-not $captured) {
        return [pscustomobject]@{ screenshotRef='';uiTreeRef='';evidenceRefs=@() }
    }
    [pscustomobject]@{
        screenshotRef = [string]$captured.screenshotRef
        uiTreeRef = [string]$captured.uiTreeRef
        evidenceRefs = @($captured.evidenceRefs)
    }
}

# 현재 상태에서 baseline으로 승인된 복구 action을 보내고 별도의 arrival Checkpoint 결과를 반환한다.
function Invoke-HtsBaselineRestore {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string]$CurrentStateId = ''
    )

    $policy = $Context.StateGraph.restorePolicy
    $baseline = [string]$Context.StateGraph.baselineStateId
    $baselineState = @($Context.StateGraph.states | Where-Object { [string]::Equals([string]$_.stateId,$baseline,[StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)[0]
    if ([string]$Context.StateGraph.configurationStatus -ne 'Ready' -or [string]$policy.mode -eq 'ConfigurationRequired' -or [string]::IsNullOrWhiteSpace($baseline)) {
        return [pscustomobject]@{ status='PENDING';actionSent=$false;arrivalCheckpointSatisfied=$false;failureCategory='POLICY';reasonCode='STATE_RESTORE_CONFIGURATION_REQUIRED';evidenceRefs=@();screenshotRef='';uiTreeRef='' }
    }
    if ([string]::Equals($CurrentStateId,$baseline,[StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ status='SUCCESS';actionSent=$false;arrivalCheckpointSatisfied=$true;failureCategory='NONE';reasonCode='ALREADY_BASELINE';evidenceRefs=@();screenshotRef='';uiTreeRef='' }
    }

    $restoreTransition = [pscustomobject]@{
        riskClass='SafeNavigation'
        action=$policy.action
        arrivalCheckpoint=$policy.arrivalCheckpoint
    }
    $policyCheck = Test-HtsStateTransitionPolicy $restoreTransition
    if (-not $policyCheck.allowed) {
        return [pscustomobject]@{ status='PENDING';actionSent=$false;arrivalCheckpointSatisfied=$false;failureCategory='POLICY';reasonCode=$policyCheck.reasonCode;evidenceRefs=@();screenshotRef='';uiTreeRef='' }
    }

    try {
        $actionResult = Invoke-HtsStateDiscoveryDependency -Context $Context -Name 'InvokeRestoreAction' -Arguments @($Context.RuntimeContext,$policy,$CurrentStateId)
    } catch {
        $actionResult = [pscustomobject]@{ success=$false;actionSent=$false;elapsedMs=0;errorCode='STATE_RESTORE_ACTION_EXCEPTION';evidenceRefs=@() }
    }
    if (-not [bool]$actionResult.success -or -not [bool]$actionResult.actionSent) {
        $reason = if($actionResult.errorCode){[string]$actionResult.errorCode}else{'STATE_RESTORE_ACTION_FAILED'}
        $evidence = Get-HtsStateFailureEvidence -Context $Context -State $baselineState -ReasonCode $reason
        return [pscustomobject]@{ status='FAILED';actionSent=[bool]$actionResult.actionSent;arrivalCheckpointSatisfied=$false;failureCategory='AUTOMATION';reasonCode=$reason;evidenceRefs=@($actionResult.evidenceRefs)+@($evidence.evidenceRefs);screenshotRef=$evidence.screenshotRef;uiTreeRef=$evidence.uiTreeRef }
    }
    if ([long]$actionResult.elapsedMs -gt [long]$policy.timeoutMs) {
        $evidence = Get-HtsStateFailureEvidence -Context $Context -State $baselineState -ReasonCode 'STATE_RESTORE_TIMEOUT'
        return [pscustomobject]@{ status='FAILED';actionSent=$true;arrivalCheckpointSatisfied=$false;failureCategory='AUTOMATION';reasonCode='STATE_RESTORE_TIMEOUT';evidenceRefs=@($actionResult.evidenceRefs)+@($evidence.evidenceRefs);screenshotRef=$evidence.screenshotRef;uiTreeRef=$evidence.uiTreeRef }
    }

    try {
        $arrival = Invoke-HtsStateDiscoveryDependency -Context $Context -Name 'TestRestoreCheckpoint' -Arguments @($Context.RuntimeContext,$policy.arrivalCheckpoint,[int]$policy.timeoutMs)
    } catch {
        $arrival = [pscustomobject]@{ satisfied=$false;timedOut=$false;failureCategory='AUTOMATION';errorCode='STATE_RESTORE_CHECKPOINT_EXCEPTION';evidenceRefs=@() }
    }
    if (-not [bool]$arrival.satisfied) {
        $category = if ($arrival.failureCategory) { [string]$arrival.failureCategory } else { 'UNKNOWN' }
        $reason = if ($arrival.timedOut) { 'STATE_RESTORE_TIMEOUT' } elseif ($arrival.errorCode) { [string]$arrival.errorCode } else { 'STATE_RESTORE_CHECKPOINT_NOT_SATISFIED' }
        $evidence = Get-HtsStateFailureEvidence -Context $Context -State $baselineState -ReasonCode $reason
        return [pscustomobject]@{ status='FAILED';actionSent=$true;arrivalCheckpointSatisfied=$false;failureCategory=$category;reasonCode=$reason;evidenceRefs=@($actionResult.evidenceRefs)+@($arrival.evidenceRefs)+@($evidence.evidenceRefs);screenshotRef=$evidence.screenshotRef;uiTreeRef=$evidence.uiTreeRef }
    }
    [pscustomobject]@{ status='SUCCESS';actionSent=$true;arrivalCheckpointSatisfied=$true;failureCategory='NONE';reasonCode='';evidenceRefs=@($actionResult.evidenceRefs)+@($arrival.evidenceRefs);screenshotRef='';uiTreeRef='' }
}

# 그래프의 상태를 순서대로 관측·전환·탐색하고 상태별 결과와 최종 baseline restore를 분리해 반환한다.
function Invoke-HtsStateDiscovery {
    param([Parameter(Mandatory = $true)]$Context)

    $graph = $Context.StateGraph
    $stateResults = New-Object Collections.Generic.List[object]
    $transitionActionCount = 0
    $transactionalActionCount = 0
    if ([string]$graph.configurationStatus -ne 'Ready') {
        foreach ($state in @($graph.states)) {
            $stateResults.Add([pscustomobject][ordered]@{
                stateContext=$state;status='PENDING';failureCategory='POLICY';reasonCode='STATE_GRAPH_CONFIGURATION_REQUIRED'
                transition=$null;controls=@();screenshotRef='';uiTreeRef=''
            })
        }
        return [pscustomobject][ordered]@{
            schemaVersion='1.0';graphId=[string]$graph.graphId;observedAt=(Get-Date).ToString('o');states=$stateResults.ToArray()
            restore=(Invoke-HtsBaselineRestore -Context $Context);transitionActionCount=0;transactionalActionCount=0
        }
    }

    $observation = Invoke-HtsStateDiscoveryDependency -Context $Context -Name 'ObserveState' -Arguments @($Context.RuntimeContext)
    $currentStateId = if ($observation) { [string]$observation.currentStateId } else { '' }
    foreach ($state in @($graph.states)) {
        $transitionResult = $null
        if ([string]$state.configurationStatus -ne 'Ready') {
            $stateResults.Add([pscustomobject][ordered]@{stateContext=$state;status='PENDING';failureCategory='POLICY';reasonCode='STATE_CONFIGURATION_REQUIRED';transition=$null;controls=@();screenshotRef='';uiTreeRef=''})
            continue
        }
        if (-not $observation -or -not [bool]$observation.success) {
            $evidence = Get-HtsStateFailureEvidence -Context $Context -State $state -ReasonCode 'STATE_OBSERVATION_FAILED'
            $category = if ($observation -and $observation.failureCategory) { [string]$observation.failureCategory } else { 'UNKNOWN' }
            $stateResults.Add([pscustomobject][ordered]@{stateContext=$state;status='FAILED';failureCategory=$category;reasonCode='STATE_OBSERVATION_FAILED';transition=$null;controls=@();screenshotRef=$evidence.screenshotRef;uiTreeRef=$evidence.uiTreeRef})
            continue
        }

        if (-not [string]::Equals($currentStateId,[string]$state.stateId,[StringComparison]::OrdinalIgnoreCase)) {
            $transition = @($graph.transitions | Where-Object {
                [string]::Equals([string]$_.sourceStateId,$currentStateId,[StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$_.targetStateId,[string]$state.stateId,[StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1)[0]
            if (-not $transition) {
                $stateResults.Add([pscustomobject][ordered]@{stateContext=$state;status='PENDING';failureCategory='POLICY';reasonCode='STATE_TRANSITION_CONFIGURATION_REQUIRED';transition=$null;controls=@();screenshotRef='';uiTreeRef=''})
                continue
            }

            $policyCheck = Test-HtsStateTransitionPolicy $transition
            if (-not $policyCheck.allowed) {
                $stateResults.Add([pscustomobject][ordered]@{stateContext=$state;status='PENDING';failureCategory='POLICY';reasonCode=$policyCheck.reasonCode;transition=$null;controls=@();screenshotRef='';uiTreeRef=''})
                continue
            }
            $observation = Invoke-HtsStateDiscoveryDependency -Context $Context -Name 'ObserveState' -Arguments @($Context.RuntimeContext)
            if (-not $observation -or -not [bool]$observation.success) {
                $evidence = Get-HtsStateFailureEvidence -Context $Context -State $state -ReasonCode 'STATE_PRECONDITION_OBSERVATION_FAILED'
                $category = if ($observation -and $observation.failureCategory) { [string]$observation.failureCategory } else { 'UNKNOWN' }
                $stateResults.Add([pscustomobject][ordered]@{stateContext=$state;status='FAILED';failureCategory=$category;reasonCode='STATE_PRECONDITION_OBSERVATION_FAILED';transition=$null;controls=@();screenshotRef=$evidence.screenshotRef;uiTreeRef=$evidence.uiTreeRef})
                continue
            }
            $precondition = Invoke-HtsStateDiscoveryDependency -Context $Context -Name 'TestPrecondition' -Arguments @($Context.RuntimeContext,$transition,$observation)
            if (-not [bool]$precondition.satisfied) {
                $stateResults.Add([pscustomobject][ordered]@{stateContext=$state;status='PENDING';failureCategory='POLICY';reasonCode='STATE_PRECONDITION_NOT_SATISFIED';transition=[pscustomobject]@{transitionId=[string]$transition.transitionId;actionSent=$false;actionVerified=$false;arrivalCheckpointSatisfied=$false;status='PENDING';errorCode='STATE_PRECONDITION_NOT_SATISFIED';elapsedMs=0;evidenceRefs=@($precondition.evidenceRefs)};controls=@();screenshotRef='';uiTreeRef=''})
                continue
            }

            try {
                $actionResult = Invoke-HtsStateDiscoveryDependency -Context $Context -Name 'InvokeTransitionAction' -Arguments @($Context.RuntimeContext,$transition,$observation)
            } catch {
                $actionResult = [pscustomobject]@{ success=$false;actionSent=$false;actionVerified=$false;elapsedMs=0;errorCode='STATE_TRANSITION_ACTION_EXCEPTION';evidenceRefs=@() }
            }
            if ([bool]$actionResult.actionSent) { $transitionActionCount++ }
            if ([string]$transition.riskClass -in @('Transactional','Prohibited')) { $transactionalActionCount++ }
            if ([bool]$actionResult.actionSent) { $currentStateId = '' }
            if (-not [bool]$actionResult.success -or -not [bool]$actionResult.actionSent) {
                $reason = if ($actionResult.errorCode) { [string]$actionResult.errorCode } else { 'STATE_TRANSITION_ACTION_FAILED' }
                $evidence = Get-HtsStateFailureEvidence -Context $Context -State $state -ReasonCode $reason
                $transitionResult = [pscustomobject]@{transitionId=[string]$transition.transitionId;actionSent=[bool]$actionResult.actionSent;actionVerified=[bool]$actionResult.actionVerified;arrivalCheckpointSatisfied=$false;status='FAILED';errorCode=$reason;elapsedMs=[long]$actionResult.elapsedMs;evidenceRefs=@($actionResult.evidenceRefs)+@($evidence.evidenceRefs)}
                $stateResults.Add([pscustomobject][ordered]@{stateContext=$state;status='FAILED';failureCategory='AUTOMATION';reasonCode=$reason;transition=$transitionResult;controls=@();screenshotRef=$evidence.screenshotRef;uiTreeRef=$evidence.uiTreeRef})
                continue
            }
            if ([long]$actionResult.elapsedMs -gt [long]$transition.timeoutMs) {
                $evidence = Get-HtsStateFailureEvidence -Context $Context -State $state -ReasonCode 'STATE_TRANSITION_TIMEOUT'
                $transitionResult = [pscustomobject]@{transitionId=[string]$transition.transitionId;actionSent=$true;actionVerified=[bool]$actionResult.actionVerified;arrivalCheckpointSatisfied=$false;status='FAILED';errorCode='STATE_TRANSITION_TIMEOUT';elapsedMs=[long]$actionResult.elapsedMs;evidenceRefs=@($actionResult.evidenceRefs)+@($evidence.evidenceRefs)}
                $stateResults.Add([pscustomobject][ordered]@{stateContext=$state;status='FAILED';failureCategory='AUTOMATION';reasonCode='STATE_TRANSITION_TIMEOUT';transition=$transitionResult;controls=@();screenshotRef=$evidence.screenshotRef;uiTreeRef=$evidence.uiTreeRef})
                continue
            }

            try {
                $arrival = Invoke-HtsStateDiscoveryDependency -Context $Context -Name 'TestArrivalCheckpoint' -Arguments @($Context.RuntimeContext,$transition.arrivalCheckpoint,[int]$transition.timeoutMs)
            } catch {
                $arrival = [pscustomobject]@{ satisfied=$false;timedOut=$false;elapsedMs=0;failureCategory='AUTOMATION';errorCode='STATE_ARRIVAL_CHECKPOINT_EXCEPTION';evidenceRefs=@() }
            }
            $elapsed = [long]$actionResult.elapsedMs + [long]$arrival.elapsedMs
            if (-not [bool]$arrival.satisfied -or [bool]$arrival.timedOut -or $elapsed -gt [long]$transition.timeoutMs) {
                $reason = if ([bool]$arrival.timedOut -or $elapsed -gt [long]$transition.timeoutMs) { 'STATE_TRANSITION_TIMEOUT' } elseif ($arrival.errorCode) { [string]$arrival.errorCode } else { 'STATE_ARRIVAL_CHECKPOINT_NOT_SATISFIED' }
                $category = if ($arrival.failureCategory) { [string]$arrival.failureCategory } else { 'UNKNOWN' }
                $evidence = Get-HtsStateFailureEvidence -Context $Context -State $state -ReasonCode $reason
                $transitionResult = [pscustomobject]@{transitionId=[string]$transition.transitionId;actionSent=$true;actionVerified=[bool]$actionResult.actionVerified;arrivalCheckpointSatisfied=$false;status='FAILED';errorCode=$reason;elapsedMs=$elapsed;evidenceRefs=@($actionResult.evidenceRefs)+@($arrival.evidenceRefs)+@($evidence.evidenceRefs)}
                $stateResults.Add([pscustomobject][ordered]@{stateContext=$state;status='FAILED';failureCategory=$category;reasonCode=$reason;transition=$transitionResult;controls=@();screenshotRef=$evidence.screenshotRef;uiTreeRef=$evidence.uiTreeRef})
                continue
            }

            $currentStateId = [string]$state.stateId
            $observation = Invoke-HtsStateDiscoveryDependency -Context $Context -Name 'ObserveState' -Arguments @($Context.RuntimeContext)
            $transitionResult = [pscustomobject]@{transitionId=[string]$transition.transitionId;actionSent=$true;actionVerified=[bool]$actionResult.actionVerified;arrivalCheckpointSatisfied=$true;status='SUCCESS';errorCode='';elapsedMs=$elapsed;evidenceRefs=@($actionResult.evidenceRefs)+@($arrival.evidenceRefs)}
        }

        try {
            $stateEvidence = Invoke-HtsStateDiscoveryDependency -Context $Context -Name 'CaptureStateEvidence' -Arguments @($Context.RuntimeContext,$state,$observation) -Optional
        } catch {
            $stateEvidence = $null
        }
        if (-not $stateEvidence -or [string]::IsNullOrWhiteSpace([string]$stateEvidence.screenshotRef) -or [string]::IsNullOrWhiteSpace([string]$stateEvidence.uiTreeRef)) {
            $evidence = Get-HtsStateFailureEvidence -Context $Context -State $state -ReasonCode 'STATE_DISCOVERY_EVIDENCE_MISSING'
            $stateResults.Add([pscustomobject][ordered]@{stateContext=$state;status='FAILED';failureCategory='AUTOMATION';reasonCode='STATE_DISCOVERY_EVIDENCE_MISSING';transition=$transitionResult;controls=@();screenshotRef=$evidence.screenshotRef;uiTreeRef=$evidence.uiTreeRef})
            continue
        }
        try {
            $rawControls = @(Invoke-HtsStateDiscoveryDependency -Context $Context -Name 'DiscoverControls' -Arguments @($Context.RuntimeContext,$state,$observation))
            $controls = @($rawControls | ForEach-Object { ConvertTo-HtsStateControlSnapshot -Control $_ -State $state -Observation $observation -ScreenshotRef ([string]$stateEvidence.screenshotRef) -UiTreeRef ([string]$stateEvidence.uiTreeRef) })
        } catch {
            $evidence = Get-HtsStateFailureEvidence -Context $Context -State $state -ReasonCode 'STATE_CONTROL_DISCOVERY_FAILED'
            $stateResults.Add([pscustomobject][ordered]@{stateContext=$state;status='FAILED';failureCategory='AUTOMATION';reasonCode='STATE_CONTROL_DISCOVERY_FAILED';transition=$transitionResult;controls=@();screenshotRef=$evidence.screenshotRef;uiTreeRef=$evidence.uiTreeRef})
            continue
        }
        $stateResults.Add([pscustomobject][ordered]@{stateContext=$state;status='SUCCESS';failureCategory='NONE';reasonCode='';transition=$transitionResult;controls=$controls;screenshotRef=[string]$stateEvidence.screenshotRef;uiTreeRef=[string]$stateEvidence.uiTreeRef})
    }

    $restore = Invoke-HtsBaselineRestore -Context $Context -CurrentStateId $currentStateId
    [pscustomobject][ordered]@{
        schemaVersion='1.0';graphId=[string]$graph.graphId;observedAt=(Get-Date).ToString('o');states=$stateResults.ToArray()
        restore=$restore;transitionActionCount=$transitionActionCount;transactionalActionCount=$transactionalActionCount
    }
}
