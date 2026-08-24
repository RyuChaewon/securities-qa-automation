<# .SYNOPSIS Regression tests for read-only capture and canonical Control Repository resolution adapters. #>
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-target-rule-binding.ps1')
. (Join-Path $root 'scripts\modules\hts-control-repository.ps1')

function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERT_TRUE failed: $Message"};$script:assertions++}
function Assert-Equal($Expected,$Actual,[string]$Message){if([string]$Expected-ne[string]$Actual){throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'"};$script:assertions++}
function Assert-Throws([scriptblock]$Action,[string]$Pattern,[string]$Message){try{&$Action;throw "ASSERT_THROWS failed: $Message"}catch{if($_.Exception.Message-notmatch$Pattern){throw};$script:assertions++}}

$script:assertions=0
$script:bridgeRequest=$null
$context=New-HtsControlCaptureContext -SessionContext ([pscustomobject]@{id='fake-session'}) -Dependencies ([pscustomobject]@{
    ReadHotkey={ [pscustomobject]@{VirtualKeyCode=119} }
    GetCursorPosition={ [pscustomobject]@{X=160;Y=240} }
    InvokeBridgeRequest={
        param($Session,$Request)
        $script:bridgeRequest=$Request
        [pscustomobject]@{success=$true;captureCandidate=[pscustomobject]@{
            status='ReviewRequired';stateContext='fixture:state';mapScreenCode='FIXTURE-MAP';relativeX=0.25;relativeY=0.5
            redactionsApplied=@('current value omitted');cursorMoved=$false;clickSent=$false;automaticallyApproved=$false
        }}
    }
})
$candidate=Invoke-HtsControlCandidateCapture -Context $context -RootHwnd 42 -StateContext 'fixture:state' -MapScreenCode 'FIXTURE-MAP' -CoordinateSpace 'ScreenClient'
Assert-Equal 'ReviewRequired' $candidate.status 'capture remains review-required'
Assert-Equal 'captureCandidate' $script:bridgeRequest.operation 'capture uses read-only bridge operation'
Assert-Equal 160 $script:bridgeRequest.capturePoint.x 'hotkey cursor point is forwarded without movement'
Assert-True (-not [bool]$candidate.cursorMoved -and -not [bool]$candidate.clickSent -and -not [bool]$candidate.automaticallyApproved) 'capture cannot move, click, or approve'

$preflightContext=New-HtsControlCaptureContext -SessionContext ([pscustomobject]@{id='fake-session'}) -Dependencies ([pscustomobject]@{
    ReadHotkey={ throw 'preflight must not read hotkey' }
    GetCursorPosition={ throw 'preflight must not read cursor' }
    InvokeBridgeRequest={
        param($Session,$Request)
        $script:bridgeRequest=$Request
        [pscustomobject]@{success=$true;controlRepositoryPreflight=[pscustomobject]@{
            status='Observed';observedAnchorIds=@('host-sha256:fixture');resolvedScreenPoint=[pscustomobject]@{x=125;y=275}
            cursorMoved=$false;clickSent=$false
        }}
    }
})
$preflight=Invoke-HtsControlRepositoryPreflightObservation -Context $preflightContext -RootHwnd 42 -StateContext 'fixture:state' -MapScreenCode 'FIXTURE-MAP' -RelativeX 0.25 -RelativeY 0.5
Assert-Equal 'controlRepositoryPreflight' $script:bridgeRequest.operation 'preflight calls the read-only relative-point bridge operation'
Assert-Equal 0.25 $script:bridgeRequest.relativeX 'preflight forwards normalized coordinates, not stored desktop coordinates'
Assert-True (-not [bool]$preflight.cursorMoved -and -not [bool]$preflight.clickSent) 'preflight cannot move cursor or click'

$wrongKey=New-HtsControlCaptureContext -SessionContext ([pscustomobject]@{}) -Dependencies ([pscustomobject]@{
    ReadHotkey={ [pscustomobject]@{VirtualKeyCode=13} }
    GetCursorPosition={ throw 'must not read cursor' }
    InvokeBridgeRequest={ throw 'must not call bridge' }
})
Assert-Throws { Invoke-HtsControlCandidateCapture -Context $wrongKey -RootHwnd 42 -StateContext 'fixture' -MapScreenCode 'FIXTURE' } 'CAPTURE_HOTKEY_MISMATCH' 'non-F8 hotkey is blocked without downstream action'

$resolution=[pscustomobject]@{
    status='Resolved';trustTier='ApprovedAnchoredRelative';approvalStatus='Approved';approvalPayloadHash=('a'*64)
    repositoryKey='F001|MAP|CONTROL|STATE';action='Input';physicalAction=$true;actionSent=$false;resolvedScreenPoint=[pscustomobject]@{x=125;y=275}
}
$hotspot=ConvertFrom-HtsCanonicalControlResolution $resolution
Assert-Equal 'ConfiguredVisualHotspot' $hotspot.className 'canonical approved coordinate becomes an explicit adapter object'
Assert-Equal 125 $hotspot.rect.left 'adapter preserves Core resolved point'
Assert-Equal 'Resolved' $hotspot.controlRepositoryResolution.status 'canonical resolution is retained without rewriting'

$unapproved=$resolution|Select-Object *;$unapproved.approvalStatus='PendingApproval'
$draft=$resolution|Select-Object *;$draft.status='ReviewSuggestion'
$imageOnly=$resolution|Select-Object *;$imageOnly.trustTier='VisualObservationOnly'
$alreadySent=$resolution|Select-Object *;$alreadySent.actionSent=$true
$observation=$resolution|Select-Object *;$observation.action='Assert';$observation.physicalAction=$false
$wrongClickIntent=$resolution|Select-Object *;$wrongClickIntent.action='Assert';$wrongClickIntent.physicalAction=$true
Assert-True ($null-eq(ConvertFrom-HtsCanonicalControlResolution $observation)) 'non-physical canonical resolution cannot become a hotspot'
Assert-True ($null-eq(ConvertFrom-HtsCanonicalControlResolution $wrongClickIntent)) 'assertion intent cannot be escalated to a physical hotspot'
Assert-True ($null-eq(ConvertFrom-HtsCanonicalControlResolution $unapproved)) 'unapproved resolution is blocked'
Assert-True ($null-eq(ConvertFrom-HtsCanonicalControlResolution $draft)) 'review suggestion is blocked'
$ruleContext=[pscustomobject]@{LastLiveControlResolution=[pscustomobject]@{} }
$legacyPlanned=[pscustomobject]@{className='ConfiguredVisualHotspot';name='legacy';definitionSource='ConfiguredVisualHotspot'}
$legacyLive=Resolve-RuleLiveControl $ruleContext ([pscustomobject]@{}) ([pscustomobject]@{}) $legacyPlanned
Assert-True ($null-eq$legacyLive) 'legacy hotspot cannot be reconstructed from stored coordinates'
Assert-Equal 'CONTROL_REPOSITORY_APPROVAL_REQUIRED' $ruleContext.LastLiveControlResolution.errorCode 'legacy hotspot records the fail-closed reason'
$approvedPlanned=$legacyPlanned|Select-Object *
$approvedPlanned|Add-Member NoteProperty controlRepositoryResolution $resolution
$approvedLive=Resolve-RuleLiveControl $ruleContext ([pscustomobject]@{}) ([pscustomobject]@{}) $approvedPlanned
Assert-Equal 'ConfiguredVisualHotspot' $approvedLive.className 'only canonical current resolution can produce a live hotspot'
Assert-Equal 'ApprovedAnchoredRelative' $ruleContext.LastLiveControlResolution.mode 'live resolution records trust tier'

$actionText=Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-action.ps1') -Raw -Encoding UTF8
Assert-True ($actionText-match'CONTROL_REPOSITORY_APPROVAL_REQUIRED') 'physical click path retains an immediate canonical approval guard'
Assert-True ($null-eq(ConvertFrom-HtsCanonicalControlResolution $imageOnly)) 'image-only resolution is blocked for physical adapter'
Assert-True ($null-eq(ConvertFrom-HtsCanonicalControlResolution $alreadySent)) 'adapter rejects a resolution that claims an action was already sent'

$moduleText=Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-control-repository.ps1') -Raw -Encoding UTF8
$toolText=Get-Content -LiteralPath (Join-Path $root 'scripts\capture-control-candidate.ps1') -Raw -Encoding UTF8
Assert-True ($moduleText-notmatch'(?i)SetCursorPos|mouse_event|SendInput|Click-Center') 'capture module contains no cursor movement or click primitive'
Assert-True ($moduleText-notmatch'ResultEvaluator|TestResult|PASS') 'capture adapter does not calculate verdict'
Assert-True ($toolText-match"ReadKey\('NoEcho,IncludeKeyDown'\)") 'tool waits for a non-action key-down'
Assert-True ($toolText-notmatch'(?i)SetCursorPos|mouse_event|SendInput|Click-Center') 'hover tool contains no physical action primitive'

Write-Output "HTS_CONTROL_REPOSITORY_TESTS=PASS assertions=$script:assertions"
