# Role: verifies identical TestResult output from direct C# CLI and the production PowerShell adapter.
# Scope: uses only temporary JSON and sample observations without HTS, FlaUI, or external modules.
# Safety: every case is offline evaluation only and performs no UI or state-changing action.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cliProject = Join-Path $root 'src\HtsQa.Cli\HtsQa.Cli.csproj'
. (Join-Path $root 'scripts\modules\result-evaluator.ps1')

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$tempRoot = Join-Path $tempBase ("htsqa-result-evaluator-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
    & dotnet build $cliProject -c Release --no-restore | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "HtsQa.Cli Release build failed: exit=$LASTEXITCODE" }

    $testPackPath = Join-Path $tempRoot 'approved-test-pack.json'
    '{"testPackId":"GOLDEN-PACK","approvalStatus":"Approved"}' | Set-Content -LiteralPath $testPackPath -Encoding UTF8
    $evaluationContext = New-HtsEvaluationAdapterContext -CliProject $cliProject -TestPackPath $testPackPath -WorkingDirectory (Join-Path $tempRoot 'raw-adapter') -ObservationContext ([pscustomobject]@{name='fake-observation'})
    if ([string]$evaluationContext.TestPackPath -ne $testPackPath -or [string]$evaluationContext.ObservationContext.name -ne 'fake-observation') {
        throw 'Raw observation evaluator context did not retain its explicit contracts.'
    }
    $orchestrationText = Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-rule-suite-orchestration.ps1') -Raw
    if ($orchestrationText -match 'function Invoke-HtsRawObservationEvaluation') { throw 'Orchestration still owns raw observation evaluation.' }
    $observationsPath = Join-Path $tempRoot 'observations.json'
    $directOutputPath = Join-Path $tempRoot 'direct-test-results.json'
    $document = [pscustomobject]@{
        schemaVersion = '1.0'
        testPackId = 'GOLDEN-PACK'
        aggregateId = 'golden-run'
        cases = @(
            [pscustomobject]@{caseId='match';executed=$true;expectedResult=@{type='ValidationRequired';messagePatterns=@('stock-code-error');errorCodes=@()};observations=@(@{observationId='match-1';kind='InputValidation';executed=$true;evidencePresent=$true;message='stock-code-error';sourceCode=''})}
            [pscustomobject]@{caseId='mismatch';executed=$true;expectedResult=@{type='ValidationAllowed';messagePatterns=@('allowed-message');errorCodes=@()};observations=@(@{observationId='mismatch-1';kind='InputValidation';executed=$true;evidencePresent=$true;message='different-message';sourceCode=''})}
            [pscustomobject]@{caseId='required-mixed';executed=$true;expectedResult=@{type='ValidationRequired';messagePatterns=@('required-message');errorCodes=@()};observations=@(@{observationId='required-1';kind='InputValidation';executed=$true;evidencePresent=$true;message='different-message';sourceCode=''},@{observationId='required-2';kind='InputValidation';executed=$true;evidencePresent=$true;message='required-message';sourceCode=''})}
            [pscustomobject]@{caseId='not-executed';executed=$false;expectedResult=@{type='Success';messagePatterns=@();errorCodes=@()};observations=@()}
            [pscustomobject]@{caseId='missing-evidence';executed=$true;expectedResult=@{type='Success';messagePatterns=@();errorCodes=@()};observations=@(@{observationId='missing-1';kind='EvidenceMissing';executed=$true;evidencePresent=$false;message='';sourceCode=''})}
            [pscustomobject]@{caseId='observation-only';executed=$true;expectedResult=@{type='ObservationOnly';messagePatterns=@();errorCodes=@()};observations=@(@{observationId='observe-1';kind='Info';executed=$true;evidencePresent=$true;message='observed';sourceCode=''})}
            [pscustomobject]@{caseId='unresolved';executed=$true;expectedResult=@{type='Success';description='TODO_INTERNAL';messagePatterns=@();errorCodes=@()};observations=@(@{observationId='unresolved-1';kind='Success';executed=$true;evidencePresent=$true;message='';sourceCode=''})}
            [pscustomobject]@{caseId='infrastructure';executed=$false;expectedResult=@{type='Success';messagePatterns=@();errorCodes=@()};observations=@(@{observationId='infra-1';kind='InfrastructureError';executed=$true;evidencePresent=$true;message='process start failed';sourceCode='PROCESS_START_FAILED'})}
        )
    }
    ConvertTo-Json -InputObject $document -Depth 20 | Set-Content -LiteralPath $observationsPath -Encoding UTF8

    & dotnet run --project $cliProject -c Release --no-build -- evaluate-results --test-pack $testPackPath --observations $observationsPath --output $directOutputPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Direct evaluate-results call failed: exit=$LASTEXITCODE" }
    $direct = Get-Content -LiteralPath $directOutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $adapter = Invoke-RuleResultEvaluation -CliProject $cliProject -TestPackPath $testPackPath -EvaluationDocument $document -WorkingDirectory (Join-Path $tempRoot 'adapter') -InvocationId 'golden'

    $directJson = ConvertTo-Json -InputObject $direct -Depth 20 -Compress
    $adapterJson = ConvertTo-Json -InputObject $adapter -Depth 20 -Compress
    if ($directJson -cne $adapterJson) { throw 'Direct C# CLI and production PowerShell adapter results differ.' }

    $reporterDocument = [pscustomobject]@{schemaVersion='1.0';testPackId='GOLDEN-PACK';aggregateId='golden-reporter';cases=@();completedResults=@($adapter.results)}
    $reporter = Invoke-RuleResultEvaluation -CliProject $cliProject -TestPackPath $testPackPath -EvaluationDocument $reporterDocument -WorkingDirectory (Join-Path $tempRoot 'reporter') -InvocationId 'reporter'
    if ([int]$reporter.summary.total -ne 8 -or [string]$reporter.overallResult.status -ne 'ERROR') { throw 'Reporter aggregation did not preserve all completed TestResult objects.' }
    $infraAdapter = Invoke-RuleSignalEvaluation -CliProject $cliProject -TestPackPath $testPackPath -WorkingDirectory (Join-Path $tempRoot 'infra-adapter') -CaseId 'infra-adapter' -EventType 'InfrastructureError' -Text 'process start failed' -SourceCode 'PROCESS_START_FAILED' -Executed $false -EvidencePresent $true -ExpectedOutcome ([pscustomobject]@{type='Success';messagePatterns=@();errorCodes=@()})
    if ([string]$infraAdapter.testResult.status -ne 'ERROR' -or [bool]$infraAdapter.testResult.executed) { throw 'Infrastructure adapter must preserve executed=false and return ERROR.' }

    $expected = @{
        'match'='PASS';'mismatch'='FAIL';'required-mixed'='FAIL';'not-executed'='PENDING';'missing-evidence'='PENDING'
        'observation-only'='PENDING';'unresolved'='PENDING';'infrastructure'='ERROR'
    }
    foreach ($result in @($adapter.results)) {
        if ([string]$result.status -ne $expected[[string]$result.caseId]) {
            throw "Unexpected status: $($result.caseId) expected=$($expected[[string]$result.caseId]) actual=$($result.status)"
        }
    }
    if ([string]$adapter.overallResult.status -ne 'ERROR') { throw "Overall status must be ERROR: $($adapter.overallResult.status)" }
    Write-Output 'PASS result-evaluator golden: CLI and PowerShell adapter results are identical (8 cases).'
} finally {
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedTempRoot).StartsWith('htsqa-result-evaluator-', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
