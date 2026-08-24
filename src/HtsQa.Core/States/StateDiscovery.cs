// 역할: 화면 독립적인 상태 그래프, 안전 전환, 도착 Checkpoint, 복구와 상태별 discovery 결과 계약을 정의한다.
// 입력/출력: TargetAdapter가 제공한 그래프를 검증하고 상태별 관측 결과를 결정론적인 JSON 계약으로 교환한다.
// 경계: 특정 화면명·locator·업무값이나 UI 실행 코드를 포함하지 않으며 TestResult verdict를 계산하지 않는다.
// 수정 지점: enum 또는 schema를 바꾸면 TargetAdapter, PowerShell 순회, reporter 계약 테스트를 함께 갱신한다.
namespace HtsQa.Core;

public static class StateDiscoveryVersions
{
    public const string GraphSchema = "1.0";
    public const string ResultSchema = "1.0";
}

public enum StateGraphConfigurationStatus { Ready, ConfigurationRequired }
public enum StateTransitionRiskClass { ReadOnly, SafeNavigation, Transactional, Prohibited }
public enum StateTransitionActionKind { Focus, Select, Toggle, Invoke, Query, FinalSubmit, AmendSubmit, CancelSubmit, TradeConfirmation }
public enum StateLocatorStrategy { RuntimeId, AutomationId, NameAndControlType, Coordinates }
public enum StateLocatorConfidence { Unspecified, Low, Medium, High }
public enum StateRestoreMode { Deterministic, ConfigurationRequired, NotRequired }
public enum StateDiscoveryStatus { SUCCESS, FAILED, PENDING }
public enum StateRestoreStatus { SUCCESS, FAILED, PENDING, NOT_REQUIRED }
public enum StateFailureCategory { NONE, AUTOMATION, ENVIRONMENT, TEST_DATA, APPLICATION, POLICY, UNKNOWN }

public sealed record StateContext
{
    public required string StateId { get; init; }
    public required string StateContextId { get; init; }
    public required string ScreenId { get; init; }
    public StateGraphConfigurationStatus ConfigurationStatus { get; init; } = StateGraphConfigurationStatus.ConfigurationRequired;
    public string[] MapScreenCodes { get; init; } = [];
    public string[] MapHostKeys { get; init; } = [];
    public string[] EvidenceRefs { get; init; } = [];
}

public sealed record StatePrecondition
{
    public string ExpectedStateId { get; init; } = "";
    public bool RequireProcessOwnershipMatch { get; init; } = true;
    public bool RequireWindowFingerprintMatch { get; init; } = true;
    public string[] EvidenceRequirements { get; init; } = [];
}

public sealed record StateLocator
{
    public StateLocatorStrategy Strategy { get; init; } = StateLocatorStrategy.RuntimeId;
    public string RuntimeId { get; init; } = "";
    public string AutomationId { get; init; } = "";
    public string Name { get; init; } = "";
    public string ControlType { get; init; } = "";
    public string Source { get; init; } = "";
    public StateLocatorConfidence Confidence { get; init; } = StateLocatorConfidence.Unspecified;
}

public sealed record StateTransitionAction
{
    public string TargetControlId { get; init; } = "";
    public StateTransitionActionKind Kind { get; init; } = StateTransitionActionKind.Select;
    public StateLocator Locator { get; init; } = new();
    public bool Allowlisted { get; init; }
    public string[] ApprovalEvidence { get; init; } = [];
    public string Value { get; init; } = "";
    public int? Index { get; init; }
    public bool? Checked { get; init; }
}

public sealed record ArrivalCheckpoint
{
    public string CheckpointId { get; init; } = "";
    public string Kind { get; init; } = "";
    public bool Required { get; init; } = true;
    public StateLocator? Locator { get; init; }
    public string ExpectedValue { get; init; } = "";
    public string[] EvidenceRequirements { get; init; } = [];
}

public sealed record StateTransition
{
    public required string TransitionId { get; init; }
    public required string SourceStateId { get; init; }
    public required string TargetStateId { get; init; }
    public StatePrecondition Precondition { get; init; } = new();
    public StateTransitionAction Action { get; init; } = new();
    public ArrivalCheckpoint ArrivalCheckpoint { get; init; } = new();
    public int TimeoutMs { get; init; } = 5000;
    public StateTransitionAction RestoreAction { get; init; } = new();
    public StateTransitionRiskClass RiskClass { get; init; } = StateTransitionRiskClass.SafeNavigation;
    public string[] EvidenceRequirements { get; init; } = [];
}

public sealed record RestorePolicy
{
    public StateRestoreMode Mode { get; init; } = StateRestoreMode.ConfigurationRequired;
    public string BaselineStateId { get; init; } = "";
    public int MaxAttempts { get; init; } = 1;
    public int TimeoutMs { get; init; } = 5000;
    public StateTransitionAction? Action { get; init; }
    public ArrivalCheckpoint? ArrivalCheckpoint { get; init; }
    public string[] EvidenceRequirements { get; init; } = [];
}

public sealed record StateGraph
{
    public string SchemaVersion { get; init; } = StateDiscoveryVersions.GraphSchema;
    public required string GraphId { get; init; }
    public required string ScreenId { get; init; }
    public StateGraphConfigurationStatus ConfigurationStatus { get; init; } = StateGraphConfigurationStatus.ConfigurationRequired;
    public string BaselineStateId { get; init; } = "";
    public StateContext[] States { get; init; } = [];
    public StateTransition[] Transitions { get; init; } = [];
    public RestorePolicy RestorePolicy { get; init; } = new();
    public string[] EvidenceRefs { get; init; } = [];
}

public sealed record StateProcessOwnership
{
    public int ProcessId { get; init; }
    public string ProcessName { get; init; } = "";
    public bool MatchesExpectedOwner { get; init; }
}

public sealed record StateIdentityObservation
{
    public string ExpectedStateId { get; init; } = "";
    public string ObservedStateId { get; init; } = "";
    public bool CheckpointSatisfied { get; init; }
    public string[] EvidenceRefs { get; init; } = [];
}

public sealed record StateLocatorEvidence
{
    public string Source { get; init; } = "";
    public StateLocatorConfidence Confidence { get; init; } = StateLocatorConfidence.Unspecified;
    public bool Approved { get; init; }
    public string[] EvidenceRefs { get; init; } = [];
}

public sealed record StateControlDiscovery
{
    public required string StateContextId { get; init; }
    public long Hwnd { get; init; }
    public string UiaRuntimeId { get; init; } = "";
    public string MapControlId { get; init; } = "";
    public string RuntimeControlId { get; init; } = "";
    public RuleRuntimeRect? MapHostClientRect { get; init; }
    public StateProcessOwnership ProcessOwnership { get; init; } = new();
    public int Dpi { get; init; }
    public string WindowFingerprint { get; init; } = "";
    public StateIdentityObservation StateIdentity { get; init; } = new();
    public DateTimeOffset ObservedAt { get; init; }
    public string ScreenshotRef { get; init; } = "";
    public string UiTreeRef { get; init; } = "";
    public StateLocatorEvidence LocatorEvidence { get; init; } = new();
    public bool Visible { get; init; }
    public bool Enabled { get; init; }
    public bool ActiveState { get; init; }
    public bool Executable { get; init; }
}

public sealed record StateTransitionResult
{
    public string TransitionId { get; init; } = "";
    public bool ActionSent { get; init; }
    public bool ActionVerified { get; init; }
    public bool ArrivalCheckpointSatisfied { get; init; }
    public StateDiscoveryStatus Status { get; init; } = StateDiscoveryStatus.PENDING;
    public string ErrorCode { get; init; } = "";
    public long ElapsedMs { get; init; }
    public string[] EvidenceRefs { get; init; } = [];
}

public sealed record StateDiscoveryStateResult
{
    public required StateContext StateContext { get; init; }
    public StateDiscoveryStatus Status { get; init; } = StateDiscoveryStatus.PENDING;
    public StateFailureCategory FailureCategory { get; init; } = StateFailureCategory.NONE;
    public string ReasonCode { get; init; } = "";
    public StateTransitionResult? Transition { get; init; }
    public StateControlDiscovery[] Controls { get; init; } = [];
    public string ScreenshotRef { get; init; } = "";
    public string UiTreeRef { get; init; } = "";
}

public sealed record StateRestoreResult
{
    public StateRestoreStatus Status { get; init; } = StateRestoreStatus.PENDING;
    public bool ActionSent { get; init; }
    public bool ArrivalCheckpointSatisfied { get; init; }
    public StateFailureCategory FailureCategory { get; init; } = StateFailureCategory.NONE;
    public string ReasonCode { get; init; } = "";
    public string[] EvidenceRefs { get; init; } = [];
    public string ScreenshotRef { get; init; } = "";
    public string UiTreeRef { get; init; } = "";
}

public sealed record StateDiscoveryResultDocument
{
    public string SchemaVersion { get; init; } = StateDiscoveryVersions.ResultSchema;
    public required string GraphId { get; init; }
    public DateTimeOffset ObservedAt { get; init; }
    public StateDiscoveryStateResult[] States { get; init; } = [];
    public StateRestoreResult Restore { get; init; } = new();
    public int TransitionActionCount { get; init; }
    public int TransactionalActionCount { get; init; }
}

/// <summary>inactive, hidden, 미승인 locator가 실행 가능한 control로 승격되지 않도록 단일 정책으로 정규화한다.</summary>
public static class StateControlDiscoveryPolicy
{
    public static StateControlDiscovery Normalize(StateControlDiscovery control, bool requestedExecutable) => control with
    {
        Executable = requestedExecutable && control.ActiveState && control.Visible && control.Enabled &&
                     control.LocatorEvidence.Approved && control.LocatorEvidence.Confidence == StateLocatorConfidence.High
    };

    public static string IdentityKey(StateControlDiscovery control) =>
        $"{control.StateContextId}|{control.Hwnd}|{control.UiaRuntimeId}|{control.MapControlId}|{control.RuntimeControlId}";
}

/// <summary>승인·locator·Checkpoint·복구 정보가 모두 있는 비거래 전환만 Ready graph에 허용한다.</summary>
public static class StateGraphValidator
{
    private static readonly HashSet<StateTransitionActionKind> ProhibitedActionKinds =
    [
        StateTransitionActionKind.FinalSubmit,
        StateTransitionActionKind.AmendSubmit,
        StateTransitionActionKind.CancelSubmit,
        StateTransitionActionKind.TradeConfirmation
    ];

    public static IReadOnlyList<ValidationIssue> Validate(StateGraph? graph)
    {
        if (graph is null) return [];
        var issues = new List<ValidationIssue>();
        if (graph.SchemaVersion != StateDiscoveryVersions.GraphSchema)
            issues.Add(new("STATE.GRAPH_SCHEMA_VERSION", $"stateGraph.schemaVersion must be {StateDiscoveryVersions.GraphSchema}.", Field: "stateGraph.schemaVersion"));
        if (string.IsNullOrWhiteSpace(graph.GraphId) || string.IsNullOrWhiteSpace(graph.ScreenId))
            issues.Add(new("STATE.GRAPH_IDENTITY", "stateGraph requires graphId and screenId.", Field: "stateGraph"));
        AddRequiredUnique(graph.States.Select(x => x.StateId), "STATE.DUPLICATE_STATE", "stateGraph.states.stateId", issues);
        AddRequiredUnique(graph.States.Select(x => x.StateContextId), "STATE.DUPLICATE_CONTEXT", "stateGraph.states.stateContextId", issues);
        AddRequiredUnique(graph.Transitions.Select(x => x.TransitionId), "STATE.DUPLICATE_TRANSITION", "stateGraph.transitions.transitionId", issues, allowEmpty: true);

        var stateIds = graph.States.Select(x => x.StateId).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var state in graph.States)
        {
            if (!state.ScreenId.Equals(graph.ScreenId, StringComparison.OrdinalIgnoreCase))
                issues.Add(new("STATE.SCREEN_MISMATCH", $"State {state.StateId} does not belong to graph screen {graph.ScreenId}.", Field: "stateGraph.states.screenId"));
            if (state.ConfigurationStatus == StateGraphConfigurationStatus.Ready && state.EvidenceRefs.Length == 0)
                issues.Add(new("STATE.EVIDENCE_REQUIRED", $"Ready state {state.StateId} requires evidenceRefs.", Field: "stateGraph.states.evidenceRefs"));
        }

        foreach (var transition in graph.Transitions)
        {
            if (!stateIds.Contains(transition.SourceStateId) || !stateIds.Contains(transition.TargetStateId))
                issues.Add(new("STATE.TRANSITION_ENDPOINT", $"Transition {transition.TransitionId} must reference declared states.", Field: "stateGraph.transitions"));
            if (string.IsNullOrWhiteSpace(transition.Precondition.ExpectedStateId) ||
                !transition.Precondition.ExpectedStateId.Equals(transition.SourceStateId, StringComparison.OrdinalIgnoreCase))
                issues.Add(new("STATE.PRECONDITION_REQUIRED", $"Transition {transition.TransitionId} requires a source-state precondition.", Field: "stateGraph.transitions.precondition"));
            if (transition.TimeoutMs <= 0)
                issues.Add(new("STATE.TIMEOUT_REQUIRED", $"Transition {transition.TransitionId} requires a positive timeoutMs.", Field: "stateGraph.transitions.timeoutMs"));
            ValidateAction(transition.Action, transition.TransitionId, "action", transition.RiskClass, issues);
            ValidateAction(transition.RestoreAction, transition.TransitionId, "restoreAction", StateTransitionRiskClass.SafeNavigation, issues);
            ValidateCheckpoint(transition.ArrivalCheckpoint, transition.TransitionId, issues);
            if (transition.EvidenceRequirements.Length == 0)
                issues.Add(new("STATE.TRANSITION_EVIDENCE_REQUIRED", $"Transition {transition.TransitionId} requires evidenceRequirements.", Field: "stateGraph.transitions.evidenceRequirements"));
        }

        if (graph.ConfigurationStatus == StateGraphConfigurationStatus.Ready)
        {
            if (string.IsNullOrWhiteSpace(graph.BaselineStateId) || !stateIds.Contains(graph.BaselineStateId))
                issues.Add(new("STATE.BASELINE_REQUIRED", "Ready stateGraph requires a declared baselineStateId.", Field: "stateGraph.baselineStateId"));
            if (graph.RestorePolicy.Mode != StateRestoreMode.Deterministic)
                issues.Add(new("STATE.RESTORE_REQUIRED", "Ready stateGraph requires a deterministic restore policy.", Field: "stateGraph.restorePolicy.mode"));
        }

        ValidateRestorePolicy(graph.RestorePolicy, stateIds, issues);
        return issues;
    }

    private static void ValidateRestorePolicy(RestorePolicy policy, HashSet<string> stateIds, List<ValidationIssue> issues)
    {
        if (policy.Mode == StateRestoreMode.ConfigurationRequired) return;
        if (policy.Mode == StateRestoreMode.NotRequired) return;
        if (string.IsNullOrWhiteSpace(policy.BaselineStateId) || !stateIds.Contains(policy.BaselineStateId))
            issues.Add(new("STATE.RESTORE_BASELINE_REQUIRED", "Deterministic restore requires a declared baseline state.", Field: "stateGraph.restorePolicy.baselineStateId"));
        if (policy.MaxAttempts <= 0 || policy.TimeoutMs <= 0)
            issues.Add(new("STATE.RESTORE_LIMIT_REQUIRED", "Deterministic restore requires positive maxAttempts and timeoutMs.", Field: "stateGraph.restorePolicy"));
        if (policy.Action is null)
            issues.Add(new("STATE.RESTORE_ACTION_REQUIRED", "Deterministic restore requires an approved action.", Field: "stateGraph.restorePolicy.action"));
        else
            ValidateAction(policy.Action, "restorePolicy", "action", StateTransitionRiskClass.SafeNavigation, issues);
        if (policy.ArrivalCheckpoint is null)
            issues.Add(new("STATE.RESTORE_CHECKPOINT_REQUIRED", "Deterministic restore requires an arrival Checkpoint.", Field: "stateGraph.restorePolicy.arrivalCheckpoint"));
        else
            ValidateCheckpoint(policy.ArrivalCheckpoint, "restorePolicy", issues);
        if (policy.EvidenceRequirements.Length == 0)
            issues.Add(new("STATE.RESTORE_EVIDENCE_REQUIRED", "Deterministic restore requires evidenceRequirements.", Field: "stateGraph.restorePolicy.evidenceRequirements"));
    }

    private static void ValidateAction(StateTransitionAction action, string id, string field, StateTransitionRiskClass riskClass, List<ValidationIssue> issues)
    {
        if (riskClass is StateTransitionRiskClass.Transactional or StateTransitionRiskClass.Prohibited || ProhibitedActionKinds.Contains(action.Kind))
            issues.Add(new("STATE.TRANSACTIONAL_ACTION_PROHIBITED", $"{id} registers a prohibited transactional action.", Field: $"stateGraph.transitions.{field}"));
        if (string.IsNullOrWhiteSpace(action.TargetControlId))
            issues.Add(new("STATE.TARGET_CONTROL_REQUIRED", $"{id} {field} requires a target control identity.", Field: $"stateGraph.transitions.{field}.targetControlId"));
        if (!action.Allowlisted || action.ApprovalEvidence.Length == 0)
            issues.Add(new("STATE.ACTION_APPROVAL_REQUIRED", $"{id} {field} requires an allowlist and approval evidence.", Field: $"stateGraph.transitions.{field}"));
        if (action.Locator.Strategy == StateLocatorStrategy.Coordinates)
            issues.Add(new("STATE.COORDINATE_LOCATOR_PROHIBITED", $"{id} {field} cannot use desktop coordinates.", Field: $"stateGraph.transitions.{field}.locator"));
        if (action.Locator.Confidence != StateLocatorConfidence.High || string.IsNullOrWhiteSpace(action.Locator.Source))
            issues.Add(new("STATE.LOCATOR_EVIDENCE_REQUIRED", $"{id} {field} requires a high-confidence sourced locator.", Field: $"stateGraph.transitions.{field}.locator"));
        var hasIdentity = action.Locator.Strategy switch
        {
            StateLocatorStrategy.RuntimeId => !string.IsNullOrWhiteSpace(action.Locator.RuntimeId),
            StateLocatorStrategy.AutomationId => !string.IsNullOrWhiteSpace(action.Locator.AutomationId),
            StateLocatorStrategy.NameAndControlType => !string.IsNullOrWhiteSpace(action.Locator.Name) && !string.IsNullOrWhiteSpace(action.Locator.ControlType),
            _ => false
        };
        if (!hasIdentity)
            issues.Add(new("STATE.LOCATOR_REQUIRED", $"{id} {field} requires a semantic locator identity.", Field: $"stateGraph.transitions.{field}.locator"));
    }

    private static void ValidateCheckpoint(ArrivalCheckpoint checkpoint, string id, List<ValidationIssue> issues)
    {
        if (!checkpoint.Required || string.IsNullOrWhiteSpace(checkpoint.CheckpointId) || string.IsNullOrWhiteSpace(checkpoint.Kind) || checkpoint.EvidenceRequirements.Length == 0)
            issues.Add(new("STATE.ARRIVAL_CHECKPOINT_REQUIRED", $"{id} requires a required arrival Checkpoint with evidence.", Field: "stateGraph.transitions.arrivalCheckpoint"));
    }

    private static void AddRequiredUnique(IEnumerable<string> values, string code, string field, List<ValidationIssue> issues, bool allowEmpty = false)
    {
        var items = values.ToArray();
        if ((!allowEmpty && items.Length == 0) || items.Any(string.IsNullOrWhiteSpace) || items.Distinct(StringComparer.OrdinalIgnoreCase).Count() != items.Length)
            issues.Add(new(code, $"{field} requires unique non-empty values.", Field: field));
    }
}
