<#
.SYNOPSIS 승인된 HTS 컨트롤에 대한 UIA3 의미 동작을 실행하고 검증된 fallback 필요성을 원시 결과로 반환한다.
.DESCRIPTION Action은 입력·클릭·선택을 조정하지만 테스트 결과 판정 또는 리포트 생성을 수행하지 않는다.
#>

function New-HtsActionContext {
    param(
        [Parameter(Mandatory = $true)]$SessionContext,
        [Parameter(Mandatory = $true)]$Metrics,
        [Parameter(Mandatory = $true)]$Dependencies,
        $RuntimeContext = $null,
        $SafetyContext = $null
    )

    [pscustomobject]@{
        SessionContext = $SessionContext
        Metrics = $Metrics
        Dependencies = $Dependencies
        RuntimeContext = $RuntimeContext
        SafetyContext = $SafetyContext
    }
}

function Invoke-HtsActionDependency {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [object[]]$Arguments = @()
    )

    if (-not $Context.Dependencies -or -not ($Context.Dependencies.PSObject.Properties.Name -contains $Name)) {
        throw "HTS action dependency가 없습니다: $Name"
    }
    $dependency = $Context.Dependencies.$Name
    if (-not ($dependency -is [scriptblock])) { throw "HTS action dependency는 scriptblock이어야 합니다: $Name" }
    & $dependency @Arguments
}

function New-HtsFlaUiSelector {
    param([Parameter(Mandatory = $true)]$Window)

    $bounds = if ($Window -and $Window.rect) {
        [ordered]@{left=[int]$Window.rect.left;top=[int]$Window.rect.top;right=[int]$Window.rect.right;bottom=[int]$Window.rect.bottom}
    } else { $null }
    $uiaClassName = if ($Window.PSObject.Properties.Name -contains 'uiaClassName') { [string]$Window.uiaClassName } elseif ([string]$Window.className -notlike 'UIA:*') { [string]$Window.className } else { '' }
    [ordered]@{
        runtimeId=$(if ($Window.PSObject.Properties.Name -contains 'uiaRuntimeId') { [string]$Window.uiaRuntimeId } else { '' })
        nativeWindowHandle=$(if ($Window.PSObject.Properties.Name -contains 'hwnd') { [Int64]$Window.hwnd } else { [Int64]0 })
        automationId=$(if ($Window.PSObject.Properties.Name -contains 'automationId') { [string]$Window.automationId } else { '' })
        name=$(if ($Window.PSObject.Properties.Name -contains 'rawTitle') { [string]$Window.rawTitle } else { '' })
        className=$uiaClassName
        controlType=$(if ($Window.PSObject.Properties.Name -contains 'uiaControlType') { [string]$Window.uiaControlType } else { '' })
        bounds=$bounds
    }
}

function Add-HtsActionFallbackReason {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $Context.Metrics.FlaUiFallbackRequests++
    if (-not $Context.Metrics.FlaUiFallbackReasons.Contains($Reason)) {
        $Context.Metrics.FlaUiFallbackReasons.Add($Reason)
    }
}

function Invoke-HtsFlaUiControlAction {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Window,
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Value = '',
        [Nullable[int]]$Index = $null,
        [Nullable[bool]]$Checked = $null,
        [string]$Key = ''
    )

    if (-not $Window -or [string]$Window.className -eq 'ConfiguredVisualHotspot') {
        return [pscustomobject]@{success=$false;verified=$false;fallbackRequired=$true;errorCode='VISUAL_HOTSPOT_REQUIRES_COORDINATE';message='시각 핫스팟은 UIA 요소가 아니므로 좌표 fallback이 필요합니다.';engine='FlaUI.UIA3'}
    }

    $centerX = [int](($Window.rect.left+$Window.rect.right)/2)
    $centerY = [int](($Window.rect.top+$Window.rect.bottom)/2)
    try {
        [void](Invoke-HtsActionDependency -Context $Context -Name 'AssertClickScope' -Arguments @($Window,$centerX,$centerY))
        $root = Invoke-HtsActionDependency -Context $Context -Name 'GetActiveInputSurface'
        $request = [ordered]@{
            requestId=[Guid]::NewGuid().ToString('N');operation='action';rootHwnd=[Int64]$root.hwnd
            selector=New-HtsFlaUiSelector $Window;action=$Action;value=$Value;key=$Key
        }
        if ($null -ne $Index) { $request.index=[int]$Index }
        if ($null -ne $Checked) { $request.checked=[bool]$Checked }
        $Context.Metrics.FlaUiActionAttempts++
        $response = Invoke-HtsActionDependency -Context $Context -Name 'InvokeBridgeRequest' -Arguments @($Context.SessionContext,$request)
        if ([bool]$response.success -and [bool]$response.verified) {
            $Context.Metrics.FlaUiActionSuccesses++
            [void](Invoke-HtsActionDependency -Context $Context -Name 'WriteInputAudit' -Arguments @('FlaUIAction','ALLOWED',$centerX,$centerY,("{0}; Pattern={1}; Target={2}" -f $Action,[string]$response.pattern,[string]$Window.rawTitle)))
            return $response
        }

        $fallbackCode = if ($response.errorCode) { [string]$response.errorCode } else { 'UIA3_RESULT_NOT_VERIFIED' }
        Add-HtsActionFallbackReason -Context $Context -Reason "${Action}:$fallbackCode"
        [void](Invoke-HtsActionDependency -Context $Context -Name 'WriteInputAudit' -Arguments @('FlaUIAction','FALLBACK',$centerX,$centerY,("{0}; {1}; {2}" -f $Action,[string]$response.errorCode,[string]$response.message)))
        $response
    } catch {
        Add-HtsActionFallbackReason -Context $Context -Reason "${Action}:UIA3_BRIDGE_EXCEPTION"
        [void](Invoke-HtsActionDependency -Context $Context -Name 'WriteInputAudit' -Arguments @('FlaUIAction','FALLBACK',$centerX,$centerY,$_.Exception.Message))
        [pscustomobject]@{success=$false;verified=$false;fallbackRequired=$true;errorCode='UIA3_BRIDGE_EXCEPTION';message=$_.Exception.Message;engine='FlaUI.UIA3'}
    }
}

function Invoke-HtsRuleControlPlanAction {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$NavigationContext,
        [Parameter(Mandatory = $true)]$Screen,
        [Parameter(Mandatory = $true)]$PlanItem
    )

    Invoke-HtsActionDependency -Context $Context -Name 'InvokeRuleControlPlanItem' -Arguments @($NavigationContext,$Screen,$PlanItem)
}

function Invoke-HtsDatasetVariableAction {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Window,
        [Parameter(Mandatory = $true)][string]$ControlKind,
        [Parameter(Mandatory = $true)][string]$Value,
        [string]$ValueMatch,
        [int]$MaxOptions = 40
    )

    Invoke-HtsActionDependency -Context $Context -Name 'InvokeRuleDatasetVariable' -Arguments @($Window,$ControlKind,$Value,$ValueMatch,$MaxOptions)
}

# Rule-suite physical input adapters. UI results remain raw action evidence.
function Invoke-FlaUiControlAction(
    $ActionContext,
    $Window,
    [string]$Action,
    [string]$Value = '',
    [Nullable[int]]$Index = $null,
    [Nullable[bool]]$Checked = $null,
    [string]$Key = '') {
    Invoke-HtsFlaUiControlAction -Context $ActionContext -Window $Window -Action $Action -Value $Value -Index $Index -Checked $Checked -Key $Key
}

function Assert-HtsForeground($ActionContext) {
    if($ActionContext.SafetyContext.MainHwnd -eq 0 -or $ActionContext.SafetyContext.MainPid -eq 0){return}
    $mainHwnd=[IntPtr][Int64]$ActionContext.SafetyContext.MainHwnd
    if(-not [TargetRuleNative]::IsWindow($mainHwnd)){
        $replacement=$null
        try{$replacement=Wait-HtsMainWindow -Context $ActionContext.SessionContext -TimeoutMs 15000}catch{}
        if(-not $replacement){throw 'HTS_FOREGROUND_GUARD: HTS 메인 창이 사라졌고 새 메인 창도 찾지 못했습니다.'}
        Set-HtsSafetySession -Context $ActionContext.SafetyContext -Main $replacement
        $mainHwnd=[IntPtr][Int64]$ActionContext.SafetyContext.MainHwnd
    }
    $foreground=[TargetRuleNative]::GetForegroundWindow()
    [uint32]$foregroundPid=0
    $foregroundThread=if($foreground -ne [IntPtr]::Zero){[TargetRuleNative]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)}else{0}
    if([int]$foregroundPid -eq [int]$ActionContext.SafetyContext.MainPid){return}

    [uint32]$targetPid=0
    $targetThread=[TargetRuleNative]::GetWindowThreadProcessId($mainHwnd,[ref]$targetPid)
    $currentThread=[TargetRuleNative]::GetCurrentThreadId()
    $attachedForeground=$false
    $attachedTarget=$false
    try{
        if($foregroundThread -ne 0 -and $foregroundThread -ne $currentThread){$attachedForeground=[TargetRuleNative]::AttachThreadInput($currentThread,$foregroundThread,$true)}
        if($targetThread -ne 0 -and $targetThread -ne $currentThread){$attachedTarget=[TargetRuleNative]::AttachThreadInput($currentThread,$targetThread,$true)}
        [void][TargetRuleNative]::ShowWindow($mainHwnd,9)
        [void][TargetRuleNative]::BringWindowToTop($mainHwnd)
        [void][TargetRuleNative]::SetForegroundWindow($mainHwnd)
    }finally{
        if($attachedTarget){[void][TargetRuleNative]::AttachThreadInput($currentThread,$targetThread,$false)}
        if($attachedForeground){[void][TargetRuleNative]::AttachThreadInput($currentThread,$foregroundThread,$false)}
    }
    Start-Sleep -Milliseconds 120
    $foreground=[TargetRuleNative]::GetForegroundWindow()
    $foregroundPid=0
    if($foreground -ne [IntPtr]::Zero){[void][TargetRuleNative]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)}
    if([int]$foregroundPid -ne [int]$ActionContext.SafetyContext.MainPid){
        [TargetRuleNative]::keybd_event([byte]0x12,0,0,[UIntPtr]::Zero)
        [TargetRuleNative]::keybd_event([byte]0x12,0,0x0002,[UIntPtr]::Zero)
        [void][TargetRuleNative]::SetForegroundWindow($mainHwnd)
        Start-Sleep -Milliseconds 120
        $foreground=[TargetRuleNative]::GetForegroundWindow()
        $foregroundPid=0
        if($foreground -ne [IntPtr]::Zero){[void][TargetRuleNative]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)}
    }
    if([int]$foregroundPid -ne [int]$ActionContext.SafetyContext.MainPid){
        $positionFlags=[uint32](0x0001 -bor 0x0002)
        [void][TargetRuleNative]::SetWindowPos($mainHwnd,[IntPtr](-1),0,0,0,0,$positionFlags)
        [void][TargetRuleNative]::BringWindowToTop($mainHwnd)
        [void][TargetRuleNative]::SetForegroundWindow($mainHwnd)
        [void][TargetRuleNative]::SetWindowPos($mainHwnd,[IntPtr](-2),0,0,0,0,$positionFlags)
        Start-Sleep -Milliseconds 150
        $foreground=[TargetRuleNative]::GetForegroundWindow()
        $foregroundPid=0
        if($foreground -ne [IntPtr]::Zero){[void][TargetRuleNative]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)}
    }
    if([int]$foregroundPid -ne [int]$ActionContext.SafetyContext.MainPid){
        [TargetRuleNative]::SwitchToThisWindow($mainHwnd,$true)
        Start-Sleep -Milliseconds 150
        $foreground=[TargetRuleNative]::GetForegroundWindow()
        $foregroundPid=0
        if($foreground -ne [IntPtr]::Zero){[void][TargetRuleNative]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)}
    }
    if([int]$foregroundPid -ne [int]$ActionContext.SafetyContext.MainPid){throw 'HTS_FOREGROUND_GUARD: HTS를 전경으로 확정하지 못해 입력을 차단했습니다.'}
}

function Send-Key($ActionContext, [byte]$Key) {
    $foregroundReady=$false
    $foregroundError=''
    for($attempt=0;$attempt -lt 3;$attempt++){
        try{Assert-HtsForeground $ActionContext;$foregroundReady=$true;break}catch{$foregroundError=$_.Exception.Message;Start-Sleep -Milliseconds 250}
    }
    if(-not $foregroundReady){Write-HtsSafetyInputBoundaryAudit -Context $ActionContext.SafetyContext -InputType 'Keyboard' -Status 'BLOCKED' -X -1 -Y -1 -Detail $foregroundError;throw $foregroundError}
    try{Assert-HtsSafetyKeyboardScope -Context $ActionContext.SafetyContext}catch{Write-HtsSafetyInputBoundaryAudit -Context $ActionContext.SafetyContext -InputType 'Keyboard' -Status 'BLOCKED' -X -1 -Y -1 -Detail $_.Exception.Message;throw}
    Write-HtsSafetyInputBoundaryAudit -Context $ActionContext.SafetyContext -InputType 'Keyboard' -Status 'ALLOWED' -X -1 -Y -1 -Detail ("VK={0}" -f $Key)
    [TargetRuleNative]::keybd_event($Key, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
    [TargetRuleNative]::keybd_event($Key, 0, 0x0002, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
}

function Focus-HtsInputWindow($ActionContext, $Window) {
    if (-not $Window -or -not ($Window.PSObject.Properties.Name -contains 'hwnd') -or [Int64]$Window.hwnd -eq 0) {
        throw 'INPUT_SCOPE_BLOCKED: 포커스 대상 HWND가 없습니다.'
    }
    $targetHwnd = [IntPtr][Int64]$Window.hwnd
    if (-not [TargetRuleNative]::IsWindow($targetHwnd)) { throw 'INPUT_SCOPE_BLOCKED: 포커스 대상 HWND가 더 이상 유효하지 않습니다.' }
    Assert-HtsForeground $ActionContext
    [uint32]$targetPid = 0
    $targetThread = [TargetRuleNative]::GetWindowThreadProcessId($targetHwnd, [ref]$targetPid)
    if ([int]$targetPid -ne [int]$ActionContext.SafetyContext.MainPid) { throw 'INPUT_SCOPE_BLOCKED: 포커스 대상이 HTS 프로세스에 속하지 않습니다.' }
    $currentThread = [TargetRuleNative]::GetCurrentThreadId()
    $attached = $false
    try {
        if ($targetThread -ne 0 -and $targetThread -ne $currentThread) {
            $attached = [TargetRuleNative]::AttachThreadInput($currentThread, $targetThread, $true)
        }
        [void][TargetRuleNative]::SetFocus($targetHwnd)
    } finally {
        if ($attached) { [void][TargetRuleNative]::AttachThreadInput($currentThread, $targetThread, $false) }
    }
    $info = New-Object TargetRuleNative+GUITHREADINFO
    $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][TargetRuleNative+GUITHREADINFO])
    [void][TargetRuleNative]::GetGUIThreadInfo(0, [ref]$info)
    $focus = [Int64]$info.hwndFocus.ToInt64()
    if ($focus -ne [Int64]$targetHwnd) {
        $detail = "expected=$([Int64]$targetHwnd), actual=$focus, targetThread=$targetThread, currentThread=$currentThread, attached=$attached"
        Write-HtsSafetyInputBoundaryAudit -Context $ActionContext.SafetyContext -InputType 'KeyboardFocus' -Status 'BLOCKED' -X -1 -Y -1 -Detail $detail
        throw "INPUT_SCOPE_BLOCKED: 화면번호 입력창 포커스를 검증하지 못했습니다. $detail"
    }
    Write-HtsSafetyInputBoundaryAudit -Context $ActionContext.SafetyContext -InputType 'KeyboardFocus' -Status 'ALLOWED' -X -1 -Y -1 -Detail "targetHwnd=$([Int64]$targetHwnd)"
}

function Click-Center($ActionContext, $Window, [switch]$DoubleClick) {
    $foregroundReady=$false
    $foregroundError=''
    for($attempt=0;$attempt -lt 3;$attempt++){
        try{Assert-HtsForeground $ActionContext;$foregroundReady=$true;break}catch{$foregroundError=$_.Exception.Message;Start-Sleep -Milliseconds 250}
    }
    if(-not $foregroundReady){Write-HtsSafetyInputBoundaryAudit -Context $ActionContext.SafetyContext -InputType 'MouseClick' -Status 'BLOCKED' -X -1 -Y -1 -Detail $foregroundError;throw $foregroundError}
    $clickWindow=$Window
    if($Window -and $Window.PSObject.Properties.Name -contains 'hwnd' -and [Int64]$Window.hwnd -ne 0){
        if(-not [TargetRuleNative]::IsWindow([IntPtr][Int64]$Window.hwnd)){throw 'INPUT_SCOPE_BLOCKED: 클릭 직전에 대상 HWND가 사라졌습니다.'}
        $clickWindow=Get-WindowInfo ([IntPtr][Int64]$Window.hwnd)
    }
    $x = [int](($clickWindow.rect.left + $clickWindow.rect.right) / 2)
    $y = [int](($clickWindow.rect.top + $clickWindow.rect.bottom) / 2)
    try{Assert-HtsSafetyClickScope -Context $ActionContext.SafetyContext -Window $clickWindow -X $x -Y $y}catch{Write-HtsSafetyInputBoundaryAudit -Context $ActionContext.SafetyContext -InputType 'MouseClick' -Status 'BLOCKED' -X $x -Y $y -Detail $_.Exception.Message;throw}
    $physicalPoint = New-Object TargetRuleNative+POINT
    $physicalPoint.X = $x
    $physicalPoint.Y = $y
    $mainHwnd = [IntPtr][Int64]$ActionContext.SafetyContext.MainHwnd
    $converted = $mainHwnd -ne [IntPtr]::Zero -and [TargetRuleNative]::LogicalToPhysicalPointForPerMonitorDPI($mainHwnd,[ref]$physicalPoint)
    if (-not $converted) {
        $dpi = if ($mainHwnd -ne [IntPtr]::Zero) { [int][TargetRuleNative]::GetDpiForWindow($mainHwnd) } else { 96 }
        if ($dpi -ne 96) {
            $message = "DPI_POINT_CONVERSION_FAILED: logical=($x,$y), dpi=$dpi"
            Write-HtsSafetyInputBoundaryAudit -Context $ActionContext.SafetyContext -InputType 'MouseClick' -Status 'BLOCKED' -X $x -Y $y -Detail $message
            throw $message
        }
    }
    $physicalX = [int]$physicalPoint.X
    $physicalY = [int]$physicalPoint.Y
    $ownerReady=$false
    $ownerError=''
    for($attempt=0;$attempt -lt 3;$attempt++){
        try{
            Assert-HtsForeground $ActionContext
            Assert-HtsSafetyPointOwner -Context $ActionContext.SafetyContext -LogicalX $x -LogicalY $y -PhysicalX $physicalX -PhysicalY $physicalY
            $ownerReady=$true
            break
        }catch{
            $ownerError=$_.Exception.Message
            Start-Sleep -Milliseconds 200
        }
    }
    if(-not $ownerReady){
        Write-HtsSafetyInputBoundaryAudit -Context $ActionContext.SafetyContext -InputType 'MouseClick' -Status 'BLOCKED' -X $physicalX -Y $physicalY -Detail $ownerError
        throw $ownerError
    }
    $targetName = if($clickWindow.rawTitle){[string]$clickWindow.rawTitle}else{[string]$clickWindow.className}
    $previousDpiContext=[TargetRuleNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
    if($previousDpiContext -eq [IntPtr]::Zero){
        $message="DPI_THREAD_CONTEXT_FAILED: logical=($x,$y), physical=($physicalX,$physicalY)"
        Write-HtsSafetyInputBoundaryAudit -Context $ActionContext.SafetyContext -InputType 'MouseClick' -Status 'BLOCKED' -X $physicalX -Y $physicalY -Detail $message
        throw $message
    }
    $actualPoint=New-Object TargetRuleNative+POINT
    $targetHit=$null
    try {
        $cursorSet = $false
        if ($ActionContext.RuntimeContext.VisiblePointerMotion) {
            $startPoint = New-Object TargetRuleNative+POINT
            if ([TargetRuleNative]::GetPhysicalCursorPos([ref]$startPoint)) {
                $distance = [Math]::Sqrt([Math]::Pow($physicalX-[int]$startPoint.X,2)+[Math]::Pow($physicalY-[int]$startPoint.Y,2))
                $motionSteps = [Math]::Min(24,[Math]::Max(8,[int][Math]::Ceiling($distance/70)))
                for ($motionStep=1; $motionStep -le $motionSteps; $motionStep++) {
                    $ratio = $motionStep/[double]$motionSteps
                    $motionX = [int][Math]::Round([int]$startPoint.X+(($physicalX-[int]$startPoint.X)*$ratio))
                    $motionY = [int][Math]::Round([int]$startPoint.Y+(($physicalY-[int]$startPoint.Y)*$ratio))
                    if (-not [TargetRuleNative]::SetPhysicalCursorPos($motionX,$motionY)) { break }
                    $cursorSet = $motionStep -eq $motionSteps
                    Start-Sleep -Milliseconds 30
                }
            }
        } else {
            $cursorSet = [TargetRuleNative]::SetPhysicalCursorPos($physicalX,$physicalY)
        }
        if(-not $cursorSet){throw "PHYSICAL_CURSOR_SET_FAILED: logical=($x,$y), physical=($physicalX,$physicalY)"}
        if(-not [TargetRuleNative]::GetPhysicalCursorPos([ref]$actualPoint) -or [Math]::Abs([int]$actualPoint.X-$physicalX)-gt1 -or [Math]::Abs([int]$actualPoint.Y-$physicalY)-gt1){
            throw "PHYSICAL_CURSOR_VERIFY_FAILED: expected=($physicalX,$physicalY), actual=($([int]$actualPoint.X),$([int]$actualPoint.Y))"
        }
        $targetHit=Assert-HtsSafetyCursorTarget -Context $ActionContext.SafetyContext -ClickWindow $clickWindow -PhysicalPoint $actualPoint
        if ($ActionContext.RuntimeContext.PointerDwellMilliseconds -gt 0) { Start-Sleep -Milliseconds $ActionContext.RuntimeContext.PointerDwellMilliseconds }
        if(-not [TargetRuleNative]::SendLeftClick()){
            $nativeError=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "SEND_INPUT_CLICK_FAILED: logical=($x,$y), physical=($physicalX,$physicalY), win32Error=$nativeError"
        }
        if ($DoubleClick) {
            Start-Sleep -Milliseconds 60
            Assert-HtsForeground $ActionContext
            if(-not [TargetRuleNative]::SendLeftClick()){
                $nativeError=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "SEND_INPUT_DOUBLE_CLICK_FAILED: logical=($x,$y), physical=($physicalX,$physicalY), win32Error=$nativeError"
            }
        }
    } catch {
        Write-HtsSafetyInputBoundaryAudit -Context $ActionContext.SafetyContext -InputType 'MouseClick' -Status 'BLOCKED' -X $physicalX -Y $physicalY -Detail $_.Exception.Message
        throw
    } finally {
        [void][TargetRuleNative]::SetThreadDpiAwarenessContext($previousDpiContext)
    }
    Write-HtsSafetyInputBoundaryAudit -Context $ActionContext.SafetyContext -InputType 'MouseClick' -Status 'ALLOWED' -X $physicalX -Y $physicalY -Detail "$targetName; logical=($x,$y); physicalTarget=($physicalX,$physicalY); physicalVerified=($([int]$actualPoint.X),$([int]$actualPoint.Y)); targetHwnd=$([Int64]$targetHit.targetHwnd); hitHwnd=$([Int64]$targetHit.hitHwnd); dpiThreadContext=PER_MONITOR_AWARE_V2; coordinateSpace=physical; inputEngine=SendInput; clickCount=$(if($DoubleClick){2}else{1}); visiblePointerMotion=$([bool]$ActionContext.RuntimeContext.VisiblePointerMotion); dwellMs=$([int]$ActionContext.RuntimeContext.PointerDwellMilliseconds)"
    Start-Sleep -Milliseconds 120
}

function Set-AutomationText($ActionContext, $Window, [string]$Value, [switch]$Sensitive, [switch]$AlreadyFocused) {
    $ActionContext.RuntimeContext.LastTextAutomationEngine = 'Win32 fallback'
    $scopeWindow=$Window
    if($Window -and $Window.PSObject.Properties.Name -contains 'hwnd' -and [Int64]$Window.hwnd -ne 0){
        if(-not [TargetRuleNative]::IsWindow([IntPtr][Int64]$Window.hwnd)){throw 'INPUT_SCOPE_BLOCKED: 입력 직전에 대상 HWND가 사라졌습니다.'}
        $scopeWindow=Get-WindowInfo ([IntPtr][Int64]$Window.hwnd)
    }
    $scopeX=[int](($scopeWindow.rect.left+$scopeWindow.rect.right)/2)
    $scopeY=[int](($scopeWindow.rect.top+$scopeWindow.rect.bottom)/2)
    Assert-HtsSafetyClickScope -Context $ActionContext.SafetyContext -Window $scopeWindow -X $scopeX -Y $scopeY
    if (-not ([Int64]$Window.hwnd -eq 0 -and $Window.className -eq "ConfiguredVisualHotspot")) {
        $flaUiResult = Invoke-FlaUiControlAction $ActionContext $Window 'setText' -Value $Value
        if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) {
            $ActionContext.RuntimeContext.LastTextAutomationEngine = 'FlaUI.UIA3'
            return $true
        }
    }
    if ([Int64]$Window.hwnd -eq 0 -and $Window.className -eq "ConfiguredVisualHotspot") {
        if ($Sensitive) { return $false }
        if (-not $AlreadyFocused) { Click-Center $ActionContext $Window }
        Assert-HtsSafetyKeyboardScope -Context $ActionContext.SafetyContext
        [TargetRuleNative]::keybd_event([byte]0x11, 0, 0, [UIntPtr]::Zero)
        Send-Key $ActionContext ([byte]0x41)
        [TargetRuleNative]::keybd_event([byte]0x11, 0, 0x0002, [UIntPtr]::Zero)
        Send-Key $ActionContext ([byte]0x08)
        Assert-HtsSafetyKeyboardScope -Context $ActionContext.SafetyContext
        [Windows.Forms.SendKeys]::SendWait($Value)
        Start-Sleep -Milliseconds 200
        return $true
    }
    [void][TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd, 0x000C, [IntPtr]::Zero, $Value)
    Start-Sleep -Milliseconds 150
    $current = Get-WindowInfo ([IntPtr][Int64]$Window.hwnd)
    $length = [TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd, 0x000E, [IntPtr]::Zero, [IntPtr]::Zero).ToInt64()
    $sentByVirtualKeys = $false
    $needsFallback = if ($Sensitive) { $length -le 0 } else { [string]$current.rawTitle -ne $Value }
    if ($needsFallback) {
        $inputPoint = [pscustomobject]@{rect=[pscustomobject]@{left=$Window.rect.left;right=[Math]::Min($Window.rect.right,$Window.rect.left+48);top=$Window.rect.top;bottom=$Window.rect.bottom}}
        if (-not $AlreadyFocused) { Click-Center $ActionContext $inputPoint }
        Assert-HtsSafetyKeyboardScope -Context $ActionContext.SafetyContext
        [TargetRuleNative]::keybd_event([byte]0x11, 0, 0, [UIntPtr]::Zero)
        Send-Key $ActionContext ([byte]0x41)
        [TargetRuleNative]::keybd_event([byte]0x11, 0, 0x0002, [UIntPtr]::Zero)
        Send-Key $ActionContext ([byte]0x08)
        if ($Sensitive -or $Value -match '^[0-9]+$') {
            foreach ($ch in $Value.ToCharArray()) {
                if ($ch -notmatch '[0-9]') { return $false }
                Send-Key $ActionContext ([byte](0x30 + [int][string]$ch))
            }
            $sentByVirtualKeys = $true
        } else {
            Assert-HtsSafetyKeyboardScope -Context $ActionContext.SafetyContext
            [Windows.Forms.SendKeys]::SendWait($Value)
        }
        Start-Sleep -Milliseconds 150
        $current = Get-WindowInfo ([IntPtr][Int64]$Window.hwnd)
        if (-not $Sensitive -and [string]$current.rawTitle -notlike "*$Value*") {
            Click-Center $ActionContext $inputPoint
            Assert-HtsSafetyKeyboardScope -Context $ActionContext.SafetyContext
            [TargetRuleNative]::keybd_event([byte]0x11,0,0,[UIntPtr]::Zero)
            Send-Key $ActionContext ([byte]0x41)
            [TargetRuleNative]::keybd_event([byte]0x11,0,0x0002,[UIntPtr]::Zero)
            [Windows.Forms.Clipboard]::SetText($Value)
            [TargetRuleNative]::keybd_event([byte]0x11,0,0,[UIntPtr]::Zero)
            Send-Key $ActionContext ([byte]0x56)
            [TargetRuleNative]::keybd_event([byte]0x11,0,0x0002,[UIntPtr]::Zero)
            Start-Sleep -Milliseconds 150
            $current = Get-WindowInfo ([IntPtr][Int64]$Window.hwnd)
            $sentByVirtualKeys = $true
        }
        $length = [TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd, 0x000E, [IntPtr]::Zero, [IntPtr]::Zero).ToInt64()
    }
    return $(if ($Sensitive) { $length -gt 0 -or $sentByVirtualKeys } elseif ([string]$current.rawTitle -eq $Value) { $true } else { $sentByVirtualKeys })
}

function Test-HtsTransactionalConfirmationDialog($Dialog, $PlanItem) {
    if (-not $Dialog -or -not $PlanItem) { return $false }
    $messageText = ((@([string]$Dialog.title) + @($Dialog.messageLines)) | Where-Object { $_ }) -join ' | '
    if (Test-SystemFailureSignal $messageText -or Test-InputValidationSignal $messageText) { return $false }
    if ([string]$Dialog.classification -ne '확인 요청') { return $false }

    $logicalName = [string]$PlanItem.controlLogicalName
    $verbPattern = switch ($logicalName) {
        'BTN_Ord_Buy' { '매수|주문' }
        'BTN_Ord_Sell' { '매도|주문' }
        'BTN_Ord_Mod' { '정정|주문' }
        'BTN_Ord_Can' { '취소\s*주문|주문\s*취소|취소' }
        default { '주문|정정|취소|전송' }
    }
    if ($messageText -notmatch $verbPattern) { return $false }

    $positiveButtonPattern = '^(확인|예|Yes|주문|주문전송|전송|매수주문|매도주문|정정주문|취소주문)$'
    @($Dialog.buttons | Where-Object { [string]$_ -match $positiveButtonPattern }).Count -gt 0
}

function Submit-HtsTransactionalDialog($ActionContext, $Dialog, $PlanItem) {
    $positiveButtonPattern = '^(확인|예|Yes|주문|주문전송|전송|매수주문|매도주문|정정주문|취소주문)$'
    $buttons = @(Get-ChildWindows ([Int64]$Dialog.window.hwnd) | Where-Object {
        $_.visible -and $_.enabled -and $_.className -like '*Button*' -and $_.rawTitle -match $positiveButtonPattern
    } | Sort-Object @{Expression={
        if ($_.rawTitle -match '^(매수주문|매도주문|정정주문|취소주문)$') { 0 }
        elseif ($_.rawTitle -match '^(확인|예|Yes)$') { 1 }
        else { 2 }
    }}, {$_.rect.left})
    if ($buttons.Count -eq 0) {
        return [pscustomobject]@{success=$false;errorCode='TRANSACTION_CONFIRM_BUTTON_NOT_FOUND';output='거래 확인창에서 명시적 승인 버튼을 찾지 못했습니다.'}
    }

    $savedHwnd=[Int64]$ActionContext.SafetyContext.ActiveInputSurfaceHwnd
    $savedKind=[string]$ActionContext.SafetyContext.ActiveInputSurfaceKind
    $savedLabel=[string]$ActionContext.SafetyContext.ActiveInputSurfaceLabel
    try {
        Set-HtsSafetyInputSurface -Context $ActionContext.SafetyContext -Window $Dialog.window -Kind 'Dialog' -Label "HTS 거래 확인창: $($Dialog.title)"
        [void][TargetRuleNative]::ShowWindow([IntPtr][Int64]$Dialog.window.hwnd, 9)
        [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$Dialog.window.hwnd)
        Click-Center $ActionContext $buttons[0]
        Start-Sleep -Milliseconds 800
        $closed = -not [TargetRuleNative]::IsWindow([IntPtr][Int64]$Dialog.window.hwnd)
        [pscustomobject]@{
            success=$closed
            errorCode=$(if($closed){''}else{'TRANSACTION_CONFIRM_DIALOG_REMAINED'})
            output=$(if($closed){"거래 확인 버튼 '$([string]$buttons[0].rawTitle)'을 눌러 제출했습니다."}else{'승인 버튼 클릭 후 거래 확인창이 닫히지 않았습니다.'})
        }
    } catch {
        [pscustomobject]@{success=$false;errorCode='TRANSACTION_CONFIRM_CLICK_FAILED';output=$_.Exception.Message}
    } finally {
        if($savedHwnd -ne 0 -and [TargetRuleNative]::IsWindow([IntPtr]$savedHwnd)){
            try{Set-HtsSafetyInputSurface -Context $ActionContext.SafetyContext -Window (Get-WindowInfo ([IntPtr]$savedHwnd)) -Kind $savedKind -Label $savedLabel}catch{Clear-HtsSafetyInputSurface -Context $ActionContext.SafetyContext}
        }else{
            Clear-HtsSafetyInputSurface -Context $ActionContext.SafetyContext
        }
    }
}
