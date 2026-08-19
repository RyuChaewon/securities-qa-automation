<#
.SYNOPSIS 설치 자료와 MAP에서 기대 결과를 추론하는 PowerShell 정책을 자체 검증한다.
.DESCRIPTION 가상 컨트롤을 사용하므로 실제 HTS를 조작하지 않으며 실패 시 즉시 예외를 발생시킨다.
#>
param()

$ErrorActionPreference = "Stop"
$scriptPath = Join-Path $PSScriptRoot "modules\rule-control-exploration.ps1"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors -join [Environment]::NewLine) }

$functionNames = @(
    "New-RuleExpectedOutcome",
    "Get-RuleOptionOutcome",
    "Get-RuleMapControlValidationMessages",
    "Set-RuleInferredExpectedOutcomes"
)
foreach ($name in $functionNames) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "추론 함수 '$name'을 찾을 수 없습니다." }
    Invoke-Expression $definition.Extent.Text
}

# 추론값이 계약과 다르면 기대·실제 값을 포함한 예외로 자체 테스트를 중단한다.
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message (기대='$Expected', 실제='$Actual')"
    }
}

# 기대 결과 추론 함수에 필요한 최소 컨트롤·선택지 객체를 만든다.
function New-TestControl([string]$Kind, [string]$Value, [string]$LabelSource = "dataset") {
    [pscustomobject]@{
        controlKind = $Kind
        options = @([pscustomobject]@{
            id = "value"
            value = $Value
            displayValue = $Value
            labelSource = $LabelSource
        })
    }
}

$explicit = New-TestControl "ComboBox" "01"
$explicit.options[0] | Add-Member -NotePropertyName expectedOutcome -NotePropertyValue (
    New-RuleExpectedOutcome "Success" "InstallationInputOption" "High" @("HTS 설치 입력 사전: exchange.ini") @() @() $true
)
Set-RuleInferredExpectedOutcomes $explicit
Assert-Equal "Success" $explicit.options[0].expectedOutcome.type "공식 선택지는 정상 계약이어야 합니다."
Assert-Equal "InstallationInputOption" $explicit.options[0].expectedOutcome.source "공식 선택지 출처가 보존되어야 합니다."
Assert-Equal "High" $explicit.options[0].expectedOutcome.confidence "공식 선택지 신뢰도가 보존되어야 합니다."

$invalidInstrument = New-TestControl "Text" "99999999"
$instrumentMap = [pscustomobject]@{kind="Instrument";semanticRole="Input";logicalName="EDT_Stock"}
Set-RuleInferredExpectedOutcomes $invalidInstrument $instrumentMap
Assert-Equal "ValidationRequired" $invalidInstrument.options[0].expectedOutcome.type "마스터 형식 밖 종목코드는 입력 검증 필수여야 합니다."
Assert-Equal "GeneratedBoundary" $invalidInstrument.options[0].expectedOutcome.source "생성 경계값의 출처가 기록되어야 합니다."
Assert-Equal "High" $invalidInstrument.options[0].expectedOutcome.confidence "명백한 형식 위반은 높은 신뢰도여야 합니다."

$futureDate = New-TestControl "Date" "20991231"
$dateMap = [pscustomobject]@{kind="Date";semanticRole="Input";logicalName="DT_End"}
$dateModel = [pscustomobject]@{errorOracle=[pscustomobject]@{messageBoxes=@([pscustomobject]@{
    classification="InputValidation"
    targetControls=@("DT_End")
    message="당일 이후로는 조회가 불가 합니다."
    conditionExpression="DT_End.GetDate() > GetCurrentDate()"
    ruleId="MAP-MSG-1"
})}}
Set-RuleInferredExpectedOutcomes $futureDate $dateMap $dateModel
Assert-Equal "ValidationRequired" $futureDate.options[0].expectedOutcome.type "MAP 조건과 일치한 미래 날짜는 검증 필수여야 합니다."
Assert-Equal "MapValidation" $futureDate.options[0].expectedOutcome.source "날짜 검증의 MAP 출처가 기록되어야 합니다."
Assert-Equal "High" $futureDate.options[0].expectedOutcome.confidence "조건식이 있는 MAP 검증은 높은 신뢰도여야 합니다."

$runtimeChoice = New-TestControl "RadioButton" "1" "runtime"
Set-RuleInferredExpectedOutcomes $runtimeChoice
Assert-Equal "Success" $runtimeChoice.options[0].expectedOutcome.type "활성 유한 선택지는 정상 선택 계약이어야 합니다."
Assert-Equal "RuntimeChoice" $runtimeChoice.options[0].expectedOutcome.source "런타임 선택지 출처가 기록되어야 합니다."
Assert-Equal "Medium" $runtimeChoice.options[0].expectedOutcome.confidence "런타임 전용 선택지는 중간 신뢰도여야 합니다."

$queryButton = New-TestControl "Button" "click" "map"
$queryMap = [pscustomobject]@{kind="Button";semanticRole="Query";logicalName="BTN_Query"}
Set-RuleInferredExpectedOutcomes $queryButton $queryMap
Assert-Equal "Success" $queryButton.options[0].expectedOutcome.type "MAP 조회 버튼은 정상 실행 계약이어야 합니다."
Assert-Equal "MapBehavior" $queryButton.options[0].expectedOutcome.source "조회 버튼의 MAP 동작 출처가 기록되어야 합니다."
Assert-Equal "True" $queryButton.options[0].expectedOutcome.queryShouldComplete "조회 버튼은 조회 완료가 필요해야 합니다."

Write-Output "기대 결과 자동 추론 테스트: PASS (5개 정책 시나리오)"
