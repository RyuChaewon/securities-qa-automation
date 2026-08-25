<#
.SYNOPSIS Rule-suite runtime state and dependency context construction.
.DESCRIPTION Creates RunServices and RunState; it does not route modes, run cases, or decide verdicts.
#>

# Creates the mutable run carrier while keeping action and checkpoint evidence separate.
function New-HtsRuleSuiteRunState {
    param([Parameter(Mandatory = $true)]$RunSpec)

    [pscustomobject]@{
        Mode = if ($RunSpec.Input.DryRun) { 'DryRun' } elseif ($RunSpec.Input.PlanOnly) { 'PlanOnly' } else { 'Execute' }
        CurrentScreen = ''
        CurrentCase = ''
        Main = $null
        ScreenEdit = $null
        Cases = @()
        Results = (New-Object Collections.Generic.List[object])
        OpenedWindows = (New-Object Collections.Generic.List[object])
        ActionEvidence = (New-Object Collections.Generic.List[object])
        CheckpointEvidence = (New-Object Collections.Generic.List[object])
        UiActionCount = 0
        TransactionalActionCount = 0
        PendingReasons = (New-Object Collections.Generic.List[string])
        Errors = (New-Object Collections.Generic.List[string])
        CleanupAttempted = $false
        CleanupSucceeded = $false
        CleanupErrors = (New-Object Collections.Generic.List[string])
        ErrorRegex = $null
        InitialScreensClosed = 0
        InitialScreensPreserved = 0
        InitialSearchOverlaysClosed = 0
        EarlyExit = $false
        OutputReady = $false
        OutputPath = [string]$RunSpec.ReportDir
        ArtifactPaths = [ordered]@{
            caseResults = (Join-Path $RunSpec.ReportDir 'case-results.json')
            testResults = (Join-Path $RunSpec.ReportDir 'test-results.json')
            summary = (Join-Path $RunSpec.ReportDir 'summary.json')
        }
    }
}

# Creates the dependency carrier without initializing native or UI infrastructure.
function New-HtsRuleSuiteRunServices {
    param([Parameter(Mandatory = $true)]$RunSpec)

    [pscustomobject]@{
        RuntimeContext = $RunSpec.RuntimeContext
        ReportingContext = (New-HtsReportingContext -ReportExporter $RunSpec.ReportExporter -TcReportExporter $RunSpec.TcReportExporter -ExecutionTracePath $RunSpec.ExecutionTracePath)
        AutomationMetrics = $null
        SessionContext = $null
        TargetRuleContext = $null
        DiscoveryContext = $null
        BindingContext = $null
        ActionContext = $null
        ObservationContext = $null
        EvaluationAdapterContext = $null
        SafetyContext = $null
        NavigationContext = $null
        TargetStateErrorCodes = @()
        Cleanup = [pscustomobject]@{
            StopBridge = { param($Context) Stop-FlaUiBridge -Context $Context }
        }
    }
}

# Initializes native, session, discovery, action, observation, safety, and navigation contexts after DryRun routing.
function Initialize-HtsRuleSuiteRuntimeServices {
    param(
        [Parameter(Mandatory = $true)]$RunSpec,
        [Parameter(Mandatory = $true)]$RunServices
    )

    [void](Initialize-HtsNativeInterop)
    $RunServices.AutomationMetrics = New-HtsDiscoveryMetrics
    $RunServices.RuntimeContext.LastTextAutomationEngine = '미실행'

    $flaUiProject = Resolve-RulePath $RunSpec.Root ([string]$RunSpec.PipelineManifest.flaUiProject)
    $flaUiAssembly = Join-Path (Split-Path -Parent $flaUiProject) 'bin\Release\net8.0-windows7.0\HtsQa.FlaUi.dll'
    $RunServices.SessionContext = New-HtsSessionContext `
        -FlaUiAssembly $flaUiAssembly `
        -TargetWindowClassName $RunServices.RuntimeContext.TargetWindowClassName `
        -TargetWindowTitlePrefix $RunServices.RuntimeContext.TargetWindowTitlePrefix `
        -DisplayName ([string]$RunSpec.TargetContext.DisplayName) `
        -GetTopWindows { Get-TopWindows }

    $services = $RunServices
    $spec = $RunSpec
    $targetRuleDependencies = [pscustomobject]@{
        GetChildWindows = { param([Int64]$Hwnd) @(Get-ChildWindows $Hwnd) }
        GetFlaUiActionableControls = { param($Screen) @(Get-FlaUiActionableControls $services.DiscoveryContext $Screen) }
        GetWindowInfo = { param([Int64]$Hwnd) Get-WindowInfo ([IntPtr]$Hwnd) }
        ClickCenter = { param($Window, [bool]$DoubleClick) Click-Center $services.ActionContext $Window -DoubleClick:$DoubleClick }
        SendKey = { param([byte]$Key) Send-Key $services.ActionContext $Key }
        Sleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
        InvokeFlaUiControlAction = {
            param($Window, [string]$Action, [string]$Value, $Index, $Checked, [string]$Key)
            Invoke-FlaUiControlAction $services.ActionContext $Window $Action -Value $Value -Index $Index -Checked $Checked -Key $Key
        }
        SetAutomationText = {
            param($Window, [string]$Value, [bool]$AlreadyFocused)
            $success = Set-AutomationText $services.ActionContext $Window $Value -AlreadyFocused:$AlreadyFocused
            [pscustomobject]@{ success = [bool]$success; engine = [string]$services.RuntimeContext.LastTextAutomationEngine }
        }
    }
    foreach ($property in @($targetRuleDependencies.PSObject.Properties)) {
        if ($property.Value -is [scriptblock]) { $property.Value = $property.Value.GetNewClosure() }
    }
    $RunServices.TargetRuleContext = New-HtsTargetRuleContext -RootPath $RunSpec.Root -Dataset $RunSpec.Dataset -MapCatalog $RunSpec.MapCatalog -Dependencies $targetRuleDependencies
    $RunServices.TargetRuleContext.FastScenarioDiscovery = [bool]($RunSpec.ScenarioMode -or $RunSpec.Input.PlanOnly)
    if ($RunSpec.Input.TargetStateOverride) { Set-HtsTargetInitialStateOverride $RunServices.TargetRuleContext.TargetAdapter ([string]$RunSpec.Input.TargetStateOverride) }

    $discoveryDependencies = [pscustomobject]@{
        InvokeBridgeRequest = { param($Context, $Request) Invoke-FlaUiBridgeRequest -Context $Context -Request $Request }
        GetMapScreenModel = { param([string]$ScreenNumber, [string]$MapScreenCode) Get-RuleMapScreenModel $services.TargetRuleContext $ScreenNumber $MapScreenCode }
        GetRuleDiscoveredControls = { param($Screen, [string]$ScreenNumber, [hashtable]$ClaimedHwnds) @(Get-RuleDiscoveredControls $services.TargetRuleContext $Screen $ScreenNumber $ClaimedHwnds) }
    }
    foreach ($property in @($discoveryDependencies.PSObject.Properties)) {
        if ($property.Value -is [scriptblock]) { $property.Value = $property.Value.GetNewClosure() }
    }
    $RunServices.DiscoveryContext = New-HtsDiscoveryContext -SessionContext $RunServices.SessionContext -Dependencies $discoveryDependencies -Metrics $RunServices.AutomationMetrics
    $RunServices.TargetStateErrorCodes = @(Get-HtsTargetStateErrorCodes $RunServices.TargetRuleContext.TargetAdapter)

    $bindingDependencies = [pscustomobject]@{
        GetChildWindows = { param([Int64]$Hwnd) @(Get-ChildWindows $Hwnd) }
        TestControlExecutionEligible = { param($Control) Test-RuleControlExecutionEligible $Control }
    }
    foreach ($property in @($bindingDependencies.PSObject.Properties)) {
        if ($property.Value -is [scriptblock]) { $property.Value = $property.Value.GetNewClosure() }
    }
    $RunServices.BindingContext = New-HtsBindingContext -DiscoveryContext $RunServices.DiscoveryContext -Dependencies $bindingDependencies

    $actionDependencies = [pscustomobject]@{
        AssertClickScope = { param($Window, [int]$X, [int]$Y) Assert-HtsSafetyClickScope -Context $services.SafetyContext -Window $Window -X $X -Y $Y }
        GetActiveInputSurface = { Get-HtsSafetyActiveInputSurface -Context $services.SafetyContext }
        InvokeBridgeRequest = { param($Context, $Request) Invoke-FlaUiBridgeRequest -Context $Context -Request $Request }
        WriteInputAudit = { param([string]$InputType, [string]$Status, [int]$X, [int]$Y, [string]$Detail) Write-HtsSafetyInputBoundaryAudit -Context $services.SafetyContext -InputType $InputType -Status $Status -X $X -Y $Y -Detail $Detail }
        InvokeRuleControlPlanItem = { param($Navigation, $Screen, $PlanItem) Invoke-RuleControlPlanItem $services.TargetRuleContext $Navigation $Screen $PlanItem }
        InvokeRuleDatasetVariable = { param($Window, [string]$Kind, [string]$Value, [string]$ValueMatch, [int]$MaxOptions) Invoke-RuleDatasetVariable $services.TargetRuleContext $Window $Kind $Value $ValueMatch $MaxOptions }
        GetChildWindows = { param([Int64]$Hwnd) @(Get-ChildWindows $Hwnd) }
        GetWindowInfo = { param([Int64]$Hwnd) Get-WindowInfo ([IntPtr]$Hwnd) }
        GetDialogs = { param($Observation, $Run, $MainWindow, [string]$SecretText) @(Get-HtsDialogs $Observation $Run $MainWindow $SecretText) }
        TestConnectionDialog = { param($Dialog) Test-HtsConnectionDialog $Dialog }
    }
    foreach ($property in @($actionDependencies.PSObject.Properties)) {
        if ($property.Value -is [scriptblock]) { $property.Value = $property.Value.GetNewClosure() }
    }
    $RunServices.ActionContext = New-HtsActionContext -SessionContext $RunServices.SessionContext -Metrics $RunServices.AutomationMetrics -Dependencies $actionDependencies -RuntimeContext $RunServices.RuntimeContext -TargetAdapterContext $RunServices.TargetRuleContext.TargetAdapter

    $observationDependencies = [pscustomobject]@{
        CreateSignalEvaluationCase = {
            param([string]$CaseId, [string]$EventType, [string]$Text, [string]$SourceCode, [string]$Source, $ExpectedOutcome, [string]$EvidenceRole, [bool]$CheckpointRequired)
            New-RuleSignalEvaluationCase -CaseId $CaseId -EventType $EventType -Text $Text -SourceCode $SourceCode -Source $Source -ExpectedOutcome $ExpectedOutcome -EvidenceRole $EvidenceRole -CheckpointRequired $CheckpointRequired
        }
        GetNow = { Get-Date }
        GetTopWindows = { @(Get-TopWindows) }
        GetChildWindows = { param([Int64]$Hwnd) @(Get-ChildWindows $Hwnd) }
        GetWindowInfo = { param([Int64]$Hwnd) Get-WindowInfo ([IntPtr]$Hwnd) }
        GetScreenNumber = { param($Window) Get-HtsScreenNumber $services.NavigationContext $Window }
        ProtectText = { param($Text, [string]$Secret) Protect-Text $Text $Secret }
        GetRelativeFilePath = { param([string]$BasePath, [string]$Path) Get-RelativeFilePath $BasePath $Path }
    }
    foreach ($property in @($observationDependencies.PSObject.Properties)) {
        if ($property.Value -is [scriptblock]) { $property.Value = $property.Value.GetNewClosure() }
    }
    $RunServices.ObservationContext = New-HtsObservationContext -MapCatalog $RunSpec.MapCatalog -InstallationRoot ([string]$RunSpec.TargetContext.InstallationRoot) -Dependencies $observationDependencies
    $RunServices.EvaluationAdapterContext = New-HtsEvaluationAdapterContext `
        -CliProject $RunSpec.CliProject `
        -TestPackPath $RunSpec.ResultEvaluationTestPackPath `
        -WorkingDirectory $RunSpec.ResultEvaluationWorkingDirectory `
        -ObservationContext $RunServices.ObservationContext

    $safetyDependencies = [pscustomobject]@{
        IsWindow = { param([Int64]$Hwnd) [TargetRuleNative]::IsWindow([IntPtr]$Hwnd) }
        GetWindowInfo = { param([Int64]$Hwnd) Get-WindowInfo ([IntPtr]$Hwnd) }
        IsChild = { param([Int64]$Parent, [Int64]$Child) [TargetRuleNative]::IsChild([IntPtr]$Parent, [IntPtr]$Child) }
        GetWindowProcessId = { param([Int64]$Hwnd) [uint32]$windowProcessId = 0; [void][TargetRuleNative]::GetWindowThreadProcessId([IntPtr]$Hwnd, [ref]$windowProcessId); [int]$windowProcessId }
        GetScreenNumber = { param($Window) Get-HtsScreenNumber $services.NavigationContext $Window }
        GetContentPolicy = { param([string]$ScreenNumber) Get-RuleContentPolicy $services.TargetRuleContext $ScreenNumber }
        TestContentControl = { param($Window, $Screen, $Policy) Test-RuleContentControl $Window $Screen $Policy }
        GetKeyboardFocusHwnd = { $info = New-Object TargetRuleNative+GUITHREADINFO; $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][TargetRuleNative+GUITHREADINFO]); [void][TargetRuleNative]::GetGUIThreadInfo(0, [ref]$info); [Int64]$info.hwndFocus.ToInt64() }
        WindowFromPoint = { param([int]$X, [int]$Y) $point = New-Object TargetRuleNative+POINT; $point.X = $X; $point.Y = $Y; [Int64]([TargetRuleNative]::WindowFromPoint($point)).ToInt64() }
        GetNow = { Get-Date }
        AppendAuditRecord = {
            param([string]$Path, $Record)
            $line = ($Record | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine
            for ($attempt = 1; $attempt -le 5; $attempt++) { $stream = $null; try { $stream = [IO.FileStream]::new($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite); [void]$stream.Seek(0, [IO.SeekOrigin]::End); $bytes = [Text.UTF8Encoding]::new($false).GetBytes($line); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush(); return } catch [IO.IOException] { if ($attempt -eq 5) { throw }; Start-Sleep -Milliseconds (20 * $attempt) } finally { if ($stream) { $stream.Dispose() } } }
        }
    }
    foreach ($property in @($safetyDependencies.PSObject.Properties)) {
        if ($property.Value -is [scriptblock]) { $property.Value = $property.Value.GetNewClosure() }
    }
    $RunServices.SafetyContext = New-HtsSafetyContext -AuditPath $RunSpec.InputBoundaryAuditPath -Dependencies $safetyDependencies
    $RunServices.ActionContext.SafetyContext = $RunServices.SafetyContext

    $navigationDependencies = [pscustomobject]@{
        GetChildWindows = { param([Int64]$Hwnd) @(Get-ChildWindows $Hwnd) }
        GetWindowInfo = { param([Int64]$Hwnd) Get-WindowInfo ([IntPtr]$Hwnd) }
        IsWindow = { param([Int64]$Hwnd) [TargetRuleNative]::IsWindow([IntPtr]$Hwnd) }
        ActivateMain = {
            param($Main)
            [void][TargetRuleNative]::ShowWindow([IntPtr][Int64]$Main.hwnd, 9)
            [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$Main.hwnd)
        }
        ActivateRequestedScreen = {
            param($Main, $Screen)
            $screenHwnd = [IntPtr][Int64]$Screen.hwnd
            $parentHwnd = [TargetRuleNative]::GetParent($screenHwnd)
            [void][TargetRuleNative]::ShowWindow([IntPtr][Int64]$Main.hwnd, 9)
            [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$Main.hwnd)
            if ($parentHwnd -ne [IntPtr]::Zero) { [void][TargetRuleNative]::SendMessage($parentHwnd, 0x0222, $screenHwnd, [IntPtr]::Zero) }
            [void][TargetRuleNative]::BringWindowToTop($screenHwnd)
        }
        SetInputSurface = { param($Window, [string]$Kind, [string]$Label) Set-HtsSafetyInputSurface -Context $services.SafetyContext -Window $Window -Kind $Kind -Label $Label }
        SetScreenNumber = { param($ScreenEdit, [string]$ScreenNumber) Set-HtsScreenNumber $ScreenEdit $ScreenNumber }
        InvokeControlAction = { param($Window, [string]$Action, [string]$Key) Invoke-FlaUiControlAction $services.ActionContext $Window $Action -Key $Key }
        TestInputAccess = { param($Window) Test-HtsScreenNavigationInputAccess $Window }
        ClickCenter = { param($Window) Click-Center $services.ActionContext $Window }
        SendEnter = { Send-Key $services.ActionContext ([byte]0x0D) }
        FocusInputWindow = { param($Window) Focus-HtsInputWindow $services.ActionContext $Window }
        Sleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
        GetNow = { Get-Date }
        GetWindowProcessId = { param([Int64]$Hwnd) [uint32]$processId = 0; [void][TargetRuleNative]::GetWindowThreadProcessId([IntPtr]$Hwnd, [ref]$processId); [int]$processId }
        IsChild = { param([Int64]$ParentHwnd, [Int64]$ChildHwnd) [TargetRuleNative]::IsChild([IntPtr]$ParentHwnd, [IntPtr]$ChildHwnd) }
        CloseWindow = { param($Window) [void][TargetRuleNative]::SendMessage([IntPtr][Int64]$Window.hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
        ClearInputSurfaceForWindow = { param($Window) if ([Int64]$services.SafetyContext.ActiveInputSurfaceHwnd -eq [Int64]$Window.hwnd) { Clear-HtsSafetyInputSurface -Context $services.SafetyContext } }
    }
    foreach ($property in @($navigationDependencies.PSObject.Properties)) {
        if ($property.Value -is [scriptblock]) { $property.Value = $property.Value.GetNewClosure() }
    }
    $RunServices.NavigationContext = New-HtsNavigationContext `
        -SessionContext $RunServices.SessionContext `
        -TargetScreenTitleRegex $RunServices.RuntimeContext.TargetScreenTitleRegex `
        -ScreenOpenTimeoutMs ([int]$RunSpec.Dataset.executionPolicy.screenOpenTimeoutMs) `
        -Dependencies $navigationDependencies

    $RunServices
}
