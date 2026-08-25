<#
.SYNOPSIS Rule-suite immutable inputs, approved TestPack context, and output paths.
.DESCRIPTION Builds RunSpec without starting UI infrastructure, evaluating evidence, or rendering reports.
#>

# Creates the explicit immutable-input carrier used by every lifecycle phase.
function New-HtsRuleSuiteRunSpec {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][hashtable]$InputContract
    )

    [pscustomobject]@{
        Root = $Root
        Input = [pscustomobject]$InputContract
        PipelineManifest = $null
        CliProject = ''
        ReportExporter = ''
        TcReportExporter = ''
        ResolvedTestPackPath = ''
        TargetContext = $null
        TestPack = $null
        Dataset = $null
        InitiallyActiveMapScreenCodes = @()
        TargetScreenIdRegex = $null
        TargetScreenTitleRegex = $null
        TargetMapScreenCodeRegex = $null
        ScenarioMode = $false
        ReuseExistingTargetScreenRequested = $false
        RuntimeContext = $null
        ScenarioPlan = $null
        PhysicalPlan = $null
        BindingCatalog = $null
        BindingCatalogSource = ''
        ScenarioPlanFullPath = ''
        PhysicalPlanFullPath = ''
        ExecutableScenarioCaseIds = @()
        RequestedScenarioCaseIds = @()
        RunId = ''
        ReportDir = ''
        ScreenshotsDir = ''
        ExecutionTracePath = ''
        InputBoundaryAuditPath = ''
        ResultEvaluationTestPackPath = ''
        ResultEvaluationWorkingDirectory = ''
        MapCatalog = $null
        MapInitializationIssue = ''
    }
}

# Validates the approved TestPack and resolves target-neutral run inputs.
function Initialize-HtsRuleSuiteBootstrap {
    param([Parameter(Mandatory = $true)]$RunSpec)

    $root = [string]$RunSpec.Root
    $runInput = $RunSpec.Input
    $pipelineManifest = Get-RulePipelineManifest $root
    $cliProject = Resolve-RulePath $root ([string]$pipelineManifest.cliProject)
    $reportExporter = Get-RulePipelineEntryPoint $pipelineManifest $root 'reportExporter'
    $tcReportExporter = Get-RulePipelineEntryPoint $pipelineManifest $root 'tcReportExporter'
    $resolvedTestPackPath = Resolve-RulePath $root ([string]$runInput.TestPackPath)
    & dotnet run --project $cliProject -c Release --no-build -- validate-test-pack --file $resolvedTestPackPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'TestPack 무결성 또는 승인 검증에 실패했습니다. validate-test-pack 결과를 확인하세요.' }

    $targetContext = Get-RuleTestPackContext $root $resolvedTestPackPath ([string]$runInput.ScreensCsv)
    $testPack = $targetContext.TestPack
    $dataset = $targetContext.Dataset
    $initiallyActiveMapScreenCodes = @($dataset.targetProfile.map.initiallyActiveMapScreenCodes | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    $targetScreenIdRegex = [regex]::new($targetContext.ScreenIdPattern)
    $screenPatternBody = $targetContext.ScreenIdPattern.Trim()
    if ($screenPatternBody.StartsWith('^')) { $screenPatternBody = $screenPatternBody.Substring(1) }
    if ($screenPatternBody.EndsWith('$')) { $screenPatternBody = $screenPatternBody.Substring(0, $screenPatternBody.Length - 1) }
    $targetScreenTitleRegex = [regex]::new('^\[(?<screen>' + $screenPatternBody + ')\]')
    $targetMapScreenCodeRegex = [regex]::new('^HT(?<screen>' + $screenPatternBody + ')')
    $scenarioMode = [bool]$runInput.ScenarioPlanPath
    $reuseExistingTargetScreenRequested = [bool]($runInput.ReuseExistingTargetScreen -or $runInput.RequireExistingTargetScreen)
    $runtimeContext = New-HtsRunContext `
        -TargetWindowClassName ([string]$targetContext.WindowClassName) `
        -TargetWindowTitlePrefix ([string]$targetContext.WindowTitlePrefix) `
        -TargetScreenIdRegex $targetScreenIdRegex `
        -TargetScreenTitleRegex $targetScreenTitleRegex `
        -TargetMapScreenCodeRegex $targetMapScreenCodeRegex `
        -InitiallyActiveMapScreenCodes $initiallyActiveMapScreenCodes `
        -VisiblePointerMotion ([bool]$runInput.VisiblePointerMotion) `
        -PointerDwellMilliseconds ([int]$runInput.PointerDwellMilliseconds)
    $requestedScenarioCaseIds = @(([string]$runInput.CaseIdsCsv) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)

    if ($runInput.SubmitTransactionalDialogs -and -not $scenarioMode) { throw '-SubmitTransactionalDialogs에는 승인된 -ScenarioPlanPath가 필요합니다.' }
    if ($runInput.SubmitTransactionalDialogs -and ($runInput.PlanOnly -or $runInput.DryRun)) { throw '-SubmitTransactionalDialogs는 PlanOnly/DryRun과 함께 사용할 수 없습니다.' }

    $RunSpec.PipelineManifest = $pipelineManifest
    $RunSpec.CliProject = $cliProject
    $RunSpec.ReportExporter = $reportExporter
    $RunSpec.TcReportExporter = $tcReportExporter
    $RunSpec.ResolvedTestPackPath = $resolvedTestPackPath
    $RunSpec.TargetContext = $targetContext
    $RunSpec.TestPack = $testPack
    $RunSpec.Dataset = $dataset
    $RunSpec.InitiallyActiveMapScreenCodes = $initiallyActiveMapScreenCodes
    $RunSpec.TargetScreenIdRegex = $targetScreenIdRegex
    $RunSpec.TargetScreenTitleRegex = $targetScreenTitleRegex
    $RunSpec.TargetMapScreenCodeRegex = $targetMapScreenCodeRegex
    $RunSpec.ScenarioMode = $scenarioMode
    $RunSpec.ReuseExistingTargetScreenRequested = $reuseExistingTargetScreenRequested
    $RunSpec.RuntimeContext = $runtimeContext
    $RunSpec.RequestedScenarioCaseIds = $requestedScenarioCaseIds
    $RunSpec
}

# Creates deterministic artifact paths without producing verdicts or UI actions.
function Initialize-HtsRuleSuiteOutputPaths {
    param([Parameter(Mandatory = $true)]$RunSpec)

    $runId = $RunSpec.TargetContext.RunLabel + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $reportDir = [string]$RunSpec.Input.ReportDir
    if (-not $reportDir) { $reportDir = Join-Path (Join-Path $RunSpec.Root 'reports') $runId }
    $reportDir = [IO.Path]::GetFullPath($reportDir)
    $screenshotsDir = Join-Path $reportDir 'screenshots'
    New-Item -ItemType Directory -Force -Path $screenshotsDir | Out-Null

    if ($RunSpec.ScenarioMode) {
        Copy-Item -LiteralPath $RunSpec.ScenarioPlanFullPath -Destination (Join-Path $reportDir 'compiled-plan.json') -Force
        $scenarioReviewSource = Join-Path (Split-Path -Parent $RunSpec.ScenarioPlanFullPath) 'scenario-review-items.json'
        if (Test-Path -LiteralPath $scenarioReviewSource) { Copy-Item -LiteralPath $scenarioReviewSource -Destination (Join-Path $reportDir 'scenario-review-items.json') -Force }
        if ($RunSpec.PhysicalPlan) {
            Copy-Item -LiteralPath $RunSpec.PhysicalPlanFullPath -Destination (Join-Path $reportDir 'physical-plan.json') -Force
            Copy-Item -LiteralPath $RunSpec.BindingCatalogSource -Destination (Join-Path $reportDir 'binding-catalog.json') -Force
        }
    }

    $executionTracePath = Join-Path $reportDir 'execution-trace.ndjson'
    if (Test-Path -LiteralPath $executionTracePath) { Remove-Item -LiteralPath $executionTracePath -Force }
    $inputBoundaryAuditPath = Join-Path $reportDir 'input-boundary-audit.ndjson'
    if (Test-Path -LiteralPath $inputBoundaryAuditPath) { Remove-Item -LiteralPath $inputBoundaryAuditPath -Force }

    $RunSpec.RunId = $runId
    $RunSpec.ReportDir = $reportDir
    $RunSpec.ScreenshotsDir = $screenshotsDir
    $RunSpec.ExecutionTracePath = $executionTracePath
    $RunSpec.InputBoundaryAuditPath = $inputBoundaryAuditPath
    $RunSpec.ResultEvaluationTestPackPath = $RunSpec.ResolvedTestPackPath
    $RunSpec.ResultEvaluationWorkingDirectory = Join-Path $reportDir 'result-evaluation'
    $RunSpec
}
