// 역할: 데이터셋 검증, TestPack 컴파일·승인, MAP 추출, 시나리오 생성·컴파일·바인딩 명령을 노출하는 CLI 호스트다.
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
        "compile-test-pack" => CompileTestPack(args),
        "create-test-pack-approval" => CreateTestPackApproval(args),
        "validate-test-pack" => ValidateTestPack(args),
        "run-test-pack" => RunTestPack(args),
        "extract-map-models" => ExtractMapModels(args),
        "generate-rule-scenarios" => GenerateRuleScenarios(args),
        "create-rule-scenario-approval" => CreateRuleScenarioApproval(args),
        "validate-generated-scenarios" => ValidateGeneratedScenarios(args),
        "import-generated-scenarios" => ImportGeneratedScenarios(args),
        "create-scenario-approval" => CreateScenarioApproval(args),
        "compile-scenarios" => CompileScenarios(args),
        "plan-scenarios" => PlanScenarios(args),
        "validate-control-repository" => ValidateControlRepository(args),
        "create-control-repository-approval" => CreateControlRepositoryApproval(args),
        "apply-control-repository-approval" => ApplyControlRepositoryApproval(args),
        "create-control-repository-review" => CreateControlRepositoryReview(args),
        "resolve-control-repository" => ResolveControlRepository(args),
        "create-calibration-session" => CreateCalibrationSession(args),
        "validate-calibration-session" => ValidateCalibrationSession(args),
        "create-calibration-review" => CreateCalibrationReview(args),
        "register-control-repository-entry" => RegisterControlRepositoryEntry(args),
        "finalize-calibration-session" => FinalizeCalibrationSession(args),
        "validate-order-scenario" => ValidateOrderScenario(args),
        "compile-order-scenario" => CompileOrderScenario(args),
        "dry-run-order-scenario" => DryRunOrderScenario(args),
        "materialize-scenario-bindings" => MaterializeScenarioBindings(args),
        "build-physical-scenario-plan" => BuildPhysicalScenarioPlan(args),
        "evaluate-results" => EvaluateResults(args),
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
      compile-test-pack --dataset PATH [--combination-policy Cartesian|Pairwise|PerControl] [--max-cases N] [--approval PATH] [--out PATH]
      create-test-pack-approval --test-pack PATH [--out PATH]
      validate-test-pack --file PATH [--dataset PATH]
      run-test-pack --file PATH --dry-run [--report-dir PATH]
      run-rule-dataset (지원 종료: compile-test-pack + run-test-pack 사용)
      extract-map-models --screen-dir PATH --screens ID1,ID2 [--installation-root PATH] [--file-pattern PATTERN] [--out PATH]
      generate-rule-scenarios --map PATH --dataset PATH [--control-plan PATH] [--reference-date yyyyMMdd] [--max-options N] [--out PATH]
      create-rule-scenario-approval --file PATH [--out PATH]
      validate-generated-scenarios --file PATH --dataset PATH [--out PATH]
      import-generated-scenarios --file PATH --dataset PATH [--out-dir PATH]
      create-scenario-approval --file PATH [--out PATH]
      compile-scenarios --file PATH --dataset PATH [--approval PATH] [--max-cases N] [--out PATH]
      plan-scenarios --file PATH --dataset PATH [--approval PATH] [--max-cases N] [--report-dir PATH]
      materialize-scenario-bindings --plan PATH --control-plan PATH --runtime-fingerprint HASH --out PATH
      create-control-repository-approval --review PATH [--out PATH]
      apply-control-repository-approval --review PATH --approval PATH [--out PATH]
      validate-control-repository --file PATH
      create-control-repository-review --capture PATH --screen ID --logical-name NAME --state-context CONTEXT --risk-class CLASS --allowed-actions A,B --anchor ID [--map ID] [--source REF] [--evidence REF1,REF2] [--out PATH]
      resolve-control-repository --repository PATH --request PATH [--out PATH]
      create-calibration-session --captures PATH1,PATH2 --session-id ID --target-profile-id ID --repository-id ID --screen ID --state-context CONTEXT --reviewer NAME [--map ID] [--out PATH]
      validate-calibration-session --file PATH [--out PATH]
      create-calibration-review --session PATH --logical-name NAME --risk-class CLASS --allowed-actions A,B --forbidden-actions A,B --source REF --evidence REF1,REF2 [--anchor ID] [--out PATH]
      register-control-repository-entry --repository PATH --entry PATH --out PATH
      finalize-calibration-session --session PATH --repository PATH --logical-name NAME --out PATH
      validate-order-scenario --input PATH [--out PATH]
      compile-order-scenario --input PATH --out PATH [--compiled-at ISO8601]
      dry-run-order-scenario --plan PATH [--out PATH]
      build-physical-scenario-plan --plan PATH --bindings PATH --out PATH
      evaluate-results --test-pack PATH --observations PATH --output PATH
      analyze-run --run REPORT_DIR

    실제 HTS 실행과 녹화는 scripts/run-target-rule-suite-recorded.ps1을 사용합니다.
    """);
    return 0;
}
// repository 구조·중복 key·승인 해시를 Core 단일 validator로 검사하며 UI를 열거나 수정하지 않는다.
int ValidateControlRepository(string[] argv)
{
    var path = Full(Required(argv, "--file"));
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
int CreateControlRepositoryReview(string[] argv)
{
    var capturePath = Full(Required(argv, "--capture"));
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
    var outPath = Full(GetOpt(argv, "--out", Path.ChangeExtension(capturePath, ".review.json")));
    if (File.Exists(outPath)) throw new IOException($"검토 payload가 이미 존재합니다: {outPath}");
    JsonFile.Write(outPath, entry);
    Console.WriteLine(outPath);
    return 0;
}

// 기존 TestPack approval overlay 형식으로 PendingApproval template만 만들며 승인자를 대신하지 않는다.
int CreateControlRepositoryApproval(string[] argv)
{
    var reviewPath = Full(Required(argv, "--review"));
    var review = JsonFile.Read<ControlRepositoryEntry>(reviewPath);
    var overlay = ControlRepositoryApprovalWorkflow.CreateTemplate(review);
    var outPath = Full(GetOpt(argv, "--out", Path.ChangeExtension(reviewPath, ".approval.json")));
    if (File.Exists(outPath)) throw new IOException($"승인 template이 이미 존재합니다: {outPath}");
    JsonFile.Write(outPath, overlay);
    Console.WriteLine(outPath);
    return 0;
}

// 사람이 명시적으로 편집한 기존 approval overlay를 hash 검증한 뒤 적용한다.
int ApplyControlRepositoryApproval(string[] argv)
{
    var reviewPath = Full(Required(argv, "--review"));
    var review = JsonFile.Read<ControlRepositoryEntry>(reviewPath);
    var overlay = JsonFile.Read<TestPackApprovalOverlay>(Full(Required(argv, "--approval")));
    var entry = ControlRepositoryApprovalWorkflow.Apply(review, overlay);
    var outPath = Full(GetOpt(argv, "--out", Path.ChangeExtension(reviewPath, ".decision.json")));
    if (File.Exists(outPath)) throw new IOException($"승인 결과가 이미 존재합니다: {outPath}");
    JsonFile.Write(outPath, entry);
    Console.WriteLine(outPath);
    return entry.Status == ControlRepositoryEntryStatus.Approved ? 0 : 3;
}

// Core resolver의 canonical 결과를 직렬화하며 physical action이나 verdict를 수행하지 않는다.
int ResolveControlRepository(string[] argv)
{
    var repository = JsonFile.Read<ControlRepositoryDocument>(Full(Required(argv, "--repository")));
    var request = JsonFile.Read<ControlRepositoryResolutionRequest>(Full(Required(argv, "--request")));
    var result = ControlRepositoryResolver.Resolve(repository, request);
    var outValue = GetOpt(argv, "--out", "");
    if (string.IsNullOrWhiteSpace(outValue)) Console.WriteLine(JsonSerializer.Serialize(result, JsonDefaults.Options));
    else
    {
        var outPath = Full(outValue);
        JsonFile.Write(outPath, result);
        Console.WriteLine(outPath);
    }
    return result.Status == ControlRepositoryResolutionStatus.Resolved ? 0 : 3;
}

// 기존 FlaUI read-only capture들을 반복 관측 세션으로 묶을 뿐 UI나 repository를 변경하지 않는다.
int CreateCalibrationSession(string[] argv)
{
    var capturePaths = Required(argv, "--captures").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
        .Select(Full).ToArray();
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
    var outPath = Full(GetOpt(argv, "--out", Path.Combine(root, "artifacts", "calibration", session.SessionId, "calibration-session.json")));
    if (File.Exists(outPath)) throw new IOException($"캘리브레이션 세션이 이미 존재합니다: {outPath}");
    JsonFile.Write(outPath, session);
    Console.WriteLine(outPath);
    return 0;
}

int ValidateCalibrationSession(string[] argv)
{
    var session = JsonFile.Read<OrderCalibrationSession>(Full(Required(argv, "--file")));
    var report = OrderCalibrationSessionAnalyzer.Analyze(session);
    WriteOptionalJson(argv, report);
    return report.IsValid ? 0 : 3;
}

// 안정된 반복 관측과 사람이 지정한 key/action/anchor로 ReviewRequired payload만 생성한다.
int CreateCalibrationReview(string[] argv)
{
    var sessionPath = Full(Required(argv, "--session"));
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
    var outPath = Full(GetOpt(argv, "--out", Path.ChangeExtension(sessionPath, ".review.json")));
    if (File.Exists(outPath)) throw new IOException($"검토 payload가 이미 존재합니다: {outPath}");
    JsonFile.Write(outPath, entry);
    Console.WriteLine(outPath);
    return 0;
}

// 승인된 entry를 새 repository 문서로만 저장하며 기존 입력 파일이나 key를 덮어쓰지 않는다.
int RegisterControlRepositoryEntry(string[] argv)
{
    var repository = JsonFile.Read<ControlRepositoryDocument>(Full(Required(argv, "--repository")));
    var entry = JsonFile.Read<ControlRepositoryEntry>(Full(Required(argv, "--entry")));
    var updated = ControlRepositoryRegistration.Register(repository, entry);
    var outPath = Full(Required(argv, "--out"));
    if (File.Exists(outPath)) throw new IOException($"출력 repository가 이미 존재합니다: {outPath}");
    JsonFile.Write(outPath, updated);
    Console.WriteLine(outPath);
    return 0;
}

// 명시적 등록이 끝난 entry의 canonical approval hash만 session provenance에 반영한다.
int FinalizeCalibrationSession(string[] argv)
{
    var session = JsonFile.Read<OrderCalibrationSession>(Full(Required(argv, "--session")));
    var repository = JsonFile.Read<ControlRepositoryDocument>(Full(Required(argv, "--repository")));
    var applied = OrderCalibrationSessionLifecycle.MarkApplied(session, repository, Required(argv, "--logical-name"));
    var outPath = Full(Required(argv, "--out"));
    if (File.Exists(outPath)) throw new IOException($"완료 세션이 이미 존재합니다: {outPath}");
    JsonFile.Write(outPath, applied);
    Console.WriteLine(outPath);
    return 0;
}

// Core 정적 validator 결과를 그대로 직렬화하며 판정이나 UI 실행을 하지 않는다.
int ValidateOrderScenario(string[] argv)
{
    var input = JsonFile.Read<OrderScenarioValidationInput>(Full(Required(argv, "--input")));
    var report = OrderScenarioValidator.Validate(input);
    WriteOptionalJson(argv, report);
    return report.IsValid ? 0 : 3;
}

// 정적 검증을 통과한 입력만 hash로 고정된 DryRun 계획으로 컴파일한다.
int CompileOrderScenario(string[] argv)
{
    var input = JsonFile.Read<OrderScenarioValidationInput>(Full(Required(argv, "--input")));
    var atText = GetOpt(argv, "--compiled-at", "");
    var compiledAt = string.IsNullOrWhiteSpace(atText)
        ? DateTimeOffset.Now
        : DateTimeOffset.TryParse(atText, out var parsed) ? parsed : throw new ArgumentException("--compiled-at은 ISO8601 시각이어야 합니다.");
    var result = OrderScenarioRunPlanCompiler.Compile(input, compiledAt);
    if (!result.Validation.IsValid || result.Plan is null)
    {
        Console.WriteLine(JsonSerializer.Serialize(result.Validation, JsonDefaults.Options));
        return 3;
    }
    var outPath = Full(Required(argv, "--out"));
    if (File.Exists(outPath)) throw new IOException($"컴파일 출력이 이미 존재합니다: {outPath}");
    JsonFile.Write(outPath, result.Plan);
    Console.WriteLine(outPath);
    return 0;
}

// 계획 무결성과 계약만 확인하며 실제 UI Action과 transactional Action을 모두 0으로 유지한다.
int DryRunOrderScenario(string[] argv)
{
    var plan = JsonFile.Read<OrderScenarioRunPlan>(Full(Required(argv, "--plan")));
    var result = OrderScenarioDryRun.Execute(plan);
    WriteOptionalJson(argv, result);
    var checks = new[]
    {
        result.PlanHashValid, result.RepositoryResolutionChecked, result.StateOrderChecked,
        result.RequiredCheckpointChecked, result.ExpectedOutcomeChecked, result.VariableBindingChecked,
        result.RiskPolicyChecked, result.RestorePlanChecked, result.ResultAndEvidenceSchemaChecked,
        result.ActualUiActionCount == 0, result.TransactionalActionCount == 0
    };
    return checks.All(x => x) ? 0 : 3;
}

void WriteOptionalJson<T>(string[] argv, T value)
{
    var outValue = GetOpt(argv, "--out", "");
    if (string.IsNullOrWhiteSpace(outValue)) Console.WriteLine(JsonSerializer.Serialize(value, JsonDefaults.Options));
    else
    {
        var outPath = Full(outValue);
        if (File.Exists(outPath)) throw new IOException($"출력 파일이 이미 존재합니다: {outPath}");
        JsonFile.Write(outPath, value);
        Console.WriteLine(outPath);
    }
}

T[] ParseEnumList<T>(string value, string option) where T : struct, Enum =>
    value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
        .Select(item => Enum.TryParse<T>(item, true, out var parsed)
            ? parsed
            : throw new ArgumentException($"{option}에 지원하지 않는 값이 있습니다: {item}"))
        .Distinct().ToArray();


// TestPack과 원시 Observation 파일을 읽고 순수 ResultEvaluator가 만든 완성 TestResult만 출력한다.
int EvaluateResults(string[] argv)
{
    var testPackPath = Full(Required(argv, "--test-pack"));
    var observationsPath = Full(Required(argv, "--observations"));
    var outputPath = Full(Required(argv, "--output"));
    if (!File.Exists(testPackPath)) throw new FileNotFoundException("TestPack 파일을 찾을 수 없습니다.", testPackPath);
    if (!File.Exists(observationsPath)) throw new FileNotFoundException("Observation 파일을 찾을 수 없습니다.", observationsPath);

    var input = JsonFile.Read<ResultEvaluationDocument>(observationsPath);
    var evaluator = new ResultEvaluator();
    var results = input.Cases.Select(evaluator.Evaluate).Concat(input.CompletedResults).ToArray();
    var testPackId = string.IsNullOrWhiteSpace(input.TestPackId)
        ? Path.GetFileNameWithoutExtension(testPackPath)
        : input.TestPackId;
    var output = new TestResultDocument
    {
        TestPackId = testPackId,
        TestPackSha256 = JsonFile.Sha256Bytes(testPackPath),
        Results = results,
        Summary = evaluator.Summarize(results),
        OverallResult = evaluator.Aggregate(string.IsNullOrWhiteSpace(input.AggregateId) ? testPackId : input.AggregateId, results)
    };
    JsonFile.Write(outputPath, output);
    Console.WriteLine(outputPath);
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
    var testPackPath = GetOpt(argv, "--test-pack", "");
    var plan = JsonFile.Read<CompiledScenarioPlan>(planPath);
    var runtimeRows = JsonFile.Read<RuntimeControlPlanRow[]>(controlPlanPath);
    var targetAdapter = string.IsNullOrWhiteSpace(testPackPath)
        ? null
        : JsonFile.Read<RuleTestPack>(Full(testPackPath)).DatasetSnapshot.TargetProfile.Adapter;
    var catalog = new ScenarioBindingMaterializer().Materialize(plan, runtimeRows, runtimeFingerprint, targetAdapter);
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
        combinationPolicy = dataset.CombinationPolicy,
        projectedCases = validation.IsValid ? new CombinationGenerator().CountCases(dataset) : 0,
        validation.Issues
    }, JsonDefaults.Options));
    return validation.IsValid ? 0 : 1;
}

// 활성 계정·화면·명시 변수를 실제 실행 케이스 목록으로 확장한다.
int ExpandRuleCases(string[] argv)
{
    var dataset = LoadValidatedDataset(Required(argv, "--file"));
    var expanded = new CombinationGenerator().Generate(dataset).Select(RuleCaseExpander.Sanitize).ToArray();
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
    return Unknown("run-rule-dataset은 승인되지 않은 Dataset 직접 실행을 막기 위해 지원 종료되었습니다. compile-test-pack 후 run-test-pack을 사용하세요.");
}

// 데이터셋을 C# 단일 조합 생성기로 확장하고 승인 정보까지 포함한 불변 TestPack을 만든다.
int CompileTestPack(string[] argv)
{
    var datasetPath = Full(Required(argv, "--dataset"));
    var dataset = LoadValidatedDataset(datasetPath);
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
    if (!string.IsNullOrWhiteSpace(approvalPath)) approval = JsonFile.Read<TestPackApprovalOverlay>(Full(approvalPath));
    var testPack = new TestPackCompiler().Compile(
        dataset,
        JsonFile.Sha256Bytes(datasetPath),
        Path.GetFileName(datasetPath),
        policy,
        maxCases,
        approval);
    var defaultPath = Path.Combine(root, "artifacts", "test-packs", testPack.TestPackId, "test-pack.json");
    var outPath = Full(GetOpt(argv, "--out", defaultPath));
    JsonFile.Write(outPath, testPack);
    Console.WriteLine(outPath);
    return 0;
}

// 컴파일 내용 해시에 결합된 승인 초안을 만든다. Approved 전환은 승인자와 시각을 명시해 사람이 수행한다.
int CreateTestPackApproval(string[] argv)
{
    var testPackPath = Full(Required(argv, "--test-pack"));
    var testPack = JsonFile.Read<RuleTestPack>(testPackPath);
    var validation = new TestPackValidator().Validate(testPack, requireApproved: false);
    if (!validation.IsValid)
        throw new InvalidDataException(string.Join(Environment.NewLine, validation.Issues.Select(x => $"{x.Code}: {x.Message}")));
    var defaultPath = Path.Combine(Path.GetDirectoryName(testPackPath)!, "approval.template.json");
    var outPath = Full(GetOpt(argv, "--out", defaultPath));
    if (File.Exists(outPath)) throw new IOException($"승인 파일이 이미 존재합니다: {outPath}");
    JsonFile.Write(outPath, TestPackCompiler.CreateApprovalTemplate(testPack));
    Console.WriteLine(outPath);
    return 0;
}

// TestPack 자체 무결성·승인을 검사하고 선택적으로 현재 Dataset 원본 해시까지 대조한다.
int ValidateTestPack(string[] argv)
{
    var testPackPath = Full(Required(argv, "--file"));
    var testPack = JsonFile.Read<RuleTestPack>(testPackPath);
    var validator = new TestPackValidator();
    var baseValidation = validator.Validate(testPack, requireApproved: true);
    var issues = baseValidation.Issues.ToList();
    var datasetPath = GetOpt(argv, "--dataset", "");
    if (!string.IsNullOrWhiteSpace(datasetPath))
    {
        datasetPath = Full(datasetPath);
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
int RunTestPack(string[] argv)
{
    if (!argv.Contains("--dry-run", StringComparer.OrdinalIgnoreCase))
        return Unknown("실제 실행은 scripts/run-target-rule-suite-recorded.ps1을 사용하세요.");

    var testPackPath = Full(Required(argv, "--file"));
    var testPack = JsonFile.Read<RuleTestPack>(testPackPath);
    var cases = new TestPackRunnerContract().LoadApprovedCases(testPack);
    var dataset = testPack.DatasetSnapshot;
    var runId = $"rule-dry-{DateTimeOffset.Now:yyyyMMdd-HHmmss-fff}";
    var reportDir = Full(GetOpt(argv, "--report-dir", Path.Combine(root, "reports", runId)));
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
