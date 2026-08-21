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
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $scriptsRoot
. (Join-Path $PSScriptRoot "pipeline-common.ps1")
. (Join-Path $PSScriptRoot "report-sanitization.ps1")
. (Join-Path $PSScriptRoot "result-evaluator.ps1")
. (Join-Path $PSScriptRoot "hts-session.ps1")
. (Join-Path $PSScriptRoot "hts-navigation.ps1")
. (Join-Path $PSScriptRoot "hts-discovery.ps1")
. (Join-Path $PSScriptRoot "hts-binding.ps1")
. (Join-Path $PSScriptRoot "hts-action.ps1")
. (Join-Path $PSScriptRoot "hts-observation.ps1")
. (Join-Path $PSScriptRoot "hts-safety.ps1")
. (Join-Path $PSScriptRoot "hts-reporting.ps1")
. (Join-Path $PSScriptRoot "hts-runtime-context.ps1")

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
$initiallyActiveMapScreenCodes = @($dataset.targetProfile.map.initiallyActiveMapScreenCodes | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } | Where-Object { $_ } | Select-Object -Unique)
$targetScreenIdRegex = [regex]::new($targetContext.ScreenIdPattern)
$screenPatternBody = $targetContext.ScreenIdPattern.Trim()
if ($screenPatternBody.StartsWith('^')) { $screenPatternBody = $screenPatternBody.Substring(1) }
if ($screenPatternBody.EndsWith('$')) { $screenPatternBody = $screenPatternBody.Substring(0, $screenPatternBody.Length - 1) }
$targetScreenTitleRegex = [regex]::new('^\[(?<screen>' + $screenPatternBody + ')\]')
$targetMapScreenCodeRegex = [regex]::new('^HT(?<screen>' + $screenPatternBody + ')')
$scenarioPlan = $null
$physicalPlan = $null
$bindingCatalog = $null
$bindingCatalogSource = ''
$scenarioMode = [bool]$ScenarioPlanPath
$reuseExistingTargetScreenRequested = [bool]($ReuseExistingTargetScreen -or $RequireExistingTargetScreen)
$runtimeContext = New-HtsRunContext `
    -TargetWindowClassName ([string]$targetContext.WindowClassName) `
    -TargetWindowTitlePrefix ([string]$targetContext.WindowTitlePrefix) `
    -TargetScreenIdRegex $targetScreenIdRegex `
    -TargetScreenTitleRegex $targetScreenTitleRegex `
    -TargetMapScreenCodeRegex $targetMapScreenCodeRegex `
    -InitiallyActiveMapScreenCodes $initiallyActiveMapScreenCodes `
    -VisiblePointerMotion ([bool]$VisiblePointerMotion) `
    -PointerDwellMilliseconds ([int]$PointerDwellMilliseconds)
$executableScenarioCaseIds = @()
$requestedScenarioCaseIds = @($CaseIdsCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($SubmitTransactionalDialogs -and -not $scenarioMode) { throw '-SubmitTransactionalDialogs에는 승인된 -ScenarioPlanPath가 필요합니다.' }
if ($SubmitTransactionalDialogs -and ($PlanOnly -or $DryRun)) { throw '-SubmitTransactionalDialogs는 PlanOnly/DryRun과 함께 사용할 수 없습니다.' }

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
$executionTracePath = Join-Path $ReportDir "execution-trace.ndjson"
if (Test-Path -LiteralPath $executionTracePath) { Remove-Item -LiteralPath $executionTracePath -Force }
$reportingContext = New-HtsReportingContext -ReportExporter $reportExporter -TcReportExporter $tcReportExporter -ExecutionTracePath $executionTracePath
$inputBoundaryAuditPath = Join-Path $ReportDir "input-boundary-audit.ndjson"
if (Test-Path -LiteralPath $inputBoundaryAuditPath) { Remove-Item -LiteralPath $inputBoundaryAuditPath -Force }

$resultEvaluationTestPackPath = $resolvedTestPackPath
$resultEvaluationWorkingDirectory = Join-Path $ReportDir 'result-evaluation'

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
        Export-HtsRuleResultWorkbooks $reportingContext $ReportDir
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
$automationMetrics = New-HtsDiscoveryMetrics
$RuntimeContext.LastTextAutomationEngine = '미실행'

# manifest에 등록된 FlaUI 프로젝트의 Release UIA3 브리지 DLL 경로를 계산한다.
$flaUiProject = Resolve-RulePath $root ([string]$pipelineManifest.flaUiProject)
$flaUiAssembly = Join-Path (Split-Path -Parent $flaUiProject) 'bin\Release\net8.0-windows7.0\HtsQa.FlaUi.dll'
$sessionContext = New-HtsSessionContext `
    -FlaUiAssembly $flaUiAssembly `
    -TargetWindowClassName $RuntimeContext.TargetWindowClassName `
    -TargetWindowTitlePrefix $RuntimeContext.TargetWindowTitlePrefix `
    -DisplayName ([string]$targetContext.DisplayName) `
    -GetTopWindows { Get-TopWindows }

. (Join-Path $PSScriptRoot "rule-control-exploration.ps1")
$targetRuleDependencies = [pscustomobject]@{
    GetChildWindows = { param([Int64]$Hwnd) @(Get-ChildWindows $Hwnd) }
    GetFlaUiActionableControls = { param($Screen) @(Get-FlaUiActionableControls $discoveryContext $Screen) }
    GetWindowInfo = { param([Int64]$Hwnd) Get-WindowInfo ([IntPtr]$Hwnd) }
    ClickCenter = { param($Window, [bool]$DoubleClick) Click-Center $actionContext $Window -DoubleClick:$DoubleClick }
    SendKey = { param([byte]$Key) Send-Key $actionContext $Key }
    Sleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    InvokeFlaUiControlAction = {
        param($Window, [string]$Action, [string]$Value, $Index, $Checked, [string]$Key)
        Invoke-FlaUiControlAction $actionContext $Window $Action -Value $Value -Index $Index -Checked $Checked -Key $Key
    }
    SetAutomationText = {
        param($Window, [string]$Value, [bool]$AlreadyFocused)
        $success = Set-AutomationText $actionContext $Window $Value -AlreadyFocused:$AlreadyFocused
        [pscustomobject]@{ success=[bool]$success; engine=[string]$RuntimeContext.LastTextAutomationEngine }
    }
}
$targetRuleContext = New-HtsTargetRuleContext -RootPath $root -Dataset $dataset -MapCatalog $mapCatalog -Dependencies $targetRuleDependencies
$targetRuleContext.FastScenarioDiscovery = [bool]($scenarioMode -or $PlanOnly)
if ($OrderTabStateOverride) { Set-RuleOrderTabState $targetRuleContext '0101' 'HT010115' $OrderTabStateOverride }
$discoveryDependencies = [pscustomobject]@{
    InvokeBridgeRequest = { param($Context, $Request) Invoke-FlaUiBridgeRequest -Context $Context -Request $Request }
    GetMapScreenModel = { param([string]$ScreenNumber, [string]$MapScreenCode) Get-RuleMapScreenModel $targetRuleContext $ScreenNumber $MapScreenCode }
    GetRuleDiscoveredControls = { param($Screen, [string]$ScreenNumber, [hashtable]$ClaimedHwnds) @(Get-RuleDiscoveredControls $targetRuleContext $Screen $ScreenNumber $ClaimedHwnds) }
}
$discoveryContext = New-HtsDiscoveryContext -SessionContext $sessionContext -Dependencies $discoveryDependencies -Metrics $automationMetrics
$bindingDependencies = [pscustomobject]@{
    GetChildWindows = { param([Int64]$Hwnd) @(Get-ChildWindows $Hwnd) }
    TestControlExecutionEligible = { param($Control) Test-RuleControlExecutionEligible $Control }
}
$bindingContext = New-HtsBindingContext -DiscoveryContext $discoveryContext -Dependencies $bindingDependencies
$actionDependencies = [pscustomobject]@{
    AssertClickScope = { param($Window,[int]$X,[int]$Y) Assert-HtsSafetyClickScope -Context $safetyContext -Window $Window -X $X -Y $Y }
    GetActiveInputSurface = { Get-HtsSafetyActiveInputSurface -Context $safetyContext }
    InvokeBridgeRequest = { param($Context,$Request) Invoke-FlaUiBridgeRequest -Context $Context -Request $Request }
    WriteInputAudit = { param([string]$InputType,[string]$Status,[int]$X,[int]$Y,[string]$Detail) Write-HtsSafetyInputBoundaryAudit -Context $safetyContext -InputType $InputType -Status $Status -X $X -Y $Y -Detail $Detail }
    InvokeRuleControlPlanItem = { param($Navigation,$Screen,$PlanItem) Invoke-RuleControlPlanItem $targetRuleContext $Navigation $Screen $PlanItem }
    InvokeRuleDatasetVariable = { param($Window,[string]$Kind,[string]$Value,[string]$ValueMatch,[int]$MaxOptions) Invoke-RuleDatasetVariable $targetRuleContext $Window $Kind $Value $ValueMatch $MaxOptions }
}
$actionContext = New-HtsActionContext -SessionContext $sessionContext -Metrics $automationMetrics -Dependencies $actionDependencies -RuntimeContext $runtimeContext
$observationDependencies = [pscustomobject]@{
    CreateSignalEvaluationCase = {
        param([string]$CaseId,[string]$EventType,[string]$Text,[string]$SourceCode,[string]$Source,$ExpectedOutcome)
        New-RuleSignalEvaluationCase -CaseId $CaseId -EventType $EventType -Text $Text -SourceCode $SourceCode -Source $Source -ExpectedOutcome $ExpectedOutcome
    }
    GetNow = { Get-Date }
    GetTopWindows = { @(Get-TopWindows) }
    GetChildWindows = { param([Int64]$Hwnd) @(Get-ChildWindows $Hwnd) }
    GetWindowInfo = { param([Int64]$Hwnd) Get-WindowInfo ([IntPtr]$Hwnd) }
    GetScreenNumber = { param($Window) Get-HtsScreenNumber $navigationContext $Window }
    ProtectText = { param($Text,[string]$Secret) Protect-Text $Text $Secret }
    GetRelativeFilePath = { param([string]$BasePath,[string]$Path) Get-RelativeFilePath $BasePath $Path }
}
$observationContext = New-HtsObservationContext -MapCatalog $mapCatalog -InstallationRoot ([string]$targetContext.InstallationRoot) -Dependencies $observationDependencies

$safetyDependencies = [pscustomobject]@{
    IsWindow = { param([Int64]$Hwnd) [TargetRuleNative]::IsWindow([IntPtr]$Hwnd) }
    GetWindowInfo = { param([Int64]$Hwnd) Get-WindowInfo ([IntPtr]$Hwnd) }
    IsChild = { param([Int64]$Parent,[Int64]$Child) [TargetRuleNative]::IsChild([IntPtr]$Parent,[IntPtr]$Child) }
    GetWindowProcessId = { param([Int64]$Hwnd) [uint32]$windowProcessId=0;[void][TargetRuleNative]::GetWindowThreadProcessId([IntPtr]$Hwnd,[ref]$windowProcessId);[int]$windowProcessId }
    GetScreenNumber = { param($Window) Get-HtsScreenNumber $navigationContext $Window }
    GetContentPolicy = { param([string]$ScreenNumber) Get-RuleContentPolicy $targetRuleContext $ScreenNumber }
    TestContentControl = { param($Window,$Screen,$Policy) Test-RuleContentControl $Window $Screen $Policy }
    GetKeyboardFocusHwnd = { $info=New-Object TargetRuleNative+GUITHREADINFO;$info.cbSize=[Runtime.InteropServices.Marshal]::SizeOf([type][TargetRuleNative+GUITHREADINFO]);[void][TargetRuleNative]::GetGUIThreadInfo(0,[ref]$info);[Int64]$info.hwndFocus.ToInt64() }
    WindowFromPoint = { param([int]$X,[int]$Y) $point=New-Object TargetRuleNative+POINT;$point.X=$X;$point.Y=$Y;[Int64]([TargetRuleNative]::WindowFromPoint($point)).ToInt64() }
    GetNow = { Get-Date }
    AppendAuditRecord = {
        param([string]$Path,$Record)
        $line=($Record|ConvertTo-Json -Compress -Depth 5)+[Environment]::NewLine
        for($attempt=1;$attempt-le5;$attempt++){$stream=$null;try{$stream=[IO.FileStream]::new($Path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);[void]$stream.Seek(0,[IO.SeekOrigin]::End);$bytes=[Text.UTF8Encoding]::new($false).GetBytes($line);$stream.Write($bytes,0,$bytes.Length);$stream.Flush();return}catch [IO.IOException]{if($attempt-eq5){throw};Start-Sleep -Milliseconds (20*$attempt)}finally{if($stream){$stream.Dispose()}}}
    }
}
$safetyContext = New-HtsSafetyContext -AuditPath $inputBoundaryAuditPath -Dependencies $safetyDependencies
$actionContext.SafetyContext = $safetyContext

# 기존 rule-control과 navigation 호출 계약을 보존하는 얇은 Action 어댑터다.

# 기존 탐색 구현의 호출 계약을 유지하되 실제 UIA3 탐색과 계측은 Discovery 모듈에 위임한다.

# 공통 창·입력 유틸리티: 민감정보 보호와 모든 물리 입력의 HTS 경계 검사를 담당한다.

# 단일 HWND의 소유 관계, 상태, 제목, 클래스와 화면 좌표를 같은 형태의 객체로 읽는다.

# 현재 데스크톱의 최상위 창을 동일한 WindowInfo 객체 배열로 수집한다.

# 지정 부모 아래의 네이티브 자식 HWND를 재귀 열거한다.

# 메인 상단의 화면 ID 입력칸 후보를 위치와 현재 값 형식으로 정렬한다.

# 화면번호 입력부는 일부 HTS 버전에서 owner-drawn 래퍼에 포함된다. UIA 성공만으로
# 입력 완료를 인정하지 않고, 창 메시지 접근성과 업무 화면 생성 결과를 함께 확인한다.


# 입력 직전 대상 프로세스를 전경으로 복구하고 다른 프로세스가 활성 상태면 입력을 차단한다.

# WindowFromPoint는 호출 프로세스의 DPI 좌표계를 사용하므로 논리 좌표로 최상단 HTS 창을 확인한다.
# Per-Monitor DPI 문맥에서 실제 커서 위치가 고정된 대상 HWND 위인지 마지막으로 확인한다.
# 전경·포커스 경계를 검증한 뒤 단일 가상 키의 누름과 해제를 전송한다.

# 물리 커서 이동이 제한된 세션에서도 화면번호 Edit HWND에 직접 포커스를 주고
# 키 입력 범위를 검증한다. 화면 열기는 버튼 조작이 아닌 이 경로를 우선 사용한다.

# 최신 창 좌표의 중심점을 계산하고 클릭 경계 감사 후 왼쪽 클릭을 전송한다.

# FlaUI UIA3 ValuePattern을 우선 사용하고 비지원 사용자 정의 입력만 Win32/키보드로 보완한다.

# 화면 수명주기: 번호 입력, 대상 창 식별, 연계 창 정리와 순차 종료를 한 화면 단위로 관리한다.

# 요청 화면 ID가 제목에 표시된 가장 큰 자식 창을 대상 화면으로 선택한다.

# targetProfile 화면 정규식으로 자식 창 제목에서 화면 ID를 추출한다.

# 대상 화면 형식과 최소 콘텐츠 크기를 만족하는 열린 업무 화면을 나열한다.

# HWND가 살아 있고 현재 제목의 화면 ID가 요청값과 같은지 확인한다.

# MDI 활성화와 전경 복구 후 요청 화면을 현재 입력 콘텐츠로 등록한다.

# 조작 중 추가로 열린 화면을 요청 화면과 분리해 연계 화면으로 반환한다.

# 요청 화면을 제외한 연계 화면을 닫고 실제 종료된 수를 반환한다.

# 후보 화면 안의 입력 가능 자식 수를 계산해 실제 콘텐츠가 있는 창을 우선한다.

# 정확한 화면 ID, 새 HWND와 입력 가능 컨트롤 수를 조합해 콘텐츠 표면을 결정한다.

# 대상 프로세스의 자식 화면에만 WM_CLOSE를 보내고 HWND 소멸까지 확인한다.

# 새 케이스 시작 전에 targetProfile 형식의 기존 업무 화면을 모두 정리한다.


# 화면번호 입력을 가릴 수 있는 화면검색 오버레이만 선택적으로 닫는다.

# 팝업 관찰: 현재 HTS 프로세스의 새 대화상자를 읽고 민감 문구를 제거한 관찰 객체를 만든다.

# 컨트롤 실행 사실을 원시 Observation으로 넘기고 현재 케이스의 Core 평가 입력에 함께 보존한다.
function Invoke-HtsRawObservationEvaluation(
    [string]$ObservationKind,
    [string]$Text,
    [string]$SourceCode,
    $ExpectedOutcome,
    [bool]$Executed = $true,
    [bool]$EvidencePresent = $true,
    [string]$Prefix = 'control') {
    $evaluationSequence = Get-HtsNextObservationSequence -Context $observationContext
    $evaluation = Invoke-RuleSignalEvaluation `
        -CliProject $cliProject `
        -TestPackPath $resultEvaluationTestPackPath `
        -WorkingDirectory $resultEvaluationWorkingDirectory `
        -CaseId ("{0}-{1:D6}" -f $Prefix, $evaluationSequence) `
        -EventType $ObservationKind `
        -Text $Text `
        -SourceCode $SourceCode `
        -Source 'PowerShell raw observation' `
        -Executed $Executed `
        -EvidencePresent $EvidencePresent `
        -ExpectedOutcome $ExpectedOutcome
    if ($observationContext.CurrentResultEvaluationCases) { $observationContext.CurrentResultEvaluationCases.Add($evaluation.evaluationCase) }
    $evaluation
}

# 승인된 거래 실행에서만 주문 확인창을 식별한다. 입력 검증·시스템 오류와
# 의미가 모호한 '취소' 단독 버튼은 제출 대상으로 인정하지 않는다.

# 거래 확인창의 명시적 승인 버튼을 실제 마우스 경로로 누르고 창이 닫혔는지 검증한다.

# 하나의 팝업·로그 신호를 판정하지 않고 원시 Observation 계약으로 분류한다.
# 대화상자의 제목·본문·버튼을 합쳐 공통 Observation 분류기로 전달한다.
# 원시 Observation을 감사 이벤트와 기대 계약별 평가 그룹에 함께 누적한다.
# 공통 오류 패턴과 현재 화면 MAP 메시지를 결합한 관찰용 정규식을 만든다.
# 연계 화면의 제목·본문·버튼·스크린샷과 MAP 예상 여부를 결과에 기록한다.

# 화면 ID가 없는 전환 창도 새 최상위 창으로 감지해 누락되지 않게 기록한다.

# 계좌·비밀번호처럼 명시 로케이터가 점유한 HWND를 자동 탐색 대상에서 제외한다.
# 재접속·프로그램 종료 선택을 포함한 연결 장애 팝업은 자동 닫기 대상에서 제외한다.


# 현재 대상 프로세스 팝업의 취소 계열 버튼 또는 WM_CLOSE를 사용해 다음 동작을 복구한다.
function Dismiss-HtsDialogs($RuntimeContext, $Main, [string]$Secret = "") {
    $dismissed = 0
    foreach ($dialog in @(Get-HtsDialogs $observationContext $RuntimeContext $Main $Secret)) {
        if (Test-HtsConnectionDialog $dialog) { continue }
        $savedHwnd=[Int64]$safetyContext.ActiveInputSurfaceHwnd
        $savedKind=[string]$safetyContext.ActiveInputSurfaceKind
        $savedLabel=[string]$safetyContext.ActiveInputSurfaceLabel
        try {
            Set-HtsSafetyInputSurface -Context $safetyContext -Window $dialog.window -Kind 'Dialog' -Label "HTS 대화상자: $($dialog.title)"
            [void][TargetRuleNative]::ShowWindow([IntPtr][Int64]$dialog.window.hwnd, 9)
            [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$dialog.window.hwnd)
            $safeButtons = @(Get-ChildWindows ([Int64]$dialog.window.hwnd) | Where-Object {
                $_.visible -and $_.enabled -and $_.className -like "*Button*" -and $_.rawTitle -match '^(취소|아니오|No|닫기|Close)$'
            } | Sort-Object @{Expression={if($_.rawTitle -match '^(취소|아니오|No)$'){0}else{1}}}, {$_.rect.left})
            if ($safeButtons.Count -gt 0) {
                $dismissResult=Invoke-FlaUiControlAction $actionContext $safeButtons[0] 'invoke'
                if(-not ([bool]$dismissResult.success -and [bool]$dismissResult.verified)){Click-Center $actionContext $safeButtons[0]}
            } else {
                [void][TargetRuleNative]::SendMessage([IntPtr][Int64]$dialog.window.hwnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
            }
        } catch {
            continue
        } finally {
            if($savedHwnd -ne 0 -and [TargetRuleNative]::IsWindow([IntPtr]$savedHwnd)){
                try{Set-HtsSafetyInputSurface -Context $safetyContext -Window (Get-WindowInfo ([IntPtr]$savedHwnd)) -Kind $savedKind -Label $savedLabel}catch{Clear-HtsSafetyInputSurface -Context $safetyContext}
            }else{
                Clear-HtsSafetyInputSurface -Context $safetyContext
            }
        }
        Start-Sleep -Milliseconds 500
        if (-not [TargetRuleNative]::IsWindow([IntPtr][Int64]$dialog.window.hwnd)) { $dismissed++ }
    }
    $dismissed
}

# 발견 팝업을 예상 패턴과 MAP 근거에 대조하고 스크린샷 경로를 함께 저장한다.

# 로케이터 후보가 화면의 top/middle/bottom 상대 영역에 들어오는지 판단한다.
# 결함 증거는 HTS 메인 창의 물리 경계로 제한한다. 팝업 증거는 화면 복사를 사용해 별도 소유 창까지 포함한다.

# 로그 증분 관찰: 실행 전 오프셋 이후에 추가된 행만 읽어 과거 오류를 신규 결함으로 오인하지 않는다.

# 주문·체결 민감 로그의 길이/수정시각 증분으로 전송 발생 여부를 원문 노출 없이 판정한다.

# 케이스 시작 이후 추가된 로그 구간에서 새 오류 신호만 추출하고 민감값을 제거한다.

# 케이스 시작 시 이미 존재하던 오류 문구를 기준선으로 수집한다.

# 기준선에 없던 새 창 문구만 평가해 과거 팝업의 재검출을 막는다.

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
    SetInputSurface = { param($Window, [string]$Kind, [string]$Label) Set-HtsSafetyInputSurface -Context $safetyContext -Window $Window -Kind $Kind -Label $Label }
    SetScreenNumber = { param($ScreenEdit, [string]$ScreenNumber) Set-HtsScreenNumber $ScreenEdit $ScreenNumber }
    InvokeControlAction = {
        param($Window, [string]$Action, [string]$Key)
        Invoke-FlaUiControlAction $actionContext $Window $Action -Key $Key
    }
    TestInputAccess = { param($Window) Test-HtsScreenNavigationInputAccess $Window }
    ClickCenter = { param($Window) Click-Center $actionContext $Window }
    SendEnter = { Send-Key $actionContext ([byte]$VK_RETURN) }
    FocusInputWindow = { param($Window) Focus-HtsInputWindow $actionContext $Window }
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
        if ([Int64]$safetyContext.ActiveInputSurfaceHwnd -eq [Int64]$Window.hwnd) { Clear-HtsSafetyInputSurface -Context $safetyContext }
    }
}
$navigationContext = New-HtsNavigationContext `
    -SessionContext $sessionContext `
    -TargetScreenTitleRegex $RuntimeContext.TargetScreenTitleRegex `
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
    Set-HtsSafetySession -Context $safetyContext -Main $main
    [void][TargetRuleNative]::ShowWindow([IntPtr][Int64]$main.hwnd, 9)
    [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$main.hwnd)
    Set-HtsSafetyInputSurface -Context $safetyContext -Window $main -Kind 'Main' -Label 'HTS 메인 사전점검'
    $screenEdit = Find-ScreenNumberEdit $RuntimeContext $main
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
    if (-not $SkipExcel) { Export-HtsRuleResultWorkbooks $reportingContext $ReportDir }
    Write-Output $ReportDir
    return
}
$initialSearchOverlaysClosed = Close-ScreenSearchOverlays $navigationContext $main
$initialScreensPreserved = 0
if ($reuseExistingTargetScreenRequested) {
    $preservedTargetScreenHwnds = @(Get-HtsScreenWindows $navigationContext $main | ForEach-Object { [Int64]$_.hwnd } | Select-Object -Unique)
    [void](Set-HtsNavigationPreservedScreens -Context $navigationContext -Hwnds $preservedTargetScreenHwnds)
    $initialScreensPreserved = $navigationContext.PreservedTargetScreenHwnds.Count
    $initialScreensClosed = 0
} else {
    $initialScreensClosed = Close-ExistingTargetScreens $navigationContext $main
}
$results = New-Object Collections.Generic.List[object]

for ($caseIndex = 0; $caseIndex -lt $cases.Count; $caseIndex++) {
    $case = $cases[$caseIndex]
    $datasetInteractionStrategy = [string]$dataset.autoExploration.interactionStrategy
    $targetRuleContext.CurrentInteractionStrategy = if ($scenarioMode -and [string]$case.scenarioCase.executionOrder) {
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
    $currentResultEvaluationCases = New-Object Collections.Generic.List[object]
    $currentSignalEvaluationGroups = @{}
    $flaUiActionAttemptsBeforeCase = [int]$automationMetrics.FlaUiActionAttempts
    $executedExpectationPatterns = New-Object Collections.Generic.List[string]
    $requiredExpectations = New-Object Collections.Generic.List[object]
    [void](Reset-HtsObservationCaseContext -Context $observationContext -ResultEvaluationCases $currentResultEvaluationCases -SignalEvaluationGroups $currentSignalEvaluationGroups -RequiredExpectations $requiredExpectations)
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
    $caseErrorRegex = Get-HtsObservationErrorRegex -Context $observationContext $errorRegex $mapOracle
    try {
        $previousPid = if ($main) { [int]$main.pid } else { 0 }
        $main = Wait-HtsMainWindow -Context $sessionContext
        Set-HtsSafetySession -Context $safetyContext -Main $main
        if ($previousPid -ne 0 -and $main.pid -ne $previousPid) {
            Add-HtsActionRecord $reportingContext $actions "recoverMainWindow" "PASS" "hfrun" "재접속 후 새 HTS 메인 창을 찾아 실행을 계속했습니다."
        }
        [void](Dismiss-HtsDialogs $RuntimeContext $main $secret)
        $startupConnectionDialogs = @(Get-HtsConnectionDialogs $observationContext $RuntimeContext $main $secret)
        if ($startupConnectionDialogs.Count -gt 0) {
            throw "HTS_CONNECTION_LOST: 연결 장애 대화상자가 남아 있어 사용자 판단 없이 실행을 중단했습니다. $([string]$startupConnectionDialogs[0].text)"
        }
        [void](Close-ScreenSearchOverlays $navigationContext $main)
        $logBefore = Get-LogState $observationContext
        $beforeErrorTexts = @(Get-ErrorWindowTexts $observationContext $main $caseErrorRegex $secret)
        if ($reuseScenarioScreen -or $reuseExistingTargetScreenRequested) {
            $requestedScreenWindow = Find-ScreenWindow $navigationContext $main ([string]$case.screen.screenNumber)
            $screen = if ($requestedScreenWindow) { Find-BestHtsContentSurface $navigationContext $main $requestedScreenWindow ([string]$case.screen.screenNumber) @() } else { $null }
            if ($screen) {
                $usedExistingTargetScreen = Test-PreservedTargetScreen $navigationContext $requestedScreenWindow
                if ($usedExistingTargetScreen) {
                    Add-HtsActionRecord $reportingContext $actions 'attachExistingScreen' 'PASS' ([string]$case.screen.screenNumber) '사용자가 미리 열어둔 대상 화면에 연결했으며 화면번호 재입력을 수행하지 않았습니다.'
                } else {
                    Add-HtsActionRecord $reportingContext $actions 'reuseScreenForScenario' 'PASS' ([string]$case.screen.screenNumber) '같은 화면의 다음 시나리오 케이스이므로 화면을 닫고 다시 열지 않고 현재 콘텐츠 표면을 재사용했습니다.'
                }
            } elseif ($RequireExistingTargetScreen) {
                $existingScreenRequiredMissing = $true
                $pendingReasons.Add("사용자가 미리 열어둔 [$($case.screen.screenNumber)] 화면이 필요합니다.")
                Add-HtsActionRecord $reportingContext $actions 'attachExistingScreen' 'PENDING' ([string]$case.screen.screenNumber) '기존 대상 화면이 없어 화면번호 재입력 없이 실행을 보류했습니다.' 'EXISTING_SCREEN_REQUIRED'
            } else {
                $screenEdit = Find-ScreenNumberEdit $RuntimeContext $main
                Open-HtsScreen $navigationContext $main $screenEdit ([string]$case.screen.screenNumber)
                $openedTargetScreenForRun = $true
                $requestedScreenWindow = Find-ScreenWindow $navigationContext $main ([string]$case.screen.screenNumber)
                $screen = Find-BestHtsContentSurface $navigationContext $main $requestedScreenWindow ([string]$case.screen.screenNumber) @()
                $openAction = if($reuseScenarioScreen){'reopenMissingScenarioScreen'}else{'openTargetScreen'}
                $openMessage = if($reuseScenarioScreen){'같은 화면의 다음 케이스 전에 대상 화면이 사라져 다시 열었습니다.'}else{'실행 중인 HTS 메인 창의 화면번호 입력란으로 대상 화면을 열었습니다.'}
                Add-HtsActionRecord $reportingContext $actions $openAction $(if($screen){'PASS'}else{'FAIL'}) ([string]$case.screen.screenNumber) $openMessage $(if($screen){''}else{'SCREEN_NOT_VISIBLE'})
            }
        } else {
            $leftoverScreensClosed=Close-ExistingTargetScreens $navigationContext $main
            if($leftoverScreensClosed -gt 0){Add-HtsActionRecord $reportingContext $actions 'cleanupPreviousScreens' 'PASS' 'HTS sibling windows' "이전 화면에서 남은 HTS 내부 창 $leftoverScreensClosed개를 정리했습니다."}
            $remainingBeforeOpen=@(Get-HtsScreenWindows $navigationContext $main)
            if($remainingBeforeOpen.Count -gt 0){
                throw "SCREEN_SEQUENCE_GUARD: 이전 화면 $($remainingBeforeOpen.Count)개가 남아 있어 다음 화면 열기를 차단했습니다."
            }
            $baselineScreenHwnds=@(Get-ChildWindows ([Int64]$main.hwnd) | Where-Object { $_.visible -and $RuntimeContext.TargetScreenTitleRegex.IsMatch([string]$_.rawTitle) } | ForEach-Object { [Int64]$_.hwnd })
            $screenEdit = Find-ScreenNumberEdit $RuntimeContext $main
            Open-HtsScreen $navigationContext $main $screenEdit ([string]$case.screen.screenNumber)
            $openedTargetScreenForRun = $true
            $requestedScreenWindow = Find-ScreenWindow $navigationContext $main ([string]$case.screen.screenNumber)
            $screen = Find-BestHtsContentSurface $navigationContext $main $requestedScreenWindow ([string]$case.screen.screenNumber) $baselineScreenHwnds
        }
        if (-not $screen) {
            $openConnectionDialogs = @(Get-HtsConnectionDialogs $observationContext $RuntimeContext $main $secret)
            if ($openConnectionDialogs.Count -gt 0) {
                throw "HTS_CONNECTION_LOST: 화면 열기 중 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$openConnectionDialogs[0].text)"
            }
            if (-not $existingScreenRequiredMissing) {
                $screenOpenFailure = $true
                $automationContractFailure = $true
                $automationContractErrorCode = 'SCREEN_NOT_VISIBLE'
                Add-HtsActionRecord $reportingContext $actions "openScreen" "FAIL" ([string]$case.screen.screenNumber) "화면 창이 표시되지 않았습니다." "SCREEN_NOT_VISIBLE"
                $errors.Add("화면을 연 뒤 대상 창이 표시되지 않았습니다.")
            }
            foreach ($dialog in @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)) {
                if ($dialog.text) { $errors.Add($dialog.text) }
            }
        } else {
            if(-not (Focus-HtsRequestedScreen $navigationContext $main $screen ([string]$case.screen.screenNumber))){
                throw "INPUT_SCOPE_BLOCKED: [$($case.screen.screenNumber)] 대상 화면을 활성 입력 표면으로 고정하지 못했습니다."
            }
            Add-HtsActionRecord $reportingContext $actions "openScreen" "PASS" ([string]$case.screen.screenNumber) $(if($usedExistingTargetScreen){'기존 화면을 재호출하지 않고 활성화했습니다.'}else{'화면 창이 열렸습니다.'})
            if ($mapOracle) {
                $oracleMessageCount = @($mapOracle.messageBoxes).Count
                $oracleErrorCount = @($mapOracle.messageBoxes | Where-Object isExplicitError).Count
                $oracleValidationCount = @($mapOracle.messageBoxes | Where-Object classification -eq 'InputValidation').Count
                Add-HtsActionRecord $reportingContext $actions 'loadMapErrorOracle' 'PASS' ([string]$case.screen.screenNumber) "MAP 오류 오라클을 적용했습니다: 메시지 $oracleMessageCount개(명시 오류 $oracleErrorCount, 입력 검증 $oracleValidationCount), 오류 핸들러 $(@($mapOracle.errorHandlers).Count)개, 통신 식별자 $(@($mapOracle.requestNames).Count + @($mapOracle.transactionCodes).Count)개."
            } else {
                Add-HtsActionRecord $reportingContext $actions 'loadMapErrorOracle' 'PENDING' ([string]$case.screen.screenNumber) '화면별 MAP 오류 오라클이 없어 공통 오류 규칙만 적용합니다.' 'MAP_ERROR_ORACLE_NOT_FOUND'
            }
            if ($mapBehavior) {
                Add-HtsActionRecord $reportingContext $actions 'loadMapBehavior' 'PASS' ([string]$case.screen.screenNumber) "MAP 동작 모델을 적용했습니다: 이벤트 $(@($mapBehavior.eventHandlers).Count)개, 조회 $(@($mapBehavior.queryControls).Count)개, 자동조회 $(@($mapBehavior.autoQueryControls).Count)개, 상태제어 $(@($mapBehavior.stateControllerControls).Count)개, 입력 $(@($mapBehavior.inputControls).Count)개, 결과 $(@($mapBehavior.resultControls).Count)개."
            } else {
                Add-HtsActionRecord $reportingContext $actions 'loadMapBehavior' 'PENDING' ([string]$case.screen.screenNumber) '화면별 MAP 동작 모델이 없어 런타임 발견 정보만 사용합니다.' 'MAP_BEHAVIOR_NOT_FOUND'
            }
            if($mapModel -and $mapCatalog.installationFingerprint){
                $canonicalTitle=if($mapModel.registry){[string]$mapModel.registry.title}else{[string]$mapModel.screenName}
                $integrityStatus=if($mapModel.integrity){[string]$mapModel.integrity.status}else{'MANIFEST_MISSING'}
                $installStatus=if($integrityStatus -eq 'MATCH'){'PASS'}else{'PENDING'}
                Add-HtsActionRecord $reportingContext $actions 'loadInstallationCatalog' $installStatus ([string]$case.screen.screenNumber) "설치 기준 '$canonicalTitle'을 적용했습니다: 탭 형제 $(@($mapModel.tabSiblings).Count)개, 연결 정의 $(@($mapModel.dependencies).Count)개, 데이터 사전 $(@($mapModel.dataReferences).Count)개, 무결성 $integrityStatus." $(if($installStatus-eq'PASS'){''}else{'INSTALLATION_MODEL_DRIFT'})
                if($installStatus-ne'PASS'){$pendingReasons.Add("설치 무결성: $integrityStatus")}
            }
            if($requestedScreenWindow -and $screen.hwnd -ne $requestedScreenWindow.hwnd){
                Add-HtsActionRecord $reportingContext $actions 'resolveContentSurface' 'PASS' ([string]$screen.rawTitle) "요청 화면과 같은 번호이거나 화면 열기 뒤 새로 생성된 콘텐츠 표면만 선택했습니다."
            }
            if ($inputMode -eq "Prefilled") {
                Add-HtsActionRecord $reportingContext $actions "usePrefilledInputs" "PASS" "prefilled inputs" "현재 화면에 기본 입력된 값을 변경하지 않고 사용했습니다."
            } else {
                $accountStrategies = if ($case.screen.locators -and $case.screen.locators.account) { $case.screen.locators.account } else { $dataset.defaultLocators.account }
                $accountControl = Resolve-HtsRoleControl -Context $bindingContext -Screen $screen -Role 'account' -Strategies $accountStrategies
                if ($accountControl -and [Int64]$accountControl.hwnd -ne 0) { $claimedHwnds[[Int64]$accountControl.hwnd] = $true }
                if ($accountControl -and (Set-AutomationText $actionContext $accountControl ([string]$case.account.accountNumber))) {
                    Add-HtsActionRecord $reportingContext $actions "setAccount" "PASS" "account" "계좌번호를 입력했으며 결과에는 마스킹했습니다."
                } else {
                    Add-HtsActionRecord $reportingContext $actions "setAccount" "PENDING" "account" "신뢰도 높은 계좌 입력칸을 찾지 못했습니다." "LOCATOR_NOT_RESOLVED"
                    $pendingReasons.Add("계좌 입력칸")
                }

                $passwordStrategies = if ($case.screen.locators -and $case.screen.locators.password) { $case.screen.locators.password } else { $dataset.defaultLocators.password }
                $passwordControl = Resolve-HtsRoleControl -Context $bindingContext -Screen $screen -Role 'password' -Strategies $passwordStrategies
                if ($passwordControl -and [Int64]$passwordControl.hwnd -ne 0) { $claimedHwnds[[Int64]$passwordControl.hwnd] = $true }
                if (-not $secret) {
                    Add-HtsActionRecord $reportingContext $actions "setPassword" "PENDING" "password" "비밀번호 환경 변수가 설정되지 않았습니다." "SECRET_NOT_SET"
                    $pendingReasons.Add("비밀번호 환경 변수")
                } elseif ($passwordControl -and (Set-AutomationText $actionContext $passwordControl $secret -Sensitive)) {
                    Add-HtsActionRecord $reportingContext $actions "setPassword" "PASS" "password" "비밀번호를 입력했으며 값은 기록하지 않았습니다."
                } else {
                    Add-HtsActionRecord $reportingContext $actions "setPassword" "PENDING" "password" "신뢰도 높은 비밀번호 입력칸을 찾지 못했습니다." "LOCATOR_NOT_RESOLVED"
                    $pendingReasons.Add("비밀번호 입력칸")
                }
            }

            if (-not $scenarioMode) { foreach ($name in @($case.variables.Keys | Sort-Object)) {
                $dimensionRows = @($dataset.variables | Where-Object { $_.name -eq $name } | Select-Object -First 1)
                $dimension = if ($dimensionRows.Count -gt 0) { $dimensionRows[0] } else { [pscustomobject]@{name=$name;targetRole="condition:$name";controlKind="Auto";valueMatch="Value";required=$true;triggerQueryAfterChange=$true;sensitive=$false} }
                $variableExpectation=if($case.variableExpectedOutcomes -and $case.variableExpectedOutcomes.ContainsKey($name)){$case.variableExpectedOutcomes[$name]}else{$null}
                $variableOption=[pscustomobject]@{id="dataset-variable:$name";expectedOutcome=$variableExpectation}
                $resolvedVariableExpectation=Get-HtsExpectedOutcome $variableOption @($case.screen.expectedPopupPatterns)
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
                    Add-HtsActionRecord $reportingContext $actions "setCondition" "PASS" $name "$kind 방식으로 데이터셋 조건값을 적용했습니다. 기대 계약: $([string]$resolvedVariableExpectation.type) / $([string]$resolvedVariableExpectation.source) / $([string]$resolvedVariableExpectation.confidence)."
                    $variableRequirementRecord=$null
                    if([string]$resolvedVariableExpectation.type -in @('ValidationRequired','FailureRequired')){
                        $variableRequirementRecord=[pscustomobject]@{controlId="dataset-variable:$name";optionId=[string]$resolvedVariableExpectation.expectationId;outcome=$resolvedVariableExpectation;observations=(New-Object Collections.Generic.List[object])}
                        $variableRequirementRecord.observations.Add([pscustomobject]@{observationId="dataset-variable:$name-completion";kind='Success';executed=$true;evidencePresent=$true;message='데이터셋 조건값 적용을 완료했습니다.';sourceCode='';source='dataset variable completion'})
                        $requiredExpectations.Add($variableRequirementRecord)
                    }
                    if($resolvedVariableExpectation.queryShouldComplete -eq $true){
                        $queryRequiredExpectations.Add([pscustomobject]@{name=$name;outcome=$resolvedVariableExpectation})
                    }
                    $variableDialogs=@(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
                    if($variableDialogs.Count -gt 0){
                        Add-PopupObservations $observationContext $popupObservations $variableDialogs $main $case.caseId ([string]$case.screen.screenNumber) $ReportDir @($resolvedVariableExpectation.messagePatterns) $mapOracle
                        $variableConnectionDialogs = @($variableDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                        if ($variableConnectionDialogs.Count -gt 0) {
                            throw "HTS_CONNECTION_LOST: 조건 입력 직후 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$variableConnectionDialogs[0].text)"
                        }
                        foreach($dialog in $variableDialogs){
                            $observation=New-HtsDialogObservation -Context $observationContext $dialog $mapOracle $resolvedVariableExpectation $caseErrorRegex
                            Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'dataset-variable' "dataset-variable:$name" ([string]$resolvedVariableExpectation.expectationId)
                        }
                        [void](Dismiss-HtsDialogs $RuntimeContext $main $secret)
                    }
                } else {
                    $required = ($null -eq $dimension.required -or [bool]$dimension.required)
                    Add-HtsActionRecord $reportingContext $actions "setCondition" $(if ($required) { "PENDING" } else { "PASS" }) $name "조건 컨트롤을 찾지 못했거나 지정값을 적용하지 못했습니다." "LOCATOR_OR_VALUE_NOT_RESOLVED"
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
                        $accountLive = Resolve-RuleLiveControl $targetRuleContext $navigationContext $screen $accountCandidate
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
                    Add-HtsActionRecord $reportingContext $actions 'verifyTransactionalAccount' $(if($transactionAccountVerified){'PASS'}else{'PENDING'}) ([string]$case.account.id) $(if($transactionAccountVerified){$transactionAccountEvidence}elseif(-not $expectedAccount -and -not $allowObservedPrefilledAccount){'데이터셋 계좌번호가 비어 있고 사전입력 계좌 실행 정책도 허용되지 않았습니다.'}else{'MAP Account 컨트롤에서 실행 가능한 계좌값을 확인하지 못했습니다.'}) $(if($transactionAccountVerified){''}else{'TRANSACTION_ACCOUNT_NOT_VERIFIED'})
                    if (-not $transactionAccountVerified) { $autoPendingReasons.Add('주문 실행 계좌 미확인') }
                }
                if ($mapModel) {
                    $mapDefinedCount=@($mapModel.controls | Where-Object isActionable).Count
                    $mapBoundCount=@($initialControls | Where-Object { $_.definitionSource -eq 'MAP+Runtime' -and [string]$_.mapScreenCode -eq [string]$mapModel.screenCode }).Count
                    $mapUnboundCount=@($initialControls | Where-Object { $_.definitionSource -eq 'MAP' -and -not $_.mapMatched -and [string]$_.mapScreenCode -eq [string]$mapModel.screenCode }).Count
                    if ($scenarioMode -and $physicalPlan) {
                        $fixedBindingCount = @($physicalPlan.resolvedBindings | Where-Object { [string]$_.scenarioId -eq [string]$case.scenarioCase.scenarioId }).Count
                        Add-HtsActionRecord $reportingContext $actions "bindMapModel" "PASS" ([string]$case.screen.screenNumber) "물리계획 1.1이 시나리오에 고정한 바인딩 $fixedBindingCount개를 실행 단계별로 재검증합니다. 전체 MAP 미결합 $mapUnboundCount개는 현재 시나리오 판정에 포함하지 않습니다."
                    } else {
                        Add-HtsActionRecord $reportingContext $actions "bindMapModel" $(if($mapUnboundCount-eq0){"PASS"}else{"PENDING"}) ([string]$case.screen.screenNumber) "MAP '$($mapModel.screenName)'의 조작 가능 컨트롤 $mapDefinedCount개 중 $mapBoundCount개를 HWND/UIA/탭 순회 결과에 결합했고 $mapUnboundCount개는 미결합으로 기록했습니다." $(if($mapUnboundCount-eq0){""}else{"MAP_CONTROL_NOT_BOUND"})
                        if($mapUnboundCount-gt0){$autoPendingReasons.Add("MAP 컨트롤 미결합 $mapUnboundCount개")}
                    }
                } elseif ($mapConfig -and [bool]$mapConfig.enabled) {
                    Add-HtsActionRecord $reportingContext $actions "bindMapModel" "PENDING" ([string]$case.screen.screenNumber) $(if($mapInitializationIssue){$mapInitializationIssue}else{"해당 화면 MAP 기준 모델을 찾지 못했습니다."}) "MAP_MODEL_NOT_FOUND"
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
                    $initialPlans = @(Get-RuleScenarioPlanItems -Context $targetRuleContext -Controls $initialControls -ScenarioCase $case.scenarioCase)
                    foreach ($planRow in $initialPlans) {
                        if ($physicalPlan) { $planRow = Set-HtsScenarioPhysicalBinding -Context $bindingContext -PlanItem $planRow -ScenarioCase $case.scenarioCase -PhysicalPlan $physicalPlan }
                        [void]$queue.Add($planRow)
                        $scheduledPlanIds[[string]$planRow.planItemId] = $true
                    }
                    Add-HtsActionRecord $reportingContext $actions "discoverControls" "PASS" ([string]$case.screen.screenNumber) "콘텐츠 영역 컨트롤 $($initialControls.Count)개를 발견하고 시나리오 '$([string]$case.scenarioCase.scenarioId)'의 조작 단계 $($queue.Count)개만 계획했습니다."
                } else {
                    $initialPlans = @(Get-RuleControlPlanItems $targetRuleContext $initialControls)
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
                    Add-HtsActionRecord $reportingContext $actions "discoverControls" "PASS" ([string]$case.screen.screenNumber) "콘텐츠 영역에서 컨트롤 $($initialControls.Count)개, 실행 계획 $($queue.Count)개를 생성했습니다."
                }

                $lastScenarioActionPopupHwnds = @()
                # 주문 명령은 TAB_Ord의 Select + AssertSelected가 같은 케이스에서
                # 성공한 상태에서만 실행한다. 탭 전환 실패 뒤의 좌표 클릭을 차단한다.
                $verifiedOrderTabContexts = @{}
                $pendingOrderTabContexts = @{}
                for ($planIndex=0; $planIndex -lt $queue.Count; $planIndex++) {
                    $planItem = $queue[$planIndex]
                    if ($scenarioMode -and [string]$planItem.status -ne 'READY' -and (Test-HtsRequestedScreen $navigationContext $screen ([string]$case.screen.screenNumber))) {
                        $scenarioRefresh = @(Get-HtsDiscoveredControls -Context $discoveryContext -Screen $screen -ScreenNumber ([string]$case.screen.screenNumber) -ClaimedHwnds $claimedHwnds)
                        foreach ($refreshedControl in $scenarioRefresh) {
                            if (@($discoveredControls | Where-Object { [string]$_.controlId -eq [string]$refreshedControl.controlId -and [string]$_.stateContext -eq [string]$refreshedControl.stateContext }).Count -eq 0) {
                                $discoveredControls.Add($refreshedControl)
                            }
                        }
                        $replacement = @(Get-RuleScenarioPlanItems -Context $targetRuleContext -Controls $scenarioRefresh -ScenarioCase $case.scenarioCase | Where-Object scenarioStepId -eq ([string]$planItem.scenarioStepId) | Select-Object -First 1)
                        if ($replacement.Count -gt 0) {
                            if ($physicalPlan) { $replacement[0] = Set-HtsScenarioPhysicalBinding -Context $bindingContext -PlanItem $replacement[0] -ScenarioCase $case.scenarioCase -PhysicalPlan $physicalPlan }
                            if ([string]$replacement[0].status -eq 'READY') { $mapReboundControls++ }
                            $planItem = $replacement[0]
                            $queue[$planIndex] = $planItem
                        }
                    }
                    $planStarted = Get-Date
                    $option = $planItem.option
                    $expectedOutcome=Get-HtsExpectedOutcome $option @($case.screen.expectedPopupPatterns)
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
                            interactionStrategy=[string]$targetRuleContext.CurrentInteractionStrategy;coordinateFocusUsed=$false;coordinateFocusVerified=$false
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
                    $dialogHwndsBefore = if($scenarioMode){@(Get-HtsDialogs $observationContext $RuntimeContext $main $secret | ForEach-Object {[Int64]$_.window.hwnd} | Sort-Object -Unique)}else{@()}
                    $freshStepDialogs = @()
                    $transactionPreRecordedHwnds = @()
                    $assertedPopupScreenshot = ''
                    $queryTriggered = $false
                    $screenReopened = $false
                    $navigationHandled = $false
                    $restorationFailed = $false
                    $unexpectedScreenClose = $false

                    if(-not (Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)){
                        $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                    }
                    if(Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber){
                        [void](Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)
                        $mapStateBlockReason = ''
                        $planMapCode = ([string]$planItem.mapScreenCode).Trim().ToUpperInvariant()
                        if ($scenarioMode -and [string]$planItem.executionOrder -eq 'CoordinateFocus' -and $planMapCode -and
                            $RuntimeContext.InitiallyActiveMapScreenCodes.Count -gt 0 -and $RuntimeContext.InitiallyActiveMapScreenCodes -notcontains $planMapCode) {
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
                                $currentAccountLive = Resolve-RuleLiveControl $targetRuleContext $navigationContext $screen $transactionAccountCandidate
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
                            $invoke = Invoke-RuleControlAssertion $targetRuleContext $navigationContext $screen $planItem
                        } elseif ([string]$planItem.scenarioAction -eq 'Restore') {
                            $restoreDialogs = @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
                            $restoreConnectionDialogs = @($restoreDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                            if ($restoreConnectionDialogs.Count -gt 0) {
                                throw "HTS_CONNECTION_LOST: 복구 단계에서 연결 장애 팝업을 발견해 자동 닫기를 중단했습니다."
                            }
                            if ($restoreDialogs.Count -eq 0) {
                                $invoke=[pscustomobject]@{success=$true;queryEligible=$false;errorCode='';automationEngine='Safe dialog restore';output='복구할 팝업이 없어 현재 0101 상태를 유지했습니다.'}
                            } else {
                                $dismissedCount = Dismiss-HtsDialogs $RuntimeContext $main $secret
                                $remainingRestoreDialogs = @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret | Where-Object { -not (Test-HtsConnectionDialog $_) })
                                $restoreSucceeded = $remainingRestoreDialogs.Count -eq 0
                                $invoke=[pscustomobject]@{success=$restoreSucceeded;queryEligible=$false;errorCode=$(if($restoreSucceeded){''}else{'RESTORE_DIALOG_NOT_DISMISSED'});automationEngine='Safe dialog restore';output="dismissed=$dismissedCount, remaining=$($remainingRestoreDialogs.Count)"}
                            }
                        } elseif ([string]$planItem.scenarioAction -eq 'AssertPopup') {
                            Start-Sleep -Milliseconds 250
                            $activePopups = @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
                            $activePopupHwnds = @($activePopups | ForEach-Object {[Int64]$_.window.hwnd} | Sort-Object -Unique)
                            $matchedFreshHwnds = @($lastScenarioActionPopupHwnds | Where-Object {$activePopupHwnds -contains [Int64]$_} | Sort-Object -Unique)
                            $matchedObservation = @($popupObservations | Where-Object {$matchedFreshHwnds -contains [Int64]$_.windowHwnd} | Select-Object -Last 1)
                            if($matchedObservation.Count -gt 0){$assertedPopupScreenshot=[string]$matchedObservation[0].screenshotPath}
                            $popupAssertionSucceeded = $matchedFreshHwnds.Count -gt 0
                            $invoke=[pscustomobject]@{success=$popupAssertionSucceeded;queryEligible=$false;errorCode=$(if($popupAssertionSucceeded){''}else{'ASSERT_POPUP_NOT_OBSERVED'});automationEngine='Fresh popup observer';output="priorActionNewPopupCount=$($lastScenarioActionPopupHwnds.Count), activePopupCount=$($activePopupHwnds.Count), matchedFreshPopupCount=$($matchedFreshHwnds.Count), matchedHwnds=$($matchedFreshHwnds -join ',')"}
                        } elseif ([string]$planItem.scenarioAction -eq 'AssertNoTransmission') {
                            $transmissionDelta = Get-TransmissionDelta $observationContext $logBefore
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
                            $transactionDialogs = @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret | Where-Object { $dialogHwndsBefore -notcontains [Int64]$_.window.hwnd })
                            if ($transactionDialogs.Count -gt 0) { break }
                        }
                        if ($transactionDialogs.Count -eq 0) {
                            $invoke.output = "$([string]$invoke.output); transactionSubmission=direct-or-no-confirmation-dialog"
                        } else {
                            Add-PopupObservations $observationContext -List $popupObservations -Dialogs $transactionDialogs -Main $main -CaseId $case.caseId -ScreenNumber $requestedScreenNumber -ReportBase $ReportDir -ExpectedPatterns @($expectedOutcome.messagePatterns) -MapOracle $mapOracle
                            $transactionPreRecordedHwnds = @($transactionDialogs | ForEach-Object { [Int64]$_.window.hwnd })
                            $eligibleTransactionDialogs = @($transactionDialogs | Where-Object { Test-HtsTransactionalConfirmationDialog $_ $planItem })
                            if ($eligibleTransactionDialogs.Count -eq 1) {
                                $transactionSubmit = Submit-HtsTransactionalDialog $actionContext $eligibleTransactionDialogs[0] $planItem
                                $invoke.output = "$([string]$invoke.output); $([string]$transactionSubmit.output)"
                                if (-not [bool]$transactionSubmit.success) {
                                    $invoke.success = $false
                                    $invoke.errorCode = [string]$transactionSubmit.errorCode
                                }
                            } else {
                                foreach ($transactionDialog in $transactionDialogs) {
                                    $transactionObservation = New-HtsDialogObservation -Context $observationContext $transactionDialog $mapOracle $expectedOutcome $caseErrorRegex
                                    Add-HtsOracleObservation -Context $observationContext $oracleEvents $transactionObservation 'transaction-confirmation' ([string]$planItem.control.controlId) ([string]$option.id)
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

                    $stepDialogs = @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
                    if ($stepDialogs.Count -gt 0) {
                        $freshStepDialogs = @($stepDialogs | Where-Object {$dialogHwndsBefore -notcontains [Int64]$_.window.hwnd})
                        $dialogsToRecord = @(
                            if($scenarioMode){
                                if([string]$planItem.scenarioAction -ne 'AssertPopup'){@($freshStepDialogs | Where-Object { $transactionPreRecordedHwnds -notcontains [Int64]$_.window.hwnd })}
                            }else{$stepDialogs}
                        )
                        if(@($dialogsToRecord).Count -gt 0){
                            $popupRecordCountBefore=$popupObservations.Count
                            Add-PopupObservations $observationContext -List $popupObservations -Dialogs $dialogsToRecord -Main $main -CaseId $case.caseId -ScreenNumber $requestedScreenNumber -ReportBase $ReportDir -ExpectedPatterns @($expectedOutcome.messagePatterns) -MapOracle $mapOracle
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
                            $observation=New-HtsDialogObservation -Context $observationContext $dialog $mapOracle $expectedOutcome $caseErrorRegex
                            Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'control' ([string]$planItem.control.controlId) ([string]$option.id)
                        }
                        $nextScenarioAction = if ($scenarioMode -and $planIndex + 1 -lt $queue.Count) { [string]$queue[$planIndex + 1].scenarioAction } else { '' }
                        if ($nextScenarioAction -notin @('AssertPopup','Restore')) {
                            [void](Dismiss-HtsDialogs $RuntimeContext $main $secret)
                        }
                    }

                    $linkedScreens=@(Get-HtsLinkedScreens $navigationContext $main $requestedScreenNumber)
                    if($linkedScreens.Count -gt 0){
                        Add-LinkedScreenObservations $observationContext $RuntimeContext $popupObservations $linkedScreens $main $case.caseId $requestedScreenNumber $ReportDir $secret @($planItem.control.mapNavigationTargets)
                        $linkedTitles=@($linkedScreens | ForEach-Object { [string]$_.rawTitle }) -join ', '
                        $linkedClosed=Close-HtsLinkedScreens $navigationContext $main $requestedScreenNumber
                        $navigationHandled=$true
                        $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                        if(-not $screen){
                            $screenEdit=Find-ScreenNumberEdit $RuntimeContext $main
                            Open-HtsScreen $navigationContext $main $screenEdit $requestedScreenNumber
                            $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                            $screenReopened=($null -ne $screen)
                        }
                        if($screen){[void](Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)}
                        $restorationFailed=-not (Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber)
                        Add-HtsActionRecord $reportingContext $actions 'restoreAfterNavigation' $(if($restorationFailed){'PENDING'}else{'PASS'}) $requestedScreenNumber "연계 화면을 관찰하고 $linkedClosed/$($linkedScreens.Count)개를 닫은 뒤 대상 화면을 복원했습니다: $linkedTitles" $(if($restorationFailed){'TARGET_RESTORE_FAILED'}else{''})
                    }

                    $screenAlive=Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber
                    if(-not $screenAlive -and -not $navigationHandled){
                        $isButtonTransition=$invoke.success -and [string]$planItem.control.controlKind -eq 'Button' -and (
                            [string]$planItem.control.mapSemanticRole -eq 'Navigation' -or @($planItem.control.mapNavigationTargets).Count -gt 0
                        )
                        if($isButtonTransition){
                            Add-UnnumberedTransitionObservation $observationContext $RuntimeContext $popupObservations $main $case.caseId $requestedScreenNumber $ReportDir $secret
                            $navigationHandled=$true
                        }else{
                            $unexpectedScreenClose=$true
                            $errors.Add("컨트롤 조작 중 [$requestedScreenNumber] 화면이 예기치 않게 닫혔습니다.")
                        }
                        $screenEdit=Find-ScreenNumberEdit $RuntimeContext $main
                        Open-HtsScreen $navigationContext $main $screenEdit $requestedScreenNumber
                        $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                        $screenReopened=($null -ne $screen)
                        $screenAlive=Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber
                        if($isButtonTransition){
                            $restorationFailed=-not $screenAlive
                            Add-HtsActionRecord $reportingContext $actions 'restoreAfterUnnumberedTransition' $(if($restorationFailed){'PENDING'}else{'PASS'}) $requestedScreenNumber '버튼 조작으로 발생한 번호 없는 콘텐츠 전환을 기록하고 대상 화면을 다시 열었습니다.' $(if($restorationFailed){'TARGET_RESTORE_FAILED'}else{''})
                        }else{
                            Add-HtsActionRecord $reportingContext $actions 'reopenScreen' 'FAIL' $requestedScreenNumber '연계 화면 없이 대상 화면이 사라져 다시 열었습니다.' 'SCREEN_CLOSED_UNEXPECTEDLY'
                        }
                    }
                    if($screenReopened -and $screenAlive){$claimedHwnds=Get-HtsClaimedControlHwndMap -Context $bindingContext -Screen $screen -Case $case -Dataset $dataset}

                    $triggerQueryForPlanItem = if ($scenarioMode) { [bool]$planItem.triggerQueryAfterChange } else { [bool]$dataset.autoExploration.triggerQueryAfterStateChange }
                    if ($invoke.success -and $invoke.queryEligible -and -not $navigationHandled -and $screenAlive -and $triggerQueryForPlanItem) {
                        [void](Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)
                        $liveTabQuery=if($tabOrderQueryControl){Resolve-RuleLiveControl $targetRuleContext $navigationContext $screen $tabOrderQueryControl}else{$null}
                        if($liveTabQuery){
                            $queryResult=Invoke-FlaUiControlAction $actionContext $liveTabQuery 'invoke'
                            if(-not ([bool]$queryResult.success -and [bool]$queryResult.verified)){Click-Center $actionContext $liveTabQuery}
                        }else{Send-Key $actionContext ([byte]$VK_F12)}
                        Start-Sleep -Milliseconds ([Math]::Max(500,[int]$dataset.executionPolicy.actionTimeoutMs))
                        $queryTriggered = $true
                        $mapQueryExecuted = $true

                        $queryDialogs=@(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
                        if($queryDialogs.Count -gt 0){
                            Add-PopupObservations $observationContext $popupObservations $queryDialogs $main $case.caseId $requestedScreenNumber $ReportDir @($expectedOutcome.messagePatterns) $mapOracle
                            $queryConnectionDialogs = @($queryDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                            if ($queryConnectionDialogs.Count -gt 0) {
                                throw "HTS_CONNECTION_LOST: 조회 직후 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$queryConnectionDialogs[0].text)"
                            }
                            foreach($dialog in $queryDialogs){
                                $observation=New-HtsDialogObservation -Context $observationContext $dialog $mapOracle $expectedOutcome $caseErrorRegex
                                Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'query-after-control' ([string]$planItem.control.controlId) ([string]$option.id)
                            }
                            [void](Dismiss-HtsDialogs $RuntimeContext $main $secret)
                        }
                        $queryLinkedScreens=@(Get-HtsLinkedScreens $navigationContext $main $requestedScreenNumber)
                        if($queryLinkedScreens.Count -gt 0){
                            Add-LinkedScreenObservations $observationContext $RuntimeContext $popupObservations $queryLinkedScreens $main $case.caseId $requestedScreenNumber $ReportDir $secret @($planItem.control.mapNavigationTargets)
                            $queryLinkedClosed=Close-HtsLinkedScreens $navigationContext $main $requestedScreenNumber
                            $navigationHandled=$true
                            $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                            if(-not $screen){
                                $screenEdit=Find-ScreenNumberEdit $RuntimeContext $main
                                Open-HtsScreen $navigationContext $main $screenEdit $requestedScreenNumber
                                $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                                $screenReopened=($null -ne $screen)
                            }
                            if($screen){[void](Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)}
                            $restorationFailed=-not (Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber)
                            Add-HtsActionRecord $reportingContext $actions 'restoreAfterQueryNavigation' $(if($restorationFailed){'PENDING'}else{'PASS'}) $requestedScreenNumber "조회 후 열린 연계 화면 $queryLinkedClosed/$($queryLinkedScreens.Count)개를 닫고 대상 화면을 복원했습니다." $(if($restorationFailed){'TARGET_RESTORE_FAILED'}else{''})
                        }
                        $screenAlive=Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber
                        if(-not $screenAlive -and $queryLinkedScreens.Count -eq 0){
                            Add-UnnumberedTransitionObservation $observationContext $RuntimeContext $popupObservations $main $case.caseId $requestedScreenNumber $ReportDir $secret
                            $navigationHandled=$true
                            $screenEdit=Find-ScreenNumberEdit $RuntimeContext $main
                            Open-HtsScreen $navigationContext $main $screenEdit $requestedScreenNumber
                            $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                            $screenReopened=($null -ne $screen)
                            $screenAlive=Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber
                            $restorationFailed=-not $screenAlive
                            Add-HtsActionRecord $reportingContext $actions 'restoreAfterQueryTransition' $(if($restorationFailed){'PENDING'}else{'PASS'}) $requestedScreenNumber '조회 후 번호 없는 콘텐츠 전환을 기록하고 대상 화면을 다시 열었습니다.' $(if($restorationFailed){'TARGET_RESTORE_FAILED'}else{''})
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
                        interactionStrategy=$(if($invoke.PSObject.Properties.Name -contains 'interactionStrategy'){[string]$invoke.interactionStrategy}else{[string]$targetRuleContext.CurrentInteractionStrategy})
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

                    if (-not $scenarioMode -and (Test-HtsRequestedScreen $navigationContext $screen ([string]$case.screen.screenNumber))) {
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
                            foreach ($newPlan in @(Get-RuleControlPlanItems $targetRuleContext @($controlForPlan))) {
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
                    Add-HtsActionRecord $reportingContext $actions 'rediscoverMapControls' 'PASS' ([string]$case.screen.screenNumber) "상태 변경 뒤 새로 활성화되거나 선택지가 늘어난 MAP 컨트롤 $mapReboundControls건을 다시 결합해 실행 계획에 추가했습니다."
                } elseif ($mapBehavior -and @($mapBehavior.stateControllerControls).Count -gt 0) {
                    Add-HtsActionRecord $reportingContext $actions 'rediscoverMapControls' 'PASS' ([string]$case.screen.screenNumber) '상태 변경마다 MAP 컨트롤을 다시 탐색했으며 추가 활성화된 컨트롤은 없었습니다.'
                }
                $controlEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId="$($case.caseId)-controls";cases=@($observationContext.CurrentResultEvaluationCases.ToArray())}
                $controlEvaluationOutput=Invoke-RuleResultEvaluation -CliProject $cliProject -TestPackPath $resultEvaluationTestPackPath -EvaluationDocument $controlEvaluationDocument -WorkingDirectory $resultEvaluationWorkingDirectory -InvocationId 'case-controls'
                Add-HtsActionRecord $reportingContext $actions "executeControlOptions" ([string]$controlEvaluationOutput.overallResult.status) "content controls" "컨트롤 선택지 $($controlTests.Count)개를 계획 또는 실행했습니다. $([string]$controlEvaluationOutput.overallResult.reason)"
            }

            if (-not $PlanOnly -and -not $scenarioMode) {
                $requestedScreenNumber=[string]$case.screen.screenNumber
                if(-not (Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)){
                    $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                }
                $queryStrategies = if ($case.screen.locators -and $case.screen.locators.query) { $case.screen.locators.query } else { $dataset.defaultLocators.query }
                $queryControls = if(Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber){@(Get-HtsRequiredQueryControls -Context $bindingContext -Screen $screen -Strategies $queryStrategies)}else{@()}
                if($tabOrderQueryControl -and (Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber)){
                    $liveTabQuery=Resolve-RuleLiveControl $targetRuleContext $navigationContext $screen $tabOrderQueryControl
                    if($liveTabQuery){$queryControls=@($liveTabQuery)+@($queryControls)}
                }
                $queryControls=@($queryControls | Group-Object { "{0}:{1}" -f [int](($_.rect.left+$_.rect.right)/2),[int](($_.rect.top+$_.rect.bottom)/2) } | ForEach-Object {$_.Group[0]})
                if ($queryControls.Count -gt 0) {
                    for ($queryIndex=0; $queryIndex -lt $queryControls.Count; $queryIndex++) {
                        $queryStarted=Get-Date
                        $queryControl=$queryControls[$queryIndex]
                        if(-not (Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)){
                            $automationIssues.Add('필수 조회 직전에 대상 화면을 활성화하지 못했습니다: TARGET_SCREEN_NOT_ACTIVE')
                            break
                        }
                        try {
                            $queryResult=Invoke-FlaUiControlAction $actionContext $queryControl 'invoke'
                            $queryActionEngine=if([bool]$queryResult.success -and [bool]$queryResult.verified){'FlaUI.UIA3'}else{'Win32 fallback'}
                            if($queryActionEngine -eq 'Win32 fallback'){Click-Center $actionContext $queryControl}
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
                            Add-HtsActionRecord $reportingContext $actions 'invokeQuery' 'PENDING' '조회' '전경 안전 검증으로 필수 조회 입력을 차단했습니다.' 'INPUT_GUARD_BLOCKED'
                            $automationIssues.Add("필수 조회 입력 차단: $guardMessage")
                            break
                        }
                        Start-Sleep -Milliseconds ([Math]::Max(500,[int]$dataset.executionPolicy.actionTimeoutMs))

                        $queryDialogs=@(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
                        if($queryDialogs.Count -gt 0){
                            $caseExpectedOutcome=Get-HtsExpectedOutcome $null @(@($case.screen.expectedPopupPatterns)+@($executedExpectationPatterns))
                            Add-PopupObservations $observationContext $popupObservations $queryDialogs $main $case.caseId $requestedScreenNumber $ReportDir @($caseExpectedOutcome.messagePatterns) $mapOracle
                            $requiredQueryConnectionDialogs = @($queryDialogs | Where-Object { Test-HtsConnectionDialog $_ })
                            if ($requiredQueryConnectionDialogs.Count -gt 0) {
                                throw "HTS_CONNECTION_LOST: 필수 조회 직후 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$requiredQueryConnectionDialogs[0].text)"
                            }
                            foreach($dialog in $queryDialogs){
                                $observation=New-HtsDialogObservation -Context $observationContext $dialog $mapOracle $caseExpectedOutcome $caseErrorRegex
                                Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'required-query'
                            }
                            [void](Dismiss-HtsDialogs $RuntimeContext $main $secret)
                        }
                        $queryLinkedScreens=@(Get-HtsLinkedScreens $navigationContext $main $requestedScreenNumber)
                        $queryNavigationHandled=$false
                        if($queryLinkedScreens.Count -gt 0){
                            Add-LinkedScreenObservations $observationContext $RuntimeContext $popupObservations $queryLinkedScreens $main $case.caseId $requestedScreenNumber $ReportDir $secret @($tabOrderQueryControl.mapNavigationTargets)
                            $queryLinkedClosed=Close-HtsLinkedScreens $navigationContext $main $requestedScreenNumber
                            $queryNavigationHandled=$true
                            $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                            if(-not $screen){
                                $screenEdit=Find-ScreenNumberEdit $RuntimeContext $main
                                Open-HtsScreen $navigationContext $main $screenEdit $requestedScreenNumber
                                $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                            }
                            if($screen){[void](Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)}
                            Add-HtsActionRecord $reportingContext $actions 'restoreAfterRequiredQuery' $(if(Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber){'PASS'}else{'PENDING'}) $requestedScreenNumber "필수 조회 후 열린 연계 화면 $queryLinkedClosed/$($queryLinkedScreens.Count)개를 닫고 대상 화면을 복원했습니다." $(if(Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber){''}else{'TARGET_RESTORE_FAILED'})
                        }
                        $queryAlive=Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber
                        if(-not $queryAlive -and -not $queryNavigationHandled){
                            Add-UnnumberedTransitionObservation $observationContext $RuntimeContext $popupObservations $main $case.caseId $requestedScreenNumber $ReportDir $secret
                            $queryNavigationHandled=$true
                            $screenEdit=Find-ScreenNumberEdit $RuntimeContext $main
                            Open-HtsScreen $navigationContext $main $screenEdit $requestedScreenNumber
                            $screen=Find-ScreenWindow $navigationContext $main $requestedScreenNumber
                            if($screen){[void](Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber)}
                            $queryAlive=Test-HtsRequestedScreen $navigationContext $screen $requestedScreenNumber
                            Add-HtsActionRecord $reportingContext $actions 'restoreAfterRequiredQueryTransition' $(if($queryAlive){'PASS'}else{'PENDING'}) $requestedScreenNumber '필수 조회 후 번호 없는 콘텐츠 전환을 기록하고 대상 화면을 다시 열었습니다.' $(if($queryAlive){''}else{'TARGET_RESTORE_FAILED'})
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
                        Add-HtsActionRecord $reportingContext $actions "invokeQuery" $queryStatus $queryName "활성화된 조회 버튼을 필수 단계에서 실제 클릭했습니다." $(if($queryAlive){""}elseif($queryNavigationHandled){'TARGET_RESTORE_FAILED'}else{"SCREEN_CLOSED_UNEXPECTEDLY"})
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
                    Add-HtsActionRecord $reportingContext $actions 'invokeQuery' 'PASS' '탭오더 조회 이력' "탭오더 순회 중 식별된 활성 조회 버튼 $completedTabQueries개를 실제 클릭했습니다."
                    $mapQueryExecuted = $true
                } else {
                    if(Focus-HtsRequestedScreen $navigationContext $main $screen $requestedScreenNumber){
                        Send-Key $actionContext ([byte]$VK_F12)
                        Start-Sleep -Milliseconds ([Math]::Max(500,[int]$dataset.executionPolicy.actionTimeoutMs))
                        Add-HtsActionRecord $reportingContext $actions "invokeQuery" "PASS" "F12" "활성 조회 버튼을 찾지 못해 화면의 F12 조회 단축키를 실행했습니다."
                        $mapQueryExecuted = $true
                        $automationIssues.Add("활성화된 조회 버튼을 찾지 못해 F12로 대체했습니다: QUERY_BUTTON_NOT_FOUND")
                    }else{
                        Add-HtsActionRecord $reportingContext $actions 'invokeQuery' 'PENDING' 'F12' '대상 화면을 활성화하지 못해 F12 입력을 차단했습니다.' 'TARGET_SCREEN_NOT_ACTIVE'
                        $automationIssues.Add('대상 화면을 활성화하지 못해 필수 조회를 실행하지 못했습니다: TARGET_SCREEN_NOT_ACTIVE')
                    }
                }
            } else {
                Add-HtsActionRecord $reportingContext $actions "invokeQuery" "PENDING" $queryTrigger "계획 전용 실행이므로 조회를 실행하지 않았습니다." "PLAN_ONLY"
            }
            if ($mapBehavior -and @($mapBehavior.queryControls).Count -gt 0) {
                if ($mapQueryExecuted) {
                    Add-HtsActionRecord $reportingContext $actions 'evaluateMapBehavior' 'PASS' (@($mapBehavior.queryControls) -join ', ') 'MAP이 정의한 조회 경로를 실제 컨트롤 조작 또는 조회 단축키로 실행했습니다.'
                } else {
                    Add-HtsActionRecord $reportingContext $actions 'evaluateMapBehavior' 'PENDING' (@($mapBehavior.queryControls) -join ', ') 'MAP이 정의한 조회 경로의 실행 증거를 확보하지 못했습니다.' 'MAP_QUERY_NOT_EXECUTED'
                    $autoPendingReasons.Add('MAP 조회 트리거 미실행')
                }
            } elseif ($mapBehavior) {
                Add-HtsActionRecord $reportingContext $actions 'evaluateMapBehavior' 'PASS' ([string]$case.screen.screenNumber) 'MAP에 별도 조회 역할 컨트롤이 정의되지 않은 화면입니다.'
            }
            foreach ($reason in $autoPendingReasons) { $pendingReasons.Add($reason) }
            if ($automationIssues.Count -gt 0) { $pendingReasons.Add("자동 컨트롤 조작 일부 미완료($($automationIssues.Count)건)") }
        }

        $caseExpectedOutcome=Get-HtsExpectedOutcome $null @(@($case.screen.expectedPopupPatterns)+@($executedExpectationPatterns))
        $finalDialogs = @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret)
        if ($finalDialogs.Count -gt 0) {
            Add-PopupObservations $observationContext $popupObservations $finalDialogs $main $case.caseId ([string]$case.screen.screenNumber) $ReportDir @($caseExpectedOutcome.messagePatterns) $mapOracle
            $finalConnectionDialogs = @($finalDialogs | Where-Object { Test-HtsConnectionDialog $_ })
            if ($finalConnectionDialogs.Count -gt 0) {
                throw "HTS_CONNECTION_LOST: 케이스 종료 전 연결 장애가 확인되어 사용자 판단 없이 실행을 중단했습니다. $([string]$finalConnectionDialogs[0].text)"
            }
            foreach ($dialog in $finalDialogs) {
                $observation=New-HtsDialogObservation -Context $observationContext $dialog $mapOracle $caseExpectedOutcome $caseErrorRegex
                Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'final-dialog'
            }
        }
        $windowErrors = @(Get-ExplicitWindowErrors $observationContext $main $beforeErrorTexts $caseErrorRegex $secret $mapOracle)
        $logErrors = @(Get-LogErrors $observationContext $logBefore $caseErrorRegex $secret $mapOracle)
        foreach ($message in $windowErrors) {
            $observation=New-HtsSignalObservation -Context $observationContext ([string]$message) $mapOracle $caseExpectedOutcome $caseErrorRegex
            Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'window-text'
        }
        foreach ($message in $logErrors) {
            $observation=New-HtsSignalObservation -Context $observationContext ([string]$message) $mapOracle $caseExpectedOutcome $caseErrorRegex
            Add-HtsOracleObservation -Context $observationContext $oracleEvents $observation 'log'
        }
        # Windows PowerShell 5.1은 빈 제네릭 List<object>를 @()로 감쌀 때 바인더 예외를 낼 수 있어 배열로 명시 변환한다.
        foreach($queryRequired in $queryRequiredExpectations.ToArray()){
            if(-not $mapQueryExecuted){
                $pendingReasons.Add("입력 또는 시나리오 단계 '$([string]$queryRequired.name)'의 기대 계약은 조회 완료가 필요하지만 조회를 실행하지 못했습니다: QUERY_EXPECTATION_NOT_EXECUTED")
            }
        }
        $signalGroupEvaluationCases=New-Object Collections.Generic.List[object]
        $signalGroupsByCaseId=@{}
        foreach($signalGroupKey in @($observationContext.CurrentSignalEvaluationGroups.Keys | Sort-Object)){
            $signalGroup=$observationContext.CurrentSignalEvaluationGroups[$signalGroupKey]
            $signalGroupCaseId="signal-group-{0:D6}" -f (Get-HtsNextObservationSequence -Context $observationContext)
            $signalGroupCase=[pscustomobject]@{caseId=$signalGroupCaseId;executed=$true;expectedResult=$signalGroup.expectedResult;observations=@($signalGroup.observations.ToArray())}
            $signalGroupEvaluationCases.Add($signalGroupCase)
            $observationContext.CurrentResultEvaluationCases.Add($signalGroupCase)
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
            $requiredCaseId="required-expectation-{0:D6}" -f (Get-HtsNextObservationSequence -Context $observationContext)
            $requiredEvaluationCase=[pscustomobject]@{
                caseId=$requiredCaseId;executed=$true
                expectedResult=[pscustomobject]@{
                    expectationId=[string]$required.outcome.expectationId;type=[string]$required.outcome.type
                    description=@($required.outcome.evidence) -join '; ';messagePatterns=@($required.outcome.messagePatterns);errorCodes=@($required.outcome.errorCodes)
                }
                observations=@($required.observations.ToArray())
            }
            $requiredEvaluationCases.Add($requiredEvaluationCase)
            $observationContext.CurrentResultEvaluationCases.Add($requiredEvaluationCase)
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
        $signalEvaluationDocument=[pscustomobject]@{schemaVersion='1.0';testPackId=[string]$testPack.testPackId;aggregateId="$($case.caseId)-signals";cases=@($observationContext.CurrentResultEvaluationCases.ToArray())}
        $signalEvaluationOutput=Invoke-RuleResultEvaluation -CliProject $cliProject -TestPackPath $resultEvaluationTestPackPath -EvaluationDocument $signalEvaluationDocument -WorkingDirectory $resultEvaluationWorkingDirectory -InvocationId 'case-signals'
        Add-HtsActionRecord $reportingContext $actions "evaluateExplicitErrors" ([string]$signalEvaluationOutput.overallResult.status) "popup/process/log" ([string]$signalEvaluationOutput.overallResult.reason)
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
        Add-HtsActionRecord $reportingContext $actions "executor" "ERROR" "runtime" $(if($externalInterruption){'HTS 연결 장애를 감지해 재접속·종료 버튼을 누르지 않고 실행을 중단했습니다.'}elseif($automationContractErrorCode -eq 'HTS_UI_ACCESS_DENIED'){'HTS UI 권한 경계로 화면 전환을 차단했습니다.'}elseif($automationContractErrorCode -eq 'SCREEN_NAVIGATION_TEXT_UNVERIFIED'){'HTS 화면번호 입력의 종단 간 검증을 완료하지 못해 화면 전환을 차단했습니다.'}else{"룰 실행기에서 예외가 발생했습니다: $executorDiagnostic"}) $(if($externalInterruption){'HTS_CONNECTION_LOST'}elseif($automationContractErrorCode -eq 'HTS_UI_ACCESS_DENIED'){'HTS_UI_ACCESS_DENIED'}elseif($automationContractErrorCode -eq 'SCREEN_NAVIGATION_TEXT_UNVERIFIED'){'SCREEN_NAVIGATION_TEXT_UNVERIFIED'}else{'EXECUTOR_EXCEPTION'})
        if (-not $main -or -not [TargetRuleNative]::IsWindow([IntPtr][Int64]$main.hwnd)) { $main = $null }
    }

    $screenshot = ""
    if ($errors.Count -gt 0) {
        $candidateScreenshot = Join-Path $screenshotsDir ("error-{0}-{1}.png" -f $case.screen.screenNumber, $case.caseId)
        if ($main -and [TargetRuleNative]::IsWindow([IntPtr][Int64]$main.hwnd) -and (Capture-HtsScreenshot $observationContext $main $candidateScreenshot)) {
            $screenshot = $candidateScreenshot
        }
    }
    $dialogsBeforeDismiss = if ($main) { @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret) } else { @() }
    if ($dialogsBeforeDismiss.Count -gt 0) {
        $dismissed = Dismiss-HtsDialogs $RuntimeContext $main $secret
        Add-HtsActionRecord $reportingContext $actions "dismissDialog" $(if ($dismissed -eq $dialogsBeforeDismiss.Count) { "PASS" } else { "PENDING" }) "HTS dialog" "후속 테스트를 위해 HTS 대화상자 $dismissed/$($dialogsBeforeDismiss.Count)개를 닫았습니다." $(if ($dismissed -eq $dialogsBeforeDismiss.Count) { "" } else { "DIALOG_DISMISS_PENDING" })
        if ($dismissed -ne $dialogsBeforeDismiss.Count) { $pendingReasons.Add("HTS 대화상자 닫기") }
    }
    $remainingDialogs = if ($main -and [TargetRuleNative]::IsWindow([IntPtr][Int64]$main.hwnd)) { @(Get-HtsDialogs $observationContext $RuntimeContext $main $secret) } else { @() }
    if ($existingScreenRequiredMissing) {
        Add-HtsActionRecord $reportingContext $actions 'closeScreen' 'PENDING' ([string]$case.screen.screenNumber) '연결된 대상 화면이 없어 화면 종료 동작을 수행하지 않았습니다.' 'EXISTING_SCREEN_REQUIRED'
    } elseif ($remainingDialogs.Count -gt 0) {
        Add-HtsActionRecord $reportingContext $actions "closeScreen" "PENDING" ([string]$case.screen.screenNumber) "모달 대화상자가 남아 있어 HTS 종료 위험을 피하도록 화면 닫기를 차단했습니다." "DIALOG_BLOCKS_SCREEN_CLOSE"
        $pendingReasons.Add("모달 대화상자 후 화면 닫기 차단")
    } elseif ($retainScenarioScreen -and (Test-HtsRequestedScreen $navigationContext $screen ([string]$case.screen.screenNumber))) {
        Add-HtsActionRecord $reportingContext $actions 'retainScreenForNextScenario' 'PASS' ([string]$case.screen.screenNumber) '같은 화면의 다음 시나리오 케이스를 위해 현재 화면을 유지했습니다.'
    } elseif ($PreserveTargetScreenAfterRun -and (Test-HtsRequestedScreen $navigationContext $screen ([string]$case.screen.screenNumber))) {
        Add-HtsActionRecord $reportingContext $actions 'preserveTargetScreenAfterRun' 'PASS' ([string]$case.screen.screenNumber) $(if($openedTargetScreenForRun){'자동화가 연 대상 화면을 후속 확인을 위해 닫지 않고 유지했습니다.'}else{'현재 대상 화면을 후속 확인을 위해 닫지 않고 유지했습니다.'})
    } elseif ($usedExistingTargetScreen -and (Test-PreservedTargetScreen $navigationContext (Find-ScreenWindow $navigationContext $main ([string]$case.screen.screenNumber)))) {
        Add-HtsActionRecord $reportingContext $actions 'preserveExistingScreen' 'PASS' ([string]$case.screen.screenNumber) '사용자가 미리 열어둔 화면이므로 테스트 종료 후에도 닫지 않고 유지했습니다.'
    } else {
        $screenToClose=if(Test-HtsRequestedScreen $navigationContext $screen ([string]$case.screen.screenNumber)){$screen}else{Find-ScreenWindow $navigationContext $main ([string]$case.screen.screenNumber)}
        if ($screenToClose) {
            if (Close-HtsScreen $navigationContext $screenToClose) {
                Add-HtsActionRecord $reportingContext $actions "closeScreen" "PASS" ([string]$case.screen.screenNumber) "테스트를 마친 화면을 의도적으로 닫았습니다."
            } else {
                Add-HtsActionRecord $reportingContext $actions "closeScreen" "PENDING" ([string]$case.screen.screenNumber) "테스트를 마친 화면을 닫지 못했습니다." "SCREEN_CLOSE_PENDING"
                $pendingReasons.Add("화면 닫기")
            }
        }
        if($main -and [TargetRuleNative]::IsWindow([IntPtr][Int64]$main.hwnd)){
            $siblingScreensClosed=Close-ExistingTargetScreens $navigationContext $main
            if($siblingScreensClosed -gt 0){Add-HtsActionRecord $reportingContext $actions 'closeSiblingScreens' 'PASS' 'HTS sibling windows' "테스트 중 새로 열린 형제·연계 내부 창 $siblingScreensClosed개를 함께 닫았습니다."}
            $remainingAfterClose=@(Get-HtsScreenWindows $navigationContext $main)
            if($remainingAfterClose.Count -gt 0){
                Add-HtsActionRecord $reportingContext $actions 'verifySequentialClose' 'PENDING' ([string]$case.screen.screenNumber) "번호 창 $($remainingAfterClose.Count)개가 남아 다음 화면 열기를 차단해야 합니다." 'SCREEN_SEQUENCE_CLOSE_PENDING'
                $pendingReasons.Add('순차 화면 닫기 미완료')
            }else{
                Add-HtsActionRecord $reportingContext $actions 'verifySequentialClose' 'PASS' ([string]$case.screen.screenNumber) '현재 화면과 연계 화면이 모두 닫혀 다음 화면을 열 수 있습니다.'
            }
        }
    }
    if ($PlanOnly -and $pendingReasons.Count -eq 0) { $pendingReasons.Add("계획 전용 실행") }
    $ended = Get-Date
    # 실행기는 사실만 Observation으로 기록하고 최종 상태는 Core ResultEvaluator 출력에서 복사한다.
    $actualCaseActionsExecuted = -not $PlanOnly -and (([int]$automationMetrics.FlaUiActionAttempts -gt $flaUiActionAttemptsBeforeCase) -or $observationContext.CurrentResultEvaluationCases.Count -gt 0)
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
        aggregateId=[string]$case.caseId;cases=@($observationContext.CurrentResultEvaluationCases.ToArray())
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
        interactionStrategy=[string]$targetRuleContext.CurrentInteractionStrategy
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
$inputAuditRows=if(Test-Path -LiteralPath $safetyContext.AuditPath){@([IO.File]::ReadAllLines($safetyContext.AuditPath,[Text.Encoding]::UTF8) | Where-Object {$_} | ForEach-Object {$_ | ConvertFrom-Json})}else{@()}
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
    preserveTargetScreenAfterRun=[bool]$PreserveTargetScreenAfterRun;visiblePointerMotion=[bool]$RuntimeContext.VisiblePointerMotion;pointerDwellMilliseconds=[int]$RuntimeContext.PointerDwellMilliseconds
    initialScreensClosed=$initialScreensClosed; initialScreensPreserved=$initialScreensPreserved; initialSearchOverlaysClosed=$initialSearchOverlaysClosed
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReportDir "summary.json") -Encoding UTF8

Stop-FlaUiBridge -Context $sessionContext
if (-not $SkipExcel) {
    Export-HtsRuleResultWorkbooks $reportingContext $ReportDir
}
Write-Output $ReportDir
