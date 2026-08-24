<# .SYNOPSIS Fake 화면으로 상태 순회, 도착 Checkpoint, 증거 분리와 baseline 복구를 검증한다. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-state-discovery.ps1')

# boolean 조건을 검증하고 assertion 수를 누적한다.
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERT_TRUE failed: $Message" }; $script:assertions++ }

# 문자열 비교로 Fake 계약의 직렬화 가능한 값을 검증한다.
function Assert-Equal($Expected, $Actual, [string]$Message) { if ([string]$Expected -ne [string]$Actual) { throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'" }; $script:assertions++ }

# 승인된 semantic locator action을 Fake 상태 그래프에 만든다.
function New-FakeAction([string]$Kind = 'Select') {
    [pscustomobject]@{
        targetControlId='FAKE_STATE_SELECTOR'
        kind=$Kind;allowlisted=$true;approvalEvidence=@('fixture:approval')
        locator=[pscustomobject]@{strategy='AutomationId';automationId='fake-state-selector';source='fixture:locator';confidence='High'}
    }
}

# required arrival Checkpoint 계약을 Fake 상태에 만든다.
function New-FakeCheckpoint([string]$Id) {
    [pscustomobject]@{checkpointId=$Id;kind='AssertState';required=$true;evidenceRequirements=@('fixture:state')}
}

# 지정한 수의 상태와 순차 전환, 결정적 baseline restore를 가진 범용 Fake graph를 만든다.
function New-FakeGraph([int]$StateCount = 3) {
    $ids = @('a','b','c')[0..($StateCount-1)]
    $states = @($ids | ForEach-Object {
        [pscustomobject]@{stateId=$_;stateContextId="state:$_";screenId='F001';configurationStatus='Ready';mapScreenCodes=@("MAP_$($_.ToUpperInvariant())");mapHostKeys=@("host:$_");evidenceRefs=@("fixture:$_")}
    })
    $transitions = New-Object Collections.Generic.List[object]
    for ($index=1; $index -lt $ids.Count; $index++) {
        $source=$ids[$index-1];$target=$ids[$index]
        $transitions.Add([pscustomobject]@{
            transitionId="$source-to-$target";sourceStateId=$source;targetStateId=$target
            precondition=[pscustomobject]@{expectedStateId=$source;evidenceRequirements=@('fixture:precondition')}
            action=(New-FakeAction);arrivalCheckpoint=(New-FakeCheckpoint "arrive-$target");timeoutMs=100
            restoreAction=(New-FakeAction);riskClass='SafeNavigation';evidenceRequirements=@('fixture:action','fixture:arrival')
        })
    }
    [pscustomobject]@{
        schemaVersion='1.0';graphId='fake-graph';screenId='F001';configurationStatus='Ready';baselineStateId='a'
        states=$states;transitions=$transitions.ToArray()
        restorePolicy=[pscustomobject]@{mode='Deterministic';baselineStateId='a';maxAttempts=1;timeoutMs=100;action=(New-FakeAction);arrivalCheckpoint=(New-FakeCheckpoint 'restore-a');evidenceRequirements=@('fixture:restore')}
    }
}

# 모든 물리 동작을 메모리의 Fake state로 제한하는 상태 discovery 의존성을 만든다.
function New-FakeDependencies {
    [pscustomobject]@{
        ObserveState = {
            param($Runtime)
            [pscustomobject]@{
                success=$true;currentStateId=[string]$Runtime.currentState;processName='fake';processOwnershipMatch=$true;evidenceRefs=@("state:$($Runtime.currentState)")
                stateObservation=[pscustomobject]@{processId=123;dpi=96;windowFingerprint='fake-window';observedAt='2026-08-24T00:00:00+09:00'}
            }
        }
        TestPrecondition = { param($Runtime,$Transition,$Observation) [pscustomobject]@{satisfied=[bool]$Runtime.preconditionSatisfied;evidenceRefs=@('fixture:precondition')} }
        InvokeTransitionAction = {
            param($Runtime,$Transition,$Observation)
            $Runtime.events.Add("transition:$($Transition.transitionId)")
            if ($Runtime.actionSent) { $Runtime.currentState=[string]$Transition.targetStateId }
            [pscustomobject]@{success=[bool]$Runtime.actionSuccess;actionSent=[bool]$Runtime.actionSent;actionVerified=[bool]$Runtime.actionVerified;elapsedMs=[long]$Runtime.transitionElapsedMs;errorCode=if($Runtime.actionSuccess){''}else{'FAKE_ACTION_FAILED'};evidenceRefs=@('fixture:action')}
        }
        TestArrivalCheckpoint = {
            param($Runtime,$Checkpoint,$TimeoutMs)
            [pscustomobject]@{satisfied=[bool]$Runtime.arrivalSatisfied;timedOut=[bool]$Runtime.arrivalTimedOut;elapsedMs=[long]$Runtime.arrivalElapsedMs;failureCategory=[string]$Runtime.arrivalFailureCategory;errorCode='';evidenceRefs=@('fixture:arrival')}
        }
        DiscoverControls = {
            param($Runtime,$State,$Observation)
            @(
                [pscustomobject]@{hwnd=42;uiaRuntimeId='1.2.3';mapModelId='MAP-CONTROL';controlId='RUNTIME-CONTROL';mapScreenCode=$State.mapScreenCodes[0];mapHostId=$State.mapHostKeys[0];visible=$true;enabled=$true;runtimeActionable=$true;locatorSource='fixture:locator';locatorConfidence='High';locatorApproved=$true;locatorEvidenceRefs=@('fixture:approved')},
                [pscustomobject]@{hwnd=43;uiaRuntimeId='1.2.4';mapModelId='HIDDEN-CONTROL';controlId='HIDDEN-CONTROL';mapScreenCode=$State.mapScreenCodes[0];mapHostId=$State.mapHostKeys[0];visible=$false;enabled=$true;runtimeActionable=$true;locatorSource='fixture:locator';locatorConfidence='High';locatorApproved=$true;locatorEvidenceRefs=@('fixture:approved')}
            )
        }
        CaptureStateEvidence = { param($Runtime,$State,$Observation) [pscustomobject]@{screenshotRef="screenshots/$($State.stateId).png";uiTreeRef="ui-tree/$($State.stateId).json";evidenceRefs=@("state:$($State.stateId)")} }
        CaptureFailureEvidence = { param($Runtime,$State,$ReasonCode) [pscustomobject]@{screenshotRef="screenshots/$($State.stateId).png";uiTreeRef="ui-tree/$($State.stateId).json";evidenceRefs=@("failure:$ReasonCode")} }
        InvokeRestoreAction = {
            param($Runtime,$Policy,$CurrentStateId)
            $Runtime.events.Add('restore')
            if ($Runtime.restoreActionSuccess) { $Runtime.currentState=[string]$Policy.baselineStateId }
            [pscustomobject]@{success=[bool]$Runtime.restoreActionSuccess;actionSent=$true;elapsedMs=[long]$Runtime.restoreElapsedMs;errorCode=if($Runtime.restoreActionSuccess){''}else{'FAKE_RESTORE_FAILED'};evidenceRefs=@('fixture:restore-action')}
        }
        TestRestoreCheckpoint = { param($Runtime,$Checkpoint,$TimeoutMs) [pscustomobject]@{satisfied=[bool]$Runtime.restoreArrivalSatisfied;timedOut=$false;failureCategory='AUTOMATION';errorCode='';evidenceRefs=@('fixture:restore-arrival')} }
    }
}

# 각 테스트에 격리된 Fake 실행 상태와 action 기록 목록을 만든다.
function New-FakeRuntime {
    [pscustomobject]@{
        currentState='a';preconditionSatisfied=$true;actionSuccess=$true;actionSent=$true;actionVerified=$true
        transitionElapsedMs=10;arrivalSatisfied=$true;arrivalTimedOut=$false;arrivalElapsedMs=10;arrivalFailureCategory='APPLICATION'
        restoreActionSuccess=$true;restoreArrivalSatisfied=$true;restoreElapsedMs=10
        events=(New-Object Collections.Generic.List[string])
    }
}

$script:assertions = 0
$dependencies = New-FakeDependencies

$runtime = New-FakeRuntime
$normal = Invoke-HtsStateDiscovery (New-HtsStateDiscoveryContext -StateGraph (New-FakeGraph) -Dependencies $dependencies -RuntimeContext $runtime)
Assert-Equal 'SUCCESS,SUCCESS,SUCCESS' (($normal.states | ForEach-Object { $_.status }) -join ',') 'fake screen follows the configured state order'
Assert-Equal 'transition:a-to-b,transition:b-to-c,restore' ($runtime.events -join ',') 'state transitions run in order and restore runs last'
Assert-Equal 'SUCCESS' $normal.restore.status 'baseline restore success is separate from state results'
Assert-True $normal.restore.arrivalCheckpointSatisfied 'restore requires its own arrival Checkpoint'
Assert-Equal 2 $normal.transitionActionCount 'only state transition actions are counted'
Assert-Equal 0 $normal.transactionalActionCount 'transactional action count remains zero'
Assert-True $normal.states[0].controls[0].executable 'active visible approved control may be executable'
Assert-True (-not $normal.states[0].controls[1].executable) 'hidden control is not promoted to executable'
Assert-Equal 'screenshots/a.png' $normal.states[0].screenshotRef 'successful state keeps screenshot reference'
Assert-Equal 'ui-tree/a.json' $normal.states[0].controls[0].uiTreeRef 'control snapshot keeps state UI tree reference'
Assert-True ([string]$normal.states[0].controls[0].stateContextId -ne [string]$normal.states[1].controls[0].stateContextId) 'same control identity remains distinct by stateContext'

$runtime = New-FakeRuntime
$runtime.preconditionSatisfied=$false
$blocked = Invoke-HtsStateDiscovery (New-HtsStateDiscoveryContext -StateGraph (New-FakeGraph 2) -Dependencies $dependencies -RuntimeContext $runtime)
Assert-Equal 'PENDING' $blocked.states[1].status 'failed precondition blocks transition'
Assert-Equal 'STATE_PRECONDITION_NOT_SATISFIED' $blocked.states[1].reasonCode 'precondition block reason is explicit'
Assert-Equal 0 $blocked.transitionActionCount 'precondition failure sends no action'

$runtime = New-FakeRuntime
$runtime.arrivalSatisfied=$false
$arrivalFailure = Invoke-HtsStateDiscovery (New-HtsStateDiscoveryContext -StateGraph (New-FakeGraph 2) -Dependencies $dependencies -RuntimeContext $runtime)
Assert-Equal 'FAILED' $arrivalFailure.states[1].status 'action success without arrival Checkpoint is a state failure'
Assert-True $arrivalFailure.states[1].transition.actionSent 'action delivery remains separately recorded'
Assert-True (-not $arrivalFailure.states[1].transition.arrivalCheckpointSatisfied) 'arrival evidence is not inferred from action success'
Assert-Equal 'APPLICATION' $arrivalFailure.states[1].failureCategory 'arrival mismatch uses supplied failure category'
Assert-Equal 'screenshots/b.png' $arrivalFailure.states[1].screenshotRef 'state failure keeps screenshot reference'
Assert-Equal 'ui-tree/b.json' $arrivalFailure.states[1].uiTreeRef 'state failure keeps UI tree reference'
Assert-True ($runtime.events.Contains('restore')) 'uncertain state after failed arrival still triggers restore'

$runtime = New-FakeRuntime
$runtime.transitionElapsedMs=120
$timeout = Invoke-HtsStateDiscovery (New-HtsStateDiscoveryContext -StateGraph (New-FakeGraph 2) -Dependencies $dependencies -RuntimeContext $runtime)
Assert-Equal 'FAILED' $timeout.states[1].status 'transition timeout fails the state'
Assert-Equal 'STATE_TRANSITION_TIMEOUT' $timeout.states[1].reasonCode 'timeout reason is explicit'

$runtime = New-FakeRuntime
$runtime.restoreActionSuccess=$false
$restoreFailure = Invoke-HtsStateDiscovery (New-HtsStateDiscoveryContext -StateGraph (New-FakeGraph 2) -Dependencies $dependencies -RuntimeContext $runtime)
Assert-Equal 'SUCCESS' $restoreFailure.states[1].status 'state discovery success is retained separately'
Assert-Equal 'FAILED' $restoreFailure.restore.status 'restore failure is reported separately'
Assert-Equal 'AUTOMATION' $restoreFailure.restore.failureCategory 'restore action failure is automation evidence'
Assert-Equal 'screenshots/a.png' $restoreFailure.restore.screenshotRef 'restore failure keeps screenshot reference'
Assert-Equal 'ui-tree/a.json' $restoreFailure.restore.uiTreeRef 'restore failure keeps UI tree reference'

$runtime = New-FakeRuntime
$discoveryFailureDependencies = New-FakeDependencies
$discoveryFailureDependencies.DiscoverControls = {
    param($Runtime,$State,$Observation)
    if ([string]$State.stateId -eq 'b') { throw 'fixture discovery failure' }
    @([pscustomobject]@{hwnd=42;uiaRuntimeId='1.2.3';mapModelId='MAP-CONTROL';controlId='RUNTIME-CONTROL';visible=$true;enabled=$true;runtimeActionable=$true;locatorSource='fixture:locator';locatorConfidence='High';locatorApproved=$true})
}
$discoveryFailure = Invoke-HtsStateDiscovery (New-HtsStateDiscoveryContext -StateGraph (New-FakeGraph) -Dependencies $discoveryFailureDependencies -RuntimeContext $runtime)
Assert-Equal 'SUCCESS,FAILED,SUCCESS' (($discoveryFailure.states | ForEach-Object { $_.status }) -join ',') 'one state discovery failure does not collapse later states'
Assert-Equal 'STATE_CONTROL_DISCOVERY_FAILED' $discoveryFailure.states[1].reasonCode 'control discovery exception is classified per state'
Assert-Equal 'screenshots/b.png' $discoveryFailure.states[1].screenshotRef 'control discovery failure keeps screenshot evidence'
Assert-True ($runtime.events.Contains('restore')) 'control discovery failure still reaches deterministic restore'

$runtime = New-FakeRuntime
$forbiddenGraph = New-FakeGraph 2
$forbiddenGraph.transitions[0].action.kind='FinalSubmit'
$forbidden = Invoke-HtsStateDiscovery (New-HtsStateDiscoveryContext -StateGraph $forbiddenGraph -Dependencies $dependencies -RuntimeContext $runtime)
Assert-Equal 'PENDING' $forbidden.states[1].status 'prohibited transition remains pending'
Assert-Equal 'STATE_TRANSACTIONAL_ACTION_PROHIBITED' $forbidden.states[1].reasonCode 'prohibited action policy is explicit'
Assert-Equal 0 $forbidden.transitionActionCount 'prohibited action is never sent'
Assert-Equal 0 $forbidden.transactionalActionCount 'blocked transactional action is not counted as executed'

$configurationGraph = New-FakeGraph 2
$configurationGraph.configurationStatus='ConfigurationRequired'
$configurationGraph.baselineStateId=''
$configurationGraph.transitions=@()
$configurationGraph.restorePolicy.mode='ConfigurationRequired'
$runtime = New-FakeRuntime
$pending = Invoke-HtsStateDiscovery (New-HtsStateDiscoveryContext -StateGraph $configurationGraph -Dependencies ([pscustomobject]@{}) -RuntimeContext $runtime)
Assert-Equal 'PENDING,PENDING' (($pending.states | ForEach-Object { $_.status }) -join ',') 'unapproved graph remains state-by-state pending without UI access'
Assert-Equal 'PENDING' $pending.restore.status 'unconfigured baseline restore remains pending'
Assert-Equal 0 $pending.transitionActionCount 'configuration-required plan sends no transition'

$moduleText = Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-state-discovery.ps1') -Raw -Encoding UTF8
$orchestrationText = Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-rule-suite-orchestration.ps1') -Raw -Encoding UTF8
Assert-True ($moduleText -notmatch '\$script:|\$global:') 'state module has no shared script/global state'
Assert-True ($moduleText -notmatch 'ResultEvaluator|TestResult|Set-Content|Add-Content') 'state module cannot evaluate verdicts or write reports'
Assert-True ($orchestrationText -notmatch 'stateContextId\s*=|sourceStateId\s*=|targetStateId\s*=') 'large orchestration does not hardcode business states'

Write-Output "HTS_STATE_DISCOVERY_TESTS=PASS assertions=$script:assertions"
