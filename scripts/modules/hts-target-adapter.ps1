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

function Get-HtsTargetStateKey([string]$ScreenId, [string]$MapScreenCode, [string]$LogicalName) {
    "$($ScreenId.Trim().ToUpperInvariant())|$($MapScreenCode.Trim().ToUpperInvariant())|$($LogicalName.Trim().ToUpperInvariant())"
}

function Resolve-HtsTargetMapScreenCode($AdapterContext, [string]$MapScreenCode) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile -or -not $AdapterContext.Profile.mapAliases) { return $MapScreenCode }
    $property = $AdapterContext.Profile.mapAliases.PSObject.Properties | Where-Object {
        [string]::Equals([string]$_.Name,$MapScreenCode,[StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if ($property -and [string]$property.Value) { return [string]$property.Value }
    $MapScreenCode
}

function Get-HtsTargetStatefulControl($AdapterContext, [string]$ScreenId, [string]$MapScreenCode, [string]$LogicalName = '') {
    if (-not $AdapterContext -or -not $AdapterContext.Profile) { return $null }
    $resolvedMapScreenCode = Resolve-HtsTargetMapScreenCode $AdapterContext $MapScreenCode
    @($AdapterContext.Profile.statefulControls | Where-Object {
        [string]::Equals([string]$_.screenId,$ScreenId,[StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$_.mapScreenCode,$resolvedMapScreenCode,[StringComparison]::OrdinalIgnoreCase) -and
        (-not $LogicalName -or [string]::Equals([string]$_.logicalName,$LogicalName,[StringComparison]::OrdinalIgnoreCase))
    } | Select-Object -First 1)[0]
}

function Get-HtsTargetStatefulControlForContext($AdapterContext, [string]$ScreenId, [string]$MapScreenCode, [string]$StateContext) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile -or [string]::IsNullOrWhiteSpace($StateContext)) { return $null }
    $resolvedMapScreenCode = Resolve-HtsTargetMapScreenCode $AdapterContext $MapScreenCode
    @($AdapterContext.Profile.statefulControls | Where-Object {
        [string]::Equals([string]$_.screenId,$ScreenId,[StringComparison]::OrdinalIgnoreCase) -and
        (-not $MapScreenCode -or [string]::Equals([string]$_.mapScreenCode,$resolvedMapScreenCode,[StringComparison]::OrdinalIgnoreCase)) -and
        [string]$_.stateContextPattern -and $StateContext -match [string]$_.stateContextPattern
    } | Select-Object -First 1)[0]
}

function Get-HtsTargetStateOption($StatefulControl, $Option) {
    if (-not $StatefulControl -or -not $Option) { return $null }
    @($StatefulControl.options | Where-Object { [string]$_.value -eq [string]$Option.value } | Select-Object -First 1)[0]
}

function Set-HtsTargetState($AdapterContext, $StatefulControl, [string]$Value) {
    if (-not $AdapterContext -or -not $StatefulControl) { return }
    $key = Get-HtsTargetStateKey ([string]$StatefulControl.screenId) ([string]$StatefulControl.mapScreenCode) ([string]$StatefulControl.logicalName)
    $AdapterContext.StateByControlKey[$key] = $Value
}

function Get-HtsTargetState($AdapterContext, $StatefulControl) {
    if (-not $AdapterContext -or -not $StatefulControl) { return '' }
    $key = Get-HtsTargetStateKey ([string]$StatefulControl.screenId) ([string]$StatefulControl.mapScreenCode) ([string]$StatefulControl.logicalName)
    [string]$AdapterContext.StateByControlKey[$key]
}

function Set-HtsTargetInitialStateOverride($AdapterContext, [string]$Value) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile) { throw 'TargetStateOverride에는 targetProfile.adapter가 필요합니다.' }
    $control = @($AdapterContext.Profile.statefulControls | Select-Object -First 1)[0]
    if (-not $control) { throw 'TargetStateOverride를 적용할 stateful control이 없습니다.' }
    $option = @($control.options | Where-Object { [string]$_.value -eq $Value } | Select-Object -First 1)[0]
    if (-not $option) { throw "TargetStateOverride 값이 adapter option에 없습니다: $Value" }
    Set-HtsTargetState $AdapterContext $control $Value
}

function Test-HtsTargetStateContext($AdapterContext, [string]$StateContext) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile -or [string]::IsNullOrWhiteSpace($StateContext)) { return $false }
    @($AdapterContext.Profile.statefulControls | Where-Object {
        [string]$_.stateContextPattern -and $StateContext -match [string]$_.stateContextPattern
    }).Count -gt 0
}

function Test-HtsTargetStateContextMatch($AdapterContext, [string]$Expected, [string]$Actual) {
    if ([string]::IsNullOrWhiteSpace($Expected)) { return $true }
    if (Test-HtsTargetStateContext $AdapterContext $Expected) { return $true }
    [string]::Equals($Actual,$Expected,[StringComparison]::OrdinalIgnoreCase)
}

function Get-HtsTargetMapHost($AdapterContext, [string]$ScreenId, [string]$MapScreenCode) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile) { return $null }
    $resolvedMapScreenCode = Resolve-HtsTargetMapScreenCode $AdapterContext $MapScreenCode
    @($AdapterContext.Profile.mapHosts | Where-Object {
        [string]::Equals([string]$_.screenId,$ScreenId,[StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$_.mapScreenCode,$resolvedMapScreenCode,[StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)[0]
}

function Get-HtsTargetTransactionalDialogPolicy($AdapterContext) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile) { return $null }
    $AdapterContext.Profile.transactionalDialogs
}

function Get-HtsTargetStateErrorCodes($AdapterContext) {
    if (-not $AdapterContext -or -not $AdapterContext.Profile) { return @() }
    @($AdapterContext.Profile.statefulControls | ForEach-Object {
        @([string]$_.selectionRequiredErrorCode,[string]$_.profileValueMissingErrorCode,[string]$_.stateMismatchErrorCode)
    } | Where-Object { $_ } | Select-Object -Unique)
}
