// 역할: 기존 read-only capture들을 세션으로 묶고, 안정된 세션에서 사람이 고른 값으로 ReviewRequired entry만 생성한다.
// 경계: 승인 결정과 repository 병합은 하지 않는다.
namespace HtsQa.Core;

public static class OrderCalibrationSessionFactory
{
    public static OrderCalibrationSession Create(string sessionId, string targetProfileId, string repositoryId,
        string screen, string map, string stateContext, IReadOnlyList<ControlCaptureCandidate> captures)
    {
        if (captures.Any(capture => capture.SchemaVersion != ControlRepositoryVersions.CaptureSchema))
            throw new InvalidDataException("Every capture must use the supported Control Repository capture schema.");
        if (captures.Any(capture => !capture.StateContext.Equals(stateContext, StringComparison.Ordinal)))
            throw new InvalidDataException("A capture stateContext cannot be relabeled by the calibration session.");
        if (captures.Any(capture => !capture.MapScreenCode.Equals(map, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException("A capture MAP cannot be relabeled by the calibration session.");
        if (captures.GroupBy(capture => Convert.ToHexString(CanonicalJson.SerializeToUtf8Bytes(capture)), StringComparer.Ordinal).Any(group => group.Count() > 1))
            throw new InvalidDataException("The same capture artifact cannot count as repeated observation.");
        var observations = captures.Select((capture, index) => new CalibrationObservation
        {
            ObservationId = $"observation-{index + 1:D3}",
            CapturedAt = capture.CapturedAt,
            Screen = screen,
            Map = map,
            StateContext = stateContext,
            HostFingerprint = new()
            {
                ProcessName = capture.ProcessName,
                ProcessFingerprint = capture.ProcessFingerprint,
                HostFingerprint = capture.HostFingerprint,
                CapturedWindowWidth = capture.WindowWidth,
                CapturedWindowHeight = capture.WindowHeight,
                CapturedClientWidth = capture.ClientWidth,
                CapturedClientHeight = capture.ClientHeight,
                CapturedDpiScale = capture.DpiScale
            },
            WindowBounds = new() { Width = capture.WindowWidth, Height = capture.WindowHeight },
            ClientBounds = new() { Width = capture.ClientWidth, Height = capture.ClientHeight },
            DpiScale = capture.DpiScale,
            LocatorTier = LocatorTrustTier.Unresolved,
            AnchoredRelativeCoordinate = new()
            {
                CoordinateSpace = capture.CoordinateSpace,
                RelativeX = capture.RelativeX,
                RelativeY = capture.RelativeY
            },
            ExpectedControlKind = capture.ExpectedControlKindCandidate,
            VisualSignature = string.IsNullOrWhiteSpace(capture.VisualSignatureHash) ? null : new()
            {
                Algorithm = "sha256-redacted-identity-geometry",
                SignatureHash = capture.VisualSignatureHash,
                MinimumSimilarity = 1.0
            },
            RedactedAnchorCandidates = capture.RedactedIdentityCandidates,
            EvidenceRefs = ["capture:" + (index + 1).ToString("D3")],
            SensitiveDataRedacted = capture.RedactionsApplied.Length > 0,
            PixelCropStored = false,
            CursorMoved = capture.CursorMoved,
            ClickSent = capture.ClickSent,
            KeyInputSent = false,
            AutomaticallyApproved = capture.AutomaticallyApproved
        }).ToArray();
        var session = new OrderCalibrationSession
        {
            SessionId = sessionId,
            TargetProfileId = targetProfileId,
            RepositoryId = repositoryId,
            Screen = screen,
            Map = map,
            StateContext = stateContext,
            CapturedAt = observations.Select(x => x.CapturedAt).DefaultIfEmpty().Min(),
            Status = observations.Length == 0 ? CalibrationSessionStatus.ConfigurationRequired : CalibrationSessionStatus.ReviewRequired,
            Observations = observations
        };
        return OrderCalibrationSessionAnalyzer.Normalize(session);
    }
}

public static class OrderCalibrationReviewFactory
{
    private static readonly HashSet<ControlRepositoryAction> CoordinateProhibited =
        [ControlRepositoryAction.FinalSubmit, ControlRepositoryAction.AmendSubmit, ControlRepositoryAction.CancelSubmit];

    public static ControlRepositoryEntry Create(OrderCalibrationSession session, string logicalName, string selectedAnchor,
        ControlRiskClass riskClass, ControlRepositoryAction[] allowedActions, ControlRepositoryAction[] forbiddenActions,
        string source, string[] evidenceRefs, DateTimeOffset createdAt)
    {
        var report = OrderCalibrationSessionAnalyzer.Analyze(session);
        if (report.Issues.Length > 0 || report.ObservationCount < 2 || report.Drift.IsUnstable)
            throw new InvalidDataException("Only a safe, repeated, stable calibration session can create a review payload.");
        if (session.Status != CalibrationSessionStatus.ReviewRequired || string.IsNullOrWhiteSpace(session.Reviewer))
            throw new InvalidDataException("A ReviewRequired session and explicit human reviewer are required.");
        if (string.IsNullOrWhiteSpace(logicalName) || string.IsNullOrWhiteSpace(source) || evidenceRefs.Length == 0)
            throw new InvalidDataException("logicalName, source and evidence references require human confirmation.");
        if (allowedActions.Length == 0 || allowedActions.Intersect(forbiddenActions).Any())
            throw new InvalidDataException("Allowed actions must be non-empty and cannot conflict with forbidden actions.");

        var observation = session.Observations[0];
        if (observation.AnchoredRelativeCoordinate?.IsConfigured == true)
        {
            if (CoordinateProhibited.Overlaps(allowedActions))
                throw new InvalidDataException("Relative-coordinate entries cannot allow final, amend, or cancel submit.");
            if (string.IsNullOrWhiteSpace(selectedAnchor) ||
                !session.Observations.All(x => x.RedactedAnchorCandidates.Contains(selectedAnchor, StringComparer.Ordinal)))
                throw new InvalidDataException("The human-selected anchor must be present in every repeated observation.");
        }

        var relative = observation.AnchoredRelativeCoordinate;
        return new()
        {
            Key = new() { Screen = session.Screen, Map = session.Map, LogicalName = logicalName, StateContext = session.StateContext },
            Status = ControlRepositoryEntryStatus.ReviewRequired,
            StableIdentity = observation.StableIdentity,
            MapRuntimeBinding = observation.MapRuntimeBinding,
            AnchoredRelativeCoordinate = relative is null ? null : relative with { AnchorId = selectedAnchor },
            HostFingerprint = observation.HostFingerprint,
            ExpectedControlKind = observation.ExpectedControlKind,
            VisualSignature = observation.VisualSignature,
            RiskClass = riskClass,
            AllowedActions = allowedActions.Distinct().Order().ToArray(),
            ForbiddenActions = forbiddenActions.Distinct().Order().ToArray(),
            CreatedAt = createdAt,
            Source = source,
            EvidenceRefs = evidenceRefs.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray()
        };
    }
}
