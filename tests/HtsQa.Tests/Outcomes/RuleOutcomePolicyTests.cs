// 역할: 기대 입력 검증과 제품 결함을 혼동하지 않도록 오류 판정 우선순위와 회귀 사례를 검증한다.
// 범위: 순수 정책 함수만 검증하고 팝업·로그 수집은 실행기 통합 검증의 책임으로 남긴다.
// 수정 지점: 새 판정 유형은 기대·결함·검토의 대칭 사례와 공식 근거 코드를 함께 검증한다.
using HtsQa.Core;

namespace HtsQa.Tests;

public sealed class RuleOutcomePolicyTests
{
    [Fact]
    public void Invalid_Stock_Code_Validation_Is_Expected_Not_A_Product_Defect()
    {
        var expected = new RuleExpectedOutcome
        {
            Type = RuleExpectedOutcomeType.ValidationRequired,
            MessagePatterns = ["종목코드오류|등록되지 않은 종목코드"]
        };

        var result = RuleOutcomePolicy.Evaluate(
            RuleObservedEventType.GenericError,
            expected,
            "종목코드오류");

        Assert.Equal(RuleOutcomeDisposition.Expected, result.Disposition);
        Assert.Equal("EXPECTED_VALIDATION_OBSERVED", result.Code);
        Assert.True(result.ExpectationSatisfied);
        Assert.False(result.ProductDefectDetected);
    }

    [Fact]
    public void System_Failure_Cannot_Be_Hidden_By_Validation_Allowance()
    {
        var expected = new RuleExpectedOutcome
        {
            Type = RuleExpectedOutcomeType.ValidationAllowed,
            MessagePatterns = ["오류"]
        };

        var result = RuleOutcomePolicy.Evaluate(
            RuleObservedEventType.ProductFailure,
            expected,
            "서버 통신 오류가 발생했습니다.");

        Assert.Equal(RuleOutcomeDisposition.Defect, result.Disposition);
        Assert.Equal("PRODUCT_FAILURE_DETECTED", result.Code);
        Assert.True(result.ProductDefectDetected);
    }

    [Fact]
    public void Validation_From_A_Success_Value_Is_A_Defect()
    {
        var result = RuleOutcomePolicy.Evaluate(
            RuleObservedEventType.InputValidation,
            new RuleExpectedOutcome { Type = RuleExpectedOutcomeType.Success },
            "종목코드를 확인하십시오.");

        Assert.Equal(RuleOutcomeDisposition.Defect, result.Disposition);
        Assert.Equal("UNEXPECTED_APPLICATION_EVENT", result.Code);
        Assert.True(result.ProductDefectDetected);
    }

    [Fact]
    public void Unspecified_Validation_Requires_Review()
    {
        var result = RuleOutcomePolicy.Evaluate(
            RuleObservedEventType.InputValidation,
            null,
            "입력값을 확인하십시오.");

        Assert.Equal(RuleOutcomeDisposition.Review, result.Disposition);
        Assert.Equal("OUTCOME_EXPECTATION_REQUIRED", result.Code);
        Assert.True(result.RequiresReview);
        Assert.False(result.ProductDefectDetected);
    }

    [Fact]
    public void Required_Validation_Missing_Is_A_Defect()
    {
        var expected = new RuleExpectedOutcome
        {
            Type = RuleExpectedOutcomeType.ValidationRequired,
            MessagePatterns = ["종목코드오류"]
        };

        var result = RuleOutcomePolicy.Evaluate(RuleObservedEventType.Success, expected);

        Assert.Equal(RuleOutcomeDisposition.Defect, result.Disposition);
        Assert.Equal("EXPECTED_OUTCOME_NOT_OBSERVED", result.Code);
        Assert.True(result.ProductDefectDetected);
    }
}
