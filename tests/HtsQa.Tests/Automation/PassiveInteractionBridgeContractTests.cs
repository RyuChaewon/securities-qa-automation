// 역할: passive interaction bridge dispatch가 typed request/response와 0-action metadata를 유지하는지 검증한다.
// 입력/출력: synthetic pointer/frame request를 engine Execute에 전달해 interaction·zone response를 확인한다.
// 경계: 실제 HWND, global hook, screenshot, UI action, ResultEvaluator와 TestResult를 사용하지 않는다.
// 수정 지점: BridgeRequest/Response 또는 passive operation 이름 변경 시 함께 갱신한다.
using HtsQa.FlaUi;

namespace HtsQa.Tests.Automation;

public sealed class PassiveInteractionBridgeContractTests
{
    [Fact]
    public void Analyze_And_Cluster_Operations_Return_Discovery_Without_Action()
    {
        using var engine = new FlaUiAutomationEngine();
        var pre = Frame("pre");
        var post = Frame("post");
        var request = new BridgeRequest
        {
            RequestId = "analyze",
            Operation = "analyzeObservedInteraction",
            RootHwnd = 10,
            InteractionSequence = 1,
            PointerDown = Pointer(1, "Down"),
            PointerUp = Pointer(2, "Up"),
            PreInteractionFrame = pre,
            PostInteractionFrames = [post, post]
        };

        var analyzed = engine.Execute(request);

        Assert.True(analyzed.Success, analyzed.Message);
        Assert.False(analyzed.ActionSent);
        Assert.False(analyzed.ActionVerified);
        var interaction = Assert.IsType<ObservedInteractionSnapshot>(analyzed.ObservedInteraction);
        Assert.Equal("Discovery", interaction.ArtifactRole);
        Assert.False(interaction.Automated);
        Assert.False(interaction.VerdictEligible);
        Assert.Equal(0, interaction.ActionSentCount);
        Assert.Equal(0, interaction.TransactionalActionCount);

        var clustered = engine.Execute(new BridgeRequest
        {
            RequestId = "cluster",
            Operation = "clusterObservedInteractions",
            RootHwnd = 10,
            Interactions = [interaction]
        });
        Assert.True(clustered.Success, clustered.Message);
        Assert.False(clustered.ActionSent);
        var zone = Assert.Single(clustered.InteractionZones);
        Assert.Equal("ReviewRequired", zone.Status);
        Assert.False(zone.AutomaticallyApproved);
        Assert.False(zone.Executable);
    }

    [Fact]
    public void Analyze_Rejects_Incomplete_Evidence_Without_Fallback_Or_Action()
    {
        using var engine = new FlaUiAutomationEngine();
        var response = engine.Execute(new BridgeRequest { RequestId = "missing", Operation = "analyzeObservedInteraction", RootHwnd = 10 });
        Assert.False(response.Success);
        Assert.Equal("PASSIVE_INTERACTION_EVIDENCE_REQUIRED", response.ErrorCode);
        Assert.False(response.ActionSent);
        Assert.False(response.ActionVerified);
        Assert.False(response.FallbackRequired);
    }

    private static PassivePointerObservation Pointer(long sequence, string phase) => new()
    {
        Sequence = sequence,
        ObservedAt = new DateTimeOffset(2026, 8, 25, 12, 0, 0, TimeSpan.Zero).AddMilliseconds(sequence * 100),
        Button = "Left",
        Phase = phase,
        X = 250,
        Y = 150
    };

    private static NativeInteractionFrameSnapshot Frame(string fingerprint)
    {
        var root = new NativeInteractionWindowSnapshot
        {
            Hwnd = 10,
            RootHwnd = 10,
            ClassName = "AfxWnd140",
            NativeSignature = "root-signature",
            IsVisible = true,
            IsEnabled = true,
            IsDescendant = true,
            Bounds = new() { Left = 0, Top = 0, Right = 1000, Bottom = 700 },
            SpatialRegion = "GlobalHeader"
        };
        return new()
        {
            RootHwnd = 10,
            ProcessId = 100,
            ForegroundHwnd = 10,
            FocusHwnd = 10,
            RootBounds = new() { Left = 0, Top = 0, Right = 1000, Bottom = 700 },
            RootClientBounds = new() { Left = 0, Top = 0, Right = 1000, Bottom = 700 },
            LayoutFingerprint = fingerprint,
            StateFingerprint = fingerprint,
            ObservedAt = new DateTimeOffset(2026, 8, 25, 12, 0, 1, TimeSpan.Zero),
            Windows = [root],
            VisualSignature = new() { Available = false, PixelDataStored = false }
        };
    }
}
