// 역할: 생성 시나리오의 구조, dataset/화면/변수/단계 참조와 evidence 계약을 검증한다.
// 경계: logical plan compilation과 runtime binding을 수행하지 않는다.

using System.Text.RegularExpressions;

namespace HtsQa.Core;

public sealed class GeneratedScenarioValidator
{
    private static readonly HashSet<string> SupportedActions = new(StringComparer.OrdinalIgnoreCase)
    {
        "Focus", "Observe", "Input", "Select", "Toggle", "Click", "DoubleClick", "Query", "Restore",
        "AssertValue", "AssertState", "AssertMessage", "AssertFocus", "AssertPopup", "AssertGrid",
        "AssertLogDelta", "AssertTransmissionCount", "AssertOrderReceipt",
        "AssertVisible", "AssertEnabled", "AssertSelected", "AssertNoTransmission"
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
                if (!scenario.Steps.Any(IsRequiredCheckpoint))
                    Warn("SCENARIO.REQUIRED_CHECKPOINT_MISSING", $"{scenario.ScenarioId}에는 required Checkpoint가 없어 실행 PASS로 판정할 수 없습니다.", scenario.ScenarioId);
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
        action.Equals("AssertValue", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertState", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertFocus", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertVisible", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertEnabled", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertSelected", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertGrid", StringComparison.OrdinalIgnoreCase);

    internal static bool IsAction(string action) =>
        action.Equals("Focus", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Input", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Select", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Toggle", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Click", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("DoubleClick", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Query", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("Restore", StringComparison.OrdinalIgnoreCase);

    internal static bool IsCheckpoint(string action) =>
        action.Equals("AssertValue", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertState", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertMessage", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertFocus", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertPopup", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertGrid", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertLogDelta", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertTransmissionCount", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertOrderReceipt", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertVisible", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertEnabled", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertSelected", StringComparison.OrdinalIgnoreCase) ||
        action.Equals("AssertNoTransmission", StringComparison.OrdinalIgnoreCase);

    internal static bool ProvidesExecutableEvidence(string action) => IsCheckpoint(action);

    internal static bool IsRequiredCheckpoint(GeneratedScenarioStep step) =>
        IsCheckpoint(step.Action) && step.CheckpointRequired != false;

    internal static bool IsRequiredCheckpoint(CompiledScenarioStep step) =>
        IsCheckpoint(step.Action) && step.CheckpointRequired != false;
}

/// <summary>검증된 생성 원본과 승인 결정을 계정별 논리 테스트 사례로 컴파일한다.</summary>
