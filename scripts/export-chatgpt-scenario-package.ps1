<#
.SYNOPSIS 선택적 외부 시나리오 생성을 위한 비식별 요청자료 묶음을 만든다.
.DESCRIPTION MAP·설치 카탈로그·데이터셋 계약을 Node 생성기에 전달하며 실제 HTS는 조작하지 않는다.
#>
param(
    [string]$OutputDir = "",
    [string]$ScreensCsv = "",
    [Parameter(Mandatory = $true)]
    [string]$DatasetPath,
    [string]$RuntimePlanPath = "",
    [switch]$SkipZip
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "modules\pipeline-common.ps1")
$targetContext = Get-RuleTargetContext $root $DatasetPath $ScreensCsv
if (-not $OutputDir) {
    $OutputDir = Join-Path $root ("exports\chatgpt-scenario-package-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
} elseif (-not [IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $root $OutputDir
}
$outputFull = [IO.Path]::GetFullPath($OutputDir)
$rootFull = [IO.Path]::GetFullPath($root)
if (-not $outputFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "출력 폴더는 작업 폴더 내부여야 합니다: $outputFull"
}
if (Test-Path -LiteralPath $outputFull) {
    $existing = @(Get-ChildItem -LiteralPath $outputFull -Force)
    if ($existing.Count -gt 0) { throw "출력 폴더가 비어 있지 않습니다. 새 경로를 지정하세요: $outputFull" }
} else {
    New-Item -ItemType Directory -Path $outputFull -Force | Out-Null
}

$datasetFull = $targetContext.DatasetPath
$runtimeFull = if ($RuntimePlanPath) { Resolve-RulePath $root $RuntimePlanPath } else { "" }
if ($runtimeFull -and -not (Test-Path -LiteralPath $runtimeFull)) { throw "런타임 관찰 파일을 찾을 수 없습니다: $runtimeFull" }

$cliProject = Join-Path $root "src\HtsQa.Cli\HtsQa.Cli.csproj"
$catalogPath = Join-Path $outputFull ".source-map-screen-models.json"
$policyPath = Join-Path $root "docs\ERROR_JUDGMENT_POLICY.md"
$exporterPath = Join-Path $root "tools\export-chatgpt-scenario-package.mjs"

$mapArgs = @('run', '--project', $cliProject, '-c', 'Release', '--no-build', '--', 'extract-map-models', '--screen-dir', $targetContext.ScreenDirectory, '--installation-root', $targetContext.InstallationRoot, '--screens', ($targetContext.TargetScreens -join ','), '--file-pattern', $targetContext.MapFilePattern, '--out', $catalogPath)
if ($targetContext.MapFamilyFiles.Count -gt 0) { $mapArgs += @('--family-files', ($targetContext.MapFamilyFiles -join ',')) }
& dotnet @mapArgs | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $catalogPath)) {
    throw "HTS 설치본 시나리오 컨텍스트 추출에 실패했습니다."
}

$node = (Get-Command node -ErrorAction Stop).Source
$nodeArguments = @($exporterPath, '--map', $catalogPath, '--dataset', $datasetFull, '--policy', $policyPath, '--output', $outputFull)
if ($runtimeFull) { $nodeArguments += @('--runtime', $runtimeFull) }
& $node @nodeArguments
if ($LASTEXITCODE -ne 0) { throw "ChatGPT 시나리오 패키지 생성에 실패했습니다." }

$resolvedCatalog = [IO.Path]::GetFullPath($catalogPath)
if (-not $resolvedCatalog.StartsWith($outputFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "임시 카탈로그 경로가 출력 폴더 밖으로 계산되었습니다."
}
Remove-Item -LiteralPath $resolvedCatalog -Force

$zipPath = ""
if (-not $SkipZip) {
    $zipPath = $outputFull + ".zip"
    if (Test-Path -LiteralPath $zipPath) { throw "ZIP 경로가 이미 존재합니다. 새 출력 경로를 지정하세요: $zipPath" }
    Compress-Archive -Path (Join-Path $outputFull "*") -DestinationPath $zipPath -CompressionLevel Optimal
}

[pscustomobject]@{
    packageDirectory = $outputFull
    zipFile = $zipPath
    manifest = Join-Path $outputFull "PACKAGE_MANIFEST.json"
    prompt = Join-Path $outputFull "01_ChatGPT_요청문.md"
}
