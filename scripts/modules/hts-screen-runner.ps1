<#
.SYNOPSIS Screen-order lifecycle and case sequence coordination.
.DESCRIPTION Owns screen-level setup and deterministic case order while delegating case evidence and verdict finalization.
#>

# Provides a fake-friendly deterministic open, case, and close sequence with finally cleanup.
function Invoke-HtsScreenCaseSequence {
    param(
        [Parameter(Mandatory = $true)][object[]]$Cases,
        [Parameter(Mandatory = $true)][scriptblock]$OpenScreen,
        [Parameter(Mandatory = $true)][scriptblock]$RunCase,
        [Parameter(Mandatory = $true)][scriptblock]$CloseScreen
    )

    $currentScreen = $null
    try {
        foreach ($case in $Cases) {
            $screenNumber = [string]$case.screen.screenNumber
            if ($null -eq $currentScreen -or [string]$currentScreen -ne $screenNumber) {
                if ($null -ne $currentScreen) { & $CloseScreen $currentScreen }
                & $OpenScreen $screenNumber
                $currentScreen = $screenNumber
            }
            & $RunCase $case
        }
    } finally {
        if ($null -ne $currentScreen) { & $CloseScreen $currentScreen }
    }
}

# Opens or reuses the approved target screen and returns only screen-lifecycle facts in the case frame.
function Enter-HtsRuleSuiteCaseScreen {
    param(
        [Parameter(Mandatory = $true)]$RunSpec,
        [Parameter(Mandatory = $true)]$RunServices,
        [Parameter(Mandatory = $true)]$RunState,
        [Parameter(Mandatory = $true)]$Frame
    )

    $scenarioMode = [bool]$RunSpec.ScenarioMode
    $reuseExistingTargetScreenRequested = [bool]$RunSpec.ReuseExistingTargetScreenRequested
    $RequireExistingTargetScreen = [bool]$RunSpec.Input.RequireExistingTargetScreen
    $RuntimeContext = $RunServices.RuntimeContext
    $sessionContext = $RunServices.SessionContext
    $safetyContext = $RunServices.SafetyContext
    $actionContext = $RunServices.ActionContext
    $observationContext = $RunServices.ObservationContext
    $navigationContext = $RunServices.NavigationContext
    $reportingContext = $RunServices.ReportingContext

    $case = $Frame.Case
    $reuseScenarioScreen = [bool]$Frame.ReuseScenarioScreen
    $main = $Frame.Main
    $screen = $Frame.Screen
    $screenEdit = $Frame.ScreenEdit
    $secret = [string]$Frame.Secret
    $actions = $Frame.Actions
    $pendingReasons = $Frame.PendingReasons
    $existingScreenRequiredMissing = [bool]$Frame.ExistingScreenRequiredMissing
    $usedExistingTargetScreen = [bool]$Frame.UsedExistingTargetScreen
    $openedTargetScreenForRun = [bool]$Frame.OpenedTargetScreenForRun

        $previousPid = if ($main) { [int]$main.pid } else { 0 }
        $main = Wait-HtsMainWindow -Context $sessionContext
        Set-HtsSafetySession -Context $safetyContext -Main $main
        if ($previousPid -ne 0 -and $main.pid -ne $previousPid) {
            Add-HtsActionRecord $reportingContext $actions "recoverMainWindow" "PASS" "hfrun" "재접속 후 새 HTS 메인 창을 찾아 실행을 계속했습니다."
        }
        [void](Dismiss-HtsDialogs $actionContext $observationContext $RuntimeContext $main $secret)
        $startupConnectionDialogs = @(Get-HtsConnectionDialogs $observationContext $RuntimeContext $main $secret)
        if ($startupConnectionDialogs.Count -gt 0) {
            throw "HTS_CONNECTION_LOST: 연결 장애 대화상자가 남아 있어 사용자 판단 없이 실행을 중단했습니다. $([string]$startupConnectionDialogs[0].text)"
        }
        [void](Close-ScreenSearchOverlays $navigationContext $main)
        $logBefore = Get-LogState $observationContext
        $beforeErrorTexts = @(Get-ErrorWindowTexts $observationContext $main $caseErrorRegex $secret)
        if ($reuseScenarioScreen -or $reuseExistingTargetScreenRequested) {
            $requestedScreenWindow = Find-ScreenWindow $navigationContext $main ([string]$case.screen.screenNumber)
            $screen = if ($requestedScreenWindow) { Find-BestHtsContentSurface $navigationContext $main $requestedScreenWindow ([string]$case.screen.screenNumber) @() } else { $null }
            if ($screen) {
                $usedExistingTargetScreen = Test-PreservedTargetScreen $navigationContext $requestedScreenWindow
                if ($usedExistingTargetScreen) {
                    Add-HtsActionRecord $reportingContext $actions 'attachExistingScreen' 'PASS' ([string]$case.screen.screenNumber) '사용자가 미리 열어둔 대상 화면에 연결했으며 화면번호 재입력을 수행하지 않았습니다.'
                } else {
                    Add-HtsActionRecord $reportingContext $actions 'reuseScreenForScenario' 'PASS' ([string]$case.screen.screenNumber) '같은 화면의 다음 시나리오 케이스이므로 화면을 닫고 다시 열지 않고 현재 콘텐츠 표면을 재사용했습니다.'
                }
            } elseif ($RequireExistingTargetScreen) {
                $existingScreenRequiredMissing = $true
                $pendingReasons.Add("사용자가 미리 열어둔 [$($case.screen.screenNumber)] 화면이 필요합니다.")
                Add-HtsActionRecord $reportingContext $actions 'attachExistingScreen' 'PENDING' ([string]$case.screen.screenNumber) '기존 대상 화면이 없어 화면번호 재입력 없이 실행을 보류했습니다.' 'EXISTING_SCREEN_REQUIRED'
            } else {
                $screenEdit = Find-ScreenNumberEdit $RuntimeContext $main
                Open-HtsScreen $navigationContext $main $screenEdit ([string]$case.screen.screenNumber)
                $openedTargetScreenForRun = $true
                $requestedScreenWindow = Find-ScreenWindow $navigationContext $main ([string]$case.screen.screenNumber)
                $screen = Find-BestHtsContentSurface $navigationContext $main $requestedScreenWindow ([string]$case.screen.screenNumber) @()
                $openAction = if($reuseScenarioScreen){'reopenMissingScenarioScreen'}else{'openTargetScreen'}
                $openMessage = if($reuseScenarioScreen){'같은 화면의 다음 케이스 전에 대상 화면이 사라져 다시 열었습니다.'}else{'실행 중인 HTS 메인 창의 화면번호 입력란으로 대상 화면을 열었습니다.'}
                Add-HtsActionRecord $reportingContext $actions $openAction $(if($screen){'PASS'}else{'FAIL'}) ([string]$case.screen.screenNumber) $openMessage $(if($screen){''}else{'SCREEN_NOT_VISIBLE'})
            }
        } else {
            $leftoverScreensClosed=Close-ExistingTargetScreens $navigationContext $main
            if($leftoverScreensClosed -gt 0){Add-HtsActionRecord $reportingContext $actions 'cleanupPreviousScreens' 'PASS' 'HTS sibling windows' "이전 화면에서 남은 HTS 내부 창 $leftoverScreensClosed개를 정리했습니다."}
            $remainingBeforeOpen=@(Get-HtsScreenWindows $navigationContext $main)
            if($remainingBeforeOpen.Count -gt 0){
                throw "SCREEN_SEQUENCE_GUARD: 이전 화면 $($remainingBeforeOpen.Count)개가 남아 있어 다음 화면 열기를 차단했습니다."
            }
            $baselineScreenHwnds=@(Get-ChildWindows ([Int64]$main.hwnd) | Where-Object { $_.visible -and $RuntimeContext.TargetScreenTitleRegex.IsMatch([string]$_.rawTitle) } | ForEach-Object { [Int64]$_.hwnd })
            $screenEdit = Find-ScreenNumberEdit $RuntimeContext $main
            Open-HtsScreen $navigationContext $main $screenEdit ([string]$case.screen.screenNumber)
            $openedTargetScreenForRun = $true
            $requestedScreenWindow = Find-ScreenWindow $navigationContext $main ([string]$case.screen.screenNumber)
            $screen = Find-BestHtsContentSurface $navigationContext $main $requestedScreenWindow ([string]$case.screen.screenNumber) $baselineScreenHwnds
        }

    $Frame.Main = $main
    $Frame.Screen = $screen
    $Frame.ScreenEdit = $screenEdit
    $Frame.ExistingScreenRequiredMissing = [bool]$existingScreenRequiredMissing
    $Frame.UsedExistingTargetScreen = [bool]$usedExistingTargetScreen
    $Frame.OpenedTargetScreenForRun = [bool]$openedTargetScreenForRun
    $Frame
}

# Restores or closes the approved target screen while preserving case evidence on every path.
function Exit-HtsRuleSuiteCaseScreen {
    param(
        [Parameter(Mandatory = $true)]$RunSpec,
        [Parameter(Mandatory = $true)]$RunServices,
        [Parameter(Mandatory = $true)]$RunState,
        [Parameter(Mandatory = $true)]$Frame
    )

    $PreserveTargetScreenAfterRun = [bool]$RunSpec.Input.PreserveTargetScreenAfterRun
    $RuntimeContext = $RunServices.RuntimeContext
    $actionContext = $RunServices.ActionContext
    $observationContext = $RunServices.ObservationContext
    $navigationContext = $RunServices.NavigationContext
    $reportingContext = $RunServices.ReportingContext

    $case = $Frame.Case
    $retainScenarioScreen = [bool]$Frame.RetainScenarioScreen
    $main = $Frame.Main
    $screen = $Frame.Screen
    $screenEdit = $Frame.ScreenEdit
    $secret = [string]$Frame.Secret
    $actions = $Frame.Actions
    $pendingReasons = $Frame.PendingReasons
    $existingScreenRequiredMissing = [bool]$Frame.ExistingScreenRequiredMissing
    $usedExistingTargetScreen = [bool]$Frame.UsedExistingTargetScreen
    $openedTargetScreenForRun = [bool]$Frame.OpenedTargetScreenForRun

    $dialogsBeforeDismiss = if ($main) { @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret) } else { @() }
    if ($dialogsBeforeDismiss.Count -gt 0) {
        $dismissed = Dismiss-HtsDialogs $actionContext $observationContext $RuntimeContext $main $secret
        Add-HtsActionRecord $reportingContext $actions "dismissDialog" $(if ($dismissed -eq $dialogsBeforeDismiss.Count) { "PASS" } else { "PENDING" }) "HTS dialog" "후속 테스트를 위해 HTS 대화상자 $dismissed/$($dialogsBeforeDismiss.Count)개를 닫았습니다." $(if ($dismissed -eq $dialogsBeforeDismiss.Count) { "" } else { "DIALOG_DISMISS_PENDING" })
        if ($dismissed -ne $dialogsBeforeDismiss.Count) { $pendingReasons.Add("HTS 대화상자 닫기") }
    }
    $remainingDialogs = if ($main -and [TargetRuleNative]::IsWindow([IntPtr][Int64]$main.hwnd)) { @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret) } else { @() }
    if ($existingScreenRequiredMissing) {
        Add-HtsActionRecord $reportingContext $actions 'closeScreen' 'PENDING' ([string]$case.screen.screenNumber) '연결된 대상 화면이 없어 화면 종료 동작을 수행하지 않았습니다.' 'EXISTING_SCREEN_REQUIRED'
    } elseif ($remainingDialogs.Count -gt 0) {
        Add-HtsActionRecord $reportingContext $actions "closeScreen" "PENDING" ([string]$case.screen.screenNumber) "모달 대화상자가 남아 있어 HTS 종료 위험을 피하도록 화면 닫기를 차단했습니다." "DIALOG_BLOCKS_SCREEN_CLOSE"
        $pendingReasons.Add("모달 대화상자 후 화면 닫기 차단")
    } elseif ($retainScenarioScreen -and (Test-HtsRequestedScreen $navigationContext $screen ([string]$case.screen.screenNumber))) {
        Add-HtsActionRecord $reportingContext $actions 'retainScreenForNextScenario' 'PASS' ([string]$case.screen.screenNumber) '같은 화면의 다음 시나리오 케이스를 위해 현재 화면을 유지했습니다.'
    } elseif ($PreserveTargetScreenAfterRun -and (Test-HtsRequestedScreen $navigationContext $screen ([string]$case.screen.screenNumber))) {
        Add-HtsActionRecord $reportingContext $actions 'preserveTargetScreenAfterRun' 'PASS' ([string]$case.screen.screenNumber) $(if($openedTargetScreenForRun){'자동화가 연 대상 화면을 후속 확인을 위해 닫지 않고 유지했습니다.'}else{'현재 대상 화면을 후속 확인을 위해 닫지 않고 유지했습니다.'})
    } elseif ($usedExistingTargetScreen -and (Test-PreservedTargetScreen $navigationContext (Find-ScreenWindow $navigationContext $main ([string]$case.screen.screenNumber)))) {
        Add-HtsActionRecord $reportingContext $actions 'preserveExistingScreen' 'PASS' ([string]$case.screen.screenNumber) '사용자가 미리 열어둔 화면이므로 테스트 종료 후에도 닫지 않고 유지했습니다.'
    } else {
        $screenToClose=if(Test-HtsRequestedScreen $navigationContext $screen ([string]$case.screen.screenNumber)){$screen}else{Find-ScreenWindow $navigationContext $main ([string]$case.screen.screenNumber)}
        if ($screenToClose) {
            if (Close-HtsScreen $navigationContext $screenToClose) {
                Add-HtsActionRecord $reportingContext $actions "closeScreen" "PASS" ([string]$case.screen.screenNumber) "테스트를 마친 화면을 의도적으로 닫았습니다."
            } else {
                Add-HtsActionRecord $reportingContext $actions "closeScreen" "PENDING" ([string]$case.screen.screenNumber) "테스트를 마친 화면을 닫지 못했습니다." "SCREEN_CLOSE_PENDING"
                $pendingReasons.Add("화면 닫기")
            }
        }
        if($main -and [TargetRuleNative]::IsWindow([IntPtr][Int64]$main.hwnd)){
            $siblingScreensClosed=Close-ExistingTargetScreens $navigationContext $main
            if($siblingScreensClosed -gt 0){Add-HtsActionRecord $reportingContext $actions 'closeSiblingScreens' 'PASS' 'HTS sibling windows' "테스트 중 새로 열린 형제·연계 내부 창 $siblingScreensClosed개를 함께 닫았습니다."}
            $remainingAfterClose=@(Get-HtsScreenWindows $navigationContext $main)
            if($remainingAfterClose.Count -gt 0){
                Add-HtsActionRecord $reportingContext $actions 'verifySequentialClose' 'PENDING' ([string]$case.screen.screenNumber) "번호 창 $($remainingAfterClose.Count)개가 남아 다음 화면 열기를 차단해야 합니다." 'SCREEN_SEQUENCE_CLOSE_PENDING'
                $pendingReasons.Add('순차 화면 닫기 미완료')
            }else{
                Add-HtsActionRecord $reportingContext $actions 'verifySequentialClose' 'PASS' ([string]$case.screen.screenNumber) '현재 화면과 연계 화면이 모두 닫혀 다음 화면을 열 수 있습니다.'
            }
        }
    }

    $Frame.Main = $main
    $Frame.Screen = $screen
    $Frame.ScreenEdit = $screenEdit
    $Frame
}

# Builds approved execution cases, performs session precheck, and coordinates cases in existing order.
function Invoke-HtsRuleSuiteScreens {
    param(
        [Parameter(Mandatory = $true)]$RunSpec,
        [Parameter(Mandatory = $true)]$RunServices,
        [Parameter(Mandatory = $true)]$RunState
    )

    $dataset = $RunSpec.Dataset
    $testPack = $RunSpec.TestPack
    $RuntimeContext = $RunServices.RuntimeContext
    $sessionContext = $RunServices.SessionContext
    $safetyContext = $RunServices.SafetyContext
    $navigationContext = $RunServices.NavigationContext

    $executionCaseContext = New-HtsExecutionCaseContext `
        -ScreensCsv ([string]$RunSpec.Input.ScreensCsv) `
        -ScenarioMode ([bool]$RunSpec.ScenarioMode) `
        -ScenarioPlan $RunSpec.ScenarioPlan `
        -RequestedScenarioCaseIds @($RunSpec.RequestedScenarioCaseIds) `
        -PlanOnly ([bool]$RunSpec.Input.PlanOnly) `
        -ExecutableScenarioCaseIds @($RunSpec.ExecutableScenarioCaseIds) `
        -Dataset $dataset `
        -TestPack $testPack
    $cases = @(Get-ExecutionCasesFromApprovedPlans -Context $executionCaseContext)
    if ($cases.Count -gt [int]$RunSpec.Input.MaxCases -or $cases.Count -gt [int]$testPack.maxCases) { throw "승인 TestPack 케이스 수 $($cases.Count)가 실행 제한을 초과했습니다." }
    if ($RunSpec.ScenarioMode -and -not $RunSpec.Input.PlanOnly -and $cases.Count -eq 0) { throw '승인과 고신뢰 바인딩을 모두 통과한 실행 가능 시나리오 케이스가 없습니다.' }
    $RunState.Cases = $cases

    $configuredErrorPatterns = @($dataset.executionPolicy.errorPatterns | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $errorPattern = if ($configuredErrorPatterns.Count -gt 0) { $configuredErrorPatterns -join '|' } else { '(?!)' }
    $RunState.ErrorRegex = [regex]::new($errorPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)

    try {
        [void](Start-FlaUiBridge -Context $sessionContext)
        $RunState.Main = Find-HtsMainWindow -Context $sessionContext
        Set-HtsSafetySession -Context $safetyContext -Main $RunState.Main
        [void][TargetRuleNative]::ShowWindow([IntPtr][Int64]$RunState.Main.hwnd, 9)
        [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$RunState.Main.hwnd)
        Set-HtsSafetyInputSurface -Context $safetyContext -Window $RunState.Main -Kind 'Main' -Label 'HTS 메인 사전점검'
        $RunState.ScreenEdit = Find-ScreenNumberEdit $RuntimeContext $RunState.Main
    } catch {
        [void](Complete-HtsEnvironmentPrecheckFailure -RunSpec $RunSpec -RunServices $RunServices -RunState $RunState -ErrorRecord $_)
        return $RunState
    }

    $RunState.InitialSearchOverlaysClosed = Close-ScreenSearchOverlays $navigationContext $RunState.Main
    if ($RunSpec.ReuseExistingTargetScreenRequested) {
        $preservedTargetScreenHwnds = @(Get-HtsScreenWindows $navigationContext $RunState.Main | ForEach-Object { [Int64]$_.hwnd } | Select-Object -Unique)
        [void](Set-HtsNavigationPreservedScreens -Context $navigationContext -Hwnds $preservedTargetScreenHwnds)
        $RunState.InitialScreensPreserved = $navigationContext.PreservedTargetScreenHwnds.Count
        $RunState.InitialScreensClosed = 0
    } else {
        $RunState.InitialScreensClosed = Close-ExistingTargetScreens $navigationContext $RunState.Main
    }

    for ($caseIndex = 0; $caseIndex -lt $cases.Count; $caseIndex++) {
        $caseCompletion = Invoke-HtsRuleSuiteCase -RunSpec $RunSpec -RunServices $RunServices -RunState $RunState -Cases $cases -CaseIndex $caseIndex
        if ($caseCompletion.StopRequested) { break }
    }
    [void](Complete-HtsRuleSuiteResult -RunSpec $RunSpec -RunServices $RunServices -RunState $RunState)
    $RunState
}
