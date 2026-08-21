<# .SYNOPSIS Regression tests for explicit HTS logical-to-physical binding. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-discovery.ps1')
. (Join-Path $root 'scripts\modules\hts-binding.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_TRUE failed: $Message" }
    $script:assertions++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) { throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'" }
    $script:assertions++
}

$script:assertions = 0
$screen = [pscustomobject]@{hwnd=1;pid=7;rect=[pscustomobject]@{left=100;top=100;width=600;height=400}}
function New-FakeWindow([Int64]$Hwnd,[string]$Class,[string]$Title,[int]$Top,[Int64]$Style=0) {
    [pscustomobject]@{hwnd=$Hwnd;visible=$true;enabled=$true;className=$Class;rawTitle=$Title;style=$Style;enumerationIndex=[int]$Hwnd;rect=[pscustomobject]@{left=120;top=$Top;right=320;bottom=$Top+24;width=200;height=24}}
}
$account = New-FakeWindow 10 'Edit' '계좌번호' 130
$password = New-FakeWindow 11 'Edit' '' 170 0x20
$query = New-FakeWindow 12 'Button' '조회' 210
$children = @($account,$password,$query)
$uiaQuery = [pscustomobject]@{
    nativeWindowHandle=0;isEnabled=$true;controlType='ControlType.Button';className='Button';name='조회'
    runtimeId='uia-query';automationId='query';supportedActions=@('invoke');options=@();selectedIndex=$null;currentValue='';minimum=$null;maximum=$null
    bounds=[pscustomobject]@{left=120;top=210;right=320;bottom=234;width=200;height=24}
}
$discoveryContext = New-HtsDiscoveryContext -SessionContext ([pscustomobject]@{}) -Dependencies ([pscustomobject]@{
    InvokeBridgeRequest = { param($Context,$Request) [pscustomobject]@{success=$true;elements=@($uiaQuery)} }
})
$bindingContext = New-HtsBindingContext -DiscoveryContext $discoveryContext -Dependencies ([pscustomobject]@{
    GetChildWindows = { param([Int64]$Hwnd) @($children) }
    TestControlExecutionEligible = { param($Control) [bool]$Control.executionEligible }
})

Assert-True (Test-HtsBindingRegion $account $screen 'top') 'top region matches an upper control'
Assert-True (-not (Test-HtsBindingRegion $account $screen 'bottom')) 'top control does not match bottom region'
$resolvedAccount = Resolve-HtsRoleControl -Context $bindingContext -Screen $screen -Role 'account' -Strategies @([pscustomobject]@{className='Edit';nameRegex='계좌';relativeRegion='top'})
Assert-Equal 10 $resolvedAccount.hwnd 'account locator resolves the unique matching HWND'
$resolvedPassword = Resolve-HtsRoleControl -Context $bindingContext -Screen $screen -Role 'password' -Strategies @([pscustomobject]@{className='Edit';ordinal=0})
Assert-Equal 11 $resolvedPassword.hwnd 'password role requires password style or label'
$hotspot = Resolve-HtsRoleControl -Context $bindingContext -Screen $screen -Role 'visual' -Strategies @([pscustomobject]@{relativeX=50;relativeY=60;width=20;height=10})
Assert-Equal 'ConfiguredVisualHotspot' $hotspot.className 'coordinate locator produces an explicit hotspot binding'

$case = [pscustomobject]@{screen=[pscustomobject]@{locators=[pscustomobject]@{account=@([pscustomobject]@{nameRegex='계좌'});password=@([pscustomobject]@{className='Edit';ordinal=0})}};variables=@{}}
$dataset = [pscustomobject]@{defaultLocators=[pscustomobject]@{};variables=@()}
$claimed = Get-HtsClaimedControlHwndMap -Context $bindingContext -Screen $screen -Case $case -Dataset $dataset
Assert-Equal 2 $claimed.Count 'account and password HWNDs are claimed once'

$control = [pscustomobject]@{controlId='c1';locatorSignature='sig1';automationEngine='FlaUI.UIA3';executionEligible=$true}
$planItem = [pscustomobject]@{scenarioAction='Set';controlLogicalName='Amount';mapScreenCode='HT0714';stateContext='';status='READY';errorCode='';control=$control}
$scenarioCase = [pscustomobject]@{scenarioId='s1'}
$physicalPlan = [pscustomobject]@{resolvedBindings=@([pscustomobject]@{scenarioId='s1';logicalName='Amount';mapScreenCode='HT0714';requiredStateContext='';controlId='c1';locatorSignature='sig1'})}
$bound = Set-HtsScenarioPhysicalBinding -Context $bindingContext -PlanItem $planItem -ScenarioCase $scenarioCase -PhysicalPlan $physicalPlan
Assert-Equal 'READY' $bound.status 'matching approved binding remains ready'
Assert-Equal 'c1' $bound.physicalBinding.controlId 'matching physical binding is attached to the plan item'

$driftControl = [pscustomobject]@{controlId='c1';locatorSignature='changed';automationEngine='FlaUI.UIA3';executionEligible=$true}
$driftItem = [pscustomobject]@{scenarioAction='Set';controlLogicalName='Amount';mapScreenCode='HT0714';stateContext='';status='READY';errorCode='';control=$driftControl}
$drift = Set-HtsScenarioPhysicalBinding -Context $bindingContext -PlanItem $driftItem -ScenarioCase $scenarioCase -PhysicalPlan $physicalPlan
Assert-Equal 'PENDING' $drift.status 'identity drift cannot remain executable'
Assert-Equal 'PHYSICAL_BINDING_DRIFT' $drift.errorCode 'identity drift retains the compatibility error code'

$queries = @(Get-HtsRequiredQueryControls -Context $bindingContext -Screen $screen -Strategies @([pscustomobject]@{nameRegex='^조회$';controlType='Button'}))
Assert-Equal 2 $queries.Count 'native and UIA query identities are collected without judging results'

$compiledScreen=[pscustomobject]@{screenNumber='0714';screenName='테스트 화면';enabled=$true}
$compiledDataset=[pscustomobject]@{screens=@($compiledScreen);accounts=@()}
$compiledCases=@(
    [pscustomobject]@{caseId='CASE-B';screenNumber='0714';accountId='a1';accountNumber='111';accountOwner='owner';inputMode='Explicit';passwordSecret=$null;variables=[pscustomobject]@{kind='B'};variableExpectedOutcomes=[pscustomobject]@{}},
    [pscustomobject]@{caseId='CASE-A';screenNumber='0714';accountId='a1';accountNumber='111';accountOwner='owner';inputMode='Explicit';passwordSecret=$null;variables=[pscustomobject]@{kind='A'};variableExpectedOutcomes=[pscustomobject]@{}}
)
$caseBindingContext=New-HtsExecutionCaseContext -Dataset $compiledDataset -TestPack ([pscustomobject]@{cases=$compiledCases})
$executionCases=@(Get-ExecutionCasesFromApprovedPlans -Context $caseBindingContext)
Assert-Equal 2 $executionCases.Count 'approved TestPack cases are all consumed without local expansion'
Assert-Equal 'CASE-B' $executionCases[0].caseId 'approved TestPack case order is preserved'
Assert-Equal 'B' $executionCases[0].variables.kind 'compiled variable values are preserved'
$filteredContext=New-HtsExecutionCaseContext -ScreensCsv '9999' -Dataset $compiledDataset -TestPack ([pscustomobject]@{cases=$compiledCases})
Assert-Equal 0 @(Get-ExecutionCasesFromApprovedPlans -Context $filteredContext).Count 'screen filter does not generate replacement cases'

$moduleText = Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-binding.ps1') -Raw
Assert-True ($moduleText -notmatch '\$script:|\$global:') 'binding module has no global or script-scoped runtime state'
Assert-True ($moduleText -notmatch 'ResultEvaluator|TestResult|Set-Content|Add-Content') 'binding module cannot evaluate or report results'
$orchestrationText=Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-rule-suite-orchestration.ps1') -Raw
Assert-True ($orchestrationText-notmatch'function Get-ExecutionCasesFromApprovedPlans') 'orchestration no longer owns approved case binding'

Write-Output "HTS_BINDING_TESTS=PASS assertions=$script:assertions"
