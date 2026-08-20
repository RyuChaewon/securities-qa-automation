<#
.SYNOPSIS 외부 생성 시나리오의 요청·반입·바인딩·실행 단계를 명시적으로 수행한다.
.DESCRIPTION 사람 승인 경로를 단계별 산출물로 분리하며 자동 생성 기본 경로와 혼합하지 않는다.
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('RequestPackage','ImportAndPlan','BindingPlan','Execute')]
    [string]$Stage,
    [string]$GeneratedScenarioPath = '',
    [string]$ApprovalPath = '',
    [string]$CompiledPlanPath = '',
    [string]$PhysicalPlanPath = '',
    [Parameter(Mandatory = $true)]
    [string]$DatasetPath,
    [string]$TestPackPath = '',
    [string]$OutputDir = '',
    [string]$ScreensCsv = '',
    [string]$CaseIdsCsv = '',
    [int]$MaxCases = 10000,
    [int]$MaxDurationSeconds = 1200,
    [double]$Fps = 2.0,
    [switch]$AllowPartialScenarioPlan,
    [switch]$AllowElevatedActionPrompt,
    [switch]$SkipZip
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'modules\pipeline-common.ps1')
. (Join-Path $PSScriptRoot 'modules\pipeline-status.ps1')
$pipelineManifest = Get-RulePipelineManifest $root
$cliProject = Resolve-RulePath $root ([string]$pipelineManifest.cliProject)

# 사용자가 준 상대 경로를 저장소 기준 절대 경로로 정규화한다.
function Resolve-InputPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([IO.Path]::IsPathRooted($Path)) {
        [IO.Path]::GetFullPath($Path)
    } else {
        [IO.Path]::GetFullPath((Join-Path $root $Path))
    }
}

# 산출물 경로를 작업 폴더 내부로 제한해 외부 파일을 덮어쓰지 않게 한다.
function Resolve-WorkspaceOutputPath([string]$Path) {
    $full = Resolve-InputPath $Path
    $rootFull = [IO.Path]::GetFullPath($root)
    if (-not $full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "파이프라인 출력 경로는 작업 폴더 내부여야 합니다: $full"
    }
    $full
}

# 각 단계가 요구하는 입력 파일의 존재를 실행 전에 확인한다.
function Require-File([string]$Path, [string]$Label) {
    $full = Resolve-InputPath $Path
    if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "$Label 파일을 찾을 수 없습니다: $Path"
    }
    $full
}

# 단계별 산출물을 독립 폴더에 보관해 재실행과 감사 추적이 가능하게 한다.
function New-StageDirectory([string]$Name) {
    if ($OutputDir) {
        $dir = Resolve-WorkspaceOutputPath $OutputDir
    } else {
        $dir = Join-Path (Join-Path $root 'artifacts\scenario-pipeline') ($Name + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    if (Test-Path -LiteralPath $dir) {
        if (@(Get-ChildItem -LiteralPath $dir -Force).Count -gt 0) {
            throw "출력 폴더가 비어 있지 않습니다. 새 경로를 지정하세요: $dir"
        }
    } else {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [IO.Path]::GetFullPath($dir)
}

# 다음 단계의 입력 경로와 실제 조작 여부를 기계 판독 가능한 상태 파일로 기록한다.
function Write-PipelineState([string]$Directory, [hashtable]$Values, [string]$Status = 'COMPLETED') {
    $requestedTestStatus = if ($Values.Contains('testStatus')) {
        [string]$Values.testStatus
    } elseif ($Values.Contains('testOutcome') -and [string]$Values.testOutcome -in @('PASS', 'FAIL', 'ERROR', 'PENDING')) {
        [string]$Values.testOutcome
    } else { 'PENDING' }
    $actionsExecuted = $Values.Contains('actualScenarioActionsExecuted') -and [bool]$Values.actualScenarioActionsExecuted
    $contract = Resolve-RulePipelineState -Status $Status -TestStatus $requestedTestStatus -ActualScenarioActionsExecuted $actionsExecuted
    $state = [ordered]@{
        schemaVersion = '1.0'
        stage = $Stage
        status = $contract.Status
        pipelineStatus = $contract.PipelineStatus
        pipelineCompleted = $contract.PipelineCompleted
        testStatus = $contract.TestStatus
        testPassed = $contract.TestPassed
        generatedAt = (Get-Date).ToString('o')
        actualScenarioActionsExecuted = $contract.ActualScenarioActionsExecuted
    }
    foreach ($key in $Values.Keys) {
        if ($key -notin @('status', 'pipelineStatus', 'pipelineCompleted', 'testStatus', 'testPassed', 'actualScenarioActionsExecuted')) {
            $state[$key] = $Values[$key]
        }
    }
    $path = Join-Path $Directory 'pipeline-state.json'
    [pscustomobject]$state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    $path
}

$datasetFull = Require-File $DatasetPath '기준 데이터셋'
$testPackFull = if ($TestPackPath) { Require-File $TestPackPath '승인 TestPack' } else { '' }
if ($Stage -in @('BindingPlan','Execute')) {
    if (-not $testPackFull) { throw "$Stage 단계에는 -TestPackPath로 Approved TestPack이 필요합니다." }
    & dotnet run --project $cliProject -c Release --no-build -- validate-test-pack --file $testPackFull --dataset $datasetFull | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'TestPack 승인·무결성·Dataset 원본 해시 검증에 실패했습니다.' }
}
$stageDir = New-StageDirectory $Stage
$actualScenarioActionsExecuted = $false
$observedTestStatus = 'PENDING'
$recordedRun = $null

# 각 분기는 사람/외부 모델을 거치는 기존 수동 파이프라인의 한 단계를 독립적으로 재현한다.
try {
switch ($Stage) {
    # MAP·데이터셋·요청문을 묶어 외부 시나리오 생성 요청 패키지를 만든다.
    'RequestPackage' {
        $packageDir = Join-Path $stageDir 'request-package'
        $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'export-chatgpt-scenario-package.ps1'),'-OutputDir',$packageDir,'-DatasetPath',$datasetFull)
        if ($ScreensCsv) { $args += @('-ScreensCsv',$ScreensCsv) }
        if ($SkipZip) { $args += '-SkipZip' }
        & powershell.exe @args | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'ChatGPT 시나리오 요청자료 묶음 생성에 실패했습니다.' }
        $statePath = Write-PipelineState $stageDir ([ordered]@{
            requestPackageDirectory = $packageDir
            requestPrompt = (Join-Path $packageDir '01_ChatGPT_요청문.md')
            packageManifest = (Join-Path $packageDir 'PACKAGE_MANIFEST.json')
            nextStage = 'ImportAndPlan'
            nextInput = 'ChatGPT가 반환한 generated-scenarios.json'
            actualHtsManipulated = $false
            testOutcome = 'PENDING'
        })
    }
    # 반환 JSON을 스키마 검증하고 승인 오버레이를 적용해 논리 실행 계획을 만든다.
    'ImportAndPlan' {
        $generatedFull = Require-File $GeneratedScenarioPath '생성 시나리오'
        $importDir = Join-Path $stageDir 'import'
        & dotnet run --project $cliProject -c Release --no-build -- import-generated-scenarios --file $generatedFull --dataset $datasetFull --out-dir $importDir | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '생성 시나리오 반입 및 검증에 실패했습니다.' }

        $importedSource = Join-Path $importDir 'generated-scenarios.json'
        $staticPlanDir = Join-Path $stageDir 'static-plan'
        $planArgs = @('run','--project',$cliProject,'-c','Release','--no-build','--','plan-scenarios','--file',$importedSource,'--dataset',$datasetFull,'--max-cases',$MaxCases,'--report-dir',$staticPlanDir)
        $approvalFull = ''
        if ($ApprovalPath) {
            $approvalFull = Require-File $ApprovalPath '승인 오버레이'
            $planArgs += @('--approval',$approvalFull)
        }
        & dotnet @planArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '정적 시나리오 계획 생성에 실패했습니다.' }

        $compiled = Join-Path $staticPlanDir 'compiled-plan.json'
        $summary = Get-Content -LiteralPath (Join-Path $staticPlanDir 'plan-summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $statePath = Write-PipelineState $stageDir ([ordered]@{
            sourceScenario = $generatedFull
            importedScenario = $importedSource
            importManifest = (Join-Path $importDir 'import-manifest.json')
            validationReport = (Join-Path $importDir 'validation.json')
            approvalTemplate = (Join-Path $importDir 'approval.template.json')
            approvalOverlay = $approvalFull
            compiledPlan = $compiled
            planSummary = (Join-Path $staticPlanDir 'plan-summary.json')
            planId = [string]$summary.planId
            planStatus = [string]$summary.status
            nextStage = 'BindingPlan'
            actualHtsManipulated = $false
            testOutcome = 'PENDING'
        })
    }
    # 현재 HTS에서 얻은 런타임 컨트롤을 논리 계획과 결합하되 실제 테스트 액션은 하지 않는다.
    'BindingPlan' {
        $compiledFull = Require-File $CompiledPlanPath '컴파일 계획'
        $bindingDir = Join-Path $stageDir 'binding-plan'
        $bindingArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'plan-scenario-bindings.ps1'),'-CompiledPlanPath',$compiledFull,'-TestPackPath',$testPackFull,'-ReportDir',$bindingDir)
        if ($ScreensCsv) { $bindingArgs += @('-ScreensCsv',$ScreensCsv) }
        & powershell.exe @bindingArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '동적 MAP 바인딩 Plan-only 실행에 실패했습니다.' }
        $bindingSummary = Join-Path $bindingDir 'binding-plan-summary.json'
        if (-not (Test-Path -LiteralPath $bindingSummary)) { throw "바인딩 요약이 생성되지 않았습니다: $bindingSummary" }
        $binding = Get-Content -LiteralPath $bindingSummary -Raw -Encoding UTF8 | ConvertFrom-Json
        $statePath = Write-PipelineState $stageDir ([ordered]@{
            compiledPlan = $compiledFull
            runtimeDiscovery = [string]$binding.runtimeReportDir
            bindingCatalog = [string]$binding.bindingCatalog
            physicalPlan = [string]$binding.physicalPlan
            bindingStatus = [string]$binding.status
            nextStage = 'Execute'
            actualHtsManipulated = $true
            actualScenarioActionsExecuted = $false
            testOutcome = 'PENDING'
        })
    }
    # 승인·바인딩이 끝난 물리 계획을 녹화 실행기로 전달하는 유일한 실제 조작 단계다.
    'Execute' {
        $compiledFull = Require-File $CompiledPlanPath '컴파일 계획'
        $physicalFull = Require-File $PhysicalPlanPath '물리 실행계획'
        $suiteDir = Join-Path $stageDir 'recorded-run'
        $recordedRunner = Get-RulePipelineEntryPoint $pipelineManifest $root 'recordedRunner'
        $runArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$recordedRunner,'-TestPackPath',$testPackFull,'-SuiteDir',$suiteDir,'-ScenarioPlanPath',$compiledFull,'-PhysicalPlanPath',$physicalFull,'-MaxCases',$MaxCases,'-MaxDurationSeconds',$MaxDurationSeconds,'-Fps',$Fps)
        if ($ScreensCsv) { $runArgs += @('-ScreensCsv',$ScreensCsv) }
        if ($CaseIdsCsv) { $runArgs += @('-CaseIdsCsv',$CaseIdsCsv) }
        if ($AllowPartialScenarioPlan) { $runArgs += '-AllowPartialScenarioPlan' }
        if ($AllowElevatedActionPrompt) { $runArgs += '-AllowElevatedActionPrompt' }
        & powershell.exe @runArgs | Out-Null
        $recordedExitCode = $LASTEXITCODE
        $marker = Join-Path $suiteDir '녹화실행완료.json'
        if (-not (Test-Path -LiteralPath $marker)) { throw "실행 완료 표식을 찾을 수 없습니다: $marker" }
        $recordedRun = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
        $actualScenarioActionsExecuted = Get-RuleActualScenarioActionsExecuted -RecordedValue $recordedRun.actualScenarioActionsExecuted -Summary $recordedRun.actionSummary
        $observedTestStatus = if ([string]$recordedRun.testStatus -in @('PASS','FAIL','ERROR','PENDING')) { [string]$recordedRun.testStatus } else { 'PENDING' }
        $runState = Resolve-RulePipelineState `
            -Status ([string]$recordedRun.status) `
            -TestStatus $observedTestStatus `
            -ActualScenarioActionsExecuted $actualScenarioActionsExecuted
        if (-not $runState.PipelineCompleted) {
            throw "실제 실행 파이프라인이 완료되지 않았습니다: $([string]$recordedRun.status) / $([string]$recordedRun.message)"
        }
        if ($recordedExitCode -ne 0) {
            throw "완료 상태와 프로세스 종료 코드가 모순됩니다: status=$([string]$recordedRun.status), exitCode=$recordedExitCode"
        }
        $statePath = Write-PipelineState $stageDir ([ordered]@{
            compiledPlan = $compiledFull
            physicalPlan = $physicalFull
            suiteDirectory = $suiteDir
            resultDirectory = [string]$recordedRun.reportDir
            workbook = [string]$recordedRun.workbook
            video = [string]$recordedRun.video
            recordedStatus = [string]$recordedRun.status
            actualHtsManipulated = $true
            actualScenarioActionsExecuted = $actualScenarioActionsExecuted
            testStatus = $runState.TestStatus
            testOutcome = 'SEE_RESULT_SUMMARY'
        })
    }
}
} catch {
    $pipelineError = $_
    if ($Stage -eq 'Execute') {
        $marker = Join-Path (Join-Path $stageDir 'recorded-run') '녹화실행완료.json'
        if (-not $recordedRun -and (Test-Path -LiteralPath $marker)) {
            try { $recordedRun = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        }
        $recordedSummary = if ($recordedRun -and $recordedRun.actionSummary) {
            $recordedRun.actionSummary
        } elseif (Test-Path -LiteralPath (Join-Path $stageDir 'recorded-run\results\summary.json')) {
            try { Get-Content -LiteralPath (Join-Path $stageDir 'recorded-run\results\summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
        } else { $null }
        $actualScenarioActionsExecuted = Get-RuleActualScenarioActionsExecuted `
            -RecordedValue $(if ($recordedRun) { $recordedRun.actualScenarioActionsExecuted } else { $actualScenarioActionsExecuted }) `
            -Summary $recordedSummary
        if ($recordedSummary -and [string]$recordedSummary.status -in @('PASS','FAIL','ERROR','PENDING')) {
            $observedTestStatus = [string]$recordedSummary.status
        } elseif ($recordedRun -and [string]$recordedRun.testStatus -in @('PASS','FAIL','ERROR','PENDING')) {
            $observedTestStatus = [string]$recordedRun.testStatus
        }
    }
    $statePath = Write-PipelineState $stageDir ([ordered]@{
        actualScenarioActionsExecuted = $actualScenarioActionsExecuted
        testStatus = $observedTestStatus
        testOutcome = 'PENDING'
        error = $pipelineError.Exception.Message
    }) 'ERROR'
    throw $pipelineError
}

[pscustomobject]@{
    stage = $Stage
    outputDirectory = $stageDir
    state = $statePath
}
