// 역할: Control Repository의 승인, locator 우선순위, 실행 직전 fail-closed 정책과 JSON 호환성을 검증한다.
// 범위: 순수 Core fake 증거만 사용하며 실제 UI 또는 물리 action을 실행하지 않는다.
using System.Text.Json;
using HtsQa.Core;

namespace HtsQa.Tests;

public sealed class ControlRepositoryTests
{
    [Fact]
    public void Stable_Identity_Has_Priority_Over_Approved_Coordinate()
    {
        var entry = ApprovedCoordinateEntry() with { StableIdentity = new() { AutomationId = "fake-uia" } };
        entry = Approve(entry);

        var result = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry) with
        {
            StableIdentityMatched = true,
            CoordinateTransform = InvalidTransform()
        });

        Assert.Equal(ControlRepositoryResolutionStatus.Resolved, result.Status);
        Assert.Equal(LocatorTrustTier.StableIdentity, result.TrustTier);
        Assert.Null(result.ResolvedScreenPoint);
        Assert.False(result.ActionSent);
        Assert.True(result.PhysicalAction);
    }

    [Fact]
    public void Map_Runtime_Has_Priority_Over_Approved_Coordinate()
    {
        var entry = ApprovedCoordinateEntry() with
        {
            MapRuntimeBinding = new() { MapScreenCode = "FAKE-MAP", RuntimeBindingId = "fixture-runtime" }
        };
        entry = Approve(entry);

        var result = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry) with
        {
            MapRuntimeBindingMatched = true,
            CoordinateTransform = InvalidTransform()
        });

        Assert.Equal(ControlRepositoryResolutionStatus.Resolved, result.Status);
        Assert.Equal(LocatorTrustTier.MapRuntimeBinding, result.TrustTier);
        Assert.False(result.ActionSent);
    }

    [Theory]
    [InlineData(ControlRepositoryEntryStatus.ConfigurationRequired)]
    [InlineData(ControlRepositoryEntryStatus.Draft)]
    [InlineData(ControlRepositoryEntryStatus.ReviewRequired)]
    [InlineData(ControlRepositoryEntryStatus.Unresolved)]
    [InlineData(ControlRepositoryEntryStatus.Rejected)]
    public void Non_Approved_Entry_Is_Blocked(ControlRepositoryEntryStatus status)
    {
        var entry = ApprovedCoordinateEntry() with { Status = status };

        var result = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry));

        Assert.Equal(ControlRepositoryResolutionStatus.Blocked, result.Status);
        Assert.Equal("ENTRY_NOT_APPROVED", result.ReasonCode);
        Assert.False(result.ActionSent);
    }

    [Fact]
    public void Approval_Hash_Mismatch_Is_Blocked()
    {
        var entry = Approve(ApprovedCoordinateEntry()) with { ApprovalPayloadHash = new string('0', 64) };

        var result = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry));

        Assert.Equal(ControlRepositoryResolutionStatus.Blocked, result.Status);
        Assert.Equal("REPOSITORY_INVALID", result.ReasonCode);
        Assert.False(result.ActionSent);
    }

    [Theory]
    [InlineData("other-process", "fixture-process", "fixture-host", "state:fake", "Process ownership")]
    [InlineData("fake-process", "fixture-process", "stale-host", "state:fake", "host fingerprint")]
    [InlineData("fake-process", "fixture-process", "fixture-host", "state:other", "stateContext")]
    public void Wrong_Process_State_Or_Host_Is_Blocked(string process, string processFingerprint, string hostFingerprint,
        string stateContext, string expectedReason)
    {
        var entry = Approve(ApprovedCoordinateEntry());

        var result = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry) with
        {
            ProcessName = process,
            ProcessFingerprint = processFingerprint,
            HostFingerprint = hostFingerprint,
            ActiveStateContext = stateContext
        });

        Assert.Equal(ControlRepositoryResolutionStatus.Blocked, result.Status);
        Assert.Equal("CONTEXT_MISMATCH", result.ReasonCode);
        Assert.Contains(expectedReason, result.Reason, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Valid_Approved_Coordinate_Resolves_For_Fake_Client_Without_Sending_Action()
    {
        var entry = Approve(ApprovedCoordinateEntry());

        var result = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry));

        Assert.Equal(ControlRepositoryResolutionStatus.Resolved, result.Status);
        Assert.Equal(LocatorTrustTier.ApprovedAnchoredRelative, result.TrustTier);
        Assert.Equal(new ControlRepositoryPoint(150, 250), result.ResolvedScreenPoint);
        Assert.Contains("approved coordinate fallback", result.FallbackReason, StringComparison.OrdinalIgnoreCase);
        Assert.False(result.ActionSent);
    }

    [Theory]
    [InlineData("wrong-anchor", "Edit", true, false, "ANCHOR_MISMATCH")]
    [InlineData("fixture-anchor", "Button", true, false, "CONTROL_KIND_MISMATCH")]
    [InlineData("fixture-anchor", "Edit", false, false, "VISUAL_SIGNATURE_MISMATCH")]
    [InlineData("fixture-anchor", "Edit", true, true, "FORBIDDEN_CONTROL_COLLISION")]
    public void Execution_Time_Guard_Mismatch_Is_Blocked(string anchor, string kind, bool visualMatched,
        bool forbiddenCollision, string expectedCode)
    {
        var entry = Approve(ApprovedCoordinateEntry());

        var result = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry) with
        {
            ObservedAnchorIds = [anchor],
            ObservedControlKind = kind,
            VisualSignatureMatched = visualMatched,
            ForbiddenControlCollision = forbiddenCollision
        });

        Assert.Equal(ControlRepositoryResolutionStatus.Blocked, result.Status);
        Assert.Equal(expectedCode, result.ReasonCode);
        Assert.False(result.ActionSent);
    }

    [Fact]
    public void Out_Of_Bounds_Transform_Is_Blocked()
    {
        var entry = Approve(ApprovedCoordinateEntry());
        var transform = ValidTransform() with
        {
            InsideClientBounds = false,
            ScreenPoint = new(301, 401),
            FailureReason = "Point is outside the client bounds."
        };

        var result = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry) with { CoordinateTransform = transform });

        Assert.Equal(ControlRepositoryResolutionStatus.Blocked, result.Status);
        Assert.Equal("COORDINATE_TRANSFORM_INVALID", result.ReasonCode);
    }

    [Theory]
    [InlineData(ControlRepositoryAction.FinalSubmit)]
    [InlineData(ControlRepositoryAction.AmendSubmit)]
    [InlineData(ControlRepositoryAction.CancelSubmit)]
    public void Transactional_Submit_Cannot_Use_Relative_Coordinate(ControlRepositoryAction action)
    {
        var entry = ApprovedCoordinateEntry() with { AllowedActions = [action], ForbiddenActions = [] };
        entry = Approve(entry);

        var result = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry) with
        {
            Action = action,
            TransactionalPolicyApproved = true
        });

        Assert.Equal(ControlRepositoryResolutionStatus.Blocked, result.Status);
        Assert.Equal("COORDINATE_TRANSACTION_FORBIDDEN", result.ReasonCode);
        Assert.False(result.ActionSent);
    }

    [Fact]
    public void Image_Only_Locator_Cannot_Perform_Physical_Action()
    {
        var entry = Approve(new ControlRepositoryEntry
        {
            Key = Key(),
            Status = ControlRepositoryEntryStatus.Approved,
            VisualSignature = new() { Algorithm = "fixture-hash", SignatureHash = "redacted-signature", MinimumSimilarity = 1 },
            HostFingerprint = HostEvidence(),
            RiskClass = ControlRiskClass.ObservationOnly,
            AllowedActions = [ControlRepositoryAction.Assert, ControlRepositoryAction.Click],
            Source = "fixture:visual",
            EvidenceRefs = ["fixture:redacted"]
        });

        var physical = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry) with
        {
            Action = ControlRepositoryAction.Click,
            PhysicalAction = true
        });
        var observation = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry) with
        {
            Action = ControlRepositoryAction.Assert,
            PhysicalAction = false
        });

        Assert.Equal("VISUAL_PHYSICAL_ACTION_FORBIDDEN", physical.ReasonCode);
        Assert.Equal(ControlRepositoryResolutionStatus.Resolved, observation.Status);
        Assert.Equal(LocatorTrustTier.VisualObservationOnly, observation.TrustTier);
    }
    [Fact]
    public void Observation_Only_Risk_Cannot_Be_Used_For_Input()
    {
        var entry = ApprovedCoordinateEntry() with { RiskClass = ControlRiskClass.ObservationOnly };
        entry = Approve(entry);

        var result = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry));

        Assert.Equal(ControlRepositoryResolutionStatus.Blocked, result.Status);
        Assert.Equal("RISK_POLICY_BLOCKED", result.ReasonCode);
    }

    [Fact]
    public void Coordinate_Physical_Action_Requires_Limited_NonTransactional_Risk()
    {
        var entry = ApprovedCoordinateEntry() with { RiskClass = ControlRiskClass.General };
        entry = Approve(entry);

        var result = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry));

        Assert.Equal(ControlRepositoryResolutionStatus.Blocked, result.Status);
        Assert.Equal("COORDINATE_RISK_CLASS_BLOCKED", result.ReasonCode);
    }

    [Fact]
    public void Opening_Confirmation_Requires_Separate_Policy_Approval()
    {
        var entry = ApprovedCoordinateEntry() with { AllowedActions = [ControlRepositoryAction.OpenConfirmation] };
        entry = Approve(entry);

        var result = ControlRepositoryResolver.Resolve(Repository(entry), Request(entry) with { Action = ControlRepositoryAction.OpenConfirmation });

        Assert.Equal(ControlRepositoryResolutionStatus.Blocked, result.Status);
        Assert.Equal("CONFIRMATION_POLICY_REQUIRED", result.ReasonCode);
    }


    [Fact]
    public void Duplicate_Logical_Key_Is_Explicitly_Rejected()
    {
        var entry = Approve(ApprovedCoordinateEntry());
        var repository = Repository(entry) with { Entries = [entry, entry with { Source = "fixture:duplicate" }] };

        var issues = ControlRepositoryValidator.Validate(repository);
        var result = ControlRepositoryResolver.Resolve(repository, Request(entry));

        Assert.Contains(issues, x => x.Code == "CONTROL_REPOSITORY.DUPLICATE_KEY");
        Assert.Equal("REPOSITORY_INVALID", result.ReasonCode);
    }

    [Fact]
    public void Discovery_Suggestion_Does_Not_Modify_Or_Approve_Repository()
    {
        var repository = Repository(ApprovedCoordinateEntry() with { Status = ControlRepositoryEntryStatus.ReviewRequired });

        var suggestion = ControlRepositoryResolver.CreateReviewSuggestion(Key(), ControlRepositoryAction.Observe,
            "new nearby identity", ["fixture:discovery"]);

        Assert.Equal(ControlRepositoryResolutionStatus.ReviewSuggestion, suggestion.Status);
        Assert.Equal(TestPackApprovalStatus.PendingApproval, suggestion.ApprovalStatus);
        Assert.False(suggestion.ActionSent);
        Assert.Equal(ControlRepositoryEntryStatus.ReviewRequired, repository.Entries[0].Status);
    }

    [Fact]
    public void Approval_Template_Remains_Pending_Until_Human_Overlay_Is_Applied()
    {
        var review = ApprovedCoordinateEntry() with
        {
            Status = ControlRepositoryEntryStatus.ReviewRequired,
            ReviewedAt = null
        };

        var template = ControlRepositoryApprovalWorkflow.CreateTemplate(review);

        Assert.Equal(TestPackApprovalStatus.PendingApproval, template.Status);
        Assert.Equal(ControlRepositoryApprovalPayload.ComputeHash(review), template.TestPackContentHash);
        Assert.Null(template.ApprovedBy);
    }

    [Fact]
    public void Explicit_Human_Approval_Uses_Existing_Overlay_And_Binds_Canonical_Hash()
    {
        var review = ApprovedCoordinateEntry() with
        {
            Status = ControlRepositoryEntryStatus.ReviewRequired,
            ReviewedAt = null
        };
        var template = ControlRepositoryApprovalWorkflow.CreateTemplate(review);
        var approvedAt = DateTimeOffset.Parse("2026-08-24T03:00:00+09:00");
        var result = ControlRepositoryApprovalWorkflow.Apply(review, template with
        {
            Status = TestPackApprovalStatus.Approved,
            ApprovedBy = "fixture-human-reviewer",
            ApprovedAt = approvedAt,
            EvidenceRefs = ["fixture:explicit-human-decision"]
        });

        Assert.Equal(ControlRepositoryEntryStatus.Approved, result.Status);
        Assert.Equal("fixture-human-reviewer", result.Approval.ApprovedBy);
        Assert.Equal(approvedAt, result.ReviewedAt);
        Assert.Equal(result.ApprovalPayloadHash, result.Approval.ApprovedContentHash);
        Assert.Empty(ControlRepositoryValidator.Validate(Repository(result)));
    }

    [Fact]
    public void Human_Approval_Hash_Mismatch_Is_Rejected()
    {
        var review = ApprovedCoordinateEntry() with { Status = ControlRepositoryEntryStatus.ReviewRequired, ReviewedAt = null };
        var template = ControlRepositoryApprovalWorkflow.CreateTemplate(review) with { TestPackContentHash = new string('0', 64) };

        Assert.Throws<InvalidDataException>(() => ControlRepositoryApprovalWorkflow.Apply(review, template));
    }

    [Fact]
    public void Schema_Round_Trips_And_Legacy_Json_Remains_Readable()
    {
        var entry = Approve(ApprovedCoordinateEntry());
        var json = JsonSerializer.Serialize(Repository(entry), JsonDefaults.Options);
        var roundTrip = JsonSerializer.Deserialize<ControlRepositoryDocument>(json, JsonDefaults.Options);
        var legacy = JsonSerializer.Deserialize<ControlRepositoryDocument>(
            "{\"schemaVersion\":\"1.0\",\"repositoryId\":\"legacy\",\"targetProfileId\":\"fake\",\"entries\":[]}", JsonDefaults.Options);

        Assert.Equal(entry.Key.Canonical, Assert.Single(roundTrip!.Entries).Key.Canonical);
        Assert.Equal(ControlRepositoryStatus.ConfigurationRequired, legacy!.Status);
        Assert.Empty(legacy.Entries);
    }

    private static ControlRepositoryKey Key() => new()
    {
        Screen = "F001",
        Map = "FAKE-MAP",
        LogicalName = "FAKE_CONTROL",
        StateContext = "state:fake"
    };

    private static ControlRepositoryEntry ApprovedCoordinateEntry() => new()
    {
        Key = Key(),
        Status = ControlRepositoryEntryStatus.Approved,
        AnchoredRelativeCoordinate = new()
        {
            CoordinateSpace = ControlRepositoryCoordinateSpace.MapHostClient,
            RelativeX = 0.25,
            RelativeY = 0.5,
            RelativeWidth = 0.1,
            RelativeHeight = 0.1,
            AnchorId = "fixture-anchor"
        },
        HostFingerprint = HostEvidence(),
        ExpectedControlKind = "Edit",
        VisualSignature = new() { Algorithm = "fixture-hash", SignatureHash = "redacted-signature", MinimumSimilarity = 1.0 },
        RiskClass = ControlRiskClass.LimitedNonTransactional,
        AllowedActions = [ControlRepositoryAction.Input],
        ForbiddenActions = [ControlRepositoryAction.FinalSubmit, ControlRepositoryAction.AmendSubmit, ControlRepositoryAction.CancelSubmit],
        CreatedAt = DateTimeOffset.Parse("2026-08-24T00:00:00+09:00"),
        ReviewedAt = DateTimeOffset.Parse("2026-08-24T00:01:00+09:00"),
        Source = "fixture:human-review",
        EvidenceRefs = ["fixture:redacted-capture"]
    };

    private static ControlRepositoryEntry Approve(ControlRepositoryEntry entry)
    {
        var hash = ControlRepositoryApprovalPayload.ComputeHash(entry);
        return entry with
        {
            ApprovalPayloadHash = hash,
            Approval = new()
            {
                Status = TestPackApprovalStatus.Approved,
                ApprovedBy = "fixture-reviewer",
                ApprovedAt = DateTimeOffset.Parse("2026-08-24T00:02:00+09:00"),
                EvidenceRefs = ["fixture:approval"],
                ApprovedContentHash = hash
            }
        };
    }

    private static ControlRepositoryDocument Repository(ControlRepositoryEntry entry) => new()
    {
        RepositoryId = "fake-control-repository",
        TargetProfileId = "fake-target",
        Status = ControlRepositoryStatus.Ready,
        Entries = [entry]
    };

    private static ControlRepositoryResolutionRequest Request(ControlRepositoryEntry entry) => new()
    {
        Key = entry.Key,
        Action = ControlRepositoryAction.Input,
        PhysicalAction = true,
        ActiveScreen = "F001",
        ActiveMap = "FAKE-MAP",
        ActiveStateContext = "state:fake",
        ProcessName = "fake-process",
        ProcessFingerprint = "fixture-process",
        HostFingerprint = "fixture-host",
        AnchorId = "fixture-anchor",
        ObservedAnchorIds = ["fixture-anchor"],
        ObservedControlKind = "Edit",
        VisualSignatureMatched = true,
        CoordinateTransform = ValidTransform()
    };

    private static ControlCoordinateTransformEvidence ValidTransform() => new()
    {
        IsValid = true,
        DpiTransformValid = true,
        InsideClientBounds = true,
        DpiScale = 1.0,
        CurrentClientRect = new(100, 100, 200, 300),
        ScreenPoint = new(150, 250)
    };

    private static ControlCoordinateTransformEvidence InvalidTransform() => new()
    {
        IsValid = false,
        DpiTransformValid = false,
        InsideClientBounds = false,
        FailureReason = "fixture invalid"
    };
    private static ControlHostFingerprint HostEvidence() => new()
    {
        ProcessName = "fake-process",
        ProcessFingerprint = "fixture-process",
        CapturedWindowWidth = 240,
        CapturedWindowHeight = 240,
        HostFingerprint = "fixture-host",
        CapturedClientWidth = 200,
        CapturedClientHeight = 200,
        CapturedDpiScale = 1.0
    };

}
