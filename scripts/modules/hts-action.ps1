<#
.SYNOPSIS 승인된 HTS 컨트롤에 대한 UIA3 의미 동작을 실행하고 검증된 fallback 필요성을 원시 결과로 반환한다.
.DESCRIPTION Action은 입력·클릭·선택을 조정하지만 테스트 결과 판정 또는 리포트 생성을 수행하지 않는다.
#>

function New-HtsActionContext {
    param(
        [Parameter(Mandatory = $true)]$SessionContext,
        [Parameter(Mandatory = $true)]$Metrics,
        [Parameter(Mandatory = $true)]$Dependencies
    )

    [pscustomobject]@{
        SessionContext = $SessionContext
        Metrics = $Metrics
        Dependencies = $Dependencies
    }
}

function Invoke-HtsActionDependency {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [object[]]$Arguments = @()
    )

    if (-not $Context.Dependencies -or -not ($Context.Dependencies.PSObject.Properties.Name -contains $Name)) {
        throw "HTS action dependency가 없습니다: $Name"
    }
    $dependency = $Context.Dependencies.$Name
    if (-not ($dependency -is [scriptblock])) { throw "HTS action dependency는 scriptblock이어야 합니다: $Name" }
    & $dependency @Arguments
}

function New-HtsFlaUiSelector {
    param([Parameter(Mandatory = $true)]$Window)

    $bounds = if ($Window -and $Window.rect) {
        [ordered]@{left=[int]$Window.rect.left;top=[int]$Window.rect.top;right=[int]$Window.rect.right;bottom=[int]$Window.rect.bottom}
    } else { $null }
    $uiaClassName = if ($Window.PSObject.Properties.Name -contains 'uiaClassName') { [string]$Window.uiaClassName } elseif ([string]$Window.className -notlike 'UIA:*') { [string]$Window.className } else { '' }
    [ordered]@{
        runtimeId=$(if ($Window.PSObject.Properties.Name -contains 'uiaRuntimeId') { [string]$Window.uiaRuntimeId } else { '' })
        nativeWindowHandle=$(if ($Window.PSObject.Properties.Name -contains 'hwnd') { [Int64]$Window.hwnd } else { [Int64]0 })
        automationId=$(if ($Window.PSObject.Properties.Name -contains 'automationId') { [string]$Window.automationId } else { '' })
        name=$(if ($Window.PSObject.Properties.Name -contains 'rawTitle') { [string]$Window.rawTitle } else { '' })
        className=$uiaClassName
        controlType=$(if ($Window.PSObject.Properties.Name -contains 'uiaControlType') { [string]$Window.uiaControlType } else { '' })
        bounds=$bounds
    }
}

function Add-HtsActionFallbackReason {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $Context.Metrics.FlaUiFallbackRequests++
    if (-not $Context.Metrics.FlaUiFallbackReasons.Contains($Reason)) {
        $Context.Metrics.FlaUiFallbackReasons.Add($Reason)
    }
}

function Invoke-HtsFlaUiControlAction {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Window,
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Value = '',
        [Nullable[int]]$Index = $null,
        [Nullable[bool]]$Checked = $null,
        [string]$Key = ''
    )

    if (-not $Window -or [string]$Window.className -eq 'ConfiguredVisualHotspot') {
        return [pscustomobject]@{success=$false;verified=$false;fallbackRequired=$true;errorCode='VISUAL_HOTSPOT_REQUIRES_COORDINATE';message='시각 핫스팟은 UIA 요소가 아니므로 좌표 fallback이 필요합니다.';engine='FlaUI.UIA3'}
    }

    $centerX = [int](($Window.rect.left+$Window.rect.right)/2)
    $centerY = [int](($Window.rect.top+$Window.rect.bottom)/2)
    try {
        [void](Invoke-HtsActionDependency -Context $Context -Name 'AssertClickScope' -Arguments @($Window,$centerX,$centerY))
        $root = Invoke-HtsActionDependency -Context $Context -Name 'GetActiveInputSurface'
        $request = [ordered]@{
            requestId=[Guid]::NewGuid().ToString('N');operation='action';rootHwnd=[Int64]$root.hwnd
            selector=New-HtsFlaUiSelector $Window;action=$Action;value=$Value;key=$Key
        }
        if ($null -ne $Index) { $request.index=[int]$Index }
        if ($null -ne $Checked) { $request.checked=[bool]$Checked }
        $Context.Metrics.FlaUiActionAttempts++
        $response = Invoke-HtsActionDependency -Context $Context -Name 'InvokeBridgeRequest' -Arguments @($Context.SessionContext,$request)
        if ([bool]$response.success -and [bool]$response.verified) {
            $Context.Metrics.FlaUiActionSuccesses++
            [void](Invoke-HtsActionDependency -Context $Context -Name 'WriteInputAudit' -Arguments @('FlaUIAction','ALLOWED',$centerX,$centerY,("{0}; Pattern={1}; Target={2}" -f $Action,[string]$response.pattern,[string]$Window.rawTitle)))
            return $response
        }

        $fallbackCode = if ($response.errorCode) { [string]$response.errorCode } else { 'UIA3_RESULT_NOT_VERIFIED' }
        Add-HtsActionFallbackReason -Context $Context -Reason "${Action}:$fallbackCode"
        [void](Invoke-HtsActionDependency -Context $Context -Name 'WriteInputAudit' -Arguments @('FlaUIAction','FALLBACK',$centerX,$centerY,("{0}; {1}; {2}" -f $Action,[string]$response.errorCode,[string]$response.message)))
        $response
    } catch {
        Add-HtsActionFallbackReason -Context $Context -Reason "${Action}:UIA3_BRIDGE_EXCEPTION"
        [void](Invoke-HtsActionDependency -Context $Context -Name 'WriteInputAudit' -Arguments @('FlaUIAction','FALLBACK',$centerX,$centerY,$_.Exception.Message))
        [pscustomobject]@{success=$false;verified=$false;fallbackRequired=$true;errorCode='UIA3_BRIDGE_EXCEPTION';message=$_.Exception.Message;engine='FlaUI.UIA3'}
    }
}

function Invoke-HtsRuleControlPlanAction {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$NavigationContext,
        [Parameter(Mandatory = $true)]$Screen,
        [Parameter(Mandatory = $true)]$PlanItem
    )

    Invoke-HtsActionDependency -Context $Context -Name 'InvokeRuleControlPlanItem' -Arguments @($NavigationContext,$Screen,$PlanItem)
}

function Invoke-HtsDatasetVariableAction {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Window,
        [Parameter(Mandatory = $true)][string]$ControlKind,
        [Parameter(Mandatory = $true)][string]$Value,
        [string]$ValueMatch,
        [int]$MaxOptions = 40
    )

    Invoke-HtsActionDependency -Context $Context -Name 'InvokeRuleDatasetVariable' -Arguments @($Window,$ControlKind,$Value,$ValueMatch,$MaxOptions)
}
