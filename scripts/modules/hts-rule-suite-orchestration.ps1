<#
.SYNOPSIS 승인 TestPack에 고정된 HTS 화면군과 케이스를 순차적으로 열고 승인된 룰/시나리오 동작을 실행한다.
.DESCRIPTION 모든 입력을 HTS 메인창과 현재 콘텐츠 경계 안으로 제한하고 팝업·로그·응답을 판정해 JSON 증적을 만든다.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TestPackPath,
    [string]$ReportDir = "",
    [string]$ScreensCsv = "",
    [string]$CaseIdsCsv = "",
    [int]$MaxCases = 10000,
    [string]$ScenarioPlanPath = "",
    [string]$PhysicalPlanPath = "",
    [switch]$AllowPartialScenarioPlan,
    [switch]$ReuseExistingTargetScreen,
    [switch]$RequireExistingTargetScreen,
    [switch]$PreserveTargetScreenAfterRun,
    [switch]$VisiblePointerMotion,
    [ValidateRange(0, 3000)]
    [int]$PointerDwellMilliseconds = 0,
    [Alias('OrderTabStateOverride')]
    [string]$TargetStateOverride = '',
    [switch]$SubmitTransactionalDialogs,
    [switch]$DryRun,
    [switch]$PlanOnly,
    [switch]$SkipExcel
)

$ErrorActionPreference = 'Stop'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $scriptsRoot

$moduleNames = @(
    'pipeline-common.ps1'
    'report-sanitization.ps1'
    'result-evaluator.ps1'
    'hts-control-repository.ps1'
    'hts-native.ps1'
    'hts-session.ps1'
    'hts-navigation.ps1'
    'hts-discovery.ps1'
    'hts-state-discovery.ps1'
    'hts-binding.ps1'
    'hts-action.ps1'
    'hts-observation.ps1'
    'hts-safety.ps1'
    'hts-reporting.ps1'
    'hts-runtime-context.ps1'
    'rule-control-exploration.ps1'
    'hts-rule-suite-bootstrap.ps1'
    'hts-rule-suite-plan-loader.ps1'
    'hts-rule-suite-context-factory.ps1'
    'hts-rule-suite-mode-router.ps1'
    'hts-case-action-runner.ps1'
    'hts-case-legacy-runner.ps1'
    'hts-run-result-finalizer.ps1'
    'hts-case-runner.ps1'
    'hts-screen-runner.ps1'
    'hts-run-cleanup.ps1'
)
foreach ($moduleName in $moduleNames) { . (Join-Path $PSScriptRoot $moduleName) }

$inputContract = @{
    TestPackPath = $TestPackPath
    ReportDir = $ReportDir
    ScreensCsv = $ScreensCsv
    CaseIdsCsv = $CaseIdsCsv
    MaxCases = $MaxCases
    ScenarioPlanPath = $ScenarioPlanPath
    PhysicalPlanPath = $PhysicalPlanPath
    AllowPartialScenarioPlan = [bool]$AllowPartialScenarioPlan
    ReuseExistingTargetScreen = [bool]$ReuseExistingTargetScreen
    RequireExistingTargetScreen = [bool]$RequireExistingTargetScreen
    PreserveTargetScreenAfterRun = [bool]$PreserveTargetScreenAfterRun
    VisiblePointerMotion = [bool]$VisiblePointerMotion
    PointerDwellMilliseconds = $PointerDwellMilliseconds
    TargetStateOverride = $TargetStateOverride
    SubmitTransactionalDialogs = [bool]$SubmitTransactionalDialogs
    DryRun = [bool]$DryRun
    PlanOnly = [bool]$PlanOnly
    SkipExcel = [bool]$SkipExcel
}

$runSpec = New-HtsRuleSuiteRunSpec -Root $root -InputContract $inputContract
$runServices = $null
$runState = $null
try {
    [void](Initialize-HtsRuleSuiteBootstrap -RunSpec $runSpec)
    [void](Resolve-HtsRuleSuitePlans -RunSpec $runSpec)
    [void](Initialize-HtsRuleSuiteOutputPaths -RunSpec $runSpec)
    [void](Initialize-HtsRuleSuiteMapModels -RunSpec $runSpec)
    $runServices = New-HtsRuleSuiteRunServices -RunSpec $runSpec
    $runState = New-HtsRuleSuiteRunState -RunSpec $runSpec

    [void](Invoke-HtsRuleSuiteMode `
        -RunSpec $runSpec `
        -RunServices $runServices `
        -RunState $runState `
        -DryRunCoordinator { param($spec, $services, $state) Invoke-HtsRuleSuiteDryRun -RunSpec $spec -RunServices $services -RunState $state } `
        -InitializeRuntime { param($spec, $services, $state) [void](Initialize-HtsRuleSuiteRuntimeServices -RunSpec $spec -RunServices $services) } `
        -PlanOnlyCoordinator { param($spec, $services, $state) Invoke-HtsRuleSuiteScreens -RunSpec $spec -RunServices $services -RunState $state } `
        -ExecuteCoordinator { param($spec, $services, $state) Invoke-HtsRuleSuiteScreens -RunSpec $spec -RunServices $services -RunState $state })
} finally {
    if ($runServices -and $runState) { [void](Invoke-HtsRuleSuiteCleanup -RunServices $runServices -RunState $runState) }
}

if ($runState -and $runState.OutputReady) {
    if (-not $SkipExcel) { Export-HtsRuleResultWorkbooks $runServices.ReportingContext $runSpec.ReportDir }
    Write-Output $runState.OutputPath
}
