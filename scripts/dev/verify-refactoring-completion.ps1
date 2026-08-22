<#
.SYNOPSIS Verifies the single-owner contracts and safety boundaries of the refactored rule pipeline.
.DESCRIPTION Performs read-only source inspection; it does not start FlaUI, an HTS process, or any target action.
.INPUTS Tracked production source under src, scripts, and tools.
.OUTPUTS A PASS summary or an error list with exit code 1.
.NOTES This gate checks ownership and delegation, while behavior remains covered by unit, dry-run, and Fake tests.
#>
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$failures = New-Object Collections.Generic.List[string]
$assertions = 0

# Records a failed invariant without stopping the remaining read-only checks.
function Assert-RefactoringInvariant {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { $script:failures.Add($Message) }
}

# Returns a repository-relative path with stable separators for diagnostics.
function Get-RefactoringRelativePath {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullPath.Substring(([IO.Path]::GetFullPath($root)).Length).TrimStart('\').Replace('\', '/')
}

# Verifies that a public contract declaration has exactly one production owner.
function Assert-SingleDeclarationOwner {
    param([string]$Contract, [string]$Pattern, [string]$ExpectedPath, [IO.FileInfo[]]$Files)
    $matches = @($Files | Select-String -Pattern $Pattern -Encoding UTF8)
    Assert-RefactoringInvariant ($matches.Count -eq 1) "$Contract must have exactly one declaration; found $($matches.Count)."
    if ($matches.Count -eq 1) {
        $actualPath = Get-RefactoringRelativePath $matches[0].Path
        Assert-RefactoringInvariant ($actualPath -eq $ExpectedPath) "$Contract owner is $actualPath; expected $ExpectedPath."
    }
}

$coreFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'src\HtsQa.Core') -Recurse -File -Filter '*.cs' |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' })

$owners = @(
    @('DatasetValidator', '^public sealed class RuleDatasetValidator$', 'src/HtsQa.Core/Datasets/RuleBased.cs'),
    @('CombinationGenerator', '^public sealed class CombinationGenerator$', 'src/HtsQa.Core/TestPacks/TestPack.cs'),
    @('ExpectationResolver', '^public sealed class ExpectationResolver$', 'src/HtsQa.Core/TestPacks/TestPack.cs'),
    @('CaseIdFactory', '^public static class CaseIdFactory$', 'src/HtsQa.Core/TestPacks/TestPack.cs'),
    @('TestPackCompiler', '^public sealed class TestPackCompiler$', 'src/HtsQa.Core/TestPacks/TestPack.cs'),
    @('ApprovedTestPackRunnerContract', '^public sealed class TestPackRunnerContract$', 'src/HtsQa.Core/TestPacks/TestPack.cs'),
    @('TargetSnapshotContract', '^public sealed record RuntimeControlPlanRow$', 'src/HtsQa.Core/Scenarios/ScenarioPlanning.cs'),
    @('Observation', '^public sealed record Observation$', 'src/HtsQa.Core/Evaluation/ResultEvaluator.cs'),
    @('ExpectedResult', '^public sealed record ExpectedResult$', 'src/HtsQa.Core/Evaluation/ResultEvaluator.cs'),
    @('ResultEvaluator', '^public sealed class ResultEvaluator$', 'src/HtsQa.Core/Evaluation/ResultEvaluator.cs'),
    @('TestResult', '^public sealed record TestResult$', 'src/HtsQa.Core/Evaluation/ResultEvaluator.cs')
)
foreach ($owner in $owners) {
    Assert-SingleDeclarationOwner -Contract $owner[0] -Pattern $owner[1] -ExpectedPath $owner[2] -Files $coreFiles
}

$entryPath = Join-Path $root 'scripts\run-target-rule-suite.ps1'
$entryText = Get-Content -LiteralPath $entryPath -Raw -Encoding UTF8
$tokens = $null
$parseErrors = $null
$entryAst = [Management.Automation.Language.Parser]::ParseFile($entryPath, [ref]$tokens, [ref]$parseErrors)
$entryParameters = @($entryAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-RefactoringInvariant ($parseErrors.Count -eq 0) 'Runner entrypoint must parse without errors.'
Assert-RefactoringInvariant ($entryParameters -contains 'TestPackPath') 'Runner must require TestPackPath.'
Assert-RefactoringInvariant ($entryParameters -notcontains 'DatasetPath') 'Runner must not accept DatasetPath.'
Assert-RefactoringInvariant ($entryText -notmatch 'CombinationGenerator|RuleCaseExpander|compile-test-pack') 'Runner entrypoint must not generate or compile cases.'

$orchestrationPath = Join-Path $root 'scripts\modules\hts-rule-suite-orchestration.ps1'
$orchestrationText = Get-Content -LiteralPath $orchestrationPath -Raw -Encoding UTF8
$validationIndex = $orchestrationText.IndexOf('validate-test-pack', [StringComparison]::Ordinal)
$sessionIndex = $orchestrationText.IndexOf('Start-FlaUiBridge', [StringComparison]::Ordinal)
Assert-RefactoringInvariant ($validationIndex -ge 0) 'Orchestration must validate the approved TestPack.'
Assert-RefactoringInvariant ($sessionIndex -gt $validationIndex) 'Approved TestPack validation must precede FlaUI session startup.'
Assert-RefactoringInvariant ($orchestrationText -notmatch 'Get-VariableCombinations|Get-RuleCases|Get-HtsSignalJudgment') 'Orchestration must not contain legacy generation or judgment functions.'

$programPath = Join-Path $root 'src\HtsQa.Cli\Program.cs'
$programText = Get-Content -LiteralPath $programPath -Raw -Encoding UTF8
$runMethod = [regex]::Match($programText, '(?s)int RunTestPack\(.*?(?=\r?\nint [A-Z])').Value
Assert-RefactoringInvariant (-not [string]::IsNullOrWhiteSpace($runMethod)) 'CLI RunTestPack method must exist.'
Assert-RefactoringInvariant ($runMethod -match 'LoadApprovedCases') 'CLI Runner must load cases through TestPackRunnerContract.'
Assert-RefactoringInvariant ($runMethod -notmatch 'CombinationGenerator|RuleCaseExpander\.Expand|LoadValidatedDataset') 'CLI Runner must not expand a raw Dataset.'
Assert-RefactoringInvariant ($programText -match 'run-rule-dataset.*support' -or $programText -match 'run-rule-dataset.*\uC9C0\uC6D0') 'Legacy raw Dataset run command must remain rejected.'

$productionFiles = @(
    $coreFiles
    Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Recurse -File -Filter '*.ps1'
    Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Recurse -File |
        Where-Object { $_.Extension -in @('.mjs', '.js', '.ps1') -and $_.FullName -notmatch '\\node_modules\\' }
)
foreach ($legacyName in @('Get-VariableCombinations', 'Get-RuleCases', 'Get-HtsSignalJudgment')) {
    $legacyMatches = @($productionFiles | Where-Object { $_.FullName -ne $PSCommandPath } | Select-String -SimpleMatch $legacyName -Encoding UTF8)
    Assert-RefactoringInvariant ($legacyMatches.Count -eq 0) "Legacy implementation name remains in production: $legacyName."
}

$ruleCaseSource = Get-Content -LiteralPath (Join-Path $root 'src\HtsQa.Core\Datasets\RuleBased.cs') -Raw -Encoding UTF8
Assert-RefactoringInvariant ($ruleCaseSource -match 'RuleCaseExpander(?s).*CombinationGenerator\.ActiveExecutionContexts') 'RuleCaseExpander active context compatibility must delegate to CombinationGenerator.'
Assert-RefactoringInvariant ($ruleCaseSource -match 'RuleCaseExpander(?s).*new CombinationGenerator\(\)\.Generate\(dataset\)') 'RuleCaseExpander expansion compatibility must delegate to CombinationGenerator.'

$legacyPolicySource = Get-Content -LiteralPath (Join-Path $root 'src\HtsQa.Core\Outcomes\RuleOutcomePolicy.cs') -Raw -Encoding UTF8
Assert-RefactoringInvariant ($legacyPolicySource -match 'new ResultEvaluator\(\)\.Evaluate') 'Legacy outcome policy must delegate to ResultEvaluator.'
Assert-RefactoringInvariant ($legacyPolicySource -notmatch 'TestStatus\.(PASS|FAIL|ERROR|PENDING)') 'Legacy outcome policy must not assign TestStatus.'

$evaluatorSource = Get-Content -LiteralPath (Join-Path $root 'src\HtsQa.Core\Evaluation\ResultEvaluator.cs') -Raw -Encoding UTF8
$notExecutedIndex = $evaluatorSource.IndexOf('if (!input.Executed)', [StringComparison]::Ordinal)
$passSafetyIndex = $evaluatorSource.IndexOf('item.Status == TestStatus.PASS && (!item.Executed || !item.EvidencePresent)', [StringComparison]::Ordinal)
Assert-RefactoringInvariant ($notExecutedIndex -ge 0) 'ResultEvaluator must explicitly guard unexecuted cases.'
Assert-RefactoringInvariant ($passSafetyIndex -gt $notExecutedIndex) 'ResultEvaluator must reject unsafe completed PASS results.'

$reportLoader = Get-Content -LiteralPath (Join-Path $root 'tools\reporting\rule-results-loader.mjs') -Raw -Encoding UTF8
$reportView = Get-Content -LiteralPath (Join-Path $root 'tools\reporting\rule-results-view-model.mjs') -Raw -Encoding UTF8
$reportRenderer = Get-Content -LiteralPath (Join-Path $root 'tools\reporting\rule-results-xlsx-renderer.mjs') -Raw -Encoding UTF8
Assert-RefactoringInvariant ($reportLoader -match 'result\.status === "PASS".*result\.executed !== true.*result\.evidencePresent !== true') 'Reporter loader must reject PASS without execution and evidence.'
Assert-RefactoringInvariant ($reportLoader -match 'canonical status.*reporter status.*change' -or $reportLoader -match 'canonical status.*\uBCC0\uACBD') 'Reporter loader must reject canonical status changes.'
Assert-RefactoringInvariant (($reportView + $reportRenderer) -notmatch 'new\s+ResultEvaluator|Invoke-RuleResultEvaluation|Get-HtsSignalJudgment|evaluate-results') 'Reporter view and renderer must not evaluate results.'

$discoverySource = Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-discovery.ps1') -Raw -Encoding UTF8
Assert-RefactoringInvariant ($discoverySource -match 'function Get-HtsDiscoveredControls') 'Discovery module must own the raw target snapshot adapter.'
Assert-RefactoringInvariant ($discoverySource -notmatch 'ResultEvaluator|Set-Content|Add-Content') 'Discovery module must not evaluate or report results.'
Assert-RefactoringInvariant (Test-Path -LiteralPath (Join-Path $root 'tests\PowerShell\target-literal-boundary.tests.ps1')) 'Generic target literal boundary regression test must exist.'

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output "REFACTORING_COMPLETION=PASS owners=$($owners.Count) assertions=$assertions"
