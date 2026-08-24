// 역할: 명시적 repository 등록이 끝난 뒤 calibration session provenance를 canonical approval hash로 고정한다.
// 경계: repository를 병합하거나 승인하지 않고 이미 등록된 단일 승인 entry만 확인한다.
namespace HtsQa.Core;

public static class OrderCalibrationSessionLifecycle
{
    public static OrderCalibrationSession MarkApplied(OrderCalibrationSession session, ControlRepositoryDocument repository, string logicalName)
    {
        var report = OrderCalibrationSessionAnalyzer.Analyze(session);
        if (!report.IsValid || report.ObservationCount < 2 || report.Drift.IsUnstable || string.IsNullOrWhiteSpace(session.Reviewer))
            throw new InvalidDataException("Only a stable human-reviewed calibration session can be finalized.");
        if (!repository.RepositoryId.Equals(session.RepositoryId, StringComparison.Ordinal) ||
            !repository.TargetProfileId.Equals(session.TargetProfileId, StringComparison.Ordinal))
            throw new InvalidDataException("The registered repository identity does not match the calibration session.");
        var key = ControlRepositoryKey.CreateCanonical(session.Screen, session.Map, logicalName, session.StateContext);
        var matches = repository.Entries.Where(x => x.Key.Canonical.Equals(key, StringComparison.Ordinal)).ToArray();
        if (matches.Length != 1) throw new InvalidDataException("Exactly one registered repository entry must match the calibration key.");
        var entry = matches[0];
        var hash = ControlRepositoryApprovalPayload.ComputeHash(entry);
        if (entry.Status != ControlRepositoryEntryStatus.Approved || entry.Approval.Status != TestPackApprovalStatus.Approved ||
            !entry.ApprovalPayloadHash.Equals(hash, StringComparison.OrdinalIgnoreCase) ||
            !entry.Approval.ApprovedContentHash.Equals(hash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The registered repository entry is not canonically approved.");
        return session with
        {
            Status = CalibrationSessionStatus.Applied,
            RepositoryApplied = true,
            CanonicalApprovalHash = hash,
            Drift = report.Drift
        };
    }
}
