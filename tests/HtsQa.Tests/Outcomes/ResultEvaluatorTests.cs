// 역할: ResultEvaluator가 실행 여부·증거·matcher·정책을 보수적인 단일 TestResult로 변환하는지 검증한다.
// 범위: UI·파일·PowerShell 없이 순수 평가 행렬과 요약 우선순위만 검사한다.
// 안전: 미실행·무증거·미해결·관찰 전용 결과가 PASS로 승격되지 않는 계약을 고정한다.
using HtsQa.Core;
using System.Text.Json;

namespace HtsQa.Tests;

public sealed class ResultEvaluatorTests
{
    private readonly ResultEvaluator evaluator = new();

    [Fact]
    public void Not_Executed_Cannot_Pass()
    {
        var result = evaluator.Evaluate(Case(executed: false, RuleExpectedOutcomeType.Success, ObservationKind.Success));

        Assert.Equal(TestStatus.PENDING, result.Status);
        Assert.Equal("NOT_EXECUTED", result.Code);
        Assert.False(result.Executed);
        Assert.False(result.EvidencePresent);
    }

    [Fact]
    public void Executed_Without_Evidence_Is_Pending()
    {
        var input = Case(executed: true, RuleExpectedOutcomeType.Success);

        var result = evaluator.Evaluate(input);

        Assert.Equal(TestStatus.PENDING, result.Status);
        Assert.Equal("EVIDENCE_MISSING", result.Code);
    }

    [Fact]
    public void Partial_Evidence_Missing_Cannot_Be_Hidden_By_Success_Evidence()
    {
        var input = Case(
            executed: true,
            RuleExpectedOutcomeType.Success,
            [
                new Observation { ObservationId = "success", Kind = ObservationKind.Success },
                new Observation { ObservationId = "missing", Kind = ObservationKind.EvidenceMissing, EvidencePresent = false }
            ]);

        var result = evaluator.Evaluate(input);

        Assert.Equal(TestStatus.PENDING, result.Status);
        Assert.Equal("REQUIRED_CHECKPOINT_EVIDENCE_MISSING", result.Code);
    }

    [Theory]
    [InlineData("종목코드오류", "", TestStatus.PASS, "EXPECTED_VALIDATION_OBSERVED")]
    [InlineData("다른 문구", "", TestStatus.FAIL, "EXPECTED_MATCHER_MISMATCH")]
    [InlineData("", "E100", TestStatus.PASS, "EXPECTED_VALIDATION_OBSERVED")]
    public void Required_Matcher_Determines_Result(string message, string sourceCode, TestStatus status, string code)
    {
        var input = Case(
            executed: true,
            RuleExpectedOutcomeType.ValidationRequired,
            [new Observation { ObservationId = "signal", Kind = ObservationKind.InputValidation, Message = message, SourceCode = sourceCode }],
            patterns: ["종목코드오류"],
            errorCodes: ["E100"]);

        var result = evaluator.Evaluate(input);

        Assert.Equal(status, result.Status);
        Assert.Equal(code, result.Code);
    }

    [Fact]
    public void Invalid_Stock_Code_Without_Required_Validation_Is_Fail_Not_Pass()
    {
        var input = Case(
            executed: true,
            RuleExpectedOutcomeType.ValidationRequired,
            [new Observation { ObservationId = "business-success", Kind = ObservationKind.Success, Message = "조회 완료" }],
            patterns: ["종목코드오류"]);

        var result = evaluator.Evaluate(input);

        Assert.Equal(TestStatus.FAIL, result.Status);
        Assert.Equal("EXPECTED_OUTCOME_NOT_OBSERVED", result.Code);
        Assert.True(result.ProductDefectDetected);
    }

    [Fact]
    public void ValidationAllowed_With_Explicit_Success_Evidence_Can_Pass()
    {
        var result = evaluator.Evaluate(Case(
            executed: true,
            RuleExpectedOutcomeType.ValidationAllowed,
            [new Observation { ObservationId = "success", Kind = ObservationKind.Success, Message = "정상 처리" }]));

        Assert.Equal(TestStatus.PASS, result.Status);
        Assert.Equal("EXPECTED_SUCCESS", result.Code);
    }

    [Fact]
    public void ValidationAllowed_With_Info_Only_Is_Pending_Not_Pass()
    {
        var result = evaluator.Evaluate(Case(
            executed: true,
            RuleExpectedOutcomeType.ValidationAllowed,
            [new Observation { ObservationId = "info", Kind = ObservationKind.Info, Message = "화면을 관찰함" }]));

        Assert.Equal(TestStatus.PENDING, result.Status);
        Assert.Equal("EXPECTED_SUCCESS_OR_ALLOWED_EVIDENCE_REQUIRED", result.Code);
        Assert.True(result.RequiresReview);
    }

    [Fact]
    public void ValidationAllowed_Validation_Without_Matcher_Is_Pending_Not_Pass()
    {
        var result = evaluator.Evaluate(Case(
            executed: true,
            RuleExpectedOutcomeType.ValidationAllowed,
            [new Observation { ObservationId = "validation", Kind = ObservationKind.InputValidation, Message = "경계 검증" }]));

        Assert.Equal(TestStatus.PENDING, result.Status);
        Assert.Equal("EXPECTED_MATCHER_REQUIRED", result.Code);
    }

    [Fact]
    public void ValidationAllowed_With_Matching_Validation_Evidence_Can_Pass()
    {
        var input = Case(
            executed: true,
            RuleExpectedOutcomeType.ValidationAllowed,
            [new Observation { ObservationId = "validation", Kind = ObservationKind.InputValidation, Message = "경계 검증" }],
            patterns: ["경계 검증"]);

        var result = evaluator.Evaluate(input);

        Assert.Equal(TestStatus.PASS, result.Status);
        Assert.Equal("EXPECTED_VALIDATION_OBSERVED", result.Code);
    }

    [Fact]
    public void Required_Matcher_Fails_When_Any_Collected_Observation_Mismatches()
    {
        var input = Case(
            executed: true,
            RuleExpectedOutcomeType.ValidationRequired,
            [
                new Observation { ObservationId = "first", Kind = ObservationKind.InputValidation, Message = "different-message" },
                new Observation { ObservationId = "second", Kind = ObservationKind.InputValidation, Message = "required-message" }
            ],
            patterns: ["required-message"]);

        var result = evaluator.Evaluate(input);

        Assert.Equal(TestStatus.FAIL, result.Status);
        Assert.Equal("EXPECTED_MATCHER_MISMATCH", result.Code);
    }

    [Fact]
    public void ValidationAllowed_With_Matcher_Mismatch_Is_Not_Optimistic_Pass()
    {
        var input = Case(
            executed: true,
            RuleExpectedOutcomeType.ValidationAllowed,
            [new Observation { ObservationId = "validation", Kind = ObservationKind.InputValidation, Message = "다른 문구" }],
            patterns: ["허용 문구"]);

        var result = evaluator.Evaluate(input);

        Assert.Equal(TestStatus.FAIL, result.Status);
        Assert.Equal(RuleOutcomeDisposition.Defect, result.Disposition);
    }

    [Fact]
    public void ValidationAllowed_Requires_Every_Collected_Application_Event_To_Match()
    {
        var input = Case(
            executed: true,
            RuleExpectedOutcomeType.ValidationAllowed,
            [
                new Observation { ObservationId = "match", Kind = ObservationKind.InputValidation, Message = "allowed-message" },
                new Observation { ObservationId = "mismatch", Kind = ObservationKind.InputValidation, Message = "different-message" }
            ],
            patterns: ["allowed-message"]);

        var result = evaluator.Evaluate(input);

        Assert.Equal(TestStatus.FAIL, result.Status);
        Assert.Equal("EXPECTED_MATCHER_MISMATCH", result.Code);
    }

    [Fact]
    public void Matcher_Mismatch_Can_Be_Explicitly_Pending_But_Never_Pass()
    {
        var input = Case(
            executed: true,
            RuleExpectedOutcomeType.ValidationRequired,
            [new Observation { ObservationId = "validation", Kind = ObservationKind.InputValidation, Message = "다른 문구" }],
            patterns: ["허용 문구"])
            with { EvaluationPolicy = new EvaluationPolicy { MatcherMismatchStatus = TestStatus.PENDING } };

        var result = evaluator.Evaluate(input);

        Assert.Equal(TestStatus.PENDING, result.Status);
        Assert.True(result.RequiresReview);

        var unsafeRequested = evaluator.Evaluate(input with
        {
            EvaluationPolicy = new EvaluationPolicy { MatcherMismatchStatus = TestStatus.PASS }
        });
        Assert.Equal(TestStatus.FAIL, unsafeRequested.Status);
    }

    [Fact]
    public void ObservationOnly_Is_Recorded_But_Not_Validation_Pass()
    {
        var result = evaluator.Evaluate(Case(executed: true, RuleExpectedOutcomeType.ObservationOnly, ObservationKind.Info));

        Assert.Equal(TestStatus.PENDING, result.Status);
        Assert.Equal(RuleOutcomeDisposition.Observed, result.Disposition);
        Assert.True(result.ExpectationSatisfied);
        Assert.False(result.RequiresReview);
    }

    [Theory]
    [InlineData("TODO_INTERNAL")]
    [InlineData("UNRESOLVED")]
    public void Unresolved_Expectation_Cannot_Pass(string marker)
    {
        var input = Case(executed: true, RuleExpectedOutcomeType.Success, ObservationKind.Success)
            with { ExpectedResult = new ExpectedResult { Type = RuleExpectedOutcomeType.Success, Description = marker } };

        var result = evaluator.Evaluate(input);

        Assert.Equal(TestStatus.PENDING, result.Status);
        Assert.Equal("UNRESOLVED_EXPECTATION", result.Code);
    }

    [Fact]
    public void Infrastructure_Error_Is_Error_Not_Test_Failure()
    {
        var result = evaluator.Evaluate(Case(executed: true, RuleExpectedOutcomeType.Success, ObservationKind.InfrastructureError));

        Assert.Equal(TestStatus.ERROR, result.Status);
        Assert.Equal("INFRASTRUCTURE_ERROR", result.Code);
        Assert.False(result.ProductDefectDetected);
        Assert.True(result.EvidencePresent);
    }

    [Fact]
    public void FailureRequired_Passes_Only_When_All_Product_Failures_Match()
    {
        var matching = Case(
            executed: true,
            RuleExpectedOutcomeType.FailureRequired,
            [new Observation { ObservationId = "expected", Kind = ObservationKind.ProductFailure, Message = "expected-failure" }],
            patterns: ["expected-failure"]);
        Assert.Equal(TestStatus.PASS, evaluator.Evaluate(matching).Status);

        var mixed = matching with
        {
            Observations =
            [
                matching.Observations[0],
                new Observation { ObservationId = "unexpected", Kind = ObservationKind.ProductFailure, Message = "different-failure", EvidenceRole = ObservationEvidenceRole.Checkpoint }
            ]
        };
        Assert.Equal(TestStatus.FAIL, evaluator.Evaluate(mixed).Status);
    }

    [Fact]
    public void Infrastructure_Error_Takes_Precedence_Even_When_Action_Did_Not_Start()
    {
        var result = evaluator.Evaluate(Case(executed: false, RuleExpectedOutcomeType.Success, ObservationKind.InfrastructureError));

        Assert.Equal(TestStatus.ERROR, result.Status);
        Assert.False(result.Executed);
    }

    [Fact]
    public void Infrastructure_Error_Cannot_Be_Downgraded_By_Policy()
    {
        var input = Case(executed: true, RuleExpectedOutcomeType.Success, ObservationKind.InfrastructureError)
            with { EvaluationPolicy = new EvaluationPolicy { InfrastructureErrorStatus = TestStatus.PASS } };

        var result = evaluator.Evaluate(input);

        Assert.Equal(TestStatus.ERROR, result.Status);
    }
    [Fact]
    public void Action_Delivery_Without_Checkpoint_Cannot_Pass()
    {
        var action = evaluator.Evaluate(Case(
            executed: true,
            RuleExpectedOutcomeType.Success,
            [new Observation
            {
                ObservationId = "click",
                Kind = ObservationKind.Success,
                EvidenceRole = ObservationEvidenceRole.Action,
                CheckpointRequired = false
            }]));

        Assert.Equal(TestStatus.PENDING, action.Status);
        Assert.Equal("ACTION_DELIVERED", action.Code);
        Assert.True(action.ActionSent);
        Assert.True(action.ActionVerified);
        Assert.Equal(ObservationEvidenceRole.Action, action.EvidenceRole);

        var aggregate = evaluator.Aggregate("click-only", [action]);
        Assert.Equal(TestStatus.PENDING, aggregate.Status);
        Assert.Equal("REQUIRED_CHECKPOINT_MISSING", aggregate.Code);
    }

    [Fact]
    public void Input_Delivery_With_Unobserved_Required_Message_Cannot_Pass()
    {
        var result = evaluator.Evaluate(Case(
            executed: true,
            RuleExpectedOutcomeType.Success,
            [
                new Observation
                {
                    ObservationId = "input",
                    Kind = ObservationKind.Success,
                    EvidenceRole = ObservationEvidenceRole.Action,
                    CheckpointRequired = false
                },
                new Observation
                {
                    ObservationId = "required-message",
                    Kind = ObservationKind.EvidenceMissing,
                    Executed = true,
                    EvidencePresent = false,
                    EvidenceRole = ObservationEvidenceRole.Checkpoint,
                    CheckpointRequired = true
                }
            ]));

        Assert.Equal(TestStatus.PENDING, result.Status);
        Assert.Equal("REQUIRED_CHECKPOINT_EVIDENCE_MISSING", result.Code);
    }

    [Fact]
    public void Required_Checkpoint_Passes_Only_After_Product_Evidence()
    {
        var action = evaluator.Evaluate(Case(
            executed: true,
            RuleExpectedOutcomeType.Success,
            [new Observation
            {
                ObservationId = "input",
                Kind = ObservationKind.Success,
                EvidenceRole = ObservationEvidenceRole.Action,
                CheckpointRequired = false
            }])) with { CaseId = "action" };
        var checkpoint = evaluator.Evaluate(Case(
            executed: true,
            RuleExpectedOutcomeType.Success,
            [new Observation
            {
                ObservationId = "message",
                Kind = ObservationKind.Success,
                EvidenceRole = ObservationEvidenceRole.Checkpoint,
                CheckpointRequired = true
            }])) with { CaseId = "checkpoint" };

        Assert.Equal(TestStatus.PASS, checkpoint.Status);
        var aggregate = evaluator.Aggregate("with-checkpoint", [action, checkpoint]);
        Assert.Equal(TestStatus.PASS, aggregate.Status);
        Assert.True(aggregate.EvidencePresent);
        Assert.True(aggregate.ExpectationSatisfied);
    }

    [Fact]
    public void Required_Checkpoint_Partially_Not_Executed_Cannot_Pass()
    {
        var result = evaluator.Evaluate(Case(
            executed: true,
            RuleExpectedOutcomeType.Success,
            [
                new Observation { ObservationId = "done", Kind = ObservationKind.Success, EvidenceRole = ObservationEvidenceRole.Checkpoint },
                new Observation { ObservationId = "not-run", Kind = ObservationKind.Success, Executed = false, EvidenceRole = ObservationEvidenceRole.Checkpoint }
            ]));

        Assert.Equal(TestStatus.PENDING, result.Status);
        Assert.Equal("REQUIRED_CHECKPOINT_NOT_EXECUTED", result.Code);
    }

    [Fact]
    public void Optional_Checkpoint_Missing_Is_Non_Blocking_But_Executed_Failure_Blocks()
    {
        var required = new Observation
        {
            ObservationId = "required",
            Kind = ObservationKind.Success,
            EvidenceRole = ObservationEvidenceRole.Checkpoint,
            CheckpointRequired = true
        };
        var missingOptional = new Observation
        {
            ObservationId = "optional-missing",
            Kind = ObservationKind.EvidenceMissing,
            Executed = false,
            EvidencePresent = false,
            EvidenceRole = ObservationEvidenceRole.Checkpoint,
            CheckpointRequired = false
        };
        var failedOptional = missingOptional with
        {
            ObservationId = "optional-failed",
            Kind = ObservationKind.InputValidation,
            Executed = true,
            EvidencePresent = true
        };

        Assert.Equal(TestStatus.PASS, evaluator.Evaluate(Case(
            executed: true,
            RuleExpectedOutcomeType.Success,
            [required, missingOptional])).Status);

        var failure = evaluator.Evaluate(Case(
            executed: true,
            RuleExpectedOutcomeType.Success,
            [required, failedOptional]));
        Assert.Equal(TestStatus.FAIL, failure.Status);
        Assert.Equal("UNEXPECTED_APPLICATION_EVENT", failure.Code);
    }

    [Fact]
    public void Unspecified_Evidence_Role_Is_Fail_Closed()
    {
        var input = new ResultEvaluationCase
        {
            CaseId = "unresolved-role",
            Executed = true,
            ExpectedResult = new ExpectedResult { Type = RuleExpectedOutcomeType.Success },
            Observations = [new Observation { ObservationId = "unknown", Kind = ObservationKind.Success, EvidenceRole = ObservationEvidenceRole.Unspecified }]
        };

        var result = evaluator.Evaluate(input);

        Assert.Equal(TestStatus.PENDING, result.Status);
        Assert.Equal("EVIDENCE_ROLE_REQUIRED", result.Code);
    }

    [Fact]
    public void Aggregate_Rejects_Action_Pass_From_External_Completed_Result()
    {
        var invalid = new TestResult
        {
            CaseId = "action-pass",
            Status = TestStatus.PASS,
            Disposition = RuleOutcomeDisposition.Expected,
            Code = "ACTION_SENT",
            Reason = "delivery only",
            Executed = true,
            EvidencePresent = true,
            EvidenceRole = ObservationEvidenceRole.Action,
            CheckpointRequired = false,
            ActionSent = true,
            ActionVerified = true
        };

        Assert.Throws<InvalidDataException>(() => evaluator.Aggregate("report", [invalid]));
    }

    [Fact]
    public void Legacy_TestResult_Json_Remains_Consumable_As_Required_Checkpoint()
    {
        const string json = """
            {
              "caseId": "legacy",
              "status": "PASS",
              "disposition": "Expected",
              "code": "EXPECTED_SUCCESS",
              "reason": "legacy",
              "executed": true,
              "evidencePresent": true,
              "expectationSatisfied": true
            }
            """;

        var result = JsonSerializer.Deserialize<TestResult>(json, JsonDefaults.Options);

        Assert.NotNull(result);
        Assert.Equal(ObservationEvidenceRole.Checkpoint, result.EvidenceRole);
        Assert.True(result.CheckpointRequired);
        Assert.Equal(TestStatus.PASS, evaluator.Aggregate("legacy-overall", [result]).Status);
    }


    [Fact]
    public void Summary_Uses_Error_Fail_Pending_Pass_Precedence()
    {
        var results = new[]
        {
            evaluator.Evaluate(Case(executed: true, RuleExpectedOutcomeType.Success, ObservationKind.Success) with { CaseId = "pass" }),
            evaluator.Evaluate(Case(executed: false, RuleExpectedOutcomeType.Success) with { CaseId = "pending" }),
            evaluator.Evaluate(Case(executed: true, RuleExpectedOutcomeType.Success, ObservationKind.InputValidation) with { CaseId = "fail" }),
            evaluator.Evaluate(Case(executed: true, RuleExpectedOutcomeType.Success, ObservationKind.InfrastructureError) with { CaseId = "error" })
        };

        var summary = evaluator.Summarize(results);

        Assert.Equal(TestStatus.ERROR, summary.Status);
        Assert.Equal(1, summary.Pass);
        Assert.Equal(1, summary.Fail);
        Assert.Equal(1, summary.Pending);
        Assert.Equal(1, summary.Error);
    }

    [Fact]
    public void Aggregate_Returns_A_Completed_TestResult_For_Reporter()
    {
        var childResults = new[]
        {
            evaluator.Evaluate(Case(executed: true, RuleExpectedOutcomeType.Success, ObservationKind.Success) with { CaseId = "pass" }),
            evaluator.Evaluate(Case(executed: false, RuleExpectedOutcomeType.Success) with { CaseId = "pending" })
        };

        var aggregate = evaluator.Aggregate("report-case", childResults);

        Assert.Equal("report-case", aggregate.CaseId);
        Assert.Equal(TestStatus.PENDING, aggregate.Status);
        Assert.Equal("AGGREGATE_PENDING", aggregate.Code);
        Assert.True(aggregate.RequiresReview);
    }

    [Fact]
    public void Aggregate_Rejects_Unexecuted_Pass_From_External_Completed_Result()
    {
        var invalid = new TestResult
        {
            CaseId = "invalid",
            Status = TestStatus.PASS,
            Disposition = RuleOutcomeDisposition.Expected,
            Code = "INVALID_EXTERNAL_PASS",
            Reason = "invalid",
            Executed = false,
            EvidencePresent = true
        };

        Assert.Throws<InvalidDataException>(() => evaluator.Aggregate("report", [invalid]));
    }

    private static ResultEvaluationCase Case(bool executed, RuleExpectedOutcomeType type, params ObservationKind[] kinds) =>
        Case(executed, type, kinds.Select((kind, index) => new Observation
        {
            ObservationId = $"observation-{index + 1}",
            Kind = kind
        }).ToArray());

    private static ResultEvaluationCase Case(
        bool executed,
        RuleExpectedOutcomeType type,
        Observation[] observations,
        string[]? patterns = null,
        string[]? errorCodes = null) => new()
        {
            CaseId = "case-1",
            Executed = executed,
            ExpectedResult = new ExpectedResult
            {
                Type = type,
                MessagePatterns = patterns ?? [],
                ErrorCodes = errorCodes ?? []
            },
            Observations = observations.Select(item =>
                item.EvidenceRole == ObservationEvidenceRole.Unspecified
                    ? item with { EvidenceRole = ObservationEvidenceRole.Checkpoint }
                    : item).ToArray()
        };
}
