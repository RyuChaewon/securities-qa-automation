// Role: owns Control Repository validation, review, approval, and resolution adapters.
// Inputs/outputs: preserves the existing CLI arguments, JSON protocol, and exit-code behavior.
// Boundary: delegates domain policy to HtsQa.Core and never starts HTS, FlaUI, or physical UI actions.
using System.Text.Json;
using HtsQa.Core;
using static HtsQa.Cli.CliArguments;

namespace HtsQa.Cli;

internal static class ControlRepositoryCommands
{
    // repository 구조·중복 key·승인 해시를 Core 단일 validator로 검사하며 UI를 열거나 수정하지 않는다.
    internal static int ValidateControlRepository(CliCommandContext context, string[] argv)
    {
        var path = context.Full(Required(argv, "--file"));
        var repository = JsonFile.Read<ControlRepositoryDocument>(path);
        var issues = ControlRepositoryValidator.Validate(repository);
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            isValid = issues.Count == 0,
            repository.RepositoryId,
            repository.Status,
            entryCount = repository.Entries.Length,
            approvedEntryCount = repository.Entries.Count(x => x.Status == ControlRepositoryEntryStatus.Approved),
            issues
        }, JsonDefaults.Options));
        return issues.Count == 0 ? 0 : 3;
    }

    // read-only capture를 사람이 검토할 ReviewRequired payload로 변환한다. 승인 상태와 승인 해시는 만들지 않는다.
    internal static int CreateControlRepositoryReview(CliCommandContext context, string[] argv)
    {
        var capturePath = context.Full(Required(argv, "--capture"));
        var capture = JsonFile.Read<ControlCaptureCandidate>(capturePath);
        if (capture.Status is ControlRepositoryEntryStatus.Approved)
            throw new InvalidDataException("capture 입력은 Approved일 수 없습니다.");
        if (capture.CursorMoved || capture.ClickSent || capture.AutomaticallyApproved)
            throw new InvalidDataException("capture 입력은 cursor 이동, click 또는 자동 승인을 포함할 수 없습니다.");
        if (capture.WindowWidth <= 0 || capture.WindowHeight <= 0 ||
            capture.ClientWidth <= 0 || capture.ClientHeight <= 0 || capture.DpiScale <= 0 ||
            capture.RelativeX < 0 || capture.RelativeX > 1 || capture.RelativeY < 0 || capture.RelativeY > 1)
            throw new InvalidDataException("capture의 client geometry 또는 normalized point가 유효하지 않습니다.");
        if (capture.RedactionsApplied.Length == 0)
            throw new InvalidDataException("capture 입력에는 저장 전 redaction 증거가 필요합니다.");

        if (!Enum.TryParse<ControlRiskClass>(Required(argv, "--risk-class"), true, out var riskClass))
            throw new ArgumentException("--risk-class 값이 유효하지 않습니다.");
        var allowedActions = Required(argv, "--allowed-actions").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Select(value => Enum.TryParse<ControlRepositoryAction>(value, true, out var parsed)
                ? parsed : throw new ArgumentException($"지원하지 않는 allowed action: {value}"))
            .Distinct().ToArray();
        if (allowedActions.Length == 0) throw new ArgumentException("--allowed-actions에는 하나 이상의 action이 필요합니다.");
        var prohibitedCoordinateActions = new[] { ControlRepositoryAction.FinalSubmit, ControlRepositoryAction.AmendSubmit, ControlRepositoryAction.CancelSubmit };
        if (allowedActions.Intersect(prohibitedCoordinateActions).Any())
            throw new ArgumentException("상대좌표 검토 payload에는 final submit, amend submit, cancel submit action을 넣을 수 없습니다.");

        var screen = Required(argv, "--screen");
        var map = GetOpt(argv, "--map", capture.MapScreenCode);
        var state = Required(argv, "--state-context");
        if (!string.IsNullOrWhiteSpace(capture.StateContext) && !capture.StateContext.Equals(state, StringComparison.Ordinal))
            throw new InvalidDataException("사람이 확인한 stateContext가 capture 문맥과 다릅니다.");

        var anchor = Required(argv, "--anchor");
        if (!capture.RedactedIdentityCandidates.Contains(anchor, StringComparer.Ordinal))
            throw new InvalidDataException("선택한 anchor가 capture 시점의 redacted UIA/host 후보에 없습니다.");

        var entry = new ControlRepositoryEntry
        {
            Key = new() { Screen = screen, Map = map, LogicalName = Required(argv, "--logical-name"), StateContext = state },
            Status = ControlRepositoryEntryStatus.ReviewRequired,
            AnchoredRelativeCoordinate = new()
            {
                CoordinateSpace = capture.CoordinateSpace,
                RelativeX = capture.RelativeX,
                RelativeY = capture.RelativeY,
                AnchorId = anchor
            },
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
            ExpectedControlKind = capture.ExpectedControlKindCandidate,
            VisualSignature = new() { Algorithm = "sha256-redacted-identity-geometry", SignatureHash = capture.VisualSignatureHash, MinimumSimilarity = 1.0 },
            RiskClass = riskClass,
            AllowedActions = allowedActions,
            ForbiddenActions = [ControlRepositoryAction.FinalSubmit, ControlRepositoryAction.AmendSubmit, ControlRepositoryAction.CancelSubmit],
            CreatedAt = DateTimeOffset.Now,
            Source = GetOpt(argv, "--source", $"capture:{Path.GetFileName(capturePath)}"),
            EvidenceRefs = GetOpt(argv, "--evidence", "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
        };
        var outPath = context.Full(GetOpt(argv, "--out", Path.ChangeExtension(capturePath, ".review.json")));
        if (File.Exists(outPath)) throw new IOException($"검토 payload가 이미 존재합니다: {outPath}");
        JsonFile.Write(outPath, entry);
        Console.WriteLine(outPath);
        return 0;
    }

    // 기존 TestPack approval overlay 형식으로 PendingApproval template만 만들며 승인자를 대신하지 않는다.
    internal static int CreateControlRepositoryApproval(CliCommandContext context, string[] argv)
    {
        var reviewPath = context.Full(Required(argv, "--review"));
        var review = JsonFile.Read<ControlRepositoryEntry>(reviewPath);
        var overlay = ControlRepositoryApprovalWorkflow.CreateTemplate(review);
        var outPath = context.Full(GetOpt(argv, "--out", Path.ChangeExtension(reviewPath, ".approval.json")));
        if (File.Exists(outPath)) throw new IOException($"승인 template이 이미 존재합니다: {outPath}");
        JsonFile.Write(outPath, overlay);
        Console.WriteLine(outPath);
        return 0;
    }

    // 사람이 명시적으로 편집한 기존 approval overlay를 hash 검증한 뒤 적용한다.
    internal static int ApplyControlRepositoryApproval(CliCommandContext context, string[] argv)
    {
        var reviewPath = context.Full(Required(argv, "--review"));
        var review = JsonFile.Read<ControlRepositoryEntry>(reviewPath);
        var overlay = JsonFile.Read<TestPackApprovalOverlay>(context.Full(Required(argv, "--approval")));
        var entry = ControlRepositoryApprovalWorkflow.Apply(review, overlay);
        var outPath = context.Full(GetOpt(argv, "--out", Path.ChangeExtension(reviewPath, ".decision.json")));
        if (File.Exists(outPath)) throw new IOException($"승인 결과가 이미 존재합니다: {outPath}");
        JsonFile.Write(outPath, entry);
        Console.WriteLine(outPath);
        return entry.Status == ControlRepositoryEntryStatus.Approved ? 0 : 3;
    }

    // Core resolver의 canonical 결과를 직렬화하며 physical action이나 verdict를 수행하지 않는다.
    internal static int ResolveControlRepository(CliCommandContext context, string[] argv)
    {
        var repository = JsonFile.Read<ControlRepositoryDocument>(context.Full(Required(argv, "--repository")));
        var request = JsonFile.Read<ControlRepositoryResolutionRequest>(context.Full(Required(argv, "--request")));
        var result = ControlRepositoryResolver.Resolve(repository, request);
        var outValue = GetOpt(argv, "--out", "");
        if (string.IsNullOrWhiteSpace(outValue)) Console.WriteLine(JsonSerializer.Serialize(result, JsonDefaults.Options));
        else
        {
            var outPath = context.Full(outValue);
            JsonFile.Write(outPath, result);
            Console.WriteLine(outPath);
        }
        return result.Status == ControlRepositoryResolutionStatus.Resolved ? 0 : 3;
    }
}
