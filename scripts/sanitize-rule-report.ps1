<#
.SYNOPSIS 기존 결과 폴더의 JSON·NDJSON에서 민감정보를 제거해 안전한 사본을 만든다.
.DESCRIPTION 계좌 원문과 비밀번호 후보를 재귀 마스킹하며 실행 결과의 상태·증거 구조는 유지한다.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ReportDir,
    [switch]$SkipExcel
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "modules\report-sanitization.ps1")

$ReportDir = if ([IO.Path]::IsPathRooted($ReportDir)) { [IO.Path]::GetFullPath($ReportDir) } else { [IO.Path]::GetFullPath((Join-Path $root $ReportDir)) }
$caseResultsPath = Join-Path $ReportDir "case-results.json"
if (-not (Test-Path -LiteralPath $caseResultsPath)) { throw "결과 파일을 찾을 수 없습니다: $caseResultsPath" }

$parsedRows = Get-Content -LiteralPath $caseResultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
# 배열·래퍼 객체가 섞인 구형 결과에서도 caseId를 가진 실제 케이스 행만 평탄화한다.
function Add-RuleResultRows($Value, [Collections.Generic.List[object]]$Destination) {
    if ($null -eq $Value) { return }
    if ($Value.psobject.Properties['caseId']) {
        $Destination.Add($Value)
        return
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { Add-RuleResultRows $item $Destination }
        return
    }
    foreach ($property in $Value.psobject.Properties) { Add-RuleResultRows $property.Value $Destination }
}
$rowList = [Collections.Generic.List[object]]::new()
Add-RuleResultRows $parsedRows $rowList
$rows = $rowList.ToArray()
if ($rows.Count -eq 0) { throw "caseId를 가진 결과 행을 찾지 못했습니다." }
foreach ($row in $rows) { Protect-RuleReportedSensitiveValues $row }
$resultArray = @($rows)
ConvertTo-Json -InputObject $resultArray -Depth 12 | Set-Content -LiteralPath $caseResultsPath -Encoding UTF8
$planRows = @($resultArray | ForEach-Object {
    [pscustomobject]@{caseId=$_.caseId;screenNumber=$_.screenNumber;screenName=$_.screenName;discoveredControls=$_.discoveredControls;controlTests=$_.controlTests}
})
ConvertTo-Json -InputObject $planRows -Depth 12 | Set-Content -LiteralPath (Join-Path $ReportDir "control-plan.json") -Encoding UTF8

if (-not $SkipExcel) {
    & (Join-Path $PSScriptRoot "export-rule-results-xlsx.ps1") -ReportDir $ReportDir | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "마스킹 결과 Excel 재생성에 실패했습니다." }
}

Write-Output $ReportDir
