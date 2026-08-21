<# .SYNOPSIS Regression tests for isolated HTS reporting and evidence utilities. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-reporting.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_TRUE failed: $Message" }
    $script:assertions++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) { throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'" }
    $script:assertions++
}

$script:assertions = 0
$tempRoot = Join-Path (Join-Path $root 'artifacts') ('reporting-regression-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $tracePath = Join-Path $tempRoot 'execution-trace.ndjson'
    $script:reportCalls = 0
    $script:tcReportCalls = 0
    $context = New-HtsReportingContext -ReportExporter { param($ReportDir) $script:reportCalls++ } -TcReportExporter { param($ReportDir) $script:tcReportCalls++ } -ExecutionTracePath $tracePath

    Assert-Equal '123****890' (Get-MaskedAccount '1234567890') 'account masking is preserved'
    Assert-Equal '123****890' (Protect-Text '1234567890') 'free-text account masking is preserved'
    Assert-Equal 'prefix ****** suffix' (Protect-Text 'prefix secret suffix' 'secret') 'explicit secret masking is preserved'
    Assert-Equal 12 (Get-AccountFingerprint '1234567890').Length 'account fingerprint length is preserved'
    Assert-Equal (Get-AccountFingerprint '1234567890') (Get-AccountFingerprint '1234567890') 'account fingerprint remains deterministic'

    $actions = New-Object Collections.Generic.List[object]
    Add-HtsActionRecord -Context $context -List $actions -Action 'observe' -Status 'PENDING' -Target 'sample' -Output 'not executed' -ErrorCode 'NOT_EXECUTED'
    Assert-Equal 1 $actions.Count 'action record is added once'
    Assert-Equal 'PENDING' ([string]$actions[0].status) 'action status is preserved'
    Assert-True (Test-Path -LiteralPath $tracePath) 'execution trace is written through reporting context'
    Assert-True ((Get-Content -LiteralPath $tracePath -Raw) -match 'NOT_EXECUTED') 'execution trace retains the error code'

    Export-HtsRuleResultWorkbooks -Context $context -Path $tempRoot
    Assert-Equal 1 $script:reportCalls 'base report exporter is called'
    Assert-Equal 0 $script:tcReportCalls 'TC exporter is skipped without TC cases'
    '{}' | Set-Content -LiteralPath (Join-Path $tempRoot 'compiled-plan.json') -Encoding UTF8
    Export-HtsRuleResultWorkbooks -Context $context -Path $tempRoot
    Assert-Equal 2 $script:reportCalls 'base exporter remains one call per export'
    Assert-Equal 1 $script:tcReportCalls 'TC exporter is called when compiled plan exists'

    $moduleText = Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-reporting.ps1') -Raw
    Assert-True ($moduleText -notmatch 'Click-Center|Set-AutomationText|Invoke-HtsRawObservationEvaluation') 'reporting module cannot execute UI actions or evaluate results'
    Write-Output "HTS_REPORTING_TESTS=PASS assertions=$script:assertions"
}
finally {
    $artifactsRoot = [IO.Path]::GetFullPath((Join-Path $root 'artifacts')).TrimEnd('\') + '\'
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTemp.StartsWith($artifactsRoot,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
