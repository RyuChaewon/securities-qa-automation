<#
.SYNOPSIS 모든 HTS 입력을 현재 프로세스, 메인 창과 승인된 콘텐츠 표면 경계 안으로 제한한다.
.DESCRIPTION Safety는 입력 허용·차단과 감사 증거만 담당하며 테스트 결과 판정이나 업무 UI 동작을 수행하지 않는다.
#>

function New-HtsSafetyContext {
    param(
        [Parameter(Mandatory = $true)][string]$AuditPath,
        [Parameter(Mandatory = $true)]$Dependencies
    )
    [pscustomobject]@{
        AuditPath=$AuditPath;Dependencies=$Dependencies;MainHwnd=[Int64]0;MainPid=0
        ActiveInputSurfaceHwnd=[Int64]0;ActiveInputSurfaceKind='None';ActiveInputSurfaceLabel=''
    }
}

function Invoke-HtsSafetyDependency {
    param([Parameter(Mandatory = $true)]$Context,[Parameter(Mandatory = $true)][string]$Name,[object[]]$Arguments=@())
    if(-not $Context.Dependencies -or -not ($Context.Dependencies.PSObject.Properties.Name -contains $Name)){throw "HTS safety dependency가 없습니다: $Name"}
    $dependency=$Context.Dependencies.$Name
    if(-not ($dependency -is [scriptblock])){throw "HTS safety dependency는 scriptblock이어야 합니다: $Name"}
    & $dependency @Arguments
}

function Set-HtsSafetySession {
    param([Parameter(Mandatory = $true)]$Context,[Parameter(Mandatory = $true)]$Main)
    $Context.MainHwnd=[Int64]$Main.hwnd;$Context.MainPid=[int]$Main.pid
}

function Test-HtsSafetyPointInRect {
    param([int]$X,[int]$Y,$Rect)
    $Rect -and $X -ge [int]$Rect.left -and $X -lt [int]$Rect.right -and $Y -ge [int]$Rect.top -and $Y -lt [int]$Rect.bottom
}

function Clear-HtsSafetyInputSurface {
    param([Parameter(Mandatory = $true)]$Context)
    $Context.ActiveInputSurfaceHwnd=[Int64]0;$Context.ActiveInputSurfaceKind='None';$Context.ActiveInputSurfaceLabel=''
}

function Set-HtsSafetyInputSurface {
    param([Parameter(Mandatory = $true)]$Context,$Window,[string]$Kind,[string]$Label='')
    if(-not $Window -or [Int64]$Window.hwnd -eq 0 -or -not [bool](Invoke-HtsSafetyDependency $Context 'IsWindow' @([Int64]$Window.hwnd))){
        throw 'INPUT_SCOPE_BLOCKED: 활성 입력 표면이 유효하지 않습니다.'
    }
    $current=Invoke-HtsSafetyDependency $Context 'GetWindowInfo' @([Int64]$Window.hwnd)
    if(-not [bool](Invoke-HtsSafetyDependency $Context 'IsWindow' @([Int64]$Context.MainHwnd)) -or [int]$current.pid -ne [int]$Context.MainPid){
        throw 'INPUT_SCOPE_BLOCKED: 입력 표면이 현재 HTS 프로세스에 속하지 않습니다.'
    }
    $main=Invoke-HtsSafetyDependency $Context 'GetWindowInfo' @([Int64]$Context.MainHwnd)
    if($Kind -eq 'Main' -and [Int64]$current.hwnd -ne [Int64]$main.hwnd){throw 'INPUT_SCOPE_BLOCKED: 메인 입력 단계의 표면이 HTS 메인창이 아닙니다.'}
    if($Kind -eq 'Content' -and -not [bool](Invoke-HtsSafetyDependency $Context 'IsChild' @([Int64]$Context.MainHwnd,[Int64]$current.hwnd))){
        throw 'INPUT_SCOPE_BLOCKED: 콘텐츠 표면이 HTS 메인창의 자식 창이 아닙니다.'
    }
    $centerX=[int](($current.rect.left+$current.rect.right)/2);$centerY=[int](($current.rect.top+$current.rect.bottom)/2)
    if(-not (Test-HtsSafetyPointInRect $centerX $centerY $main.rect)){throw 'INPUT_SCOPE_BLOCKED: 입력 표면이 HTS 메인창 경계 밖에 있습니다.'}
    $Context.ActiveInputSurfaceHwnd=[Int64]$current.hwnd;$Context.ActiveInputSurfaceKind=$Kind;$Context.ActiveInputSurfaceLabel=$Label
}

function Get-HtsSafetyActiveInputSurface {
    param([Parameter(Mandatory = $true)]$Context)
    if($Context.ActiveInputSurfaceHwnd -eq 0 -or -not [bool](Invoke-HtsSafetyDependency $Context 'IsWindow' @([Int64]$Context.ActiveInputSurfaceHwnd))){
        throw 'INPUT_SCOPE_BLOCKED: 활성 입력 표면이 없거나 사라졌습니다.'
    }
    Invoke-HtsSafetyDependency $Context 'GetWindowInfo' @([Int64]$Context.ActiveInputSurfaceHwnd)
}

function Assert-HtsSafetyClickScope {
    param([Parameter(Mandatory = $true)]$Context,$Window,[int]$X,[int]$Y)
    $main=Invoke-HtsSafetyDependency $Context 'GetWindowInfo' @([Int64]$Context.MainHwnd)
    $surface=Get-HtsSafetyActiveInputSurface $Context
    if(-not (Test-HtsSafetyPointInRect $X $Y $main.rect)){throw "INPUT_SCOPE_BLOCKED: 클릭 좌표 ($X,$Y)가 HTS 메인창 밖에 있습니다."}
    if(-not (Test-HtsSafetyPointInRect $X $Y $surface.rect)){throw "INPUT_SCOPE_BLOCKED: 클릭 좌표 ($X,$Y)가 현재 대상 창 '$($Context.ActiveInputSurfaceLabel)' 밖에 있습니다."}
    if($Context.ActiveInputSurfaceKind -eq 'Content'){
        $screenNumber=Invoke-HtsSafetyDependency $Context 'GetScreenNumber' @($surface)
        $policy=Invoke-HtsSafetyDependency $Context 'GetContentPolicy' @($screenNumber)
        $probe=if($Window){$Window}else{[pscustomobject]@{rect=[pscustomobject]@{left=$X-1;right=$X+1;top=$Y-1;bottom=$Y+1;width=2;height=2};className='';rawTitle=''}}
        if(-not [bool](Invoke-HtsSafetyDependency $Context 'TestContentControl' @($probe,$surface,$policy))){throw "INPUT_SCOPE_BLOCKED: 클릭 좌표 ($X,$Y)가 [$screenNumber] 콘텐츠 안전 영역 밖에 있습니다."}
    }
    $targetHwnd=if($Window -and $Window.PSObject.Properties.Name -contains 'hwnd'){[Int64]$Window.hwnd}else{[Int64]0}
    if($targetHwnd -ne 0){
        if(-not [bool](Invoke-HtsSafetyDependency $Context 'IsWindow' @($targetHwnd))){throw 'INPUT_SCOPE_BLOCKED: 클릭 대상 HWND가 더 이상 유효하지 않습니다.'}
        $targetPid=[int](Invoke-HtsSafetyDependency $Context 'GetWindowProcessId' @($targetHwnd))
        if($targetPid -ne [int]$Context.MainPid){throw 'INPUT_SCOPE_BLOCKED: 클릭 대상이 HTS 프로세스에 속하지 않습니다.'}
        if($targetHwnd -ne [Int64]$surface.hwnd -and -not [bool](Invoke-HtsSafetyDependency $Context 'IsChild' @([Int64]$surface.hwnd,$targetHwnd))){throw 'INPUT_SCOPE_BLOCKED: 클릭 대상이 현재 대상 창의 자손이 아닙니다.'}
    }
}

function Assert-HtsSafetyKeyboardScope {
    param([Parameter(Mandatory = $true)]$Context)
    $surface=Get-HtsSafetyActiveInputSurface $Context
    $focus=[Int64](Invoke-HtsSafetyDependency $Context 'GetKeyboardFocusHwnd')
    if($focus -eq 0){throw 'INPUT_SCOPE_BLOCKED: HTS 내부 키보드 포커스를 찾지 못했습니다.'}
    if($focus -ne [Int64]$surface.hwnd -and -not [bool](Invoke-HtsSafetyDependency $Context 'IsChild' @([Int64]$surface.hwnd,$focus))){
        throw "INPUT_SCOPE_BLOCKED: 키보드 포커스가 현재 대상 창 '$($Context.ActiveInputSurfaceLabel)' 밖에 있습니다."
    }
    if($Context.ActiveInputSurfaceKind -eq 'Content' -and $focus -ne [Int64]$surface.hwnd){
        $focusWindow=Invoke-HtsSafetyDependency $Context 'GetWindowInfo' @($focus)
        $screenNumber=Invoke-HtsSafetyDependency $Context 'GetScreenNumber' @($surface)
        $policy=Invoke-HtsSafetyDependency $Context 'GetContentPolicy' @($screenNumber)
        if(-not [bool](Invoke-HtsSafetyDependency $Context 'TestContentControl' @($focusWindow,$surface,$policy))){throw "INPUT_SCOPE_BLOCKED: 키보드 포커스가 [$screenNumber] 콘텐츠 안전 영역 밖에 있습니다."}
    }
}

function Write-HtsSafetyInputBoundaryAudit {
    param([Parameter(Mandatory = $true)]$Context,[string]$InputType,[string]$Status,[int]$X=-1,[int]$Y=-1,[string]$Detail='')
    $mainRect=$null;$surfaceRect=$null
    try{if($Context.MainHwnd -ne 0 -and [bool](Invoke-HtsSafetyDependency $Context 'IsWindow' @([Int64]$Context.MainHwnd))){$mainRect=(Invoke-HtsSafetyDependency $Context 'GetWindowInfo' @([Int64]$Context.MainHwnd)).rect}}catch{}
    try{if($Context.ActiveInputSurfaceHwnd -ne 0 -and [bool](Invoke-HtsSafetyDependency $Context 'IsWindow' @([Int64]$Context.ActiveInputSurfaceHwnd))){$surfaceRect=(Invoke-HtsSafetyDependency $Context 'GetWindowInfo' @([Int64]$Context.ActiveInputSurfaceHwnd)).rect}}catch{}
    $now=Invoke-HtsSafetyDependency $Context 'GetNow'
    $record=[pscustomobject]@{
        timestamp=$now.ToString('o');inputType=$InputType;status=$Status;x=$X;y=$Y;mainHwnd=[Int64]$Context.MainHwnd;mainRect=$mainRect
        surfaceHwnd=[Int64]$Context.ActiveInputSurfaceHwnd;surfaceKind=[string]$Context.ActiveInputSurfaceKind;surfaceLabel=[string]$Context.ActiveInputSurfaceLabel
        surfaceRect=$surfaceRect;detail=$Detail
    }
    Invoke-HtsSafetyDependency $Context 'AppendAuditRecord' @($Context.AuditPath,$record)
}

function Assert-HtsSafetyPointOwner {
    param([Parameter(Mandatory = $true)]$Context,[int]$LogicalX,[int]$LogicalY,[int]$PhysicalX,[int]$PhysicalY)
    $hitHwnd=[Int64](Invoke-HtsSafetyDependency $Context 'WindowFromPoint' @($LogicalX,$LogicalY))
    $hitPid=if($hitHwnd -ne 0){[int](Invoke-HtsSafetyDependency $Context 'GetWindowProcessId' @($hitHwnd))}else{0}
    if($hitPid -ne [int]$Context.MainPid){throw "HTS_POINT_OWNER_GUARD: 논리 좌표 ($LogicalX,$LogicalY), 물리 좌표 ($PhysicalX,$PhysicalY)의 최상단 창이 HTS 프로세스가 아닙니다. ownerPid=$hitPid"}
}

function Assert-HtsSafetyCursorTarget {
    param([Parameter(Mandatory = $true)]$Context,$ClickWindow,$PhysicalPoint)
    $hitHwnd=[Int64](Invoke-HtsSafetyDependency $Context 'WindowFromPoint' @([int]$PhysicalPoint.X,[int]$PhysicalPoint.Y))
    $hitPid=if($hitHwnd -ne 0){[int](Invoke-HtsSafetyDependency $Context 'GetWindowProcessId' @($hitHwnd))}else{0}
    if($hitPid -ne [int]$Context.MainPid){throw "HTS_PHYSICAL_CURSOR_OWNER_GUARD: 실제 커서 위치 ($([int]$PhysicalPoint.X),$([int]$PhysicalPoint.Y))의 최상단 창이 HTS 프로세스가 아닙니다. ownerPid=$hitPid"}
    $targetHwnd=if($ClickWindow -and $ClickWindow.PSObject.Properties.Name -contains 'hwnd'){[Int64]$ClickWindow.hwnd}else{[Int64]0}
    if($targetHwnd -ne 0 -and $hitHwnd -ne $targetHwnd -and -not [bool](Invoke-HtsSafetyDependency $Context 'IsChild' @($targetHwnd,$hitHwnd))){throw "HTS_PHYSICAL_CURSOR_TARGET_GUARD: 실제 커서 위치가 고정 대상 HWND와 다릅니다. targetHwnd=$targetHwnd, hitHwnd=$hitHwnd"}
    [pscustomobject]@{hitHwnd=$hitHwnd;targetHwnd=$targetHwnd;ownerPid=$hitPid}
}
