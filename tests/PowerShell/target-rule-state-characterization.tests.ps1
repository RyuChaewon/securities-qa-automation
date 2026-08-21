<# .SYNOPSIS Characterizes target rule state behavior before explicit context migration. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\rule-control-exploration.ps1')

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
$dataset = [pscustomobject]@{
    targetProfile = [pscustomobject]@{
        map = [pscustomobject]@{ initiallyActiveMapScreenCodes = @('HT010102', 'ht010101', 'HT010102') }
    }
    autoExploration = [pscustomobject]@{
        interactionStrategy = 'CoordinateFocus'
        contentRegionFile = ''
        maxActionsPerScreen = 2
    }
}
$mapCatalog = [pscustomobject]@{
    screens = @(
        [pscustomobject]@{ screenNumber = '0101'; screenCode = 'HT010102' },
        [pscustomobject]@{ screenNumber = '0101'; screenCode = 'HT010101' },
        [pscustomobject]@{ screenNumber = '0714'; screenCode = 'HT0714' }
    )
}

$context = New-HtsTargetRuleContext -RootPath $root -Dataset $dataset -MapCatalog $mapCatalog
$models = @(Get-RuleMapScreenModels -Context $context -ScreenNumber '0101')
Assert-Equal 2 $models.Count 'screen model filtering is preserved'
Assert-Equal 'HT010101' ([string]$models[0].screenCode) 'screen models remain sorted by screenCode'
Assert-Equal 'HT010102' ([string](Get-RuleMapScreenModel -Context $context -ScreenNumber '0101' -MapScreenCode 'HT010102').screenCode) 'explicit map screen selection is preserved'
Assert-Equal 'HT010101' ([string](Get-RuleMapScreenModel -Context $context -ScreenNumber '0101').screenCode) 'default map screen selection remains deterministic'

Set-RuleOrderTabState -Context $context -ScreenNumber '0101' -MapScreenCode 'ht010115' -Value '2'
Assert-Equal '2' (Get-RuleOrderTabState -Context $context -ScreenNumber '0101' -MapScreenCode 'HT010115') 'order-tab keys remain case insensitive'

$controls = @(
    [pscustomobject]@{ controlId='B';tabOrder=2;claimedByDataset=$false;dataRequired=$false;options=@([pscustomobject]@{id='b1'},[pscustomobject]@{id='b2'}) },
    [pscustomobject]@{ controlId='A';tabOrder=1;claimedByDataset=$false;dataRequired=$false;options=@([pscustomobject]@{id='a1'},[pscustomobject]@{id='a2'}) }
)
$plans = @(Get-RuleControlPlanItems -Context $context -Controls $controls)
Assert-Equal 2 $plans.Count 'maxActionsPerScreen remains a hard planning limit'
Assert-Equal 'A-a1' ([string]$plans[0].planItemId) 'plan ordering remains tabOrder then option order'
Assert-Equal 'A-a2' ([string]$plans[1].planItemId) 'plan truncation remains deterministic'

$secondContext = New-HtsTargetRuleContext -RootPath $root -Dataset $dataset -MapCatalog $mapCatalog
Assert-Equal '' (Get-RuleOrderTabState -Context $secondContext -ScreenNumber '0101' -MapScreenCode 'HT010115') 'a new run context starts with isolated order-tab state'
Assert-Equal '2' (Get-RuleOrderTabState -Context $context -ScreenNumber '0101' -MapScreenCode 'HT010115') 'creating another context does not mutate the first run'
Assert-True (Test-RuleRuntimeKindCompatible -PlannedKind 'Date' -RuntimeKind 'Text') 'representative pure compatibility behavior remains fixed'

foreach ($path in @('hts-target-rule-context.ps1', 'hts-target-rule-discovery.ps1', 'hts-target-rule-binding.ps1', 'hts-target-rule-action.ps1')) {
    $text = Get-Content -LiteralPath (Join-Path $root "scripts\modules\$path") -Raw
    Assert-True ($text -notmatch '\$script:') "$path has no script-scoped shared state"
}

Write-Output "TARGET_RULE_STATE_CHARACTERIZATION=PASS assertions=$script:assertions"
