// 역할: 승인된 생성 시나리오에서 만들어지는 compiled logical plan 계약을 정의한다.
// 경계: source validation과 runtime UI binding을 수행하지 않는다.

namespace HtsQa.Core;

public enum ScenarioReadiness
{
    ReadyForBinding,
    PendingBinding,
    PendingApproval,
    ManualReview,
    Rejected,
    Invalid
}

public sealed record CompiledScenarioPlan
{
    public string SchemaVersion { get; init; } = ScenarioPlanVersions.CompiledSchema;
    public string CompilerVersion { get; init; } = ScenarioPlanVersions.Compiler;
    public required string PlanId { get; init; }
    public required string PlanHash { get; init; }
    public required string SourceSha256 { get; init; }
    public required string SourceInstallationFingerprint { get; init; }
    public required string DatasetId { get; init; }
    public required string DatasetSha256 { get; init; }
    public string ScenarioGenerationMode { get; init; } = "External";
    public string ScenarioGenerator { get; init; } = "";
    public string ScenarioGeneratorVersion { get; init; } = "";
    public bool RuntimeDiscoveryUsed { get; init; }
    public string? ApprovalSha256 { get; init; }
    public string ApprovalStatus { get; init; } = "NotProvided";
    public string? ApprovedBy { get; init; }
    public DateTimeOffset? ApprovedAt { get; init; }
    public int ReviewDecisionCount { get; init; }
    public int ScenarioDecisionCount { get; init; }
    public int CoverageGapDecisionCount { get; init; }
    public required string Status { get; init; }
    public DateTimeOffset GeneratedAt { get; init; }
    public int ScreenCount { get; init; }
    public int ScenarioCount { get; init; }
    public int CaseCount { get; init; }
    public int StepCount { get; init; }
    public int ReadyScenarioCount { get; init; }
    public int PendingApprovalScenarioCount { get; init; }
    public int PendingBindingScenarioCount { get; init; }
    public int ManualReviewScenarioCount { get; init; }
    public int UnusedVariableCount { get; init; }
    public ValidationIssue[] Issues { get; init; } = [];
    public CompiledScreenPlan[] Screens { get; init; } = [];
    public CompiledScenarioCase[] Cases { get; init; } = [];
}

public sealed record CompiledScreenPlan
{
    public required string ScreenNumber { get; init; }
    public required string ScreenName { get; init; }
    public CompiledScenarioDefinition[] Scenarios { get; init; } = [];
    public ScenarioBindingRequirement[] BindingRequirements { get; init; } = [];
    public string[] CoverageGaps { get; init; } = [];
}

public sealed record CompiledScenarioDefinition
{
    public required string ScenarioId { get; init; }
    public string SourceTestCaseId { get; init; } = "";
    public string MapScreenCode { get; init; } = "";
    public bool Transactional { get; init; }
    public string ExpectedResult { get; init; } = "";
    public required string Title { get; init; }
    public required string Priority { get; init; }
    public required string Category { get; init; }
    public required ScenarioReadiness Readiness { get; init; }
    public string[] BlockingReasons { get; init; } = [];
    public string[] RequiredReviewIds { get; init; } = [];
    public string[] CoveredControls { get; init; } = [];
    public string[] CoveredValidationRuleIds { get; init; } = [];
    public int CaseCount { get; init; }
    public int StepCount { get; init; }
}

public sealed record ScenarioBindingRequirement
{
    public required string LogicalName { get; init; }
    public string MapScreenCode { get; init; } = "";
    public string StateContext { get; init; } = "";
    public string BindingKey { get; init; } = "";
    public string ControlRepositoryKey { get; init; } = "";
    public string TargetRole { get; init; } = "Input";
    public RuleControlKind ControlKind { get; init; } = RuleControlKind.Auto;
    public bool Required { get; init; } = true;
    public string[] ScenarioIds { get; init; } = [];
    public string RecommendedEvidence { get; init; } = "";
}

public sealed record CompiledScenarioCase
{
    public required string CaseId { get; init; }
    public required string ScenarioId { get; init; }
    public string SourceTestCaseId { get; init; } = "";
    public string MapScreenCode { get; init; } = "";
    public bool Transactional { get; init; }
    public string ExpectedResult { get; init; } = "";
    public string ExecutionOrder { get; init; } = RuleInteractionStrategies.RuntimeTabOrder;
    public required string ScenarioTitle { get; init; }
    public required string Priority { get; init; }
    public required string Category { get; init; }
    public required string ScreenNumber { get; init; }
    public required string ScreenName { get; init; }
    public required string AccountId { get; init; }
    public required ScenarioReadiness Readiness { get; init; }
    public string[] BlockingReasons { get; init; } = [];
    public Dictionary<string, CompiledScenarioValue> Values { get; init; } = [];
    public CompiledScenarioStep[] Steps { get; init; } = [];
}

public sealed record CompiledScenarioValue
{
    public required string VariableName { get; init; }
    public required string ValueId { get; init; }
    public required string Value { get; init; }
    public string DisplayValue { get; init; } = "";
    public required string TargetLogicalName { get; init; }
    public string TargetRole { get; init; } = "Input";
    public RuleControlKind ControlKind { get; init; } = RuleControlKind.Auto;
    public RuleValueMatch ValueMatch { get; init; } = RuleValueMatch.Value;
    public bool TriggerQueryAfterChange { get; init; }
    public RuleExpectedOutcome ExpectedOutcome { get; init; } = new();
    public string Rationale { get; init; } = "";
    public string[] SourceRefs { get; init; } = [];
}

public sealed record CompiledScenarioStep
{
    public required string StepId { get; init; }
    public int Sequence { get; init; }
    public required string Action { get; init; }
    public string? ControlLogicalName { get; init; }
    public string MapScreenCode { get; init; } = "";
    public string StateContext { get; init; } = "";
    public string ControlRepositoryKey { get; init; } = "";
    public bool Transactional { get; init; }
    public string? ValueRef { get; init; }
    public CompiledScenarioValue? SelectedValue { get; init; }
    public string ExpectedObservation { get; init; } = "";
    public bool? CheckpointRequired { get; init; }
    public string ExecutionPhase { get; init; } = "Action";
    public bool RuntimeTabOrderEligible { get; init; }
}

public sealed record ScenarioImportManifest
{
    public required string GenerationId { get; init; }
    public required string SourceFileName { get; init; }
    public required string SourceSha256 { get; init; }
    public required string SourceInstallationFingerprint { get; init; }
    public required string DatasetId { get; init; }
    public required string DatasetSha256 { get; init; }
    public required string ValidationStatus { get; init; }
    public DateTimeOffset ImportedAt { get; init; }
}

// 런타임 바인딩과 물리 실행계획 계약 -------------------------------------------
