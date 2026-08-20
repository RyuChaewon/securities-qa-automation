<# .SYNOPSIS Regression tests for explicit HTS discovery context and raw UIA snapshots. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-discovery.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_TRUE failed: $Message" }
    $script:assertions++
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) {
        throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'"
    }
    $script:assertions++
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    try {
        & $Action
        throw "ASSERT_THROWS failed: $Message"
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
    }
    $script:assertions++
}

$script:assertions = 0
$screen = [pscustomobject]@{hwnd=71;pid=9}
$session = [pscustomobject]@{Name='fake-session'}
$element = [pscustomobject]@{
    nativeWindowHandle=72;isEnabled=$true;controlType='ControlType.Edit';className='Edit';name='검색어'
    runtimeId='1.2.3';automationId='query';supportedActions=@('setValue');options=@();selectedIndex=$null
    currentValue='';minimum=$null;maximum=$null
    bounds=[pscustomobject]@{left=10;top=20;right=110;bottom=40;width=100;height=20}
}
$dependencies = [pscustomobject]@{
    InvokeBridgeRequest = { param($Context, $Request) [pscustomobject]@{success=$true;elements=@($element)} }
    GetMapScreenModel = { param([string]$ScreenNumber, [string]$MapScreenCode) [pscustomobject]@{screenNumber=$ScreenNumber;screenCode=$MapScreenCode} }
    GetRuleDiscoveredControls = { param($Target, [string]$ScreenNumber, [hashtable]$Claimed) @([pscustomobject]@{screenNumber=$ScreenNumber;claimed=$Claimed.Count}) }
}
$context = New-HtsDiscoveryContext -SessionContext $session -Dependencies $dependencies

$controls = @(Get-HtsFlaUiActionableControls -Context $context -Screen $screen)
Assert-Equal 1 $controls.Count 'successful discovery returns one raw control'
Assert-Equal 'UIA:Edit' $controls[0].className 'control type is normalized without evaluation'
Assert-Equal 1 $context.Metrics.FlaUiDiscoveryCalls 'discovery call metric increments'
Assert-Equal 1 $context.Metrics.FlaUiElementsDiscovered 'discovered element metric increments'

$model = Get-HtsDiscoveryMapScreenModel -Context $context -ScreenNumber '0714' -MapScreenCode 'HT0714'
Assert-Equal 'HT0714' $model.screenCode 'MAP lookup is delegated through the explicit context'
$ruleControls = @(Get-HtsDiscoveredControls -Context $context -Screen $screen -ScreenNumber '0714' -ClaimedHwnds @{72=$true})
Assert-Equal 1 $ruleControls[0].claimed 'rule discovery receives the claimed HWND map'

$failureContext = New-HtsDiscoveryContext -SessionContext $session -Dependencies ([pscustomobject]@{
    InvokeBridgeRequest = { param($Context, $Request) [pscustomobject]@{success=$false;errorCode='FAKE_DISCOVERY_FAILURE';elements=@()} }
})
$failed = @(Get-HtsFlaUiActionableControls -Context $failureContext -Screen $screen)
Assert-Equal 0 $failed.Count 'failed discovery returns an empty raw snapshot'
Assert-Equal 1 $failureContext.Metrics.FlaUiFallbackRequests 'failed discovery records a fallback request'
Assert-True ($failureContext.Metrics.FlaUiFallbackReasons.Contains('discover:FAKE_DISCOVERY_FAILURE')) 'fallback reason is retained once'

$missing = New-HtsDiscoveryContext -SessionContext $session -Dependencies ([pscustomobject]@{})
Assert-Throws { Get-HtsDiscoveryMapScreenModel -Context $missing -ScreenNumber '0714' } 'dependency' 'missing MAP dependency is a contract error'

$moduleText = Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-discovery.ps1') -Raw
Assert-True ($moduleText -notmatch '\$script:|\$global:') 'discovery module has no global or script-scoped runtime state'
Assert-True ($moduleText -notmatch 'TestResult|ResultEvaluator|Set-Content|Add-Content') 'discovery module cannot evaluate or report results'

Write-Output "HTS_DISCOVERY_TESTS=PASS assertions=$script:assertions"
