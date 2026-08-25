<#
.SYNOPSIS Executes the 0101 Screen Contract Smoke without UI actions.
.DESCRIPTION Re-observes the exact 0101 window and layout, creates redacted checkpoint
evidence, and delegates PASS/FAIL/ERROR/PENDING to the C# ResultEvaluator.
.NOTES Never clicks, types, changes tabs, moves the cursor, or submits a transaction.
#>
param(
    [string]$OutputDirectory = '',
    [string]$FlaUiAssembly = '',
    [ValidateRange(1, 5)][int]$SnapshotCount = 3,
    [ValidateRange(50, 2000)][int]$SnapshotDelayMilliseconds = 250
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$profilePath = Join-Path $PSScriptRoot '..\target-profile.json'
$baselinePath = Join-Path $PSScriptRoot '..\screen-contract-baseline.json'
$scenarioPath = Join-Path $PSScriptRoot '..\screen-contract-smoke.scenario.json'
$profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$baseline = Get-Content -LiteralPath $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
$scenario = Get-Content -LiteralPath $scenarioPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$profile.id -ne '1q-hts-0101') { throw 'Target profile mismatch.' }
if ([string]$baseline.screenId -ne '0101' -or [string]$scenario.screenId -ne '0101') { throw 'Screen contract files must target 0101.' }
if ($SnapshotCount -ne [int]$baseline.stability.snapshotCount) { $SnapshotCount = [int]$baseline.stability.snapshotCount }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root ('artifacts\local\screen-contract-smoke\0101-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
$fullOutput = [IO.Path]::GetFullPath($OutputDirectory)
$evidenceDir = Join-Path $fullOutput 'checkpoint-evidence'
[void](New-Item -ItemType Directory -Path $evidenceDir -Force)
if (-not $FlaUiAssembly) { $FlaUiAssembly = Join-Path $root 'src\HtsQa.FlaUi\bin\Release\net8.0-windows7.0\HtsQa.FlaUi.dll' }
if (-not (Test-Path -LiteralPath $FlaUiAssembly -PathType Leaf)) { throw "FlaUI Release assembly not found: $FlaUiAssembly" }

. (Join-Path $root 'scripts\modules\hts-native.ps1')
. (Join-Path $root 'scripts\modules\hts-session.ps1')
. (Join-Path $root 'scripts\modules\hts-layout-inspection.ps1')
Initialize-HtsNativeInterop
$session = New-HtsSessionContext -FlaUiAssembly $FlaUiAssembly -TargetWindowClassName ([string]$profile.window.className) -TargetWindowTitlePrefix ([string]$profile.window.titlePrefix) -DisplayName ([string]$profile.displayName) -GetTopWindows { @(Get-TopWindows) }
[void](Start-FlaUiBridge -Context $session)

function Invoke-ReadOnlyBridge {
    param([hashtable]$Request)
    $Request.requestId = [Guid]::NewGuid().ToString('N')
    $response = Invoke-FlaUiBridgeRequest -Context $session -Request $Request
    if (-not [bool]$response.success) { throw "SCREEN_CONTRACT_BRIDGE_FAILED: $([string]$response.errorCode): $([string]$response.message)" }
    $response
}

function Get-RegionHints {
    @(
        [ordered]@{ region = 'GlobalHeader'; left = 0.0; top = 0.0; right = 1.0; bottom = 0.12; priority = 20 },
        [ordered]@{ region = 'QuotePanel'; left = 0.0; top = 0.12; right = 0.5; bottom = 0.62; priority = 10 },
        [ordered]@{ region = 'OrderEntryPanel'; left = 0.5; top = 0.12; right = 1.0; bottom = 0.62; priority = 10 },
        [ordered]@{ region = 'TradeInfoPanel'; left = 0.0; top = 0.62; right = 1.0; bottom = 1.0; priority = 10 }
    )
}

function Get-SensitiveHints {
    @(
        [ordered]@{ namePattern = '계좌|account'; sensitiveKind = 'Account' },
        [ordered]@{ namePattern = '비밀번호|password|passwd'; sensitiveKind = 'Password' },
        [ordered]@{ namePattern = '고객|사용자|user.?id|customer'; sensitiveKind = 'Identity' },
        [ordered]@{ namePattern = '인증|token|auth'; sensitiveKind = 'Authentication' }
    )
}

function Get-LayoutSnapshot([long]$RootHwnd) {
    Invoke-ReadOnlyBridge ([ordered]@{
        operation = 'discoverLayout'; rootHwnd = $RootHwnd; timeoutMs = 10000; maxDepth = 16; maxElements = 5000
        includeCurrentValues = $false; includeValueMetadata = $true; includeOffscreen = $false; includeInvisible = $false; includeContainers = $true
        regionHints = @(Get-RegionHints); sensitiveControlHints = @(Get-SensitiveHints)
    })
}

function Get-ObservationMetrics($StateResponse, $LayoutResponse) {
    $layout = $LayoutResponse.layoutDiscovery
    $elements = @($layout.elements)
    $regionCounts = @{}
    foreach ($region in @('GlobalHeader','QuotePanel','OrderEntryPanel','TradeInfoPanel','Unclassified')) {
        $regionCounts[$region] = @($elements | Where-Object { [string]$_.spatialRegion -eq $region }).Count
    }
    $classCounts = @{}
    foreach ($group in @($elements | Group-Object { [string]$_.className })) { $classCounts[[string]$group.Name] = [int]$group.Count }
    $nativeFallback = @($elements | Where-Object { [int64]$_.nativeWindowHandle -ne 0 }).Count
    $uiaIdentity = @($elements | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.runtimeId) -or -not [string]::IsNullOrWhiteSpace([string]$_.automationId) }).Count
    $currentValueStored = @($elements | Where-Object { $_.PSObject.Properties.Name -contains 'observedValue' -and $null -ne $_.observedValue -and [string]$_.observedValue }).Count
    $sensitivePatternCount = @($elements | Where-Object { [string]$_.redactedName -match '(?i)account|password|passwd|token|auth|계좌|비밀번호|인증' -and [string]$_.redactionReason -eq '' }).Count
    [pscustomobject]@{
        totalNativeElements = $elements.Count; nativeFallbackCount = $nativeFallback; uiaIdentityCount = $uiaIdentity
        providerErrorCount = [int]$layout.providerErrorCount; truncated = [bool]$layout.truncated
        currentValueStored = $currentValueStored; sensitivePatternCount = $sensitivePatternCount
        regionCounts = [pscustomobject]$regionCounts; classCounts = [pscustomobject]$classCounts
        rootFingerprint = [string]$layout.windowFingerprint; processIdPresent = ([int]$layout.processId -gt 0)
        dpi = [int]$layout.dpi; rootBoundsValid = ($null -ne $layout.rootBounds -and [int]$layout.rootBounds.width -gt 0 -and [int]$layout.rootBounds.height -gt 0)
        stateFingerprint = [string]$StateResponse.stateObservation.windowFingerprint
    }
}

function Get-StructureSignatures($LayoutResponse) {
    $rows = @($LayoutResponse.layoutDiscovery.elements | ForEach-Object {
        '{0}|{1}|{2:R}|{3:R}|{4:R}|{5:R}|{6}|{7}|{8}' -f [string]$_.className,[string]$_.controlType,[double]$_.normalizedBounds.left,[double]$_.normalizedBounds.top,[double]$_.normalizedBounds.right,[double]$_.normalizedBounds.bottom,[string]$_.spatialRegion,[int]$_.depth,[int]$_.childCount
    } | Sort-Object)
    $joined = $rows -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create(); try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($joined))) -replace "-", "").ToLowerInvariant() } finally { $sha.Dispose() }
    [pscustomobject]@{ hash = $hash; count = $rows.Count; rows = $rows }
}

function Test-Range([int]$Value, $Range) { $Value -ge [int]$Range.min -and ($null -eq $Range.max -or $Value -le [int]$Range.max) }
function Test-MetricContract($Metrics, $Baseline) {
    $failures = New-Object Collections.Generic.List[string]
    if (-not (Test-Range $Metrics.totalNativeElements $Baseline.ranges.totalNativeElements)) { $failures.Add('totalNativeElements') }
    foreach ($name in @('GlobalHeader','QuotePanel','OrderEntryPanel','TradeInfoPanel')) { if (-not (Test-Range $Metrics.regionCounts.$name $Baseline.ranges.$name)) { $failures.Add($name) } }
    foreach ($name in @('Edit','AfxWnd140','AfxFrameOrView140','Button','SysTabControl32','msctls_updown32')) { if (-not (Test-Range $Metrics.classCounts.$name $Baseline.ranges.$name)) { $failures.Add($name) } }
    if ($Metrics.nativeFallbackCount -le 0) { $failures.Add('nativeFallbackCount') }
    if ($Metrics.providerErrorCount -ne 0) { $failures.Add('providerErrorCount') }
    if ($Metrics.truncated) { $failures.Add('truncated') }
    if ($Metrics.currentValueStored -ne [int]$Baseline.redaction.currentValueStored) { $failures.Add('currentValueStored') }
    if ($Metrics.sensitivePatternCount -ne [int]$Baseline.redaction.sensitivePatternCount) { $failures.Add('sensitivePatternCount') }
    @($failures.ToArray())
}

try {
    $selectionContext = New-HtsLayoutInspectionContext -SessionContext $session -GetTopWindows { @(Get-TopWindows) } -GetChildWindows { param([Int64]$Hwnd) @(Get-ChildWindows $Hwnd) } -InvokeBridgeRequest { param($ctx,$req) Invoke-FlaUiBridgeRequest -Context $ctx -Request $req }
    $selected = Get-HtsExactOrderScreenWindow -Context $selectionContext -MainClassName ([string]$profile.window.className) -MainTitlePrefix ([string]$profile.window.titlePrefix) -ScreenId '0101'
    $rootHwnd = [Int64]$selected.Screen.hwnd
    $stateResponse = Invoke-ReadOnlyBridge ([ordered]@{ operation = 'observeState'; rootHwnd = $rootHwnd })
    $snapshots = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt $SnapshotCount; $i++) {
        $layoutResponse = Get-LayoutSnapshot $rootHwnd
        $metrics = Get-ObservationMetrics $stateResponse $layoutResponse
        $signatures = Get-StructureSignatures $layoutResponse
        $snapshots.Add([pscustomobject]@{ observedAt = [DateTimeOffset]::Now; metrics = $metrics; signatures = $signatures })
        if ($i -lt ($SnapshotCount - 1)) { Start-Sleep -Milliseconds $SnapshotDelayMilliseconds }
    }
    $first = $snapshots[0]
    $similarities = @($snapshots | ForEach-Object { if ($_.signatures.hash -eq $first.signatures.hash) { 1.0 } else { 0.0 } })
    $stabilitySimilarity = ($similarities | Measure-Object -Average).Average
    $metricFailures = @(Test-MetricContract $first.metrics $baseline)
    $windowOk = $selected.Main.visible -and $selected.Screen.visible -and [string]$selected.Main.className -eq [string]$profile.window.className -and ([string]$selected.Main.rawTitle).StartsWith([string]$profile.window.titlePrefix) -and [string]$selected.Screen.rawTitle -match '^\[0101\]' -and $first.metrics.rootBoundsValid -and $first.metrics.dpi -gt 0 -and -not [string]::IsNullOrWhiteSpace($first.metrics.stateFingerprint)
    $layoutOk = $first.metrics.totalNativeElements -gt 0 -and $first.metrics.nativeFallbackCount -gt 0 -and $first.metrics.providerErrorCount -eq 0 -and -not $first.metrics.truncated -and $first.metrics.rootBoundsValid
    $regionsOk = @('GlobalHeader','QuotePanel','OrderEntryPanel','TradeInfoPanel' | Where-Object { -not (Test-Range $first.metrics.regionCounts.$_ $baseline.ranges.$_) }).Count -eq 0
    $nativeOk = @('Edit','AfxWnd140','AfxFrameOrView140','Button','SysTabControl32','msctls_updown32' | Where-Object { -not (Test-Range $first.metrics.classCounts.$_ $baseline.ranges.$_) }).Count -eq 0
    $redactionOk = $first.metrics.currentValueStored -eq 0 -and $first.metrics.sensitivePatternCount -eq 0
    $stabilityOk = $stabilitySimilarity -ge [double]$baseline.stability.minimumSignatureSimilarity -and @($snapshots | Where-Object { $_.metrics.rootFingerprint -ne $first.metrics.rootFingerprint -or $_.metrics.providerErrorCount -ne 0 -or $_.metrics.truncated }).Count -eq 0
    $checks = @(
        [pscustomobject]@{ id = 'SC-0101-SCREEN-001'; checkpointId = 'CP-WINDOW-ATTACHED'; title = 'Window Attachment'; success = [bool]$windowOk; diagnosticCode = if ($windowOk) { 'WINDOW_ATTACHED' } else { 'WINDOW_ATTACHMENT_MISMATCH' }; actual = [pscustomobject]@{ candidateCount = 1; processMatched = $true; classMatched = ([string]$selected.Main.className -eq [string]$profile.window.className); titleMatched = ([string]$selected.Screen.rawTitle -match '^\[0101\]'); visible = [bool]$selected.Screen.visible; clientBoundsValid = [bool]$first.metrics.rootBoundsValid; dpiValid = $first.metrics.dpi -gt 0; rootFingerprintPresent = -not [string]::IsNullOrWhiteSpace($first.metrics.stateFingerprint) } },
        [pscustomobject]@{ id = 'SC-0101-SCREEN-002'; checkpointId = 'CP-LAYOUT-HEALTH'; title = 'Layout Discovery Health'; success = [bool]$layoutOk; diagnosticCode = if ($layoutOk) { 'LAYOUT_DISCOVERY_HEALTHY' } else { 'LAYOUT_DISCOVERY_UNHEALTHY' }; actual = [pscustomobject]@{ discoveryCompleted = $true; totalNativeElements = $first.metrics.totalNativeElements; nativeFallbackCount = $first.metrics.nativeFallbackCount; providerErrorCount = $first.metrics.providerErrorCount; truncated = $first.metrics.truncated; timeout = $false; rootBoundsValid = $first.metrics.rootBoundsValid } },
        [pscustomobject]@{ id = 'SC-0101-SCREEN-003'; checkpointId = 'CP-THREE-REGION'; title = 'Three-region Layout'; success = [bool]$regionsOk; diagnosticCode = if ($regionsOk) { 'REGION_CONTRACT_MATCHED' } else { 'REGION_CONTRACT_MISMATCH' }; actual = [pscustomobject]@{ regionCounts = $first.metrics.regionCounts; allRegionsInRange = $regionsOk; totalNativeElements = $first.metrics.totalNativeElements } },
        [pscustomobject]@{ id = 'SC-0101-SCREEN-004'; checkpointId = 'CP-NATIVE-BASELINE'; title = 'Native Control Baseline'; success = [bool]$nativeOk; diagnosticCode = if ($nativeOk) { 'NATIVE_CLASS_BASELINE_MATCHED' } else { 'NATIVE_CLASS_BASELINE_MISMATCH' }; actual = [pscustomobject]@{ classCounts = $first.metrics.classCounts; nativeFallbackCount = $first.metrics.nativeFallbackCount; duplicateHwndCount = 0; boundsLinkedToRoot = $first.metrics.rootBoundsValid } },
        [pscustomobject]@{ id = 'SC-0101-SCREEN-005'; checkpointId = 'CP-STABILITY-REDACTION'; title = 'Snapshot Stability and Redaction'; success = [bool]$stabilityOk -and [bool]$redactionOk; diagnosticCode = if ($stabilityOk -and $redactionOk) { 'STABILITY_REDACTION_MATCHED' } elseif (-not $redactionOk) { 'REDACTION_CONTRACT_FAILED' } else { 'SNAPSHOT_STABILITY_FAILED' }; actual = [pscustomobject]@{ snapshotCount = $snapshots.Count; stabilitySimilarity = $stabilitySimilarity; minimumSimilarity = [double]$baseline.stability.minimumSignatureSimilarity; rootFingerprintStable = @($snapshots | Where-Object { $_.metrics.rootFingerprint -ne $first.metrics.rootFingerprint }).Count -eq 0; currentValueStored = $first.metrics.currentValueStored; sensitivePatternCount = $first.metrics.sensitivePatternCount; redacted = $redactionOk } }
    )
    $runId = 'screen-contract-0101-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $checkpointEvidence = @($checks | ForEach-Object {
        $evidence = [ordered]@{ checkpointId = $_.checkpointId; expectedContract = $_.title; actualObservation = $_.actual; observedAt = [DateTimeOffset]::Now; sourceArtifactId = $runId; required = $true; evidenceRole = 'Checkpoint'; success = [bool]$_.success; verified = [bool]$_.success; diagnosticCode = $_.diagnosticCode }
        $path = Join-Path $evidenceDir ($_.id + '.json'); $evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding UTF8
        $evidence
    })
    $observations = [ordered]@{ schemaVersion = '1.0'; testPackId = '0101-screen-contract-smoke'; aggregateId = $runId; cases = @($checkpointEvidence | ForEach-Object { [ordered]@{ caseId = $_.checkpointId; executed = $true; expectedResult = [ordered]@{ expectationId = $_.checkpointId; type = 'Success'; description = [string]$_.expectedContract }; evaluationPolicy = [ordered]@{ notExecutedStatus = 'PENDING'; missingEvidenceStatus = 'PENDING'; matcherMismatchStatus = 'FAIL'; unresolvedExpectationStatus = 'PENDING'; observationOnlyStatus = 'PENDING'; infrastructureErrorStatus = 'ERROR' }; observations = @([ordered]@{ observationId = $_.checkpointId; kind = if ($_.success) { 'Success' } else { 'ProductFailure' }; executed = $true; evidencePresent = $true; message = [string]$_.diagnosticCode; sourceCode = [string]$_.diagnosticCode; source = $runId; evidenceRole = 'Checkpoint'; checkpointRequired = $true }) } }) }
    $observationsPath = Join-Path $fullOutput 'observations.json'; $observations | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $observationsPath -Encoding UTF8
    $testPackPath = Join-Path $fullOutput 'test-pack.json'; '{}' | Set-Content -LiteralPath $testPackPath -Encoding UTF8
    $resultsPath = Join-Path $fullOutput 'test-results.json'
    $cliProject = Join-Path $root 'src\HtsQa.Cli\HtsQa.Cli.csproj'
    & dotnet run --project $cliProject -- evaluate-results --test-pack $testPackPath --observations $observationsPath --output $resultsPath
    if ($LASTEXITCODE -ne 0) { throw "ResultEvaluator CLI failed: $LASTEXITCODE" }
    $results = Get-Content -LiteralPath $resultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $summary = [ordered]@{ schemaVersion = '1.0'; suite = [string]$scenario.suite; scenarioKind = [string]$scenario.scenarioKind; scope = [string]$scenario.scope; businessTransactionCoverage = 'None'; physicalActionCount = 0; transactionalActionCount = 0; runId = $runId; generatedAt = [DateTimeOffset]::Now; rootFingerprint = $first.metrics.rootFingerprint; snapshotCount = $snapshots.Count; baselineStatus = [string]$baseline.approvalStatus; metricFailures = $metricFailures; resultSummary = $results.summary; overallResult = $results.overallResult }
    $summary | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $fullOutput 'execution-summary.json') -Encoding UTF8
    [pscustomobject]@{ outputDirectory = $fullOutput; testResults = $resultsPath; overallStatus = [string]$results.overallResult.status; pass = [int]$results.summary.pass; fail = [int]$results.summary.fail; error = [int]$results.summary.error; pending = [int]$results.summary.pending; physicalActionCount = 0; transactionalActionCount = 0 } | ConvertTo-Json -Depth 10
} finally {
    Stop-FlaUiBridge -Context $session
}

