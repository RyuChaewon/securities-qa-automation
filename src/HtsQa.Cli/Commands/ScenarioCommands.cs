// Role: owns generated-scenario, logical-plan, and physical-binding CLI adapters.
// Inputs/outputs: preserves the existing CLI arguments, JSON protocol, and exit-code behavior.
// Boundary: delegates domain policy to HtsQa.Core and never starts HTS, FlaUI, or physical UI actions.
using System.Text.Json;
using HtsQa.Core;
using static HtsQa.Cli.CliArguments;

namespace HtsQa.Cli;

internal static class ScenarioCommands
{
    // MAP·데이터셋·선택적 런타임 계획을 읽어 결정론적 시나리오 원본을 생성하고 즉시 검증한다.
    internal static int GenerateRuleScenarios(CliCommandContext context, string[] argv)
    {
        var mapPath = context.Full(Required(argv, "--map"));
        var datasetPath = context.Full(Required(argv, "--dataset"));
        var catalog = JsonFile.Read<HtsMapCatalog>(mapPath);
        var dataset = DatasetCommands.LoadValidatedDataset(context, datasetPath);
        var controlPlanPath = GetOpt(argv, "--control-plan", "");
        RuntimeControlPlanRow[] runtimeRows = [];
        var runtimeSha = "";
        if (!string.IsNullOrWhiteSpace(controlPlanPath))
        {
            controlPlanPath = context.Full(controlPlanPath);
            runtimeRows = JsonFile.Read<RuntimeControlPlanRow[]>(controlPlanPath);
            runtimeSha = JsonFile.Sha256Bytes(controlPlanPath);
        }
        var referenceDateText = GetOpt(argv, "--reference-date", DateOnly.FromDateTime(DateTime.Today).ToString("yyyyMMdd"));
        if (!DateOnly.TryParseExact(referenceDateText, "yyyyMMdd", out var referenceDate))
            throw new ArgumentException("--reference-date는 yyyyMMdd 형식이어야 합니다.");
        var maxOptionsText = GetOpt(argv, "--max-options", dataset.AutoExploration.MaxOptionsPerControl.ToString());
        if (!int.TryParse(maxOptionsText, out var maxOptions) || maxOptions < 1)
            throw new ArgumentException("--max-options는 1 이상의 정수여야 합니다.");

        var result = new RuleScenarioGenerator().Generate(catalog, dataset, runtimeRows, new RuleScenarioGenerationOptions
        {
            ReferenceDate = referenceDate,
            MaxOptionsPerControl = maxOptions,
            MapCatalogSha256 = JsonFile.Sha256Bytes(mapPath),
            RuntimeControlPlanSha256 = runtimeSha
        });
        var defaultPath = Path.Combine(context.RepositoryRoot, "artifacts", "auto-scenarios", $"rule-scenarios-{referenceDateText}.json");
        var outPath = context.Full(GetOpt(argv, "--out", defaultPath));
        JsonFile.Write(outPath, result.Document);
        var validation = new GeneratedScenarioValidator().Validate(result.Document, dataset, JsonFile.Sha256Bytes(outPath));
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            output = outPath,
            result.ScreenCount,
            result.ScenarioCount,
            result.VariableCount,
            result.ProjectedCasesPerAccount,
            result.CoverageGapCount,
            result.RuntimeOptionControlCount,
            validation.Status,
            validation.IsValid
        }, JsonDefaults.Options));
        return validation.IsValid ? 0 : 1;
    }

    // 자동 생성기 서명과 필수 검토 여부를 검사한 뒤 정책 승인 파일을 만든다.
    internal static int CreateRuleScenarioApproval(CliCommandContext context, string[] argv)
    {
        var sourcePath = context.Full(Required(argv, "--file"));
        var source = JsonFile.Read<GeneratedScenarioDocument>(sourcePath);
        var sourceSha = JsonFile.Sha256Bytes(sourcePath);
        var defaultPath = Path.Combine(context.RepositoryRoot, "data", "scenarios", "approvals", $"AUTO-{sourceSha[..12]}.approval.json");
        var outPath = context.Full(GetOpt(argv, "--out", defaultPath));
        var approval = new RuleScenarioAutoApprovalPolicy().Create(source, sourceSha, DateTimeOffset.Now);
        JsonFile.Write(outPath, approval);
        Console.WriteLine(outPath);
        return 0;
    }

    // 논리 logicalName 요구를 Plan-only에서 발견한 실제 컨트롤 후보에 결합한다.
    internal static int MaterializeScenarioBindings(CliCommandContext context, string[] argv)
    {
        var planPath = context.Full(Required(argv, "--plan"));
        var controlPlanPath = context.Full(Required(argv, "--control-plan"));
        var runtimeFingerprint = Required(argv, "--runtime-fingerprint");
        var outPath = context.Full(Required(argv, "--out"));
        var testPackPath = GetOpt(argv, "--test-pack", "");
        var plan = JsonFile.Read<CompiledScenarioPlan>(planPath);
        var runtimeRows = JsonFile.Read<RuntimeControlPlanRow[]>(controlPlanPath);
        var targetAdapter = string.IsNullOrWhiteSpace(testPackPath)
            ? null
            : JsonFile.Read<RuleTestPack>(context.Full(testPackPath)).DatasetSnapshot.TargetProfile.Adapter;
        var catalog = new ScenarioBindingMaterializer().Materialize(plan, runtimeRows, runtimeFingerprint, targetAdapter);
        JsonFile.Write(outPath, catalog);
        Console.WriteLine(outPath);
        return catalog.Status == "READY" ? 0 : 3;
    }

    // 승인 및 고신뢰 바인딩을 모두 통과한 사례만 포함하는 물리 계획을 만든다.
    internal static int BuildPhysicalScenarioPlan(CliCommandContext context, string[] argv)
    {
        var planPath = context.Full(Required(argv, "--plan"));
        var bindingsPath = context.Full(Required(argv, "--bindings"));
        var outPath = context.Full(Required(argv, "--out"));
        var plan = JsonFile.Read<CompiledScenarioPlan>(planPath);
        var bindings = JsonFile.Read<ScenarioBindingCatalog>(bindingsPath);
        var physical = new ScenarioBindingMaterializer().BuildPhysicalPlan(plan, bindings, JsonFile.Sha256Bytes(bindingsPath));
        JsonFile.Write(outPath, physical);
        Console.WriteLine(outPath);
        return physical.Status == "READY" ? 0 : physical.Status == "PARTIAL" ? 3 : 4;
    }

    // 외부 또는 자동 생성 시나리오의 구조와 참조 무결성을 검사한다.
    internal static int ValidateGeneratedScenarios(CliCommandContext context, string[] argv)
    {
        var sourcePath = context.Full(Required(argv, "--file"));
        var datasetPath = context.Full(Required(argv, "--dataset"));
        var source = JsonFile.Read<GeneratedScenarioDocument>(sourcePath);
        var dataset = DatasetCommands.LoadValidatedDataset(context, datasetPath);
        var report = new GeneratedScenarioValidator().Validate(source, dataset, JsonFile.Sha256Bytes(sourcePath));
        var json = JsonSerializer.Serialize(report, JsonDefaults.Options);
        var outPath = GetOpt(argv, "--out", "");
        if (string.IsNullOrWhiteSpace(outPath)) Console.WriteLine(json);
        else
        {
            outPath = context.Full(outPath);
            JsonFile.Write(outPath, report);
            Console.WriteLine(outPath);
        }
        return report.IsValid ? 0 : 1;
    }

    // 외부 생성 원본을 해시 고정 inbox에 보존하고 검증·승인 초안을 함께 생성한다.
    internal static int ImportGeneratedScenarios(CliCommandContext context, string[] argv)
    {
        var sourcePath = context.Full(Required(argv, "--file"));
        var datasetPath = context.Full(Required(argv, "--dataset"));
        var source = JsonFile.Read<GeneratedScenarioDocument>(sourcePath);
        var dataset = DatasetCommands.LoadValidatedDataset(context, datasetPath);
        var sourceSha = JsonFile.Sha256Bytes(sourcePath);
        var datasetSha = JsonFile.Sha256Bytes(datasetPath);
        var generationId = $"GEN-{sourceSha[..12]}";
        var outDir = context.Full(GetOpt(argv, "--out-dir", Path.Combine(context.RepositoryRoot, "data", "scenarios", "inbox", generationId)));
        Directory.CreateDirectory(outDir);
        var importedSource = Path.Combine(outDir, "generated-scenarios.json");
        if (File.Exists(importedSource) && !JsonFile.Sha256Bytes(importedSource).Equals(sourceSha, StringComparison.OrdinalIgnoreCase))
            throw new IOException($"동일한 수입 폴더에 다른 generated-scenarios.json이 있습니다: {outDir}");
        if (!File.Exists(importedSource)) File.Copy(sourcePath, importedSource);

        var validation = new GeneratedScenarioValidator().Validate(source, dataset, sourceSha);
        var manifest = new ScenarioImportManifest
        {
            GenerationId = generationId,
            SourceFileName = Path.GetFileName(sourcePath),
            SourceSha256 = sourceSha,
            SourceInstallationFingerprint = source.SourceInstallationFingerprint,
            DatasetId = dataset.DatasetId,
            DatasetSha256 = datasetSha,
            ValidationStatus = validation.Status,
            ImportedAt = DateTimeOffset.Now
        };
        JsonFile.Write(Path.Combine(outDir, "import-manifest.json"), manifest);
        JsonFile.Write(Path.Combine(outDir, "validation.json"), validation);
        var approvalPath = Path.Combine(outDir, "approval.template.json");
        if (!File.Exists(approvalPath))
            JsonFile.Write(approvalPath, ScenarioPlanCompiler.CreateApprovalTemplate(source, sourceSha));
        Console.WriteLine(outDir);
        return validation.IsValid ? 0 : 1;
    }

    // 사람이 작성할 외부 시나리오 승인 오버레이 초안을 생성한다.
    internal static int CreateScenarioApproval(CliCommandContext context, string[] argv)
    {
        var sourcePath = context.Full(Required(argv, "--file"));
        var source = JsonFile.Read<GeneratedScenarioDocument>(sourcePath);
        var sourceSha = JsonFile.Sha256Bytes(sourcePath);
        var defaultPath = Path.Combine(context.RepositoryRoot, "data", "scenarios", "approvals", $"GEN-{sourceSha[..12]}.approval.json");
        var outPath = context.Full(GetOpt(argv, "--out", defaultPath));
        if (File.Exists(outPath)) throw new IOException($"승인 파일이 이미 존재합니다: {outPath}");
        JsonFile.Write(outPath, ScenarioPlanCompiler.CreateApprovalTemplate(source, sourceSha));
        Console.WriteLine(outPath);
        return 0;
    }

    // 검증·승인된 시나리오를 논리 계획 JSON 한 파일로 컴파일한다.
    internal static int CompileScenarios(CliCommandContext context, string[] argv)
    {
        var result = CompileScenarioPlan(context, argv);
        var defaultPath = Path.Combine(context.RepositoryRoot, "artifacts", "plans", result.Plan.PlanId, "compiled-plan.json");
        var outPath = context.Full(GetOpt(argv, "--out", defaultPath));
        JsonFile.Write(outPath, result.Plan);
        Console.WriteLine(outPath);
        return 0;
    }

    // 실제 HTS를 건드리지 않고 컴파일 계획과 검토 요약을 계획 폴더에 기록한다.
    internal static int PlanScenarios(CliCommandContext context, string[] argv)
    {
        var result = CompileScenarioPlan(context, argv);
        var reportDir = context.Full(GetOpt(argv, "--report-dir", Path.Combine(context.RepositoryRoot, "artifacts", "plans", result.Plan.PlanId)));
        Directory.CreateDirectory(reportDir);
        JsonFile.Write(Path.Combine(reportDir, "compiled-plan.json"), result.Plan);
        JsonFile.Write(Path.Combine(reportDir, "plan-summary.json"), new
        {
            mode = "StaticPlanOnly",
            result.Plan.PlanId,
            result.Plan.PlanHash,
            result.Plan.Status,
            result.Plan.DatasetId,
            result.Plan.SourceInstallationFingerprint,
            result.Plan.ApprovalStatus,
            result.Plan.ApprovedBy,
            result.Plan.ApprovedAt,
            result.Plan.ReviewDecisionCount,
            result.Plan.ScenarioDecisionCount,
            result.Plan.CoverageGapDecisionCount,
            result.Plan.ScreenCount,
            result.Plan.ScenarioCount,
            result.Plan.CaseCount,
            result.Plan.StepCount,
            result.Plan.ReadyScenarioCount,
            result.Plan.PendingApprovalScenarioCount,
            result.Plan.PendingBindingScenarioCount,
            result.Plan.ManualReviewScenarioCount,
            result.Plan.UnusedVariableCount,
            actualHtsManipulated = false,
            testOutcome = TestStatus.PENDING,
            note = "정적 계획 검증만 수행했으며 HTS 화면을 열거나 조작하지 않았습니다.",
            generatedAt = DateTimeOffset.Now
        });
        JsonFile.Write(Path.Combine(reportDir, "scenario-review-items.json"), result.Source.ReviewItems.Select(item => new
        {
            reviewId = ScenarioPlanCompiler.ReviewId(item),
            item.Severity,
            item.ScreenNumber,
            item.Subject,
            item.Question,
            item.Reason
        }).ToArray());
        Console.WriteLine(reportDir);
        return 0;
    }

    // compile-scenarios와 plan-scenarios가 공유하는 입력 로드·승인 적용 경로다.
    private static (CompiledScenarioPlan Plan, GeneratedScenarioDocument Source) CompileScenarioPlan(CliCommandContext context, string[] argv)
    {
        var sourcePath = context.Full(Required(argv, "--file"));
        var datasetPath = context.Full(Required(argv, "--dataset"));
        var source = JsonFile.Read<GeneratedScenarioDocument>(sourcePath);
        var dataset = DatasetCommands.LoadValidatedDataset(context, datasetPath);
        var approvalPath = GetOpt(argv, "--approval", "");
        ScenarioApprovalOverlay? approval = null;
        string? approvalSha = null;
        if (!string.IsNullOrWhiteSpace(approvalPath))
        {
            approvalPath = context.Full(approvalPath);
            approval = JsonFile.Read<ScenarioApprovalOverlay>(approvalPath);
            approvalSha = JsonFile.Sha256Bytes(approvalPath);
        }
        int? maxCases = null;
        var maxCasesText = GetOpt(argv, "--max-cases", "");
        if (!string.IsNullOrWhiteSpace(maxCasesText))
        {
            if (!int.TryParse(maxCasesText, out var parsed) || parsed < 1) throw new ArgumentException("--max-cases는 1 이상의 정수여야 합니다.");
            maxCases = parsed;
        }
        var plan = new ScenarioPlanCompiler().Compile(
            source,
            dataset,
            JsonFile.Sha256Bytes(sourcePath),
            JsonFile.Sha256Bytes(datasetPath),
            approval,
            approvalSha,
            maxCases);
        return (plan, source);
    }
}
