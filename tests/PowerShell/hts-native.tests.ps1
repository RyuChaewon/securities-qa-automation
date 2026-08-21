<# .SYNOPSIS Regression tests for explicit, idempotent HTS native interop initialization. #>
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath=Join-Path $root 'scripts\modules\hts-native.ps1'
. $modulePath
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERT_TRUE failed: $Message"};$script:assertions++}

$script:assertions=0
Initialize-HtsNativeInterop
Assert-True ($null-ne('TargetRuleNative'-as[type])) 'native contract compiles without opening or controlling HTS'
Initialize-HtsNativeInterop
Assert-True ($null-ne('TargetRuleNative'-as[type])) 'native initialization is idempotent'

$orchestrationPath=Join-Path $root 'scripts\modules\hts-rule-suite-orchestration.ps1'
$orchestrationText=Get-Content -LiteralPath $orchestrationPath -Raw
Assert-True ($orchestrationText-notmatch'Add-Type') 'orchestration does not declare native APIs'
Assert-True ($orchestrationText-notmatch'(?m)^\$(VK_|KEYEVENT|SWP_|HWND_|WM_)') 'orchestration has no mutable Win32 constant state'
$dryRunIndex=$orchestrationText.IndexOf('if ($DryRun)',[StringComparison]::Ordinal)
$nativeIndex=$orchestrationText.IndexOf('Initialize-HtsNativeInterop',[StringComparison]::Ordinal)
Assert-True ($dryRunIndex-ge0-and$nativeIndex-gt$dryRunIndex) 'native initialization stays after the dry-run return path'

Write-Output "HTS_NATIVE_TESTS=PASS assertions=$script:assertions"
