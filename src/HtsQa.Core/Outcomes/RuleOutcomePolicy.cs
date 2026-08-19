// 역할: 관찰된 팝업·로그·응답 이벤트를 값별 기대 계약과 비교해 정상 검증, 결함, 보류로 분류한다.
// 입력/출력: RuleObservedEventType과 expectedOutcome을 RuleOutcomeJudgment 및 감사용 근거 코드로 변환한다.
// 경계: 시스템 실패가 최우선이며 의도 미지정 업무 이벤트를 FAIL로 추측하지 않고 Review로 남긴다.
// 수정 지점: 판정 우선순위를 바꾸면 RuleOutcomePolicyTests와 docs/ERROR_JUDGMENT_POLICY.md를 함께 갱신한다.
using System.Text.RegularExpressions;
namespace HtsQa.Core;

public enum RuleObservedEventType
{
    Success,
    InputValidation,
    NoData,
    Warning,
    ProductFailure,
    GenericError
}

public enum RuleOutcomeDisposition
{
    Expected,
    Unexpected,
    Defect,
    Review,
    Observed
}

public sealed record RuleOutcomeJudgment
{
    public required RuleObservedEventType EventType { get; init; }
    public required RuleOutcomeDisposition Disposition { get; init; }
    public required string Code { get; init; }
    public required string Reason { get; init; }
    public bool ProductDefectDetected { get; init; }
    public bool RequiresReview { get; init; }
    public bool ExpectationSatisfied { get; init; }
}

/// <summary>관찰 이벤트와 expectedOutcome 계약을 비교하는 공통 오류 판정 정책이다.</summary>
public static class RuleOutcomePolicy
{
    /// <summary>관찰 종류, 문구, 코드와 기대 계약을 종합해 최종 판정과 근거 코드를 반환한다.</summary>
    public static RuleOutcomeJudgment Evaluate(
        RuleObservedEventType eventType,
        RuleExpectedOutcome? expectedOutcome,
        string message = "",
        string sourceCode = "")
    {
        var expected = expectedOutcome ?? new RuleExpectedOutcome();
        var hasMatchers = expected.MessagePatterns.Length > 0 || expected.ErrorCodes.Length > 0;
        var matches = MatchesExpectedSignal(expected, message, sourceCode);

        if (eventType == RuleObservedEventType.ProductFailure)
        {
            if (expected.Type == RuleExpectedOutcomeType.FailureRequired && matches)
                return Expected(eventType, "EXPECTED_FAILURE_OBSERVED", "지정한 실패 반응이 관찰되었습니다.");

            return Defect(eventType, "PRODUCT_FAILURE_DETECTED", "시스템·통신·인증·프로그램 실패는 입력 검증 허용 규칙으로 제외하지 않습니다.");
        }

        if (eventType is RuleObservedEventType.InputValidation or RuleObservedEventType.GenericError)
        {
            if (expected.Type is RuleExpectedOutcomeType.ValidationAllowed or RuleExpectedOutcomeType.ValidationRequired
                && (!hasMatchers || matches))
                return Expected(RuleObservedEventType.InputValidation, "EXPECTED_VALIDATION_OBSERVED", "입력값에 정의한 검증 반응과 일치합니다.");

            if (expected.Type == RuleExpectedOutcomeType.FailureRequired && matches)
                return Expected(eventType, "EXPECTED_FAILURE_OBSERVED", "지정한 실패 반응이 관찰되었습니다.");

            return EvaluateUnexpectedApplicationEvent(eventType, expected.Type, hasMatchers);
        }

        if (eventType == RuleObservedEventType.NoData)
        {
            if (expected.Type == RuleExpectedOutcomeType.NoDataAllowed && (!hasMatchers || matches))
                return Expected(eventType, "EXPECTED_NO_DATA", "자료 없음이 허용된 입력 조건입니다.");

            return EvaluateUnexpectedApplicationEvent(eventType, expected.Type, hasMatchers);
        }

        if (eventType == RuleObservedEventType.Warning)
        {
            if (expected.Type == RuleExpectedOutcomeType.WarningAllowed && (!hasMatchers || matches))
                return Expected(eventType, "EXPECTED_WARNING", "정의한 경고 반응과 일치합니다.");

            return EvaluateUnexpectedApplicationEvent(eventType, expected.Type, hasMatchers);
        }

        if (expected.Type is RuleExpectedOutcomeType.ValidationRequired or RuleExpectedOutcomeType.FailureRequired)
            return Defect(eventType, "EXPECTED_OUTCOME_NOT_OBSERVED", "필수로 정의한 반응이 관찰되지 않았습니다.");

        return Expected(eventType, "EXPECTED_SUCCESS", "실행 결과가 기대 계약을 위반하지 않았습니다.");
    }

    /// <summary>기대 문구 정규식 또는 오류코드가 현재 관찰 신호와 일치하는지 검사한다.</summary>
    public static bool MatchesExpectedSignal(RuleExpectedOutcome expected, string message, string sourceCode)
    {
        if (!string.IsNullOrWhiteSpace(sourceCode)
            && expected.ErrorCodes.Contains(sourceCode, StringComparer.OrdinalIgnoreCase))
            return true;

        foreach (var pattern in expected.MessagePatterns)
        {
            if (Regex.IsMatch(message ?? string.Empty, pattern, RegexOptions.IgnoreCase))
                return true;
        }

        return false;
    }

    private static RuleOutcomeJudgment EvaluateUnexpectedApplicationEvent(
        RuleObservedEventType eventType,
        RuleExpectedOutcomeType expectedType,
        bool hasMatchers)
    {
        if (expectedType == RuleExpectedOutcomeType.Unspecified)
            return Review(eventType, "OUTCOME_EXPECTATION_REQUIRED", "입력 의도가 없어 정상 검증과 결함을 자동 구분할 수 없습니다.");

        if (expectedType == RuleExpectedOutcomeType.ObservationOnly)
            return new RuleOutcomeJudgment
            {
                EventType = eventType,
                Disposition = RuleOutcomeDisposition.Observed,
                Code = "OBSERVATION_RECORDED",
                Reason = "관찰 전용 입력의 반응을 기록했습니다.",
                ExpectationSatisfied = true
            };

        var reason = hasMatchers
            ? "관찰 결과가 이 입력값에 정의한 문구 또는 오류 코드와 일치하지 않습니다."
            : "관찰 결과가 이 입력값에 정의한 결과 유형과 일치하지 않습니다.";
        return Defect(eventType, "UNEXPECTED_APPLICATION_EVENT", reason);
    }

    private static RuleOutcomeJudgment Expected(RuleObservedEventType eventType, string code, string reason) => new()
    {
        EventType = eventType,
        Disposition = RuleOutcomeDisposition.Expected,
        Code = code,
        Reason = reason,
        ExpectationSatisfied = true
    };

    private static RuleOutcomeJudgment Defect(RuleObservedEventType eventType, string code, string reason) => new()
    {
        EventType = eventType,
        Disposition = RuleOutcomeDisposition.Defect,
        Code = code,
        Reason = reason,
        ProductDefectDetected = true
    };

    private static RuleOutcomeJudgment Review(RuleObservedEventType eventType, string code, string reason) => new()
    {
        EventType = eventType,
        Disposition = RuleOutcomeDisposition.Review,
        Code = code,
        Reason = reason,
        RequiresReview = true
    };
}
