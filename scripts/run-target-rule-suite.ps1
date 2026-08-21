<#
.SYNOPSIS 승인 TestPack 기반 HTS rule-suite orchestration을 시작하는 얇은 CLI 진입점이다.
.DESCRIPTION 공개 인자 계약을 보존하고 실제 단계 조립은 modules/hts-rule-suite-orchestration.ps1에 위임한다.
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
$orchestrationPath = Join-Path $PSScriptRoot 'modules\hts-rule-suite-orchestration.ps1'
& $orchestrationPath @PSBoundParameters
