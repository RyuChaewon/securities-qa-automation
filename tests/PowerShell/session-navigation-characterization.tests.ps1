<#
.SYNOPSIS Characterizes session JSON and navigation selection behavior before module extraction.
.DESCRIPTION Keeps the pre-extraction golden behavior against explicit session and navigation contexts.
#>
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

$script:assertions = 0

$asciiJson = ConvertTo-FlaUiAsciiJson ([ordered]@{requestId='r1';text='한'})
Assert-Equal '{"requestId":"r1","text":"\uD55C"}' $asciiJson 'FlaUI bridge ASCII JSON'
Assert-True (-not $asciiJson.Contains('한')) 'FlaUI bridge JSON contains ASCII only'

$script:fakeTopWindows = @(
    [pscustomobject]@{hwnd=11;visible=$true;className='HtsMain';rawTitle='하나증권 A'},
    [pscustomobject]@{hwnd=12;visible=$false;className='HtsMain';rawTitle='하나증권 B'},
    [pscustomobject]@{hwnd=15;visible=$true;className='HtsMain';rawTitle='하나증권 C'},
    [pscustomobject]@{hwnd=20;visible=$true;className='Other';rawTitle='하나증권 D'})
function Get-TopWindows { @($script:fakeTopWindows) }

$sessionContext = New-HtsSessionContext `
    -FlaUiAssembly 'unused-for-characterization' `
    -TargetWindowClassName 'HtsMain' `
    -TargetWindowTitlePrefix '하나증권' `
    -DisplayName '하나증권' `
    -GetTopWindows { Get-TopWindows }
$main = Find-HtsMainWindow -Context $sessionContext
Assert-Equal 15 $main.hwnd 'highest matching visible main HWND'
Assert-Equal 15 $sessionContext.MainWindow.hwnd 'selected main HWND stored in explicit session context'

$script:fakeChildren = @(
    [pscustomobject]@{hwnd=101;visible=$true;rawTitle='[0714] 요청';rect=[pscustomobject]@{width=500;height=400}},
    [pscustomobject]@{hwnd=102;visible=$true;rawTitle='[0714] 작은창';rect=[pscustomobject]@{width=300;height=200}},
    [pscustomobject]@{hwnd=103;visible=$true;rawTitle='[0715] 보존';rect=[pscustomobject]@{width=450;height=350}},
    [pscustomobject]@{hwnd=104;visible=$true;rawTitle='[0716] 연계';rect=[pscustomobject]@{width=420;height=320}},
    [pscustomobject]@{hwnd=105;visible=$true;rawTitle='도움말';rect=[pscustomobject]@{width=600;height=500}})
function Get-ChildWindows([Int64]$ParentHwnd) { @($script:fakeChildren) }

$navigationDependencies = [pscustomobject]@{
    GetChildWindows = { param([Int64]$Hwnd) Get-ChildWindows $Hwnd }
    GetWindowInfo = { param([Int64]$Hwnd) @($script:fakeChildren | Where-Object hwnd -eq $Hwnd | Select-Object -First 1)[0] }
    IsWindow = { param([Int64]$Hwnd) $true }
    ActivateMain = { param($Main) }
    ActivateRequestedScreen = { param($Main, $Screen) }
    SetInputSurface = { param($Window, [string]$Kind, [string]$Label) }
    SetScreenNumber = { param($ScreenEdit, [string]$ScreenNumber) }
    InvokeControlAction = { param($Window, [string]$Action, [string]$Key) [pscustomobject]@{success=$true;verified=$true} }
    TestInputAccess = { param($Window) 0 }
    ClickCenter = { param($Window) }
    SendEnter = { }
    FocusInputWindow = { param($Window) }
    Sleep = { param([int]$Milliseconds) }
    GetNow = { Get-Date }
    GetWindowProcessId = { param([Int64]$Hwnd) 1 }
    IsChild = { param([Int64]$ParentHwnd, [Int64]$ChildHwnd) $true }
    CloseWindow = { param($Window) }
    ClearInputSurfaceForWindow = { param($Window) }
}
$navigationContext = New-HtsNavigationContext `
    -SessionContext $sessionContext `
    -TargetScreenTitleRegex ([regex]::new('^\[(?<screen>\d{4})\]')) `
    -Dependencies $navigationDependencies
[void](Set-HtsNavigationPreservedScreens -Context $navigationContext -Hwnds @(103))

$mainWindow = [pscustomobject]@{hwnd=1}
Assert-Equal '0714' (Get-HtsNavigationScreenNumber -Context $navigationContext -Window $script:fakeChildren[0]) 'screen number extraction'
Assert-Equal '' (Get-HtsNavigationScreenNumber -Context $navigationContext -Window $script:fakeChildren[4]) 'non-screen title extraction'
Assert-Equal 101 (Find-HtsNavigationScreenWindow -Context $navigationContext -Main $mainWindow -ScreenNumber '0714').hwnd 'largest requested screen selection'

$screenWindows = @(Get-HtsNavigationScreenWindows -Context $navigationContext -Main $mainWindow)
Assert-Equal '101,103,104,102' (($screenWindows | ForEach-Object hwnd) -join ',') 'screen windows sorted by area'
$linked = @(Get-HtsNavigationLinkedScreens -Context $navigationContext -Main $mainWindow -RequestedScreenNumber '0714')
Assert-Equal '104' (($linked | ForEach-Object hwnd) -join ',') 'requested and preserved screens excluded from linked screens'
Assert-True (Test-HtsNavigationPreservedTargetScreen -Context $navigationContext -Window $script:fakeChildren[2]) 'preserved screen membership'
Assert-True (-not (Test-HtsNavigationPreservedTargetScreen -Context $navigationContext -Window $script:fakeChildren[3])) 'non-preserved screen membership'

Write-Output "SESSION_NAVIGATION_CHARACTERIZATION=PASS assertions=$script:assertions"
