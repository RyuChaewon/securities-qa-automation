<#
.SYNOPSIS Passive Recorder loop가 injected input 없이 manual down/up을 한 interaction과 7개 Discovery artifact로 조정하는지 검증한다.
.DESCRIPTION observer, clock, frame, analyzer와 writer를 모두 fake dependency로 주입해 실제 HWND·hook·filesystem을 사용하지 않는다.
.OUTPUTS assertion 수가 포함된 PASS 한 줄.
.NOTES UI Action, 거래, keyboard 문자열, ResultEvaluator와 TestResult를 실행하지 않는다.
#>
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-passive-interaction-recorder.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ASSERT_TRUE failed: $Message"};$script:assertions++}
function Assert-Equal($Expected,$Actual,[string]$Message){if([string]$Expected-ne[string]$Actual){throw "ASSERT_EQUAL failed: $Message expected='$Expected' actual='$Actual'"};$script:assertions++}
$script:assertions=0
$script:pointerIndex=0;$script:stopChecks=0;$script:started=0;$script:stopped=0;$script:clock=0
$script:writes=@{}
$baseTime=[DateTimeOffset]'2026-08-25T12:00:00Z'
$pointerEvents=@(
 [pscustomobject]@{sequence=1;observedAt=$baseTime.AddMilliseconds(100);button='Left';phase='Down';x=200;y=100;injected=$false},
 [pscustomobject]@{sequence=2;observedAt=$baseTime.AddMilliseconds(180);button='Left';phase='Up';x=200;y=100;injected=$false})
$frame=[pscustomobject]@{
 rootHwnd=101;processId=900;observedAt=$baseTime;stateFingerprint='frame';actionSentCount=0;transactionalActionCount=0
 hitTarget=[pscustomobject]@{insideTarget=$true;primaryHwnd=11;parentHwnd=101;className='AfxWnd140';nativeSignature='sig';spatialRegion='GlobalHeader'}
}
$interaction=[pscustomobject]@{
 interactionId='interaction-0001';automated=$false;verdictEligible=$false;actionSentCount=0;transactionalActionCount=0
 preStateFingerprint='pre';postStateFingerprint='post';preFrameReference='snapshots/interaction-0001.pre.json';postFrameReference='snapshots/interaction-0001.post.json'
 hitTarget=[pscustomobject]@{insideTarget=$true;primaryHwnd=11;parentHwnd=101;className='AfxWnd140';nativeSignature='sig';spatialRegion='GlobalHeader'}
 delta=[pscustomobject]@{stateFingerprintChanged=$true;popupCreatedHwnds=@();popupClosedHwnds=@();selectionEventObserved=$false}
 suggestion=[pscustomobject]@{inferredRole='order-tab:buy';inferredActionKind='Select';confidence=.6;ambiguous=$true;transactionalRiskCandidate=$false;evidence=@('fixture')}
}
$zone=[pscustomobject]@{zoneId='zone-001';parentHwnd=101;nativeSignature='sig';className='AfxWnd140';spatialRegion='GlobalHeader';centerX=.2;centerY=.1;observationCount=1;roleSuggestion='order-tab:buy';actionKindSuggestion='Select';confidence=.6}
$context=New-HtsPassiveInteractionRecorderContext -Dependencies ([pscustomobject]@{
 EnsureDirectory={param([string]$Path)}
 CaptureFrame={param([Int64]$Hwnd,$Point,$Regions);$frame|Add-Member -NotePropertyName observedAt -NotePropertyValue $baseTime.AddMilliseconds($script:clock) -Force;$frame}
 AnalyzeInteraction={param($Sequence,$Down,$Up,$Pre,$Post,$Events,$Previous);$interaction}
 ClusterInteractions={param($Interactions,$Threshold);@($zone)}
 StartObserver={param([int]$ProcessId);$script:started++}
 StopObserver={$script:stopped++}
 TryDequeuePointer={if($script:pointerIndex-lt$pointerEvents.Count){$value=$pointerEvents[$script:pointerIndex];$script:pointerIndex++;$value}else{$null}}
 TryDequeueWindowEvent={$null}
 GetStopReason={$script:stopChecks++;if($script:pointerIndex-ge$pointerEvents.Count-and$script:stopChecks-ge4){'F10'}else{''}}
 WaitMilliseconds={param([int]$Milliseconds);$script:clock+=$Milliseconds}
 Now={$script:clock+=10;$baseTime.AddMilliseconds($script:clock)}
 WriteStatus={param([string]$Message)}
 WriteJson={param([string]$Path,$Value);$script:writes[[IO.Path]::GetFileName($Path)]=$Value}
})
$summary=Invoke-HtsPassiveInteractionRecording -Context $context -RootHwnd 101 -OutputDirectory (Join-Path $root 'fake-passive-output') -MaxDurationSeconds 10 -IdleSnapshotMilliseconds 400
Assert-Equal 1 $script:started 'observer started once'
Assert-Equal 1 $script:stopped 'observer stopped once'
Assert-Equal 1 $summary.Session.interactionCount 'one manual interaction'
Assert-Equal 1 $summary.Session.uniqueTargetHwndCount 'unique target count'
Assert-Equal 1 $summary.Session.ownerDrawnZoneCount 'owner-drawn zone count'
Assert-Equal 1 $summary.Session.ambiguousInteractionCount 'ambiguity count'
Assert-Equal 'F10' $summary.Session.stopReason 'stop reason'
Assert-Equal 0 $summary.UiActionCount 'UI action count'
Assert-Equal 0 $summary.TransactionalActionCount 'transactional action count'
Assert-Equal 7 $summary.ArtifactFiles.Count 'seven discovery artifacts'
Assert-True ($script:writes.ContainsKey('interaction-session.json')) 'session artifact written'
Assert-True ($script:writes.ContainsKey('observed-interactions.json')) 'interaction artifact written'
Assert-True ($script:writes.ContainsKey('interaction-0001.pre.json')) 'pre frame written'
Assert-True ($script:writes.ContainsKey('interaction-0001.post.json')) 'post samples written'
Assert-Equal 'Discovery' $script:writes['interaction-session.json'].artifactRole 'session remains discovery'
Assert-True (-not[bool]$script:writes['control-repository-candidates.json'].payload.candidates[0].executable) 'repository candidate not executable'
Write-Output "HTS_PASSIVE_INTERACTION_ORCHESTRATION_TESTS=PASS assertions=$script:assertions"
