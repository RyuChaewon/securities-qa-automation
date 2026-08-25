<#
.SYNOPSIS
  Produces redacted 0101 Pilot binding-discovery evidence without executing UI actions.
.DESCRIPTION
  Reuses the existing compiled/physical plan artifacts. It never changes dispositions,
  invokes the target runner, sends input, or creates TestResult verdicts.
#>
param(
  [string]$PhysicalPlanPath = 'artifacts/pending-resolution-20260822/current-binding/physical-plan.json',
  [string]$OutputDirectory = 'artifacts/local/binding-discovery/0101'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$planPath = if ([IO.Path]::IsPathRooted($PhysicalPlanPath)) { $PhysicalPlanPath } else { Join-Path $root $PhysicalPlanPath }
$out = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $root $OutputDirectory }
if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { throw "Physical plan not found: $planPath" }
New-Item -ItemType Directory -Force -Path $out | Out-Null
$plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pilot = @('TC-0101-CTL-0018','TC-0101-CTL-0040','TC-0101-CTL-0047','TC-0101-CTL-0048')
$rows = foreach ($id in $pilot) {
  $d = @($plan.scenarioDispositions | Where-Object { [string]$_.scenarioId -eq $id }) | Select-Object -First 1
  [ordered]@{ caseId=$id; status=if($d){[string]$d.status}else{'REVIEW_REQUIRED'}; reasonCodes=if($d){@($d.reasons)}else{@('CASE_NOT_PRESENT_IN_PHYSICAL_PLAN')}; autoExecutable=($plan.executableCaseIds -contains $id) }
}
$candidates = [ordered]@{ schemaVersion='1.0'; kind='BindingDiscovery'; humanObserved=$false; approvalStatus='REVIEW_REQUIRED'; uiActionCount=0; transactionalActionCount=0; candidates=@(); requiredEvidence=@('nativeHwnd','class','parentChild','bounds','normalizedBounds','mapHostOrContainer','runtimeIdentity','stateFingerprint') }
$summary = [ordered]@{ schemaVersion='1.0'; kind='BindingDiscovery'; generatedAt=[DateTimeOffset]::Now; sourcePhysicalPlan=[IO.Path]::GetFullPath($planPath); pilotCases=$rows; autoExecutableCaseCount=@($rows | Where-Object autoExecutable).Count; humanObservationRequired=@('buy tab/button','sell tab/button','modify/cancel tab/button','cancel tab/button','quote price selection','order-condition controls','arrival checkpoints'); approvedLocatorCount=0; uiActionCount=0; transactionalActionCount=0; verdictEligible=$false; note='Discovery evidence only; no TestResult or canonical verdict.' }
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $out 'binding-discovery-summary.json') -Encoding UTF8
$candidates | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $out 'control-repository-candidates.json') -Encoding UTF8
$rows | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $out 'pilot-binding-reasons.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 12
