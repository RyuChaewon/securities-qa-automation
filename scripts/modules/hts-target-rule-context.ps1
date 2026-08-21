<#
.SYNOPSIS target-specific rule control 실행 상태와 외부 의존성 계약을 정의한다.
.DESCRIPTION 실행별 mutable 상태를 격리하고 Discovery/Binding/Action이 orchestration 함수 정의 순서에 의존하지 않게 한다.
#>
function New-HtsTargetRuleContext([string]$RootPath, $Dataset, $MapCatalog = $null, $Dependencies = $null) {
    $regionConfig = $null
    $targetAdapter = New-HtsTargetAdapterContext $Dataset.targetProfile
    $activeMapScreenCodes = @($Dataset.targetProfile.map.initiallyActiveMapScreenCodes | ForEach-Object {
        ([string]$_).Trim().ToUpperInvariant()
    } | Where-Object { $_ } | Select-Object -Unique)
    $configuredStrategy = [string]$Dataset.autoExploration.interactionStrategy
    $interactionStrategy = if ($configuredStrategy) { $configuredStrategy } else { 'RuntimeTabOrder' }
    $regionFile = [string]$Dataset.autoExploration.contentRegionFile
    if ($regionFile) {
        $regionPath = if ([IO.Path]::IsPathRooted($regionFile)) { $regionFile } else { Join-Path $RootPath $regionFile }
        if (Test-Path -LiteralPath $regionPath) {
            $regionConfig = Get-Content -LiteralPath $regionPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }

    [pscustomobject]@{
        RootPath = $RootPath
        Dataset = $Dataset
        TargetAdapter = $targetAdapter
        RegionConfig = $regionConfig
        MapCatalog = $MapCatalog
        MapTransformCache = @{}
        ActualTabOrderCache = @{}
        ActiveMapScreenCodes = $activeMapScreenCodes
        CurrentInteractionStrategy = $interactionStrategy
        FastScenarioDiscovery = $false
        LastLiveControlResolution = [pscustomobject]@{success=$false;errorCode='CONTROL_STALE';mode='Unresolved';candidateCount=0;evidence=@()}
        LastTextAutomationEngine = '미실행'
        Dependencies = $Dependencies
    }
}

function Invoke-HtsTargetRuleDependency($Context, [string]$Name, [object[]]$Arguments = @()) {
    if (-not $Context -or -not $Context.Dependencies -or -not ($Context.Dependencies.PSObject.Properties.Name -contains $Name)) {
        throw "TargetRule dependency가 없습니다: $Name"
    }
    $dependency = $Context.Dependencies.$Name
    if (-not ($dependency -is [scriptblock])) { throw "TargetRule dependency는 scriptblock이어야 합니다: $Name" }
    & $dependency @Arguments
}
