<#
.SYNOPSIS 이미 열린 0101에서 사용자가 직접 수행한 mouse interaction을 관찰 전용으로 기록한다.
.DESCRIPTION 정확한 0101 HWND를 선택하고 passive hook, native frame, visual hash와 suggestion artifact를 조립한다.
.INPUTS 현재 열린 0101 화면, 선택적 local output directory와 최대 recording 시간.
.OUTPUTS artifacts/local 아래 Discovery JSON과 종료 상태; TestResult나 승인 repository는 만들지 않는다.
.NOTES mouse/key injection, keyboard 문자열 수집, 자동 주문, ResultEvaluator와 Computer Use를 사용하지 않는다.
#>
param(
    [ValidateSet('1q-hts-0101')][string]$Target='1q-hts-0101',
    [ValidatePattern('^0101$')][string]$ScreenId='0101',
    [string]$OutputDirectory='',
    [string]$FlaUiAssembly='',
    [ValidateRange(1,7200)][int]$MaxDurationSeconds=1800)

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$profilePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\target-profile.json'))
if(-not(Test-Path -LiteralPath $profilePath -PathType Leaf)){throw "Target profile not found: $profilePath"}
$profile=Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$profile.id-ne$Target){throw "Target profile id mismatch: expected=$Target actual=$($profile.id)"}
if(-not$OutputDirectory){$OutputDirectory=Join-Path $root ('artifacts\local\passive-interactions\0101-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))}
if(-not$FlaUiAssembly){$FlaUiAssembly=Join-Path $root 'src\HtsQa.FlaUi\bin\Release\net8.0-windows7.0\HtsQa.FlaUi.dll'}
if(-not(Test-Path -LiteralPath $FlaUiAssembly -PathType Leaf)){throw "FlaUI Release assembly not found: $FlaUiAssembly"}

. (Join-Path $root 'scripts\modules\hts-native.ps1')
. (Join-Path $root 'scripts\modules\hts-session.ps1')
. (Join-Path $root 'scripts\modules\hts-layout-inspection.ps1')
. (Join-Path $root 'scripts\modules\hts-passive-interaction-recorder.ps1')
Initialize-HtsNativeInterop

$session=New-HtsSessionContext -FlaUiAssembly $FlaUiAssembly -TargetWindowClassName ([string]$profile.window.className) -TargetWindowTitlePrefix ([string]$profile.window.titlePrefix) -DisplayName ([string]$profile.displayName) -GetTopWindows { @(Get-TopWindows) }
[void](Start-FlaUiBridge -Context $session)
$observer=$null
$fullOutput=[IO.Path]::GetFullPath($OutputDirectory)
$exitPath=Join-Path $fullOutput 'recorder-exit.json'
$exitCode=1
try{
    Add-Type -Path $FlaUiAssembly
    $selectionContext=New-HtsLayoutInspectionContext -SessionContext $session -GetTopWindows { @(Get-TopWindows) } -GetChildWindows { param([Int64]$Hwnd) @(Get-ChildWindows $Hwnd) } -InvokeBridgeRequest { param($BridgeContext,$Request) Invoke-FlaUiBridgeRequest -Context $BridgeContext -Request $Request }
    $selected=Get-HtsExactOrderScreenWindow -Context $selectionContext -MainClassName ([string]$profile.window.className) -MainTitlePrefix ([string]$profile.window.titlePrefix) -ScreenId $ScreenId
    $rootHwnd=[Int64]$selected.Screen.hwnd
    $observer=[HtsQa.FlaUi.PassiveInputObserver]::new()
    $context=New-HtsPassiveInteractionRecorderContext -Dependencies ([pscustomobject]@{
        EnsureDirectory={param([string]$Path);if(-not(Test-Path -LiteralPath $Path)){[void](New-Item -ItemType Directory -Path $Path -Force)}}
        CaptureFrame={param([Int64]$Hwnd,$Point,$Regions)
            $request=[ordered]@{requestId=[Guid]::NewGuid().ToString('N');operation='observeInteractionFrame';rootHwnd=$Hwnd
                includeVisualSignature=$true;visualGridColumns=16;visualGridRows=12;regionHints=$Regions}
            if($null-ne$Point){$request.capturePoint=$Point}
            $response=Invoke-FlaUiBridgeRequest -Context $session -Request $request
            if(-not[bool]$response.success){throw "PASSIVE_FRAME_FAILED: $([string]$response.errorCode): $([string]$response.message)"}
            $response.interactionFrame}
        AnalyzeInteraction={param($Sequence,$Down,$Up,$Pre,$Post,$Events,$Previous)
            $request=[ordered]@{requestId=[Guid]::NewGuid().ToString('N');operation='analyzeObservedInteraction';rootHwnd=$rootHwnd
                interactionSequence=$Sequence;pointerDown=$Down;pointerUp=$Up;preInteractionFrame=$Pre;postInteractionFrames=$Post;windowEvents=$Events}
            if($null-ne$Previous){$request.previousInteraction=$Previous}
            $response=Invoke-FlaUiBridgeRequest -Context $session -Request $request
            if(-not[bool]$response.success){throw "PASSIVE_ANALYSIS_FAILED: $([string]$response.errorCode): $([string]$response.message)"}
            $interaction=$response.observedInteraction
            $orderTabRoles=@{
                'top-region:left'='order-tab:buy'
                'top-region:center'='order-tab:sell'
                'top-region:right'='order-tab:modify-cancel'
            }
            $genericRole=[string]$interaction.suggestion.inferredRole
            if($orderTabRoles.ContainsKey($genericRole)){
                $interaction.suggestion.inferredRole=$orderTabRoles[$genericRole]
                $interaction.suggestion.evidence=@($interaction.suggestion.evidence)+@('0101-order-tab-region-map')}
            $interaction}
        ClusterInteractions={param($Interactions,$Threshold)
            $response=Invoke-FlaUiBridgeRequest -Context $session -Request ([ordered]@{requestId=[Guid]::NewGuid().ToString('N');operation='clusterObservedInteractions';rootHwnd=$rootHwnd;interactions=$Interactions;zoneDistanceThreshold=$Threshold})
            if(-not[bool]$response.success){throw "PASSIVE_CLUSTER_FAILED: $([string]$response.errorCode): $([string]$response.message)"}
            @($response.interactionZones)}
        StartObserver={param([int]$ProcessId);$observer.Start($ProcessId)}
        StopObserver={if($null-ne$observer){$observer.Dispose()}}
        TryDequeuePointer={$value=$null;if($observer.TryDequeuePointer([ref]$value)){$value}else{$null}}
        TryDequeueWindowEvent={$value=$null;if($observer.TryDequeueWindowEvent([ref]$value)){$value}else{$null}}
        GetStopReason={
            if($observer.StopRequested){return 'F10'}
            try{if($Host.UI.RawUI.KeyAvailable){$key=$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');if([int]$key.VirtualKeyCode-eq13){return 'ConsoleEnter'}}}catch{}
            ''}
        WaitMilliseconds={param([int]$Milliseconds);Start-Sleep -Milliseconds $Milliseconds}
        Now={[DateTimeOffset]::Now}
        WriteStatus={param([string]$Message);Write-Host $Message}
        WriteJson={param([string]$Path,$Value);$parent=Split-Path -Parent $Path;if($parent-and-not(Test-Path -LiteralPath $parent)){[void](New-Item -ItemType Directory -Path $parent -Force)};$Value|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $Path -Encoding UTF8}
    })
    $summary=Invoke-HtsPassiveInteractionRecording -Context $context -RootHwnd $rootHwnd -OutputDirectory $fullOutput -MaxDurationSeconds $MaxDurationSeconds
    $exitCode=0
    [ordered]@{schemaVersion='1.0';status='Completed';exitCode=0;outputDirectory=$fullOutput;interactionCount=[int]$summary.Session.interactionCount
        uiActionCount=0;transactionalActionCount=0;testExecution=$false;verdictEligible=$false;resultEvaluatorInvoked=$false;completedAt=[DateTimeOffset]::Now}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $exitPath -Encoding UTF8
    $summary|ConvertTo-Json -Depth 8
}catch{
    if(-not(Test-Path -LiteralPath $fullOutput)){[void](New-Item -ItemType Directory -Path $fullOutput -Force)}
    [ordered]@{schemaVersion='1.0';status='Failed';exitCode=1;errorCode='PASSIVE_RECORDER_FAILED';message=[string]$_.Exception.Message
        uiActionCount=0;transactionalActionCount=0;testExecution=$false;verdictEligible=$false;resultEvaluatorInvoked=$false;completedAt=[DateTimeOffset]::Now}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $exitPath -Encoding UTF8
    throw
}finally{
    if($null-ne$observer){try{$observer.Dispose()}catch{}}
    Stop-FlaUiBridge -Context $session
}
exit $exitCode
