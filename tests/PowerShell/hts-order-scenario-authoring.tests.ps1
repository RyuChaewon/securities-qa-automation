<# .SYNOPSIS Regression tests for the thin calibration and order-scenario CLI adapter. #>
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts/modules/hts-order-scenario-authoring.ps1')

function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERT_TRUE failed: $Message"};$script:assertions++}
function Assert-Equal($Expected,$Actual,[string]$Message){if([string]$Expected-ne[string]$Actual){throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'"};$script:assertions++}

$script:assertions=0
$script:calls=New-Object Collections.Generic.List[object]
$context=New-HtsOrderAuthoringContext -InvokeCli {
    param([string[]]$Arguments)
    $script:calls.Add(@($Arguments))
    [pscustomobject]@{status='PENDING';actualUiActionCount=0;transactionalActionCount=0}
}

[void](New-HtsOrderCalibrationSession -Context $context -CapturePaths @('one.json','two.json') -SessionId 'fixture-session' `
    -TargetProfileId 'fixture-target' -RepositoryId 'fixture-repository' -Screen 'F001' -StateContext 'state:a' `
    -Reviewer 'fixture-reviewer' -Map 'FAKE-MAP' -Out 'session.json')
[void](Test-HtsOrderCalibrationSession -Context $context -Session 'session.json' -Out 'calibration-validation.json')
[void](New-HtsOrderCalibrationReview -Context $context -Session 'session.json' -LogicalName 'FIXTURE_CONTROL' -Anchor 'redacted-anchor' `
    -RiskClass 'LimitedNonTransactional' -AllowedActions @('Input') -ForbiddenActions @('FinalSubmit','AmendSubmit','CancelSubmit') `
    -Source 'fixture:review' -Evidence @('fixture:one','fixture:two') -BusinessRole 'symbol-input' -TransactionalRole 'None' -Out 'review.json')
[void](Add-HtsApprovedControlRepositoryEntry -Context $context -Repository 'repository.json' -Entry 'decision.json' -Out 'repository.next.json')
[void](Complete-HtsOrderCalibrationSession -Context $context -Session 'session.json' -Repository 'repository.next.json' -LogicalName 'FIXTURE_CONTROL' -Out 'session.applied.json')
[void](Test-HtsOrderScenario -Context $context -InputPath 'input.json' -Out 'validation.json')
[void](New-HtsOrderScenarioRunPlan -Context $context -InputPath 'input.json' -Out 'compile.json' -CompiledAt '2026-08-24T09:00:00+09:00')
$dryRun=Invoke-HtsOrderScenarioDryRun -Context $context -Plan 'plan.json' -Out 'dry-run.json'
[void](New-HtsExecutionAuthorizationApproval -Context $context -Request 'authorization-request.json' -Out 'authorization-approval.json')
[void](Set-HtsExecutionAuthorizationApproval -Context $context -Request 'authorization-request.json' -Approval 'authorization-approval.json' -Out 'authorization.json')
[void](Test-HtsExecutionAuthorization -Context $context -Request 'authorization-check.json' -CheckedAt '2026-08-24T09:00:00+09:00' -Out 'authorization-decision.json')

Assert-Equal 11 $script:calls.Count 'each adapter command delegates exactly once'
Assert-Equal 'create-calibration-session' $script:calls[0][0] 'session delegates to Core CLI'
Assert-True ($script:calls[0] -contains 'one.json,two.json') 'repeated captures remain explicit inputs'
Assert-Equal 'validate-calibration-session' $script:calls[1][0] 'calibration validation delegates to Core CLI'
Assert-Equal 'create-calibration-review' $script:calls[2][0] 'human review delegates to Core CLI'
Assert-Equal 'register-control-repository-entry' $script:calls[3][0] 'registration delegates to Core CLI'
Assert-Equal 'finalize-calibration-session' $script:calls[4][0] 'session finalization delegates to Core CLI'
Assert-Equal 'validate-order-scenario' $script:calls[5][0] 'validation delegates to Core CLI'
Assert-True ($script:calls[2] -contains 'symbol-input') 'review forwards the explicit business role without deriving policy'
Assert-Equal 'compile-order-scenario' $script:calls[6][0] 'compile delegates to Core CLI'
Assert-Equal 'dry-run-order-scenario' $script:calls[7][0] 'DryRun delegates to Core CLI'
Assert-Equal 'PENDING' $dryRun.status 'adapter preserves canonical DryRun status'
Assert-Equal 0 $context.UiActionCount 'adapter sends no UI action'
Assert-Equal 0 $context.TransactionalActionCount 'adapter sends no transactional action'

Assert-Equal 'create-execution-authorization-approval' $script:calls[8][0] 'authorization template delegates to Core CLI'
Assert-Equal 'apply-execution-authorization-approval' $script:calls[9][0] 'authorization apply delegates to Core CLI'
Assert-Equal 'check-execution-authorization' $script:calls[10][0] 'authorization check delegates to Core CLI'
$moduleText=Get-Content -LiteralPath (Join-Path $root 'scripts/modules/hts-order-scenario-authoring.ps1') -Raw -Encoding UTF8
Assert-True ($moduleText-notmatch'(?i)SetCursorPos|mouse_event|SendInput|Click-Center|FlaUiAutomationEngine') 'authoring adapter contains no UI action primitive'
Assert-True ($moduleText-notmatch'ResultEvaluator|TestStatus|\bPASS\b') 'authoring adapter does not calculate verdict'
Assert-True ($moduleText-match'ORDER_DRY_RUN_ACTION_COUNT_NONZERO') 'adapter guards the zero-action invariant'

Assert-True ($moduleText-notmatch'CanonicalJson|SHA256|ApprovedContentHash') 'PowerShell does not calculate authorization hashes'
Write-Output "HTS_ORDER_SCENARIO_AUTHORING_TESTS=PASS assertions=$script:assertions"
