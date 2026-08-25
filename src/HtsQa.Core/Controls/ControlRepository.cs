// 역할: 시나리오와 분리된 논리 컨트롤 저장소, 승인 해시, locator 신뢰도 및 실행 직전 fail-closed 판정을 정의한다.
// 경계: UI 관측/좌표 변환/물리 동작은 수행하지 않으며 TargetAdapter와 FlaUI가 제공한 증거만 평가한다.
namespace HtsQa.Core;

public enum ControlRepositoryStatus
{
    ConfigurationRequired,
    Ready
}

public enum ControlRepositoryEntryStatus
{
    ConfigurationRequired,
    Draft,
    ReviewRequired,
    Approved,
    Rejected,
    Unresolved
}

public enum LocatorTrustTier
{
    Unresolved,
    StableIdentity,
    MapRuntimeBinding,
    ApprovedAnchoredRelative,
    VisualObservationOnly
}

public enum ControlRiskClass
{
    ObservationOnly,
    General,
    LimitedNonTransactional,
    Transactional
}

public enum ControlRepositoryAction
{
    Observe,
    Assert,
    Focus,
    Input,
    Select,
    Toggle,
    Click,
    DoubleClick,
    Query,
    OpenConfirmation,
    FinalSubmit,
    AmendSubmit,
    CancelSubmit
}

public enum ControlRepositoryResolutionStatus
{
    Resolved,
    Blocked,
    ReviewSuggestion,
    Unresolved
}

public enum ControlRepositoryCoordinateSpace
{
    MapHostClient,
    ScreenClient
}

public sealed record ControlRepositoryKey
{
    public required string Screen { get; init; }
    public string Map { get; init; } = "";
    public required string LogicalName { get; init; }
    public string StateContext { get; init; } = "";

    public string Canonical => CreateCanonical(Screen, Map, LogicalName, StateContext);

    public static string CreateCanonical(string? screen, string? map, string? logicalName, string? stateContext) =>
        string.Join("|", Normalize(screen), Normalize(map), Normalize(logicalName), Normalize(stateContext));

    private static string Normalize(string? value) =>
        string.IsNullOrWhiteSpace(value) ? "*" : value.Trim().ToUpperInvariant();
}

public sealed record ControlStableIdentity
{
    public string AutomationId { get; init; } = "";
    public string NativeClass { get; init; } = "";
    public string NativeControlId { get; init; } = "";
    public string NativeIdentityHash { get; init; } = "";

    public bool IsConfigured =>
        !string.IsNullOrWhiteSpace(AutomationId) ||
        !string.IsNullOrWhiteSpace(NativeControlId) ||
        !string.IsNullOrWhiteSpace(NativeIdentityHash);
}

public sealed record ControlMapRuntimeBinding
{
    public string MapScreenCode { get; init; } = "";
    public string RuntimeBindingId { get; init; } = "";
    public bool IsConfigured =>
        !string.IsNullOrWhiteSpace(MapScreenCode) && !string.IsNullOrWhiteSpace(RuntimeBindingId);
}

public sealed record ControlHostFingerprint
{
    public string ProcessName { get; init; } = "";
    public string ProcessFingerprint { get; init; } = "";
    public string HostFingerprint { get; init; } = "";
    public int CapturedWindowWidth { get; init; }
    public int CapturedWindowHeight { get; init; }
    public int CapturedClientWidth { get; init; }
    public int CapturedClientHeight { get; init; }
    public double CapturedDpiScale { get; init; } = 1.0;
}

public sealed record AnchoredRelativeCoordinate
{
    public ControlRepositoryCoordinateSpace CoordinateSpace { get; init; } = ControlRepositoryCoordinateSpace.MapHostClient;
    public double RelativeX { get; init; }
    public double RelativeY { get; init; }
    public double RelativeWidth { get; init; }
    public double RelativeHeight { get; init; }
    public string AnchorId { get; init; } = "";

    public bool IsConfigured =>
        !string.IsNullOrWhiteSpace(AnchorId) || RelativeX != 0 || RelativeY != 0 || RelativeWidth != 0 || RelativeHeight != 0;
}

public sealed record ControlVisualSignature
{
    public string Algorithm { get; init; } = "";
    public string SignatureHash { get; init; } = "";
    public double MinimumSimilarity { get; init; } = 1.0;

    public bool IsConfigured => !string.IsNullOrWhiteSpace(Algorithm) && !string.IsNullOrWhiteSpace(SignatureHash);
}

public sealed record ControlRepositoryEntry
{
    public required ControlRepositoryKey Key { get; init; }
    public string TargetProfileId { get; init; } = "";
    public string BusinessRole { get; init; } = "";
    public ControlTransactionalRole TransactionalRole { get; init; }
    public ControlRepositoryEntryStatus Status { get; init; } = ControlRepositoryEntryStatus.ConfigurationRequired;
    public ControlStableIdentity? StableIdentity { get; init; }
    public ControlMapRuntimeBinding? MapRuntimeBinding { get; init; }
    public AnchoredRelativeCoordinate? AnchoredRelativeCoordinate { get; init; }
    public ControlHostFingerprint? HostFingerprint { get; init; }
    public string ExpectedControlKind { get; init; } = "";
    public ControlVisualSignature? VisualSignature { get; init; }
    public ControlRiskClass RiskClass { get; init; } = ControlRiskClass.ObservationOnly;
    public ControlRepositoryAction[] AllowedActions { get; init; } = [];
    public ControlRepositoryAction[] ForbiddenActions { get; init; } = [];
    public TestPackApprovalInfo Approval { get; init; } = new();
    public string ApprovalPayloadHash { get; init; } = "";
    public string ControlContractHash { get; init; } = "";
    public DateTimeOffset CreatedAt { get; init; }
    public DateTimeOffset? ReviewedAt { get; init; }
    public string Source { get; init; } = "";
    public string[] EvidenceRefs { get; init; } = [];
}

public sealed record ControlRepositoryDocument
{
    public string SchemaVersion { get; init; } = ControlRepositoryVersions.Schema;
    public required string RepositoryId { get; init; }
    public required string TargetProfileId { get; init; }
    public ControlRepositoryStatus Status { get; init; } = ControlRepositoryStatus.ConfigurationRequired;
    public ControlRepositoryEntry[] Entries { get; init; } = [];
}

public static class ControlRepositoryVersions
{
    public const string Schema = "1.0";
    public const string ResolutionSchema = "1.0";
    public const string CaptureSchema = "1.0";
}

public sealed record ControlRepositoryApprovalPayload
{
    public required ControlRepositoryKey Key { get; init; }
    public ControlStableIdentity? StableIdentity { get; init; }
    public ControlMapRuntimeBinding? MapRuntimeBinding { get; init; }
    public AnchoredRelativeCoordinate? AnchoredRelativeCoordinate { get; init; }
    public ControlHostFingerprint? HostFingerprint { get; init; }
    public string ExpectedControlKind { get; init; } = "";
    public ControlVisualSignature? VisualSignature { get; init; }
    public ControlRiskClass RiskClass { get; init; }
    public ControlRepositoryAction[] AllowedActions { get; init; } = [];
    public ControlRepositoryAction[] ForbiddenActions { get; init; } = [];
    public string Source { get; init; } = "";
    public string[] EvidenceRefs { get; init; } = [];

    public static ControlRepositoryApprovalPayload From(ControlRepositoryEntry entry) => new()
    {
        Key = entry.Key,
        StableIdentity = entry.StableIdentity,
        MapRuntimeBinding = entry.MapRuntimeBinding,
        AnchoredRelativeCoordinate = entry.AnchoredRelativeCoordinate,
        HostFingerprint = entry.HostFingerprint,
        ExpectedControlKind = entry.ExpectedControlKind,
        VisualSignature = entry.VisualSignature,
        RiskClass = entry.RiskClass,
        AllowedActions = entry.AllowedActions.Order().ToArray(),
        ForbiddenActions = entry.ForbiddenActions.Order().ToArray(),
        Source = entry.Source,
        EvidenceRefs = entry.EvidenceRefs.Order(StringComparer.Ordinal).ToArray()
    };

    public static string ComputeHash(ControlRepositoryEntry entry) => CanonicalJson.Sha256(From(entry));
}

/// <summary>기존 TestPack approval overlay를 사람이 편집한 뒤 repository entry에 적용한다.</summary>
public static class ControlRepositoryApprovalWorkflow
{
    public static TestPackApprovalOverlay CreateTemplate(ControlRepositoryEntry review)
    {
        RequireReview(review);
        return new()
        {
            TestPackContentHash = ControlContractHasher.ComputeApprovalHash(review),
            Status = TestPackApprovalStatus.PendingApproval
        };
    }

    public static ControlRepositoryEntry Apply(ControlRepositoryEntry review, TestPackApprovalOverlay overlay)
    {
        RequireReview(review);
        if (overlay.SchemaVersion != TestPackVersions.ApprovalSchema)
            throw new InvalidDataException($"Unsupported approval schemaVersion: {overlay.SchemaVersion}.");
        var contentHash = ControlContractHasher.ComputeApprovalHash(review);
        if (!overlay.TestPackContentHash.Equals(contentHash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Approval content hash does not match the reviewed control payload.");
        if (overlay.Status == TestPackApprovalStatus.Approved &&
            (string.IsNullOrWhiteSpace(overlay.ApprovedBy) || overlay.ApprovedAt is null || overlay.EvidenceRefs.Length == 0))
            throw new InvalidDataException("Approved control requires approvedBy, approvedAt, and approval evidence.");

        var approved = overlay.Status == TestPackApprovalStatus.Approved;
        return review with
        {
            Status = approved ? ControlRepositoryEntryStatus.Approved :
                overlay.Status == TestPackApprovalStatus.Rejected ? ControlRepositoryEntryStatus.Rejected : ControlRepositoryEntryStatus.ReviewRequired,
            ReviewedAt = overlay.Status == TestPackApprovalStatus.PendingApproval ? review.ReviewedAt : overlay.ApprovedAt,
            ApprovalPayloadHash = approved ? contentHash : "",
            ControlContractHash = approved && ControlContractHasher.IsContractReady(review) ? ControlContractHasher.Compute(review) : "",
            Approval = new()
            {
                Status = overlay.Status,
                ApprovedBy = approved ? overlay.ApprovedBy : null,
                ApprovedAt = approved ? overlay.ApprovedAt : null,
                EvidenceRefs = overlay.EvidenceRefs,
                ApprovedContentHash = approved ? contentHash : ""
            }
        };
    }

    private static void RequireReview(ControlRepositoryEntry review)
    {
        if (review.Status != ControlRepositoryEntryStatus.ReviewRequired)
            throw new InvalidDataException("Only a ReviewRequired control payload can enter the human approval workflow.");
        if (review.Approval.Status != TestPackApprovalStatus.PendingApproval || !string.IsNullOrWhiteSpace(review.ApprovalPayloadHash))
            throw new InvalidDataException("Review payload must not contain an approval decision or approval hash.");
    }
}

public static class ControlRepositoryValidator
{
    public static IReadOnlyList<ValidationIssue> Validate(ControlRepositoryDocument repository)
    {
        var issues = new List<ValidationIssue>();
        if (repository.SchemaVersion != ControlRepositoryVersions.Schema)
            issues.Add(new("CONTROL_REPOSITORY.SCHEMA_VERSION", "Control Repository schemaVersion must be 1.0.", Field: "schemaVersion"));
        if (string.IsNullOrWhiteSpace(repository.RepositoryId) || string.IsNullOrWhiteSpace(repository.TargetProfileId))
            issues.Add(new("CONTROL_REPOSITORY.IDENTITY", "repositoryId and targetProfileId are required."));

        foreach (var duplicate in repository.Entries.GroupBy(x => x.Key.Canonical, StringComparer.Ordinal).Where(x => x.Count() > 1))
            issues.Add(new("CONTROL_REPOSITORY.DUPLICATE_KEY", $"Duplicate logical key {duplicate.Key}.", Field: "entries.key"));

        foreach (var entry in repository.Entries)
            ValidateEntry(entry, issues);

        if (repository.Status == ControlRepositoryStatus.Ready && repository.Entries.Length == 0)
            issues.Add(new("CONTROL_REPOSITORY.EMPTY_READY", "An empty repository cannot be Ready.", Field: "status"));
        return issues;
    }

    private static void ValidateEntry(ControlRepositoryEntry entry, List<ValidationIssue> issues)
    {
        var key = entry.Key.Canonical;
        if (string.IsNullOrWhiteSpace(entry.Key.Screen) || string.IsNullOrWhiteSpace(entry.Key.LogicalName))
            issues.Add(new("CONTROL_REPOSITORY.KEY_REQUIRED", $"screen and logicalName are required for {key}.", Field: "entries.key"));
        if (entry.AllowedActions.Intersect(entry.ForbiddenActions).Any())
            issues.Add(new("CONTROL_REPOSITORY.ACTION_CONFLICT", $"Allowed and forbidden actions overlap for {key}."));

        var relative = entry.AnchoredRelativeCoordinate;
        if (relative?.IsConfigured == true &&
            (!Unit(relative.RelativeX) || !Unit(relative.RelativeY) || !Unit(relative.RelativeWidth) || !Unit(relative.RelativeHeight) ||
             relative.RelativeX + relative.RelativeWidth > 1 || relative.RelativeY + relative.RelativeHeight > 1))
            issues.Add(new("CONTROL_REPOSITORY.RELATIVE_BOUNDS", $"Anchored coordinates for {key} must remain inside normalized client bounds."));

        if (entry.Status != ControlRepositoryEntryStatus.Approved) return;

        if (entry.Approval.Status != TestPackApprovalStatus.Approved || string.IsNullOrWhiteSpace(entry.Approval.ApprovedBy) ||
            entry.Approval.ApprovedAt is null || entry.Approval.EvidenceRefs.Length == 0)
            issues.Add(new("CONTROL_REPOSITORY.APPROVAL_REQUIRED", $"Approved entry {key} requires the existing approval metadata contract."));

        if (entry.HostFingerprint is null || string.IsNullOrWhiteSpace(entry.HostFingerprint.ProcessName) ||
            entry.HostFingerprint.CapturedWindowWidth <= 0 || entry.HostFingerprint.CapturedWindowHeight <= 0 ||
            string.IsNullOrWhiteSpace(entry.HostFingerprint.ProcessFingerprint) || string.IsNullOrWhiteSpace(entry.HostFingerprint.HostFingerprint) ||
            entry.HostFingerprint.CapturedClientWidth <= 0 || entry.HostFingerprint.CapturedClientHeight <= 0 || entry.HostFingerprint.CapturedDpiScale <= 0)
            issues.Add(new("CONTROL_REPOSITORY.HOST_EVIDENCE", $"Approved entry {key} requires process, host, client bounds, and DPI evidence."));

        var expectedHash = ControlContractHasher.ComputeApprovalHash(entry);
        if (string.IsNullOrWhiteSpace(entry.ApprovalPayloadHash) ||
            !entry.ApprovalPayloadHash.Equals(expectedHash, StringComparison.OrdinalIgnoreCase) ||
            !entry.Approval.ApprovedContentHash.Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
            issues.Add(new("CONTROL_REPOSITORY.APPROVAL_HASH", $"Approval hash does not match the canonical locator payload for {key}."));

        if (!string.IsNullOrWhiteSpace(entry.ControlContractHash) &&
            (!ControlContractHasher.IsContractReady(entry) ||
             !entry.ControlContractHash.Equals(ControlContractHasher.Compute(entry), StringComparison.OrdinalIgnoreCase)))
            issues.Add(new("CONTROL_REPOSITORY.CONTROL_CONTRACT_HASH", $"ControlContractHash does not match the stable control contract for {key}."));

        if (entry.TransactionalRole != ControlTransactionalRole.None && entry.RiskClass != ControlRiskClass.Transactional)
            issues.Add(new("CONTROL_REPOSITORY.TRANSACTIONAL_ROLE_RISK", $"Transactional role for {key} requires Transactional risk classification."));

        if (relative?.IsConfigured == true)
        {
            if (string.IsNullOrWhiteSpace(relative.AnchorId) || string.IsNullOrWhiteSpace(entry.ExpectedControlKind) ||
                entry.VisualSignature?.IsConfigured != true)
                issues.Add(new("CONTROL_REPOSITORY.COORDINATE_EVIDENCE", $"Approved anchored locator {key} lacks required host, DPI, anchor, kind, or visual evidence."));
        }

        if (string.IsNullOrWhiteSpace(entry.Source) || entry.EvidenceRefs.Length == 0)
            issues.Add(new("CONTROL_REPOSITORY.SOURCE_EVIDENCE", $"Approved entry {key} requires source and evidence references."));
    }

    private static bool Unit(double value) => double.IsFinite(value) && value >= 0 && value <= 1;
}

public sealed record ControlRepositoryPoint(int X, int Y);

public sealed record ControlRepositoryRect(int Left, int Top, int Width, int Height)
{
    public bool IsValid => Width > 0 && Height > 0;
    public bool Contains(ControlRepositoryPoint point) =>
        IsValid && point.X >= Left && point.Y >= Top && point.X < Left + Width && point.Y < Top + Height;
}

public sealed record ControlCoordinateTransformEvidence
{
    public bool IsValid { get; init; }
    public bool DpiTransformValid { get; init; }
    public bool InsideClientBounds { get; init; }
    public double DpiScale { get; init; }
    public ControlRepositoryRect? CurrentClientRect { get; init; }
    public ControlRepositoryPoint? ScreenPoint { get; init; }
    public string FailureReason { get; init; } = "";
}

public sealed record ControlRepositoryResolutionRequest
{
    public required ControlRepositoryKey Key { get; init; }
    public required ControlRepositoryAction Action { get; init; }
    public bool PhysicalAction { get; init; }
    public string ActiveScreen { get; init; } = "";
    public string ActiveMap { get; init; } = "";
    public string ActiveStateContext { get; init; } = "";
    public string ProcessName { get; init; } = "";
    public string ProcessFingerprint { get; init; } = "";
    public string HostFingerprint { get; init; } = "";
    public string[] ObservedAnchorIds { get; init; } = [];
    public string AnchorId { get; init; } = "";
    public string ObservedControlKind { get; init; } = "";
    public bool StableIdentityMatched { get; init; }
    public bool MapRuntimeBindingMatched { get; init; }
    public bool VisualSignatureMatched { get; init; }
    public bool ForbiddenControlCollision { get; init; }
    public bool TransactionalPolicyApproved { get; init; }
    public ControlCoordinateTransformEvidence? CoordinateTransform { get; init; }
}

public sealed record ControlRepositoryResolution
{
    public string SchemaVersion { get; init; } = ControlRepositoryVersions.ResolutionSchema;
    public bool PhysicalAction { get; init; }
    public required string RepositoryKey { get; init; }
    public ControlRepositoryResolutionStatus Status { get; init; }
    public LocatorTrustTier TrustTier { get; init; } = LocatorTrustTier.Unresolved;
    public string LocatorSource { get; init; } = "";
    public string FallbackReason { get; init; } = "";
    public string ReasonCode { get; init; } = "";
    public string Reason { get; init; } = "";
    public TestPackApprovalStatus ApprovalStatus { get; init; } = TestPackApprovalStatus.PendingApproval;
    public string ApprovalPayloadHash { get; init; } = "";
    public ControlRepositoryAction Action { get; init; }
    public ControlRepositoryPoint? ResolvedScreenPoint { get; init; }
    public bool ActionSent { get; init; }
    public string[] Evidence { get; init; } = [];
}

public sealed record ControlRepositoryResolutionDocument
{
    public string SchemaVersion { get; init; } = ControlRepositoryVersions.ResolutionSchema;
    public string RepositoryId { get; init; } = "";
    public ControlRepositoryResolution[] Resolutions { get; init; } = [];
}

public static class ControlRepositoryResolver
{
    private static readonly HashSet<ControlRepositoryAction> TransactionalActions =
        [ControlRepositoryAction.FinalSubmit, ControlRepositoryAction.AmendSubmit, ControlRepositoryAction.CancelSubmit];

    private static readonly HashSet<ControlRepositoryAction> ObservationActions =
        [ControlRepositoryAction.Observe, ControlRepositoryAction.Assert];

    public static ControlRepositoryResolution Resolve(ControlRepositoryDocument repository, ControlRepositoryResolutionRequest request)
    {
        var key = request.Key.Canonical;
        var validation = ControlRepositoryValidator.Validate(repository);
        if (validation.Count > 0)
            return Block(key, request.Action, "REPOSITORY_INVALID", string.Join(" ", validation.Select(x => x.Code)));

        var entry = repository.Entries.SingleOrDefault(x => x.Key.Canonical.Equals(key, StringComparison.Ordinal));
        if (entry is null)
            return Unresolved(key, request.Action, "ENTRY_NOT_FOUND", "No repository entry exists for the logical key.");
        if (entry.Status != ControlRepositoryEntryStatus.Approved)
            return Block(entry, request.Action, "ENTRY_NOT_APPROVED", $"Entry status is {entry.Status}.");

        var expectedHash = ControlRepositoryApprovalPayload.ComputeHash(entry);
        if (entry.Approval.Status != TestPackApprovalStatus.Approved ||
            !entry.ApprovalPayloadHash.Equals(expectedHash, StringComparison.OrdinalIgnoreCase) ||
            !entry.Approval.ApprovedContentHash.Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
            return Block(entry, request.Action, "APPROVAL_HASH_MISMATCH", "Approval metadata or canonical payload hash does not match.");

        if (!entry.AllowedActions.Contains(request.Action) || entry.ForbiddenActions.Contains(request.Action))
            return Block(entry, request.Action, "ACTION_NOT_ALLOWED", "The requested action is not approved for this entry.");
        var visualOnly = entry.StableIdentity?.IsConfigured != true && entry.MapRuntimeBinding?.IsConfigured != true &&
            entry.AnchoredRelativeCoordinate?.IsConfigured != true && entry.VisualSignature?.IsConfigured == true;
        if (!visualOnly && entry.RiskClass == ControlRiskClass.ObservationOnly && !ObservationActions.Contains(request.Action))
            return Block(entry, request.Action, "RISK_POLICY_BLOCKED", "ObservationOnly entries can only observe or assert.");
        if (request.Action == ControlRepositoryAction.OpenConfirmation && !request.TransactionalPolicyApproved)
            return Block(entry, request.Action, "CONFIRMATION_POLICY_REQUIRED", "Opening a confirmation boundary requires separate policy approval.");
        if (TransactionalActions.Contains(request.Action) && !request.TransactionalPolicyApproved)
            return Block(entry, request.Action, "TRANSACTIONAL_POLICY_REQUIRED", "Transactional actions require a separate policy approval.");
        if (!ContextMatches(entry, request, out var contextReason))
            return Block(entry, request.Action, "CONTEXT_MISMATCH", contextReason);

        if (entry.StableIdentity?.IsConfigured == true)
            return request.StableIdentityMatched
                ? Resolved(entry, request, LocatorTrustTier.StableIdentity, "StableIdentity", "")
                : Block(entry, request.Action, "STABLE_IDENTITY_MISMATCH", "A configured higher-trust stable identity did not match; fallback is not allowed.");

        if (entry.MapRuntimeBinding?.IsConfigured == true)
            return request.MapRuntimeBindingMatched
                ? Resolved(entry, request, LocatorTrustTier.MapRuntimeBinding, "MapRuntimeBinding", "No stable identity is configured.")
                : Block(entry, request.Action, "MAP_RUNTIME_MISMATCH", "A configured higher-trust MAP/runtime binding did not match; fallback is not allowed.");

        if (entry.AnchoredRelativeCoordinate?.IsConfigured == true)
            return ResolveCoordinate(entry, request);

        if (entry.VisualSignature?.IsConfigured == true)
        {
            if (request.PhysicalAction || !ObservationActions.Contains(request.Action))
                return Block(entry, request.Action, "VISUAL_PHYSICAL_ACTION_FORBIDDEN", "Image/visual-only locators cannot perform a physical action.");
            if (!request.VisualSignatureMatched)
                return Block(entry, request.Action, "VISUAL_SIGNATURE_MISMATCH", "The observed visual signature is outside the approved match contract.");
            return Resolved(entry, request, LocatorTrustTier.VisualObservationOnly, "VisualSignature", "No UIA/native, MAP/runtime, or anchored locator is configured.");
        }

        return Unresolved(entry.Key.Canonical, request.Action, "LOCATOR_NOT_CONFIGURED", "The entry has no locator evidence.", entry);
    }

    public static ControlRepositoryResolution CreateReviewSuggestion(ControlRepositoryKey key, ControlRepositoryAction action, string reason, string[] evidence) => new()
    {
        RepositoryKey = key.Canonical,
        Status = ControlRepositoryResolutionStatus.ReviewSuggestion,
        TrustTier = LocatorTrustTier.Unresolved,
        LocatorSource = "DiscoverySuggestion",
        FallbackReason = reason,
        ReasonCode = "HUMAN_REVIEW_REQUIRED",
        Reason = "Discovery changes are suggestions only and never update or approve the repository.",
        Action = action,
        ActionSent = false,
        Evidence = evidence
    };

    private static ControlRepositoryResolution ResolveCoordinate(ControlRepositoryEntry entry, ControlRepositoryResolutionRequest request)
    {
        if (TransactionalActions.Contains(request.Action))
            return Block(entry, request.Action, "COORDINATE_TRANSACTION_FORBIDDEN", "Final submit, amend submit, and cancel submit cannot use relative coordinates.");
        var nonObservationPhysical = request.PhysicalAction && !ObservationActions.Contains(request.Action);
        if (nonObservationPhysical && entry.RiskClass != ControlRiskClass.LimitedNonTransactional)
            return Block(entry, request.Action, "COORDINATE_RISK_CLASS_BLOCKED", "Relative-coordinate physical actions require LimitedNonTransactional risk approval.");
        if (request.ForbiddenControlCollision)
            return Block(entry, request.Action, "FORBIDDEN_CONTROL_COLLISION", "The resolved point intersects a forbidden control region.");
        if (!request.ObservedAnchorIds.Contains(entry.AnchoredRelativeCoordinate!.AnchorId, StringComparer.Ordinal))
            return Block(entry, request.Action, "ANCHOR_MISMATCH", "The reobserved redacted anchor candidates do not contain the approved anchor.");
        if (string.IsNullOrWhiteSpace(entry.ExpectedControlKind) ||
            !request.ObservedControlKind.Equals(entry.ExpectedControlKind, StringComparison.OrdinalIgnoreCase))
            return Block(entry, request.Action, "CONTROL_KIND_MISMATCH", "The hit-tested control kind does not match the approved kind.");
        if (!request.VisualSignatureMatched)
            return Block(entry, request.Action, "VISUAL_SIGNATURE_MISMATCH", "The observed visual signature is outside the approved match contract.");
        if (request.CoordinateTransform is not { IsValid: true, DpiTransformValid: true, InsideClientBounds: true, ScreenPoint: not null } transform ||
            transform.CurrentClientRect?.Contains(transform.ScreenPoint) != true)
            return Block(entry, request.Action, "COORDINATE_TRANSFORM_INVALID", request.CoordinateTransform?.FailureReason ?? "Coordinate transform evidence is missing.");

        return Resolved(entry, request, LocatorTrustTier.ApprovedAnchoredRelative, "AnchoredRelativeCoordinate",
            "No stable identity or MAP/runtime binding is configured; the approved coordinate fallback passed every execution-time guard.", transform.ScreenPoint);
    }

    private static bool ContextMatches(ControlRepositoryEntry entry, ControlRepositoryResolutionRequest request, out string reason)
    {
        if (!entry.Key.Screen.Equals(request.ActiveScreen, StringComparison.OrdinalIgnoreCase))
        {
            reason = "Active screen does not match the repository key.";
            return false;
        }
        if (!string.IsNullOrWhiteSpace(entry.Key.Map) && !entry.Key.Map.Equals(request.ActiveMap, StringComparison.OrdinalIgnoreCase))
        {
            reason = "Active MAP does not match the repository key.";
            return false;
        }
        if (!string.IsNullOrWhiteSpace(entry.Key.StateContext) && !entry.Key.StateContext.Equals(request.ActiveStateContext, StringComparison.Ordinal))
        {
            reason = "Active stateContext does not match the repository key.";
            return false;
        }

        var host = entry.HostFingerprint;
        if (host is not null &&
            (!host.ProcessName.Equals(request.ProcessName, StringComparison.OrdinalIgnoreCase) ||
             !host.ProcessFingerprint.Equals(request.ProcessFingerprint, StringComparison.Ordinal) ||
             !host.HostFingerprint.Equals(request.HostFingerprint, StringComparison.Ordinal)))
        {
            reason = "Process ownership or host fingerprint is stale or different.";
            return false;
        }
        reason = "";
        return true;
    }

    private static ControlRepositoryResolution Resolved(ControlRepositoryEntry entry, ControlRepositoryResolutionRequest request,
        LocatorTrustTier trustTier, string source, string fallback, ControlRepositoryPoint? point = null) => new()
    {
        RepositoryKey = entry.Key.Canonical,
        Status = ControlRepositoryResolutionStatus.Resolved,
        TrustTier = trustTier,
        LocatorSource = source,
        FallbackReason = fallback,
        ReasonCode = "RESOLVED",
        Reason = "Locator resolution succeeded; no physical action has been sent.",
        ApprovalStatus = entry.Approval.Status,
        PhysicalAction = request.PhysicalAction,
        ApprovalPayloadHash = entry.ApprovalPayloadHash,
        Action = request.Action,
        ResolvedScreenPoint = point,
        ActionSent = false,
        Evidence = entry.EvidenceRefs
    };

    private static ControlRepositoryResolution Block(ControlRepositoryEntry entry, ControlRepositoryAction action, string code, string reason) =>
        Block(entry.Key.Canonical, action, code, reason, entry);

    private static ControlRepositoryResolution Block(string key, ControlRepositoryAction action, string code, string reason, ControlRepositoryEntry? entry = null) => new()
    {
        RepositoryKey = key,
        Status = ControlRepositoryResolutionStatus.Blocked,
        TrustTier = LocatorTrustTier.Unresolved,
        ReasonCode = code,
        Reason = reason,
        ApprovalStatus = entry?.Approval.Status ?? TestPackApprovalStatus.PendingApproval,
        ApprovalPayloadHash = entry?.ApprovalPayloadHash ?? "",
        Action = action,
        ActionSent = false,
        Evidence = entry?.EvidenceRefs ?? []
    };

    private static ControlRepositoryResolution Unresolved(string key, ControlRepositoryAction action, string code, string reason,
        ControlRepositoryEntry? entry = null) => new()
    {
        RepositoryKey = key,
        Status = ControlRepositoryResolutionStatus.Unresolved,
        TrustTier = LocatorTrustTier.Unresolved,
        ReasonCode = code,
        Reason = reason,
        ApprovalStatus = entry?.Approval.Status ?? TestPackApprovalStatus.PendingApproval,
        ApprovalPayloadHash = entry?.ApprovalPayloadHash ?? "",
        Action = action,
        ActionSent = false,
        Evidence = entry?.EvidenceRefs ?? []
    };
}

public sealed record ControlCaptureCandidate
{
    public DateTimeOffset CapturedAt { get; init; }
    public string SchemaVersion { get; init; } = ControlRepositoryVersions.CaptureSchema;
    public string TargetProfileId { get; init; } = "";
    public ControlRepositoryEntryStatus Status { get; init; } = ControlRepositoryEntryStatus.ReviewRequired;
    public string ProcessName { get; init; } = "";
    public string ProcessFingerprint { get; init; } = "";
    public string HostFingerprint { get; init; } = "";
    public string StateContext { get; init; } = "";
    public string MapScreenCode { get; init; } = "";
    public int WindowWidth { get; init; }
    public int WindowHeight { get; init; }
    public ControlRepositoryCoordinateSpace CoordinateSpace { get; init; }
    public double RelativeX { get; init; }
    public double RelativeY { get; init; }
    public int ClientWidth { get; init; }
    public int ClientHeight { get; init; }
    public double DpiScale { get; init; }
    public string[] RedactedIdentityCandidates { get; init; } = [];
    public string ExpectedControlKindCandidate { get; init; } = "";
    public string VisualSignatureHash { get; init; } = "";
    public string[] RedactionsApplied { get; init; } = [];
    public bool CursorMoved { get; init; }
    public bool ClickSent { get; init; }
    public bool AutomaticallyApproved { get; init; }
}
