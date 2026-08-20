// 역할: ResultEvaluator 도입 전에 C# 정책과 PowerShell 운영 판정이 달랐던 대표 행렬을 변경 불가 스냅샷으로 기록한다.
// 범위: 기존 구현의 차이만 설명하며 새 canonical 판정의 기대값은 ResultEvaluatorTests가 소유한다.
// 안전: 이 테스트는 UI·파일·프로세스를 사용하지 않고 과거 PowerShell 분기와 순수 C# 정책만 비교한다.
using HtsQa.Core;

namespace HtsQa.Tests;

public sealed class LegacyOutcomeCharacterizationTests
{
    public static TheoryData<string, RuleObservedEventType, RuleExpectedOutcome, string, RuleOutcomeDisposition, RuleOutcomeDisposition, bool, bool> Matrix => new()
    {
        {
            "validation-allowed-matcher-mismatch",
            RuleObservedEventType.InputValidation,
            new RuleExpectedOutcome { Type = RuleExpectedOutcomeType.ValidationAllowed, MessagePatterns = ["허용 문구"] },
            "다른 입력 검증 문구",
            RuleOutcomeDisposition.Defect,
            RuleOutcomeDisposition.Expected,
            false,
            true
        },
        {
            "observation-only-input-validation",
            RuleObservedEventType.InputValidation,
            new RuleExpectedOutcome { Type = RuleExpectedOutcomeType.ObservationOnly },
            "관찰 문구",
            RuleOutcomeDisposition.Observed,
            RuleOutcomeDisposition.Expected,
            true,
            false
        },
        {
            "required-validation-match",
            RuleObservedEventType.InputValidation,
            new RuleExpectedOutcome { Type = RuleExpectedOutcomeType.ValidationRequired, MessagePatterns = ["종목코드오류"] },
            "종목코드오류",
            RuleOutcomeDisposition.Expected,
            RuleOutcomeDisposition.Expected,
            true,
            true
        },
        {
            "unspecified-validation",
            RuleObservedEventType.InputValidation,
            new RuleExpectedOutcome(),
            "입력값을 확인하십시오.",
            RuleOutcomeDisposition.Review,
            RuleOutcomeDisposition.Review,
            false,
            false
        },
        {
            "system-failure-cannot-be-allowed",
            RuleObservedEventType.ProductFailure,
            new RuleExpectedOutcome { Type = RuleExpectedOutcomeType.ValidationAllowed, MessagePatterns = ["오류"] },
            "서버 통신 오류",
            RuleOutcomeDisposition.Defect,
            RuleOutcomeDisposition.Defect,
            false,
            false
        }
    };

    [Theory]
    [MemberData(nameof(Matrix))]
    public void Captures_Legacy_CSharp_And_PowerShell_Differences(
        string id,
        RuleObservedEventType eventType,
        RuleExpectedOutcome expected,
        string message,
        RuleOutcomeDisposition expectedCSharp,
        RuleOutcomeDisposition expectedPowerShell,
        bool expectedCSharpSatisfied,
        bool expectedPowerShellSatisfied)
    {
        var csharp = RuleOutcomePolicy.Evaluate(eventType, expected, message);
        var powerShell = LegacyPowerShellPolicySnapshot.Evaluate(eventType, expected, message);

        Assert.Equal(expectedCSharp, csharp.Disposition);
        Assert.Equal(expectedPowerShell, powerShell.Disposition);
        Assert.Equal(expectedCSharpSatisfied, csharp.ExpectationSatisfied);
        Assert.Equal(expectedPowerShellSatisfied, powerShell.ExpectationSatisfied);
        Assert.False(string.IsNullOrWhiteSpace(id));
    }

    private static class LegacyPowerShellPolicySnapshot
    {
        public static Snapshot Evaluate(RuleObservedEventType eventType, RuleExpectedOutcome expected, string message)
        {
            var matches = RuleOutcomePolicy.MatchesExpectedSignal(expected, message, "");
            var hasMatchers = expected.MessagePatterns.Length > 0 || expected.ErrorCodes.Length > 0;
            var productFailure = eventType == RuleObservedEventType.ProductFailure;

            if (expected.Type == RuleExpectedOutcomeType.FailureRequired && matches && productFailure)
                return new(RuleOutcomeDisposition.Expected, true);
            if (expected.Type == RuleExpectedOutcomeType.ValidationAllowed && eventType == RuleObservedEventType.InputValidation)
                return new(RuleOutcomeDisposition.Expected, true);
            if (expected.Type == RuleExpectedOutcomeType.ValidationRequired
                && eventType is RuleObservedEventType.InputValidation or RuleObservedEventType.GenericError
                && (!hasMatchers || matches))
                return new(RuleOutcomeDisposition.Expected, true);
            if (expected.Type == RuleExpectedOutcomeType.ObservationOnly && !productFailure)
                return new(RuleOutcomeDisposition.Expected, matches);
            if (expected.Type == RuleExpectedOutcomeType.Unspecified
                && eventType is RuleObservedEventType.GenericError or RuleObservedEventType.InputValidation or RuleObservedEventType.NoData or RuleObservedEventType.Warning)
                return new(RuleOutcomeDisposition.Review, false);
            if (expected.Type != RuleExpectedOutcomeType.Unspecified
                && eventType is RuleObservedEventType.GenericError or RuleObservedEventType.InputValidation or RuleObservedEventType.NoData or RuleObservedEventType.Warning)
                return new(RuleOutcomeDisposition.Unexpected, false);
            if (productFailure) return new(RuleOutcomeDisposition.Defect, false);
            if (matches) return new(RuleOutcomeDisposition.Expected, true);
            return new(RuleOutcomeDisposition.Observed, false);
        }

        public sealed record Snapshot(RuleOutcomeDisposition Disposition, bool ExpectationSatisfied);
    }
}
