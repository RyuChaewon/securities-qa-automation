<#
.SYNOPSIS HTS 실행 증거의 마스킹, 파일 식별자, action trace와 workbook export를 담당한다.
.DESCRIPTION UI 동작이나 테스트 판정을 수행하지 않고 완성된 결과와 원시 action 기록만 파일로 내보낸다.
#>
function New-HtsReportingContext($ReportExporter, $TcReportExporter, [string]$ExecutionTracePath) {
    [pscustomobject]@{
        ReportExporter = $ReportExporter
        TcReportExporter = $TcReportExporter
        ExecutionTracePath = $ExecutionTracePath
    }
}

# 결과 근거 파일의 SHA-256을 계산하고 파일이 없으면 빈 값을 반환한다.
function Get-RuleFileSha256([string]$Path) {
    $stream=[IO.File]::OpenRead($Path)
    $hasher=[Security.Cryptography.SHA256]::Create()
    try {
        (($hasher.ComputeHash($stream) | ForEach-Object { $_.ToString('X2') }) -join '')
    } finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

# 완성된 TestResult 경로를 등록된 workbook exporter에 전달한다.
function Export-HtsRuleResultWorkbooks($Context, [string]$Path) {
    & $Context.ReportExporter -ReportDir $Path | Out-Null
    $compiledPath = Join-Path $Path 'compiled-plan.json'
    $casePath = Join-Path $Path 'case-results.json'
    $hasTcCases = Test-Path -LiteralPath $compiledPath
    if (-not $hasTcCases -and (Test-Path -LiteralPath $casePath)) {
        $tcRows = @(Get-Content -LiteralPath $casePath -Raw -Encoding UTF8 | ConvertFrom-Json | Where-Object { [string]$_.sourceTestCaseId })
        $hasTcCases = $tcRows.Count -gt 0
    }
    if ($hasTcCases) { & $Context.TcReportExporter -ReportDir $Path | Out-Null }
}

# 보고서 텍스트에서 비밀 값과 민감 패턴을 제거한다.
function Protect-Text([string]$Text, [string]$Secret = '') {
    if ($null -eq $Text) { return '' }
    $masked = $Text -replace '\b(\d{3})\d{5}-(\d{3})\b', '$1****$2'
    $masked = $masked -replace '\b(\d{3})\d{4,8}(\d{3})\b', '$1****$2'
    $masked = $masked -replace '\b\d{6}-\d{7}\b', '******-*******'
    if ($Secret) { $masked = $masked.Replace($Secret, '******') }
    $masked
}

# 원문 계좌번호를 노출하지 않는 비교용 fingerprint를 만든다.
function Get-AccountFingerprint([string]$AccountNumber) {
    if ([string]::IsNullOrWhiteSpace($AccountNumber)) { return '' }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $sha = $hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($AccountNumber)) }
    finally { $hasher.Dispose() }
    $hex = -join ($sha | ForEach-Object { $_.ToString('x2') })
    $hex.Substring(0,12)
}

# 보고서 표시용으로 계좌번호 일부를 마스킹한다.
function Get-MaskedAccount([string]$AccountNumber) {
    if ([string]::IsNullOrWhiteSpace($AccountNumber)) { return '' }
    $digits = $AccountNumber -replace '\D', ''
    if ($digits.Length -lt 7) { return '******' }
    $digits.Substring(0,3) + '****' + $digits.Substring($digits.Length - 3)
}

# 보고서 기준 경로에서 증거 파일의 상대 경로를 계산한다.
function Get-RelativeFilePath([string]$BasePath, [string]$TargetPath) {
    $baseFull = [IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    $targetFull = [IO.Path]::GetFullPath($TargetPath)
    $relative = (New-Object Uri($baseFull)).MakeRelativeUri((New-Object Uri($targetFull))).ToString()
    [Uri]::UnescapeDataString($relative).Replace('/', '\')
}

# 수행된 action 사실을 보호된 실행 추적 레코드로 추가한다.
function Add-HtsActionRecord($Context, $List, [string]$Action, [string]$Status, [string]$Target = '', [string]$Output = '', [string]$ErrorCode = '') {
    $row=[pscustomobject]@{ action=$Action; status=$Status; target=$Target; output=$Output; errorCode=$ErrorCode; elapsedMs=0 }
    $List.Add($row)
    [pscustomobject]@{timestamp=(Get-Date).ToString('o');action=$Action;status=$Status;target=$Target;output=$Output;errorCode=$ErrorCode} |
        ConvertTo-Json -Compress | Add-Content -LiteralPath $Context.ExecutionTracePath -Encoding UTF8
}
