// 역할: passive mouse/WinEvent queue, frame diff, hit-zone clustering, redaction과 Discovery metadata를 synthetic data로 검증한다.
// 입력/출력: 실제 HTS나 global hook 없이 pointer/frame fixture를 interaction·zone suggestion으로 변환한다.
// 경계: mouse·keyboard injection, 실제 거래, screenshot 저장, ResultEvaluator와 TestResult를 호출하지 않는다.
// 수정 지점: PassiveInteractionContracts, observation/analysis와 PowerShell recorder 변경 시 함께 갱신한다.
using System.Text.Json;
using HtsQa.FlaUi;

namespace HtsQa.Tests.Automation;

public sealed class PassiveInteractionRecorderTests
{
    [Fact]
    public void ObservationQueue_Preserves_Mouse_Order_And_Separates_WinEvents()
    {
        var queue = new PassiveObservationQueue();
        queue.EnqueuePointer(Pointer(1, "Down", 100, 120));
        queue.EnqueuePointer(Pointer(2, "Up", 100, 120));
        queue.EnqueueWindowEvent(new() { Sequence = 3, EventName = "Selection", Hwnd = 12 });

        Assert.Equal(2, queue.PointerCount);
        Assert.True(queue.TryDequeuePointer(out var first));
        Assert.True(queue.TryDequeuePointer(out var second));
        Assert.Equal("Down", first!.Phase);
        Assert.Equal("Up", second!.Phase);
        Assert.True(queue.TryDequeueWindowEvent(out var selection));
        Assert.Equal("Selection", selection!.EventName);
    }

    [Fact]
    public void Hook_Recognizes_Only_F10_As_Stop_And_Records_No_Keyboard_String()
    {
        Assert.True(PassiveInputObserver.IsStopVirtualKey(0x79));
        Assert.False(PassiveInputObserver.IsStopVirtualKey('A'));
        Assert.False(PassiveInputObserver.IsInjectedMouseFlags(0));
        Assert.True(PassiveInputObserver.IsInjectedMouseFlags(0x00000001));
        Assert.True(PassiveInputObserver.IsInjectedMouseFlags(0x00000002));
        Assert.Equal("LeftDown", PassiveInputObserver.MouseMessageName(0x0201));
        Assert.Equal(string.Empty, PassiveInputObserver.MouseMessageName(0x0200));
        var json = JsonSerializer.Serialize(new BridgeRequest(), new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
        Assert.DoesNotContain("keyboardText", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("keystroke", json, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void FrameDiff_Correlates_Delayed_Popup_Focus_Selection_And_Visual_Change()
    {
        var pre = Frame("pre", [Window(10, 0, "AfxWnd140", 0, 0, 1000, 700)], focus: 10,
            visual: Visual("before", "a", "a", "a", "a"));
        var at100 = Frame("at100", pre.Windows, focus: 10, visual: Visual("same", "a", "a", "a", "a"));
        var popup = Window(20, 10, "ComboLBox", 600, 180, 840, 360, popup: true);
        var at300 = Frame("at300", [.. pre.Windows, popup], focus: 20, popups: [20], visual: Visual("popup", "a", "b", "a", "b"));
        var at750 = Frame("at300", [.. pre.Windows, popup], focus: 20, popups: [20], visual: Visual("popup", "a", "b", "a", "b"));
        var events = new[] { new PassiveWindowEventObservation { EventName = "Show", Hwnd = 20 }, new PassiveWindowEventObservation { EventName = "Selection", Hwnd = 20 } };

        var delta = PassiveInteractionAnalysis.CompareFrames(pre, [at100, at300, at750], events);

        Assert.Contains(20, delta.NewHwnds);
        Assert.Contains(20, delta.PopupCreatedHwnds);
        Assert.True(delta.FocusChanged);
        Assert.True(delta.SelectionEventObserved);
        Assert.False(delta.UnstablePostState);
        Assert.True(delta.VisualDiff.Available);
        Assert.Equal(2, delta.VisualDiff.ChangedBlockCount);
    }

    [Fact]
    public void Interaction_Is_Manual_Discovery_And_OwnerDrawn_Hit_Remains_A_Zone_Candidate()
    {
        var root = Window(10, 0, "AfxWnd140", 0, 0, 1000, 700);
        var ownerDrawn = Window(11, 10, "AfxWnd140", 400, 50, 900, 500);
        var pre = Frame("pre", [root, ownerDrawn], visual: Visual("before", "a", "a", "a", "a"));
        var post = Frame("post", [root, ownerDrawn], visual: Visual("after", "a", "a", "b", "a"));
        var down = Pointer(1, "Down", 550, 140);
        var up = Pointer(2, "Up", 550, 140);

        var interaction = PassiveInteractionAnalysis.CreateInteraction(1, down, up, pre, [post, post], [], null);

        Assert.True(interaction.UserPerformed);
        Assert.False(interaction.Automated);
        Assert.Equal("Discovery", interaction.ArtifactRole);
        Assert.Equal("ObservedManualInteraction", interaction.InteractionRole);
        Assert.False(interaction.TestExecution);
        Assert.False(interaction.VerdictEligible);
        Assert.False(interaction.ResultEvaluatorInvoked);
        Assert.Null(interaction.CanonicalVerdict);
        Assert.Equal(0, interaction.ActionSentCount);
        Assert.Equal(0, interaction.TransactionalActionCount);
        Assert.True(interaction.HitTarget.InsideTarget);
        Assert.Equal(11, interaction.HitTarget.PrimaryHwnd);
        Assert.InRange(interaction.HitTarget.NormalizedRootX, 0.54, 0.56);
        Assert.Equal("OrderEntryPanel", interaction.HitTarget.SpatialRegion);
        Assert.InRange(interaction.HitTarget.NormalizedRegionX, 0.09, 0.12);
        Assert.InRange(interaction.HitTarget.NormalizedRegionY, 0.15, 0.18);
        Assert.Equal(50, interaction.HitTarget.RegionRelativePoint.X);
        Assert.Equal(56, interaction.HitTarget.RegionRelativePoint.Y);
        Assert.False(interaction.Suggestion.TransactionalRiskCandidate);
    }

    [Fact]
    public void Clustering_Separates_Distant_Zones_Inside_The_Same_Afx_Hwnd()
    {
        var first = Interaction("one", 11, 10, 0.15, 0.10, "GlobalHeader", "order-tab:buy");
        var repeated = Interaction("two", 11, 10, 0.17, 0.11, "GlobalHeader", "order-tab:buy");
        var distant = Interaction("three", 11, 10, 0.72, 0.74, "GlobalHeader", "other-selectable-control");

        var zones = PassiveInteractionAnalysis.Cluster([first, repeated, distant], 0.05);

        Assert.Equal(2, zones.Count);
        Assert.Contains(zones, zone => zone.ObservationCount == 2);
        Assert.All(zones, zone =>
        {
            Assert.Equal("ReviewRequired", zone.Status);
            Assert.False(zone.AutomaticallyApproved);
            Assert.False(zone.Executable);
        });
    }

    [Fact]
    public void Outside_Target_And_Injected_Observations_Are_Not_Eligible_For_Zones()
    {
        var outside = Interaction("outside", 0, 0, 1.5, 1.5, "Unclassified", "other-selectable-control");
        outside.HitTarget.InsideTarget = false;
        var zones = PassiveInteractionAnalysis.Cluster([outside], 0.05);
        Assert.Empty(zones);
        Assert.True(Pointer(1, "Down", 0, 0, injected: true).Injected);
    }

    [Fact]
    public void Serialized_Artifacts_Contain_No_Raw_Text_Pixel_Or_TestResult_Status()
    {
        var interaction = Interaction("safe", 11, 10, 0.2, 0.3, "QuotePanel", "other-selectable-control");
        var json = JsonSerializer.Serialize(interaction, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
        Assert.DoesNotContain("fixture-password", json, StringComparison.Ordinal);
        Assert.DoesNotContain("rawText", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("observedValue", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("pixelData", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("PASS", json, StringComparison.Ordinal);
        Assert.Contains("\"verdictEligible\":false", json, StringComparison.Ordinal);
        Assert.Contains("\"resultEvaluatorInvoked\":false", json, StringComparison.Ordinal);
    }

    private static PassivePointerObservation Pointer(long sequence, string phase, int x, int y, bool injected = false) => new()
    {
        Sequence = sequence,
        ObservedAt = new DateTimeOffset(2026, 8, 25, 12, 0, 0, TimeSpan.Zero).AddMilliseconds(sequence * 100),
        Button = "Left",
        Phase = phase,
        X = x,
        Y = y,
        Injected = injected
    };

    private static NativeInteractionWindowSnapshot Window(long hwnd, long parent, string className,
        int left, int top, int right, int bottom, bool popup = false) => new()
    {
        Hwnd = hwnd,
        ParentHwnd = parent,
        RootHwnd = 10,
        ClassName = className,
        NativeSignature = $"signature-{hwnd}",
        IsVisible = true,
        IsEnabled = true,
        IsDescendant = !popup,
        IsOwnedPopup = popup,
        IsPopup = popup,
        Bounds = new() { Left = left, Top = top, Right = right, Bottom = bottom },
        NormalizedBounds = new() { Left = left / 1000.0, Top = top / 700.0, Right = right / 1000.0, Bottom = bottom / 700.0,
            CenterX = (left + right) / 2000.0, CenterY = (top + bottom) / 1400.0 },
        SpatialRegion = top < 100 ? "GlobalHeader" : top > 430 ? "TradeInfoPanel" : left < 500 ? "QuotePanel" : "OrderEntryPanel",
        AncestorHwnds = parent == 0 ? [] : [10]
    };

    private static NativeInteractionFrameSnapshot Frame(string fingerprint, IReadOnlyList<NativeInteractionWindowSnapshot> windows,
        long focus = 10, IReadOnlyList<long>? popups = null, PassiveVisualSignature? visual = null) => new()
    {
        RootHwnd = 10,
        ProcessId = 100,
        RootBounds = new() { Left = 0, Top = 0, Right = 1000, Bottom = 700 },
        RootClientBounds = new() { Left = 0, Top = 0, Right = 1000, Bottom = 700 },
        ForegroundHwnd = 10,
        FocusHwnd = focus,
        LayoutFingerprint = fingerprint,
        StateFingerprint = fingerprint,
        ObservedAt = new DateTimeOffset(2026, 8, 25, 12, 0, 1, TimeSpan.Zero),
        Windows = windows,
        PopupHwnds = popups ?? [],
        VisualSignature = visual ?? Visual(fingerprint, "a", "a", "a", "a")
    };

    private static PassiveVisualSignature Visual(string hash, params string[] blocks) => new()
    {
        Available = true,
        Columns = 2,
        Rows = 2,
        PerceptualHash = hash,
        BlockHashes = blocks,
        PixelDataStored = false
    };

    private static ObservedInteractionSnapshot Interaction(string id, long hwnd, long parent, double x, double y, string region, string role) => new()
    {
        InteractionId = id,
        HitTarget = new()
        {
            InsideTarget = true,
            PrimaryHwnd = hwnd,
            ParentHwnd = parent,
            NativeSignature = $"signature-{hwnd}",
            NormalizedParentX = x,
            NormalizedParentY = y,
            SpatialRegion = region
        },
        Suggestion = new() { InferredRole = role, InferredActionKind = "Select", Confidence = 0.6 }
    };
}
