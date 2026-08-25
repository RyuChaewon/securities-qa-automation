<#
.SYNOPSIS Approved logical, physical, and binding plan loading.
.DESCRIPTION Validates schemas and hashes and never executes a plan or chooses a fallback.
#>

# Loads approved plan artifacts and rejects every incompatible hash or execution scope.
function Resolve-HtsRuleSuitePlans {
    param([Parameter(Mandatory = $true)]$RunSpec)

    $root = [string]$RunSpec.Root
    $runInput = $RunSpec.Input
    $dataset = $RunSpec.Dataset
    $scenarioPlan = $null
    $physicalPlan = $null
    $bindingCatalog = $null
    $bindingCatalogSource = ''
    $scenarioPlanFullPath = ''
    $physicalPlanFullPath = ''
    $executableScenarioCaseIds = @()

    if ($RunSpec.ScenarioMode) {
        $scenarioPlanFullPath = if ([IO.Path]::IsPathRooted([string]$runInput.ScenarioPlanPath)) { [string]$runInput.ScenarioPlanPath } else { Join-Path $root ([string]$runInput.ScenarioPlanPath) }
        if (-not (Test-Path -LiteralPath $scenarioPlanFullPath)) { throw "컴파일된 시나리오 계획을 찾을 수 없습니다: $scenarioPlanFullPath" }
        $scenarioPlan = Get-Content -LiteralPath $scenarioPlanFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$scenarioPlan.datasetId -ne [string]$dataset.datasetId) { throw '시나리오 계획과 기준 데이터셋의 datasetId가 일치하지 않습니다.' }
        if (-not $runInput.PlanOnly) {
            if (-not $runInput.PhysicalPlanPath) { throw '실제 시나리오 실행에는 Binding Plan-only로 생성한 -PhysicalPlanPath가 필요합니다.' }
            $physicalPlanFullPath = if ([IO.Path]::IsPathRooted([string]$runInput.PhysicalPlanPath)) { [string]$runInput.PhysicalPlanPath } else { Join-Path $root ([string]$runInput.PhysicalPlanPath) }
            if (-not (Test-Path -LiteralPath $physicalPlanFullPath)) { throw "물리 실행계획을 찾을 수 없습니다: $physicalPlanFullPath" }
            $physicalPlan = Get-Content -LiteralPath $physicalPlanFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$physicalPlan.schemaVersion -ne '1.1') { throw "지원하지 않는 물리 실행계획 schemaVersion입니다: $([string]$physicalPlan.schemaVersion). 1.1 계획을 다시 생성하세요." }
            if ([string]$physicalPlan.logicalPlanHash -ne [string]$scenarioPlan.planHash) { throw '물리 실행계획이 현재 논리 시나리오 계획과 일치하지 않습니다.' }
            $bindingCatalogSource = Join-Path (Split-Path -Parent $physicalPlanFullPath) 'binding-catalog.json'
            if (-not (Test-Path -LiteralPath $bindingCatalogSource)) { throw "물리 실행계획의 바인딩 카탈로그를 찾을 수 없습니다: $bindingCatalogSource" }
            $bindingCatalog = Get-Content -LiteralPath $bindingCatalogSource -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$bindingCatalog.schemaVersion -ne '1.1') { throw "지원하지 않는 바인딩 카탈로그 schemaVersion입니다: $([string]$bindingCatalog.schemaVersion). 1.1 카탈로그를 다시 생성하세요." }
            $bindingCatalogHash = Get-RuleFileSha256 $bindingCatalogSource
            if (-not [string]::Equals($bindingCatalogHash, [string]$physicalPlan.bindingCatalogHash, [StringComparison]::OrdinalIgnoreCase)) { throw '바인딩 카탈로그 파일 해시가 물리 실행계획과 일치하지 않습니다.' }
            if ([string]$bindingCatalog.planHash -ne [string]$scenarioPlan.planHash) { throw '바인딩 카탈로그가 현재 논리 시나리오 계획에서 생성되지 않았습니다.' }
            if ([string]$bindingCatalog.sourceInstallationFingerprint -ne [string]$bindingCatalog.runtimeInstallationFingerprint) { throw '바인딩 카탈로그의 소스/런타임 HTS 설치 fingerprint가 일치하지 않습니다.' }
            foreach ($fixedBinding in @($physicalPlan.resolvedBindings)) {
                $catalogBinding = @($bindingCatalog.screens | Where-Object { [string]$_.screenNumber -eq [string]$fixedBinding.screenNumber } | ForEach-Object { @($_.controls) } | Where-Object {
                    [string]$_.bindingKey -eq [string]$fixedBinding.requirementBindingKey -and [bool]$_.executionEligible
                })
                $catalogCandidate = @($catalogBinding | ForEach-Object { @($_.candidates) } | Where-Object {
                    [bool]$_.runtimeActionable -and [string]$_.controlId -eq [string]$fixedBinding.controlId -and [string]$_.locatorSignature -eq [string]$fixedBinding.locatorSignature
                })
                if ($catalogBinding.Count -ne 1 -or $catalogCandidate.Count -ne 1) {
                    throw "물리 실행계획의 고정 바인딩이 카탈로그의 유일한 실행 후보와 일치하지 않습니다: $([string]$fixedBinding.scenarioId)/$([string]$fixedBinding.requirementBindingKey)"
                }
            }
            if ([string]$physicalPlan.status -ne 'READY' -and -not $runInput.AllowPartialScenarioPlan) {
                throw "물리 실행계획 상태가 READY가 아닙니다: $([string]$physicalPlan.status). 부분 실행은 -AllowPartialScenarioPlan을 명시해야 합니다."
            }
            $executableScenarioCaseIds = @($physicalPlan.executableCaseIds | ForEach-Object { [string]$_ })
        }
    }

    if ($RunSpec.RequestedScenarioCaseIds.Count -gt 0 -and -not $RunSpec.ScenarioMode) { throw '-CaseIdsCsv는 -ScenarioPlanPath와 함께 사용해야 합니다.' }
    if ($RunSpec.RequestedScenarioCaseIds.Count -gt 0) {
        $knownScenarioCaseIds = @($scenarioPlan.cases | ForEach-Object { [string]$_.caseId })
        $unknownRequestedCaseIds = @($RunSpec.RequestedScenarioCaseIds | Where-Object { $knownScenarioCaseIds -notcontains $_ })
        if ($unknownRequestedCaseIds.Count -gt 0) { throw "시나리오 계획에 없는 caseId가 요청되었습니다: $($unknownRequestedCaseIds -join ', ')" }
        if (-not $runInput.PlanOnly) {
            $unboundRequestedCaseIds = @($RunSpec.RequestedScenarioCaseIds | Where-Object { $executableScenarioCaseIds -notcontains $_ })
            if ($unboundRequestedCaseIds.Count -gt 0) { throw "물리 실행계획에서 실행 불가능한 caseId가 요청되었습니다: $($unboundRequestedCaseIds -join ', ')" }
        }
    }

    $RunSpec.ScenarioPlan = $scenarioPlan
    $RunSpec.PhysicalPlan = $physicalPlan
    $RunSpec.BindingCatalog = $bindingCatalog
    $RunSpec.BindingCatalogSource = $bindingCatalogSource
    $RunSpec.ScenarioPlanFullPath = $scenarioPlanFullPath
    $RunSpec.PhysicalPlanFullPath = $physicalPlanFullPath
    $RunSpec.ExecutableScenarioCaseIds = $executableScenarioCaseIds
    $RunSpec
}

# Builds the read-only MAP baseline used by discovery and records initialization evidence.
function Initialize-HtsRuleSuiteMapModels {
    param([Parameter(Mandatory = $true)]$RunSpec)

    $dataset = $RunSpec.Dataset
    $mapCatalog = $null
    $mapInitializationIssue = ''
    $mapConfig = $dataset.autoExploration.mapBaseline
    if ($mapConfig -and [bool]$mapConfig.enabled) {
        $mapScreenDirectory = $RunSpec.TargetContext.ScreenDirectory
        $installationRoot = $RunSpec.TargetContext.InstallationRoot
        $mapCatalogPath = Join-Path $RunSpec.ReportDir 'map-screen-models.json'
        $enabledMapScreens = @($dataset.screens | Where-Object enabled -ne $false | ForEach-Object { [string]$_.screenNumber })
        if ($RunSpec.Input.ScreensCsv) { $requestedMapScreens = @(([string]$RunSpec.Input.ScreensCsv).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $enabledMapScreens -contains $_ }) } else { $requestedMapScreens = $enabledMapScreens }
        $mapScreensCsv = $requestedMapScreens -join ','
        try {
            $mapArgs = @('run', '--project', $RunSpec.CliProject, '-c', 'Release', '--no-build', '--', 'extract-map-models', '--screen-dir', $mapScreenDirectory, '--installation-root', $installationRoot, '--screens', $mapScreensCsv, '--file-pattern', $RunSpec.TargetContext.MapFilePattern, '--out', $mapCatalogPath)
            if ($RunSpec.TargetContext.MapFamilyFiles.Count -gt 0) { $mapArgs += @('--family-files', ($RunSpec.TargetContext.MapFamilyFiles -join ',')) }
            & dotnet @mapArgs | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $mapCatalogPath)) { throw 'MAP 모델 추출 명령이 결과 파일을 생성하지 못했습니다.' }
            $mapCatalog = Get-Content -LiteralPath $mapCatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (@($mapCatalog.missingScreens).Count -gt 0) { $mapInitializationIssue = 'MAP 파일 누락: ' + (@($mapCatalog.missingScreens) -join ', ') }
            $integrityFailures = @($mapCatalog.integrityEntries | Where-Object { [string]$_.status -ne 'MATCH' })
            if ($integrityFailures.Count -gt 0) { $mapInitializationIssue = "HTS 설치 무결성 불일치: $($integrityFailures.Count)개" }
        } catch {
            $mapInitializationIssue = "MAP 기준 모델 초기화 실패: $($_.Exception.Message)"
        }
    }
    $RunSpec.MapCatalog = $mapCatalog
    $RunSpec.MapInitializationIssue = $mapInitializationIssue
    $RunSpec
}
