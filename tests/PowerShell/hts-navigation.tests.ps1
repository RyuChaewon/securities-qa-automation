<# .SYNOPSIS Regression tests for explicit HTS navigation context and adapters. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-session.ps1')
. (Join-Path $root 'scripts\modules\hts-navigation.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_TRUE failed: $Message" }
    $script:assertions++
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) {
        throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'"
    }
    $script:assertions++
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    try {
        & $Action
        throw "ASSERT_THROWS failed: $Message"
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
    }
    $script:assertions++
}

$script:assertions = 0
$script:operations = New-Object Collections.Generic.List[string]
$main = [pscustomobject]@{hwnd=1;pid=7;visible=$true;rawTitle='Main';rect=[pscustomobject]@{width=1200;height=800}}
$screen = [pscustomobject]@{hwnd=101;pid=7;visible=$true;enabled=$true;rawTitle='[0714] Screen';className='AfxWnd';style=0;rect=[pscustomobject]@{width=500;height=400}}
$screenEdit = [pscustomobject]@{hwnd=2;pid=7;visible=$true;rawTitle='';rect=[pscustomobject]@{width=80;height=20}}
$script:windows = @{1=$main;2=$screenEdit;101=$screen}
$script:alive = @{1=$true;2=$true;101=$true}

$session = New-HtsSessionContext -FlaUiAssembly 'unused' -GetTopWindows { @($main) }
$session.MainWindow = $main
$dependencies = [pscustomobject]@{
    GetChildWindows = { param([Int64]$Hwnd) if ($Hwnd -eq 1) { @($screen) } else { @() } }
    GetWindowInfo = { param([Int64]$Hwnd) $script:windows[[int]$Hwnd] }
    IsWindow = { param([Int64]$Hwnd) [bool]$script:alive[[int]$Hwnd] }
    ActivateMain = { param($Window) $script:operations.Add('activate-main') }
    ActivateRequestedScreen = { param($MainWindow, $ScreenWindow) $script:operations.Add("activate-screen:$($ScreenWindow.hwnd)") }
    SetInputSurface = { param($Window, [string]$Kind, [string]$Label) $script:operations.Add("surface:${Kind}:$($Window.hwnd)") }
    SetScreenNumber = { param($Edit, [string]$Number) $script:operations.Add("set-screen:$Number") }
    InvokeControlAction = { param($Window, [string]$Action, [string]$Key) $script:operations.Add("action:${Action}:$Key"); [pscustomobject]@{success=$true;verified=$true} }
    TestInputAccess = { param($Window) $script:operations.Add('test-input'); 0 }
    ClickCenter = { param($Window) $script:operations.Add('click-center') }
    SendEnter = { $script:operations.Add('send-enter') }
    FocusInputWindow = { param($Window) $script:operations.Add('focus-input') }
    Sleep = { param([int]$Milliseconds) $script:operations.Add("sleep:$Milliseconds") }
    GetNow = { Get-Date }
    GetWindowProcessId = { param([Int64]$Hwnd) 7 }
    IsChild = { param([Int64]$ParentHwnd, [Int64]$ChildHwnd) $ParentHwnd -eq 1 -and $ChildHwnd -eq 101 }
    CloseWindow = { param($Window) $script:operations.Add("close:$($Window.hwnd)"); $script:alive[[int]$Window.hwnd]=$false }
    ClearInputSurfaceForWindow = { param($Window) $script:operations.Add("clear-surface:$($Window.hwnd)") }
}
$context = New-HtsNavigationContext `
    -SessionContext $session `
    -TargetScreenTitleRegex ([regex]::new('^\[(?<screen>\d{4})\]')) `
    -ScreenOpenTimeoutMs 10000 `
    -Dependencies $dependencies

Open-HtsNavigationScreen -Context $context -Main $main -ScreenEdit $screenEdit -ScreenNumber '0714'
Assert-True ($script:operations.Contains('set-screen:0714')) 'open sets requested screen number'
Assert-True ($script:operations.Contains('action:pressKey:ENTER')) 'open sends ENTER through action adapter first'
Assert-True (-not $script:operations.Contains('click-center')) 'verified UIA ENTER avoids fallback click'
Assert-True ($script:operations.Contains('sleep:5000')) 'open wait preserves timeout policy'

$focused = Focus-HtsNavigationRequestedScreen -Context $context -Main $main -Screen $screen -ScreenNumber '0714'
Assert-True $focused 'requested screen focus succeeds'
Assert-True ($script:operations.Contains('activate-screen:101')) 'focus uses navigation activation adapter'
Assert-True ($script:operations.Contains('surface:Content:101')) 'focus registers content input surface'

$closed = Close-HtsNavigationScreen -Context $context -Screen $screen
Assert-True $closed 'owned child screen closes'
Assert-True ($script:operations.Contains('clear-surface:101')) 'close clears active input surface through adapter'
Assert-True ($script:operations.Contains('close:101')) 'close uses scoped close adapter'
Assert-True (-not (Close-HtsNavigationScreen -Context $context -Screen $main)) 'main window cannot be closed as a screen'

$badDependencies = [pscustomobject]@{}
Assert-Throws {
    New-HtsNavigationContext -SessionContext $session -TargetScreenTitleRegex ([regex]::new('x')) -Dependencies $badDependencies
} "dependency 'GetChildWindows' is required" 'missing dependency contract'

$navigationSource = Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-navigation.ps1') -Raw -Encoding UTF8
$explorationSource = Get-Content -LiteralPath (Join-Path $root 'scripts\modules\rule-control-exploration.ps1') -Raw -Encoding UTF8
Assert-True ($navigationSource -notmatch '\$script:') 'navigation module has no script-scoped mutable state'
Assert-True ($navigationSource -notmatch 'ResultEvaluator|TestResult|Set-Content|Add-Content|Export-Rule') 'navigation module has no evaluation or reporting logic'
Assert-True ($explorationSource -notmatch 'activeHtsMainHwnd|\bGet-HtsScreenNumber\b|\bFocus-HtsRequestedScreen\b') 'exploration receives navigation explicitly instead of runner globals'
foreach ($name in @('Find-ScreenNumberEdit','Set-HtsScreenNumber','Open-HtsScreen','Find-ScreenWindow','Focus-HtsRequestedScreen','Close-HtsScreen')) {
    Assert-True ($navigationSource -match "function $name") "navigation owns $name"
}
$orchestrationSource = Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-rule-suite-orchestration.ps1') -Raw -Encoding UTF8
Assert-True ($orchestrationSource -notmatch 'function Open-HtsScreen|function Find-ScreenWindow|function Close-HtsScreen') 'orchestration no longer defines navigation operations'

Write-Output "HTS_NAVIGATION_TESTS=PASS assertions=$script:assertions"
