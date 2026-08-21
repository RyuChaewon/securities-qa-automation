<# .SYNOPSIS Regression tests for explicit rule-suite runtime state. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-runtime-context.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_TRUE failed: $Message" }
    $script:assertions++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) { throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'" }
    $script:assertions++
}

$script:assertions = 0
$first = New-HtsRunContext -TargetWindowClassName 'AfxFrame' -TargetWindowTitlePrefix '1Q' `
    -TargetScreenIdRegex ([regex]::new('^\d{4}$')) -TargetScreenTitleRegex ([regex]::new('^\[(?<screen>\d{4})\]')) `
    -TargetMapScreenCodeRegex ([regex]::new('^HT(?<screen>\d{4})')) -InitiallyActiveMapScreenCodes @('HT0101') `
    -VisiblePointerMotion $true -PointerDwellMilliseconds 120
$second = New-HtsRunContext -TargetWindowClassName 'Other' -TargetWindowTitlePrefix 'Other'

Assert-Equal 'AfxFrame' ([string]$first.TargetWindowClassName) 'target window class is retained'
Assert-Equal '1Q' ([string]$first.TargetWindowTitlePrefix) 'target title prefix is retained'
Assert-True ($first.TargetScreenIdRegex.IsMatch('0714')) 'screen id regex is retained'
Assert-Equal '0714' ([string]$first.TargetScreenTitleRegex.Match('[0714] 화면').Groups['screen'].Value) 'screen title capture is retained'
Assert-Equal '0714' ([string]$first.TargetMapScreenCodeRegex.Match('HT0714').Groups['screen'].Value) 'MAP screen capture is retained'
Assert-Equal 1 @($first.InitiallyActiveMapScreenCodes).Count 'initial MAP set is retained'
Assert-True ([bool]$first.VisiblePointerMotion) 'visible pointer policy is retained'
Assert-Equal 120 ([int]$first.PointerDwellMilliseconds) 'pointer dwell policy is retained'
$first.LastTextAutomationEngine = 'FlaUI.UIA3'
Assert-Equal '미실행' ([string]$second.LastTextAutomationEngine) 'runtime contexts do not share text input evidence'

$orchestrationText = Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-rule-suite-orchestration.ps1') -Raw
Assert-True ($orchestrationText -notmatch '\$script:') 'orchestration has no script-scoped runtime state'
Write-Output "HTS_RUNTIME_CONTEXT_TESTS=PASS assertions=$script:assertions"
