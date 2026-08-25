$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-layout-inspection.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ASSERT_TRUE failed: $Message"};$script:assertions++}
function Assert-Equal($Expected,$Actual,[string]$Message){if([string]$Expected-ne[string]$Actual){throw "ASSERT_EQUAL failed: $Message expected='$Expected' actual='$Actual'"};$script:assertions++}
function Assert-Throws([scriptblock]$Action,[string]$Pattern,[string]$Message){try{&$Action;throw "ASSERT_THROWS failed: $Message"}catch{if($_.Exception.Message-notmatch$Pattern){throw}};$script:assertions++}
$script:assertions=0
$script:mains=@([pscustomobject]@{hwnd=10;visible=$true;className='MainClass';rawTitle='HTS Main'})
$script:screens=@([pscustomobject]@{hwnd=101;visible=$true;rawTitle='[0101] Order'})
$script:requests=New-Object Collections.Generic.List[object]
$script:writes=@{}
$layout=[pscustomobject]@{
 observedAt='2026-08-25T00:00:00Z';rootBounds=[pscustomobject]@{left=0;top=0;right=1000;bottom=700};dpi=96
 truncated=$false;providerErrorCount=0
 elements=@(
  [pscustomobject]@{elementId='one';isActionable=$true;automationId='query';nativeWindowHandle=11;runtimeId='1.2';controlType='Edit';spatialRegion='QuotePanel';normalizedBounds=[pscustomobject]@{left=.1;top=.2;right=.2;bottom=.3};observedValue=$null;isPassword=$false;valueMasked=$false;redactedName='Query'},
  [pscustomobject]@{elementId='password';isActionable=$true;automationId='password';nativeWindowHandle=12;runtimeId='1.3';controlType='Edit';spatialRegion='OrderEntryPanel';normalizedBounds=[pscustomobject]@{left=.6;top=.2;right=.7;bottom=.3};observedValue=$null;isPassword=$true;valueMasked=$true;redactedName='[REDACTED]'})
}
$context=New-HtsLayoutInspectionContext -SessionContext ([pscustomobject]@{}) -GetTopWindows {@($script:mains)} -GetChildWindows {param([Int64]$Hwnd)@($script:screens)} -InvokeBridgeRequest {
 param($Session,$Request);$script:requests.Add($Request)
 if($Request.operation-eq'observeState'){[pscustomobject]@{success=$true;stateObservation=[pscustomobject]@{rootHwnd=101}}}
 else{[pscustomobject]@{success=$true;layoutDiscovery=$layout}}
} -WriteJson {param([string]$Path,$Value);$script:writes[[IO.Path]::GetFileName($Path)]=$Value}
$profile=[pscustomobject]@{id='1q-hts-0101';window=[pscustomobject]@{className='MainClass';titlePrefix='HTS'}}
$result=Invoke-HtsOrderScreenInspection -Context $context -TargetProfile $profile -ScreenId '0101' -OutputDirectory (Join-Path $root 'fake-output')
Assert-Equal 101 $result.RootHwnd 'exact screen HWND selected'
Assert-Equal 2 $script:requests.Count 'only observeState and discoverLayout requests sent'
Assert-Equal 'observeState' $script:requests[0].operation 'state observation first'
Assert-Equal 'discoverLayout' $script:requests[1].operation 'layout discovery second'
Assert-True (-not$script:requests[1].includeCurrentValues) 'current values excluded'
Assert-Equal 6 $script:writes.Count 'six separated discovery artifacts emitted'
foreach($artifact in $script:writes.Values){
 Assert-Equal 'Discovery' $artifact.artifactRole 'artifact role'
 Assert-True (-not$artifact.verdictEligible) 'not verdict eligible'
 Assert-True (-not$artifact.testExecution) 'not test execution'
 Assert-True (-not$artifact.resultEvaluatorInvoked) 'evaluator not invoked'
 Assert-Equal 'NotExecuted' $artifact.executionStatus 'fixed execution state'
}
Assert-Equal 0 $result.UiActionCount 'UI action count'
Assert-Equal 0 $result.TransactionalActionCount 'transactional action count'
Assert-Equal 'ConfigurationRequired' $script:writes['calibration-session.json'].payload.status 'calibration remains configuration required'
Assert-Equal 'ReviewRequired' $script:writes['control-repository-candidates.json'].payload.status 'candidate review required'
Assert-True (-not$script:writes['control-repository-candidates.json'].payload.automaticallyApproved) 'no automatic approval'
Assert-Equal 0 @($script:writes['scenario-authoring-hints.json'].payload.executableScenarios).Count 'no executable scenario'

$script:mains=@();Assert-Throws {Get-HtsExactOrderScreenWindow -Context $context -MainClassName 'MainClass' -MainTitlePrefix 'HTS' -ScreenId '0101'} 'MAIN_WINDOW_COUNT_INVALID.*actual=0' 'zero main blocked'
$script:mains=@([pscustomobject]@{hwnd=10;visible=$true;className='MainClass';rawTitle='HTS Main'},[pscustomobject]@{hwnd=11;visible=$true;className='MainClass';rawTitle='HTS Other'})
Assert-Throws {Get-HtsExactOrderScreenWindow -Context $context -MainClassName 'MainClass' -MainTitlePrefix 'HTS' -ScreenId '0101'} 'MAIN_WINDOW_COUNT_INVALID.*actual=2' 'multiple main blocked'
$script:mains=@([pscustomobject]@{hwnd=10;visible=$true;className='MainClass';rawTitle='HTS Main'});$script:screens=@()
Assert-Throws {Get-HtsExactOrderScreenWindow -Context $context -MainClassName 'MainClass' -MainTitlePrefix 'HTS' -ScreenId '0101'} 'SCREEN_WINDOW_COUNT_INVALID.*actual=0' 'zero screen blocked'
$script:screens=@([pscustomobject]@{hwnd=101;visible=$true;rawTitle='[0101] One'},[pscustomobject]@{hwnd=102;visible=$true;rawTitle='[0101] Two'})
Assert-Throws {Get-HtsExactOrderScreenWindow -Context $context -MainClassName 'MainClass' -MainTitlePrefix 'HTS' -ScreenId '0101'} 'SCREEN_WINDOW_COUNT_INVALID.*actual=2' 'multiple screen blocked'
$bad=[pscustomobject]@{elements=@([pscustomobject]@{elementId='secret';observedValue='plaintext';isPassword=$true;valueMasked=$false;redactedName='plaintext'})}
Assert-Throws {Assert-HtsDiscoverySensitiveValuesExcluded -Layout $bad} 'SENSITIVE_SCAN_FAILED' 'plaintext sensitive value blocked'
$module=Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-layout-inspection.ps1') -Raw
$policyNeutral=$module-replace'resultEvaluatorInvoked|ResultEvaluatorNotInvoked',''
Assert-True ($policyNeutral-notmatch'ResultEvaluator|TestResult|Invoke-HtsAction|Click-|Set-AutomationText') 'inspection module has no action or verdict owner'
Write-Output "HTS_LAYOUT_INSPECTION_TESTS=PASS assertions=$script:assertions"
