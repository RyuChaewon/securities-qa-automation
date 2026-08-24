// 역할: optional Checkpoint의 비차단 성공과 차단 실패 정책을 개별 TestResult 집계 경로에서 고정한다.
// 범위: UI나 파일 없이 순수 ResultEvaluator 입력과 aggregate verdict만 검증한다.
// 안전: optional Checkpoint가 required Checkpoint를 대신해 PASS를 만들지 못하게 한다.
using HtsQa.Core;

namespace HtsQa.Tests;

public sealed class OptionalCheckpointPolicyTests
{
    private readonly ResultEvaluator evaluator = new();

    [Fact]
    public void Optional_Checkpoint_Is_Nonblocking_Unless_Executed_Result_Fails()
    {
        var required = Evaluate("required", ObservationKind.Success, required: true);
        var optional = Evaluate("optional", ObservationKind.Success, required: false);
        var optionalMissing = Evaluate("optional-missing", ObservationKind.EvidenceMissing, required: false, executed: false, evidencePresent: false);
        var optionalFailure = Evaluate("optional-failure", ObservationKind.InputValidation, required: false);

        Assert.Equal(TestStatus.PENDING, optional.Status);
        Assert.Equal("OPTIONAL_CHECKPOINT_OBSERVED", optional.Code);
        Assert.Equal(TestStatus.PENDING, optionalMissing.Status);
        Assert.Equal("OPTIONAL_CHECKPOINT_NOT_OBSERVED", optionalMissing.Code);
        Assert.Equal(TestStatus.FAIL, optionalFailure.Status);
        Assert.Equal(TestStatus.PASS, evaluator.Aggregate("nonblocking", [required, optional, optionalMissing]).Status);
        Assert.Equal(TestStatus.FAIL, evaluator.Aggregate("blocking", [required, optionalFailure]).Status);
    }

    private TestResult Evaluate(
        string caseId,
        ObservationKind kind,
        bool required,
        bool executed = true,
        bool evidencePresent = true) => evaluator.Evaluate(new ResultEvaluationCase
        {
            CaseId = caseId,
            Executed = true,
            ExpectedResult = new ExpectedResult { Type = RuleExpectedOutcomeType.Success },
            Observations =
            [
                new Observation
                {
                    ObservationId = caseId,
                    Kind = kind,
                    Executed = executed,
                    EvidencePresent = evidencePresent,
                    EvidenceRole = ObservationEvidenceRole.Checkpoint,
                    CheckpointRequired = required
                }
            ]
        });
}
