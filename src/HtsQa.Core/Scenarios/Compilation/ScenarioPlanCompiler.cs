// 역할: 승인된 생성 시나리오를 해시로 고정된 compiled logical plan으로 변환한다.
// 경계: runtime UI binding과 TestResult verdict를 담당하지 않는다.

namespace HtsQa.Core;

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
                            ControlRepositoryKey = string.IsNullOrWhiteSpace(step.ControlLogicalName) ? "" :
                                global::HtsQa.Core.ControlRepositoryKey.CreateCanonical(screen.ScreenNumber,
                                    string.IsNullOrWhiteSpace(step.MapScreenCode) ? scenario.MapScreenCode : step.MapScreenCode, step.ControlLogicalName, step.StateContext),
                            Transactional = step.Transactional,
                            ValueRef = step.ValueRef,
                            SelectedValue = !string.IsNullOrWhiteSpace(step.ValueRef) ? selectedValues.GetValueOrDefault(step.ValueRef) : null,
                            ExpectedObservation = step.ExpectedObservation,
                            CheckpointRequired = step.CheckpointRequired,
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
                        ControlRepositoryKey = global::HtsQa.Core.ControlRepositoryKey.CreateCanonical(screen.ScreenNumber, mapScreenCode, logicalName, first.step.StateContext),
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
        "assertvalue" or "assertstate" or "assertmessage" or "assertfocus" or "assertpopup" or "assertgrid"
            or "assertlogdelta" or "asserttransmissioncount" or "assertorderreceipt"
            or "assertvisible" or "assertenabled" or "assertselected" or "assertnotransmission" => "Assert",
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
