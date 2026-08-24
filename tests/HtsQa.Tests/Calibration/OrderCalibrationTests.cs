// 역할: 캘리브레이션 반복 관측, read-only/redaction, review와 명시적 repository 등록 경계를 검증한다.
using System.Text.Json;
using HtsQa.Core;

namespace HtsQa.Tests.Calibration;

public sealed class OrderCalibrationTests
{
    [Fact]
    public void Single_Observation_Remains_ReviewRequired_And_Is_Not_Auto_Approved()
    {
        var session = Session(Observation("one"));
        var report = OrderCalibrationSessionAnalyzer.Analyze(session);

        Assert.True(report.IsValid);
        Assert.Equal(CalibrationSessionStatus.ReviewRequired, report.Status);
        Assert.Equal(1, report.ObservationCount);
        Assert.False(session.RepositoryApplied);
        Assert.Empty(session.CanonicalApprovalHash);
    }

    [Fact]
    public void Repeated_Identity_Bounds_Or_Anchor_Change_Is_Unstable()
    {
        var changed = Observation("two") with
        {
            ClientBounds = new() { Width = 801, Height = 600 },
            RedactedAnchorCandidates = ["different-redacted-anchor"]
        };

        var report = OrderCalibrationSessionAnalyzer.Analyze(Session(Observation("one"), changed));

        Assert.Equal(CalibrationSessionStatus.Unstable, report.Status);
        Assert.True(report.Drift.BoundsChanged);
        Assert.True(report.Drift.AnchorChanged);
    }

    [Fact]
    public void Capture_With_Input_Or_Pixel_Crop_Is_Rejected()
    {
        var unsafeObservation = Observation("unsafe") with { ClickSent = true, PixelCropStored = true };
        var report = OrderCalibrationSessionAnalyzer.Analyze(Session(unsafeObservation, unsafeObservation with { ObservationId = "unsafe-2" }));

        Assert.Contains(report.Issues, x => x.Code == "CALIBRATION.READ_ONLY_REQUIRED");
        Assert.Contains(report.Issues, x => x.Code == "CALIBRATION.SENSITIVE_ARTIFACT");
        Assert.False(report.IsValid);
    }

    [Fact]
    public void Stable_Repeated_Session_Creates_ReviewRequired_Payload_Only()
    {
        var entry = OrderCalibrationReviewFactory.Create(
            Session(Observation("one"), Observation("two")),
            "FIXTURE_CONTROL", "redacted-anchor", ControlRiskClass.LimitedNonTransactional,
            [ControlRepositoryAction.Input],
            [ControlRepositoryAction.FinalSubmit, ControlRepositoryAction.AmendSubmit, ControlRepositoryAction.CancelSubmit],
            "fixture:operator-review", ["fixture:observation-1", "fixture:observation-2"], At);

        Assert.Equal(ControlRepositoryEntryStatus.ReviewRequired, entry.Status);
        Assert.Equal(TestPackApprovalStatus.PendingApproval, entry.Approval.Status);
        Assert.Empty(entry.ApprovalPayloadHash);
        Assert.Equal("redacted-anchor", entry.AnchoredRelativeCoordinate!.AnchorId);
    }

    [Fact]
    public void Unstable_Session_Cannot_Create_Review_Payload()
    {
        var changed = Observation("two") with { DpiScale = 1.25 };
        Assert.Throws<InvalidDataException>(() => OrderCalibrationReviewFactory.Create(
            Session(Observation("one"), changed), "FIXTURE_CONTROL", "redacted-anchor", ControlRiskClass.General,
            [ControlRepositoryAction.Assert], [], "fixture:review", ["fixture:evidence"], At));
    }

    [Fact]
    public void Approved_Entry_Registers_Without_Overwriting_And_Duplicate_Is_Blocked()
    {
        var approved = ApprovedStableEntry();
        var empty = new ControlRepositoryDocument
        {
            RepositoryId = "fixture-repository", TargetProfileId = "fixture-target",
            Status = ControlRepositoryStatus.ConfigurationRequired
        };

        var registered = ControlRepositoryRegistration.Register(empty, approved);

        Assert.Equal(ControlRepositoryStatus.Ready, registered.Status);
        Assert.Single(registered.Entries);
        Assert.Throws<InvalidDataException>(() => ControlRepositoryRegistration.Register(registered, approved));
    }

    [Fact]
    public void Registered_Approved_Entry_Finalizes_Session_With_Canonical_Hash()
    {
        var entry = ApprovedStableEntry();
        var repository = new ControlRepositoryDocument
        {
            RepositoryId = "fixture-repository", TargetProfileId = "fixture-target", Status = ControlRepositoryStatus.Ready, Entries = [entry]
        };
        var applied = OrderCalibrationSessionLifecycle.MarkApplied(Session(Observation("one"), Observation("two")), repository, "FIXTURE_CONTROL");

        Assert.Equal(CalibrationSessionStatus.Applied, applied.Status);
        Assert.True(applied.RepositoryApplied);
        Assert.Equal(entry.ApprovalPayloadHash, applied.CanonicalApprovalHash);
        Assert.True(OrderCalibrationSessionAnalyzer.Analyze(applied).IsValid);
    }

    [Fact]
    public void Capture_Context_Cannot_Be_Relabeled_Or_Reused_As_Repeated_Observation()
    {
        var capture = Capture("one", At);
        Assert.Throws<InvalidDataException>(() => OrderCalibrationSessionFactory.Create(
            "fixture-session", "fixture-target", "fixture-repository", "F001", "OTHER-MAP", "state:a", [capture]));
        Assert.Throws<InvalidDataException>(() => OrderCalibrationSessionFactory.Create(
            "fixture-session", "fixture-target", "fixture-repository", "F001", "FAKE-MAP", "state:other", [capture]));
        Assert.Throws<InvalidDataException>(() => OrderCalibrationSessionFactory.Create(
            "fixture-session", "fixture-target", "fixture-repository", "F001", "FAKE-MAP", "state:a", [capture, capture]));
    }

    [Fact]
    public void Review_Requires_Human_Reviewer_And_Finalization_Requires_Exact_Repository_Identity()
    {
        var session = Session(Observation("one"), Observation("two"));
        Assert.Throws<InvalidDataException>(() => OrderCalibrationReviewFactory.Create(session with { Reviewer = "" },
            "FIXTURE_CONTROL", "redacted-anchor", ControlRiskClass.General, [ControlRepositoryAction.Assert], [],
            "fixture:review", ["fixture:evidence"], At));
        var wrongRepository = new ControlRepositoryDocument
        {
            RepositoryId = "other", TargetProfileId = "fixture-target", Status = ControlRepositoryStatus.Ready, Entries = [ApprovedStableEntry()]
        };
        Assert.Throws<InvalidDataException>(() => OrderCalibrationSessionLifecycle.MarkApplied(session, wrongRepository, "FIXTURE_CONTROL"));
    }

    [Fact]
    public void Calibration_Schema_RoundTrips_Without_Sensitive_Value_Or_Crop_Field()
    {
        var json = JsonSerializer.Serialize(Session(Observation("one"), Observation("two")), JsonDefaults.Options);
        var roundTrip = JsonSerializer.Deserialize<OrderCalibrationSession>(json, JsonDefaults.Options);

        Assert.NotNull(roundTrip);
        Assert.Equal(2, roundTrip!.Observations.Length);
        Assert.DoesNotContain("password", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("accountNumber", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("pixelCropData", json, StringComparison.OrdinalIgnoreCase);
    }

    private static readonly DateTimeOffset At = DateTimeOffset.Parse("2026-08-24T09:00:00+09:00");

    private static OrderCalibrationSession Session(params CalibrationObservation[] observations) => new()
    {
        SessionId = "fixture-session",
        TargetProfileId = "fixture-target",
        RepositoryId = "fixture-repository",
        Screen = "F001",
        Map = "FAKE-MAP",
        StateContext = "state:a",
        CapturedAt = At,
        Reviewer = "fixture-reviewer",
        Status = CalibrationSessionStatus.ReviewRequired,
        Observations = observations
    };

    private static CalibrationObservation Observation(string id) => new()
    {
        ObservationId = id,
        CapturedAt = id == "one" ? At : At.AddSeconds(1),
        Screen = "F001",
        Map = "FAKE-MAP",
        StateContext = "state:a",
        HostFingerprint = Host(),
        WindowBounds = new() { Width = 1000, Height = 700 },
        ClientBounds = new() { Width = 800, Height = 600 },
        DpiScale = 1.0,
        LocatorTier = LocatorTrustTier.Unresolved,
        AnchoredRelativeCoordinate = new() { RelativeX = 0.25, RelativeY = 0.5 },
        ExpectedControlKind = "Edit",
        VisualSignature = new() { Algorithm = "fixture", SignatureHash = "redacted-signature" },
        RedactedAnchorCandidates = ["redacted-anchor"],
        SensitiveDataRedacted = true,
        EvidenceRefs = ["fixture:read-only"]
    };

    private static ControlCaptureCandidate Capture(string id, DateTimeOffset capturedAt) => new()
    {
        CapturedAt = capturedAt,
        ProcessName = "fixture-process",
        ProcessFingerprint = "fixture-process-hash",
        HostFingerprint = "fixture-host-hash",
        StateContext = "state:a",
        MapScreenCode = "FAKE-MAP",
        WindowWidth = 1000,
        WindowHeight = 700,
        ClientWidth = 800,
        ClientHeight = 600,
        DpiScale = 1.0,
        RelativeX = 0.25,
        RelativeY = 0.5,
        RedactedIdentityCandidates = ["redacted-" + id],
        ExpectedControlKindCandidate = "Edit",
        VisualSignatureHash = "redacted-signature-" + id,
        RedactionsApplied = ["values omitted"]
    };

    private static ControlHostFingerprint Host() => new()
    {
        ProcessName = "fixture-process", ProcessFingerprint = "fixture-process-hash", HostFingerprint = "fixture-host-hash",
        CapturedWindowWidth = 1000, CapturedWindowHeight = 700, CapturedClientWidth = 800, CapturedClientHeight = 600, CapturedDpiScale = 1.0
    };

    private static ControlRepositoryEntry ApprovedStableEntry()
    {
        var entry = new ControlRepositoryEntry
        {
            Key = new() { Screen = "F001", Map = "FAKE-MAP", LogicalName = "FIXTURE_CONTROL", StateContext = "state:a" },
            Status = ControlRepositoryEntryStatus.Approved,
            StableIdentity = new() { AutomationId = "fixture-control" },
            HostFingerprint = Host(),
            ExpectedControlKind = "Edit",
            RiskClass = ControlRiskClass.General,
            AllowedActions = [ControlRepositoryAction.Input, ControlRepositoryAction.Assert, ControlRepositoryAction.Select],
            ForbiddenActions = [ControlRepositoryAction.FinalSubmit, ControlRepositoryAction.AmendSubmit, ControlRepositoryAction.CancelSubmit],
            CreatedAt = At,
            ReviewedAt = At,
            Source = "fixture:review",
            EvidenceRefs = ["fixture:evidence"]
        };
        var hash = ControlRepositoryApprovalPayload.ComputeHash(entry);
        return entry with
        {
            ApprovalPayloadHash = hash,
            Approval = new()
            {
                Status = TestPackApprovalStatus.Approved,
                ApprovedBy = "fixture-reviewer",
                ApprovedAt = At,
                EvidenceRefs = ["fixture:approval"],
                ApprovedContentHash = hash
            }
        };
    }
}
