<#
.SYNOPSIS 모든 실행 진입점이 공유하는 대상 프로필, 경로와 파이프라인 연결 정보를 제공한다.
.DESCRIPTION 이 파일은 직접 실행하는 프로그램이 아니라 다른 PowerShell 진입점에서 dot-source하는 공통 라이브러리다.
.INPUTS 저장소 루트, pipeline manifest, 대상 데이터셋 경로.
.OUTPUTS 정규화된 절대 경로, 검증된 진입점과 target context 객체.
.NOTES 대상별 값은 데이터셋 targetProfile에 두고 실행 파일 연결은 manifest에서만 변경한다.
#>

# 상대 경로를 지정한 기준 폴더 아래의 절대 경로로 바꾼다.
function Resolve-RulePath([string]$BasePath, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

# 파일명과 실행 ID에 사용할 수 없는 문자를 제거하고 빈 값에는 안정적인 기본 이름을 준다.
function ConvertTo-RuleSafeLabel([string]$Value, [string]$Fallback = 'target') {
    $label = ($Value -replace '[<>:"/\\|?*]', '-' -replace '\s+', '-').Trim('-')
    if ($label) { return $label }
    return $Fallback
}

# config/pipeline.manifest.json을 읽고 연결된 파일이 실제 저장소 안에 존재하는지 검증한다.
function Get-RulePipelineManifest([string]$RootPath) {
    $manifestPath = Join-Path $RootPath 'config\pipeline.manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "파이프라인 연결 명세를 찾을 수 없습니다: $manifestPath"
    }

    # BOM 유무와 관계없이 JSON을 읽고 필수 진입점 이름을 확인한다.
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # 오케스트레이터가 사용하는 공개 진입점은 누락 시 실행 도중이 아니라 시작 시 실패하게 한다.
    $requiredEntryPoints = @('automaticPipeline', 'targetRunner', 'recordedRunner', 'recorder', 'reportExporter', 'tcReportExporter', 'bindingPlanner', 'externalPipeline')
    foreach ($name in $requiredEntryPoints) {
        $property = $manifest.entryPoints.PSObject.Properties[$name]
        if (-not $property -or -not [string]$property.Value) {
            throw "파이프라인 명세에 필수 진입점이 없습니다: $name"
        }
        $resolved = Resolve-RulePath $RootPath ([string]$property.Value)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "파이프라인 진입점 파일을 찾을 수 없습니다: $name / $resolved"
        }
    }

    # .NET 명령과 dot-source 라이브러리도 같은 manifest 계약에 포함해 파일 이동 시 연결 누락을 탐지한다.
    foreach ($propertyName in @('solution', 'cliProject', 'flaUiProject')) {
        $relativePath = [string]$manifest.$propertyName
        $resolvedPath = Resolve-RulePath $RootPath $relativePath
        if (-not $relativePath -or -not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            throw "파이프라인 명세의 $propertyName 파일을 찾을 수 없습니다: $resolvedPath"
        }
    }
    foreach ($libraryPath in @($manifest.sharedLibraries)) {
        $resolvedLibrary = Resolve-RulePath $RootPath ([string]$libraryPath)
        if (-not (Test-Path -LiteralPath $resolvedLibrary -PathType Leaf)) {
            throw "파이프라인 공통 라이브러리를 찾을 수 없습니다: $resolvedLibrary"
        }
    }
    return $manifest
}

# manifest의 논리 이름을 실제 실행 파일 절대 경로로 변환한다.
function Get-RulePipelineEntryPoint($Manifest, [string]$RootPath, [string]$Name) {
    $property = $Manifest.entryPoints.PSObject.Properties[$Name]
    if (-not $property -or -not [string]$property.Value) {
        throw "알 수 없는 파이프라인 진입점입니다: $Name"
    }
    return Resolve-RulePath $RootPath ([string]$property.Value)
}

# 데이터셋의 targetProfile과 화면 선택을 실제 실행에서 사용할 단일 컨텍스트로 정규화한다.
function Get-RuleTargetContext(
    [string]$RootPath,
    [string]$DatasetPath,
    [string]$ScreensCsv = '',
    [string]$InstallationRootOverride = '') {
    $datasetFullPath = Resolve-RulePath $RootPath $DatasetPath
    if (-not (Test-Path -LiteralPath $datasetFullPath -PathType Leaf)) {
        throw "대상 데이터셋을 찾을 수 없습니다: $datasetFullPath"
    }

    # 데이터셋은 화면 범위뿐 아니라 창·MAP·실행 라벨을 함께 소유한다.
    $dataset = Get-Content -LiteralPath $datasetFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $profile = $dataset.targetProfile
    if (-not $profile) {
        throw 'targetProfile이 없는 구형 데이터셋입니다. 범용 실행을 위해 데이터셋을 schemaVersion 2.0으로 변환하세요.'
    }

    # 화면 ID 정규식을 미리 컴파일해 잘못된 프로필이 HTS를 열기 전에 실패하게 한다.
    try { $screenIdRegex = [regex]::new([string]$profile.screenIdPattern) }
    catch { throw "targetProfile.screenIdPattern이 올바른 정규식이 아닙니다: $($profile.screenIdPattern)" }

    # 현재 창과 MAP을 식별할 최소 계약을 PowerShell 단계에서도 확인해 모호한 경로 계산을 차단한다.
    if ([string]::IsNullOrWhiteSpace([string]$profile.window.className) -and
        [string]::IsNullOrWhiteSpace([string]$profile.window.titlePrefix)) {
        throw 'targetProfile.window.className과 titlePrefix 중 하나 이상이 필요합니다.'
    }
    if ([bool]$dataset.autoExploration.mapBaseline.enabled) {
        if ([string]::IsNullOrWhiteSpace([string]$profile.map.installationRoot)) { throw 'MAP 사용 시 targetProfile.map.installationRoot가 필요합니다.' }
        if ([string]::IsNullOrWhiteSpace([string]$profile.map.screenDirectory)) { throw 'MAP 사용 시 targetProfile.map.screenDirectory가 필요합니다.' }
        $familyFiles = @($profile.map.familyFiles | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if ($familyFiles.Count -eq 0 -and -not ([string]$profile.map.filePattern).Contains('{screenNumber}')) { throw 'MAP 파일 패턴에는 {screenNumber}가 필요합니다.' }
        $invalidFamilyFile = @($familyFiles | Where-Object { [IO.Path]::GetFileName($_) -ne $_ })
        if ($invalidFamilyFile.Count -gt 0) { throw 'MAP family에는 screen 폴더 기준 파일명만 사용할 수 있습니다.' }
    }

    $enabledScreens = @($dataset.screens | Where-Object { $_.enabled -ne $false } | ForEach-Object { [string]$_.screenNumber })
    $requestedScreens = @($ScreensCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $unknownScreens = @($requestedScreens | Where-Object { $enabledScreens -notcontains $_ })
    if ($unknownScreens.Count -gt 0) {
        throw "데이터셋에 등록되지 않았거나 비활성인 화면이 요청되었습니다: $($unknownScreens -join ', ')"
    }
    $targetScreens = if ($requestedScreens.Count -gt 0) { $requestedScreens } else { $enabledScreens }
    if ($targetScreens.Count -eq 0) { throw '실행할 활성 대상 화면이 없습니다.' }
    foreach ($screen in $targetScreens) {
        if (-not $screenIdRegex.IsMatch($screen)) {
            throw "대상 화면 ID가 targetProfile.screenIdPattern과 맞지 않습니다: $screen"
        }
    }

    # 계좌가 필요 없는 화면군도 동일한 케이스 생성기를 사용하도록 기본 실행 컨텍스트를 한 건 보충한다.
    if (-not $dataset.PSObject.Properties['accounts']) {
        $dataset | Add-Member -NotePropertyName accounts -NotePropertyValue @()
    }
    $configuredAccounts = @($dataset.accounts)
    if (@($configuredAccounts | Where-Object { $_.enabled -ne $false }).Count -eq 0) {
        $defaultContext = [pscustomobject]@{
            id = 'default'
            accountNumber = ''
            owner = ''
            inputMode = 'Prefilled'
            enabled = $true
            metadata = [pscustomobject]@{ purpose = '계좌 입력이 없는 일반 대상의 기본 실행 컨텍스트' }
        }
        $dataset.accounts = @($configuredAccounts) + @($defaultContext)
    }

    # 명령행 설치 경로는 일회성 환경 재정의이며, 없으면 데이터셋 프로필 값을 사용한다.
    $installationRoot = if ($InstallationRootOverride) {
        Resolve-RulePath $RootPath $InstallationRootOverride
    } else {
        Resolve-RulePath $RootPath ([string]$profile.map.installationRoot)
    }
    $screenDirectory = if ([IO.Path]::IsPathRooted([string]$profile.map.screenDirectory)) {
        [IO.Path]::GetFullPath([string]$profile.map.screenDirectory)
    } else {
        [IO.Path]::GetFullPath((Join-Path $installationRoot ([string]$profile.map.screenDirectory)))
    }

    # 호출 파일은 이 객체만 사용하므로 대상별 하드코딩이 각 스크립트로 다시 퍼지지 않는다.
    return [pscustomobject]@{
        DatasetPath = $datasetFullPath
        Dataset = $dataset
        ProfileId = [string]$profile.id
        DisplayName = [string]$profile.displayName
        RunLabel = ConvertTo-RuleSafeLabel ([string]$profile.runLabel) 'target-rule'
        ScreenIdPattern = [string]$profile.screenIdPattern
        WindowClassName = [string]$profile.window.className
        WindowTitlePrefix = [string]$profile.window.titlePrefix
        InstallationRoot = $installationRoot
        ScreenDirectory = $screenDirectory
        MapFilePattern = [string]$profile.map.filePattern
        MapFamilyFiles = @($profile.map.familyFiles | ForEach-Object { [string]$_ } | Where-Object { $_ })
        TargetScreens = @($targetScreens)
    }
}
