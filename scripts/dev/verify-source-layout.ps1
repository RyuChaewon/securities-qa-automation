<#
.SYNOPSIS 저장소의 책임별 폴더 구조, manifest 참조, 파일 헤더와 PowerShell 구문을 검증한다.
.DESCRIPTION 실제 HTS를 실행하지 않는 개발용 정적 검사로 구조 변경 뒤 경로 누락과 주석 계약 퇴행을 빠르게 찾는다.
.INPUTS config/pipeline.manifest.json과 src, tests, scripts의 유지 코드.
.OUTPUTS 검사별 PASS 메시지. 위반이 하나라도 있으면 오류 목록과 종료 코드 1.
.NOTES 생성물 폴더는 검사하지 않으며 이 스크립트는 파일을 수정하지 않는다.
#>
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$failures = New-Object Collections.Generic.List[string]

# manifest는 실행 파일 연결의 단일 기준이므로 모든 선언 경로가 저장소 안에 실제 존재해야 한다.
$manifestPath = Join-Path $root 'config\pipeline.manifest.json'
try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($relativePath in @($manifest.entryPoints.PSObject.Properties.Value) + @($manifest.sharedLibraries)) {
        $fullPath = [IO.Path]::GetFullPath((Join-Path $root ([string]$relativePath)))
        if (-not $fullPath.StartsWith(([IO.Path]::GetFullPath($root).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            $failures.Add("manifest 경로가 저장소 밖을 가리킵니다: $relativePath")
        } elseif (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            $failures.Add("manifest 파일이 없습니다: $relativePath")
        }
    }
} catch {
    $failures.Add("manifest를 읽지 못했습니다: $($_.Exception.Message)")
}

# 내부 PowerShell 라이브러리가 다시 공개 명령 폴더에 섞이는 것을 방지한다.
$requiredModules = @('pipeline-common.ps1', 'rule-control-exploration.ps1', 'report-sanitization.ps1')
foreach ($moduleName in $requiredModules) {
    if (-not (Test-Path -LiteralPath (Join-Path $root "scripts\modules\$moduleName") -PathType Leaf)) {
        $failures.Add("필수 내부 모듈이 scripts/modules에 없습니다: $moduleName")
    }
    if (Test-Path -LiteralPath (Join-Path $root "scripts\$moduleName") -PathType Leaf) {
        $failures.Add("내부 모듈이 scripts 루트에도 중복되어 있습니다: $moduleName")
    }
}

# 유지 코드의 첫 비어 있지 않은 줄은 역할을 설명하는 주석이어야 한다.
$codeFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File -Filter '*.cs' |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }
    Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Recurse -File -Filter '*.cs' |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }
    Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Recurse -File -Filter '*.ps1'
    Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Recurse -File |
        Where-Object {
            $_.FullName -notmatch '\\(node_modules|bin|obj|__pycache__)\\' -and
            $_.Extension -in @('.cs', '.mjs', '.py', '.ps1')
        }
)
foreach ($file in $codeFiles) {
    $firstLine = Get-Content -LiteralPath $file.FullName -Encoding UTF8 |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1
    $isHeader = switch ($file.Extension) {
        '.cs' { $firstLine -match '^\s*//' }
        '.ps1' { $firstLine -match '^\s*<#' }
        '.mjs' { $firstLine -match '^\s*/\*\*' }
        '.py' { $firstLine -match '^\s*"""' }
        default { $false }
    }
    if (-not $isHeader) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\')
        $failures.Add("파일 역할 헤더가 없습니다: $relative")
    }
}

# 화면군 식별자는 데이터셋·fixture가 소유해야 하므로 유지 코드에 과거 대상 번호가 다시 들어오는 것을 차단한다.
$legacyFamilyPrefix = '0' + '7'
$targetScreenLiteralPattern = "(?<![0-9])$legacyFamilyPrefix[0-9]{2}(?![0-9])|HT$legacyFamilyPrefix[0-9]{2}|${legacyFamilyPrefix}xx"
foreach ($file in $codeFiles) {
    foreach ($match in @(Select-String -LiteralPath $file.FullName -Pattern $targetScreenLiteralPattern -Encoding UTF8)) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\')
        $failures.Add("대상 화면번호 하드코딩이 있습니다: ${relative}:$($match.LineNumber)")
    }
}

# 제품별 설치 경로와 기본 데이터셋도 생산 코드에 두지 않아야 명령마다 DatasetPath를 명시적으로 선택할 수 있다.
$productionFiles = @($codeFiles | Where-Object { $_.FullName -notmatch '\\tests\\' })
$forbiddenTargetDefaults = @(
    ('C:' + '\' + '1QHTS'),
    ('1q-hts-' + 'account-inquiry.dataset.json')
)
foreach ($file in $productionFiles) {
    foreach ($forbiddenValue in $forbiddenTargetDefaults) {
        foreach ($match in @(Select-String -LiteralPath $file.FullName -SimpleMatch $forbiddenValue -Encoding UTF8)) {
            $relative = $file.FullName.Substring($root.Length).TrimStart('\')
            $failures.Add("대상별 기본값이 생산 코드에 있습니다: ${relative}:$($match.LineNumber)")
        }
    }
}

# 실행 전에 모든 PowerShell 파일을 파싱해 이동 과정의 dot-source 주변 구문 오류도 차단한다.
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Recurse -File -Filter '*.ps1') {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in @($parseErrors)) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\')
        $failures.Add("PowerShell 구문 오류: ${relative}:$($parseError.Extent.StartLineNumber) $($parseError.Message)")
    }

    # 함수 주석은 구현을 반복하지 않고 호출자가 알아야 할 목적·반환·안전 경계 중 하나를 설명해야 한다.
    $lines = Get-Content -LiteralPath $file.FullName -Encoding UTF8
    foreach ($functionAst in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
        $functionLine = $functionAst.Extent.StartLineNumber - 1
        $commentStart = [Math]::Max(0, $functionLine - 3)
        $precedingLines = if ($functionLine -gt 0) { $lines[$commentStart..($functionLine - 1)] -join "`n" } else { '' }
        if ($precedingLines -notmatch '(?m)^\s*#') {
            $relative = $file.FullName.Substring($root.Length).TrimStart('\')
            $failures.Add("PowerShell 함수 목적 주석이 없습니다: ${relative}:$($functionAst.Extent.StartLineNumber) $($functionAst.Name)")
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output "SOURCE_LAYOUT=PASS files=$($codeFiles.Count) manifest=$manifestPath"
