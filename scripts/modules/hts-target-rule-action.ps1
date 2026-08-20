<#
.SYNOPSIS 결합 완료된 HTS 컨트롤에 승인된 UI 동작을 적용한다.
.DESCRIPTION 콤보·목록 선택, 좌표 포커스, 계획 항목과 데이터셋 변수 동작을 실행한다.
.INPUTS 승인된 계획, 결합된 컨트롤, 명시적 실행 컨텍스트.
.OUTPUTS 원시 동작 및 관찰 결과 객체.
.NOTES 결과 판정과 리포트 생성은 수행하지 않는다.
#>
# 콤보를 펼친 뒤 계획된 행 위치를 클릭하고 선택 상태를 확인한다.
function Invoke-RuleComboOptionClick($Window, $Option) {
    if ([Int64]$Window.hwnd -eq 0) { return [pscustomobject]@{success=$false;errorCode="COMBO_NATIVE_LIST_REQUIRED";output="좌표 핫스팟은 콤보 목록 행의 위치를 검증할 수 없습니다."} }
    $combo = Get-RuleNativeComboWindow $Window
    $comboHwnd = [IntPtr][Int64]$combo.hwnd
    $clickPoint = [pscustomobject]@{rect=[pscustomobject]@{left=[Math]::Max($combo.rect.left,$combo.rect.right-24);right=$combo.rect.right;top=$combo.rect.top;bottom=$combo.rect.bottom}}
    Click-Center $clickPoint
    Start-Sleep -Milliseconds 150
    $info = New-Object TargetRuleNative+COMBOBOXINFO
    $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][TargetRuleNative+COMBOBOXINFO])
    if (-not [TargetRuleNative]::GetComboBoxInfo($comboHwnd,[ref]$info) -or $info.hwndList -eq [IntPtr]::Zero) {
        [void][TargetRuleNative]::SendMessage($comboHwnd,$script:CB_SHOWDROPDOWN,[IntPtr]1,[IntPtr]::Zero)
        Start-Sleep -Milliseconds 120
        $info = New-Object TargetRuleNative+COMBOBOXINFO
        $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][TargetRuleNative+COMBOBOXINFO])
        if (-not [TargetRuleNative]::GetComboBoxInfo($comboHwnd,[ref]$info) -or $info.hwndList -eq [IntPtr]::Zero) {
            return [pscustomobject]@{success=$false;errorCode="COMBO_LIST_NOT_VISIBLE";output="콤보를 펼쳤지만 목록 창을 찾지 못했습니다."}
        }
    }
    $list = Get-WindowInfo $info.hwndList
    $itemHeight = [int][TargetRuleNative]::SendMessage($comboHwnd,$script:CB_GETITEMHEIGHT,[IntPtr]0,[IntPtr]::Zero).ToInt64()
    if ($itemHeight -le 0 -or $itemHeight -gt 200) { $itemHeight=18 }
    $visibleRows = [Math]::Max(1,[int][Math]::Floor($list.rect.height/$itemHeight))
    $topIndex = [Math]::Max(0,[int]$Option.index-[int][Math]::Floor($visibleRows/2))
    [void][TargetRuleNative]::SendMessage($info.hwndList,$script:LB_SETTOPINDEX,[IntPtr]$topIndex,[IntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    $topIndex = [int][TargetRuleNative]::SendMessage($info.hwndList,$script:LB_GETTOPINDEX,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
    $row = [int]$Option.index-$topIndex
    $target = [pscustomobject]@{rect=[pscustomobject]@{left=$list.rect.left+3;right=$list.rect.right-3;top=$list.rect.top+($row*$itemHeight);bottom=[Math]::Min($list.rect.bottom,$list.rect.top+(($row+1)*$itemHeight))}}
    Click-Center $target
    Start-Sleep -Milliseconds 180
    $selected = [TargetRuleNative]::SendMessage($comboHwnd,$script:CB_GETCURSEL,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
    [pscustomobject]@{success=($selected -eq [int]$Option.index);errorCode=$(if ($selected -eq [int]$Option.index) {""} else {"COMBO_SELECTION_NOT_APPLIED"});output="드롭다운의 $([int]$Option.index+1)번째 항목을 실제 클릭했습니다."}
}

# 목록의 계획된 행을 콘텐츠 경계 안에서 클릭한다.
function Invoke-RuleListOptionClick($Window, $Option) {
    $itemHeight = [int][TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd,$script:LB_GETITEMHEIGHT,[IntPtr]0,[IntPtr]::Zero).ToInt64()
    if ($itemHeight -le 0 -or $itemHeight -gt 200) { $itemHeight=18 }
    $visibleRows = [Math]::Max(1,[int][Math]::Floor($Window.rect.height/$itemHeight))
    $topIndex = [Math]::Max(0,[int]$Option.index-[int][Math]::Floor($visibleRows/2))
    [void][TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd,$script:LB_SETTOPINDEX,[IntPtr]$topIndex,[IntPtr]::Zero)
    $topIndex = [int][TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd,$script:LB_GETTOPINDEX,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
    $row = [int]$Option.index-$topIndex
    $target = [pscustomobject]@{rect=[pscustomobject]@{left=$Window.rect.left+3;right=$Window.rect.right-3;top=$Window.rect.top+($row*$itemHeight);bottom=[Math]::Min($Window.rect.bottom,$Window.rect.top+(($row+1)*$itemHeight))}}
    Click-Center $target
    $selected = [TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd,$script:LB_GETCURSEL,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
    $selected -eq [int]$Option.index
}


# 좌표 우선 입력은 클릭 지점의 HTS 소유권 검증 뒤 포커스가 요청 화면 안에 남았는지 다시 확인한다.
function Set-RuleCoordinateFocus($NavigationContext, $Screen, $Live) {
    $screenNumber = Get-HtsNavigationScreenNumber -Context $NavigationContext -Window $Screen
    Click-Center $Live
    Start-Sleep -Milliseconds 100
    if (-not $screenNumber -or (Get-HtsNavigationScreenNumber -Context $NavigationContext -Window $Screen) -ne $screenNumber) {
        return [pscustomobject]@{success=$false;errorCode='COORDINATE_FOCUS_SCREEN_CHANGED';output='좌표 클릭 직후 요청 화면이 바뀌어 후속 키 입력을 차단했습니다.'}
    }
    $threadInfo = New-Object TargetRuleNative+GUITHREADINFO
    $threadInfo.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][TargetRuleNative+GUITHREADINFO])
    [void][TargetRuleNative]::GetGUIThreadInfo(0,[ref]$threadInfo)
    $focusedHwnd = [Int64]$threadInfo.hwndFocus.ToInt64()
    $insideScreen = $focusedHwnd -ne 0 -and
        ($focusedHwnd -eq [Int64]$Screen.hwnd -or [TargetRuleNative]::IsChild([IntPtr][Int64]$Screen.hwnd,[IntPtr]$focusedHwnd))
    if (-not $insideScreen) {
        return [pscustomobject]@{success=$false;errorCode='COORDINATE_FOCUS_NOT_CONFIRMED';output="좌표 클릭 뒤 키보드 포커스가 요청 화면 내부에 있음을 확인하지 못했습니다. focusedHwnd=$focusedHwnd"}
    }
    $targetHwnd = [Int64]$Live.hwnd
    $targetFocused = $targetHwnd -eq 0 -or $focusedHwnd -eq $targetHwnd -or
        [TargetRuleNative]::IsChild([IntPtr]$targetHwnd,[IntPtr]$focusedHwnd) -or
        [TargetRuleNative]::IsChild([IntPtr]$focusedHwnd,[IntPtr]$targetHwnd)
    [pscustomobject]@{
        success=$true;errorCode='';focusedHwnd=$focusedHwnd;targetFocused=[bool]$targetFocused
        output="coordinateFocus=verified, focusedHwnd=$focusedHwnd, targetFocused=$([bool]$targetFocused)"
    }
}

# 컨트롤 실행: 종류별 입력/선택/토글/클릭을 수행하고 적용 여부와 복원 정보를 반환한다.
function Invoke-RuleControlPlanItem($NavigationContext, $Screen, $PlanItem) {
    if ($PlanItem.status -ne "READY") { return [pscustomobject]@{success=$false;queryEligible=$false;errorCode=[string]$PlanItem.errorCode;output=[string]$PlanItem.control.pendingReason} }
    $control = $PlanItem.control
    $option = $PlanItem.option
    # 대상 프로필과 일치하는 현재 화면만 조작해 다른 화면이나 HTS 외부로 입력이 새는 것을 막는다.
    $screenNumber = Get-HtsNavigationScreenNumber -Context $NavigationContext -Window $Screen
    if(-not $screenNumber -or -not (Focus-HtsNavigationRequestedScreen -Context $NavigationContext -Main $NavigationContext.SessionContext.MainWindow -Screen $Screen -ScreenNumber $screenNumber)){
        return [pscustomobject]@{success=$false;queryEligible=$false;errorCode="TARGET_SCREEN_NOT_ACTIVE";output="실행 직전에 대상 콘텐츠 화면을 활성화하지 못해 입력을 차단했습니다."}
    }
    $expectedBinding = if ($PlanItem.PSObject.Properties.Name -contains 'physicalBinding') { $PlanItem.physicalBinding } else { $null }
    $executionOrder = if ([string]$PlanItem.executionOrder) { [string]$PlanItem.executionOrder } else { 'RuntimeTabOrder' }
    $coordinateFocus = $executionOrder -eq 'CoordinateFocus'
    $live = Resolve-RuleLiveControl $NavigationContext $Screen $control $expectedBinding $executionOrder
    if (-not $live) {
        $resolutionCode = if ($script:lastLiveControlResolution.errorCode) { [string]$script:lastLiveControlResolution.errorCode } else { 'CONTROL_STALE' }
        return [pscustomobject]@{success=$false;queryEligible=$false;errorCode=$resolutionCode;output="실행 직전에 고정된 컨트롤을 다시 확인하지 못했습니다. mode=$([string]$script:lastLiveControlResolution.mode), candidates=$([int]$script:lastLiveControlResolution.candidateCount)";resolution=$script:lastLiveControlResolution}
    }
    if([Int64]$live.hwnd -ne 0 -and -not [TargetRuleNative]::IsChild([IntPtr][Int64]$Screen.hwnd,[IntPtr][Int64]$live.hwnd)){
        return [pscustomobject]@{success=$false;queryEligible=$false;errorCode="CONTROL_OUTSIDE_TARGET_SURFACE";output="컨트롤이 요청 화면의 자손이 아니어서 입력을 차단했습니다."}
    }
    $hwnd = [IntPtr][Int64]$live.hwnd
    $success = $true
    $queryEligible = $false
    $verificationNote = ""
    $actionEngine = "Win32 fallback"
    $coordinateFocusUsed = $false
    $coordinateFocusVerified = $false
    try {
    if ($coordinateFocus -and [string]$control.controlKind -in @('Text','Date')) {
        $focusResult = Set-RuleCoordinateFocus $NavigationContext $Screen $live
        if (-not [bool]$focusResult.success) {
            return [pscustomobject]@{
                success=$false;queryEligible=$false;errorCode=[string]$focusResult.errorCode
                automationEngine='CoordinateFocus';interactionStrategy=$executionOrder
                coordinateFocusUsed=$true;coordinateFocusVerified=$false;output=[string]$focusResult.output
            }
        }
        $coordinateFocusUsed = $true
        $coordinateFocusVerified = $true
        $verificationNote = " $([string]$focusResult.output)."
    }
    switch ([string]$control.controlKind) {
        "Text" { $success = Set-AutomationText $live ([string]$option.value) -AlreadyFocused:$coordinateFocus; $actionEngine=$(if($coordinateFocus){"CoordinateFocus + $script:lastTextAutomationEngine"}else{$script:lastTextAutomationEngine}); $queryEligible=$true }
        "Date" {
            $rawDateValue = [string]$option.value
            $dateValue = if ($rawDateValue.Length -eq 0) { '' } else { ConvertTo-RuleDateValue $rawDateValue }
            $success = ($null -ne $dateValue) -and (Set-AutomationText $live $dateValue -AlreadyFocused:$coordinateFocus)
            $actionEngine=$(if($coordinateFocus){"CoordinateFocus + $script:lastTextAutomationEngine"}else{$script:lastTextAutomationEngine})
            $queryEligible=$true
            if ($null -eq $dateValue) { $verificationNote=" 날짜값이 yyyyMMdd 형식이 아닙니다." }
        }
        "ComboBox" {
            # MAP 콤보가 런타임에서 일반 Button/Pane으로만 보이면 네이티브 목록 API를 호출하지 않고 오결합으로 보류한다.
            $runtimeKind = if ($control.PSObject.Properties.Name -contains 'runtimeControlKind') { [string]$control.runtimeControlKind } else { '' }
            $supportsSelectIndex = @($control.supportedActions) -contains 'selectIndex'
            if ($runtimeKind -and $runtimeKind -ne 'ComboBox' -and -not $supportsSelectIndex) {
                return [pscustomobject]@{
                    success=$false;queryEligible=$false;errorCode='COMBO_RUNTIME_KIND_MISMATCH';automationEngine='FlaUI.UIA3'
                    output="MAP ComboBox가 런타임 $runtimeKind 컨트롤로 관찰되어 잘못된 목록 클릭을 차단했습니다."
                }
            }
            if ($coordinateFocus) {
                $comboResult = Invoke-RuleComboOptionClick $live $option
                $success=[bool]$comboResult.success
                $verificationNote=" $($comboResult.output)"
                $queryEligible=$true
                $coordinateFocusUsed=$true
                $coordinateFocusVerified=$success
                $actionEngine='CoordinateFocus + Win32 combo'
                break
            }
            $flaUiResult = Invoke-FlaUiControlAction $live 'selectIndex' -Index ([int]$option.index)
            if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) {
                $success=$true;$queryEligible=$true;$actionEngine='FlaUI.UIA3';$verificationNote=" $($flaUiResult.pattern)으로 선택 결과를 확인했습니다."
                break
            }
            $comboResult = Invoke-RuleComboOptionClick $live $option
            $success=[bool]$comboResult.success
            $verificationNote=" $($comboResult.output)"
            $queryEligible=$true
        }
        "CheckBox" {
            if (-not $coordinateFocus -and [string]$option.value -in @('true','false')) {
                $wantedChecked = [string]$option.value -eq 'true'
                $flaUiResult = Invoke-FlaUiControlAction $live 'setChecked' -Checked $wantedChecked
                if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) {
                    $success=$true;$queryEligible=$true;$actionEngine='FlaUI.UIA3';$verificationNote=" $($flaUiResult.pattern)으로 체크 상태를 확인했습니다."
                    break
                }
            }
            if ([Int64]$live.hwnd -eq 0 -or $control.className -like 'AfxWnd*') {
                return [pscustomobject]@{
                    success=$false;queryEligible=$false;errorCode='CHECK_STATE_UNVERIFIABLE';automationEngine='Win32/UIA state'
                    output="체크 상태를 읽어 검증할 수 없는 런타임 컨트롤이므로 조작하지 않았습니다. class=$([string]$control.className)"
                    resolution=$script:lastLiveControlResolution
                }
            } elseif ([string]$option.value -eq 'toggle') {
                $before = [int][TargetRuleNative]::SendMessage($hwnd,$script:BM_GETCHECK,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                Click-Center $live
                if ($coordinateFocus) { $coordinateFocusUsed=$true; $coordinateFocusVerified=$true; $actionEngine='CoordinateFocus' }
                Start-Sleep -Milliseconds 180
                $after = [int][TargetRuleNative]::SendMessage($hwnd,$script:BM_GETCHECK,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                $success = ($after -ne $before)
            } else {
                $wanted = if ([string]$option.value -eq "true") {$script:BST_CHECKED} else {$script:BST_UNCHECKED}
                $current = [int][TargetRuleNative]::SendMessage($hwnd,$script:BM_GETCHECK,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                if ($current -ne $wanted) {
                    Click-Center $live
                    if ($coordinateFocus) { $coordinateFocusUsed=$true; $coordinateFocusVerified=$true; $actionEngine='CoordinateFocus' }
                }
                $after = [int][TargetRuleNative]::SendMessage($hwnd,$script:BM_GETCHECK,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                $success = ($after -eq $wanted)
            }
            $queryEligible=$true
        }
        "RadioButton" {
            if (-not $coordinateFocus) {
                $flaUiResult = Invoke-FlaUiControlAction $live 'select'
                if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) {
                    $success=$true;$queryEligible=$true;$actionEngine='FlaUI.UIA3';$verificationNote=" $($flaUiResult.pattern)으로 선택 상태를 확인했습니다."
                    break
                }
            }
            Click-Center $live
            if ($coordinateFocus) { $coordinateFocusUsed=$true; $coordinateFocusVerified=$true; $actionEngine='CoordinateFocus' }
            $success=$(if([Int64]$live.hwnd-eq0){$true}else{[int][TargetRuleNative]::SendMessage($hwnd,$script:BM_GETCHECK,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64() -ne $script:BST_UNCHECKED})
            $queryEligible=$true
        }
        "RadioGroup" {
            $count=[Math]::Max(1,@($control.options).Count)
            $segmentWidth=[double]$live.rect.width/$count
            $x=[int]($live.rect.left+($segmentWidth*([int]$option.index+0.5)))
            $y=[int](($live.rect.top+$live.rect.bottom)/2)
            Click-Center ([pscustomobject]@{rect=[pscustomobject]@{left=$x-2;right=$x+2;top=$y-2;bottom=$y+2}})
            if ($coordinateFocus) { $coordinateFocusUsed=$true; $coordinateFocusVerified=$true; $actionEngine='CoordinateFocus' }
            Start-Sleep -Milliseconds 180
            $success=$true
            $queryEligible=$true
        }
        "Tab" {
            if ([string]$option.value -eq [string]$control.initialValue) {
                $success=$true
                $verificationNote=" 현재 선택된 탭이므로 재클릭 없이 활성 상태를 확인했습니다."
                break
            }
            $logicalName = if ([string]$PlanItem.controlLogicalName) { [string]$PlanItem.controlLogicalName } else { [string]$control.name }
            $orderTabProfile = Get-RuleOrderTabProfile $screenNumber ([string]$PlanItem.mapScreenCode) $logicalName
            $orderTabItem = Get-RuleOrderTabItem $orderTabProfile $option
            if ($orderTabItem -and ([string]$live.className).StartsWith('AfxWnd',[StringComparison]::OrdinalIgnoreCase)) {
                $x = [int]$live.rect.left + [int]$orderTabItem.x
                $y = [int]$live.rect.top + [int]$orderTabProfile.y
                Click-Center ([pscustomobject]@{rect=[pscustomobject]@{left=$x-2;right=$x+2;top=$y-2;bottom=$y+2}})
                Set-RuleOrderTabState $screenNumber ([string]$PlanItem.mapScreenCode) ([string]$option.value)
                $coordinateFocusUsed=$true
                $coordinateFocusVerified=$true
                $actionEngine='CoordinateFocus + profiled owner-drawn tab'
                Start-Sleep -Milliseconds 500
                $success=$true
                $verificationNote=" 0101 주문 탭 프로필 좌표 ($([int]$orderTabItem.x),$([int]$orderTabProfile.y))를 사용했습니다."
                break
            }
            if (-not $coordinateFocus) {
                $flaUiResult = Invoke-FlaUiControlAction $live 'selectTabIndex' -Index ([int]$option.index)
                if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) {
                    $success=$true;$actionEngine='FlaUI.UIA3';$verificationNote=" $($flaUiResult.pattern)으로 탭 인덱스를 확인했습니다."
                    break
                }
            }
            $count = if ([Int64]$live.hwnd -eq 0) { [Math]::Max(1,@($control.options).Count) } else { [Math]::Max(1,[int][TargetRuleNative]::SendMessage($hwnd,$script:TCM_GETITEMCOUNT,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()) }
            $x = [int]($live.rect.left + ($live.rect.width * ([int]$option.index + 0.5) / $count))
            $y = [int](($live.rect.top + $live.rect.bottom) / 2)
            Click-Center ([pscustomobject]@{rect=[pscustomobject]@{left=$x-2;right=$x+2;top=$y-2;bottom=$y+2}})
            if ($coordinateFocus) { $coordinateFocusUsed=$true; $coordinateFocusVerified=$true; $actionEngine='CoordinateFocus' }
            Start-Sleep -Milliseconds 250
            if ([Int64]$live.hwnd -eq 0) { $success=$true } else {
                $selected = [TargetRuleNative]::SendMessage($hwnd,$script:TCM_GETCURSEL,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                if ($selected -ne [int]$option.index) { $verificationNote = " HTS owner-drawn 탭이 선택 인덱스 API를 갱신하지 않아 클릭 전송만 확인했습니다." }
                $success = $true
            }
        }
        "Button" {
            if (-not $coordinateFocus) {
                $flaUiResult = Invoke-FlaUiControlAction $live 'invoke'
                if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) {
                    $success=$true;$actionEngine='FlaUI.UIA3';$verificationNote=" $($flaUiResult.pattern)으로 실행했습니다."
                    Start-Sleep -Milliseconds 600
                    break
                }
            }
            $isDoubleClick = [string]$PlanItem.scenarioAction -eq 'DoubleClick'
            Click-Center $live -DoubleClick:$isDoubleClick
            if ($coordinateFocus) { $coordinateFocusUsed=$true; $coordinateFocusVerified=$true; $actionEngine='CoordinateFocus' }
            Start-Sleep -Milliseconds 600
            $success=$true
        }
        "ListBox" {
            if (-not $coordinateFocus) {
                $flaUiResult = Invoke-FlaUiControlAction $live 'selectIndex' -Index ([int]$option.index)
                if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) {
                    $success=$true;$queryEligible=$true;$actionEngine='FlaUI.UIA3';$verificationNote=" $($flaUiResult.pattern)으로 목록 선택을 확인했습니다."
                    break
                }
            }
            $success=Invoke-RuleListOptionClick $live $option;$queryEligible=$true
            if ($coordinateFocus) { $coordinateFocusUsed=$true; $coordinateFocusVerified=[bool]$success; $actionEngine='CoordinateFocus + Win32 list' }
        }
        "Slider" {
            $flaUiAction = if ([string]$option.value -in @('increment','decrement')) { [string]$option.value } else { 'setRangeValue' }
            if (-not $coordinateFocus) {
                $flaUiResult = Invoke-FlaUiControlAction $live $flaUiAction -Value ([string]$option.value)
                if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) {
                    $success=$true;$queryEligible=$true;$actionEngine='FlaUI.UIA3';$verificationNote=" $($flaUiResult.pattern)으로 범위값을 확인했습니다."
                    break
                }
            }
            $minimum=[int][TargetRuleNative]::SendMessage($hwnd,$script:TBM_GETRANGEMIN,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
            $maximum=[int][TargetRuleNative]::SendMessage($hwnd,$script:TBM_GETRANGEMAX,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
            $wanted=[int]$option.value
            if ($maximum -gt $minimum) {
                $ratio=($wanted-$minimum)/[double]($maximum-$minimum)
                $target=[pscustomobject]@{rect=[pscustomobject]@{left=[int]($live.rect.left+6+(($live.rect.width-12)*$ratio))-2;right=[int]($live.rect.left+6+(($live.rect.width-12)*$ratio))+2;top=$live.rect.top;bottom=$live.rect.bottom}}
                Click-Center $target
                if ($coordinateFocus) { $coordinateFocusUsed=$true; $coordinateFocusVerified=$true; $actionEngine='CoordinateFocus' }
                $actual=[int][TargetRuleNative]::SendMessage($hwnd,$script:TBM_GETPOS,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                $success=[Math]::Abs($actual-$wanted) -le [Math]::Max(1,[int](($maximum-$minimum)/50))
                $queryEligible=$true
            } else { $success=$false }
        }
        "Spin" {
            $flaUiAction = if ([string]$option.value -eq 'decrement') { 'decrement' } else { 'increment' }
            if (-not $coordinateFocus) {
                $flaUiResult = Invoke-FlaUiControlAction $live $flaUiAction
                if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) {
                    $success=$true;$queryEligible=$true;$actionEngine='FlaUI.UIA3';$verificationNote=" $($flaUiResult.pattern)으로 증감 동작을 확인했습니다."
                    break
                }
            }
            $mid=[int](($live.rect.top+$live.rect.bottom)/2)
            $target=[pscustomobject]@{rect=[pscustomobject]@{left=$live.rect.left;right=$live.rect.right;top=$(if($option.value -eq "increment"){$live.rect.top}else{$mid});bottom=$(if($option.value -eq "increment"){$mid}else{$live.rect.bottom})}}
            Click-Center $target; $success=$true; $queryEligible=$true
            if ($coordinateFocus) { $coordinateFocusUsed=$true; $coordinateFocusVerified=$true; $actionEngine='CoordinateFocus' }
        }
        default { $success=$false }
    }
    } catch {
        return [pscustomobject]@{
            success=$false;queryEligible=$false;errorCode="INPUT_GUARD_BLOCKED"
            automationEngine=$(if($coordinateFocus){'CoordinateFocus'}else{'Win32/UIA'})
            interactionStrategy=$executionOrder;coordinateFocusUsed=[bool]$coordinateFocusUsed;coordinateFocusVerified=$false
            output="전경 또는 대상 표면 안전 검증을 통과하지 못해 이 조작만 차단했습니다: $($_.Exception.Message)"
        }
    }
    Start-Sleep -Milliseconds 450
    [pscustomobject]@{
        success=$success; queryEligible=$queryEligible
        errorCode=$(if ($success) {""} elseif ($control.controlKind -eq "ComboBox" -and $comboResult) {[string]$comboResult.errorCode} else {"CONTROL_ACTION_FAILED"})
        automationEngine=$actionEngine
        interactionStrategy=$executionOrder
        coordinateFocusUsed=[bool]$coordinateFocusUsed
        coordinateFocusVerified=[bool]$coordinateFocusVerified
        resolution=$script:lastLiveControlResolution
        output=$(if ($success) {"[$actionEngine] $($control.controlKind) '$($control.name)'에 '$($option.displayValue)' 동작을 적용했습니다.$verificationNote"} else {"컨트롤 동작 결과를 확인하지 못했습니다."})
    }
}

# 명시 변수 실행: 데이터셋의 Value/DisplayText/Index/Checked 계약을 실제 컨트롤 조작으로 변환한다.
function Invoke-RuleDatasetVariable($Window, [string]$ControlKind, [string]$Value, [string]$ValueMatch, [int]$MaxOptions = 40) {
    $kind = $ControlKind
    if (-not $kind -or $kind -eq "Auto") {
        $kind = switch -Wildcard ([string]$Window.className) {
            "ComboBox" { "ComboBox"; break }
            "ComboBoxEx32" { "ComboBox"; break }
            "SysTabControl32" { "Tab"; break }
            "Edit" { "Text"; break }
            "ListBox" { "ListBox"; break }
            "*Button*" { Get-RuleButtonKind $Window; break }
            default { "Text" }
        }
    }
    $hwnd = [IntPtr][Int64]$Window.hwnd
    $isHotspot = ([Int64]$Window.hwnd -eq 0 -and $Window.className -eq "ConfiguredVisualHotspot")
    switch ($kind) {
        "Text" { return [bool](Set-AutomationText $Window $Value) }
        "Date" {
            $dateValue=ConvertTo-RuleDateValue $Value
            return ($null -ne $dateValue) -and [bool](Set-AutomationText $Window $dateValue)
        }
        "ComboBox" {
            if ($isHotspot) {
                return $false
            }
            $options = @(Get-RuleComboOptions $Window $MaxOptions)
            $selected = $null
            if ($ValueMatch -eq "Index") {
                $selected = @($options | Where-Object { $_.index -eq [int]$Value } | Select-Object -First 1)
            } else {
                $selected = @($options | Where-Object { $_.value -eq $Value -or $_.displayValue -eq $Value } | Select-Object -First 1)
            }
            if ($selected.Count -eq 0) { return $false }
            $flaUiResult = if ($ValueMatch -eq 'Index') {
                Invoke-FlaUiControlAction $Window 'selectIndex' -Index ([int]$selected[0].index)
            } else {
                Invoke-FlaUiControlAction $Window 'selectText' -Value ([string]$selected[0].displayValue)
            }
            if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) { return $true }
            $comboResult=Invoke-RuleComboOptionClick $Window $selected[0]
            return [bool]$comboResult.success
        }
        "CheckBox" {
            if ($isHotspot) { Click-Center $Window; return $true }
            $wantedChecked = $Value.Trim().ToLowerInvariant() -in @("true","1","y","yes","checked")
            $flaUiResult = Invoke-FlaUiControlAction $Window 'setChecked' -Checked $wantedChecked
            if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) { return $true }
            $wanted = if ($Value.Trim().ToLowerInvariant() -in @("true","1","y","yes","checked")) {$script:BST_CHECKED} else {$script:BST_UNCHECKED}
            $current = [int][TargetRuleNative]::SendMessage($hwnd,$script:BM_GETCHECK,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
            if ($current -ne $wanted) { Click-Center $Window }
            return ([int][TargetRuleNative]::SendMessage($hwnd,$script:BM_GETCHECK,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64() -eq $wanted)
        }
        "RadioButton" {
            if (-not $isHotspot) {
                $flaUiResult = Invoke-FlaUiControlAction $Window 'select'
                if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) { return $true }
            }
            Click-Center $Window
            return $isHotspot -or ([int][TargetRuleNative]::SendMessage($hwnd,$script:BM_GETCHECK,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64() -ne $script:BST_UNCHECKED)
        }
        "Tab" {
            $index = 0
            if (-not [int]::TryParse($Value,[ref]$index)) { return $false }
            if (-not $isHotspot) {
                $flaUiResult = Invoke-FlaUiControlAction $Window 'selectTabIndex' -Index $index
                if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) { return $true }
            }
            $count = if ($isHotspot) { [Math]::Max(1,$index+1) } else { [Math]::Max(1,[int][TargetRuleNative]::SendMessage($hwnd,$script:TCM_GETITEMCOUNT,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()) }
            if ($index -ge $count) { return $false }
            $x = [int]($Window.rect.left + ($Window.rect.width * ($index + 0.5) / $count))
            $y = [int](($Window.rect.top + $Window.rect.bottom) / 2)
            Click-Center ([pscustomobject]@{rect=[pscustomobject]@{left=$x-2;right=$x+2;top=$y-2;bottom=$y+2}})
            Start-Sleep -Milliseconds 250
            if ($isHotspot) { return $true }
            return ([TargetRuleNative]::SendMessage($hwnd,$script:TCM_GETCURSEL,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64() -eq $index)
        }
        "Button" {
            if (-not $isHotspot) {
                $flaUiResult = Invoke-FlaUiControlAction $Window 'invoke'
                if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) { return $true }
            }
            Click-Center $Window; return $true
        }
        "ListBox" {
            $options=@(Get-RuleListOptions $Window $MaxOptions)
            $selected=@($options | Where-Object { $_.value -eq $Value -or $_.displayValue -eq $Value } | Select-Object -First 1)
            if ($selected.Count -eq 0) { return $false }
            $flaUiResult = Invoke-FlaUiControlAction $Window 'selectIndex' -Index ([int]$selected[0].index)
            if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) { return $true }
            return [bool](Invoke-RuleListOptionClick $Window $selected[0])
        }
        default { return $false }
    }
}
