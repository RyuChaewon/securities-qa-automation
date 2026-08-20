// 역할: 조합 정책, canonical CaseId, maxCases, TestPack 승인·원본 해시 및 Runner 케이스 고정을 회귀 검증한다.
// 범위: 순수 Core 계약만 사용하며 파일, PowerShell, FlaUI 또는 실제 HTS를 실행하지 않는다.
// 수정 지점: TestPack 스키마나 정책 의미를 바꿀 때 이전 결정성·거부 조건을 유지하도록 이 행렬을 갱신한다.
using HtsQa.Core;

namespace HtsQa.Tests;

public sealed class TestPackTests
{
    private const string DatasetSha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    [Fact]
    public void Same_Dataset_Always_Produces_Same_Order_And_CaseIds()
    {
        var dataset = Dataset();
        var first = new CombinationGenerator().Generate(dataset);
        var second = new CombinationGenerator().Generate(dataset with { Variables = dataset.Variables.Reverse().ToArray() });

        Assert.Equal(first.Select(x => x.CaseId), second.Select(x => x.CaseId));
        Assert.Equal(first.Select(x => string.Join('|', x.Variables.OrderBy(v => v.Key).Select(v => $"{v.Key}={v.Value}"))),
            second.Select(x => string.Join('|', x.Variables.OrderBy(v => v.Key).Select(v => $"{v.Key}={v.Value}"))));

        var ordered = new Dictionary<string, string> { ["alpha"] = "1", ["beta"] = "2" };
        var reversed = new Dictionary<string, string> { ["beta"] = "2", ["alpha"] = "1" };
        Assert.Equal(
            CaseIdFactory.CreateRuleCase("dataset", "0102", "account", ordered),
            CaseIdFactory.CreateRuleCase("dataset", "0102", "account", reversed));
    }

    [Fact]
    public void Cartesian_Count_Is_Exact_And_Default()
    {
        var dataset = Dataset();
        var generator = new CombinationGenerator();

        Assert.Equal(CombinationPolicy.Cartesian, dataset.CombinationPolicy);
        Assert.Equal(6, generator.CountCases(dataset));
        Assert.Equal(6, generator.Generate(dataset).Length);
    }

    [Fact]
    public void Pairwise_And_PerControl_Are_Deterministic_Explicit_Policies()
    {
        var dataset = Dataset() with
        {
            Variables =
            [
                Dimension("a", "1", "2", "3"),
                Dimension("b", "1", "2", "3"),
                Dimension("c", "1", "2", "3")
            ]
        };
        var generator = new CombinationGenerator();

        var pairwise = generator.Generate(dataset, CombinationPolicy.Pairwise);
        var perControl = generator.Generate(dataset, CombinationPolicy.PerControl);

        Assert.True(pairwise.Length < 27);
        Assert.Equal(pairwise.Select(x => x.CaseId), generator.Generate(dataset, CombinationPolicy.Pairwise).Select(x => x.CaseId));
        Assert.Equal(7, perControl.Length);
    }

    [Fact]
    public void MaxCases_Exceeded_Fails_Compilation_Without_Truncation()
    {
        var error = Assert.Throws<CombinationLimitExceededException>(() =>
            new TestPackCompiler().Compile(Dataset(), DatasetSha, maxCases: 5));

        Assert.Equal(6, error.ProjectedCases);
        Assert.Equal(5, error.MaxCases);
    }

    [Fact]
    public void Unapproved_TestPack_Is_Rejected_By_Runner()
    {
        var pending = new TestPackCompiler().Compile(Dataset(), DatasetSha, generatedAt: DateTimeOffset.UnixEpoch);

        var error = Assert.Throws<InvalidDataException>(() => new TestPackRunnerContract().LoadApprovedCases(pending));

        Assert.Contains("TESTPACK.NOT_APPROVED", error.Message);
    }

    [Fact]
    public void Approved_TestPack_Is_The_Single_Case_Set_For_DryRun_And_Runner()
    {
        var approved = ApprovedPack(Dataset());
        var runnerCases = new TestPackRunnerContract().LoadApprovedCases(approved);
        var dryRunResults = runnerCases.Select(x => new RuleDryRunExecutor().Execute("dry", x)).ToArray();

        Assert.Equal(approved.Cases.Select(x => x.CaseId), runnerCases.Select(x => x.CaseId));
        Assert.Equal(approved.Cases.Select(x => x.CaseId), dryRunResults.Select(x => x.CaseId));
        Assert.All(dryRunResults, x => Assert.Equal(TestStatus.PENDING, x.Status));
    }

    [Fact]
    public void Dataset_Change_Is_Detected_Against_Existing_TestPack()
    {
        var original = Dataset();
        var approved = ApprovedPack(original);
        var changed = original with { DatasetId = "changed-dataset" };

        var validation = new TestPackValidator().ValidateSource(approved, changed, new string('b', 64));

        Assert.False(validation.IsValid);
        Assert.Contains(validation.Issues, x => x.Code == "TESTPACK.SOURCE_HASH_MISMATCH");
        Assert.Contains(validation.Issues, x => x.Code == "TESTPACK.DATASET_CHANGED");
    }

    [Fact]
    public void Expected_Result_Is_Resolved_Into_Each_TestPack_Case()
    {
        var testCase = Assert.Single(new CombinationGenerator().Generate(Dataset() with
        {
            Variables =
            [
                new RuleVariableDimension
                {
                    Name = "code",
                    Values =
                    [
                        new RuleVariableValue
                        {
                            Id = "invalid",
                            Value = "INVALID",
                            ExpectedOutcome = new RuleExpectedOutcome
                            {
                                Type = RuleExpectedOutcomeType.ValidationRequired,
                                MessagePatterns = ["invalid"],
                                Source = RuleExpectationSource.Dataset,
                                Confidence = RuleExpectationConfidence.High,
                                Evidence = ["dataset"]
                            }
                        }
                    ]
                }
            ]
        }));

        Assert.Equal(RuleExpectedOutcomeType.ValidationRequired, testCase.ExpectedResult.Type);
        Assert.Equal(RuleExpectedOutcomeType.ValidationRequired, testCase.ExpectedResult.ByVariable["code"].Type);
        Assert.Contains("invalid", testCase.ExpectedResult.MessagePatterns);
    }

    private static RuleTestPack ApprovedPack(RuleTestDataset dataset)
    {
        var compiler = new TestPackCompiler();
        var pending = compiler.Compile(dataset, DatasetSha, generatedAt: DateTimeOffset.UnixEpoch);
        return compiler.Compile(dataset, DatasetSha, approval: new TestPackApprovalOverlay
        {
            TestPackContentHash = pending.ContentHash,
            Status = TestPackApprovalStatus.Approved,
            ApprovedBy = "unit-test-approver",
            ApprovedAt = DateTimeOffset.UnixEpoch,
            EvidenceRefs = ["unit-test"]
        }, generatedAt: DateTimeOffset.UnixEpoch);
    }

    private static RuleVariableDimension Dimension(string name, params string[] values) => new()
    {
        Name = name,
        Values = values.Select(value => new RuleVariableValue { Id = value, Value = value }).ToArray()
    };

    private static RuleTestDataset Dataset() => new()
    {
        SchemaVersion = "2.0",
        DatasetId = "test-pack-dataset",
        TargetProfile = new RuleTargetProfile
        {
            Id = "synthetic-target",
            DisplayName = "Synthetic Target",
            RunLabel = "synthetic",
            ScreenIdPattern = "^[0-9]{4}$",
            Window = new RuleTargetWindowProfile { ClassName = "SyntheticWindow" }
        },
        MaxExpandedCases = 100,
        ExecutionPolicy = new RuleExecutionPolicy { ErrorPatterns = ["Error"] },
        Accounts = [],
        Screens = [new RuleScreenInput { ScreenNumber = "0102", ScreenName = "Synthetic screen" }],
        Variables =
        [
            Dimension("period", "d1", "d2"),
            Dimension("market", "all", "domestic", "overseas")
        ],
        AutoExploration = new RuleAutoExplorationPolicy
        {
            Enabled = false,
            MapBaseline = new RuleMapBaselinePolicy { Enabled = false }
        }
    };
}
