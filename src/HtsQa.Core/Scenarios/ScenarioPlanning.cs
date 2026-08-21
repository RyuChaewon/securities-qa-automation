// 역할: 생성 원본, 승인 오버레이, 논리 계획, 런타임 바인딩과 물리 실행계획의 계약을 정의한다.
// 입력/출력: 시나리오 원본과 승인 결정을 검증해 해시로 고정된 compiled/physical plan을 만든다.
// 경계: 원본 SHA, 승인 상태, 설치 fingerprint, BoundHigh 조건을 모두 통과해야 실행 가능해진다.
// 수정 지점: schemaVersion 또는 해시 입력을 바꾸면 이전 산출물 호환 정책과 계획 테스트를 함께 갱신한다.
using System.Text.RegularExpressions;

namespace HtsQa.Core;

// 생성 원본과 승인 계약 ---------------------------------------------------------
public static class ScenarioPlanVersions
{
    public const string SourceSchema = "1.0";
    public const string ApprovalSchema = "1.0";
    public const string CompiledSchema = "1.0";
    public const string Compiler = "1.0.0";
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
    public bool Transactional { get; init; }
    public string? ValueRef { get; init; }
    public CompiledScenarioValue? SelectedValue { get; init; }
    public string ExpectedObservation { get; init; } = "";
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
public sealed class ScenarioBindingMaterializer
{
    private const double MaxActionableMapMatchDistance = 24d;

    /// <summary>런타임 컨트롤 후보를 신뢰도별로 평가해 화면별 바인딩 카탈로그를 생성한다.</summary>
    public ScenarioBindingCatalog Materialize(
        CompiledScenarioPlan plan,
        RuntimeControlPlanRow[] runtimeRows,
        string runtimeInstallationFingerprint,
        RuleTargetAdapterProfile? targetAdapter = null)
    {
        if (!plan.SourceInstallationFingerprint.Equals(runtimeInstallationFingerprint, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("컴파일 계획과 런타임 HTS 설치 fingerprint가 일치하지 않습니다.");

        var screenBindings = new List<ScenarioScreenBindings>();
        foreach (var screen in plan.Screens)
        {
            var runtimeControls = runtimeRows.Where(x => x.ScreenNumber.Equals(screen.ScreenNumber, StringComparison.OrdinalIgnoreCase))
                .SelectMany(x => x.DiscoveredControls)
                .GroupBy(x => $"{x.ControlId}|{x.StateContext}|{x.LocatorSignature}", StringComparer.OrdinalIgnoreCase)
                .Select(x => x.First())
                .ToArray();
            var bindings = new List<ScenarioControlBinding>();
            foreach (var requirement in screen.BindingRequirements)
            {
                var matching = runtimeControls.Where(control => Matches(control, requirement, targetAdapter)).ToArray();
                var actionable = matching.Where(IsRuntimeActionable).ToArray();
                var runtimeCandidates = matching.Where(x => !x.DefinitionSource.Equals("MAP", StringComparison.OrdinalIgnoreCase)).ToArray();
                ScenarioBindingStatus status;
                string reason;
                RuleDiscoveredControl[] selected;
                if (actionable.Length == 1)
                {
                    status = ScenarioBindingStatus.BoundHigh;
                    reason = "유일한 MAP+Runtime 후보가 locator, 종류, 좌표, 거리 실행 조건을 모두 충족했습니다.";
                    selected = actionable;
                }
                else if (actionable.Length > 1)
                {
                    status = ScenarioBindingStatus.Ambiguous;
                    reason = "실행 조건을 충족하는 MAP+Runtime 후보가 둘 이상이므로 대상을 고정할 수 없습니다.";
                    selected = actionable;
                }
                else if (runtimeCandidates.Length == 1)
                {
                    status = ScenarioBindingStatus.BoundMedium;
                    reason = $"런타임 후보는 있으나 실행 조건이 부족합니다: {string.Join(", ", RuntimeEvidence(runtimeCandidates[0]).Where(x => x.StartsWith("FAIL:", StringComparison.Ordinal)))}";
                    selected = runtimeCandidates;
                }
                else if (runtimeCandidates.Length > 1)
                {
                    status = ScenarioBindingStatus.Ambiguous;
                    reason = "동일 논리 이름에 대해 실행 대상을 확정할 수 없는 런타임 후보가 둘 이상입니다.";
                    selected = runtimeCandidates;
                }
                else
                {
                    status = ScenarioBindingStatus.Unbound;
                    reason = matching.Any(x => x.DefinitionSource.Equals("MAP", StringComparison.OrdinalIgnoreCase))
                        ? "MAP 정의는 있으나 현재 화면에서 실행 가능한 HWND/UIA 컨트롤을 찾지 못했습니다."
                        : "현재 화면에서 논리 이름에 대응하는 컨트롤을 찾지 못했습니다.";
                    selected = matching;
                }
                bindings.Add(new ScenarioControlBinding
                {
                    LogicalName = requirement.LogicalName,
                    MapScreenCode = requirement.MapScreenCode,
                    StateContext = requirement.StateContext,
                    BindingKey = requirement.BindingKey,
                    Status = status,
                    Confidence = status switch
                    {
                        ScenarioBindingStatus.BoundHigh => "High",
                        ScenarioBindingStatus.BoundMedium => "Medium",
                        _ => "Unspecified"
                    },
                    Required = requirement.Required,
                    ExecutionEligible = status == ScenarioBindingStatus.BoundHigh && selected.Length == 1,
                    Reason = reason,
                    Candidates = selected.Select(ToCandidate).ToArray()
                });
            }
            screenBindings.Add(new ScenarioScreenBindings
            {
                ScreenNumber = screen.ScreenNumber,
                ScreenName = screen.ScreenName,
                Controls = bindings.ToArray()
            });
        }

        var all = screenBindings.SelectMany(x => x.Controls).ToArray();
        var requiredUnbound = all.Any(x => x.Required && !x.ExecutionEligible);
        return new ScenarioBindingCatalog
        {
            PlanId = plan.PlanId,
            PlanHash = plan.PlanHash,
            SourceInstallationFingerprint = plan.SourceInstallationFingerprint,
            RuntimeInstallationFingerprint = runtimeInstallationFingerprint,
            Status = requiredUnbound ? "INCOMPLETE" : "READY",
            GeneratedAt = DateTimeOffset.Now,
            RequiredBindings = all.Count(x => x.Required),
            HighConfidenceBindings = all.Count(x => x.Status == ScenarioBindingStatus.BoundHigh),
            MediumConfidenceBindings = all.Count(x => x.Status == ScenarioBindingStatus.BoundMedium),
            AmbiguousBindings = all.Count(x => x.Status == ScenarioBindingStatus.Ambiguous),
            UnboundBindings = all.Count(x => x.Status == ScenarioBindingStatus.Unbound),
            Screens = screenBindings.ToArray()
        };
    }

    /// <summary>승인과 고신뢰 바인딩을 모두 통과한 사례만 실행 가능으로 표시한다.</summary>
    public PhysicalScenarioPlan BuildPhysicalPlan(
        CompiledScenarioPlan logicalPlan,
        ScenarioBindingCatalog bindings,
        string bindingCatalogHash)
    {
        if (!logicalPlan.PlanHash.Equals(bindings.PlanHash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("바인딩 카탈로그가 현재 논리 계획에서 생성되지 않았습니다.");

        var dispositions = new List<PhysicalScenarioDisposition>();
        var resolvedBindings = new List<PhysicalScenarioResolvedBinding>();
        var executableScenarioIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var screen in logicalPlan.Screens)
        {
            var screenBindings = bindings.Screens.FirstOrDefault(x => x.ScreenNumber.Equals(screen.ScreenNumber, StringComparison.OrdinalIgnoreCase));
            foreach (var scenario in screen.Scenarios)
            {
                var reasons = new List<string>(scenario.BlockingReasons);
                var status = "PENDING_BINDING";
                var scenarioCases = logicalPlan.Cases.Where(x => x.ScenarioId.Equals(scenario.ScenarioId, StringComparison.OrdinalIgnoreCase)).ToArray();
                var hasExecutableEvidence = scenarioCases.SelectMany(x => x.Steps).Any(x => GeneratedScenarioValidator.ProvidesExecutableEvidence(x.Action));
                if (scenario.Readiness is ScenarioReadiness.PendingApproval or ScenarioReadiness.ManualReview or ScenarioReadiness.Rejected)
                {
                    status = "PENDING_APPROVAL";
                }
                else if (!hasExecutableEvidence)
                {
                    reasons.Add("조작 또는 양성 결과 검증 단계가 없어 실행 PASS 판정을 차단했습니다.");
                }
                else
                {
                    var requirements = screen.BindingRequirements.Where(x => x.ScenarioIds.Contains(scenario.ScenarioId, StringComparer.OrdinalIgnoreCase) && x.Required).ToArray();
                    var resolved = requirements.Select(requirement =>
                    {
                        var binding = screenBindings?.Controls.FirstOrDefault(x => x.BindingKey.Equals(requirement.BindingKey, StringComparison.OrdinalIgnoreCase));
                        var candidates = binding?.Candidates.Where(x => x.RuntimeActionable && IsScenarioActionCompatible(x, scenarioCases, requirement.LogicalName)).ToArray() ?? [];
                        return new { requirement, binding, candidates };
                    }).ToArray();
                    var unresolved = resolved.Where(x => x.binding is null || x.binding.Status != ScenarioBindingStatus.BoundHigh || !x.binding.ExecutionEligible || x.candidates.Length != 1)
                        .Select(x => x.requirement.BindingKey).ToArray();
                    if (unresolved.Length == 0)
                    {
                        status = "READY";
                        executableScenarioIds.Add(scenario.ScenarioId);
                        resolvedBindings.AddRange(resolved.Select(x =>
                        {
                            var candidate = x.candidates[0];
                            return new PhysicalScenarioResolvedBinding
                            {
                                ScenarioId = scenario.ScenarioId,
                                ScreenNumber = screen.ScreenNumber,
                                RequirementBindingKey = x.requirement.BindingKey,
                                MapScreenCode = x.requirement.MapScreenCode,
                                LogicalName = x.requirement.LogicalName,
                                RequiredStateContext = x.requirement.StateContext,
                                CandidateBindingKey = candidate.BindingKey,
                                ControlId = candidate.ControlId,
                                LocatorSignature = candidate.LocatorSignature,
                                CandidateStateContext = candidate.StateContext,
                                RuntimeControlKind = candidate.RuntimeControlKind,
                                MapMatchDistance = candidate.MapMatchDistance,
                                MapHostId = candidate.MapHostId,
                                MapGeometryDelta = candidate.MapGeometryDelta
                            };
                        }));
                    }
                    else reasons.Add($"고신뢰 바인딩 미완료: {string.Join(", ", unresolved)}");
                }
                dispositions.Add(new PhysicalScenarioDisposition
                {
                    ScenarioId = scenario.ScenarioId,
                    ScreenNumber = screen.ScreenNumber,
                    Status = status,
                    Reasons = reasons.ToArray(),
                    CaseCount = scenario.CaseCount
                });
            }
        }

        var executableCases = logicalPlan.Cases.Where(x => executableScenarioIds.Contains(x.ScenarioId)).Select(x => x.CaseId).ToArray();
        var fixedBindings = resolvedBindings.OrderBy(x => x.ScenarioId, StringComparer.OrdinalIgnoreCase)
            .ThenBy(x => x.RequirementBindingKey, StringComparer.OrdinalIgnoreCase).ToArray();
        var hash = JsonFile.Sha256Json(new { logicalPlan.PlanHash, bindingCatalogHash, executableCases, resolvedBindings = fixedBindings });
        return new PhysicalScenarioPlan
        {
            PhysicalPlanId = $"PHYSICAL-{hash[..12]}",
            LogicalPlanId = logicalPlan.PlanId,
            LogicalPlanHash = logicalPlan.PlanHash,
            BindingCatalogHash = bindingCatalogHash,
            Status = executableCases.Length == logicalPlan.Cases.Length ? "READY" : executableCases.Length > 0 ? "PARTIAL" : "BLOCKED",
            GeneratedAt = DateTimeOffset.Now,
            TotalCases = logicalPlan.Cases.Length,
            ExecutableCases = executableCases.Length,
            PendingApprovalCases = dispositions.Where(x => x.Status == "PENDING_APPROVAL").Sum(x => x.CaseCount),
            PendingBindingCases = dispositions.Where(x => x.Status == "PENDING_BINDING").Sum(x => x.CaseCount),
            ExecutableCaseIds = executableCases,
            ResolvedBindings = fixedBindings,
            ScenarioDispositions = dispositions.ToArray()
        };
    }

    private static bool Matches(RuleDiscoveredControl control, ScenarioBindingRequirement requirement, RuleTargetAdapterProfile? targetAdapter)
    {
        var logicalMatch = string.Equals(control.Name, requirement.LogicalName, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(control.MapModelId, requirement.LogicalName, StringComparison.OrdinalIgnoreCase) ||
            control.ControlId.EndsWith($":{requirement.LogicalName}", StringComparison.OrdinalIgnoreCase);
        var requiredMap = RuleTargetAdapterMatcher.ResolveMapScreenCode(targetAdapter, requirement.MapScreenCode);
        var candidateMap = RuleTargetAdapterMatcher.ResolveMapScreenCode(targetAdapter, control.MapScreenCode);
        var mapMatch = string.IsNullOrWhiteSpace(requiredMap) || string.Equals(candidateMap, requiredMap, StringComparison.OrdinalIgnoreCase);
        var stateMatch = StateContextMatches(requirement.StateContext, control.StateContext, targetAdapter);
        return logicalMatch && mapMatch && stateMatch;
    }

    // Adapter-declared state is an execution precondition that owner-drawn child HWNDs may not expose.
    // The runner verifies the state transition while binding retains it in the compound key.
    private static bool StateContextMatches(string? required, string? candidate, RuleTargetAdapterProfile? targetAdapter)
    {
        if (string.IsNullOrWhiteSpace(required)) return true;
        if (RuleTargetAdapterMatcher.IsStateContext(targetAdapter, required)) return true;
        return string.Equals(candidate, required, StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsRuntimeActionable(RuleDiscoveredControl control) => RuntimeEvidence(control).All(x => x.StartsWith("PASS:", StringComparison.Ordinal));

    private static bool IsScenarioActionCompatible(ScenarioBindingCandidate candidate, CompiledScenarioCase[] cases, string logicalName)
    {
        var needsSelectedState = cases.SelectMany(x => x.Steps).Any(step =>
            string.Equals(step.ControlLogicalName, logicalName, StringComparison.OrdinalIgnoreCase) &&
            step.Action is "Toggle" or "AssertSelected");
        if (!needsSelectedState || candidate.ControlKind != RuleControlKind.CheckBox) return true;
        return !candidate.ClassName.StartsWith("AfxWnd", StringComparison.OrdinalIgnoreCase);
    }

    private static string[] RuntimeEvidence(RuleDiscoveredControl control)
    {
        var rectValid = control.RelativeRect is { Width: > 0, Height: > 0 };
        var classValid = !string.IsNullOrWhiteSpace(control.ClassName) &&
            !control.ClassName.Equals("MapDefinition", StringComparison.OrdinalIgnoreCase) &&
            !control.ClassName.Equals("ScenarioUnbound", StringComparison.OrdinalIgnoreCase);
        var kindCompatible = RuntimeKindCompatible(control.ControlKind, control.RuntimeControlKind) ||
            (control.MapHostRequired && control.MapHostMatched && control.MapGeometryExact &&
             control.AllowOwnerDrawnKindOverride &&
             (control.ClassName?.StartsWith("AfxWnd", StringComparison.OrdinalIgnoreCase) ?? false));
        return
        [
            Evidence(control.DefinitionSource.Equals("MAP+Runtime", StringComparison.OrdinalIgnoreCase), "definitionSource=MAP+Runtime"),
            Evidence(control.MapMatched, "mapMatched=true"),
            Evidence(!string.IsNullOrWhiteSpace(control.LocatorSignature) && control.LocatorSignature.StartsWith("MAP|", StringComparison.OrdinalIgnoreCase), "stable MAP locator"),
            Evidence(classValid, "runtime class"),
            Evidence(!string.IsNullOrWhiteSpace(control.AutomationEngine), "runtime automation engine"),
            Evidence(rectValid, "positive runtime rectangle"),
            Evidence(control.MapMatchDistance is >= 0 and <= MaxActionableMapMatchDistance, $"mapMatchDistance<={MaxActionableMapMatchDistance:0}"),
            Evidence(!control.MapHostRequired || control.MapHostMatched, "configured MAP host matched"),
            Evidence(!control.MapHostRequired || control.MapGeometryExact, "host-local geometry matched"),
            Evidence(control.RuntimeIdentityUnique, "runtime identity unique across active MAPs"),
            Evidence(kindCompatible, $"runtime kind compatible with {control.ControlKind} or exact owner-drawn MAP geometry")
        ];
    }

    private static string Evidence(bool passed, string description) => $"{(passed ? "PASS" : "FAIL")}:{description}";

    private static bool RuntimeKindCompatible(RuleControlKind plannedKind, string? runtimeKind)
    {
        if (string.IsNullOrWhiteSpace(runtimeKind)) return false;
        if (plannedKind == RuleControlKind.Auto) return true;
        if (!Enum.TryParse<RuleControlKind>(runtimeKind, true, out var parsed)) return false;
        if (plannedKind is RuleControlKind.Date or RuleControlKind.Text)
            return parsed is RuleControlKind.Date or RuleControlKind.Text;
        return parsed == plannedKind;
    }

    private static ScenarioBindingCandidate ToCandidate(RuleDiscoveredControl control) => new()
    {
        ControlId = control.ControlId,
        MapScreenCode = control.MapScreenCode ?? "",
        BindingKey = BindingKey(control.MapScreenCode, control.Name ?? control.MapModelId ?? control.ControlId, control.StateContext),
        ControlKind = control.ControlKind,
        Name = control.Name ?? "",
        ClassName = control.ClassName ?? "",
        LocatorSignature = control.LocatorSignature ?? "",
        TabOrder = control.TabOrder,
        StateContext = control.StateContext ?? "",
        DefinitionSource = control.DefinitionSource,
        RuntimeName = control.RuntimeName ?? "",
        RuntimeControlKind = control.RuntimeControlKind ?? "",
        AutomationEngine = control.AutomationEngine ?? "",
        MapModelId = control.MapModelId ?? "",
        MapMatched = control.MapMatched,
        MapMatchDistance = control.MapMatchDistance,
        MapGeometryDelta = control.MapGeometryDelta,
        MapGeometryExact = control.MapGeometryExact,
        MapHostRequired = control.MapHostRequired,
        MapHostMatched = control.MapHostMatched,
        MapHostId = control.MapHostId,
        RuntimeIdentityUnique = control.RuntimeIdentityUnique,
        AllowOwnerDrawnKindOverride = control.AllowOwnerDrawnKindOverride,
        RelativeRect = control.RelativeRect,
        RuntimeActionable = IsRuntimeActionable(control),
        Evidence = RuntimeEvidence(control)
    };

    private static string BindingKey(string? mapScreenCode, string logicalName, string? stateContext) =>
        $"{(string.IsNullOrWhiteSpace(mapScreenCode) ? "*" : mapScreenCode)}|{logicalName}|{(string.IsNullOrWhiteSpace(stateContext) ? "*" : stateContext)}";
}

/// <summary>생성 시나리오의 화면, 단계, 변수 참조, 날짜 형식과 기대 계약을 정적으로 검증한다.</summary>
public sealed class GeneratedScenarioValidator
{
    private static readonly HashSet<string> SupportedActions = new(StringComparer.OrdinalIgnoreCase)
    {
        "Focus", "Observe", "Input", "Select", "Toggle", "Click", "DoubleClick", "Query", "Restore",
        "AssertVisible", "AssertEnabled", "AssertSelected", "AssertGrid", "AssertPopup", "AssertNoTransmission"
    };

    public ScenarioValidationReport Validate(GeneratedScenarioDocument source, RuleTestDataset dataset, string sourceSha256)
    {
        var issues = new List<ValidationIssue>();
        if (source.PackageVersion != ScenarioPlanVersions.SourceSchema)
            Error("SCENARIO.PACKAGE_VERSION", $"지원하지 않는 packageVersion입니다: {source.PackageVersion}");
        if (string.IsNullOrWhiteSpace(source.SourceInstallationFingerprint))
            Error("SCENARIO.FINGERPRINT_REQUIRED", "sourceInstallationFingerprint가 필요합니다.");
        if (source.Screens.Length == 0) Error("SCENARIO.SCREENS_REQUIRED", "하나 이상의 화면 시나리오가 필요합니다.");

        // 데이터셋 검증을 선행하므로 이 정규식은 대상 프로필과 동일한 화면 ID 계약을 사용한다.
        var screenRegex = new Regex(dataset.TargetProfile.ScreenIdPattern, RegexOptions.CultureInvariant);
        var enabledScreens = dataset.Screens.Where(x => x.Enabled).Select(x => x.ScreenNumber).ToHashSet(StringComparer.OrdinalIgnoreCase);
        AddDuplicates(source.Screens.Select(x => x.ScreenNumber), "SCENARIO.DUPLICATE_SCREEN", "화면번호");
        AddDuplicates(source.Screens.SelectMany(x => x.Scenarios).Select(x => x.ScenarioId), "SCENARIO.DUPLICATE_ID", "시나리오 ID");
        AddDuplicates(source.Screens.SelectMany(x => x.Scenarios).Select(x => x.SourceTestCaseId), "SCENARIO.DUPLICATE_TC_ID", "원본 TC_ID");
        AddDuplicates(source.DatasetPatch.Variables.Select(x => x.Name), "SCENARIO.DUPLICATE_VARIABLE", "변수 이름");
        AddDuplicates(source.DatasetPatch.LocatorRequests.Select(x => $"{x.ScreenNumber}|{x.MapScreenCode}|{x.LogicalName}"), "SCENARIO.DUPLICATE_LOCATOR", "로케이터 요청");

        var variables = source.DatasetPatch.Variables.ToDictionary(x => x.Name, StringComparer.OrdinalIgnoreCase);
        var usedVariables = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var screen in source.Screens)
        {
            if (!screenRegex.IsMatch(screen.ScreenNumber)) Error("SCENARIO.SCREEN_FORMAT", $"대상 프로필과 화면 ID 형식이 맞지 않습니다: {screen.ScreenNumber}");
            if (!enabledScreens.Contains(screen.ScreenNumber)) Error("SCENARIO.SCREEN_NOT_IN_DATASET", $"기준 데이터셋에 없는 화면입니다: {screen.ScreenNumber}");
            foreach (var scenario in screen.Scenarios)
            {
                if (scenario.Steps.Length == 0) Error("SCENARIO.STEPS_REQUIRED", $"{scenario.ScenarioId}에 단계가 없습니다.", scenario.ScenarioId);
                if (!RuleInteractionStrategies.IsSupported(scenario.ExecutionOrder))
                    Error("SCENARIO.EXECUTION_ORDER", $"{scenario.ScenarioId}의 executionOrder는 RuntimeTabOrder 또는 CoordinateFocus여야 합니다.", scenario.ScenarioId);
                var scenarioActions = scenario.Steps.Select(x => x.Action).ToHashSet(StringComparer.OrdinalIgnoreCase);
                var objectiveHasDoubleClick = Regex.IsMatch(scenario.Objective, "(빠른\\s*)?(이중|더블)\\s*클릭|double\\s*click", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
                if (objectiveHasDoubleClick && scenario.Transactional)
                    Warn("SCENARIO.TRANSACTIONAL_DOUBLE_CLICK_SKIPPED", $"{scenario.ScenarioId}의 주문/전송 이중 클릭 절차는 안전 정책에 따라 자동 실행에서 제외됩니다.", scenario.ScenarioId);
                else if (objectiveHasDoubleClick && !scenarioActions.Contains("DoubleClick"))
                    Error("SCENARIO.DOUBLE_CLICK_REQUIRED", $"{scenario.ScenarioId}의 원본 절차에 이중 클릭이 있지만 DoubleClick 단계가 없습니다.", scenario.ScenarioId);
                if (scenario.Objective.Contains("원상복구", StringComparison.OrdinalIgnoreCase) && !scenarioActions.Contains("Restore"))
                    Error("SCENARIO.RESTORE_REQUIRED", $"{scenario.ScenarioId}의 원본 절차에 원상복구가 있지만 Restore 단계가 없습니다.", scenario.ScenarioId);
                if (!scenarioActions.Any(ProvidesExecutableEvidence))
                    Warn("SCENARIO.NO_EFFECT_STEP", $"{scenario.ScenarioId}에는 조작 또는 양성 결과 검증 단계가 없어 실행 PASS로 판정할 수 없습니다.", scenario.ScenarioId);
                var expectedSequence = 1;
                foreach (var step in scenario.Steps.OrderBy(x => x.Sequence))
                {
                    if (step.Sequence != expectedSequence)
                        Error("SCENARIO.STEP_SEQUENCE", $"{scenario.ScenarioId}의 단계 번호는 1부터 연속이어야 합니다.", scenario.ScenarioId);
                    expectedSequence++;
                    if (!SupportedActions.Contains(step.Action))
                        Error("SCENARIO.ACTION_UNSUPPORTED", $"지원하지 않는 동작입니다: {step.Action}", scenario.ScenarioId);
                    if (step.Action.Equals("DoubleClick", StringComparison.OrdinalIgnoreCase) && (scenario.Transactional || step.Transactional))
                        Error("SCENARIO.TRANSACTIONAL_DOUBLE_CLICK", $"{scenario.ScenarioId}의 주문/전송 단계에는 DoubleClick을 사용할 수 없습니다.", scenario.ScenarioId);
                    if (RequiresTarget(step.Action) && string.IsNullOrWhiteSpace(step.ControlLogicalName))
                        Error("SCENARIO.TARGET_REQUIRED", $"{step.Action} 단계에는 controlLogicalName이 필요합니다.", scenario.ScenarioId);
                    if (string.IsNullOrWhiteSpace(step.ValueRef)) continue;
                    usedVariables.Add(step.ValueRef);
                    if (!variables.TryGetValue(step.ValueRef, out var variable))
                    {
                        Error("SCENARIO.VALUE_REF_NOT_FOUND", $"{scenario.ScenarioId}에서 존재하지 않는 변수를 참조합니다: {step.ValueRef}", scenario.ScenarioId);
                        continue;
                    }
                    if (!variable.AppliesToScreens.Contains(screen.ScreenNumber, StringComparer.OrdinalIgnoreCase) &&
                        !variable.AppliesToScreens.Contains("*", StringComparer.OrdinalIgnoreCase))
                        Error("SCENARIO.VARIABLE_SCREEN_MISMATCH", $"{step.ValueRef}는 {screen.ScreenNumber} 화면에 적용되지 않습니다.", scenario.ScenarioId);
                    if (!string.IsNullOrWhiteSpace(step.ControlLogicalName) &&
                        !step.ControlLogicalName.Equals(variable.TargetLogicalName, StringComparison.OrdinalIgnoreCase))
                        Error("SCENARIO.VARIABLE_TARGET_MISMATCH", $"{step.ValueRef}의 대상 {variable.TargetLogicalName}과 단계 대상 {step.ControlLogicalName}이 다릅니다.", scenario.ScenarioId);
                }
            }
        }

        foreach (var variable in source.DatasetPatch.Variables)
        {
            if (variable.Values.Length == 0) Error("SCENARIO.VARIABLE_VALUES_REQUIRED", $"{variable.Name}에 값이 없습니다.");
            AddDuplicates(variable.Values.Select(x => x.Id), "SCENARIO.DUPLICATE_VALUE", $"{variable.Name} 값 ID");
            foreach (var value in variable.Values)
            {
                var expected = value.ExpectedOutcome;
                if (expected.Type is RuleExpectedOutcomeType.ValidationRequired or RuleExpectedOutcomeType.FailureRequired &&
                    expected.MessagePatterns.Length == 0 && expected.ErrorCodes.Length == 0)
                    Error("SCENARIO.EXPECTATION_MATCHER_REQUIRED", $"{variable.Name}/{value.Id}의 필수 기대 결과에는 메시지 또는 오류코드가 필요합니다.");
                if (variable.ControlKind == RuleControlKind.Date && value.Value.Length > 0 && !DateOnly.TryParseExact(value.Value, "yyyyMMdd", out _))
                    Error("SCENARIO.DATE_FORMAT", $"{variable.Name}/{value.Id} 날짜는 yyyyMMdd여야 합니다.");
            }
        }

        foreach (var unused in variables.Keys.Where(x => !usedVariables.Contains(x)))
            Warn("SCENARIO.UNUSED_VARIABLE", $"어떤 시나리오에서도 사용하지 않는 변수입니다: {unused}");

        var coveredControls = source.Screens.SelectMany(screen => screen.Scenarios
                .SelectMany(scenario => scenario.CoveredControls)
                .Select(control => $"{screen.ScreenNumber}|{control}"))
            .Distinct(StringComparer.OrdinalIgnoreCase).Count();
        var coveredRules = source.Screens.SelectMany(x => x.Scenarios).SelectMany(x => x.CoveredValidationRuleIds)
            .Distinct(StringComparer.OrdinalIgnoreCase).Count();
        var valid = issues.All(x => !x.Severity.Equals("ERROR", StringComparison.OrdinalIgnoreCase));
        return new ScenarioValidationReport
        {
            SourceSha256 = sourceSha256,
            IsValid = valid,
            Status = !valid ? "INVALID" : issues.Count > 0 ? "VALIDATED_WITH_WARNINGS" : "VALIDATED",
            Screens = source.Screens.Length,
            Scenarios = source.Screens.Sum(x => x.Scenarios.Length),
            Variables = source.DatasetPatch.Variables.Length,
            LocatorRequests = source.DatasetPatch.LocatorRequests.Length,
            ReviewItems = source.ReviewItems.Length,
            RequiredReviewItems = source.ReviewItems.Count(x => x.Severity.Equals("Required", StringComparison.OrdinalIgnoreCase)),
            CoveredControls = coveredControls,
            CoveredValidationRules = coveredRules,
            UnusedVariables = variables.Keys.Count(x => !usedVariables.Contains(x)),
            Issues = issues.ToArray()
        };

        void Error(string code, string message, string? stepId = null) => issues.Add(new(code, message, stepId));
        void Warn(string code, string message, string? stepId = null) => issues.Add(new(code, message, stepId, Severity: "WARNING"));
        void AddDuplicates(IEnumerable<string> values, string code, string label)
        {
            foreach (var duplicate in values.Where(x => !string.IsNullOrWhiteSpace(x)).GroupBy(x => x, StringComparer.OrdinalIgnoreCase).Where(x => x.Count() > 1))
                Error(code, $"중복된 {label}입니다: {duplicate.Key}");
        }
    }

    private static bool RequiresTarget(string action) =>
        action.Equals("Input", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Select", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Toggle", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Click", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("DoubleClick", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Query", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertVisible", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertEnabled", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertSelected", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertGrid", StringComparison.OrdinalIgnoreCase);

    internal static bool ProvidesExecutableEvidence(string action) =>
        action.Equals("Input", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Select", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Toggle", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Click", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("DoubleClick", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Query", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertVisible", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertEnabled", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertSelected", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertGrid", StringComparison.OrdinalIgnoreCase);
}

/// <summary>검증된 생성 원본과 승인 결정을 계정별 논리 테스트 사례로 컴파일한다.</summary>
public sealed class ScenarioPlanCompiler
{
    /// <summary>참조된 변수만 조합하고 승인 상태를 반영해 해시 고정 논리 계획을 만든다.</summary>
    public CompiledScenarioPlan Compile(
        GeneratedScenarioDocument source,
        RuleTestDataset dataset,
        string sourceSha256,
        string datasetSha256,
        ScenarioApprovalOverlay? approval = null,
        string? approvalSha256 = null,
        int? maxCases = null)
    {
        var validation = new GeneratedScenarioValidator().Validate(source, dataset, sourceSha256);
        if (!validation.IsValid)
            throw new InvalidDataException(string.Join(Environment.NewLine, validation.Issues.Where(x => x.Severity == "ERROR").Select(x => $"{x.Code}: {x.Message}")));
        if (approval is not null)
        {
            if (!string.Equals(approval.SourceSha256, sourceSha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("승인 오버레이의 sourceSha256이 생성 시나리오 원본과 일치하지 않습니다.");
            ValidateApproval(approval, source);
        }

        var variables = source.DatasetPatch.Variables.ToDictionary(x => x.Name, StringComparer.OrdinalIgnoreCase);
        var approvalActive = string.Equals(approval?.Status, "Approved", StringComparison.OrdinalIgnoreCase);
        var reviewDecisions = approvalActive
            ? approval!.ReviewDecisions.ToDictionary(x => x.ReviewId, StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string, ScenarioReviewDecision>(StringComparer.OrdinalIgnoreCase);
        var scenarioDecisions = approvalActive
            ? approval!.ScenarioDecisions.ToDictionary(x => x.ScenarioId, StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string, ScenarioExecutionDecision>(StringComparer.OrdinalIgnoreCase);
        // 계좌가 없는 일반 화면군도 공통 기본 실행 컨텍스트 한 건으로 컴파일한다.
        var accounts = RuleCaseExpander.ActiveExecutionContexts(dataset);
        var cases = new List<CompiledScenarioCase>();
        var screenPlans = new List<CompiledScreenPlan>();
        var definitionRows = new List<CompiledScenarioDefinition>();

        foreach (var screen in source.Screens)
        {
            var definitions = new List<CompiledScenarioDefinition>();
            foreach (var scenario in screen.Scenarios.OrderBy(x => PriorityOrder(x.Priority)).ThenBy(x => x.ScenarioId, StringComparer.OrdinalIgnoreCase))
            {
                var unresolvedReviews = RequiredReviewsForScenario(source, screen, scenario)
                    .Where(x => !IsReviewApproved(reviewDecisions.GetValueOrDefault(ReviewId(x))))
                    .ToArray();
                var decision = scenarioDecisions.GetValueOrDefault(scenario.ScenarioId);
                var readiness = ResolveReadiness(scenario, decision, unresolvedReviews);
                var blocking = new List<string>();
                if (decision?.Decision.Equals("Reject", StringComparison.OrdinalIgnoreCase) == true) blocking.Add("승인 오버레이에서 실행을 거부했습니다.");
                if (scenario.AutomationStatus.Equals("ManualReview", StringComparison.OrdinalIgnoreCase) &&
                    decision?.Decision.Equals("Approve", StringComparison.OrdinalIgnoreCase) != true)
                    blocking.Add("수동 검토 시나리오의 명시적 실행 승인이 필요합니다.");
                blocking.AddRange(unresolvedReviews.Select(x => $"필수 검토 미해결: {x.Subject}"));

                var refs = scenario.Steps.Where(x => !string.IsNullOrWhiteSpace(x.ValueRef)).Select(x => x.ValueRef!)
                    .Distinct(StringComparer.OrdinalIgnoreCase).Select(x => variables[x]).ToArray();
                var combinations = new CombinationGenerator()
                    .GenerateCartesian(refs, x => x.Name, x => x.Values, x => x.Id)
                    .ToArray();
                var caseCount = combinations.Length * accounts.Length;
                var definition = new CompiledScenarioDefinition
                {
                    ScenarioId = scenario.ScenarioId,
                    SourceTestCaseId = scenario.SourceTestCaseId,
                    MapScreenCode = scenario.MapScreenCode,
                    Transactional = scenario.Transactional,
                    ExpectedResult = scenario.ExpectedResult,
                    Title = scenario.Title,
                    Priority = scenario.Priority,
                    Category = scenario.Category,
                    Readiness = readiness,
                    BlockingReasons = blocking.ToArray(),
                    RequiredReviewIds = unresolvedReviews.Select(ReviewId).ToArray(),
                    CoveredControls = scenario.CoveredControls,
                    CoveredValidationRuleIds = scenario.CoveredValidationRuleIds,
                    CaseCount = caseCount,
                    StepCount = caseCount * scenario.Steps.Length
                };
                definitions.Add(definition);
                definitionRows.Add(definition);

                var ordinal = 0;
                foreach (var account in accounts)
                foreach (var selected in combinations)
                {
                    ordinal++;
                    var selectedValues = selected.ToDictionary(
                        x => x.Key,
                        x => ToCompiledValue(variables[x.Key], x.Value),
                        StringComparer.OrdinalIgnoreCase);
                    var caseId = CaseIdFactory.Create("SC", new
                    {
                        sourceSha256,
                        scenarioId = scenario.ScenarioId,
                        accountId = account.Id,
                        values = selectedValues.OrderBy(x => x.Key, StringComparer.Ordinal)
                            .ToDictionary(x => x.Key, x => x.Value.ValueId, StringComparer.Ordinal)
                    });
                    cases.Add(new CompiledScenarioCase
                    {
                        CaseId = caseId,
                        ScenarioId = scenario.ScenarioId,
                        SourceTestCaseId = scenario.SourceTestCaseId,
                        MapScreenCode = scenario.MapScreenCode,
                        Transactional = scenario.Transactional,
                        ExpectedResult = scenario.ExpectedResult,
                        ExecutionOrder = scenario.ExecutionOrder,
                        ScenarioTitle = scenario.Title,
                        Priority = scenario.Priority,
                        Category = scenario.Category,
                        ScreenNumber = screen.ScreenNumber,
                        ScreenName = screen.ScreenName,
                        AccountId = account.Id,
                        Readiness = readiness,
                        BlockingReasons = blocking.ToArray(),
                        Values = selectedValues,
                        Steps = scenario.Steps.OrderBy(x => x.Sequence).Select(step => new CompiledScenarioStep
                        {
                            StepId = $"{scenario.ScenarioId}-S{step.Sequence:000}",
                            Sequence = step.Sequence,
                            Action = step.Action,
                            ControlLogicalName = step.ControlLogicalName,
                            MapScreenCode = string.IsNullOrWhiteSpace(step.MapScreenCode) ? scenario.MapScreenCode : step.MapScreenCode,
                            StateContext = step.StateContext,
                            Transactional = step.Transactional,
                            ValueRef = step.ValueRef,
                            SelectedValue = !string.IsNullOrWhiteSpace(step.ValueRef) ? selectedValues.GetValueOrDefault(step.ValueRef) : null,
                            ExpectedObservation = step.ExpectedObservation,
                            ExecutionPhase = Phase(step.Action),
                            RuntimeTabOrderEligible = step.Action is "Input" or "Select" or "Toggle"
                        }).ToArray()
                    });
                }
            }

            var requirements = screen.Scenarios.SelectMany(scenario => scenario.Steps
                    .Where(step => !string.IsNullOrWhiteSpace(step.ControlLogicalName))
                    .Select(step => (scenario, step)))
                .GroupBy(x => BindingKey(
                    string.IsNullOrWhiteSpace(x.step.MapScreenCode) ? x.scenario.MapScreenCode : x.step.MapScreenCode,
                    x.step.ControlLogicalName!,
                    x.step.StateContext), StringComparer.OrdinalIgnoreCase)
                .Select(group =>
                {
                    var first = group.First();
                    var logicalName = first.step.ControlLogicalName!;
                    var mapScreenCode = string.IsNullOrWhiteSpace(first.step.MapScreenCode) ? first.scenario.MapScreenCode : first.step.MapScreenCode;
                    var variable = source.DatasetPatch.Variables.FirstOrDefault(x => x.TargetLogicalName.Equals(logicalName, StringComparison.OrdinalIgnoreCase));
                    var locator = source.DatasetPatch.LocatorRequests.FirstOrDefault(x =>
                        x.ScreenNumber == screen.ScreenNumber &&
                        x.LogicalName.Equals(logicalName, StringComparison.OrdinalIgnoreCase) &&
                        (string.IsNullOrWhiteSpace(x.MapScreenCode) || x.MapScreenCode.Equals(mapScreenCode, StringComparison.OrdinalIgnoreCase)));
                    return new ScenarioBindingRequirement
                    {
                        LogicalName = logicalName,
                        MapScreenCode = mapScreenCode,
                        StateContext = first.step.StateContext,
                        BindingKey = group.Key,
                        TargetRole = variable?.TargetRole ?? locator?.TargetRole ?? "Command",
                        ControlKind = variable?.ControlKind ?? InferKind(group.First().step.Action),
                        Required = variable?.Required ?? true,
                        ScenarioIds = group.Select(x => x.scenario.ScenarioId).Distinct(StringComparer.OrdinalIgnoreCase).ToArray(),
                        RecommendedEvidence = locator?.RecommendedEvidence ?? "MAP logicalName과 런타임 컨트롤의 종류·상대위치·탭오더를 결합"
                    };
                }).OrderBy(x => x.BindingKey, StringComparer.OrdinalIgnoreCase).ToArray();
            screenPlans.Add(new CompiledScreenPlan
            {
                ScreenNumber = screen.ScreenNumber,
                ScreenName = screen.ScreenName,
                Scenarios = definitions.ToArray(),
                BindingRequirements = requirements,
                CoverageGaps = screen.CoverageGaps
            });
        }

        var limit = Math.Min(dataset.MaxExpandedCases, maxCases ?? dataset.MaxExpandedCases);
        if (cases.Count > limit) throw new InvalidDataException($"시나리오별 확장 케이스 {cases.Count}건이 제한 {limit}건을 초과했습니다.");
        var used = source.Screens.SelectMany(x => x.Scenarios).SelectMany(x => x.Steps).Where(x => !string.IsNullOrWhiteSpace(x.ValueRef))
            .Select(x => x.ValueRef!).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var payloadHash = JsonFile.Sha256Json(new
        {
            compiler = ScenarioPlanVersions.Compiler,
            sourceSha256,
            datasetSha256,
            approvalSha256 = approvalSha256 ?? "",
            cases = cases.Select(x => new { x.CaseId, x.ScenarioId, x.ScreenNumber, x.AccountId, values = x.Values.ToDictionary(v => v.Key, v => v.Value.ValueId) })
        });
        var pendingApproval = definitionRows.Count(x => x.Readiness is ScenarioReadiness.PendingApproval or ScenarioReadiness.ManualReview or ScenarioReadiness.Rejected);
        var status = pendingApproval > 0 ? "NEEDS_APPROVAL" : "READY_FOR_BINDING";
        return new CompiledScenarioPlan
        {
            PlanId = $"PLAN-{payloadHash[..12]}",
            PlanHash = payloadHash,
            SourceSha256 = sourceSha256,
            SourceInstallationFingerprint = source.SourceInstallationFingerprint,
            DatasetId = dataset.DatasetId,
            DatasetSha256 = datasetSha256,
            ScenarioGenerationMode = source.GenerationSummary.GenerationMode,
            ScenarioGenerator = source.GenerationSummary.Generator,
            ScenarioGeneratorVersion = source.GenerationSummary.GeneratorVersion,
            RuntimeDiscoveryUsed = source.GenerationSummary.RuntimeDiscoveryUsed,
            ApprovalSha256 = approvalSha256,
            ApprovalStatus = approval?.Status ?? "NotProvided",
            ApprovedBy = approvalActive ? approval!.ApprovedBy : null,
            ApprovedAt = approvalActive ? approval!.ApprovedAt : null,
            ReviewDecisionCount = approval?.ReviewDecisions.Length ?? 0,
            ScenarioDecisionCount = approval?.ScenarioDecisions.Length ?? 0,
            CoverageGapDecisionCount = approval?.CoverageGapDecisions.Length ?? 0,
            Status = status,
            GeneratedAt = DateTimeOffset.Now,
            ScreenCount = source.Screens.Length,
            ScenarioCount = definitionRows.Count,
            CaseCount = cases.Count,
            StepCount = cases.Sum(x => x.Steps.Length),
            ReadyScenarioCount = definitionRows.Count(x => x.Readiness == ScenarioReadiness.ReadyForBinding),
            PendingApprovalScenarioCount = definitionRows.Count(x => x.Readiness == ScenarioReadiness.PendingApproval),
            PendingBindingScenarioCount = definitionRows.Count(x => x.Readiness == ScenarioReadiness.PendingBinding),
            ManualReviewScenarioCount = definitionRows.Count(x => x.Readiness == ScenarioReadiness.ManualReview),
            UnusedVariableCount = source.DatasetPatch.Variables.Count(x => !used.Contains(x.Name)),
            Issues = validation.Issues,
            Screens = screenPlans.ToArray(),
            Cases = cases.ToArray()
        };
    }

    public static ScenarioApprovalOverlay CreateApprovalTemplate(GeneratedScenarioDocument source, string sourceSha256) => new()
    {
        SourceSha256 = sourceSha256,
        ReviewDecisions = source.ReviewItems.Select(item => new ScenarioReviewDecision
        {
            ReviewId = ReviewId(item),
            Decision = item.Severity.Equals("Required", StringComparison.OrdinalIgnoreCase) ? "Deferred" : "Informational",
            Reason = item.Question
        }).ToArray(),
        ScenarioDecisions = source.Screens.SelectMany(x => x.Scenarios)
            .Where(x => x.AutomationStatus.Equals("ManualReview", StringComparison.OrdinalIgnoreCase))
            .Select(x => new ScenarioExecutionDecision { ScenarioId = x.ScenarioId, Decision = "Deferred", Reason = "수동 검토 시나리오" })
            .ToArray(),
        CoverageGapDecisions = source.Screens.SelectMany(screen => screen.CoverageGaps.Select(gap => new ScenarioCoverageGapDecision
        {
            ScreenNumber = screen.ScreenNumber,
            GapHash = ScenarioIds.Hash($"{screen.ScreenNumber}|{gap}", 12),
            Decision = "Deferred",
            Reason = gap
        })).ToArray()
    };

    public static string ReviewId(GeneratedReviewItem item) =>
        $"REV-{item.ScreenNumber}-{ScenarioIds.Hash($"{item.Severity}|{item.Subject}|{item.Question}", 12)}";

    private static IEnumerable<GeneratedReviewItem> RequiredReviewsForScenario(
        GeneratedScenarioDocument source,
        GeneratedScreenScenario screen,
        GeneratedScenario scenario)
    {
        foreach (var item in source.ReviewItems.Where(x =>
                     x.ScreenNumber.Equals(screen.ScreenNumber, StringComparison.OrdinalIgnoreCase) &&
                     x.Severity.Equals("Required", StringComparison.OrdinalIgnoreCase)))
        {
            var relatesToControl = scenario.CoveredControls.Any(control => item.Subject.Contains(control, StringComparison.OrdinalIgnoreCase));
            var relatesToRule = scenario.CoveredValidationRuleIds.Any(rule => item.Subject.Contains(rule, StringComparison.OrdinalIgnoreCase));
            var hasSpecificReference = screen.Scenarios.SelectMany(x => x.CoveredControls.Concat(x.CoveredValidationRuleIds))
                .Any(reference => item.Subject.Contains(reference, StringComparison.OrdinalIgnoreCase));
            if (relatesToControl || relatesToRule || !hasSpecificReference) yield return item;
        }
    }

    private static bool IsReviewApproved(ScenarioReviewDecision? decision) =>
        decision is not null && (decision.Decision.Equals("Resolved", StringComparison.OrdinalIgnoreCase) ||
                                 decision.Decision.Equals("AcceptedGap", StringComparison.OrdinalIgnoreCase));

    private static void ValidateApproval(ScenarioApprovalOverlay approval, GeneratedScenarioDocument source)
    {
        if (!string.Equals(approval.SchemaVersion, ScenarioPlanVersions.ApprovalSchema, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException($"지원하지 않는 승인 오버레이 schemaVersion입니다: {approval.SchemaVersion}");
        if (!string.Equals(approval.Status, "Draft", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(approval.Status, "Approved", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("승인 오버레이 status는 Draft 또는 Approved여야 합니다.");

        if (string.Equals(approval.Status, "Approved", StringComparison.OrdinalIgnoreCase) &&
            (string.IsNullOrWhiteSpace(approval.ApprovedBy) || approval.ApprovedAt is null))
            throw new InvalidDataException("Approved 승인 오버레이에는 approvedBy와 approvedAt이 모두 필요합니다.");

        ValidateDecisionSet(approval.ReviewDecisions.Select(x => (x.ReviewId, x.Decision)),
            ["Deferred", "Informational", "Resolved", "AcceptedGap"], "reviewDecisions");
        ValidateDecisionSet(approval.ScenarioDecisions.Select(x => (x.ScenarioId, x.Decision)),
            ["Deferred", "Approve", "Reject"], "scenarioDecisions");
        ValidateDecisionSet(approval.CoverageGapDecisions.Select(x => ($"{x.ScreenNumber}|{x.GapHash}", x.Decision)),
            ["Deferred", "AcceptedGap", "Resolved"], "coverageGapDecisions");

        var knownReviewIds = source.ReviewItems.Select(ReviewId).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var unknownReview = approval.ReviewDecisions.FirstOrDefault(x => !knownReviewIds.Contains(x.ReviewId));
        if (unknownReview is not null)
            throw new InvalidDataException($"승인 오버레이 reviewDecisions가 원본에 없는 검토 ID를 참조합니다: {unknownReview.ReviewId}");

        var knownScenarioIds = source.Screens.SelectMany(x => x.Scenarios).Select(x => x.ScenarioId).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var unknownScenario = approval.ScenarioDecisions.FirstOrDefault(x => !knownScenarioIds.Contains(x.ScenarioId));
        if (unknownScenario is not null)
            throw new InvalidDataException($"승인 오버레이 scenarioDecisions가 원본에 없는 시나리오 ID를 참조합니다: {unknownScenario.ScenarioId}");

        var knownGaps = source.Screens.SelectMany(screen => screen.CoverageGaps.Select(gap =>
            $"{screen.ScreenNumber}|{ScenarioIds.Hash($"{screen.ScreenNumber}|{gap}", 12)}"))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var unknownGap = approval.CoverageGapDecisions.FirstOrDefault(x => !knownGaps.Contains($"{x.ScreenNumber}|{x.GapHash}"));
        if (unknownGap is not null)
            throw new InvalidDataException($"승인 오버레이 coverageGapDecisions가 원본에 없는 공백을 참조합니다: {unknownGap.ScreenNumber}|{unknownGap.GapHash}");

        if (string.Equals(approval.Status, "Approved", StringComparison.OrdinalIgnoreCase))
        {
            var decidedReviewIds = approval.ReviewDecisions.Select(x => x.ReviewId).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var missingReview = knownReviewIds.FirstOrDefault(x => !decidedReviewIds.Contains(x));
            if (missingReview is not null)
                throw new InvalidDataException($"Approved 승인 오버레이에 검토 결정이 누락되었습니다: {missingReview}");

            var knownManualScenarioIds = source.Screens.SelectMany(x => x.Scenarios)
                .Where(x => x.AutomationStatus.Equals("ManualReview", StringComparison.OrdinalIgnoreCase))
                .Select(x => x.ScenarioId).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var decidedScenarioIds = approval.ScenarioDecisions.Select(x => x.ScenarioId).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var missingScenario = knownManualScenarioIds.FirstOrDefault(x => !decidedScenarioIds.Contains(x));
            if (missingScenario is not null)
                throw new InvalidDataException($"Approved 승인 오버레이에 수동 시나리오 결정이 누락되었습니다: {missingScenario}");

            var decidedGaps = approval.CoverageGapDecisions.Select(x => $"{x.ScreenNumber}|{x.GapHash}").ToHashSet(StringComparer.OrdinalIgnoreCase);
            var missingGap = knownGaps.FirstOrDefault(x => !decidedGaps.Contains(x));
            if (missingGap is not null)
                throw new InvalidDataException($"Approved 승인 오버레이에 커버리지 공백 결정이 누락되었습니다: {missingGap}");

            if (approval.ReviewDecisions.Any(x => x.Decision.Equals("Deferred", StringComparison.OrdinalIgnoreCase)) ||
                approval.ScenarioDecisions.Any(x => x.Decision.Equals("Deferred", StringComparison.OrdinalIgnoreCase)) ||
                approval.CoverageGapDecisions.Any(x => x.Decision.Equals("Deferred", StringComparison.OrdinalIgnoreCase)))
                throw new InvalidDataException("Approved 승인 오버레이에는 Deferred 결정이 남아 있을 수 없습니다.");
        }
    }

    private static void ValidateDecisionSet(
        IEnumerable<(string Key, string Decision)> decisions,
        string[] allowed,
        string section)
    {
        var rows = decisions.ToArray();
        var duplicate = rows.GroupBy(x => x.Key, StringComparer.OrdinalIgnoreCase).FirstOrDefault(x => x.Count() > 1);
        if (duplicate is not null) throw new InvalidDataException($"승인 오버레이 {section}에 중복 키가 있습니다: {duplicate.Key}");
        var invalid = rows.FirstOrDefault(x => !allowed.Contains(x.Decision, StringComparer.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(invalid.Key))
            throw new InvalidDataException($"승인 오버레이 {section}의 결정값이 유효하지 않습니다: {invalid.Key}={invalid.Decision}");
    }

    private static ScenarioReadiness ResolveReadiness(
        GeneratedScenario scenario,
        ScenarioExecutionDecision? decision,
        GeneratedReviewItem[] unresolvedReviews)
    {
        if (decision?.Decision.Equals("Reject", StringComparison.OrdinalIgnoreCase) == true) return ScenarioReadiness.Rejected;
        if (scenario.AutomationStatus.Equals("ManualReview", StringComparison.OrdinalIgnoreCase) &&
            decision?.Decision.Equals("Approve", StringComparison.OrdinalIgnoreCase) != true) return ScenarioReadiness.ManualReview;
        if (unresolvedReviews.Length > 0) return ScenarioReadiness.PendingApproval;
        return scenario.AutomationStatus.Equals("NeedsLocator", StringComparison.OrdinalIgnoreCase)
            ? ScenarioReadiness.PendingBinding
            : ScenarioReadiness.ReadyForBinding;
    }

    private static CompiledScenarioValue ToCompiledValue(GeneratedScenarioVariable variable, GeneratedScenarioValue value) => new()
    {
        VariableName = variable.Name,
        ValueId = value.Id,
        Value = value.Value,
        DisplayValue = value.DisplayValue,
        TargetLogicalName = variable.TargetLogicalName,
        TargetRole = variable.TargetRole,
        ControlKind = variable.ControlKind,
        ValueMatch = variable.ValueMatch,
        TriggerQueryAfterChange = variable.TriggerQueryAfterChange,
        ExpectedOutcome = value.ExpectedOutcome,
        Rationale = value.Rationale,
        SourceRefs = value.SourceRefs
    };

    private static int PriorityOrder(string priority) => priority.ToUpperInvariant() switch
    {
        "P0" => 0,
        "P1" => 1,
        "P2" => 2,
        "P3" => 3,
        _ => 9
    };

    private static string Phase(string action) => action.ToLowerInvariant() switch
    {
        "focus" => "Open",
        "input" or "select" or "toggle" => "Arrange",
        "query" => "Query",
        "observe" => "Observe",
        "assertvisible" or "assertenabled" or "assertselected" or "assertgrid" or "assertpopup" or "assertnotransmission" => "Assert",
        "restore" => "Restore",
        _ => "Action"
    };

    private static RuleControlKind InferKind(string action) => action.ToLowerInvariant() switch
    {
        "input" => RuleControlKind.Text,
        "select" => RuleControlKind.ComboBox,
        "toggle" => RuleControlKind.CheckBox,
        "click" or "query" => RuleControlKind.Button,
        _ => RuleControlKind.Auto
    };

    private static string BindingKey(string? mapScreenCode, string logicalName, string? stateContext) =>
        $"{(string.IsNullOrWhiteSpace(mapScreenCode) ? "*" : mapScreenCode)}|{logicalName}|{(string.IsNullOrWhiteSpace(stateContext) ? "*" : stateContext)}";
}

public static class ScenarioIds
{
    public static string Hash(string value, int length) => RuleCaseExpander.Fingerprint(value, length);
}
