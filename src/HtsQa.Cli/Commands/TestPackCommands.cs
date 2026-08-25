// Role: owns TestPack compilation, approval-template, validation, and offline dry-run commands.
// Inputs/outputs: preserves the existing CLI arguments, JSON protocol, and exit-code behavior.
// Boundary: delegates domain policy to HtsQa.Core and never starts HTS, FlaUI, or physical UI actions.
using System.Text.Json;
using HtsQa.Core;
using static HtsQa.Cli.CliArguments;

namespace HtsQa.Cli;

internal static class TestPackCommands
{
    // 데이터셋을 C# 단일 조합 생성기로 확장하고 승인 정보까지 포함한 불변 TestPack을 만든다.
    internal static int CompileTestPack(CliCommandContext context, string[] argv)
    {
        var datasetPath = context.Full(Required(argv, "--dataset"));
        var dataset = DatasetCommands.LoadValidatedDataset(context, datasetPath);
        var policyText = GetOpt(argv, "--combination-policy", dataset.CombinationPolicy.ToString());
        if (!Enum.TryParse<CombinationPolicy>(policyText, ignoreCase: true, out var policy))
            throw new ArgumentException("--combination-policy는 Cartesian, Pairwise, PerControl 중 하나여야 합니다.");
        int? maxCases = null;
        var maxCasesText = GetOpt(argv, "--max-cases", "");
        if (!string.IsNullOrWhiteSpace(maxCasesText))
        {
            if (!int.TryParse(maxCasesText, out var parsed) || parsed < 1)
                throw new ArgumentException("--max-cases는 1 이상의 정수여야 합니다.");
            maxCases = parsed;
        }
        TestPackApprovalOverlay? approval = null;
        var approvalPath = GetOpt(argv, "--approval", "");
        if (!string.IsNullOrWhiteSpace(approvalPath)) approval = JsonFile.Read<TestPackApprovalOverlay>(context.Full(approvalPath));
        var testPack = new TestPackCompiler().Compile(
            dataset,
            JsonFile.Sha256Bytes(datasetPath),
            Path.GetFileName(datasetPath),
            policy,
            maxCases,
            approval);
        var defaultPath = Path.Combine(context.RepositoryRoot, "artifacts", "test-packs", testPack.TestPackId, "test-pack.json");
        var outPath = context.Full(GetOpt(argv, "--out", defaultPath));
        JsonFile.Write(outPath, testPack);
        Console.WriteLine(outPath);
        return 0;
    }

    // 컴파일 내용 해시에 결합된 승인 초안을 만든다. Approved 전환은 승인자와 시각을 명시해 사람이 수행한다.
    internal static int CreateTestPackApproval(CliCommandContext context, string[] argv)
    {
        var testPackPath = context.Full(Required(argv, "--test-pack"));
        var testPack = JsonFile.Read<RuleTestPack>(testPackPath);
        var validation = new TestPackValidator().Validate(testPack, requireApproved: false);
        if (!validation.IsValid)
            throw new InvalidDataException(string.Join(Environment.NewLine, validation.Issues.Select(x => $"{x.Code}: {x.Message}")));
        var defaultPath = Path.Combine(Path.GetDirectoryName(testPackPath)!, "approval.template.json");
        var outPath = context.Full(GetOpt(argv, "--out", defaultPath));
        if (File.Exists(outPath)) throw new IOException($"승인 파일이 이미 존재합니다: {outPath}");
        JsonFile.Write(outPath, TestPackCompiler.CreateApprovalTemplate(testPack));
        Console.WriteLine(outPath);
        return 0;
    }

    // TestPack 자체 무결성·승인을 검사하고 선택적으로 현재 Dataset 원본 해시까지 대조한다.
    internal static int ValidateTestPack(CliCommandContext context, string[] argv)
    {
        var testPackPath = context.Full(Required(argv, "--file"));
        var testPack = JsonFile.Read<RuleTestPack>(testPackPath);
        var validator = new TestPackValidator();
        var baseValidation = validator.Validate(testPack, requireApproved: true);
        var issues = baseValidation.Issues.ToList();
        var datasetPath = GetOpt(argv, "--dataset", "");
        if (!string.IsNullOrWhiteSpace(datasetPath))
        {
            datasetPath = context.Full(datasetPath);
            var currentDataset = JsonFile.Read<RuleTestDataset>(datasetPath);
            issues.AddRange(validator.ValidateSource(testPack, currentDataset, JsonFile.Sha256Bytes(datasetPath)).Issues);
        }
        var output = new ValidationResult(issues.Count == 0, issues);
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            output.IsValid,
            testPack.TestPackId,
            testPack.Approval.Status,
            testPack.CombinationPolicy,
            testPack.CaseCount,
            output.Issues
        }, JsonDefaults.Options));
        return output.IsValid ? 0 : 3;
    }

    // 승인 TestPack의 고정 케이스 배열만 읽어 제품을 조작하지 않는 드라이런 증적을 만든다.
    internal static int RunTestPack(CliCommandContext context, string[] argv)
    {
        if (!argv.Contains("--dry-run", StringComparer.OrdinalIgnoreCase))
            return CliApplication.Unknown("실제 실행은 scripts/run-target-rule-suite-recorded.ps1을 사용하세요.");

        var testPackPath = context.Full(Required(argv, "--file"));
        var testPack = JsonFile.Read<RuleTestPack>(testPackPath);
        var cases = new TestPackRunnerContract().LoadApprovedCases(testPack);
        var dataset = testPack.DatasetSnapshot;
        var runId = $"rule-dry-{DateTimeOffset.Now:yyyyMMdd-HHmmss-fff}";
        var reportDir = context.Full(GetOpt(argv, "--report-dir", Path.Combine(context.RepositoryRoot, "reports", runId)));
        Directory.CreateDirectory(reportDir);
        var executor = new RuleDryRunExecutor();
        var results = cases.Select(x => executor.Execute(runId, x)).ToArray();

        JsonFile.Write(Path.Combine(reportDir, "test-pack.json"), testPack);
        JsonFile.Write(Path.Combine(reportDir, "expanded-cases.json"), new
        {
            datasetId = dataset.DatasetId,
            testPackId = testPack.TestPackId,
            testPackContentHash = testPack.ContentHash,
            combinationPolicy = testPack.CombinationPolicy,
            generatedAt = DateTimeOffset.Now,
            caseCount = cases.Length,
            cases = cases.Select(RuleCaseExpander.Sanitize).ToArray()
        });
        JsonFile.Write(Path.Combine(reportDir, "case-results.json"), results);
        JsonFile.Write(Path.Combine(reportDir, "control-plan.json"), cases.Select(item => new
        {
            item.CaseId,
            item.ScreenNumber,
            item.ScreenName,
            status = TestStatus.PENDING,
            reason = "드라이런에서는 실제 HTS 컨트롤을 발견하지 않습니다.",
            discoveredControls = Array.Empty<object>(),
            controlTests = Array.Empty<object>()
        }).ToArray());
        JsonFile.Write(Path.Combine(reportDir, "summary.json"), new
        {
            runId,
            testPackId = testPack.TestPackId,
            testPackContentHash = testPack.ContentHash,
            datasetId = dataset.DatasetId,
            targetProfileId = dataset.TargetProfile.Id,
            targetDisplayName = dataset.TargetProfile.DisplayName,
            targetScreenIdPattern = dataset.TargetProfile.ScreenIdPattern,
            status = TestStatus.PENDING,
            total = results.Length,
            pass = 0,
            fail = 0,
            error = 0,
            pending = results.Length,
            dryRun = true,
            explicitErrorsDetected = 0,
            discoveredControls = 0,
            controlTests = 0,
            popupObservations = 0,
            finishedAt = DateTimeOffset.Now,
            executionMode = "드라이런 - 실제 HTS 조작 없음",
            inputMode = "화면 기본값 또는 데이터셋 명시 입력",
            planner = testPack.GeneratorVersion,
            note = "실제 HTS를 조작하지 않았으므로 모든 결과를 대기로 기록했습니다."
        });
        Console.WriteLine(reportDir);
        return 0;
    }
}
