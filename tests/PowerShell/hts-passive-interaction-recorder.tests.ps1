<#
.SYNOPSIS Passive Interaction Recorder의 Discovery metadata, redaction, suggestion projection과 진입점 안전 경계를 검증한다.
.DESCRIPTION synthetic interaction/zone만 사용하며 global hook, 실제 HTS, mouse/key injection이나 filesystem output을 실행하지 않는다.
.OUTPUTS assertion 수가 포함된 PASS 한 줄.
.NOTES 실제 recording과 거래 control을 수행하지 않는다.
#>
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-passive-interaction-recorder.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ASSERT_TRUE failed: $Message"};$script:assertions++}
function Assert-Equal($Expected,$Actual,[string]$Message){if([string]$Expected-ne[string]$Actual){throw "ASSERT_EQUAL failed: $Message expected='$Expected' actual='$Actual'"};$script:assertions++}
function Assert-Throws([scriptblock]$Action,[string]$Pattern,[string]$Message){try{&$Action;throw "ASSERT_THROWS failed: $Message"}catch{if($_.Exception.Message-notmatch$Pattern){throw}};$script:assertions++}
$script:assertions=0

$interaction=[pscustomobject]@{
 interactionId='interaction-0001';automated=$false;verdictEligible=$false;actionSentCount=0;transactionalActionCount=0
 preStateFingerprint='pre';postStateFingerprint='post';preFrameReference='snapshots/one.pre.json';postFrameReference='snapshots/one.post.json'
 hitTarget=[pscustomobject]@{primaryHwnd=11;spatialRegion='GlobalHeader'}
 delta=[pscustomobject]@{stateFingerprintChanged=$true;popupCreatedHwnds=@(20);popupClosedHwnds=@();selectionEventObserved=$true}
 suggestion=[pscustomobject]@{inferredRole='order-tab:buy';inferredActionKind='Select';confidence=.65;ambiguous=$true;transactionalRiskCandidate=$false;evidence=@('top-band-position')}
}
$zone=[pscustomobject]@{zoneId='zone-001';parentHwnd=10;nativeSignature='sha256:fixture';spatialRegion='GlobalHeader';centerX=.2;centerY=.1;observationCount=1;roleSuggestion='order-tab:buy';actionKindSuggestion='Select';confidence=.65}
$session=[ordered]@{interactionCount=1;uiActionCount=0;transactionalActionCount=0;automated=$false;testExecution=$false;verdictEligible=$false;resultEvaluatorInvoked=$false}
$artifacts=New-HtsPassiveInteractionArtifactSet -Session $session -Interactions @($interaction) -Zones @($zone)
Assert-Equal 7 $artifacts.Count 'seven separated local artifacts'
foreach($artifact in $artifacts.Values){
 Assert-Equal 'Discovery' $artifact.artifactRole 'artifact role fixed'
 Assert-Equal 'ObservedManualInteraction' $artifact.interactionRole 'manual role fixed'
 Assert-True (-not[bool]$artifact.automated) 'not automated'
 Assert-True (-not[bool]$artifact.testExecution) 'not test execution'
 Assert-True (-not[bool]$artifact.verdictEligible) 'not verdict eligible'
 Assert-True (-not[bool]$artifact.resultEvaluatorInvoked) 'evaluator not invoked'
 Assert-True ($null-eq$artifact.canonicalVerdict) 'canonical verdict absent'
 Assert-True (Assert-HtsPassiveRecorderArtifactSafety $artifact) 'artifact safety scan passes'
}
Assert-Equal 'ReviewRequired' $artifacts['control-repository-candidates.json'].payload.status 'repository candidates require review'
Assert-True (-not[bool]$artifacts['control-repository-candidates.json'].payload.automaticallyApproved) 'repository not auto-approved'
Assert-Equal 0 @($artifacts['scenario-authoring-hints.json'].payload.executableScenarios).Count 'no executable scenario'
Assert-Equal 'ConfigurationRequired' $artifacts['state-transition-suggestions.json'].payload.suggestions[0].status 'state suggestion remains configuration required'
Assert-True (-not[bool]$artifacts['state-transition-suggestions.json'].payload.suggestions[0].transitionApproved) 'transition not approved'

$badText=New-HtsPassiveRecorderEnvelope 'ObservedInteractions' ([ordered]@{rawText='do-not-store'})
Assert-Throws {Assert-HtsPassiveRecorderArtifactSafety $badText} 'REDACTION_FAILED' 'raw text property blocked'
$badAction=New-HtsPassiveRecorderEnvelope 'InteractionSession' ([ordered]@{actionSentCount=1})
Assert-Throws {Assert-HtsPassiveRecorderArtifactSafety $badAction} 'ACTION_COUNT_NONZERO' 'nonzero action count blocked'
$badVerdict=New-HtsPassiveRecorderEnvelope 'InteractionSession' ([ordered]@{verdictEligible=$true})
Assert-Throws {Assert-HtsPassiveRecorderArtifactSafety $badVerdict} 'DISCOVERY_METADATA_INVALID' 'verdict eligibility blocked'

$schema=Get-Content -LiteralPath (Join-Path $root 'config\schemas\passive-interaction-discovery.schema.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert-Equal 'Discovery' $schema.properties.artifactRole.const 'schema fixes discovery role'
Assert-True (-not[bool]$schema.properties.automated.const) 'schema fixes automated false'
$entrypoint=Get-Content -LiteralPath (Join-Path $root 'targets\1q-hts\0101\scripts\record-order-screen-interactions.ps1') -Raw -Encoding UTF8
Assert-True ($entrypoint-match'PassiveInputObserver') 'target entrypoint uses passive observer'
Assert-True ($entrypoint-match'Get-HtsExactOrderScreenWindow') 'target entrypoint requires exact existing screen'
Assert-True ($entrypoint-notmatch'SetCursorPos|mouse_event|SendInput|keybd_event|Invoke-HtsAction') 'entrypoint contains no injection primitive'
Assert-True ($entrypoint-match"'top-region:left'='order-tab:buy'") '0101 maps generic left top region to buy tab suggestion'
Assert-True ($entrypoint-match"'top-region:center'='order-tab:sell'") '0101 maps generic center top region to sell tab suggestion'
Assert-True ($entrypoint-match"'top-region:right'='order-tab:modify-cancel'") '0101 maps generic right top region to modify/cancel suggestion'
$module=Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-passive-interaction-recorder.ps1') -Raw -Encoding UTF8
$implementationOnly=$module-replace'ResultEvaluatorNotInvoked|resultEvaluatorInvoked|ResultEvaluator|TestResult',''
Assert-True ($implementationOnly-notmatch'Invoke-HtsAction|Click-|Set-AutomationText|ResultEvaluator') 'module contains no action or verdict call'
Write-Output "HTS_PASSIVE_INTERACTION_RECORDER_TESTS=PASS assertions=$script:assertions"
