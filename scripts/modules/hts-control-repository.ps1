<#
.SYNOPSIS Control Repository capture와 canonical resolution 결과의 얇은 PowerShell adapter다.
.DESCRIPTION hover hotkey 시점의 cursor를 읽기만 하며 Core가 Resolved로 판정한 승인 상대좌표만 실행 객체로 변환한다.
.NOTES repository 승인, locator 우선순위, risk 판정 또는 verdict를 재구현하지 않는다.
#>

function New-HtsControlCaptureContext {
    param(
        [Parameter(Mandatory = $true)]$SessionContext,
        [Parameter(Mandatory = $true)]$Dependencies
    )
    [pscustomobject]@{ SessionContext=$SessionContext; Dependencies=$Dependencies }
}

# 주입된 의존성만 호출해 capture 도구가 전역 함수나 상태에 결합되지 않게 한다.
function Invoke-HtsControlCaptureDependency {
    param($Context,[string]$Name,[object[]]$Arguments=@())
    if (-not $Context -or -not $Context.Dependencies -or -not ($Context.Dependencies.PSObject.Properties.Name -contains $Name)) {
        throw "Control capture dependency가 없습니다: $Name"
    }
    $dependency=$Context.Dependencies.$Name
    if (-not ($dependency -is [scriptblock])) { throw "Control capture dependency는 scriptblock이어야 합니다: $Name" }
    & $dependency @Arguments
}

# F8 key-down만 capture trigger로 받으며 다른 키는 UI action으로 전달하지 않는다.
function Wait-HtsControlCaptureHotkey {
    param([Parameter(Mandatory = $true)]$Context,[int]$VirtualKeyCode=119)
    $key=Invoke-HtsControlCaptureDependency $Context 'ReadHotkey' @()
    if ([int]$key.VirtualKeyCode -ne $VirtualKeyCode) {
        throw "CAPTURE_HOTKEY_MISMATCH: expected=$VirtualKeyCode, actual=$([int]$key.VirtualKeyCode)"
    }
    $key
}

# cursor를 이동하지 않고 hotkey 시점 위치를 bridge의 read-only captureCandidate operation에 전달한다.
function Invoke-HtsControlCandidateCapture {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][Int64]$RootHwnd,
        [Parameter(Mandatory = $true)][string]$StateContext,
        [Parameter(Mandatory = $true)][string]$MapScreenCode,
        [ValidateSet('MapHostClient','ScreenClient')][string]$CoordinateSpace='ScreenClient'
    )
    [void](Wait-HtsControlCaptureHotkey -Context $Context)
    $cursor=Invoke-HtsControlCaptureDependency $Context 'GetCursorPosition' @()
    $request=[ordered]@{
        requestId=[Guid]::NewGuid().ToString('N');operation='captureCandidate';rootHwnd=$RootHwnd
        capturePoint=[ordered]@{x=[int]$cursor.X;y=[int]$cursor.Y}
        stateContext=$StateContext;mapScreenCode=$MapScreenCode;coordinateSpace=$CoordinateSpace
    }
    $response=Invoke-HtsControlCaptureDependency $Context 'InvokeBridgeRequest' @($Context.SessionContext,$request)
    if (-not [bool]$response.success) { throw "CONTROL_CAPTURE_FAILED: $([string]$response.errorCode): $([string]$response.message)" }
    $candidate=$response.captureCandidate
    if (-not $candidate -or [string]$candidate.status -ne 'ReviewRequired' -or [bool]$candidate.cursorMoved -or
        [bool]$candidate.clickSent -or [bool]$candidate.automaticallyApproved) {
        throw 'CONTROL_CAPTURE_UNSAFE_RESULT: capture must remain read-only and ReviewRequired.'
    }
    if (@($candidate.redactionsApplied).Count -eq 0) { throw 'CONTROL_CAPTURE_REDACTION_REQUIRED: capture lacks redaction evidence.' }
    $candidate
}

# 승인 normalized 좌표를 current client rect/DPI로 다시 계산해 action 전 redacted hit-test 증거만 수집한다.
function Invoke-HtsControlRepositoryPreflightObservation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][Int64]$RootHwnd,
        [Parameter(Mandatory = $true)][string]$StateContext,
        [Parameter(Mandatory = $true)][string]$MapScreenCode,
        [Parameter(Mandatory = $true)][double]$RelativeX,
        [Parameter(Mandatory = $true)][double]$RelativeY,
        [ValidateSet('MapHostClient','ScreenClient')][string]$CoordinateSpace='ScreenClient'
    )
    $request=[ordered]@{
        requestId=[Guid]::NewGuid().ToString('N');operation='controlRepositoryPreflight';rootHwnd=$RootHwnd
        stateContext=$StateContext;mapScreenCode=$MapScreenCode;coordinateSpace=$CoordinateSpace
        relativeX=$RelativeX;relativeY=$RelativeY
    }
    $response=Invoke-HtsControlCaptureDependency $Context 'InvokeBridgeRequest' @($Context.SessionContext,$request)
    if (-not [bool]$response.success) { throw "CONTROL_REPOSITORY_PREFLIGHT_FAILED: $([string]$response.errorCode): $([string]$response.message)" }
    $observed=$response.controlRepositoryPreflight
    if (-not $observed -or [string]$observed.status -ne 'Observed' -or [bool]$observed.cursorMoved -or [bool]$observed.clickSent -or
        @($observed.observedAnchorIds).Count -eq 0 -or -not $observed.resolvedScreenPoint) {
        throw 'CONTROL_REPOSITORY_PREFLIGHT_UNSAFE_RESULT: read-only execution evidence is incomplete.'
    }
    $observed
}

# Core canonical resolution을 표시/실행 adapter 객체로 바꾼다. 판정값이나 trust tier는 변경하지 않는다.
function ConvertFrom-HtsCanonicalControlResolution {
    param([Parameter(Mandatory = $true)]$Resolution)
    if ([string]$Resolution.status -ne 'Resolved' -or [string]$Resolution.trustTier -ne 'ApprovedAnchoredRelative' -or
        [string]$Resolution.approvalStatus -ne 'Approved' -or [string]::IsNullOrWhiteSpace([string]$Resolution.approvalPayloadHash) -or
        -not [bool]$Resolution.physicalAction -or [bool]$Resolution.actionSent -or -not $Resolution.resolvedScreenPoint -or
        @('Focus','Input','Select','Toggle','Click','DoubleClick','OpenConfirmation') -notcontains [string]$Resolution.action) {
        return $null
    }
    $x=[int]$Resolution.resolvedScreenPoint.x
    $y=[int]$Resolution.resolvedScreenPoint.y
    [pscustomobject]@{
        hwnd=0;visible=$true;enabled=$true;className='ConfiguredVisualHotspot';rawTitle=[string]$Resolution.repositoryKey;style=0
        rect=[pscustomobject]@{left=$x;top=$y;right=$x+1;bottom=$y+1;width=1;height=1}
        controlRepositoryResolution=$Resolution
    }
}
