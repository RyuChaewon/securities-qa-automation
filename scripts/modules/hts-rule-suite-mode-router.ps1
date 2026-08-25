<#
.SYNOPSIS DryRun, PlanOnly, and Execute lifecycle routing.
.DESCRIPTION Selects a coordinator only; detailed UI actions and verdict calculation remain delegated.
#>

# Returns the single execution mode selected by the public switch contract.
function Get-HtsRuleSuiteExecutionMode {
    param([Parameter(Mandatory = $true)]$RunSpec)
    if ($RunSpec.Input.DryRun) { return 'DryRun' }
    if ($RunSpec.Input.PlanOnly) { return 'PlanOnly' }
    'Execute'
}

# Invokes only the coordinator and deferred runtime initializer allowed for the selected mode.
function Invoke-HtsRuleSuiteMode {
    param(
        [Parameter(Mandatory = $true)]$RunSpec,
        [Parameter(Mandatory = $true)]$RunServices,
        [Parameter(Mandatory = $true)]$RunState,
        [Parameter(Mandatory = $true)][scriptblock]$DryRunCoordinator,
        [Parameter(Mandatory = $true)][scriptblock]$InitializeRuntime,
        [Parameter(Mandatory = $true)][scriptblock]$PlanOnlyCoordinator,
        [Parameter(Mandatory = $true)][scriptblock]$ExecuteCoordinator
    )

    $mode = Get-HtsRuleSuiteExecutionMode $RunSpec
    $RunState.Mode = $mode
    switch ($mode) {
        'DryRun' { & $DryRunCoordinator $RunSpec $RunServices $RunState; break }
        'PlanOnly' { & $InitializeRuntime $RunSpec $RunServices $RunState; & $PlanOnlyCoordinator $RunSpec $RunServices $RunState; break }
        'Execute' { & $InitializeRuntime $RunSpec $RunServices $RunState; & $ExecuteCoordinator $RunSpec $RunServices $RunState; break }
        default { throw "지원하지 않는 rule suite 실행 모드입니다: $mode" }
    }
}

# Runs the existing offline TestPack dry-run and enriches its non-UI summary.
function Invoke-HtsRuleSuiteDryRun {
    param(
        [Parameter(Mandatory = $true)]$RunSpec,
        [Parameter(Mandatory = $true)]$RunServices,
        [Parameter(Mandatory = $true)]$RunState
    )

    & dotnet run --project $RunSpec.CliProject -c Release --no-build -- run-test-pack --file $RunSpec.ResolvedTestPackPath --dry-run --report-dir $RunSpec.ReportDir | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '룰 드라이런에 실패했습니다.' }
    $drySummaryPath = Join-Path $RunSpec.ReportDir 'summary.json'
    $mapCatalog = $RunSpec.MapCatalog
    if (Test-Path -LiteralPath $drySummaryPath) {
        $drySummary = Get-Content -LiteralPath $drySummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $drySummary | Add-Member -NotePropertyName targetProfileId -NotePropertyValue $RunSpec.TargetContext.ProfileId -Force
        $drySummary | Add-Member -NotePropertyName targetDisplayName -NotePropertyValue $RunSpec.TargetContext.DisplayName -Force
        $drySummary | Add-Member -NotePropertyName datasetPath -NotePropertyValue ([string]$RunSpec.TestPack.datasetSource) -Force
        $drySummary | Add-Member -NotePropertyName testPackPath -NotePropertyValue $RunSpec.ResolvedTestPackPath -Force
        $mapDefinedCount = if ($mapCatalog) { ($mapCatalog.screens | Measure-Object actionableControlCount -Sum).Sum } else { 0 }
        foreach ($pair in @{
            automationEngine = 'FlaUI.UIA3'; automationEngineVersion = '5.0.0'; automationExecution = '드라이런이므로 UIA3 조작 미실행'
            flaUiDiscoveryCalls = 0; flaUiElementsDiscovered = 0; flaUiActionAttempts = 0; flaUiActionSuccesses = 0; flaUiFallbackRequests = 0; flaUiFallbackReasons = @()
            mapModels = $(if ($mapCatalog) { @($mapCatalog.screens).Count } else { 0 }); mapDefinedControls = $mapDefinedCount; mapBoundControls = 0
            mapUnboundControls = 0; runtimeOnlyControls = 0; mapInitializationIssue = $(if ($RunSpec.MapInitializationIssue) { $RunSpec.MapInitializationIssue } elseif ($mapCatalog) { '드라이런이므로 실시간 MAP 결합은 실행하지 않았습니다.' } else { '' })
            mapOracleScreens = $(if ($mapCatalog) { @($mapCatalog.screens | Where-Object errorOracle).Count } else { 0 })
            mapOracleMessages = $(if ($mapCatalog) { @($mapCatalog.screens | ForEach-Object { @($_.errorOracle.messageBoxes).Count } | Measure-Object -Sum).Sum } else { 0 })
            mapOracleExplicitErrors = $(if ($mapCatalog) { @($mapCatalog.screens | ForEach-Object { @($_.errorOracle.messageBoxes | Where-Object isExplicitError).Count } | Measure-Object -Sum).Sum } else { 0 })
            mapOracleValidationMessages = $(if ($mapCatalog) { @($mapCatalog.screens | ForEach-Object { @($_.errorOracle.messageBoxes | Where-Object classification -eq 'InputValidation').Count } | Measure-Object -Sum).Sum } else { 0 })
            mapBehaviorHandlers = $(if ($mapCatalog) { @($mapCatalog.screens | ForEach-Object { @($_.behavior.eventHandlers).Count } | Measure-Object -Sum).Sum } else { 0 })
            mapQueryControls = $(if ($mapCatalog) { @($mapCatalog.screens | ForEach-Object { @($_.behavior.queryControls).Count } | Measure-Object -Sum).Sum } else { 0 })
            mapStateControllers = $(if ($mapCatalog) { @($mapCatalog.screens | ForEach-Object { @($_.behavior.stateControllerControls).Count } | Measure-Object -Sum).Sum } else { 0 })
            mapResultControls = $(if ($mapCatalog) { @($mapCatalog.screens | ForEach-Object { @($_.behavior.resultControls).Count } | Measure-Object -Sum).Sum } else { 0 })
            mapReboundControls = 0; expectedEvents = 0; reviewEvents = 0; productDefects = 0
            installationFingerprint = $(if ($mapCatalog) { [string]$mapCatalog.installationFingerprint } else { '' })
            dependencyModels = $(if ($mapCatalog) { @($mapCatalog.dependencyScreens).Count } else { 0 })
            mapDependencies = $(if ($mapCatalog) { @($mapCatalog.dependencies).Count } else { 0 })
            unresolvedDependencies = $(if ($mapCatalog) { @($mapCatalog.dependencies | Where-Object { -not $_.isDynamic -and -not $_.targetExists }).Count } else { 0 })
            staticDataReferences = $(if ($mapCatalog) { @($mapCatalog.screens | ForEach-Object { @($_.dataReferences).Count } | Measure-Object -Sum).Sum } else { 0 })
            officialOptionControls = $(if ($mapCatalog) { @($mapCatalog.screens | ForEach-Object { @($_.controls | Where-Object { @($_.staticOptions).Count -gt 0 }).Count } | Measure-Object -Sum).Sum } else { 0 })
            installedErrorCodes = $(if ($mapCatalog) { @($mapCatalog.errorCodes).Count } else { 0 })
            integrityMatched = $(if ($mapCatalog) { @($mapCatalog.integrityEntries | Where-Object status -eq 'MATCH').Count } else { 0 })
            integrityFailed = $(if ($mapCatalog) { @($mapCatalog.integrityEntries | Where-Object status -ne 'MATCH').Count } else { 0 })
        }.GetEnumerator()) { $drySummary | Add-Member -NotePropertyName $pair.Key -NotePropertyValue $pair.Value -Force }
        $drySummary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $drySummaryPath -Encoding UTF8
    }
    $RunState.UiActionCount = 0
    $RunState.TransactionalActionCount = 0
    $RunState.OutputReady = $true
    $RunState.OutputPath = $RunSpec.ReportDir
}
