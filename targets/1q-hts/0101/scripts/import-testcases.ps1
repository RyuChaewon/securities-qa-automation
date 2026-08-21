<#
.SYNOPSIS 0101_TC를 19개 MAP family 기반 데이터셋과 generated-scenarios.json으로 변환한다.
#>
param(
    [string]$WorkbookPath = "",
    [string]$OutputDir = "outputs\0101_automation",
    [string]$InstallationRoot = "C:\1QHTS",
    [string]$AccountId = "",
    [string]$AccountNumber = "",
    [string]$AccountOwner = ""
)

$ErrorActionPreference = "Stop"
$targetRoot = Split-Path -Parent $PSScriptRoot
$root = [IO.Path]::GetFullPath((Join-Path $targetRoot '..\..\..'))
function Resolve-LocalPath([string]$Value) {
    if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
    return [IO.Path]::GetFullPath((Join-Path $root $Value))
}

$workbookFull = if ($WorkbookPath) {
    Resolve-LocalPath $WorkbookPath
} else {
    $candidateDir = Join-Path $root "outputs\0101_screen_testcases"
    $candidate = Get-ChildItem -LiteralPath $candidateDir -Filter "*.xlsx" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $candidate) { throw "0101 workbook not found: $candidateDir" }
    $candidate.FullName
}
$outputFull = Resolve-LocalPath $OutputDir
$installationFull = [IO.Path]::GetFullPath($InstallationRoot)
$targetProfilePath = Join-Path $targetRoot 'target-profile.json'
if (-not (Test-Path -LiteralPath $workbookFull -PathType Leaf)) { throw "0101 테스트케이스 파일을 찾을 수 없습니다: $workbookFull" }
if (-not (Test-Path -LiteralPath (Join-Path $installationFull "screen") -PathType Container)) { throw "HTS screen 폴더를 찾을 수 없습니다: $installationFull" }
New-Item -ItemType Directory -Path $outputFull -Force | Out-Null

$targetProfile = Get-Content -LiteralPath $targetProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$familyFiles = @($targetProfile.map.familyFiles | ForEach-Object { [string]$_ })
$requiredMapFamilyCount = [int]$targetProfile.adapter.import.requiredMapFamilyCount
if ($familyFiles.Count -ne $requiredMapFamilyCount) { throw "Target MAP family 카탈로그 수가 adapter 계약과 다릅니다." }
$missingMaps = @($familyFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $installationFull "screen\$_") -PathType Leaf) })
if ($missingMaps.Count -gt 0) { throw "설치본에서 MAP family 파일을 찾을 수 없습니다: $($missingMaps -join ', ')" }

$env:DOTNET_CLI_HOME = Join-Path $root ".dotnet-home"
& dotnet build (Join-Path $root "HtsQaPoc.sln") -c Release --no-restore | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Release 빌드에 실패했습니다." }
$cliProject = Join-Path $root "src\HtsQa.Cli\HtsQa.Cli.csproj"
$mapCatalogPath = Join-Path $outputFull "map-screen-models.json"
& dotnet run --project $cliProject -c Release --no-build -- extract-map-models --screen-dir (Join-Path $installationFull "screen") --installation-root $installationFull --screens (@($targetProfile.adapter.screenIds) -join ',') --file-pattern "" --family-files ($familyFiles -join ',') --out $mapCatalogPath | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $mapCatalogPath -PathType Leaf)) { throw "19개 MAP family 추출에 실패했습니다." }

$node = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
$nodeModules = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\node_modules"
if (-not (Test-Path -LiteralPath $node)) { throw "번들 Node.js를 찾을 수 없습니다: $node" }
if (-not (Test-Path -LiteralPath (Join-Path $nodeModules "@oai\artifact-tool"))) { throw "번들 artifact-tool을 찾을 수 없습니다." }
$junction = Join-Path $targetRoot "tools\node_modules"
if (-not (Test-Path -LiteralPath $junction)) { New-Item -ItemType Junction -Path $junction -Target $nodeModules | Out-Null }

$importArgs = @((Join-Path $targetRoot 'tools\import-testcases.mjs'), '--workbook', $workbookFull, '--map-catalog', $mapCatalogPath, '--target-profile', $targetProfilePath, '--output-dir', $outputFull)
if ($AccountId) { $importArgs += @('--account-id', $AccountId) }
if ($AccountNumber) { $importArgs += @('--account-number', $AccountNumber) }
if ($AccountOwner) { $importArgs += @('--account-owner', $AccountOwner) }
& $node @importArgs
if ($LASTEXITCODE -ne 0) { throw "0101_TC 변환에 실패했습니다." }

$datasetPath = Join-Path $outputFull "$(@($targetProfile.adapter.screenIds)[0]).dataset.json"
$scenarioPath = Join-Path $outputFull "generated-scenarios.json"
& dotnet run --project $cliProject -c Release --no-build -- validate-rule-dataset --file $datasetPath | Out-Null
if ($LASTEXITCODE -ne 0) { throw "생성된 0101 데이터셋 검증에 실패했습니다." }
& dotnet run --project $cliProject -c Release --no-build -- validate-generated-scenarios --file $scenarioPath --dataset $datasetPath --out (Join-Path $outputFull "scenario-validation.json") | Out-Null
if ($LASTEXITCODE -ne 0) { throw "생성된 0101 시나리오 검증에 실패했습니다." }
$approvalPath = Join-Path $outputFull "scenario-approval.json"
$sourceSha = (Get-FileHash -LiteralPath $scenarioPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (Test-Path -LiteralPath $approvalPath) {
    $existingApproval = Get-Content -LiteralPath $approvalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$existingApproval.sourceSha256 -ne $sourceSha) {
        $staleApprovalPath = Join-Path $outputFull ("scenario-approval.stale." + (Get-Date -Format "yyyyMMddHHmmss") + ".json")
        Move-Item -LiteralPath $approvalPath -Destination $staleApprovalPath
    }
}
if (-not (Test-Path -LiteralPath $approvalPath)) {
    & dotnet run --project $cliProject -c Release --no-build -- create-scenario-approval --file $scenarioPath --out $approvalPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "시나리오 승인 템플릿 생성에 실패했습니다." }
}

Write-Output $outputFull
