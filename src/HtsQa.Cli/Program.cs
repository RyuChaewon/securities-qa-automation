// 역할: 데이터셋 검증, MAP 추출, 시나리오 생성·승인·컴파일·바인딩 명령을 노출하는 CLI 호스트다.
// 입력/출력: 명령행 인수와 JSON 파일을 받아 다음 파이프라인 단계가 소비할 JSON을 표준 출력 또는 파일로 만든다.
// 경계: 실제 HTS 조작과 녹화는 PowerShell 실행기가 담당하므로 이 파일에 UI 입력 코드를 추가하지 않는다.
// 수정 지점: 새 명령은 help, switch 분기, 전용 처리 함수와 docs/PROJECT_STRUCTURE.md를 함께 갱신한다.
using System.Text.Json;
using HtsQa.Core;

var root = FindRoot();
var command = args.FirstOrDefault()?.ToLowerInvariant() ?? "help";

try
{
    return command switch
    {
        "help" => Help(),
        "validate-rule-dataset" => ValidateRuleDataset(Required(args, "--file")),
        "expand-rule-cases" => ExpandRuleCases(args),
        "run-rule-dataset" => RunRuleDataset(args),
        "extract-map-models" => ExtractMapModels(args),
        "generate-rule-scenarios" => GenerateRuleScenarios(args),
        "create-rule-scenario-approval" => CreateRuleScenarioApproval(args),
        "validate-generated-scenarios" => ValidateGeneratedScenarios(args),
        "import-generated-scenarios" => ImportGeneratedScenarios(args),
        "create-scenario-approval" => CreateScenarioApproval(args),
        "compile-scenarios" => CompileScenarios(args),
        "plan-scenarios" => PlanScenarios(args),
        "materialize-scenario-bindings" => MaterializeScenarioBindings(args),
        "build-physical-scenario-plan" => BuildPhysicalScenarioPlan(args),
        "analyze-run" => AnalyzeRun(GetOpt(args, "--run", "")),
        _ => Unknown($"알 수 없는 명령: {command}")
    };
}
catch (Exception ex)
{
    Console.Error.WriteLine($"오류: {ex.Message}");
    return 2;
}

int Help()
{
    Console.WriteLine("""
    HtsQa.Cli 명령:
      validate-rule-dataset --file PATH
      expand-rule-cases --file PATH [--out PATH]
      run-rule-dataset --file PATH --dry-run [--report-dir PATH]
      extract-map-models --screen-dir PATH --screens ID1,ID2 [--installation-root PATH] [--file-pattern PATTERN] [--out PATH]
      generate-rule-scenarios --map PATH --dataset PATH [--control-plan PATH] [--reference-date yyyyMMdd] [--max-options N] [--out PATH]
      create-rule-scenario-approval --file PATH [--out PATH]
      validate-generated-scenarios --file PATH --dataset PATH [--out PATH]
      import-generated-scenarios --file PATH --dataset PATH [--out-dir PATH]
      create-scenario-approval --file PATH [--out PATH]
      compile-scenarios --file PATH --dataset PATH [--approval PATH] [--max-cases N] [--out PATH]
      plan-scenarios --file PATH --dataset PATH [--approval PATH] [--max-cases N] [--report-dir PATH]
      materialize-scenario-bindings --plan PATH --control-plan PATH --runtime-fingerprint HASH --out PATH
      build-physical-scenario-plan --plan PATH --bindings PATH --out PATH
      analyze-run --run REPORT_DIR

    실제 HTS 실행과 녹화는 scripts/run-target-rule-suite-recorded.ps1을 사용합니다.
    """);
    return 0;
}

// MAP·데이터셋·선택적 런타임 계획을 읽어 결정론적 시나리오 원본을 생성하고 즉시 검증한다.
int GenerateRuleScenarios(string[] argv)
{
    var mapPath = Full(Required(argv, "--map"));
    var datasetPath = Full(Required(argv, "--dataset"));
    var catalog = JsonFile.Read<HtsMapCatalog>(mapPath);
    var dataset = LoadValidatedDataset(datasetPath);
    var controlPlanPath = GetOpt(argv, "--control-plan", "");
    RuntimeControlPlanRow[] runtimeRows = [];
    var runtimeSha = "";
    if (!string.IsNullOrWhiteSpace(controlPlanPath))
    {
        controlPlanPath = Full(controlPlanPath);
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
    var defaultPath = Path.Combine(root, "artifacts", "auto-scenarios", $"rule-scenarios-{referenceDateText}.json");
    var outPath = Full(GetOpt(argv, "--out", defaultPath));
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
int CreateRuleScenarioApproval(string[] argv)
{
    var sourcePath = Full(Required(argv, "--file"));
    var source = JsonFile.Read<GeneratedScenarioDocument>(sourcePath);
    var sourceSha = JsonFile.Sha256Bytes(sourcePath);
    var defaultPath = Path.Combine(root, "data", "scenarios", "approvals", $"AUTO-{sourceSha[..12]}.approval.json");
    var outPath = Full(GetOpt(argv, "--out", defaultPath));
    var approval = new RuleScenarioAutoApprovalPolicy().Create(source, sourceSha, DateTimeOffset.Now);
    JsonFile.Write(outPath, approval);
    Console.WriteLine(outPath);
    return 0;
}

// 논리 logicalName 요구를 Plan-only에서 발견한 실제 컨트롤 후보에 결합한다.
int MaterializeScenarioBindings(string[] argv)
{
    var planPath = Full(Required(argv, "--plan"));
    var controlPlanPath = Full(Required(argv, "--control-plan"));
    var runtimeFingerprint = Required(argv, "--runtime-fingerprint");
    var outPath = Full(Required(argv, "--out"));
    var plan = JsonFile.Read<CompiledScenarioPlan>(planPath);
    var runtimeRows = JsonFile.Read<RuntimeControlPlanRow[]>(controlPlanPath);
    var catalog = new ScenarioBindingMaterializer().Materialize(plan, runtimeRows, runtimeFingerprint);
    JsonFile.Write(outPath, catalog);
    Console.WriteLine(outPath);
    return catalog.Status == "READY" ? 0 : 3;
}

// 승인 및 고신뢰 바인딩을 모두 통과한 사례만 포함하는 물리 계획을 만든다.
int BuildPhysicalScenarioPlan(string[] argv)
{
    var planPath = Full(Required(argv, "--plan"));
    var bindingsPath = Full(Required(argv, "--bindings"));
    var outPath = Full(Required(argv, "--out"));
    var plan = JsonFile.Read<CompiledScenarioPlan>(planPath);
    var bindings = JsonFile.Read<ScenarioBindingCatalog>(bindingsPath);
    var physical = new ScenarioBindingMaterializer().BuildPhysicalPlan(plan, bindings, JsonFile.Sha256Bytes(bindingsPath));
    JsonFile.Write(outPath, physical);
    Console.WriteLine(outPath);
    return physical.Status == "READY" ? 0 : physical.Status == "PARTIAL" ? 3 : 4;
}

// 외부 또는 자동 생성 시나리오의 구조와 참조 무결성을 검사한다.
int ValidateGeneratedScenarios(string[] argv)
{
    var sourcePath = Full(Required(argv, "--file"));
    var datasetPath = Full(Required(argv, "--dataset"));
    var source = JsonFile.Read<GeneratedScenarioDocument>(sourcePath);
    var dataset = LoadValidatedDataset(datasetPath);
    var report = new GeneratedScenarioValidator().Validate(source, dataset, JsonFile.Sha256Bytes(sourcePath));
    var json = JsonSerializer.Serialize(report, JsonDefaults.Options);
    var outPath = GetOpt(argv, "--out", "");
    if (string.IsNullOrWhiteSpace(outPath)) Console.WriteLine(json);
    else
    {
        outPath = Full(outPath);
        JsonFile.Write(outPath, report);
        Console.WriteLine(outPath);
    }
    return report.IsValid ? 0 : 1;
}

// 외부 생성 원본을 해시 고정 inbox에 보존하고 검증·승인 초안을 함께 생성한다.
int ImportGeneratedScenarios(string[] argv)
{
    var sourcePath = Full(Required(argv, "--file"));
    var datasetPath = Full(Required(argv, "--dataset"));
    var source = JsonFile.Read<GeneratedScenarioDocument>(sourcePath);
    var dataset = LoadValidatedDataset(datasetPath);
    var sourceSha = JsonFile.Sha256Bytes(sourcePath);
    var datasetSha = JsonFile.Sha256Bytes(datasetPath);
    var generationId = $"GEN-{sourceSha[..12]}";
    var outDir = Full(GetOpt(argv, "--out-dir", Path.Combine(root, "data", "scenarios", "inbox", generationId)));
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
int CreateScenarioApproval(string[] argv)
{
    var sourcePath = Full(Required(argv, "--file"));
    var source = JsonFile.Read<GeneratedScenarioDocument>(sourcePath);
    var sourceSha = JsonFile.Sha256Bytes(sourcePath);
    var defaultPath = Path.Combine(root, "data", "scenarios", "approvals", $"GEN-{sourceSha[..12]}.approval.json");
    var outPath = Full(GetOpt(argv, "--out", defaultPath));
    if (File.Exists(outPath)) throw new IOException($"승인 파일이 이미 존재합니다: {outPath}");
    JsonFile.Write(outPath, ScenarioPlanCompiler.CreateApprovalTemplate(source, sourceSha));
    Console.WriteLine(outPath);
    return 0;
}

// 검증·승인된 시나리오를 논리 계획 JSON 한 파일로 컴파일한다.
int CompileScenarios(string[] argv)
{
    var result = CompileScenarioPlan(argv);
    var defaultPath = Path.Combine(root, "artifacts", "plans", result.Plan.PlanId, "compiled-plan.json");
    var outPath = Full(GetOpt(argv, "--out", defaultPath));
    JsonFile.Write(outPath, result.Plan);
    Console.WriteLine(outPath);
    return 0;
}

// 실제 HTS를 건드리지 않고 컴파일 계획과 검토 요약을 계획 폴더에 기록한다.
int PlanScenarios(string[] argv)
{
    var result = CompileScenarioPlan(argv);
    var reportDir = Full(GetOpt(argv, "--report-dir", Path.Combine(root, "artifacts", "plans", result.Plan.PlanId)));
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
(CompiledScenarioPlan Plan, GeneratedScenarioDocument Source) CompileScenarioPlan(string[] argv)
{
    var sourcePath = Full(Required(argv, "--file"));
    var datasetPath = Full(Required(argv, "--dataset"));
    var source = JsonFile.Read<GeneratedScenarioDocument>(sourcePath);
    var dataset = LoadValidatedDataset(datasetPath);
    var approvalPath = GetOpt(argv, "--approval", "");
    ScenarioApprovalOverlay? approval = null;
    string? approvalSha = null;
    if (!string.IsNullOrWhiteSpace(approvalPath))
    {
        approvalPath = Full(approvalPath);
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

// 설치본 MAP과 보조 설치 자료를 구조화된 화면 카탈로그로 추출한다.
int ExtractMapModels(string[] argv)
{
    var screenDirectory = Full(Required(argv, "--screen-dir"));
    var screenNumbers = Required(argv, "--screens")
        .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    var filePattern = GetOpt(argv, "--file-pattern", "ht{screenNumber}00.map");
    var familyFiles = GetOpt(argv, "--family-files", "")
        .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    var installationRoot = GetOpt(argv, "--installation-root", "");
    if (string.IsNullOrWhiteSpace(installationRoot))
    {
        var parent = Directory.GetParent(screenDirectory)?.FullName ?? string.Empty;
        if (File.Exists(Path.Combine(parent, "screen_hts.vst"))) installationRoot = parent;
    }
    var catalog = string.IsNullOrWhiteSpace(installationRoot)
        ? familyFiles.Length > 0
            ? new HtsMapParser().ParseFamilyCatalog(screenDirectory, screenNumbers, familyFiles, filePattern)
            : new HtsMapParser().ParseCatalog(screenDirectory, screenNumbers, filePattern)
        : new HtsInstallationCatalogBuilder().Build(Full(installationRoot), screenNumbers, filePattern, familyFiles);
    var json = JsonSerializer.Serialize(catalog, JsonDefaults.Options);
    var outPath = GetOpt(argv, "--out", "");
    if (string.IsNullOrWhiteSpace(outPath))
    {
        Console.WriteLine(json);
    }
    else
    {
        outPath = Full(outPath);
        Directory.CreateDirectory(Path.GetDirectoryName(outPath)!);
        File.WriteAllText(outPath, json, new System.Text.UTF8Encoding(false));
        Console.WriteLine(outPath);
    }
    return 0;
}

// 기준 데이터셋의 형식과 예상 조합 수를 검사한다.
int ValidateRuleDataset(string file)
{
    var dataset = JsonFile.Read<RuleTestDataset>(Full(file));
    var validation = new RuleDatasetValidator().Validate(dataset);
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        validation.IsValid,
        projectedCases = validation.IsValid ? RuleCaseExpander.CountCases(dataset) : 0,
        validation.Issues
    }, JsonDefaults.Options));
    return validation.IsValid ? 0 : 1;
}

// 활성 계정·화면·명시 변수를 실제 실행 케이스 목록으로 확장한다.
int ExpandRuleCases(string[] argv)
{
    var dataset = LoadValidatedDataset(Required(argv, "--file"));
    var expanded = RuleCaseExpander.Expand(dataset).Select(RuleCaseExpander.Sanitize).ToArray();
    var defaultPath = Path.Combine(root, "reports", $"expanded-cases-{DateTimeOffset.Now:yyyyMMdd-HHmmss}.json");
    var outPath = Full(GetOpt(argv, "--out", defaultPath));
    JsonFile.Write(outPath, new
    {
        datasetId = dataset.DatasetId,
        generatedAt = DateTimeOffset.Now,
        caseCount = expanded.Length,
        cases = expanded
    });
    Console.WriteLine(outPath);
    return 0;
}

// 제품을 조작하지 않는 드라이런 결과와 기본 리포트 JSON을 생성한다.
int RunRuleDataset(string[] argv)
{
    if (!argv.Contains("--dry-run", StringComparer.OrdinalIgnoreCase))
        return Unknown("실제 실행은 scripts/run-target-rule-suite-recorded.ps1을 사용하세요.");

    var dataset = LoadValidatedDataset(Required(argv, "--file"));
    var cases = RuleCaseExpander.Expand(dataset);
    var runId = $"rule-dry-{DateTimeOffset.Now:yyyyMMdd-HHmmss-fff}";
    var reportDir = Full(GetOpt(argv, "--report-dir", Path.Combine(root, "reports", runId)));
    Directory.CreateDirectory(reportDir);
    var executor = new RuleDryRunExecutor();
    var results = cases.Select(x => executor.Execute(runId, x)).ToArray();

    JsonFile.Write(Path.Combine(reportDir, "expanded-cases.json"), new
    {
        datasetId = dataset.DatasetId,
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
        planner = "결정론적 규칙",
        note = "실제 HTS를 조작하지 않았으므로 모든 결과를 대기로 기록했습니다."
    });
    Console.WriteLine(reportDir);
    return 0;
}

// 기존 실행 폴더의 요약 JSON을 콘솔에 표시한다.
int AnalyzeRun(string run)
{
    if (string.IsNullOrWhiteSpace(run)) return Unknown("analyze-run에는 --run이 필요합니다.");
    var summaryPath = Path.Combine(Full(run), "summary.json");
    if (!File.Exists(summaryPath)) return Unknown($"summary.json을 찾을 수 없습니다: {summaryPath}");
    Console.WriteLine(File.ReadAllText(summaryPath));
    return 0;
}

// 모든 명령이 동일한 데이터셋 검증 경계를 사용하도록 로드 과정을 통합한다.
RuleTestDataset LoadValidatedDataset(string file)
{
    var dataset = JsonFile.Read<RuleTestDataset>(Full(file));
    var validation = new RuleDatasetValidator().Validate(dataset);
    if (!validation.IsValid)
        throw new InvalidDataException(string.Join(Environment.NewLine, validation.Issues.Select(x => $"{x.Code}: {x.Message}")));
    return dataset;
}

string Full(string path) => Path.IsPathRooted(path) ? Path.GetFullPath(path) : Path.GetFullPath(Path.Combine(root, path));

static string FindRoot()
{
    var dir = new DirectoryInfo(Environment.CurrentDirectory);
    while (dir is not null)
    {
        if (File.Exists(Path.Combine(dir.FullName, "HtsQaPoc.sln"))) return dir.FullName;
        dir = dir.Parent;
    }
    return Environment.CurrentDirectory;
}

static string Required(string[] argv, string name)
{
    var value = GetOpt(argv, name, "");
    if (string.IsNullOrWhiteSpace(value)) throw new ArgumentException($"{name}이 필요합니다.");
    return value;
}

static string GetOpt(string[] argv, string name, string defaultValue)
{
    for (var index = 0; index < argv.Length; index++)
    {
        if (argv[index].Equals(name, StringComparison.OrdinalIgnoreCase) && index + 1 < argv.Length) return argv[index + 1];
        if (argv[index].StartsWith(name + "=", StringComparison.OrdinalIgnoreCase)) return argv[index].Split('=', 2)[1];
    }
    return defaultValue;
}

static int Unknown(string message)
{
    Console.Error.WriteLine(message);
    return 1;
}
