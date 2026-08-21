// 역할: 룰 기반 테스트의 데이터셋, 런타임 컨트롤, 실행 결과 계약과 기본 검증·케이스 확장을 정의한다.
// 입력/출력: dataset JSON을 검증된 RuleDataset과 결정론적 RuleTestCase 목록으로 변환한다.
// 경계: UI 조작이나 HTS 설치 파일 해석은 포함하지 않고 실행기와 교환할 도메인 계약만 유지한다.
// 수정 지점: 필드 추가 시 템플릿 데이터셋, Validator, Excel 안내, 관련 테스트를 함께 갱신한다.
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace HtsQa.Core;

// 데이터셋 입력 및 기대 결과 계약 -------------------------------------------------
public enum RuleInputMode
{
    Prefilled,
    Explicit
}

public enum SecretProvider
{
    Environment
}

public enum RuleControlKind
{
    Auto,
    Text,
    Date,
    ComboBox,
    RadioButton,
    RadioGroup,
    CheckBox,
    Tab,
    Button,
    ListBox,
    ListView,
    TreeView,
    Slider,
    Spin
}

public enum RuleValueMatch
{
    Value,
    DisplayText,
    Index,
    Checked
}

public enum RuleExpectedOutcomeType
{
    Unspecified,
    Success,
    ValidationAllowed,
    ValidationRequired,
    FailureRequired,
    NoDataAllowed,
    WarningAllowed,
    ObservationOnly
}

public enum RuleExpectationSource
{
    Unspecified,
    Dataset,
    DatasetDefault,
    InstallationInputOption,
    InstallationMaster,
    MapValidation,
    MapBehavior,
    RuntimeChoice,
    GeneratedBoundary,
    ScreenExpectedPattern
}

public enum RuleExpectationConfidence
{
    Unspecified,
    Low,
    Medium,
    High
}

public sealed record SecretReference
{
    public SecretProvider Provider { get; init; } = SecretProvider.Environment;
    public required string Key { get; init; }
}

public sealed record RuleAccountInput
{
    public required string Id { get; init; }
    public required string AccountNumber { get; init; }
    public required string Owner { get; init; }
    public RuleInputMode InputMode { get; init; } = RuleInputMode.Prefilled;
    public SecretReference? PasswordSecret { get; init; }
    public bool Enabled { get; init; } = true;
    public Dictionary<string, string> Metadata { get; init; } = [];
}

public sealed record RuleVariableValue
{
    public required string Id { get; init; }
    public required string Value { get; init; }
    public string? DisplayValue { get; init; }
    public RuleExpectedOutcome ExpectedOutcome { get; init; } = new();
}

public sealed record RuleExpectedOutcome
{
    public RuleExpectedOutcomeType Type { get; init; } = RuleExpectedOutcomeType.Unspecified;
    public string[] MessagePatterns { get; init; } = [];
    public string[] ErrorCodes { get; init; } = [];
    public bool? QueryShouldComplete { get; init; }
    public RuleExpectationSource Source { get; init; } = RuleExpectationSource.Unspecified;
    public RuleExpectationConfidence Confidence { get; init; } = RuleExpectationConfidence.Unspecified;
    public string[] Evidence { get; init; } = [];
}

public sealed record RuleVariableDimension
{
    public required string Name { get; init; }
    public string? TargetRole { get; init; }
    public RuleControlKind ControlKind { get; init; } = RuleControlKind.Auto;
    public RuleValueMatch ValueMatch { get; init; } = RuleValueMatch.Value;
    public RuleVariableValue[] Values { get; init; } = [];
    public string[] AppliesToScreens { get; init; } = ["*"];
    public bool Sensitive { get; init; }
    public bool Required { get; init; } = true;
    public bool TriggerQueryAfterChange { get; init; } = true;
}

public sealed record RuleAutoExplorationPolicy
{
    public string InteractionStrategy { get; init; } = RuleInteractionStrategies.RuntimeTabOrder;
    public bool Enabled { get; init; } = true;
    public bool IncludeButtons { get; init; } = true;
    public bool IncludeUnlabeledButtons { get; init; } = true;
    public bool TriggerQueryAfterStateChange { get; init; } = true;
    public int MaxControlsPerScreen { get; init; } = 120;
    public int MaxOptionsPerControl { get; init; } = 40;
    public int MaxActionsPerScreen { get; init; } = 500;
    public string ContentRegionFile { get; init; } = "data/realhts/content-regions.json";
    public RuleVariableValue[] DefaultTextValues { get; init; } = [];
    public RuleVariableValue[] DefaultDateValues { get; init; } = [];
    public string[] ExcludeTitlePatterns { get; init; } = ["^(B|X|Button1)$"];
    public RuleMapBaselinePolicy MapBaseline { get; init; } = new();
}

public static class RuleInteractionStrategies
{
    public const string RuntimeTabOrder = "RuntimeTabOrder";
    public const string CoordinateFocus = "CoordinateFocus";

    public static bool IsSupported(string? value) =>
        value is not null &&
        (value.Equals(RuntimeTabOrder, StringComparison.OrdinalIgnoreCase) ||
         value.Equals(CoordinateFocus, StringComparison.OrdinalIgnoreCase));
}

public sealed record RuleMapBaselinePolicy
{
    public bool Enabled { get; init; }
    public int MatchTolerancePx { get; init; } = 36;
}

/// <summary>테스트 대상 프로그램의 최상위 창을 안전하게 식별하는 조건이다.</summary>
public sealed record RuleTargetWindowProfile
{
    public string ClassName { get; init; } = "";
    public string TitlePrefix { get; init; } = "";
}

/// <summary>설치 폴더에서 정적 화면 모델을 찾는 방법을 정의한다.</summary>
public sealed record RuleTargetMapProfile
{
    public string InstallationRoot { get; init; } = "";
    public string ScreenDirectory { get; init; } = "screen";
    public string FilePattern { get; init; } = "ht{screenNumber}00.map";
    public string[] FamilyFiles { get; init; } = [];
    public string[] InitiallyActiveMapScreenCodes { get; init; } = [];
}

/// <summary>특정 화면군에 종속되던 실행 환경 값을 데이터셋 단위 설정으로 모은다.</summary>
public sealed record RuleTargetProfile
{
    public string Id { get; init; } = "target";
    public string DisplayName { get; init; } = "대상 HTS";
    public string RunLabel { get; init; } = "target-rule";
    public string ScreenIdPattern { get; init; } = "^[0-9]{4}$";
    public RuleTargetWindowProfile Window { get; init; } = new();
    public RuleTargetMapProfile Map { get; init; } = new();
    public RuleTargetAdapterProfile? Adapter { get; init; }
}

public sealed record RuleLocatorStrategy
{
    public string? AutomationId { get; init; }
    public string? NameRegex { get; init; }
    public string? ClassName { get; init; }
    public string? ControlType { get; init; }
    public int? Ordinal { get; init; }
    public string? RelativeRegion { get; init; }
    public int? RelativeX { get; init; }
    public int? RelativeY { get; init; }
    public int? Width { get; init; }
    public int? Height { get; init; }
}

public sealed record RuleScreenInput
{
    public required string ScreenNumber { get; init; }
    public required string ScreenName { get; init; }
    public bool Enabled { get; init; } = true;
    public string QueryTrigger { get; init; } = "F12";
    public Dictionary<string, RuleLocatorStrategy[]> Locators { get; init; } = [];
    public Dictionary<string, string> FixedConditions { get; init; } = [];
    public string[] ExpectedPopupPatterns { get; init; } = [];
}

public sealed record RuleExecutionPolicy
{
    public string Mode { get; init; } = "explicitErrorOnly";
    public bool StopOnFirstError { get; init; }
    public int ScreenOpenTimeoutMs { get; init; } = 10000;
    public int ActionTimeoutMs { get; init; } = 5000;
    public bool AllowTransactionalActions { get; init; }
    public bool RequireApprovedPlanForTransactionalActions { get; init; } = true;
    public bool AllowObservedPrefilledTransactionalAccount { get; init; }
    public string[] AllowedTransactionalAccountIds { get; init; } = [];
    public string[] AllowedTransactionalScreens { get; init; } = [];
    public string[] ErrorPatterns { get; init; } =
    [
        "Error", "Exception", "Fail", "Socket Error", "SOCKET_ERROR",
        "\uC624\uB958", "\uC5D0\uB7EC", "\uC2E4\uD328", "\uC608\uC678", "\uC7A5\uC560"
    ];
}

public sealed record RuleTestDataset
{
    public required string SchemaVersion { get; init; }
    public required string DatasetId { get; init; }
    public RuleTargetProfile TargetProfile { get; init; } = new();
    public CombinationPolicy CombinationPolicy { get; init; } = CombinationPolicy.Cartesian;
    public int MaxExpandedCases { get; init; } = 10000;
    public required RuleExecutionPolicy ExecutionPolicy { get; init; }
    public RuleAccountInput[] Accounts { get; init; } = [];
    public RuleScreenInput[] Screens { get; init; } = [];
    public RuleVariableDimension[] Variables { get; init; } = [];
    public Dictionary<string, RuleLocatorStrategy[]> DefaultLocators { get; init; } = [];
    public RuleAutoExplorationPolicy AutoExploration { get; init; } = new();
}

// 런타임 실행 및 관찰 결과 계약 -------------------------------------------------
public sealed record RuleTestCase
{
    public required string CaseId { get; init; }
    public required string DatasetId { get; init; }
    public required string ScreenNumber { get; init; }
    public required string ScreenName { get; init; }
    public required string QueryTrigger { get; init; }
    public required string AccountId { get; init; }
    public required string AccountNumber { get; init; }
    public required string AccountOwner { get; init; }
    public required RuleInputMode InputMode { get; init; }
    public SecretReference? PasswordSecret { get; init; }
    public Dictionary<string, string> Variables { get; init; } = [];
    public Dictionary<string, bool> SensitiveVariables { get; init; } = [];
    public Dictionary<string, RuleControlKind> VariableControlKinds { get; init; } = [];
    public Dictionary<string, RuleValueMatch> VariableValueMatches { get; init; } = [];
    public Dictionary<string, string> VariableTargetRoles { get; init; } = [];
    public Dictionary<string, bool> VariableRequired { get; init; } = [];
    public Dictionary<string, bool> VariableTriggerQuery { get; init; } = [];
    public Dictionary<string, RuleExpectedOutcome> VariableExpectedOutcomes { get; init; } = [];
    public ResolvedExpectedResult ExpectedResult { get; init; } = new();
    public bool AutoExplorationEnabled { get; init; }
    public Dictionary<string, RuleLocatorStrategy[]> Locators { get; init; } = [];
}

public sealed record SanitizedRuleTestCase
{
    public required string CaseId { get; init; }
    public required string DatasetId { get; init; }
    public required string ScreenNumber { get; init; }
    public required string ScreenName { get; init; }
    public required RuleInputMode InputMode { get; init; }
    public required string AccountId { get; init; }
    public required string AccountMasked { get; init; }
    public required string AccountFingerprint { get; init; }
    public required string AccountOwner { get; init; }
    public required string PasswordSource { get; init; }
    public Dictionary<string, string> Variables { get; init; } = [];
}

public sealed record RuleActionResult
{
    public required string Action { get; init; }
    public required TestStatus Status { get; init; }
    public string? Target { get; init; }
    public string? Output { get; init; }
    public string? ErrorCode { get; init; }
    public long ElapsedMs { get; init; }
}

public sealed record RuleControlOption
{
    public required string Id { get; init; }
    public required string Value { get; init; }
    public string? DisplayValue { get; init; }
    public string LabelSource { get; init; } = "native";
    public RuleExpectedOutcome ExpectedOutcome { get; init; } = new();
}

public sealed record RuleRuntimeRect
{
    public int Left { get; init; }
    public int Top { get; init; }
    public int Right { get; init; }
    public int Bottom { get; init; }
    public int Width { get; init; }
    public int Height { get; init; }
    public double CenterX { get; init; }
    public double CenterY { get; init; }
}

public sealed record RuleDiscoveredControl
{
    public required string ControlId { get; init; }
    public required RuleControlKind ControlKind { get; init; }
    public string? Name { get; init; }
    public string? ClassName { get; init; }
    public string? AutomationId { get; init; }
    public string? AutomationEngine { get; init; }
    public string? LocatorSignature { get; init; }
    public string? InitialValue { get; init; }
    public int TabOrder { get; init; }
    public bool TabStop { get; init; }
    public string? StateContext { get; init; }
    public string? MapScreenCode { get; init; }
    public string RegionRole { get; init; } = "content";
    public bool ClaimedByDataset { get; init; }
    public bool DataRequired { get; init; }
    public string? PendingReason { get; init; }
    public string DefinitionSource { get; init; } = "RuntimeOnly";
    public string? RuntimeName { get; init; }
    public string? RuntimeControlKind { get; init; }
    public string? MapModelId { get; init; }
    public string? MapTypeCode { get; init; }
    public int? MapDefinitionOrder { get; init; }
    public bool MapMatched { get; init; }
    public double? MapMatchDistance { get; init; }
    public double? MapGeometryDelta { get; init; }
    public bool MapGeometryExact { get; init; }
    public bool MapHostRequired { get; init; }
    public bool MapHostMatched { get; init; }
    public string MapHostId { get; init; } = "";
    public bool RuntimeIdentityUnique { get; init; } = true;
    public bool AllowOwnerDrawnKindOverride { get; init; }
    public string[] MapEvents { get; init; } = [];
    public HtsMapRect? MapRect { get; init; }
    public RuleRuntimeRect? RelativeRect { get; init; }
    public RuleControlOption[] Options { get; init; } = [];
}

public sealed record RuleControlTestResult
{
    public required string PlanItemId { get; init; }
    public required string ControlId { get; init; }
    public required string ControlKind { get; init; }
    public string? ControlName { get; init; }
    public string? OptionId { get; init; }
    public string? InputValue { get; init; }
    public string? DisplayValue { get; init; }
    public required TestStatus Status { get; init; }
    public bool QueryTriggered { get; init; }
    public bool ErrorDetected { get; init; }
    public RuleExpectedOutcomeType ExpectedOutcomeType { get; init; } = RuleExpectedOutcomeType.Unspecified;
    public bool ExpectationSatisfied { get; init; }
    public RuleExpectationSource ExpectedOutcomeSource { get; init; } = RuleExpectationSource.Unspecified;
    public RuleExpectationConfidence ExpectedOutcomeConfidence { get; init; } = RuleExpectationConfidence.Unspecified;
    public string[] ExpectedOutcomeEvidence { get; init; } = [];
    public string? Output { get; init; }
    public string? ErrorCode { get; init; }
    public string? ScreenshotPath { get; init; }
    public long ElapsedMs { get; init; }
}

public sealed record RuleOracleEvent
{
    public required string EventType { get; init; }
    public required string Disposition { get; init; }
    public RuleExpectedOutcomeType ExpectedOutcomeType { get; init; } = RuleExpectedOutcomeType.Unspecified;
    public RuleExpectationSource ExpectedOutcomeSource { get; init; } = RuleExpectationSource.Unspecified;
    public RuleExpectationConfidence ExpectedOutcomeConfidence { get; init; } = RuleExpectationConfidence.Unspecified;
    public string[] ExpectedOutcomeEvidence { get; init; } = [];
    public string? Source { get; init; }
    public string? SourceCode { get; init; }
    public string? Message { get; init; }
    public bool ProductDefect { get; init; }
    public bool RequiresReview { get; init; }
    public DateTimeOffset DetectedAt { get; init; }
}

public sealed record RulePopupObservation
{
    public required string PopupId { get; init; }
    public string? Title { get; init; }
    public string[] MessageLines { get; init; } = [];
    public string[] Buttons { get; init; } = [];
    public string Classification { get; init; } = "알 수 없음";
    public string? Summary { get; init; }
    public bool Expected { get; init; }
    public string? ScreenshotPath { get; init; }
    public DateTimeOffset DetectedAt { get; init; }
}

public sealed record RuleCaseResult
{
    public required string RunId { get; init; }
    public required string CaseId { get; init; }
    public required string DatasetId { get; init; }
    public required string ScreenNumber { get; init; }
    public required string ScreenName { get; init; }
    public required string InputMode { get; init; }
    public required string AccountId { get; init; }
    public required string AccountMasked { get; init; }
    public required string AccountFingerprint { get; init; }
    public required string AccountOwner { get; init; }
    public Dictionary<string, string> InputVariables { get; init; } = [];
    public required TestStatus Status { get; init; }
    public required bool ErrorDetected { get; init; }
    public bool ProductDefectDetected { get; init; }
    public string? ErrorCode { get; init; }
    public string? ErrorMessage { get; init; }
    public string? OutputSummary { get; init; }
    public string[] AutomationIssues { get; init; } = [];
    public string? ScreenshotPath { get; init; }
    public RuleActionResult[] Actions { get; init; } = [];
    public RuleDiscoveredControl[] DiscoveredControls { get; init; } = [];
    public RuleControlTestResult[] ControlTests { get; init; } = [];
    public RulePopupObservation[] PopupObservations { get; init; } = [];
    public RuleOracleEvent[] OracleEvents { get; init; } = [];
    public DateTimeOffset StartedAt { get; init; }
    public DateTimeOffset EndedAt { get; init; }
    public long ElapsedMs { get; init; }
}

/// <summary>데이터셋의 화면·계좌·변수·로케이터·기대 결과 형식을 실행 전에 검증한다.</summary>
public sealed class RuleDatasetValidator
{
    private static readonly Regex AccountRegex = new("^[0-9]{8}-[0-9]{3}$", RegexOptions.CultureInvariant);
    private static readonly Regex KeyRegex = new("^[A-Z][A-Z0-9_]{2,127}$", RegexOptions.CultureInvariant);

    /// <summary>데이터셋 전체를 검사하고 기계 판독 가능한 오류 코드 목록을 반환한다.</summary>
    public ValidationResult Validate(RuleTestDataset dataset)
    {
        var issues = new List<ValidationIssue>();
        if (dataset.SchemaVersion is not ("1.0" or "1.1" or "1.2" or "2.0"))
            issues.Add(new("RULE.SCHEMA_VERSION", "Rule dataset schemaVersion must be 1.0, 1.1, 1.2, or 2.0."));

        // 대상 프로필의 정규식은 화면 검증과 런타임 선택에 함께 쓰이므로 가장 먼저 컴파일한다.
        Regex? screenIdRegex = null;
        if (string.IsNullOrWhiteSpace(dataset.TargetProfile.Id))
            issues.Add(new("RULE.TARGET_ID_REQUIRED", "targetProfile.id is required.", Field: "targetProfile.id"));
        if (string.IsNullOrWhiteSpace(dataset.TargetProfile.DisplayName))
            issues.Add(new("RULE.TARGET_NAME_REQUIRED", "targetProfile.displayName is required.", Field: "targetProfile.displayName"));
        if (string.IsNullOrWhiteSpace(dataset.TargetProfile.RunLabel))
            issues.Add(new("RULE.TARGET_RUN_LABEL_REQUIRED", "targetProfile.runLabel is required.", Field: "targetProfile.runLabel"));
        try
        {
            screenIdRegex = new Regex(dataset.TargetProfile.ScreenIdPattern, RegexOptions.CultureInvariant);
        }
        catch (ArgumentException)
        {
            issues.Add(new("RULE.TARGET_SCREEN_PATTERN", "targetProfile.screenIdPattern must be a valid regular expression.", Field: "targetProfile.screenIdPattern"));
        }
        if (string.IsNullOrWhiteSpace(dataset.TargetProfile.Window.ClassName) &&
            string.IsNullOrWhiteSpace(dataset.TargetProfile.Window.TitlePrefix))
            issues.Add(new("RULE.TARGET_WINDOW_REQUIRED", "At least one target window className or titlePrefix is required.", Field: "targetProfile.window"));
        if (dataset.AutoExploration.MapBaseline.Enabled &&
            dataset.TargetProfile.Map.FamilyFiles.Length == 0 &&
            !dataset.TargetProfile.Map.FilePattern.Contains("{screenNumber}", StringComparison.Ordinal))
            issues.Add(new("RULE.MAP_FILE_PATTERN", "targetProfile.map.filePattern must contain {screenNumber}.", Field: "targetProfile.map.filePattern"));
        if (dataset.TargetProfile.Map.FamilyFiles.Any(x => Path.GetFileName(x) != x))
            issues.Add(new("RULE.MAP_FAMILY_FILE", "targetProfile.map.familyFiles에는 screen 폴더 기준 파일명만 사용할 수 있습니다.", Field: "targetProfile.map.familyFiles"));
        if (dataset.TargetProfile.Map.InitiallyActiveMapScreenCodes.Any(x => !Regex.IsMatch(x ?? "", "^HT[A-Z0-9]+$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)))
            issues.Add(new("RULE.MAP_ACTIVE_CODE", "targetProfile.map.initiallyActiveMapScreenCodes에는 HT로 시작하는 내부화면코드만 사용할 수 있습니다.", Field: "targetProfile.map.initiallyActiveMapScreenCodes"));
        if (dataset.TargetProfile.Map.InitiallyActiveMapScreenCodes.Distinct(StringComparer.OrdinalIgnoreCase).Count() != dataset.TargetProfile.Map.InitiallyActiveMapScreenCodes.Length)
            issues.Add(new("RULE.MAP_ACTIVE_DUPLICATE", "targetProfile.map.initiallyActiveMapScreenCodes에 중복 내부화면코드가 있습니다.", Field: "targetProfile.map.initiallyActiveMapScreenCodes"));
        if (dataset.TargetProfile.Map.FamilyFiles.Length > 0)
        {
            var familyCodes = dataset.TargetProfile.Map.FamilyFiles
                .Select(x => Path.GetFileNameWithoutExtension(x).ToUpperInvariant())
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            if (dataset.TargetProfile.Map.InitiallyActiveMapScreenCodes.Any(x => !familyCodes.Contains(x)))
                issues.Add(new("RULE.MAP_ACTIVE_NOT_IN_FAMILY", "초기 활성 내부화면코드는 targetProfile.map.familyFiles에 포함되어야 합니다.", Field: "targetProfile.map.initiallyActiveMapScreenCodes"));
        }
        if (dataset.AutoExploration.MapBaseline.Enabled && string.IsNullOrWhiteSpace(dataset.TargetProfile.Map.InstallationRoot))
            issues.Add(new("RULE.MAP_ROOT_REQUIRED", "targetProfile.map.installationRoot is required when MAP baseline is enabled.", Field: "targetProfile.map.installationRoot"));
        if (dataset.AutoExploration.MapBaseline.Enabled && string.IsNullOrWhiteSpace(dataset.TargetProfile.Map.ScreenDirectory))
            issues.Add(new("RULE.MAP_SCREEN_DIR_REQUIRED", "targetProfile.map.screenDirectory is required when MAP baseline is enabled.", Field: "targetProfile.map.screenDirectory"));
        issues.AddRange(RuleTargetAdapterValidator.Validate(dataset.TargetProfile, dataset.Screens.Select(x => x.ScreenNumber)));

        // 계좌 입력이 없는 화면군은 accounts를 생략할 수 있으며 실행기가 기본 컨텍스트 한 건을 만든다.
        if (dataset.Screens.Length == 0)
            issues.Add(new("RULE.SCREEN_REQUIRED", "At least one target screen is required."));
        if (!dataset.ExecutionPolicy.Mode.Equals("explicitErrorOnly", StringComparison.OrdinalIgnoreCase))
            issues.Add(new("RULE.ORACLE_MODE", "The current PoC supports only explicitErrorOnly mode."));
        if (dataset.ExecutionPolicy.ErrorPatterns.Length == 0)
            issues.Add(new("RULE.ERROR_PATTERN_REQUIRED", "At least one explicit error pattern is required."));
        if (dataset.AutoExploration.MaxControlsPerScreen is < 1 or > 1000)
            issues.Add(new("RULE.AUTO_CONTROL_LIMIT", "autoExploration.maxControlsPerScreen must be 1..1000."));
        if (!RuleInteractionStrategies.IsSupported(dataset.AutoExploration.InteractionStrategy))
            issues.Add(new("RULE.INTERACTION_STRATEGY", "autoExploration.interactionStrategy must be RuntimeTabOrder or CoordinateFocus.", Field: "autoExploration.interactionStrategy"));
        if (dataset.AutoExploration.MaxOptionsPerControl is < 1 or > 500)
            issues.Add(new("RULE.AUTO_OPTION_LIMIT", "autoExploration.maxOptionsPerControl must be 1..500."));
        if (dataset.AutoExploration.MaxActionsPerScreen is < 1 or > 100000)
            issues.Add(new("RULE.AUTO_ACTION_LIMIT", "autoExploration.maxActionsPerScreen must be 1..100000."));
        if (dataset.AutoExploration.MapBaseline.MatchTolerancePx is < 4 or > 300)
            issues.Add(new("RULE.MAP_MATCH_TOLERANCE", "autoExploration.mapBaseline.matchTolerancePx must be 4..300."));
        foreach (var value in dataset.AutoExploration.DefaultTextValues)
            ValidateExpectedOutcome(value.ExpectedOutcome, $"autoExploration.defaultTextValues[{value.Id}]", issues);
        foreach (var value in dataset.AutoExploration.DefaultDateValues)
        {
            if (!DateOnly.TryParseExact(value.Value, "yyyyMMdd", out _))
                issues.Add(new("RULE.AUTO_DATE_FORMAT", $"Date value {value.Id} must use yyyyMMdd format.", Field: "autoExploration.defaultDateValues"));
            ValidateExpectedOutcome(value.ExpectedOutcome, $"autoExploration.defaultDateValues[{value.Id}]", issues);
        }

        AddDuplicates(dataset.Accounts.Select(x => x.Id), "RULE.DUPLICATE_ACCOUNT_ID", "account id", issues);
        AddDuplicates(dataset.Screens.Select(x => x.ScreenNumber), "RULE.DUPLICATE_SCREEN", "screen number", issues);
        AddDuplicates(dataset.Variables.Select(x => x.Name), "RULE.DUPLICATE_VARIABLE", "variable name", issues);

        foreach (var account in dataset.Accounts)
        {
            // Prefilled 화면은 계좌 입력 자체가 없을 수 있으므로 값이 있을 때만 형식을 제한한다.
            if (!string.IsNullOrWhiteSpace(account.AccountNumber) && !AccountRegex.IsMatch(account.AccountNumber))
                issues.Add(new("RULE.ACCOUNT_FORMAT", $"Account {account.Id} must use ########-### format.", Field: "accountNumber"));
            if (account.InputMode == RuleInputMode.Explicit && string.IsNullOrWhiteSpace(account.AccountNumber))
                issues.Add(new("RULE.ACCOUNT_REQUIRED", $"Account {account.Id} requires accountNumber in Explicit input mode.", Field: "accountNumber"));
            if (account.InputMode == RuleInputMode.Explicit && account.PasswordSecret is null)
                issues.Add(new("RULE.SECRET_REQUIRED", $"Account {account.Id} requires passwordSecret in Explicit input mode.", Field: "passwordSecret"));
            else if (account.PasswordSecret is not null && !KeyRegex.IsMatch(account.PasswordSecret.Key))
                issues.Add(new("RULE.SECRET_KEY", $"Account {account.Id} has an invalid environment secret key.", Field: "passwordSecret.key"));
        }

        foreach (var screen in dataset.Screens)
        {
            if (screenIdRegex is not null && !screenIdRegex.IsMatch(screen.ScreenNumber))
                issues.Add(new("RULE.SCREEN_FORMAT", $"Screen {screen.ScreenNumber} does not match targetProfile.screenIdPattern.", Field: "screenNumber"));
            if (string.IsNullOrWhiteSpace(screen.QueryTrigger))
                issues.Add(new("RULE.QUERY_TRIGGER_REQUIRED", $"Screen {screen.ScreenNumber} requires a deterministic query trigger."));
            foreach (var pair in screen.Locators)
            {
                if (pair.Value.Length == 0)
                    issues.Add(new("RULE.LOCATOR_EMPTY", $"Screen {screen.ScreenNumber} locator role {pair.Key} has no strategies."));
                ValidateLocatorCoordinates(pair.Value, $"Screen {screen.ScreenNumber} role {pair.Key}", issues);
            }
        }

        foreach (var pair in dataset.DefaultLocators)
        {
            if (pair.Value.Length == 0)
                issues.Add(new("RULE.LOCATOR_EMPTY", $"Default locator role {pair.Key} has no strategies."));
            ValidateLocatorCoordinates(pair.Value, $"Default role {pair.Key}", issues);
        }

        foreach (var dimension in dataset.Variables)
        {
            if (dimension.Values.Length == 0)
                issues.Add(new("RULE.VARIABLE_VALUES_REQUIRED", $"Variable {dimension.Name} requires at least one value."));
            AddDuplicates(dimension.Values.Select(x => x.Id), "RULE.DUPLICATE_VARIABLE_VALUE", $"value id in {dimension.Name}", issues);
            foreach (var screen in dimension.AppliesToScreens.Where(x => x != "*"))
                if (!dataset.Screens.Any(x => x.ScreenNumber == screen))
                    issues.Add(new("RULE.VARIABLE_UNKNOWN_SCREEN", $"Variable {dimension.Name} references unknown screen {screen}."));
            if (dimension.ValueMatch == RuleValueMatch.Index && dimension.Values.Any(x => !int.TryParse(x.Value, out var index) || index < 0))
                issues.Add(new("RULE.VARIABLE_INDEX_VALUE", $"Variable {dimension.Name} uses Index matching and requires non-negative integer values."));
            if (dimension.ControlKind == RuleControlKind.CheckBox && dimension.Values.Any(x => !IsBooleanValue(x.Value)))
                issues.Add(new("RULE.VARIABLE_CHECKED_VALUE", $"Variable {dimension.Name} targets a CheckBox and requires true/false, 1/0, Y/N, or checked/unchecked values."));
            if (dimension.ControlKind == RuleControlKind.Date && dimension.Values.Any(x => !DateOnly.TryParseExact(x.Value, "yyyyMMdd", out _)))
                issues.Add(new("RULE.VARIABLE_DATE_VALUE", $"Variable {dimension.Name} targets a Date control and requires yyyyMMdd values."));
            foreach (var value in dimension.Values)
                ValidateExpectedOutcome(value.ExpectedOutcome, $"variables[{dimension.Name}].values[{value.Id}]", issues);
        }

        var projected = new CombinationGenerator().CountCases(dataset);
        if (projected > dataset.MaxExpandedCases)
            issues.Add(new("POLICY.CASE_LIMIT", $"Projected case count {projected} exceeds maxExpandedCases {dataset.MaxExpandedCases}."));
        return new(issues.Count == 0, issues);
    }

    private static bool IsBooleanValue(string value) => value.Trim().ToLowerInvariant() is
        "true" or "false" or "1" or "0" or "y" or "n" or "yes" or "no" or "checked" or "unchecked";

    private static void ValidateExpectedOutcome(
        RuleExpectedOutcome outcome,
        string field,
        List<ValidationIssue> issues)
    {
        if (outcome.Type is RuleExpectedOutcomeType.ValidationRequired or RuleExpectedOutcomeType.FailureRequired &&
            outcome.MessagePatterns.Length == 0 && outcome.ErrorCodes.Length == 0)
            issues.Add(new("RULE.EXPECTED_VALIDATION_EVIDENCE", $"{field} requires at least one messagePattern or errorCode for ValidationRequired.", Field: field));

        foreach (var pattern in outcome.MessagePatterns)
        {
            try { _ = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant); }
            catch (ArgumentException)
            {
                issues.Add(new("RULE.EXPECTED_MESSAGE_PATTERN", $"{field} contains an invalid regular expression: {pattern}", Field: field));
            }
        }
        foreach (var code in outcome.ErrorCodes.Where(x => !Regex.IsMatch(x, @"^[A-Za-z0-9_.-]{2,64}$", RegexOptions.CultureInvariant)))
            issues.Add(new("RULE.EXPECTED_ERROR_CODE", $"{field} contains an invalid expected error code: {code}", Field: field));
    }

    private static void ValidateLocatorCoordinates(RuleLocatorStrategy[] strategies, string label, List<ValidationIssue> issues)
    {
        foreach (var strategy in strategies)
        {
            if (strategy.RelativeX.HasValue != strategy.RelativeY.HasValue)
                issues.Add(new("RULE.LOCATOR_COORDINATE_PAIR", $"{label} must specify relativeX and relativeY together."));
            if (strategy.RelativeX is < 0 || strategy.RelativeY is < 0 || strategy.Width is <= 0 || strategy.Height is <= 0)
                issues.Add(new("RULE.LOCATOR_COORDINATE_RANGE", $"{label} coordinate locator requires non-negative coordinates and positive dimensions."));
        }
    }

    private static void AddDuplicates(IEnumerable<string> values, string code, string label, List<ValidationIssue> issues)
    {
        foreach (var value in values.GroupBy(x => x, StringComparer.OrdinalIgnoreCase).Where(x => x.Count() > 1).Select(x => x.Key))
            issues.Add(new(code, $"Duplicate {label}: {value}."));
    }
}

/// <summary>활성 화면, 계좌와 명시 변수값을 결정론적으로 조합하고 민감정보를 보호한다.</summary>
public static class RuleCaseExpander
{
    /// <summary>활성 계좌가 없을 때도 일반 화면 테스트가 한 번 실행되도록 기본 컨텍스트를 제공한다.</summary>
    public static RuleAccountInput[] ActiveExecutionContexts(RuleTestDataset dataset) =>
        CombinationGenerator.ActiveExecutionContexts(dataset);

    /// <summary>실제 배열을 만들지 않고 예상 케이스 수를 계산해 조합 폭증을 사전 차단한다.</summary>
    public static long CountCases(RuleTestDataset dataset) => new CombinationGenerator().CountCases(dataset);

    /// <summary>검증된 데이터셋을 실행 가능한 개별 테스트 케이스 배열로 확장한다.</summary>
    public static RuleTestCase[] Expand(RuleTestDataset dataset)
    {
        var validation = new RuleDatasetValidator().Validate(dataset);
        if (!validation.IsValid)
            throw new InvalidDataException(string.Join(Environment.NewLine, validation.Issues.Select(x => $"{x.Code}: {x.Message}")));

        return new CombinationGenerator().Generate(dataset);
    }

    /// <summary>리포트 저장 전에 계좌번호와 민감 변수를 마스킹한 사본을 만든다.</summary>
    public static SanitizedRuleTestCase Sanitize(RuleTestCase item) => new()
    {
        CaseId = item.CaseId,
        DatasetId = item.DatasetId,
        ScreenNumber = item.ScreenNumber,
        ScreenName = item.ScreenName,
        InputMode = item.InputMode,
        AccountId = item.AccountId,
        AccountMasked = MaskAccount(item.AccountNumber),
        AccountFingerprint = string.IsNullOrWhiteSpace(item.AccountNumber) ? "" : Fingerprint(item.AccountNumber, 12),
        AccountOwner = item.AccountOwner,
        PasswordSource = item.InputMode == RuleInputMode.Prefilled
            ? "화면 기본값"
            : $"{item.PasswordSecret!.Provider}:{item.PasswordSecret.Key}",
        Variables = item.Variables.ToDictionary(
            x => x.Key,
            x => item.SensitiveVariables.GetValueOrDefault(x.Key) ? "******" : x.Value,
            StringComparer.OrdinalIgnoreCase)
    };

    public static string ResolvePassword(RuleTestCase item)
    {
        if (item.InputMode == RuleInputMode.Prefilled)
            throw new InvalidOperationException("화면 기본값 입력 모드에서는 비밀번호를 조회하지 않습니다.");
        if (item.PasswordSecret is null)
            throw new InvalidOperationException("명시 입력 모드에 passwordSecret이 없습니다.");
        var value = item.PasswordSecret.Provider switch
        {
            SecretProvider.Environment => Environment.GetEnvironmentVariable(item.PasswordSecret.Key),
            _ => null
        };
        return !string.IsNullOrEmpty(value)
            ? value
            : throw new InvalidOperationException($"비밀번호 환경 변수 {item.PasswordSecret.Key}가 설정되지 않았습니다.");
    }

    public static string MaskAccount(string accountNumber)
    {
        if (string.IsNullOrWhiteSpace(accountNumber)) return "";
        var digits = new string(accountNumber.Where(char.IsDigit).ToArray());
        if (digits.Length < 7) return "******";
        return $"{digits[..3]}****{digits[^3..]}";
    }

    public static string Fingerprint(string value, int length)
    {
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
        return hash[..Math.Clamp(length, 4, hash.Length)];
    }

}

/// <summary>HTS를 조작하지 않고 계획과 산출물 구조만 검증하는 드라이런 결과를 만든다.</summary>
public sealed class RuleDryRunExecutor
{
    public RuleCaseResult Execute(string runId, RuleTestCase testCase)
    {
        var started = DateTimeOffset.Now;
        var safe = RuleCaseExpander.Sanitize(testCase);
        var actions = PlannedActions(testCase).Select(action => new RuleActionResult
        {
            Action = action,
            Status = TestStatus.PENDING,
            Output = "드라이런이므로 HTS 화면 조작을 실행하지 않았습니다."
        }).ToArray();
        return new RuleCaseResult
        {
            RunId = runId,
            CaseId = safe.CaseId,
            DatasetId = safe.DatasetId,
            ScreenNumber = safe.ScreenNumber,
            ScreenName = safe.ScreenName,
            InputMode = safe.InputMode == RuleInputMode.Prefilled ? "화면 기본값" : "데이터셋 명시 입력",
            AccountId = safe.AccountId,
            AccountMasked = safe.AccountMasked,
            AccountFingerprint = safe.AccountFingerprint,
            AccountOwner = safe.AccountOwner,
            InputVariables = safe.Variables,
            Status = TestStatus.PENDING,
            ErrorDetected = false,
            ErrorCode = "DRY_RUN",
            OutputSummary = "PENDING: 결정론적 규칙으로 생성했으며 HTS 화면은 실행하지 않았습니다.",
            Actions = actions,
            StartedAt = started,
            EndedAt = DateTimeOffset.Now,
            ElapsedMs = 0
        };
    }

    private static string[] PlannedActions(RuleTestCase item)
    {
        var actions = new List<string> { "openScreen" };
        if (item.InputMode == RuleInputMode.Prefilled)
            actions.Add("usePrefilledInputs");
        else
            actions.AddRange(["setAccount", "setPassword"]);
        actions.AddRange(item.Variables.Keys.OrderBy(x => x).Select(x => $"setCondition:{x}"));
        if (item.AutoExplorationEnabled)
            actions.AddRange(["discoverControls", "executeControlOptions"]);
        actions.Add("invokeQuery");
        actions.Add("evaluateExplicitErrors");
        actions.Add("closeScreen");
        return actions.ToArray();
    }
}
