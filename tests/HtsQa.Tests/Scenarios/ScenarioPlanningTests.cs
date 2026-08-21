// 역할: 생성 시나리오 검증, 승인, 논리 컴파일, MAP+Runtime 바인딩과 물리 실행 허용 조건을 검증한다.
// 범위: JSON 계약과 해시·승인·결합 정책을 검증하며 실제 UI 동작은 Automation 테스트가 담당한다.
// 수정 지점: 계획 스키마나 실행 허용 조건을 바꾸면 허용·차단·부분 계획 사례를 함께 갱신한다.
using HtsQa.Core;

namespace HtsQa.Tests;

public sealed class ScenarioPlanningTests
{
    [Fact]
    public void Compiler_Expands_Only_Variables_Referenced_By_Each_Scenario()
    {
        var source = Source(
            scenarios:
            [
                Scenario("TS-GENERIC-A", "v_date", "CAL_Date"),
                Scenario("TS-GENERIC-B", "v_check", "CHK_Mode")
            ],
            variables:
            [
                Variable("v_date", "CAL_Date", RuleControlKind.Date, "20260810", "20260811"),
                Variable("v_check", "CHK_Mode", RuleControlKind.CheckBox, "false", "true", "false")
            ]);

        var plan = Compile(source);

        Assert.Equal(5, plan.CaseCount);
        Assert.Equal(10, plan.StepCount);
        Assert.Equal(2, plan.Cases.Count(x => x.ScenarioId == "TS-GENERIC-A"));
        Assert.Equal(3, plan.Cases.Count(x => x.ScenarioId == "TS-GENERIC-B"));
        Assert.Equal(plan.Cases.Length, plan.Cases.Select(x => x.CaseId).Distinct().Count());
    }

    [Fact]
    public void Coordinate_Focus_Is_Validated_And_Preserved_In_Compiled_Cases()
    {
        var scenario = Scenario("TS-GENERIC-COORDINATE", null, "BTN_Query") with
        {
            ExecutionOrder = RuleInteractionStrategies.CoordinateFocus
        };
        var source = Source([scenario], []);

        var validation = new GeneratedScenarioValidator().Validate(source, Dataset(), "source");
        var plan = Compile(source);

        Assert.True(validation.IsValid);
        Assert.DoesNotContain(validation.Issues, x => x.Code == "SCENARIO.EXECUTION_ORDER");
        Assert.Equal(RuleInteractionStrategies.CoordinateFocus, Assert.Single(plan.Cases).ExecutionOrder);
    }

    [Fact]
    public void Unknown_Interaction_Strategy_Is_Rejected()
    {
        var scenario = Scenario("TS-GENERIC-BAD-ORDER", null, "BTN_Query") with { ExecutionOrder = "ScreenGuess" };
        var source = Source([scenario], []);

        var validation = new GeneratedScenarioValidator().Validate(source, Dataset(), "source");

        Assert.False(validation.IsValid);
        Assert.Contains(validation.Issues, x => x.Code == "SCENARIO.EXECUTION_ORDER" && x.Severity == "ERROR");
    }

    [Fact]
    public void Compound_Button_Procedure_Preserves_Restore_And_DoubleClick()
    {
        var scenario = Scenario("TS-0101-COMPOUND", null, "BTN_EnvSet") with
        {
            Objective = "단일 클릭 후 확인하고 원상복구 후 빠른 이중 클릭을 수행한다.",
            ExecutionOrder = RuleInteractionStrategies.CoordinateFocus,
            Steps =
            [
                new GeneratedScenarioStep { Sequence = 1, Action = "Click", ControlLogicalName = "BTN_EnvSet" },
                new GeneratedScenarioStep { Sequence = 2, Action = "AssertPopup" },
                new GeneratedScenarioStep { Sequence = 3, Action = "Restore" },
                new GeneratedScenarioStep { Sequence = 4, Action = "DoubleClick", ControlLogicalName = "BTN_EnvSet" },
                new GeneratedScenarioStep { Sequence = 5, Action = "AssertPopup" }
            ]
        };
        var source = Source([scenario], []);

        var validation = new GeneratedScenarioValidator().Validate(source, Dataset(), "source");
        var compiled = Compile(source);

        Assert.True(validation.IsValid, string.Join("\n", validation.Issues.Select(x => x.Message)));
        Assert.Contains(Assert.Single(compiled.Cases).Steps, x => x.Action == "Restore");
        Assert.Contains(Assert.Single(compiled.Cases).Steps, x => x.Action == "DoubleClick");
    }

    [Fact]
    public void Compound_Procedure_Missing_Required_Actions_Is_Rejected()
    {
        var scenario = Scenario("TS-0101-COMPOUND-MISSING", null, "BTN_EnvSet") with
        {
            Objective = "원상복구 후 빠른 이중 클릭을 수행한다."
        };

        var validation = new GeneratedScenarioValidator().Validate(Source([scenario], []), Dataset(), "source");

        Assert.False(validation.IsValid);
        Assert.Contains(validation.Issues, x => x.Code == "SCENARIO.DOUBLE_CLICK_REQUIRED");
        Assert.Contains(validation.Issues, x => x.Code == "SCENARIO.RESTORE_REQUIRED");
    }

    [Fact]
    public void Transactional_DoubleClick_Is_Rejected()
    {
        var scenario = Scenario("TS-0101-ORDER-DOUBLE", null, "BTN_Order") with
        {
            Objective = "주문 버튼을 빠른 이중 클릭한다.",
            Transactional = true,
            Steps = [new GeneratedScenarioStep { Sequence = 1, Action = "DoubleClick", ControlLogicalName = "BTN_Order", Transactional = true }]
        };

        var validation = new GeneratedScenarioValidator().Validate(Source([scenario], []), Dataset(), "source");

        Assert.False(validation.IsValid);
        Assert.Contains(validation.Issues, x => x.Code == "SCENARIO.TRANSACTIONAL_DOUBLE_CLICK");
        Assert.Contains(validation.Issues, x => x.Code == "SCENARIO.TRANSACTIONAL_DOUBLE_CLICK_SKIPPED" && x.Severity == "WARNING");
    }

    [Fact]
    public void Passive_NoTransmission_Only_Scenario_Is_Not_Executable()
    {
        var scenario = Scenario("TS-0101-PASSIVE", null, "RQ_SAMPLE") with
        {
            Steps =
            [
                new GeneratedScenarioStep { Sequence = 1, Action = "Focus" },
                new GeneratedScenarioStep { Sequence = 2, Action = "AssertNoTransmission" }
            ]
        };
        var logical = Compile(Source([scenario], []));
        var materializer = new ScenarioBindingMaterializer();
        var bindings = materializer.Materialize(logical,
        [
            new RuntimeControlPlanRow { ScreenNumber = TestTargetFixture.ScreenNumber, DiscoveredControls = [] }
        ], "installation");
        var physical = materializer.BuildPhysicalPlan(logical, bindings, "bindings");

        Assert.Contains(logical.Issues, x => x.Code == "SCENARIO.NO_EFFECT_STEP" && x.Severity == "WARNING");
        Assert.Equal("BLOCKED", physical.Status);
        Assert.Empty(physical.ExecutableCaseIds);
        Assert.Equal("PENDING_BINDING", Assert.Single(physical.ScenarioDispositions).Status);
        Assert.Contains(Assert.Single(physical.ScenarioDispositions).Reasons, x => x.Contains("PASS 판정"));
    }

    [Fact]
    public void Validator_Allows_Blank_Date_For_Expected_Validation()
    {
        var variable = Variable("v_date", "CAL_Date", RuleControlKind.Date, "");
        variable = variable with
        {
            Values =
            [
                variable.Values[0] with
                {
                    ExpectedOutcome = new RuleExpectedOutcome
                    {
                        Type = RuleExpectedOutcomeType.ValidationRequired,
                        MessagePatterns = ["날짜"],
                        Source = RuleExpectationSource.MapValidation,
                        Confidence = RuleExpectationConfidence.High
                    }
                }
            ]
        };
        var source = Source([Scenario("TS-GENERIC-DATE", "v_date", "CAL_Date")], [variable]);

        var report = new GeneratedScenarioValidator().Validate(source, Dataset(), "source");

        Assert.True(report.IsValid);
        Assert.DoesNotContain(report.Issues, x => x.Code == "SCENARIO.DATE_FORMAT");
    }

    [Fact]
    public void Required_Review_Blocks_Only_Related_Scenario_Until_Resolved()
    {
        var source = Source(
            [
                Scenario("TS-GENERIC-DATE", "v_date", "CAL_Date"),
                Scenario("TS-GENERIC-CHECK", "v_check", "CHK_Mode")
            ],
            [
                Variable("v_date", "CAL_Date", RuleControlKind.Date, "20260810"),
                Variable("v_check", "CHK_Mode", RuleControlKind.CheckBox, "false", "true")
            ]) with
        {
            ReviewItems =
            [
                new GeneratedReviewItem
                {
                    Severity = "Required",
                    ScreenNumber = TestTargetFixture.ScreenNumber,
                    Subject = "CAL_Date 입력 형식",
                    Question = "런타임 날짜 형식을 확인해야 합니다.",
                    Reason = "정적 자료만으로 확정할 수 없음"
                }
            ]
        };
        var initial = Compile(source);
        var review = Assert.Single(source.ReviewItems);
        var approval = new ScenarioApprovalOverlay
        {
            SourceSha256 = "source",
            Status = "Approved",
            ApprovedBy = "테스트 승인자",
            ApprovedAt = DateTimeOffset.Parse("2026-08-10T12:00:00+09:00"),
            ReviewDecisions =
            [
                new ScenarioReviewDecision
                {
                    ReviewId = ScenarioPlanCompiler.ReviewId(review),
                    Decision = "Resolved",
                    Reason = "바인딩 계획에서 형식 확인"
                }
            ]
        };
        var approved = Compile(source, approval);

        Assert.Equal(ScenarioReadiness.PendingApproval, initial.Screens[0].Scenarios.Single(x => x.ScenarioId == "TS-GENERIC-DATE").Readiness);
        Assert.Equal(ScenarioReadiness.PendingBinding, initial.Screens[0].Scenarios.Single(x => x.ScenarioId == "TS-GENERIC-CHECK").Readiness);
        Assert.Equal(ScenarioReadiness.PendingBinding, approved.Screens[0].Scenarios.Single(x => x.ScenarioId == "TS-GENERIC-DATE").Readiness);
    }

    [Fact]
    public void Manual_Review_Requires_Explicit_Scenario_Approval()
    {
        var manual = Scenario("TS-GENERIC-EXPORT", null, "BTN_Excel") with { AutomationStatus = "ManualReview" };
        var source = Source([manual], []);
        var initial = Compile(source);
        var approval = new ScenarioApprovalOverlay
        {
            SourceSha256 = "source",
            Status = "Approved",
            ApprovedBy = "테스트 승인자",
            ApprovedAt = DateTimeOffset.Parse("2026-08-10T12:00:00+09:00"),
            ScenarioDecisions =
            [
                new ScenarioExecutionDecision { ScenarioId = manual.ScenarioId, Decision = "Approve", Reason = "테스트 전용 저장 경로 확인" }
            ]
        };
        var approved = Compile(source, approval);

        Assert.Equal(ScenarioReadiness.ManualReview, initial.Screens[0].Scenarios[0].Readiness);
        Assert.Equal(ScenarioReadiness.ReadyForBinding, approved.Screens[0].Scenarios[0].Readiness);
    }

    [Fact]
    public void Draft_Approval_Does_Not_Activate_Decisions()
    {
        var manual = Scenario("TS-GENERIC-DRAFT", null, "BTN_Excel") with { AutomationStatus = "ManualReview" };
        var source = Source([manual], []);
        var draft = new ScenarioApprovalOverlay
        {
            SourceSha256 = "source",
            Status = "Draft",
            ScenarioDecisions =
            [
                new ScenarioExecutionDecision { ScenarioId = manual.ScenarioId, Decision = "Approve", Reason = "아직 초안" }
            ]
        };

        var compiled = Compile(source, draft);

        Assert.Equal(ScenarioReadiness.ManualReview, compiled.Screens[0].Scenarios.Single().Readiness);
    }

    [Fact]
    public void Approved_Overlay_Requires_Approver_And_Timestamp()
    {
        var source = Source([Scenario("TS-GENERIC-APPROVAL", null, "BTN_Query")], []);
        var invalid = new ScenarioApprovalOverlay
        {
            SourceSha256 = "source",
            Status = "Approved"
        };

        var error = Assert.Throws<InvalidDataException>(() => Compile(source, invalid));

        Assert.Contains("approvedBy", error.Message);
        Assert.Contains("approvedAt", error.Message);
    }

    [Fact]
    public void Approval_With_Unknown_Scenario_Id_Is_Rejected()
    {
        var source = Source([Scenario("TS-GENERIC-KNOWN", null, "BTN_Query")], []);
        var invalid = new ScenarioApprovalOverlay
        {
            SourceSha256 = "source",
            Status = "Draft",
            ScenarioDecisions =
            [
                new ScenarioExecutionDecision { ScenarioId = "TS-GENERIC-TYPO", Decision = "Deferred", Reason = "오타" }
            ]
        };

        var error = Assert.Throws<InvalidDataException>(() => Compile(source, invalid));

        Assert.Contains("원본에 없는 시나리오 ID", error.Message);
    }

    [Fact]
    public void Missing_Value_Reference_Is_Rejected()
    {
        var source = Source([Scenario("TS-GENERIC-BAD", "missing", "CAL_Date")], []);

        var report = new GeneratedScenarioValidator().Validate(source, Dataset(), "source");

        Assert.False(report.IsValid);
        Assert.Contains(report.Issues, x => x.Code == "SCENARIO.VALUE_REF_NOT_FOUND");
    }

    [Fact]
    public void Map_Runtime_Binding_Makes_Related_Cases_Executable()
    {
        var source = Source(
            [Scenario("TS-GENERIC-DATE", "v_date", "CAL_Date")],
            [Variable("v_date", "CAL_Date", RuleControlKind.Date, "20260810", "20260811")]);
        var logical = Compile(source);
        var materializer = new ScenarioBindingMaterializer();
        var bindings = materializer.Materialize(logical,
        [
            new RuntimeControlPlanRow
            {
                ScreenNumber = TestTargetFixture.ScreenNumber,
                DiscoveredControls =
                [
                    new RuleDiscoveredControl
                    {
                        ControlId = $"{TestTargetFixture.ScreenNumber}:CAL_Date",
                        ControlKind = RuleControlKind.Date,
                        Name = "CAL_Date",
                        ClassName = "Edit",
                        DefinitionSource = "MAP+Runtime",
                        MapMatched = true,
                        LocatorSignature = $"MAP|{TestTargetFixture.ScreenNumber}:CAL_Date|Edit|",
                        RuntimeControlKind = "Text",
                        AutomationEngine = "Win32/MAP",
                        MapMatchDistance = 2,
                        RelativeRect = RuntimeRect(),
                        TabOrder = 3
                    }
                ]
            }
        ], "installation");
        var physical = materializer.BuildPhysicalPlan(logical, bindings, "bindings");

        Assert.Equal("READY", bindings.Status);
        Assert.Equal(ScenarioBindingStatus.BoundHigh, bindings.Screens[0].Controls[0].Status);
        Assert.Equal("READY", physical.Status);
        Assert.Equal(2, physical.ExecutableCases);
        Assert.Equal("1.1", physical.SchemaVersion);
        Assert.All(physical.ResolvedBindings, x => Assert.Equal($"{TestTargetFixture.ScreenNumber}:CAL_Date", x.ControlId));
    }

    [Fact]
    public void Map_Only_Placeholder_Remains_Pending_Binding()
    {
        var source = Source(
            [Scenario("TS-GENERIC-DATE", "v_date", "CAL_Date")],
            [Variable("v_date", "CAL_Date", RuleControlKind.Date, "20260810")]);
        var logical = Compile(source);
        var materializer = new ScenarioBindingMaterializer();
        var bindings = materializer.Materialize(logical,
        [
            new RuntimeControlPlanRow
            {
                ScreenNumber = TestTargetFixture.ScreenNumber,
                DiscoveredControls =
                [
                    new RuleDiscoveredControl
                    {
                        ControlId = $"{TestTargetFixture.ScreenNumber}:CAL_Date",
                        ControlKind = RuleControlKind.Date,
                        Name = "CAL_Date",
                        DefinitionSource = "MAP",
                        MapMatched = false
                    }
                ]
            }
        ], "installation");
        var physical = materializer.BuildPhysicalPlan(logical, bindings, "bindings");

        Assert.Equal("INCOMPLETE", bindings.Status);
        Assert.Equal(ScenarioBindingStatus.Unbound, bindings.Screens[0].Controls[0].Status);
        Assert.Equal("BLOCKED", physical.Status);
        Assert.Equal(0, physical.ExecutableCases);
    }

    [Fact]
    public void Tc_Metadata_And_Assert_Steps_Are_Preserved_By_Compiler()
    {
        var scenario = Scenario("TS-0101-TC", null, "BTN_Order") with
        {
            SourceTestCaseId = "0101-CMD-0001",
            MapScreenCode = "HT010101",
            Transactional = true,
            ExpectedResult = "주문 확인 팝업이 표시된다.",
            Steps =
            [
                new GeneratedScenarioStep { Sequence = 1, Action = "AssertVisible", ControlLogicalName = "BTN_Order", MapScreenCode = "HT010101" },
                new GeneratedScenarioStep { Sequence = 2, Action = "Click", ControlLogicalName = "BTN_Order", MapScreenCode = "HT010101", Transactional = true },
                new GeneratedScenarioStep { Sequence = 3, Action = "AssertPopup", MapScreenCode = "HT010101" },
                new GeneratedScenarioStep { Sequence = 4, Action = "AssertNoTransmission", MapScreenCode = "HT010101" }
            ]
        };

        var plan = Compile(Source([scenario], []));
        var compiled = Assert.Single(plan.Cases);

        Assert.Equal("0101-CMD-0001", compiled.SourceTestCaseId);
        Assert.Equal("HT010101", compiled.MapScreenCode);
        Assert.True(compiled.Transactional);
        Assert.Equal("주문 확인 팝업이 표시된다.", compiled.ExpectedResult);
        Assert.True(compiled.Steps.Single(x => x.Action == "Click").Transactional);
        Assert.All(compiled.Steps.Where(x => x.Action.StartsWith("Assert")), step => Assert.Equal("Assert", step.ExecutionPhase));
    }

    [Fact]
    public void Binding_Uses_Map_Control_And_State_Compound_Key()
    {
        var scenario = Scenario("TS-0101-BINDING", null, "BTN_Order") with
        {
            MapScreenCode = "HT010101",
            Steps =
            [
                new GeneratedScenarioStep
                {
                    Sequence = 1,
                    Action = "Click",
                    ControlLogicalName = "BTN_Order",
                    MapScreenCode = "HT010101",
                    StateContext = "order-tab"
                }
            ]
        };
        var logical = Compile(Source([scenario], []));
        var bindings = new ScenarioBindingMaterializer().Materialize(logical,
        [
            new RuntimeControlPlanRow
            {
                ScreenNumber = TestTargetFixture.ScreenNumber,
                DiscoveredControls =
                [
                    new RuleDiscoveredControl { ControlId = "wrong-map", ControlKind = RuleControlKind.Button, Name = "BTN_Order", MapScreenCode = "HT010102", StateContext = "order-tab", DefinitionSource = "MAP+Runtime", MapMatched = true },
                    new RuleDiscoveredControl { ControlId = "wrong-state", ControlKind = RuleControlKind.Button, Name = "BTN_Order", MapScreenCode = "HT010101", StateContext = "quote-tab", DefinitionSource = "MAP+Runtime", MapMatched = true },
                    ActionableControl("correct", "BTN_Order", "HT010101", "order-tab")
                ]
            }
        ], "installation");

        var binding = Assert.Single(bindings.Screens[0].Controls);
        Assert.Equal("HT010101|BTN_Order|order-tab", binding.BindingKey);
        Assert.Equal(ScenarioBindingStatus.BoundHigh, binding.Status);
        Assert.Equal("correct", Assert.Single(binding.Candidates).ControlId);
        Assert.True(binding.ExecutionEligible);
    }

    [Fact]
    public void Binding_Retains_Order_Tab_Context_While_Binding_OwnerDrawn_Command()
    {
        var scenario = Scenario("TS-0101-ORDER-TAB", null, "BTN_Ord_Buy") with
        {
            MapScreenCode = "HT010115",
            Steps =
            [
                new GeneratedScenarioStep
                {
                    Sequence = 1,
                    Action = "Click",
                    ControlLogicalName = "BTN_Ord_Buy",
                    MapScreenCode = "HT010115",
                    StateContext = "order-tab:buy",
                    Transactional = true
                }
            ]
        };
        var logical = Compile(Source([scenario], []));
        var bindings = new ScenarioBindingMaterializer().Materialize(logical,
        [
            new RuntimeControlPlanRow
            {
                ScreenNumber = TestTargetFixture.ScreenNumber,
                DiscoveredControls =
                [
                    ActionableControl("buy", "BTN_Ord_Buy", "HT010115", "428:173=0")
                ]
            }
        ], "installation", new RuleTargetAdapterProfile
        {
            StatefulControls = [new() { StateContextPattern = "^order-tab:(buy|sell|modify-cancel|any)$" }]
        });

        var binding = Assert.Single(bindings.Screens[0].Controls);
        Assert.Equal("HT010115|BTN_Ord_Buy|order-tab:buy", binding.BindingKey);
        Assert.Equal(ScenarioBindingStatus.BoundHigh, binding.Status);
        Assert.True(binding.ExecutionEligible);
    }

    [Fact]
    public void Large_Map_Distance_Is_Not_Execution_Eligible()
    {
        var logical = Compile(Source([Scenario("TS-0101-DISTANCE", null, "BTN_Order") with { MapScreenCode = "HT010101" }], []));
        var control = ActionableControl("far", "BTN_Order", "HT010101") with { MapMatchDistance = 44.84 };

        var bindings = new ScenarioBindingMaterializer().Materialize(logical,
        [
            new RuntimeControlPlanRow { ScreenNumber = TestTargetFixture.ScreenNumber, DiscoveredControls = [control] }
        ], "installation");
        var physical = new ScenarioBindingMaterializer().BuildPhysicalPlan(logical, bindings, "bindings");

        var binding = Assert.Single(bindings.Screens[0].Controls);
        Assert.Equal(ScenarioBindingStatus.BoundMedium, binding.Status);
        Assert.False(binding.ExecutionEligible);
        Assert.Contains(binding.Candidates[0].Evidence, x => x == "FAIL:mapMatchDistance<=24");
        Assert.Equal("BLOCKED", physical.Status);
    }

    [Fact]
    public void Runtime_Control_Kind_Mismatch_Is_Not_Execution_Eligible()
    {
        var logical = Compile(Source([Scenario("TS-0101-KIND", null, "CHK_Remain") with { MapScreenCode = "HT010101" }], []));
        var control = ActionableControl("mismatch", "CHK_Remain", "HT010101", kind: RuleControlKind.CheckBox) with
        {
            RuntimeControlKind = "RadioGroup"
        };

        var bindings = new ScenarioBindingMaterializer().Materialize(logical,
        [
            new RuntimeControlPlanRow { ScreenNumber = TestTargetFixture.ScreenNumber, DiscoveredControls = [control] }
        ], "installation");

        var binding = Assert.Single(bindings.Screens[0].Controls);
        Assert.Equal(ScenarioBindingStatus.BoundMedium, binding.Status);
        Assert.False(binding.Candidates[0].RuntimeActionable);
        Assert.Contains(binding.Candidates[0].Evidence, x => x == "FAIL:runtime kind compatible with CheckBox or exact owner-drawn MAP geometry");
    }

    [Fact]
    public void Configured_Map_Host_Must_Be_Matched()
    {
        var logical = Compile(Source([Scenario("TS-0101-HOST", null, "BTN_SEARCH") with { MapScreenCode = "HT010103" }], []));
        var control = ActionableControl("wrong-host", "BTN_SEARCH", "HT010103") with
        {
            MapHostRequired = true,
            MapHostMatched = false,
            MapGeometryExact = true,
            MapHostId = "HT010100:selectedTabContent:HT010103"
        };

        var bindings = new ScenarioBindingMaterializer().Materialize(logical,
        [
            new RuntimeControlPlanRow { ScreenNumber = TestTargetFixture.ScreenNumber, DiscoveredControls = [control] }
        ], "installation");

        var binding = Assert.Single(bindings.Screens[0].Controls);
        Assert.Equal(ScenarioBindingStatus.BoundMedium, binding.Status);
        Assert.False(binding.ExecutionEligible);
        Assert.Contains(binding.Candidates[0].Evidence, x => x == "FAIL:configured MAP host matched");
    }

    [Fact]
    public void Exact_Owner_Drawn_Host_Geometry_Allows_Runtime_Kind_Override()
    {
        var logical = Compile(Source([Scenario("TS-0101-OWNER-DRAWN", null, "BTN_SEARCH") with { MapScreenCode = "HT010103" }], []));
        var control = ActionableControl("exact-owner-drawn", "BTN_SEARCH", "HT010103") with
        {
            RuntimeControlKind = RuleControlKind.CheckBox.ToString(),
            MapHostRequired = true,
            MapHostMatched = true,
            MapGeometryExact = true,
            MapHostId = "HT010100:selectedTabContent:HT010103",
            AllowOwnerDrawnKindOverride = true
        };

        var bindings = new ScenarioBindingMaterializer().Materialize(logical,
        [
            new RuntimeControlPlanRow { ScreenNumber = TestTargetFixture.ScreenNumber, DiscoveredControls = [control] }
        ], "installation");

        var binding = Assert.Single(bindings.Screens[0].Controls);
        Assert.Equal(ScenarioBindingStatus.BoundHigh, binding.Status);
        Assert.True(binding.ExecutionEligible);
        Assert.True(Assert.Single(binding.Candidates).RuntimeActionable);
    }

    [Fact]
    public void Runtime_Identity_Collision_Is_Not_Execution_Eligible()
    {
        var logical = Compile(Source([Scenario("TS-0101-COLLISION", null, "BTN_SEARCH") with { MapScreenCode = "HT010103" }], []));
        var control = ActionableControl("collision", "BTN_SEARCH", "HT010103") with { RuntimeIdentityUnique = false };

        var bindings = new ScenarioBindingMaterializer().Materialize(logical,
        [
            new RuntimeControlPlanRow { ScreenNumber = TestTargetFixture.ScreenNumber, DiscoveredControls = [control] }
        ], "installation");

        var binding = Assert.Single(bindings.Screens[0].Controls);
        Assert.Equal(ScenarioBindingStatus.BoundMedium, binding.Status);
        Assert.False(binding.ExecutionEligible);
        Assert.Contains(binding.Candidates[0].Evidence, x => x == "FAIL:runtime identity unique across active MAPs");
    }

    [Fact]
    public void Missing_Automation_Engine_Is_Not_Execution_Eligible()
    {
        var logical = Compile(Source([Scenario("TS-0101-ENGINE", null, "BTN_Order") with { MapScreenCode = "HT010101" }], []));
        var control = ActionableControl("no-engine", "BTN_Order", "HT010101") with { AutomationEngine = "" };

        var bindings = new ScenarioBindingMaterializer().Materialize(logical,
        [
            new RuntimeControlPlanRow { ScreenNumber = TestTargetFixture.ScreenNumber, DiscoveredControls = [control] }
        ], "installation");

        var binding = Assert.Single(bindings.Screens[0].Controls);
        Assert.Equal(ScenarioBindingStatus.BoundMedium, binding.Status);
        Assert.False(binding.ExecutionEligible);
        Assert.Contains(binding.Candidates[0].Evidence, x => x == "FAIL:runtime automation engine");
    }

    [Fact]
    public void Owner_Drawn_CheckBox_State_Scenario_Is_Not_Physically_Executable()
    {
        var scenario = Scenario("TS-0101-AFX-CHECK", null, "CHK_Credit") with
        {
            MapScreenCode = "HT010101",
            Steps =
            [
                new GeneratedScenarioStep { Sequence = 1, Action = "Toggle", ControlLogicalName = "CHK_Credit" },
                new GeneratedScenarioStep { Sequence = 2, Action = "AssertSelected", ControlLogicalName = "CHK_Credit" }
            ]
        };
        var logical = Compile(Source([scenario], []));
        var control = ActionableControl("afx-check", "CHK_Credit", "HT010101", kind: RuleControlKind.CheckBox);
        var materializer = new ScenarioBindingMaterializer();
        var bindings = materializer.Materialize(logical,
        [
            new RuntimeControlPlanRow { ScreenNumber = TestTargetFixture.ScreenNumber, DiscoveredControls = [control] }
        ], "installation");
        var physical = materializer.BuildPhysicalPlan(logical, bindings, "bindings");

        Assert.True(Assert.Single(bindings.Screens[0].Controls).ExecutionEligible);
        Assert.Equal("BLOCKED", physical.Status);
        Assert.Empty(physical.ResolvedBindings);
        Assert.Equal("PENDING_BINDING", Assert.Single(physical.ScenarioDispositions).Status);
    }

    [Fact]
    public void Multiple_Actionable_Candidates_Remain_Ambiguous()
    {
        var logical = Compile(Source([Scenario("TS-0101-AMBIGUOUS", null, "BTN_Order") with { MapScreenCode = "HT010101" }], []));

        var bindings = new ScenarioBindingMaterializer().Materialize(logical,
        [
            new RuntimeControlPlanRow
            {
                ScreenNumber = TestTargetFixture.ScreenNumber,
                DiscoveredControls =
                [
                    ActionableControl("candidate-a", "BTN_Order", "HT010101"),
                    ActionableControl("candidate-b", "BTN_Order", "HT010101") with { LocatorSignature = "MAP|candidate-b|Button|" }
                ]
            }
        ], "installation");
        var physical = new ScenarioBindingMaterializer().BuildPhysicalPlan(logical, bindings, "bindings");

        var binding = Assert.Single(bindings.Screens[0].Controls);
        Assert.Equal(ScenarioBindingStatus.Ambiguous, binding.Status);
        Assert.False(binding.ExecutionEligible);
        Assert.Equal(2, binding.Candidates.Length);
        Assert.Empty(physical.ResolvedBindings);
        Assert.Equal("BLOCKED", physical.Status);
    }

    private static RuleDiscoveredControl ActionableControl(
        string controlId,
        string name,
        string mapScreenCode,
        string stateContext = "",
        RuleControlKind kind = RuleControlKind.Button) => new()
    {
        ControlId = controlId,
        ControlKind = kind,
        Name = name,
        ClassName = kind == RuleControlKind.Text ? "Edit" : "AfxWnd140",
        LocatorSignature = $"MAP|{controlId}|{kind}|{stateContext}",
        StateContext = stateContext,
        MapScreenCode = mapScreenCode,
        DefinitionSource = "MAP+Runtime",
        RuntimeControlKind = kind.ToString(),
        AutomationEngine = "Win32/MAP",
        MapModelId = name,
        MapMatched = true,
        MapMatchDistance = 2,
        RelativeRect = RuntimeRect()
    };

    private static RuleRuntimeRect RuntimeRect() => new()
    {
        Left = 10,
        Top = 10,
        Right = 110,
        Bottom = 40,
        Width = 100,
        Height = 30,
        CenterX = 60,
        CenterY = 25
    };

    private static CompiledScenarioPlan Compile(GeneratedScenarioDocument source, ScenarioApprovalOverlay? approval = null) =>
        new ScenarioPlanCompiler().Compile(source, Dataset(), "source", "dataset", approval, approval is null ? null : "approval");

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
        Steps = valueRef is null
            ?
            [
                new GeneratedScenarioStep { Sequence = 1, Action = "Click", ControlLogicalName = control },
                new GeneratedScenarioStep { Sequence = 2, Action = "Observe" }
            ]
            :
            [
                new GeneratedScenarioStep { Sequence = 1, Action = "Input", ControlLogicalName = control, ValueRef = valueRef },
                new GeneratedScenarioStep { Sequence = 2, Action = "Observe" }
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
