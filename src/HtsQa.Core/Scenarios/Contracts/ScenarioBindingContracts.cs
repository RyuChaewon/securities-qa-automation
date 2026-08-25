// 역할: runtime binding catalog와 physical scenario plan 계약을 정의한다.
// 경계: 생성 시나리오 validation과 최종 TestResult 판정을 수행하지 않는다.

namespace HtsQa.Core;

public enum ScenarioBindingStatus
{
    BoundHigh,
    BoundMedium,
    Ambiguous,
    Unbound
}

public sealed record ScenarioBindingCatalog
{
    public string SchemaVersion { get; init; } = "1.1";
    public required string PlanId { get; init; }
    public required string PlanHash { get; init; }
    public required string SourceInstallationFingerprint { get; init; }
    public required string RuntimeInstallationFingerprint { get; init; }
    public required string Status { get; init; }
    public DateTimeOffset GeneratedAt { get; init; }
    public int RequiredBindings { get; init; }
    public int HighConfidenceBindings { get; init; }
    public int MediumConfidenceBindings { get; init; }
    public int AmbiguousBindings { get; init; }
    public int UnboundBindings { get; init; }
    public ScenarioScreenBindings[] Screens { get; init; } = [];
}

public sealed record ScenarioScreenBindings
{
    public required string ScreenNumber { get; init; }
    public required string ScreenName { get; init; }
    public ScenarioControlBinding[] Controls { get; init; } = [];
}

public sealed record ScenarioControlBinding
{
    public required string LogicalName { get; init; }
    public string MapScreenCode { get; init; } = "";
    public string StateContext { get; init; } = "";
    public string BindingKey { get; init; } = "";
    public required ScenarioBindingStatus Status { get; init; }
    public required string Confidence { get; init; }
    public bool Required { get; init; }
    public bool ExecutionEligible { get; init; }
    public string Reason { get; init; } = "";
    public ScenarioBindingCandidate[] Candidates { get; init; } = [];
}

public sealed record ScenarioBindingCandidate
{
    public required string ControlId { get; init; }
    public string MapScreenCode { get; init; } = "";
    public string BindingKey { get; init; } = "";
    public RuleControlKind ControlKind { get; init; } = RuleControlKind.Auto;
    public string Name { get; init; } = "";
    public string ClassName { get; init; } = "";
    public string LocatorSignature { get; init; } = "";
    public int TabOrder { get; init; }
    public string StateContext { get; init; } = "";
    public string DefinitionSource { get; init; } = "";
    public string RuntimeName { get; init; } = "";
    public string RuntimeControlKind { get; init; } = "";
    public string AutomationEngine { get; init; } = "";
    public string MapModelId { get; init; } = "";
    public bool MapMatched { get; init; }
    public double? MapMatchDistance { get; init; }
    public double? MapGeometryDelta { get; init; }
    public bool MapGeometryExact { get; init; }
    public bool MapHostRequired { get; init; }
    public bool MapHostMatched { get; init; }
    public string MapHostId { get; init; } = "";
    public bool RuntimeIdentityUnique { get; init; } = true;
    public bool AllowOwnerDrawnKindOverride { get; init; }
    public RuleRuntimeRect? RelativeRect { get; init; }
    public bool RuntimeActionable { get; init; }
    public string[] Evidence { get; init; } = [];
}

public sealed record RuntimeControlPlanRow
{
    public string CaseId { get; init; } = "";
    public required string ScreenNumber { get; init; }
    public string ScreenName { get; init; } = "";
    public RuleDiscoveredControl[] DiscoveredControls { get; init; } = [];
}

public sealed record PhysicalScenarioPlan
{
    public string SchemaVersion { get; init; } = "1.1";
    public required string PhysicalPlanId { get; init; }
    public required string LogicalPlanId { get; init; }
    public required string LogicalPlanHash { get; init; }
    public required string BindingCatalogHash { get; init; }
    public required string Status { get; init; }
    public DateTimeOffset GeneratedAt { get; init; }
    public int TotalCases { get; init; }
    public int ExecutableCases { get; init; }
    public int PendingApprovalCases { get; init; }
    public int PendingBindingCases { get; init; }
    public string[] ExecutableCaseIds { get; init; } = [];
    public PhysicalScenarioResolvedBinding[] ResolvedBindings { get; init; } = [];
    public PhysicalScenarioDisposition[] ScenarioDispositions { get; init; } = [];
}

public sealed record PhysicalScenarioResolvedBinding
{
    public required string ScenarioId { get; init; }
    public required string ScreenNumber { get; init; }
    public required string RequirementBindingKey { get; init; }
    public string MapScreenCode { get; init; } = "";
    public required string LogicalName { get; init; }
    public string RequiredStateContext { get; init; } = "";
    public required string CandidateBindingKey { get; init; }
    public required string ControlId { get; init; }
    public required string LocatorSignature { get; init; }
    public string CandidateStateContext { get; init; } = "";
    public string RuntimeControlKind { get; init; } = "";
    public double? MapMatchDistance { get; init; }
    public string MapHostId { get; init; } = "";
    public double? MapGeometryDelta { get; init; }
}

public sealed record PhysicalScenarioDisposition
{
    public required string ScenarioId { get; init; }
    public required string ScreenNumber { get; init; }
    public required string Status { get; init; }
    public string[] Reasons { get; init; } = [];
    public int CaseCount { get; init; }
}

/// <summary>논리 logicalName 요구사항을 현재 HTS의 MAP+Runtime 컨트롤에 결합하고 물리 실행 허용 목록을 만든다.</summary>
