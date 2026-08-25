// 역할: Scenario planning public API, JSON 계약, canonical ID/hash의 분리 전 baseline을 고정한다.
// 범위: 합성 데이터만 사용하며 HTS, FlaUI, Windows UI를 시작하지 않는다.
using System.Text.Json;
using HtsQa.Core;

namespace HtsQa.Tests;

public sealed class ScenarioPlanningContractTests
{
    [Fact]
    public void Public_Scenario_Planning_Type_Names_And_Namespace_Are_Stable()
    {
        string[] names =
        [
            "ScenarioPlanVersions",
            "GeneratedScenarioDocument",
            "GeneratedScenarioSummary",
            "GeneratedScreenScenario",
            "GeneratedScenario",
            "GeneratedScenarioStep",
            "GeneratedDatasetPatch",
            "GeneratedScenarioVariable",
            "GeneratedScenarioValue",
            "GeneratedLocatorRequest",
            "GeneratedReviewItem",
            "ScenarioApprovalOverlay",
            "ScenarioReviewDecision",
            "ScenarioExecutionDecision",
            "ScenarioCoverageGapDecision",
            "ScenarioValidationReport",
            "ScenarioReadiness",
            "CompiledScenarioPlan",
            "CompiledScreenPlan",
            "CompiledScenarioDefinition",
            "ScenarioBindingRequirement",
            "CompiledScenarioCase",
            "CompiledScenarioValue",
            "CompiledScenarioStep",
            "ScenarioImportManifest",
            "ScenarioBindingStatus",
            "ScenarioBindingCatalog",
            "ScenarioScreenBindings",
            "ScenarioControlBinding",
            "ScenarioBindingCandidate",
            "RuntimeControlPlanRow",
            "PhysicalScenarioPlan",
            "PhysicalScenarioResolvedBinding",
            "PhysicalScenarioDisposition",
            "ScenarioBindingMaterializer",
            "GeneratedScenarioValidator",
            "ScenarioPlanCompiler",
            "ScenarioIds"
        ];

        var assembly = typeof(GeneratedScenarioDocument).Assembly;
        foreach (var name in names)
        {
            var type = assembly.GetType($"HtsQa.Core.{name}");
            Assert.NotNull(type);
            Assert.True(type!.IsPublic, name);
            Assert.Equal("HtsQa.Core", type.Namespace);
        }

        Assert.Equal(names.Length, names.Distinct(StringComparer.Ordinal).Count());
    }

    [Fact]
    public void Schema_Compiler_And_Enum_Json_Values_Are_Stable()
    {
        Assert.Equal("1.0", ScenarioPlanVersions.SourceSchema);
        Assert.Equal("1.0", ScenarioPlanVersions.ApprovalSchema);
        Assert.Equal("1.0", ScenarioPlanVersions.CompiledSchema);
        Assert.Equal("1.1.0", ScenarioPlanVersions.Compiler);

        AssertEnumJsonValues<ScenarioReadiness>(
            "ReadyForBinding", "PendingBinding", "PendingApproval", "ManualReview", "Rejected", "Invalid");
        AssertEnumJsonValues<ScenarioBindingStatus>(
            "BoundHigh", "BoundMedium", "Ambiguous", "Unbound");
    }

    [Fact]
    public void Generated_Scenario_Json_Round_Trip_And_Property_Names_Are_Stable()
    {
        var source = Source(
            [Scenario("TS-GENERIC-A", "v_date", "CAL_Date")],
            [Variable("v_date", "CAL_Date", RuleControlKind.Date, "20260810")]);

        var json = JsonSerializer.Serialize(source, JsonDefaults.Options);
        var roundTrip = JsonSerializer.Deserialize<GeneratedScenarioDocument>(json, JsonDefaults.Options);

        Assert.NotNull(roundTrip);
        Assert.Equal(json, JsonSerializer.Serialize(roundTrip, JsonDefaults.Options));
        using var document = JsonDocument.Parse(json);
        Assert.Equal(
            ["packageVersion", "sourceInstallationFingerprint", "generationSummary", "screens", "datasetPatch", "reviewItems"],
            document.RootElement.EnumerateObject().Select(x => x.Name).ToArray());
        Assert.Equal(
            ["screenNumber", "screenName", "scenarios", "coverageGaps"],
            document.RootElement.GetProperty("screens")[0].EnumerateObject().Select(x => x.Name).ToArray());
        Assert.Equal(
            ["variables", "locatorRequests"],
            document.RootElement.GetProperty("datasetPatch").EnumerateObject().Select(x => x.Name).ToArray());
    }

    [Fact]
    public void Compiler_Canonical_Hash_Ids_Counts_And_Order_Match_Baseline()
    {
        var source = Source(
            [
                Scenario("TS-GENERIC-A", "v_date", "CAL_Date"),
                Scenario("TS-GENERIC-B", "v_check", "CHK_Mode")
            ],
            [
                Variable("v_date", "CAL_Date", RuleControlKind.Date, "20260810", "20260811"),
                Variable("v_check", "CHK_Mode", RuleControlKind.CheckBox, "false", "true", "false")
            ]);

        var validation = new GeneratedScenarioValidator().Validate(source, Dataset(), "source");
        var plan = new ScenarioPlanCompiler().Compile(source, Dataset(), "source", "dataset");

        Assert.True(validation.IsValid);
        Assert.Empty(validation.Issues);
        Assert.Equal("PLAN-415866cdf8e0", plan.PlanId);
        Assert.Equal("415866cdf8e0c822caf914bebab41af0a153f5071da9b6f188ecee32c71f8d39", plan.PlanHash);
        Assert.Equal(5, plan.CaseCount);
        Assert.Equal(10, plan.StepCount);
        Assert.Equal(
            [
                "SC-ead81c303355fc7b",
                "SC-1507d4b694e56a2b",
                "SC-f58738d6b933b20f",
                "SC-949fe05ffbf5f4e2",
                "SC-eea397a245633e2c"
            ],
            plan.Cases.Select(x => x.CaseId).ToArray());
        Assert.Equal(
            ["value-0", "value-1", "value-0", "value-1", "value-2"],
            plan.Cases.SelectMany(x => x.Values.Values).Select(x => x.ValueId).ToArray());
    }

    [Fact]
    public void Validation_Issue_Code_Target_And_Message_Match_Baseline()
    {
        var source = Source([Scenario("TS-GENERIC-BAD", "missing", "CAL_Date")], []);

        var report = new GeneratedScenarioValidator().Validate(source, Dataset(), "source");

        var issue = Assert.Single(report.Issues);
        Assert.Equal("SCENARIO.VALUE_REF_NOT_FOUND", issue.Code);
        Assert.Equal("ERROR", issue.Severity);
        Assert.Equal("TS-GENERIC-BAD", issue.StepId);
        Assert.Null(issue.Field);
        Assert.Equal("TS-GENERIC-BAD에서 존재하지 않는 변수를 참조합니다: missing", issue.Message);
        Assert.Null(issue.Remediation);
    }

    private static void AssertEnumJsonValues<TEnum>(params string[] expected) where TEnum : struct, Enum
    {
        var values = Enum.GetValues<TEnum>();
        Assert.Equal(expected, values.Select(x => x.ToString()).ToArray());
        Assert.Equal(
            expected.Select(x => $"\"{x}\"").ToArray(),
            values.Select(x => JsonSerializer.Serialize(x, JsonDefaults.Options)).ToArray());
        Assert.Equal(values, expected.Select(x => JsonSerializer.Deserialize<TEnum>($"\"{x}\"", JsonDefaults.Options)).ToArray());
    }

    private static GeneratedScenarioDocument Source(GeneratedScenario[] scenarios, GeneratedScenarioVariable[] variables) => new()
    {
        PackageVersion = "1.0",
        SourceInstallationFingerprint = "installation",
        Screens =
        [
            new GeneratedScreenScenario
            {
                ScreenNumber = TestTargetFixture.ScreenNumber,
                ScreenName = TestTargetFixture.ScreenName,
                Scenarios = scenarios
            }
        ],
        DatasetPatch = new GeneratedDatasetPatch
        {
            Variables = variables,
            LocatorRequests = scenarios.SelectMany(x => x.CoveredControls).Distinct().Select(name => new GeneratedLocatorRequest
            {
                ScreenNumber = TestTargetFixture.ScreenNumber,
                LogicalName = name,
                TargetRole = "Input"
            }).ToArray()
        }
    };

    private static GeneratedScenario Scenario(string id, string? valueRef, string control) => new()
    {
        ScenarioId = id,
        Title = id,
        Priority = "P1",
        ExecutionOrder = RuleInteractionStrategies.RuntimeTabOrder,
        AutomationStatus = "NeedsLocator",
        CoveredControls = [control],
        Steps =
        [
            new GeneratedScenarioStep
            {
                Sequence = 1,
                Action = "Input",
                ControlLogicalName = control,
                ValueRef = valueRef
            },
            new GeneratedScenarioStep
            {
                Sequence = 2,
                Action = "AssertVisible",
                ControlLogicalName = control
            }
        ]
    };

    private static GeneratedScenarioVariable Variable(string name, string target, RuleControlKind kind, params string[] values) => new()
    {
        Name = name,
        TargetLogicalName = target,
        TargetRole = "Input",
        ControlKind = kind,
        AppliesToScreens = [TestTargetFixture.ScreenNumber],
        Values = values.Select((value, index) => new GeneratedScenarioValue
        {
            Id = $"value-{index}",
            Value = value,
            DisplayValue = value,
            ExpectedOutcome = new RuleExpectedOutcome
            {
                Type = RuleExpectedOutcomeType.ObservationOnly,
                Source = RuleExpectationSource.Dataset,
                Confidence = RuleExpectationConfidence.Medium
            }
        }).ToArray()
    };

    private static RuleTestDataset Dataset() => new()
    {
        SchemaVersion = "2.0",
        DatasetId = "scenario-planning-tests",
        TargetProfile = new RuleTargetProfile
        {
            Id = "synthetic-target",
            DisplayName = "합성 대상",
            RunLabel = "synthetic-target",
            ScreenIdPattern = "^[0-9]{4}$",
            Window = new RuleTargetWindowProfile { ClassName = "SyntheticWindow" },
            Map = new RuleTargetMapProfile { InstallationRoot = TestTargetFixture.InstallationRoot }
        },
        ExecutionPolicy = new RuleExecutionPolicy(),
        Accounts =
        [
            new RuleAccountInput
            {
                Id = "account-1",
                AccountNumber = "00000000-000",
                Owner = "테스트",
                InputMode = RuleInputMode.Prefilled
            }
        ],
        Screens = [new RuleScreenInput { ScreenNumber = TestTargetFixture.ScreenNumber, ScreenName = TestTargetFixture.ScreenName }]
    };
}
