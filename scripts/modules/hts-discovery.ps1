<#
.SYNOPSIS FlaUI/UIA3와 MAP 기반 탐색을 명시적 실행 컨텍스트 뒤에 격리한다.
.DESCRIPTION 탐색은 원시 컨트롤 snapshot만 반환하며 UI 조작, 결과 판정 또는 리포트 작성을 수행하지 않는다.
#>

function New-HtsDiscoveryMetrics {
    [pscustomobject]@{
        FlaUiDiscoveryCalls = 0
        FlaUiElementsDiscovered = 0
        FlaUiActionAttempts = 0
        FlaUiActionSuccesses = 0
        FlaUiFallbackRequests = 0
        FlaUiFallbackReasons = New-Object Collections.Generic.List[string]
    }
}

function New-HtsDiscoveryContext {
    param(
        [Parameter(Mandatory = $true)]$SessionContext,
        [Parameter(Mandatory = $true)]$Dependencies,
        $Metrics = $null
    )

    if (-not $Metrics) { $Metrics = New-HtsDiscoveryMetrics }
    [pscustomobject]@{
        SessionContext = $SessionContext
        Dependencies = $Dependencies
        Metrics = $Metrics
    }
}

function Invoke-HtsDiscoveryDependency {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [object[]]$Arguments = @()
    )

    if (-not $Context.Dependencies -or -not ($Context.Dependencies.PSObject.Properties.Name -contains $Name)) {
        throw "HTS discovery dependency가 없습니다: $Name"
    }
    $dependency = $Context.Dependencies.$Name
    if (-not ($dependency -is [scriptblock])) { throw "HTS discovery dependency는 scriptblock이어야 합니다: $Name" }
    & $dependency @Arguments
}

function Add-HtsDiscoveryFallbackReason {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $Context.Metrics.FlaUiFallbackRequests++
    if (-not $Context.Metrics.FlaUiFallbackReasons.Contains($Reason)) {
        $Context.Metrics.FlaUiFallbackReasons.Add($Reason)
    }
}

function Get-HtsFlaUiActionableControls {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Screen
    )

    $rows = New-Object Collections.Generic.List[object]
    try {
        $Context.Metrics.FlaUiDiscoveryCalls++
        $request = [ordered]@{
            requestId = [Guid]::NewGuid().ToString('N')
            operation = 'discover'
            rootHwnd = [Int64]$Screen.hwnd
        }
        $response = Invoke-HtsDiscoveryDependency -Context $Context -Name 'InvokeBridgeRequest' -Arguments @($Context.SessionContext, $request)
        if (-not $response.success) {
            Add-HtsDiscoveryFallbackReason -Context $Context -Reason "discover:$([string]$response.errorCode)"
            return @()
        }

        $elements = @($response.elements)
        $Context.Metrics.FlaUiElementsDiscovered += $elements.Count
        for ($index = 0; $index -lt $elements.Count; $index++) {
            $element = $elements[$index]
            $type = [string]$element.controlType
            $shortType = $type.Replace('ControlType.','')
            $rect = $element.bounds
            $rows.Add([pscustomobject]@{
                hwnd = [Int64]$element.nativeWindowHandle
                parent = [Int64]$Screen.hwnd
                pid = $Screen.pid
                visible = $true
                enabled = [bool]$element.isEnabled
                hung = $false
                className = "UIA:$shortType"
                uiaClassName = [string]$element.className
                rawTitle = [string]$element.name
                style = 0
                uiaControlType = $type
                uiaRuntimeId = [string]$element.runtimeId
                automationId = [string]$element.automationId
                automationEngine = 'FlaUI.UIA3'
                supportedActions = @($element.supportedActions)
                uiaOptions = @($element.options)
                uiaSelectedIndex = $element.selectedIndex
                uiaCurrentValue = [string]$element.currentValue
                uiaMinimum = $element.minimum
                uiaMaximum = $element.maximum
                enumerationIndex = 100000 + $index
                rect = [pscustomobject]@{
                    left = [int]$rect.left
                    top = [int]$rect.top
                    right = [int]$rect.right
                    bottom = [int]$rect.bottom
                    width = [int]$rect.width
                    height = [int]$rect.height
                }
            })
        }
    } catch {
        Add-HtsDiscoveryFallbackReason -Context $Context -Reason 'discover:UIA3_BRIDGE_EXCEPTION'
    }
    $rows.ToArray()
}

function Get-HtsDiscoveryMapScreenModel {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$ScreenNumber,
        [string]$MapScreenCode = ''
    )

    Invoke-HtsDiscoveryDependency -Context $Context -Name 'GetMapScreenModel' -Arguments @($ScreenNumber, $MapScreenCode)
}

function Get-HtsDiscoveredControls {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Screen,
        [Parameter(Mandatory = $true)][string]$ScreenNumber,
        [hashtable]$ClaimedHwnds = @{}
    )

    @(Invoke-HtsDiscoveryDependency -Context $Context -Name 'GetRuleDiscoveredControls' -Arguments @($Screen, $ScreenNumber, $ClaimedHwnds))
}

# Rule-suite discovery adapter.
function Get-FlaUiActionableControls($DiscoveryContext, $Screen) {
    @(Get-HtsFlaUiActionableControls -Context $DiscoveryContext -Screen $Screen)
}
