<#
.SYNOPSIS 실제 HTS 테스트 실행과 전체 HTS 창 녹화를 같은 시간축으로 감싼다.
.DESCRIPTION 권한 일치, 실행 완료 표식, 영상 검사, 오류 프레임 추출과 Excel 생성을 한 실행 폴더에 묶는다.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TestPackPath,
    [string]$SuiteDir = "",
    [string]$ScreensCsv = "",
    [string]$CaseIdsCsv = "",
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
    [switch]$ShowCursor,
    [switch]$SubmitTransactionalDialogs,
    [int]$MaxCases = 10000,
    [int]$MaxDurationSeconds = 1200,
    [double]$Fps = 2.0,
    [int]$ActionTimeoutSeconds = 1000,
    [switch]$PlanOnly,
    [switch]$RefreshPhysicalPlanBeforeRun,
    [switch]$AllowElevatedActionPrompt,
    [switch]$FailOnTestFailure,
    [switch]$KeepFrames
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "modules\pipeline-common.ps1")
$pipelineStatusModule = Join-Path $PSScriptRoot 'modules\pipeline-status.ps1'
. $pipelineStatusModule

# manifest는 녹화기와 실행기 연결을, targetContext는 대상별 창과 화면 범위를 제공한다.
$pipelineManifest = Get-RulePipelineManifest $root
$cliProject = Resolve-RulePath $root ([string]$pipelineManifest.cliProject)
$resolvedTestPackPath = Resolve-RulePath $root $TestPackPath
& dotnet run --project $cliProject -c Release --no-build -- validate-test-pack --file $resolvedTestPackPath | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'TestPack 무결성 또는 승인 검증에 실패했습니다.' }
$targetContext = Get-RuleTestPackContext $root $resolvedTestPackPath $ScreensCsv
$reportExporter = Get-RulePipelineEntryPoint $pipelineManifest $root 'reportExporter'
$tcReportExporter = Get-RulePipelineEntryPoint $pipelineManifest $root 'tcReportExporter'
$datasetPreflight = $targetContext.Dataset
$registeredScreens = @($datasetPreflight.screens | ForEach-Object { [string]$_.screenNumber })
if ($ScenarioPlanPath) {
    $resolvedScenarioPlanPath = if ([IO.Path]::IsPathRooted($ScenarioPlanPath)) { [IO.Path]::GetFullPath($ScenarioPlanPath) } else { [IO.Path]::GetFullPath((Join-Path $root $ScenarioPlanPath)) }
    if (-not (Test-Path -LiteralPath $resolvedScenarioPlanPath)) { throw "시나리오 계획을 찾을 수 없습니다: $resolvedScenarioPlanPath" }
    $scenarioPlanPreflight = Get-Content -LiteralPath $resolvedScenarioPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $registeredScreens = @($scenarioPlanPreflight.screens | ForEach-Object { [string]$_.screenNumber })
}
if ($PhysicalPlanPath) {
    $resolvedPhysicalPlanPath = if ([IO.Path]::IsPathRooted($PhysicalPlanPath)) { [IO.Path]::GetFullPath($PhysicalPlanPath) } else { [IO.Path]::GetFullPath((Join-Path $root $PhysicalPlanPath)) }
    if (-not (Test-Path -LiteralPath $resolvedPhysicalPlanPath)) { throw "물리 실행계획을 찾을 수 없습니다: $resolvedPhysicalPlanPath" }
}
if ($RefreshPhysicalPlanBeforeRun -and -not $ScenarioPlanPath) {
    throw '-RefreshPhysicalPlanBeforeRun에는 -ScenarioPlanPath가 필요합니다.'
}
if ($RefreshPhysicalPlanBeforeRun -and $PlanOnly) {
    throw '-RefreshPhysicalPlanBeforeRun과 -PlanOnly는 함께 사용할 수 없습니다.'
}
$requestedScreens = @($ScreensCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# 실행 식별자와 화면 범위를 기준으로 영상·JSON·Excel을 한 폴더에 묶는다.
$targetScreens = if ($requestedScreens.Count -gt 0) {
    @($registeredScreens | Where-Object { $requestedScreens -contains $_ })
} else {
    $registeredScreens
}
if ($targetScreens.Count -eq 0) {
    throw "데이터셋과 일치하는 대상 화면이 0건입니다. 등록 화면: $($registeredScreens -join ', ')"
}
if (-not $SuiteDir) {
    $SuiteDir = Join-Path (Join-Path $root "reports") ($targetContext.RunLabel + "-full-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
}
$SuiteDir = [IO.Path]::GetFullPath($SuiteDir)
New-Item -ItemType Directory -Force -Path $SuiteDir | Out-Null

$framesDir = Join-Path $SuiteDir "frames"
$video = Join-Path $SuiteDir "full-run.mp4"
$stopFile = Join-Path $SuiteDir "recording.stop"
$readyFile = Join-Path $SuiteDir "actions.start"
$marker = Join-Path $SuiteDir "실행완료.json"
$errorLog = Join-Path $SuiteDir "실행오류.txt"
$recordScript = Get-RulePipelineEntryPoint $pipelineManifest $root 'recorder'
$runner = Get-RulePipelineEntryPoint $pipelineManifest $root 'targetRunner'
$bindingPlanner = Join-Path $PSScriptRoot 'plan-scenario-bindings.ps1'
$reportDir = Join-Path $SuiteDir "results"

foreach ($path in @($stopFile, $readyFile, $marker, $errorLog)) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

# 녹화기와 액션 실행기는 별도 프로세스로 띄워 액션 실패 시에도 영상 종료 처리를 보장한다.
$recordCommand = @"
`$ErrorActionPreference = 'Stop'
& '$recordScript' -OutDir '$framesDir' -VideoOut '$video' -DurationSeconds $MaxDurationSeconds -Fps $Fps -StopFile '$stopFile' -WindowClass '$($targetContext.WindowClassName)' -WindowTitlePrefix '$($targetContext.WindowTitlePrefix)' $(if($ShowCursor){'-ShowCursor'}else{''})
"@
$recordEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($recordCommand))

$screensLiteral = "'" + ($ScreensCsv -replace "'", "''") + "'"
$caseIdsLiteral = "'" + ($CaseIdsCsv -replace "'", "''") + "'"
$testPackLiteral = "'" + ($resolvedTestPackPath -replace "'", "''") + "'"
$planOnlyArgument = if ($PlanOnly) { "-PlanOnly" } else { "" }
$scenarioPlanArgument = if ($ScenarioPlanPath) { "-ScenarioPlanPath '" + ($resolvedScenarioPlanPath -replace "'", "''") + "'" } else { "" }
$physicalPlanArgument = if ($PhysicalPlanPath) { "-PhysicalPlanPath '" + ($resolvedPhysicalPlanPath -replace "'", "''") + "'" } else { "" }
$partialPlanArgument = if ($AllowPartialScenarioPlan) { "-AllowPartialScenarioPlan" } else { "" }
$reuseExistingTargetScreenArgument = if ($ReuseExistingTargetScreen) { "-ReuseExistingTargetScreen" } else { "" }
$requireExistingTargetScreenArgument = if ($RequireExistingTargetScreen) { "-RequireExistingTargetScreen" } else { "" }
$preserveTargetScreenAfterRunArgument = if ($PreserveTargetScreenAfterRun) { "-PreserveTargetScreenAfterRun" } else { "" }
$visiblePointerMotionArgument = if ($VisiblePointerMotion) { "-VisiblePointerMotion" } else { "" }
$submitTransactionalDialogsArgument = if ($SubmitTransactionalDialogs) { "-SubmitTransactionalDialogs" } else { "" }
$pointerDwellArgument = "-PointerDwellMilliseconds $PointerDwellMilliseconds"
$refreshPhysicalPlanBlock = if ($RefreshPhysicalPlanBeforeRun) {
@"
  `$bindingDiscoveryDir = Join-Path '$SuiteDir' 'binding-discovery'
  `$refreshedBindingDir = Join-Path '$SuiteDir' 'refreshed-binding-plan'
  & '$runner' -TestPackPath $testPackLiteral -ReportDir `$bindingDiscoveryDir -ScreensCsv $screensLiteral -CaseIdsCsv $caseIdsLiteral -MaxCases $MaxCases -SkipExcel -PlanOnly -ScenarioPlanPath '$resolvedScenarioPlanPath' -AllowPartialScenarioPlan $reuseExistingTargetScreenArgument $requireExistingTargetScreenArgument $preserveTargetScreenAfterRunArgument | Out-Null
  `$discoverySummaryPath = Join-Path `$bindingDiscoveryDir 'summary.json'
  `$discoveryControlPlanPath = Join-Path `$bindingDiscoveryDir 'control-plan.json'
  if (-not (Test-Path -LiteralPath `$discoverySummaryPath) -or -not (Test-Path -LiteralPath `$discoveryControlPlanPath)) {
    throw '실행 직전 MAP+Runtime 재탐색 산출물이 생성되지 않았습니다.'
  }
  `$discoverySummary = Get-Content -LiteralPath `$discoverySummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([int]`$discoverySummary.total -le 0) { throw '실행 직전 MAP+Runtime 재탐색 결과가 0건입니다.' }
  `$discoveryRows = @(Get-Content -LiteralPath `$discoveryControlPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json)
  `$bindingEvidenceFields = @('mapGeometryDelta','mapGeometryExact','mapHostRequired','mapHostMatched','mapHostId','runtimeIdentityUnique','allowOwnerDrawnKindOverride')
  `$bindingEvidenceViolations = @(`$discoveryRows | ForEach-Object { @(`$_.discoveredControls) } |
    Where-Object { [string]`$_.definitionSource -eq 'MAP+Runtime' } | ForEach-Object {
      `$runtimeControl = `$_
      `$missingFields = @(`$bindingEvidenceFields | Where-Object { `$runtimeControl.PSObject.Properties.Name -notcontains `$_ })
      if (`$missingFields.Count -gt 0) { "`$([string]`$runtimeControl.controlId):`$(`$missingFields -join ',')" }
    })
  if (`$bindingEvidenceViolations.Count -gt 0) {
    throw "MAP+Runtime 바인딩 증거 직렬화 계약이 누락되었습니다: `$(`$bindingEvidenceViolations -join ' | ')"
  }
  & '$bindingPlanner' -CompiledPlanPath '$resolvedScenarioPlanPath' -TestPackPath $testPackLiteral -ReportDir `$refreshedBindingDir -ScreensCsv $screensLiteral -RuntimeControlPlanPath (Join-Path `$bindingDiscoveryDir 'control-plan.json') -RuntimeSummaryPath (Join-Path `$bindingDiscoveryDir 'summary.json') | Out-Null
  `$effectivePhysicalPlanPath = Join-Path `$refreshedBindingDir 'physical-plan.json'
  if (-not (Test-Path -LiteralPath `$effectivePhysicalPlanPath)) { throw '실행 직전 물리 바인딩 계획이 생성되지 않았습니다.' }
  `$refreshedPhysicalPlan = Get-Content -LiteralPath `$effectivePhysicalPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
  `$requestedCaseIds = @($caseIdsLiteral -split ',' | ForEach-Object { `$_.Trim() } | Where-Object { `$_ })
  `$unresolvedCaseIds = @(`$requestedCaseIds | Where-Object { `$refreshedPhysicalPlan.executableCaseIds -notcontains `$_ })
  if (`$unresolvedCaseIds.Count -gt 0) {
    `$blocked = @(`$refreshedPhysicalPlan.scenarioDispositions | Where-Object { `$_.status -ne 'READY' } | Select-Object -First 12)
    throw "재탐색 후에도 실행 가능한 물리 바인딩이 없는 케이스입니다: `$(`$unresolvedCaseIds -join ', '). 차단 근거: `$(@(`$blocked.reasons) -join ' | ')"
  }
"@
} else {
    $effectivePath = if ($PhysicalPlanPath) { $resolvedPhysicalPlanPath } else { '' }
    "  `$effectivePhysicalPlanPath = '" + ($effectivePath -replace "'", "''") + "'"
}
$refreshFlagText = if ($RefreshPhysicalPlanBeforeRun) { 'true' } else { 'false' }
$pipelineStatusModuleLiteral = $pipelineStatusModule -replace "'", "''"
$actionCommand = @"
`$ErrorActionPreference = 'Stop'
    . '$pipelineStatusModuleLiteral'
`$runSummary = `$null
`$actualScenarioActionsExecuted = `$false
try {
    # HTS와 권한 수준이 맞아야 UI 메시지와 입력을 전달할 수 있으므로 필요할 때만 액션 프로세스를 승격한다.
  while (-not (Test-Path -LiteralPath '$readyFile')) { Start-Sleep -Milliseconds 200 }
$refreshPhysicalPlanBlock
  `$runParams = @{
    TestPackPath = $testPackLiteral
    ReportDir = '$reportDir'
    ScreensCsv = $screensLiteral
    CaseIdsCsv = $caseIdsLiteral
    MaxCases = $MaxCases
    SkipExcel = `$true
    PointerDwellMilliseconds = $PointerDwellMilliseconds
    OrderTabStateOverride = '$OrderTabStateOverride'
  }
  if ('$resolvedScenarioPlanPath') { `$runParams.ScenarioPlanPath = '$resolvedScenarioPlanPath' }
  if (`$effectivePhysicalPlanPath) { `$runParams.PhysicalPlanPath = `$effectivePhysicalPlanPath }
  if ('$partialPlanArgument') { `$runParams.AllowPartialScenarioPlan = `$true }
  if ('$planOnlyArgument') { `$runParams.PlanOnly = `$true }
  if ('$reuseExistingTargetScreenArgument') { `$runParams.ReuseExistingTargetScreen = `$true }
  if ('$requireExistingTargetScreenArgument') { `$runParams.RequireExistingTargetScreen = `$true }
  if ('$preserveTargetScreenAfterRunArgument') { `$runParams.PreserveTargetScreenAfterRun = `$true }
  if ('$visiblePointerMotionArgument') { `$runParams.VisiblePointerMotion = `$true }
  if ('$submitTransactionalDialogsArgument') { `$runParams.SubmitTransactionalDialogs = `$true }
  & '$runner' @runParams | Out-Null
  `$runSummaryPath = Join-Path '$reportDir' 'summary.json'
  if (-not (Test-Path -LiteralPath `$runSummaryPath)) { throw '대상 화면 룰 기반 실행 결과가 생성되지 않았습니다.' }
  `$runSummary=Get-Content -LiteralPath `$runSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([int]`$runSummary.total -le 0) { throw '대상 테스트 케이스가 0건이어서 실행을 완료 처리할 수 없습니다.' }
  `$actualScenarioActionsExecuted = Get-RuleActualScenarioActionsExecuted -Summary `$runSummary
  `$actionState = Resolve-RulePipelineState -Status 'DONE' -TestStatus ([string]`$runSummary.status) -ActualScenarioActionsExecuted `$actualScenarioActionsExecuted
  `$datasetLabel=([string]`$runSummary.datasetId -replace '[<>:"/\\|?*]','-' -replace '\s+','-').Trim('-')
  `$runLabel=([string]`$runSummary.runId -replace '[<>:"/\\|?*]','-' -replace '\s+','-').Trim('-')
  `$workbookName="테스트결과-`$datasetLabel-`$runLabel.xlsx"
  [pscustomobject]@{
    status=`$actionState.Status
    pipelineStatus=`$actionState.PipelineStatus
    pipelineCompleted=`$actionState.PipelineCompleted
    testStatus=`$actionState.TestStatus
    testPassed=`$actionState.TestPassed
    actualScenarioActionsExecuted=`$actionState.ActualScenarioActionsExecuted
    message='대상 화면 룰 기반 테스트 프로세스와 결과 저장을 완료했습니다.'
    reportDir='$reportDir'
    summary=(Join-Path '$reportDir' 'summary.json')
    workbook=(Join-Path '$reportDir' `$workbookName)
    physicalPlan=`$effectivePhysicalPlanPath
    physicalPlanRefreshed='$refreshFlagText'
    finishedAt=(Get-Date).ToString('o')
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath '$marker' -Encoding UTF8
} catch {
  `$actionError = `$_
  if (-not `$runSummary -and (Test-Path -LiteralPath (Join-Path '$reportDir' 'summary.json'))) {
    try { `$runSummary = Get-Content -LiteralPath (Join-Path '$reportDir' 'summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  }
  `$actualScenarioActionsExecuted = Get-RuleActualScenarioActionsExecuted -RecordedValue `$actualScenarioActionsExecuted -Summary `$runSummary
  `$observedTestStatus = if (`$runSummary -and [string]`$runSummary.status -in @('PASS','FAIL','ERROR','PENDING')) { [string]`$runSummary.status } else { 'PENDING' }
  `$actionState = Resolve-RulePipelineState -Status 'ERROR' -TestStatus `$observedTestStatus -ActualScenarioActionsExecuted `$actualScenarioActionsExecuted
  `$actionError.Exception.ToString() | Set-Content -LiteralPath '$errorLog' -Encoding UTF8
  [pscustomobject]@{
    status=`$actionState.Status; pipelineStatus=`$actionState.PipelineStatus; pipelineCompleted=`$actionState.PipelineCompleted
    testStatus=`$actionState.TestStatus; testPassed=`$actionState.TestPassed; actualScenarioActionsExecuted=`$actionState.ActualScenarioActionsExecuted
    message='대상 화면 룰 기반 테스트 실행 중 오류가 발생했습니다.'; error=`$actionError.Exception.Message; finishedAt=(Get-Date).ToString('o')
  } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath '$marker' -Encoding UTF8
}
"@
$actionCommandPath = Join-Path $SuiteDir 'action-command.ps1'
$actionTokens = $null
$actionErrors = $null
[void][Management.Automation.Language.Parser]::ParseInput($actionCommand,[ref]$actionTokens,[ref]$actionErrors)
if (@($actionErrors).Count -gt 0) {
    throw "생성된 관리자 실행 명령에 구문 오류가 있습니다: $(@($actionErrors.Message) -join ' | ')"
}
$actionCommand | Set-Content -LiteralPath $actionCommandPath -Encoding UTF8
$actionEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($actionCommand))

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$recorder = $null
$action = $null
$launchError = ""
$timedOut = $false

try {
    $actionAllowed = $isAdmin -or $AllowElevatedActionPrompt
    if (-not $actionAllowed) {
        [pscustomobject]@{
            status='PENDING_ADMIN_RUNNER_REQUIRED'
            message='HTS와 같은 권한의 실행기가 필요합니다. -AllowElevatedActionPrompt 옵션으로 다시 실행하고 UAC를 승인하세요.'
            finishedAt=(Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $marker -Encoding UTF8
    }

    if ($actionAllowed) {
        # 녹화기를 먼저 준비해 액션 시작 뒤 녹화 실패로 대기 프로세스가 남는 것을 방지한다.
        $recorder = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $recordEncoded
        ) -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 3

        if ($isAdmin) {
            $action = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $actionEncoded) -WindowStyle Hidden -PassThru
        } else {
            $powershellExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
            $action = Start-Process -FilePath $powershellExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-EncodedCommand", $actionEncoded) -Verb RunAs -WindowStyle Hidden -PassThru
        }

        "start" | Set-Content -LiteralPath $readyFile -Encoding ASCII
    }

    $deadline = (Get-Date).AddSeconds($ActionTimeoutSeconds)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $marker)) {
        Start-Sleep -Seconds 3
    }
    $timedOut = -not (Test-Path -LiteralPath $marker)
} catch {
    $launchError = $_.Exception.Message
    $_.Exception.ToString() | Set-Content -LiteralPath $errorLog -Encoding UTF8
    $launchStatus = if ($launchError -match 'canceled by the user|사용자가.*취소') { 'PENDING_ADMIN_APPROVAL_DECLINED' } else { 'LAUNCH_ERROR' }
    $launchMessage = if ($launchStatus -eq 'PENDING_ADMIN_APPROVAL_DECLINED') { '관리자 권한 HTS 접근 승인이 취소되어 테스트를 시작하지 않았습니다.' } else { '녹화 실행을 시작하지 못했습니다.' }
    [pscustomobject]@{ status=$launchStatus; message=$launchMessage; error=$launchError; finishedAt=(Get-Date).ToString('o') } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $marker -Encoding UTF8
} finally {
    "stop" | Set-Content -LiteralPath $stopFile -Encoding ASCII
    if ($recorder) {
        $recorder.WaitForExit([Math]::Max(30000, ($MaxDurationSeconds + 60) * 1000)) | Out-Null
        if (-not $recorder.HasExited) { $recorder.Kill() }
    }
}

# 실행 종료 후 영상 자체를 검사하고, 오류 행에 즉시 캡처가 없으면 해당 시점의 영상 프레임을 증거로 보완한다.
$actionDone = $null
$actionMarkerReadError = ''
if (Test-Path -LiteralPath $marker) {
    try { $actionDone = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch {
        $actionMarkerReadError = $_.Exception.Message
        $_.Exception.ToString() | Set-Content -LiteralPath (Join-Path $SuiteDir '실행완료표식읽기오류.txt') -Encoding UTF8
    }
}
$videoInspection = @("영상 파일이 생성되지 않았습니다.")
$videoOk = $false
if (Test-Path -LiteralPath $video) {
    $videoInspection = & python (Join-Path $root "tools\inspect_video.py") $video 2>&1
    $videoOk = $LASTEXITCODE -eq 0
}

# 실행기 감사 좌표와 DPI-aware 녹화기가 본 실제 커서 위치를 독립적으로 대조한다.
$cursorTracePath = Join-Path $SuiteDir 'cursor-trace.ndjson'
$cursorAuditVerificationPath = Join-Path $SuiteDir 'cursor-audit-verification.json'
$cursorAuditVerification = [pscustomobject]@{status='NOT_APPLICABLE';clicks=0;matched=0;failures=@();traceRows=0;maxTimeDeltaMs=750;maxDistancePx=4}
$cursorAuditOk = $true
$inputAuditPath = Join-Path $reportDir 'input-boundary-audit.ndjson'
if (Test-Path -LiteralPath $inputAuditPath) {
    $clickAudits = @([IO.File]::ReadAllLines($inputAuditPath,[Text.Encoding]::UTF8) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object { [string]$_.inputType -eq 'MouseClick' -and [string]$_.status -eq 'ALLOWED' })
    if ($clickAudits.Count -gt 0) {
        $cursorAuditOk = $false
        $cursorTraceRows = if (Test-Path -LiteralPath $cursorTracePath) {
            @([IO.File]::ReadAllLines($cursorTracePath,[Text.Encoding]::UTF8) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        } else { @() }
        $cursorFailures = New-Object Collections.Generic.List[object]
        $cursorMatches = 0
        foreach ($clickAudit in $clickAudits) {
            $clickAt = [DateTimeOffset]::Parse([string]$clickAudit.timestamp)
            $nearest = @($cursorTraceRows | ForEach-Object {
                $traceAt = [DateTimeOffset]::Parse([string]$_.timestamp)
                [pscustomobject]@{row=$_;deltaMs=[Math]::Abs(($traceAt-$clickAt).TotalMilliseconds)}
            } | Sort-Object deltaMs | Select-Object -First 1)
            if ($nearest.Count -eq 0) {
                $cursorFailures.Add([pscustomobject]@{timestamp=$clickAudit.timestamp;reason='CURSOR_TRACE_MISSING';expectedX=[int]$clickAudit.x;expectedY=[int]$clickAudit.y})
                continue
            }
            $trace = $nearest[0].row
            $dx = [int]$trace.x-[int]$clickAudit.x
            $dy = [int]$trace.y-[int]$clickAudit.y
            $distance = [Math]::Sqrt(($dx*$dx)+($dy*$dy))
            if ([double]$nearest[0].deltaMs -le 750 -and $distance -le 4 -and [bool]$trace.insideCapture) {
                $cursorMatches++
            } else {
                $cursorFailures.Add([pscustomobject]@{
                    timestamp=$clickAudit.timestamp;reason='CURSOR_AUDIT_MISMATCH';expectedX=[int]$clickAudit.x;expectedY=[int]$clickAudit.y
                    observedX=[int]$trace.x;observedY=[int]$trace.y;distancePx=[Math]::Round($distance,2);timeDeltaMs=[Math]::Round([double]$nearest[0].deltaMs,2)
                    traceFrame=[int]$trace.frame;insideCapture=[bool]$trace.insideCapture
                })
            }
        }
        $cursorAuditOk = $cursorFailures.Count -eq 0 -and $cursorMatches -eq $clickAudits.Count
        $cursorAuditVerification = [pscustomobject]@{
            status=$(if($cursorAuditOk){'PASS'}else{'FAIL'});clicks=$clickAudits.Count;matched=$cursorMatches;failures=$cursorFailures.ToArray()
            traceRows=$cursorTraceRows.Count;maxTimeDeltaMs=750;maxDistancePx=4
        }
    } else {
        $cursorAuditVerification = [pscustomobject]@{status='PASS';clicks=0;matched=0;failures=@();traceRows=0;maxTimeDeltaMs=750;maxDistancePx=4}
    }
}
$cursorAuditVerification | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $cursorAuditVerificationPath -Encoding UTF8

$videoFallbackScreenshots = 0
$videoFallbackScreenshotError = ""
$caseResultsPath = Join-Path $reportDir "case-results.json"
$recordingMetadataPath = Join-Path $SuiteDir "recording.done.json"
if ($videoOk -and (Test-Path -LiteralPath $caseResultsPath) -and (Test-Path -LiteralPath $recordingMetadataPath)) {
    try {
        $recordingMetadata = Get-Content -LiteralPath $recordingMetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($recordingMetadata.startedAt -and [int]$recordingMetadata.frames -gt 0 -and [double]$recordingMetadata.fps -gt 0) {
            $recordingStartedAt = [DateTimeOffset]::Parse([string]$recordingMetadata.startedAt)
            $caseRows = @(Get-Content -LiteralPath $caseResultsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            $screenshotsDir = Join-Path $reportDir "screenshots"
            New-Item -ItemType Directory -Force -Path $screenshotsDir | Out-Null
            $changed = $false
            foreach ($caseRow in @($caseRows | Where-Object { $_.status -in @("FAIL", "ERROR") -and -not [string]$_.screenshotPath })) {
                $caseEndedAt = [DateTimeOffset]::Parse([string]$caseRow.endedAt)
                $seconds = [Math]::Max(0, ($caseEndedAt - $recordingStartedAt).TotalSeconds)
                $frameIndex = [Math]::Min([int]$recordingMetadata.frames - 1, [Math]::Max(0, [int][Math]::Floor($seconds * [double]$recordingMetadata.fps)))
                & python (Join-Path $root "tools\extract_video_frames.py") $video $screenshotsDir $frameIndex | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "오류 시점 영상 프레임 $frameIndex 추출에 실패했습니다." }
                $extracted = Join-Path $screenshotsDir ("frame_{0:D6}.png" -f $frameIndex)
                if (-not (Test-Path -LiteralPath $extracted)) { throw "추출된 오류 프레임을 찾을 수 없습니다: $extracted" }
                $safeCaseId = ([string]$caseRow.caseId -replace '[^A-Za-z0-9_-]', '-')
                $fileName = "error-$([string]$caseRow.screenNumber)-$safeCaseId-video.png"
                $destination = Join-Path $screenshotsDir $fileName
                Move-Item -LiteralPath $extracted -Destination $destination -Force
                $caseRow.screenshotPath = "screenshots\$fileName"
                $videoFallbackScreenshots++
                $changed = $true
            }
            if ($changed) {
                @($caseRows) | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $caseResultsPath -Encoding UTF8
            }
        }
    } catch {
        $videoFallbackScreenshotError = $_.Exception.Message
        $_.Exception.ToString() | Set-Content -LiteralPath (Join-Path $SuiteDir "영상오류스크린샷추출오류.txt") -Encoding UTF8
    }
}

# JSON 결과가 존재할 때만 Excel 변환을 수행하며 실패는 테스트 PASS와 분리된 리포트 오류로 기록한다.
$excelStatus = "PENDING"
$excelError = ""
$workbookPath = ""
$tcWorkbookPath = ""
if ((Test-Path -LiteralPath (Join-Path $reportDir "summary.json")) -and (Test-Path -LiteralPath (Join-Path $reportDir "case-results.json"))) {
    try {
        $excelOutput = @(& $reportExporter -ReportDir $reportDir)
        # 호출된 PowerShell 스크립트가 내부에서 실행한 외부 프로세스의 LASTEXITCODE는
        # 성공 반환 뒤에도 남을 수 있으므로 반환 경로와 실제 파일 크기로 성공을 판정한다.
        $workbookPath = [string]($excelOutput | Where-Object {
            $_ -and (Test-Path -LiteralPath $_) -and (Get-Item -LiteralPath $_).Length -gt 0
        } | Select-Object -Last 1)
        if (-not $workbookPath) { throw "식별 가능한 이름의 엑셀 파일을 찾지 못했습니다." }
        $tcRows = @(Get-Content -LiteralPath (Join-Path $reportDir 'case-results.json') -Raw -Encoding UTF8 | ConvertFrom-Json | Where-Object { [string]$_.sourceTestCaseId })
        if ($tcRows.Count -gt 0 -or (Test-Path -LiteralPath (Join-Path $reportDir 'compiled-plan.json'))) {
            $tcExcelOutput = @(& $tcReportExporter -ReportDir $reportDir)
            $tcWorkbookPath = [string]($tcExcelOutput | Where-Object {
                $_ -and (Test-Path -LiteralPath $_) -and (Get-Item -LiteralPath $_).Length -gt 0
            } | Select-Object -Last 1)
            if (-not $tcWorkbookPath) { throw "TC_ID 중심 엑셀 파일을 찾지 못했습니다." }
        }
        $excelStatus = "DONE"
    } catch {
        $excelStatus = "ERROR"
        $excelError = $_.Exception.Message
        $_.Exception.ToString() | Set-Content -LiteralPath (Join-Path $SuiteDir "엑셀생성오류.txt") -Encoding UTF8
    }
}

# 인코딩 성공이 확인된 뒤에만 원본 프레임을 지우고, 삭제 대상이 실행 폴더 내부인지 재검증한다.
if (-not $KeepFrames -and $videoOk -and (Test-Path -LiteralPath $framesDir)) {
    $resolvedSuite = [IO.Path]::GetFullPath($SuiteDir).TrimEnd('\') + '\'
    $resolvedFrames = [IO.Path]::GetFullPath($framesDir)
    if (-not $resolvedFrames.StartsWith($resolvedSuite, [StringComparison]::OrdinalIgnoreCase)) {
        throw "녹화 프레임 폴더가 실행 폴더 밖에 있어 정리를 중단했습니다: $resolvedFrames"
    }
    Remove-Item -LiteralPath $resolvedFrames -Recurse -Force
}

# 액션·영상·Excel 증거를 공통 상태 계약에 전달해 파이프라인 완료와 테스트 결과를 독립 계산한다.
$summary = $null
$summaryReadError = ''
if (Test-Path -LiteralPath (Join-Path $reportDir "summary.json")) {
    try { $summary = Get-Content -LiteralPath (Join-Path $reportDir "summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $summaryReadError = $_.Exception.Message }
}
$actionStatus = if ($actionDone -and $actionDone.status) { [string]$actionDone.status } else { "" }
$testStatus = if ($summary -and $summary.status) { [string]$summary.status } else { "" }
$actualScenarioActionsExecuted = Get-RuleActualScenarioActionsExecuted -RecordedValue $actionDone.actualScenarioActionsExecuted -Summary $summary
$pipelineState = Resolve-RuleRecordedPipelineState `
    -ActionStatus $actionStatus `
    -TestStatus $testStatus `
    -HasSummary ([bool]$summary) `
    -TotalTests $(if ($summary) { [int]$summary.total } else { 0 }) `
    -VideoOk $videoOk `
    -CursorAuditOk $cursorAuditOk `
    -ExcelStatus $excelStatus `
    -LaunchError $launchError `
    -TimedOut $timedOut `
    -ActualScenarioActionsExecuted $actualScenarioActionsExecuted

[pscustomobject]@{
    status = $pipelineState.Status
    pipelineStatus = $pipelineState.PipelineStatus
    pipelineCompleted = $pipelineState.PipelineCompleted
    testStatus = $pipelineState.TestStatus
    testPassed = $pipelineState.TestPassed
    actualScenarioActionsExecuted = $pipelineState.ActualScenarioActionsExecuted
    message = Get-RulePipelineStatusMessage $pipelineState.Status
    testPackId = [string]$targetContext.TestPack.testPackId
    testPackPath = $resolvedTestPackPath
    suiteDir = $SuiteDir
    reportDir = $reportDir
    workbook = $workbookPath
    tcWorkbook = $tcWorkbookPath
    video = $video
    actionSummary = $summary
    actionDone = [bool]$actionDone
    recordingDone = Test-Path -LiteralPath (Join-Path $SuiteDir "recording.done.json")
    excelStatus = $excelStatus
    excelError = $excelError
    actionMarkerReadError = $actionMarkerReadError
    summaryReadError = $summaryReadError
    actionsTimedOut = $timedOut
    videoInspection = @($videoInspection)
    cursorAudit = $cursorAuditVerification
    cursorAuditVerification = $cursorAuditVerificationPath
    videoFallbackScreenshots = $videoFallbackScreenshots
    videoFallbackScreenshotError = $videoFallbackScreenshotError
    framesKept = [bool]$KeepFrames
    finishedAt = (Get-Date).ToString("o")
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $SuiteDir "녹화실행완료.json") -Encoding UTF8

Write-Output $SuiteDir
if (-not $pipelineState.PipelineCompleted) {
    exit 1
}
if ($FailOnTestFailure -and $pipelineState.TestStatus -ne 'PASS') { exit 2 }
