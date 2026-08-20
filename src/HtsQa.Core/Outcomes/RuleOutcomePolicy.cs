// 역할: 관찰된 팝업·로그·응답 이벤트를 값별 기대 계약과 비교해 정상 검증, 결함, 보류로 분류한다.
// 입력/출력: RuleObservedEventType과 expectedOutcome을 RuleOutcomeJudgment 및 감사용 근거 코드로 변환한다.
// 경계: 시스템 실패가 최우선이며 의도 미지정 업무 이벤트를 FAIL로 추측하지 않고 Review로 남긴다.
// 수정 지점: 판정 우선순위를 바꾸면 RuleOutcomePolicyTests와 docs/ERROR_JUDGMENT_POLICY.md를 함께 갱신한다.
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

/// <summary>기존 호출 계약을 ResultEvaluator의 단일 판정 소스로 연결하는 호환 어댑터다.</summary>
public static class RuleOutcomePolicy
{
    /// <summary>기존 signal 호출을 순수 ResultEvaluator 입력으로 바꿔 동일한 근거 코드를 반환한다.</summary>
    public static RuleOutcomeJudgment Evaluate(
        RuleObservedEventType eventType,
        RuleExpectedOutcome? expectedOutcome,
        string message = "",
        string sourceCode = "")
    {
        var expected = ExpectedResult.FromRuleExpectedOutcome(expectedOutcome);
        var result = new ResultEvaluator().Evaluate(new ResultEvaluationCase
        {
            CaseId = "legacy-signal",
            Executed = true,
            ExpectedResult = expected,
            Observations =
            [
                new Observation
                {
                    ObservationId = "legacy-signal-1",
                    Kind = eventType switch
                    {
                        RuleObservedEventType.Success => ObservationKind.Success,
                        RuleObservedEventType.InputValidation => ObservationKind.InputValidation,
                        RuleObservedEventType.NoData => ObservationKind.NoData,
                        RuleObservedEventType.Warning => ObservationKind.Warning,
                        RuleObservedEventType.ProductFailure => ObservationKind.ProductFailure,
                        _ => ObservationKind.GenericError
                    },
                    Executed = true,
                    EvidencePresent = true,
                    Message = message,
                    SourceCode = sourceCode
                }
            ]
        });
        return new RuleOutcomeJudgment
        {
            EventType = result.Code == "EXPECTED_VALIDATION_OBSERVED" ? RuleObservedEventType.InputValidation : eventType,
            Disposition = result.Disposition,
            Code = result.Code,
            Reason = result.Reason,
            ProductDefectDetected = result.ProductDefectDetected,
            RequiresReview = result.RequiresReview,
            ExpectationSatisfied = result.ExpectationSatisfied
        };
    }

    /// <summary>기대 문구 정규식 또는 오류코드가 현재 관찰 신호와 일치하는지 검사한다.</summary>
    public static bool MatchesExpectedSignal(RuleExpectedOutcome expected, string message, string sourceCode)
    {
        return ResultEvaluator.MatchesExpectedSignal(ExpectedResult.FromRuleExpectedOutcome(expected), message, sourceCode);
    }
}
