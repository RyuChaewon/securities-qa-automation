<#
.SYNOPSIS 논리 시나리오의 logicalName을 현재 HTS 컨트롤에 Plan-only로 바인딩한다.
.DESCRIPTION 화면은 열어 컨트롤을 발견하지만 시나리오 입력·선택·클릭은 수행하지 않고 물리 계획만 만든다.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$CompiledPlanPath,
    [Parameter(Mandatory = $true)]
    [string]$TestPackPath,
    [string]$ReportDir = "",
    [string]$ScreensCsv = "",
    [string]$RuntimeControlPlanPath = "",
    [string]$RuntimeSummaryPath = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "modules\pipeline-common.ps1")
$pipelineManifest = Get-RulePipelineManifest $root
$cliProject = Resolve-RulePath $root ([string]$pipelineManifest.cliProject)

# 컴파일 계획과 승인 TestPack의 식별자를 비교해 서로 다른 실행 묶음이 섞이지 않게 한다.
$planPath = Resolve-RulePath $root $CompiledPlanPath
$testPackFullPath = Resolve-RulePath $root $TestPackPath
if (-not (Test-Path -LiteralPath $planPath)) { throw "컴파일 계획을 찾을 수 없습니다: $planPath" }
if (-not (Test-Path -LiteralPath $testPackFullPath)) { throw "승인 TestPack을 찾을 수 없습니다: $testPackFullPath" }
& dotnet run --project $cliProject -c Release --no-build -- validate-test-pack --file $testPackFullPath | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'TestPack 무결성 또는 승인 검증에 실패했습니다.' }

$plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
$testPack = Get-Content -LiteralPath $testPackFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$testPack.approval.status -ne 'Approved') { throw '바인딩 계획은 Approved TestPack만 사용할 수 있습니다.' }
$dataset = $testPack.datasetSnapshot
if ([string]$plan.datasetId -ne [string]$dataset.datasetId) {
    throw "컴파일 계획의 datasetId와 TestPack datasetSnapshot이 일치하지 않습니다."
}

if (-not $ReportDir) {
    $ReportDir = Join-Path (Join-Path $root "artifacts\bindings") ("$([string]$plan.planId)-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
} else {
    $ReportDir = Resolve-RulePath $root $ReportDir
}
$ReportDir = [IO.Path]::GetFullPath($ReportDir)
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

$planScreens = @($plan.screens | ForEach-Object { [string]$_.screenNumber })
$requestedScreens = @($ScreensCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$targetScreens = if ($requestedScreens.Count -gt 0) {
    @($planScreens | Where-Object { $requestedScreens -contains $_ })
} else { $planScreens }
if ($targetScreens.Count -eq 0) { throw "바인딩을 확인할 대상 화면이 없습니다." }

$runtimeDir = Join-Path $ReportDir "runtime-discovery"
$reuseRuntimeEvidence = [bool]$RuntimeControlPlanPath -or [bool]$RuntimeSummaryPath
if ($reuseRuntimeEvidence -and (-not $RuntimeControlPlanPath -or -not $RuntimeSummaryPath)) {
    throw "런타임 증거를 재사용하려면 -RuntimeControlPlanPath와 -RuntimeSummaryPath를 함께 지정해야 합니다."
}
if ($reuseRuntimeEvidence) {
    $sourceControlPlanPath = Resolve-RulePath $root $RuntimeControlPlanPath
    $sourceRuntimeSummaryPath = Resolve-RulePath $root $RuntimeSummaryPath
    if (-not (Test-Path -LiteralPath $sourceControlPlanPath -PathType Leaf)) { throw "재사용할 control-plan.json을 찾을 수 없습니다: $sourceControlPlanPath" }
    if (-not (Test-Path -LiteralPath $sourceRuntimeSummaryPath -PathType Leaf)) { throw "재사용할 summary.json을 찾을 수 없습니다: $sourceRuntimeSummaryPath" }
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    $controlPlanPath = Join-Path $runtimeDir "control-plan.json"
    $runtimeSummaryPath = Join-Path $runtimeDir "summary.json"
    Copy-Item -LiteralPath $sourceControlPlanPath -Destination $controlPlanPath -Force
    Copy-Item -LiteralPath $sourceRuntimeSummaryPath -Destination $runtimeSummaryPath -Force
} else {
    $runner = Get-RulePipelineEntryPoint $pipelineManifest $root 'targetRunner'
    # 현재 HTS를 plan-only로 관찰해 컨트롤 후보와 설치 fingerprint를 수집한다.
    & $runner `
        -TestPackPath $testPackFullPath `
        -ReportDir $runtimeDir `
        -ScreensCsv ($targetScreens -join ',') `
        -MaxCases ([int]$testPack.maxCases) `
        -PlanOnly `
        -SkipExcel | Out-Null
    $runtimeSummaryPath = Join-Path $runtimeDir "summary.json"
    $controlPlanPath = Join-Path $runtimeDir "control-plan.json"
}
if (-not (Test-Path -LiteralPath $runtimeSummaryPath) -or -not (Test-Path -LiteralPath $controlPlanPath)) {
    throw "런타임 바인딩 Plan-only 결과가 생성되지 않았습니다: $runtimeDir"
}
$runtimeSummary = Get-Content -LiteralPath $runtimeSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
$runtimeFingerprint = [string]$runtimeSummary.installationFingerprint
$summaryPath = Join-Path $ReportDir "binding-plan-summary.json"
if ([string]$runtimeSummary.status -eq 'ERROR') {
    [pscustomobject]@{
        mode = "BindingPlanOnly"
        status = "PENDING_RUNTIME_DISCOVERY_ERROR"
        planId = [string]$plan.planId
        targetScreens = $targetScreens
        actualControlActionsExecuted = $false
        runtimeEvidenceReused = $reuseRuntimeEvidence
        runtimeReportDir = $runtimeDir
        note = "Plan-only 런타임 발견에 ERROR가 있어 바인딩 카탈로그와 물리 계획 생성을 중단했습니다."
        generatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Write-Output $ReportDir
    return
}
if (-not $runtimeFingerprint) {
    [pscustomobject]@{
        mode = "BindingPlanOnly"
        status = "PENDING_HTS_NOT_ACCESSIBLE"
        planId = [string]$plan.planId
        targetScreens = $targetScreens
        actualControlActionsExecuted = $false
        runtimeEvidenceReused = $reuseRuntimeEvidence
        runtimeReportDir = $runtimeDir
        note = "HTS 설치 fingerprint를 확보하지 못해 바인딩 카탈로그를 만들지 않았습니다."
        generatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Write-Output $ReportDir
    return
}
if ($runtimeFingerprint -ne [string]$plan.sourceInstallationFingerprint) {
    throw "컴파일 계획과 현재 HTS 설치 fingerprint가 다릅니다. 요청 패키지와 시나리오를 다시 생성해야 합니다."
}

$cliProject = Join-Path $root "src\HtsQa.Cli\HtsQa.Cli.csproj"
$bindingsPath = Join-Path $ReportDir "binding-catalog.json"
$physicalPlanPath = Join-Path $ReportDir "physical-plan.json"
# 논리 컨트롤 ID를 현재 화면에서 재현 가능한 UIA/탭/좌표 후보와 연결한다.
& dotnet run --project $cliProject -c Release --no-build -- materialize-scenario-bindings `
    --plan $planPath `
    --control-plan $controlPlanPath `
    --runtime-fingerprint $runtimeFingerprint `
    --out $bindingsPath | Out-Null
$bindingExitCode = $LASTEXITCODE
if ($bindingExitCode -notin @(0,3) -or -not (Test-Path -LiteralPath $bindingsPath)) {
    throw "바인딩 카탈로그 생성에 실패했습니다. 종료 코드: $bindingExitCode"
}

$activeMapScreenCodes = @($dataset.targetProfile.map.initiallyActiveMapScreenCodes | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } | Where-Object { $_ } | Select-Object -Unique)
$coordinateFocusEnabled = [string]$dataset.autoExploration.interactionStrategy -eq 'CoordinateFocus' -or
    @($plan.cases | Where-Object { [string]$_.executionOrder -eq 'CoordinateFocus' }).Count -gt 0
$stateGatedBindings = 0
if ($coordinateFocusEnabled -and $activeMapScreenCodes.Count -gt 0) {
    $bindingStateCatalog = Get-Content -LiteralPath $bindingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $allStateBindings = @($bindingStateCatalog.screens | ForEach-Object { @($_.controls) })
    foreach ($binding in $allStateBindings) {
        $bindingMapCode = ([string]$binding.mapScreenCode).Trim().ToUpperInvariant()
        if (-not $bindingMapCode -or $activeMapScreenCodes -contains $bindingMapCode) { continue }
        if ([bool]$binding.executionEligible) { $stateGatedBindings++ }
        $binding.status = 'Unbound'
        $binding.confidence = 'Unspecified'
        $binding.executionEligible = $false
        $binding.reason = "MAP $bindingMapCode 는 카탈로그에는 포함되지만 런타임 발견 시 활성 상태가 아니었습니다. 명시적 상태 전환 경로가 필요합니다."
        foreach ($candidate in @($binding.candidates)) {
            $candidate.runtimeActionable = $false
            $candidate.evidence = @($candidate.evidence) + 'FAIL:MAP state is not initially active'
        }
    }
    $bindingStateCatalog.highConfidenceBindings = @($allStateBindings | Where-Object status -eq 'BoundHigh').Count
    $bindingStateCatalog.mediumConfidenceBindings = @($allStateBindings | Where-Object status -eq 'BoundMedium').Count
    $bindingStateCatalog.ambiguousBindings = @($allStateBindings | Where-Object status -eq 'Ambiguous').Count
    $bindingStateCatalog.unboundBindings = @($allStateBindings | Where-Object status -eq 'Unbound').Count
    $bindingStateCatalog.status = if (@($allStateBindings | Where-Object { [bool]$_.required -and -not [bool]$_.executionEligible }).Count -gt 0) { 'INCOMPLETE' } else { 'READY' }
    $bindingStateCatalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $bindingsPath -Encoding UTF8
}

# 실행 가능한 바인딩만 물리 계획으로 확정하고 미해결 항목은 PENDING으로 보존한다.
& dotnet run --project $cliProject -c Release --no-build -- build-physical-scenario-plan `
    --plan $planPath `
    --bindings $bindingsPath `
    --out $physicalPlanPath | Out-Null
$physicalExitCode = $LASTEXITCODE
if ($physicalExitCode -notin @(0,3,4) -or -not (Test-Path -LiteralPath $physicalPlanPath)) {
    throw "물리 실행계획 생성에 실패했습니다. 종료 코드: $physicalExitCode"
}

$bindings = Get-Content -LiteralPath $bindingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$physical = Get-Content -LiteralPath $physicalPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
[pscustomobject]@{
    mode = "BindingPlanOnly"
    status = [string]$physical.status
    planId = [string]$plan.planId
    physicalPlanId = [string]$physical.physicalPlanId
    bindingSchemaVersion = [string]$bindings.schemaVersion
    physicalSchemaVersion = [string]$physical.schemaVersion
    targetScreens = $targetScreens
    initiallyActiveMapScreenCodes = $activeMapScreenCodes
    stateGatedBindings = $stateGatedBindings
    requiredBindings = [int]$bindings.requiredBindings
    highConfidenceBindings = [int]$bindings.highConfidenceBindings
    executionEligibleBindings = @($bindings.screens.controls | Where-Object executionEligible).Count
    mediumConfidenceBindings = [int]$bindings.mediumConfidenceBindings
    ambiguousBindings = [int]$bindings.ambiguousBindings
    unboundBindings = [int]$bindings.unboundBindings
    totalCases = [int]$physical.totalCases
    executableCases = [int]$physical.executableCases
    resolvedBindings = @($physical.resolvedBindings).Count
    pendingApprovalCases = [int]$physical.pendingApprovalCases
    pendingBindingCases = [int]$physical.pendingBindingCases
    actualControlActionsExecuted = $false
    runtimeEvidenceReused = $reuseRuntimeEvidence
    runtimeReportDir = $runtimeDir
    bindingCatalog = $bindingsPath
    physicalPlan = $physicalPlanPath
    note = "화면 열기와 컨트롤 발견·MAP 결합만 수행했습니다. 활성 MAP의 전용 호스트, host-local 좌표·크기, 런타임 식별자 무충돌, 조작 종류 또는 정확한 owner-drawn MAP geometry를 모두 통과한 유일 후보만 물리 실행 대상으로 고정했습니다."
    generatedAt = (Get-Date).ToString('o')
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Output $ReportDir
