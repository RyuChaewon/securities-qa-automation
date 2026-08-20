// 역할: 데이터셋 조합, canonical CaseId, 기대 결과 해석, 불변 TestPack 컴파일과 승인 검증의 단일 구현이다.
// 입력/출력: 검증된 RuleTestDataset과 승인 오버레이를 받아 Runner가 소비할 RuleTestPack을 만든다.
// 경계: UI, 파일 시스템, Excel, PowerShell에 의존하지 않으며 원본 파일 바이트 해시는 호출자가 제공한다.
// 수정 지점: 조합 정책이나 TestPack 스키마 변경 시 CLI, Runner 계약 및 TestPack 회귀 테스트를 함께 갱신한다.
using System.Text.Json;

namespace HtsQa.Core;

public enum CombinationPolicy
{
    Cartesian,
    Pairwise,
    PerControl
}

public enum TestPackApprovalStatus
{
    PendingApproval,
    Approved,
    Rejected
}

public sealed record ResolvedExpectedResult
{
    public RuleExpectedOutcomeType Type { get; init; } = RuleExpectedOutcomeType.Unspecified;
    public string[] MessagePatterns { get; init; } = [];
    public string[] ErrorCodes { get; init; } = [];
    public string[] Evidence { get; init; } = [];
    public Dictionary<string, RuleExpectedOutcome> ByVariable { get; init; } = [];
}

public sealed record TestPackApprovalOverlay
{
    public string SchemaVersion { get; init; } = TestPackVersions.ApprovalSchema;
    public required string TestPackContentHash { get; init; }
    public TestPackApprovalStatus Status { get; init; } = TestPackApprovalStatus.PendingApproval;
    public string? ApprovedBy { get; init; }
    public DateTimeOffset? ApprovedAt { get; init; }
    public string[] EvidenceRefs { get; init; } = [];
}

public sealed record TestPackApprovalInfo
{
    public TestPackApprovalStatus Status { get; init; } = TestPackApprovalStatus.PendingApproval;
    public string? ApprovedBy { get; init; }
    public DateTimeOffset? ApprovedAt { get; init; }
    public string[] EvidenceRefs { get; init; } = [];
    public string ApprovedContentHash { get; init; } = "";
}

public sealed record RuleTestPack
{
    public string SchemaVersion { get; init; } = TestPackVersions.Schema;
    public string GeneratorVersion { get; init; } = TestPackVersions.Generator;
    public required string TestPackId { get; init; }
    public required string ContentHash { get; init; }
    public required string DatasetId { get; init; }
    public required string DatasetSha256 { get; init; }
    public required string SourceHash { get; init; }
    public required string DatasetContentHash { get; init; }
    public string DatasetSource { get; init; } = "";
    public CombinationPolicy CombinationPolicy { get; init; } = CombinationPolicy.Cartesian;
    public int MaxCases { get; init; }
    public int CaseCount { get; init; }
    public required RuleTestDataset DatasetSnapshot { get; init; }
    public RuleTestCase[] Cases { get; init; } = [];
    public TestPackApprovalInfo Approval { get; init; } = new();
    public DateTimeOffset GeneratedAt { get; init; }
}

public static class TestPackVersions
{
    public const string Schema = "1.0";
    public const string ApprovalSchema = "1.0";
    public const string Generator = "HtsQa.Core.TestPackCompiler/1.0";
}

public sealed class CombinationLimitExceededException(long projectedCases, int maxCases)
    : Exception($"Projected case count {projectedCases} exceeds maxCases {maxCases}; TestPack compilation was not truncated.")
{
    public long ProjectedCases { get; } = projectedCases;
    public int MaxCases { get; } = maxCases;
}

/// <summary>객체의 모든 JSON object key를 ordinal 정렬해 입력 사전 순서와 직렬화기 차이를 제거한다.</summary>
public static class CanonicalJson
{
    public static byte[] SerializeToUtf8Bytes<T>(T value)
    {
        var element = JsonSerializer.SerializeToElement(value, JsonDefaults.Options);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = false }))
            Write(writer, element);
        return stream.ToArray();
    }

    public static string Sha256<T>(T value) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(SerializeToUtf8Bytes(value))).ToLowerInvariant();

    private static void Write(Utf8JsonWriter writer, JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in element.EnumerateObject().OrderBy(x => x.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    Write(writer, property.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in element.EnumerateArray()) Write(writer, item);
                writer.WriteEndArray();
                break;
            case JsonValueKind.String:
                writer.WriteStringValue(element.GetString());
                break;
            case JsonValueKind.Number:
                writer.WriteRawValue(element.GetRawText(), skipInputValidation: true);
                break;
            case JsonValueKind.True:
                writer.WriteBooleanValue(true);
                break;
            case JsonValueKind.False:
                writer.WriteBooleanValue(false);
                break;
            case JsonValueKind.Null:
            case JsonValueKind.Undefined:
                writer.WriteNullValue();
                break;
        }
    }
}

/// <summary>모든 실행 CaseId를 canonical JSON SHA-256으로 생성하는 유일한 팩터리다.</summary>
public static class CaseIdFactory
{
    public static string Create(string prefix, object identity, int hashLength = 16)
    {
        if (string.IsNullOrWhiteSpace(prefix)) throw new ArgumentException("CaseId prefix is required.", nameof(prefix));
        var hash = CanonicalJson.Sha256(identity);
        return $"{prefix}-{hash[..Math.Clamp(hashLength, 4, hash.Length)]}";
    }

    public static string CreateRuleCase(string datasetId, string screenNumber, string accountId, IReadOnlyDictionary<string, string> variables) =>
        Create("RC", new
        {
            datasetId,
            screenNumber,
            accountId,
            variables = variables.OrderBy(x => x.Key, StringComparer.Ordinal).ToDictionary(x => x.Key, x => x.Value, StringComparer.Ordinal)
        });
}

/// <summary>선택된 변수값의 기대 계약을 손실 없이 보존하고 대표 기대 유형을 결정론적으로 계산한다.</summary>
public sealed class ExpectationResolver
{
    public ResolvedExpectedResult Resolve(IReadOnlyDictionary<string, RuleVariableValue> selectedValues)
    {
        var byVariable = selectedValues.OrderBy(x => x.Key, StringComparer.Ordinal)
            .ToDictionary(x => x.Key, x => x.Value.ExpectedOutcome, StringComparer.OrdinalIgnoreCase);
        var explicitRows = byVariable.Values.Where(x => x.Type != RuleExpectedOutcomeType.Unspecified).ToArray();
        var effective = explicitRows.OrderByDescending(x => Priority(x.Type)).FirstOrDefault();
        return new ResolvedExpectedResult
        {
            Type = effective?.Type ?? RuleExpectedOutcomeType.Unspecified,
            MessagePatterns = explicitRows.SelectMany(x => x.MessagePatterns).Distinct(StringComparer.Ordinal).OrderBy(x => x, StringComparer.Ordinal).ToArray(),
            ErrorCodes = explicitRows.SelectMany(x => x.ErrorCodes).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x => x, StringComparer.Ordinal).ToArray(),
            Evidence = explicitRows.SelectMany(x => x.Evidence).Distinct(StringComparer.Ordinal).OrderBy(x => x, StringComparer.Ordinal).ToArray(),
            ByVariable = byVariable
        };
    }

    private static int Priority(RuleExpectedOutcomeType type) => type switch
    {
        RuleExpectedOutcomeType.FailureRequired => 800,
        RuleExpectedOutcomeType.ValidationRequired => 700,
        RuleExpectedOutcomeType.ObservationOnly => 600,
        RuleExpectedOutcomeType.ValidationAllowed => 500,
        RuleExpectedOutcomeType.WarningAllowed => 400,
        RuleExpectedOutcomeType.NoDataAllowed => 400,
        RuleExpectedOutcomeType.Success => 300,
        _ => 0
    };
}

/// <summary>Cartesian, Pairwise, PerControl 정책을 구현하는 유일한 룰 케이스 조합 생성기다.</summary>
public sealed class CombinationGenerator
{
    public IReadOnlyList<Dictionary<string, TValue>> GenerateCartesian<TDimension, TValue>(
        IEnumerable<TDimension> dimensions,
        Func<TDimension, string> nameSelector,
        Func<TDimension, IEnumerable<TValue>> valuesSelector,
        Func<TValue, string> valueKeySelector)
    {
        var rows = new List<Dictionary<string, TValue>> { new(StringComparer.OrdinalIgnoreCase) };
        foreach (var dimension in dimensions.OrderBy(nameSelector, StringComparer.Ordinal))
        {
            var nextRows = new List<Dictionary<string, TValue>>();
            foreach (var row in rows)
            foreach (var value in valuesSelector(dimension).OrderBy(valueKeySelector, StringComparer.Ordinal))
            {
                var next = new Dictionary<string, TValue>(row, StringComparer.OrdinalIgnoreCase)
                {
                    [nameSelector(dimension)] = value
                };
                nextRows.Add(next);
            }
            rows = nextRows;
        }
        return rows;
    }

    public long CountCases(RuleTestDataset dataset, CombinationPolicy? policy = null)
    {
        var effectivePolicy = policy ?? dataset.CombinationPolicy;
        var contexts = ActiveExecutionContexts(dataset).Length;
        long total = 0;
        foreach (var screen in EnabledScreens(dataset))
        {
            var dimensions = ApplicableDimensions(dataset, screen.ScreenNumber);
            var combinations = effectivePolicy == CombinationPolicy.Cartesian
                ? CartesianCount(dimensions)
                : GenerateSelections(dimensions, effectivePolicy).LongCount();
            total = checked(total + checked(combinations * contexts));
        }
        return total;
    }

    public RuleTestCase[] Generate(RuleTestDataset dataset, CombinationPolicy? policy = null, int? maxCases = null)
    {
        var effectivePolicy = policy ?? dataset.CombinationPolicy;
        var limit = maxCases ?? dataset.MaxExpandedCases;
        if (limit < 1) throw new ArgumentOutOfRangeException(nameof(maxCases), "maxCases must be at least 1.");
        var projected = CountCases(dataset, effectivePolicy);
        if (projected > limit) throw new CombinationLimitExceededException(projected, limit);

        var resolver = new ExpectationResolver();
        var result = new List<RuleTestCase>((int)projected);
        foreach (var screen in EnabledScreens(dataset))
        foreach (var account in ActiveExecutionContexts(dataset))
        {
            var applicable = ApplicableDimensions(dataset, screen.ScreenNumber);
            foreach (var selectedValues in GenerateSelections(applicable, effectivePolicy))
            {
                var variables = selectedValues.OrderBy(x => x.Key, StringComparer.Ordinal)
                    .ToDictionary(x => x.Key, x => x.Value.Value, StringComparer.OrdinalIgnoreCase);
                foreach (var fixedPair in screen.FixedConditions.OrderBy(x => x.Key, StringComparer.Ordinal))
                    variables[fixedPair.Key] = fixedPair.Value;
                var expectation = resolver.Resolve(selectedValues);
                result.Add(new RuleTestCase
                {
                    CaseId = CaseIdFactory.CreateRuleCase(dataset.DatasetId, screen.ScreenNumber, account.Id, variables),
                    DatasetId = dataset.DatasetId,
                    ScreenNumber = screen.ScreenNumber,
                    ScreenName = screen.ScreenName,
                    QueryTrigger = screen.QueryTrigger,
                    AccountId = account.Id,
                    AccountNumber = account.AccountNumber,
                    AccountOwner = account.Owner,
                    InputMode = account.InputMode,
                    PasswordSecret = account.PasswordSecret,
                    Variables = variables,
                    SensitiveVariables = dataset.Variables.OrderBy(x => x.Name, StringComparer.Ordinal).ToDictionary(x => x.Name, x => x.Sensitive, StringComparer.OrdinalIgnoreCase),
                    VariableControlKinds = applicable.ToDictionary(x => x.Name, x => x.ControlKind, StringComparer.OrdinalIgnoreCase),
                    VariableValueMatches = applicable.ToDictionary(x => x.Name, x => x.ValueMatch, StringComparer.OrdinalIgnoreCase),
                    VariableTargetRoles = applicable.ToDictionary(x => x.Name, x => x.TargetRole ?? $"condition:{x.Name}", StringComparer.OrdinalIgnoreCase),
                    VariableRequired = applicable.ToDictionary(x => x.Name, x => x.Required, StringComparer.OrdinalIgnoreCase),
                    VariableTriggerQuery = applicable.ToDictionary(x => x.Name, x => x.TriggerQueryAfterChange, StringComparer.OrdinalIgnoreCase),
                    VariableExpectedOutcomes = expectation.ByVariable,
                    ExpectedResult = expectation,
                    AutoExplorationEnabled = dataset.AutoExploration.Enabled,
                    Locators = MergeLocators(dataset.DefaultLocators, screen.Locators)
                });
            }
        }
        return result.ToArray();
    }

    public static RuleAccountInput[] ActiveExecutionContexts(RuleTestDataset dataset)
    {
        var configured = dataset.Accounts.Where(x => x.Enabled).OrderBy(x => x.Id, StringComparer.Ordinal).ToArray();
        return configured.Length > 0 ? configured :
        [
            new RuleAccountInput { Id = "default", AccountNumber = "", Owner = "", InputMode = RuleInputMode.Prefilled }
        ];
    }

    private static RuleScreenInput[] EnabledScreens(RuleTestDataset dataset) =>
        dataset.Screens.Where(x => x.Enabled).OrderBy(x => x.ScreenNumber, StringComparer.Ordinal).ToArray();

    private static RuleVariableDimension[] ApplicableDimensions(RuleTestDataset dataset, string screenNumber) =>
        dataset.Variables.Where(x => x.AppliesToScreens.Contains("*") || x.AppliesToScreens.Contains(screenNumber))
            .OrderBy(x => x.Name, StringComparer.Ordinal).ToArray();

    private static long CartesianCount(RuleVariableDimension[] dimensions)
    {
        long count = 1;
        foreach (var dimension in dimensions) count = checked(count * dimension.Values.Length);
        return count;
    }

    private static IReadOnlyList<Dictionary<string, RuleVariableValue>> GenerateSelections(
        RuleVariableDimension[] dimensions,
        CombinationPolicy policy) => policy switch
        {
            CombinationPolicy.Cartesian => Cartesian(dimensions),
            CombinationPolicy.Pairwise => Pairwise(dimensions),
            CombinationPolicy.PerControl => PerControl(dimensions),
            _ => throw new ArgumentOutOfRangeException(nameof(policy), policy, "Unsupported combination policy.")
        };

    private static IReadOnlyList<Dictionary<string, RuleVariableValue>> Cartesian(RuleVariableDimension[] dimensions)
        => new CombinationGenerator().GenerateCartesian(dimensions, x => x.Name, x => x.Values, x => x.Id);

    // 결정론적 IPO 방식: 기존 행에는 새 제어값을 최대 미커버 pair 우선으로 배치하고 남은 pair만 보충한다.
    private static IReadOnlyList<Dictionary<string, RuleVariableValue>> Pairwise(RuleVariableDimension[] dimensions)
    {
        if (dimensions.Length < 2) return Cartesian(dimensions);
        var rows = Cartesian(dimensions[..2]).ToList();
        for (var index = 2; index < dimensions.Length; index++)
        {
            var current = dimensions[index];
            var uncovered = new HashSet<(string LeftName, string LeftId, string RightId)>();
            foreach (var previous in dimensions[..index])
            foreach (var left in previous.Values)
            foreach (var right in current.Values)
                uncovered.Add((previous.Name, left.Id, right.Id));

            foreach (var row in rows)
            {
                var chosen = current.Values.OrderByDescending(value => dimensions[..index].Count(previous =>
                        uncovered.Contains((previous.Name, row[previous.Name].Id, value.Id))))
                    .ThenBy(value => value.Id, StringComparer.Ordinal).First();
                row[current.Name] = chosen;
                RemoveCovered(uncovered, row, current, dimensions[..index]);
            }

            while (uncovered.Count > 0)
            {
                var pair = uncovered.OrderBy(x => x.LeftName, StringComparer.Ordinal).ThenBy(x => x.LeftId, StringComparer.Ordinal)
                    .ThenBy(x => x.RightId, StringComparer.Ordinal).First();
                var row = dimensions[..(index + 1)].ToDictionary(
                    x => x.Name,
                    x => x.Values.OrderBy(v => v.Id, StringComparer.Ordinal).First(),
                    StringComparer.OrdinalIgnoreCase);
                row[pair.LeftName] = dimensions.First(x => x.Name.Equals(pair.LeftName, StringComparison.OrdinalIgnoreCase)).Values.First(x => x.Id == pair.LeftId);
                row[current.Name] = current.Values.First(x => x.Id == pair.RightId);
                rows.Add(row);
                RemoveCovered(uncovered, row, current, dimensions[..index]);
            }
        }
        return Deduplicate(rows);
    }

    private static void RemoveCovered(
        HashSet<(string LeftName, string LeftId, string RightId)> uncovered,
        Dictionary<string, RuleVariableValue> row,
        RuleVariableDimension current,
        RuleVariableDimension[] previous)
    {
        foreach (var dimension in previous)
            uncovered.Remove((dimension.Name, row[dimension.Name].Id, row[current.Name].Id));
    }

    private static IReadOnlyList<Dictionary<string, RuleVariableValue>> PerControl(RuleVariableDimension[] dimensions)
    {
        if (dimensions.Length == 0) return [new(StringComparer.OrdinalIgnoreCase)];
        var baseline = dimensions.ToDictionary(x => x.Name, x => x.Values.OrderBy(v => v.Id, StringComparer.Ordinal).First(), StringComparer.OrdinalIgnoreCase);
        var rows = new List<Dictionary<string, RuleVariableValue>> { baseline };
        foreach (var dimension in dimensions)
        foreach (var value in dimension.Values.OrderBy(x => x.Id, StringComparer.Ordinal).Skip(1))
        {
            var row = new Dictionary<string, RuleVariableValue>(baseline, StringComparer.OrdinalIgnoreCase) { [dimension.Name] = value };
            rows.Add(row);
        }
        return Deduplicate(rows);
    }

    private static IReadOnlyList<Dictionary<string, RuleVariableValue>> Deduplicate(IEnumerable<Dictionary<string, RuleVariableValue>> rows) =>
        rows.GroupBy(row => string.Join("|", row.OrderBy(x => x.Key, StringComparer.Ordinal).Select(x => $"{x.Key}={x.Value.Id}")), StringComparer.Ordinal)
            .Select(x => x.First()).ToArray();

    private static Dictionary<string, RuleLocatorStrategy[]> MergeLocators(
        Dictionary<string, RuleLocatorStrategy[]> defaults,
        Dictionary<string, RuleLocatorStrategy[]> overrides)
    {
        var merged = new Dictionary<string, RuleLocatorStrategy[]>(defaults, StringComparer.OrdinalIgnoreCase);
        foreach (var pair in overrides) merged[pair.Key] = pair.Value;
        return merged;
    }
}

/// <summary>검증·조합·기대 해석·승인 적용을 순서대로 수행해 저장 가능한 TestPack을 컴파일한다.</summary>
public sealed class TestPackCompiler
{
    public RuleTestPack Compile(
        RuleTestDataset dataset,
        string datasetSha256,
        string datasetSource = "",
        CombinationPolicy? combinationPolicy = null,
        int? maxCases = null,
        TestPackApprovalOverlay? approval = null,
        DateTimeOffset? generatedAt = null)
    {
        var validation = new RuleDatasetValidator().Validate(dataset);
        if (!validation.IsValid)
            throw new InvalidDataException(string.Join(Environment.NewLine, validation.Issues.Select(x => $"{x.Code}: {x.Message}")));
        if (string.IsNullOrWhiteSpace(datasetSha256)) throw new ArgumentException("datasetSha256 is required.", nameof(datasetSha256));

        var policy = combinationPolicy ?? dataset.CombinationPolicy;
        var limit = Math.Min(dataset.MaxExpandedCases, maxCases ?? dataset.MaxExpandedCases);
        var cases = new CombinationGenerator().Generate(dataset, policy, limit);
        var datasetContentHash = CanonicalJson.Sha256(dataset);
        var contentHash = ComputeContentHash(dataset, datasetSha256, datasetContentHash, policy, limit, cases);
        var approvalInfo = ApplyApproval(contentHash, approval);
        return new RuleTestPack
        {
            TestPackId = $"TP-{contentHash[..16]}",
            ContentHash = contentHash,
            DatasetId = dataset.DatasetId,
            DatasetSha256 = datasetSha256.ToLowerInvariant(),
            SourceHash = datasetSha256.ToLowerInvariant(),
            DatasetContentHash = datasetContentHash,
            DatasetSource = datasetSource,
            CombinationPolicy = policy,
            MaxCases = limit,
            CaseCount = cases.Length,
            DatasetSnapshot = dataset,
            Cases = cases,
            Approval = approvalInfo,
            GeneratedAt = generatedAt ?? DateTimeOffset.UtcNow
        };
    }

    public static TestPackApprovalOverlay CreateApprovalTemplate(RuleTestPack testPack) => new()
    {
        TestPackContentHash = testPack.ContentHash,
        Status = TestPackApprovalStatus.PendingApproval
    };

    internal static string ComputeContentHash(
        RuleTestDataset dataset,
        string datasetSha256,
        string datasetContentHash,
        CombinationPolicy policy,
        int maxCases,
        RuleTestCase[] cases) => CanonicalJson.Sha256(new
        {
            schemaVersion = TestPackVersions.Schema,
            generatorVersion = TestPackVersions.Generator,
            datasetSha256 = datasetSha256.ToLowerInvariant(),
            datasetContentHash,
            combinationPolicy = policy,
            maxCases,
            datasetSnapshot = dataset,
            cases
        });

    private static TestPackApprovalInfo ApplyApproval(string contentHash, TestPackApprovalOverlay? approval)
    {
        if (approval is null) return new();
        if (approval.SchemaVersion != TestPackVersions.ApprovalSchema)
            throw new InvalidDataException($"Unsupported TestPack approval schemaVersion: {approval.SchemaVersion}.");
        if (!string.Equals(approval.TestPackContentHash, contentHash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Approval TestPack content hash does not match the compiled content.");
        if (approval.Status == TestPackApprovalStatus.Approved &&
            (string.IsNullOrWhiteSpace(approval.ApprovedBy) || approval.ApprovedAt is null))
            throw new InvalidDataException("Approved TestPack requires approvedBy and approvedAt.");
        return new TestPackApprovalInfo
        {
            Status = approval.Status,
            ApprovedBy = approval.Status == TestPackApprovalStatus.Approved ? approval.ApprovedBy : null,
            ApprovedAt = approval.Status == TestPackApprovalStatus.Approved ? approval.ApprovedAt : null,
            EvidenceRefs = approval.EvidenceRefs,
            ApprovedContentHash = approval.Status == TestPackApprovalStatus.Approved ? contentHash : ""
        };
    }
}

/// <summary>Runner 진입 전에 스키마, 내용, CaseId, 승인, 선택적 원본 데이터셋 해시를 검증한다.</summary>
public sealed class TestPackValidator
{
    public ValidationResult Validate(RuleTestPack testPack, bool requireApproved = true)
    {
        var issues = new List<ValidationIssue>();
        if (testPack.SchemaVersion != TestPackVersions.Schema)
            issues.Add(new("TESTPACK.SCHEMA", $"Unsupported TestPack schemaVersion: {testPack.SchemaVersion}."));
        if (testPack.GeneratorVersion != TestPackVersions.Generator)
            issues.Add(new("TESTPACK.GENERATOR", $"Unsupported TestPack generatorVersion: {testPack.GeneratorVersion}."));
        if (testPack.CaseCount != testPack.Cases.Length)
            issues.Add(new("TESTPACK.CASE_COUNT", "caseCount does not match cases length."));
        if (testPack.Cases.Length > testPack.MaxCases)
            issues.Add(new("TESTPACK.CASE_LIMIT", "TestPack cases exceed maxCases."));

        var datasetContentHash = CanonicalJson.Sha256(testPack.DatasetSnapshot);
        if (!string.Equals(datasetContentHash, testPack.DatasetContentHash, StringComparison.OrdinalIgnoreCase))
            issues.Add(new("TESTPACK.DATASET_CONTENT_HASH", "Embedded dataset content hash mismatch."));
        var contentHash = TestPackCompiler.ComputeContentHash(
            testPack.DatasetSnapshot,
            testPack.DatasetSha256,
            testPack.DatasetContentHash,
            testPack.CombinationPolicy,
            testPack.MaxCases,
            testPack.Cases);
        if (!string.Equals(contentHash, testPack.ContentHash, StringComparison.OrdinalIgnoreCase))
            issues.Add(new("TESTPACK.CONTENT_HASH", "TestPack content hash mismatch."));
        if (!string.Equals(testPack.TestPackId, $"TP-{testPack.ContentHash[..Math.Min(16, testPack.ContentHash.Length)]}", StringComparison.Ordinal))
            issues.Add(new("TESTPACK.ID", "testPackId does not match contentHash."));

        foreach (var testCase in testPack.Cases)
        {
            var expectedCaseId = CaseIdFactory.CreateRuleCase(testCase.DatasetId, testCase.ScreenNumber, testCase.AccountId, testCase.Variables);
            if (!string.Equals(testCase.CaseId, expectedCaseId, StringComparison.Ordinal))
                issues.Add(new("TESTPACK.CASE_ID", $"CaseId does not match canonical identity: {testCase.CaseId}."));
        }
        if (testPack.Cases.Select(x => x.CaseId).Distinct(StringComparer.Ordinal).Count() != testPack.Cases.Length)
            issues.Add(new("TESTPACK.DUPLICATE_CASE_ID", "Duplicate CaseId exists."));

        if (requireApproved && testPack.Approval.Status != TestPackApprovalStatus.Approved)
            issues.Add(new("TESTPACK.NOT_APPROVED", "Runner accepts only Approved TestPack files."));
        if (testPack.Approval.Status == TestPackApprovalStatus.Approved &&
            (!string.Equals(testPack.Approval.ApprovedContentHash, testPack.ContentHash, StringComparison.OrdinalIgnoreCase) ||
             string.IsNullOrWhiteSpace(testPack.Approval.ApprovedBy) || testPack.Approval.ApprovedAt is null))
            issues.Add(new("TESTPACK.APPROVAL_INVALID", "Approved TestPack approval metadata or content hash is invalid."));
        return new ValidationResult(issues.Count == 0, issues);
    }

    public ValidationResult ValidateSource(RuleTestPack testPack, RuleTestDataset currentDataset, string currentDatasetSha256)
    {
        var issues = new List<ValidationIssue>();
        if (!string.Equals(testPack.DatasetSha256, currentDatasetSha256, StringComparison.OrdinalIgnoreCase))
            issues.Add(new("TESTPACK.SOURCE_HASH_MISMATCH", "Current dataset source hash differs from the compiled TestPack."));
        if (!string.Equals(testPack.DatasetContentHash, CanonicalJson.Sha256(currentDataset), StringComparison.OrdinalIgnoreCase))
            issues.Add(new("TESTPACK.DATASET_CHANGED", "Current dataset content differs from the compiled TestPack snapshot."));
        return new ValidationResult(issues.Count == 0, issues);
    }
}

/// <summary>C# dry-run과 PowerShell Runner가 공유하는 승인된 케이스 집합 로더다.</summary>
public sealed class TestPackRunnerContract
{
    public RuleTestCase[] LoadApprovedCases(RuleTestPack testPack)
    {
        var validation = new TestPackValidator().Validate(testPack, requireApproved: true);
        if (!validation.IsValid)
            throw new InvalidDataException(string.Join(Environment.NewLine, validation.Issues.Select(x => $"{x.Code}: {x.Message}")));
        return testPack.Cases.ToArray();
    }
}
