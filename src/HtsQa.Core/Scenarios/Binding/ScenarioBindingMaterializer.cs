// 역할: compiled requirement와 runtime control 후보를 결합하고 physical plan을 생성한다.
// 경계: source scenario validation과 TestResult verdict를 담당하지 않는다.

namespace HtsQa.Core;

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
                var hasRequiredCheckpoint = scenarioCases.SelectMany(x => x.Steps).Any(GeneratedScenarioValidator.IsRequiredCheckpoint);
                if (scenario.Readiness is ScenarioReadiness.PendingApproval or ScenarioReadiness.ManualReview or ScenarioReadiness.Rejected)
                {
                    status = "PENDING_APPROVAL";
                }
                else if (!hasRequiredCheckpoint)
                {
                    reasons.Add("required Checkpoint가 없어 실행 PASS 판정을 차단했습니다.");
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
