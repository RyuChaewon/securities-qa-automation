<# Read-only FlaUI/UIA3 observation of one already-open 0101 screen. #>
param(
 [ValidateSet('1q-hts-0101')][string]$Target='1q-hts-0101',
 [ValidatePattern('^0101$')][string]$ScreenId='0101',
 [string]$OutputDirectory='',[string]$FlaUiAssembly='',
 [ValidateRange(1000,60000)][int]$TimeoutMs=10000,
 [ValidateRange(1,64)][int]$MaxDepth=16,
 [ValidateRange(1,20000)][int]$MaxElements=5000)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$profilePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\target-profile.json'))
if(-not(Test-Path -LiteralPath $profilePath -PathType Leaf)){throw "Target profile not found: $profilePath"}
$profile=Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$profile.id-ne$Target){throw "Target profile id mismatch: expected=$Target actual=$($profile.id)"}
if(-not$OutputDirectory){$OutputDirectory=Join-Path $root ('artifacts\local\order-screen-discovery\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))}
if(-not$FlaUiAssembly){$FlaUiAssembly=Join-Path $root 'src\HtsQa.FlaUi\bin\Release\net8.0-windows7.0\HtsQa.FlaUi.dll'}
. (Join-Path $root 'scripts\modules\hts-native.ps1')
. (Join-Path $root 'scripts\modules\hts-session.ps1')
. (Join-Path $root 'scripts\modules\hts-layout-inspection.ps1')
Initialize-HtsNativeInterop
$session=New-HtsSessionContext -FlaUiAssembly $FlaUiAssembly -TargetWindowClassName ([string]$profile.window.className) -TargetWindowTitlePrefix ([string]$profile.window.titlePrefix) -DisplayName ([string]$profile.displayName) -GetTopWindows { @(Get-TopWindows) }
[void](Start-FlaUiBridge -Context $session)
try {
 $context=New-HtsLayoutInspectionContext -SessionContext $session -GetTopWindows { @(Get-TopWindows) } -GetChildWindows { param([Int64]$Hwnd) @(Get-ChildWindows $Hwnd) } -InvokeBridgeRequest { param($BridgeContext,$Request) Invoke-FlaUiBridgeRequest -Context $BridgeContext -Request $Request }
 $summary=Invoke-HtsOrderScreenInspection -Context $context -TargetProfile $profile -ScreenId $ScreenId -OutputDirectory $OutputDirectory -TimeoutMs $TimeoutMs -MaxDepth $MaxDepth -MaxElements $MaxElements
 $summary|ConvertTo-Json -Depth 8
} finally { Stop-FlaUiBridge -Context $session }
