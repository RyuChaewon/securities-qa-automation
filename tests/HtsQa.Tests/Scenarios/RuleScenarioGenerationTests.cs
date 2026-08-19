// 역할: 자동 시나리오의 결정성, 데이터 병합, 선택지 전수, 수명주기 차단과 자동 승인 경계를 검증한다.
// 범위: 동일 입력은 동일 ID·순서·계약을 생성해야 하며 실제 화면 바인딩은 Planning 테스트가 담당한다.
// 수정 지점: 새 생성 규칙은 정상 생성, 제외 조건과 재실행 결정성 사례를 함께 추가한다.
using HtsQa.Core;

namespace HtsQa.Tests;

public sealed class RuleScenarioGenerationTests
{
    [Fact]
    public void Generator_Creates_Deterministic_Query_Date_And_Checkbox_Cases()
    {
        var query = Control("BTN_Query", HtsMapControlKind.Button, RuleControlKind.Button, 1);
        var date = Control("CAL_Date", HtsMapControlKind.Date, RuleControlKind.Date, 2);
        var check = Control("CHK_All", HtsMapControlKind.CheckBox, RuleControlKind.CheckBox, 3);
        var screen = Screen([query, date, check], new HtsMapBehaviorDefinition
        {
            QueryControls = [query.LogicalName],
            InputControls = [date.LogicalName, check.LogicalName]
        });
        var catalog = Catalog(screen);
        var dataset = Dataset();
        var options = new RuleScenarioGenerationOptions { ReferenceDate = new DateOnly(2026, 8, 10), MapCatalogSha256 = "map" };

        var first = new RuleScenarioGenerator().Generate(catalog, dataset, [], options);
        var second = new RuleScenarioGenerator().Generate(catalog, dataset, [], options);
        var approval = new RuleScenarioAutoApprovalPolicy().Create(first.Document, "source", DateTimeOffset.Parse("2026-08-10T12:00:00+09:00"));
        var plan = new ScenarioPlanCompiler().Compile(first.Document, dataset, "source", "dataset", approval, "approval");

        Assert.Equal(JsonFile.Sha256Json(first.Document), JsonFile.Sha256Json(second.Document));
        Assert.Equal(3, first.ScenarioCount);
        Assert.Equal(8, first.ProjectedCasesPerAccount);
        Assert.Equal(8, plan.CaseCount);
        Assert.Equal("READY_FOR_BINDING", plan.Status);
        Assert.Equal(RuleScenarioGeneratorVersions.GenerationMode, plan.ScenarioGenerationMode);
    }

    [Fact]
    public void Generator_Uses_Dataset_Interaction_Strategy()
    {
        var query = Control("BTN_Query", HtsMapControlKind.Button, RuleControlKind.Button, 1);
        var dataset = Dataset() with
        {
            AutoExploration = new RuleAutoExplorationPolicy
            {
                InteractionStrategy = RuleInteractionStrategies.CoordinateFocus
            }
        };

        var result = new RuleScenarioGenerator().Generate(
            Catalog(Screen([query], new HtsMapBehaviorDefinition { QueryControls = [query.LogicalName] })),
            dataset,
            [],
            new RuleScenarioGenerationOptions { ReferenceDate = new DateOnly(2026, 8, 10) });

        Assert.All(Assert.Single(result.Document.Screens).Scenarios,
            scenario => Assert.Equal(RuleInteractionStrategies.CoordinateFocus, scenario.ExecutionOrder));
    }

    [Fact]
    public void Generator_Uses_All_Runtime_Radio_Options_By_Index()
    {
        var radio = Control("RAD_TradeType", HtsMapControlKind.RadioGroup, RuleControlKind.RadioGroup, 1);
        var result = new RuleScenarioGenerator().Generate(
            Catalog(Screen([radio], new HtsMapBehaviorDefinition { StateControllerControls = [radio.LogicalName] })),
            Dataset(),
            [
                new RuntimeControlPlanRow
                {
                    ScreenNumber = TestTargetFixture.ScreenNumber,
                    DiscoveredControls =
                    [
                        new RuleDiscoveredControl
                        {
                            ControlId = $"{TestTargetFixture.ScreenNumber}:RAD_TradeType",
                            ControlKind = RuleControlKind.RadioGroup,
                            MapModelId = radio.ModelId,
                            MapMatched = true,
                            DefinitionSource = "MAP+Runtime",
                            Options =
                            [
                                new RuleControlOption { Id = "all", Value = "0", DisplayValue = "전체" },
                                new RuleControlOption { Id = "sell", Value = "1", DisplayValue = "매도" },
                                new RuleControlOption { Id = "buy", Value = "2", DisplayValue = "매수" }
                            ]
                        }
                    ]
                }
            ],
            new RuleScenarioGenerationOptions { ReferenceDate = new DateOnly(2026, 8, 10) });

        var variable = Assert.Single(result.Document.DatasetPatch.Variables);
        Assert.Equal(RuleValueMatch.Index, variable.ValueMatch);
        Assert.Equal(["전체", "매도", "매수"], variable.Values.Select(x => x.DisplayValue));
        Assert.Equal(3, result.ProjectedCasesPerAccount);
        Assert.Equal(1, result.RuntimeOptionControlCount);
        Assert.True(result.Document.GenerationSummary.RuntimeDiscoveryUsed);
    }

    [Fact]
    public void AutoApproval_Rejects_External_Scenario_Document()
    {
        var external = new GeneratedScenarioDocument
        {
            PackageVersion = ScenarioPlanVersions.SourceSchema,
            SourceInstallationFingerprint = "installation",
            Screens = []
        };

        var error = Assert.Throws<InvalidDataException>(() =>
            new RuleScenarioAutoApprovalPolicy().Create(external, "source", DateTimeOffset.Now));

        Assert.Contains("프로그램 자동 생성기", error.Message);
    }

    [Fact]
    public void AutoApproval_Resolves_All_Gaps_Without_Deferred_Decisions()
    {
        var account = Control("ACC_NO", HtsMapControlKind.Account, RuleControlKind.Text, 1);
        var result = new RuleScenarioGenerator().Generate(
            Catalog(Screen([account], new HtsMapBehaviorDefinition { InputControls = [account.LogicalName] })),
            Dataset(),
            [],
            new RuleScenarioGenerationOptions { ReferenceDate = new DateOnly(2026, 8, 10) });

        var approval = new RuleScenarioAutoApprovalPolicy().Create(result.Document, "source", DateTimeOffset.Parse("2026-08-10T12:00:00+09:00"));

        Assert.Equal("Approved", approval.Status);
        Assert.NotEmpty(approval.CoverageGapDecisions);
        Assert.All(approval.CoverageGapDecisions, x => Assert.Equal("AcceptedGap", x.Decision));
        Assert.DoesNotContain(approval.ReviewDecisions, x => x.Decision == "Deferred");
        Assert.DoesNotContain(approval.ScenarioDecisions, x => x.Decision == "Deferred");
    }

    [Fact]
    public void Generator_Merges_User_Dataset_Values_Before_Automatic_Boundaries()
    {
        var text = Control("TXT_Condition", HtsMapControlKind.Text, RuleControlKind.Text, 1);
        var dataset = Dataset() with
        {
            Variables =
            [
                new RuleVariableDimension
                {
                    Name = "사용자조건",
                    TargetRole = text.LogicalName,
                    ControlKind = RuleControlKind.Text,
                    Values =
                    [
                        new RuleVariableValue
                        {
                            Id = "custom",
                            Value = "ABC",
                            DisplayValue = "사용자 지정값",
                            ExpectedOutcome = new RuleExpectedOutcome { Type = RuleExpectedOutcomeType.Success }
                        }
                    ],
                    AppliesToScreens = [TestTargetFixture.ScreenNumber]
                }
            ]
        };

        var result = new RuleScenarioGenerator().Generate(
            Catalog(Screen([text], new HtsMapBehaviorDefinition { InputControls = [text.LogicalName] })),
            dataset,
            [],
            new RuleScenarioGenerationOptions { ReferenceDate = new DateOnly(2026, 8, 10) });

        var values = Assert.Single(result.Document.DatasetPatch.Variables).Values;
        Assert.Equal("ABC", values[0].Value);
        Assert.Equal(RuleExpectationSource.Dataset, values[0].ExpectedOutcome.Source);
        Assert.Contains(values, x => x.Value == "99999999");
    }

    [Fact]
    public void Generator_Excludes_Lifecycle_Button_Detected_By_Map_Handler()
    {
        var close = Control("BTN_9", HtsMapControlKind.Button, RuleControlKind.Button, 1);
        var result = new RuleScenarioGenerator().Generate(
            Catalog(Screen([close], new HtsMapBehaviorDefinition
            {
                EventHandlers =
                [
                    new HtsMapEventHandlerDefinition
                    {
                        Handler = "CloseCurrentScreen",
                        SourceControl = close.LogicalName,
                        Event = "Click",
                        SemanticRole = "Command"
                    }
                ]
            })),
            Dataset(),
            [],
            new RuleScenarioGenerationOptions { ReferenceDate = new DateOnly(2026, 8, 10) });

        Assert.Empty(Assert.Single(result.Document.Screens).Scenarios);
        Assert.Contains(result.Document.Screens[0].CoverageGaps, x => x.Contains("수명주기 보호 정책"));
    }

    [Fact]
    public void AutoApproval_Rejects_Required_Review_Even_For_Automatic_Document()
    {
        var result = new RuleScenarioGenerator().Generate(
            Catalog(Screen([Control("BTN_Query", HtsMapControlKind.Button, RuleControlKind.Button, 1)], new HtsMapBehaviorDefinition())),
            Dataset(),
            [],
            new RuleScenarioGenerationOptions { ReferenceDate = new DateOnly(2026, 8, 10) });
        var source = result.Document with
        {
            ReviewItems =
            [
                new GeneratedReviewItem
                {
                    Severity = "Required",
                    ScreenNumber = TestTargetFixture.ScreenNumber,
                    Subject = "필수 근거 누락",
                    Question = "확인이 필요합니다.",
                    Reason = "자동 정책으로 확정할 수 없음"
                }
            ]
        };

        var error = Assert.Throws<InvalidDataException>(() =>
            new RuleScenarioAutoApprovalPolicy().Create(source, "source", DateTimeOffset.Now));

        Assert.Contains("필수 검토 항목은 자동 승인할 수 없습니다", error.Message);
    }

    private static HtsMapCatalog Catalog(HtsMapScreenDefinition screen) => new()
    {
        GeneratedAt = DateTimeOffset.Parse("2026-08-10T00:00:00+09:00"),
        ScreenDirectory = Path.Combine(TestTargetFixture.InstallationRoot, "screen"),
        FilePattern = "ht{screenNumber}00.map",
        RequestedScreens = [screen.ScreenNumber],
        MissingScreens = [],
        Screens = [screen],
        InstallationRoot = TestTargetFixture.InstallationRoot,
        InstallationFingerprint = "installation"
    };

    private static HtsMapScreenDefinition Screen(HtsMapControlDefinition[] controls, HtsMapBehaviorDefinition behavior) => new()
    {
        ScreenNumber = TestTargetFixture.ScreenNumber,
        ScreenCode = TestTargetFixture.ScreenCode,
        ScreenName = TestTargetFixture.ScreenName,
        SourceFile = Path.Combine(TestTargetFixture.InstallationRoot, "screen", TestTargetFixture.MapFileName),
        SourceSha256 = "map-source",
        SourceLastWriteTime = DateTimeOffset.Parse("2026-08-10T00:00:00+09:00"),
        DesignWidth = 800,
        DesignHeight = 600,
        Controls = controls,
        ErrorOracle = new HtsMapErrorOracleDefinition
        {
            HasReceiveErrorParameters = true,
            HasOnErrorHandler = true
        },
        Behavior = behavior
    };

    private static HtsMapControlDefinition Control(
        string logicalName,
        HtsMapControlKind mapKind,
        RuleControlKind ruleKind,
        int order) => new()
    {
        ModelId = logicalName,
        DefinitionOrder = order,
        TypeCode = "TEST",
        Kind = mapKind,
        RuleControlKind = ruleKind.ToString(),
        LogicalName = logicalName,
        ParentName = "",
        Rect = new HtsMapRect { X = order * 10, Y = order * 10, Width = 100, Height = 24 },
        IsActionable = true,
        IsTabStopCandidate = true
    };

    private static RuleTestDataset Dataset() => new()
    {
        SchemaVersion = "1.0",
        DatasetId = "test-dataset",
        MaxExpandedCases = 100,
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
