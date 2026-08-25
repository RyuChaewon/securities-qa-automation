// 역할: 승인된 Control Repository key만 사용하는 주문 시나리오, 정적 검증, 불변 DryRun 계획 계약을 정의한다.
// 경계: UI Action과 verdict를 수행하지 않으며 기존 TestPack/ResultEvaluator 계약을 변경하지 않는다.
namespace HtsQa.Core;

public static class OrderScenarioAuthoringVersions
{
    public const string ScenarioSchema = "1.0";
    public const string ValidationSchema = "1.0";
    public const string RunPlanSchema = "1.0";
    public const string DryRunSchema = "1.0";
    public const string Compiler = "1.0.0";
}

public enum OrderScenarioConfigurationStatus { ConfigurationRequired, ReviewRequired, Ready }
public enum OrderScenarioStepRole { Precondition, Transition, Action, Checkpoint, Restore }
public enum OrderCheckpointRequirement { NotApplicable, Required, Optional }
public enum OrderScenarioOperation
{
    ObserveState, Transition, Focus, Input, Select, Toggle, Click, DoubleClick, Query, PressKey,
    AssertValue, AssertState, AssertMessage, AssertFocus, AssertPopup, AssertGrid, AssertLogDelta,
    AssertTransmissionCount, AssertOrderReceipt, Restore
}
public enum OrderEvidenceKind
{
    ActionDelivery, Value, State, Message, Focus, Popup, Grid, LogDelta, TransmissionCount,
    OrderReceipt, Screenshot, UiTree
}
public enum OrderScenarioValidationStatus { Ready, Blocked, ConfigurationRequired, ReviewRequired }
public enum OrderRunPlanExecutionMode { DryRun }

public sealed record OrderScenarioVariable
{
    public required string Name { get; init; }
    public bool Sensitive { get; init; }
    public bool Required { get; init; } = true;
}

public sealed record OrderScenarioRestoreContract
{
    public required string PolicyId { get; init; }
    public required string BaselineStateId { get; init; }
    public bool Required { get; init; } = true;
}

public sealed record OrderScenarioStep
{
    public required string StepId { get; init; }
    public int Sequence { get; init; }
    public OrderScenarioStepRole Role { get; init; }
    public ControlRepositoryKey? RepositoryKey { get; init; }
    public string CurrentStateContext { get; init; } = "";
    public string TargetStateContext { get; init; } = "";
    public OrderScenarioOperation Operation { get; init; }
    public ControlRepositoryAction RepositoryAction { get; init; }
    public string CurrentStateId { get; init; } = "";
    public string TargetStateId { get; init; } = "";
    public bool PhysicalAction { get; init; }
    public string VariableRef { get; init; } = "";
    public string KeyInput { get; init; } = "";
    public RuleExpectedOutcomeType ExpectedMode { get; init; } = RuleExpectedOutcomeType.Unspecified;
    public OrderCheckpointRequirement CheckpointRequirement { get; init; } = OrderCheckpointRequirement.NotApplicable;
    public int TimeoutMs { get; init; } = 5000;
    public OrderEvidenceKind[] EvidenceRequirements { get; init; } = [];
    public string[] FailureEvidence { get; init; } = ["screenshot", "uiTree"];
    public string RestorePolicyId { get; init; } = "";
    public ControlRiskClass RiskClass { get; init; } = ControlRiskClass.ObservationOnly;
    public bool ExecutionAllowed { get; init; }
    public bool ReadbackRequired { get; init; }
    public bool TransactionalAllowlisted { get; init; }
    public string OrderType { get; init; } = "";
}

public sealed record OrderScenarioDocument
{
    public string SchemaVersion { get; init; } = OrderScenarioAuthoringVersions.ScenarioSchema;
    public required string ScenarioId { get; init; }
    public required string CaseId { get; init; }
    public required string TargetProfileId { get; init; }
    public required string Screen { get; init; }
    public string Map { get; init; } = "";
    public OrderScenarioConfigurationStatus Status { get; init; } = OrderScenarioConfigurationStatus.ConfigurationRequired;
    public required string InitialStateContext { get; init; }
    public required string TargetStateContext { get; init; }
    public OrderScenarioVariable[] Variables { get; init; } = [];
    public OrderScenarioStep[] Steps { get; init; } = [];
    public OrderScenarioRestoreContract? Restore { get; init; }
}

public sealed record OrderScenarioRuntimeContext
{
    public string ActiveScreen { get; init; } = "";
    public string ActiveMap { get; init; } = "";
    public string ActiveStateContext { get; init; } = "";
    public string ProcessName { get; init; } = "";
    public string ProcessFingerprint { get; init; } = "";
    public string HostFingerprint { get; init; } = "";
    public int WindowWidth { get; init; }
    public int WindowHeight { get; init; }
    public int ClientWidth { get; init; }
    public int ClientHeight { get; init; }
    public double DpiScale { get; init; }
}

public sealed record OrderScenarioValidationInput
{
    public required OrderScenarioDocument Scenario { get; init; }
    public required ControlRepositoryDocument Repository { get; init; }
    public required StateGraph StateGraph { get; init; }
    public OrderScenarioRuntimeContext RuntimeContext { get; init; } = new();
    public bool TransactionalExecutionApproved { get; init; }
    public string[] TransactionalScenarioAllowlist { get; init; } = [];
    public EnvironmentFingerprintInput? CurrentEnvironment { get; init; }
    public ExecutionAuthorizationDocument? ExecutionAuthorization { get; init; }
    public ControlContractObservation[] ControlPreflightObservations { get; init; } = [];
    public DateTimeOffset AuthorizationCheckedAt { get; init; }
    public int RequestedCaseCount { get; init; } = 1;
    public decimal? RequestedQuantity { get; init; }
    public decimal? RequestedAmount { get; init; }
}

public sealed record OrderScenarioResolvedControl
{
    public required string StepId { get; init; }
    public required string RepositoryKey { get; init; }
    public LocatorTrustTier TrustTier { get; init; }
    public required string ApprovalHash { get; init; }
    public string ControlContractHash { get; init; } = "";
    public string LocatorSource { get; init; } = "";
}

public sealed record OrderScenarioValidationReport
{
    public string SchemaVersion { get; init; } = OrderScenarioAuthoringVersions.ValidationSchema;
    public required string ScenarioId { get; init; }
    public OrderScenarioValidationStatus Status { get; init; }
    public bool IsValid { get; init; }
    public ValidationIssue[] Issues { get; init; } = [];
    public OrderScenarioResolvedControl[] ResolvedControls { get; init; } = [];
    public ExecutionAuthorizationDecision? Authorization { get; init; }
}

public static class OrderScenarioValidator
{
    private static readonly HashSet<ControlRepositoryAction> TransactionalActions =
        [ControlRepositoryAction.FinalSubmit, ControlRepositoryAction.AmendSubmit, ControlRepositoryAction.CancelSubmit, ControlRepositoryAction.OpenConfirmation];
    private static readonly HashSet<OrderEvidenceKind> ProductEvidence =
        [OrderEvidenceKind.Value, OrderEvidenceKind.State, OrderEvidenceKind.Message, OrderEvidenceKind.Focus, OrderEvidenceKind.Popup,
         OrderEvidenceKind.Grid, OrderEvidenceKind.LogDelta, OrderEvidenceKind.TransmissionCount, OrderEvidenceKind.OrderReceipt];
    private static readonly HashSet<OrderScenarioOperation> ActionOperations =
        [OrderScenarioOperation.Focus, OrderScenarioOperation.Input, OrderScenarioOperation.Select, OrderScenarioOperation.Toggle,
         OrderScenarioOperation.Click, OrderScenarioOperation.DoubleClick, OrderScenarioOperation.Query, OrderScenarioOperation.PressKey];
    private static readonly HashSet<OrderScenarioOperation> CheckpointOperations =
        [OrderScenarioOperation.AssertValue, OrderScenarioOperation.AssertState, OrderScenarioOperation.AssertMessage,
         OrderScenarioOperation.AssertFocus, OrderScenarioOperation.AssertPopup, OrderScenarioOperation.AssertGrid,
         OrderScenarioOperation.AssertLogDelta, OrderScenarioOperation.AssertTransmissionCount, OrderScenarioOperation.AssertOrderReceipt];

    public static OrderScenarioValidationReport Validate(OrderScenarioValidationInput input)
    {
        var scenario = input.Scenario;
        var issues = new List<ValidationIssue>();
        var resolved = new List<OrderScenarioResolvedControl>();
        void Add(string code, string message, string remediation, string? stepId = null, string? field = null) =>
            issues.Add(new(code, message, stepId, field, Remediation: remediation));

        if (scenario.SchemaVersion != OrderScenarioAuthoringVersions.ScenarioSchema)
            Add("ORDER_SCENARIO.SCHEMA_VERSION", "Unsupported order scenario schema.", "Use schemaVersion 1.0.", field: "schemaVersion");
        if (string.IsNullOrWhiteSpace(scenario.ScenarioId) || string.IsNullOrWhiteSpace(scenario.CaseId) ||
            string.IsNullOrWhiteSpace(scenario.TargetProfileId) || string.IsNullOrWhiteSpace(scenario.Screen))
            Add("ORDER_SCENARIO.IDENTITY_REQUIRED", "scenarioId, caseId, targetProfileId and screen are required.", "Supply stable logical identities.");
        if (scenario.Status != OrderScenarioConfigurationStatus.Ready)
            Add("ORDER_SCENARIO.CONFIGURATION_REQUIRED", $"Scenario status is {scenario.Status}.", "Resolve every configuration/review item before compilation.");

        var repositoryIssues = ControlRepositoryValidator.Validate(input.Repository);
        foreach (var issue in repositoryIssues)
            Add("ORDER_SCENARIO.REPOSITORY_INVALID", $"{issue.Code}: {issue.Message}", "Repair and revalidate the Control Repository.");
        if (!input.Repository.TargetProfileId.Equals(scenario.TargetProfileId, StringComparison.Ordinal))
            Add("ORDER_SCENARIO.TARGET_PROFILE_MISMATCH", "Control Repository target profile differs from the scenario.", "Use the repository approved for this exact target profile.");
        if (!input.StateGraph.ScreenId.Equals(scenario.Screen, StringComparison.OrdinalIgnoreCase))
            Add("ORDER_SCENARIO.STATE_GRAPH_SCREEN_MISMATCH", "State Graph screen differs from the scenario.", "Use the validated State Graph for this exact screen.");

        ValidateStateAndRestore(input, issues);

        var duplicateStepIds = scenario.Steps.GroupBy(x => x.StepId, StringComparer.Ordinal).Where(x => x.Count() > 1);
        foreach (var duplicate in duplicateStepIds)
            Add("ORDER_SCENARIO.DUPLICATE_STEP", $"Duplicate stepId {duplicate.Key}.", "Use a unique stepId.", duplicate.Key);
        if (!scenario.Steps.Select(x => x.Sequence).SequenceEqual(scenario.Steps.Select(x => x.Sequence).Order()))
            Add("ORDER_SCENARIO.STEP_ORDER", "Steps must be stored in ascending sequence order.", "Sort and renumber scenario steps.");

        var requiredCheckpoints = scenario.Steps.Where(x => x.Role == OrderScenarioStepRole.Checkpoint && x.CheckpointRequirement == OrderCheckpointRequirement.Required).ToArray();
        if (requiredCheckpoints.Length == 0)
            Add("ORDER_SCENARIO.REQUIRED_CHECKPOINT_MISSING", "At least one required Checkpoint is mandatory.", "Add a required product-evidence Checkpoint.");
        if (!scenario.Steps.Any(x => x.Role == OrderScenarioStepRole.Restore))
            Add("ORDER_SCENARIO.RESTORE_STEP_MISSING", "A deterministic Restore step is required.", "Add a Restore step targeting the approved baseline.");

        var runtime = input.RuntimeContext;
        if (!runtime.ActiveScreen.Equals(scenario.Screen, StringComparison.OrdinalIgnoreCase) ||
            !runtime.ActiveMap.Equals(scenario.Map, StringComparison.OrdinalIgnoreCase) ||
            !runtime.ActiveStateContext.Equals(scenario.InitialStateContext, StringComparison.Ordinal))
            Add("ORDER_SCENARIO.ACTIVE_CONTEXT_MISMATCH", "Current screen/MAP/state does not match the scenario precondition.", "Recapture read-only preflight data in the intended initial state.");
        if (!scenario.Steps.Any(x => x.Role == OrderScenarioStepRole.Precondition))
            Add("ORDER_SCENARIO.PRECONDITION_MISSING", "At least one state/product Precondition is required.", "Add an observed precondition before any physical Action.");
        if (scenario.Steps.Any(x => x.Role == OrderScenarioStepRole.Restore && x.Sequence != scenario.Steps.Max(step => step.Sequence)))
            Add("ORDER_SCENARIO.RESTORE_ORDER", "Restore must be the final scenario step.", "Move deterministic restore to the end of the plan.");

        var duplicateVariables = scenario.Variables.GroupBy(x => x.Name, StringComparer.Ordinal).Where(x => x.Count() > 1).ToArray();
        foreach (var duplicate in duplicateVariables)
            Add("ORDER_SCENARIO.AMBIGUOUS_VARIABLE", $"Variable {duplicate.Key} is declared more than once.", "Keep one canonical variable declaration.", field: "variables");
        var variables = scenario.Variables.GroupBy(x => x.Name, StringComparer.Ordinal)
            .ToDictionary(x => x.Key, x => x.First(), StringComparer.Ordinal);
        foreach (var step in scenario.Steps)
        {
            ValidateStepShape(step, scenario, variables, issues);
            var entry = ResolveEntry(step, input.Repository, issues);
            if (entry is null) continue;
            ValidateEntryAndContext(step, scenario, entry, input, issues);
            resolved.Add(new()
            {
                StepId = step.StepId,
                RepositoryKey = entry.Key.Canonical,
                TrustTier = TrustTier(entry),
                ApprovalHash = entry.ApprovalPayloadHash,
                ControlContractHash = entry.ControlContractHash,
                LocatorSource = LocatorSource(entry)
            });
        }
        var authorization = AuthorizeExecution(input);
        foreach (var issue in authorization.Issues)
            issues.Add(new(issue.Code, issue.Message, Field: issue.Target, Remediation: issue.Remediation));


        var status = issues.Count == 0 ? OrderScenarioValidationStatus.Ready :
            scenario.Status == OrderScenarioConfigurationStatus.ConfigurationRequired ||
            input.Repository.Status == ControlRepositoryStatus.ConfigurationRequired ||
            input.StateGraph.ConfigurationStatus == StateGraphConfigurationStatus.ConfigurationRequired
            || authorization.Status is ExecutionAuthorizationStatus.ConfigurationRequired
                or ExecutionAuthorizationStatus.ControlApprovalRequired
                or ExecutionAuthorizationStatus.EnvironmentApprovalRequired
                ? OrderScenarioValidationStatus.ConfigurationRequired
                : scenario.Status == OrderScenarioConfigurationStatus.ReviewRequired ||
                  input.Repository.Entries.Any(x => x.Status is ControlRepositoryEntryStatus.ReviewRequired or ControlRepositoryEntryStatus.Draft)
                    ? OrderScenarioValidationStatus.ReviewRequired
                    : OrderScenarioValidationStatus.Blocked;
        return new()
        {
            ScenarioId = scenario.ScenarioId,
            Status = status,
            IsValid = issues.Count == 0,
            Issues = issues.ToArray(),
            ResolvedControls = resolved.ToArray(),
            Authorization = authorization
        };
    }

    private static ExecutionAuthorizationDecision AuthorizeExecution(OrderScenarioValidationInput input)
    {
        if (input.CurrentEnvironment is null || input.AuthorizationCheckedAt == default)
            return new()
            {
                Status = ExecutionAuthorizationStatus.ConfigurationRequired,
                Issues = [new()
                {
                    Code = "AUTH.CONFIGURATION_REQUIRED",
                    Message = "Current environment fingerprint and authorization check time are required.",
                    Remediation = "Supply classified, redacted environment inputs and a deterministic check time."
                }],
                ActualActionCallCount = 0
            };
        var requirements = input.Scenario.Steps.Where(step => step.RepositoryKey is not null).Select(step =>
        {
            var key = step.RepositoryKey!.Canonical;
            var entry = input.Repository.Entries.FirstOrDefault(candidate => candidate.Key.Canonical.Equals(key, StringComparison.Ordinal));
            var transactional = TransactionalActions.Contains(step.RepositoryAction) || step.RiskClass == ControlRiskClass.Transactional ||
                step.Operation == OrderScenarioOperation.PressKey && step.KeyInput.Equals("ENTER", StringComparison.OrdinalIgnoreCase);
            return new ExecutionControlRequirement
            {
                RepositoryKey = key,
                ControlContractHash = entry?.ControlContractHash ?? "",
                Action = step.RepositoryAction,
                RiskClass = step.RiskClass,
                PhysicalAction = step.PhysicalAction,
                TransactionalAction = transactional,
                OrderType = step.OrderType
            };
        }).ToArray();
        return new ExecutionAuthorizationService().Authorize(new()
        {
            CurrentEnvironment = input.CurrentEnvironment,
            Authorization = input.ExecutionAuthorization,
            Repository = input.Repository,
            Requirements = requirements,
            ControlObservations = input.ControlPreflightObservations,
            RequestedCaseCount = input.RequestedCaseCount,
            RequestedQuantity = input.RequestedQuantity,
            RequestedAmount = input.RequestedAmount
        }, input.AuthorizationCheckedAt);
    }

    private static void ValidateStateAndRestore(OrderScenarioValidationInput input, List<ValidationIssue> issues)
    {
        void Add(string code, string message, string remediation) => issues.Add(new(code, message, Remediation: remediation));
        var graphIssues = StateGraphValidator.Validate(input.StateGraph);
        if (input.StateGraph.ConfigurationStatus != StateGraphConfigurationStatus.Ready || graphIssues.Count > 0)
            Add("ORDER_SCENARIO.STATE_GRAPH_NOT_READY", "The State Graph is not a validated Ready graph.", "Configure approved transitions, arrival Checkpoints, baseline and restore evidence.");
        var restore = input.Scenario.Restore;
        if (restore is null || !restore.Required || string.IsNullOrWhiteSpace(restore.PolicyId) || string.IsNullOrWhiteSpace(restore.BaselineStateId))
            Add("ORDER_SCENARIO.RESTORE_POLICY_MISSING", "Scenario baseline/restore policy is missing.", "Reference a deterministic approved restore policy.");
        else if (!restore.BaselineStateId.Equals(input.StateGraph.BaselineStateId, StringComparison.Ordinal) ||
                 input.StateGraph.RestorePolicy.Mode != StateRestoreMode.Deterministic)
            Add("ORDER_SCENARIO.RESTORE_POLICY_MISMATCH", "Scenario restore policy does not match the deterministic State Graph baseline.", "Use the validated State Graph baseline and restore policy.");
    }

    private static void ValidateStepShape(OrderScenarioStep step, OrderScenarioDocument scenario,
        IReadOnlyDictionary<string, OrderScenarioVariable> variables, List<ValidationIssue> issues)
    {
        void Add(string code, string message, string remediation, string? field = null) =>
            issues.Add(new(code, message, step.StepId, field, Remediation: remediation));
        if (string.IsNullOrWhiteSpace(step.StepId) || step.Sequence <= 0)
            Add("ORDER_SCENARIO.STEP_IDENTITY", "stepId and positive sequence are required.", "Assign a stable stepId and sequence.");
        if (step.RepositoryKey is null)
            Add("ORDER_SCENARIO.REPOSITORY_KEY_REQUIRED", "Every authored step must reference a repository key.", "Select an approved screen|map|logicalName|stateContext key.");
        if (step.RepositoryKey is { } key &&
            (!key.Screen.Equals(scenario.Screen, StringComparison.OrdinalIgnoreCase) || !key.Map.Equals(scenario.Map, StringComparison.OrdinalIgnoreCase)))
            Add("ORDER_SCENARIO.SCREEN_MAP_MISMATCH", "Repository key screen/MAP differs from the scenario.", "Use a key for the authored scenario screen and MAP.");
        if (step.RepositoryKey is { } stateKey && !stateKey.StateContext.Equals(step.CurrentStateContext, StringComparison.Ordinal))
            Add("ORDER_SCENARIO.STATE_CONTEXT_MISMATCH", "Repository key stateContext differs from the step current state.", "Use the exact approved stateContext.");
        if (!OperationMatchesRole(step))
            Add("ORDER_SCENARIO.ROLE_OPERATION_MISMATCH", "Operation is not valid for the declared step role.", "Use ObserveState for Precondition, Transition for Transition, an Action operation, an Assert operation, or Restore respectively.");
        if (step.TimeoutMs <= 0)
            Add("ORDER_SCENARIO.TIMEOUT_REQUIRED", "A positive timeout is required.", "Set an evidence-backed timeout.");
        if (!step.FailureEvidence.Contains("screenshot", StringComparer.OrdinalIgnoreCase) ||
            !step.FailureEvidence.Contains("uiTree", StringComparer.OrdinalIgnoreCase))
            Add("ORDER_SCENARIO.FAILURE_EVIDENCE_REQUIRED", "Failure evidence must include screenshot and UI tree references.", "Request redacted screenshot and UI tree references without sensitive content.");
        if (!step.ExecutionAllowed)
            Add("ORDER_SCENARIO.STEP_EXECUTION_NOT_ALLOWED", "The step is not approved for execution.", "Complete review and explicitly allow this non-prohibited step.");
        if (string.IsNullOrWhiteSpace(step.CurrentStateId) || string.IsNullOrWhiteSpace(step.CurrentStateContext))
            Add("ORDER_SCENARIO.STATE_REQUIRED", "Current state id and stateContext are required.", "Reference an observed State Graph state and its exact stateContext.");
        if (!string.IsNullOrWhiteSpace(step.VariableRef) && !variables.ContainsKey(step.VariableRef))
            Add("ORDER_SCENARIO.VARIABLE_NOT_FOUND", "The input variable reference does not exist.", "Declare the variable or correct valueRef.");
        if (!string.IsNullOrWhiteSpace(step.VariableRef) && variables.TryGetValue(step.VariableRef, out var variable) && variable.Sensitive && step.ReadbackRequired)
            Add("ORDER_SCENARIO.SENSITIVE_READBACK_FORBIDDEN", "Sensitive input cannot require readback.", "Use an approved masked/state/message Checkpoint without recording the value.");

        if (step.Role == OrderScenarioStepRole.Checkpoint)
        {
            if (step.PhysicalAction)
                Add("ORDER_SCENARIO.CHECKPOINT_PHYSICAL_ACTION", "Checkpoint cannot be a physical action.", "Separate the Action from the product observation.");
            if (step.ReadbackRequired && step.Operation != OrderScenarioOperation.AssertValue)
                Add("ORDER_SCENARIO.READBACK_OPERATION_MISMATCH", "Readback is only valid for an AssertValue Checkpoint.", "Use an observation-specific Checkpoint without reading an input value.");
            if (step.CheckpointRequirement == OrderCheckpointRequirement.NotApplicable)
                Add("ORDER_SCENARIO.CHECKPOINT_REQUIREMENT", "Checkpoint must be Required or Optional.", "Declare checkpoint requirement explicitly.");
            if (!step.EvidenceRequirements.Any(ProductEvidence.Contains))
                Add("ORDER_SCENARIO.ACTION_DELIVERY_ONLY_CHECKPOINT", "Checkpoint does not require independent product evidence.", "Require value/state/message/focus/popup/grid/log/transmission/receipt evidence.");
            if (step.CheckpointRequirement == OrderCheckpointRequirement.Required &&
                step.ExpectedMode is RuleExpectedOutcomeType.ObservationOnly or RuleExpectedOutcomeType.Unspecified)
                Add("ORDER_SCENARIO.NON_VERDICT_EXPECTATION", "ObservationOnly or Unspecified cannot support PASS.", "Use an approved structured expected mode or keep the scenario non-executable.");
        }
        else if (step.CheckpointRequirement != OrderCheckpointRequirement.NotApplicable)
            Add("ORDER_SCENARIO.NON_CHECKPOINT_REQUIREMENT", "Only Checkpoint steps can be Required or Optional.", "Move verdict evidence into a Checkpoint step.");

        if (step.Role == OrderScenarioStepRole.Restore && (scenario.Restore is null || !step.RestorePolicyId.Equals(scenario.Restore.PolicyId, StringComparison.Ordinal)))
            Add("ORDER_SCENARIO.RESTORE_REFERENCE_MISMATCH", "Restore step does not reference the scenario restore policy.", "Use the declared restore policy id.");
    }

    private static bool OperationMatchesRole(OrderScenarioStep step) => step.Role switch
    {
        OrderScenarioStepRole.Precondition => step.Operation is OrderScenarioOperation.ObserveState or OrderScenarioOperation.Query,
        OrderScenarioStepRole.Transition => step.Operation == OrderScenarioOperation.Transition,
        OrderScenarioStepRole.Action => ActionOperations.Contains(step.Operation),
        OrderScenarioStepRole.Checkpoint => CheckpointOperations.Contains(step.Operation),
        OrderScenarioStepRole.Restore => step.Operation == OrderScenarioOperation.Restore,
        _ => false
    };

    private static ControlRepositoryEntry? ResolveEntry(OrderScenarioStep step, ControlRepositoryDocument repository, List<ValidationIssue> issues)
    {
        if (step.RepositoryKey is null) return null;
        var matches = repository.Entries.Where(x => x.Key.Canonical.Equals(step.RepositoryKey.Canonical, StringComparison.Ordinal)).ToArray();
        if (matches.Length == 0)
        {
            issues.Add(new("ORDER_SCENARIO.REPOSITORY_KEY_NOT_FOUND", "Repository key is not registered.", step.StepId,
                Remediation: "Capture, review, approve and explicitly register the control first."));
            return null;
        }
        if (matches.Length > 1)
        {
            issues.Add(new("ORDER_SCENARIO.AMBIGUOUS_LOGICAL_KEY", "Repository key resolves to multiple entries.", step.StepId,
                Remediation: "Resolve the duplicate logical key without automatic selection."));
            return null;
        }
        return matches[0];
    }

    private static void ValidateEntryAndContext(OrderScenarioStep step, OrderScenarioDocument scenario, ControlRepositoryEntry entry,
        OrderScenarioValidationInput input, List<ValidationIssue> issues)
    {
        void Add(string code, string message, string remediation) => issues.Add(new(code, message, step.StepId, Remediation: remediation));
        if (entry.Status != ControlRepositoryEntryStatus.Approved || entry.Approval.Status != TestPackApprovalStatus.Approved)
            Add("ORDER_SCENARIO.REPOSITORY_ENTRY_NOT_APPROVED", $"Repository entry status is {entry.Status}.", "Complete human approval before authoring an executable scenario.");
        var expectedHash = ControlContractHasher.ComputeApprovalHash(entry);
        if (!entry.ApprovalPayloadHash.Equals(expectedHash, StringComparison.OrdinalIgnoreCase) ||
            !entry.Approval.ApprovedContentHash.Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
            Add("ORDER_SCENARIO.APPROVAL_HASH_MISMATCH", "Canonical repository approval hash does not match.", "Review and approve the unchanged canonical payload again.");
        if (!entry.AllowedActions.Contains(step.RepositoryAction) || entry.ForbiddenActions.Contains(step.RepositoryAction))
            Add("ORDER_SCENARIO.ACTION_POLICY_CONFLICT", "Requested action is forbidden or not allowlisted by the repository entry.", "Select an allowed action or obtain a new explicit approval.");
        if (entry.RiskClass != step.RiskClass)
            Add("ORDER_SCENARIO.RISK_CLASS_MISMATCH", "Scenario and repository risk classes differ.", "Use the approved repository risk class.");

        var runtime = input.RuntimeContext;
        var host = entry.HostFingerprint;
        if (host is null || string.IsNullOrWhiteSpace(runtime.ProcessName) || runtime.WindowWidth <= 0 || runtime.WindowHeight <= 0 ||
            runtime.ClientWidth <= 0 || runtime.ClientHeight <= 0 || runtime.DpiScale <= 0)
            Add("ORDER_SCENARIO.PREFLIGHT_REQUIRED", "Current process, fingerprint, bounds and DPI preflight evidence is required.", "Capture read-only preflight evidence immediately before compilation.");
        else if (!host.ProcessName.Equals(runtime.ProcessName, StringComparison.OrdinalIgnoreCase) ||
                 !host.ProcessFingerprint.Equals(runtime.ProcessFingerprint, StringComparison.Ordinal) ||
                 !host.HostFingerprint.Equals(runtime.HostFingerprint, StringComparison.Ordinal))
            Add("ORDER_SCENARIO.RUNTIME_DRIFT", "Current process or host fingerprint differs from approval evidence.", "Stop and recapture/review; never self-heal the repository.");

        var tier = TrustTier(entry);
        var transactional = TransactionalActions.Contains(step.RepositoryAction) || entry.RiskClass == ControlRiskClass.Transactional ||
            step.Operation == OrderScenarioOperation.PressKey && step.KeyInput.Equals("ENTER", StringComparison.OrdinalIgnoreCase);
        var states = input.StateGraph.States.Where(x => x.StateId.Equals(step.CurrentStateId, StringComparison.Ordinal)).Take(2).ToArray();
        if (states.Length != 1 || !states[0].StateContextId.Equals(step.CurrentStateContext, StringComparison.Ordinal))
            Add("ORDER_SCENARIO.STATE_IDENTITY_MISMATCH", "Step state id/stateContext is not declared by the State Graph.", "Use the exact approved State Graph state identity.");
        if (step.Role == OrderScenarioStepRole.Restore && input.Scenario.Restore is { } restore &&
            !step.TargetStateId.Equals(restore.BaselineStateId, StringComparison.Ordinal))
            Add("ORDER_SCENARIO.RESTORE_TARGET_MISMATCH", "Restore step does not target the approved baseline state.", "Target the State Graph baseline state.");

        if (step.PhysicalAction && tier == LocatorTrustTier.VisualObservationOnly)
            Add("ORDER_SCENARIO.IMAGE_ONLY_PHYSICAL_ACTION", "Image/visual-only locator cannot perform a physical action.", "Use it only for observation or obtain a stronger approved locator.");
        if (transactional && tier == LocatorTrustTier.ApprovedAnchoredRelative)
            Add("ORDER_SCENARIO.COORDINATE_TRANSACTION_FORBIDDEN", "Transactional action cannot use a relative coordinate.", "Use a verified stable UIA/native identity and separate approval.");
        if (transactional && tier != LocatorTrustTier.StableIdentity)
            Add("ORDER_SCENARIO.TRANSACTION_STABLE_IDENTITY_REQUIRED", "Transactional action requires a verified stable UIA/native locator.", "Approve a stable identity; MAP, coordinate and visual-only locators are insufficient.");

        if (step.Role == OrderScenarioStepRole.Transition)
        {
            var transitions = input.StateGraph.Transitions.Where(x =>
                x.SourceStateId.Equals(step.CurrentStateId, StringComparison.Ordinal) &&
                x.TargetStateId.Equals(step.TargetStateId, StringComparison.Ordinal)).Take(2).ToArray();
            if (transitions.Length != 1)
                Add("ORDER_SCENARIO.TRANSITION_NOT_FOUND", "No approved State Graph transition matches this step.", "Configure and approve the transition and arrival Checkpoint first.");
        }
    }

    internal static LocatorTrustTier TrustTier(ControlRepositoryEntry entry) => ControlContractHasher.TrustTier(entry);

    internal static string LocatorSource(ControlRepositoryEntry entry) => TrustTier(entry) switch
    {
        LocatorTrustTier.StableIdentity => "StableIdentity",
        LocatorTrustTier.MapRuntimeBinding => "MapRuntimeBinding",
        LocatorTrustTier.ApprovedAnchoredRelative => "AnchoredRelativeCoordinate",
        LocatorTrustTier.VisualObservationOnly => "VisualSignature",
        _ => "Unresolved"
    };
}

public sealed record OrderScenarioRunPlanStep
{
    public required string StepId { get; init; }
    public int Sequence { get; init; }
    public required string RepositoryKey { get; init; }
    public LocatorTrustTier ResolvedLocatorTier { get; init; }
    public required string ApprovalHash { get; init; }
    public string ControlContractHash { get; init; } = "";
    public OrderScenarioStepRole Role { get; init; }
    public OrderScenarioOperation Operation { get; init; }
    public ControlRepositoryAction RepositoryAction { get; init; }
    public string CurrentStateContext { get; init; } = "";
    public string TargetStateContext { get; init; } = "";
    public string CurrentStateId { get; init; } = "";
    public string TargetStateId { get; init; } = "";
    public string VariableRef { get; init; } = "";
    public RuleExpectedOutcomeType ExpectedMode { get; init; }
    public OrderCheckpointRequirement CheckpointRequirement { get; init; }
    public bool AffectsVerdict { get; init; }
    public bool RequiredForPass { get; init; }
    public int TimeoutMs { get; init; }
    public ControlRiskClass RiskClass { get; init; }
    public bool ApprovedForSeparateExecution { get; init; }
    public string OrderType { get; init; } = "";
}

public sealed record OrderScenarioRunPlanVariable
{
    public required string Name { get; init; }
    public bool Sensitive { get; init; }
    public bool Required { get; init; }
}

public sealed record OrderScenarioRunPlan
{
    public string SchemaVersion { get; init; } = OrderScenarioAuthoringVersions.RunPlanSchema;
    public string CompilerVersion { get; init; } = OrderScenarioAuthoringVersions.Compiler;
    public required string PlanId { get; init; }
    public required string PlanHash { get; init; }
    public required string ScenarioId { get; init; }
    public required string CaseId { get; init; }
    public required string RepositoryId { get; init; }
    public required string StateGraphId { get; init; }
    public DateTimeOffset CompiledAt { get; init; }
    public OrderRunPlanExecutionMode ExecutionMode { get; init; } = OrderRunPlanExecutionMode.DryRun;
    public bool ActualExecutionAllowed { get; init; }
    public ExecutionAuthorizationStatus AuthorizationStatus { get; init; } = ExecutionAuthorizationStatus.ConfigurationRequired;
    public string EnvironmentFingerprintHash { get; init; } = "";
    public string ExecutionAuthorizationHash { get; init; } = "";
    public OrderScenarioRunPlanVariable[] Variables { get; init; } = [];
    public OrderScenarioRunPlanStep[] Steps { get; init; } = [];
    public string[] RestoreSequence { get; init; } = [];
    public string ResultSchema { get; init; } = "test-results.json/canonical-verdict";
    public string EvidenceSchema { get; init; } = "action-delivery-and-checkpoint-evidence";
}

public sealed record OrderScenarioCompileResult
{
    public required OrderScenarioValidationReport Validation { get; init; }
    public OrderScenarioRunPlan? Plan { get; init; }
}

public static class OrderScenarioRunPlanCompiler
{
    public static OrderScenarioCompileResult Compile(OrderScenarioValidationInput input, DateTimeOffset compiledAt)
    {
        var validation = OrderScenarioValidator.Validate(input);
        if (!validation.IsValid) return new() { Validation = validation };
        var resolved = validation.ResolvedControls.ToDictionary(x => x.StepId, StringComparer.Ordinal);
        var draft = new OrderScenarioRunPlan
        {
            PlanId = "",
            PlanHash = "",
            ScenarioId = input.Scenario.ScenarioId,
            CaseId = input.Scenario.CaseId,
            RepositoryId = input.Repository.RepositoryId,
            StateGraphId = input.StateGraph.GraphId,
            CompiledAt = compiledAt,
            ActualExecutionAllowed = false,
            AuthorizationStatus = validation.Authorization!.Status,
            EnvironmentFingerprintHash = validation.Authorization.EnvironmentFingerprintHash,
            ExecutionAuthorizationHash = validation.Authorization.ExecutionAuthorizationHash,
            Variables = input.Scenario.Variables.Select(variable => new OrderScenarioRunPlanVariable
            {
                Name = variable.Name,
                Sensitive = variable.Sensitive,
                Required = variable.Required
            }).ToArray(),
            Steps = input.Scenario.Steps.Select(step => new OrderScenarioRunPlanStep
            {
                StepId = step.StepId,
                Sequence = step.Sequence,
                RepositoryKey = step.RepositoryKey!.Canonical,
                ResolvedLocatorTier = resolved[step.StepId].TrustTier,
                ApprovalHash = resolved[step.StepId].ApprovalHash,
                ControlContractHash = resolved[step.StepId].ControlContractHash,
                Role = step.Role,
                Operation = step.Operation,
                RepositoryAction = step.RepositoryAction,
                CurrentStateContext = step.CurrentStateContext,
                CurrentStateId = step.CurrentStateId,
                TargetStateId = step.TargetStateId,
                TargetStateContext = step.TargetStateContext,
                VariableRef = step.VariableRef,
                ExpectedMode = step.ExpectedMode,
                CheckpointRequirement = step.CheckpointRequirement,
                AffectsVerdict = step.Role == OrderScenarioStepRole.Checkpoint,
                RequiredForPass = step.Role == OrderScenarioStepRole.Checkpoint && step.CheckpointRequirement == OrderCheckpointRequirement.Required,
                TimeoutMs = step.TimeoutMs,
                RiskClass = step.RiskClass,
                ApprovedForSeparateExecution = step.ExecutionAllowed,
                OrderType = step.OrderType
            }).ToArray(),
            RestoreSequence = input.Scenario.Steps.Where(x => x.Role == OrderScenarioStepRole.Restore).OrderBy(x => x.Sequence).Select(x => x.StepId).ToArray()
        };
        var hash = ComputeHash(draft);
        return new() { Validation = validation, Plan = draft with { PlanId = $"order-plan-{hash[..16]}", PlanHash = hash } };
    }

    public static string ComputeHash(OrderScenarioRunPlan plan) => CanonicalJson.Sha256(plan with { PlanId = "", PlanHash = "" });
}

public sealed record OrderScenarioDryRunResult
{
    public string SchemaVersion { get; init; } = OrderScenarioAuthoringVersions.DryRunSchema;
    public required string PlanId { get; init; }
    public TestStatus Status { get; init; } = TestStatus.PENDING;
    public bool PlanHashValid { get; init; }
    public bool RepositoryResolutionChecked { get; init; }
    public bool StateOrderChecked { get; init; }
    public bool RequiredCheckpointChecked { get; init; }
    public bool ExpectedOutcomeChecked { get; init; }
    public bool VariableBindingChecked { get; init; }
    public bool RiskPolicyChecked { get; init; }
    public bool AuthorizationChecked { get; init; }
    public bool RestorePlanChecked { get; init; }
    public bool ResultAndEvidenceSchemaChecked { get; init; }
    public int ActualUiActionCount { get; init; }
    public int TransactionalActionCount { get; init; }
    public string Reason { get; init; } = "DryRun validates an immutable plan but does not execute or determine PASS.";
}

public static class OrderScenarioDryRun
{
    public static OrderScenarioDryRunResult Execute(OrderScenarioRunPlan plan)
    {
        var hashValid = plan.PlanHash.Equals(OrderScenarioRunPlanCompiler.ComputeHash(plan), StringComparison.OrdinalIgnoreCase);
        return new()
        {
            PlanId = plan.PlanId,
            PlanHashValid = hashValid,
            RepositoryResolutionChecked = plan.Steps.All(x => x.ResolvedLocatorTier != LocatorTrustTier.Unresolved && !string.IsNullOrWhiteSpace(x.ApprovalHash) && !string.IsNullOrWhiteSpace(x.ControlContractHash)),
            StateOrderChecked = StateOrderValid(plan.Steps),
            RequiredCheckpointChecked = plan.Steps.Any(x => x.Role == OrderScenarioStepRole.Checkpoint && x.CheckpointRequirement == OrderCheckpointRequirement.Required),
            ExpectedOutcomeChecked = plan.Steps.Where(x => x.RequiredForPass)
                .All(x => x.ExpectedMode is not RuleExpectedOutcomeType.Unspecified and not RuleExpectedOutcomeType.ObservationOnly),
            VariableBindingChecked = plan.Steps.Where(x => !string.IsNullOrWhiteSpace(x.VariableRef))
                .All(step => plan.Variables.Count(variable => variable.Name.Equals(step.VariableRef, StringComparison.Ordinal)) == 1),
            RiskPolicyChecked = !plan.ActualExecutionAllowed && plan.ExecutionMode == OrderRunPlanExecutionMode.DryRun && plan.AuthorizationStatus == ExecutionAuthorizationStatus.Authorized,
            AuthorizationChecked = plan.AuthorizationStatus == ExecutionAuthorizationStatus.Authorized && !string.IsNullOrWhiteSpace(plan.EnvironmentFingerprintHash) && !string.IsNullOrWhiteSpace(plan.ExecutionAuthorizationHash),
            RestorePlanChecked = plan.RestoreSequence.Length > 0,
            ResultAndEvidenceSchemaChecked = !string.IsNullOrWhiteSpace(plan.ResultSchema) && !string.IsNullOrWhiteSpace(plan.EvidenceSchema),
            ActualUiActionCount = 0,
            TransactionalActionCount = 0
        };
    }

    private static bool StateOrderValid(OrderScenarioRunPlanStep[] steps)
    {
        var ordered = steps.OrderBy(x => x.Sequence).ToArray();
        if (!steps.SequenceEqual(ordered)) return false;
        for (var index = 0; index < ordered.Length; index++)
        {
            if (ordered[index].Role != OrderScenarioStepRole.Transition) continue;
            if (index + 1 >= ordered.Length || !ordered[index + 1].CurrentStateId.Equals(ordered[index].TargetStateId, StringComparison.Ordinal)) return false;
        }
        return true;
    }
}

public sealed record OrderScenarioTemplate
{
    public string SchemaVersion { get; init; } = OrderScenarioAuthoringVersions.ScenarioSchema;
    public required string TemplateId { get; init; }
    public required string DisplayName { get; init; }
    public OrderScenarioConfigurationStatus Status { get; init; } = OrderScenarioConfigurationStatus.ConfigurationRequired;
    public required string Screen { get; init; }
    public required string CandidateStateContext { get; init; }
    public string[] RequiredLogicalControlRoles { get; init; } = [];
    public string[] RequiredPreconditions { get; init; } = [];
    public string[] InputActionRoles { get; init; } = [];
    public string[] RequiredCheckpointRoles { get; init; } = [];
    public string[] OptionalCheckpointRoles { get; init; } = [];
    public string ValidationRequiredExample { get; init; } = "";
    public string[] RestoreRequirements { get; init; } = [];
    public string[] UnconfirmedItems { get; init; } = [];
    public string[] RequiredFieldEvidence { get; init; } = [];
    public ControlRepositoryKey[] RepositoryKeys { get; init; } = [];
    public bool Executable { get; init; }
}
