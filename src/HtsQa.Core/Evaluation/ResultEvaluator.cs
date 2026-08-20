// 역할: 원시 Observation과 ExpectedResult를 EvaluationPolicy에 따라 단일 TestResult로 판정한다.
// 입력/출력: UI·파일·PowerShell과 무관한 불변 평가 계약을 받아 PASS/FAIL/ERROR/PENDING 및 근거 코드를 반환한다.
// 경계: 미실행·무증거·미해결 기대값은 PASS가 될 수 없고 ObservationOnly는 검증 성공으로 승격하지 않는다.
// 수정 지점: 상태 우선순위나 matcher 의미를 바꾸면 ResultEvaluatorTests와 CLI golden test를 함께 갱신한다.
using System.Text.RegularExpressions;

namespace HtsQa.Core;

public enum ObservationKind
{
    Success,
    Info,
    InputValidation,
    NoData,
    Warning,
    ProductFailure,
    GenericError,
    EvidenceMissing,
    InfrastructureError
}

public sealed record Observation
{
    public string ObservationId { get; init; } = "";
    public ObservationKind Kind { get; init; } = ObservationKind.Info;
    public bool Executed { get; init; } = true;
    public bool EvidencePresent { get; init; } = true;
    public string Message { get; init; } = "";
    public string SourceCode { get; init; } = "";
    public string Source { get; init; } = "";
}

public sealed record ExpectedResult
{
    public string ExpectationId { get; init; } = "";
    public RuleExpectedOutcomeType Type { get; init; } = RuleExpectedOutcomeType.Unspecified;
    public string Description { get; init; } = "";
    public string[] MessagePatterns { get; init; } = [];
    public string[] ErrorCodes { get; init; } = [];

    public static ExpectedResult FromRuleExpectedOutcome(RuleExpectedOutcome? expected, string description = "", string expectationId = "")
    {
        var source = expected ?? new RuleExpectedOutcome();
        return new ExpectedResult
        {
            ExpectationId = expectationId,
            Type = source.Type,
            Description = description,
            MessagePatterns = source.MessagePatterns,
            ErrorCodes = source.ErrorCodes
        };
    }
}

public sealed record EvaluationPolicy
{
    public TestStatus NotExecutedStatus { get; init; } = TestStatus.PENDING;
    public TestStatus MissingEvidenceStatus { get; init; } = TestStatus.PENDING;
    public TestStatus MatcherMismatchStatus { get; init; } = TestStatus.FAIL;
    public TestStatus UnresolvedExpectationStatus { get; init; } = TestStatus.PENDING;
    public TestStatus ObservationOnlyStatus { get; init; } = TestStatus.PENDING;
    public TestStatus InfrastructureErrorStatus { get; init; } = TestStatus.ERROR;
}

public sealed record ResultEvaluationCase
{
    public required string CaseId { get; init; }
    public bool Executed { get; init; }
    public ExpectedResult ExpectedResult { get; init; } = new();
    public EvaluationPolicy EvaluationPolicy { get; init; } = new();
    public Observation[] Observations { get; init; } = [];
}

public sealed record ResultEvaluationDocument
{
    public string SchemaVersion { get; init; } = "1.0";
    public string TestPackId { get; init; } = "";
    public string AggregateId { get; init; } = "";
    public ResultEvaluationCase[] Cases { get; init; } = [];
    public TestResult[] CompletedResults { get; init; } = [];
}

public sealed record TestResult
{
    public required string CaseId { get; init; }
    public required TestStatus Status { get; init; }
    public required RuleOutcomeDisposition Disposition { get; init; }
    public required string Code { get; init; }
    public required string Reason { get; init; }
    public bool Executed { get; init; }
    public bool EvidencePresent { get; init; }
    public bool ExpectationSatisfied { get; init; }
    public bool ProductDefectDetected { get; init; }
    public bool RequiresReview { get; init; }
    public string[] ObservationIds { get; init; } = [];
}

public sealed record TestResultSummary
{
    public required TestStatus Status { get; init; }
    public int Total { get; init; }
    public int Pass { get; init; }
    public int Fail { get; init; }
    public int Error { get; init; }
    public int Pending { get; init; }
}

public sealed record TestResultDocument
{
    public string SchemaVersion { get; init; } = "1.0";
    public string TestPackId { get; init; } = "";
    public string TestPackSha256 { get; init; } = "";
    public TestResult[] Results { get; init; } = [];
    public required TestResultSummary Summary { get; init; }
    public required TestResult OverallResult { get; init; }
}

/// <summary>모든 테스트 판정을 소유하는 순수 평가기다.</summary>
public sealed class ResultEvaluator
{
    private static readonly string[] UnresolvedMarkers = ["TODO_INTERNAL", "UNRESOLVED"];

    /// <summary>한 케이스의 실행·증거·기대 계약을 보수적으로 평가한다.</summary>
    public TestResult Evaluate(ResultEvaluationCase input)
    {
        ArgumentNullException.ThrowIfNull(input);
        var expected = input.ExpectedResult ?? new ExpectedResult();
        var policy = input.EvaluationPolicy ?? new EvaluationPolicy();
        var observations = input.Observations ?? [];

        var executed = observations.Where(item => item.Executed).ToArray();
        var infrastructure = executed.FirstOrDefault(item => item.Kind == ObservationKind.InfrastructureError);
        if (infrastructure is not null)
            return Result(input, TestStatus.ERROR, RuleOutcomeDisposition.Unexpected, "INFRASTRUCTURE_ERROR", MessageOr(infrastructure, "실행 인프라 오류가 관찰되었습니다."), false, false, false, infrastructure);

        if (!input.Executed)
            return Pending(input, policy.NotExecutedStatus, RuleOutcomeDisposition.Review, "NOT_EXECUTED", "실행되지 않은 케이스는 PASS로 판정할 수 없습니다.", false);

        var evidence = executed.Where(item => item.EvidencePresent && item.Kind != ObservationKind.EvidenceMissing).ToArray();
        if (evidence.Length == 0)
            return Pending(input, policy.MissingEvidenceStatus, RuleOutcomeDisposition.Review, "EVIDENCE_MISSING", "실행 증거가 없어 결과를 확정할 수 없습니다.", false);

        var productFailures = evidence.Where(item => item.Kind == ObservationKind.ProductFailure).ToArray();
        if (productFailures.Length > 0)
        {
            if (expected.Type == RuleExpectedOutcomeType.FailureRequired
                && HasMatchers(expected)
                && productFailures.All(item => MatchesExpectedSignal(expected, item.Message, item.SourceCode)))
                return Pass(input, "EXPECTED_FAILURE_OBSERVED", "지정한 실패 반응이 관찰되었습니다.", productFailures);

            return Result(input, TestStatus.FAIL, RuleOutcomeDisposition.Defect, "PRODUCT_FAILURE_DETECTED", "시스템·통신·인증·프로그램 실패는 허용 규칙으로 제외하지 않습니다.", false, true, false, productFailures);
        }

        if (executed.Any(item => !item.EvidencePresent || item.Kind == ObservationKind.EvidenceMissing))
            return Pending(input, policy.MissingEvidenceStatus, RuleOutcomeDisposition.Review, "EVIDENCE_MISSING", "필수 실행 증거 일부가 없어 결과를 확정할 수 없습니다.", false, evidence);

        if (ContainsUnresolvedMarker(expected))
            return Pending(input, policy.UnresolvedExpectationStatus, RuleOutcomeDisposition.Review, "UNRESOLVED_EXPECTATION", "기대값이 TODO_INTERNAL 또는 UNRESOLVED 상태여서 성공을 확정하지 않습니다.", false, evidence);

        if (expected.Type == RuleExpectedOutcomeType.ObservationOnly)
            return Pending(input, policy.ObservationOnlyStatus, RuleOutcomeDisposition.Observed, "OBSERVATION_RECORDED", "관찰 전용 결과를 기록했으며 검증 PASS로 승격하지 않습니다.", true, evidence);

        if (expected.Type == RuleExpectedOutcomeType.Unspecified)
            return Pending(input, policy.UnresolvedExpectationStatus, RuleOutcomeDisposition.Review, "OUTCOME_EXPECTATION_REQUIRED", "입력 의도가 없어 정상 검증과 결함을 자동 구분할 수 없습니다.", false, evidence);

        return expected.Type switch
        {
            RuleExpectedOutcomeType.Success => EvaluateSuccess(input, evidence),
            RuleExpectedOutcomeType.ValidationAllowed => EvaluateAllowed(input, evidence, ObservationKind.InputValidation, "EXPECTED_VALIDATION_OBSERVED", "입력값에 정의한 검증 반응과 일치합니다."),
            RuleExpectedOutcomeType.ValidationRequired => EvaluateRequired(input, evidence, [ObservationKind.InputValidation, ObservationKind.GenericError], "EXPECTED_VALIDATION_OBSERVED", "입력값에 정의한 검증 반응과 일치합니다."),
            RuleExpectedOutcomeType.FailureRequired => EvaluateRequired(input, evidence, [ObservationKind.GenericError], "EXPECTED_FAILURE_OBSERVED", "지정한 실패 반응이 관찰되었습니다."),
            RuleExpectedOutcomeType.NoDataAllowed => EvaluateAllowed(input, evidence, ObservationKind.NoData, "EXPECTED_NO_DATA", "자료 없음이 허용된 입력 조건입니다."),
            RuleExpectedOutcomeType.WarningAllowed => EvaluateAllowed(input, evidence, ObservationKind.Warning, "EXPECTED_WARNING", "정의한 경고 반응과 일치합니다."),
            _ => Pending(input, policy.UnresolvedExpectationStatus, RuleOutcomeDisposition.Review, "OUTCOME_EXPECTATION_REQUIRED", "지원되지 않는 기대 결과 유형입니다.", false, evidence)
        };
    }

    /// <summary>여러 TestResult를 ERROR, FAIL, PENDING, PASS 순서로 요약한다.</summary>
    public TestResultSummary Summarize(IEnumerable<TestResult> results)
    {
        var rows = results?.ToArray() ?? [];
        var status = rows.Any(item => item.Status == TestStatus.ERROR) ? TestStatus.ERROR
            : rows.Any(item => item.Status == TestStatus.FAIL) ? TestStatus.FAIL
            : rows.Any(item => item.Status == TestStatus.PENDING) || rows.Length == 0 ? TestStatus.PENDING
            : TestStatus.PASS;
        return new TestResultSummary
        {
            Status = status,
            Total = rows.Length,
            Pass = rows.Count(item => item.Status == TestStatus.PASS),
            Fail = rows.Count(item => item.Status == TestStatus.FAIL),
            Error = rows.Count(item => item.Status == TestStatus.ERROR),
            Pending = rows.Count(item => item.Status == TestStatus.PENDING)
        };
    }

    /// <summary>완성된 하위 TestResult 집합을 reporter가 직접 소비할 하나의 TestResult로 축약한다.</summary>
    public TestResult Aggregate(string caseId, IEnumerable<TestResult> results)
    {
        var rows = results?.ToArray() ?? [];
        if (rows.Any(item => item.Status == TestStatus.PASS && (!item.Executed || !item.EvidencePresent)))
            throw new InvalidDataException("PASS TestResult에는 executed=true와 evidencePresent=true가 필요합니다.");
        var summary = Summarize(rows);
        if (rows.Length == 0)
            return new TestResult
            {
                CaseId = caseId,
                Status = TestStatus.PENDING,
                Disposition = RuleOutcomeDisposition.Review,
                Code = "NO_TEST_RESULTS",
                Reason = "완성된 하위 TestResult가 없어 전체 결과를 확정할 수 없습니다.",
                RequiresReview = true
            };

        var primary = rows.First(item => item.Status == summary.Status);
        return new TestResult
        {
            CaseId = caseId,
            Status = summary.Status,
            Disposition = summary.Status switch
            {
                TestStatus.PASS => RuleOutcomeDisposition.Expected,
                TestStatus.FAIL when rows.Any(item => item.Status == TestStatus.FAIL && item.ProductDefectDetected) => RuleOutcomeDisposition.Defect,
                TestStatus.FAIL => RuleOutcomeDisposition.Unexpected,
                TestStatus.ERROR => RuleOutcomeDisposition.Unexpected,
                _ when rows.Where(item => item.Status == TestStatus.PENDING).All(item => item.Disposition == RuleOutcomeDisposition.Observed) => RuleOutcomeDisposition.Observed,
                _ => RuleOutcomeDisposition.Review
            },
            Code = rows.Length == 1 ? primary.Code : $"AGGREGATE_{summary.Status}",
            Reason = rows.Length == 1
                ? primary.Reason
                : $"하위 TestResult {summary.Total}개: PASS={summary.Pass}, FAIL={summary.Fail}, ERROR={summary.Error}, PENDING={summary.Pending}",
            Executed = rows.All(item => item.Executed),
            EvidencePresent = rows.All(item => item.EvidencePresent),
            ExpectationSatisfied = rows.All(item => item.ExpectationSatisfied),
            ProductDefectDetected = rows.Any(item => item.ProductDefectDetected),
            RequiresReview = rows.Any(item => item.RequiresReview),
            ObservationIds = rows.SelectMany(item => item.ObservationIds).Distinct(StringComparer.OrdinalIgnoreCase).ToArray()
        };
    }

    /// <summary>오류코드 또는 메시지 정규식이 기대 matcher와 일치하는지 검사한다.</summary>
    public static bool MatchesExpectedSignal(ExpectedResult expected, string message, string sourceCode)
    {
        if (!string.IsNullOrWhiteSpace(sourceCode)
            && expected.ErrorCodes.Contains(sourceCode, StringComparer.OrdinalIgnoreCase))
            return true;
        return expected.MessagePatterns.Any(pattern => Regex.IsMatch(message ?? string.Empty, pattern, RegexOptions.IgnoreCase));
    }

    private TestResult EvaluateSuccess(ResultEvaluationCase input, Observation[] evidence)
    {
        var unexpected = evidence.Where(item => item.Kind is not ObservationKind.Success and not ObservationKind.Info).ToArray();
        return unexpected.Length == 0
            ? Pass(input, "EXPECTED_SUCCESS", "실행 결과가 성공 기대 계약과 일치합니다.", evidence)
            : Mismatch(input, "UNEXPECTED_APPLICATION_EVENT", "성공 기대값과 다른 업무 이벤트가 관찰되었습니다.", unexpected);
    }

    private TestResult EvaluateAllowed(ResultEvaluationCase input, Observation[] evidence, ObservationKind allowedKind, string code, string reason)
    {
        var expected = input.ExpectedResult;
        var applicationEvents = evidence.Where(item => item.Kind is not ObservationKind.Success and not ObservationKind.Info).ToArray();
        if (applicationEvents.Length == 0) return Pass(input, "EXPECTED_SUCCESS", "허용 계약을 위반하지 않고 실행되었습니다.", evidence);
        if (applicationEvents.Any(item => item.Kind != allowedKind && !(allowedKind == ObservationKind.InputValidation && item.Kind == ObservationKind.GenericError)))
            return Mismatch(input, "UNEXPECTED_APPLICATION_EVENT", "관찰 결과가 허용된 결과 유형과 일치하지 않습니다.", applicationEvents);
        if (HasMatchers(expected) && applicationEvents.Any(item => !MatchesExpectedSignal(expected, item.Message, item.SourceCode)))
            return Mismatch(input, "EXPECTED_MATCHER_MISMATCH", "관찰 결과가 정의한 문구 또는 오류 코드와 일치하지 않습니다.", applicationEvents);
        return Pass(input, code, reason, applicationEvents);
    }

    private TestResult EvaluateRequired(ResultEvaluationCase input, Observation[] evidence, ObservationKind[] requiredKinds, string code, string reason)
    {
        var expected = input.ExpectedResult;
        if (!HasMatchers(expected))
            return Pending(input, input.EvaluationPolicy.MissingEvidenceStatus, RuleOutcomeDisposition.Review, "EXPECTED_MATCHER_REQUIRED", "필수 기대 결과에는 문구 또는 오류 코드 matcher가 필요합니다.", false, evidence);
        var candidates = evidence.Where(item => requiredKinds.Contains(item.Kind)).ToArray();
        if (candidates.Length == 0)
            return Result(input, TestStatus.FAIL, RuleOutcomeDisposition.Defect, "EXPECTED_OUTCOME_NOT_OBSERVED", "필수로 정의한 반응이 관찰되지 않았습니다.", false, true, false, evidence);
        if (candidates.Any(item => !MatchesExpectedSignal(expected, item.Message, item.SourceCode)))
            return Mismatch(input, "EXPECTED_MATCHER_MISMATCH", "관찰 결과가 필수 matcher와 일치하지 않습니다.", candidates);
        return Pass(input, code, reason, candidates);
    }

    private TestResult Mismatch(ResultEvaluationCase input, string code, string reason, params Observation[] evidence)
    {
        var requested = input.EvaluationPolicy.MatcherMismatchStatus;
        var status = requested == TestStatus.PASS ? TestStatus.FAIL : requested;
        var disposition = status == TestStatus.PENDING ? RuleOutcomeDisposition.Review : RuleOutcomeDisposition.Defect;
        return Result(input, status, disposition, code, reason, false, status == TestStatus.FAIL, status == TestStatus.PENDING, evidence);
    }

    private static bool HasMatchers(ExpectedResult expected) => expected.MessagePatterns.Length > 0 || expected.ErrorCodes.Length > 0;

    private static bool ContainsUnresolvedMarker(ExpectedResult expected)
    {
        var values = new[] { expected.ExpectationId, expected.Description }
            .Concat(expected.MessagePatterns)
            .Concat(expected.ErrorCodes);
        return values.Any(value => UnresolvedMarkers.Any(marker => (value ?? "").Contains(marker, StringComparison.OrdinalIgnoreCase)));
    }

    private static string MessageOr(Observation observation, string fallback) => string.IsNullOrWhiteSpace(observation.Message) ? fallback : observation.Message;

    private TestResult Pass(ResultEvaluationCase input, string code, string reason, params Observation[] evidence) =>
        Result(input, TestStatus.PASS, RuleOutcomeDisposition.Expected, code, reason, true, false, false, evidence);

    private TestResult Pending(ResultEvaluationCase input, TestStatus requested, RuleOutcomeDisposition disposition, string code, string reason, bool expectationSatisfied, params Observation[] evidence)
    {
        var status = requested == TestStatus.PASS ? TestStatus.PENDING : requested;
        return Result(input, status, disposition, code, reason, expectationSatisfied, false, disposition == RuleOutcomeDisposition.Review, evidence);
    }

    private static TestResult Result(
        ResultEvaluationCase input,
        TestStatus status,
        RuleOutcomeDisposition disposition,
        string code,
        string reason,
        bool expectationSatisfied,
        bool productDefect,
        bool requiresReview,
        params Observation[] evidence) => new()
        {
            CaseId = input.CaseId,
            Status = status,
            Disposition = disposition,
            Code = code,
            Reason = reason,
            Executed = input.Executed,
            EvidencePresent = evidence.Length > 0,
            ExpectationSatisfied = expectationSatisfied,
            ProductDefectDetected = productDefect,
            RequiresReview = requiresReview,
            ObservationIds = evidence.Select(item => item.ObservationId).Where(id => !string.IsNullOrWhiteSpace(id)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray()
        };
}
