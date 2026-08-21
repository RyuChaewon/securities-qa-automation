<#
.SYNOPSIS Sends raw PowerShell observations to HtsQa.Cli evaluate-results and returns completed TestResult objects.
.DESCRIPTION Exchanges a TestPack path and ResultEvaluationDocument as JSON without local judgment branches.
.INPUTS CLI project, TestPack path, and raw observation evaluation document.
.OUTPUTS TestResultDocument completed by HtsQa.Core.
.NOTES Only HtsQa.Core ResultEvaluator defines PASS, FAIL, ERROR, PENDING, and matcher semantics.
#>

function New-HtsEvaluationAdapterContext {
    param(
        [Parameter(Mandatory = $true)][string]$CliProject,
        [Parameter(Mandatory = $true)][string]$TestPackPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)]$ObservationContext
    )

    [pscustomobject]@{
        CliProject = $CliProject
        TestPackPath = $TestPackPath
        WorkingDirectory = $WorkingDirectory
        ObservationContext = $ObservationContext
    }
}

# 원시 Observation을 C# ResultEvaluator 입력으로 전달하고 TestResult를 반환한다.
function Invoke-HtsRawObservationEvaluation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string]$ObservationKind,
        [string]$Text,
        [string]$SourceCode,
        $ExpectedOutcome,
        [bool]$Executed = $true,
        [bool]$EvidencePresent = $true,
        [string]$Prefix = 'control'
    )

    $evaluationSequence = Get-HtsNextObservationSequence -Context $Context.ObservationContext
    $evaluation = Invoke-RuleSignalEvaluation `
        -CliProject $Context.CliProject `
        -TestPackPath $Context.TestPackPath `
        -WorkingDirectory $Context.WorkingDirectory `
        -CaseId ("{0}-{1:D6}" -f $Prefix, $evaluationSequence) `
        -EventType $ObservationKind `
        -Text $Text `
        -SourceCode $SourceCode `
        -Source 'PowerShell raw observation' `
        -Executed $Executed `
        -EvidencePresent $EvidencePresent `
        -ExpectedOutcome $ExpectedOutcome
    if ($Context.ObservationContext.CurrentResultEvaluationCases) {
        $Context.ObservationContext.CurrentResultEvaluationCases.Add($evaluation.evaluationCase)
    }
    $evaluation
}

# rule 실행 결과 파일을 단일 C# 평가 명령으로 처리한다.
function Invoke-RuleResultEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CliProject,
        [Parameter(Mandatory = $true)][string]$TestPackPath,
        [Parameter(Mandatory = $true)]$EvaluationDocument,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [string]$InvocationId = 'evaluation'
    )

    if (-not (Test-Path -LiteralPath $CliProject)) { throw "ResultEvaluator CLI project not found: $CliProject" }
    if (-not (Test-Path -LiteralPath $TestPackPath)) { throw "ResultEvaluator TestPack not found: $TestPackPath" }
    $cliAssembly = Join-Path (Split-Path -Parent $CliProject) 'bin\Release\net8.0-windows\HtsQa.Cli.dll'
    if (-not (Test-Path -LiteralPath $cliAssembly)) { throw "Built ResultEvaluator CLI assembly not found: $cliAssembly" }
    New-Item -ItemType Directory -Force -Path $WorkingDirectory | Out-Null
    $safeId = ([string]$InvocationId -replace '[^A-Za-z0-9_.-]', '_').Trim('_')
    if (-not $safeId) { $safeId = 'evaluation' }
    $token = [guid]::NewGuid().ToString('N')
    $observationsPath = Join-Path $WorkingDirectory ("{0}-{1}.observations.json" -f $safeId, $token)
    $outputPath = Join-Path $WorkingDirectory ("{0}-{1}.test-results.json" -f $safeId, $token)
    ConvertTo-Json -InputObject $EvaluationDocument -Depth 20 | Set-Content -LiteralPath $observationsPath -Encoding UTF8

    $arguments = @(
        $cliAssembly, 'evaluate-results', '--test-pack', $TestPackPath,
        '--observations', $observationsPath, '--output', $outputPath
    )
    $commandOutput = @(& dotnet @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "ResultEvaluator CLI failed (exit=$LASTEXITCODE): $($commandOutput -join [Environment]::NewLine)"
    }
    if (-not (Test-Path -LiteralPath $outputPath)) { throw "ResultEvaluator CLI did not create output: $outputPath" }
    Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

# legacy rule 신호를 ResultEvaluator가 소비할 평가 케이스로 변환한다.
function New-RuleSignalEvaluationCase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CaseId,
        [Parameter(Mandatory = $true)][string]$EventType,
        [string]$Text = '',
        [string]$SourceCode = '',
        [string]$Source = '',
        [bool]$Executed = $true,
        [bool]$EvidencePresent = $true,
        [bool]$ObservationExecuted = $true,
        $ExpectedOutcome
    )

    $expectedType = if ($ExpectedOutcome -and [string]$ExpectedOutcome.type) { [string]$ExpectedOutcome.type } else { 'Unspecified' }
    [pscustomobject]@{
        caseId = $CaseId
        executed = $Executed
        expectedResult = [pscustomobject]@{
            expectationId = $(if ($ExpectedOutcome) { [string]$ExpectedOutcome.expectationId } else { '' })
            type = $expectedType
            description = $(if ($ExpectedOutcome) { @($ExpectedOutcome.evidence) -join '; ' } else { '' })
            messagePatterns = @($(if ($ExpectedOutcome) { $ExpectedOutcome.messagePatterns } else { @() }))
            errorCodes = @($(if ($ExpectedOutcome) { $ExpectedOutcome.errorCodes } else { @() }))
        }
        observations = @([pscustomobject]@{
            observationId = "$CaseId-observation"
            kind = $EventType
            executed = $ObservationExecuted
            evidencePresent = $EvidencePresent
            message = $Text
            sourceCode = $SourceCode
            source = $Source
        })
    }
}

# rule 신호 평가 케이스를 단일 C# 평가 경로로 전달한다.
function Invoke-RuleSignalEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CliProject,
        [Parameter(Mandatory = $true)][string]$TestPackPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$CaseId,
        [Parameter(Mandatory = $true)][string]$EventType,
        [string]$Text = '',
        [string]$SourceCode = '',
        [string]$Source = '',
        [bool]$Executed = $true,
        [bool]$EvidencePresent = $true,
        [bool]$ObservationExecuted = $true,
        $ExpectedOutcome
    )

    $evaluationCase = New-RuleSignalEvaluationCase -CaseId $CaseId -EventType $EventType -Text $Text -SourceCode $SourceCode -Source $Source -Executed $Executed -EvidencePresent $EvidencePresent -ObservationExecuted $ObservationExecuted -ExpectedOutcome $ExpectedOutcome
    $document = [pscustomobject]@{ schemaVersion = '1.0'; testPackId = [IO.Path]::GetFileNameWithoutExtension($TestPackPath); aggregateId = $CaseId; cases = @($evaluationCase) }
    $output = Invoke-RuleResultEvaluation -CliProject $CliProject -TestPackPath $TestPackPath -EvaluationDocument $document -WorkingDirectory $WorkingDirectory -InvocationId $CaseId
    [pscustomobject]@{ evaluationCase = $evaluationCase; testResult = @($output.results)[0]; output = $output }
}
