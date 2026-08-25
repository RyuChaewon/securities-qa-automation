// 역할: 승인 key 기반 주문 시나리오 validator, 불변 run plan, fail-closed DryRun 계약을 검증한다.
using System.Text.Json;
using HtsQa.Core;

namespace HtsQa.Tests.Scenarios;

public sealed class OrderScenarioAuthoringTests
{
    [Fact]
    public void Approved_Repository_Keys_Compile_To_Immutable_DryRun_Plan()
    {
        var result = OrderScenarioRunPlanCompiler.Compile(Input(), At);

        Assert.True(result.Validation.IsValid);
        var plan = Assert.IsType<OrderScenarioRunPlan>(result.Plan);
        Assert.False(plan.ActualExecutionAllowed);
        Assert.Equal(OrderRunPlanExecutionMode.DryRun, plan.ExecutionMode);
        Assert.Equal(OrderScenarioRunPlanCompiler.ComputeHash(plan), plan.PlanHash, ignoreCase: true);
        Assert.Equal(ExecutionAuthorizationStatus.Authorized, plan.AuthorizationStatus);
        Assert.False(string.IsNullOrWhiteSpace(plan.EnvironmentFingerprintHash));
        Assert.False(string.IsNullOrWhiteSpace(plan.ExecutionAuthorizationHash));
        Assert.All(plan.Steps, step => Assert.False(string.IsNullOrWhiteSpace(step.ApprovalHash)));
        Assert.Empty(plan.Variables);
        Assert.All(plan.Steps, step => Assert.False(string.IsNullOrWhiteSpace(step.ControlContractHash)));
        Assert.True(plan.Steps.Single(x => x.StepId == "required-checkpoint").RequiredForPass);
        Assert.False(plan.Steps.Single(x => x.StepId == "action").AffectsVerdict);
    }

    [Fact]
    public void Missing_And_Unapproved_Repository_Keys_Are_Blocked()
    {
        var missing = Input() with { Repository = Repository() with { Entries = [] } };
        var unapprovedEntry = StableEntry() with { Status = ControlRepositoryEntryStatus.ReviewRequired };
        var unapproved = Input() with { Repository = Repository(unapprovedEntry) };

        AssertIssue(missing, "ORDER_SCENARIO.REPOSITORY_KEY_NOT_FOUND");
        AssertIssue(unapproved, "ORDER_SCENARIO.REPOSITORY_ENTRY_NOT_APPROVED");
    }

    [Fact]
    public void Approval_Hash_Mismatch_Is_Blocked()
    {
        var entry = StableEntry() with { ApprovalPayloadHash = new string('0', 64) };
        AssertIssue(Input() with { Repository = Repository(entry) }, "ORDER_SCENARIO.APPROVAL_HASH_MISMATCH");
    }

    [Fact]
    public void StateContext_Mismatch_Is_Blocked()
    {
        var scenario = Scenario() with
        {
            Steps = Scenario().Steps.Select((step, index) => index == 0 ? step with { CurrentStateContext = "state:other" } : step).ToArray()
        };
        AssertIssue(Input() with { Scenario = scenario }, "ORDER_SCENARIO.STATE_CONTEXT_MISMATCH");
    }

    [Fact]
    public void Required_Checkpoint_Missing_And_Action_Only_Scenario_Are_Blocked()
    {
        var noCheckpoint = Scenario() with { Steps = Scenario().Steps.Where(x => x.Role != OrderScenarioStepRole.Checkpoint).ToArray() };
        AssertIssue(Input() with { Scenario = noCheckpoint }, "ORDER_SCENARIO.REQUIRED_CHECKPOINT_MISSING");
    }

    [Fact]
    public void Optional_Checkpoint_Is_Nonblocking_But_Executed_Failure_Remains_Evaluator_Input()
    {
        var scenario = Scenario();
        var optional = scenario.Steps.Single(x => x.StepId == "required-checkpoint") with
        {
            StepId = "optional-checkpoint", Sequence = 3, CheckpointRequirement = OrderCheckpointRequirement.Optional,
            ExpectedMode = RuleExpectedOutcomeType.ObservationOnly
        };
        scenario = scenario with
        {
            Steps = [scenario.Steps[0], scenario.Steps[1], scenario.Steps[2], optional with { Sequence = 4 }, scenario.Steps[3] with { Sequence = 5 }]
        };

        var result = OrderScenarioRunPlanCompiler.Compile(Input() with { Scenario = scenario }, At);

        Assert.True(result.Validation.IsValid);
        Assert.True(result.Plan!.Steps.Single(x => x.StepId == "required-checkpoint").AffectsVerdict);
        Assert.True(result.Plan.Steps.Single(x => x.StepId == "optional-checkpoint").AffectsVerdict);
        Assert.False(result.Plan.Steps.Single(x => x.StepId == "optional-checkpoint").RequiredForPass);
    }

    [Theory]
    [InlineData(RuleExpectedOutcomeType.ObservationOnly)]
    [InlineData(RuleExpectedOutcomeType.Unspecified)]
    public void Non_Verdict_Expectation_Cannot_Support_Required_Checkpoint(RuleExpectedOutcomeType mode)
    {
        var scenario = Scenario() with
        {
            Steps = Scenario().Steps.Select(x => x.StepId == "required-checkpoint" ? x with { ExpectedMode = mode } : x).ToArray()
        };
        AssertIssue(Input() with { Scenario = scenario }, "ORDER_SCENARIO.NON_VERDICT_EXPECTATION");
    }

    [Fact]
    public void Checkpoint_That_Only_Repeats_Action_Delivery_Is_Blocked()
    {
        var scenario = Scenario() with
        {
            Steps = Scenario().Steps.Select(x => x.StepId == "required-checkpoint"
                ? x with { EvidenceRequirements = [OrderEvidenceKind.ActionDelivery, OrderEvidenceKind.Screenshot] }
                : x).ToArray()
        };
        AssertIssue(Input() with { Scenario = scenario }, "ORDER_SCENARIO.ACTION_DELIVERY_ONLY_CHECKPOINT");
    }

    [Fact]
    public void Relative_Coordinate_FinalSubmit_Is_Blocked_Even_With_Transactional_Approval()
    {
        var transaction = CoordinateEntry(ControlRepositoryAction.FinalSubmit, ControlRiskClass.Transactional, "TRANSACTION_CONTROL");
        var input = TransactionInput(transaction, ControlRepositoryAction.FinalSubmit, OrderScenarioOperation.Click) with
        {
            TransactionalExecutionApproved = true,
            TransactionalScenarioAllowlist = ["fixture-scenario"]
        };
        AssertIssue(input, "ORDER_SCENARIO.COORDINATE_TRANSACTION_FORBIDDEN");
    }

    [Fact]
    public void Image_Only_Locator_Cannot_Perform_Physical_Action()
    {
        var visual = VisualEntry();
        var scenario = ReplaceActionKey(Scenario(), visual.Key, ControlRepositoryAction.Click, OrderScenarioOperation.Click, ControlRiskClass.General);
        AssertIssue(Input() with { Scenario = scenario, Repository = Repository(StableEntry(), visual) }, "ORDER_SCENARIO.IMAGE_ONLY_PHYSICAL_ACTION");
    }

    [Fact]
    public void Transactional_Action_Without_Environment_Scope_Is_Blocked()
    {
        var transaction = StableEntry(ControlRepositoryAction.FinalSubmit, ControlRiskClass.Transactional, "TRANSACTION_CONTROL");
        AssertIssue(TransactionInput(transaction, ControlRepositoryAction.FinalSubmit, OrderScenarioOperation.Click), "AUTH.TRANSACTION_SCOPE_REQUIRED");
    }

    [Fact]
    public void Sensitive_Input_Readback_Is_Blocked()
    {
        var scenario = Scenario() with
        {
            Variables = [new() { Name = "secret", Sensitive = true }],
            Steps = Scenario().Steps.Select(x => x.StepId == "action" ? x with { VariableRef = "secret", ReadbackRequired = true } : x).ToArray()
        };
        AssertIssue(Input() with { Scenario = scenario }, "ORDER_SCENARIO.SENSITIVE_READBACK_FORBIDDEN");
    }

    [Fact]
    public void Duplicate_Variable_And_Incomplete_Failure_Evidence_Are_Structured_Blockers()
    {
        var scenario = Scenario() with
        {
            Variables = [new() { Name = "value" }, new() { Name = "value" }],
            Steps = Scenario().Steps.Select(x => x.StepId == "action" ? x with { FailureEvidence = ["screenshot"] } : x).ToArray()
        };
        var report = OrderScenarioValidator.Validate(Input() with { Scenario = scenario });

        Assert.Contains(report.Issues, x => x.Code == "ORDER_SCENARIO.AMBIGUOUS_VARIABLE");
        Assert.Contains(report.Issues, x => x.Code == "ORDER_SCENARIO.FAILURE_EVIDENCE_REQUIRED");
    }

    [Fact]
    public void Role_And_Operation_Mismatch_Is_Blocked()
    {
        var scenario = Scenario() with
        {
            Steps = Scenario().Steps.Select(x => x.StepId == "required-checkpoint" ? x with { Operation = OrderScenarioOperation.Input } : x).ToArray()
        };

        AssertIssue(Input() with { Scenario = scenario }, "ORDER_SCENARIO.ROLE_OPERATION_MISMATCH");
    }

    [Fact]
    public void Ambiguous_Logical_Key_Is_Blocked_Without_Auto_Selection()
    {
        var entry = StableEntry();
        AssertIssue(Input() with { Repository = Repository(entry, entry) }, "ORDER_SCENARIO.AMBIGUOUS_LOGICAL_KEY");
    }

    [Fact]
    public void Dpi_And_Bounds_Transform_Do_Not_Reapprove_But_Fingerprint_Drift_Is_Blocked()
    {
        var transformed = Input() with { RuntimeContext = Runtime() with { DpiScale = 1.25, ClientWidth = 801, WindowWidth = 1201 } };
        var drifted = Input() with { RuntimeContext = Runtime() with { HostFingerprint = "changed-host" } };

        Assert.True(OrderScenarioValidator.Validate(transformed).IsValid);
        AssertIssue(drifted, "ORDER_SCENARIO.RUNTIME_DRIFT");
    }

    [Fact]
    public void Missing_Restore_Policy_And_Step_Are_Blocked()
    {
        var scenario = Scenario() with { Restore = null, Steps = Scenario().Steps.Where(x => x.Role != OrderScenarioStepRole.Restore).ToArray() };
        var report = OrderScenarioValidator.Validate(Input() with { Scenario = scenario });

        Assert.Contains(report.Issues, x => x.Code == "ORDER_SCENARIO.RESTORE_POLICY_MISSING");
        Assert.Contains(report.Issues, x => x.Code == "ORDER_SCENARIO.RESTORE_STEP_MISSING");
    }

    [Fact]
    public void DryRun_Performs_Zero_Ui_And_Transactional_Actions_And_Never_Passes()
    {
        var plan = OrderScenarioRunPlanCompiler.Compile(Input(), At).Plan!;
        var result = OrderScenarioDryRun.Execute(plan);

        Assert.Equal(TestStatus.PENDING, result.Status);
        Assert.Equal(0, result.ActualUiActionCount);
        Assert.Equal(0, result.TransactionalActionCount);
        Assert.True(result.PlanHashValid);
        Assert.True(result.RequiredCheckpointChecked);
        Assert.True(result.RestorePlanChecked);
        Assert.True(result.AuthorizationChecked);
        Assert.True(result.VariableBindingChecked);
    }

    [Fact]
    public void DryRun_Detects_Undeclared_Variable_Reference_Without_Sending_Action()
    {
        var plan = OrderScenarioRunPlanCompiler.Compile(Input(), At).Plan!;
        var changedSteps = plan.Steps.Select(x => x.StepId == "action" ? x with { VariableRef = "missing" } : x).ToArray();
        var changed = plan with { PlanId = "", PlanHash = "", Steps = changedSteps };
        var hash = OrderScenarioRunPlanCompiler.ComputeHash(changed);
        changed = changed with { PlanId = $"order-plan-{hash[..16]}", PlanHash = hash };

        var result = OrderScenarioDryRun.Execute(changed);

        Assert.False(result.VariableBindingChecked);
        Assert.Equal(0, result.ActualUiActionCount);
    }

    [Fact]
    public void DryRun_Detects_A_Transition_Whose_Target_Does_Not_Match_The_Next_State()
    {
        var plan = OrderScenarioRunPlanCompiler.Compile(Input(), At).Plan!;
        var changedSteps = plan.Steps.Select(x => x.StepId == "action"
            ? x with { Role = OrderScenarioStepRole.Transition, TargetStateId = "b", TargetStateContext = "state:b" }
            : x).ToArray();
        var changed = plan with { PlanId = "", PlanHash = "", Steps = changedSteps };
        var hash = OrderScenarioRunPlanCompiler.ComputeHash(changed);
        changed = changed with { PlanId = $"order-plan-{hash[..16]}", PlanHash = hash };

        var result = OrderScenarioDryRun.Execute(changed);

        Assert.True(result.PlanHashValid);
        Assert.False(result.StateOrderChecked);
        Assert.Equal(0, result.ActualUiActionCount);
    }

    [Fact]
    public void New_Documents_RoundTrip_And_Legacy_Scenario_Contract_Remains_Readable()
    {
        var plan = OrderScenarioRunPlanCompiler.Compile(Input(), At).Plan!;
        var json = JsonSerializer.Serialize(plan, JsonDefaults.Options);
        var roundTrip = JsonSerializer.Deserialize<OrderScenarioRunPlan>(json, JsonDefaults.Options);
        var legacy = JsonSerializer.Deserialize<GeneratedScenarioStep>("""{"sequence":1,"action":"Click","controlLogicalName":"X"}""", JsonDefaults.Options);

        Assert.Equal(plan.PlanHash, roundTrip!.PlanHash);
        Assert.Equal("Click", legacy!.Action);
        Assert.Equal(ScenarioPlanVersions.CompiledSchema, new CompiledScenarioPlan
        {
            PlanId = "p", PlanHash = "h", SourceSha256 = "s", SourceInstallationFingerprint = "f",
            DatasetId = "d", DatasetSha256 = "x", Status = "PENDING"
        }.SchemaVersion);
    }

    [Fact]
    public void Actual_0101_Templates_And_Repository_Remain_ConfigurationRequired()
    {
        var root = FindRoot();
        var repository = JsonSerializer.Deserialize<ControlRepositoryDocument>(
            File.ReadAllText(Path.Combine(root, "targets", "1q-hts", "0101", "control-repository.json")), JsonDefaults.Options);
        var templateFiles = Directory.GetFiles(Path.Combine(root, "targets", "1q-hts", "0101", "scenario-templates"), "*.json");
        var templates = templateFiles.Select(path => JsonSerializer.Deserialize<OrderScenarioTemplate>(File.ReadAllText(path), JsonDefaults.Options)!).ToArray();

        Assert.NotNull(repository);
        Assert.Empty(repository!.Entries);
        Assert.Equal(ControlRepositoryStatus.ConfigurationRequired, repository.Status);
        Assert.Equal(3, templates.Length);
        Assert.All(templates, template =>
        {
            Assert.Equal(OrderScenarioConfigurationStatus.ConfigurationRequired, template.Status);
            Assert.False(template.Executable);
            Assert.Empty(template.RepositoryKeys);
            Assert.NotEmpty(template.RequiredFieldEvidence);
        });
    }

    private static readonly DateTimeOffset At = DateTimeOffset.Parse("2026-08-24T09:00:00+09:00");

    private static void AssertIssue(OrderScenarioValidationInput input, string code) =>
        Assert.Contains(OrderScenarioValidator.Validate(input).Issues, issue => issue.Code == code);

    private static OrderScenarioValidationInput Input()
    {
        var entry = StableEntry();
        return new()
        {
            Scenario = Scenario(), Repository = Repository(entry), StateGraph = Graph(), RuntimeContext = Runtime(),
            CurrentEnvironment = Environment(), ExecutionAuthorization = Authorization(DefaultScope()),
            AuthorizationCheckedAt = At, ControlPreflightObservations = [Observation(entry)]
        };
    }

    private static OrderScenarioDocument Scenario() => new()
    {
        ScenarioId = "fixture-scenario", CaseId = "fixture-case", TargetProfileId = "fixture-target",
        Screen = "F001", Map = "FAKE-MAP", Status = OrderScenarioConfigurationStatus.Ready,
        InitialStateContext = "state:a", TargetStateContext = "state:a",
        Restore = new() { PolicyId = "fixture-restore", BaselineStateId = "a" },
        Steps =
        [
            Step("precondition", 1, OrderScenarioStepRole.Precondition, ControlRepositoryAction.Assert, OrderScenarioOperation.ObserveState, false),
            Step("action", 2, OrderScenarioStepRole.Action, ControlRepositoryAction.Input, OrderScenarioOperation.Input, true),
            Step("required-checkpoint", 3, OrderScenarioStepRole.Checkpoint, ControlRepositoryAction.Assert, OrderScenarioOperation.AssertState, false) with
            {
                CheckpointRequirement = OrderCheckpointRequirement.Required,
                EvidenceRequirements = [OrderEvidenceKind.State],
                ExpectedMode = RuleExpectedOutcomeType.Success
            },
            Step("restore", 4, OrderScenarioStepRole.Restore, ControlRepositoryAction.Select, OrderScenarioOperation.Restore, true) with
            {
                TargetStateId = "a", TargetStateContext = "state:a", RestorePolicyId = "fixture-restore",
                ExpectedMode = RuleExpectedOutcomeType.Success
            }
        ]
    };

    private static OrderScenarioStep Step(string id, int sequence, OrderScenarioStepRole role,
        ControlRepositoryAction action, OrderScenarioOperation operation, bool physical) => new()
    {
        StepId = id, Sequence = sequence, Role = role, RepositoryKey = Key(), CurrentStateId = "a",
        CurrentStateContext = "state:a", TargetStateId = "a", TargetStateContext = "state:a",
        RepositoryAction = action, Operation = operation, PhysicalAction = physical,
        ExpectedMode = RuleExpectedOutcomeType.Success, TimeoutMs = 1000, RiskClass = ControlRiskClass.General,
        ExecutionAllowed = true
    };

    private static OrderScenarioDocument ReplaceActionKey(OrderScenarioDocument scenario, ControlRepositoryKey key,
        ControlRepositoryAction action, OrderScenarioOperation operation, ControlRiskClass risk) => scenario with
    {
        Steps = scenario.Steps.Select(x => x.StepId == "action"
            ? x with { RepositoryKey = key, RepositoryAction = action, Operation = operation, RiskClass = risk, TransactionalAllowlisted = true, OrderType = risk == ControlRiskClass.Transactional ? "LIMIT" : "" }
            : x).ToArray()
    };

    private static OrderScenarioValidationInput TransactionInput(ControlRepositoryEntry transaction, ControlRepositoryAction action, OrderScenarioOperation operation)
    {
        var scenario = ReplaceActionKey(Scenario(), transaction.Key, action, operation, transaction.RiskClass);
        var stable = StableEntry();
        var scope = DefaultScope() with
        {
            AllowedActions = [ControlRepositoryAction.Input, ControlRepositoryAction.Assert, ControlRepositoryAction.Select, action],
            AllowedRiskClasses = [ControlRiskClass.General, transaction.RiskClass],
            TransactionalActionsAllowed = false,
            AllowedOrderTypes = ["LIMIT"]
        };
        return Input() with { Scenario = scenario, Repository = Repository(stable, transaction),
            ExecutionAuthorization = Authorization(scope), ControlPreflightObservations = [Observation(stable), Observation(transaction)] };
    }

    private static ControlRepositoryKey Key(string logical = "FIXTURE_CONTROL") => new()
    {
        Screen = "F001", Map = "FAKE-MAP", LogicalName = logical, StateContext = "state:a"
    };

    private static ControlRepositoryEntry StableEntry(ControlRepositoryAction extra = ControlRepositoryAction.Observe,
        ControlRiskClass risk = ControlRiskClass.General, string logical = "FIXTURE_CONTROL")
    {
        var allowed = new[] { ControlRepositoryAction.Input, ControlRepositoryAction.Assert, ControlRepositoryAction.Select, extra }.Distinct().ToArray();
        var entry = new ControlRepositoryEntry
        {
            Key = Key(logical), TargetProfileId = "fixture-target", BusinessRole = logical,
            TransactionalRole = extra switch { ControlRepositoryAction.FinalSubmit => ControlTransactionalRole.FinalSubmit,
                ControlRepositoryAction.AmendSubmit => ControlTransactionalRole.AmendSubmit,
                ControlRepositoryAction.CancelSubmit => ControlTransactionalRole.CancelSubmit, _ => ControlTransactionalRole.None },
            Status = ControlRepositoryEntryStatus.ReviewRequired,
            StableIdentity = new() { AutomationId = "fixture-" + logical.ToLowerInvariant() }, HostFingerprint = Host(),
            ExpectedControlKind = "Edit", RiskClass = risk, AllowedActions = allowed,
            ForbiddenActions = (extra is ControlRepositoryAction.FinalSubmit or ControlRepositoryAction.AmendSubmit or ControlRepositoryAction.CancelSubmit) ? [] :
                [ControlRepositoryAction.FinalSubmit, ControlRepositoryAction.AmendSubmit, ControlRepositoryAction.CancelSubmit],
            CreatedAt = At, ReviewedAt = At, Source = "fixture:review", EvidenceRefs = ["fixture:evidence"]
        };
        return Approve(entry);
    }

    private static ControlRepositoryEntry CoordinateEntry(ControlRepositoryAction action, ControlRiskClass risk, string logical)
    {
        var entry = new ControlRepositoryEntry
        {
            Key = Key(logical), TargetProfileId = "fixture-target", BusinessRole = logical,
            TransactionalRole = action switch { ControlRepositoryAction.FinalSubmit => ControlTransactionalRole.FinalSubmit,
                ControlRepositoryAction.AmendSubmit => ControlTransactionalRole.AmendSubmit,
                ControlRepositoryAction.CancelSubmit => ControlTransactionalRole.CancelSubmit, _ => ControlTransactionalRole.None },
            Status = ControlRepositoryEntryStatus.ReviewRequired,
            AnchoredRelativeCoordinate = new() { RelativeX = 0.25, RelativeY = 0.5, RelativeWidth = 0.1, RelativeHeight = 0.1, AnchorId = "fixture-anchor" },
            HostFingerprint = Host(), ExpectedControlKind = "Button",
            VisualSignature = new() { Algorithm = "fixture", SignatureHash = "redacted-signature" },
            RiskClass = risk, AllowedActions = [action], CreatedAt = At, ReviewedAt = At,
            Source = "fixture:review", EvidenceRefs = ["fixture:evidence"]
        };
        return Approve(entry);
    }

    private static ControlRepositoryEntry VisualEntry()
    {
        var entry = new ControlRepositoryEntry
        {
            Key = Key("VISUAL_CONTROL"), TargetProfileId = "fixture-target", BusinessRole = "visual-observation", Status = ControlRepositoryEntryStatus.ReviewRequired,
            HostFingerprint = Host(), ExpectedControlKind = "Button",
            VisualSignature = new() { Algorithm = "fixture", SignatureHash = "redacted-signature" },
            RiskClass = ControlRiskClass.General, AllowedActions = [ControlRepositoryAction.Click],
            CreatedAt = At, ReviewedAt = At, Source = "fixture:review", EvidenceRefs = ["fixture:evidence"]
        };
        return Approve(entry);
    }

    private static ControlRepositoryEntry Approve(ControlRepositoryEntry entry)
    {
        var template = ControlRepositoryApprovalWorkflow.CreateTemplate(entry);
        return ControlRepositoryApprovalWorkflow.Apply(entry, template with
        {
            Status = TestPackApprovalStatus.Approved, ApprovedBy = "fixture-reviewer", ApprovedAt = At,
            EvidenceRefs = ["fixture:approval"]
        });
    }

    private static ControlRepositoryDocument Repository(params ControlRepositoryEntry[] entries) => new()
    {
        RepositoryId = "fixture-repository", TargetProfileId = "fixture-target", Status = ControlRepositoryStatus.Ready, Entries = entries
    };

    private static ExecutionAuthorizationDocument Authorization(ExecutionAuthorizationScope scope)
    {
        var draft = new ExecutionAuthorizationDraft { Environment = Environment(), Scope = scope };
        var template = ExecutionAuthorizationWorkflow.CreateTemplate(draft);
        return ExecutionAuthorizationWorkflow.Apply(draft, template with
        {
            Status = TestPackApprovalStatus.Approved, ApprovedBy = "fixture-environment-reviewer",
            ApprovedAt = At, EvidenceRefs = ["fixture:environment-approval"]
        });
    }

    private static ExecutionAuthorizationScope DefaultScope() => new()
    {
        PolicyVersion = "fixture-policy/1.0", TargetIds = ["fixture-target"], Screens = ["F001"], Maps = ["FAKE-MAP"],
        AllowedActions = [ControlRepositoryAction.Input, ControlRepositoryAction.Assert, ControlRepositoryAction.Select],
        AllowedRiskClasses = [ControlRiskClass.General], ExpiresAt = At.AddDays(30)
    };

    private static EnvironmentFingerprintInput Environment() => new()
    {
        TargetId = "fixture-target", ProductClassification = "synthetic-hts",
        ExecutableFingerprint = "fixture-exe-hash", InstallationFingerprint = "fixture-install-hash", VersionFingerprint = "1.0",
        HostClassification = "isolated-test-host", MachineFingerprint = "fixture-machine-hash",
        EnvironmentClassification = ExecutionEnvironmentClassification.Test, RoutingClassification = "simulation-routing",
        AccountClassification = ExecutionAccountClassification.Test, AdapterVersion = "fixture-adapter/1.0",
        ExecutionPolicyVersion = "fixture-policy/1.0"
    };

    private static ControlContractObservation Observation(ControlRepositoryEntry entry) => new()
    {
        Key = entry.Key, StateContext = entry.Key.StateContext, StableIdentity = entry.StableIdentity,
        MapRuntimeBinding = entry.MapRuntimeBinding, AnchoredRelativeCoordinate = entry.AnchoredRelativeCoordinate,
        ExpectedControlKind = entry.ExpectedControlKind, VisualSignatureMatched = true,
        ProcessName = entry.HostFingerprint!.ProcessName, ProcessFingerprint = entry.HostFingerprint.ProcessFingerprint,
        HostFingerprint = entry.HostFingerprint.HostFingerprint,
        WindowWidth = 1000, WindowHeight = 700, ClientWidth = 800, ClientHeight = 600, DpiScale = 1
    };

    private static ControlHostFingerprint Host() => new()
    {
        ProcessName = "fixture-process", ProcessFingerprint = "fixture-process-hash", HostFingerprint = "fixture-host-hash",
        CapturedWindowWidth = 1000, CapturedWindowHeight = 700, CapturedClientWidth = 800, CapturedClientHeight = 600, CapturedDpiScale = 1.0
    };

    private static OrderScenarioRuntimeContext Runtime() => new()
    {
        ActiveScreen = "F001", ActiveMap = "FAKE-MAP", ActiveStateContext = "state:a",
        ProcessName = "fixture-process", ProcessFingerprint = "fixture-process-hash", HostFingerprint = "fixture-host-hash",
        WindowWidth = 1000, WindowHeight = 700, ClientWidth = 800, ClientHeight = 600, DpiScale = 1.0
    };

    private static StateGraph Graph() => new()
    {
        GraphId = "fixture-graph", ScreenId = "F001", ConfigurationStatus = StateGraphConfigurationStatus.Ready,
        BaselineStateId = "a",
        States = [new() { StateId = "a", StateContextId = "state:a", ScreenId = "F001", ConfigurationStatus = StateGraphConfigurationStatus.Ready, EvidenceRefs = ["fixture:state"] }],
        RestorePolicy = new()
        {
            Mode = StateRestoreMode.Deterministic, BaselineStateId = "a", MaxAttempts = 1, TimeoutMs = 1000,
            Action = StateAction(), ArrivalCheckpoint = new() { CheckpointId = "restore-a", Kind = "AssertState", Required = true, EvidenceRequirements = ["fixture:state"] },
            EvidenceRequirements = ["fixture:restore"]
        },
        EvidenceRefs = ["fixture:graph"]
    };

    private static StateTransitionAction StateAction() => new()
    {
        TargetControlId = "FIXTURE_STATE", Kind = StateTransitionActionKind.Select, Allowlisted = true,
        ApprovalEvidence = ["fixture:approval"], Locator = new()
        {
            Strategy = StateLocatorStrategy.AutomationId, AutomationId = "fixture-state", Source = "fixture:locator", Confidence = StateLocatorConfidence.High
        }
    };

    private static string FindRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null)
        {
            if (File.Exists(Path.Combine(current.FullName, "HtsQaPoc.sln"))) return current.FullName;
            current = current.Parent;
        }
        throw new DirectoryNotFoundException("Repository root not found.");
    }
}
