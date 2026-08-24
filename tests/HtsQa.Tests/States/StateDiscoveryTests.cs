// 역할: generic State Graph의 승인, 도착 Checkpoint, 금지 동작, 상태별 identity와 JSON 호환성을 검증한다.
// 범위: 순수 Fake 계약만 사용하며 실제 HTS, UI 입력 또는 FlaUI action을 실행하지 않는다.
using System.Text.Json;
using HtsQa.Core;

namespace HtsQa.Tests;

public sealed class StateDiscoveryTests
{
    [Fact]
    public void Ready_Graph_Requires_Approved_Transition_Arrival_Checkpoint_And_Deterministic_Restore()
    {
        var issues = StateGraphValidator.Validate(ReadyGraph());

        Assert.Empty(issues);
    }

    [Theory]
    [InlineData(StateTransitionActionKind.FinalSubmit)]
    [InlineData(StateTransitionActionKind.AmendSubmit)]
    [InlineData(StateTransitionActionKind.CancelSubmit)]
    [InlineData(StateTransitionActionKind.TradeConfirmation)]
    public void Transactional_Transition_Registration_Is_Blocked(StateTransitionActionKind kind)
    {
        var graph = ReadyGraph();
        graph = graph with
        {
            Transitions = [graph.Transitions[0] with { Action = ApprovedAction(kind) }]
        };

        var issues = StateGraphValidator.Validate(graph);

        Assert.Contains(issues, issue => issue.Code == "STATE.TRANSACTIONAL_ACTION_PROHIBITED");
    }

    [Fact]
    public void Coordinate_Or_Unapproved_Transition_Is_Blocked()
    {
        var graph = ReadyGraph();
        graph = graph with
        {
            Transitions =
            [
                graph.Transitions[0] with
                {
                    Action = ApprovedAction(StateTransitionActionKind.Select) with
                    {
                        Allowlisted = false,
                        Locator = new() { Strategy = StateLocatorStrategy.Coordinates, Source = "fixture", Confidence = StateLocatorConfidence.High }
                    }
                }
            ]
        };

        var issues = StateGraphValidator.Validate(graph);

        Assert.Contains(issues, issue => issue.Code == "STATE.ACTION_APPROVAL_REQUIRED");
        Assert.Contains(issues, issue => issue.Code == "STATE.COORDINATE_LOCATOR_PROHIBITED");
    }

    [Fact]
    public void Inactive_Hidden_Or_Unapproved_Control_Cannot_Be_Executable()
    {
        var active = Control("state:a") with { ActiveState = true, Visible = true, Enabled = true, LocatorEvidence = ApprovedLocatorEvidence() };
        var inactive = active with { StateContextId = "state:b", ActiveState = false };
        var hidden = active with { StateContextId = "state:c", Visible = false };
        var unapproved = active with { StateContextId = "state:d", LocatorEvidence = ApprovedLocatorEvidence() with { Approved = false } };

        Assert.True(StateControlDiscoveryPolicy.Normalize(active, requestedExecutable: true).Executable);
        Assert.False(StateControlDiscoveryPolicy.Normalize(inactive, requestedExecutable: true).Executable);
        Assert.False(StateControlDiscoveryPolicy.Normalize(hidden, requestedExecutable: true).Executable);
        Assert.False(StateControlDiscoveryPolicy.Normalize(unapproved, requestedExecutable: true).Executable);
    }

    [Fact]
    public void Same_Control_Identity_Is_Distinct_Per_State_Context()
    {
        var first = Control("state:a");
        var second = first with { StateContextId = "state:b" };

        Assert.NotEqual(StateControlDiscoveryPolicy.IdentityKey(first), StateControlDiscoveryPolicy.IdentityKey(second));
    }

    [Fact]
    public void Action_Delivery_Without_Arrival_Checkpoint_Is_Not_A_Success_State()
    {
        var result = new StateDiscoveryStateResult
        {
            StateContext = ReadyGraph().States[1],
            Status = StateDiscoveryStatus.FAILED,
            FailureCategory = StateFailureCategory.APPLICATION,
            ReasonCode = "ARRIVAL_CHECKPOINT_NOT_SATISFIED",
            Transition = new()
            {
                TransitionId = "a-to-b",
                ActionSent = true,
                ActionVerified = true,
                ArrivalCheckpointSatisfied = false,
                Status = StateDiscoveryStatus.FAILED
            }
        };

        Assert.Equal(StateDiscoveryStatus.FAILED, result.Status);
        Assert.False(result.Transition!.ArrivalCheckpointSatisfied);
    }

    [Fact]
    public void State_Graph_And_Result_Schema_Round_Trip_Without_Breaking_Older_Adapter()
    {
        var graph = ReadyGraph();
        var graphJson = JsonSerializer.Serialize(graph, JsonDefaults.Options);
        var roundTrip = JsonSerializer.Deserialize<StateGraph>(graphJson, JsonDefaults.Options);
        var legacyAdapter = JsonSerializer.Deserialize<RuleTargetAdapterProfile>("{\"schemaVersion\":\"1.0\",\"id\":\"fake\",\"screenIds\":[\"F001\"]}", JsonDefaults.Options);
        var document = new StateDiscoveryResultDocument
        {
            GraphId = graph.GraphId,
            ObservedAt = DateTimeOffset.Parse("2026-08-24T00:00:00+09:00"),
            States = [new() { StateContext = graph.States[0], Status = StateDiscoveryStatus.SUCCESS, ScreenshotRef = "screenshots/a.png", UiTreeRef = "ui-tree/a.json" }],
            Restore = new() { Status = StateRestoreStatus.SUCCESS, ArrivalCheckpointSatisfied = true }
        };
        var resultJson = JsonSerializer.Serialize(document, JsonDefaults.Options);
        var resultRoundTrip = JsonSerializer.Deserialize<StateDiscoveryResultDocument>(resultJson, JsonDefaults.Options);

        Assert.Equal(StateDiscoveryVersions.GraphSchema, roundTrip!.SchemaVersion);
        Assert.Equal("a-to-b", Assert.Single(roundTrip.Transitions).TransitionId);
        Assert.NotNull(legacyAdapter);
        Assert.Null(legacyAdapter!.StateGraph);
        Assert.Equal(StateRestoreStatus.SUCCESS, resultRoundTrip!.Restore.Status);
        Assert.Equal(StateDiscoveryVersions.ResultSchema, resultRoundTrip.SchemaVersion);
    }

    private static StateGraph ReadyGraph() => new()
    {
        GraphId = "fake-state-graph",
        ScreenId = "F001",
        ConfigurationStatus = StateGraphConfigurationStatus.Ready,
        BaselineStateId = "a",
        States =
        [
            new() { StateId = "a", StateContextId = "state:a", ScreenId = "F001", ConfigurationStatus = StateGraphConfigurationStatus.Ready, EvidenceRefs = ["fixture:a"] },
            new() { StateId = "b", StateContextId = "state:b", ScreenId = "F001", ConfigurationStatus = StateGraphConfigurationStatus.Ready, EvidenceRefs = ["fixture:b"] }
        ],
        Transitions =
        [
            new()
            {
                TransitionId = "a-to-b",
                SourceStateId = "a",
                TargetStateId = "b",
                Precondition = new() { ExpectedStateId = "a", EvidenceRequirements = ["state snapshot"] },
                Action = ApprovedAction(StateTransitionActionKind.Select),
                ArrivalCheckpoint = Arrival("arrive-b"),
                TimeoutMs = 1000,
                RestoreAction = ApprovedAction(StateTransitionActionKind.Select),
                RiskClass = StateTransitionRiskClass.SafeNavigation,
                EvidenceRequirements = ["action delivery", "arrival checkpoint"]
            }
        ],
        RestorePolicy = new()
        {
            Mode = StateRestoreMode.Deterministic,
            BaselineStateId = "a",
            MaxAttempts = 1,
            TimeoutMs = 1000,
            Action = ApprovedAction(StateTransitionActionKind.Select),
            ArrivalCheckpoint = Arrival("restore-a"),
            EvidenceRequirements = ["restore action", "baseline arrival checkpoint"]
        },
        EvidenceRefs = ["fixture:graph"]
    };

    private static StateTransitionAction ApprovedAction(StateTransitionActionKind kind) => new()
    {
        TargetControlId = "FAKE_STATE_SELECTOR",
        Kind = kind,
        Allowlisted = true,
        ApprovalEvidence = ["fixture:approval"],
        Locator = new()
        {
            Strategy = StateLocatorStrategy.AutomationId,
            AutomationId = "fixture-selector",
            Source = "fixture:locator",
            Confidence = StateLocatorConfidence.High
        }
    };

    private static ArrivalCheckpoint Arrival(string id) => new()
    {
        CheckpointId = id,
        Kind = "AssertState",
        Required = true,
        EvidenceRequirements = ["fixture:state observation"]
    };

    private static StateControlDiscovery Control(string context) => new()
    {
        StateContextId = context,
        Hwnd = 42,
        UiaRuntimeId = "1.2.3",
        MapControlId = "MAP-CONTROL",
        RuntimeControlId = "RUNTIME-CONTROL",
        LocatorEvidence = ApprovedLocatorEvidence()
    };

    private static StateLocatorEvidence ApprovedLocatorEvidence() => new()
    {
        Source = "fixture:locator",
        Confidence = StateLocatorConfidence.High,
        Approved = true,
        EvidenceRefs = ["fixture:evidence"]
    };
}
