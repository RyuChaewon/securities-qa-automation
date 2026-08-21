<#
.SYNOPSIS versioned TargetAdapter profile을 generic 실행 컨텍스트와 조회 함수로 정규화한다.
.DESCRIPTION 대상별 화면 ID, AutomationId, 상태형 컨트롤, MAP host와 대화상자 matcher를 외부 profile에서만 읽는다.
.NOTES UI 조작, 파일 읽기, 결과 판정과 리포트 생성은 수행하지 않는다.
#>

function New-HtsTargetAdapterContext($Profile) {
    $adapter = if ($Profile -and $Profile.adapter) { $Profile.adapter } else { $null }
    $states = @{}
    if ($adapter) {
        foreach ($control in @($adapter.statefulControls)) {
            $key = Get-HtsTargetStateKey ([string]$control.screenId) ([string]$control.mapScreenCode) ([string]$control.logicalName)
            if (-not [string]::IsNullOrWhiteSpace([string]$control.defaultValue)) {
                $states[$key] = [string]$control.defaultValue
            }
        }
    }
    [pscustomobject]@{
        Profile = $adapter
        StateByControlKey = $states
    }
}

# 대상별 상태 저장소가 사용하는 대소문자 비의존 canonical key를 만든다.
function Get-HtsTargetStateKey([string]$ScreenId, [string]$MapScreenCode, [string]$LogicalName) {
    "$($ScreenId.Trim().ToUpperInvariant())|$($MapScreenCode.Trim().ToUpperInvariant())|$($LogicalName.Trim().ToUpperInvariant())"
}

# profile의 MAP alias를 실제 adapter MAP 코드로 정규화한다.
function Resolve-HtsTargetMapScreenCode($AdapterContext, [string]$MapScreenCode) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile -or -not $AdapterContext.Profile.mapAliases) { return $MapScreenCode }
    $property = $AdapterContext.Profile.mapAliases.PSObject.Properties | Where-Object {
        [string]::Equals([string]$_.Name,$MapScreenCode,[StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if ($property -and [string]$property.Value) { return [string]$property.Value }
    $MapScreenCode
}

# 화면, MAP, 논리 이름으로 상태형 control 계약을 조회한다.
function Get-HtsTargetStatefulControl($AdapterContext, [string]$ScreenId, [string]$MapScreenCode, [string]$LogicalName = '') {
    if (-not $AdapterContext -or -not $AdapterContext.Profile) { return $null }
    $resolvedMapScreenCode = Resolve-HtsTargetMapScreenCode $AdapterContext $MapScreenCode
    @($AdapterContext.Profile.statefulControls | Where-Object {
        [string]::Equals([string]$_.screenId,$ScreenId,[StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$_.mapScreenCode,$resolvedMapScreenCode,[StringComparison]::OrdinalIgnoreCase) -and
        (-not $LogicalName -or [string]::Equals([string]$_.logicalName,$LogicalName,[StringComparison]::OrdinalIgnoreCase))
    } | Select-Object -First 1)[0]
}

# scenario stateContext와 일치하는 상태형 control 계약을 조회한다.
function Get-HtsTargetStatefulControlForContext($AdapterContext, [string]$ScreenId, [string]$MapScreenCode, [string]$StateContext) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile -or [string]::IsNullOrWhiteSpace($StateContext)) { return $null }
    $resolvedMapScreenCode = Resolve-HtsTargetMapScreenCode $AdapterContext $MapScreenCode
    @($AdapterContext.Profile.statefulControls | Where-Object {
        [string]::Equals([string]$_.screenId,$ScreenId,[StringComparison]::OrdinalIgnoreCase) -and
        (-not $MapScreenCode -or [string]::Equals([string]$_.mapScreenCode,$resolvedMapScreenCode,[StringComparison]::OrdinalIgnoreCase)) -and
        [string]$_.stateContextPattern -and $StateContext -match [string]$_.stateContextPattern
    } | Select-Object -First 1)[0]
}

# 상태형 control에서 요청 값과 정확히 일치하는 option 계약을 반환한다.
function Get-HtsTargetStateOption($StatefulControl, $Option) {
    if (-not $StatefulControl -or -not $Option) { return $null }
    @($StatefulControl.options | Where-Object { [string]$_.value -eq [string]$Option.value } | Select-Object -First 1)[0]
}

# 실행 컨텍스트에 상태형 control의 현재 값을 기록한다.
function Set-HtsTargetState($AdapterContext, $StatefulControl, [string]$Value) {
    if (-not $AdapterContext -or -not $StatefulControl) { return }
    $key = Get-HtsTargetStateKey ([string]$StatefulControl.screenId) ([string]$StatefulControl.mapScreenCode) ([string]$StatefulControl.logicalName)
    $AdapterContext.StateByControlKey[$key] = $Value
}

# 실행 컨텍스트에 기록된 상태형 control 값을 조회한다.
function Get-HtsTargetState($AdapterContext, $StatefulControl) {
    if (-not $AdapterContext -or -not $StatefulControl) { return '' }
    $key = Get-HtsTargetStateKey ([string]$StatefulControl.screenId) ([string]$StatefulControl.mapScreenCode) ([string]$StatefulControl.logicalName)
    [string]$AdapterContext.StateByControlKey[$key]
}

# 공개 override 값을 첫 상태형 control option으로 검증해 초기 상태에 적용한다.
function Set-HtsTargetInitialStateOverride($AdapterContext, [string]$Value) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile) { throw 'TargetStateOverride에는 targetProfile.adapter가 필요합니다.' }
    $control = @($AdapterContext.Profile.statefulControls | Select-Object -First 1)[0]
    if (-not $control) { throw 'TargetStateOverride를 적용할 stateful control이 없습니다.' }
    $option = @($control.options | Where-Object { [string]$_.value -eq $Value } | Select-Object -First 1)[0]
    if (-not $option) { throw "TargetStateOverride 값이 adapter option에 없습니다: $Value" }
    Set-HtsTargetState $AdapterContext $control $Value
}

# stateContext가 adapter에 선언된 상태형 의미인지 확인한다.
function Test-HtsTargetStateContext($AdapterContext, [string]$StateContext) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile -or [string]::IsNullOrWhiteSpace($StateContext)) { return $false }
    @($AdapterContext.Profile.statefulControls | Where-Object {
        [string]$_.stateContextPattern -and $StateContext -match [string]$_.stateContextPattern
    }).Count -gt 0
}

# adapter 상태 context는 허용하고 그 밖의 context는 기존 문자열 일치로 비교한다.
function Test-HtsTargetStateContextMatch($AdapterContext, [string]$Expected, [string]$Actual) {
    if ([string]::IsNullOrWhiteSpace($Expected)) { return $true }
    if (Test-HtsTargetStateContext $AdapterContext $Expected) { return $true }
    [string]::Equals($Actual,$Expected,[StringComparison]::OrdinalIgnoreCase)
}

# 화면과 MAP에 선언된 target host binding을 조회한다.
function Get-HtsTargetMapHost($AdapterContext, [string]$ScreenId, [string]$MapScreenCode) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile) { return $null }
    $resolvedMapScreenCode = Resolve-HtsTargetMapScreenCode $AdapterContext $MapScreenCode
    @($AdapterContext.Profile.mapHosts | Where-Object {
        [string]::Equals([string]$_.screenId,$ScreenId,[StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$_.mapScreenCode,$resolvedMapScreenCode,[StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)[0]
}

# target profile이 제공하는 거래 확인 대화상자 matcher 계약을 반환한다.
function Get-HtsTargetTransactionalDialogPolicy($AdapterContext) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile) { return $null }
    $AdapterContext.Profile.transactionalDialogs
}

# 상태형 control 계약의 호환 오류 코드를 중복 없이 수집한다.
function Get-HtsTargetStateErrorCodes($AdapterContext) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile) { return @() }
    @($AdapterContext.Profile.statefulControls | ForEach-Object {
        @([string]$_.selectionRequiredErrorCode,[string]$_.profileValueMissingErrorCode,[string]$_.stateMismatchErrorCode)
    } | Where-Object { $_ } | Select-Object -Unique)
}
