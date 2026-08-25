$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$baseline = Get-Content -LiteralPath (Join-Path $root 'targets\1q-hts\0101\screen-contract-baseline.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$scenario = Get-Content -LiteralPath (Join-Path $root 'targets\1q-hts\0101\screen-contract-smoke.scenario.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$scriptText = Get-Content -LiteralPath (Join-Path $root 'targets\1q-hts\0101\scripts\run-screen-contract-smoke.ps1') -Raw -Encoding UTF8
if ($scenario.cases.Count -ne 5) { throw 'Screen Contract Smoke must define exactly five cases.' }
if ($scenario.cases.checkpointId.Count -ne 5) { throw 'Each case must define a required checkpoint.' }
if ($scenario.physicalActionCount -ne 0 -or $scenario.transactionalActionCount -ne 0) { throw 'Screen contract must have zero physical and transactional actions.' }
if ($baseline.approvalStatus -ne 'UserApprovedForSmoke' -or $baseline.permanentLocatorApproval -or $baseline.businessRuleApproval) { throw 'Baseline approval semantics are invalid.' }
if ($baseline.ranges.totalNativeElements.min -lt 50 -or $baseline.ranges.totalNativeElements.max -gt 120) { throw 'Baseline total range is unsafe.' }
if ($scriptText -match 'Invoke-HtsAction|SendInput|Set-AutomationText|type_text|pressKey|captureCandidate') { throw 'Screen contract runner must remain read-only.' }
if ($scriptText -notmatch 'observeState' -or $scriptText -notmatch 'discoverLayout' -or $scriptText -notmatch 'evaluate-results') { throw 'Screen contract runner must re-observe and delegate to ResultEvaluator.' }
Write-Host 'SCREEN_CONTRACT_SMOKE_CONTRACT=PASS cases=5 actions=0 transactional=0'

