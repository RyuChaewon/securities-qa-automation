<# .SYNOPSIS Fake profile로 순수 TargetAdapter PowerShell 계약을 검증한다. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-target-adapter.ps1')

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERT_TRUE failed: $Message" }; $script:assertions++ }
function Assert-Equal($Expected, $Actual, [string]$Message) { if ([string]$Expected -ne [string]$Actual) { throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'" }; $script:assertions++ }

$script:assertions = 0
$profile = [pscustomobject]@{
    adapter = [pscustomobject]@{
        statefulControls = @([pscustomobject]@{
            screenId='F001';mapScreenCode='MAP_A';logicalName='MODE_A';defaultValue='0';stateContextPattern='^mode:(a|b)$'
            selectionRequiredErrorCode='FAKE_STATE_REQUIRED';profileValueMissingErrorCode='FAKE_VALUE_MISSING';stateMismatchErrorCode='FAKE_STATE_MISMATCH'
            options=@(
                [pscustomobject]@{id='a';value='0';displayValue='A';stateContext='mode:a';x=10;verificationControls=@('ACTION_A')},
                [pscustomobject]@{id='b';value='1';displayValue='B';stateContext='mode:b';x=20;verificationControls=@('ACTION_B')}
            )
        })
        mapHosts = @([pscustomobject]@{screenId='F001';mapScreenCode='MAP_A';containerScreenCode='ROOT';hostRole='content';scale=1.0})
        mapAliases = [pscustomobject]@{ MAP_OLD='MAP_A' }
        transactionalDialogs = [pscustomobject]@{confirmationClassification='confirm'}
    }
}

$context = New-HtsTargetAdapterContext $profile
$control = Get-HtsTargetStatefulControl $context 'f001' 'map_a' 'mode_a'
Assert-True ($null -ne $control) 'stateful control lookup is case insensitive'
Assert-Equal '0' (Get-HtsTargetState $context $control) 'configured default state is retained'
Assert-True (Test-HtsTargetStateContext $context 'mode:b') 'configured context pattern is recognized'
Assert-True (-not (Test-HtsTargetStateContext $context 'other:a')) 'undeclared context is not recognized'
Assert-True (Test-HtsTargetStateContextMatch $context 'mode:a' 'unrelated') 'declared state uses the verified-state guard path'
Assert-True (-not (Test-HtsTargetStateContextMatch $context 'plain' 'different')) 'plain contexts still require equality'
Assert-Equal '1' ([string](Get-HtsTargetStateOption $control ([pscustomobject]@{value='1'})).value) 'state option resolves by adapter value'
Set-HtsTargetInitialStateOverride $context '1'
Assert-Equal '1' (Get-HtsTargetState $context $control) 'validated generic state override is applied'
Assert-Equal 'content' ([string](Get-HtsTargetMapHost $context 'F001' 'MAP_A').hostRole) 'map host comes from adapter'
Assert-Equal 'content' ([string](Get-HtsTargetMapHost $context 'F001' 'MAP_OLD').hostRole) 'map aliases resolve through adapter'
Assert-Equal 'confirm' ([string](Get-HtsTargetTransactionalDialogPolicy $context).confirmationClassification) 'dialog policy comes from adapter'
Assert-Equal 'FAKE_STATE_REQUIRED,FAKE_VALUE_MISSING,FAKE_STATE_MISMATCH' ((Get-HtsTargetStateErrorCodes $context) -join ',') 'compatibility error codes stay adapter-owned'

$standalone = New-HtsTargetAdapterContext ([pscustomobject]@{})
Assert-True (-not (Test-HtsTargetStateContext $standalone 'mode:a')) 'generic engine works without a target adapter'
Assert-True (Test-HtsTargetStateContextMatch $standalone 'same' 'same') 'generic exact context matching works without adapter'

Write-Output "HTS_TARGET_ADAPTER_TESTS=PASS assertions=$script:assertions"
