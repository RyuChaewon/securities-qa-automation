// Role: owns read-only calibration session, review, registration, and finalization adapters.
// Inputs/outputs: preserves the existing CLI arguments, JSON protocol, and exit-code behavior.
// Boundary: delegates domain policy to HtsQa.Core and never starts HTS, FlaUI, or physical UI actions.
using System.Text.Json;
using HtsQa.Core;
using static HtsQa.Cli.CliArguments;

namespace HtsQa.Cli;

internal static class CalibrationCommands
{
    // 기존 FlaUI read-only capture들을 반복 관측 세션으로 묶을 뿐 UI나 repository를 변경하지 않는다.
    internal static int CreateCalibrationSession(CliCommandContext context, string[] argv)
    {
        var capturePaths = Required(argv, "--captures").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Select(context.Full).ToArray();
        if (capturePaths.Length == 0) throw new ArgumentException("--captures에는 하나 이상의 경로가 필요합니다.");
        if (capturePaths.Distinct(StringComparer.OrdinalIgnoreCase).Count() != capturePaths.Length)
            throw new ArgumentException("같은 capture 경로를 반복 관측으로 중복 사용할 수 없습니다.");
        var captures = capturePaths.Select(JsonFile.Read<ControlCaptureCandidate>).ToArray();
        var reviewer = Required(argv, "--reviewer");
        var session = OrderCalibrationSessionFactory.Create(
            Required(argv, "--session-id"),
            Required(argv, "--target-profile-id"),
            Required(argv, "--repository-id"),
            Required(argv, "--screen"),
            GetOpt(argv, "--map", ""),
            Required(argv, "--state-context"),
            captures) with { Reviewer = reviewer };
        var outPath = context.Full(GetOpt(argv, "--out", Path.Combine(context.RepositoryRoot, "artifacts", "calibration", session.SessionId, "calibration-session.json")));
        if (File.Exists(outPath)) throw new IOException($"캘리브레이션 세션이 이미 존재합니다: {outPath}");
        JsonFile.Write(outPath, session);
        Console.WriteLine(outPath);
        return 0;
    }

    internal static int ValidateCalibrationSession(CliCommandContext context, string[] argv)
    {
        var session = JsonFile.Read<OrderCalibrationSession>(context.Full(Required(argv, "--file")));
        var report = OrderCalibrationSessionAnalyzer.Analyze(session);
        WriteOptionalJson(context, argv, report);
        return report.IsValid ? 0 : 3;
    }

    // 안정된 반복 관측과 사람이 지정한 key/action/anchor로 ReviewRequired payload만 생성한다.
    internal static int CreateCalibrationReview(CliCommandContext context, string[] argv)
    {
        var sessionPath = context.Full(Required(argv, "--session"));
        var session = JsonFile.Read<OrderCalibrationSession>(sessionPath);
        if (string.IsNullOrWhiteSpace(session.Reviewer))
            throw new InvalidDataException("캘리브레이션 세션에는 reviewer가 필요합니다.");
        if (!Enum.TryParse<ControlRiskClass>(Required(argv, "--risk-class"), true, out var riskClass))
            throw new ArgumentException("--risk-class 값이 유효하지 않습니다.");
        var allowed = ParseEnumList<ControlRepositoryAction>(Required(argv, "--allowed-actions"), "--allowed-actions");
        var forbidden = ParseEnumList<ControlRepositoryAction>(GetOpt(argv, "--forbidden-actions", ""), "--forbidden-actions");
        var evidence = Required(argv, "--evidence").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        var entry = OrderCalibrationReviewFactory.Create(
            session,
            Required(argv, "--logical-name"),
            GetOpt(argv, "--anchor", ""),
            riskClass,
            allowed,
            forbidden,
            Required(argv, "--source"),
            evidence,
            DateTimeOffset.Now);
        var outPath = context.Full(GetOpt(argv, "--out", Path.ChangeExtension(sessionPath, ".review.json")));
        if (File.Exists(outPath)) throw new IOException($"검토 payload가 이미 존재합니다: {outPath}");
        JsonFile.Write(outPath, entry);
        Console.WriteLine(outPath);
        return 0;
    }

    // 승인된 entry를 새 repository 문서로만 저장하며 기존 입력 파일이나 key를 덮어쓰지 않는다.
    internal static int RegisterControlRepositoryEntry(CliCommandContext context, string[] argv)
    {
        var repository = JsonFile.Read<ControlRepositoryDocument>(context.Full(Required(argv, "--repository")));
        var entry = JsonFile.Read<ControlRepositoryEntry>(context.Full(Required(argv, "--entry")));
        var updated = ControlRepositoryRegistration.Register(repository, entry);
        var outPath = context.Full(Required(argv, "--out"));
        if (File.Exists(outPath)) throw new IOException($"출력 repository가 이미 존재합니다: {outPath}");
        JsonFile.Write(outPath, updated);
        Console.WriteLine(outPath);
        return 0;
    }

    // 명시적 등록이 끝난 entry의 canonical approval hash만 session provenance에 반영한다.
    internal static int FinalizeCalibrationSession(CliCommandContext context, string[] argv)
    {
        var session = JsonFile.Read<OrderCalibrationSession>(context.Full(Required(argv, "--session")));
        var repository = JsonFile.Read<ControlRepositoryDocument>(context.Full(Required(argv, "--repository")));
        var applied = OrderCalibrationSessionLifecycle.MarkApplied(session, repository, Required(argv, "--logical-name"));
        var outPath = context.Full(Required(argv, "--out"));
        if (File.Exists(outPath)) throw new IOException($"완료 세션이 이미 존재합니다: {outPath}");
        JsonFile.Write(outPath, applied);
        Console.WriteLine(outPath);
        return 0;
    }
}
