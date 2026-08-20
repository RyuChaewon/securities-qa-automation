<# .SYNOPSIS Regression tests for explicit HTS action context and UIA3 fallback semantics. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-discovery.ps1')
. (Join-Path $root 'scripts\modules\hts-action.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_TRUE failed: $Message" }
    $script:assertions++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) { throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'" }
    $script:assertions++
}

$script:assertions = 0
$script:bridgeMode = 'success'
$script:lastRequest = $null
$script:audits = New-Object Collections.Generic.List[object]
$script:adapterCalls = New-Object Collections.Generic.List[string]
$window = [pscustomobject]@{
    hwnd=72;rawTitle='조회';className='UIA:Button';uiaClassName='Button';uiaRuntimeId='1.2';automationId='query';uiaControlType='ControlType.Button'
    rect=[pscustomobject]@{left=10;top=20;right=110;bottom=40;width=100;height=20}
}
$metrics = New-HtsDiscoveryMetrics
$dependencies = [pscustomobject]@{
    AssertClickScope = { param($Window,[int]$X,[int]$Y) if($X -ne 60 -or $Y -ne 30){throw 'unexpected point'} }
    GetActiveInputSurface = { [pscustomobject]@{hwnd=71} }
    InvokeBridgeRequest = {
        param($Session,$Request)
        $script:lastRequest = $Request
        if($script:bridgeMode -eq 'throw'){throw 'fake bridge exception'}
        if($script:bridgeMode -eq 'fallback'){return [pscustomobject]@{success=$false;verified=$false;errorCode='PATTERN_UNAVAILABLE';message='fallback';pattern=''}}
        [pscustomobject]@{success=$true;verified=$true;errorCode='';message='ok';pattern='Invoke'}
    }
    WriteInputAudit = { param([string]$Type,[string]$Status,[int]$X,[int]$Y,[string]$Detail) [void]$script:audits.Add([pscustomobject]@{type=$Type;status=$Status;detail=$Detail}) }
    InvokeRuleControlPlanItem = { param($Navigation,$Screen,$PlanItem) [void]$script:adapterCalls.Add('plan'); [pscustomobject]@{status='SUCCEEDED';planItem=$PlanItem} }
    InvokeRuleDatasetVariable = { param($Window,[string]$Kind,[string]$Value,[string]$Match,[int]$Max) [void]$script:adapterCalls.Add("dataset:${Kind}:${Value}"); $true }
}
$context = New-HtsActionContext -SessionContext ([pscustomobject]@{name='fake'}) -Metrics $metrics -Dependencies $dependencies

$success = Invoke-HtsFlaUiControlAction -Context $context -Window $window -Action 'selectIndex' -Index 2
Assert-True ([bool]$success.success -and [bool]$success.verified) 'verified bridge result is returned unchanged'
Assert-Equal 1 $metrics.FlaUiActionAttempts 'action attempt metric increments'
Assert-Equal 1 $metrics.FlaUiActionSuccesses 'verified action success metric increments'
Assert-Equal 2 $script:lastRequest.index 'optional selector index is preserved'
Assert-Equal 71 $script:lastRequest.rootHwnd 'action is scoped to the explicit input surface'
Assert-Equal 'ALLOWED' $script:audits[0].status 'verified action writes an allowed audit event'

$script:bridgeMode = 'fallback'
$fallback = Invoke-HtsFlaUiControlAction -Context $context -Window $window -Action 'invoke'
Assert-Equal 'PATTERN_UNAVAILABLE' $fallback.errorCode 'unverified bridge result remains a raw fallback result'
Assert-Equal 1 $metrics.FlaUiFallbackRequests 'fallback metric increments without judging a test result'
Assert-True ($metrics.FlaUiFallbackReasons.Contains('invoke:PATTERN_UNAVAILABLE')) 'fallback reason is retained'

$script:bridgeMode = 'throw'
$exception = Invoke-HtsFlaUiControlAction -Context $context -Window $window -Action 'setText' -Value 'sample'
Assert-Equal 'UIA3_BRIDGE_EXCEPTION' $exception.errorCode 'bridge exception is an action infrastructure result'
Assert-Equal 2 $metrics.FlaUiFallbackRequests 'bridge exception also records fallback need'

$beforeAttempts = $metrics.FlaUiActionAttempts
$hotspot = Invoke-HtsFlaUiControlAction -Context $context -Window ([pscustomobject]@{className='ConfiguredVisualHotspot'}) -Action 'invoke'
Assert-Equal 'VISUAL_HOTSPOT_REQUIRES_COORDINATE' $hotspot.errorCode 'visual hotspot requires the existing coordinate path'
Assert-Equal $beforeAttempts $metrics.FlaUiActionAttempts 'visual hotspot does not claim a UIA action attempt'

$planResult = Invoke-HtsRuleControlPlanAction -Context $context -NavigationContext ([pscustomobject]@{}) -Screen ([pscustomobject]@{}) -PlanItem ([pscustomobject]@{id='p1'})
Assert-Equal 'SUCCEEDED' $planResult.status 'rule control execution is delegated through Action context'
$datasetResult = Invoke-HtsDatasetVariableAction -Context $context -Window $window -ControlKind 'Text' -Value 'abc' -ValueMatch 'Exact'
Assert-True $datasetResult 'dataset variable execution is delegated through Action context'
Assert-True ($script:adapterCalls.Contains('plan') -and $script:adapterCalls.Contains('dataset:Text:abc')) 'both rule action adapters were invoked'

$moduleText = Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-action.ps1') -Raw
Assert-True ($moduleText -notmatch '\$script:|\$global:') 'action module has no global or script-scoped runtime state'
Assert-True ($moduleText -notmatch 'ResultEvaluator|TestResult|Set-Content|Add-Content') 'action module cannot evaluate or report results'

Write-Output "HTS_ACTION_TESTS=PASS assertions=$script:assertions"
