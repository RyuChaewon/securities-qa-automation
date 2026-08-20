<#
.SYNOPSIS Verifies that C# dry-run and the PowerShell Runner consume the same Approved TestPack cases.
.DESCRIPTION Uses no external test module and checks pending rejection, approval, golden CaseIds, and duplicate removal.
.OUTPUTS Prints TEST_PACK_RUNNER_TESTS=PASS and the assertion count when every check passes.
#>
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cliProject = Join-Path $root 'src\HtsQa.Cli\HtsQa.Cli.csproj'
$runner = Join-Path $root 'scripts\run-target-rule-suite.ps1'
$dataset = Join-Path $root 'data\rule-tests\1q-hts-non07-static-smoke.dataset.json'
$tempRoot = Join-Path (Join-Path $root 'artifacts') ('test-pack-regression-' + [guid]::NewGuid().ToString('N'))
$script:assertions = 0

function Assert-True([bool]$Actual, [string]$Message) {
    $script:assertions++
    if (-not $Actual) { throw $Message }
}

function Assert-Equal([object]$Expected, [object]$Actual, [string]$Message) {
    $script:assertions++
    if ($Expected -ne $Actual) { throw "$Message expected=[$Expected] actual=[$Actual]" }
}

function Invoke-Cli([string[]]$Arguments) {
    & dotnet run --project $cliProject -c Release --no-build -- @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "CLI failed: $($Arguments -join ' ') / $LASTEXITCODE" }
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $pendingPath = Join-Path $tempRoot 'pending-test-pack.json'
    $approvalPath = Join-Path $tempRoot 'approval.json'
    $approvedPath = Join-Path $tempRoot 'approved-test-pack.json'
    $cliDryRun = Join-Path $tempRoot 'cli-dry-run'
    $runnerDryRun = Join-Path $tempRoot 'runner-dry-run'

    Invoke-Cli @('compile-test-pack', '--dataset', $dataset, '--combination-policy', 'Cartesian', '--max-cases', '1000', '--out', $pendingPath)
    $pending = Get-Content -LiteralPath $pendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'PendingApproval' ([string]$pending.approval.status) 'Pending TestPack status'

    [pscustomobject]@{
        schemaVersion = '1.0'
        testPackContentHash = [string]$pending.contentHash
        status = 'Approved'
        approvedBy = 'powershell-regression-test'
        approvedAt = '2026-08-20T00:00:00+09:00'
        evidenceRefs = @('tests/PowerShell/test-pack-runner.tests.ps1')
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $approvalPath -Encoding UTF8

    Invoke-Cli @('compile-test-pack', '--dataset', $dataset, '--combination-policy', 'Cartesian', '--max-cases', '1000', '--approval', $approvalPath, '--out', $approvedPath)
    Invoke-Cli @('validate-test-pack', '--file', $approvedPath, '--dataset', $dataset)
    $approved = Get-Content -LiteralPath $approvedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'Approved' ([string]$approved.approval.status) 'Approved TestPack status'
    Assert-Equal ([int]$approved.caseCount) @($approved.cases).Count 'TestPack caseCount'

    $pendingLog = Join-Path $tempRoot 'pending-rejection.log'
    $pendingErrorLog = Join-Path $tempRoot 'pending-rejection-error.log'
    $pendingProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner,
        '-TestPackPath', $pendingPath, '-ReportDir', (Join-Path $tempRoot 'pending-rejected'), '-DryRun', '-SkipExcel'
    ) -RedirectStandardOutput $pendingLog -RedirectStandardError $pendingErrorLog -WindowStyle Hidden -Wait -PassThru
    Assert-True ($pendingProcess.ExitCode -ne 0) 'Runner must reject a pending TestPack.'

    Invoke-Cli @('run-test-pack', '--file', $approvedPath, '--dry-run', '--report-dir', $cliDryRun)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -TestPackPath $approvedPath -ReportDir $runnerDryRun -DryRun -SkipExcel | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Approved TestPack Runner dry-run failed: $LASTEXITCODE" }

    $cliCases = @(Get-Content -LiteralPath (Join-Path $cliDryRun 'expanded-cases.json') -Raw -Encoding UTF8 | ConvertFrom-Json).cases
    $runnerCases = @(Get-Content -LiteralPath (Join-Path $runnerDryRun 'expanded-cases.json') -Raw -Encoding UTF8 | ConvertFrom-Json).cases
    Assert-Equal (@($cliCases).Count) (@($runnerCases).Count) 'C# dry-run and Runner case count'
    Assert-Equal ((@($cliCases.caseId) -join ',')) ((@($runnerCases.caseId) -join ',')) 'C# dry-run and Runner CaseId order'
    Assert-True (@($runnerCases).Count -gt 0) 'Runner dry-run cases exist'

    $summary = Get-Content -LiteralPath (Join-Path $runnerDryRun 'summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'PENDING' ([string]$summary.status) 'Unexecuted dry-run status'
    Assert-Equal 0 ([int]$summary.flaUiActionAttempts) 'Dry-run FlaUI action attempts'
    Assert-Equal ([string]$approved.testPackId) ([string]$summary.testPackId) 'Summary TestPack trace'

    $runnerSource = Get-Content -LiteralPath $runner -Raw -Encoding UTF8
    Assert-True (-not $runnerSource.Contains('function Get-VariableCombinations')) 'PowerShell combination generator removed'
    Assert-True (-not $runnerSource.Contains('function Get-RuleCases')) 'PowerShell Dataset case generator removed'
    Assert-True ($runnerSource.Contains('[string]$TestPackPath')) 'Runner TestPackPath contract'
    Assert-True (-not $runnerSource.Contains('[string]$DatasetPath')) 'Runner DatasetPath input removed'

    "TEST_PACK_RUNNER_TESTS=PASS assertions=$script:assertions"
}
finally {
    $artifactsRoot = [IO.Path]::GetFullPath((Join-Path $root 'artifacts')).TrimEnd('\') + '\'
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTemp.StartsWith($artifactsRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
