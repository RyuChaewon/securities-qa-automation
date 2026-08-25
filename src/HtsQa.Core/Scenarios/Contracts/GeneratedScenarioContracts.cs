// 역할: 생성 시나리오, dataset patch, 검토 및 승인 오버레이 계약을 정의한다.
// 경계: 검증, 컴파일, 런타임 binding을 수행하지 않는다.

namespace HtsQa.Core;

public static class ScenarioPlanVersions
{
    public const string SourceSchema = "1.0";
    public const string ApprovalSchema = "1.0";
    public const string CompiledSchema = "1.0";
    public const string Compiler = "1.1.0";
}

public sealed record GeneratedScenarioDocument
{
    public required string PackageVersion { get; init; }
    public required string SourceInstallationFingerprint { get; init; }
    public GeneratedScenarioSummary GenerationSummary { get; init; } = new();
    public GeneratedScreenScenario[] Screens { get; init; } = [];
    public GeneratedDatasetPatch DatasetPatch { get; init; } = new();
    public GeneratedReviewItem[] ReviewItems { get; init; } = [];
}

public sealed record GeneratedScenarioSummary
{
    public string? ReferenceDate { get; init; }
    public string CombinationStrategy { get; init; } = "Mixed";
    public string GenerationMode { get; init; } = "External";
    public string Generator { get; init; } = "";
    public string GeneratorVersion { get; init; } = "";
    public bool RuntimeDiscoveryUsed { get; init; }
    public string MapCatalogSha256 { get; init; } = "";
    public string RuntimeControlPlanSha256 { get; init; } = "";
    public string[] Assumptions { get; init; } = [];
}

public sealed record GeneratedScreenScenario
{
    public required string ScreenNumber { get; init; }
    public required string ScreenName { get; init; }
    public GeneratedScenario[] Scenarios { get; init; } = [];
    public string[] CoverageGaps { get; init; } = [];
}

public sealed record GeneratedScenario
{
    public required string ScenarioId { get; init; }
    public string SourceTestCaseId { get; init; } = "";
    public string MapScreenCode { get; init; } = "";
    public bool Transactional { get; init; }
    public required string Title { get; init; }
    public string Objective { get; init; } = "";
    public string Priority { get; init; } = "P2";
    public string Category { get; init; } = "기타";
    public string ExecutionOrder { get; init; } = RuleInteractionStrategies.RuntimeTabOrder;
    public string[] Preconditions { get; init; } = [];
    public GeneratedScenarioStep[] Steps { get; init; } = [];
    public string[] CoveredControls { get; init; } = [];
    public string[] CoveredValidationRuleIds { get; init; } = [];
    public string ExpectedResult { get; init; } = "";
    public string AutomationStatus { get; init; } = "NeedsLocator";
}

public sealed record GeneratedScenarioStep
{
    public int Sequence { get; init; }
    public required string Action { get; init; }
    public string? ControlLogicalName { get; init; }
    public string MapScreenCode { get; init; } = "";
    public string StateContext { get; init; } = "";
    public bool Transactional { get; init; }
    public string? ValueRef { get; init; }
    public string ExpectedObservation { get; init; } = "";
    public bool? CheckpointRequired { get; init; }
}

public sealed record GeneratedDatasetPatch
{
    public GeneratedScenarioVariable[] Variables { get; init; } = [];
    public GeneratedLocatorRequest[] LocatorRequests { get; init; } = [];
}

public sealed record GeneratedScenarioVariable
{
    public required string Name { get; init; }
    public string TargetRole { get; init; } = "Input";
    public required string TargetLogicalName { get; init; }
    public RuleControlKind ControlKind { get; init; } = RuleControlKind.Auto;
    public RuleValueMatch ValueMatch { get; init; } = RuleValueMatch.Value;
    public GeneratedScenarioValue[] Values { get; init; } = [];
    public string[] AppliesToScreens { get; init; } = [];
    public bool Required { get; init; } = true;
    public bool TriggerQueryAfterChange { get; init; } = true;
}

public sealed record GeneratedScenarioValue
{
    public required string Id { get; init; }
    public required string Value { get; init; }
    public string DisplayValue { get; init; } = "";
    public RuleExpectedOutcome ExpectedOutcome { get; init; } = new();
    public string Rationale { get; init; } = "";
    public string[] SourceRefs { get; init; } = [];
}

public sealed record GeneratedLocatorRequest
{
    public required string ScreenNumber { get; init; }
    public string MapScreenCode { get; init; } = "";
    public string TargetRole { get; init; } = "Input";
    public required string LogicalName { get; init; }
    public string Reason { get; init; } = "";
    public string RecommendedEvidence { get; init; } = "";
}

public sealed record GeneratedReviewItem
{
    public required string Severity { get; init; }
    public required string ScreenNumber { get; init; }
    public required string Subject { get; init; }
    public required string Question { get; init; }
    public required string Reason { get; init; }
}

public sealed record ScenarioApprovalOverlay
{
    public string SchemaVersion { get; init; } = ScenarioPlanVersions.ApprovalSchema;
    public required string SourceSha256 { get; init; }
    public string Status { get; init; } = "Draft";
    public string? ApprovedBy { get; init; }
    public DateTimeOffset? ApprovedAt { get; init; }
    public ScenarioReviewDecision[] ReviewDecisions { get; init; } = [];
    public ScenarioExecutionDecision[] ScenarioDecisions { get; init; } = [];
    public ScenarioCoverageGapDecision[] CoverageGapDecisions { get; init; } = [];
}

public sealed record ScenarioReviewDecision
{
    public required string ReviewId { get; init; }
    public string Decision { get; init; } = "Deferred";
    public string Reason { get; init; } = "";
    public string[] EvidenceRefs { get; init; } = [];
}

public sealed record ScenarioExecutionDecision
{
    public required string ScenarioId { get; init; }
    public string Decision { get; init; } = "Deferred";
    public string Reason { get; init; } = "";
}

public sealed record ScenarioCoverageGapDecision
{
    public required string ScreenNumber { get; init; }
    public required string GapHash { get; init; }
    public string Decision { get; init; } = "Deferred";
    public string Reason { get; init; } = "";
}

public sealed record ScenarioValidationReport
{
    public required string SourceSha256 { get; init; }
    public required string Status { get; init; }
    public required bool IsValid { get; init; }
    public int Screens { get; init; }
    public int Scenarios { get; init; }
    public int Variables { get; init; }
    public int LocatorRequests { get; init; }
    public int ReviewItems { get; init; }
    public int RequiredReviewItems { get; init; }
    public int CoveredControls { get; init; }
    public int CoveredValidationRules { get; init; }
    public int UnusedVariables { get; init; }
    public ValidationIssue[] Issues { get; init; } = [];
}

// 컴파일된 논리 계획 계약 -------------------------------------------------------
