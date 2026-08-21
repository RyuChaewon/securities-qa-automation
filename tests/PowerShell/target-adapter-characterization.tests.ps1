<# .SYNOPSIS 0101 target 전용 동작을 adapter로 이동하기 전의 회귀 기준을 고정한다. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_TRUE failed: $Message" }
    $script:assertions++
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) {
        throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'"
    }
    $script:assertions++
}

# hts-action의 기존 confirmation matcher만 분리해서 관찰한다. UI 함수는 호출하지 않는다.
function Test-HtsSystemFailureSignal([string]$Text) { $Text -match '시스템오류' }
function Test-HtsInputValidationSignal([string]$Text) { $Text -match '입력오류' }
. (Join-Path $root 'scripts\modules\hts-target-adapter.ps1')
. (Join-Path $root 'scripts\modules\hts-action.ps1')

$script:assertions = 0
$profile = Get-Content -LiteralPath (Join-Path $root 'targets\1q-hts\0101\target-profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$actionContext = [pscustomobject]@{ TargetAdapter = New-HtsTargetAdapterContext $profile }
$dialog = [pscustomobject]@{
    title = '매수주문 확인'
    messageLines = @('주문 내용을 확인하세요')
    classification = '확인 요청'
    buttons = @('확인', '취소')
}
$buyPlan = [pscustomobject]@{ controlLogicalName = 'BTN_Ord_Buy' }
Assert-True (Test-HtsTransactionalConfirmationDialog $actionContext $dialog $buyPlan) 'matching command confirmation remains recognized'

# 현 matcher의 "주문" 대체 분기가 verb를 넓게 허용하는 것도 이동 중 의미 변경을 막기 위해 기록한다.
$broadDialog = [pscustomobject]@{
    title = '매도주문 확인'
    messageLines = @('주문 내용을 확인하세요')
    classification = '확인 요청'
    buttons = @('확인')
}
Assert-True (Test-HtsTransactionalConfirmationDialog $actionContext $broadDialog $buyPlan) 'legacy broad order-token fallback is characterized'
$invalidDialog = [pscustomobject]@{
    title = '입력오류'
    messageLines = @('값을 확인하세요')
    classification = '확인 요청'
    buttons = @('확인')
}
Assert-True (-not (Test-HtsTransactionalConfirmationDialog $actionContext $invalidDialog $buyPlan)) 'validation dialog is never treated as a transactional confirmation'

$summary = Get-Content -LiteralPath (Join-Path $root 'outputs\0101_automation\import-summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$package = Get-Content -LiteralPath (Join-Path $root 'outputs\0101_automation\generated-scenarios.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$scenarios = @($package.screens | ForEach-Object { $_.scenarios })
$variables = @($package.datasetPatch.variables)

Assert-Equal 1159 $summary.importedTestCases 'checked-in workbook import row count remains fixed'
Assert-Equal 19 $summary.mapFamilyCount 'MAP family count remains fixed'
Assert-Equal 1159 $scenarios.Count 'generated scenario count remains fixed'
Assert-Equal 457 $variables.Count 'generated variable count remains fixed'
Assert-Equal 26 @($scenarios | Where-Object { $_.transactional }).Count 'transactional scenario classification remains fixed'
Assert-Equal 577 @($scenarios | Where-Object { $_.automationStatus -eq 'ManualReview' }).Count 'manual review classification remains fixed'
Assert-Equal 50 @($scenarios | Where-Object { $_.orderTabContext }).Count 'stateful tab scenario coverage remains fixed'

$tabValues = @($variables | Where-Object { $_.targetLogicalName -eq 'TAB_Ord' } | ForEach-Object { $_.values } |
    ForEach-Object { "$(($_.value))|$(($_.displayValue))" } | Sort-Object -Unique)
Assert-Equal '0|매수,1|매도,2|정정/취소' ($tabValues -join ',') 'stateful tab option mapping remains fixed'

Write-Output "TARGET_ADAPTER_CHARACTERIZATION=PASS assertions=$script:assertions"
