<# .SYNOPSIS Fake and source-contract regression tests for the rule-suite lifecycle modules. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\report-sanitization.ps1')
. (Join-Path $root 'scripts\modules\hts-reporting.ps1')
. (Join-Path $root 'scripts\modules\hts-rule-suite-context-factory.ps1')
. (Join-Path $root 'scripts\modules\hts-rule-suite-mode-router.ps1')
. (Join-Path $root 'scripts\modules\hts-screen-runner.ps1')
. (Join-Path $root 'scripts\modules\hts-run-result-finalizer.ps1')
. (Join-Path $root 'scripts\modules\hts-run-cleanup.ps1')

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERT_TRUE failed: $Message" }; $script:assertions++ }
function Assert-Equal($Expected, $Actual, [string]$Message) { if ([string]$Expected -ne [string]$Actual) { throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'" }; $script:assertions++ }

function New-FakeModeSpec([string]$Mode) {
    [pscustomobject]@{ Input = [pscustomobject]@{ DryRun = $Mode -eq 'DryRun'; PlanOnly = $Mode -eq 'PlanOnly' } }
}

function New-FakeModeState {
    [pscustomobject]@{ Mode = ''; UiActionCount = 0; TransactionalActionCount = 0 }
}

$script:assertions = 0
$constructorSpec = [pscustomobject]@{
    RuntimeContext = [pscustomobject]@{ name = 'fake-runtime' }
    ReportExporter = 'fake-report-exporter'
    TcReportExporter = 'fake-tc-exporter'
    ExecutionTracePath = 'fake-trace.ndjson'
    ReportDir = [IO.Path]::GetTempPath()
    Input = [pscustomobject]@{ DryRun = $true; PlanOnly = $false }
}
$constructorState = New-HtsRuleSuiteRunState -RunSpec $constructorSpec
$constructorServices = New-HtsRuleSuiteRunServices -RunSpec $constructorSpec
Assert-Equal 'DryRun' $constructorState.Mode 'RunState records the selected mode without UI initialization'
Assert-True ($constructorState.ActionEvidence -is [Collections.Generic.List[object]]) 'RunState owns an explicit action evidence collection'
Assert-True ($constructorState.CheckpointEvidence -is [Collections.Generic.List[object]]) 'RunState owns a separate checkpoint evidence collection'
Assert-Equal 'fake-runtime' $constructorServices.RuntimeContext.name 'RunServices carries the injected runtime contract'
Assert-True ($null -eq $constructorServices.SessionContext) 'base RunServices defers session creation until non-DryRun routing'

$script:evaluatorInvocation = $null
function Invoke-RuleResultEvaluation {
    param($CliProject, $TestPackPath, $EvaluationDocument, $WorkingDirectory, $InvocationId)
    $script:evaluatorInvocation = [pscustomobject]@{
        CliProject = $CliProject
        TestPackPath = $TestPackPath
        EvaluationDocument = $EvaluationDocument
        WorkingDirectory = $WorkingDirectory
        InvocationId = $InvocationId
    }
    [pscustomobject]@{ overallResult = [pscustomobject]@{ status = 'PENDING' } }
}
$evaluationSpec = [pscustomobject]@{
    CliProject = 'fake-cli'
    ResultEvaluationTestPackPath = 'fake-approved-pack.json'
    ResultEvaluationWorkingDirectory = 'fake-evaluation'
}
$evaluationDocument = [pscustomobject]@{ schemaVersion = '1.0'; aggregateId = 'fake-evaluation' }
$evaluationOutput = Invoke-HtsRuleSuiteEvaluation -RunSpec $evaluationSpec -EvaluationDocument $evaluationDocument -InvocationId 'fake-invocation'
Assert-Equal 'fake-cli' $script:evaluatorInvocation.CliProject 'finalizer adapter supplies the configured CLI project'
Assert-Equal 'fake-approved-pack.json' $script:evaluatorInvocation.TestPackPath 'finalizer adapter supplies the approved TestPack'
Assert-True ([object]::ReferenceEquals($evaluationDocument, $script:evaluatorInvocation.EvaluationDocument)) 'finalizer forwards the raw evaluation document without rewriting it'
Assert-Equal 'fake-evaluation' $script:evaluatorInvocation.WorkingDirectory 'finalizer supplies the isolated evaluation path'
Assert-Equal 'fake-invocation' $script:evaluatorInvocation.InvocationId 'finalizer preserves the evaluator invocation identity'
Assert-Equal 'PENDING' $evaluationOutput.overallResult.status 'finalizer returns the canonical evaluator result unchanged'

$services = [pscustomobject]@{}
foreach ($mode in @('DryRun', 'PlanOnly', 'Execute')) {
    $calls = New-Object Collections.Generic.List[string]
    $state = New-FakeModeState
    [void](Invoke-HtsRuleSuiteMode -RunSpec (New-FakeModeSpec $mode) -RunServices $services -RunState $state `
        -DryRunCoordinator { param($spec, $svc, $run) $calls.Add('dry') } `
        -InitializeRuntime { param($spec, $svc, $run) $calls.Add('init') } `
        -PlanOnlyCoordinator { param($spec, $svc, $run) $calls.Add('plan') } `
        -ExecuteCoordinator { param($spec, $svc, $run) $calls.Add('execute') })
    $expected = switch ($mode) { 'DryRun' { 'dry' } 'PlanOnly' { 'init|plan' } default { 'init|execute' } }
    Assert-Equal $expected ($calls -join '|') "$mode routes only through its coordinator"
    Assert-Equal $mode $state.Mode "$mode is recorded in RunState"
    if ($mode -in @('DryRun', 'PlanOnly')) {
        Assert-Equal 0 $state.UiActionCount "$mode fake sends no UI action"
        Assert-Equal 0 $state.TransactionalActionCount "$mode fake sends no transactional action"
    }
}

$cases = @(
    [pscustomobject]@{ caseId = 'A-1'; screen = [pscustomobject]@{ screenNumber = 'A' } },
    [pscustomobject]@{ caseId = 'A-2'; screen = [pscustomobject]@{ screenNumber = 'A' } },
    [pscustomobject]@{ caseId = 'B-1'; screen = [pscustomobject]@{ screenNumber = 'B' } }
)
$sequence = New-Object Collections.Generic.List[string]
Invoke-HtsScreenCaseSequence -Cases $cases `
    -OpenScreen { param($screen) $sequence.Add("open:$screen") } `
    -RunCase { param($case) $sequence.Add("case:$($case.caseId)") } `
    -CloseScreen { param($screen) $sequence.Add("close:$screen") }
Assert-Equal 'open:A|case:A-1|case:A-2|close:A|open:B|case:B-1|close:B' ($sequence -join '|') 'screen order, consecutive cases, and close timing stay deterministic'

$exceptionSequence = New-Object Collections.Generic.List[string]
$caught = $false
try {
    Invoke-HtsScreenCaseSequence -Cases @($cases[0]) `
        -OpenScreen { param($screen) $exceptionSequence.Add("open:$screen") } `
        -RunCase { param($case) $exceptionSequence.Add('case:throw'); throw 'fake case failure' } `
        -CloseScreen { param($screen) $exceptionSequence.Add("close:$screen") }
} catch { $caught = $true }
Assert-True $caught 'fake case exception remains observable'
Assert-Equal 'open:A|case:throw|close:A' ($exceptionSequence -join '|') 'screen cleanup runs after a case exception'

$cleanupCalls = New-Object Collections.Generic.List[string]
$actionEvidence = New-Object Collections.Generic.List[object]
$actionEvidence.Add([pscustomobject]@{ action = 'delivered'; status = 'PASS' })
$cleanupState = [pscustomobject]@{
    CleanupAttempted = $false; CleanupSucceeded = $false; CleanupErrors = (New-Object Collections.Generic.List[string])
    UiActionCount = 1; ActionEvidence = $actionEvidence
}
$cleanupServices = [pscustomobject]@{
    SessionContext = [pscustomobject]@{ id = 'fake' }
    AutomationMetrics = [pscustomobject]@{ FlaUiActionAttempts = 1 }
    Cleanup = [pscustomobject]@{ StopBridge = { param($context) $cleanupCalls.Add([string]$context.id) } }
}
[void](Invoke-HtsRuleSuiteCleanup -RunServices $cleanupServices -RunState $cleanupState)
Assert-True $cleanupState.CleanupAttempted 'cleanup attempt is recorded'
Assert-True $cleanupState.CleanupSucceeded 'successful fake cleanup is separated from verdict'
Assert-Equal 'fake' ($cleanupCalls -join '|') 'cleanup uses the injected session dependency'
Assert-Equal 1 $cleanupState.ActionEvidence.Count 'cleanup preserves action delivery evidence'
Assert-Equal 1 $cleanupState.UiActionCount 'cleanup preserves the executed UI action count'

$failedCleanupEvidence = New-Object Collections.Generic.List[object]
$failedCleanupEvidence.Add([pscustomobject]@{ action = 'attempted-before-error' })
$failedCleanupState = [pscustomobject]@{
    CleanupAttempted = $false; CleanupSucceeded = $true; CleanupErrors = (New-Object Collections.Generic.List[string])
    UiActionCount = 2; ActionEvidence = $failedCleanupEvidence
}
$failedCleanupServices = [pscustomobject]@{
    SessionContext = [pscustomobject]@{ id = 'fake-failure' }
    AutomationMetrics = [pscustomobject]@{ FlaUiActionAttempts = 2 }
    Cleanup = [pscustomobject]@{ StopBridge = { param($context) throw 'fake cleanup failure' } }
}
[void](Invoke-HtsRuleSuiteCleanup -RunServices $failedCleanupServices -RunState $failedCleanupState)
Assert-True $failedCleanupState.CleanupAttempted 'cleanup is attempted even when the injected stop operation throws'
Assert-True (-not $failedCleanupState.CleanupSucceeded) 'cleanup failure remains separate from the test verdict'
Assert-Equal 1 $failedCleanupState.CleanupErrors.Count 'cleanup failure records its evidence'
Assert-Equal 1 $failedCleanupState.ActionEvidence.Count 'cleanup failure does not erase prior action evidence'
Assert-Equal 2 $failedCleanupState.UiActionCount 'cleanup failure preserves the action-attempt counter'

$moduleRoot = Join-Path $root 'scripts\modules'
$orchestration = Get-Content -LiteralPath (Join-Path $moduleRoot 'hts-rule-suite-orchestration.ps1') -Raw
$bootstrap = Get-Content -LiteralPath (Join-Path $moduleRoot 'hts-rule-suite-bootstrap.ps1') -Raw
$plans = Get-Content -LiteralPath (Join-Path $moduleRoot 'hts-rule-suite-plan-loader.ps1') -Raw
$contexts = Get-Content -LiteralPath (Join-Path $moduleRoot 'hts-rule-suite-context-factory.ps1') -Raw
$caseRunner = Get-Content -LiteralPath (Join-Path $moduleRoot 'hts-case-runner.ps1') -Raw
$actionRunner = Get-Content -LiteralPath (Join-Path $moduleRoot 'hts-case-action-runner.ps1') -Raw
$finalizer = Get-Content -LiteralPath (Join-Path $moduleRoot 'hts-run-result-finalizer.ps1') -Raw

Assert-True ($bootstrap -match 'validate-test-pack') 'bootstrap retains approved TestPack validation'
Assert-True (($caseRunner + $actionRunner) -notmatch 'Invoke-RuleResultEvaluation') 'case and action runners cannot call the canonical evaluator directly'
Assert-True ($bootstrap -match 'TestPack 무결성 또는 승인 검증에 실패했습니다') 'unapproved TestPack keeps its blocking error contract'
Assert-True ($plans -match '논리 시나리오 계획과 일치하지 않습니다') 'compiled and physical plan mismatch remains blocked'
Assert-True ($plans -match '바인딩 카탈로그 파일 해시가 물리 실행계획과 일치하지 않습니다') 'binding catalog hash mismatch remains blocked'
Assert-True ($plans -match "status -ne 'READY'.*AllowPartialScenarioPlan") 'partial plan policy remains explicit'
Assert-True ($bootstrap -match 'SubmitTransactionalDialogs.*ScenarioPlanPath') 'transactional dialog submission still requires an approved scenario plan'
Assert-True ($actionRunner -match 'SubmitTransactionalDialogs') 'transactional approval boundary remains in the physical action phase'
Assert-True ($caseRunner -match 'FlaUiActionAttemptsBeforeCase') 'case runner preserves action delivery baseline evidence'
$actionCheckpointPattern = [regex]::Escape("'Action'") + '.*\r?\n\s*' + [regex]::Escape('$false')
Assert-True ($finalizer -match $actionCheckpointPattern) 'case completion Action remains non-checkpoint evidence'
Assert-True ($finalizer -match 'Invoke-RuleResultEvaluation') 'finalizer delegates every canonical verdict to the evaluator adapter'
Assert-True ($finalizer -notmatch '(?m)^\s*\$(status|summaryStatus)\s*=\s*["''](PASS|FAIL|ERROR|PENDING)') 'finalizer does not assign a canonical verdict literal'
Assert-True ($finalizer -match 'PipelineStatus|pipelineStatus' -or (Test-Path (Join-Path $root 'tests\PowerShell\pipeline-status.tests.ps1'))) 'PipelineStatus remains separately regression-tested'
Assert-True ($finalizer.Contains("'******'") -or $finalizer.Contains('"******"')) 'sensitive variables remain masked before JSON serialization'
Assert-True ($orchestration -notmatch 'Start-FlaUiBridge|Invoke-RuleResultEvaluation|Set-Content') 'composition root owns no UI, verdict, or result-writing implementation'
Assert-True ($orchestration -match '(?s)finally\s*\{.*Invoke-HtsRuleSuiteCleanup') 'composition root always connects top-level exceptions to cleanup'
Assert-True ($contexts -match 'RunServices' -and $caseRunner -match 'RunSpec.*RunServices.*RunState') 'runtime phases accept the explicit lifecycle objects'
Assert-True (([regex]::Matches($contexts, 'GetNewClosure\(\)')).Count -ge 7) 'dependency scriptblocks close over RunServices in the factory scope'
Assert-True (@(Get-Content -LiteralPath (Join-Path $moduleRoot 'hts-rule-suite-orchestration.ps1')).Count -le 140) 'composition root remains below the structural size gate'

Write-Output "HTS_RULE_SUITE_LIFECYCLE_TESTS=PASS assertions=$script:assertions"
