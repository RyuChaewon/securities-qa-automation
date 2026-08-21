<# .SYNOPSIS Regression tests for the thin rule-suite entrypoint and orchestration handoff. #>
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERT_TRUE failed: $Message"};$script:assertions++}
function Assert-Equal($Expected,$Actual,[string]$Message){if([string]$Expected-ne[string]$Actual){throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'"};$script:assertions++}
function Get-ScriptAst([string]$Path){$tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Path),[ref]$tokens,[ref]$errors);if($errors){throw ($errors|ForEach-Object Message|Out-String)};$ast}

$script:assertions=0
$entryPath=Join-Path $root 'scripts\run-target-rule-suite.ps1'
$orchestrationPath=Join-Path $root 'scripts\modules\hts-rule-suite-orchestration.ps1'
$entryAst=Get-ScriptAst $entryPath
$orchestrationAst=Get-ScriptAst $orchestrationPath
$entryParams=@($entryAst.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})
$orchestrationParams=@($orchestrationAst.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})
Assert-Equal ($orchestrationParams -join '|') ($entryParams -join '|') 'thin entrypoint preserves every orchestration parameter name and order'
Assert-Equal $orchestrationAst.ParamBlock.Extent.Text $entryAst.ParamBlock.Extent.Text 'validation attributes and parameter defaults remain byte-for-byte equivalent'

$entryFunctions=@($entryAst.FindAll({param($node)$node-is[System.Management.Automation.Language.FunctionDefinitionAst]},$true))
Assert-Equal 0 $entryFunctions.Count 'thin entrypoint defines no operational functions'
$entryLines=@(Get-Content -LiteralPath $entryPath)
Assert-True ($entryLines.Count-le40) 'thin entrypoint stays limited to arguments and orchestration handoff'
$entryText=$entryLines-join"`n"
Assert-True ($entryText-match'hts-rule-suite-orchestration\.ps1') 'entrypoint delegates to the dedicated orchestration file'
Assert-True ($entryText-match'@PSBoundParameters') 'entrypoint forwards only the public bound parameter contract'

$orchestrationText=Get-Content -LiteralPath $orchestrationPath -Raw
$orchestrationFunctions=@($orchestrationAst.FindAll({param($node)$node-is[System.Management.Automation.Language.FunctionDefinitionAst]},$true))
Assert-Equal 0 $orchestrationFunctions.Count 'orchestration defines no responsibility implementation functions'
$validationIndex=$orchestrationText.IndexOf('validate-test-pack',[StringComparison]::Ordinal)
$sessionIndex=$orchestrationText.IndexOf('Start-FlaUiBridge',[StringComparison]::Ordinal)
Assert-True ($validationIndex-ge0) 'orchestration retains approved TestPack validation'
Assert-True ($sessionIndex-gt$validationIndex) 'TestPack validation remains before any FlaUI session start'
foreach($module in @('hts-native.ps1','hts-session.ps1','hts-navigation.ps1','hts-discovery.ps1','hts-binding.ps1','hts-action.ps1','hts-observation.ps1','hts-safety.ps1','hts-reporting.ps1','hts-runtime-context.ps1')){
    Assert-True ($orchestrationText.Contains($module)) "orchestration composes $module"
}

Write-Output "HTS_ORCHESTRATION_ENTRYPOINT_TESTS=PASS assertions=$script:assertions"
