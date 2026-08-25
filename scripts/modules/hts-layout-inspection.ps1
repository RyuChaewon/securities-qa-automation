<# Read-only order-screen layout inspection orchestration. #>
# Creates an explicit dependency-injected context without global mutable state.
function New-HtsLayoutInspectionContext {
 param([Parameter(Mandatory=$true)]$SessionContext,[Parameter(Mandatory=$true)][scriptblock]$GetTopWindows,[Parameter(Mandatory=$true)][scriptblock]$GetChildWindows,[Parameter(Mandatory=$true)][scriptblock]$InvokeBridgeRequest,[scriptblock]$WriteJson={param([string]$Path,$Value);$parent=Split-Path -Parent $Path;if($parent-and-not(Test-Path -LiteralPath $parent)){[void](New-Item -ItemType Directory -Path $parent -Force)};$Value|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $Path -Encoding UTF8})
 [pscustomobject]@{SessionContext=$SessionContext;Dependencies=[pscustomobject]@{GetTopWindows=$GetTopWindows;GetChildWindows=$GetChildWindows;InvokeBridgeRequest=$InvokeBridgeRequest;WriteJson=$WriteJson}}
}
# Requires exactly one existing main window and one existing screen window; never opens a screen.
function Get-HtsExactOrderScreenWindow {
 param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)][string]$MainClassName,[Parameter(Mandatory=$true)][string]$MainTitlePrefix,[Parameter(Mandatory=$true)][string]$ScreenId)
 $mains=@(& $Context.Dependencies.GetTopWindows|Where-Object{$_.visible-and[string]$_.className-eq$MainClassName-and([string]$_.rawTitle).StartsWith($MainTitlePrefix)})
 if($mains.Count-ne 1){throw "LAYOUT_MAIN_WINDOW_COUNT_INVALID expected=1 actual=$($mains.Count)"}
 $main=$mains[0];$screenPattern='^\['+[regex]::Escape($ScreenId)+'\]'
 $screens=@(& $Context.Dependencies.GetChildWindows ([Int64]$main.hwnd)|Where-Object{$_.visible-and[string]$_.rawTitle-match$screenPattern})
 if($screens.Count-ne 1){throw "LAYOUT_SCREEN_WINDOW_COUNT_INVALID screen=$ScreenId expected=1 actual=$($screens.Count)"}
 [pscustomobject]@{Main=$main;Screen=$screens[0]}
}
# Wraps observation data with fixed non-test and non-verdict metadata.
function New-HtsDiscoveryEnvelope { param([string]$Kind,$Payload);[ordered]@{schemaVersion='1.0';artifactRole='Discovery';artifactKind=$Kind;verdictEligible=$false;testExecution=$false;resultEvaluatorInvoked=$false;scenarioId=$null;caseId=$null;canonicalVerdict=$null;executionStatus='NotExecuted';verdictStatus='NoCanonicalVerdict';evaluatorStatus='ResultEvaluatorNotInvoked';payload=$Payload} }
# Fails closed if any current value or unredacted password metadata reaches output.
function Assert-HtsDiscoverySensitiveValuesExcluded {
 param([Parameter(Mandatory=$true)]$Layout)
 foreach($element in @($Layout.elements)){
  if($null-ne$element.observedValue-and[string]$element.observedValue-ne''){throw "LAYOUT_SENSITIVE_SCAN_FAILED element=$($element.elementId) observedValue must be absent"}
  if($element.isPassword-and(-not$element.valueMasked-or[string]$element.redactedName-notin@('','[REDACTED]'))){throw "LAYOUT_SENSITIVE_SCAN_FAILED element=$($element.elementId) password metadata is not redacted"}
 }
}
# Sends only observeState and discoverLayout, then writes separated local Discovery artifacts.
function Invoke-HtsOrderScreenInspection {
 param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)]$TargetProfile,[Parameter(Mandatory=$true)][string]$ScreenId,[Parameter(Mandatory=$true)][string]$OutputDirectory,[int]$TimeoutMs=10000,[int]$MaxDepth=16,[int]$MaxElements=5000)
 $selected=Get-HtsExactOrderScreenWindow -Context $Context -MainClassName ([string]$TargetProfile.window.className) -MainTitlePrefix ([string]$TargetProfile.window.titlePrefix) -ScreenId $ScreenId
 $rootHwnd=[Int64]$selected.Screen.hwnd
 $state=& $Context.Dependencies.InvokeBridgeRequest $Context.SessionContext ([ordered]@{requestId=[Guid]::NewGuid().ToString('N');operation='observeState';rootHwnd=$rootHwnd})
 if(-not$state.success){throw "LAYOUT_STATE_OBSERVATION_FAILED code=$($state.errorCode) message=$($state.message)"}
 $regions=@(
  [ordered]@{region='GlobalHeader';left=0.0;top=0.0;right=1.0;bottom=0.12;priority=20},
  [ordered]@{region='QuotePanel';left=0.0;top=0.12;right=0.5;bottom=0.62;priority=10},
  [ordered]@{region='OrderEntryPanel';left=0.5;top=0.12;right=1.0;bottom=0.62;priority=10},
  [ordered]@{region='TradeInfoPanel';left=0.0;top=0.62;right=1.0;bottom=1.0;priority=10})
 $sensitiveHints=@(
  [ordered]@{namePattern='계좌|account';sensitiveKind='Account'},
  [ordered]@{namePattern='비밀번호|password|passwd';sensitiveKind='Password'},
  [ordered]@{namePattern='고객|사용자|user.?id|customer';sensitiveKind='Identity'},
  [ordered]@{namePattern='인증|token|auth';sensitiveKind='Authentication'})
 $layoutResponse=& $Context.Dependencies.InvokeBridgeRequest $Context.SessionContext ([ordered]@{requestId=[Guid]::NewGuid().ToString('N');operation='discoverLayout';rootHwnd=$rootHwnd;timeoutMs=$TimeoutMs;maxDepth=$MaxDepth;maxElements=$MaxElements;includeCurrentValues=$false;includeValueMetadata=$true;includeOffscreen=$false;includeInvisible=$false;includeContainers=$true;regionHints=$regions;sensitiveControlHints=$sensitiveHints})
 if(-not$layoutResponse.success){throw "LAYOUT_DISCOVERY_FAILED code=$($layoutResponse.errorCode) message=$($layoutResponse.message)"}
 $layout=$layoutResponse.layoutDiscovery;Assert-HtsDiscoverySensitiveValuesExcluded -Layout $layout
 $candidates=@($layout.elements|Where-Object{$_.isActionable-or$_.automationId-or$_.nativeWindowHandle-ne 0}|ForEach-Object{
  [ordered]@{repositoryKey=$null;configurationStatus='ConfigurationRequired';approvalStatus='Unapproved';executable=$false;elementId=$_.elementId;stateContext='ConfigurationRequired';spatialRegion=$_.spatialRegion;automationId=$_.automationId;runtimeIdCandidate=$_.runtimeId;nativeWindowHandleCandidate=$_.nativeWindowHandle;controlType=$_.controlType;bounds=$_.normalizedBounds;evidenceReference='control-discovery-results.json'}
 })
 $regionCounts=@($layout.elements|Group-Object spatialRegion|ForEach-Object{[ordered]@{region=$_.Name;controlCount=$_.Count}})
 $common=[ordered]@{targetId=$TargetProfile.id;screenId=$ScreenId;rootHwnd=$rootHwnd;observedAt=$layout.observedAt;actionSentCount=0;transactionalActionCount=0;configurationStatus='ConfigurationRequired'}
 $artifacts=[ordered]@{
  'screen-layout-observation.json'=New-HtsDiscoveryEnvelope 'ScreenLayoutObservation' ([ordered]@{context=$common;regions=$regionCounts;rootBounds=$layout.rootBounds;dpi=$layout.dpi})
  'control-discovery-results.json'=New-HtsDiscoveryEnvelope 'ControlDiscoveryResults' $layout
  'state-observation-results.json'=New-HtsDiscoveryEnvelope 'StateObservationResults' ([ordered]@{context=$common;observation=$state.stateObservation;stateIdentity='ConfigurationRequired'})
  'calibration-session.json'=New-HtsDiscoveryEnvelope 'CalibrationSessionCandidate' ([ordered]@{context=$common;status='ConfigurationRequired';reviewer=$null;approvalStatus='Unapproved';observations=@();repositoryApplied=$false})
  'control-repository-candidates.json'=New-HtsDiscoveryEnvelope 'ControlRepositoryCandidates' ([ordered]@{context=$common;status='ReviewRequired';automaticallyApproved=$false;candidates=$candidates})
  'scenario-authoring-hints.json'=New-HtsDiscoveryEnvelope 'ScenarioAuthoringHints' ([ordered]@{context=$common;status='ConfigurationRequired';regions=$regionCounts;hints=@();executableScenarios=@()})
 }
 $fullOutput=[IO.Path]::GetFullPath($OutputDirectory)
 foreach($entry in $artifacts.GetEnumerator()){& $Context.Dependencies.WriteJson (Join-Path $fullOutput $entry.Key) $entry.Value}
 [pscustomobject]@{OutputDirectory=$fullOutput;RootHwnd=$rootHwnd;ElementCount=@($layout.elements).Count;CandidateCount=$candidates.Count;Truncated=[bool]$layout.truncated;ProviderErrorCount=[int]$layout.providerErrorCount;UiActionCount=0;TransactionalActionCount=0;ArtifactFiles=@($artifacts.Keys)}
}
