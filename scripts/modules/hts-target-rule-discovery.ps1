<#
.SYNOPSIS MAP과 런타임 HWND/UIA/탭오더를 결합해 화면 내부 컨트롤과 선택지를 발견한다.
.DESCRIPTION 콘텐츠 경계, 컨트롤 종류, 옵션, MAP 결합과 동적 재발견을 담당한다.
.INPUTS 현재 HTS 창 snapshot, MAP 화면 모델과 데이터셋 탐색 계약.
.OUTPUTS 발견 컨트롤, 탭 순서와 MAP 결합 결과 객체.
.NOTES UI 동작, 결과 판정과 리포트 생성은 수행하지 않는다.
#>
# 실행별 TargetRule 상태를 한 객체에 격리한다. 모듈 로드 시 mutable 상태를 만들지 않는다.
function New-HtsTargetRuleContext([string]$RootPath, $Dataset, $MapCatalog = $null, $Dependencies = $null) {
    $regionConfig = $null
    $orderTabStateByScreenMap = @{}
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
            foreach ($screenProperty in @($regionConfig.screens.PSObject.Properties)) {
                foreach ($orderTab in @($screenProperty.Value.orderTabs)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$orderTab.defaultValue)) {
                        $orderTabStateByScreenMap["$([string]$screenProperty.Name)|$(([string]$orderTab.mapScreenCode).ToUpperInvariant())"] = [string]$orderTab.defaultValue
                    }
                }
            }
        }
    }

    [pscustomobject]@{
        RootPath = $RootPath
        Dataset = $Dataset
        RegionConfig = $regionConfig
        MapCatalog = $MapCatalog
        MapTransformCache = @{}
        ActualTabOrderCache = @{}
        OrderTabStateByScreenMap = $orderTabStateByScreenMap
        ActiveMapScreenCodes = $activeMapScreenCodes
        CurrentInteractionStrategy = $interactionStrategy
        FastScenarioDiscovery = $false
        LastLiveControlResolution = [pscustomobject]@{success=$false;errorCode='CONTROL_STALE';mode='Unresolved';candidateCount=0;evidence=@()}
        LastTextAutomationEngine = '미실행'
        Dependencies = $Dependencies
    }
}

# 현재 화면 ID에 속한 컨테이너/탭 MAP 전체를 반환한다.
function Get-RuleMapScreenModels($Context, [string]$ScreenNumber) {
    if (-not $Context.MapCatalog -or -not $Context.MapCatalog.screens) { return $null }
    @($Context.MapCatalog.screens | Where-Object { [string]$_.screenNumber -eq $ScreenNumber } | Sort-Object screenCode)
}

# 시나리오가 지정한 내부 화면코드를 우선해 한 MAP을 선택한다.
function Get-RuleMapScreenModel($Context, [string]$ScreenNumber, [string]$MapScreenCode = '') {
    $models = @(Get-RuleMapScreenModels $Context $ScreenNumber)
    if ($MapScreenCode) {
        $match = @($models | Where-Object { [string]$_.screenCode -eq $MapScreenCode } | Select-Object -First 1)
        if ($match.Count -gt 0) { return $match[0] }
    }
    @($models | Select-Object -First 1)[0]
}

# MAP 종류와 런타임 종류의 호환도를 정확·호환·불일치 점수로 변환한다.
function Get-RuleMapCompatibility([string]$MapKind, [string]$RuntimeKind) {
    if ($MapKind -eq $RuntimeKind) { return 4 }
    switch ($MapKind) {
        "Text" { if ($RuntimeKind -in @("Date","ComboBox","Button")) { return 1 } }
        "Date" { if ($RuntimeKind -eq "Text") { return 3 } }
        "ComboBox" { if ($RuntimeKind -in @("Text","Button","RadioGroup")) { return 1 } }
        "CheckBox" { if ($RuntimeKind -in @("Button","RadioButton","RadioGroup")) { return 2 } }
        "RadioGroup" { if ($RuntimeKind -in @("CheckBox","RadioButton","Button")) { return 2 } }
    }
    0
}

# 물리 실행은 의미상 유사도가 아니라 실제 조작 종류의 호환성을 요구한다.
function Test-RuleRuntimeKindCompatible([string]$PlannedKind, [string]$RuntimeKind) {
    if (-not $RuntimeKind) { return $false }
    if (-not $PlannedKind -or $PlannedKind -eq 'Auto') { return $true }
    if ($PlannedKind -in @('Date','Text')) { return $RuntimeKind -in @('Date','Text') }
    $PlannedKind -eq $RuntimeKind
}

function Test-RuleControlExecutionEligible($Control) {
    if (-not $Control) { return $false }
    $rect = $Control.relativeRect
    $distance = if ($null -ne $Control.mapMatchDistance) { [double]$Control.mapMatchDistance } else { [double]::PositiveInfinity }
    $hostRequired = $Control.PSObject.Properties.Name -contains 'mapHostRequired' -and [bool]$Control.mapHostRequired
    $hostMatched = -not $hostRequired -or ($Control.PSObject.Properties.Name -contains 'mapHostMatched' -and [bool]$Control.mapHostMatched)
    $geometryExact = -not $hostRequired -or ($Control.PSObject.Properties.Name -contains 'mapGeometryExact' -and [bool]$Control.mapGeometryExact)
    $identityUnique = -not ($Control.PSObject.Properties.Name -contains 'runtimeIdentityUnique') -or [bool]$Control.runtimeIdentityUnique
    $ownerDrawnKindOverride = $hostMatched -and $geometryExact -and
        ($Control.PSObject.Properties.Name -contains 'allowOwnerDrawnKindOverride') -and [bool]$Control.allowOwnerDrawnKindOverride -and
        ([string]$Control.className).StartsWith('AfxWnd',[StringComparison]::OrdinalIgnoreCase)
    [string]$Control.definitionSource -eq 'MAP+Runtime' -and
        [bool]$Control.mapMatched -and
        ([string]$Control.locatorSignature).StartsWith('MAP|',[StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::IsNullOrWhiteSpace([string]$Control.className) -and
        [string]$Control.className -notin @('MapDefinition','ScenarioUnbound') -and
        -not [string]::IsNullOrWhiteSpace([string]$Control.automationEngine) -and
        $rect -and [int]$rect.width -gt 0 -and [int]$rect.height -gt 0 -and
        $distance -ge 0 -and $distance -le 24 -and
        $hostMatched -and $geometryExact -and $identityUnique -and
        ((Test-RuleRuntimeKindCompatible ([string]$Control.controlKind) ([string]$Control.runtimeControlKind)) -or $ownerDrawnKindOverride)
}

# TAB_Ord의 상태는 owner-drawn 자식 HWND의 원시 stateContext와 일치하지 않을 수 있다.
# 주문 탭 상태는 Select + AssertSelected 선행 단계로 실행기에서 검증하고, 여기서는
# 동일 MAP/논리 컨트롤의 물리 바인딩을 유지한다.
function Test-RuleStateContextMatch([string]$Expected, [string]$Actual) {
    if ([string]::IsNullOrWhiteSpace($Expected)) { return $true }
    if ($Expected -like 'order-tab:*') { return $true }
    [string]::Equals($Actual,$Expected,[StringComparison]::OrdinalIgnoreCase)
}

function Test-RuleOrderTabContext([string]$StateContext) {
    $StateContext -match '^order-tab:(buy|sell|modify-cancel|any)$'
}

# owner-drawn 주문 탭은 네이티브 TCM_* 메시지를 지원하지 않으므로 대상 프로필의
# 실측 탭 헤더와 탭별 검증 컨트롤을 사용한다.
function Get-RuleOrderTabProfile($Context, [string]$ScreenNumber, [string]$MapScreenCode, [string]$LogicalName) {
    if (-not $Context.RegionConfig -or -not $Context.RegionConfig.screens -or
        -not ($Context.RegionConfig.screens.PSObject.Properties.Name -contains $ScreenNumber)) { return $null }
    @($Context.RegionConfig.screens.$ScreenNumber.orderTabs | Where-Object {
        [string]::Equals([string]$_.mapScreenCode,$MapScreenCode,[StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$_.controlLogicalName,$LogicalName,[StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)[0]
}

function Get-RuleOrderTabItem($Profile, $Option) {
    if (-not $Profile -or -not $Option) { return $null }
    @($Profile.items | Where-Object { [string]$_.value -eq [string]$Option.value } | Select-Object -First 1)[0]
}

function Set-RuleOrderTabState($Context, [string]$ScreenNumber, [string]$MapScreenCode, [string]$Value) {
    if (-not $Context.OrderTabStateByScreenMap) { $Context.OrderTabStateByScreenMap = @{} }
    $Context.OrderTabStateByScreenMap["$ScreenNumber|$($MapScreenCode.ToUpperInvariant())"] = $Value
}

function Get-RuleOrderTabState($Context, [string]$ScreenNumber, [string]$MapScreenCode) {
    if (-not $Context.OrderTabStateByScreenMap) { return '' }
    [string]$Context.OrderTabStateByScreenMap["$ScreenNumber|$($MapScreenCode.ToUpperInvariant())"]
}

# 이름·역할·종류 일치도를 좌표 거리와 별개인 의미 점수로 계산한다.
function Get-RuleMapSemanticScore($MapControl, $RuntimeControl) {
    $logicalName = [string]$MapControl.logicalName
    $runtimeName = [string]$RuntimeControl.name
    $semanticRole = [string]$MapControl.semanticRole
    if ([string]$MapControl.kind -eq "Account" -and $runtimeName -match "계좌") { return 8 }
    if ([string]$MapControl.kind -eq "Password" -and $runtimeName -match "비밀번호") { return 8 }
    if ($semanticRole -eq "Query" -and $runtimeName -match "조회|검색") { return 10 }
    if ($semanticRole -eq "Export" -and $runtimeName -match "엑셀|저장|내보내기") { return 9 }
    if ($semanticRole -eq "Pagination" -and $runtimeName -match "다음|계속") { return 9 }
    if ($logicalName -match '^BTN_(Comm|Search|Query)' -and $runtimeName -match "조회") { return 6 }
    0
}

# MAP family의 각 내부 화면을 현재 컨테이너의 실제 호스트 영역에 고정한다.
function Get-RuleMapHostPolicy($Context, [string]$ScreenNumber, [string]$MapScreenCode) {
    if (-not $Context.RegionConfig -or -not $Context.RegionConfig.screens -or
        -not ($Context.RegionConfig.screens.PSObject.Properties.Name -contains $ScreenNumber)) { return $null }
    $screenPolicy = $Context.RegionConfig.screens.$ScreenNumber
    @($screenPolicy.mapHosts | Where-Object {
        [string]::Equals(([string]$_.mapScreenCode).Trim(),$MapScreenCode,[StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)[0]
}

# 설정된 hostRole을 화면의 대형 owner-drawn 컨테이너와 선택 탭으로 재식별한다.
function Get-RuleConfiguredMapHostTransform($Context, $Screen, $MapModel, $RuntimeControls) {
    $hostPolicy = Get-RuleMapHostPolicy $Context ([string]$MapModel.screenNumber) ([string]$MapModel.screenCode)
    if (-not $hostPolicy) { return $null }

    $runtimeRows = @($RuntimeControls | Where-Object { $_.relativeRect -and [Int64]$_.hwnd -ne 0 })
    $screenWidth = [int]$Screen.rect.width
    $wideHosts = @($runtimeRows | Where-Object {
        ([string]$_.className).StartsWith('AfxWnd',[StringComparison]::OrdinalIgnoreCase) -and
        [int]$_.relativeRect.width -ge [int]($screenWidth * 0.82) -and
        [int]$_.relativeRect.height -ge 160
    })
    $hostControl = $null
    $role = [string]$hostPolicy.hostRole
    if ($role -eq 'upperContent') {
        $hostControl = @($wideHosts | Where-Object {
            [int]$_.relativeRect.top -ge 12 -and [int]$_.relativeRect.top -le 100 -and
            [int]$_.relativeRect.height -ge 260 -and [int]$_.relativeRect.height -le 380
        } | Sort-Object @{Expression={[int]$_.relativeRect.top}},@{Expression={[Math]::Abs([int]$_.relativeRect.width-$screenWidth)}} | Select-Object -First 1)[0]
    } elseif ($role -eq 'selectedTabContent') {
        $tab = @($runtimeRows | Where-Object { [string]$_.className -eq 'SysTabControl32' } |
            Sort-Object @{Expression={[int]$_.relativeRect.top}} | Select-Object -Last 1)[0]
        if ($tab) {
            $selectedIndex = 0
            [void][int]::TryParse([string]$tab.initialValue,[ref]$selectedIndex)
            $requiredIndex = if ($null -ne $hostPolicy.tabIndex) { [int]$hostPolicy.tabIndex } else { $selectedIndex }
            if ($selectedIndex -eq $requiredIndex) {
                $tabBottom = [int]$tab.relativeRect.bottom
                $hostControl = @($wideHosts | Where-Object {
                    [int]$_.relativeRect.top -ge ($tabBottom-2) -and [int]$_.relativeRect.top -le ($tabBottom+18)
                } | Sort-Object @{Expression={[Math]::Abs([int]$_.relativeRect.top-$tabBottom)}},@{Expression={[Math]::Abs([int]$_.relativeRect.height-[int]$MapModel.designHeight)}} | Select-Object -First 1)[0]
            }
        }
    }

    $scale = if ($null -ne $hostPolicy.scale -and [double]$hostPolicy.scale -gt 0) { [double]$hostPolicy.scale } else { 1.0 }
    $hostId = "$([string]$hostPolicy.containerScreenCode):${role}:$([string]$MapModel.screenCode)"
    if (-not $hostControl) {
        return [pscustomobject]@{
            scale=$scale;offsetX=0;offsetY=0;tolerance=0;matches=0;score=0
            hostRequired=$true;hostMatched=$false;hostId=$hostId;hostRole=$role;hostRect=$null
            clipMapHeight=$(if($null -ne $hostPolicy.clipMapHeight){[int]$hostPolicy.clipMapHeight}else{0})
            maxDimensionDeltaPx=$(if($null -ne $hostPolicy.maxDimensionDeltaPx){[int]$hostPolicy.maxDimensionDeltaPx}else{12})
            allowOwnerDrawnKindOverride=[bool]$hostPolicy.allowOwnerDrawnKindOverride
        }
    }

    $originX = if ($null -ne $hostPolicy.mapOriginX) { [double]$hostPolicy.mapOriginX } else { 0.0 }
    $originY = if ($null -ne $hostPolicy.mapOriginY) { [double]$hostPolicy.mapOriginY } else { 0.0 }
    [pscustomobject]@{
        scale=$scale
        offsetX=[int][Math]::Round([double]$hostControl.relativeRect.left-($originX*$scale))
        offsetY=[int][Math]::Round([double]$hostControl.relativeRect.top-($originY*$scale))
        tolerance=$(if($null -ne $hostPolicy.matchTolerancePx){[int]$hostPolicy.matchTolerancePx}else{8})
        matches=0;score=0
        hostRequired=$true;hostMatched=$true;hostId=$hostId;hostRole=$role;hostRect=$hostControl.relativeRect
        clipMapHeight=$(if($null -ne $hostPolicy.clipMapHeight){[int]$hostPolicy.clipMapHeight}else{0})
        maxDimensionDeltaPx=$(if($null -ne $hostPolicy.maxDimensionDeltaPx){[int]$hostPolicy.maxDimensionDeltaPx}else{12})
        allowOwnerDrawnKindOverride=[bool]$hostPolicy.allowOwnerDrawnKindOverride
    }
}

function Get-RuleMapGeometry($MapControl, $RuntimeControl, $Transform) {
    $scale = [double]$Transform.scale
    $left = ([double]$MapControl.rect.x*$scale)+[int]$Transform.offsetX
    $top = ([double]$MapControl.rect.y*$scale)+[int]$Transform.offsetY
    $width = [double]$MapControl.rect.width*$scale
    $height = [double]$MapControl.rect.height*$scale
    $centerX = $left+($width/2.0)
    $centerY = $top+($height/2.0)
    $dx = [double]$RuntimeControl.relativeRect.centerX-$centerX
    $dy = [double]$RuntimeControl.relativeRect.centerY-$centerY
    $centerDistance = [Math]::Sqrt(($dx*$dx)+($dy*$dy))
    $widthDelta = [Math]::Abs([double]$RuntimeControl.relativeRect.width-$width)
    $heightDelta = [Math]::Abs([double]$RuntimeControl.relativeRect.height-$height)
    [pscustomobject]@{
        centerDistance=$centerDistance;widthDelta=$widthDelta;heightDelta=$heightDelta
        score=$centerDistance+(($widthDelta+$heightDelta)*0.25)
    }
}

# MAP 디자인 좌표를 현재 DPI·창 크기의 물리 좌표로 옮기는 스케일과 오프셋을 구한다.
function Get-RuleMapTransform($Context, $Screen, $MapModel, $RuntimeControls) {
    $cacheKey = "$($Screen.hwnd)|$($MapModel.sourceSha256)"
    if ($Context.MapTransformCache.ContainsKey($cacheKey)) { return $Context.MapTransformCache[$cacheKey] }
    $mapControls = @($MapModel.controls | Where-Object isActionable)
    $runtimeControls = @($RuntimeControls | Where-Object { $_.relativeRect -and [Int64]$_.hwnd -ne 0 })
    $configuredHost = Get-RuleConfiguredMapHostTransform $Context $Screen $MapModel $runtimeControls
    if ($configuredHost) {
        $Context.MapTransformCache[$cacheKey] = $configuredHost
        return $configuredHost
    }
    $configuredTolerance = [int]$Context.Dataset.autoExploration.mapBaseline.matchTolerancePx
    $tolerance = if ($configuredTolerance -gt 0) { $configuredTolerance } else { 36 }
    if ($Context.FastScenarioDiscovery) {
        $scale = 1.0
        if ([int]$MapModel.designWidth -gt 0) {
            $widthScale = [double]$Screen.rect.width / [double]$MapModel.designWidth
            if ($widthScale -ge 0.75 -and $widthScale -le 2.5) { $scale = $widthScale }
        }
        $fastTransform = [pscustomobject]@{
            scale = [double]$scale
            offsetX = 0
            offsetY = 0
            tolerance = [Math]::Max($tolerance, 48)
            matches = 0
            score = 0
            hostRequired = $false
            hostMatched = $true
            hostId = ''
            hostRole = ''
            hostRect = $null
            clipMapHeight = 0
            maxDimensionDeltaPx = 0
            allowOwnerDrawnKindOverride = $false
        }
        $Context.MapTransformCache[$cacheKey] = $fastTransform
        return $fastTransform
    }
    $scales = New-Object Collections.Generic.List[double]
    try {
        $dpi = [int][TargetRuleNative]::GetDpiForWindow([IntPtr][Int64]$Screen.hwnd)
        if ($dpi -ge 72 -and $dpi -le 480) { $scales.Add($dpi / 96.0) }
    } catch {}
    foreach ($scale in @(1.0,1.25,1.5,1.75,2.0)) {
        if (@($scales | Where-Object { [Math]::Abs($_-$scale) -lt 0.001 }).Count -eq 0) { $scales.Add($scale) }
    }
    if ([int]$MapModel.designWidth -gt 0) {
        $widthScale = [double]$Screen.rect.width / [double]$MapModel.designWidth
        if ($widthScale -ge 0.75 -and $widthScale -le 2.5) { $scales.Add($widthScale) }
    }

    $candidates = New-Object Collections.Generic.List[object]
    foreach ($scale in @($scales | Sort-Object -Unique)) {
        foreach ($mapControl in $mapControls) {
            foreach ($runtimeControl in $runtimeControls) {
                if ((Get-RuleMapCompatibility ([string]$mapControl.ruleControlKind) ([string]$runtimeControl.controlKind)) -le 0) { continue }
                $candidates.Add([pscustomobject]@{
                    scale=[double]$scale
                    offsetX=[int][Math]::Round([double]$runtimeControl.relativeRect.centerX-([double]$mapControl.rect.centerX*[double]$scale))
                    offsetY=[int][Math]::Round([double]$runtimeControl.relativeRect.centerY-([double]$mapControl.rect.centerY*[double]$scale))
                })
            }
        }
    }
    if ($candidates.Count -eq 0) { $candidates.Add([pscustomobject]@{scale=1.0;offsetX=0;offsetY=0}) }
    $candidates = @($candidates | Group-Object { "{0:F3}|{1}|{2}" -f $_.scale,$_.offsetX,$_.offsetY } | ForEach-Object { $_.Group[0] } | Select-Object -First 1200)

    $best = $null
    foreach ($candidate in $candidates) {
        $used = @{}
        $matches = 0
        $semantic = 0
        $distanceTotal = 0.0
        foreach ($mapControl in $mapControls) {
            $predictedX = ([double]$mapControl.rect.centerX*[double]$candidate.scale)+[int]$candidate.offsetX
            $predictedY = ([double]$mapControl.rect.centerY*[double]$candidate.scale)+[int]$candidate.offsetY
            $nearest = $null
            $nearestDistance = [double]::MaxValue
            foreach ($runtimeControl in $runtimeControls) {
                $runtimeKey = [string]$runtimeControl.controlId
                if ($used.ContainsKey($runtimeKey)) { continue }
                $compatibility = Get-RuleMapCompatibility ([string]$mapControl.ruleControlKind) ([string]$runtimeControl.controlKind)
                if ($compatibility -le 0) { continue }
                $dx = [double]$runtimeControl.relativeRect.centerX-$predictedX
                $dy = [double]$runtimeControl.relativeRect.centerY-$predictedY
                $distance = [Math]::Sqrt(($dx*$dx)+($dy*$dy))
                if ($distance -le $tolerance -and $distance -lt $nearestDistance) {
                    $nearest=$runtimeControl; $nearestDistance=$distance
                }
            }
            if ($nearest) {
                $used[[string]$nearest.controlId]=$true
                $matches++
                $semantic += Get-RuleMapSemanticScore $mapControl $nearest
                $distanceTotal += $nearestDistance
            }
        }
        $score = ($matches*1000)+($semantic*100)-$distanceTotal
        if (-not $best -or $score -gt [double]$best.score) {
            $best=[pscustomobject]@{
                scale=[double]$candidate.scale;offsetX=[int]$candidate.offsetX;offsetY=[int]$candidate.offsetY
                tolerance=$tolerance;matches=$matches;score=$score
                hostRequired=$false;hostMatched=$true;hostId='';hostRole='';hostRect=$null
                clipMapHeight=0;maxDimensionDeltaPx=0;allowOwnerDrawnKindOverride=$false
            }
        }
    }
    $Context.MapTransformCache[$cacheKey]=$best
    $best
}

# 기대 계약 추론: 데이터셋, 설치 사전, 마스터, MAP 검증과 런타임 선택지의 우선순위를 값마다 기록한다.
function New-RuleExpectedOutcome([string]$Type, [string]$Source, [string]$Confidence, $Evidence = @(), $MessagePatterns = @(), $ErrorCodes = @(), $QueryShouldComplete = $null) {
    [pscustomobject]@{
        type=$Type;source=$Source;confidence=$Confidence
        evidence=@($Evidence | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        messagePatterns=@($MessagePatterns | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        errorCodes=@($ErrorCodes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        queryShouldComplete=$QueryShouldComplete
    }
}

# 선택지에 포함된 기대 계약을 누락 필드 없이 정규화한다.
function Get-RuleOptionOutcome($Option) {
    if ($Option -and $Option.expectedOutcome) { return $Option.expectedOutcome }
    New-RuleExpectedOutcome 'Unspecified' 'Unspecified' 'Unspecified'
}

# 현재 MAP 컨트롤을 대상으로 하는 입력 검증 메시지만 추린다.
function Get-RuleMapControlValidationMessages($MapModel, $MapControl) {
    if (-not $MapModel -or -not $MapModel.errorOracle -or -not $MapControl) { return @() }
    @($MapModel.errorOracle.messageBoxes | Where-Object {
        [string]$_.classification -eq 'InputValidation' -and
        (@($_.targetControls) -contains [string]$MapControl.logicalName)
    })
}

# 데이터셋·설치 사전·MAP 조건·런타임 선택지 순으로 값별 기대 계약을 보충한다.
function Set-RuleInferredExpectedOutcomes($RuntimeControl, $MapControl = $null, $MapModel = $null) {
    if (-not $RuntimeControl -or @($RuntimeControl.options).Count -eq 0) { return }
    $kind=[string]$RuntimeControl.controlKind
    $mapKind=if($MapControl){[string]$MapControl.kind}else{''}
    $role=if($MapControl){[string]$MapControl.semanticRole}else{''}
    $validationMessages=@(Get-RuleMapControlValidationMessages $MapModel $MapControl)
    $validationPatterns=@($validationMessages | ForEach-Object {[regex]::Escape(([string]$_.message).Trim())} | Where-Object {$_} | Sort-Object -Unique)
    $validationEvidence=@($validationMessages | ForEach-Object {
        $condition=if([string]$_.conditionExpression){" / 조건: $([string]$_.conditionExpression)"}else{''}
        "MAP $([string]$_.ruleId): $([string]$_.message)$condition"
    })
    $mapConfidence=if(@($validationMessages | Where-Object conditionExpression).Count -gt 0){'High'}else{'Medium'}

    foreach($option in @($RuntimeControl.options)) {
        if(-not ($option.PSObject.Properties.Name -contains 'expectedOutcome')){
            $option | Add-Member -NotePropertyName expectedOutcome -NotePropertyValue (New-RuleExpectedOutcome 'Unspecified' 'Unspecified' 'Unspecified')
        }
        $current=Get-RuleOptionOutcome $option
        $currentType=if($current.type){[string]$current.type}else{'Unspecified'}
        $currentPatterns=@($current.messagePatterns)
        $currentCodes=@($current.errorCodes)
        $currentEvidence=@($current.evidence)
        $source=if($current.source){[string]$current.source}else{'Unspecified'}
        $confidence=if($current.confidence){[string]$current.confidence}else{'Unspecified'}
        $labelSource=[string]$option.labelSource

        if($source -eq 'Unspecified' -and $currentType -ne 'Unspecified') {
            if($labelSource -eq 'dataset'){$source='DatasetDefault';$confidence='Medium';$currentEvidence += '데이터셋 자동 탐색 기본값'}
            else{$source='Dataset';$confidence='High';$currentEvidence += '데이터셋 명시 기대 결과'}
        }

        if($mapKind -eq 'Instrument' -and $labelSource -notlike 'HTS종목마스터:*') {
            $value=[string]$option.value
            $patterns=@($currentPatterns)+@($validationPatterns)+@('종목코드오류|등록되지 않은 종목코드|종목코드.*확인')
            if($value -notmatch '^[A-Za-z0-9]{6}$') {
                $option.expectedOutcome=New-RuleExpectedOutcome 'ValidationRequired' 'GeneratedBoundary' 'High' (@($currentEvidence)+@($validationEvidence)+@('HTS 종목 마스터 코드 형식은 영문·숫자 6자리')) $patterns @() $false
                continue
            }
            if($currentType -ne 'Success') {
                $option.expectedOutcome=New-RuleExpectedOutcome 'ValidationAllowed' 'GeneratedBoundary' 'Medium' (@($currentEvidence)+@($validationEvidence)+@('종목 마스터 전체 포함 여부를 확정하지 못한 자동 입력값')) $patterns @() $false
                continue
            }
        }

        if($kind -eq 'Date' -and $validationMessages.Count -gt 0) {
            $parsed=[datetime]::MinValue
            $isDate=[datetime]::TryParseExact([string]$option.value,'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)
            $futureMessages=@($validationMessages | Where-Object {[string]$_.message -match '당일\s*이후|당월\s*이후'})
            if($isDate -and $parsed.Date -gt (Get-Date).Date -and $futureMessages.Count -gt 0) {
                $futurePatterns=@($futureMessages | ForEach-Object {[regex]::Escape(([string]$_.message).Trim())})
                $futureEvidence=@($futureMessages | ForEach-Object {"MAP $([string]$_.ruleId): $([string]$_.message) / 조건: $([string]$_.conditionExpression)"})
                $option.expectedOutcome=New-RuleExpectedOutcome 'ValidationRequired' 'MapValidation' $(if(@($futureMessages | Where-Object conditionExpression).Count){'High'}else{'Medium'}) $futureEvidence $futurePatterns @() $false
                continue
            }
        }

        if($validationMessages.Count -gt 0) {
            $allPatterns=@($currentPatterns)+@($validationPatterns)
            $allEvidence=@($currentEvidence)+@($validationEvidence)
            $required=$false
            if([string]::IsNullOrWhiteSpace([string]$option.value) -and @($validationMessages | Where-Object {[string]$_.message -match '입력|선택|확인|필수'}).Count -gt 0){$required=$true}
            $type=if($required){'ValidationRequired'}elseif($currentType -in @('ValidationRequired','FailureRequired')){$currentType}else{'ValidationAllowed'}
            $option.expectedOutcome=New-RuleExpectedOutcome $type 'MapValidation' $mapConfidence $allEvidence $allPatterns $currentCodes $(if($required){$false}else{$current.queryShouldComplete})
            continue
        }

        if($currentType -ne 'Unspecified') {
            $option.expectedOutcome=New-RuleExpectedOutcome $currentType $source $confidence $currentEvidence $currentPatterns $currentCodes $current.queryShouldComplete
            continue
        }

        if($kind -in @('ComboBox','RadioButton','RadioGroup','CheckBox','Tab','ListBox','Slider','Spin')) {
            $option.expectedOutcome=New-RuleExpectedOutcome 'Success' 'RuntimeChoice' 'Medium' @("활성 컨트롤에서 런타임에 발견한 유한 선택지: $labelSource") @() @() $true
        } elseif($kind -eq 'Button' -and $role -in @('Query','AutoQuery')) {
            $option.expectedOutcome=New-RuleExpectedOutcome 'Success' 'MapBehavior' 'High' @("MAP 조회 역할: $([string]$MapControl.logicalName)") @() @() $true
        } elseif($kind -eq 'Button') {
            $buttonSource=if($MapControl){'MapBehavior'}else{'RuntimeChoice'}
            $buttonConfidence=if($MapControl){'High'}else{'Medium'}
            $option.expectedOutcome=New-RuleExpectedOutcome 'ObservationOnly' $buttonSource $buttonConfidence @("명령 버튼 반응 관찰: $labelSource")
        } else {
            $option.expectedOutcome=New-RuleExpectedOutcome 'Unspecified' 'Unspecified' 'Unspecified'
        }
    }
}

# 정적 MAP과 설치 사전의 유한 선택지를 런타임 컨트롤 옵션에 중복 없이 병합한다.
function Set-RuleMapControlOptions($Context, $RuntimeControl, $MapControl, $MapModel = $null) {
    $kind = [string]$MapControl.ruleControlKind
    $staticOptions = @($MapControl.staticOptions)
    if ($staticOptions.Count -gt 0) {
        $official = @($staticOptions | ForEach-Object {
            $outcome=if($_.expectedOutcome -and [string]$_.expectedOutcome.type -ne 'Unspecified'){$_.expectedOutcome}else{New-RuleExpectedOutcome 'Success' 'InstallationInputOption' 'High' @("HTS 설치 입력 사전: $([string]$_.source)") @() @() $true}
            [pscustomobject]@{id=[string]$_.id;value=[string]$_.value;displayValue=[string]$_.displayValue;labelSource="HTS설치데이터:$([string]$_.source)";index=[int]$_.index;expectedOutcome=$outcome}
        })
        if (@($RuntimeControl.options).Count -eq 0 -or @($RuntimeControl.options).Count -eq $official.Count) {
            $RuntimeControl.options = $official
        }
        $RuntimeControl | Add-Member -NotePropertyName mapOptionSource -NotePropertyValue ([string]$MapControl.optionSource) -Force
    }
    if ([string]$MapControl.kind -eq 'Instrument' -and $Context.MapCatalog -and $Context.MapCatalog.masterDataSources) {
        $existingOptions=@($RuntimeControl.options)
        $limit = [Math]::Max(1,[int]$Context.Dataset.autoExploration.maxOptionsPerControl)
        $instrumentOptions = @($Context.MapCatalog.masterDataSources | ForEach-Object {
            $source=[string]$_.id
            @($_.samples) | ForEach-Object {
                $outcome=if($_.expectedOutcome -and [string]$_.expectedOutcome.type -ne 'Unspecified'){$_.expectedOutcome}else{New-RuleExpectedOutcome 'Success' 'InstallationMaster' 'High' @("HTS 설치 종목 마스터: $source") @() @() $true}
                [pscustomobject]@{id="$source-$([string]$_.code)";value=[string]$_.code;displayValue="$([string]$_.code) $([string]$_.name) [$([string]$_.market)]";labelSource="HTS종목마스터:$source";index=0;expectedOutcome=$outcome}
            }
        } | Group-Object value | ForEach-Object {$_.Group[0]})
        $mergedInstrumentOptions=@($instrumentOptions)+@($existingOptions)
        $mergedInstrumentOptions=@($mergedInstrumentOptions | Group-Object value | ForEach-Object {$_.Group[0]} | Select-Object -First $limit)
        if ($mergedInstrumentOptions.Count -gt 0) { $RuntimeControl.options=$mergedInstrumentOptions }
    }
    switch ($kind) {
        "Button" {
            $RuntimeControl.options=@([pscustomobject]@{id="click";value="click";displayValue=[string]$MapControl.logicalName;labelSource="map";index=0})
        }
        "CheckBox" {
            $RuntimeControl.options=@(
                [pscustomobject]@{id="current";value="current";displayValue="현재 상태";labelSource="map+runtime";index=0},
                [pscustomobject]@{id="toggled";value="toggle";displayValue="반대 상태";labelSource="map+runtime";index=1}
            )
        }
        "RadioGroup" {
            $count=[Math]::Max(2,[Math]::Min(12,[int][Math]::Round([double]$MapControl.rect.width/52.0)))
            $RuntimeControl.options=@(for($index=0;$index-lt$count;$index++){
                [pscustomobject]@{id="option-$index";value=[string]$index;displayValue="라디오 항목 $($index+1)";labelSource="mapGeometry";index=$index}
            })
        }
    }
    Set-RuleInferredExpectedOutcomes $RuntimeControl $MapControl $MapModel
}

# MAP 정의를 물리 좌표·종류·의미 점수로 런타임 컨트롤에 일대일 결합한다.
function Merge-RuleSingleMapBaseline($Context, $Screen, [string]$ScreenNumber, $RuntimeControls, $mapModel, [bool]$IncludeRuntimeOnly = $true) {
    $runtimeRows = @($RuntimeControls)
    if (-not $mapModel) {
        foreach ($runtimeControl in $runtimeRows) {
            $runtimeControl | Add-Member -NotePropertyName definitionSource -NotePropertyValue "RuntimeOnly" -Force
            $runtimeControl | Add-Member -NotePropertyName mapMatched -NotePropertyValue $false -Force
            Set-RuleInferredExpectedOutcomes $runtimeControl
        }
        return $runtimeRows
    }

    $transform = Get-RuleMapTransform $Context $Screen $mapModel $runtimeRows
    $usedRuntime = @{}
    $merged = New-Object Collections.Generic.List[object]
    $actionableMapControls = @($mapModel.controls | Where-Object isActionable | Sort-Object definitionOrder)
    $orderTabProfile = Get-RuleOrderTabProfile $Context $ScreenNumber ([string]$mapModel.screenCode) 'TAB_Ord'
    $activeOrderTabValue = Get-RuleOrderTabState $Context $ScreenNumber ([string]$mapModel.screenCode)
    if ($orderTabProfile -and $activeOrderTabValue) {
        $activeOrderTabItem = @($orderTabProfile.items | Where-Object { [string]$_.value -eq $activeOrderTabValue } | Select-Object -First 1)[0]
        $allOrderCommands = @($orderTabProfile.items | ForEach-Object { @($_.verificationControls) } | Sort-Object -Unique)
        $activeOrderCommands = @($activeOrderTabItem.verificationControls)
        $actionableMapControls = @($actionableMapControls | Where-Object {
            $allOrderCommands -notcontains [string]$_.logicalName -or $activeOrderCommands -contains [string]$_.logicalName
        })
    }
    foreach ($mapControl in $actionableMapControls) {
        $predictedX = ([double]$mapControl.rect.centerX*[double]$transform.scale)+[int]$transform.offsetX
        $predictedY = ([double]$mapControl.rect.centerY*[double]$transform.scale)+[int]$transform.offsetY
        $nearest = $null
        $nearestDistance = [double]::MaxValue
        $nearestGeometry = $null
        $insideClip = [int]$transform.clipMapHeight -le 0 -or [double]$mapControl.rect.centerY -le [int]$transform.clipMapHeight
        if ($insideClip -and (-not [bool]$transform.hostRequired -or [bool]$transform.hostMatched)) {
            foreach ($runtimeControl in $runtimeRows) {
                $runtimeKey=if([Int64]$runtimeControl.hwnd-ne0){"H:$([Int64]$runtimeControl.hwnd)"}else{"C:$([string]$runtimeControl.controlId)"}
                if ($usedRuntime.ContainsKey($runtimeKey)) { continue }
                if ([bool]$transform.hostRequired -and $transform.hostRect) {
                    $hostRect = $transform.hostRect
                    if ([double]$runtimeControl.relativeRect.centerX -lt ([double]$hostRect.left-2) -or
                        [double]$runtimeControl.relativeRect.centerX -gt ([double]$hostRect.right+2) -or
                        [double]$runtimeControl.relativeRect.centerY -lt ([double]$hostRect.top-2) -or
                        [double]$runtimeControl.relativeRect.centerY -gt ([double]$hostRect.bottom+2)) { continue }
                }
                $geometry = Get-RuleMapGeometry $mapControl $runtimeControl $transform
                $compatibility = Get-RuleMapCompatibility ([string]$mapControl.ruleControlKind) ([string]$runtimeControl.controlKind)
                $ownerDrawnOverride = [bool]$transform.hostRequired -and [bool]$transform.allowOwnerDrawnKindOverride -and
                    ([string]$runtimeControl.className).StartsWith('AfxWnd',[StringComparison]::OrdinalIgnoreCase) -and
                    [double]$geometry.centerDistance -le [int]$transform.tolerance -and
                    [double]$geometry.widthDelta -le [int]$transform.maxDimensionDeltaPx -and
                    [double]$geometry.heightDelta -le [int]$transform.maxDimensionDeltaPx
                if ($compatibility -le 0 -and -not $ownerDrawnOverride) { continue }
                if ([bool]$transform.hostRequired) {
                    if ([double]$geometry.centerDistance -gt [int]$transform.tolerance -or
                        [double]$geometry.widthDelta -gt [int]$transform.maxDimensionDeltaPx -or
                        [double]$geometry.heightDelta -gt [int]$transform.maxDimensionDeltaPx) { continue }
                    $distance = [double]$geometry.score
                } else {
                    $distance = [double]$geometry.centerDistance
                    if ($distance -gt [int]$transform.tolerance) { continue }
                }
                if ($distance -lt $nearestDistance) {
                    $nearest=$runtimeControl; $nearestDistance=$distance; $nearestGeometry=$geometry
                }
            }
        }
        if ($nearest) {
            $nearestRuntimeKey=if([Int64]$nearest.hwnd-ne0){"H:$([Int64]$nearest.hwnd)"}else{"C:$([string]$nearest.controlId)"}
            $usedRuntime[$nearestRuntimeKey]=$true
            $runtimeName=[string]$nearest.name
            $runtimeKind=[string]$nearest.controlKind
            $nearest.controlId=[string]$mapControl.modelId
            $nearest.name=[string]$mapControl.logicalName
            $nearest.controlKind=[string]$mapControl.ruleControlKind
            $nearest.locatorSignature="MAP|$($mapControl.modelId)|$([string]$transform.hostId)|$($nearest.className)|$($nearest.stateContext)"
            $nearest | Add-Member -NotePropertyName definitionSource -NotePropertyValue "MAP+Runtime" -Force
            $nearest | Add-Member -NotePropertyName runtimeName -NotePropertyValue $runtimeName -Force
            $nearest | Add-Member -NotePropertyName runtimeControlKind -NotePropertyValue $runtimeKind -Force
            $nearest | Add-Member -NotePropertyName mapModelId -NotePropertyValue ([string]$mapControl.modelId) -Force
            $nearest | Add-Member -NotePropertyName mapScreenCode -NotePropertyValue ([string]$mapModel.screenCode) -Force
            $nearest | Add-Member -NotePropertyName mapTypeCode -NotePropertyValue ([string]$mapControl.typeCode) -Force
            $nearest | Add-Member -NotePropertyName mapKind -NotePropertyValue ([string]$mapControl.kind) -Force
            $nearest | Add-Member -NotePropertyName mapDefinitionOrder -NotePropertyValue ([int]$mapControl.definitionOrder) -Force
            $nearest | Add-Member -NotePropertyName mapMatched -NotePropertyValue $true -Force
            $nearest | Add-Member -NotePropertyName mapMatchDistance -NotePropertyValue ([Math]::Round([double]$nearestGeometry.centerDistance,2)) -Force
            $nearest | Add-Member -NotePropertyName mapGeometryDelta -NotePropertyValue ([Math]::Round(([double]$nearestGeometry.widthDelta+[double]$nearestGeometry.heightDelta),2)) -Force
            $nearest | Add-Member -NotePropertyName mapGeometryExact -NotePropertyValue $true -Force
            $nearest | Add-Member -NotePropertyName mapHostRequired -NotePropertyValue ([bool]$transform.hostRequired) -Force
            $nearest | Add-Member -NotePropertyName mapHostMatched -NotePropertyValue ([bool]$transform.hostMatched) -Force
            $nearest | Add-Member -NotePropertyName mapHostId -NotePropertyValue ([string]$transform.hostId) -Force
            $nearest | Add-Member -NotePropertyName runtimeIdentityUnique -NotePropertyValue $true -Force
            $nearest | Add-Member -NotePropertyName allowOwnerDrawnKindOverride -NotePropertyValue ([bool]$transform.allowOwnerDrawnKindOverride) -Force
            $nearest | Add-Member -NotePropertyName mapEvents -NotePropertyValue @($mapControl.events) -Force
            $nearest | Add-Member -NotePropertyName mapSemanticRole -NotePropertyValue ([string]$mapControl.semanticRole) -Force
            $nearest | Add-Member -NotePropertyName mapTriggeredRequests -NotePropertyValue @($mapControl.triggeredRequestNames) -Force
            $nearest | Add-Member -NotePropertyName mapReadControls -NotePropertyValue @($mapControl.readControls) -Force
            $nearest | Add-Member -NotePropertyName mapAffectedControls -NotePropertyValue @($mapControl.affectedControls) -Force
            $nearest | Add-Member -NotePropertyName mapResultControls -NotePropertyValue @($mapControl.resultControls) -Force
            $nearest | Add-Member -NotePropertyName mapInvokedHandlers -NotePropertyValue @($mapControl.invokedHandlers) -Force
            $nearest | Add-Member -NotePropertyName mapNavigationTargets -NotePropertyValue @($mapControl.navigationTargets) -Force
            $nearest | Add-Member -NotePropertyName mapOptionSource -NotePropertyValue ([string]$mapControl.optionSource) -Force
            $nearest | Add-Member -NotePropertyName mapRect -NotePropertyValue $mapControl.rect -Force
            if ([string]$mapControl.kind -in @("Account","Password")) { $nearest.claimedByDataset=$true; $nearest.options=@() }
            else { Set-RuleMapControlOptions $Context $nearest $mapControl $mapModel }
            $merged.Add($nearest)
        } else {
            $left=[int][Math]::Round(([double]$mapControl.rect.x*[double]$transform.scale)+[int]$transform.offsetX)
            $top=[int][Math]::Round(([double]$mapControl.rect.y*[double]$transform.scale)+[int]$transform.offsetY)
            $width=[Math]::Max(1,[int][Math]::Round([double]$mapControl.rect.width*[double]$transform.scale))
            $height=[Math]::Max(1,[int][Math]::Round([double]$mapControl.rect.height*[double]$transform.scale))
            $relative=[pscustomobject]@{left=$left;top=$top;right=$left+$width;bottom=$top+$height;width=$width;height=$height;centerX=$left+[int]($width/2);centerY=$top+[int]($height/2)}
            $placeholder=[pscustomobject]@{
                controlId=[string]$mapControl.modelId;controlKind=[string]$mapControl.ruleControlKind;name=[string]$mapControl.logicalName
                className="MapDefinition";hwnd=[Int64]0;locatorSignature="MAP|$($mapControl.modelId)|UNBOUND";initialValue=""
                tabOrder=20000+[int]$mapControl.definitionOrder;tabStop=[bool]$mapControl.isTabStopCandidate;relativeRect=$relative;regionRole="content";stateContext=""
                claimedByDataset=([string]$mapControl.kind -in @("Account","Password"));dataRequired=$false
                pendingReason=$(if(-not $insideClip){"현재 MAP 호스트에 표시되지 않는 잘린 영역입니다."}elseif([bool]$transform.hostRequired -and -not [bool]$transform.hostMatched){"현재 화면에서 MAP 전용 호스트 영역을 확인하지 못했습니다."}else{"MAP 정의 컨트롤을 전용 호스트 내부의 동일 좌표·크기 HWND/UIA와 결합하지 못했습니다."});options=@()
                definitionSource="MAP";runtimeName="";runtimeControlKind="";mapModelId=[string]$mapControl.modelId;mapTypeCode=[string]$mapControl.typeCode
                mapScreenCode=[string]$mapModel.screenCode
                mapKind=[string]$mapControl.kind
                mapDefinitionOrder=[int]$mapControl.definitionOrder;mapMatched=$false;mapMatchDistance=$null;mapGeometryDelta=$null;mapGeometryExact=$false
                mapHostRequired=[bool]$transform.hostRequired;mapHostMatched=[bool]$transform.hostMatched;mapHostId=[string]$transform.hostId
                runtimeIdentityUnique=$true;allowOwnerDrawnKindOverride=[bool]$transform.allowOwnerDrawnKindOverride;mapEvents=@($mapControl.events)
                mapSemanticRole=[string]$mapControl.semanticRole;mapTriggeredRequests=@($mapControl.triggeredRequestNames);mapReadControls=@($mapControl.readControls)
                mapAffectedControls=@($mapControl.affectedControls);mapResultControls=@($mapControl.resultControls);mapInvokedHandlers=@($mapControl.invokedHandlers)
                mapNavigationTargets=@($mapControl.navigationTargets);mapOptionSource=[string]$mapControl.optionSource;mapRect=$mapControl.rect
            }
            if ([string]$mapControl.kind -notin @('Account','Password')) { Set-RuleMapControlOptions $Context $placeholder $mapControl $mapModel }
            $merged.Add($placeholder)
        }
    }
    if ($IncludeRuntimeOnly) { foreach ($runtimeControl in $runtimeRows) {
        $runtimeKey=if([Int64]$runtimeControl.hwnd-ne0){"H:$([Int64]$runtimeControl.hwnd)"}else{"C:$([string]$runtimeControl.controlId)"}
        if ($usedRuntime.ContainsKey($runtimeKey)) { continue }
        $runtimeControl | Add-Member -NotePropertyName definitionSource -NotePropertyValue "RuntimeOnly" -Force
        $runtimeControl | Add-Member -NotePropertyName mapMatched -NotePropertyValue $false -Force
        $runtimeControl | Add-Member -NotePropertyName mapScreenCode -NotePropertyValue '' -Force
        Set-RuleInferredExpectedOutcomes $runtimeControl
        $merged.Add($runtimeControl)
    } }
    @($merged.ToArray() | Sort-Object tabOrder,controlId)
}

# 0101처럼 같은 화면번호를 공유하는 MAP family를 모두 보존하고 런타임 전용 컨트롤은 한 번만 추가한다.
function Merge-RuleMapBaseline($Context, $Screen, [string]$ScreenNumber, $RuntimeControls) {
    $runtimeRows = @($RuntimeControls)
    $models = @(Get-RuleMapScreenModels $Context $ScreenNumber)
    if ($models.Count -eq 0) {
        foreach ($runtimeControl in $runtimeRows) {
            $runtimeControl | Add-Member -NotePropertyName definitionSource -NotePropertyValue 'RuntimeOnly' -Force
            $runtimeControl | Add-Member -NotePropertyName mapMatched -NotePropertyValue $false -Force
            $runtimeControl | Add-Member -NotePropertyName mapScreenCode -NotePropertyValue '' -Force
            Set-RuleInferredExpectedOutcomes $runtimeControl
        }
        return $runtimeRows
    }

    $merged = New-Object Collections.Generic.List[object]
    foreach ($model in $models) {
        $mapCode = ([string]$model.screenCode).Trim().ToUpperInvariant()
        $isActive = $Context.ActiveMapScreenCodes.Count -eq 0 -or $Context.ActiveMapScreenCodes -contains $mapCode
        $clonedRuntime = if ($isActive) { @($runtimeRows | ForEach-Object { $_ | Select-Object * }) } else { @() }
        foreach ($control in @(Merge-RuleSingleMapBaseline $Context $Screen $ScreenNumber $clonedRuntime $model $false)) {
            if (-not $isActive) {
                $control.pendingReason = "MAP $mapCode 는 카탈로그에 포함되지만 현재 컨테이너/탭 상태에서는 활성화되지 않았습니다."
                $control.mapMatched = $false
                $control.mapHostMatched = $false
            }
            $merged.Add($control)
        }
    }

    # 서로 다른 활성 MAP이 같은 HWND를 차지하면 어느 논리 컨트롤도 물리 실행 대상으로 확정하지 않는다.
    $runtimeCollisions = @($merged.ToArray() | Where-Object {
        [string]$_.definitionSource -eq 'MAP+Runtime' -and [Int64]$_.hwnd -ne 0
    } | Group-Object { "$([Int64]$_.hwnd)|$([string]$_.stateContext)" } | Where-Object {
        @($_.Group.mapScreenCode | Select-Object -Unique).Count -gt 1
    })
    foreach ($collision in $runtimeCollisions) {
        $collisionNames = @($collision.Group | ForEach-Object { "$([string]$_.mapScreenCode).$([string]$_.name)" }) -join ', '
        foreach ($control in $collision.Group) {
            $control.runtimeIdentityUnique = $false
            $control.mapMatched = $false
            $control.pendingReason = "서로 다른 MAP 논리 컨트롤이 동일 런타임 HWND에 충돌했습니다: $collisionNames"
        }
    }
    foreach ($runtimeControl in $runtimeRows) {
        $runtimeControl | Add-Member -NotePropertyName definitionSource -NotePropertyValue 'RuntimeOnly' -Force
        $runtimeControl | Add-Member -NotePropertyName mapMatched -NotePropertyValue $false -Force
        $runtimeControl | Add-Member -NotePropertyName mapScreenCode -NotePropertyValue '' -Force
        Set-RuleInferredExpectedOutcomes $runtimeControl
        $merged.Add($runtimeControl)
    }
    @($merged.ToArray() | Sort-Object mapScreenCode,tabOrder,controlId)
}

# 화면별 정책 값이 없을 때 defaults를 사용하는 안전한 속성 조회 함수다.
function Get-RulePolicyValue($Object, [string]$Name, $DefaultValue) {
    if ($Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name) { return $Object.$Name }
    $DefaultValue
}

# 콘텐츠 경계: 프레임/창 버튼을 제외하고 현재 화면 내부에서 조작 가능한 상대 영역을 계산한다.
function Get-RuleContentPolicy($Context, [string]$ScreenNumber) {
    $defaults = if ($Context.RegionConfig) { $Context.RegionConfig.defaults } else { $null }
    $screenPolicy = $null
    if ($Context.RegionConfig -and $Context.RegionConfig.screens -and
        $Context.RegionConfig.screens.PSObject.Properties.Name -contains $ScreenNumber) {
        $screenPolicy = $Context.RegionConfig.screens.$ScreenNumber
    }
    [pscustomobject]@{
        contentRegion = Get-RulePolicyValue $screenPolicy "contentRegion" (Get-RulePolicyValue $defaults "contentRegion" $null)
        excludeBands = @(Get-RulePolicyValue $screenPolicy "excludeBands" (Get-RulePolicyValue $defaults "excludeBands" @()))
        excludeTitleRegex = [string](Get-RulePolicyValue $screenPolicy "excludeTitleRegex" (Get-RulePolicyValue $defaults "excludeTitleRegex" "^(B|X|Button1)$"))
        excludeSmallUntitled = Get-RulePolicyValue $screenPolicy "excludeSmallUntitled" (Get-RulePolicyValue $defaults "excludeSmallUntitled" $null)
        visualHotspots = @(Get-RulePolicyValue $screenPolicy "visualHotspots" @())
    }
}

# 절대 화면 좌표를 대상 화면 좌상단 기준 상대 사각형으로 바꾼다.
function Get-RuleRelativeRect($Rect, $ScreenRect) {
    [pscustomobject]@{
        left=[int]($Rect.left-$ScreenRect.left); top=[int]($Rect.top-$ScreenRect.top)
        right=[int]($Rect.right-$ScreenRect.left); bottom=[int]($Rect.bottom-$ScreenRect.top)
        width=[int]$Rect.width; height=[int]$Rect.height
        centerX=[int]((($Rect.left+$Rect.right)/2)-$ScreenRect.left)
        centerY=[int]((($Rect.top+$Rect.bottom)/2)-$ScreenRect.top)
    }
}

# 프레임·하단 버튼·소형 장식물을 제외하고 콘텐츠 내부 활성 컨트롤만 허용한다.
function Test-RuleContentControl($Window, $Screen, $Policy) {
    $relative = Get-RuleRelativeRect $Window.rect $Screen.rect
    $region = $Policy.contentRegion
    if ($region) {
        $left = [int](Get-RulePolicyValue $region "left" 0)
        $top = [int](Get-RulePolicyValue $region "top" 0)
        $right = [int]$Screen.rect.width - [int](Get-RulePolicyValue $region "rightInset" 0)
        $bottom = [int]$Screen.rect.height - [int](Get-RulePolicyValue $region "bottomInset" 0)
        if ($relative.centerX -lt $left -or $relative.centerX -gt $right -or $relative.centerY -lt $top -or $relative.centerY -gt $bottom) { return $false }
    }
    foreach ($band in @($Policy.excludeBands)) {
        $bandTop = if ($null -ne $band.top) { [int]$band.top } elseif ($null -ne $band.topFromBottom) { [int]$Screen.rect.height - [int]$band.topFromBottom } else { $null }
        $bandBottom = if ($null -ne $band.bottom) { [int]$band.bottom } elseif ($null -ne $band.bottomFromBottom) { [int]$Screen.rect.height - [int]$band.bottomFromBottom } else { $null }
        if ($null -ne $bandTop -and $null -ne $bandBottom -and $relative.centerY -ge $bandTop -and $relative.centerY -le $bandBottom) { return $false }
    }
    if ($Window.className -like "*Button*" -and $Policy.excludeTitleRegex -and $Window.rawTitle -match $Policy.excludeTitleRegex) { return $false }
    $small = $Policy.excludeSmallUntitled
    if ($Window.className -like "*Button*" -and -not $Window.rawTitle -and $small -and
        $Window.rect.width -le [int]$small.maxWidth -and $Window.rect.height -le [int]$small.maxHeight) { return $false }
    return $true
}

# 제목과 스타일을 이용해 명령 버튼·체크·라디오를 구분한다.
function Get-RuleButtonKind($Window) {
    $styleKind = [int64]$Window.style -band 0xF
    if ($styleKind -in @(2,3,5,6)) { return "CheckBox" }
    if ($styleKind -in @(4,9)) { return "RadioButton" }
    "Button"
}

# ComboBoxEx 같은 래퍼 안에서 실제 목록 동작을 수행할 네이티브 콤보 HWND를 찾는다.
function Get-RuleNativeComboWindow($Context, $Window) {
    if ($Window.className -eq "ComboBox") { return $Window }
    if ($Window.className -eq "ComboBoxEx32") {
        $inner = @(Get-ChildWindows ([Int64]$Window.hwnd) | Where-Object { $_.visible -and $_.enabled -and $_.className -eq "ComboBox" } | Select-Object -First 1)
        if ($inner.Count -gt 0) { return $inner[0] }
    }
    $Window
}

# yyyyMMdd 값을 현재 날짜 컨트롤에 보낼 숫자 문자열로 검증·정규화한다.
function ConvertTo-RuleDateValue([string]$Value) {
    $digits = -join @($Value.ToCharArray() | Where-Object { $_ -match '[0-9]' })
    if ($digits.Length -ne 8) { return $null }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($digits,"yyyyMMdd",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)) { return $null }
    $digits
}

# 분리된 년·월·일 자식 입력과 단일 입력에서 현재 날짜 표시값을 읽는다.
function Get-RuleDateDisplayValue($Window, $Children) {
    $direct = ConvertTo-RuleDateValue ([string]$Window.rawTitle)
    if ($direct) { return $direct }
    $centerX = [int](($Window.rect.left+$Window.rect.right)/2)
    $centerY = [int](($Window.rect.top+$Window.rect.bottom)/2)
    foreach ($candidate in @($Children | Where-Object {
        $_.hwnd -ne $Window.hwnd -and $_.className -like "AfxWnd*" -and
        [Math]::Abs([int](($_.rect.left+$_.rect.right)/2)-$centerX) -le 14 -and
        [Math]::Abs([int](($_.rect.top+$_.rect.bottom)/2)-$centerY) -le 10
    })) {
        $value = ConvertTo-RuleDateValue ([string]$candidate.rawTitle)
        if ($value) { return $value }
    }
    $null
}

# 클래스·자식 구조·현재 값으로 자체 그리기 날짜 컨트롤인지 판별한다.
function Test-RuleDateControl($Window, $Children) {
    if ($Window.className -ne "Edit" -or $Window.rect.width -lt 55 -or $Window.rect.width -gt 140 -or $Window.rect.height -gt 32) { return $false }
    $null -ne (Get-RuleDateDisplayValue $Window $Children)
}

# Win32 대화상자 탭 체인에서 정적 탭 순번 후보를 만든다.
function Get-RuleTabOrderMap($Screen, $Children) {
    $result = @{}
    $known = @{}
    foreach ($child in @($Children)) { $known[[Int64]$child.hwnd]=$true }
    $current = [IntPtr]::Zero
    for ($index=0; $index -lt $Children.Count; $index++) {
        $next = [TargetRuleNative]::GetNextDlgTabItem([IntPtr][Int64]$Screen.hwnd,$current,$false)
        if ($next -eq [IntPtr]::Zero -or ($current -ne [IntPtr]::Zero -and $next -eq $current)) { break }
        $key = [Int64]$next.ToInt64()
        if ($result.ContainsKey($key)) { break }
        if ($known.ContainsKey($key)) { $result[$key]=$result.Count }
        $current = $next
    }
    $fallback = $result.Count
    foreach ($child in @($Children | Sort-Object enumerationIndex)) {
        $key = [Int64]$child.hwnd
        if (-not $result.ContainsKey($key)) { $result[$key]=$fallback; $fallback++ }
    }
    $result
}

# 탭오더 수집: 첫 포커스로 돌아올 때까지 Tab을 보내 실제 활성 컨트롤 순서를 기록한다.
# 실제 Tab 키 포커스 이동을 관찰해 owner-drawn 컨트롤까지 포함한 실행 순서를 만든다.
function Get-RuleActualTabOrderMap($Context, $Screen, $Children, $Policy) {
    $candidateIds = @($Children | Where-Object { Test-RuleContentControl $_ $Screen $Policy } | ForEach-Object { [string]$_.hwnd } | Sort-Object)
    $cacheKey = "$($Screen.hwnd)|$($candidateIds -join ',')"
    if ($Context.ActualTabOrderCache.ContainsKey($cacheKey)) { return $Context.ActualTabOrderCache[$cacheKey] }

    $known = @{}
    foreach ($child in $Children) { $known[[Int64]$child.hwnd] = $child }
    $preferredStarts = @($Children | Where-Object {
        (Test-RuleContentControl $_ $Screen $Policy) -and
        ($_.className -in @('Edit','ComboBox','ComboBoxEx32') -or ($_.rawTitle -match '^\d{8,14}(-\d{3})?$' -and $_.rect.width -ge 80))
    } | Sort-Object rect.top,rect.left)
    $nativeTabStarts = @($Children | Where-Object {
        (Test-RuleContentControl $_ $Screen $Policy) -and (([Int64]$_.style -band 0x00010000) -ne 0)
    } | Sort-Object rect.top,rect.left)
    $ownerDrawnStarts = @($Children | Where-Object {
        (Test-RuleContentControl $_ $Screen $Policy) -and $_.className -like 'AfxWnd*' -and
        $_.rect.width -ge 24 -and $_.rect.width -le 300 -and $_.rect.height -le 40 -and
        (Get-RuleRelativeRect $_.rect $Screen.rect).centerY -le 260
    } | Sort-Object rect.top,rect.left)
    $startPool = @($preferredStarts) + @($nativeTabStarts) + @($ownerDrawnStarts)
    $safeStarts = @($startPool | Group-Object hwnd | ForEach-Object { $_.Group[0] } | Select-Object -First 8)
    if ($safeStarts.Count -eq 0) {
        $result = [pscustomobject]@{ map=@{}; order=@() }
        $Context.ActualTabOrderCache[$cacheKey] = $result
        return $result
    }

    $ordered = New-Object Collections.Generic.List[Int64]
    $seen = @{}
    $currentThread=[TargetRuleNative]::GetCurrentThreadId()
    $limit = [Math]::Min([Math]::Max(24,$Children.Count+12),[int]$Context.Dataset.autoExploration.maxControlsPerScreen+12)
    foreach($safeStart in $safeStarts){
        $targetHwnd=[IntPtr][Int64]$safeStart.hwnd
        if(-not [TargetRuleNative]::IsWindow($targetHwnd)){continue}
        [uint32]$targetPid=0
        $targetThread=[TargetRuleNative]::GetWindowThreadProcessId($targetHwnd,[ref]$targetPid)
        [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$Screen.hwnd)
        $attached=$false
        try {
            if($targetThread -ne 0 -and $targetThread -ne $currentThread){$attached=[TargetRuleNative]::AttachThreadInput($currentThread,$targetThread,$true)}
            [void][TargetRuleNative]::SetFocus($targetHwnd)
        } finally {
            if($attached){[void][TargetRuleNative]::AttachThreadInput($currentThread,$targetThread,$false)}
        }
        Start-Sleep -Milliseconds 80
        $focusCheck=New-Object TargetRuleNative+GUITHREADINFO
        $focusCheck.cbSize=[Runtime.InteropServices.Marshal]::SizeOf([type][TargetRuleNative+GUITHREADINFO])
        [void][TargetRuleNative]::GetGUIThreadInfo(0,[ref]$focusCheck)
        if($focusCheck.hwndFocus -ne $targetHwnd){
            Click-Center $safeStart
            Start-Sleep -Milliseconds 120
        }
        $scanSeen=@{}
        $repeatedFocusCount=0
        for ($step=0; $step -lt $limit; $step++) {
            $threadInfo = New-Object TargetRuleNative+GUITHREADINFO
            $threadInfo.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][TargetRuleNative+GUITHREADINFO])
            [void][TargetRuleNative]::GetGUIThreadInfo(0,[ref]$threadInfo)
            $focused = [Int64]$threadInfo.hwndFocus.ToInt64()
            if($focused -eq 0 -or ($focused -ne [Int64]$Screen.hwnd -and -not [TargetRuleNative]::IsChild([IntPtr][Int64]$Screen.hwnd,[IntPtr]$focused))){break}
            if(-not $known.ContainsKey($focused) -or -not (Test-RuleContentControl $known[$focused] $Screen $Policy)){break}
            if ($focused -ne 0 -and $known.ContainsKey($focused) -and (Test-RuleContentControl $known[$focused] $Screen $Policy)) {
                if($scanSeen.ContainsKey($focused)){
                    $repeatedFocusCount++
                    if($repeatedFocusCount -ge 2){break}
                } else {
                    $scanSeen[$focused]=$true
                    $repeatedFocusCount=0
                    if (-not $seen.ContainsKey($focused)) {
                        $seen[$focused] = $true
                        $ordered.Add($focused)
                    }
                }
            }
            Send-Key ([byte]$VK_TAB)
            Start-Sleep -Milliseconds 90
        }
        if($scanSeen.Count -ge 3){break}
    }

    $accountPosition = -1
    for ($index=0; $index -lt $ordered.Count; $index++) {
        $window = $known[$ordered[$index]]
        if ($window.rawTitle -match '^\d{8,14}(-\d{3})?$' -and $window.rect.width -ge 80) { $accountPosition=$index; break }
    }
    if ($accountPosition -gt 0) {
        $rotated = New-Object Collections.Generic.List[Int64]
        for ($index=0; $index -lt $ordered.Count; $index++) { $rotated.Add($ordered[($accountPosition+$index)%$ordered.Count]) }
        $ordered = $rotated
    }
    $map = @{}
    for ($index=0; $index -lt $ordered.Count; $index++) { $map[$ordered[$index]]=$index }
    $result = [pscustomobject]@{ map=$map; order=$ordered.ToArray() }
    $Context.ActualTabOrderCache[$cacheKey] = $result
    $result
}

# AfxWnd 자체 그리기 컨트롤의 제목·크기·스타일에서 의미 종류를 추정한다.
function Get-RuleAfxControlKind($Window) {
    if (-not $Window.rawTitle) { return "" }
    if ($Window.rawTitle -match '^(조회|전체조회|조회하기|검색|확인|적용|다음|이전|참고|유의사항|엑셀저장|저장|인쇄)$') { return "Button" }
    ""
}

# 콤보 목록을 실제로 열어 위에서부터 표시문자와 인덱스를 수집한다.
function Get-RuleComboOptions($Context, $Window, [int]$Limit) {
    $Window = Get-RuleNativeComboWindow $Context $Window
    $rows = New-Object Collections.Generic.List[object]
    $count = [int][TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd, 0x0146, [IntPtr]::Zero, [IntPtr]::Zero).ToInt64()
    if ($count -lt 0) { return @() }
    for ($index=0; $index -lt [Math]::Min($count,$Limit); $index++) {
        $length = [int][TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd, 0x0149, [IntPtr]$index, [IntPtr]::Zero).ToInt64()
        $label = "항목 $($index+1) (표시문자 수집 불가)"
        $labelSource = "ordinalFallback"
        if ($length -ge 0 -and $length -lt 4096) {
            $buffer = New-Object Text.StringBuilder ([Math]::Max(2,$length+1))
            [void][TargetRuleNative]::SendMessageText([IntPtr][Int64]$Window.hwnd, 0x0148, [IntPtr]$index, $buffer)
            if ($buffer.Length -gt 0) { $label = $buffer.ToString(); $labelSource = "native" }
        }
        $rows.Add([pscustomobject]@{id="index-$index";value=[string]$index;displayValue=$label;labelSource=$labelSource;index=$index})
    }
    $rows.ToArray()
}

# ListBox·ListView의 접근 가능한 행을 제한 수까지 선택지로 읽는다.
function Get-RuleListOptions($Context, $Window, [int]$Limit) {
    $rows = New-Object Collections.Generic.List[object]
    $count = [int][TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd,0x018B,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
    if ($count -lt 0) { return @() }
    for ($index=0; $index -lt [Math]::Min($count,$Limit); $index++) {
        $length = [int][TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd,0x018A,[IntPtr]$index,[IntPtr]::Zero).ToInt64()
        $label = "목록 항목 $($index+1) (표시문자 수집 불가)"
        $labelSource = "ordinalFallback"
        if ($length -ge 0 -and $length -lt 4096) {
            $buffer = New-Object Text.StringBuilder ([Math]::Max(2,$length+1))
            [void][TargetRuleNative]::SendMessageText([IntPtr][Int64]$Window.hwnd,0x0189,[IntPtr]$index,$buffer)
            if ($buffer.Length -gt 0) { $label=$buffer.ToString(); $labelSource="native" }
        }
        $rows.Add([pscustomobject]@{id="row-$index";value=[string]$index;displayValue=$label;labelSource=$labelSource;index=$index})
    }
    $rows.ToArray()
}

# 화면·종류·탭 순서·위치·동적 상태를 해시해 재발견 가능한 컨트롤 ID를 만든다.
function New-RuleControlId([string]$ScreenNumber, $Window, [string]$Kind, $RelativeRect, [string]$StateContext = "", [int]$TabOrder = -1) {
    $effectiveState = if ($Kind -eq "Tab") { "" } else { $StateContext }
    $identity = if ($TabOrder -ge 0) {
        "$ScreenNumber|$effectiveState|$Kind|$($Window.className)|$($Window.rawTitle)|tab:$TabOrder"
    } elseif ($Kind -eq "Tab") {
        "$ScreenNumber|$Kind|$($Window.className)|$($RelativeRect.top)"
    } else {
        "$ScreenNumber|$StateContext|$Kind|$($Window.className)|$($Window.rawTitle)|$($RelativeRect.centerX)|$($RelativeRect.centerY)"
    }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $sha = $hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)) } finally { $hasher.Dispose() }
    "CTL-" + (-join ($sha | ForEach-Object { $_.ToString("x2") })).Substring(0,12)
}

# 컨트롤 발견: HWND/UIA/탭오더/MAP 정보를 하나의 실행 컨트롤 모델로 병합하고 옵션을 수집한다.
function Get-RuleDiscoveredControls($Context, $Screen, [string]$ScreenNumber, [hashtable]$ClaimedHwnds) {
    if($Screen -and [Int64]$Screen.hwnd -ne 0 -and [TargetRuleNative]::IsWindow([IntPtr][Int64]$Screen.hwnd)){
        $Screen=Get-WindowInfo ([IntPtr][Int64]$Screen.hwnd)
    }
    $policy = Get-RuleContentPolicy $Context $ScreenNumber
    $maxControls = [int]$Context.Dataset.autoExploration.maxControlsPerScreen
    $maxOptions = [int]$Context.Dataset.autoExploration.maxOptionsPerControl
    $textValues = @($Context.Dataset.autoExploration.defaultTextValues)
    $dateValues = @($Context.Dataset.autoExploration.defaultDateValues)
    $rows = New-Object Collections.Generic.List[object]
    $children = @(Get-ChildWindows ([Int64]$Screen.hwnd) | Where-Object {
        $_.visible -and $_.enabled -and $_.rect.width -ge 8 -and $_.rect.height -ge 8
    })
    $fallbackTabOrderMap = Get-RuleTabOrderMap $Screen $children
    $passiveDiscovery = $Context.FastScenarioDiscovery -or [string]$Context.CurrentInteractionStrategy -eq 'CoordinateFocus'
    $actualTabOrder = if ($passiveDiscovery) {
        [pscustomobject]@{
            map = $fallbackTabOrderMap
            order = @($children | Sort-Object @{Expression={ [int]$fallbackTabOrderMap[[Int64]$_.hwnd] }},enumerationIndex | ForEach-Object { [Int64]$_.hwnd })
        }
    } else {
        Get-RuleActualTabOrderMap $Context $Screen $children $policy
    }
    $tabOrderMap = @{}
    foreach ($entry in $actualTabOrder.map.GetEnumerator()) { $tabOrderMap[[Int64]$entry.Key]=[int]$entry.Value }
    $fallbackOffset = $tabOrderMap.Count
    foreach ($window in @($children | Sort-Object @{Expression={ [int]$fallbackTabOrderMap[[Int64]$_.hwnd] }},enumerationIndex)) {
        if (-not $tabOrderMap.ContainsKey([Int64]$window.hwnd)) { $tabOrderMap[[Int64]$window.hwnd]=$fallbackOffset; $fallbackOffset++ }
    }
    $tabState = @($children | Where-Object className -eq "SysTabControl32" | Sort-Object {$_.rect.top},{$_.rect.left} | ForEach-Object {
        $relativeTab=Get-RuleRelativeRect $_.rect $Screen.rect
        $selected=[TargetRuleNative]::SendMessage([IntPtr][Int64]$_.hwnd,0x130B,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
        "$($relativeTab.centerX):$($relativeTab.centerY)=$selected"
    }) -join ";"
    $actualWindows = @($actualTabOrder.order | ForEach-Object { $id=[Int64]$_; $children | Where-Object { [Int64]$_.hwnd -eq $id } | Select-Object -First 1 })
    $accountWindow = @($actualWindows | Where-Object { $_ -and $_.rawTitle -match '^\d{8,14}(-\d{3})?$' -and $_.rect.width -ge 80 } | Select-Object -First 1)
    $accountHwnd = if ($accountWindow.Count -gt 0) { [Int64]$accountWindow[0].hwnd } else { [Int64]0 }
    $passwordHwnd = [Int64]0
    if ($accountHwnd -ne 0) {
        $accountIndex = [int]$actualTabOrder.map[$accountHwnd]
        $passwordWindow = @($actualWindows | Where-Object {
            $_ -and [int]$actualTabOrder.map[[Int64]$_.hwnd] -eq ($accountIndex+1) -and $_.rect.width -le 120
        } | Select-Object -First 1)
        if ($passwordWindow.Count -gt 0) { $passwordHwnd=[Int64]$passwordWindow[0].hwnd }
    }
    $queryCandidates = @($actualWindows | Where-Object {
        if (-not $_ -or $_.className -notlike 'AfxWnd*' -or $_.rawTitle) { return $false }
        $relativeCandidate=Get-RuleRelativeRect $_.rect $Screen.rect
        $_.rect.width -ge 45 -and $_.rect.width -le 140 -and $_.rect.height -ge 18 -and $_.rect.height -le 40 -and $relativeCandidate.centerY -le 180
    })
    $rightQueryCandidates=@($queryCandidates | Where-Object { (Get-RuleRelativeRect $_.rect $Screen.rect).centerX -ge ([int]$Screen.rect.width*0.60) })
    if($rightQueryCandidates.Count -gt 0){$queryCandidates=$rightQueryCandidates}
    $queryCandidates=@($queryCandidates | Sort-Object @{Expression={[int]$actualTabOrder.map[[Int64]$_.hwnd]}},@{Expression={(Get-RuleRelativeRect $_.rect $Screen.rect).centerX};Descending=$true})
    $queryHwnd = if ($queryCandidates.Count -gt 0) { [Int64]$queryCandidates[0].hwnd } else { [Int64]0 }
    $checkboxRowHwnds=@{}
    if($queryHwnd -ne 0){
        $queryWindow=@($children | Where-Object { [Int64]$_.hwnd -eq $queryHwnd } | Select-Object -First 1)
        if($queryWindow.Count -gt 0){
            $queryRelative=Get-RuleRelativeRect $queryWindow[0].rect $Screen.rect
            $checkboxRows=@($actualWindows | Where-Object {
                if(-not $_ -or $_.className -notlike 'AfxWnd*' -or $_.rawTitle){return $false}
                $relativeCheckbox=Get-RuleRelativeRect $_.rect $Screen.rect
                $relativeCheckbox.centerY -gt ($queryRelative.centerY+8) -and $relativeCheckbox.centerY -le ($queryRelative.centerY+70) -and $_.rect.width -le 220
            } | Group-Object { [Math]::Round((Get-RuleRelativeRect $_.rect $Screen.rect).centerY/8.0) } | Where-Object Count -ge 2)
            foreach($row in $checkboxRows){foreach($item in $row.Group){$checkboxRowHwnds[[Int64]$item.hwnd]=$true}}
        }
    }

    $children = @($children | Sort-Object @{Expression={ [int]$tabOrderMap[[Int64]$_.hwnd] }},enumerationIndex)
    foreach ($window in $children) {
        if (-not (Test-RuleContentControl $window $Screen $policy)) { continue }
        $kind = switch -Wildcard ($window.className) {
            "ComboBox" { "ComboBox"; break }
            "ComboBoxEx32" { "ComboBox"; break }
            "Edit" {
                $looksLikeOrderedDate = $actualTabOrder.map.ContainsKey([Int64]$window.hwnd) -and
                    [int]$actualTabOrder.map[[Int64]$window.hwnd] -ge 2 -and [int]$actualTabOrder.map[[Int64]$window.hwnd] -le 4 -and
                    $window.rect.width -ge 55 -and $window.rect.width -le 140 -and $window.rect.height -le 32 -and
                    @($children | Where-Object {
                        $_.hwnd -ne $window.hwnd -and $_.className -like 'AfxWnd*' -and -not $_.rawTitle -and
                        $_.rect.width -ge 14 -and $_.rect.width -le 32 -and
                        $_.rect.left -ge ($window.rect.right-14) -and $_.rect.left -le ($window.rect.right+36) -and
                        [Math]::Abs([int](($_.rect.top+$_.rect.bottom)/2)-[int](($window.rect.top+$window.rect.bottom)/2)) -le 6
                    }).Count -eq 1
                if ((Test-RuleDateControl $window $children) -or $looksLikeOrderedDate) { "Date" } else { "Text" }; break
            }
            "SysTabControl32" { "Tab"; break }
            "ListBox" { "ListBox"; break }
            "SysListView32" { "ListView"; break }
            "SysTreeView32" { "TreeView"; break }
            "msctls_trackbar32" { "Slider"; break }
            "msctls_updown32" { "Spin"; break }
            "*Button*" { Get-RuleButtonKind $window; break }
            "AfxWnd*" {
                $windowHwnd=[Int64]$window.hwnd
                if ($windowHwnd -eq $accountHwnd -or $windowHwnd -eq $passwordHwnd) { "Text"; break }
                if ($windowHwnd -eq $queryHwnd) { "Button"; break }
                if ($actualTabOrder.map.ContainsKey($windowHwnd)) {
                    $relativeAfx=Get-RuleRelativeRect $window.rect $Screen.rect
                    if($checkboxRowHwnds.ContainsKey($windowHwnd)){"CheckBox";break}
                    if (-not $window.rawTitle -and $window.rect.width -ge 120) { "RadioGroup"; break }
                    if (-not $window.rawTitle -and $queryHwnd -ne 0) {
                        $queryWindow=@($children | Where-Object { [Int64]$_.hwnd -eq $queryHwnd } | Select-Object -First 1)
                        $queryRelative=if($queryWindow.Count -gt 0){Get-RuleRelativeRect $queryWindow[0].rect $Screen.rect}else{$null}
                        if ($queryRelative -and $relativeAfx.centerY -gt ($queryRelative.centerY+8) -and $window.rect.width -le 90) { "CheckBox"; break }
                    }
                    "Button"; break
                }
                Get-RuleAfxControlKind $window; break
            }
            default { "" }
        }
        if (-not $kind) { continue }
        if ($kind -eq "Text" -and (([int64]$window.style -band 0x20) -ne 0)) { continue }
        if ($kind -eq "Button" -and -not [bool]$Context.Dataset.autoExploration.includeButtons) { continue }
        if ($kind -eq "Button" -and -not $window.rawTitle -and -not [bool]$Context.Dataset.autoExploration.includeUnlabeledButtons) { continue }
        $relative = Get-RuleRelativeRect $window.rect $Screen.rect
        $isAccount = ([Int64]$window.hwnd -eq $accountHwnd)
        $isPassword = ([Int64]$window.hwnd -eq $passwordHwnd)
        $isTabQuery = ([Int64]$window.hwnd -eq $queryHwnd)
        $identityWindow = if ($kind -in @("Text","Date") -or $isAccount -or $isPassword) {[pscustomobject]@{className=$window.className;rawTitle=""}} else {$window}
        $controlId = New-RuleControlId $ScreenNumber $identityWindow $kind $relative $(if($kind-eq"Tab"){""}else{$tabState}) ([int]$tabOrderMap[[Int64]$window.hwnd])
        $claimed = ($ClaimedHwnds -and $ClaimedHwnds.ContainsKey([Int64]$window.hwnd)) -or $isAccount -or $isPassword
        $controlName = if($isAccount){"계좌번호(기본값)"}elseif($isPassword){"비밀번호(기본값)"}elseif($isTabQuery){"조회(탭오더)"}else{[string]$window.rawTitle}
        $options = @()
        $initialValue = ""
        $dataRequired = $false
        $pendingReason = ""
        switch ($kind) {
            "ComboBox" {
                $options = @(Get-RuleComboOptions $Context $window $maxOptions)
                $nativeCombo = Get-RuleNativeComboWindow $Context $window
                $initialValue = [string][TargetRuleNative]::SendMessage([IntPtr][Int64]$nativeCombo.hwnd,0x0147,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                if ($options.Count -eq 0) { $pendingReason = "콤보 선택지를 Win32 메시지로 읽지 못했습니다." }
            }
            "CheckBox" {
                if ($window.className -like 'AfxWnd*') {
                    $options=@(
                        [pscustomobject]@{id="current";value="current";displayValue="현재 상태";labelSource="tabOrder";index=0},
                        [pscustomobject]@{id="toggled";value="toggle";displayValue="반대 상태";labelSource="tabOrder";index=1}
                    )
                } else {
                    $initialValue = [string][TargetRuleNative]::SendMessage([IntPtr][Int64]$window.hwnd,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                    $options = @(
                        [pscustomobject]@{id="unchecked";value="false";displayValue="해제";labelSource="generated";index=0},
                        [pscustomobject]@{id="checked";value="true";displayValue="선택";labelSource="generated";index=1}
                    )
                }
            }
            "RadioButton" { $options = @([pscustomobject]@{id="select";value="true";displayValue=$(if ($window.rawTitle) {$window.rawTitle} else {"라디오 선택"});labelSource=$(if($window.rawTitle){"native"}else{"generated"});index=1}) }
            "RadioGroup" {
                $count=[Math]::Max(2,[Math]::Min(8,[int][Math]::Round($window.rect.width/60.0)))
                $options=@(for($index=0;$index-lt$count;$index++){[pscustomobject]@{id="option-$index";value=[string]$index;displayValue="라디오 항목 $($index+1)";labelSource="tabOrderOrdinal";index=$index}})
            }
            "Tab" {
                $initialValue = [string][TargetRuleNative]::SendMessage([IntPtr][Int64]$window.hwnd,0x130B,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                $count = [int][TargetRuleNative]::SendMessage([IntPtr][Int64]$window.hwnd, 0x1304, [IntPtr]::Zero, [IntPtr]::Zero).ToInt64()
                if ($count -le 0) { $count = [Math]::Max(1,[Math]::Min(20,[int][Math]::Ceiling($window.rect.width/90.0))) }
                $options = @(for ($index=0; $index -lt [Math]::Min($count,$maxOptions); $index++) { [pscustomobject]@{id="tab-$index";value=[string]$index;displayValue="탭 $($index+1) (표시문자 수집 불가)";labelSource="ordinalFallback";index=$index} })
            }
            "Button" { $options = @([pscustomobject]@{id="click";value="click";displayValue=$(if ($window.rawTitle) {$window.rawTitle} else {"이름 없는 콘텐츠 버튼"});labelSource=$(if($window.rawTitle){"native"}else{"generated"});index=0}) }
            "Text" {
                if ($isAccount) { $initialValue="계좌 기본값"; $options=@() }
                elseif ($isPassword) { $initialValue="******"; $options=@() }
                else {
                    $initialValue = [string]$window.rawTitle
                    $options = @($textValues | Select-Object -First $maxOptions | ForEach-Object { [pscustomobject]@{id=[string]$_.id;value=[string]$_.value;displayValue=$(if ($_.displayValue) {[string]$_.displayValue} else {[string]$_.value});labelSource="dataset";index=0;expectedOutcome=$_.expectedOutcome} })
                    if ($options.Count -eq 0) { $dataRequired=$true; $pendingReason="데이터셋 autoExploration.defaultTextValues에 입력값이 필요합니다." }
                }
            }
            "Date" {
                $initialValue = [string](Get-RuleDateDisplayValue $window $children)
                $options = @($dateValues | Select-Object -First $maxOptions | ForEach-Object {
                    $value = ConvertTo-RuleDateValue ([string]$_.value)
                    [pscustomobject]@{id=[string]$_.id;value=[string]$value;displayValue=$(if ($_.displayValue) {[string]$_.displayValue} else {$value.Insert(4,"/").Insert(7,"/")});labelSource="dataset";index=0;expectedOutcome=$_.expectedOutcome}
                })
                if ($options.Count -eq 0) { $dataRequired=$true; $pendingReason="데이터셋 autoExploration.defaultDateValues에 yyyyMMdd 입력값이 필요합니다." }
            }
            "ListBox" {
                $initialValue = [string][TargetRuleNative]::SendMessage([IntPtr][Int64]$window.hwnd,0x0188,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                $options = @(Get-RuleListOptions $Context $window $maxOptions)
                if ($options.Count -eq 0) { $pendingReason="목록 선택지를 Win32 메시지로 읽지 못했습니다." }
            }
            "Slider" {
                $minimum=[int][TargetRuleNative]::SendMessage([IntPtr][Int64]$window.hwnd,0x0401,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                $maximum=[int][TargetRuleNative]::SendMessage([IntPtr][Int64]$window.hwnd,0x0402,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                $initialValue=[string][TargetRuleNative]::SendMessage([IntPtr][Int64]$window.hwnd,0x0400,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
                if ($maximum -gt $minimum) { $options=@($minimum,[int](($minimum+$maximum)/2),$maximum | Sort-Object -Unique | ForEach-Object {[pscustomobject]@{id="value-$_";value=[string]$_;displayValue=[string]$_;labelSource="nativeRange";index=[int]$_}}) } else { $pendingReason="슬라이더 범위를 읽지 못했습니다." }
            }
            "Spin" {
                $options=@([pscustomobject]@{id="decrement";value="decrement";displayValue="감소";labelSource="generated";index=0},[pscustomobject]@{id="increment";value="increment";displayValue="증가";labelSource="generated";index=1})
            }
            "ListView" { $pendingReason="리스트뷰는 표시 데이터 영역으로 발견만 기록하며 임의 행 선택은 수행하지 않습니다." }
            "TreeView" { $pendingReason="트리뷰는 교차 프로세스 항목 텍스트를 안전하게 열거할 수 없어 발견만 기록합니다." }
        }
        $rows.Add([pscustomobject]@{
            controlId=$controlId; controlKind=$kind; name=$controlName; className=[string]$window.className
            automationEngine='Win32/MAP'; supportedActions=@()
            hwnd=[Int64]$window.hwnd; locatorSignature="$($window.className)|$(if($kind -in @('Text','Date')){''}else{$window.rawTitle})|$($relative.centerX)|$($relative.centerY)|$tabState"
            initialValue=$initialValue; tabOrder=[int]$tabOrderMap[[Int64]$window.hwnd]; tabStop=($actualTabOrder.map.ContainsKey([Int64]$window.hwnd) -or (([int64]$window.style -band 0x00010000) -ne 0))
            relativeRect=$relative; regionRole="content"; stateContext=$tabState; claimedByDataset=[bool]$claimed; dataRequired=$dataRequired
            pendingReason=$pendingReason; options=$options
        })
        if ($rows.Count -ge $maxControls) { break }
    }
    $uiaActionableControls = if ($Context.FastScenarioDiscovery) { @() } else { @(Get-FlaUiActionableControls $Screen) }
    foreach ($window in $uiaActionableControls) {
        if ($rows.Count -ge $maxControls) { break }
        if (-not (Test-RuleContentControl $window $Screen $policy)) { continue }
        # FlaUI UIA3 ControlType을 공통 실행기의 논리 컨트롤 종류로 변환한다.
        $kind=switch([string]$window.uiaControlType){
            "ControlType.CheckBox"{"CheckBox"}
            "ControlType.RadioButton"{"RadioButton"}
            "ControlType.ComboBox"{"ComboBox"}
            "ControlType.Edit"{"Text"}
            "ControlType.Document"{"Text"}
            "ControlType.Tab"{"Tab"}
            "ControlType.TabItem"{"RadioButton"}
            "ControlType.List"{"ListBox"}
            "ControlType.ListItem"{"RadioButton"}
            "ControlType.Slider"{"Slider"}
            "ControlType.Spinner"{"Spin"}
            default{"Button"}
        }
        if ($kind -eq "Button" -and -not [bool]$Context.Dataset.autoExploration.includeButtons) { continue }
        if ($kind -eq "Button" -and -not $window.rawTitle -and -not [bool]$Context.Dataset.autoExploration.includeUnlabeledButtons) { continue }
        $relative=Get-RuleRelativeRect $window.rect $Screen.rect
        $duplicate=@($rows | Where-Object {
            $_.controlKind-eq$kind -and [Math]::Abs([int]$_.relativeRect.centerX-[int]$relative.centerX)-le4 -and
            [Math]::Abs([int]$_.relativeRect.centerY-[int]$relative.centerY)-le4
        }).Count -gt 0
        if ($duplicate) { continue }
        $options=switch($kind){
            "CheckBox"{@([pscustomobject]@{id="unchecked";value="false";displayValue="해제";labelSource="uia";index=0},[pscustomobject]@{id="checked";value="true";displayValue="선택";labelSource="uia";index=1})}
            "RadioButton"{@([pscustomobject]@{id="select";value="true";displayValue=$(if($window.rawTitle){$window.rawTitle}else{"선택 항목"});labelSource="flaui-uia3";index=1})}
            "ComboBox"{@($window.uiaOptions | ForEach-Object {[pscustomobject]@{id="index-$([int]$_.index)";value=[string]$_.index;displayValue=$(if($_.name){[string]$_.name}else{"항목 $([int]$_.index+1)"});labelSource="flaui-uia3";index=[int]$_.index}})}
            "Text"{@([pscustomobject]@{id="current";value=[string]$window.uiaCurrentValue;displayValue="현재값 유지";labelSource="flaui-uia3";index=0})}
            "Tab"{@($window.uiaOptions | ForEach-Object {[pscustomobject]@{id="tab-$([int]$_.index)";value=[string]$_.index;displayValue=$(if($_.name){[string]$_.name}else{"탭 $([int]$_.index+1)"});labelSource="flaui-uia3";index=[int]$_.index}})}
            "ListBox"{@($window.uiaOptions | ForEach-Object {[pscustomobject]@{id="row-$([int]$_.index)";value=[string]$_.index;displayValue=$(if($_.name){[string]$_.name}else{"목록 항목 $([int]$_.index+1)"});labelSource="flaui-uia3";index=[int]$_.index}})}
            "Slider"{@([pscustomobject]@{id="minimum";value=[string]$window.uiaMinimum;displayValue="최소값";labelSource="flaui-uia3";index=0},[pscustomobject]@{id="maximum";value=[string]$window.uiaMaximum;displayValue="최대값";labelSource="flaui-uia3";index=1})}
            "Spin"{@([pscustomobject]@{id="increment";value="increment";displayValue="증가";labelSource="flaui-uia3";index=0},[pscustomobject]@{id="decrement";value="decrement";displayValue="감소";labelSource="flaui-uia3";index=1})}
            default{@([pscustomobject]@{id="click";value="click";displayValue=$(if($window.rawTitle){$window.rawTitle}else{"이름 없는 콘텐츠 버튼"});labelSource="uia";index=0})}
        }
        $identity=[pscustomobject]@{className=$window.className;rawTitle=[string]$window.rawTitle}
        $rows.Add([pscustomobject]@{
            controlId=(New-RuleControlId $ScreenNumber $identity $kind $relative $tabState);controlKind=$kind;name=[string]$window.rawTitle;className=[string]$window.className
            hwnd=[Int64]$window.hwnd;uiaRuntimeId=[string]$window.uiaRuntimeId;automationId=[string]$window.automationId;uiaClassName=[string]$window.uiaClassName
            uiaControlType=[string]$window.uiaControlType;automationEngine='FlaUI.UIA3';supportedActions=@($window.supportedActions)
            locatorSignature="$($window.className)|$($window.rawTitle)|$($relative.centerX)|$($relative.centerY)|$tabState"
            initialValue=$(if($kind -eq 'Tab' -and $null -ne $window.uiaSelectedIndex){[string]$window.uiaSelectedIndex}else{[string]$window.uiaCurrentValue})
            tabOrder=50000+[int]$window.enumerationIndex;tabStop=$true;relativeRect=$relative;regionRole="content";stateContext=$tabState
            claimedByDataset=$false;dataRequired=$false;pendingReason="";options=$options
        })
    }
    foreach ($hotspot in @($policy.visualHotspots)) {
        if ($rows.Count -ge $maxControls) { break }
        $sourceKind = if ($hotspot.kind) { [string]$hotspot.kind } else { "visualButton" }
        $kind = switch ($sourceKind) {
            "visualCombo" { "ComboBox" }
            "visualCheck" { "CheckBox" }
            "visualTab" { "Tab" }
            default { "Button" }
        }
        $name = if ($hotspot.label) { [string]$hotspot.label } else { "configured-hotspot" }
        $centerX = [int]$hotspot.centerX
        $centerY = [int]$hotspot.centerY
        $width = if ($hotspot.width) { [int]$hotspot.width } else { 24 }
        $height = if ($hotspot.height) { [int]$hotspot.height } else { 20 }
        $optionCount = if ($hotspot.optionCount) { [Math]::Min([int]$hotspot.optionCount,$maxOptions) } else { 0 }
        $options = switch ($kind) {
            "ComboBox" { @(for($index=0;$index -lt $optionCount;$index++){[pscustomobject]@{id="index-$index";value=[string]$index;displayValue="항목 $($index+1) (좌표 설정)";labelSource="configuredOrdinal";index=$index}}) }
            "CheckBox" { @([pscustomobject]@{id="toggle";value="toggle";displayValue="토글";labelSource="configured";index=0}) }
            "Tab" { @(for($index=0;$index -lt $optionCount;$index++){[pscustomobject]@{id="tab-$index";value=[string]$index;displayValue="탭 $($index+1) (좌표 설정)";labelSource="configuredOrdinal";index=$index}}) }
            default { @([pscustomobject]@{id="click";value="click";displayValue=$name;labelSource="configured";index=0}) }
        }
        $pendingReason = if ($kind -in @("ComboBox","Tab") -and @($options).Count -eq 0) { "좌표 핫스팟에 optionCount를 지정해야 전체 선택지를 실행할 수 있습니다." } else { "" }
        $identityWindow = [pscustomobject]@{className="ConfiguredVisualHotspot";rawTitle=$name}
        $relative = [pscustomobject]@{left=$centerX-[int]($width/2);top=$centerY-[int]($height/2);right=$centerX+[int]($width/2);bottom=$centerY+[int]($height/2);width=$width;height=$height;centerX=$centerX;centerY=$centerY}
        $rows.Add([pscustomobject]@{
            controlId=(New-RuleControlId $ScreenNumber $identityWindow $kind $relative $tabState);controlKind=$kind;name=$name;className="ConfiguredVisualHotspot";hwnd=0
            automationEngine='ConfiguredVisualHotspot';supportedActions=@()
            locatorSignature="ConfiguredVisualHotspot|$name|$centerX|$centerY";relativeRect=$relative;regionRole="content";claimedByDataset=$false
            initialValue="";tabOrder=100000+$rows.Count;tabStop=$false
            dataRequired=$false;pendingReason=$pendingReason;options=$options
        })
    }
    @(Merge-RuleMapBaseline $Context $Screen $ScreenNumber @($rows.ToArray() | Sort-Object tabOrder,controlId))
}
