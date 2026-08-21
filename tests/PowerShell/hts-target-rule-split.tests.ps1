<# .SYNOPSIS Characterization tests for target-specific rule control module ownership. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

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

function Get-ScriptAst([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Path), [ref]$tokens, [ref]$errors)
    if ($errors) { throw ($errors | ForEach-Object Message | Out-String) }
    $ast
}

$script:assertions = 0
$moduleRoot = Join-Path $root 'scripts\modules'
$aggregatorPath = Join-Path $moduleRoot 'rule-control-exploration.ps1'
$adapterPath = Join-Path $moduleRoot 'hts-target-adapter.ps1'
$contextPath = Join-Path $moduleRoot 'hts-target-rule-context.ps1'
$discoveryPath = Join-Path $moduleRoot 'hts-target-rule-discovery.ps1'
$bindingPath = Join-Path $moduleRoot 'hts-target-rule-binding.ps1'
$actionPath = Join-Path $moduleRoot 'hts-target-rule-action.ps1'
$paths = @($adapterPath, $contextPath, $discoveryPath, $bindingPath, $actionPath)

$aggregatorAst = Get-ScriptAst $aggregatorPath
$aggregatorFunctions = @($aggregatorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
Assert-Equal 0 $aggregatorFunctions.Count 'compatibility entrypoint defines no operational functions'
$aggregatorText = Get-Content -LiteralPath $aggregatorPath -Raw
foreach ($name in @('hts-target-adapter.ps1', 'hts-target-rule-context.ps1', 'hts-target-rule-discovery.ps1', 'hts-target-rule-binding.ps1', 'hts-target-rule-action.ps1')) {
    Assert-True ($aggregatorText.Contains($name)) "compatibility entrypoint loads $name"
}

$functionsByFile = @{}
$allFunctionNames = @()
foreach ($path in $paths) {
    $ast = Get-ScriptAst $path
    $names = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
    $functionsByFile[[IO.Path]::GetFileName($path)] = $names
    $allFunctionNames += $names
}
Assert-Equal 63 $allFunctionNames.Count 'split retains generic target functions plus explicit adapter/context dependencies'
Assert-Equal 63 @($allFunctionNames | Sort-Object -Unique).Count 'each function has one implementation'
Assert-True ($functionsByFile['hts-target-adapter.ps1'] -contains 'New-HtsTargetAdapterContext') 'adapter module owns target profile normalization'
Assert-True ($functionsByFile['hts-target-rule-context.ps1'] -contains 'New-HtsTargetRuleContext') 'context module owns per-run state construction'
Assert-True ($functionsByFile['hts-target-rule-discovery.ps1'] -contains 'Get-RuleDiscoveredControls') 'discovery owns target control discovery'
Assert-True ($functionsByFile['hts-target-rule-discovery.ps1'] -notcontains 'Invoke-RuleControlPlanItem') 'discovery does not own target actions'
Assert-True ($functionsByFile['hts-target-rule-binding.ps1'] -contains 'Resolve-RuleLiveControl') 'binding owns live control resolution'
Assert-True ($functionsByFile['hts-target-rule-binding.ps1'] -notcontains 'Invoke-RuleComboOptionClick') 'binding does not own target actions'
Assert-True ($functionsByFile['hts-target-rule-action.ps1'] -contains 'Invoke-RuleControlPlanItem') 'action owns plan item execution'
Assert-True ($functionsByFile['hts-target-rule-action.ps1'] -contains 'Invoke-RuleComboOptionClick') 'action owns combo interaction'

. $aggregatorPath
Assert-Equal 1 (Get-RuleMapCompatibility 'Text' 'Date') 'map compatibility behavior is preserved'
Assert-True (Test-RuleRuntimeKindCompatible 'Date' 'Text') 'date and text runtime compatibility is preserved'
$fakeAdapter = New-HtsTargetAdapterContext ([pscustomobject]@{adapter=[pscustomobject]@{statefulControls=@([pscustomobject]@{screenId='F001';mapScreenCode='MAP_A';logicalName='MODE';defaultValue='';stateContextPattern='^mode:(a|b)$';options=@()});mapHosts=@()}})
$fakeContext = [pscustomobject]@{TargetAdapter=$fakeAdapter}
Assert-True (Test-RuleStateContextMatch $fakeContext 'mode:a' 'unrelated') 'adapter-declared state compatibility is preserved'
Assert-True (Test-HtsTargetStateContext $fakeAdapter 'mode:b') 'adapter recognizes only configured state contexts'
Assert-Equal '20260820' (ConvertTo-RuleDateValue '2026-08-20') 'date normalization behavior is preserved'
Assert-True (-not (Test-RuleControlExecutionEligible $null)) 'missing controls remain ineligible for execution'

foreach ($path in $paths) {
    $text = Get-Content -LiteralPath $path -Raw
    Assert-True ($text -notmatch 'ResultEvaluator|Invoke-HtsRawObservationEvaluation|Set-Content|Add-Content') "$([IO.Path]::GetFileName($path)) cannot evaluate or report results"
}

& {
    foreach ($path in @($adapterPath, $contextPath, $actionPath, $bindingPath, $discoveryPath)) { . $path }
    $fakeDataset = [pscustomobject]@{
        targetProfile=[pscustomobject]@{map=[pscustomobject]@{initiallyActiveMapScreenCodes=@()};adapter=$null}
        autoExploration=[pscustomobject]@{interactionStrategy='RuntimeTabOrder';contentRegionFile='';maxActionsPerScreen=1}
    }
    $reverseContext = New-HtsTargetRuleContext -RootPath $root -Dataset $fakeDataset -MapCatalog ([pscustomobject]@{screens=@()})
    Assert-Equal 'RuntimeTabOrder' ([string]$reverseContext.CurrentInteractionStrategy) 'target modules load without Discovery/Binding/Action order dependence'
}

Write-Output "HTS_TARGET_RULE_SPLIT_TESTS=PASS assertions=$script:assertions"
