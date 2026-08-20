<# .SYNOPSIS Regression tests for explicit HTS input boundary and ownership safety. #>
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-safety.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERT_TRUE failed: $Message"};$script:assertions++}
function Assert-Equal($Expected,$Actual,[string]$Message){if([string]$Expected-ne[string]$Actual){throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'"};$script:assertions++}
function Assert-Throws([scriptblock]$Action,[string]$Pattern,[string]$Message){try{&$Action;throw "ASSERT_THROWS failed: $Message"}catch{if($_.Exception.Message-notmatch$Pattern){throw}};$script:assertions++}

$script:assertions=0
function New-FakeWindow([Int64]$Hwnd,[int]$ProcessId,[int]$Left,[int]$Top,[int]$Right,[int]$Bottom){[pscustomobject]@{hwnd=$Hwnd;pid=$ProcessId;className='Edit';rawTitle='';rect=[pscustomobject]@{left=$Left;top=$Top;right=$Right;bottom=$Bottom;width=$Right-$Left;height=$Bottom-$Top}}}
$main=New-FakeWindow 1 7 0 0 1000 800
$surface=New-FakeWindow 2 7 100 100 900 700
$target=New-FakeWindow 3 7 200 200 300 240
$foreign=New-FakeWindow 4 8 200 200 300 240
$windows=@{1=$main;2=$surface;3=$target;4=$foreign}
$script:focusHwnd=[Int64]3
$script:hitHwnd=[Int64]3
$script:auditRecords=New-Object Collections.Generic.List[object]
$dependencies=[pscustomobject]@{
    IsWindow={param([Int64]$Hwnd)$windows.ContainsKey([int]$Hwnd)}
    GetWindowInfo={param([Int64]$Hwnd)$windows[[int]$Hwnd]}
    IsChild={param([Int64]$Parent,[Int64]$Child)($Parent-eq1-and$Child-in@(2,3))-or($Parent-eq2-and$Child-eq3)}
    GetWindowProcessId={param([Int64]$Hwnd)[int]$windows[[int]$Hwnd].pid}
    GetScreenNumber={param($Window)'0714'}
    GetContentPolicy={param([string]$ScreenNumber)[pscustomobject]@{screenNumber=$ScreenNumber}}
    TestContentControl={param($Window,$Screen,$Policy)[int]$Window.rect.left-ge100-and[int]$Window.rect.right-le900}
    GetKeyboardFocusHwnd={$script:focusHwnd}
    WindowFromPoint={param([int]$X,[int]$Y)$script:hitHwnd}
    GetNow={[datetime]'2026-08-20T12:00:00Z'}
    AppendAuditRecord={param([string]$Path,$Record)[void]$script:auditRecords.Add($Record)}
}
$context=New-HtsSafetyContext -AuditPath 'fake-audit.ndjson' -Dependencies $dependencies
Set-HtsSafetySession -Context $context -Main $main
Assert-Equal 1 $context.MainHwnd 'main HWND is explicit safety context state'
Assert-Equal 7 $context.MainPid 'main PID is explicit safety context state'

Set-HtsSafetyInputSurface -Context $context -Window $surface -Kind 'Content' -Label '0714 content'
Assert-Equal 2 $context.ActiveInputSurfaceHwnd 'content input surface is registered'
Assert-Equal 'Content' $context.ActiveInputSurfaceKind 'surface kind is retained'
Assert-Equal 2 (Get-HtsSafetyActiveInputSurface -Context $context).hwnd 'active input surface is re-read through dependencies'

Assert-HtsSafetyClickScope -Context $context -Window $target -X 250 -Y 220
Assert-True $true 'in-process child click inside content scope is allowed'
Assert-Throws {Assert-HtsSafetyClickScope -Context $context -Window $target -X 950 -Y 220} 'INPUT_SCOPE_BLOCKED' 'click outside active surface is blocked'
Assert-Throws {Assert-HtsSafetyClickScope -Context $context -Window $foreign -X 250 -Y 220} 'HTS 프로세스' 'foreign process target is blocked'

$script:focusHwnd=3
Assert-HtsSafetyKeyboardScope -Context $context
Assert-True $true 'keyboard focus on content child is allowed'
$script:focusHwnd=4
Assert-Throws {Assert-HtsSafetyKeyboardScope -Context $context} '대상 창' 'keyboard focus outside content surface is blocked'

Write-HtsSafetyInputBoundaryAudit -Context $context -InputType 'MouseClick' -Status 'ALLOWED' -X 250 -Y 220 -Detail 'fake'
Assert-Equal 1 $script:auditRecords.Count 'audit record is delegated once'
Assert-Equal 2 $script:auditRecords[0].surfaceHwnd 'audit record captures explicit surface identity'

$script:hitHwnd=3
Assert-HtsSafetyPointOwner -Context $context -LogicalX 250 -LogicalY 220 -PhysicalX 250 -PhysicalY 220
Assert-True $true 'point owner in HTS process is allowed'
$cursor=Assert-HtsSafetyCursorTarget -Context $context -ClickWindow $target -PhysicalPoint ([pscustomobject]@{X=250;Y=220})
Assert-Equal 3 $cursor.hitHwnd 'cursor target returns raw ownership evidence'
$script:hitHwnd=4
Assert-Throws {Assert-HtsSafetyPointOwner -Context $context -LogicalX 250 -LogicalY 220 -PhysicalX 250 -PhysicalY 220} 'OWNER_GUARD' 'foreign point owner is blocked'

Clear-HtsSafetyInputSurface -Context $context
Assert-Equal 0 $context.ActiveInputSurfaceHwnd 'clear removes prior surface identity'
Assert-Throws {Get-HtsSafetyActiveInputSurface -Context $context} '활성 입력 표면' 'cleared surface cannot be reused'

$moduleText=Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-safety.ps1') -Raw
Assert-True ($moduleText-notmatch'\$script:|\$global:') 'safety module has no global or script-scoped runtime state'
Assert-True ($moduleText-notmatch'ResultEvaluator|TestResult|Invoke-RuleResultEvaluation') 'safety module cannot evaluate test results'
Write-Output "HTS_SAFETY_TESTS=PASS assertions=$script:assertions"
