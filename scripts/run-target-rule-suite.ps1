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
    [ValidateSet('', '0', '1', '2')]
    [string]$OrderTabStateOverride = '',
    [switch]$SubmitTransactionalDialogs,
    [switch]$DryRun,
    [switch]$PlanOnly,
    [switch]$SkipExcel
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "modules\pipeline-common.ps1")
. (Join-Path $PSScriptRoot "modules\report-sanitization.ps1")
. (Join-Path $PSScriptRoot "modules\result-evaluator.ps1")
. (Join-Path $PSScriptRoot "modules\hts-session.ps1")
. (Join-Path $PSScriptRoot "modules\hts-navigation.ps1")
. (Join-Path $PSScriptRoot "modules\hts-discovery.ps1")
. (Join-Path $PSScriptRoot "modules\hts-binding.ps1")
. (Join-Path $PSScriptRoot "modules\hts-action.ps1")

# 공통 manifest와 대상 컨텍스트를 한 번만 읽고 이하 모든 단계가 같은 파일·창·화면 범위를 사용하게 한다.
$pipelineManifest = Get-RulePipelineManifest $root
$cliProject = Resolve-RulePath $root ([string]$pipelineManifest.cliProject)
$reportExporter = Get-RulePipelineEntryPoint $pipelineManifest $root 'reportExporter'
$tcReportExporter = Get-RulePipelineEntryPoint $pipelineManifest $root 'tcReportExporter'
$resolvedTestPackPath = Resolve-RulePath $root $TestPackPath
& dotnet run --project $cliProject -c Release --no-build -- validate-test-pack --file $resolvedTestPackPath | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'TestPack 무결성 또는 승인 검증에 실패했습니다. validate-test-pack 결과를 확인하세요.' }
$targetContext = Get-RuleTestPackContext $root $resolvedTestPackPath $ScreensCsv
$testPack = $targetContext.TestPack
$dataset = $targetContext.Dataset
$script:initiallyActiveMapScreenCodes = @($dataset.targetProfile.map.initiallyActiveMapScreenCodes | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } | Where-Object { $_ } | Select-Object -Unique)
$script:targetWindowClassName = $targetContext.WindowClassName
$script:targetWindowTitlePrefix = $targetContext.WindowTitlePrefix
$script:targetScreenIdRegex = [regex]::new($targetContext.ScreenIdPattern)
$screenPatternBody = $targetContext.ScreenIdPattern.Trim()
if ($screenPatternBody.StartsWith('^')) { $screenPatternBody = $screenPatternBody.Substring(1) }
if ($screenPatternBody.EndsWith('$')) { $screenPatternBody = $screenPatternBody.Substring(0, $screenPatternBody.Length - 1) }
$script:targetScreenTitleRegex = [regex]::new('^\[(?<screen>' + $screenPatternBody + ')\]')
$script:targetMapScreenCodeRegex = [regex]::new('^HT(?<screen>' + $screenPatternBody + ')')
$scenarioPlan = $null
$physicalPlan = $null
$bindingCatalog = $null
$bindingCatalogSource = ''
$scenarioMode = [bool]$ScenarioPlanPath
$reuseExistingTargetScreenRequested = [bool]($ReuseExistingTargetScreen -or $RequireExistingTargetScreen)
$script:visiblePointerMotion = [bool]$VisiblePointerMotion
$script:pointerDwellMilliseconds = [int]$PointerDwellMilliseconds
$executableScenarioCaseIds = @()
$requestedScenarioCaseIds = @($CaseIdsCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($SubmitTransactionalDialogs -and -not $scenarioMode) { throw '-SubmitTransactionalDialogs에는 승인된 -ScenarioPlanPath가 필요합니다.' }
if ($SubmitTransactionalDialogs -and ($PlanOnly -or $DryRun)) { throw '-SubmitTransactionalDialogs는 PlanOnly/DryRun과 함께 사용할 수 없습니다.' }

function Get-RuleFileSha256([string]$Path) {
    $stream=[IO.File]::OpenRead($Path)
    $hasher=[Security.Cryptography.SHA256]::Create()
    try {
        (($hasher.ComputeHash($stream) | ForEach-Object { $_.ToString('X2') }) -join '')
    } finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function Export-RuleResultWorkbooks([string]$Path) {
    & $reportExporter -ReportDir $Path | Out-Null
    $compiledPath = Join-Path $Path 'compiled-plan.json'
    $casePath = Join-Path $Path 'case-results.json'
    $hasTcCases = Test-Path -LiteralPath $compiledPath
    if (-not $hasTcCases -and (Test-Path -LiteralPath $casePath)) {
        $tcRows = @(Get-Content -LiteralPath $casePath -Raw -Encoding UTF8 | ConvertFrom-Json | Where-Object { [string]$_.sourceTestCaseId })
        $hasTcCases = $tcRows.Count -gt 0
    }
    if ($hasTcCases) { & $tcReportExporter -ReportDir $Path | Out-Null }
}
if ($scenarioMode) {
    $scenarioPlanFullPath = if ([IO.Path]::IsPathRooted($ScenarioPlanPath)) { $ScenarioPlanPath } else { Join-Path $root $ScenarioPlanPath }
    if (-not (Test-Path -LiteralPath $scenarioPlanFullPath)) { throw "컴파일된 시나리오 계획을 찾을 수 없습니다: $scenarioPlanFullPath" }
    $scenarioPlan = Get-Content -LiteralPath $scenarioPlanFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$scenarioPlan.datasetId -ne [string]$dataset.datasetId) { throw "시나리오 계획과 기준 데이터셋의 datasetId가 일치하지 않습니다." }
    if (-not $PlanOnly) {
        if (-not $PhysicalPlanPath) { throw "실제 시나리오 실행에는 Binding Plan-only로 생성한 -PhysicalPlanPath가 필요합니다." }
        $physicalPlanFullPath = if ([IO.Path]::IsPathRooted($PhysicalPlanPath)) { $PhysicalPlanPath } else { Join-Path $root $PhysicalPlanPath }
        if (-not (Test-Path -LiteralPath $physicalPlanFullPath)) { throw "물리 실행계획을 찾을 수 없습니다: $physicalPlanFullPath" }
        $physicalPlan = Get-Content -LiteralPath $physicalPlanFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$physicalPlan.schemaVersion -ne '1.1') { throw "지원하지 않는 물리 실행계획 schemaVersion입니다: $([string]$physicalPlan.schemaVersion). 1.1 계획을 다시 생성하세요." }
        if ([string]$physicalPlan.logicalPlanHash -ne [string]$scenarioPlan.planHash) { throw "물리 실행계획이 현재 논리 시나리오 계획과 일치하지 않습니다." }
        $bindingCatalogSource = Join-Path (Split-Path -Parent $physicalPlanFullPath) 'binding-catalog.json'
        if (-not (Test-Path -LiteralPath $bindingCatalogSource)) { throw "물리 실행계획의 바인딩 카탈로그를 찾을 수 없습니다: $bindingCatalogSource" }
        $bindingCatalog = Get-Content -LiteralPath $bindingCatalogSource -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$bindingCatalog.schemaVersion -ne '1.1') { throw "지원하지 않는 바인딩 카탈로그 schemaVersion입니다: $([string]$bindingCatalog.schemaVersion). 1.1 카탈로그를 다시 생성하세요." }
        $bindingCatalogHash = Get-RuleFileSha256 $bindingCatalogSource
        if (-not [string]::Equals($bindingCatalogHash,[string]$physicalPlan.bindingCatalogHash,[StringComparison]::OrdinalIgnoreCase)) { throw "바인딩 카탈로그 파일 해시가 물리 실행계획과 일치하지 않습니다." }
        if ([string]$bindingCatalog.planHash -ne [string]$scenarioPlan.planHash) { throw "바인딩 카탈로그가 현재 논리 시나리오 계획에서 생성되지 않았습니다." }
        if ([string]$bindingCatalog.sourceInstallationFingerprint -ne [string]$bindingCatalog.runtimeInstallationFingerprint) { throw "바인딩 카탈로그의 소스/런타임 HTS 설치 fingerprint가 일치하지 않습니다." }
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
        if ([string]$physicalPlan.status -ne 'READY' -and -not $AllowPartialScenarioPlan) {
            throw "물리 실행계획 상태가 READY가 아닙니다: $([string]$physicalPlan.status). 부분 실행은 -AllowPartialScenarioPlan을 명시해야 합니다."
        }
        $executableScenarioCaseIds = @($physicalPlan.executableCaseIds | ForEach-Object { [string]$_ })
    }
}
if ($requestedScenarioCaseIds.Count -gt 0 -and -not $scenarioMode) {
    throw "-CaseIdsCsv는 -ScenarioPlanPath와 함께 사용해야 합니다."
}
if ($requestedScenarioCaseIds.Count -gt 0) {
    $knownScenarioCaseIds = @($scenarioPlan.cases | ForEach-Object { [string]$_.caseId })
    $unknownRequestedCaseIds = @($requestedScenarioCaseIds | Where-Object { $knownScenarioCaseIds -notcontains $_ })
    if ($unknownRequestedCaseIds.Count -gt 0) { throw "시나리오 계획에 없는 caseId가 요청되었습니다: $($unknownRequestedCaseIds -join ', ')" }
    if (-not $PlanOnly) {
        $unboundRequestedCaseIds = @($requestedScenarioCaseIds | Where-Object { $executableScenarioCaseIds -notcontains $_ })
        if ($unboundRequestedCaseIds.Count -gt 0) { throw "물리 실행계획에서 실행 불가능한 caseId가 요청되었습니다: $($unboundRequestedCaseIds -join ', ')" }
    }
}
$runId = $targetContext.RunLabel + "-" + (Get-Date -Format "yyyyMMdd-HHmmss")
if (-not $ReportDir) { $ReportDir = Join-Path (Join-Path $root "reports") $runId }
$ReportDir = [IO.Path]::GetFullPath($ReportDir)
$screenshotsDir = Join-Path $ReportDir "screenshots"
New-Item -ItemType Directory -Force -Path $screenshotsDir | Out-Null
if ($scenarioMode) {
    Copy-Item -LiteralPath $scenarioPlanFullPath -Destination (Join-Path $ReportDir 'compiled-plan.json') -Force
    $scenarioReviewSource = Join-Path (Split-Path -Parent $scenarioPlanFullPath) 'scenario-review-items.json'
    if (Test-Path -LiteralPath $scenarioReviewSource) { Copy-Item -LiteralPath $scenarioReviewSource -Destination (Join-Path $ReportDir 'scenario-review-items.json') -Force }
    if ($physicalPlan) {
        Copy-Item -LiteralPath $physicalPlanFullPath -Destination (Join-Path $ReportDir 'physical-plan.json') -Force
        Copy-Item -LiteralPath $bindingCatalogSource -Destination (Join-Path $ReportDir 'binding-catalog.json') -Force
    }
}
$script:executionTracePath = Join-Path $ReportDir "execution-trace.ndjson"
if (Test-Path -LiteralPath $script:executionTracePath) { Remove-Item -LiteralPath $script:executionTracePath -Force }
$script:inputBoundaryAuditPath = Join-Path $ReportDir "input-boundary-audit.ndjson"
if (Test-Path -LiteralPath $script:inputBoundaryAuditPath) { Remove-Item -LiteralPath $script:inputBoundaryAuditPath -Force }

$resultEvaluationTestPackPath = $resolvedTestPackPath
$resultEvaluationWorkingDirectory = Join-Path $ReportDir 'result-evaluation'
$script:resultEvaluationSequence = 0

$mapCatalog = $null
$mapInitializationIssue = ""
$mapConfig = $dataset.autoExploration.mapBaseline
if ($mapConfig -and [bool]$mapConfig.enabled) {
    # MAP 위치와 파일 패턴은 autoExploration이 아니라 재사용 가능한 targetProfile에서 가져온다.
    $mapScreenDirectory = $targetContext.ScreenDirectory
    $installationRoot = $targetContext.InstallationRoot
    $mapCatalogPath = Join-Path $ReportDir "map-screen-models.json"
    $enabledMapScreens = @($dataset.screens | Where-Object enabled -ne $false | ForEach-Object { [string]$_.screenNumber })
    if($ScreensCsv){$requestedMapScreens=@($ScreensCsv.Split(',')|ForEach-Object{$_.Trim()}|Where-Object{$_ -and $enabledMapScreens -contains $_})}else{$requestedMapScreens=$enabledMapScreens}
    $mapScreensCsv = $requestedMapScreens -join ","
    try {
        $mapArgs = @('run', '--project', $cliProject, '-c', 'Release', '--no-build', '--', 'extract-map-models', '--screen-dir', $mapScreenDirectory, '--installation-root', $installationRoot, '--screens', $mapScreensCsv, '--file-pattern', $targetContext.MapFilePattern, '--out', $mapCatalogPath)
        if ($targetContext.MapFamilyFiles.Count -gt 0) { $mapArgs += @('--family-files', ($targetContext.MapFamilyFiles -join ',')) }
        & dotnet @mapArgs | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $mapCatalogPath)) { throw "MAP 모델 추출 명령이 결과 파일을 생성하지 못했습니다." }
        $mapCatalog = Get-Content -LiteralPath $mapCatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (@($mapCatalog.missingScreens).Count -gt 0) { $mapInitializationIssue = "MAP 파일 누락: " + (@($mapCatalog.missingScreens) -join ", ") }
        $integrityFailures = @($mapCatalog.integrityEntries | Where-Object { [string]$_.status -ne 'MATCH' })
        if ($integrityFailures.Count -gt 0) { $mapInitializationIssue = "HTS 설치 무결성 불일치: $($integrityFailures.Count)개" }
    } catch {
        $mapInitializationIssue = "MAP 기준 모델 초기화 실패: $($_.Exception.Message)"
    }
}

if ($DryRun) {
    & dotnet run --project $cliProject -c Release --no-build -- run-test-pack --file $resolvedTestPackPath --dry-run --report-dir $ReportDir | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "룰 드라이런에 실패했습니다." }
    $drySummaryPath=Join-Path $ReportDir "summary.json"
    if(Test-Path -LiteralPath $drySummaryPath){
        $drySummary=Get-Content -LiteralPath $drySummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $drySummary | Add-Member -NotePropertyName targetProfileId -NotePropertyValue $targetContext.ProfileId -Force
        $drySummary | Add-Member -NotePropertyName targetDisplayName -NotePropertyValue $targetContext.DisplayName -Force
        $drySummary | Add-Member -NotePropertyName datasetPath -NotePropertyValue ([string]$testPack.datasetSource) -Force
        $drySummary | Add-Member -NotePropertyName testPackPath -NotePropertyValue $resolvedTestPackPath -Force
        $mapDefinedCount=if($mapCatalog){($mapCatalog.screens|Measure-Object actionableControlCount -Sum).Sum}else{0}
        foreach($pair in @{
            automationEngine='FlaUI.UIA3';automationEngineVersion='5.0.0';automationExecution='드라이런이므로 UIA3 조작 미실행'
            flaUiDiscoveryCalls=0;flaUiElementsDiscovered=0;flaUiActionAttempts=0;flaUiActionSuccesses=0;flaUiFallbackRequests=0;flaUiFallbackReasons=@()
            mapModels=$(if($mapCatalog){@($mapCatalog.screens).Count}else{0});mapDefinedControls=$mapDefinedCount;mapBoundControls=0
            mapUnboundControls=0;runtimeOnlyControls=0;mapInitializationIssue=$(if($mapInitializationIssue){$mapInitializationIssue}elseif($mapCatalog){"드라이런이므로 실시간 MAP 결합은 실행하지 않았습니다."}else{""})
            mapOracleScreens=$(if($mapCatalog){@($mapCatalog.screens | Where-Object errorOracle).Count}else{0})
            mapOracleMessages=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.errorOracle.messageBoxes).Count } | Measure-Object -Sum).Sum}else{0})
            mapOracleExplicitErrors=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.errorOracle.messageBoxes | Where-Object isExplicitError).Count } | Measure-Object -Sum).Sum}else{0})
            mapOracleValidationMessages=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.errorOracle.messageBoxes | Where-Object classification -eq 'InputValidation').Count } | Measure-Object -Sum).Sum}else{0})
            mapBehaviorHandlers=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.behavior.eventHandlers).Count } | Measure-Object -Sum).Sum}else{0})
            mapQueryControls=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.behavior.queryControls).Count } | Measure-Object -Sum).Sum}else{0})
            mapStateControllers=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.behavior.stateControllerControls).Count } | Measure-Object -Sum).Sum}else{0})
            mapResultControls=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.behavior.resultControls).Count } | Measure-Object -Sum).Sum}else{0})
            mapReboundControls=0
            expectedEvents=0;reviewEvents=0;productDefects=0
            installationFingerprint=$(if($mapCatalog){[string]$mapCatalog.installationFingerprint}else{''})
            dependencyModels=$(if($mapCatalog){@($mapCatalog.dependencyScreens).Count}else{0})
            mapDependencies=$(if($mapCatalog){@($mapCatalog.dependencies).Count}else{0})
            unresolvedDependencies=$(if($mapCatalog){@($mapCatalog.dependencies | Where-Object { -not $_.isDynamic -and -not $_.targetExists }).Count}else{0})
            staticDataReferences=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object {@($_.dataReferences).Count} | Measure-Object -Sum).Sum}else{0})
            officialOptionControls=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object {@($_.controls | Where-Object {@($_.staticOptions).Count -gt 0}).Count} | Measure-Object -Sum).Sum}else{0})
            installedErrorCodes=$(if($mapCatalog){@($mapCatalog.errorCodes).Count}else{0})
            integrityMatched=$(if($mapCatalog){@($mapCatalog.integrityEntries | Where-Object status -eq 'MATCH').Count}else{0})
            integrityFailed=$(if($mapCatalog){@($mapCatalog.integrityEntries | Where-Object status -ne 'MATCH').Count}else{0})
        }.GetEnumerator()){$drySummary|Add-Member -NotePropertyName $pair.Key -NotePropertyValue $pair.Value -Force}
        $drySummary|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $drySummaryPath -Encoding UTF8
    }
    if (-not $SkipExcel) {
        Export-RuleResultWorkbooks $ReportDir
    }
    Write-Output $ReportDir
    return
}

# 네이티브 상호운용 계층: HWND 열거, 포커스, 좌표, 키보드/마우스 입력에 필요한 Win32 API만 선언한다.
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TargetRuleNative {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  public delegate bool EnumChildProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumChildProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll", SetLastError=true)] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetFocus(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint command);
  [DllImport("user32.dll")] public static extern bool IsChild(IntPtr hWndParent, IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool SetPhysicalCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetPhysicalCursorPos(out POINT point);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool LogicalToPhysicalPointForPerMonitorDPI(IntPtr hWnd, ref POINT point);
  [DllImport("user32.dll")] public static extern IntPtr GetNextDlgTabItem(IntPtr hDlg, IntPtr hCtl, bool previous);
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);
  [DllImport("user32.dll")] public static extern bool GetComboBoxInfo(IntPtr hwndCombo, ref COMBOBOXINFO info);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, string lParam);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true, EntryPoint="SendMessageTimeoutW")] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true, EntryPoint="SendMessageTimeoutW")] public static extern IntPtr SendMessageTimeoutText(IntPtr hWnd, uint msg, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr SendMessageText(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam);
  [DllImport("user32.dll", EntryPoint="GetWindowLong")] public static extern int GetWindowLong32(IntPtr hWnd, int index);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtr")] public static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int index);
  public static long GetStyle(IntPtr hWnd) { return IntPtr.Size == 8 ? GetWindowLongPtr64(hWnd, -16).ToInt64() : GetWindowLong32(hWnd, -16); }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
    public int dx; public int dy; public uint mouseData; public uint flags; public uint time; public UIntPtr extraInfo;
  }
  [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
    [FieldOffset(0)] public MOUSEINPUT mouse;
  }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT {
    public uint type; public INPUTUNION data;
  }
  public static bool SendLeftClick() {
    INPUT[] inputs = new INPUT[2];
    inputs[0].type = 0;
    inputs[0].data.mouse.flags = 0x0002;
    inputs[1].type = 0;
    inputs[1].data.mouse.flags = 0x0004;
    return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) == (uint)inputs.Length;
  }
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public int flags;
    public IntPtr hwndActive; public IntPtr hwndFocus; public IntPtr hwndCapture;
    public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret;
    public RECT rcCaret;
  }
  [StructLayout(LayoutKind.Sequential)] public struct COMBOBOXINFO {
    public int cbSize; public RECT rcItem; public RECT rcButton; public int stateButton;
    public IntPtr hwndCombo; public IntPtr hwndItem; public IntPtr hwndList;
  }
}
'@

$VK_CONTROL = 0x11
$VK_A = 0x41
$VK_V = 0x56
$VK_BACK = 0x08
$VK_RETURN = 0x0D
$VK_F12 = 0x7B
$VK_ESCAPE = 0x1B
$VK_HOME = 0x24
$VK_DOWN = 0x28
$VK_TAB = 0x09
$VK_LEFT = 0x25
$VK_RIGHT = 0x27
$KEYEVENTF_KEYUP = 0x0002
$SWP_NOSIZE = 0x0001
$SWP_NOMOVE = 0x0002
$HWND_TOPMOST = [IntPtr](-1)
$HWND_NOTOPMOST = [IntPtr](-2)
$WM_SETTEXT = 0x000C
$WM_GETTEXTLENGTH = 0x000E
$WM_CLOSE = 0x0010
$WM_MDIACTIVATE = 0x0222
$VK_MENU = 0x12
$script:activeHtsMainHwnd = [Int64]0
$script:activeHtsPid = 0
$script:activeInputSurfaceHwnd = [Int64]0
$script:activeInputSurfaceKind = 'None'
$script:activeInputSurfaceLabel = ''
$automationMetrics = New-HtsDiscoveryMetrics
$script:lastTextAutomationEngine = '미실행'

# manifest에 등록된 FlaUI 프로젝트의 Release UIA3 브리지 DLL 경로를 계산한다.
$flaUiProject = Resolve-RulePath $root ([string]$pipelineManifest.flaUiProject)
$flaUiAssembly = Join-Path (Split-Path -Parent $flaUiProject) 'bin\Release\net8.0-windows7.0\HtsQa.FlaUi.dll'
$sessionContext = New-HtsSessionContext `
    -FlaUiAssembly $flaUiAssembly `
    -TargetWindowClassName $script:targetWindowClassName `
    -TargetWindowTitlePrefix $script:targetWindowTitlePrefix `
    -DisplayName ([string]$targetContext.DisplayName) `
    -GetTopWindows { Get-TopWindows }

. (Join-Path $PSScriptRoot "modules\rule-control-exploration.ps1")
Initialize-RuleControlExploration $root $dataset $mapCatalog
if ($OrderTabStateOverride) { Set-RuleOrderTabState '0101' 'HT010115' $OrderTabStateOverride }
$script:ruleFastScenarioDiscovery = [bool]($scenarioMode -or $PlanOnly)
$discoveryDependencies = [pscustomobject]@{
    InvokeBridgeRequest = { param($Context, $Request) Invoke-FlaUiBridgeRequest -Context $Context -Request $Request }
    GetMapScreenModel = { param([string]$ScreenNumber, [string]$MapScreenCode) Get-RuleMapScreenModel $ScreenNumber $MapScreenCode }
    GetRuleDiscoveredControls = { param($Screen, [string]$ScreenNumber, [hashtable]$ClaimedHwnds) @(Get-RuleDiscoveredControls $Screen $ScreenNumber $ClaimedHwnds) }
}
$discoveryContext = New-HtsDiscoveryContext -SessionContext $sessionContext -Dependencies $discoveryDependencies -Metrics $automationMetrics
$bindingDependencies = [pscustomobject]@{
    GetChildWindows = { param([Int64]$Hwnd) @(Get-ChildWindows $Hwnd) }
    TestControlExecutionEligible = { param($Control) Test-RuleControlExecutionEligible $Control }
}
$bindingContext = New-HtsBindingContext -DiscoveryContext $discoveryContext -Dependencies $bindingDependencies
$actionDependencies = [pscustomobject]@{
    AssertClickScope = { param($Window,[int]$X,[int]$Y) Assert-HtsClickScope $Window $X $Y }
    GetActiveInputSurface = { Get-HtsActiveInputSurface }
    InvokeBridgeRequest = { param($Context,$Request) Invoke-FlaUiBridgeRequest -Context $Context -Request $Request }
    WriteInputAudit = { param([string]$InputType,[string]$Status,[int]$X,[int]$Y,[string]$Detail) Write-HtsInputBoundaryAudit $InputType $Status $X $Y $Detail }
    InvokeRuleControlPlanItem = { param($Navigation,$Screen,$PlanItem) Invoke-RuleControlPlanItem $Navigation $Screen $PlanItem }
    InvokeRuleDatasetVariable = { param($Window,[string]$Kind,[string]$Value,[string]$ValueMatch,[int]$MaxOptions) Invoke-RuleDatasetVariable $Window $Kind $Value $ValueMatch $MaxOptions }
}
$actionContext = New-HtsActionContext -SessionContext $sessionContext -Metrics $automationMetrics -Dependencies $actionDependencies

# 기존 rule-control과 navigation 호출 계약을 보존하는 얇은 Action 어댑터다.
function Invoke-FlaUiControlAction(
    $Window,
    [string]$Action,
    [string]$Value = '',
    [Nullable[int]]$Index = $null,
    [Nullable[bool]]$Checked = $null,
    [string]$Key = '') {
    Invoke-HtsFlaUiControlAction -Context $actionContext -Window $Window -Action $Action -Value $Value -Index $Index -Checked $Checked -Key $Key
}

# 기존 탐색 구현의 호출 계약을 유지하되 실제 UIA3 탐색과 계측은 Discovery 모듈에 위임한다.
function Get-FlaUiActionableControls($Screen) {
    @(Get-HtsFlaUiActionableControls -Context $discoveryContext -Screen $Screen)
}

# 공통 창·입력 유틸리티: 민감정보 보호와 모든 물리 입력의 HTS 경계 검사를 담당한다.
function Protect-Text([string]$Text, [string]$Secret = "") {
    if ($null -eq $Text) { return "" }
    $masked = $Text -replace '\b(\d{3})\d{5}-(\d{3})\b', '$1****$2'
    $masked = $masked -replace '\b(\d{3})\d{4,8}(\d{3})\b', '$1****$2'
    $masked = $masked -replace '\b\d{6}-\d{7}\b', '******-*******'
    if ($Secret) { $masked = $masked.Replace($Secret, "******") }
    $masked
}

# 단일 HWND의 소유 관계, 상태, 제목, 클래스와 화면 좌표를 같은 형태의 객체로 읽는다.
function Get-WindowInfo([IntPtr]$Hwnd) {
    [uint32]$windowPid = 0
    [void][TargetRuleNative]::GetWindowThreadProcessId($Hwnd, [ref]$windowPid)
    $title = New-Object Text.StringBuilder 1024
    $class = New-Object Text.StringBuilder 512
    [void][TargetRuleNative]::GetWindowText($Hwnd, $title, $title.Capacity)
    [void][TargetRuleNative]::GetClassName($Hwnd, $class, $class.Capacity)
    $rect = New-Object TargetRuleNative+RECT
    [void][TargetRuleNative]::GetWindowRect($Hwnd, [ref]$rect)
    [pscustomobject]@{
        hwnd = $Hwnd.ToInt64()
        parent = ([TargetRuleNative]::GetParent($Hwnd)).ToInt64()
        owner = ([TargetRuleNative]::GetWindow($Hwnd, 4)).ToInt64()
        pid = [int]$windowPid
        visible = [TargetRuleNative]::IsWindowVisible($Hwnd)
        enabled = [TargetRuleNative]::IsWindowEnabled($Hwnd)
        hung = [TargetRuleNative]::IsHungAppWindow($Hwnd)
        className = $class.ToString()
        rawTitle = $title.ToString()
        style = [TargetRuleNative]::GetStyle($Hwnd)
        rect = [pscustomobject]@{
            left = $rect.Left; top = $rect.Top; right = $rect.Right; bottom = $rect.Bottom
            width = $rect.Right - $rect.Left; height = $rect.Bottom - $rect.Top
        }
    }
}

# 클릭 좌표가 허용된 사각형 안에 포함되는지 경계값까지 포함해 검사한다.
function Test-HtsPointInRect([int]$X, [int]$Y, $Rect) {
    $Rect -and $X -ge [int]$Rect.left -and $X -lt [int]$Rect.right -and $Y -ge [int]$Rect.top -and $Y -lt [int]$Rect.bottom
}

# 화면 전환 중 이전 콘텐츠 HWND가 재사용되지 않도록 활성 입력 경계를 초기화한다.
function Clear-HtsInputSurface {
    $script:activeInputSurfaceHwnd=[Int64]0
    $script:activeInputSurfaceKind='None'
    $script:activeInputSurfaceLabel=''
}

# 이후 마우스·키보드 입력이 허용될 현재 메인 또는 콘텐츠 HWND를 등록한다.
function Set-HtsInputSurface($Window, [string]$Kind, [string]$Label = '') {
    if(-not $Window -or [Int64]$Window.hwnd -eq 0 -or -not [TargetRuleNative]::IsWindow([IntPtr][Int64]$Window.hwnd)){
        throw 'INPUT_SCOPE_BLOCKED: 활성 입력 표면이 유효하지 않습니다.'
    }
    $current=Get-WindowInfo ([IntPtr][Int64]$Window.hwnd)
    $mainHwnd=[IntPtr][Int64]$script:activeHtsMainHwnd
    if(-not [TargetRuleNative]::IsWindow($mainHwnd) -or [int]$current.pid -ne [int]$script:activeHtsPid){
        throw 'INPUT_SCOPE_BLOCKED: 입력 표면이 현재 HTS 프로세스에 속하지 않습니다.'
    }
    $main=Get-WindowInfo $mainHwnd
    if($Kind -eq 'Main' -and [Int64]$current.hwnd -ne [Int64]$main.hwnd){
        throw 'INPUT_SCOPE_BLOCKED: 메인 입력 단계의 표면이 HTS 메인창이 아닙니다.'
    }
    if($Kind -eq 'Content' -and -not [TargetRuleNative]::IsChild($mainHwnd,[IntPtr][Int64]$current.hwnd)){
        throw 'INPUT_SCOPE_BLOCKED: 콘텐츠 표면이 HTS 메인창의 자식 창이 아닙니다.'
    }
    $centerX=[int](($current.rect.left+$current.rect.right)/2)
    $centerY=[int](($current.rect.top+$current.rect.bottom)/2)
    if(-not (Test-HtsPointInRect $centerX $centerY $main.rect)){
        throw 'INPUT_SCOPE_BLOCKED: 입력 표면이 HTS 메인창 경계 밖에 있습니다.'
    }
    $script:activeInputSurfaceHwnd=[Int64]$current.hwnd
    $script:activeInputSurfaceKind=$Kind
    $script:activeInputSurfaceLabel=$Label
}

# 등록된 입력 경계가 아직 유효한 HWND인지 확인하고 최신 좌표로 다시 읽는다.
function Get-HtsActiveInputSurface {
    if($script:activeInputSurfaceHwnd -eq 0 -or -not [TargetRuleNative]::IsWindow([IntPtr][Int64]$script:activeInputSurfaceHwnd)){
        throw 'INPUT_SCOPE_BLOCKED: 활성 입력 표면이 없거나 사라졌습니다.'
    }
    Get-WindowInfo ([IntPtr][Int64]$script:activeInputSurfaceHwnd)
}

# 클릭 대상·PID·부모 관계·좌표가 현재 대상 콘텐츠 경계 안인지 모두 확인한다.
function Assert-HtsClickScope($Window, [int]$X, [int]$Y) {
    $main=Get-WindowInfo ([IntPtr][Int64]$script:activeHtsMainHwnd)
    $surface=Get-HtsActiveInputSurface
    if(-not (Test-HtsPointInRect $X $Y $main.rect)){
        throw "INPUT_SCOPE_BLOCKED: 클릭 좌표 ($X,$Y)가 HTS 메인창 밖에 있습니다."
    }
    if(-not (Test-HtsPointInRect $X $Y $surface.rect)){
        throw "INPUT_SCOPE_BLOCKED: 클릭 좌표 ($X,$Y)가 현재 대상 창 '$($script:activeInputSurfaceLabel)' 밖에 있습니다."
    }
    if($script:activeInputSurfaceKind -eq 'Content'){
        $screenNumber=Get-HtsScreenNumber $surface
        $policy=Get-RuleContentPolicy $screenNumber
        $probe=if($Window){$Window}else{[pscustomobject]@{rect=[pscustomobject]@{left=$X-1;right=$X+1;top=$Y-1;bottom=$Y+1;width=2;height=2};className='';rawTitle=''}}
        if(-not (Test-RuleContentControl $probe $surface $policy)){
            throw "INPUT_SCOPE_BLOCKED: 클릭 좌표 ($X,$Y)가 [$screenNumber] 콘텐츠 안전 영역 밖에 있습니다."
        }
    }
    $targetHwnd=if($Window -and $Window.PSObject.Properties.Name -contains 'hwnd'){[Int64]$Window.hwnd}else{[Int64]0}
    if($targetHwnd -ne 0){
        if(-not [TargetRuleNative]::IsWindow([IntPtr]$targetHwnd)){
            throw 'INPUT_SCOPE_BLOCKED: 클릭 대상 HWND가 더 이상 유효하지 않습니다.'
        }
        [uint32]$targetPid=0
        [void][TargetRuleNative]::GetWindowThreadProcessId([IntPtr]$targetHwnd,[ref]$targetPid)
        if([int]$targetPid -ne [int]$script:activeHtsPid){
            throw 'INPUT_SCOPE_BLOCKED: 클릭 대상이 HTS 프로세스에 속하지 않습니다.'
        }
        $surfaceHwnd=[IntPtr][Int64]$surface.hwnd
        if([Int64]$targetHwnd -ne [Int64]$surface.hwnd -and -not [TargetRuleNative]::IsChild($surfaceHwnd,[IntPtr]$targetHwnd)){
            throw 'INPUT_SCOPE_BLOCKED: 클릭 대상이 현재 대상 창의 자손이 아닙니다.'
        }
    }
}

# 현재 키보드 포커스가 등록된 입력 표면 또는 그 자식에 있을 때만 키 입력을 허용한다.
function Assert-HtsKeyboardScope {
    $surface=Get-HtsActiveInputSurface
    $info=New-Object TargetRuleNative+GUITHREADINFO
    $info.cbSize=[Runtime.InteropServices.Marshal]::SizeOf([type][TargetRuleNative+GUITHREADINFO])
    [void][TargetRuleNative]::GetGUIThreadInfo(0,[ref]$info)
    $focus=[Int64]$info.hwndFocus.ToInt64()
    if($focus -eq 0){throw 'INPUT_SCOPE_BLOCKED: HTS 내부 키보드 포커스를 찾지 못했습니다.'}
    if($focus -ne [Int64]$surface.hwnd -and -not [TargetRuleNative]::IsChild([IntPtr][Int64]$surface.hwnd,[IntPtr]$focus)){
        throw "INPUT_SCOPE_BLOCKED: 키보드 포커스가 현재 대상 창 '$($script:activeInputSurfaceLabel)' 밖에 있습니다."
    }
    if($script:activeInputSurfaceKind -eq 'Content' -and $focus -ne [Int64]$surface.hwnd){
        $focusWindow=Get-WindowInfo ([IntPtr]$focus)
        $screenNumber=Get-HtsScreenNumber $surface
        if(-not (Test-RuleContentControl $focusWindow $surface (Get-RuleContentPolicy $screenNumber))){
            throw "INPUT_SCOPE_BLOCKED: 키보드 포커스가 [$screenNumber] 콘텐츠 안전 영역 밖에 있습니다."
        }
    }
}

# 모든 허용·차단 입력을 NDJSON으로 남겨 외부 클릭 여부를 실행 후 감사할 수 있게 한다.
function Write-HtsInputBoundaryAudit([string]$InputType, [string]$Status, [int]$X = -1, [int]$Y = -1, [string]$Detail = '') {
    $mainRect=$null
    $surfaceRect=$null
    try{if($script:activeHtsMainHwnd -ne 0 -and [TargetRuleNative]::IsWindow([IntPtr][Int64]$script:activeHtsMainHwnd)){$mainRect=(Get-WindowInfo ([IntPtr][Int64]$script:activeHtsMainHwnd)).rect}}catch{}
    try{if($script:activeInputSurfaceHwnd -ne 0 -and [TargetRuleNative]::IsWindow([IntPtr][Int64]$script:activeInputSurfaceHwnd)){$surfaceRect=(Get-WindowInfo ([IntPtr][Int64]$script:activeInputSurfaceHwnd)).rect}}catch{}
    $line=([pscustomobject]@{
        timestamp=(Get-Date).ToString('o');inputType=$InputType;status=$Status;x=$X;y=$Y
        mainHwnd=[Int64]$script:activeHtsMainHwnd;mainRect=$mainRect;surfaceHwnd=[Int64]$script:activeInputSurfaceHwnd
        surfaceKind=[string]$script:activeInputSurfaceKind;surfaceLabel=[string]$script:activeInputSurfaceLabel;surfaceRect=$surfaceRect;detail=$Detail
    } | ConvertTo-Json -Compress -Depth 5)+[Environment]::NewLine
    for($attempt=1;$attempt-le5;$attempt++){
        $stream=$null
        try{
            $stream=[IO.FileStream]::new($script:inputBoundaryAuditPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
            [void]$stream.Seek(0,[IO.SeekOrigin]::End)
            $bytes=[Text.UTF8Encoding]::new($false).GetBytes($line)
            $stream.Write($bytes,0,$bytes.Length)
            $stream.Flush()
            return
        }catch [IO.IOException]{
            if($attempt-eq5){throw}
            Start-Sleep -Milliseconds (20*$attempt)
        }finally{
            if($stream){$stream.Dispose()}
        }
    }
}

# 현재 데스크톱의 최상위 창을 동일한 WindowInfo 객체 배열로 수집한다.
function Get-TopWindows {
    $rows = New-Object Collections.Generic.List[object]
    [void][TargetRuleNative]::EnumWindows({ param($h, $l) $rows.Add((Get-WindowInfo $h)); return $true }, [IntPtr]::Zero)
    $rows
}

# 지정 부모 아래의 네이티브 자식 HWND를 재귀 열거한다.
function Get-ChildWindows([Int64]$ParentHwnd) {
    $rows = New-Object Collections.Generic.List[object]
    [void][TargetRuleNative]::EnumChildWindows([IntPtr]$ParentHwnd, { param($h, $l) $rows.Add((Get-WindowInfo $h)); return $true }, [IntPtr]::Zero)
    for ($index=0; $index -lt $rows.Count; $index++) {
        $rows[$index] | Add-Member -NotePropertyName enumerationIndex -NotePropertyValue $index -Force
    }
    $rows
}

# 메인 상단의 화면 ID 입력칸 후보를 위치와 현재 값 형식으로 정렬한다.
function Find-ScreenNumberEdit($Main) {
    if ([int]$Main.rect.left -le -30000 -or [int]$Main.rect.top -le -30000) {
        [void][TargetRuleNative]::ShowWindow([IntPtr][Int64]$Main.hwnd, 9)
        [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$Main.hwnd)
        Start-Sleep -Milliseconds 500
        $Main = Get-WindowInfo ([IntPtr][Int64]$Main.hwnd)
    }
    $edit = Get-ChildWindows ([Int64]$Main.hwnd) | Where-Object {
        $_.visible -and $_.enabled -and $_.className -eq "Edit" -and
        $_.rect.left -lt ($Main.rect.left + 250) -and $_.rect.top -lt ($Main.rect.top + 90) -and $_.rect.width -ge 35 -and $_.rect.width -le 180
    } | Sort-Object @{ Expression = { if ($script:targetScreenIdRegex.IsMatch([string]$_.rawTitle)) { 0 } else { 1 } } }, { $_.rect.top }, { $_.rect.left } | Select-Object -First 1
    if (-not $edit) { throw "HTS 화면번호 입력칸을 찾을 수 없습니다." }
    $edit
}

# 화면번호 입력부는 일부 HTS 버전에서 owner-drawn 래퍼에 포함된다. UIA 성공만으로
# 입력 완료를 인정하지 않고, 창 메시지 접근성과 업무 화면 생성 결과를 함께 확인한다.
function Test-HtsScreenNavigationInputAccess($ScreenEdit) {
    $targetHwnd = [IntPtr][Int64]$ScreenEdit.hwnd
    [IntPtr]$messageResult = [IntPtr]::Zero
    $completed = [TargetRuleNative]::SendMessageTimeout($targetHwnd, $WM_GETTEXTLENGTH, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 1200, [ref]$messageResult)
    $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($completed -eq [IntPtr]::Zero -and $nativeError -eq 5) {
        throw "HTS_UI_ACCESS_DENIED: 화면번호 입력부 HWND=$([Int64]$ScreenEdit.hwnd)에 대한 Win32 메시지가 Access denied(5)로 차단되었습니다. HTS와 같은 권한 수준에서 실행해야 합니다."
    }
    if ($completed -eq [IntPtr]::Zero) {
        throw "SCREEN_NAVIGATION_INPUT_UNAVAILABLE: 화면번호 입력부 HWND=$([Int64]$ScreenEdit.hwnd) 접근을 확인하지 못했습니다. win32Error=$nativeError"
    }
    [int]$messageResult.ToInt64()
}

function Set-HtsScreenNumber($ScreenEdit, [string]$ScreenNumber) {
    [void](Test-HtsScreenNavigationInputAccess $ScreenEdit)
    $uiaResult = Invoke-FlaUiControlAction $ScreenEdit 'setText' -Value $ScreenNumber
    Start-Sleep -Milliseconds 180
    $current = Get-WindowInfo ([IntPtr][Int64]$ScreenEdit.hwnd)
    if ([string]$current.rawTitle -eq $ScreenNumber) {
        Write-HtsInputBoundaryAudit 'ScreenNavigationText' 'ALLOWED' -1 -1 "engine=FlaUI.UIA3; value=$ScreenNumber; nativeTextVerified=True"
        return
    }

    [IntPtr]$messageResult = [IntPtr]::Zero
    $completed = [TargetRuleNative]::SendMessageTimeoutText([IntPtr][Int64]$ScreenEdit.hwnd, $WM_SETTEXT, [IntPtr]::Zero, $ScreenNumber, 0x0002, 1200, [ref]$messageResult)
    $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($completed -eq [IntPtr]::Zero -and $nativeError -eq 5) {
        throw "HTS_UI_ACCESS_DENIED: UIA 화면번호 입력 결과를 네이티브로 확인하지 못했고 WM_SETTEXT도 Access denied(5)로 차단되었습니다. HTS와 같은 권한 수준에서 실행해야 합니다."
    }
    $current = Get-WindowInfo ([IntPtr][Int64]$ScreenEdit.hwnd)
    if ([string]$current.rawTitle -eq $ScreenNumber) {
        Write-HtsInputBoundaryAudit 'ScreenNavigationText' 'ALLOWED' -1 -1 "engine=Win32; value=$ScreenNumber; nativeTextVerified=True"
        return
    }
    if ([bool]$uiaResult.success -and [bool]$uiaResult.verified) {
        # 이 입력부는 값을 owner-drawn 래퍼에 그려 native window text가 비어 있을 수 있다.
        # 값 입력은 UIA 패턴으로 확인하고, 뒤이어 업무 화면 생성으로 종단 간 검증한다.
        Write-HtsInputBoundaryAudit 'ScreenNavigationText' 'ALLOWED' -1 -1 "engine=FlaUI.UIA3; value=$ScreenNumber; nativeTextVerified=False; ownerDrawn=True; screenCreationPending=True"
        return
    }
    if ($completed -ne [IntPtr]::Zero) {
        Write-HtsInputBoundaryAudit 'ScreenNavigationText' 'ALLOWED' -1 -1 "engine=Win32; value=$ScreenNumber; nativeTextVerified=False; ownerDrawn=True; screenCreationPending=True"
        return
    }
    $uiaDetail = "success=$([bool]$uiaResult.success), verified=$([bool]$uiaResult.verified)"
    throw "SCREEN_NAVIGATION_TEXT_UNVERIFIED: 화면번호 '$ScreenNumber' 입력을 확인하지 못했습니다. $uiaDetail; nativeText='$([string]$current.rawTitle)'; win32Error=$nativeError"
}

# 입력 직전 대상 프로세스를 전경으로 복구하고 다른 프로세스가 활성 상태면 입력을 차단한다.
function Assert-HtsForeground {
    if($script:activeHtsMainHwnd -eq 0 -or $script:activeHtsPid -eq 0){return}
    $mainHwnd=[IntPtr][Int64]$script:activeHtsMainHwnd
    if(-not [TargetRuleNative]::IsWindow($mainHwnd)){
        $replacement=$null
        try{$replacement=Wait-HtsMainWindow -Context $sessionContext -TimeoutMs 15000}catch{}
        if(-not $replacement){throw 'HTS_FOREGROUND_GUARD: HTS 메인 창이 사라졌고 새 메인 창도 찾지 못했습니다.'}
        $script:activeHtsMainHwnd=[Int64]$replacement.hwnd
        $script:activeHtsPid=[int]$replacement.pid
        $mainHwnd=[IntPtr][Int64]$script:activeHtsMainHwnd
    }
    $foreground=[TargetRuleNative]::GetForegroundWindow()
    [uint32]$foregroundPid=0
    $foregroundThread=if($foreground -ne [IntPtr]::Zero){[TargetRuleNative]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)}else{0}
    if([int]$foregroundPid -eq [int]$script:activeHtsPid){return}

    [uint32]$targetPid=0
    $targetThread=[TargetRuleNative]::GetWindowThreadProcessId($mainHwnd,[ref]$targetPid)
    $currentThread=[TargetRuleNative]::GetCurrentThreadId()
    $attachedForeground=$false
    $attachedTarget=$false
    try{
        if($foregroundThread -ne 0 -and $foregroundThread -ne $currentThread){$attachedForeground=[TargetRuleNative]::AttachThreadInput($currentThread,$foregroundThread,$true)}
        if($targetThread -ne 0 -and $targetThread -ne $currentThread){$attachedTarget=[TargetRuleNative]::AttachThreadInput($currentThread,$targetThread,$true)}
        [void][TargetRuleNative]::ShowWindow($mainHwnd,9)
        [void][TargetRuleNative]::BringWindowToTop($mainHwnd)
        [void][TargetRuleNative]::SetForegroundWindow($mainHwnd)
    }finally{
        if($attachedTarget){[void][TargetRuleNative]::AttachThreadInput($currentThread,$targetThread,$false)}
        if($attachedForeground){[void][TargetRuleNative]::AttachThreadInput($currentThread,$foregroundThread,$false)}
    }
    Start-Sleep -Milliseconds 120
    $foreground=[TargetRuleNative]::GetForegroundWindow()
    $foregroundPid=0
    if($foreground -ne [IntPtr]::Zero){[void][TargetRuleNative]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)}
    if([int]$foregroundPid -ne [int]$script:activeHtsPid){
        [TargetRuleNative]::keybd_event([byte]$VK_MENU,0,0,[UIntPtr]::Zero)
        [TargetRuleNative]::keybd_event([byte]$VK_MENU,0,$KEYEVENTF_KEYUP,[UIntPtr]::Zero)
        [void][TargetRuleNative]::SetForegroundWindow($mainHwnd)
        Start-Sleep -Milliseconds 120
        $foreground=[TargetRuleNative]::GetForegroundWindow()
        $foregroundPid=0
        if($foreground -ne [IntPtr]::Zero){[void][TargetRuleNative]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)}
    }
    if([int]$foregroundPid -ne [int]$script:activeHtsPid){
        $positionFlags=[uint32]($SWP_NOSIZE -bor $SWP_NOMOVE)
        [void][TargetRuleNative]::SetWindowPos($mainHwnd,$HWND_TOPMOST,0,0,0,0,$positionFlags)
        [void][TargetRuleNative]::BringWindowToTop($mainHwnd)
        [void][TargetRuleNative]::SetForegroundWindow($mainHwnd)
        [void][TargetRuleNative]::SetWindowPos($mainHwnd,$HWND_NOTOPMOST,0,0,0,0,$positionFlags)
        Start-Sleep -Milliseconds 150
        $foreground=[TargetRuleNative]::GetForegroundWindow()
        $foregroundPid=0
        if($foreground -ne [IntPtr]::Zero){[void][TargetRuleNative]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)}
    }
    if([int]$foregroundPid -ne [int]$script:activeHtsPid){
        [TargetRuleNative]::SwitchToThisWindow($mainHwnd,$true)
        Start-Sleep -Milliseconds 150
        $foreground=[TargetRuleNative]::GetForegroundWindow()
        $foregroundPid=0
        if($foreground -ne [IntPtr]::Zero){[void][TargetRuleNative]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)}
    }
    if([int]$foregroundPid -ne [int]$script:activeHtsPid){throw 'HTS_FOREGROUND_GUARD: HTS를 전경으로 확정하지 못해 입력을 차단했습니다.'}
}

# WindowFromPoint는 호출 프로세스의 DPI 좌표계를 사용하므로 논리 좌표로 최상단 HTS 창을 확인한다.
function Assert-HtsPhysicalPointOwner([int]$LogicalX, [int]$LogicalY, [int]$PhysicalX, [int]$PhysicalY) {
    $point=New-Object TargetRuleNative+POINT
    $point.X=$LogicalX
    $point.Y=$LogicalY
    $hitHwnd=[TargetRuleNative]::WindowFromPoint($point)
    [uint32]$hitPid=0
    if($hitHwnd -ne [IntPtr]::Zero){[void][TargetRuleNative]::GetWindowThreadProcessId($hitHwnd,[ref]$hitPid)}
    if([int]$hitPid -ne [int]$script:activeHtsPid){
        throw "HTS_POINT_OWNER_GUARD: 논리 좌표 ($LogicalX,$LogicalY), 물리 좌표 ($PhysicalX,$PhysicalY)의 최상단 창이 HTS 프로세스가 아닙니다. ownerPid=$hitPid"
    }
}

# Per-Monitor DPI 문맥에서 실제 커서 위치가 고정된 대상 HWND 위인지 마지막으로 확인한다.
function Assert-HtsPhysicalCursorTarget($ClickWindow, $PhysicalPoint) {
    $hitHwnd=[TargetRuleNative]::WindowFromPoint($PhysicalPoint)
    [uint32]$hitPid=0
    if($hitHwnd -ne [IntPtr]::Zero){[void][TargetRuleNative]::GetWindowThreadProcessId($hitHwnd,[ref]$hitPid)}
    if([int]$hitPid -ne [int]$script:activeHtsPid){
        throw "HTS_PHYSICAL_CURSOR_OWNER_GUARD: 실제 커서 위치 ($([int]$PhysicalPoint.X),$([int]$PhysicalPoint.Y))의 최상단 창이 HTS 프로세스가 아닙니다. ownerPid=$hitPid"
    }
    $targetHwnd=if($ClickWindow -and $ClickWindow.PSObject.Properties.Name -contains 'hwnd'){[IntPtr][Int64]$ClickWindow.hwnd}else{[IntPtr]::Zero}
    if($targetHwnd -ne [IntPtr]::Zero -and $hitHwnd -ne $targetHwnd -and -not [TargetRuleNative]::IsChild($targetHwnd,$hitHwnd)){
        throw "HTS_PHYSICAL_CURSOR_TARGET_GUARD: 실제 커서 위치가 고정 대상 HWND와 다릅니다. targetHwnd=$([Int64]$targetHwnd), hitHwnd=$([Int64]$hitHwnd)"
    }
    [pscustomobject]@{hitHwnd=[Int64]$hitHwnd;targetHwnd=[Int64]$targetHwnd;ownerPid=[int]$hitPid}
}

# 전경·포커스 경계를 검증한 뒤 단일 가상 키의 누름과 해제를 전송한다.
function Send-Key([byte]$Key) {
    $foregroundReady=$false
    $foregroundError=''
    for($attempt=0;$attempt -lt 3;$attempt++){
        try{Assert-HtsForeground;$foregroundReady=$true;break}catch{$foregroundError=$_.Exception.Message;Start-Sleep -Milliseconds 250}
    }
    if(-not $foregroundReady){Write-HtsInputBoundaryAudit 'Keyboard' 'BLOCKED' -1 -1 $foregroundError;throw $foregroundError}
    try{Assert-HtsKeyboardScope}catch{Write-HtsInputBoundaryAudit 'Keyboard' 'BLOCKED' -1 -1 $_.Exception.Message;throw}
    Write-HtsInputBoundaryAudit 'Keyboard' 'ALLOWED' -1 -1 ("VK={0}" -f $Key)
    [TargetRuleNative]::keybd_event($Key, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
    [TargetRuleNative]::keybd_event($Key, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
}

# 물리 커서 이동이 제한된 세션에서도 화면번호 Edit HWND에 직접 포커스를 주고
# 키 입력 범위를 검증한다. 화면 열기는 버튼 조작이 아닌 이 경로를 우선 사용한다.
function Focus-HtsInputWindow($Window) {
    if (-not $Window -or -not ($Window.PSObject.Properties.Name -contains 'hwnd') -or [Int64]$Window.hwnd -eq 0) {
        throw 'INPUT_SCOPE_BLOCKED: 포커스 대상 HWND가 없습니다.'
    }
    $targetHwnd = [IntPtr][Int64]$Window.hwnd
    if (-not [TargetRuleNative]::IsWindow($targetHwnd)) { throw 'INPUT_SCOPE_BLOCKED: 포커스 대상 HWND가 더 이상 유효하지 않습니다.' }
    Assert-HtsForeground
    [uint32]$targetPid = 0
    $targetThread = [TargetRuleNative]::GetWindowThreadProcessId($targetHwnd, [ref]$targetPid)
    if ([int]$targetPid -ne [int]$script:activeHtsPid) { throw 'INPUT_SCOPE_BLOCKED: 포커스 대상이 HTS 프로세스에 속하지 않습니다.' }
    $currentThread = [TargetRuleNative]::GetCurrentThreadId()
    $attached = $false
    try {
        if ($targetThread -ne 0 -and $targetThread -ne $currentThread) {
            $attached = [TargetRuleNative]::AttachThreadInput($currentThread, $targetThread, $true)
        }
        [void][TargetRuleNative]::SetFocus($targetHwnd)
    } finally {
        if ($attached) { [void][TargetRuleNative]::AttachThreadInput($currentThread, $targetThread, $false) }
    }
    $info = New-Object TargetRuleNative+GUITHREADINFO
    $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][TargetRuleNative+GUITHREADINFO])
    [void][TargetRuleNative]::GetGUIThreadInfo(0, [ref]$info)
    $focus = [Int64]$info.hwndFocus.ToInt64()
    if ($focus -ne [Int64]$targetHwnd) {
        $detail = "expected=$([Int64]$targetHwnd), actual=$focus, targetThread=$targetThread, currentThread=$currentThread, attached=$attached"
        Write-HtsInputBoundaryAudit 'KeyboardFocus' 'BLOCKED' -1 -1 $detail
        throw "INPUT_SCOPE_BLOCKED: 화면번호 입력창 포커스를 검증하지 못했습니다. $detail"
    }
    Write-HtsInputBoundaryAudit 'KeyboardFocus' 'ALLOWED' -1 -1 "targetHwnd=$([Int64]$targetHwnd)"
}

# 최신 창 좌표의 중심점을 계산하고 클릭 경계 감사 후 왼쪽 클릭을 전송한다.
function Click-Center($Window, [switch]$DoubleClick) {
    $foregroundReady=$false
    $foregroundError=''
    for($attempt=0;$attempt -lt 3;$attempt++){
        try{Assert-HtsForeground;$foregroundReady=$true;break}catch{$foregroundError=$_.Exception.Message;Start-Sleep -Milliseconds 250}
    }
    if(-not $foregroundReady){Write-HtsInputBoundaryAudit 'MouseClick' 'BLOCKED' -1 -1 $foregroundError;throw $foregroundError}
    $clickWindow=$Window
    if($Window -and $Window.PSObject.Properties.Name -contains 'hwnd' -and [Int64]$Window.hwnd -ne 0){
        if(-not [TargetRuleNative]::IsWindow([IntPtr][Int64]$Window.hwnd)){throw 'INPUT_SCOPE_BLOCKED: 클릭 직전에 대상 HWND가 사라졌습니다.'}
        $clickWindow=Get-WindowInfo ([IntPtr][Int64]$Window.hwnd)
    }
    $x = [int](($clickWindow.rect.left + $clickWindow.rect.right) / 2)
    $y = [int](($clickWindow.rect.top + $clickWindow.rect.bottom) / 2)
    try{Assert-HtsClickScope $clickWindow $x $y}catch{Write-HtsInputBoundaryAudit 'MouseClick' 'BLOCKED' $x $y $_.Exception.Message;throw}
    $physicalPoint = New-Object TargetRuleNative+POINT
    $physicalPoint.X = $x
    $physicalPoint.Y = $y
    $mainHwnd = [IntPtr][Int64]$script:activeHtsMainHwnd
    $converted = $mainHwnd -ne [IntPtr]::Zero -and [TargetRuleNative]::LogicalToPhysicalPointForPerMonitorDPI($mainHwnd,[ref]$physicalPoint)
    if (-not $converted) {
        $dpi = if ($mainHwnd -ne [IntPtr]::Zero) { [int][TargetRuleNative]::GetDpiForWindow($mainHwnd) } else { 96 }
        if ($dpi -ne 96) {
            $message = "DPI_POINT_CONVERSION_FAILED: logical=($x,$y), dpi=$dpi"
            Write-HtsInputBoundaryAudit 'MouseClick' 'BLOCKED' $x $y $message
            throw $message
        }
    }
    $physicalX = [int]$physicalPoint.X
    $physicalY = [int]$physicalPoint.Y
    $ownerReady=$false
    $ownerError=''
    for($attempt=0;$attempt -lt 3;$attempt++){
        try{
            Assert-HtsForeground
            Assert-HtsPhysicalPointOwner $x $y $physicalX $physicalY
            $ownerReady=$true
            break
        }catch{
            $ownerError=$_.Exception.Message
            Start-Sleep -Milliseconds 200
        }
    }
    if(-not $ownerReady){
        Write-HtsInputBoundaryAudit 'MouseClick' 'BLOCKED' $physicalX $physicalY $ownerError
        throw $ownerError
    }
    $targetName = if($clickWindow.rawTitle){[string]$clickWindow.rawTitle}else{[string]$clickWindow.className}
    $previousDpiContext=[TargetRuleNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
    if($previousDpiContext -eq [IntPtr]::Zero){
        $message="DPI_THREAD_CONTEXT_FAILED: logical=($x,$y), physical=($physicalX,$physicalY)"
        Write-HtsInputBoundaryAudit 'MouseClick' 'BLOCKED' $physicalX $physicalY $message
        throw $message
    }
    $actualPoint=New-Object TargetRuleNative+POINT
    $targetHit=$null
    try {
        $cursorSet = $false
        if ($script:visiblePointerMotion) {
            $startPoint = New-Object TargetRuleNative+POINT
            if ([TargetRuleNative]::GetPhysicalCursorPos([ref]$startPoint)) {
                $distance = [Math]::Sqrt([Math]::Pow($physicalX-[int]$startPoint.X,2)+[Math]::Pow($physicalY-[int]$startPoint.Y,2))
                $motionSteps = [Math]::Min(24,[Math]::Max(8,[int][Math]::Ceiling($distance/70)))
                for ($motionStep=1; $motionStep -le $motionSteps; $motionStep++) {
                    $ratio = $motionStep/[double]$motionSteps
                    $motionX = [int][Math]::Round([int]$startPoint.X+(($physicalX-[int]$startPoint.X)*$ratio))
                    $motionY = [int][Math]::Round([int]$startPoint.Y+(($physicalY-[int]$startPoint.Y)*$ratio))
                    if (-not [TargetRuleNative]::SetPhysicalCursorPos($motionX,$motionY)) { break }
                    $cursorSet = $motionStep -eq $motionSteps
                    Start-Sleep -Milliseconds 30
                }
            }
        } else {
            $cursorSet = [TargetRuleNative]::SetPhysicalCursorPos($physicalX,$physicalY)
        }
        if(-not $cursorSet){throw "PHYSICAL_CURSOR_SET_FAILED: logical=($x,$y), physical=($physicalX,$physicalY)"}
        if(-not [TargetRuleNative]::GetPhysicalCursorPos([ref]$actualPoint) -or [Math]::Abs([int]$actualPoint.X-$physicalX)-gt1 -or [Math]::Abs([int]$actualPoint.Y-$physicalY)-gt1){
            throw "PHYSICAL_CURSOR_VERIFY_FAILED: expected=($physicalX,$physicalY), actual=($([int]$actualPoint.X),$([int]$actualPoint.Y))"
        }
        $targetHit=Assert-HtsPhysicalCursorTarget $clickWindow $actualPoint
        if ($script:pointerDwellMilliseconds -gt 0) { Start-Sleep -Milliseconds $script:pointerDwellMilliseconds }
        if(-not [TargetRuleNative]::SendLeftClick()){
            $nativeError=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "SEND_INPUT_CLICK_FAILED: logical=($x,$y), physical=($physicalX,$physicalY), win32Error=$nativeError"
        }
        if ($DoubleClick) {
            Start-Sleep -Milliseconds 60
            Assert-HtsForeground
            if(-not [TargetRuleNative]::SendLeftClick()){
                $nativeError=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "SEND_INPUT_DOUBLE_CLICK_FAILED: logical=($x,$y), physical=($physicalX,$physicalY), win32Error=$nativeError"
            }
        }
    } catch {
        Write-HtsInputBoundaryAudit 'MouseClick' 'BLOCKED' $physicalX $physicalY $_.Exception.Message
        throw
    } finally {
        [void][TargetRuleNative]::SetThreadDpiAwarenessContext($previousDpiContext)
    }
    Write-HtsInputBoundaryAudit 'MouseClick' 'ALLOWED' $physicalX $physicalY "$targetName; logical=($x,$y); physicalTarget=($physicalX,$physicalY); physicalVerified=($([int]$actualPoint.X),$([int]$actualPoint.Y)); targetHwnd=$([Int64]$targetHit.targetHwnd); hitHwnd=$([Int64]$targetHit.hitHwnd); dpiThreadContext=PER_MONITOR_AWARE_V2; coordinateSpace=physical; inputEngine=SendInput; clickCount=$(if($DoubleClick){2}else{1}); visiblePointerMotion=$([bool]$script:visiblePointerMotion); dwellMs=$([int]$script:pointerDwellMilliseconds)"
    Start-Sleep -Milliseconds 120
}

# FlaUI UIA3 ValuePattern을 우선 사용하고 비지원 사용자 정의 입력만 Win32/키보드로 보완한다.
function Set-AutomationText($Window, [string]$Value, [switch]$Sensitive, [switch]$AlreadyFocused) {
    $script:lastTextAutomationEngine = 'Win32 fallback'
    $scopeWindow=$Window
    if($Window -and $Window.PSObject.Properties.Name -contains 'hwnd' -and [Int64]$Window.hwnd -ne 0){
        if(-not [TargetRuleNative]::IsWindow([IntPtr][Int64]$Window.hwnd)){throw 'INPUT_SCOPE_BLOCKED: 입력 직전에 대상 HWND가 사라졌습니다.'}
        $scopeWindow=Get-WindowInfo ([IntPtr][Int64]$Window.hwnd)
    }
    $scopeX=[int](($scopeWindow.rect.left+$scopeWindow.rect.right)/2)
    $scopeY=[int](($scopeWindow.rect.top+$scopeWindow.rect.bottom)/2)
    Assert-HtsClickScope $scopeWindow $scopeX $scopeY
    if (-not ([Int64]$Window.hwnd -eq 0 -and $Window.className -eq "ConfiguredVisualHotspot")) {
        $flaUiResult = Invoke-FlaUiControlAction $Window 'setText' -Value $Value
        if ([bool]$flaUiResult.success -and [bool]$flaUiResult.verified) {
            $script:lastTextAutomationEngine = 'FlaUI.UIA3'
            return $true
        }
    }
    if ([Int64]$Window.hwnd -eq 0 -and $Window.className -eq "ConfiguredVisualHotspot") {
        if ($Sensitive) { return $false }
        if (-not $AlreadyFocused) { Click-Center $Window }
        Assert-HtsKeyboardScope
        [TargetRuleNative]::keybd_event([byte]$VK_CONTROL, 0, 0, [UIntPtr]::Zero)
        Send-Key ([byte]$VK_A)
        [TargetRuleNative]::keybd_event([byte]$VK_CONTROL, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
        Send-Key ([byte]$VK_BACK)
        Assert-HtsKeyboardScope
        [Windows.Forms.SendKeys]::SendWait($Value)
        Start-Sleep -Milliseconds 200
        return $true
    }
    [void][TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd, $WM_SETTEXT, [IntPtr]::Zero, $Value)
    Start-Sleep -Milliseconds 150
    $current = Get-WindowInfo ([IntPtr][Int64]$Window.hwnd)
    $length = [TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd, $WM_GETTEXTLENGTH, [IntPtr]::Zero, [IntPtr]::Zero).ToInt64()
    $sentByVirtualKeys = $false
    $needsFallback = if ($Sensitive) { $length -le 0 } else { [string]$current.rawTitle -ne $Value }
    if ($needsFallback) {
        $inputPoint = [pscustomobject]@{rect=[pscustomobject]@{left=$Window.rect.left;right=[Math]::Min($Window.rect.right,$Window.rect.left+48);top=$Window.rect.top;bottom=$Window.rect.bottom}}
        if (-not $AlreadyFocused) { Click-Center $inputPoint }
        Assert-HtsKeyboardScope
        [TargetRuleNative]::keybd_event([byte]$VK_CONTROL, 0, 0, [UIntPtr]::Zero)
        Send-Key ([byte]$VK_A)
        [TargetRuleNative]::keybd_event([byte]$VK_CONTROL, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
        Send-Key ([byte]$VK_BACK)
        if ($Sensitive -or $Value -match '^[0-9]+$') {
            foreach ($ch in $Value.ToCharArray()) {
                if ($ch -notmatch '[0-9]') { return $false }
                Send-Key ([byte](0x30 + [int][string]$ch))
            }
            $sentByVirtualKeys = $true
        } else {
            Assert-HtsKeyboardScope
            [Windows.Forms.SendKeys]::SendWait($Value)
        }
        Start-Sleep -Milliseconds 150
        $current = Get-WindowInfo ([IntPtr][Int64]$Window.hwnd)
        if (-not $Sensitive -and [string]$current.rawTitle -notlike "*$Value*") {
            Click-Center $inputPoint
            Assert-HtsKeyboardScope
            [TargetRuleNative]::keybd_event([byte]$VK_CONTROL,0,0,[UIntPtr]::Zero)
            Send-Key ([byte]$VK_A)
            [TargetRuleNative]::keybd_event([byte]$VK_CONTROL,0,$KEYEVENTF_KEYUP,[UIntPtr]::Zero)
            [Windows.Forms.Clipboard]::SetText($Value)
            [TargetRuleNative]::keybd_event([byte]$VK_CONTROL,0,0,[UIntPtr]::Zero)
            Send-Key ([byte]$VK_V)
            [TargetRuleNative]::keybd_event([byte]$VK_CONTROL,0,$KEYEVENTF_KEYUP,[UIntPtr]::Zero)
            Start-Sleep -Milliseconds 150
            $current = Get-WindowInfo ([IntPtr][Int64]$Window.hwnd)
            $sentByVirtualKeys = $true
        }
        $length = [TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd, $WM_GETTEXTLENGTH, [IntPtr]::Zero, [IntPtr]::Zero).ToInt64()
    }
    return $(if ($Sensitive) { $length -gt 0 -or $sentByVirtualKeys } elseif ([string]$current.rawTitle -eq $Value) { $true } else { $sentByVirtualKeys })
}

# 화면 수명주기: 번호 입력, 대상 창 식별, 연계 창 정리와 순차 종료를 한 화면 단위로 관리한다.
function Open-HtsScreen($Main, $ScreenEdit, [string]$ScreenNumber) {
    Open-HtsNavigationScreen -Context $navigationContext -Main $Main -ScreenEdit $ScreenEdit -ScreenNumber $ScreenNumber
}

# 요청 화면 ID가 제목에 표시된 가장 큰 자식 창을 대상 화면으로 선택한다.
function Find-ScreenWindow($Main, [string]$ScreenNumber) {
    Find-HtsNavigationScreenWindow -Context $navigationContext -Main $Main -ScreenNumber $ScreenNumber
}

# targetProfile 화면 정규식으로 자식 창 제목에서 화면 ID를 추출한다.
function Get-HtsScreenNumber($Window) {
    Get-HtsNavigationScreenNumber -Context $navigationContext -Window $Window
}

# 대상 화면 형식과 최소 콘텐츠 크기를 만족하는 열린 업무 화면을 나열한다.
function Get-HtsScreenWindows($Main) {
    @(Get-HtsNavigationScreenWindows -Context $navigationContext -Main $Main)
}

# HWND가 살아 있고 현재 제목의 화면 ID가 요청값과 같은지 확인한다.
function Test-HtsRequestedScreen($Screen, [string]$ScreenNumber) {
    Test-HtsNavigationRequestedScreen -Context $navigationContext -Screen $Screen -ScreenNumber $ScreenNumber
}

# MDI 활성화와 전경 복구 후 요청 화면을 현재 입력 콘텐츠로 등록한다.
function Focus-HtsRequestedScreen($Main, $Screen, [string]$ScreenNumber) {
    Focus-HtsNavigationRequestedScreen -Context $navigationContext -Main $Main -Screen $Screen -ScreenNumber $ScreenNumber
}

# 조작 중 추가로 열린 화면을 요청 화면과 분리해 연계 화면으로 반환한다.
function Get-HtsLinkedScreens($Main, [string]$RequestedScreenNumber) {
    @(Get-HtsNavigationLinkedScreens -Context $navigationContext -Main $Main -RequestedScreenNumber $RequestedScreenNumber)
}

# 요청 화면을 제외한 연계 화면을 닫고 실제 종료된 수를 반환한다.
function Close-HtsLinkedScreens($Main, [string]$RequestedScreenNumber) {
    Close-HtsNavigationLinkedScreens -Context $navigationContext -Main $Main -RequestedScreenNumber $RequestedScreenNumber
}

# 후보 화면 안의 입력 가능 자식 수를 계산해 실제 콘텐츠가 있는 창을 우선한다.
function Get-HtsInputSurfaceScore($Window) {
    Get-HtsNavigationInputSurfaceScore -Context $navigationContext -Window $Window
}

# 정확한 화면 ID, 새 HWND와 입력 가능 컨트롤 수를 조합해 콘텐츠 표면을 결정한다.
function Find-BestHtsContentSurface($Main, $RequestedWindow, [string]$RequestedScreenNumber, [Int64[]]$BaselineScreenHwnds = @()) {
    Find-HtsNavigationBestContentSurface -Context $navigationContext -Main $Main -RequestedWindow $RequestedWindow -RequestedScreenNumber $RequestedScreenNumber -BaselineScreenHwnds $BaselineScreenHwnds
}

# 대상 프로세스의 자식 화면에만 WM_CLOSE를 보내고 HWND 소멸까지 확인한다.
function Close-HtsScreen($Screen) {
    Close-HtsNavigationScreen -Context $navigationContext -Screen $Screen
}

# 새 케이스 시작 전에 targetProfile 형식의 기존 업무 화면을 모두 정리한다.
function Close-ExistingTargetScreens($Main) {
    Close-HtsNavigationExistingTargetScreens -Context $navigationContext -Main $Main
}

function Test-PreservedTargetScreen($Window) {
    Test-HtsNavigationPreservedTargetScreen -Context $navigationContext -Window $Window
}

# 화면번호 입력을 가릴 수 있는 화면검색 오버레이만 선택적으로 닫는다.
function Close-ScreenSearchOverlays($Main) {
    Close-HtsNavigationSearchOverlays -Context $navigationContext -Main $Main
}

# 팝업 관찰: 현재 HTS 프로세스의 새 대화상자를 읽고 민감 문구를 제거한 관찰 객체를 만든다.
function Get-HtsDialogs($Main, [string]$Secret = "") {
    foreach ($window in @(Get-TopWindows | Where-Object {
        $_.visible -and $_.pid -eq $Main.pid -and $_.hwnd -ne $Main.hwnd -and
        -not $script:targetScreenTitleRegex.IsMatch([string]$_.rawTitle) -and
        ($_.className -eq "#32770" -or $_.rawTitle -eq "하나증권" -or $_.rawTitle -match '유의사항|참고사항|안내|경고|확인|설정|편집|도움말' -or
            ($_.owner -eq $Main.hwnd -and ($_.rawTitle -or $_.className -notlike 'AfxWnd*')))
    })) {
        $children = @(Get-ChildWindows ([Int64]$window.hwnd) | Where-Object { $_.visible })
        $buttons = @($children | Where-Object { $_.className -like "*Button*" -and $_.rawTitle } | ForEach-Object { Protect-Text $_.rawTitle $Secret } | Sort-Object -Unique)
        $messages = @($children | Where-Object { $_.className -notlike "*Button*" -and $_.rawTitle } | ForEach-Object { Protect-Text $_.rawTitle $Secret } | Sort-Object -Unique)
        $title = Protect-Text $window.rawTitle $Secret
        $text = Protect-Text ((@($title) + $messages + $buttons | Where-Object { $_ } | Sort-Object -Unique) -join " | ") $Secret
        $classification = if ($text -match '오류|에러|실패|예외|장애|Error|Exception|Fail|SOCKET') {
            "오류"
        } elseif ($text -match '경고|주의|Warning') {
            "경고"
        } elseif ($buttons -match '예|아니오|Yes|No|확인|취소') {
            "확인 요청"
        } else {
            "정보"
        }
        [pscustomobject]@{
            window = $window
            title = $title
            messageLines = $messages
            buttons = $buttons
            classification = $classification
            text = $text
            summary = "$classification 팝업: " + $(if ($messages.Count -gt 0) { $messages -join " / " } elseif ($title) { $title } else { "본문 없음" })
        }
    }
}

# 오류 오라클: MAP 원문, 공식 오류코드, 값별 기대 계약과 시스템 실패 우선순위를 결합한다.
function Get-MapOracleMessageMatch([string]$Text, $MapOracle) {
    if (-not $MapOracle -or [string]::IsNullOrWhiteSpace($Text)) { return $null }
    $rank = @{ Error=0; InputValidation=1; Warning=2; Info=3 }
    $matches = @($MapOracle.messageBoxes | Where-Object {
        $message = [string]$_.message
        $title = [string]$_.title
        ($message -and $Text.IndexOf($message, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
        ($title -and $Text.IndexOf($title, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    } | Sort-Object @{Expression={if($rank.ContainsKey([string]$_.classification)){$rank[[string]$_.classification]}else{9}}}, ruleId)
    if ($matches.Count -gt 0) { return $matches[0] }
    return $null
}

# 설치 카탈로그의 공식 오류코드·문구가 관찰 문자열에 포함됐는지 찾는다.
function Get-InstallationErrorCodeMatch([string]$Text) {
    if (-not $mapCatalog -or -not $mapCatalog.errorCodes -or [string]::IsNullOrWhiteSpace($Text)) { return $null }
    $matches = @($mapCatalog.errorCodes | Where-Object {
        $code = [string]$_.code
        $message = [string]$_.message
        ($code -and $Text -match "(?<![0-9])$([regex]::Escape($code))(?![0-9])") -or
        ($message.Length -ge 6 -and $Text.IndexOf($message, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    } | Sort-Object @{Expression={if([bool]$_.isFailure){0}else{1}}}, code)
    if ($matches.Count -gt 0) { return $matches[0] }
    $null
}

# 선택지의 명시 기대 계약을 정규화하고 화면 수준 패턴은 최후 근거로만 보충한다.
function Get-RuleExpectedOutcome($Option, $FallbackPatterns = @()) {
    $source = if ($Option -and $Option.expectedOutcome) { $Option.expectedOutcome } else { $null }
    $type = if ($source -and $source.type) { [string]$source.type } elseif(@($FallbackPatterns).Count -gt 0) { 'ValidationAllowed' } else { 'Unspecified' }
    $expectationSource = if($source -and $source.source -and [string]$source.source -ne 'Unspecified') {[string]$source.source} elseif($source -and $type -ne 'Unspecified') {'Dataset'} elseif(@($FallbackPatterns).Count -gt 0) {'ScreenExpectedPattern'} else {'Unspecified'}
    $confidence = if($source -and $source.confidence -and [string]$source.confidence -ne 'Unspecified') {[string]$source.confidence} elseif($source -and $type -ne 'Unspecified') {'High'} elseif(@($FallbackPatterns).Count -gt 0) {'Medium'} else {'Unspecified'}
    $patterns = New-Object Collections.Generic.List[string]
    foreach($pattern in @($FallbackPatterns) + @($(if($source){$source.messagePatterns}else{@()}))){
        if(-not [string]::IsNullOrWhiteSpace([string]$pattern) -and -not $patterns.Contains([string]$pattern)){$patterns.Add([string]$pattern)}
    }
    $evidence = New-Object Collections.Generic.List[string]
    foreach($item in @($(if($source){$source.evidence}else{@()}))){
        if(-not [string]::IsNullOrWhiteSpace([string]$item) -and -not $evidence.Contains([string]$item)){$evidence.Add([string]$item)}
    }
    if(@($FallbackPatterns).Count -gt 0 -and $evidence.Count -eq 0){$evidence.Add('화면 데이터셋 expectedPopupPatterns')}
    [pscustomobject]@{
        type=$type
        source=$expectationSource
        confidence=$confidence
        evidence=$evidence.ToArray()
        messagePatterns=$patterns.ToArray()
        errorCodes=@($(if($source){$source.errorCodes}else{@()}))
        queryShouldComplete=$(if($source){$source.queryShouldComplete}else{$null})
        expectationId=$(if($Option){[string]$Option.id}else{'screen-default'})
    }
}

# 컨트롤 실행 사실을 원시 Observation으로 넘기고 현재 케이스의 Core 평가 입력에 함께 보존한다.
function Invoke-HtsRawObservationEvaluation(
    [string]$ObservationKind,
    [string]$Text,
    [string]$SourceCode,
    $ExpectedOutcome,
    [bool]$Executed = $true,
    [bool]$EvidencePresent = $true,
    [string]$Prefix = 'control') {
    $script:resultEvaluationSequence++
    $evaluation = Invoke-RuleSignalEvaluation `
        -CliProject $cliProject `
        -TestPackPath $resultEvaluationTestPackPath `
        -WorkingDirectory $resultEvaluationWorkingDirectory `
        -CaseId ("{0}-{1:D6}" -f $Prefix, $script:resultEvaluationSequence) `
        -EventType $ObservationKind `
        -Text $Text `
        -SourceCode $SourceCode `
        -Source 'PowerShell raw observation' `
        -Executed $Executed `
        -EvidencePresent $EvidencePresent `
        -ExpectedOutcome $ExpectedOutcome
    if ($script:currentResultEvaluationCases) { $script:currentResultEvaluationCases.Add($evaluation.evaluationCase) }
    $evaluation
}

# 입력 검증으로 허용할 수 없는 시스템·통신·인증·프로그램 실패 문구를 우선 감지한다.
function Test-SystemFailureSignal([string]$Text) {
    $Text -match '시스템\s*오류|처리\s*오류가?\s*발생|서버\s*(오류|장애|접속)|통신\s*(오류|장애|실패)|소켓|Socket|Exception|예외|프로그램\s*(오류|종료)|강제\s*종료|응답\s*(없음|하지)|세션\s*만료|자동\s*로그아웃'
}

# 잘못된 사용자 입력에 대한 정상 거절 문구를 시스템·제품 결함과 분리한다.
function Test-InputValidationSignal([string]$Text) {
    $Text -match '종목\s*코드\s*오류|계좌번호를?\s*확인|비밀번호를?\s*확인|하나를\s*선택해\s*주세요|입력해\s*주세요|선택해\s*주세요|조회가\s*불가|시작일자가\s*종료일자보다'
}

# 승인된 거래 실행에서만 주문 확인창을 식별한다. 입력 검증·시스템 오류와
# 의미가 모호한 '취소' 단독 버튼은 제출 대상으로 인정하지 않는다.
function Test-HtsTransactionalConfirmationDialog($Dialog, $PlanItem) {
    if (-not $Dialog -or -not $PlanItem) { return $false }
    $messageText = ((@([string]$Dialog.title) + @($Dialog.messageLines)) | Where-Object { $_ }) -join ' | '
    if (Test-SystemFailureSignal $messageText -or Test-InputValidationSignal $messageText) { return $false }
    if ([string]$Dialog.classification -ne '확인 요청') { return $false }

    $logicalName = [string]$PlanItem.controlLogicalName
    $verbPattern = switch ($logicalName) {
        'BTN_Ord_Buy' { '매수|주문' }
        'BTN_Ord_Sell' { '매도|주문' }
        'BTN_Ord_Mod' { '정정|주문' }
        'BTN_Ord_Can' { '취소\s*주문|주문\s*취소|취소' }
        default { '주문|정정|취소|전송' }
    }
    if ($messageText -notmatch $verbPattern) { return $false }

    $positiveButtonPattern = '^(확인|예|Yes|주문|주문전송|전송|매수주문|매도주문|정정주문|취소주문)$'
    @($Dialog.buttons | Where-Object { [string]$_ -match $positiveButtonPattern }).Count -gt 0
}

# 거래 확인창의 명시적 승인 버튼을 실제 마우스 경로로 누르고 창이 닫혔는지 검증한다.
function Submit-HtsTransactionalDialog($Dialog, $PlanItem) {
    $positiveButtonPattern = '^(확인|예|Yes|주문|주문전송|전송|매수주문|매도주문|정정주문|취소주문)$'
    $buttons = @(Get-ChildWindows ([Int64]$Dialog.window.hwnd) | Where-Object {
        $_.visible -and $_.enabled -and $_.className -like '*Button*' -and $_.rawTitle -match $positiveButtonPattern
    } | Sort-Object @{Expression={
        if ($_.rawTitle -match '^(매수주문|매도주문|정정주문|취소주문)$') { 0 }
        elseif ($_.rawTitle -match '^(확인|예|Yes)$') { 1 }
        else { 2 }
    }}, {$_.rect.left})
    if ($buttons.Count -eq 0) {
        return [pscustomobject]@{success=$false;errorCode='TRANSACTION_CONFIRM_BUTTON_NOT_FOUND';output='거래 확인창에서 명시적 승인 버튼을 찾지 못했습니다.'}
    }

    $savedHwnd=[Int64]$script:activeInputSurfaceHwnd
    $savedKind=[string]$script:activeInputSurfaceKind
    $savedLabel=[string]$script:activeInputSurfaceLabel
    try {
        Set-HtsInputSurface $Dialog.window 'Dialog' "HTS 거래 확인창: $($Dialog.title)"
        [void][TargetRuleNative]::ShowWindow([IntPtr][Int64]$Dialog.window.hwnd, 9)
        [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$Dialog.window.hwnd)
        Click-Center $buttons[0]
        Start-Sleep -Milliseconds 800
        $closed = -not [TargetRuleNative]::IsWindow([IntPtr][Int64]$Dialog.window.hwnd)
        [pscustomobject]@{
            success=$closed
            errorCode=$(if($closed){''}else{'TRANSACTION_CONFIRM_DIALOG_REMAINED'})
            output=$(if($closed){"거래 확인 버튼 '$([string]$buttons[0].rawTitle)'을 눌러 제출했습니다."}else{'승인 버튼 클릭 후 거래 확인창이 닫히지 않았습니다.'})
        }
    } catch {
        [pscustomobject]@{success=$false;errorCode='TRANSACTION_CONFIRM_CLICK_FAILED';output=$_.Exception.Message}
    } finally {
        if($savedHwnd -ne 0 -and [TargetRuleNative]::IsWindow([IntPtr]$savedHwnd)){
            try{Set-HtsInputSurface (Get-WindowInfo ([IntPtr]$savedHwnd)) $savedKind $savedLabel}catch{Clear-HtsInputSurface}
        }else{
            Clear-HtsInputSurface
        }
    }
}

# 하나의 팝업·로그 신호를 판정하지 않고 원시 Observation 계약으로 분류한다.
function Get-HtsSignalObservation([string]$Text, $MapOracle, $ExpectedOutcome, [regex]$ErrorRegex, [string]$FallbackClassification = '') {
    $installedMatch = Get-InstallationErrorCodeMatch $Text
    $mapMatch = Get-MapOracleMessageMatch $Text $MapOracle
    $source = '공통 규칙'
    $code = ''
    $eventType = 'Info'

    if($installedMatch){
        $source='HTS 오류코드';$code=[string]$installedMatch.code
        switch([string]$installedMatch.classification){
            'Authentication' {$eventType='ProductFailure'}
            'TransientFailure' {$eventType='ProductFailure'}
            'SystemFailure' {$eventType='ProductFailure'}
            'NoData' {$eventType='NoData'}
            'Normal' {$eventType='Success'}
            default {$eventType='InputValidation'}
        }
    }elseif($mapMatch){
        $source='MAP';$code=[string]$mapMatch.ruleId
        switch([string]$mapMatch.classification){
            'Error' {$eventType='ProductFailure'}
            'InputValidation' {$eventType='InputValidation'}
            'Warning' {$eventType='Warning'}
            default {$eventType='Info'}
        }
    }elseif(Test-SystemFailureSignal $Text){
        $eventType='ProductFailure'
    }elseif(Test-InputValidationSignal $Text){
        $eventType='InputValidation'
    }elseif($FallbackClassification -eq '경고'){
        $eventType='Warning'
    }elseif($FallbackClassification -eq '정보'){
        $eventType='Info'
    }elseif(($ErrorRegex -and $Text -match $ErrorRegex) -or $FallbackClassification -eq '오류'){
        $eventType='GenericError'
    }

    $type=if($ExpectedOutcome){[string]$ExpectedOutcome.type}else{'Unspecified'}
    $script:resultEvaluationSequence++
    $evaluationCase = New-RuleSignalEvaluationCase `
        -CaseId ("signal-{0:D6}" -f $script:resultEvaluationSequence) `
        -EventType $eventType `
        -Text $Text `
        -SourceCode $code `
        -Source $source `
        -ExpectedOutcome $ExpectedOutcome

    [pscustomobject]@{
        eventType=$eventType;disposition='Observed';expectedOutcomeType=$type
        expectedOutcomeSource=$(if($ExpectedOutcome){[string]$ExpectedOutcome.source}else{'Unspecified'})
        expectedOutcomeConfidence=$(if($ExpectedOutcome){[string]$ExpectedOutcome.confidence}else{'Unspecified'})
        expectedOutcomeEvidence=@($(if($ExpectedOutcome){$ExpectedOutcome.evidence}else{@()}))
        expectationId=$(if($ExpectedOutcome){[string]$ExpectedOutcome.expectationId}else{''})
        source=$source;code=$code;text=$Text;evaluationCase=$evaluationCase
    }
}

# 대화상자의 제목·본문·버튼을 합쳐 공통 Observation 분류기로 전달한다.
function Get-HtsDialogObservation($Dialog, $MapOracle, $ExpectedOutcome, [regex]$ErrorRegex) {
    Get-HtsSignalObservation ([string]$Dialog.text) $MapOracle $ExpectedOutcome $ErrorRegex ([string]$Dialog.classification)
}

# 원시 Observation을 감사 이벤트와 기대 계약별 평가 그룹에 함께 누적한다.
function Add-OracleObservation($List, $Observation, [string]$Stage, [string]$ControlId = '', [string]$OptionId = '') {
    if(-not $Observation){return}
    $key="$Stage|$ControlId|$OptionId|$([string]$Observation.eventType)|$([string]$Observation.text)"
    if(@($List | Where-Object eventKey -eq $key).Count -gt 0){return}
    $List.Add([pscustomobject]@{
        eventKey=$key;stage=$Stage;controlId=$ControlId;optionId=$OptionId;eventType=[string]$Observation.eventType
        disposition='Observed';expectedOutcomeType=[string]$Observation.expectedOutcomeType
        expectedOutcomeSource=[string]$Observation.expectedOutcomeSource;expectedOutcomeConfidence=[string]$Observation.expectedOutcomeConfidence
        expectedOutcomeEvidence=@($Observation.expectedOutcomeEvidence)
        expectationId=[string]$Observation.expectationId;source=[string]$Observation.source;sourceCode=[string]$Observation.code
        message=[string]$Observation.text
        detectedAt=(Get-Date).ToString('o')
    })
    if ($Observation.evaluationCase) {
        $requiredRows=if($script:currentRequiredExpectations){@($script:currentRequiredExpectations.ToArray())}else{@()}
        foreach($required in $requiredRows){
            $sameControl = -not $ControlId -or [string]$required.controlId -eq $ControlId
            $sameOption = -not $OptionId -or [string]$required.optionId -eq $OptionId
            if($sameControl -and $sameOption -and $required.observations){$required.observations.Add(@($Observation.evaluationCase.observations)[0])}
        }
        if([string]$Observation.expectedOutcomeType -notin @('ValidationRequired','FailureRequired')){
            $groupKey="$ControlId|$OptionId|$([string]$Observation.expectedOutcomeType)|$([string]$Observation.expectationId)"
            if(-not $script:currentSignalEvaluationGroups.ContainsKey($groupKey)){
                $script:currentSignalEvaluationGroups[$groupKey]=[pscustomobject]@{stage=$Stage;controlId=$ControlId;optionId=$OptionId;observation=$Observation;expectedResult=$Observation.evaluationCase.expectedResult;observations=(New-Object Collections.Generic.List[object])}
            }
            $script:currentSignalEvaluationGroups[$groupKey].observations.Add(@($Observation.evaluationCase.observations)[0])
        }
    }
}

# 공통 오류 패턴과 현재 화면 MAP 메시지를 결합한 관찰용 정규식을 만든다.
function Get-MapOracleErrorRegex([regex]$BaseRegex, $MapOracle) {
    $patterns = New-Object Collections.Generic.List[string]
    $patterns.Add($BaseRegex.ToString())
    if ($MapOracle) {
        foreach ($message in @($MapOracle.messageBoxes | Where-Object isExplicitError)) {
            if ($message.message) { $patterns.Add([regex]::Escape([string]$message.message)) }
            if ($message.title) { $patterns.Add([regex]::Escape([string]$message.title)) }
        }
    }
    if ($mapCatalog -and $mapCatalog.errorCodes) {
        foreach ($entry in @($mapCatalog.errorCodes | Where-Object isFailure)) {
            if ($entry.code) { $patterns.Add("(?<![0-9])$([regex]::Escape([string]$entry.code))(?![0-9])") }
            if ([string]$entry.message -and ([string]$entry.message).Length -ge 6) { $patterns.Add([regex]::Escape([string]$entry.message)) }
        }
    }
    [regex]::new(($patterns -join '|'), [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

# 연계 화면의 제목·본문·버튼·스크린샷과 MAP 예상 여부를 결과에 기록한다.
function Add-LinkedScreenObservations($List, $LinkedScreens, $Main, [string]$CaseId, [string]$RequestedScreenNumber, [string]$ReportBase, [string]$Secret = "", $ExpectedTargets = @()) {
    $index=$List.Count
    $expectedNumbers=@($ExpectedTargets | Where-Object targetScreenCode | ForEach-Object {
        $code=[string]$_.targetScreenCode
        $codeMatch=$script:targetMapScreenCodeRegex.Match($code)
        if($codeMatch.Success){[string]$codeMatch.Groups['screen'].Value}
    } | Where-Object {$_} | Sort-Object -Unique)
    foreach($linked in @($LinkedScreens)){
        $index++
        $linkedNumber=Get-HtsScreenNumber $linked
        $children=@(Get-ChildWindows ([Int64]$linked.hwnd) | Where-Object { $_.visible -and $_.rawTitle })
        $buttons=@($children | Where-Object { $_.className -like '*Button*' } | ForEach-Object { Protect-Text $_.rawTitle $Secret } | Sort-Object -Unique)
        $messages=@($children | Where-Object { $_.className -notlike '*Button*' } | ForEach-Object { Protect-Text $_.rawTitle $Secret } | Sort-Object -Unique | Select-Object -First 30)
        $linkedShot=Join-Path (Join-Path $ReportBase 'screenshots') ("linked-{0}-{1}-{2:000}.png" -f $RequestedScreenNumber,$CaseId,$index)
        $relativeShot=""
        if(Capture-HtsScreenshot $Main $linkedShot){$relativeShot=Get-RelativeFilePath $ReportBase $linkedShot}
        $title=Protect-Text ([string]$linked.rawTitle) $Secret
        $isExpected=$expectedNumbers -contains $linkedNumber
        $List.Add([pscustomobject]@{
            popupId="NAV-$CaseId-$('{0:000}' -f $index)";title=$title;messageLines=$messages;buttons=$buttons
            classification=$(if($isExpected){'예상 연계 화면'}else{'예상 밖 연계 화면'});summary="내부 컨트롤 조작으로 연계 화면 [$linkedNumber]이 열렸습니다: $title"
            expected=$isExpected;oracleSource=$(if($isExpected){'MAP 연결 그래프'}else{'런타임 관찰'});screenshotPath=$relativeShot;detectedAt=(Get-Date).ToString('o')
        })
    }
}

# 화면 ID가 없는 전환 창도 새 최상위 창으로 감지해 누락되지 않게 기록한다.
function Add-UnnumberedTransitionObservation($List, $Main, [string]$CaseId, [string]$RequestedScreenNumber, [string]$ReportBase, [string]$Secret = "") {
    $index=$List.Count+1
    $visibleTitles=@(Get-TopWindows | Where-Object {
        $_.visible -and $_.pid -eq $Main.pid -and $_.hwnd -ne $Main.hwnd -and -not $script:targetScreenTitleRegex.IsMatch([string]$_.rawTitle)
    } | ForEach-Object { Protect-Text $_.rawTitle $Secret } | Where-Object { $_ } | Sort-Object -Unique | Select-Object -First 30)
    $transitionShot=Join-Path (Join-Path $ReportBase 'screenshots') ("transition-{0}-{1}-{2:000}.png" -f $RequestedScreenNumber,$CaseId,$index)
    $relativeShot=""
    if(Capture-HtsScreenshot $Main $transitionShot){$relativeShot=Get-RelativeFilePath $ReportBase $transitionShot}
    $List.Add([pscustomobject]@{
        popupId="NAV-$CaseId-$('{0:000}' -f $index)";title='번호 없는 콘텐츠 전환';messageLines=$visibleTitles;buttons=@()
        classification='연계 화면';summary="버튼 조작 후 [$RequestedScreenNumber] 창이 번호 없는 콘텐츠로 전환되거나 자체 닫혀 원래 화면을 다시 열었습니다."
        expected=$true;screenshotPath=$relativeShot;detectedAt=(Get-Date).ToString('o')
    })
}

# 계좌·비밀번호처럼 명시 로케이터가 점유한 HWND를 자동 탐색 대상에서 제외한다.
# 재접속·프로그램 종료 선택을 포함한 연결 장애 팝업은 자동 닫기 대상에서 제외한다.
function Test-HtsConnectionDialog($Dialog) {
    $buttonText = @($Dialog.buttons | ForEach-Object {
        if ($_ -is [string]) { [string]$_ }
        elseif ($_.PSObject.Properties.Name -contains 'title') { [string]$_.title }
        elseif ($_.PSObject.Properties.Name -contains 'name') { [string]$_.name }
        else { [string]$_ }
    }) -join ' '
    $dialogText = (([string]$Dialog.title) + ' ' + ([string]$Dialog.text) + ' ' + (@($Dialog.messageLines) -join ' ') + ' ' + $buttonText)
    $dialogText -match '접속\s*해제|연결이\s*끊어|재접속|프로그램\s*종료|connection\s*(lost|disconnected)|reconnect'
}

function Get-HtsConnectionDialogs($Main, [string]$Secret = '') {
    if (-not $Main) { return @() }
    @(Get-HtsDialogs $Main $Secret | Where-Object { Test-HtsConnectionDialog $_ })
}

# 현재 대상 프로세스 팝업의 취소 계열 버튼 또는 WM_CLOSE를 사용해 다음 동작을 복구한다.
function Dismiss-HtsDialogs($Main, [string]$Secret = "") {
    $dismissed = 0
    foreach ($dialog in @(Get-HtsDialogs $Main $Secret)) {
        if (Test-HtsConnectionDialog $dialog) { continue }
        $savedHwnd=[Int64]$script:activeInputSurfaceHwnd
        $savedKind=[string]$script:activeInputSurfaceKind
        $savedLabel=[string]$script:activeInputSurfaceLabel
        try {
            Set-HtsInputSurface $dialog.window 'Dialog' "HTS 대화상자: $($dialog.title)"
            [void][TargetRuleNative]::ShowWindow([IntPtr][Int64]$dialog.window.hwnd, 9)
            [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$dialog.window.hwnd)
            $safeButtons = @(Get-ChildWindows ([Int64]$dialog.window.hwnd) | Where-Object {
                $_.visible -and $_.enabled -and $_.className -like "*Button*" -and $_.rawTitle -match '^(취소|아니오|No|닫기|Close)$'
            } | Sort-Object @{Expression={if($_.rawTitle -match '^(취소|아니오|No)$'){0}else{1}}}, {$_.rect.left})
            if ($safeButtons.Count -gt 0) {
                $dismissResult=Invoke-FlaUiControlAction $safeButtons[0] 'invoke'
                if(-not ([bool]$dismissResult.success -and [bool]$dismissResult.verified)){Click-Center $safeButtons[0]}
            } else {
                [void][TargetRuleNative]::SendMessage([IntPtr][Int64]$dialog.window.hwnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
            }
        } catch {
            continue
        } finally {
            if($savedHwnd -ne 0 -and [TargetRuleNative]::IsWindow([IntPtr]$savedHwnd)){
                try{Set-HtsInputSurface (Get-WindowInfo ([IntPtr]$savedHwnd)) $savedKind $savedLabel}catch{Clear-HtsInputSurface}
            }else{
                Clear-HtsInputSurface
            }
        }
        Start-Sleep -Milliseconds 500
        if (-not [TargetRuleNative]::IsWindow([IntPtr][Int64]$dialog.window.hwnd)) { $dismissed++ }
    }
    $dismissed
}

# 발견 팝업을 예상 패턴과 MAP 근거에 대조하고 스크린샷 경로를 함께 저장한다.
function Add-PopupObservations($List, $Dialogs, $Main, [string]$CaseId, [string]$ScreenNumber, [string]$ReportBase, $ExpectedPatterns, $MapOracle = $null) {
    $index = $List.Count
    foreach ($dialog in @($Dialogs)) {
        $index++
        $expected = $false
        foreach ($pattern in @($ExpectedPatterns)) {
            if ($pattern -and $dialog.text -match [string]$pattern) { $expected=$true; break }
        }
        $mapMatch = Get-MapOracleMessageMatch ([string]$dialog.text) $MapOracle
        $installedMatch = Get-InstallationErrorCodeMatch ([string]$dialog.text)
        $classification = if ($installedMatch) {
            switch ([string]$installedMatch.classification) {
                'Authentication' { '인증 오류' }
                'TransientFailure' { '일시 장애' }
                'SystemFailure' { '시스템 오류' }
                'NoData' { '자료 없음' }
                'Normal' { '정상 응답' }
                default { '입력·업무 검증' }
            }
        } elseif ($mapMatch) {
            switch ([string]$mapMatch.classification) {
                'Error' { '오류' }
                'InputValidation' { '입력 검증' }
                'Warning' { '경고' }
                default { '정보' }
            }
        } else { [string]$dialog.classification }
        $oracleSource = if ($installedMatch) { 'HTS 오류코드' } elseif ($mapMatch) { 'MAP' } else { '공통 규칙' }
        $popupShot = Join-Path (Join-Path $ReportBase "screenshots") ("popup-{0}-{1}-{2:000}.png" -f $ScreenNumber,$CaseId,$index)
        $relativeShot = ""
        if (Capture-HtsScreenshot $Main $popupShot $true) { $relativeShot = Get-RelativeFilePath $ReportBase $popupShot }
        $List.Add([pscustomobject]@{
            popupId="POP-$CaseId-$('{0:000}' -f $index)"; title=[string]$dialog.title
            windowHwnd=[Int64]$dialog.window.hwnd; windowClass=[string]$dialog.window.className; windowRect=$dialog.window.rect
            messageLines=@($dialog.messageLines); buttons=@($dialog.buttons); classification=$classification
            summary="$classification 팝업: " + $(if (@($dialog.messageLines).Count -gt 0) { @($dialog.messageLines) -join ' / ' } elseif ($dialog.title) { [string]$dialog.title } else { '본문 없음' })
            expected=$expected; oracleSource=$oracleSource; oracleRuleId=$(if($mapMatch){[string]$mapMatch.ruleId}else{''})
            mapHandler=$(if($mapMatch){[string]$mapMatch.handler}else{''}); mapMessage=$(if($mapMatch){[string]$mapMatch.message}else{''})
            installedErrorCode=$(if($installedMatch){[string]$installedMatch.code}else{''}); installedErrorClass=$(if($installedMatch){[string]$installedMatch.classification}else{''})
            screenshotPath=$relativeShot; detectedAt=(Get-Date).ToString("o")
        })
    }
}

# 로케이터 후보가 화면의 top/middle/bottom 상대 영역에 들어오는지 판단한다.
# 결함 증거는 HTS 메인 창의 물리 경계로 제한한다. 팝업 증거는 화면 복사를 사용해 별도 소유 창까지 포함한다.
function Capture-HtsScreenshot($Main, [string]$Path, [bool]$IncludeVisibleOwnedWindows = $false) {
    $mainHwnd=[IntPtr][Int64]$Main.hwnd
    if(-not [TargetRuleNative]::IsWindow($mainHwnd)){return $false}
    $previousDpiContext=[TargetRuleNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
    $bitmap=$null
    $graphics=$null
    try {
        $physicalMain=Get-WindowInfo $mainHwnd
        $rect=$physicalMain.rect
        $width=[int]$rect.width
        $height=[int]$rect.height
        if($width-le0 -or $height-le0){return $false}
        $bitmap=New-Object Drawing.Bitmap $width,$height
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        $printed=$false
        if(-not $IncludeVisibleOwnedWindows){
            $hdc=$graphics.GetHdc()
            try{$printed=[TargetRuleNative]::PrintWindow($mainHwnd,$hdc,2)}finally{$graphics.ReleaseHdc($hdc)}
        }
        if($IncludeVisibleOwnedWindows -or -not $printed){
            $graphics.CopyFromScreen([int]$rect.left,[int]$rect.top,0,0,(New-Object Drawing.Size $width,$height))
        }
        $bitmap.Save($Path,[Drawing.Imaging.ImageFormat]::Png)
        return $true
    } finally {
        if($graphics){$graphics.Dispose()}
        if($bitmap){$bitmap.Dispose()}
        [void][TargetRuleNative]::SetThreadDpiAwarenessContext($previousDpiContext)
    }
}

# 로그 증분 관찰: 실행 전 오프셋 이후에 추가된 행만 읽어 과거 오류를 신규 결함으로 오인하지 않는다.
function Get-LogState {
    $state = @{}
    $sources = if ($mapCatalog -and $mapCatalog.logSources) { @($mapCatalog.logSources) } else {
        # 설치 카탈로그가 로그 정의를 제공하지 않을 때도 대상 프로필의 설치 루트 밖으로 벗어나지 않는다.
        $logDirectory = Join-Path $targetContext.InstallationRoot 'log'
        @(
            [pscustomobject]@{id='DEBUG_MAIN';pathPattern=(Join-Path $logDirectory 'debugmain.log');mode='AppendText';sensitive=$false;failureOnChange=$false},
            [pscustomobject]@{id='SOCKET_ERROR';pathPattern=(Join-Path $logDirectory 'SocketErr.log');mode='AppendText';sensitive=$false;failureOnChange=$false},
            [pscustomobject]@{id='STARTER';pathPattern=(Join-Path $logDirectory 'Starter.log');mode='AppendText';sensitive=$false;failureOnChange=$false}
        )
    }
    foreach ($source in $sources) {
        $paths = if ([string]$source.pathPattern -match '[*?]') { @(Get-ChildItem -Path ([string]$source.pathPattern) -File -ErrorAction SilentlyContinue | ForEach-Object FullName) } else { @([string]$source.pathPattern) }
        foreach ($path in $paths) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $item=Get-Item -LiteralPath $path
            $state[$path] = [pscustomobject]@{
                id=[string]$source.id;mode=[string]$source.mode;sensitive=[bool]$source.sensitive;failureOnChange=[bool]$source.failureOnChange
                length=[Int64]$item.Length;lastWriteUtc=$item.LastWriteTimeUtc.Ticks
            }
        }
    }
    $state
}

# 주문·체결 민감 로그의 길이/수정시각 증분으로 전송 발생 여부를 원문 노출 없이 판정한다.
function Get-TransmissionDelta($Before) {
    $after = Get-LogState
    $changes = New-Object Collections.Generic.List[string]
    foreach ($path in $after.Keys) {
        $current = $after[$path]
        if ([string]$current.mode -ne 'SensitiveDelta') { continue }
        if (-not $Before.ContainsKey($path)) {
            $changes.Add([string]$current.id)
            continue
        }
        $previous = $Before[$path]
        if ([Int64]$current.length -ne [Int64]$previous.length -or [Int64]$current.lastWriteUtc -ne [Int64]$previous.lastWriteUtc) {
            $changes.Add([string]$current.id)
        }
    }
    [pscustomobject]@{hasTransmission=($changes.Count-gt0);sources=@($changes.ToArray() | Select-Object -Unique)}
}

# 케이스 시작 이후 추가된 로그 구간에서 새 오류 신호만 추출하고 민감값을 제거한다.
function Get-LogErrors($Before, [regex]$ErrorRegex, [string]$Secret, $MapOracle = $null) {
    $errors = New-Object Collections.Generic.List[string]
    foreach ($path in $Before.Keys) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path
        $beforeState=$Before[$path]
        $offset=if($beforeState -is [ValueType]){[Int64]$beforeState}else{[Int64]$beforeState.length}
        $mode=if($beforeState -is [ValueType]){'AppendText'}else{[string]$beforeState.mode}
        $changed=($item.Length -ne $offset) -or ($beforeState -isnot [ValueType] -and $item.LastWriteTimeUtc.Ticks -ne [Int64]$beforeState.lastWriteUtc)
        if(-not $changed){continue}
        if($mode -eq 'SensitiveDelta'){
            if([bool]$beforeState.failureOnChange){$errors.Add("[민감 로그 변화 감지] 조회 테스트 중 체결·주문 관련 로그의 크기 또는 시간이 변경되었습니다. 원문은 개인정보 보호를 위해 수집하지 않았습니다.")}
            continue
        }
        if($mode -eq 'DiagnosticSnapshot'){
            continue
        }
        if ($item.Length -le $offset) { continue }
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::Default)
            $tokens = if ($MapOracle) { @($MapOracle.requestNames) + @($MapOracle.transactionCodes) } else { @() }
            foreach ($line in @($reader.ReadToEnd() -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                $installedMatch = Get-InstallationErrorCodeMatch ([string]$line)
                $mapMessage = Get-MapOracleMessageMatch ([string]$line) $MapOracle
                $isCandidate=($line -match $ErrorRegex) -or ($line -match '자동\s*로그아웃\s*후|세션\s*만료') -or $installedMatch -or $mapMessage
                if(-not $isCandidate){continue}
                if ($installedMatch -and -not [bool]$installedMatch.isFailure) { continue }
                if ($mapMessage -and -not [bool]$mapMessage.isExplicitError) { continue }
                $matchedToken = @($tokens | Where-Object { $_ -and $line.IndexOf([string]$_, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1)
                $prefix = if ($installedMatch) { "[HTS 오류코드 $($installedMatch.code)/$($installedMatch.classification)] " } elseif ($matchedToken.Count -gt 0) { "[MAP 통신 $($matchedToken[0])] " } else { "" }
                $errors.Add($prefix + (Protect-Text $line $Secret))
            }
        } finally { $stream.Dispose() }
    }
    @($errors | Select-Object -Last 20)
}

# 케이스 시작 시 이미 존재하던 오류 문구를 기준선으로 수집한다.
function Get-ErrorWindowTexts($Main, [regex]$ErrorRegex, [string]$Secret) {
    $rows = New-Object Collections.Generic.List[string]
    foreach ($window in @(Get-TopWindows | Where-Object { $_.visible -and $_.pid -eq $Main.pid })) {
        $texts = @($window.rawTitle) + @(Get-ChildWindows ([Int64]$window.hwnd) | ForEach-Object { $_.rawTitle })
        foreach ($match in @($texts | Where-Object { $_ -and $_ -match $ErrorRegex })) { $rows.Add((Protect-Text $match $Secret)) }
    }
    @($rows | Sort-Object -Unique)
}

# 기준선에 없던 새 창 문구만 평가해 과거 팝업의 재검출을 막는다.
function Get-ExplicitWindowErrors($Main, $BeforeErrorTexts, [regex]$ErrorRegex, [string]$Secret, $MapOracle = $null) {
    $rows = New-Object Collections.Generic.List[string]
    $top = @(Get-TopWindows | Where-Object { $_.visible -and $_.pid -eq $Main.pid })
    foreach ($window in $top) {
        $texts = @($window.rawTitle) + @(Get-ChildWindows ([Int64]$window.hwnd) | ForEach-Object { $_.rawTitle })
        $matches = @($texts | Where-Object { $_ -and $_ -match $ErrorRegex })
        foreach ($match in $matches) {
            $mapMessage = Get-MapOracleMessageMatch ([string]$match) $MapOracle
            if ($mapMessage -and -not [bool]$mapMessage.isExplicitError) { continue }
            $safe = Protect-Text $match $Secret
            if ($BeforeErrorTexts -notcontains $safe) { $rows.Add($safe) }
        }
    }
    @($rows | Sort-Object -Unique)
}

# 논리 시나리오 사례 또는 승인 TestPack의 고정 케이스를 실행기 내부 객체로 변환한다.
function Get-ExecutionCasesFromApprovedPlans {
    $selected = @($ScreensCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($scenarioMode) {
        $plannedScreens = @{}
        foreach ($scenarioCase in @($scenarioPlan.cases)) {
            if ($selected.Count -gt 0 -and $selected -notcontains [string]$scenarioCase.screenNumber) { continue }
            if ($requestedScenarioCaseIds.Count -gt 0 -and $requestedScenarioCaseIds -notcontains [string]$scenarioCase.caseId) { continue }
            if (-not $PlanOnly -and $executableScenarioCaseIds -notcontains [string]$scenarioCase.caseId) { continue }
            if ($PlanOnly -and $requestedScenarioCaseIds.Count -eq 0) {
                $screenKey = [string]$scenarioCase.screenNumber
                if ($plannedScreens.ContainsKey($screenKey)) { continue }
                $plannedScreens[$screenKey] = $true
            }
            $screenRows = @($dataset.screens | Where-Object { [string]$_.screenNumber -eq [string]$scenarioCase.screenNumber -and $_.enabled -ne $false } | Select-Object -First 1)
            $accountRows = @($dataset.accounts | Where-Object { [string]$_.id -eq [string]$scenarioCase.accountId -and $_.enabled -ne $false } | Select-Object -First 1)
            if ($screenRows.Count -eq 0 -or $accountRows.Count -eq 0) { continue }
            $variables = @{}
            $expectedOutcomes = @{}
            foreach ($property in @($scenarioCase.values.PSObject.Properties)) {
                $variables[[string]$property.Name] = [string]$property.Value.value
                $expectedOutcomes[[string]$property.Name] = $property.Value.expectedOutcome
            }
            [pscustomobject]@{
                caseId=[string]$scenarioCase.caseId;screen=$screenRows[0];account=$accountRows[0]
                variables=$variables;variableExpectedOutcomes=$expectedOutcomes;scenarioCase=$scenarioCase
            }
        }
        return
    }
    foreach ($compiledCase in @($testPack.cases)) {
        if ($selected.Count -gt 0 -and $selected -notcontains [string]$compiledCase.screenNumber) { continue }
        $screen = @($dataset.screens | Where-Object { [string]$_.screenNumber -eq [string]$compiledCase.screenNumber } | Select-Object -First 1)
        if ($screen.Count -ne 1) { throw "TestPack 케이스의 화면이 datasetSnapshot에 없습니다: $([string]$compiledCase.caseId)" }
        $variables = @{}
        foreach ($property in @($compiledCase.variables.PSObject.Properties)) { $variables[[string]$property.Name] = [string]$property.Value }
        $expectedOutcomes = @{}
        foreach ($property in @($compiledCase.variableExpectedOutcomes.PSObject.Properties)) { $expectedOutcomes[[string]$property.Name] = $property.Value }
        $account = [pscustomobject]@{
            id = [string]$compiledCase.accountId
            accountNumber = [string]$compiledCase.accountNumber
            owner = [string]$compiledCase.accountOwner
            inputMode = [string]$compiledCase.inputMode
            passwordSecret = $compiledCase.passwordSecret
            enabled = $true
        }
        [pscustomobject]@{
            caseId = [string]$compiledCase.caseId
            screen = $screen[0]
            account = $account
            variables = $variables
            variableExpectedOutcomes = $expectedOutcomes
            testPackCase = $compiledCase
        }
    }
}

# 계좌가 있을 때만 보고서 상관관계용 비가역 SHA-256 짧은 지문을 만든다.
function Get-AccountFingerprint([string]$AccountNumber) {
    if ([string]::IsNullOrWhiteSpace($AccountNumber)) { return "" }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $sha = $hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($AccountNumber)) }
    finally { $hasher.Dispose() }
    $hex = -join ($sha | ForEach-Object { $_.ToString("x2") })
    $hex.Substring(0,12)
}

# 계좌가 있을 때 앞뒤 일부만 남기고 중간 숫자를 가린다.
function Get-MaskedAccount([string]$AccountNumber) {
    if ([string]::IsNullOrWhiteSpace($AccountNumber)) { return "" }
    $digits = $AccountNumber -replace '\D', ''
    if ($digits.Length -lt 7) { return "******" }
    $digits.Substring(0,3) + "****" + $digits.Substring($digits.Length - 3)
}

# 실행 폴더 기준 상대 경로를 만들어 결과 폴더 이동 후에도 증거 링크가 유지되게 한다.
function Get-RelativeFilePath([string]$BasePath, [string]$TargetPath) {
    $baseFull = [IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    $targetFull = [IO.Path]::GetFullPath($TargetPath)
    $relative = (New-Object Uri($baseFull)).MakeRelativeUri((New-Object Uri($targetFull))).ToString()
    [Uri]::UnescapeDataString($relative).Replace('/', '\')
}

# 케이스 액션 배열과 시간순 실행 trace에 같은 상태를 동시에 기록한다.
function Add-Action($List, [string]$Action, [string]$Status, [string]$Target = "", [string]$Output = "", [string]$ErrorCode = "") {
    $row=[pscustomobject]@{ action=$Action; status=$Status; target=$Target; output=$Output; errorCode=$ErrorCode; elapsedMs=0 }
    $List.Add($row)
    [pscustomobject]@{timestamp=(Get-Date).ToString('o');action=$Action;status=$Status;target=$Target;output=$Output;errorCode=$ErrorCode} |
        ConvertTo-Json -Compress | Add-Content -LiteralPath $script:executionTracePath -Encoding UTF8
}

$navigationDependencies = [pscustomobject]@{
    GetChildWindows = { param([Int64]$Hwnd) @(Get-ChildWindows $Hwnd) }
    GetWindowInfo = { param([Int64]$Hwnd) Get-WindowInfo ([IntPtr]$Hwnd) }
    IsWindow = { param([Int64]$Hwnd) [TargetRuleNative]::IsWindow([IntPtr]$Hwnd) }
    ActivateMain = {
        param($Main)
        [void][TargetRuleNative]::ShowWindow([IntPtr][Int64]$Main.hwnd, 9)
        [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$Main.hwnd)
    }
    ActivateRequestedScreen = {
        param($Main, $Screen)
        $screenHwnd = [IntPtr][Int64]$Screen.hwnd
        $parentHwnd = [TargetRuleNative]::GetParent($screenHwnd)
        [void][TargetRuleNative]::ShowWindow([IntPtr][Int64]$Main.hwnd, 9)
        [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$Main.hwnd)
        if ($parentHwnd -ne [IntPtr]::Zero) {
            [void][TargetRuleNative]::SendMessage($parentHwnd, $WM_MDIACTIVATE, $screenHwnd, [IntPtr]::Zero)
        }
        [void][TargetRuleNative]::BringWindowToTop($screenHwnd)
    }
    SetInputSurface = { param($Window, [string]$Kind, [string]$Label) Set-HtsInputSurface $Window $Kind $Label }
    SetScreenNumber = { param($ScreenEdit, [string]$ScreenNumber) Set-HtsScreenNumber $ScreenEdit $ScreenNumber }
    InvokeControlAction = {
        param($Window, [string]$Action, [string]$Key)
        Invoke-FlaUiControlAction $Window $Action -Key $Key
    }
    TestInputAccess = { param($Window) Test-HtsScreenNavigationInputAccess $Window }
    ClickCenter = { param($Window) Click-Center $Window }
    SendEnter = { Send-Key ([byte]$VK_RETURN) }
    FocusInputWindow = { param($Window) Focus-HtsInputWindow $Window }
    Sleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    GetNow = { Get-Date }
    GetWindowProcessId = {
        param([Int64]$Hwnd)
        [uint32]$processId = 0
        [void][TargetRuleNative]::GetWindowThreadProcessId([IntPtr]$Hwnd, [ref]$processId)
        [int]$processId
    }
    IsChild = { param([Int64]$ParentHwnd, [Int64]$ChildHwnd) [TargetRuleNative]::IsChild([IntPtr]$ParentHwnd, [IntPtr]$ChildHwnd) }
    CloseWindow = { param($Window) [void][TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) }
    ClearInputSurfaceForWindow = {
        param($Window)
        if ([Int64]$script:activeInputSurfaceHwnd -eq [Int64]$Window.hwnd) { Clear-HtsInputSurface }
    }
}
$navigationContext = New-HtsNavigationContext `
    -SessionContext $sessionContext `
    -TargetScreenTitleRegex $script:targetScreenTitleRegex `
    -ScreenOpenTimeoutMs ([int]$dataset.executionPolicy.screenOpenTimeoutMs) `
    -Dependencies $navigationDependencies

# 실행 루프: 각 화면을 열고 같은 화면의 사례를 연속 처리한 뒤 완전히 닫고 다음 화면으로 이동한다.
$cases = @(Get-ExecutionCasesFromApprovedPlans)
if ($cases.Count -gt $MaxCases -or $cases.Count -gt [int]$testPack.maxCases) { throw "승인 TestPack 케이스 수 $($cases.Count)가 실행 제한을 초과했습니다." }
if ($scenarioMode -and -not $PlanOnly -and $cases.Count -eq 0) { throw "승인과 고신뢰 바인딩을 모두 통과한 실행 가능 시나리오 케이스가 없습니다." }
$configuredErrorPatterns = @($dataset.executionPolicy.errorPatterns | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
$errorPattern = if ($configuredErrorPatterns.Count -gt 0) { $configuredErrorPatterns -join '|' } else { '(?!)' }
$errorRegex = [regex]::new($errorPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
$main = $null
$screenEdit = $null
try {
    [void](Start-FlaUiBridge -Context $sessionContext)
    $main = Find-HtsMainWindow -Context $sessionContext
    $script:activeHtsMainHwnd=[Int64]$main.hwnd
    $script:activeHtsPid=[int]$main.pid
    [void][TargetRuleNative]::ShowWindow([IntPtr][Int64]$main.hwnd, 9)
    [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$main.hwnd)
    Set-HtsInputSurface $main 'Main' 'HTS 메인 사전점검'
    $screenEdit = Find-ScreenNumberEdit $main
} catch {
    $_.Exception.ToString() | Set-Content -LiteralPath (Join-Path $ReportDir "환경사전점검오류.txt") -Encoding UTF8
    $precheckMessage = Protect-Text $_.Exception.Message
    $precheckExpectation=[pscustomobject]@{type='Success';expectationId='environment-precheck';messagePatterns=@();errorCodes=@();evidence=@('HTS/FlaUI 환경 사전점검')}
    $precheckEvaluationCases=@($cases | ForEach-Object {
        New-RuleSignalEvaluationCase -CaseId ([string]$_.caseId) -EventType 'InfrastructureError' -Text $precheckMessage -SourceCode 'ENVIRONMENT_HTS_NOT_ACCESSIBLE' -Source 'environment precheck' -Executed $false -EvidencePresent $true -ExpectedOutcome $precheckExpectation
    })
    $precheckEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId="$runId-precheck";cases=$precheckEvaluationCases}
    $precheckEvaluationOutput=Invoke-RuleResultEvaluation -CliProject $cliProject -TestPackPath $resultEvaluationTestPackPath -EvaluationDocument $precheckEvaluationDocument -WorkingDirectory $resultEvaluationWorkingDirectory -InvocationId 'environment-precheck'
    $precheckTestResults=@{}
    foreach($testResult in @($precheckEvaluationOutput.results)){$precheckTestResults[[string]$testResult.caseId]=$testResult}
    $precheckResults = @($cases | ForEach-Object {
        $caseRow = $_
        $caseTestResult=$precheckTestResults[[string]$caseRow.caseId]
        $safeVariables = [ordered]@{}
        foreach ($name in @($caseRow.variables.Keys | Sort-Object)) {
            $dimension = @($dataset.variables | Where-Object { $_.name -eq $name } | Select-Object -First 1)
            $safeVariables[$name] = if ($dimension.Count -gt 0 -and $dimension[0].sensitive) { "******" } else { [string]$caseRow.variables[$name] }
        }
        [pscustomobject]@{
            runId=$runId; caseId=$caseRow.caseId; datasetId=[string]$dataset.datasetId
            screenNumber=[string]$caseRow.screen.screenNumber; screenName=[string]$caseRow.screen.screenName; inputMode=$(if ([string]$caseRow.account.inputMode -eq "Explicit") { "데이터셋 명시 입력" } else { "화면 기본값" })
            accountId=[string]$caseRow.account.id; accountMasked=(Get-MaskedAccount ([string]$caseRow.account.accountNumber)); accountFingerprint=(Get-AccountFingerprint ([string]$caseRow.account.accountNumber)); accountOwner=[string]$caseRow.account.owner
            inputVariables=$safeVariables; status=[string]$caseTestResult.status; errorDetected=$false;productDefectDetected=[bool]$caseTestResult.productDefectDetected;actualScenarioActionsExecuted=$false;testResult=$caseTestResult;errorCode=[string]$caseTestResult.code
            errorMessage=""; outputSummary=[string]$caseTestResult.reason; screenshotPath=""
            actions=@([pscustomobject]@{action="environmentPrecheck";status="PENDING";target="hfrun";output=$precheckMessage;errorCode="ENVIRONMENT_HTS_NOT_ACCESSIBLE";elapsedMs=0})
            startedAt=(Get-Date).ToString("o"); endedAt=(Get-Date).ToString("o"); elapsedMs=0
        }
    })
    $precheckResults | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ReportDir "case-results.json") -Encoding UTF8
    $precheckEvaluationOutput | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ReportDir 'test-results.json') -Encoding UTF8
    [pscustomobject]@{
        runId=$runId; testPackId=[string]$testPack.testPackId;testPackPath=$resolvedTestPackPath;datasetId=[string]$dataset.datasetId;datasetPath=[string]$testPack.datasetSource; status=[string]$precheckEvaluationOutput.overallResult.status; total=$precheckResults.Count
        pass=[int]$precheckEvaluationOutput.summary.pass; fail=[int]$precheckEvaluationOutput.summary.fail; error=[int]$precheckEvaluationOutput.summary.error; pending=[int]$precheckEvaluationOutput.summary.pending; dryRun=$false; explicitErrorsDetected=0
        automationEngine='FlaUI.UIA3';automationEngineVersion='5.0.0';flaUiDiscoveryCalls=$automationMetrics.FlaUiDiscoveryCalls;flaUiActionAttempts=$automationMetrics.FlaUiActionAttempts
        flaUiActionSuccesses=$automationMetrics.FlaUiActionSuccesses;flaUiFallbackRequests=$automationMetrics.FlaUiFallbackRequests;flaUiFallbackReasons=@($automationMetrics.FlaUiFallbackReasons)
        environmentStatus="HTS_NOT_ACCESSIBLE"; finishedAt=(Get-Date).ToString("o"); executionMode=$(if($SubmitTransactionalDialogs){"승인된 테스트계좌 거래 제출"}else{"조회 전용"}); inputMode="화면 기본값 또는 데이터셋 명시 입력"; planner="결정론적 규칙"
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReportDir "summary.json") -Encoding UTF8
    Stop-FlaUiBridge -Context $sessionContext
    if (-not $SkipExcel) { Export-RuleResultWorkbooks $ReportDir }
    Write-Output $ReportDir
    return
}
$initialSearchOverlaysClosed = Close-ScreenSearchOverlays $main
$initialScreensPreserved = 0
if ($reuseExistingTargetScreenRequested) {
    $preservedTargetScreenHwnds = @(Get-HtsScreenWindows $main | ForEach-Object { [Int64]$_.hwnd } | Select-Object -Unique)
    [void](Set-HtsNavigationPreservedScreens -Context $navigationContext -Hwnds $preservedTargetScreenHwnds)
    $initialScreensPreserved = $navigationContext.PreservedTargetScreenHwnds.Count
    $initialScreensClosed = 0
} else {
    $initialScreensClosed = Close-ExistingTargetScreens $main
}
$results = New-Object Collections.Generic.List[object]

for ($caseIndex = 0; $caseIndex -lt $cases.Count; $caseIndex++) {
    $case = $cases[$caseIndex]
    $datasetInteractionStrategy = [string]$dataset.autoExploration.interactionStrategy
    $script:ruleCurrentInteractionStrategy = if ($scenarioMode -and [string]$case.scenarioCase.executionOrder) {
        [string]$case.scenarioCase.executionOrder
    } elseif ($datasetInteractionStrategy) {
        $datasetInteractionStrategy
    } else {
        'RuntimeTabOrder'
    }
    $previousCase = if ($caseIndex -gt 0) { $cases[$caseIndex-1] } else { $null }
    $nextCase = if ($caseIndex + 1 -lt $cases.Count) { $cases[$caseIndex+1] } else { $null }
    $reuseScenarioScreen = $scenarioMode -and $previousCase -and [string]$previousCase.screen.screenNumber -eq [string]$case.screen.screenNumber
    $retainScenarioScreen = $scenarioMode -and $nextCase -and [string]$nextCase.screen.screenNumber -eq [string]$case.screen.screenNumber
    $started = Get-Date
    $actions = New-Object Collections.Generic.List[object]
    $pendingReasons = New-Object Collections.Generic.List[string]
    $errors = New-Object Collections.Generic.List[string]
    $automationIssues = New-Object Collections.Generic.List[string]
    $discoveredControls = New-Object Collections.Generic.List[object]
    $controlTests = New-Object Collections.Generic.List[object]
    $popupObservations = New-Object Collections.Generic.List[object]
    $oracleEvents = New-Object Collections.Generic.List[object]
    $script:currentResultEvaluationCases = New-Object Collections.Generic.List[object]
    $script:currentSignalEvaluationGroups = @{}
    $flaUiActionAttemptsBeforeCase = [int]$automationMetrics.FlaUiActionAttempts
    $executedExpectationPatterns = New-Object Collections.Generic.List[string]
    $requiredExpectations = New-Object Collections.Generic.List[object]
    $script:currentRequiredExpectations = $requiredExpectations
    $queryRequiredExpectations = New-Object Collections.Generic.List[object]
    $claimedHwnds = @{}
    $tabOrderQueryControl = $null
    $executorException = $false
    $executorDiagnostic = ""
    $automationContractFailure = $false
    $automationContractErrorCode = ''
    $externalInterruption = $false
    $screenOpenFailure = $false
    $existingScreenRequiredMissing = $false
    $usedExistingTargetScreen = $false
    $openedTargetScreenForRun = $false
    $transactionAccountVerified = $false
    $transactionAccountEvidence = ''
    $transactionAccountCandidate = $null
    $transactionAccountFingerprint = ''
    $inputMode = if ($case.account.inputMode) { [string]$case.account.inputMode } else { "Prefilled" }
    $queryTrigger = if ($case.screen.queryTrigger) { [string]$case.screen.queryTrigger } else { "F12" }
    $secret = if ($inputMode -eq "Explicit" -and $case.account.passwordSecret) {
        [Environment]::GetEnvironmentVariable([string]$case.account.passwordSecret.key)
    } else { "" }
    $logBefore = @{}
    $beforeErrorTexts = @()
    $screen = $null
    $mapModel = Get-HtsDiscoveryMapScreenModel -Context $discoveryContext -ScreenNumber ([string]$case.screen.screenNumber) -MapScreenCode $(if($scenarioMode){[string]$case.scenarioCase.mapScreenCode}else{''})
    $mapOracle = if ($mapModel) { $mapModel.errorOracle } else { $null }
    $mapBehavior = if ($mapModel) { $mapModel.behavior } else { $null }
    $mapQueryExecuted = $false
    $mapReboundControls = 0
    $caseErrorRegex = Get-MapOracleErrorRegex $errorRegex $mapOracle
    try {
        $previousPid = if ($main) { [int]$main.pid } else { 0 }
        $main = Wait-HtsMainWindow -Context $sessionContext
        $script:activeHtsMainHwnd=[Int64]$main.hwnd
        $script:activeHtsPid=[int]$main.pid
        if ($previousPid -ne 0 -and $main.pid -ne $previousPid) {
            Add-Action $actions "recoverMainWindow" "PASS" "hfrun" "재접속 후 새 HTS 메인 창을 찾아 실행을 계속했습니다."
        }
        [void](Dismiss-HtsDialogs $main $secret)
        $startupConnectionDialogs = @(Get-HtsConnectionDialogs $main $secret)
        if ($startupConnectionDialogs.Count -gt 0) {
            throw "HTS_CONNECTION_LOST: 연결 장애 대화상자가 남아 있어 사용자 판단 없이 실행을 중단했습니다. $([string]$startupConnectionDialogs[0].text)"
        }
        [void](Close-ScreenSearchOverlays $main)
        $logBefore = Get-LogState
        $beforeErrorTexts = @(Get-ErrorWindowTexts $main $caseErrorRegex $secret)
        if ($reuseScenarioScreen -or $reuseExistingTargetScreenRequested) {
            $requestedScreenWindow = Find-ScreenWindow $main ([string]$case.screen.screenNumber)
            $screen = if ($requestedScreenWindow) { Find-BestHtsContentSurface $main $requestedScreenWindow ([string]$case.screen.screenNumber) @() } else { $null }
            if ($screen) {
                $usedExistingTargetScreen = Test-PreservedTargetScreen $requestedScreenWindow
                if ($usedExistingTargetScreen) {
                    Add-Action $actions 'attachExistingScreen' 'PASS' ([string]$case.screen.screenNumber) '사용자가 미리 열어둔 대상 화면에 연결했으며 화면번호 재입력을 수행하지 않았습니다.'
                } else {
                    Add-Action $actions 'reuseScreenForScenario' 'PASS' ([string]$case.screen.screenNumber) '같은 화면의 다음 시나리오 케이스이므로 화면을 닫고 다시 열지 않고 현재 콘텐츠 표면을 재사용했습니다.'
                }
            } elseif ($RequireExistingTargetScreen) {
                $existingScreenRequiredMissing = $true
                $pendingReasons.Add("사용자가 미리 열어둔 [$($case.screen.screenNumber)] 화면이 필요합니다.")
                Add-Action $actions 'attachExistingScreen' 'PENDING' ([string]$case.screen.screenNumber) '기존 대상 화면이 없어 화면번호 재입력 없이 실행을 보류했습니다.' 'EXISTING_SCREEN_REQUIRED'
            } else {
                $screenEdit = Find-ScreenNumberEdit $main
                Open-HtsScreen $main $screenEdit ([string]$case.screen.screenNumber)
                $openedTargetScreenForRun = $true
                $requestedScreenWindow = Find-ScreenWindow $main ([string]$case.screen.screenNumber)
                $screen = Find-BestHtsContentSurface $main $requestedScreenWindow ([string]$case.screen.screenNumber) @()
                $openAction = if($reuseScenarioScreen){'reopenMissingScenarioScreen'}else{'openTargetScreen'}
                $openMessage = if($reuseScenarioScreen){'같은 화면의 다음 케이스 전에 대상 화면이 사라져 다시 열었습니다.'}else{'실행 중인 HTS 메인 창의 화면번호 입력란으로 대상 화면을 열었습니다.'}
                Add-Action $actions $openAction $(if($screen){'PASS'}else{'FAIL'}) ([string]$case.screen.screenNumber) $openMessage $(if($screen){''}else{'SCREEN_NOT_VISIBLE'})
            }
        } else {
            $leftoverScreensClosed=Close-ExistingTargetScreens $main
            if($leftoverScreensClosed -gt 0){Add-Action $actions 'cleanupPreviousScreens' 'PASS' 'HTS sibling windows' "이전 화면에서 남은 HTS 내부 창 $leftoverScreensClosed개를 정리했습니다."}
            $remainingBeforeOpen=@(Get-HtsScreenWindows $main)
            if($remainingBeforeOpen.Count -gt 0){
                throw "SCREEN_SEQUENCE_GUARD: 이전 화면 $($remainingBeforeOpen.Count)개가 남아 있어 다음 화면 열기를 차단했습니다."
            }
            $baselineScreenHwnds=@(Get-ChildWindows ([Int64]$main.hwnd) | Where-Object { $_.visible -and $script:targetScreenTitleRegex.IsMatch([string]$_.rawTitle) } | ForEach-Object { [Int64]$_.hwnd })
            $screenEdit = Find-ScreenNumberEdit $main
            Open-HtsScreen $main $screenEdit ([string]$case.screen.screenNumber)
            $openedTargetScreenForRun = $true
            $requestedScreenWindow = Find-ScreenWindow $main ([string]$case.screen.screenNumber)
            $screen = Find-BestHtsContentSurface $main $requestedScreenWindow ([string]$case.screen.screenNumber) $baselineScreenHwnds
        }
        if (-not $screen) {
            $openConnectionDialogs = @(Get-HtsConnectionDialogs $main $secret)
            if ($openConnectionDialogs.Count -gt 0) {
                throw "HTS_CONNECTION_LOST: 화면 열기 중 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$openConnectionDialogs[0].text)"
            }
            if (-not $existingScreenRequiredMissing) {
                $screenOpenFailure = $true
                $automationContractFailure = $true
                $automationContractErrorCode = 'SCREEN_NOT_VISIBLE'
                Add-Action $actions "openScreen" "FAIL" ([string]$case.screen.screenNumber) "화면 창이 표시되지 않았습니다." "SCREEN_NOT_VISIBLE"
                $errors.Add("화면을 연 뒤 대상 창이 표시되지 않았습니다.")
            }
            foreach ($dialog in @(Get-HtsDialogs $main $secret)) {
                if ($dialog.text) { $errors.Add($dialog.text) }
            }
        } else {
            if(-not (Focus-HtsRequestedScreen $main $screen ([string]$case.screen.screenNumber))){
                throw "INPUT_SCOPE_BLOCKED: [$($case.screen.screenNumber)] 대상 화면을 활성 입력 표면으로 고정하지 못했습니다."
            }
            Add-Action $actions "openScreen" "PASS" ([string]$case.screen.screenNumber) $(if($usedExistingTargetScreen){'기존 화면을 재호출하지 않고 활성화했습니다.'}else{'화면 창이 열렸습니다.'})
            if ($mapOracle) {
                $oracleMessageCount = @($mapOracle.messageBoxes).Count
                $oracleErrorCount = @($mapOracle.messageBoxes | Where-Object isExplicitError).Count
                $oracleValidationCount = @($mapOracle.messageBoxes | Where-Object classification -eq 'InputValidation').Count
                Add-Action $actions 'loadMapErrorOracle' 'PASS' ([string]$case.screen.screenNumber) "MAP 오류 오라클을 적용했습니다: 메시지 $oracleMessageCount개(명시 오류 $oracleErrorCount, 입력 검증 $oracleValidationCount), 오류 핸들러 $(@($mapOracle.errorHandlers).Count)개, 통신 식별자 $(@($mapOracle.requestNames).Count + @($mapOracle.transactionCodes).Count)개."
            } else {
                Add-Action $actions 'loadMapErrorOracle' 'PENDING' ([string]$case.screen.screenNumber) '화면별 MAP 오류 오라클이 없어 공통 오류 규칙만 적용합니다.' 'MAP_ERROR_ORACLE_NOT_FOUND'
            }
            if ($mapBehavior) {
                Add-Action $actions 'loadMapBehavior' 'PASS' ([string]$case.screen.screenNumber) "MAP 동작 모델을 적용했습니다: 이벤트 $(@($mapBehavior.eventHandlers).Count)개, 조회 $(@($mapBehavior.queryControls).Count)개, 자동조회 $(@($mapBehavior.autoQueryControls).Count)개, 상태제어 $(@($mapBehavior.stateControllerControls).Count)개, 입력 $(@($mapBehavior.inputControls).Count)개, 결과 $(@($mapBehavior.resultControls).Count)개."
            } else {
                Add-Action $actions 'loadMapBehavior' 'PENDING' ([string]$case.screen.screenNumber) '화면별 MAP 동작 모델이 없어 런타임 발견 정보만 사용합니다.' 'MAP_BEHAVIOR_NOT_FOUND'
            }
            if($mapModel -and $mapCatalog.installationFingerprint){
                $canonicalTitle=if($mapModel.registry){[string]$mapModel.registry.title}else{[string]$mapModel.screenName}
                $integrityStatus=if($mapModel.integrity){[string]$mapModel.integrity.status}else{'MANIFEST_MISSING'}
                $installStatus=if($integrityStatus -eq 'MATCH'){'PASS'}else{'PENDING'}
                Add-Action $actions 'loadInstallationCatalog' $installStatus ([string]$case.screen.screenNumber) "설치 기준 '$canonicalTitle'을 적용했습니다: 탭 형제 $(@($mapModel.tabSiblings).Count)개, 연결 정의 $(@($mapModel.dependencies).Count)개, 데이터 사전 $(@($mapModel.dataReferences).Count)개, 무결성 $integrityStatus." $(if($installStatus-eq'PASS'){''}else{'INSTALLATION_MODEL_DRIFT'})
                if($installStatus-ne'PASS'){$pendingReasons.Add("설치 무결성: $integrityStatus")}
            }
            if($requestedScreenWindow -and $screen.hwnd -ne $requestedScreenWindow.hwnd){
                Add-Action $actions 'resolveContentSurface' 'PASS' ([string]$screen.rawTitle) "요청 화면과 같은 번호이거나 화면 열기 뒤 새로 생성된 콘텐츠 표면만 선택했습니다."
            }
            if ($inputMode -eq "Prefilled") {
                Add-Action $actions "usePrefilledInputs" "PASS" "prefilled inputs" "현재 화면에 기본 입력된 값을 변경하지 않고 사용했습니다."
            } else {
                $accountStrategies = if ($case.screen.locators -and $case.screen.locators.account) { $case.screen.locators.account } else { $dataset.defaultLocators.account }
                $accountControl = Resolve-HtsRoleControl -Context $bindingContext -Screen $screen -Role 'account' -Strategies $accountStrategies
                if ($accountControl -and [Int64]$accountControl.hwnd -ne 0) { $claimedHwnds[[Int64]$accountControl.hwnd] = $true }
                if ($accountControl -and (Set-AutomationText $accountControl ([string]$case.account.accountNumber))) {
                    Add-Action $actions "setAccount" "PASS" "account" "계좌번호를 입력했으며 결과에는 마스킹했습니다."
                } else {
                    Add-Action $actions "setAccount" "PENDING" "account" "신뢰도 높은 계좌 입력칸을 찾지 못했습니다." "LOCATOR_NOT_RESOLVED"
                    $pendingReasons.Add("계좌 입력칸")
                }

                $passwordStrategies = if ($case.screen.locators -and $case.screen.locators.password) { $case.screen.locators.password } else { $dataset.defaultLocators.password }
                $passwordControl = Resolve-HtsRoleControl -Context $bindingContext -Screen $screen -Role 'password' -Strategies $passwordStrategies
                if ($passwordControl -and [Int64]$passwordControl.hwnd -ne 0) { $claimedHwnds[[Int64]$passwordControl.hwnd] = $true }
                if (-not $secret) {
                    Add-Action $actions "setPassword" "PENDING" "password" "비밀번호 환경 변수가 설정되지 않았습니다." "SECRET_NOT_SET"
                    $pendingReasons.Add("비밀번호 환경 변수")
                } elseif ($passwordControl -and (Set-AutomationText $passwordControl $secret -Sensitive)) {
                    Add-Action $actions "setPassword" "PASS" "password" "비밀번호를 입력했으며 값은 기록하지 않았습니다."
                } else {
                    Add-Action $actions "setPassword" "PENDING" "password" "신뢰도 높은 비밀번호 입력칸을 찾지 못했습니다." "LOCATOR_NOT_RESOLVED"
                    $pendingReasons.Add("비밀번호 입력칸")
                }
            }

            if (-not $scenarioMode) { foreach ($name in @($case.variables.Keys | Sort-Object)) {
                $dimensionRows = @($dataset.variables | Where-Object { $_.name -eq $name } | Select-Object -First 1)
                $dimension = if ($dimensionRows.Count -gt 0) { $dimensionRows[0] } else { [pscustomobject]@{name=$name;targetRole="condition:$name";controlKind="Auto";valueMatch="Value";required=$true;triggerQueryAfterChange=$true;sensitive=$false} }
                $variableExpectation=if($case.variableExpectedOutcomes -and $case.variableExpectedOutcomes.ContainsKey($name)){$case.variableExpectedOutcomes[$name]}else{$null}
                $variableOption=[pscustomobject]@{id="dataset-variable:$name";expectedOutcome=$variableExpectation}
                $resolvedVariableExpectation=Get-RuleExpectedOutcome $variableOption @($case.screen.expectedPopupPatterns)
                foreach($pattern in @($resolvedVariableExpectation.messagePatterns)){
                    if($pattern -and -not $executedExpectationPatterns.Contains([string]$pattern)){$executedExpectationPatterns.Add([string]$pattern)}
                }
                $role = if ($dimension.targetRole) { [string]$dimension.targetRole } else { "condition:$name" }
                $strategies = $null
                if ($case.screen.locators -and $case.screen.locators.PSObject.Properties.Name -contains $role) { $strategies = $case.screen.locators.$role }
                $control = Resolve-HtsRoleControl -Context $bindingContext -Screen $screen -Role $role -Strategies $strategies
                if ($control -and [Int64]$control.hwnd -ne 0) { $claimedHwnds[[Int64]$control.hwnd] = $true }
                $kind = if ($dimension.controlKind) { [string]$dimension.controlKind } else { "Auto" }
                $valueMatch = if ($dimension.valueMatch) { [string]$dimension.valueMatch } else { "Value" }
                if ($control -and (Invoke-HtsDatasetVariableAction -Context $actionContext -Window $control -ControlKind $kind -Value ([string]$case.variables[$name]) -ValueMatch $valueMatch -MaxOptions ([int]$dataset.autoExploration.maxOptionsPerControl))) {
                    Add-Action $actions "setCondition" "PASS" $name "$kind 방식으로 데이터셋 조건값을 적용했습니다. 기대 계약: $([string]$resolvedVariableExpectation.type) / $([string]$resolvedVariableExpectation.source) / $([string]$resolvedVariableExpectation.confidence)."
                    $variableRequirementRecord=$null
                    if([string]$resolvedVariableExpectation.type -in @('ValidationRequired','FailureRequired')){
                        $variableRequirementRecord=[pscustomobject]@{controlId="dataset-variable:$name";optionId=[string]$resolvedVariableExpectation.expectationId;outcome=$resolvedVariableExpectation;observations=(New-Object Collections.Generic.List[object])}
                        $variableRequirementRecord.observations.Add([pscustomobject]@{observationId="dataset-variable:$name-completion";kind='Success';executed=$true;evidencePresent=$true;message='데이터셋 조건값 적용을 완료했습니다.';sourceCode='';source='dataset variable completion'})
                        $requiredExpectations.Add($variableRequirementRecord)
                    }
                    if($resolvedVariableExpectation.queryShouldComplete -eq $true){
                        $queryRequiredExpectations.Add([pscustomobject]@{name=$name;outcome=$resolvedVariableExpectation})
                    }
                    $variableDialogs=@(Get-HtsDialogs $main $secret)
                    if($variableDialogs.Count -gt 0){
                        Add-PopupObservations $popupObservations $variableDialogs $main $case.caseId ([string]$case.screen.screenNumber) $ReportDir @($resolvedVariableExpectation.messagePatterns) $mapOracle
                        $variableConnectionDialogs = @($variableDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                        if ($variableConnectionDialogs.Count -gt 0) {
                            throw "HTS_CONNECTION_LOST: 조건 입력 직후 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$variableConnectionDialogs[0].text)"
                        }
                        foreach($dialog in $variableDialogs){
                            $observation=Get-HtsDialogObservation $dialog $mapOracle $resolvedVariableExpectation $caseErrorRegex
                            Add-OracleObservation $oracleEvents $observation 'dataset-variable' "dataset-variable:$name" ([string]$resolvedVariableExpectation.expectationId)
                        }
                        [void](Dismiss-HtsDialogs $main $secret)
                    }
                } else {
                    $required = ($null -eq $dimension.required -or [bool]$dimension.required)
                    Add-Action $actions "setCondition" $(if ($required) { "PENDING" } else { "PASS" }) $name "조건 컨트롤을 찾지 못했거나 지정값을 적용하지 못했습니다." "LOCATOR_OR_VALUE_NOT_RESOLVED"
                    if ($required) { $pendingReasons.Add("조건 컨트롤 $name") }
                }
            } }

            $autoPendingReasons = New-Object Collections.Generic.List[string]
            if ($dataset.autoExploration -and [bool]$dataset.autoExploration.enabled) {
                $initialControls = @(Get-HtsDiscoveredControls -Context $discoveryContext -Screen $screen -ScreenNumber ([string]$case.screen.screenNumber) -ClaimedHwnds $claimedHwnds)
                if ($scenarioMode -and [bool]$case.scenarioCase.transactional) {
                    $expectedAccount = ([string]$case.account.accountNumber -replace '\D','')
                    $allowObservedPrefilledAccount = [bool]$dataset.executionPolicy.allowObservedPrefilledTransactionalAccount -and $inputMode -eq 'Prefilled'
                    foreach ($accountCandidate in @($initialControls | Where-Object { [string]$_.mapKind -eq 'Account' -and [string]$_.definitionSource -eq 'MAP+Runtime' })) {
                        $accountLive = Resolve-RuleLiveControl $navigationContext $screen $accountCandidate
                        if (-not $accountLive) { continue }
                        $observedAccount = ([string]$accountLive.rawTitle -replace '\D','')
                        if (-not $observedAccount) { $observedAccount = ([string]$accountCandidate.initialValue -replace '\D','') }
                        if (-not $observedAccount) { continue }
                        $matchesConfiguredAccount = $expectedAccount -and $observedAccount -eq $expectedAccount
                        $matchesApprovedPrefilledPolicy = -not $expectedAccount -and $allowObservedPrefilledAccount -and $observedAccount.Length -ge 7
                        if ($matchesConfiguredAccount -or $matchesApprovedPrefilledPolicy) {
                            $transactionAccountVerified = $true
                            $transactionAccountCandidate = $accountCandidate
                            $transactionAccountFingerprint = Get-AccountFingerprint $observedAccount
                            $verificationMode = if ($matchesConfiguredAccount) { '데이터셋 계좌값 일치' } else { '승인된 사전입력 계좌 확인' }
                            $transactionAccountEvidence = "MAP $([string]$accountCandidate.mapScreenCode)/$([string]$accountCandidate.name) $verificationMode (지문 $transactionAccountFingerprint)"
                            break
                        }
                    }
                    Add-Action $actions 'verifyTransactionalAccount' $(if($transactionAccountVerified){'PASS'}else{'PENDING'}) ([string]$case.account.id) $(if($transactionAccountVerified){$transactionAccountEvidence}elseif(-not $expectedAccount -and -not $allowObservedPrefilledAccount){'데이터셋 계좌번호가 비어 있고 사전입력 계좌 실행 정책도 허용되지 않았습니다.'}else{'MAP Account 컨트롤에서 실행 가능한 계좌값을 확인하지 못했습니다.'}) $(if($transactionAccountVerified){''}else{'TRANSACTION_ACCOUNT_NOT_VERIFIED'})
                    if (-not $transactionAccountVerified) { $autoPendingReasons.Add('주문 실행 계좌 미확인') }
                }
                if ($mapModel) {
                    $mapDefinedCount=@($mapModel.controls | Where-Object isActionable).Count
                    $mapBoundCount=@($initialControls | Where-Object { $_.definitionSource -eq 'MAP+Runtime' -and [string]$_.mapScreenCode -eq [string]$mapModel.screenCode }).Count
                    $mapUnboundCount=@($initialControls | Where-Object { $_.definitionSource -eq 'MAP' -and -not $_.mapMatched -and [string]$_.mapScreenCode -eq [string]$mapModel.screenCode }).Count
                    if ($scenarioMode -and $physicalPlan) {
                        $fixedBindingCount = @($physicalPlan.resolvedBindings | Where-Object { [string]$_.scenarioId -eq [string]$case.scenarioCase.scenarioId }).Count
                        Add-Action $actions "bindMapModel" "PASS" ([string]$case.screen.screenNumber) "물리계획 1.1이 시나리오에 고정한 바인딩 $fixedBindingCount개를 실행 단계별로 재검증합니다. 전체 MAP 미결합 $mapUnboundCount개는 현재 시나리오 판정에 포함하지 않습니다."
                    } else {
                        Add-Action $actions "bindMapModel" $(if($mapUnboundCount-eq0){"PASS"}else{"PENDING"}) ([string]$case.screen.screenNumber) "MAP '$($mapModel.screenName)'의 조작 가능 컨트롤 $mapDefinedCount개 중 $mapBoundCount개를 HWND/UIA/탭 순회 결과에 결합했고 $mapUnboundCount개는 미결합으로 기록했습니다." $(if($mapUnboundCount-eq0){""}else{"MAP_CONTROL_NOT_BOUND"})
                        if($mapUnboundCount-gt0){$autoPendingReasons.Add("MAP 컨트롤 미결합 $mapUnboundCount개")}
                    }
                } elseif ($mapConfig -and [bool]$mapConfig.enabled) {
                    Add-Action $actions "bindMapModel" "PENDING" ([string]$case.screen.screenNumber) $(if($mapInitializationIssue){$mapInitializationIssue}else{"해당 화면 MAP 기준 모델을 찾지 못했습니다."}) "MAP_MODEL_NOT_FOUND"
                    $autoPendingReasons.Add("MAP 기준 모델 없음: $($case.screen.screenNumber)")
                }
                $tabQueryRows=@($initialControls | Where-Object { $_.controlKind -eq 'Button' -and ([string]$_.mapSemanticRole -eq 'Query' -or [string]$_.name -eq '조회(탭오더)' -or [string]$_.name -match '^BTN_(Comm|Search|Query)') } | Select-Object -First 1)
                if($tabQueryRows.Count -gt 0){$tabOrderQueryControl=$tabQueryRows[0]}
                foreach ($controlRow in $initialControls) { $discoveredControls.Add($controlRow) }
                $queue = New-Object Collections.ArrayList
                $controlById = @{}
                foreach ($controlRow in $initialControls) { $controlById[[string]$controlRow.controlId] = $controlRow }
                $scheduledPlanIds = @{}
                if ($scenarioMode) {
                    $initialPlans = @(Get-RuleScenarioPlanItems -Controls $initialControls -ScenarioCase $case.scenarioCase)
                    foreach ($planRow in $initialPlans) {
                        if ($physicalPlan) { $planRow = Set-HtsScenarioPhysicalBinding -Context $bindingContext -PlanItem $planRow -ScenarioCase $case.scenarioCase -PhysicalPlan $physicalPlan }
                        [void]$queue.Add($planRow)
                        $scheduledPlanIds[[string]$planRow.planItemId] = $true
                    }
                    Add-Action $actions "discoverControls" "PASS" ([string]$case.screen.screenNumber) "콘텐츠 영역 컨트롤 $($initialControls.Count)개를 발견하고 시나리오 '$([string]$case.scenarioCase.scenarioId)'의 조작 단계 $($queue.Count)개만 계획했습니다."
                } else {
                    $initialPlans = @(Get-RuleControlPlanItems $initialControls)
                    $currentTabPlans = @($initialPlans | Where-Object {
                        $_.control.controlKind -eq "Tab" -and $_.option -and [string]$_.option.value -eq [string]$_.control.initialValue
                    })
                    $initialContentPlans = @($initialPlans | Where-Object { $_.control.controlKind -ne "Tab" })
                    $remainingTabPlans = @($initialPlans | Where-Object {
                        $_.control.controlKind -eq "Tab" -and -not ($_.option -and [string]$_.option.value -eq [string]$_.control.initialValue)
                    })
                    foreach ($planRow in @($currentTabPlans + $initialContentPlans + $remainingTabPlans)) {
                        [void]$queue.Add($planRow)
                        $scheduledPlanIds[[string]$planRow.planItemId] = $true
                    }
                    Add-Action $actions "discoverControls" "PASS" ([string]$case.screen.screenNumber) "콘텐츠 영역에서 컨트롤 $($initialControls.Count)개, 실행 계획 $($queue.Count)개를 생성했습니다."
                }

                $lastScenarioActionPopupHwnds = @()
                # 주문 명령은 TAB_Ord의 Select + AssertSelected가 같은 케이스에서
                # 성공한 상태에서만 실행한다. 탭 전환 실패 뒤의 좌표 클릭을 차단한다.
                $verifiedOrderTabContexts = @{}
                $pendingOrderTabContexts = @{}
                for ($planIndex=0; $planIndex -lt $queue.Count; $planIndex++) {
                    $planItem = $queue[$planIndex]
                    if ($scenarioMode -and [string]$planItem.status -ne 'READY' -and (Test-HtsRequestedScreen $screen ([string]$case.screen.screenNumber))) {
                        $scenarioRefresh = @(Get-HtsDiscoveredControls -Context $discoveryContext -Screen $screen -ScreenNumber ([string]$case.screen.screenNumber) -ClaimedHwnds $claimedHwnds)
                        foreach ($refreshedControl in $scenarioRefresh) {
                            if (@($discoveredControls | Where-Object { [string]$_.controlId -eq [string]$refreshedControl.controlId -and [string]$_.stateContext -eq [string]$refreshedControl.stateContext }).Count -eq 0) {
                                $discoveredControls.Add($refreshedControl)
                            }
                        }
                        $replacement = @(Get-RuleScenarioPlanItems -Controls $scenarioRefresh -ScenarioCase $case.scenarioCase | Where-Object scenarioStepId -eq ([string]$planItem.scenarioStepId) | Select-Object -First 1)
                        if ($replacement.Count -gt 0) {
                            if ($physicalPlan) { $replacement[0] = Set-HtsScenarioPhysicalBinding -Context $bindingContext -PlanItem $replacement[0] -ScenarioCase $case.scenarioCase -PhysicalPlan $physicalPlan }
                            if ([string]$replacement[0].status -eq 'READY') { $mapReboundControls++ }
                            $planItem = $replacement[0]
                            $queue[$planIndex] = $planItem
                        }
                    }
                    $planStarted = Get-Date
                    $option = $planItem.option
                    $expectedOutcome=Get-RuleExpectedOutcome $option @($case.screen.expectedPopupPatterns)
                    foreach($pattern in @($expectedOutcome.messagePatterns)){if($pattern -and -not $executedExpectationPatterns.Contains([string]$pattern)){$executedExpectationPatterns.Add([string]$pattern)}}
                    $requiredExpectationRecord=$null
                    if([string]$expectedOutcome.type -in @('ValidationRequired','FailureRequired')){
                        $requiredExpectationRecord=[pscustomobject]@{controlId=[string]$planItem.control.controlId;optionId=[string]$option.id;outcome=$expectedOutcome;observations=(New-Object Collections.Generic.List[object])}
                        $requiredExpectations.Add($requiredExpectationRecord)
                    }
                    if($expectedOutcome.queryShouldComplete -eq $true){
                        $queryRequiredExpectations.Add([pscustomobject]@{
                            name=$(if($scenarioMode){[string]$planItem.scenarioStepId}else{[string]$planItem.control.controlId})
                            outcome=$expectedOutcome
                        })
                    }
                    if ($PlanOnly -or $planItem.status -ne "READY") {
                        if (-not $PlanOnly -and $scenarioMode -and $physicalPlan) {
                            $automationContractFailure = $true
                            if (-not $automationContractErrorCode) { $automationContractErrorCode = if ([string]$planItem.errorCode) { [string]$planItem.errorCode } else { 'PHYSICAL_BINDING_DRIFT' } }
                            $automationIssues.Add("물리 실행 가능 시나리오의 단계가 실행 시점에 준비되지 않았습니다: $([string]$planItem.scenarioStepId)/$automationContractErrorCode")
                        }
                        $pendingCode = if ($PlanOnly) { "PLAN_ONLY" } else { [string]$planItem.errorCode }
                        $pendingOutput = if ($PlanOnly) { "계획 전용 실행이므로 조작하지 않았습니다." } else { [string]$planItem.control.pendingReason }
                        $controlEvaluation = Invoke-HtsRawObservationEvaluation `
                            $(if ($PlanOnly) { 'EvidenceMissing' } else { 'InfrastructureError' }) `
                            $pendingOutput `
                            $pendingCode `
                            $expectedOutcome `
                            $false `
                            $false `
                            'control-not-executed'
                        $controlTestResult = $controlEvaluation.testResult
                        $controlTests.Add([pscustomobject]@{
                            scenarioId=$(if($scenarioMode){[string]$case.scenarioCase.scenarioId}else{''});scenarioTitle=$(if($scenarioMode){[string]$case.scenarioCase.scenarioTitle}else{''})
                            sourceTestCaseId=$(if($scenarioMode){[string]$case.scenarioCase.sourceTestCaseId}else{''});mapScreenCode=$(if($scenarioMode){[string]$planItem.mapScreenCode}else{''});stateContext=$(if($scenarioMode){[string]$planItem.stateContext}else{''});transactional=$(if($scenarioMode){[bool]$planItem.transactional}else{$false})
                            scenarioStepId=$(if($scenarioMode){[string]$planItem.scenarioStepId}else{''});scenarioSequence=$(if($scenarioMode){[int]$planItem.scenarioSequence}else{0});scenarioAction=$(if($scenarioMode){[string]$planItem.scenarioAction}else{''})
                            expectedObservation=$(if($scenarioMode){[string]$planItem.expectedObservation}else{''})
                            interactionStrategy=[string]$script:ruleCurrentInteractionStrategy;coordinateFocusUsed=$false;coordinateFocusVerified=$false
                            planItemId=[string]$planItem.planItemId; controlId=[string]$planItem.control.controlId; controlKind=[string]$planItem.control.controlKind
                            controlName=[string]$planItem.control.name; optionId=$(if ($option) {[string]$option.id} else {""}); inputValue=$(if ($option) {[string]$option.value} else {""})
                            displayValue=$(if ($option) {[string]$option.displayValue} else {""}); status=[string]$controlTestResult.status; queryTriggered=$false; errorDetected=[bool]$controlTestResult.productDefectDetected
                            expectedOutcomeType=[string]$expectedOutcome.type;expectationSatisfied=[bool]$controlTestResult.expectationSatisfied;testResult=$controlTestResult
                            expectedOutcomeSource=[string]$expectedOutcome.source;expectedOutcomeConfidence=[string]$expectedOutcome.confidence;expectedOutcomeEvidence=@($expectedOutcome.evidence)
                            automationEngine='미실행'
                            output=$pendingOutput; errorCode=$pendingCode; screenshotPath=""; elapsedMs=[int64]((Get-Date)-$planStarted).TotalMilliseconds
                        })
                        $autoPendingReasons.Add("$($planItem.control.controlKind) $($planItem.control.name): $pendingCode")
                        continue
                    }

                    $requestedScreenNumber=[string]$case.screen.screenNumber
                    $errorCountBefore = $errors.Count
                    $popupCountBefore = $popupObservations.Count
                    $dialogHwndsBefore = if($scenarioMode){@(Get-HtsDialogs $main $secret | ForEach-Object {[Int64]$_.window.hwnd} | Sort-Object -Unique)}else{@()}
                    $freshStepDialogs = @()
                    $transactionPreRecordedHwnds = @()
                    $assertedPopupScreenshot = ''
                    $queryTriggered = $false
                    $screenReopened = $false
                    $navigationHandled = $false
                    $restorationFailed = $false
                    $unexpectedScreenClose = $false

                    if(-not (Focus-HtsRequestedScreen $main $screen $requestedScreenNumber)){
                        $screen=Find-ScreenWindow $main $requestedScreenNumber
                    }
                    if(Test-HtsRequestedScreen $screen $requestedScreenNumber){
                        [void](Focus-HtsRequestedScreen $main $screen $requestedScreenNumber)
                        $mapStateBlockReason = ''
                        $planMapCode = ([string]$planItem.mapScreenCode).Trim().ToUpperInvariant()
                        if ($scenarioMode -and [string]$planItem.executionOrder -eq 'CoordinateFocus' -and $planMapCode -and
                            $script:initiallyActiveMapScreenCodes.Count -gt 0 -and $script:initiallyActiveMapScreenCodes -notcontains $planMapCode) {
                            $mapStateBlockReason = "내부화면 $planMapCode 는 현재 0101의 초기 활성 MAP이 아니며 명시적 상태 전환 절차가 없습니다."
                        }
                        $transactionBlockReason = ''
                        if ([bool]$planItem.transactional) {
                            $policy = $dataset.executionPolicy
                            if (-not [bool]$policy.allowTransactionalActions) { $transactionBlockReason = '데이터셋이 주문/전송 실행을 허용하지 않았습니다.' }
                            elseif ([bool]$policy.requireApprovedPlanForTransactionalActions -and [string]$scenarioPlan.approvalStatus -ne 'Approved') { $transactionBlockReason = 'Approved 시나리오 계획이 아닙니다.' }
                            elseif (@($policy.allowedTransactionalAccountIds).Count -eq 0 -or @($policy.allowedTransactionalAccountIds) -notcontains [string]$case.account.id) { $transactionBlockReason = '현재 계좌 ID가 주문 실행 허용 목록에 없습니다.' }
                            elseif (@($policy.allowedTransactionalScreens).Count -eq 0 -or @($policy.allowedTransactionalScreens) -notcontains $requestedScreenNumber) { $transactionBlockReason = '현재 화면이 주문 실행 허용 목록에 없습니다.' }
                            elseif ([string]::IsNullOrWhiteSpace([string]$case.account.accountNumber) -and -not [bool]$policy.allowObservedPrefilledTransactionalAccount) { $transactionBlockReason = '테스트 계좌번호가 데이터셋에 없고 사전입력 계좌 실행 정책도 허용되지 않았습니다.' }
                            elseif (-not $transactionAccountVerified) { $transactionBlockReason = '현재 화면 계좌가 데이터셋 테스트 계좌와 일치한다고 확인되지 않았습니다.' }
                            elseif ($transactionAccountCandidate) {
                                $currentAccountLive = Resolve-RuleLiveControl $navigationContext $screen $transactionAccountCandidate
                                $currentAccountDigits = if ($currentAccountLive) { ([string]$currentAccountLive.rawTitle -replace '\D','') } else { '' }
                                if (-not $currentAccountDigits) { $currentAccountDigits = ([string]$transactionAccountCandidate.initialValue -replace '\D','') }
                                if (-not $currentAccountDigits -or (Get-AccountFingerprint $currentAccountDigits) -ne $transactionAccountFingerprint) {
                                    $transactionBlockReason = '주문 직전 계좌값이 사전 확인 상태와 달라졌습니다.'
                                }
                            }
                        }
                        $orderTabContext = [string]$planItem.stateContext
                        $isOrderTabContext = Test-RuleOrderTabContext $orderTabContext
                        $isOrderTabSelection = $isOrderTabContext -and [string]$planItem.controlLogicalName -eq 'TAB_Ord' -and [string]$planItem.scenarioAction -eq 'Select'
                        $isOrderTabAssertion = $isOrderTabContext -and [string]$planItem.controlLogicalName -eq 'TAB_Ord' -and [string]$planItem.scenarioAction -eq 'AssertSelected'
                        $requiresVerifiedOrderTab = $isOrderTabContext -and -not $isOrderTabSelection -and -not $isOrderTabAssertion
                        if ($mapStateBlockReason) {
                            $invoke=[pscustomobject]@{success=$false;queryEligible=$false;errorCode='MAP_STATE_NOT_ACTIVATED';automationEngine='MAP state guard';output=$mapStateBlockReason}
                        } elseif ($requiresVerifiedOrderTab -and -not $verifiedOrderTabContexts.ContainsKey($orderTabContext)) {
                            $invoke=[pscustomobject]@{success=$false;queryEligible=$false;errorCode='ORDER_TAB_NOT_SELECTED';automationEngine='Order tab guard';output="주문 탭 상태 '$orderTabContext'의 Select + AssertSelected 성공 기록이 없어 해당 컨트롤 조작을 차단했습니다."}
                        } elseif ($transactionBlockReason) {
                            $invoke=[pscustomobject]@{success=$false;queryEligible=$false;errorCode='TRANSACTION_GUARD_BLOCKED';automationEngine='Transaction guard';output=$transactionBlockReason}
                        } elseif ([string]$planItem.scenarioAction -in @('AssertVisible','AssertEnabled','AssertSelected','AssertGrid')) {
                            $invoke = Invoke-RuleControlAssertion $navigationContext $screen $planItem
                        } elseif ([string]$planItem.scenarioAction -eq 'Restore') {
                            $restoreDialogs = @(Get-HtsDialogs $main $secret)
                            $restoreConnectionDialogs = @($restoreDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                            if ($restoreConnectionDialogs.Count -gt 0) {
                                throw "HTS_CONNECTION_LOST: 복구 단계에서 연결 장애 팝업을 발견해 자동 닫기를 중단했습니다."
                            }
                            if ($restoreDialogs.Count -eq 0) {
                                $invoke=[pscustomobject]@{success=$true;queryEligible=$false;errorCode='';automationEngine='Safe dialog restore';output='복구할 팝업이 없어 현재 0101 상태를 유지했습니다.'}
                            } else {
                                $dismissedCount = Dismiss-HtsDialogs $main $secret
                                $remainingRestoreDialogs = @(Get-HtsDialogs $main $secret | Where-Object { -not (Test-HtsConnectionDialog $_) })
                                $restoreSucceeded = $remainingRestoreDialogs.Count -eq 0
                                $invoke=[pscustomobject]@{success=$restoreSucceeded;queryEligible=$false;errorCode=$(if($restoreSucceeded){''}else{'RESTORE_DIALOG_NOT_DISMISSED'});automationEngine='Safe dialog restore';output="dismissed=$dismissedCount, remaining=$($remainingRestoreDialogs.Count)"}
                            }
                        } elseif ([string]$planItem.scenarioAction -eq 'AssertPopup') {
                            Start-Sleep -Milliseconds 250
                            $activePopups = @(Get-HtsDialogs $main $secret)
                            $activePopupHwnds = @($activePopups | ForEach-Object {[Int64]$_.window.hwnd} | Sort-Object -Unique)
                            $matchedFreshHwnds = @($lastScenarioActionPopupHwnds | Where-Object {$activePopupHwnds -contains [Int64]$_} | Sort-Object -Unique)
                            $matchedObservation = @($popupObservations | Where-Object {$matchedFreshHwnds -contains [Int64]$_.windowHwnd} | Select-Object -Last 1)
                            if($matchedObservation.Count -gt 0){$assertedPopupScreenshot=[string]$matchedObservation[0].screenshotPath}
                            $popupAssertionSucceeded = $matchedFreshHwnds.Count -gt 0
                            $invoke=[pscustomobject]@{success=$popupAssertionSucceeded;queryEligible=$false;errorCode=$(if($popupAssertionSucceeded){''}else{'ASSERT_POPUP_NOT_OBSERVED'});automationEngine='Fresh popup observer';output="priorActionNewPopupCount=$($lastScenarioActionPopupHwnds.Count), activePopupCount=$($activePopupHwnds.Count), matchedFreshPopupCount=$($matchedFreshHwnds.Count), matchedHwnds=$($matchedFreshHwnds -join ',')"}
                        } elseif ([string]$planItem.scenarioAction -eq 'AssertNoTransmission') {
                            $transmissionDelta = Get-TransmissionDelta $logBefore
                            $invoke=[pscustomobject]@{success=(-not [bool]$transmissionDelta.hasTransmission);queryEligible=$false;errorCode=$(if($transmissionDelta.hasTransmission){'ASSERT_TRANSMISSION_DETECTED'}else{''});automationEngine='Sensitive log delta';output=$(if($transmissionDelta.hasTransmission){"transmissionSources=$(@($transmissionDelta.sources)-join ',')"}else{'sensitiveTransmissionDelta=none'})}
                        } else {
                            $invoke = Invoke-HtsRuleControlPlanAction -Context $actionContext -NavigationContext $navigationContext -Screen $screen -PlanItem $planItem
                        }
                    }else{
                        $invoke=[pscustomobject]@{success=$false;queryEligible=$false;errorCode='TARGET_SCREEN_NOT_ACTIVE';output='대상 화면을 활성화하지 못해 좌표 입력을 차단했습니다.'}
                    }

                    # 실제 제출 모드는 주문 버튼 직후의 신규 확인창을 먼저 증적화한 뒤
                    # 입력 검증/오류가 아닌 명시적 거래 확인창 하나만 승인한다.
                    if ($invoke.success -and $SubmitTransactionalDialogs -and [bool]$planItem.transactional -and [string]$planItem.scenarioAction -in @('Click','DoubleClick')) {
                        $transactionDialogs = @()
                        for ($transactionDialogAttempt=0; $transactionDialogAttempt -lt 12; $transactionDialogAttempt++) {
                            Start-Sleep -Milliseconds 250
                            $transactionDialogs = @(Get-HtsDialogs $main $secret | Where-Object { $dialogHwndsBefore -notcontains [Int64]$_.window.hwnd })
                            if ($transactionDialogs.Count -gt 0) { break }
                        }
                        if ($transactionDialogs.Count -eq 0) {
                            $invoke.output = "$([string]$invoke.output); transactionSubmission=direct-or-no-confirmation-dialog"
                        } else {
                            Add-PopupObservations -List $popupObservations -Dialogs $transactionDialogs -Main $main -CaseId $case.caseId -ScreenNumber $requestedScreenNumber -ReportBase $ReportDir -ExpectedPatterns @($expectedOutcome.messagePatterns) -MapOracle $mapOracle
                            $transactionPreRecordedHwnds = @($transactionDialogs | ForEach-Object { [Int64]$_.window.hwnd })
                            $eligibleTransactionDialogs = @($transactionDialogs | Where-Object { Test-HtsTransactionalConfirmationDialog $_ $planItem })
                            if ($eligibleTransactionDialogs.Count -eq 1) {
                                $transactionSubmit = Submit-HtsTransactionalDialog $eligibleTransactionDialogs[0] $planItem
                                $invoke.output = "$([string]$invoke.output); $([string]$transactionSubmit.output)"
                                if (-not [bool]$transactionSubmit.success) {
                                    $invoke.success = $false
                                    $invoke.errorCode = [string]$transactionSubmit.errorCode
                                }
                            } else {
                                foreach ($transactionDialog in $transactionDialogs) {
                                    $transactionObservation = Get-HtsDialogObservation $transactionDialog $mapOracle $expectedOutcome $caseErrorRegex
                                    Add-OracleObservation $oracleEvents $transactionObservation 'transaction-confirmation' ([string]$planItem.control.controlId) ([string]$option.id)
                                }
                                $invoke.success = $false
                                $invoke.errorCode = if ($eligibleTransactionDialogs.Count -gt 1) { 'TRANSACTION_CONFIRMATION_AMBIGUOUS' } else { 'TRANSACTION_CONFIRMATION_NOT_ELIGIBLE' }
                                $invoke.output = "$([string]$invoke.output); 입력 검증·오류 또는 모호한 팝업이어서 실제 승인하지 않았습니다. popupCount=$($transactionDialogs.Count), eligible=$($eligibleTransactionDialogs.Count)"
                            }
                        }
                    }
                    $isAssertionStep = [string]$planItem.scenarioAction -like 'Assert*'
                    if ($isOrderTabSelection) {
                        if ($invoke.success) { $pendingOrderTabContexts[$orderTabContext] = $true }
                        else { $pendingOrderTabContexts.Remove($orderTabContext); $verifiedOrderTabContexts.Remove($orderTabContext) }
                    }
                    if ($isOrderTabAssertion) {
                        if ($invoke.success -and $pendingOrderTabContexts.ContainsKey($orderTabContext)) { $verifiedOrderTabContexts[$orderTabContext] = $true }
                        else { $verifiedOrderTabContexts.Remove($orderTabContext) }
                    }
                    if ($isAssertionStep -and -not $invoke.success) {
                        $errors.Add("$([string]$planItem.scenarioAction) 실패: $([string]$planItem.expectedObservation) ($([string]$invoke.errorCode))")
                    }
                    $isExplicitScenarioQuery = $scenarioMode -and [string]$planItem.scenarioAction -eq 'Query'
                    if ($invoke.success -and ($isExplicitScenarioQuery -or [string]$planItem.control.mapSemanticRole -in @('Query','AutoQuery'))) {
                        $mapQueryExecuted = $true
                        $queryTriggered = $true
                        if($isExplicitScenarioQuery){
                            Start-Sleep -Milliseconds ([Math]::Max(500,[int]$dataset.executionPolicy.actionTimeoutMs))
                        }
                    }
                    if (-not $invoke.success) { $automationIssues.Add("컨트롤 '$($planItem.control.name)'의 '$($option.displayValue)' 동작을 완료하지 못했습니다: $($invoke.errorCode)") }
                    if (-not $invoke.success -and [string]$invoke.errorCode -in @('PHYSICAL_BINDING_DRIFT','SCENARIO_CONTROL_NOT_BOUND','CONTROL_STALE','CONTROL_AMBIGUOUS','CONTROL_OUTSIDE_TARGET_SURFACE','CHECK_STATE_UNVERIFIABLE','INPUT_GUARD_BLOCKED','TARGET_SCREEN_NOT_ACTIVE','COORDINATE_FOCUS_SCREEN_CHANGED','COORDINATE_FOCUS_NOT_CONFIRMED','MAP_STATE_NOT_ACTIVATED','ORDER_TAB_NOT_SELECTED','RESTORE_DIALOG_NOT_DISMISSED','TRANSACTION_CONFIRM_BUTTON_NOT_FOUND','TRANSACTION_CONFIRM_DIALOG_REMAINED','TRANSACTION_CONFIRM_CLICK_FAILED','TRANSACTION_CONFIRMATION_AMBIGUOUS','TRANSACTION_CONFIRMATION_NOT_ELIGIBLE')) {
                        $automationContractFailure = $true
                        if (-not $automationContractErrorCode) { $automationContractErrorCode = [string]$invoke.errorCode }
                    }

                    $stepDialogs = @(Get-HtsDialogs $main $secret)
                    if ($stepDialogs.Count -gt 0) {
                        $freshStepDialogs = @($stepDialogs | Where-Object {$dialogHwndsBefore -notcontains [Int64]$_.window.hwnd})
                        $dialogsToRecord = @(
                            if($scenarioMode){
                                if([string]$planItem.scenarioAction -ne 'AssertPopup'){@($freshStepDialogs | Where-Object { $transactionPreRecordedHwnds -notcontains [Int64]$_.window.hwnd })}
                            }else{$stepDialogs}
                        )
                        if(@($dialogsToRecord).Count -gt 0){
                            $popupRecordCountBefore=$popupObservations.Count
                            Add-PopupObservations -List $popupObservations -Dialogs $dialogsToRecord -Main $main -CaseId $case.caseId -ScreenNumber $requestedScreenNumber -ReportBase $ReportDir -ExpectedPatterns @($expectedOutcome.messagePatterns) -MapOracle $mapOracle
                            $recordedPopupRows=@($popupObservations | Select-Object -Skip $popupRecordCountBefore)
                            if($recordedPopupRows.Count -ne $dialogsToRecord.Count){
                                throw "POPUP_EVIDENCE_RECORD_FAILED: 신규 팝업 $($dialogsToRecord.Count)건 중 $($recordedPopupRows.Count)건만 관찰 목록에 기록됐습니다."
                            }
                            if(@($recordedPopupRows | Where-Object {[string]::IsNullOrWhiteSpace([string]$_.screenshotPath)}).Count -gt 0){
                                throw 'POPUP_EVIDENCE_CAPTURE_FAILED: 신규 팝업의 실제 표시 스크린샷을 저장하지 못했습니다.'
                            }
                        }
                        $connectionDialogs = @($stepDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                        if ($connectionDialogs.Count -gt 0) {
                            throw "HTS_CONNECTION_LOST: 컨트롤 단계 직후 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$connectionDialogs[0].text)"
                        }
                        foreach ($dialog in $dialogsToRecord) {
                            $observation=Get-HtsDialogObservation $dialog $mapOracle $expectedOutcome $caseErrorRegex
                            Add-OracleObservation $oracleEvents $observation 'control' ([string]$planItem.control.controlId) ([string]$option.id)
                        }
                        $nextScenarioAction = if ($scenarioMode -and $planIndex + 1 -lt $queue.Count) { [string]$queue[$planIndex + 1].scenarioAction } else { '' }
                        if ($nextScenarioAction -notin @('AssertPopup','Restore')) {
                            [void](Dismiss-HtsDialogs $main $secret)
                        }
                    }

                    $linkedScreens=@(Get-HtsLinkedScreens $main $requestedScreenNumber)
                    if($linkedScreens.Count -gt 0){
                        Add-LinkedScreenObservations $popupObservations $linkedScreens $main $case.caseId $requestedScreenNumber $ReportDir $secret @($planItem.control.mapNavigationTargets)
                        $linkedTitles=@($linkedScreens | ForEach-Object { [string]$_.rawTitle }) -join ', '
                        $linkedClosed=Close-HtsLinkedScreens $main $requestedScreenNumber
                        $navigationHandled=$true
                        $screen=Find-ScreenWindow $main $requestedScreenNumber
                        if(-not $screen){
                            $screenEdit=Find-ScreenNumberEdit $main
                            Open-HtsScreen $main $screenEdit $requestedScreenNumber
                            $screen=Find-ScreenWindow $main $requestedScreenNumber
                            $screenReopened=($null -ne $screen)
                        }
                        if($screen){[void](Focus-HtsRequestedScreen $main $screen $requestedScreenNumber)}
                        $restorationFailed=-not (Test-HtsRequestedScreen $screen $requestedScreenNumber)
                        Add-Action $actions 'restoreAfterNavigation' $(if($restorationFailed){'PENDING'}else{'PASS'}) $requestedScreenNumber "연계 화면을 관찰하고 $linkedClosed/$($linkedScreens.Count)개를 닫은 뒤 대상 화면을 복원했습니다: $linkedTitles" $(if($restorationFailed){'TARGET_RESTORE_FAILED'}else{''})
                    }

                    $screenAlive=Test-HtsRequestedScreen $screen $requestedScreenNumber
                    if(-not $screenAlive -and -not $navigationHandled){
                        $isButtonTransition=$invoke.success -and [string]$planItem.control.controlKind -eq 'Button' -and (
                            [string]$planItem.control.mapSemanticRole -eq 'Navigation' -or @($planItem.control.mapNavigationTargets).Count -gt 0
                        )
                        if($isButtonTransition){
                            Add-UnnumberedTransitionObservation $popupObservations $main $case.caseId $requestedScreenNumber $ReportDir $secret
                            $navigationHandled=$true
                        }else{
                            $unexpectedScreenClose=$true
                            $errors.Add("컨트롤 조작 중 [$requestedScreenNumber] 화면이 예기치 않게 닫혔습니다.")
                        }
                        $screenEdit=Find-ScreenNumberEdit $main
                        Open-HtsScreen $main $screenEdit $requestedScreenNumber
                        $screen=Find-ScreenWindow $main $requestedScreenNumber
                        $screenReopened=($null -ne $screen)
                        $screenAlive=Test-HtsRequestedScreen $screen $requestedScreenNumber
                        if($isButtonTransition){
                            $restorationFailed=-not $screenAlive
                            Add-Action $actions 'restoreAfterUnnumberedTransition' $(if($restorationFailed){'PENDING'}else{'PASS'}) $requestedScreenNumber '버튼 조작으로 발생한 번호 없는 콘텐츠 전환을 기록하고 대상 화면을 다시 열었습니다.' $(if($restorationFailed){'TARGET_RESTORE_FAILED'}else{''})
                        }else{
                            Add-Action $actions 'reopenScreen' 'FAIL' $requestedScreenNumber '연계 화면 없이 대상 화면이 사라져 다시 열었습니다.' 'SCREEN_CLOSED_UNEXPECTEDLY'
                        }
                    }
                    if($screenReopened -and $screenAlive){$claimedHwnds=Get-HtsClaimedControlHwndMap -Context $bindingContext -Screen $screen -Case $case -Dataset $dataset}

                    $triggerQueryForPlanItem = if ($scenarioMode) { [bool]$planItem.triggerQueryAfterChange } else { [bool]$dataset.autoExploration.triggerQueryAfterStateChange }
                    if ($invoke.success -and $invoke.queryEligible -and -not $navigationHandled -and $screenAlive -and $triggerQueryForPlanItem) {
                        [void](Focus-HtsRequestedScreen $main $screen $requestedScreenNumber)
                        $liveTabQuery=if($tabOrderQueryControl){Resolve-RuleLiveControl $navigationContext $screen $tabOrderQueryControl}else{$null}
                        if($liveTabQuery){
                            $queryResult=Invoke-FlaUiControlAction $liveTabQuery 'invoke'
                            if(-not ([bool]$queryResult.success -and [bool]$queryResult.verified)){Click-Center $liveTabQuery}
                        }else{Send-Key ([byte]$VK_F12)}
                        Start-Sleep -Milliseconds ([Math]::Max(500,[int]$dataset.executionPolicy.actionTimeoutMs))
                        $queryTriggered = $true
                        $mapQueryExecuted = $true

                        $queryDialogs=@(Get-HtsDialogs $main $secret)
                        if($queryDialogs.Count -gt 0){
                            Add-PopupObservations $popupObservations $queryDialogs $main $case.caseId $requestedScreenNumber $ReportDir @($expectedOutcome.messagePatterns) $mapOracle
                            $queryConnectionDialogs = @($queryDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                            if ($queryConnectionDialogs.Count -gt 0) {
                                throw "HTS_CONNECTION_LOST: 조회 직후 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$queryConnectionDialogs[0].text)"
                            }
                            foreach($dialog in $queryDialogs){
                                $observation=Get-HtsDialogObservation $dialog $mapOracle $expectedOutcome $caseErrorRegex
                                Add-OracleObservation $oracleEvents $observation 'query-after-control' ([string]$planItem.control.controlId) ([string]$option.id)
                            }
                            [void](Dismiss-HtsDialogs $main $secret)
                        }
                        $queryLinkedScreens=@(Get-HtsLinkedScreens $main $requestedScreenNumber)
                        if($queryLinkedScreens.Count -gt 0){
                            Add-LinkedScreenObservations $popupObservations $queryLinkedScreens $main $case.caseId $requestedScreenNumber $ReportDir $secret @($planItem.control.mapNavigationTargets)
                            $queryLinkedClosed=Close-HtsLinkedScreens $main $requestedScreenNumber
                            $navigationHandled=$true
                            $screen=Find-ScreenWindow $main $requestedScreenNumber
                            if(-not $screen){
                                $screenEdit=Find-ScreenNumberEdit $main
                                Open-HtsScreen $main $screenEdit $requestedScreenNumber
                                $screen=Find-ScreenWindow $main $requestedScreenNumber
                                $screenReopened=($null -ne $screen)
                            }
                            if($screen){[void](Focus-HtsRequestedScreen $main $screen $requestedScreenNumber)}
                            $restorationFailed=-not (Test-HtsRequestedScreen $screen $requestedScreenNumber)
                            Add-Action $actions 'restoreAfterQueryNavigation' $(if($restorationFailed){'PENDING'}else{'PASS'}) $requestedScreenNumber "조회 후 열린 연계 화면 $queryLinkedClosed/$($queryLinkedScreens.Count)개를 닫고 대상 화면을 복원했습니다." $(if($restorationFailed){'TARGET_RESTORE_FAILED'}else{''})
                        }
                        $screenAlive=Test-HtsRequestedScreen $screen $requestedScreenNumber
                        if(-not $screenAlive -and $queryLinkedScreens.Count -eq 0){
                            Add-UnnumberedTransitionObservation $popupObservations $main $case.caseId $requestedScreenNumber $ReportDir $secret
                            $navigationHandled=$true
                            $screenEdit=Find-ScreenNumberEdit $main
                            Open-HtsScreen $main $screenEdit $requestedScreenNumber
                            $screen=Find-ScreenWindow $main $requestedScreenNumber
                            $screenReopened=($null -ne $screen)
                            $screenAlive=Test-HtsRequestedScreen $screen $requestedScreenNumber
                            $restorationFailed=-not $screenAlive
                            Add-Action $actions 'restoreAfterQueryTransition' $(if($restorationFailed){'PENDING'}else{'PASS'}) $requestedScreenNumber '조회 후 번호 없는 콘텐츠 전환을 기록하고 대상 화면을 다시 열었습니다.' $(if($restorationFailed){'TARGET_RESTORE_FAILED'}else{''})
                        }
                    }

                    if ($scenarioMode) {
                        if ([string]$planItem.scenarioAction -eq 'AssertPopup') {
                            $lastScenarioActionPopupHwnds = @()
                        } elseif ([string]$planItem.scenarioAction -notlike 'Assert*') {
                            $lastScenarioActionPopupHwnds = @($freshStepDialogs | ForEach-Object {[Int64]$_.window.hwnd} | Sort-Object -Unique)
                        }
                    }

                    $newErrors = $errors.Count -gt $errorCountBefore
                    $queryExpectationIncomplete = $false
                    $hasDeferredScenarioQuery = $false
                    if($scenarioMode -and $expectedOutcome.queryShouldComplete -eq $true -and -not $queryTriggered){
                        for($futurePlanIndex=$planIndex+1;$futurePlanIndex -lt $queue.Count;$futurePlanIndex++){
                            if([string]$queue[$futurePlanIndex].scenarioAction -eq 'Query'){
                                $hasDeferredScenarioQuery=$true
                                break
                            }
                        }
                    }
                    if ($expectedOutcome.queryShouldComplete -eq $true -and -not $queryTriggered -and -not $hasDeferredScenarioQuery) {
                        $queryExpectationIncomplete = $true
                        $automationIssues.Add("컨트롤 '$($planItem.control.name)'의 '$($option.displayValue)' 값은 조회 완료가 필요하지만 조회를 실행하지 못했습니다: QUERY_EXPECTATION_NOT_EXECUTED")
                        $autoPendingReasons.Add("$($planItem.control.controlKind) $($planItem.control.name): QUERY_EXPECTATION_NOT_EXECUTED")
                    }
                    $controlObservationKind = if ($unexpectedScreenClose -or $newErrors -or ($isAssertionStep -and -not $invoke.success)) { 'ProductFailure' } elseif (-not $invoke.success -or $restorationFailed -or $queryExpectationIncomplete) { 'EvidenceMissing' } else { 'Success' }
                    $controlObservationCode = if (-not $invoke.success) {[string]$invoke.errorCode} elseif ($restorationFailed) {'TARGET_RESTORE_FAILED'} elseif ($queryExpectationIncomplete) {'QUERY_EXPECTATION_NOT_EXECUTED'} elseif ($unexpectedScreenClose) {'SCREEN_CLOSED_UNEXPECTEDLY'} elseif ($newErrors) {'PRODUCT_DEFECT_DETECTED'} else {''}
                    $controlCompletionExpectation = [pscustomobject]@{ type='Success';expectationId=[string]$expectedOutcome.expectationId;messagePatterns=@();errorCodes=@();evidence=@('컨트롤 실행 완료 계약') }
                    $controlEvaluation = Invoke-HtsRawObservationEvaluation `
                        $controlObservationKind `
                        ([string]$invoke.output) `
                        $controlObservationCode `
                        $controlCompletionExpectation `
                        ([bool]($invoke.success -or $newErrors)) `
                        ($controlObservationKind -ne 'EvidenceMissing') `
                        'control-completion'
                    $controlTestResult = $controlEvaluation.testResult
                    if($requiredExpectationRecord){$requiredExpectationRecord.observations.Add(@($controlEvaluation.evaluationCase.observations)[0])}
                    $status = [string]$controlTestResult.status
                    $shot = $assertedPopupScreenshot
                    if ($popupObservations.Count -gt $popupCountBefore) { $shot = [string]$popupObservations[$popupObservations.Count-1].screenshotPath }
                    $controlTests.Add([pscustomobject]@{
                        scenarioId=$(if($scenarioMode){[string]$case.scenarioCase.scenarioId}else{''});scenarioTitle=$(if($scenarioMode){[string]$case.scenarioCase.scenarioTitle}else{''})
                        sourceTestCaseId=$(if($scenarioMode){[string]$case.scenarioCase.sourceTestCaseId}else{''});mapScreenCode=$(if($scenarioMode){[string]$planItem.mapScreenCode}else{''});stateContext=$(if($scenarioMode){[string]$planItem.stateContext}else{''});transactional=$(if($scenarioMode){[bool]$planItem.transactional}else{$false})
                        scenarioStepId=$(if($scenarioMode){[string]$planItem.scenarioStepId}else{''});scenarioSequence=$(if($scenarioMode){[int]$planItem.scenarioSequence}else{0});scenarioAction=$(if($scenarioMode){[string]$planItem.scenarioAction}else{''})
                        expectedObservation=$(if($scenarioMode){[string]$planItem.expectedObservation}else{''})
                        interactionStrategy=$(if($invoke.PSObject.Properties.Name -contains 'interactionStrategy'){[string]$invoke.interactionStrategy}else{[string]$script:ruleCurrentInteractionStrategy})
                        coordinateFocusUsed=$(if($invoke.PSObject.Properties.Name -contains 'coordinateFocusUsed'){[bool]$invoke.coordinateFocusUsed}else{$false})
                        coordinateFocusVerified=$(if($invoke.PSObject.Properties.Name -contains 'coordinateFocusVerified'){[bool]$invoke.coordinateFocusVerified}else{$false})
                        planItemId=[string]$planItem.planItemId; controlId=[string]$planItem.control.controlId; controlKind=[string]$planItem.control.controlKind
                        controlName=[string]$planItem.control.name; optionId=[string]$option.id; inputValue=$(if ($planItem.control.controlKind -in @("Text","Date")) {[string]$option.value} else {""})
                        displayValue=[string]$option.displayValue; status=$status; queryTriggered=$queryTriggered; errorDetected=[bool]$controlTestResult.productDefectDetected
                        expectedOutcomeType=[string]$expectedOutcome.type;expectationSatisfied=[bool]$controlTestResult.expectationSatisfied;testResult=$controlTestResult
                        expectedOutcomeSource=[string]$expectedOutcome.source;expectedOutcomeConfidence=[string]$expectedOutcome.confidence;expectedOutcomeEvidence=@($expectedOutcome.evidence)
                        automationEngine=$(if($invoke.PSObject.Properties.Name -contains 'automationEngine'){[string]$invoke.automationEngine}else{'Win32 fallback'})
                        bindingResolution=$(if($invoke.PSObject.Properties.Name -contains 'resolution'){$invoke.resolution}else{$null})
                        output=([string]$invoke.output + $(if($navigationHandled){' 연계 화면을 관찰·정리하고 원래 화면으로 복귀했습니다.'}elseif($screenReopened){' 화면을 다시 열어 다음 항목을 계속했습니다.'}else{''}))
                        errorCode=[string]$controlTestResult.code
                        screenshotPath=$shot; elapsedMs=[int64]((Get-Date)-$planStarted).TotalMilliseconds
                    })

                    if (-not $scenarioMode -and (Test-HtsRequestedScreen $screen ([string]$case.screen.screenNumber))) {
                        $refreshed = @(Get-HtsDiscoveredControls -Context $discoveryContext -Screen $screen -ScreenNumber ([string]$case.screen.screenNumber) -ClaimedHwnds $claimedHwnds)
                        $newPlans = New-Object Collections.Generic.List[object]
                        foreach ($refreshedControl in $refreshed) {
                            $controlId = [string]$refreshedControl.controlId
                            $controlForPlan = $refreshedControl
                            $isRuntimeUpgrade = $false
                            if ($controlById.ContainsKey($controlId)) {
                                $existingControl = $controlById[$controlId]
                                $isRuntimeUpgrade = (
                                    ([string]$existingControl.definitionSource -eq 'MAP' -and [string]$refreshedControl.definitionSource -eq 'MAP+Runtime') -or
                                    (@($existingControl.options).Count -lt @($refreshedControl.options).Count)
                                )
                                if ($isRuntimeUpgrade) {
                                    foreach ($property in $refreshedControl.PSObject.Properties) {
                                        $existingControl | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
                                    }
                                    $controlForPlan = $existingControl
                                    if ([string]$existingControl.mapModelId) { $mapReboundControls++ }
                                }
                            } else {
                                $controlById[$controlId] = $refreshedControl
                                $discoveredControls.Add($refreshedControl)
                                $isRuntimeUpgrade = $true
                            }
                            if (-not $isRuntimeUpgrade) { continue }
                            if($controlForPlan.controlKind -eq 'Button' -and ([string]$controlForPlan.mapSemanticRole -eq 'Query' -or [string]$controlForPlan.name -eq '조회(탭오더)' -or [string]$controlForPlan.name -match '^BTN_(Comm|Search|Query)')){$tabOrderQueryControl=$controlForPlan}
                            foreach ($newPlan in @(Get-RuleControlPlanItems @($controlForPlan))) {
                                if (-not $scheduledPlanIds.ContainsKey([string]$newPlan.planItemId)) {
                                    $scheduledPlanIds[[string]$newPlan.planItemId] = $true
                                    $newPlans.Add($newPlan)
                                }
                            }
                        }
                        for ($newIndex=$newPlans.Count-1; $newIndex -ge 0; $newIndex--) {
                            if ($queue.Count -lt [int]$dataset.autoExploration.maxActionsPerScreen) { [void]$queue.Insert($planIndex+1,$newPlans[$newIndex]) }
                        }
                    }
                }
                if ($mapReboundControls -gt 0) {
                    Add-Action $actions 'rediscoverMapControls' 'PASS' ([string]$case.screen.screenNumber) "상태 변경 뒤 새로 활성화되거나 선택지가 늘어난 MAP 컨트롤 $mapReboundControls건을 다시 결합해 실행 계획에 추가했습니다."
                } elseif ($mapBehavior -and @($mapBehavior.stateControllerControls).Count -gt 0) {
                    Add-Action $actions 'rediscoverMapControls' 'PASS' ([string]$case.screen.screenNumber) '상태 변경마다 MAP 컨트롤을 다시 탐색했으며 추가 활성화된 컨트롤은 없었습니다.'
                }
                $controlEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId="$($case.caseId)-controls";cases=@($script:currentResultEvaluationCases.ToArray())}
                $controlEvaluationOutput=Invoke-RuleResultEvaluation -CliProject $cliProject -TestPackPath $resultEvaluationTestPackPath -EvaluationDocument $controlEvaluationDocument -WorkingDirectory $resultEvaluationWorkingDirectory -InvocationId 'case-controls'
                Add-Action $actions "executeControlOptions" ([string]$controlEvaluationOutput.overallResult.status) "content controls" "컨트롤 선택지 $($controlTests.Count)개를 계획 또는 실행했습니다. $([string]$controlEvaluationOutput.overallResult.reason)"
            }

            if (-not $PlanOnly -and -not $scenarioMode) {
                $requestedScreenNumber=[string]$case.screen.screenNumber
                if(-not (Focus-HtsRequestedScreen $main $screen $requestedScreenNumber)){
                    $screen=Find-ScreenWindow $main $requestedScreenNumber
                }
                $queryStrategies = if ($case.screen.locators -and $case.screen.locators.query) { $case.screen.locators.query } else { $dataset.defaultLocators.query }
                $queryControls = if(Test-HtsRequestedScreen $screen $requestedScreenNumber){@(Get-HtsRequiredQueryControls -Context $bindingContext -Screen $screen -Strategies $queryStrategies)}else{@()}
                if($tabOrderQueryControl -and (Test-HtsRequestedScreen $screen $requestedScreenNumber)){
                    $liveTabQuery=Resolve-RuleLiveControl $navigationContext $screen $tabOrderQueryControl
                    if($liveTabQuery){$queryControls=@($liveTabQuery)+@($queryControls)}
                }
                $queryControls=@($queryControls | Group-Object { "{0}:{1}" -f [int](($_.rect.left+$_.rect.right)/2),[int](($_.rect.top+$_.rect.bottom)/2) } | ForEach-Object {$_.Group[0]})
                if ($queryControls.Count -gt 0) {
                    for ($queryIndex=0; $queryIndex -lt $queryControls.Count; $queryIndex++) {
                        $queryStarted=Get-Date
                        $queryControl=$queryControls[$queryIndex]
                        if(-not (Focus-HtsRequestedScreen $main $screen $requestedScreenNumber)){
                            $automationIssues.Add('필수 조회 직전에 대상 화면을 활성화하지 못했습니다: TARGET_SCREEN_NOT_ACTIVE')
                            break
                        }
                        try {
                            $queryResult=Invoke-FlaUiControlAction $queryControl 'invoke'
                            $queryActionEngine=if([bool]$queryResult.success -and [bool]$queryResult.verified){'FlaUI.UIA3'}else{'Win32 fallback'}
                            if($queryActionEngine -eq 'Win32 fallback'){Click-Center $queryControl}
                            $mapQueryExecuted = $true
                        } catch {
                            $guardMessage=Protect-Text $_.Exception.Message $secret
                            $queryExpectation = [pscustomobject]@{type='Success';expectationId="required-query-$queryIndex";messagePatterns=@();errorCodes=@();evidence=@('필수 조회 실행 계약')}
                            $guardEvaluation = Invoke-HtsRawObservationEvaluation 'EvidenceMissing' $guardMessage 'INPUT_GUARD_BLOCKED' $queryExpectation $false $false 'required-query-guard'
                            $guardTestResult = $guardEvaluation.testResult
                            $controlTests.Add([pscustomobject]@{
                                planItemId="REQUIRED-QUERY-$queryIndex";controlId="REQUIRED-QUERY-$queryIndex";controlKind="Button";controlName='조회'
                                optionId='click';inputValue='';displayValue='조회';status=[string]$guardTestResult.status;queryTriggered=$false;errorDetected=[bool]$guardTestResult.productDefectDetected;testResult=$guardTestResult
                                output="전경 안전 검증으로 필수 조회 입력을 차단했습니다: $guardMessage";errorCode=[string]$guardTestResult.code;screenshotPath='';elapsedMs=[int64]((Get-Date)-$queryStarted).TotalMilliseconds
                            })
                            Add-Action $actions 'invokeQuery' 'PENDING' '조회' '전경 안전 검증으로 필수 조회 입력을 차단했습니다.' 'INPUT_GUARD_BLOCKED'
                            $automationIssues.Add("필수 조회 입력 차단: $guardMessage")
                            break
                        }
                        Start-Sleep -Milliseconds ([Math]::Max(500,[int]$dataset.executionPolicy.actionTimeoutMs))

                        $queryDialogs=@(Get-HtsDialogs $main $secret)
                        if($queryDialogs.Count -gt 0){
                            $caseExpectedOutcome=Get-RuleExpectedOutcome $null @(@($case.screen.expectedPopupPatterns)+@($executedExpectationPatterns))
                            Add-PopupObservations $popupObservations $queryDialogs $main $case.caseId $requestedScreenNumber $ReportDir @($caseExpectedOutcome.messagePatterns) $mapOracle
                            $requiredQueryConnectionDialogs = @($queryDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                            if ($requiredQueryConnectionDialogs.Count -gt 0) {
                                throw "HTS_CONNECTION_LOST: 필수 조회 직후 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$requiredQueryConnectionDialogs[0].text)"
                            }
                            foreach($dialog in $queryDialogs){
                                $observation=Get-HtsDialogObservation $dialog $mapOracle $caseExpectedOutcome $caseErrorRegex
                                Add-OracleObservation $oracleEvents $observation 'required-query'
                            }
                            [void](Dismiss-HtsDialogs $main $secret)
                        }
                        $queryLinkedScreens=@(Get-HtsLinkedScreens $main $requestedScreenNumber)
                        $queryNavigationHandled=$false
                        if($queryLinkedScreens.Count -gt 0){
                            Add-LinkedScreenObservations $popupObservations $queryLinkedScreens $main $case.caseId $requestedScreenNumber $ReportDir $secret @($tabOrderQueryControl.mapNavigationTargets)
                            $queryLinkedClosed=Close-HtsLinkedScreens $main $requestedScreenNumber
                            $queryNavigationHandled=$true
                            $screen=Find-ScreenWindow $main $requestedScreenNumber
                            if(-not $screen){
                                $screenEdit=Find-ScreenNumberEdit $main
                                Open-HtsScreen $main $screenEdit $requestedScreenNumber
                                $screen=Find-ScreenWindow $main $requestedScreenNumber
                            }
                            if($screen){[void](Focus-HtsRequestedScreen $main $screen $requestedScreenNumber)}
                            Add-Action $actions 'restoreAfterRequiredQuery' $(if(Test-HtsRequestedScreen $screen $requestedScreenNumber){'PASS'}else{'PENDING'}) $requestedScreenNumber "필수 조회 후 열린 연계 화면 $queryLinkedClosed/$($queryLinkedScreens.Count)개를 닫고 대상 화면을 복원했습니다." $(if(Test-HtsRequestedScreen $screen $requestedScreenNumber){''}else{'TARGET_RESTORE_FAILED'})
                        }
                        $queryAlive=Test-HtsRequestedScreen $screen $requestedScreenNumber
                        if(-not $queryAlive -and -not $queryNavigationHandled){
                            Add-UnnumberedTransitionObservation $popupObservations $main $case.caseId $requestedScreenNumber $ReportDir $secret
                            $queryNavigationHandled=$true
                            $screenEdit=Find-ScreenNumberEdit $main
                            Open-HtsScreen $main $screenEdit $requestedScreenNumber
                            $screen=Find-ScreenWindow $main $requestedScreenNumber
                            if($screen){[void](Focus-HtsRequestedScreen $main $screen $requestedScreenNumber)}
                            $queryAlive=Test-HtsRequestedScreen $screen $requestedScreenNumber
                            Add-Action $actions 'restoreAfterRequiredQueryTransition' $(if($queryAlive){'PASS'}else{'PENDING'}) $requestedScreenNumber '필수 조회 후 번호 없는 콘텐츠 전환을 기록하고 대상 화면을 다시 열었습니다.' $(if($queryAlive){''}else{'TARGET_RESTORE_FAILED'})
                        }
                        $queryObservationKind=if($queryAlive){'Success'}elseif($queryNavigationHandled){'EvidenceMissing'}else{'ProductFailure'}
                        $queryObservationCode=if($queryAlive){''}elseif($queryNavigationHandled){'TARGET_RESTORE_FAILED'}else{'SCREEN_CLOSED_UNEXPECTEDLY'}
                        $queryName=if($queryControl.rawTitle){[string]$queryControl.rawTitle}elseif($tabOrderQueryControl){[string]$tabOrderQueryControl.name}else{"조회"}
                        $queryExpectation = [pscustomobject]@{type='Success';expectationId="required-query-$queryIndex";messagePatterns=@();errorCodes=@();evidence=@('필수 조회 실행 계약')}
                        $queryEvaluation = Invoke-HtsRawObservationEvaluation $queryObservationKind '활성화된 조회 버튼을 필수 단계에서 실제 클릭했습니다.' $queryObservationCode $queryExpectation $true ($queryObservationKind -ne 'EvidenceMissing') 'required-query'
                        $queryTestResult = $queryEvaluation.testResult
                        $queryStatus = [string]$queryTestResult.status
                        $controlTests.Add([pscustomobject]@{
                            planItemId="REQUIRED-QUERY-$queryIndex";controlId="REQUIRED-QUERY-$queryIndex";controlKind="Button";controlName=$queryName
                            optionId="click";inputValue="";displayValue=$queryName;status=$queryStatus;queryTriggered=$true;errorDetected=[bool]$queryTestResult.productDefectDetected;testResult=$queryTestResult
                            automationEngine=$queryActionEngine
                            output="활성화된 조회 버튼을 필수 단계에서 실제 클릭했습니다.";errorCode=[string]$queryTestResult.code;screenshotPath="";elapsedMs=[int64]((Get-Date)-$queryStarted).TotalMilliseconds
                        })
                        Add-Action $actions "invokeQuery" $queryStatus $queryName "활성화된 조회 버튼을 필수 단계에서 실제 클릭했습니다." $(if($queryAlive){""}elseif($queryNavigationHandled){'TARGET_RESTORE_FAILED'}else{"SCREEN_CLOSED_UNEXPECTEDLY"})
                        if (-not $queryAlive -and -not $queryNavigationHandled) { $errors.Add("조회 버튼 클릭 후 [$requestedScreenNumber] 화면이 예기치 않게 닫혔습니다."); break }
                    }
                } elseif (@($controlTests | Where-Object { $_.controlKind -eq 'Button' -and $_.controlName -eq '조회(탭오더)' -and $_.queryTriggered -and -not $_.errorDetected }).Count -gt 0) {
                    $completedTabQueries=@($controlTests | Where-Object { $_.controlKind -eq 'Button' -and $_.controlName -eq '조회(탭오더)' -and $_.queryTriggered -and -not $_.errorDetected }).Count
                    $queryHistoryExpectation = [pscustomobject]@{type='Success';expectationId='required-query-history';messagePatterns=@();errorCodes=@();evidence=@('탭오더 조회 실행 이력')}
                    $queryHistoryEvaluation = Invoke-HtsRawObservationEvaluation 'Success' "탭오더 조회 버튼 $completedTabQueries개 실행 이력" '' $queryHistoryExpectation $true $true 'required-query-history'
                    $queryHistoryTestResult = $queryHistoryEvaluation.testResult
                    $controlTests.Add([pscustomobject]@{
                        planItemId='REQUIRED-QUERY-HISTORY';controlId='REQUIRED-QUERY-HISTORY';controlKind='Button';controlName='조회(탭오더)'
                        optionId='verified';inputValue='';displayValue="탭오더 조회 버튼 $completedTabQueries개";status=[string]$queryHistoryTestResult.status;queryTriggered=$true;errorDetected=[bool]$queryHistoryTestResult.productDefectDetected;testResult=$queryHistoryTestResult
                        output="탭오더 순회 중 식별된 활성 조회 버튼 $completedTabQueries개를 실제 클릭했습니다.";errorCode=[string]$queryHistoryTestResult.code;screenshotPath='';elapsedMs=0
                    })
                    Add-Action $actions 'invokeQuery' 'PASS' '탭오더 조회 이력' "탭오더 순회 중 식별된 활성 조회 버튼 $completedTabQueries개를 실제 클릭했습니다."
                    $mapQueryExecuted = $true
                } else {
                    if(Focus-HtsRequestedScreen $main $screen $requestedScreenNumber){
                        Send-Key ([byte]$VK_F12)
                        Start-Sleep -Milliseconds ([Math]::Max(500,[int]$dataset.executionPolicy.actionTimeoutMs))
                        Add-Action $actions "invokeQuery" "PASS" "F12" "활성 조회 버튼을 찾지 못해 화면의 F12 조회 단축키를 실행했습니다."
                        $mapQueryExecuted = $true
                        $automationIssues.Add("활성화된 조회 버튼을 찾지 못해 F12로 대체했습니다: QUERY_BUTTON_NOT_FOUND")
                    }else{
                        Add-Action $actions 'invokeQuery' 'PENDING' 'F12' '대상 화면을 활성화하지 못해 F12 입력을 차단했습니다.' 'TARGET_SCREEN_NOT_ACTIVE'
                        $automationIssues.Add('대상 화면을 활성화하지 못해 필수 조회를 실행하지 못했습니다: TARGET_SCREEN_NOT_ACTIVE')
                    }
                }
            } else {
                Add-Action $actions "invokeQuery" "PENDING" $queryTrigger "계획 전용 실행이므로 조회를 실행하지 않았습니다." "PLAN_ONLY"
            }
            if ($mapBehavior -and @($mapBehavior.queryControls).Count -gt 0) {
                if ($mapQueryExecuted) {
                    Add-Action $actions 'evaluateMapBehavior' 'PASS' (@($mapBehavior.queryControls) -join ', ') 'MAP이 정의한 조회 경로를 실제 컨트롤 조작 또는 조회 단축키로 실행했습니다.'
                } else {
                    Add-Action $actions 'evaluateMapBehavior' 'PENDING' (@($mapBehavior.queryControls) -join ', ') 'MAP이 정의한 조회 경로의 실행 증거를 확보하지 못했습니다.' 'MAP_QUERY_NOT_EXECUTED'
                    $autoPendingReasons.Add('MAP 조회 트리거 미실행')
                }
            } elseif ($mapBehavior) {
                Add-Action $actions 'evaluateMapBehavior' 'PASS' ([string]$case.screen.screenNumber) 'MAP에 별도 조회 역할 컨트롤이 정의되지 않은 화면입니다.'
            }
            foreach ($reason in $autoPendingReasons) { $pendingReasons.Add($reason) }
            if ($automationIssues.Count -gt 0) { $pendingReasons.Add("자동 컨트롤 조작 일부 미완료($($automationIssues.Count)건)") }
        }

        $caseExpectedOutcome=Get-RuleExpectedOutcome $null @(@($case.screen.expectedPopupPatterns)+@($executedExpectationPatterns))
        $finalDialogs = @(Get-HtsDialogs $main $secret)
        if ($finalDialogs.Count -gt 0) {
            Add-PopupObservations $popupObservations $finalDialogs $main $case.caseId ([string]$case.screen.screenNumber) $ReportDir @($caseExpectedOutcome.messagePatterns) $mapOracle
            $finalConnectionDialogs = @($finalDialogs | Where-Object { Test-HtsConnectionDialog $_ })
            if ($finalConnectionDialogs.Count -gt 0) {
                throw "HTS_CONNECTION_LOST: 케이스 종료 전 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$finalConnectionDialogs[0].text)"
            }
            foreach ($dialog in $finalDialogs) {
                $observation=Get-HtsDialogObservation $dialog $mapOracle $caseExpectedOutcome $caseErrorRegex
                Add-OracleObservation $oracleEvents $observation 'final-dialog'
            }
        }
        $windowErrors = @(Get-ExplicitWindowErrors $main $beforeErrorTexts $caseErrorRegex $secret $mapOracle)
        $logErrors = @(Get-LogErrors $logBefore $caseErrorRegex $secret $mapOracle)
        foreach ($message in $windowErrors) {
            $observation=Get-HtsSignalObservation ([string]$message) $mapOracle $caseExpectedOutcome $caseErrorRegex
            Add-OracleObservation $oracleEvents $observation 'window-text'
        }
        foreach ($message in $logErrors) {
            $observation=Get-HtsSignalObservation ([string]$message) $mapOracle $caseExpectedOutcome $caseErrorRegex
            Add-OracleObservation $oracleEvents $observation 'log'
        }
        # Windows PowerShell 5.1은 빈 제네릭 List<object>를 @()로 감쌀 때 바인더 예외를 낼 수 있어 배열로 명시 변환한다.
        foreach($queryRequired in $queryRequiredExpectations.ToArray()){
            if(-not $mapQueryExecuted){
                $pendingReasons.Add("입력 또는 시나리오 단계 '$([string]$queryRequired.name)'의 기대 계약은 조회 완료가 필요하지만 조회를 실행하지 못했습니다: QUERY_EXPECTATION_NOT_EXECUTED")
            }
        }
        $signalGroupEvaluationCases=New-Object Collections.Generic.List[object]
        $signalGroupsByCaseId=@{}
        foreach($signalGroupKey in @($script:currentSignalEvaluationGroups.Keys | Sort-Object)){
            $signalGroup=$script:currentSignalEvaluationGroups[$signalGroupKey]
            $script:resultEvaluationSequence++
            $signalGroupCaseId="signal-group-{0:D6}" -f $script:resultEvaluationSequence
            $signalGroupCase=[pscustomobject]@{caseId=$signalGroupCaseId;executed=$true;expectedResult=$signalGroup.expectedResult;observations=@($signalGroup.observations.ToArray())}
            $signalGroupEvaluationCases.Add($signalGroupCase)
            $script:currentResultEvaluationCases.Add($signalGroupCase)
            $signalGroupsByCaseId[$signalGroupCaseId]=$signalGroup
        }
        if($signalGroupEvaluationCases.Count -gt 0){
            $signalGroupEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId="$($case.caseId)-signals";cases=@($signalGroupEvaluationCases.ToArray())}
            $signalGroupEvaluationOutput=Invoke-RuleResultEvaluation -CliProject $cliProject -TestPackPath $resultEvaluationTestPackPath -EvaluationDocument $signalGroupEvaluationDocument -WorkingDirectory $resultEvaluationWorkingDirectory -InvocationId 'signal-groups'
            foreach($signalTestResult in @($signalGroupEvaluationOutput.results)){
                $signalGroup=$signalGroupsByCaseId[[string]$signalTestResult.caseId]
                $sourceObservation=$signalGroup.observation
                $oracleEvents.Add([pscustomobject]@{eventKey="evaluation|$([string]$signalTestResult.caseId)";stage=[string]$signalGroup.stage;controlId=[string]$signalGroup.controlId;optionId=[string]$signalGroup.optionId;eventType='SignalEvaluation';disposition=[string]$signalTestResult.disposition;expectedOutcomeType=[string]$sourceObservation.expectedOutcomeType;expectedOutcomeSource=[string]$sourceObservation.expectedOutcomeSource;expectedOutcomeConfidence=[string]$sourceObservation.expectedOutcomeConfidence;expectedOutcomeEvidence=@($sourceObservation.expectedOutcomeEvidence);expectationId=[string]$sourceObservation.expectationId;source='ResultEvaluator';sourceCode=[string]$signalTestResult.code;evaluationCode=[string]$signalTestResult.code;testStatus=[string]$signalTestResult.status;message=[string]$signalTestResult.reason;productDefect=[bool]$signalTestResult.productDefectDetected;requiresReview=[bool]$signalTestResult.requiresReview;testResult=$signalTestResult;detectedAt=(Get-Date).ToString('o')})
            }
        }
        $requiredEvaluationCases=New-Object Collections.Generic.List[object]
        $requiredRecordsByCaseId=@{}
        foreach($required in $requiredExpectations.ToArray()){
            $script:resultEvaluationSequence++
            $requiredCaseId="required-expectation-{0:D6}" -f $script:resultEvaluationSequence
            $requiredEvaluationCase=[pscustomobject]@{
                caseId=$requiredCaseId;executed=$true
                expectedResult=[pscustomobject]@{
                    expectationId=[string]$required.outcome.expectationId;type=[string]$required.outcome.type
                    description=@($required.outcome.evidence) -join '; ';messagePatterns=@($required.outcome.messagePatterns);errorCodes=@($required.outcome.errorCodes)
                }
                observations=@($required.observations.ToArray())
            }
            $requiredEvaluationCases.Add($requiredEvaluationCase)
            $script:currentResultEvaluationCases.Add($requiredEvaluationCase)
            $requiredRecordsByCaseId[$requiredCaseId]=$required
        }
        if($requiredEvaluationCases.Count -gt 0){
            $requiredEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId="$($case.caseId)-required-expectations";cases=@($requiredEvaluationCases.ToArray())}
            $requiredEvaluationOutput=Invoke-RuleResultEvaluation -CliProject $cliProject -TestPackPath $resultEvaluationTestPackPath -EvaluationDocument $requiredEvaluationDocument -WorkingDirectory $resultEvaluationWorkingDirectory -InvocationId 'required-expectations'
            foreach($requiredTestResult in @($requiredEvaluationOutput.results)){
                $required=$requiredRecordsByCaseId[[string]$requiredTestResult.caseId]
                $requiredMessage="필수 기대 반응 평가: $([string]$required.outcome.type)/$([string]$required.controlId)/$([string]$required.optionId)"
                $oracleEvents.Add([pscustomobject]@{eventKey="required|$([string]$required.controlId)|$([string]$required.optionId)";stage='expectation';controlId=[string]$required.controlId;optionId=[string]$required.optionId;eventType='ExpectedOutcomeEvaluation';disposition=[string]$requiredTestResult.disposition;expectedOutcomeType=[string]$required.outcome.type;expectedOutcomeSource=[string]$required.outcome.source;expectedOutcomeConfidence=[string]$required.outcome.confidence;expectedOutcomeEvidence=@($required.outcome.evidence);expectationId=[string]$required.outcome.expectationId;source='ResultEvaluator';sourceCode=[string]$requiredTestResult.code;evaluationCode=[string]$requiredTestResult.code;testStatus=[string]$requiredTestResult.status;message=$requiredMessage;productDefect=[bool]$requiredTestResult.productDefectDetected;requiresReview=[bool]$requiredTestResult.requiresReview;testResult=$requiredTestResult;detectedAt=(Get-Date).ToString('o')})
            }
        }
        $currentMain = Get-WindowInfo ([IntPtr][Int64]$main.hwnd)
        if ($currentMain.hung) { $errors.Add("HTS 메인 창이 응답하지 않습니다.") }
        $signalEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId="$($case.caseId)-signals";cases=@($script:currentResultEvaluationCases.ToArray())}
        $signalEvaluationOutput=Invoke-RuleResultEvaluation -CliProject $cliProject -TestPackPath $resultEvaluationTestPackPath -EvaluationDocument $signalEvaluationDocument -WorkingDirectory $resultEvaluationWorkingDirectory -InvocationId 'case-signals'
        Add-Action $actions "evaluateExplicitErrors" ([string]$signalEvaluationOutput.overallResult.status) "popup/process/log" ([string]$signalEvaluationOutput.overallResult.reason)
    } catch {
        $executorException = $true
        # 예외 원문만으로는 PowerShell 바인딩 오류 위치를 알 수 없으므로 형식·행·스택을 실행 증거에 남긴다.
        $exceptionType = $_.Exception.GetType().FullName
        $exceptionLine = if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) { [int]$_.InvocationInfo.ScriptLineNumber } else { 0 }
        $exceptionStack = if ($_.ScriptStackTrace) { [string]$_.ScriptStackTrace } else { "" }
        $executorDiagnostic = Protect-Text ("{0} / line {1} / {2}" -f $exceptionType, $exceptionLine, $exceptionStack) $secret
        $safeExceptionMessage = Protect-Text $_.Exception.Message $secret
        if ($safeExceptionMessage -like 'HTS_CONNECTION_LOST:*') {
            $externalInterruption = $true
            $automationContractErrorCode = 'HTS_CONNECTION_LOST'
        } elseif ($safeExceptionMessage -like 'HTS_UI_ACCESS_DENIED:*' -or $safeExceptionMessage -like 'SCREEN_NAVIGATION_INPUT_UNAVAILABLE:*' -or $safeExceptionMessage -like 'SCREEN_NAVIGATION_TEXT_UNVERIFIED:*') {
            $automationContractFailure = $true
            $automationContractErrorCode = if ($safeExceptionMessage -like 'HTS_UI_ACCESS_DENIED:*') { 'HTS_UI_ACCESS_DENIED' } else { 'SCREEN_NAVIGATION_TEXT_UNVERIFIED' }
            $automationIssues.Add('HTS 화면번호 입력 결과를 업무 화면 생성으로 검증하지 못해 실제 화면 전환을 차단했습니다.')
        }
        $errors.Add($safeExceptionMessage)
        $automationIssues.Add("실행기 예외 위치: $executorDiagnostic")
        Add-Action $actions "executor" "ERROR" "runtime" $(if($externalInterruption){'HTS 연결 장애를 감지해 재접속·종료 버튼을 누르지 않고 실행을 중단했습니다.'}elseif($automationContractErrorCode -eq 'HTS_UI_ACCESS_DENIED'){'HTS UI 권한 경계로 화면 전환을 차단했습니다.'}elseif($automationContractErrorCode -eq 'SCREEN_NAVIGATION_TEXT_UNVERIFIED'){'HTS 화면번호 입력의 종단 간 검증을 완료하지 못해 화면 전환을 차단했습니다.'}else{"룰 실행기에서 예외가 발생했습니다: $executorDiagnostic"}) $(if($externalInterruption){'HTS_CONNECTION_LOST'}elseif($automationContractErrorCode -eq 'HTS_UI_ACCESS_DENIED'){'HTS_UI_ACCESS_DENIED'}elseif($automationContractErrorCode -eq 'SCREEN_NAVIGATION_TEXT_UNVERIFIED'){'SCREEN_NAVIGATION_TEXT_UNVERIFIED'}else{'EXECUTOR_EXCEPTION'})
        if (-not $main -or -not [TargetRuleNative]::IsWindow([IntPtr][Int64]$main.hwnd)) { $main = $null }
    }

    $screenshot = ""
    if ($errors.Count -gt 0) {
        $candidateScreenshot = Join-Path $screenshotsDir ("error-{0}-{1}.png" -f $case.screen.screenNumber, $case.caseId)
        if ($main -and [TargetRuleNative]::IsWindow([IntPtr][Int64]$main.hwnd) -and (Capture-HtsScreenshot $main $candidateScreenshot)) {
            $screenshot = $candidateScreenshot
        }
    }
    $dialogsBeforeDismiss = if ($main) { @(Get-HtsDialogs $main $secret) } else { @() }
    if ($dialogsBeforeDismiss.Count -gt 0) {
        $dismissed = Dismiss-HtsDialogs $main $secret
        Add-Action $actions "dismissDialog" $(if ($dismissed -eq $dialogsBeforeDismiss.Count) { "PASS" } else { "PENDING" }) "HTS dialog" "후속 테스트를 위해 HTS 대화상자 $dismissed/$($dialogsBeforeDismiss.Count)개를 닫았습니다." $(if ($dismissed -eq $dialogsBeforeDismiss.Count) { "" } else { "DIALOG_DISMISS_PENDING" })
        if ($dismissed -ne $dialogsBeforeDismiss.Count) { $pendingReasons.Add("HTS 대화상자 닫기") }
    }
    $remainingDialogs = if ($main -and [TargetRuleNative]::IsWindow([IntPtr][Int64]$main.hwnd)) { @(Get-HtsDialogs $main $secret) } else { @() }
    if ($existingScreenRequiredMissing) {
        Add-Action $actions 'closeScreen' 'PENDING' ([string]$case.screen.screenNumber) '연결된 대상 화면이 없어 화면 종료 동작을 수행하지 않았습니다.' 'EXISTING_SCREEN_REQUIRED'
    } elseif ($remainingDialogs.Count -gt 0) {
        Add-Action $actions "closeScreen" "PENDING" ([string]$case.screen.screenNumber) "모달 대화상자가 남아 있어 HTS 종료 위험을 피하도록 화면 닫기를 차단했습니다." "DIALOG_BLOCKS_SCREEN_CLOSE"
        $pendingReasons.Add("모달 대화상자 후 화면 닫기 차단")
    } elseif ($retainScenarioScreen -and (Test-HtsRequestedScreen $screen ([string]$case.screen.screenNumber))) {
        Add-Action $actions 'retainScreenForNextScenario' 'PASS' ([string]$case.screen.screenNumber) '같은 화면의 다음 시나리오 케이스를 위해 현재 화면을 유지했습니다.'
    } elseif ($PreserveTargetScreenAfterRun -and (Test-HtsRequestedScreen $screen ([string]$case.screen.screenNumber))) {
        Add-Action $actions 'preserveTargetScreenAfterRun' 'PASS' ([string]$case.screen.screenNumber) $(if($openedTargetScreenForRun){'자동화가 연 대상 화면을 후속 확인을 위해 닫지 않고 유지했습니다.'}else{'현재 대상 화면을 후속 확인을 위해 닫지 않고 유지했습니다.'})
    } elseif ($usedExistingTargetScreen -and (Test-PreservedTargetScreen (Find-ScreenWindow $main ([string]$case.screen.screenNumber)))) {
        Add-Action $actions 'preserveExistingScreen' 'PASS' ([string]$case.screen.screenNumber) '사용자가 미리 열어둔 화면이므로 테스트 종료 후에도 닫지 않고 유지했습니다.'
    } else {
        $screenToClose=if(Test-HtsRequestedScreen $screen ([string]$case.screen.screenNumber)){$screen}else{Find-ScreenWindow $main ([string]$case.screen.screenNumber)}
        if ($screenToClose) {
            if (Close-HtsScreen $screenToClose) {
                Add-Action $actions "closeScreen" "PASS" ([string]$case.screen.screenNumber) "테스트를 마친 화면을 의도적으로 닫았습니다."
            } else {
                Add-Action $actions "closeScreen" "PENDING" ([string]$case.screen.screenNumber) "테스트를 마친 화면을 닫지 못했습니다." "SCREEN_CLOSE_PENDING"
                $pendingReasons.Add("화면 닫기")
            }
        }
        if($main -and [TargetRuleNative]::IsWindow([IntPtr][Int64]$main.hwnd)){
            $siblingScreensClosed=Close-ExistingTargetScreens $main
            if($siblingScreensClosed -gt 0){Add-Action $actions 'closeSiblingScreens' 'PASS' 'HTS sibling windows' "테스트 중 새로 열린 형제·연계 내부 창 $siblingScreensClosed개를 함께 닫았습니다."}
            $remainingAfterClose=@(Get-HtsScreenWindows $main)
            if($remainingAfterClose.Count -gt 0){
                Add-Action $actions 'verifySequentialClose' 'PENDING' ([string]$case.screen.screenNumber) "번호 창 $($remainingAfterClose.Count)개가 남아 다음 화면 열기를 차단해야 합니다." 'SCREEN_SEQUENCE_CLOSE_PENDING'
                $pendingReasons.Add('순차 화면 닫기 미완료')
            }else{
                Add-Action $actions 'verifySequentialClose' 'PASS' ([string]$case.screen.screenNumber) '현재 화면과 연계 화면이 모두 닫혀 다음 화면을 열 수 있습니다.'
            }
        }
    }
    if ($PlanOnly -and $pendingReasons.Count -eq 0) { $pendingReasons.Add("계획 전용 실행") }
    $ended = Get-Date
    # 실행기는 사실만 Observation으로 기록하고 최종 상태는 Core ResultEvaluator 출력에서 복사한다.
    $actualCaseActionsExecuted = -not $PlanOnly -and (([int]$automationMetrics.FlaUiActionAttempts -gt $flaUiActionAttemptsBeforeCase) -or $script:currentResultEvaluationCases.Count -gt 0)
    $completionObservationKind = if ($externalInterruption -or $executorException -or $automationContractFailure) { 'InfrastructureError' } elseif ($errors.Count -gt 0) { 'ProductFailure' } elseif ($pendingReasons.Count -gt 0) { 'EvidenceMissing' } else { 'Success' }
    $completionObservationCode = if ($externalInterruption) { 'HTS_CONNECTION_LOST' } elseif ($automationContractFailure -and $automationContractErrorCode) { $automationContractErrorCode } elseif ($executorException) { 'EXECUTOR_EXCEPTION' } elseif ($screenOpenFailure) { 'SCREEN_NOT_VISIBLE' } elseif ($errors.Count -gt 0) { 'PRODUCT_DEFECT_DETECTED' } elseif ($existingScreenRequiredMissing) { 'EXISTING_SCREEN_REQUIRED' } elseif ($pendingReasons.Count -gt 0) { 'PRECONDITION_PENDING' } else { '' }
    $completionMessage = if ($errors.Count -gt 0) { @($errors | Select-Object -Unique) -join ' | ' } elseif ($pendingReasons.Count -gt 0) { @($pendingReasons | Select-Object -Unique) -join ' | ' } else { '케이스 실행 및 증거 수집을 완료했습니다.' }
    $completionExpectation = [pscustomobject]@{
        type='Success';expectationId="case-completion:$($case.caseId)";messagePatterns=@();errorCodes=@()
        evidence=@($(if($scenarioMode){[string]$case.scenarioCase.expectedResult}else{'케이스 실행 완료 계약'}))
    }
    $completionEvaluation = Invoke-HtsRawObservationEvaluation `
        $completionObservationKind `
        $completionMessage `
        $completionObservationCode `
        $completionExpectation `
        $actualCaseActionsExecuted `
        ($completionObservationKind -ne 'EvidenceMissing') `
        'case-completion'
    $caseEvaluationDocument = [pscustomobject]@{
        schemaVersion='1.0';testPackId=[string]$testPack.testPackId
        aggregateId=[string]$case.caseId;cases=@($script:currentResultEvaluationCases.ToArray())
    }
    $caseEvaluationOutput = Invoke-RuleResultEvaluation -CliProject $cliProject -TestPackPath $resultEvaluationTestPackPath -EvaluationDocument $caseEvaluationDocument -WorkingDirectory $resultEvaluationWorkingDirectory -InvocationId ("case-{0}" -f $case.caseId)
    $caseTestResult = $caseEvaluationOutput.overallResult
    $status = [string]$caseTestResult.status
    $safeVariables = [ordered]@{}
    foreach ($name in @($case.variables.Keys | Sort-Object)) {
        $dimension = @($dataset.variables | Where-Object { $_.name -eq $name } | Select-Object -First 1)
        $safeVariables[$name] = if ($dimension.Count -gt 0 -and $dimension[0].sensitive) { "******" } else { [string]$case.variables[$name] }
    }
    $resultRow = [pscustomobject]@{
        runId=$runId; caseId=$case.caseId; datasetId=[string]$dataset.datasetId
        automationEngine='FlaUI.UIA3';automationEngineVersion='5.0.0'
        scenarioMode=[bool]$scenarioMode;scenarioId=$(if($scenarioMode){[string]$case.scenarioCase.scenarioId}else{''});scenarioTitle=$(if($scenarioMode){[string]$case.scenarioCase.scenarioTitle}else{''})
        sourceTestCaseId=$(if($scenarioMode){[string]$case.scenarioCase.sourceTestCaseId}else{''});mapScreenCode=$(if($scenarioMode){[string]$case.scenarioCase.mapScreenCode}else{''});transactional=$(if($scenarioMode){[bool]$case.scenarioCase.transactional}else{$false})
        interactionStrategy=[string]$script:ruleCurrentInteractionStrategy
        expectedResult=$(if($scenarioMode){[string]$case.scenarioCase.expectedResult}else{''})
        scenarioPriority=$(if($scenarioMode){[string]$case.scenarioCase.priority}else{''});scenarioCategory=$(if($scenarioMode){[string]$case.scenarioCase.category}else{''})
        logicalPlanId=$(if($scenarioMode){[string]$scenarioPlan.planId}else{''});physicalPlanId=$(if($physicalPlan){[string]$physicalPlan.physicalPlanId}else{''})
        screenNumber=[string]$case.screen.screenNumber; screenName=[string]$case.screen.screenName; inputMode=$(if ($inputMode -eq "Explicit") { "데이터셋 명시 입력" } else { "화면 기본값" })
        accountId=[string]$case.account.id; accountMasked=(Get-MaskedAccount ([string]$case.account.accountNumber)); accountFingerprint=(Get-AccountFingerprint ([string]$case.account.accountNumber)); accountOwner=[string]$case.account.owner
        inputVariables=$safeVariables; status=$status; errorDetected=($errors.Count -gt 0);productDefectDetected=[bool]$caseTestResult.productDefectDetected
        actualScenarioActionsExecuted=[bool]$actualCaseActionsExecuted;testResult=$caseTestResult;testResults=@($caseEvaluationOutput.results)
        automationContractFailure=[bool]$automationContractFailure;externalInterruption=[bool]$externalInterruption
        errorCode=[string]$caseTestResult.code
        errorMessage=Protect-Text (@($errors | Select-Object -Unique) -join " | ") $secret
        executorDiagnostic=$executorDiagnostic
        automationIssues=@($automationIssues | Select-Object -Unique)
        outputSummary=[string]$caseTestResult.reason
        screenshotPath=if ($screenshot) { Get-RelativeFilePath $ReportDir $screenshot } else { "" }
        actions=$actions.ToArray()
        discoveredControls=@($discoveredControls | ForEach-Object {
            [pscustomobject]@{
                controlId=$_.controlId;controlKind=$_.controlKind;name=$_.name;className=$_.className
                automationId=$(if($_.PSObject.Properties.Name -contains 'automationId'){[string]$_.automationId}else{''})
                uiaRuntimeId=$(if($_.PSObject.Properties.Name -contains 'uiaRuntimeId'){[string]$_.uiaRuntimeId}else{''})
                uiaControlType=$(if($_.PSObject.Properties.Name -contains 'uiaControlType'){[string]$_.uiaControlType}else{''})
                automationEngine=$(if($_.PSObject.Properties.Name -contains 'automationEngine'){[string]$_.automationEngine}else{'Win32/MAP'})
                supportedActions=$(if($_.PSObject.Properties.Name -contains 'supportedActions'){@($_.supportedActions)}else{@()})
                locatorSignature=$_.locatorSignature
                initialValue=$_.initialValue;tabOrder=$_.tabOrder;tabStop=$_.tabStop;stateContext=$_.stateContext;mapScreenCode=$_.mapScreenCode;regionRole=$_.regionRole
                # 선택지가 하나여도 JSON 객체로 붕괴되지 않도록 명시적인 배열 계약을 유지한다.
                claimedByDataset=$_.claimedByDataset;dataRequired=$_.dataRequired;pendingReason=$_.pendingReason;options=@($_.options);relativeRect=$_.relativeRect
                definitionSource=$_.definitionSource;runtimeName=$_.runtimeName;runtimeControlKind=$_.runtimeControlKind;mapModelId=$_.mapModelId
                mapTypeCode=$_.mapTypeCode;mapKind=$_.mapKind;mapDefinitionOrder=$_.mapDefinitionOrder;mapMatched=$_.mapMatched;mapMatchDistance=$_.mapMatchDistance
                mapGeometryDelta=$(if($_.PSObject.Properties.Name -contains 'mapGeometryDelta'){$_.mapGeometryDelta}else{$null})
                mapGeometryExact=$(if($_.PSObject.Properties.Name -contains 'mapGeometryExact'){[bool]$_.mapGeometryExact}else{$false})
                mapHostRequired=$(if($_.PSObject.Properties.Name -contains 'mapHostRequired'){[bool]$_.mapHostRequired}else{$false})
                mapHostMatched=$(if($_.PSObject.Properties.Name -contains 'mapHostMatched'){[bool]$_.mapHostMatched}else{$false})
                mapHostId=$(if($_.PSObject.Properties.Name -contains 'mapHostId'){[string]$_.mapHostId}else{''})
                runtimeIdentityUnique=$(if($_.PSObject.Properties.Name -contains 'runtimeIdentityUnique'){[bool]$_.runtimeIdentityUnique}else{$true})
                allowOwnerDrawnKindOverride=$(if($_.PSObject.Properties.Name -contains 'allowOwnerDrawnKindOverride'){[bool]$_.allowOwnerDrawnKindOverride}else{$false})
                mapEvents=$_.mapEvents;mapSemanticRole=$_.mapSemanticRole;mapTriggeredRequests=$_.mapTriggeredRequests;mapReadControls=$_.mapReadControls
                mapAffectedControls=$_.mapAffectedControls;mapResultControls=$_.mapResultControls;mapInvokedHandlers=$_.mapInvokedHandlers
                mapNavigationTargets=$_.mapNavigationTargets;mapOptionSource=$_.mapOptionSource;mapRect=$_.mapRect
            }
        })
        controlTests=$controlTests.ToArray(); popupObservations=$popupObservations.ToArray();oracleEvents=$oracleEvents.ToArray()
        mapErrorOracle=$(if($mapOracle){[pscustomobject]@{
            sourceFile=[string]$mapModel.sourceFile;sourceSha256=[string]$mapModel.sourceSha256
            hasReceiveErrorParameters=[bool]$mapOracle.hasReceiveErrorParameters;hasOnErrorHandler=[bool]$mapOracle.hasOnErrorHandler
            errorHandlers=@($mapOracle.errorHandlers);messageBoxes=@($mapOracle.messageBoxes)
            requestNames=@($mapOracle.requestNames);transactionCodes=@($mapOracle.transactionCodes)
        }}else{$null})
        mapBehavior=$(if($mapBehavior){[pscustomobject]@{
            eventHandlerCount=@($mapBehavior.eventHandlers).Count;queryControls=@($mapBehavior.queryControls);autoQueryControls=@($mapBehavior.autoQueryControls)
            paginationControls=@($mapBehavior.paginationControls);exportControls=@($mapBehavior.exportControls);navigationControls=@($mapBehavior.navigationControls)
            stateControllerControls=@($mapBehavior.stateControllerControls);inputControls=@($mapBehavior.inputControls);resultControls=@($mapBehavior.resultControls)
            queryExecuted=[bool]$mapQueryExecuted;reboundControls=[int]$mapReboundControls
        }}else{$null})
        installationModel=$(if($mapModel -and $mapCatalog.installationFingerprint){[pscustomobject]@{
            fingerprint=[string]$mapCatalog.installationFingerprint;canonicalTitle=$(if($mapModel.registry){[string]$mapModel.registry.title}else{[string]$mapModel.screenName})
            tabGroups=@($mapModel.tabGroups);tabSiblings=@($mapModel.tabSiblings);dependencies=@($mapModel.dependencies)
            dataReferences=@($mapModel.dataReferences);integrity=$mapModel.integrity
        }}else{$null})
        startedAt=$started.ToString("o"); endedAt=$ended.ToString("o"); elapsedMs=[int64]($ended-$started).TotalMilliseconds
    }
    Protect-RuleReportedSensitiveValues $resultRow
    $results.Add($resultRow)
    $checkpointResults=@($results.ToArray())
    ConvertTo-Json -InputObject $checkpointResults -Depth 12 | Set-Content -LiteralPath (Join-Path $ReportDir "case-results.json") -Encoding UTF8
    $checkpointEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId="$runId-checkpoint";cases=@();completedResults=@($checkpointResults | ForEach-Object {$_.testResult})}
    $checkpointEvaluationOutput=Invoke-RuleResultEvaluation -CliProject $cliProject -TestPackPath $resultEvaluationTestPackPath -EvaluationDocument $checkpointEvaluationDocument -WorkingDirectory $resultEvaluationWorkingDirectory -InvocationId 'checkpoint'
    $checkpointResultSummary=$checkpointEvaluationOutput.summary
    [pscustomobject]@{
        runId=$runId;completed=$checkpointResults.Count;total=$cases.Count;lastCaseId=$case.caseId;lastScreenNumber=[string]$case.screen.screenNumber
        pass=[int]$checkpointResultSummary.pass;fail=[int]$checkpointResultSummary.fail
        error=[int]$checkpointResultSummary.error;pending=[int]$checkpointResultSummary.pending;updatedAt=(Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReportDir "checkpoint-summary.json") -Encoding UTF8
    if ($dataset.executionPolicy.stopOnFirstError -and [string]$caseTestResult.status -in @('FAIL','ERROR')) { break }
}

$resultArray = $results.ToArray()
$resultArray | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ReportDir "case-results.json") -Encoding UTF8
$controlPlanRows = @($resultArray | ForEach-Object {
    [pscustomobject]@{caseId=$_.caseId;scenarioId=$_.scenarioId;scenarioTitle=$_.scenarioTitle;screenNumber=$_.screenNumber;screenName=$_.screenName;discoveredControls=$_.discoveredControls;controlTests=$_.controlTests}
})
# 화면이 한 개여도 소비자 스키마의 RuntimeControlPlanRow[] 계약이 유지되도록 파이프라인 직렬화를 피한다.
ConvertTo-Json -InputObject $controlPlanRows -Depth 12 | Set-Content -LiteralPath (Join-Path $ReportDir "control-plan.json") -Encoding UTF8
$inputAuditRows=if(Test-Path -LiteralPath $script:inputBoundaryAuditPath){@([IO.File]::ReadAllLines($script:inputBoundaryAuditPath,[Text.Encoding]::UTF8) | Where-Object {$_} | ForEach-Object {$_ | ConvertFrom-Json})}else{@()}
$runEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId=$runId;cases=@();completedResults=@($resultArray | ForEach-Object {$_.testResult})}
$runEvaluationOutput=Invoke-RuleResultEvaluation -CliProject $cliProject -TestPackPath $resultEvaluationTestPackPath -EvaluationDocument $runEvaluationDocument -WorkingDirectory $resultEvaluationWorkingDirectory -InvocationId 'run-summary'
$runEvaluationOutput | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ReportDir 'test-results.json') -Encoding UTF8
$runResultSummary=$runEvaluationOutput.summary
$summaryStatus=[string]$runEvaluationOutput.overallResult.status
[pscustomobject]@{
    runId=$runId; testPackId=[string]$testPack.testPackId;testPackPath=$resolvedTestPackPath;datasetId=[string]$dataset.datasetId; datasetPath=[string]$testPack.datasetSource; targetProfileId=$targetContext.ProfileId; targetDisplayName=$targetContext.DisplayName; status=$summaryStatus; total=$resultArray.Count
    pass=[int]$runResultSummary.pass; fail=[int]$runResultSummary.fail
    error=[int]$runResultSummary.error; pending=[int]$runResultSummary.pending
    dryRun=$false; explicitErrorsDetected=@($resultArray | Where-Object productDefectDetected).Count
    automationEngine='FlaUI.UIA3';automationEngineVersion='5.0.0'
    flaUiDiscoveryCalls=$automationMetrics.FlaUiDiscoveryCalls;flaUiElementsDiscovered=$automationMetrics.FlaUiElementsDiscovered
    flaUiActionAttempts=$automationMetrics.FlaUiActionAttempts;flaUiActionSuccesses=$automationMetrics.FlaUiActionSuccesses
    flaUiFallbackRequests=$automationMetrics.FlaUiFallbackRequests;flaUiFallbackReasons=@($automationMetrics.FlaUiFallbackReasons)
    finishedAt=(Get-Date).ToString("o"); executionMode=$(if ($PlanOnly) {"계획 전용"} elseif($SubmitTransactionalDialogs){"승인된 테스트계좌 거래 제출"} elseif($scenarioMode){"승인된 시나리오 기반 조작"} else {"대상 화면 규칙 기반 전체 조작"}); inputMode="화면 기본값 또는 데이터셋 명시 입력"; planner=[string]$testPack.generatorVersion
    scenarioMode=[bool]$scenarioMode;logicalPlanId=$(if($scenarioMode){[string]$scenarioPlan.planId}else{''});physicalPlanId=$(if($physicalPlan){[string]$physicalPlan.physicalPlanId}else{''})
    scenarioGenerationMode=$(if($scenarioMode){[string]$scenarioPlan.scenarioGenerationMode}else{''});scenarioGenerator=$(if($scenarioMode){[string]$scenarioPlan.scenarioGenerator}else{''});scenarioGeneratorVersion=$(if($scenarioMode){[string]$scenarioPlan.scenarioGeneratorVersion}else{''});runtimeDiscoveryUsed=$(if($scenarioMode){[bool]$scenarioPlan.runtimeDiscoveryUsed}else{$false})
    scenarioCount=$(if($scenarioMode){@($resultArray.scenarioId | Sort-Object -Unique).Count}else{0});scenarioStepTests=$(if($scenarioMode){@($resultArray | ForEach-Object {@($_.controlTests | Where-Object scenarioStepId).Count} | Measure-Object -Sum).Sum}else{0})
    coordinateFocusSteps=@($resultArray | ForEach-Object { @($_.controlTests | Where-Object coordinateFocusUsed).Count } | Measure-Object -Sum).Sum
    coordinateFocusVerified=@($resultArray | ForEach-Object { @($_.controlTests | Where-Object coordinateFocusVerified).Count } | Measure-Object -Sum).Sum
    discoveredControls=@($resultArray | ForEach-Object { @($_.discoveredControls).Count } | Measure-Object -Sum).Sum
    controlTests=@($resultArray | ForEach-Object { @($_.controlTests).Count } | Measure-Object -Sum).Sum
    popupObservations=@($resultArray | ForEach-Object { @($_.popupObservations).Count } | Measure-Object -Sum).Sum
    expectedEvents=@($resultArray | ForEach-Object { @($_.oracleEvents | Where-Object disposition -eq 'Expected').Count } | Measure-Object -Sum).Sum
    reviewEvents=@($resultArray | ForEach-Object { @($_.oracleEvents | Where-Object requiresReview).Count } | Measure-Object -Sum).Sum
    productDefects=@($resultArray | Where-Object productDefectDetected).Count
    automationContractFailures=@($resultArray | Where-Object automationContractFailure).Count
    externalInterruptions=@($resultArray | Where-Object externalInterruption).Count
    inputBoundaryAllowed=@($inputAuditRows | Where-Object status -eq 'ALLOWED').Count
    inputBoundaryBlocked=@($inputAuditRows | Where-Object status -eq 'BLOCKED').Count
    mouseClicksAllowed=@($inputAuditRows | Where-Object { $_.inputType -eq 'MouseClick' -and $_.status -eq 'ALLOWED' }).Count
    mouseClicksBlocked=@($inputAuditRows | Where-Object { $_.inputType -eq 'MouseClick' -and $_.status -eq 'BLOCKED' }).Count
    mapModels=@($mapCatalog.screens).Count
    mapDefinedControls=@($resultArray | ForEach-Object { @($_.discoveredControls | Where-Object { $_.definitionSource -in @('MAP','MAP+Runtime') }).Count } | Measure-Object -Sum).Sum
    mapBoundControls=@($resultArray | ForEach-Object { @($_.discoveredControls | Where-Object definitionSource -eq 'MAP+Runtime').Count } | Measure-Object -Sum).Sum
    mapUnboundControls=@($resultArray | ForEach-Object { @($_.discoveredControls | Where-Object definitionSource -eq 'MAP').Count } | Measure-Object -Sum).Sum
    runtimeOnlyControls=@($resultArray | ForEach-Object { @($_.discoveredControls | Where-Object definitionSource -eq 'RuntimeOnly').Count } | Measure-Object -Sum).Sum
    mapOracleScreens=$(if($mapCatalog){@($mapCatalog.screens | Where-Object errorOracle).Count}else{0})
    mapOracleMessages=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.errorOracle.messageBoxes).Count } | Measure-Object -Sum).Sum}else{0})
    mapOracleExplicitErrors=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.errorOracle.messageBoxes | Where-Object isExplicitError).Count } | Measure-Object -Sum).Sum}else{0})
    mapOracleValidationMessages=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.errorOracle.messageBoxes | Where-Object classification -eq 'InputValidation').Count } | Measure-Object -Sum).Sum}else{0})
    mapOracleMatchedPopups=@($resultArray | ForEach-Object { @($_.popupObservations | Where-Object oracleSource -eq 'MAP').Count } | Measure-Object -Sum).Sum
    mapBehaviorHandlers=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.behavior.eventHandlers).Count } | Measure-Object -Sum).Sum}else{0})
    mapQueryControls=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.behavior.queryControls).Count } | Measure-Object -Sum).Sum}else{0})
    mapStateControllers=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.behavior.stateControllerControls).Count } | Measure-Object -Sum).Sum}else{0})
    mapResultControls=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object { @($_.behavior.resultControls).Count } | Measure-Object -Sum).Sum}else{0})
    mapReboundControls=@($resultArray | ForEach-Object { if($_.mapBehavior){[int]$_.mapBehavior.reboundControls}else{0} } | Measure-Object -Sum).Sum
    installationFingerprint=$(if($mapCatalog){[string]$mapCatalog.installationFingerprint}else{''})
    dependencyModels=$(if($mapCatalog){@($mapCatalog.dependencyScreens).Count}else{0})
    mapDependencies=$(if($mapCatalog){@($mapCatalog.dependencies).Count}else{0})
    unresolvedDependencies=$(if($mapCatalog){@($mapCatalog.dependencies | Where-Object { -not $_.isDynamic -and -not $_.targetExists }).Count}else{0})
    staticDataReferences=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object {@($_.dataReferences).Count} | Measure-Object -Sum).Sum}else{0})
    officialOptionControls=$(if($mapCatalog){@($mapCatalog.screens | ForEach-Object {@($_.controls | Where-Object {@($_.staticOptions).Count -gt 0}).Count} | Measure-Object -Sum).Sum}else{0})
    installedErrorCodes=$(if($mapCatalog){@($mapCatalog.errorCodes).Count}else{0})
    integrityMatched=$(if($mapCatalog){@($mapCatalog.integrityEntries | Where-Object status -eq 'MATCH').Count}else{0})
    integrityFailed=$(if($mapCatalog){@($mapCatalog.integrityEntries | Where-Object status -ne 'MATCH').Count}else{0})
    mapInitializationIssue=$mapInitializationIssue
    planOnly=[bool]$PlanOnly; reuseExistingTargetScreen=[bool]$reuseExistingTargetScreenRequested; requireExistingTargetScreen=[bool]$RequireExistingTargetScreen
    preserveTargetScreenAfterRun=[bool]$PreserveTargetScreenAfterRun;visiblePointerMotion=[bool]$script:visiblePointerMotion;pointerDwellMilliseconds=[int]$script:pointerDwellMilliseconds
    initialScreensClosed=$initialScreensClosed; initialScreensPreserved=$initialScreensPreserved; initialSearchOverlaysClosed=$initialSearchOverlaysClosed
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReportDir "summary.json") -Encoding UTF8

Stop-FlaUiBridge -Context $sessionContext
if (-not $SkipExcel) {
    Export-RuleResultWorkbooks $ReportDir
}
Write-Output $ReportDir
