<# .SYNOPSIS Regression tests for raw HTS observation normalization and case-local collection. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-observation.ps1')

function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERT_TRUE failed: $Message"};$script:assertions++}
function Assert-Equal($Expected,$Actual,[string]$Message){if([string]$Expected -ne [string]$Actual){throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'"};$script:assertions++}

$script:assertions=0
$mapCatalog=[pscustomobject]@{errorCodes=@(
    [pscustomobject]@{code='E100';message='설치 카탈로그 시스템 오류';classification='SystemFailure';isFailure=$true},
    [pscustomobject]@{code='N001';message='정상 처리되었습니다';classification='Normal';isFailure=$false}
)}
$dependencies=[pscustomobject]@{
    CreateSignalEvaluationCase={
        param([string]$CaseId,[string]$EventType,[string]$Text,[string]$SourceCode,[string]$Source,$ExpectedOutcome)
        [pscustomobject]@{
            caseId=$CaseId;executed=$true
            expectedResult=[pscustomobject]@{type=[string]$ExpectedOutcome.type;expectationId=[string]$ExpectedOutcome.expectationId}
            observations=@([pscustomobject]@{kind=$EventType;message=$Text;sourceCode=$SourceCode;source=$Source;executed=$true;evidencePresent=$true})
        }
    }
    GetNow={ [datetime]'2026-08-20T12:00:00Z' }
}
$context=New-HtsObservationContext -MapCatalog $mapCatalog -Dependencies $dependencies
$expected=Get-HtsExpectedOutcome -Option ([pscustomobject]@{id='option-1';expectedOutcome=[pscustomobject]@{type='ValidationAllowed';source='Dataset';confidence='High';messagePatterns=@('허용 문구');errorCodes=@();evidence=@('dataset evidence');queryShouldComplete=$false}}) -FallbackPatterns @('화면 패턴')
Assert-Equal 'ValidationAllowed' $expected.type 'explicit expected type is preserved'
Assert-Equal 2 @($expected.messagePatterns).Count 'fallback and option matcher patterns are combined once'
Assert-Equal 'dataset evidence' $expected.evidence[0] 'explicit evidence is preserved'

$mapOracle=[pscustomobject]@{messageBoxes=@(
    [pscustomobject]@{ruleId='R-WARN';message='주의 문구';title='';classification='Warning';isExplicitError=$false},
    [pscustomobject]@{ruleId='R-ERR';message='MAP 오류 문구';title='';classification='Error';isExplicitError=$true}
)}
$installed=New-HtsSignalObservation -Context $context -Text 'E100 설치 카탈로그 시스템 오류' -MapOracle $mapOracle -ExpectedOutcome $expected -ErrorRegex ([regex]'기타 오류')
Assert-Equal 'ProductFailure' $installed.eventType 'installed failure code is normalized as a product failure observation'
Assert-Equal 'HTS 오류코드' $installed.source 'installed catalog has priority source attribution'
Assert-Equal 'E100' $installed.code 'installed error code is retained as evidence'

$map=New-HtsSignalObservation -Context $context -Text 'MAP 오류 문구' -MapOracle $mapOracle -ExpectedOutcome $expected -ErrorRegex ([regex]'기타 오류')
Assert-Equal 'ProductFailure' $map.eventType 'MAP explicit error becomes a raw product failure event'
Assert-Equal 'R-ERR' $map.code 'MAP rule id is retained'
$validation=New-HtsSignalObservation -Context $context -Text '비밀번호를 확인해 주세요' -MapOracle $null -ExpectedOutcome $expected -ErrorRegex ([regex]'기타 오류')
Assert-Equal 'InputValidation' $validation.eventType 'input validation language stays distinct from system failure'
$generic=New-HtsSignalObservation -Context $context -Text '기타 오류' -MapOracle $null -ExpectedOutcome $expected -ErrorRegex ([regex]'기타 오류')
Assert-Equal 'GenericError' $generic.eventType 'configured generic error remains an unjudged raw event'
Assert-Equal 'signal-000004' $generic.evaluationCase.caseId 'observation ids use the explicit monotonic context sequence'

$results=New-Object Collections.Generic.List[object]
$groups=@{}
$requiredList=New-Object Collections.Generic.List[object]
$requiredObservations=New-Object Collections.Generic.List[object]
$requiredObservations.Add([pscustomobject]@{kind='ExistingEvidence'})
$requiredList.Add([pscustomobject]@{controlId='c1';optionId='o1';observations=$requiredObservations})
[void](Reset-HtsObservationCaseContext -Context $context -ResultEvaluationCases $results -SignalEvaluationGroups $groups -RequiredExpectations $requiredList)
$events=New-Object Collections.Generic.List[object]
Add-HtsOracleObservation -Context $context -List $events -Observation $generic -Stage 'afterAction' -ControlId 'c1' -OptionId 'o1'
Add-HtsOracleObservation -Context $context -List $events -Observation $generic -Stage 'afterAction' -ControlId 'c1' -OptionId 'o1'
Assert-Equal 1 $events.Count 'duplicate observation evidence is collected once'
Assert-Equal 2 $requiredObservations.Count 'matching required expectation receives the raw observation'
Assert-Equal 1 $groups.Count 'non-required signal is grouped for the later evaluator adapter'
Assert-Equal '2026-08-20T12:00:00.0000000Z' ([datetime]::Parse([string]$events[0].detectedAt).ToUniversalTime().ToString('o')) 'observation timestamp comes from the explicit dependency'

$regex=Get-HtsObservationErrorRegex -Context $context -BaseRegex ([regex]'base-error') -MapOracle $mapOracle
Assert-True ('MAP 오류 문구' -match $regex) 'MAP explicit error is included in the observation filter'
Assert-True ('E100' -match $regex) 'installed failure code is included in the observation filter'
Assert-True (-not ('N001' -match $regex)) 'non-failure installed code is excluded from the error filter'

$moduleText=Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-observation.ps1') -Raw
Assert-True ($moduleText -notmatch '\$script:|\$global:') 'observation module has no global or script-scoped runtime state'
Assert-True ($moduleText -notmatch 'Invoke-RuleResultEvaluation|Invoke-RuleSignalEvaluation|Set-Content|Add-Content') 'observation module cannot evaluate or report results'

Write-Output "HTS_OBSERVATION_TESTS=PASS assertions=$script:assertions"
