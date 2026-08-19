<#
.SYNOPSIS MAP 추출부터 룰 시나리오 자동 생성, 바인딩, 녹화 실행과 Excel까지 한 번에 수행한다.
.DESCRIPTION StaticOnly/PrepareOnly/실행 모드를 분리하고 미검증·미결합 단계에서는 실제 시나리오 동작을 시작하지 않는다.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$DatasetPath,
    [string]$InstallationRoot = '',
    [string]$ScreensCsv = '',
    [string]$OutputDir = '',
    [string]$ReferenceDate = '',
    [int]$MaxOptionsPerControl = 40,
    [int]$MaxCases = 10000,
    [int]$MaxDurationSeconds = 1800,
    [double]$Fps = 2.0,
    [switch]$StaticOnly,
    [switch]$PrepareOnly,
    [switch]$AllowPartialScenarioPlan,
    [switch]$SubmitTransactionalDialogs,
    [switch]$AllowElevatedActionPrompt
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'modules\pipeline-common.ps1')

# 기계 판독 가능한 manifest가 실행 파일 사이의 연결을 소유하며 호출 스크립트는 논리 이름만 사용한다.
$pipelineManifest = Get-RulePipelineManifest $root
$cliProject = Resolve-RulePath $root ([string]$pipelineManifest.cliProject)
$runner = Get-RulePipelineEntryPoint $pipelineManifest $root 'targetRunner'
$recordedRunner = Get-RulePipelineEntryPoint $pipelineManifest $root 'recordedRunner'

# 현재 단계와 실제 HTS 조작 여부를 상태 JSON에 남겨 중단 후에도 실행 사실을 판별할 수 있게 한다.
function Write-State([string]$Status, [hashtable]$Values) {
    $state = [ordered]@{
        schemaVersion = '1.0'
        mode = 'AutomaticRuleScenarioPipeline'
        status = $Status
        generatedAt = (Get-Date).ToString('o')
    }
    # targetContext 생성 후 호출되는 모든 상태에 대상 식별값을 자동 포함해 단계 갱신 시 추적 정보가 사라지지 않게 한다.
    if ($targetContext) {
        $state.targetProfileId = $targetContext.ProfileId
        $state.targetDisplayName = $targetContext.DisplayName
        $state.targetScreens = @($targetContext.TargetScreens)
    }
    foreach ($key in $Values.Keys) { $state[$key] = $Values[$key] }
    $state | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

# 공용 .NET CLI를 호출하고 단계별로 허용된 종료 코드만 정상 흐름으로 인정한다.
function Invoke-Cli([string[]]$Arguments, [int[]]$AllowedExitCodes = @(0)) {
    & dotnet run --project $cliProject -c Release --no-build -- @Arguments | Out-Null
    if ($AllowedExitCodes -notcontains $LASTEXITCODE) { throw "CLI 명령이 실패했습니다: $($Arguments -join ' ') / 종료 코드 $LASTEXITCODE" }
}

# 데이터셋의 targetProfile을 창·설치·화면 범위가 결합된 단일 실행 컨텍스트로 만든다.
$targetContext = Get-RuleTargetContext $root $DatasetPath $ScreensCsv $InstallationRoot
$datasetFull = $targetContext.DatasetPath
$installationFull = $targetContext.InstallationRoot
$screenDirectory = $targetContext.ScreenDirectory
if (-not (Test-Path -LiteralPath $screenDirectory -PathType Container)) { throw "HTS screen 폴더를 찾을 수 없습니다: $screenDirectory" }

$dataset = $targetContext.Dataset
$targetScreens = @($targetContext.TargetScreens)
if (-not $ReferenceDate) { $ReferenceDate = Get-Date -Format 'yyyyMMdd' }
if ($ReferenceDate -notmatch '^\d{8}$') { throw 'ReferenceDate는 yyyyMMdd 형식이어야 합니다.' }

if (-not $OutputDir) {
    $OutputDir = Join-Path (Join-Path $root 'reports') ($targetContext.RunLabel + '-자동시나리오-' + $ReferenceDate + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
} else {
    $OutputDir = Resolve-RulePath $root $OutputDir
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$rootPrefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
if (-not $OutputDir.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "출력 폴더는 작업 폴더 내부여야 합니다: $OutputDir" }

# 실제 HTS 탐색·조작 단계만 관리자 프로세스로 재기동하며 정적 생성 모드는 승격하지 않는다.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $StaticOnly -and -not $isAdmin -and $AllowElevatedActionPrompt) {
    # 승격 자식 프로세스 명령에 경로·값을 전달할 때 PowerShell 리터럴 경계를 보존한다.
    function Quote-PowerShellLiteral([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
    $command = "& $(Quote-PowerShellLiteral $MyInvocation.MyCommand.Path)" +
        " -DatasetPath $(Quote-PowerShellLiteral $datasetFull)" +
        " -InstallationRoot $(Quote-PowerShellLiteral $installationFull)" +
        " -ScreensCsv $(Quote-PowerShellLiteral ($targetScreens -join ','))" +
        " -OutputDir $(Quote-PowerShellLiteral $OutputDir)" +
        " -ReferenceDate $(Quote-PowerShellLiteral $ReferenceDate)" +
        " -MaxOptionsPerControl $MaxOptionsPerControl" +
        " -MaxCases $MaxCases" +
        " -MaxDurationSeconds $MaxDurationSeconds" +
        " -Fps $($Fps.ToString([Globalization.CultureInfo]::InvariantCulture))"
    if ($PrepareOnly) { $command += ' -PrepareOnly' }
    if ($AllowPartialScenarioPlan) { $command += ' -AllowPartialScenarioPlan' }
    if ($SubmitTransactionalDialogs) { $command += ' -SubmitTransactionalDialogs' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $process = Start-Process -FilePath $powershellExe -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded
    ) -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "관리자 자동 파이프라인이 종료 코드 $($process.ExitCode)로 실패했습니다." }
    Write-Output $OutputDir
    return
}

if (Test-Path -LiteralPath $OutputDir) {
    if (@(Get-ChildItem -LiteralPath $OutputDir -Force).Count -gt 0) { throw "출력 폴더가 비어 있지 않습니다: $OutputDir" }
} else {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$statePath = Join-Path $OutputDir '자동파이프라인-상태.json'
$effectiveDatasetPath = Join-Path $OutputDir 'effective-dataset.json'
$mapPath = Join-Path $OutputDir 'map-catalog.json'
$runtimeDir = Join-Path $OutputDir 'runtime-discovery'
$controlPlanPath = Join-Path $runtimeDir 'control-plan.json'
$scenarioPath = Join-Path $OutputDir 'generated-rule-scenarios.json'
$approvalPath = Join-Path $OutputDir 'automatic-approval.json'
$validationPath = Join-Path $OutputDir 'scenario-validation.json'
$compiledPath = Join-Path $OutputDir 'compiled-plan.json'
$bindingsPath = Join-Path $OutputDir 'binding-catalog.json'
$physicalPath = Join-Path $OutputDir 'physical-plan.json'
$recordedDir = Join-Path $OutputDir 'recorded-run'

# 사용자가 선택한 화면만 시나리오 생성·검증·컴파일 대상이 되도록 실행 전용 데이터셋을 분리한다.
$effectiveDataset = $dataset | ConvertTo-Json -Depth 64 | ConvertFrom-Json
$effectiveScreens = @($effectiveDataset.screens | Where-Object { $targetScreens -contains [string]$_.screenNumber })
if ($effectiveScreens.Count -ne $targetScreens.Count) {
    throw "실행 전용 데이터셋 화면 수가 선택 범위와 일치하지 않습니다: 선택 $($targetScreens.Count), 데이터셋 $($effectiveScreens.Count)"
}
$effectiveDataset.screens = [object[]]$effectiveScreens
ConvertTo-Json -InputObject $effectiveDataset -Depth 64 | Set-Content -LiteralPath $effectiveDatasetPath -Encoding UTF8

Write-State 'STARTED' ([ordered]@{
    dataset = $datasetFull
    targetProfileId = $targetContext.ProfileId
    targetDisplayName = $targetContext.DisplayName
    installationRoot = $installationFull
    targetScreens = $targetScreens
    staticOnly = [bool]$StaticOnly
    prepareOnly = [bool]$PrepareOnly
    actualHtsManipulated = $false
    actualScenarioActionsExecuted = $false
    testOutcome = 'PENDING'
})

try {
    # 1단계: 빌드된 CLI와 설치 MAP으로 실행 환경에 독립적인 정적 화면 모델을 만든다.
    $env:DOTNET_CLI_HOME = Join-Path $root '.dotnet-home'
    & dotnet build (Join-Path $root 'HtsQaPoc.sln') -c Release --no-restore | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Release 빌드에 실패했습니다.' }

    $mapArgs = @(
        'extract-map-models',
        '--screen-dir', $screenDirectory,
        '--installation-root', $installationFull,
        '--screens', ($targetScreens -join ','),
        '--file-pattern', $targetContext.MapFilePattern,
        '--out', $mapPath
    )
    if ($targetContext.MapFamilyFiles.Count -gt 0) {
        $mapArgs += @('--family-files', ($targetContext.MapFamilyFiles -join ','))
    }
    Invoke-Cli $mapArgs

    # 2단계: plan-only 실행으로 현재 HTS의 컨트롤과 탭 순서를 읽되 시나리오 액션은 수행하지 않는다.
    $runtimeFingerprint = ''
    if (-not $StaticOnly) {
        if (-not $isAdmin) {
            Write-State 'PENDING_ADMIN_RUNNER_REQUIRED' ([ordered]@{
                dataset = $datasetFull
                mapCatalog = $mapPath
                targetScreens = $targetScreens
                actualHtsManipulated = $false
                actualScenarioActionsExecuted = $false
                testOutcome = 'PENDING'
                note = '런타임 탭오더와 선택 항목을 얻으려면 HTS와 같은 관리자 권한에서 이 스크립트를 다시 실행해야 합니다.'
            })
            Write-Output $OutputDir
            return
        }

        & $runner -DatasetPath $datasetFull -ReportDir $runtimeDir -ScreensCsv ($targetScreens -join ',') -MaxCases $targetScreens.Count -PlanOnly -SkipExcel | Out-Null
        if (-not (Test-Path -LiteralPath $controlPlanPath)) { throw "런타임 컨트롤 계획이 생성되지 않았습니다: $controlPlanPath" }
        $runtimeSummaryPath = Join-Path $runtimeDir 'summary.json'
        if (-not (Test-Path -LiteralPath $runtimeSummaryPath)) { throw "런타임 탐색 요약이 생성되지 않았습니다: $runtimeSummaryPath" }
        $runtimeSummary = Get-Content -LiteralPath $runtimeSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $runtimeFingerprint = [string]$runtimeSummary.installationFingerprint
        if (-not $runtimeFingerprint) { throw '런타임 설치 fingerprint를 얻지 못했습니다.' }
    }

    # 3단계: 정적 MAP과 런타임 관찰을 입력으로 룰 기반 시나리오를 생성·검증·승인·컴파일한다.
    $generateArgs = @(
        'generate-rule-scenarios',
        '--map', $mapPath,
        '--dataset', $effectiveDatasetPath,
        '--reference-date', $ReferenceDate,
        '--max-options', $MaxOptionsPerControl,
        '--out', $scenarioPath
    )
    if (-not $StaticOnly) { $generateArgs += @('--control-plan', $controlPlanPath) }
    Invoke-Cli $generateArgs
    Invoke-Cli @('validate-generated-scenarios', '--file', $scenarioPath, '--dataset', $effectiveDatasetPath, '--out', $validationPath)
    Invoke-Cli @('create-rule-scenario-approval', '--file', $scenarioPath, '--out', $approvalPath)
    Invoke-Cli @(
        'compile-scenarios',
        '--file', $scenarioPath,
        '--dataset', $effectiveDatasetPath,
        '--approval', $approvalPath,
        '--max-cases', $MaxCases,
        '--out', $compiledPath
    )

    $compiled = Get-Content -LiteralPath $compiledPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$compiled.status -ne 'READY_FOR_BINDING') { throw "자동 컴파일 계획이 바인딩 준비 상태가 아닙니다: $([string]$compiled.status)" }

    if ($StaticOnly) {
        Write-State 'STATIC_PLAN_READY' ([ordered]@{
            dataset = $datasetFull
            mapCatalog = $mapPath
            generatedScenarios = $scenarioPath
            validation = $validationPath
            approval = $approvalPath
            compiledPlan = $compiledPath
            scenarioCount = [int]$compiled.scenarioCount
            caseCount = [int]$compiled.caseCount
            actualHtsManipulated = $false
            actualScenarioActionsExecuted = $false
            testOutcome = 'PENDING'
            note = '정적 자동 생성·검증·정책 승인·컴파일만 수행했습니다.'
        })
        Write-Output $OutputDir
        return
    }

    if ($runtimeFingerprint -ne [string]$compiled.sourceInstallationFingerprint) {
        throw 'MAP 카탈로그와 현재 HTS 런타임의 설치 fingerprint가 일치하지 않습니다.'
    }
    # 4단계: 논리 컨트롤을 현재 HWND/UIA/탭 순회 결과와 결합해 물리 실행 계획으로 고정한다.
    Invoke-Cli -Arguments @(
        'materialize-scenario-bindings',
        '--plan', $compiledPath,
        '--control-plan', $controlPlanPath,
        '--runtime-fingerprint', $runtimeFingerprint,
        '--out', $bindingsPath
    ) -AllowedExitCodes @(0, 3)
    Invoke-Cli -Arguments @('build-physical-scenario-plan', '--plan', $compiledPath, '--bindings', $bindingsPath, '--out', $physicalPath) -AllowedExitCodes @(0, 3, 4)

    $physical = Get-Content -LiteralPath $physicalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$physical.status -ne 'READY' -and -not $AllowPartialScenarioPlan) {
        Write-State 'PENDING_BINDING' ([ordered]@{
            dataset = $datasetFull
            mapCatalog = $mapPath
            runtimeDiscovery = $runtimeDir
            generatedScenarios = $scenarioPath
            validation = $validationPath
            approval = $approvalPath
            compiledPlan = $compiledPath
            bindingCatalog = $bindingsPath
            physicalPlan = $physicalPath
            physicalStatus = [string]$physical.status
            executableCases = [int]$physical.executableCases
            pendingBindingCases = [int]$physical.pendingBindingCases
            actualHtsManipulated = $true
            actualScenarioActionsExecuted = $false
            testOutcome = 'PENDING'
            note = '고신뢰 바인딩이 완료되지 않아 실제 시나리오 동작을 시작하지 않았습니다.'
        })
        Write-Output $OutputDir
        return
    }

    if ($PrepareOnly) {
        Write-State 'PHYSICAL_PLAN_READY' ([ordered]@{
            dataset = $datasetFull
            mapCatalog = $mapPath
            runtimeDiscovery = $runtimeDir
            generatedScenarios = $scenarioPath
            validation = $validationPath
            approval = $approvalPath
            compiledPlan = $compiledPath
            bindingCatalog = $bindingsPath
            physicalPlan = $physicalPath
            physicalStatus = [string]$physical.status
            executableCases = [int]$physical.executableCases
            actualHtsManipulated = $true
            actualScenarioActionsExecuted = $false
            testOutcome = 'PENDING'
            note = 'Plan-only 바인딩 검증까지 완료했고 실제 시나리오 동작은 실행하지 않았습니다.'
        })
        Write-Output $OutputDir
        return
    }

    $runArguments = @{
        DatasetPath = $datasetFull
        SuiteDir = $recordedDir
        ScreensCsv = ($targetScreens -join ',')
        ScenarioPlanPath = $compiledPath
        PhysicalPlanPath = $physicalPath
        MaxCases = $MaxCases
        MaxDurationSeconds = $MaxDurationSeconds
        # 녹화 시간보다 짧은 고정 액션 제한 때문에 결과·Excel이 중간 종료되지 않도록 같은 상한을 사용한다.
        ActionTimeoutSeconds = $MaxDurationSeconds
        Fps = $Fps
    }
    if ($AllowPartialScenarioPlan) { $runArguments.AllowPartialScenarioPlan = $true }
    if ($SubmitTransactionalDialogs) { $runArguments.SubmitTransactionalDialogs = $true }
    if ($AllowElevatedActionPrompt) { $runArguments.AllowElevatedActionPrompt = $true }
    & $recordedRunner @runArguments | Out-Null

    $completionPath = Join-Path $recordedDir '녹화실행완료.json'
    if (-not (Test-Path -LiteralPath $completionPath)) { throw "녹화 실행 완료 파일을 찾지 못했습니다: $completionPath" }
    $completion = Get-Content -LiteralPath $completionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$completion.status -ne 'DONE') { throw "실제 실행이 완료되지 않았습니다: $([string]$completion.status)" }
    Write-State 'DONE' ([ordered]@{
        dataset = $datasetFull
        mapCatalog = $mapPath
        runtimeDiscovery = $runtimeDir
        generatedScenarios = $scenarioPath
        validation = $validationPath
        approval = $approvalPath
        compiledPlan = $compiledPath
        bindingCatalog = $bindingsPath
        physicalPlan = $physicalPath
        recordedRun = $recordedDir
        resultDirectory = [string]$completion.reportDir
        workbook = [string]$completion.workbook
        video = [string]$completion.video
        actualHtsManipulated = $true
        actualScenarioActionsExecuted = $true
        testOutcome = 'SEE_RESULT_SUMMARY'
    })
} catch {
    Write-State 'ERROR' ([ordered]@{
        dataset = $datasetFull
        mapCatalog = $mapPath
        generatedScenarios = $scenarioPath
        compiledPlan = $compiledPath
        actualScenarioActionsExecuted = $false
        testOutcome = 'PENDING'
        error = $_.Exception.Message
    })
    throw
}

Write-Output $OutputDir
