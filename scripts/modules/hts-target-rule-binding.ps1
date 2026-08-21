<#
.SYNOPSIS 승인된 계획을 현재 HTS UIA 요소에 결합한다.
.DESCRIPTION 계획 항목과 동적으로 재발견한 컨트롤을 연결하고 실행 전 계약을 검증한다.
.INPUTS 계획 항목, 발견 결과, 실행 컨텍스트.
.OUTPUTS 결합된 컨트롤과 검증 결과 객체.
.NOTES 판정과 리포트 생성은 수행하지 않는다.
#>
# 계획 생성: 일반 자동탐색에서는 컨트롤별 독립 선택지를, 시나리오 모드에서는 승인된 단계만 실행 항목으로 만든다.
function Get-RuleControlPlanItems($Context, $Controls) {
    $rows = New-Object Collections.Generic.List[object]
    $maxActions = [int]$Context.Dataset.autoExploration.maxActionsPerScreen
    foreach ($control in @($Controls | Sort-Object tabOrder,controlId)) {
        if ($control.claimedByDataset) { continue }
        if (@($control.options).Count -eq 0) {
            $rows.Add([pscustomobject]@{planItemId="$($control.controlId)-pending";control=$control;option=$null;status="PENDING";errorCode=$(if ($control.dataRequired) {"PENDING_DATA_REQUIRED"} else {"OPTIONS_NOT_DISCOVERED"})})
        } else {
            foreach ($option in @($control.options)) {
                $rows.Add([pscustomobject]@{planItemId="$($control.controlId)-$($option.id)";control=$control;option=$option;status="READY";errorCode=""})
                if ($rows.Count -ge $maxActions) { break }
            }
        }
        if ($rows.Count -ge $maxActions) { break }
    }
    $rows.ToArray()
}

# 시나리오 계획 변환: logicalName 바인딩과 선택값을 현재 실행 항목에 연결한다.
function Get-RuleScenarioPlanItems($Context, $Controls, $ScenarioCase) {
    $rows = New-Object Collections.Generic.List[object]
    $controlSnapshot = @($Controls)
    $executionOrder = if ([string]$ScenarioCase.executionOrder) { [string]$ScenarioCase.executionOrder } else { 'RuntimeTabOrder' }
    foreach ($step in @($ScenarioCase.steps | Sort-Object sequence)) {
        $action = [string]$step.action
        if ($action -in @('Focus','Observe')) { continue }
        $logicalName = ([string]$step.controlLogicalName).Trim()
        $mapScreenCode = $(if ([string]$step.mapScreenCode) { [string]$step.mapScreenCode } else { [string]$ScenarioCase.mapScreenCode }).Trim()
        $stateContext = ([string]$step.stateContext).Trim()
        $isGlobalAssertion = $action -in @('Restore','AssertPopup','AssertNoTransmission')
        $candidates = @()
        if (-not $isGlobalAssertion) {
            $candidateRows = New-Object Collections.Generic.List[object]
            foreach ($candidate in $controlSnapshot) {
                $candidateName = ([string]$candidate.name).Trim()
                $candidateModelId = ([string]$candidate.mapModelId).Trim()
                $candidateControlId = ([string]$candidate.controlId).Trim()
                $candidateMapCode = ([string]$candidate.mapScreenCode).Trim()
                $candidateState = ([string]$candidate.stateContext).Trim()
                $nameMatches = [string]::Equals($candidateName,$logicalName,[StringComparison]::OrdinalIgnoreCase) -or
                    [string]::Equals($candidateModelId,$logicalName,[StringComparison]::OrdinalIgnoreCase) -or
                    $candidateControlId.EndsWith(":$logicalName",[StringComparison]::OrdinalIgnoreCase)
                $mapMatches = -not $mapScreenCode -or [string]::Equals($candidateMapCode,$mapScreenCode,[StringComparison]::OrdinalIgnoreCase)
                $stateMatches = Test-RuleStateContextMatch $stateContext $candidateState
                if ($nameMatches -and $mapMatches -and $stateMatches) { $candidateRows.Add($candidate) }
            }
            $candidates = @($candidateRows.ToArray() | Sort-Object @{Expression={if([string]$_.definitionSource -eq 'MAP+Runtime'){0}elseif([string]$_.definitionSource -eq 'RuntimeOnly'){1}else{2}}},tabOrder)
        }
        $control = if ($isGlobalAssertion) {
            [pscustomobject]@{
                controlId="${mapScreenCode}:$action";controlKind='Auto';name=$action;className='ScenarioAssertion';hwnd=0
                locatorSignature="SCENARIO|$mapScreenCode|$action";initialValue='';tabOrder=999998;tabStop=$false;stateContext=$stateContext;mapScreenCode=$mapScreenCode;regionRole='content'
                claimedByDataset=$false;dataRequired=$false;pendingReason='';definitionSource='ScenarioGlobal';runtimeName='';mapModelId='';mapMatched=$true;options=@()
            }
        } elseif ($candidates.Count -gt 0) { $candidates[0] } else { $null }
        if (-not $control) {
            $sameNameCount = @($controlSnapshot | Where-Object { [string]::Equals(([string]$_.name).Trim(),$logicalName,[StringComparison]::OrdinalIgnoreCase) }).Count
            $sameMapCount = @($controlSnapshot | Where-Object { [string]::Equals(([string]$_.mapScreenCode).Trim(),$mapScreenCode,[StringComparison]::OrdinalIgnoreCase) }).Count
            $control = [pscustomobject]@{
                controlId="$([string]$ScenarioCase.screenNumber):$logicalName";controlKind='Auto';name=$logicalName;className='ScenarioUnbound';hwnd=0
                locatorSignature="SCENARIO|$mapScreenCode|$logicalName|$stateContext|UNBOUND";initialValue='';tabOrder=999999;tabStop=$false;stateContext=$stateContext;mapScreenCode=$mapScreenCode;regionRole='content'
                claimedByDataset=$false;dataRequired=$true;pendingReason="시나리오 logicalName을 현재 화면의 MAP+Runtime 컨트롤과 결합하지 못했습니다. logicalName=$logicalName, map=$mapScreenCode, state=$stateContext, sameName=$sameNameCount, sameMap=$sameMapCount"
                definitionSource='Scenario';runtimeName='';mapModelId=$logicalName;mapMatched=$false;options=@()
            }
        }

        $selected = $step.selectedValue
        $option = $null
        if ($selected) {
            $index = 0
            if ([string]$selected.valueMatch -eq 'Index') {
                [void][int]::TryParse([string]$selected.value,[ref]$index)
            } else {
                $runtimeOption = @($control.options | Where-Object {
                    [string]$_.value -eq [string]$selected.value -or [string]$_.displayValue -eq [string]$selected.value -or
                    [string]$_.displayValue -eq [string]$selected.displayValue
                } | Select-Object -First 1)
                if ($runtimeOption.Count -gt 0) { $index = [int]$runtimeOption[0].index }
            }
            $option = [pscustomobject]@{
                id=[string]$selected.valueId;value=[string]$selected.value;displayValue=[string]$selected.displayValue
                labelSource='compiledScenario';index=$index;expectedOutcome=$selected.expectedOutcome
            }
        } else {
            $existing = @($control.options | Where-Object { [string]$_.value -eq 'click' } | Select-Object -First 1)
            $option = if ($existing.Count -gt 0) { $existing[0] } else {
                [pscustomobject]@{id=$action.ToLowerInvariant();value='click';displayValue=$logicalName;labelSource='compiledScenario';index=0;expectedOutcome=$null}
            }
        }
        $ready = $isGlobalAssertion -or (Test-RuleControlExecutionEligible $control)
        $rows.Add([pscustomobject]@{
            planItemId="$([string]$ScenarioCase.caseId)-$([string]$step.stepId)";control=$control;option=$option
            status=$(if($ready){'READY'}else{'PENDING'});errorCode=$(if($ready){''}else{'SCENARIO_CONTROL_NOT_BOUND'})
            scenarioStepId=[string]$step.stepId;scenarioSequence=[int]$step.sequence;scenarioAction=$action
            controlLogicalName=$logicalName
            mapScreenCode=$mapScreenCode;stateContext=$stateContext;transactional=[bool]$step.transactional
            expectedObservation=[string]$step.expectedObservation
            executionPhase=[string]$step.executionPhase;runtimeTabOrderEligible=[bool]$step.runtimeTabOrderEligible
            executionOrder=$executionOrder;coordinateFocus=($executionOrder -eq 'CoordinateFocus')
            triggerQueryAfterChange=$(if($selected){[bool]$selected.triggerQueryAfterChange}else{$false})
        })
    }

    if ($executionOrder -eq 'CoordinateFocus') {
        return @($rows.ToArray() | Sort-Object scenarioSequence)
    }

    $ordered = New-Object Collections.Generic.List[object]
    $arrange = New-Object Collections.Generic.List[object]
    foreach ($row in @($rows.ToArray() | Sort-Object scenarioSequence)) {
        if ([bool]$row.runtimeTabOrderEligible) {
            $arrange.Add($row)
            continue
        }
        foreach ($pending in @($arrange.ToArray() | Sort-Object {$_.control.tabOrder},scenarioSequence)) { $ordered.Add($pending) }
        $arrange.Clear()
        $ordered.Add($row)
    }
    foreach ($pending in @($arrange.ToArray() | Sort-Object {$_.control.tabOrder},scenarioSequence)) { $ordered.Add($pending) }
    $ordered.ToArray()
}

# 동적 재식별: 물리 바인딩은 고정된 MAP identity를 다시 확인하고, 일반 탐색만 제한적인 위치 fallback을 쓴다.
function Resolve-RuleLiveControl($Context, $NavigationContext, $Screen, $PlannedControl, $ExpectedBinding = $null, [string]$ExecutionOrder = 'RuntimeTabOrder') {
    $Context.LastLiveControlResolution = [pscustomobject]@{success=$false;errorCode='CONTROL_STALE';mode='Unresolved';candidateCount=0;evidence=@()}
    $strictBinding = $null -ne $ExpectedBinding -or [string]$PlannedControl.definitionSource -eq 'MAP+Runtime'
    if ($strictBinding) {
        $currentScreenNumber = Get-HtsNavigationScreenNumber -Context $NavigationContext -Window $Screen
        if (-not $currentScreenNumber) {
            $Context.LastLiveControlResolution = [pscustomobject]@{success=$false;errorCode='TARGET_SCREEN_NOT_ACTIVE';mode='StrictPhysical';candidateCount=0;evidence=@('현재 콘텐츠 화면 ID를 판독하지 못했습니다.')}
            return $null
        }
        $expectedControlId = if ($ExpectedBinding -and [string]$ExpectedBinding.controlId) { [string]$ExpectedBinding.controlId } else { [string]$PlannedControl.controlId }
        $expectedSignature = if ($ExpectedBinding -and [string]$ExpectedBinding.locatorSignature) { [string]$ExpectedBinding.locatorSignature } else { [string]$PlannedControl.locatorSignature }
        $expectedMapCode = if ($ExpectedBinding -and [string]$ExpectedBinding.mapScreenCode) { [string]$ExpectedBinding.mapScreenCode } else { [string]$PlannedControl.mapScreenCode }
        $expectedState = if ($ExpectedBinding -and [string]$ExpectedBinding.requiredStateContext) { [string]$ExpectedBinding.requiredStateContext } else { [string]$PlannedControl.stateContext }
        $expectedName = if ($ExpectedBinding -and [string]$ExpectedBinding.logicalName) { [string]$ExpectedBinding.logicalName } elseif ([string]$PlannedControl.name) { [string]$PlannedControl.name } else { [string]$PlannedControl.mapModelId }
        $discovered = @(Get-RuleDiscoveredControls $Context $Screen $currentScreenNumber @{})
        $candidates = @($discovered | Where-Object {
            $candidateName = if ([string]$_.name) { [string]$_.name } else { [string]$_.mapModelId }
            [string]$_.definitionSource -eq 'MAP+Runtime' -and [bool]$_.mapMatched -and
                [Int64]$_.hwnd -ne 0 -and
                [string]$_.controlId -eq $expectedControlId -and
                (-not $expectedSignature -or [string]$_.locatorSignature -eq $expectedSignature) -and
                (-not $expectedMapCode -or [string]$_.mapScreenCode -eq $expectedMapCode) -and
                (Test-RuleStateContextMatch $expectedState ([string]$_.stateContext)) -and
                (-not $expectedName -or $candidateName -eq $expectedName) -and
                (Test-RuleControlExecutionEligible $_)
        })
        if ($candidates.Count -ne 1) {
            $code = if ($candidates.Count -gt 1) { 'CONTROL_AMBIGUOUS' } else { 'CONTROL_STALE' }
            $idMatches = @($discovered | Where-Object { [string]$_.controlId -eq $expectedControlId }).Count
            $locatorMatches = @($discovered | Where-Object { [string]$_.locatorSignature -eq $expectedSignature }).Count
            $nameMatches = @($discovered | Where-Object { [string]$_.name -eq $expectedName }).Count
            $Context.LastLiveControlResolution = [pscustomobject]@{
                success=$false;errorCode=$code;mode='StrictPhysical';candidateCount=$candidates.Count
                evidence=@("controlId=$expectedControlId","locatorSignature=$expectedSignature","mapScreenCode=$expectedMapCode","stateContext=$expectedState","logicalName=$expectedName","discovered=$($discovered.Count)","idMatches=$idMatches","locatorMatches=$locatorMatches","nameMatches=$nameMatches")
            }
            return $null
        }
        $candidate = $candidates[0]
        $current = Invoke-HtsTargetRuleDependency $Context 'GetWindowInfo' @([Int64]$candidate.hwnd)
        if (-not $current.visible -or -not $current.enabled -or -not [TargetRuleNative]::IsChild([IntPtr][Int64]$Screen.hwnd,[IntPtr][Int64]$current.hwnd)) {
            $Context.LastLiveControlResolution = [pscustomobject]@{success=$false;errorCode='CONTROL_OUTSIDE_TARGET_SURFACE';mode='StrictPhysical';candidateCount=1;evidence=@("hwnd=$([Int64]$candidate.hwnd)")}
            return $null
        }
        $Context.LastLiveControlResolution = [pscustomobject]@{
            success=$true;errorCode='';mode='StrictPhysical';candidateCount=1
            evidence=@("controlId=$([string]$candidate.controlId)","locatorSignature=$([string]$candidate.locatorSignature)","runtimeControlKind=$([string]$candidate.runtimeControlKind)")
        }
        return $current
    }
    if ($PlannedControl.className -eq "ConfiguredVisualHotspot") {
        $relative = $PlannedControl.relativeRect
        return [pscustomobject]@{
            hwnd=0;visible=$true;enabled=$true;className="ConfiguredVisualHotspot";rawTitle=$PlannedControl.name;style=0
            rect=[pscustomobject]@{left=[int]$Screen.rect.left+[int]$relative.left;top=[int]$Screen.rect.top+[int]$relative.top;right=[int]$Screen.rect.left+[int]$relative.right;bottom=[int]$Screen.rect.top+[int]$relative.bottom;width=[int]$relative.width;height=[int]$relative.height}
        }
    }
    if ($PlannedControl.className -like "UIA:*") {
        $plannedRect=$PlannedControl.relativeRect
        $matches=@(Invoke-HtsTargetRuleDependency $Context 'GetFlaUiActionableControls' @($Screen) | Where-Object {
            $_.className-eq$PlannedControl.className -and
            [Math]::Abs([int](($_.rect.left+$_.rect.right)/2-$Screen.rect.left)-[int]$plannedRect.centerX)-le12 -and
            [Math]::Abs([int](($_.rect.top+$_.rect.bottom)/2-$Screen.rect.top)-[int]$plannedRect.centerY)-le12
        } | Sort-Object { [Math]::Abs([int](($_.rect.left+$_.rect.right)/2-$Screen.rect.left)-[int]$plannedRect.centerX)+[Math]::Abs([int](($_.rect.top+$_.rect.bottom)/2-$Screen.rect.top)-[int]$plannedRect.centerY) })
        if ($matches.Count -gt 0) {
            $Context.LastLiveControlResolution = [pscustomobject]@{success=$true;errorCode='';mode='UIANearby';candidateCount=$matches.Count;evidence=@('class and center within 12px')}
            return $matches[0]
        }
        return $null
    }
    if ($PlannedControl.hwnd -and [TargetRuleNative]::IsWindow([IntPtr][Int64]$PlannedControl.hwnd)) {
        $current = Invoke-HtsTargetRuleDependency $Context 'GetWindowInfo' @([Int64]$PlannedControl.hwnd)
        if ($current.visible -and $current.enabled -and [TargetRuleNative]::IsChild([IntPtr][Int64]$Screen.hwnd,[IntPtr][Int64]$current.hwnd)) {
            $Context.LastLiveControlResolution = [pscustomobject]@{success=$true;errorCode='';mode='ExistingHwnd';candidateCount=1;evidence=@("hwnd=$([Int64]$current.hwnd)")}
            return $current
        }
    }
    $signature = [string]$PlannedControl.locatorSignature
    # 화면 ID 길이를 가정하지 않고 targetProfile 정규식을 쓰는 공통 판독기로 현재 제목을 해석한다.
    $currentScreenNumber = Get-HtsNavigationScreenNumber -Context $NavigationContext -Window $Screen
    if (-not $currentScreenNumber) { return $null }
    $candidates = @(Get-RuleDiscoveredControls $Context $Screen $currentScreenNumber @{})
    $sameMapControl = @($candidates | Where-Object { [string]$_.controlId -eq [string]$PlannedControl.controlId -and [Int64]$_.hwnd -ne 0 } | Select-Object -First 1)
    if ($sameMapControl.Count -gt 0) {
        $Context.LastLiveControlResolution = [pscustomobject]@{success=$true;errorCode='';mode='ControlIdFallback';candidateCount=$sameMapControl.Count;evidence=@([string]$PlannedControl.controlId)}
        return Invoke-HtsTargetRuleDependency $Context 'GetWindowInfo' @([Int64]$sameMapControl[0].hwnd)
    }
    foreach ($candidate in $candidates) {
        if ([string]$candidate.locatorSignature -eq $signature) {
            $Context.LastLiveControlResolution = [pscustomobject]@{success=$true;errorCode='';mode='LocatorFallback';candidateCount=1;evidence=@($signature)}
            return Invoke-HtsTargetRuleDependency $Context 'GetWindowInfo' @([Int64]$candidate.hwnd)
        }
    }
    $plannedRect = $PlannedControl.relativeRect
    $nearby = @($candidates | Where-Object {
        $_.controlKind -eq $PlannedControl.controlKind -and $_.className -eq $PlannedControl.className -and
        [Math]::Abs([int]$_.relativeRect.centerX - [int]$plannedRect.centerX) -le 12 -and
        [Math]::Abs([int]$_.relativeRect.centerY - [int]$plannedRect.centerY) -le 12
    } | Sort-Object { [Math]::Abs([int]$_.relativeRect.centerX - [int]$plannedRect.centerX) + [Math]::Abs([int]$_.relativeRect.centerY - [int]$plannedRect.centerY) })
    if ($nearby.Count -gt 0) {
        $Context.LastLiveControlResolution = [pscustomobject]@{success=$true;errorCode='';mode='NearbyFallback';candidateCount=$nearby.Count;evidence=@('kind, class and center within 12px')}
        return Invoke-HtsTargetRuleDependency $Context 'GetWindowInfo' @([Int64]$nearby[0].hwnd)
    }
    $sameTabOrder = if ($ExecutionOrder -eq 'CoordinateFocus') { @() } else { @($candidates | Where-Object {
        $_.controlKind -eq $PlannedControl.controlKind -and
        $_.className -eq $PlannedControl.className -and
        [int]$_.tabOrder -eq [int]$PlannedControl.tabOrder -and
        ($_.controlKind -eq "Tab" -or [string]$_.stateContext -eq [string]$PlannedControl.stateContext)
    } | Sort-Object {
        [Math]::Abs([int]$_.relativeRect.centerX - [int]$plannedRect.centerX) +
        [Math]::Abs([int]$_.relativeRect.centerY - [int]$plannedRect.centerY)
    }) }
    if ($sameTabOrder.Count -gt 0) {
        if ([Int64]$sameTabOrder[0].hwnd -eq 0) { return $sameTabOrder[0] }
        $Context.LastLiveControlResolution = [pscustomobject]@{success=$true;errorCode='';mode='TabOrderFallback';candidateCount=$sameTabOrder.Count;evidence=@("tabOrder=$([int]$PlannedControl.tabOrder)")}
        return Invoke-HtsTargetRuleDependency $Context 'GetWindowInfo' @([Int64]$sameTabOrder[0].hwnd)
    }
    $rawNearby=@(Invoke-HtsTargetRuleDependency $Context 'GetChildWindows' @([Int64]$Screen.hwnd) | Where-Object {
        $_.visible-and$_.enabled-and$_.className-eq$PlannedControl.className -and
        [Math]::Abs([int](($_.rect.left+$_.rect.right)/2-$Screen.rect.left)-[int]$plannedRect.centerX)-le12 -and
        [Math]::Abs([int](($_.rect.top+$_.rect.bottom)/2-$Screen.rect.top)-[int]$plannedRect.centerY)-le12
    } | Sort-Object { [Math]::Abs([int](($_.rect.left+$_.rect.right)/2-$Screen.rect.left)-[int]$plannedRect.centerX)+[Math]::Abs([int](($_.rect.top+$_.rect.bottom)/2-$Screen.rect.top)-[int]$plannedRect.centerY) })
    if($rawNearby.Count-gt0){
        $Context.LastLiveControlResolution = [pscustomobject]@{success=$true;errorCode='';mode='RawNearbyFallback';candidateCount=$rawNearby.Count;evidence=@('class and center within 12px')}
        return $rawNearby[0]
    }
    $null
}

# 시나리오 Assert 단계: 현재 HWND/UIA 상태를 읽어 성공 여부와 관찰값을 반환한다.
function Invoke-RuleControlAssertion($Context, $NavigationContext, $Screen, $PlanItem) {
    $action = [string]$PlanItem.scenarioAction
    $control = $PlanItem.control
    $expectedBinding = if ($PlanItem.PSObject.Properties.Name -contains 'physicalBinding') { $PlanItem.physicalBinding } else { $null }
    $executionOrder = if ([string]$PlanItem.executionOrder) { [string]$PlanItem.executionOrder } else { 'RuntimeTabOrder' }
    $live = Resolve-RuleLiveControl $Context $NavigationContext $Screen $control $expectedBinding $executionOrder
    if (-not $live) {
        $resolutionCode = if ($Context.LastLiveControlResolution.errorCode) { [string]$Context.LastLiveControlResolution.errorCode } else { 'ASSERT_CONTROL_NOT_FOUND' }
        return [pscustomobject]@{success=$false;queryEligible=$false;errorCode=$resolutionCode;automationEngine='Win32/UIA state';output="검증 시점에 고정된 대상 컨트롤을 확인하지 못했습니다. mode=$([string]$Context.LastLiveControlResolution.mode), candidates=$([int]$Context.LastLiveControlResolution.candidateCount)";resolution=$Context.LastLiveControlResolution}
    }

    if ($action -eq 'AssertVisible') {
        return [pscustomobject]@{success=[bool]$live.visible;queryEligible=$false;errorCode=$(if($live.visible){''}else{'ASSERT_NOT_VISIBLE'});automationEngine='Win32/UIA state';output="visible=$([bool]$live.visible)"}
    }
    if ($action -eq 'AssertEnabled') {
        return [pscustomobject]@{success=[bool]$live.enabled;queryEligible=$false;errorCode=$(if($live.enabled){''}else{'ASSERT_NOT_ENABLED'});automationEngine='Win32/UIA state';output="enabled=$([bool]$live.enabled)"}
    }
    if ($action -eq 'AssertGrid') {
        if ([Int64]$live.hwnd -eq 0) {
            return [pscustomobject]@{success=$true;queryEligible=$false;errorCode='';automationEngine='UIA state';output='UIA 그리드 컨트롤이 현재 화면에서 접근 가능합니다.'}
        }
        $rowCount = if ([string]$live.className -eq 'SysListView32') {
            [int][TargetRuleNative]::SendMessage([IntPtr][Int64]$live.hwnd,0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
        } else { -1 }
        return [pscustomobject]@{success=$true;queryEligible=$false;errorCode='';automationEngine='Win32 state';output=$(if($rowCount-ge0){"gridRowCount=$rowCount"}else{"gridClass=$([string]$live.className), accessible=true"})}
    }
    if ($action -eq 'AssertSelected') {
        if ([Int64]$live.hwnd -eq 0) {
            return [pscustomobject]@{success=$false;queryEligible=$false;errorCode='ASSERT_SELECTED_UNVERIFIABLE';automationEngine='UIA state';output='선택 상태를 읽을 수 있는 네이티브 HWND가 없습니다.'}
        }
        $hwnd = [IntPtr][Int64]$live.hwnd
        $expectedIndex = if ($PlanItem.option) { [int]$PlanItem.option.index } else { 0 }
        $kind = [string]$control.controlKind
        $logicalName = if ([string]$PlanItem.controlLogicalName) { [string]$PlanItem.controlLogicalName } else { [string]$control.name }
        $orderTabProfile = if ($kind -eq 'Tab') { Get-RuleOrderTabProfile $Context (Get-HtsNavigationScreenNumber -Context $NavigationContext -Window $Screen) ([string]$PlanItem.mapScreenCode) $logicalName } else { $null }
        if ($orderTabProfile -and ([string]$live.className).StartsWith('AfxWnd',[StringComparison]::OrdinalIgnoreCase)) {
            $orderTabItem = Get-RuleOrderTabItem $orderTabProfile $PlanItem.option
            if (-not $orderTabItem) {
                return [pscustomobject]@{success=$false;queryEligible=$false;errorCode='ORDER_TAB_PROFILE_VALUE_MISSING';automationEngine='MAP+Runtime state';output="주문 탭 프로필에 값 '$([string]$PlanItem.option.value)'이 없습니다."}
            }
            $refreshedControls = @(Get-RuleDiscoveredControls $Context $Screen (Get-HtsNavigationScreenNumber -Context $NavigationContext -Window $Screen))
            $verifiedControls = @($orderTabItem.verificationControls | Where-Object {
                $verificationName = [string]$_
                @($refreshedControls | Where-Object {
                    [string]$_.mapScreenCode -eq [string]$PlanItem.mapScreenCode -and
                    [string]$_.name -eq $verificationName -and
                    (Test-RuleControlExecutionEligible $_)
                }).Count -gt 0
            })
            $success = $verifiedControls.Count -gt 0
            return [pscustomobject]@{
                success=$success;queryEligible=$false;errorCode=$(if($success){''}else{'ASSERT_ORDER_TAB_STATE_MISMATCH'})
                automationEngine='MAP+Runtime state'
                output="orderTab=$([string]$orderTabItem.displayValue), verifiedControls=$($verifiedControls -join ','), expectedControls=$(@($orderTabItem.verificationControls) -join ',')"
            }
        }
        $actual = -1
        $success = $false
        switch ($kind) {
            'CheckBox' {
                if ([string]$live.className -like 'AfxWnd*') {
                    return [pscustomobject]@{success=$false;queryEligible=$false;errorCode='ASSERT_SELECTED_UNVERIFIABLE';automationEngine='Win32 state';output="owner-drawn 체크 상태를 네이티브 체크 API로 검증할 수 없습니다. class=$([string]$live.className)";resolution=$Context.LastLiveControlResolution}
                }
                $actual=[int][TargetRuleNative]::SendMessage($hwnd,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                $wanted=if([string]$PlanItem.option.value -eq 'true'){1}else{0}
                $success=($actual-eq$wanted)
            }
            'RadioButton' {
                $actual=[int][TargetRuleNative]::SendMessage($hwnd,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                $success=($actual-ne0)
            }
            'ComboBox' {
                $actual=[int][TargetRuleNative]::SendMessage($hwnd,0x0147,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                $success=($actual-eq$expectedIndex)
            }
            'ListBox' {
                $actual=[int][TargetRuleNative]::SendMessage($hwnd,0x0188,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                $success=($actual-eq$expectedIndex)
            }
            'Tab' {
                $actual=[int][TargetRuleNative]::SendMessage($hwnd,0x130B,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                $success=($actual-eq$expectedIndex)
            }
            default {
                return [pscustomobject]@{success=$false;queryEligible=$false;errorCode='ASSERT_SELECTED_UNSUPPORTED';automationEngine='Win32 state';output="선택 검증을 지원하지 않는 컨트롤 종류입니다: $kind"}
            }
        }
        return [pscustomobject]@{success=$success;queryEligible=$false;errorCode=$(if($success){''}else{'ASSERT_SELECTED_MISMATCH'});automationEngine='Win32 state';output="selected=$actual expected=$expectedIndex"}
    }
    [pscustomobject]@{success=$false;queryEligible=$false;errorCode='ASSERT_ACTION_UNSUPPORTED';automationEngine='Win32/UIA state';output="지원하지 않는 Assert 단계입니다: $action"}
}
