<#
.SYNOPSIS Characterizes the public HtsQa.Cli routing and process protocol.
.DESCRIPTION Verifies command registration, help, error, path, and JSON contracts without starting HTS or FlaUI.
.OUTPUTS Prints CLI_COMMAND_ROUTING_TESTS=PASS and the assertion count when every check passes.
#>
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cliProject = Join-Path $root 'src\HtsQa.Cli\HtsQa.Cli.csproj'
$cliDll = Join-Path $root 'src\HtsQa.Cli\bin\Release\net8.0-windows\HtsQa.Cli.dll'
$datasetRelative = 'data/rule-tests/1q-hts-non07-static-smoke.dataset.json'
$datasetAbsolute = Join-Path $root ($datasetRelative -replace '/', '\')
$script:assertions = 0

$expectedCommands = @(
    'help',
    'validate-rule-dataset', 'expand-rule-cases', 'run-rule-dataset',
    'compile-test-pack', 'create-test-pack-approval', 'validate-test-pack', 'run-test-pack',
    'extract-map-models',
    'generate-rule-scenarios', 'create-rule-scenario-approval', 'validate-generated-scenarios',
    'import-generated-scenarios', 'create-scenario-approval', 'compile-scenarios', 'plan-scenarios',
    'validate-control-repository', 'create-control-repository-approval', 'apply-control-repository-approval',
    'create-control-repository-review', 'resolve-control-repository',
    'create-execution-authorization-approval', 'apply-execution-authorization-approval', 'check-execution-authorization',
    'create-calibration-session', 'validate-calibration-session', 'create-calibration-review',
    'register-control-repository-entry', 'finalize-calibration-session',
    'validate-order-scenario', 'compile-order-scenario', 'dry-run-order-scenario',
    'materialize-scenario-bindings', 'build-physical-scenario-plan',
    'evaluate-results', 'analyze-run'
)

$expectedHelpCommands = @(
    'validate-rule-dataset', 'expand-rule-cases',
    'compile-test-pack', 'create-test-pack-approval', 'validate-test-pack', 'run-test-pack', 'run-rule-dataset',
    'extract-map-models',
    'generate-rule-scenarios', 'create-rule-scenario-approval', 'validate-generated-scenarios',
    'import-generated-scenarios', 'create-scenario-approval', 'compile-scenarios', 'plan-scenarios',
    'materialize-scenario-bindings', 'create-control-repository-approval', 'apply-control-repository-approval',
    'validate-control-repository', 'create-control-repository-review', 'resolve-control-repository',
    'create-calibration-session', 'validate-calibration-session',
    'create-execution-authorization-approval', 'apply-execution-authorization-approval', 'check-execution-authorization', 'create-calibration-review',
    'register-control-repository-entry', 'finalize-calibration-session', 'validate-order-scenario',
    'compile-order-scenario', 'dry-run-order-scenario', 'build-physical-scenario-plan', 'evaluate-results', 'analyze-run'
)

$expectedHandlers = [ordered]@{
    'validate-rule-dataset' = 'DatasetCommands'
    'expand-rule-cases' = 'DatasetCommands'
    'run-rule-dataset' = 'DatasetCommands'
    'compile-test-pack' = 'TestPackCommands'
    'create-test-pack-approval' = 'TestPackCommands'
    'validate-test-pack' = 'TestPackCommands'
    'run-test-pack' = 'TestPackCommands'
    'extract-map-models' = 'MapCommands'
    'generate-rule-scenarios' = 'ScenarioCommands'
    'create-rule-scenario-approval' = 'ScenarioCommands'
    'validate-generated-scenarios' = 'ScenarioCommands'
    'import-generated-scenarios' = 'ScenarioCommands'
    'create-scenario-approval' = 'ScenarioCommands'
    'compile-scenarios' = 'ScenarioCommands'
    'plan-scenarios' = 'ScenarioCommands'
    'materialize-scenario-bindings' = 'ScenarioCommands'
    'build-physical-scenario-plan' = 'ScenarioCommands'
    'validate-control-repository' = 'ControlRepositoryCommands'
    'create-control-repository-approval' = 'ControlRepositoryCommands'
    'apply-control-repository-approval' = 'ControlRepositoryCommands'
    'create-control-repository-review' = 'ControlRepositoryCommands'
    'resolve-control-repository' = 'ControlRepositoryCommands'
    'create-calibration-session' = 'CalibrationCommands'
    'validate-calibration-session' = 'CalibrationCommands'
    'create-execution-authorization-approval' = 'AuthorizationCommands'
    'apply-execution-authorization-approval' = 'AuthorizationCommands'
    'check-execution-authorization' = 'AuthorizationCommands'
    'create-calibration-review' = 'CalibrationCommands'
    'register-control-repository-entry' = 'CalibrationCommands'
    'finalize-calibration-session' = 'CalibrationCommands'
    'validate-order-scenario' = 'OrderScenarioCommands'
    'compile-order-scenario' = 'OrderScenarioCommands'
    'dry-run-order-scenario' = 'OrderScenarioCommands'
    'evaluate-results' = 'EvaluationCommands'
    'analyze-run' = 'RunAnalysisCommands'
}

function Assert-True([bool]$Actual, [string]$Message) {
    $script:assertions++
    if (-not $Actual) { throw $Message }
}

function Assert-Equal([object]$Expected, [object]$Actual, [string]$Message) {
    $script:assertions++
    if ($Expected -cne $Actual) { throw "$Message expected=[$Expected] actual=[$Actual]" }
}

function Invoke-CliProcess([string[]]$Arguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'dotnet'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = $root
    [void]$startInfo.ArgumentList.Add($cliDll)
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

& dotnet build $cliProject -c Release --no-restore | Out-Null
if ($LASTEXITCODE -ne 0) { throw "HtsQa.Cli Release build failed: exit=$LASTEXITCODE" }

$routerPath = Join-Path $root 'src\HtsQa.Cli\CliApplication.cs'
if (-not (Test-Path -LiteralPath $routerPath -PathType Leaf)) {
    $routerPath = Join-Path $root 'src\HtsQa.Cli\Program.cs'
}
$routerText = Get-Content -LiteralPath $routerPath -Raw -Encoding UTF8
$registered = @([regex]::Matches($routerText, '"([a-z][a-z0-9-]+)"\s*=>') | ForEach-Object { $_.Groups[1].Value })
Assert-Equal ($expectedCommands -join '|') ($registered -join '|') 'Command registration and order'
Assert-Equal $registered.Count (@($registered | Sort-Object -Unique).Count) 'Duplicate command registration'

$help = Invoke-CliProcess @('help')
Assert-Equal 0 $help.ExitCode 'help exit code'
Assert-Equal '' $help.StdErr 'help stderr'
$helpHashBytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($help.StdOut))
$helpHash = ([BitConverter]::ToString($helpHashBytes)).Replace('-', '').ToLowerInvariant()
Assert-Equal 'aa8a2048e7e245af5645be2572443bd016a49b13bc97700c7966dfdbc73e5b27' $helpHash 'help stdout bytes'
$helpCommands = @([regex]::Matches($help.StdOut, '(?m)^  ([a-z][a-z0-9-]+)(?:\s|$)') | ForEach-Object { $_.Groups[1].Value })
Assert-Equal ($expectedHelpCommands -join '|') ($helpCommands -join '|') 'Help command list and order'

$unknown = Invoke-CliProcess @('does-not-exist')
Assert-Equal 1 $unknown.ExitCode 'unknown command exit code'
Assert-Equal '' $unknown.StdOut 'unknown command stdout'
Assert-Equal "알 수 없는 명령: does-not-exist`r`n" $unknown.StdErr 'unknown command stderr'

$missing = Invoke-CliProcess @('validate-rule-dataset')
Assert-Equal 2 $missing.ExitCode 'required option exit code'
Assert-Equal '' $missing.StdOut 'required option stdout'
Assert-Equal "오류: --file이 필요합니다.`r`n" $missing.StdErr 'required option stderr'

$relative = Invoke-CliProcess @('validate-rule-dataset', '--file', $datasetRelative)
$absolute = Invoke-CliProcess @('validate-rule-dataset', '--file', $datasetAbsolute)
Assert-Equal 0 $relative.ExitCode 'relative path exit code'
Assert-Equal 0 $absolute.ExitCode 'absolute path exit code'
Assert-Equal '' $relative.StdErr 'relative path stderr'
Assert-Equal '' $absolute.StdErr 'absolute path stderr'
$relativeJson = $relative.StdOut | ConvertFrom-Json
$absoluteJson = $absolute.StdOut | ConvertFrom-Json
Assert-Equal $true ([bool]$relativeJson.isValid) 'relative path validation result'
Assert-Equal $true ([bool]$absoluteJson.isValid) 'absolute path validation result'
Assert-Equal ([string]$relativeJson.combinationPolicy) ([string]$absoluteJson.combinationPolicy) 'relative and absolute path policy'
Assert-Equal ([int]$relativeJson.projectedCases) ([int]$absoluteJson.projectedCases) 'relative and absolute path case count'

$splitRouter = Join-Path $root 'src\HtsQa.Cli\CliApplication.cs'
if (Test-Path -LiteralPath $splitRouter -PathType Leaf) {
    foreach ($entry in $expectedHandlers.GetEnumerator()) {
        $pattern = '"{0}"\s*=>\s*{1}\.' -f [regex]::Escape([string]$entry.Key), [regex]::Escape([string]$entry.Value)
        Assert-True ([regex]::IsMatch($routerText, $pattern)) "Command routed to wrong handler: $($entry.Key)"
    }
}

Write-Output "CLI_COMMAND_ROUTING_TESTS=PASS assertions=$script:assertions"
