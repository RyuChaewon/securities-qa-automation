// 역할: 읽기 전용 컨트롤 관측을 반복 가능한 캘리브레이션 세션으로 묶고 안정성/승인 경계를 판정한다.
// 경계: UI를 조작하거나 repository를 자동 변경하지 않으며 민감 텍스트와 pixel crop을 계약에 포함하지 않는다.
namespace HtsQa.Core;

public static class OrderCalibrationVersions
{
    public const string SessionSchema = "1.0";
}

public enum CalibrationSessionStatus
{
    ConfigurationRequired,
    ReviewRequired,
    Unstable,
    Approved,
    Applied
}

public sealed record CalibrationBounds
{
    public int Width { get; init; }
    public int Height { get; init; }
    public bool IsValid => Width > 0 && Height > 0;
}

public sealed record CalibrationObservation
{
    public required string ObservationId { get; init; }
    public DateTimeOffset CapturedAt { get; init; }
    public required string Screen { get; init; }
    public string Map { get; init; } = "";
    public required string StateContext { get; init; }
    public ControlHostFingerprint HostFingerprint { get; init; } = new();
    public CalibrationBounds WindowBounds { get; init; } = new();
    public CalibrationBounds ClientBounds { get; init; } = new();
    public ControlVisualSignature? VisualSignature { get; init; }
    public double DpiScale { get; init; }
    public LocatorTrustTier LocatorTier { get; init; } = LocatorTrustTier.Unresolved;
    public ControlStableIdentity? StableIdentity { get; init; }
    public ControlMapRuntimeBinding? MapRuntimeBinding { get; init; }
    public AnchoredRelativeCoordinate? AnchoredRelativeCoordinate { get; init; }
    public string ExpectedControlKind { get; init; } = "";
    public string[] RedactedAnchorCandidates { get; init; } = [];
    public string[] AllowedActions { get; init; } = [];
    public string[] ForbiddenActions { get; init; } = [];
    public string[] EvidenceRefs { get; init; } = [];
    public bool SensitiveDataRedacted { get; init; }
    public bool PixelCropStored { get; init; }
    public bool CursorMoved { get; init; }
    public bool ClickSent { get; init; }
    public bool KeyInputSent { get; init; }
    public bool AutomaticallyApproved { get; init; }
}

public sealed record CalibrationDrift
{
    public int ObservationCount { get; init; }
    public bool IdentityChanged { get; init; }
    public bool BoundsChanged { get; init; }
    public bool AnchorChanged { get; init; }
    public bool DpiChanged { get; init; }
    public bool HostFingerprintChanged { get; init; }
    public bool IsUnstable => IdentityChanged || BoundsChanged || AnchorChanged || DpiChanged || HostFingerprintChanged;
}

public sealed record OrderCalibrationSession
{
    public string SchemaVersion { get; init; } = OrderCalibrationVersions.SessionSchema;
    public required string SessionId { get; init; }
    public required string TargetProfileId { get; init; }
    public required string RepositoryId { get; init; }
    public required string Screen { get; init; }
    public string Map { get; init; } = "";
    public required string StateContext { get; init; }
    public DateTimeOffset CapturedAt { get; init; }
    public string Reviewer { get; init; } = "";
    public CalibrationSessionStatus Status { get; init; } = CalibrationSessionStatus.ConfigurationRequired;
    public CalibrationObservation[] Observations { get; init; } = [];
    public CalibrationDrift Drift { get; init; } = new();
    public bool RepositoryApplied { get; init; }
    public string CanonicalApprovalHash { get; init; } = "";
}

public sealed record CalibrationSessionValidationReport
{
    public string SchemaVersion { get; init; } = OrderCalibrationVersions.SessionSchema;
    public required string SessionId { get; init; }
    public CalibrationSessionStatus Status { get; init; }
    public int ObservationCount { get; init; }
    public CalibrationDrift Drift { get; init; } = new();
    public bool IsValid { get; init; }
    public ValidationIssue[] Issues { get; init; } = [];
}

public static class OrderCalibrationSessionAnalyzer
{
    public static CalibrationSessionValidationReport Analyze(OrderCalibrationSession session)
    {
        var issues = new List<ValidationIssue>();
        if (session.SchemaVersion != OrderCalibrationVersions.SessionSchema)
            Add("CALIBRATION.SCHEMA_VERSION", "Unsupported calibration session schema.", "Use schemaVersion 1.0.");
        if (string.IsNullOrWhiteSpace(session.SessionId) || string.IsNullOrWhiteSpace(session.TargetProfileId) ||
            string.IsNullOrWhiteSpace(session.RepositoryId) || string.IsNullOrWhiteSpace(session.Screen) ||
            string.IsNullOrWhiteSpace(session.StateContext))
            Add("CALIBRATION.IDENTITY_REQUIRED", "Session, target, repository, screen and stateContext are required.", "Supply only observed and configured identities.");
        if (session.CapturedAt == default)
            Add("CALIBRATION.CAPTURE_TIME_REQUIRED", "A capture timestamp is required.", "Record the observation time at capture.");
        foreach (var duplicate in session.Observations.GroupBy(x => x.ObservationId, StringComparer.Ordinal).Where(x => x.Count() > 1))
            Add("CALIBRATION.DUPLICATE_OBSERVATION_ID", $"Observation id {duplicate.Key} is duplicated.", "Use a unique capture identity for each observation.", duplicate.Key);
        foreach (var duplicate in session.Observations.GroupBy(ObservationFingerprint, StringComparer.Ordinal).Where(x => x.Count() > 1))
            Add("CALIBRATION.DUPLICATE_OBSERVATION", "The same captured observation was supplied more than once.", "Capture the control again at a distinct observation time; do not reuse one artifact.");

        foreach (var observation in session.Observations)
        {
            var step = observation.ObservationId;
            if (observation.CapturedAt == default)
                Add("CALIBRATION.OBSERVATION_TIME_REQUIRED", "Each observation requires a capture timestamp.", "Capture again with a timestamp.", step);
            if (!observation.Screen.Equals(session.Screen, StringComparison.OrdinalIgnoreCase) ||
                !observation.Map.Equals(session.Map, StringComparison.OrdinalIgnoreCase) ||
                !observation.StateContext.Equals(session.StateContext, StringComparison.Ordinal))
                Add("CALIBRATION.CONTEXT_MISMATCH", "Observation screen/MAP/stateContext differs from the session.", "Create a separate session for each state context.", step);
            if (!observation.WindowBounds.IsValid || !observation.ClientBounds.IsValid || observation.DpiScale <= 0)
                Add("CALIBRATION.GEOMETRY_REQUIRED", "Window/client bounds and positive DPI are required.", "Capture geometry from the approved host.", step);
            if (string.IsNullOrWhiteSpace(observation.HostFingerprint.ProcessName) ||
                string.IsNullOrWhiteSpace(observation.HostFingerprint.ProcessFingerprint) ||
                string.IsNullOrWhiteSpace(observation.HostFingerprint.HostFingerprint))
                Add("CALIBRATION.FINGERPRINT_REQUIRED", "Process and host fingerprints are required.", "Capture process ownership and host fingerprints.", step);
            if (!observation.SensitiveDataRedacted || observation.PixelCropStored)
                Add("CALIBRATION.SENSITIVE_ARTIFACT", "Sensitive redaction is required and pixel crops must not be stored.", "Discard the artifact and recapture with metadata-only redaction.", step);
            if (observation.CursorMoved || observation.ClickSent || observation.KeyInputSent)
                Add("CALIBRATION.READ_ONLY_REQUIRED", "Calibration capture must not move the cursor or send click/key input.", "Use the read-only capture path.", step);
            if (observation.AutomaticallyApproved)
                Add("CALIBRATION.AUTO_APPROVAL_FORBIDDEN", "Calibration cannot automatically approve a candidate.", "Route the candidate through human review and the canonical approval overlay.", step);
        }

        var drift = MeasureDrift(session.Observations);
        var status = DeriveStatus(session, drift, issues);
        if (session.Status is CalibrationSessionStatus.Approved or CalibrationSessionStatus.Applied)
        {
            if (string.IsNullOrWhiteSpace(session.Reviewer) || string.IsNullOrWhiteSpace(session.CanonicalApprovalHash))
                Add("CALIBRATION.APPROVAL_REQUIRED", "Approved/applied sessions require reviewer and canonical approval hash.", "Apply a human-reviewed canonical approval decision.");
            if (drift.IsUnstable || session.Observations.Length < 2)
                Add("CALIBRATION.APPROVAL_UNSTABLE", "An unstable or single-observation session cannot be approved.", "Repeat observation until stable, then review again.");
            if (session.Status == CalibrationSessionStatus.Applied && !session.RepositoryApplied)
                Add("CALIBRATION.REPOSITORY_APPLICATION_REQUIRED", "Applied status requires repositoryApplied=true.", "Register the approved entry explicitly.");
        }

        if (issues.Count > 0 && status is CalibrationSessionStatus.Approved or CalibrationSessionStatus.Applied)
            status = drift.IsUnstable ? CalibrationSessionStatus.Unstable : CalibrationSessionStatus.ReviewRequired;

        return new()
        {
            SessionId = session.SessionId,
            Status = status,
            ObservationCount = session.Observations.Length,
            Drift = drift,
            IsValid = issues.Count == 0,
            Issues = issues.ToArray()
        };

        void Add(string code, string message, string remediation, string? stepId = null) =>
            issues.Add(new(code, message, stepId, Remediation: remediation));
    }

    public static OrderCalibrationSession Normalize(OrderCalibrationSession session)
    {
        var report = Analyze(session);
        return session with { Status = report.Status, Drift = report.Drift };
    }

    private static CalibrationSessionStatus DeriveStatus(OrderCalibrationSession session, CalibrationDrift drift, List<ValidationIssue> issues)
    {
        if (session.Observations.Length == 0) return CalibrationSessionStatus.ConfigurationRequired;
        if (drift.IsUnstable) return CalibrationSessionStatus.Unstable;
        if (issues.Count > 0 || session.Observations.Length < 2) return CalibrationSessionStatus.ReviewRequired;
        return session.Status is CalibrationSessionStatus.Approved or CalibrationSessionStatus.Applied
            ? session.Status
            : CalibrationSessionStatus.ReviewRequired;
    }

    public static CalibrationDrift MeasureDrift(IReadOnlyList<CalibrationObservation> observations)
    {
        if (observations.Count == 0) return new();
        var first = observations[0];
        return new()
        {
            ObservationCount = observations.Count,
            IdentityChanged = observations.Skip(1).Any(x => Identity(x) != Identity(first)),
            BoundsChanged = observations.Skip(1).Any(x => x.WindowBounds != first.WindowBounds || x.ClientBounds != first.ClientBounds),
            AnchorChanged = observations.Skip(1).Any(x => !x.RedactedAnchorCandidates.SequenceEqual(first.RedactedAnchorCandidates, StringComparer.Ordinal)),
            DpiChanged = observations.Skip(1).Any(x => x.DpiScale != first.DpiScale),
            HostFingerprintChanged = observations.Skip(1).Any(x => Host(x) != Host(first))
        };
    }

    private static string Identity(CalibrationObservation value) => Convert.ToHexString(CanonicalJson.SerializeToUtf8Bytes(new
    {
        value.LocatorTier,
        value.StableIdentity,
        value.MapRuntimeBinding,
        value.AnchoredRelativeCoordinate,
        value.ExpectedControlKind,
        value.VisualSignature,
    }));

    private static string Host(CalibrationObservation value) => Convert.ToHexString(CanonicalJson.SerializeToUtf8Bytes(value.HostFingerprint));

    private static string ObservationFingerprint(CalibrationObservation value) => Convert.ToHexString(CanonicalJson.SerializeToUtf8Bytes(new
    {
        value.CapturedAt,
        value.Screen,
        value.Map,
        value.StateContext,
        value.HostFingerprint,
        value.WindowBounds,
        value.ClientBounds,
        value.DpiScale,
        Identity = Identity(value),
        value.RedactedAnchorCandidates
    }));
}

/// <summary>사람이 승인한 entry만 새 문서로 등록한다. 입력 repository를 변경하거나 기존 key를 덮어쓰지 않는다.</summary>
public static class ControlRepositoryRegistration
{
    public static ControlRepositoryDocument Register(ControlRepositoryDocument repository, ControlRepositoryEntry entry)
    {
        if (repository.Entries.Any(x => x.Key.Canonical.Equals(entry.Key.Canonical, StringComparison.Ordinal)))
            throw new InvalidDataException($"Duplicate repository key: {entry.Key.Canonical}.");
        var candidate = repository with { Status = ControlRepositoryStatus.Ready, Entries = [.. repository.Entries, entry] };
        var issues = ControlRepositoryValidator.Validate(candidate);
        if (entry.Status != ControlRepositoryEntryStatus.Approved || issues.Count > 0)
            throw new InvalidDataException(string.Join(Environment.NewLine, issues.Select(x => $"{x.Code}: {x.Message}").Prepend("Only a valid approved entry can be registered.")));
        return candidate;
    }
}
