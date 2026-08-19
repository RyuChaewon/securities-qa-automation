// 역할: HTS .map 바이너리와 포함 스크립트를 화면·컨트롤·이벤트·오류·화면전환 기준 모델로 변환한다.
// 입력/출력: 화면 MAP 파일을 읽어 직렬화 가능한 HtsMapScreenModel과 오라클·동작 그래프를 만든다.
// 경계: MAP은 설계 기준이며 실제 활성·가시·포커스 상태는 런타임 바인더가 판정한다.
// 수정 지점: 레코드 길이·인코딩·스크립트 문법은 설치본 종속이므로 샘플 MAP 회귀 테스트와 함께 변경한다.
using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace HtsQa.Core;

// MAP 직렬화 모델 ---------------------------------------------------------------
public enum HtsMapControlKind
{
    Unknown,
    EmbeddedScreen,
    Tab,
    StaticText,
    Label,
    Button,
    Text,
    Instrument,
    ComboBox,
    Account,
    Date,
    GroupBox,
    CheckBox,
    RadioGroup,
    Grid,
    Chart,
    Image,
    Password,
    EmbeddedFrame,
    Spin,
    Web,
    Tree,
    Timer,
    CalendarDiary,
    Explorer,
    SplitButton,
    Slider,
    Custom
}

public sealed record HtsMapRect
{
    public required int X { get; init; }
    public required int Y { get; init; }
    public required int Width { get; init; }
    public required int Height { get; init; }
    public int Right => X + Width;
    public int Bottom => Y + Height;
    public double CenterX => X + (Width / 2.0);
    public double CenterY => Y + (Height / 2.0);
}

public sealed record HtsMapControlDefinition
{
    public required string ModelId { get; init; }
    public required int DefinitionOrder { get; init; }
    public required string TypeCode { get; init; }
    public required HtsMapControlKind Kind { get; init; }
    public required string RuleControlKind { get; init; }
    public required string LogicalName { get; init; }
    public required string ParentName { get; init; }
    public required HtsMapRect Rect { get; init; }
    public required bool IsActionable { get; init; }
    public required bool IsTabStopCandidate { get; init; }
    public string[] Events { get; init; } = [];
    public string SemanticRole { get; init; } = "";
    public string[] TriggeredRequestNames { get; init; } = [];
    public string[] ReadControls { get; init; } = [];
    public string[] AffectedControls { get; init; } = [];
    public string[] ResultControls { get; init; } = [];
    public string[] InvokedHandlers { get; init; } = [];
    public HtsMapNavigationDefinition[] NavigationTargets { get; init; } = [];
    public HtsMapOptionDefinition[] StaticOptions { get; init; } = [];
    public string OptionSource { get; init; } = "";
}

public sealed record HtsMapOptionDefinition
{
    public required string Id { get; init; }
    public required string Value { get; init; }
    public required string DisplayValue { get; init; }
    public required int Index { get; init; }
    public required string Source { get; init; }
    public RuleExpectedOutcome ExpectedOutcome { get; init; } = new();
}

public sealed record HtsMapNavigationDefinition
{
    public required string RuleId { get; init; }
    public required string SourceScreenCode { get; init; }
    public required string SourceControl { get; init; }
    public required string Handler { get; init; }
    public required string Api { get; init; }
    public required string Kind { get; init; }
    public required string TargetExpression { get; init; }
    public string TargetScreenCode { get; init; } = "";
    public string TargetMapFile { get; init; } = "";
    public bool IsDynamic { get; init; }
    public bool TargetExists { get; init; }
    public string TargetSourceFile { get; init; } = "";
    public string TargetSha256 { get; init; } = "";
}

public sealed record HtsMapMessageDefinition
{
    public required string RuleId { get; init; }
    public required string Api { get; init; }
    public required string Handler { get; init; }
    public required string Message { get; init; }
    public required string Title { get; init; }
    public required string Classification { get; init; }
    public required bool IsExplicitError { get; init; }
    public string[] TargetControls { get; init; } = [];
    public string ConditionExpression { get; init; } = "";
}

public sealed record HtsMapEventHandlerDefinition
{
    public required string Handler { get; init; }
    public required string SourceControl { get; init; }
    public required string Event { get; init; }
    public required string SemanticRole { get; init; }
    public string[] DirectRequestNames { get; init; } = [];
    public string[] EffectiveRequestNames { get; init; } = [];
    public string[] ReadControls { get; init; } = [];
    public string[] AffectedControls { get; init; } = [];
    public string[] ResultControls { get; init; } = [];
    public string[] InvokedHandlers { get; init; } = [];
    public HtsMapNavigationDefinition[] NavigationTargets { get; init; } = [];
}

public sealed record HtsMapBehaviorDefinition
{
    public HtsMapEventHandlerDefinition[] EventHandlers { get; init; } = [];
    public string[] QueryControls { get; init; } = [];
    public string[] AutoQueryControls { get; init; } = [];
    public string[] PaginationControls { get; init; } = [];
    public string[] ExportControls { get; init; } = [];
    public string[] NavigationControls { get; init; } = [];
    public string[] StateControllerControls { get; init; } = [];
    public string[] InputControls { get; init; } = [];
    public string[] ResultControls { get; init; } = [];
    public HtsMapNavigationDefinition[] NavigationTargets { get; init; } = [];
}

public sealed record HtsMapErrorOracleDefinition
{
    public required bool HasReceiveErrorParameters { get; init; }
    public required bool HasOnErrorHandler { get; init; }
    public string[] ErrorHandlers { get; init; } = [];
    public HtsMapMessageDefinition[] MessageBoxes { get; init; } = [];
    public string[] RequestNames { get; init; } = [];
    public string[] TransactionCodes { get; init; } = [];
}

public sealed record HtsMapScreenDefinition
{
    public string SchemaVersion { get; init; } = "1.4";
    public required string ScreenNumber { get; init; }
    public required string ScreenCode { get; init; }
    public required string ScreenName { get; init; }
    public required string SourceFile { get; init; }
    public required string SourceSha256 { get; init; }
    public required DateTimeOffset SourceLastWriteTime { get; init; }
    public required int DesignWidth { get; init; }
    public required int DesignHeight { get; init; }
    public required HtsMapControlDefinition[] Controls { get; init; }
    public required HtsMapErrorOracleDefinition ErrorOracle { get; init; }
    public required HtsMapBehaviorDefinition Behavior { get; init; }
    public int ActionableControlCount => Controls.Count(x => x.IsActionable);
    public HtsScreenRegistryDefinition? Registry { get; init; }
    public string[] TabGroups { get; init; } = [];
    public string[] TabSiblings { get; init; } = [];
    public HtsMapDataReferenceDefinition[] DataReferences { get; init; } = [];
    public HtsIntegrityDefinition? Integrity { get; init; }
    public HtsMapNavigationDefinition[] Dependencies { get; init; } = [];
    public string[] Warnings { get; init; } = [];
}

public sealed record HtsMapCatalog
{
    public string SchemaVersion { get; init; } = "1.4";
    public required DateTimeOffset GeneratedAt { get; init; }
    public required string ScreenDirectory { get; init; }
    public required string FilePattern { get; init; }
    public string[] FamilyFiles { get; init; } = [];
    public required string[] RequestedScreens { get; init; }
    public required string[] MissingScreens { get; init; }
    public required HtsMapScreenDefinition[] Screens { get; init; }
    public string InstallationRoot { get; init; } = "";
    public string InstallationFingerprint { get; init; } = "";
    public HtsScreenRegistryDefinition[] ScreenRegistry { get; init; } = [];
    public HtsScreenAliasDefinition[] ScreenAliases { get; init; } = [];
    public HtsTabGroupDefinition[] TabGroups { get; init; } = [];
    public HtsControlTypeDefinition[] ControlTypes { get; init; } = [];
    public HtsErrorCodeDefinition[] ErrorCodes { get; init; } = [];
    public HtsIntegrityDefinition[] IntegrityEntries { get; init; } = [];
    public HtsMapScreenDefinition[] DependencyScreens { get; init; } = [];
    public HtsMapNavigationDefinition[] Dependencies { get; init; } = [];
    public HtsMasterDataSourceDefinition[] MasterDataSources { get; init; } = [];
    public HtsLogSourceDefinition[] LogSources { get; init; } = [];
    public string[] Warnings { get; init; } = [];
}

/// <summary>단일 MAP 또는 화면 집합을 구조화된 기준 모델로 파싱한다.</summary>
public sealed class HtsMapParser
{
    private const int ControlRecordLength = 54;
    private const int FixedNameLength = 21;
    private static readonly Regex ScreenCodeRegex = new("HT(?<number>[0-9]{4}[0-9A-Z]{2})", RegexOptions.CultureInvariant);
    private static readonly Regex IdentifierRegex = new("^[A-Za-z][A-Za-z0-9_]*$", RegexOptions.CultureInvariant);
    private static readonly Regex HandlerRegex = new(
        @"\b(?:Sub|Function)\s+(?<name>[A-Za-z][A-Za-z0-9_]*)\s*\((?<parameters>[^)]*)\)(?<body>.*?)\bEnd\s+(?:Sub|Function)\b",
        RegexOptions.IgnoreCase | RegexOptions.Singleline | RegexOptions.CultureInvariant);
    private static readonly Regex MessageCallRegex = new(
        @"\b(?<api>FormMsgBox2|FormMsgBox)\s*\((?<arguments>[^)]{0,2000})\)",
        RegexOptions.IgnoreCase | RegexOptions.Singleline | RegexOptions.CultureInvariant);
    private static readonly Regex QuotedStringRegex = new(
        "\"(?<value>(?:\"\"|[^\"])*)\"",
        RegexOptions.Singleline | RegexOptions.CultureInvariant);
    private static readonly Regex RequestNameRegex = new(
        @"\bRQ_[A-Za-z0-9_]+\b",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex RequestDispatchRegex = new(
        @"\b(?:CommRequest|SetTranRqData|SetInputQuery(?:Ex)?)\s*\((?<arguments>[^)]{0,2000})\)",
        RegexOptions.IgnoreCase | RegexOptions.Singleline | RegexOptions.CultureInvariant);
    private static readonly Regex TransactionCodeRegex = new(
        @"\b(?<code>[A-Z]{2,8}[0-9]{4,}[A-Z0-9]*)\b",
        RegexOptions.CultureInvariant);
    private static readonly Regex ControlMemberRegex = new(
        @"\b(?<control>[A-Za-z][A-Za-z0-9_]*)\.(?<member>[A-Za-z][A-Za-z0-9_]*)\b",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex PropertyAssignmentRegex = new(
        @"\b(?<control>[A-Za-z][A-Za-z0-9_]*)\.(?<member>Enabled|Visible|CheckState|Caption|Value|ForeColorIndex)\s*=",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex HandlerCallRegex = new(
        @"(?:\bCall\s+)?\b(?<name>[A-Za-z][A-Za-z0-9_]*)\s*\(",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex NavigationCallRegex = new(
        @"\b(?<api>OpenScreen|DialogScreenCreate|CreateLinkScreen|OpenMenuScreen|OpenMapCreateFromCode)\s*\((?<arguments>[^)]{0,2000})\)",
        RegexOptions.IgnoreCase | RegexOptions.Singleline | RegexOptions.CultureInvariant);
    private static readonly Encoding KoreanEncoding = CreateKoreanEncoding();
    private readonly IReadOnlyDictionary<string, HtsMapControlKind>? controlKinds;

    public HtsMapParser(IReadOnlyDictionary<string, HtsMapControlKind>? controlKinds = null)
    {
        this.controlKinds = controlKinds;
    }

    private sealed record ScriptHandler(string Name, string Parameters, string Body);

    private sealed class HandlerDraft
    {
        public required ScriptHandler Script { get; init; }
        public required string SourceControl { get; init; }
        public required string Event { get; init; }
        public HashSet<string> DirectRequests { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> Reads { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> Writes { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> Results { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> InvokedHandlers { get; } = new(StringComparer.OrdinalIgnoreCase);
        public List<HtsMapNavigationDefinition> NavigationTargets { get; } = [];
    }

    /// <summary>한 MAP 파일에서 화면 크기, 컨트롤, 동작 그래프와 오류 오라클을 추출한다.</summary>
    public HtsMapScreenDefinition Parse(string path, bool allowEmptyControls = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var fullPath = Path.GetFullPath(path);
        var bytes = File.ReadAllBytes(fullPath);
        var screenCodeMatch = ScreenCodeRegex.Match(Encoding.ASCII.GetString(bytes, 0, Math.Min(bytes.Length, 160)));
        if (!screenCodeMatch.Success)
            throw new InvalidDataException($"MAP 화면 코드를 찾을 수 없습니다: {fullPath}");

        var sixDigitNumber = screenCodeMatch.Groups["number"].Value;
        var screenNumber = sixDigitNumber[..4];
        var screenCode = screenCodeMatch.Value;
        var screenName = ReadScreenName(bytes, screenCode);
        var script = KoreanEncoding.GetString(bytes).Replace('\0', ' ');
        var controls = ParseControls(bytes, screenNumber, screenCode);
        var behavior = ParseBehavior(script, controls, screenCode, screenNumber);
        controls = EnrichControls(controls, behavior);
        var errorOracle = ParseErrorOracle(script, screenNumber, controls);
        if (controls.Length == 0 && !allowEmptyControls)
            throw new InvalidDataException($"MAP 컨트롤 레코드를 찾을 수 없습니다: {fullPath}");

        var warnings = new List<string>();
        if (string.IsNullOrWhiteSpace(screenName))
            warnings.Add("화면 한글명을 읽지 못했습니다.");
        if (controls.Length == 0)
            warnings.Add("컨트롤이 없는 컨테이너 MAP입니다. family의 하위 MAP을 함께 사용해야 합니다.");
        if (!Path.GetFileNameWithoutExtension(fullPath).Contains(screenNumber, StringComparison.OrdinalIgnoreCase))
            warnings.Add("파일명과 MAP 내부 화면번호가 일치하지 않을 수 있습니다.");

        return new HtsMapScreenDefinition
        {
            ScreenNumber = screenNumber,
            ScreenCode = screenCode,
            ScreenName = screenName,
            SourceFile = fullPath,
            SourceSha256 = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
            SourceLastWriteTime = File.GetLastWriteTimeUtc(fullPath),
            DesignWidth = controls.Length == 0 ? 0 : controls.Max(x => x.Rect.Right),
            DesignHeight = controls.Length == 0 ? 0 : controls.Max(x => x.Rect.Bottom),
            Controls = controls,
            ErrorOracle = errorOracle,
            Behavior = behavior,
            Warnings = warnings.ToArray()
        };
    }

    /// <summary>요청 화면 목록을 파싱하고 누락 화면을 포함한 카탈로그로 묶는다.</summary>
    public HtsMapCatalog ParseCatalog(string screenDirectory, IEnumerable<string> screenNumbers, string filePattern)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(screenDirectory);
        ArgumentException.ThrowIfNullOrWhiteSpace(filePattern);
        if (!filePattern.Contains("{screenNumber}", StringComparison.Ordinal))
            throw new ArgumentException("MAP 파일 패턴에는 {screenNumber}가 포함되어야 합니다.", nameof(filePattern));

        var fullDirectory = Path.GetFullPath(screenDirectory);
        var requested = screenNumbers
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Select(NormalizeScreenNumber)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var missing = new List<string>();
        var screens = new List<HtsMapScreenDefinition>();

        foreach (var screenNumber in requested)
        {
            var fileName = filePattern.Replace("{screenNumber}", screenNumber, StringComparison.Ordinal);
            var path = Path.Combine(fullDirectory, fileName);
            if (!File.Exists(path))
            {
                missing.Add(screenNumber);
                continue;
            }
            screens.Add(Parse(path));
        }

        return new HtsMapCatalog
        {
            GeneratedAt = DateTimeOffset.Now,
            ScreenDirectory = fullDirectory,
            FilePattern = filePattern,
            RequestedScreens = requested,
            MissingScreens = missing.ToArray(),
            Screens = screens.ToArray()
        };
    }

    /// <summary>화면 번호가 같은 컨테이너/탭 MAP을 명시한 순서대로 모두 파싱한다.</summary>
    public HtsMapCatalog ParseFamilyCatalog(
        string screenDirectory,
        IEnumerable<string> screenNumbers,
        IEnumerable<string> familyFiles,
        string filePattern = "")
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(screenDirectory);
        var fullDirectory = Path.GetFullPath(screenDirectory);
        var requested = screenNumbers
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Select(NormalizeScreenNumber)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var files = familyFiles
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Select(x => Path.GetFileName(x)!)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (files.Length == 0)
            throw new ArgumentException("MAP family 파일이 하나 이상 필요합니다.", nameof(familyFiles));

        var missing = new List<string>();
        var screens = new List<HtsMapScreenDefinition>();
        foreach (var file in files)
        {
            var path = Path.Combine(fullDirectory, file);
            if (!File.Exists(path))
            {
                missing.Add(file);
                continue;
            }
            screens.Add(Parse(path, allowEmptyControls: true));
        }

        return new HtsMapCatalog
        {
            GeneratedAt = DateTimeOffset.Now,
            ScreenDirectory = fullDirectory,
            FilePattern = filePattern,
            FamilyFiles = files,
            RequestedScreens = requested,
            MissingScreens = missing.ToArray(),
            Screens = screens.ToArray()
        };
    }

    private HtsMapControlDefinition[] ParseControls(byte[] bytes, string screenNumber, string screenCode)
    {
        var ascii = Encoding.ASCII.GetString(bytes);
        var controls = new List<HtsMapControlDefinition>();
        for (var offset = 0; offset <= bytes.Length - ControlRecordLength; offset++)
        {
            if (!LooksLikeControlRecord(bytes, offset)) continue;

            var typeCode = Encoding.ASCII.GetString(bytes, offset + 1, 2);
            var parentName = ReadFixedAscii(bytes, offset + 12, FixedNameLength);
            var logicalName = ReadFixedAscii(bytes, offset + 33, FixedNameLength);
            if (!IdentifierRegex.IsMatch(parentName) || !IdentifierRegex.IsMatch(logicalName)) continue;

            var rect = new HtsMapRect
            {
                X = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(offset + 4, 2)),
                Y = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(offset + 6, 2)),
                Width = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(offset + 8, 2)),
                Height = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(offset + 10, 2))
            };
            if (rect.Width > 8192 || rect.Height > 8192 || rect.X > 16384 || rect.Y > 16384) continue;

            var kind = MapKind(typeCode);
            var ruleKind = MapRuleControlKind(kind);
            var actionable = IsActionable(kind);
            var order = controls.Count;
            controls.Add(new HtsMapControlDefinition
            {
                ModelId = $"MAP-{screenCode}-{logicalName}-{order:D3}",
                DefinitionOrder = order,
                TypeCode = typeCode,
                Kind = kind,
                RuleControlKind = ruleKind,
                LogicalName = logicalName,
                ParentName = parentName,
                Rect = rect,
                IsActionable = actionable,
                IsTabStopCandidate = actionable && kind is not HtsMapControlKind.Button,
                Events = FindEvents(ascii, logicalName)
            });
            offset += ControlRecordLength - 1;
        }
        return controls.ToArray();
    }

    private static bool LooksLikeControlRecord(byte[] bytes, int offset) =>
        bytes[offset] == 0xff &&
        bytes[offset + 1] is >= (byte)'0' and <= (byte)'9' &&
        bytes[offset + 2] is >= (byte)'0' and <= (byte)'9' &&
        bytes[offset + 3] == 0;

    private static string ReadFixedAscii(byte[] bytes, int offset, int length)
    {
        var count = Array.IndexOf(bytes, (byte)0, offset, length);
        if (count < 0) count = offset + length;
        return Encoding.ASCII.GetString(bytes, offset, count - offset).Trim();
    }

    private static string ReadScreenName(byte[] bytes, string screenCode)
    {
        var code = Encoding.ASCII.GetBytes(screenCode);
        var offset = bytes.AsSpan().IndexOf(code);
        if (offset < 0) return string.Empty;
        offset += code.Length;
        while (offset < bytes.Length && bytes[offset] == 0) offset++;
        var end = Array.IndexOf(bytes, (byte)0, offset);
        if (end < 0) end = Math.Min(bytes.Length, offset + 80);
        return KoreanEncoding.GetString(bytes, offset, end - offset).Trim();
    }

    private static string[] FindEvents(string ascii, string logicalName)
    {
        var pattern = $@"\b{Regex.Escape(logicalName)}_(?<event>[A-Za-z][A-Za-z0-9_]*)\b";
        return Regex.Matches(ascii, pattern, RegexOptions.CultureInvariant)
            .Select(x => x.Groups["event"].Value)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static ScriptHandler[] ParseScriptHandlers(string script) => HandlerRegex.Matches(script)
        .Select(match => new ScriptHandler(
            match.Groups["name"].Value,
            match.Groups["parameters"].Value,
            match.Groups["body"].Value))
        .ToArray();

    private static HtsMapBehaviorDefinition ParseBehavior(
        string script,
        HtsMapControlDefinition[] controls,
        string screenCode,
        string screenNumber)
    {
        var handlers = ParseScriptHandlers(script);
        var controlByName = controls
            .GroupBy(x => x.LogicalName, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(x => x.Key, x => x.First(), StringComparer.OrdinalIgnoreCase);
        var controlNames = controlByName.Keys.OrderByDescending(x => x.Length).ToArray();
        var handlerNames = handlers.Select(x => x.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var drafts = new Dictionary<string, HandlerDraft>(StringComparer.OrdinalIgnoreCase);

        foreach (var handler in handlers)
        {
            var sourceControl = controlNames.FirstOrDefault(name =>
                handler.Name.StartsWith(name + "_", StringComparison.OrdinalIgnoreCase)) ?? string.Empty;
            var eventName = sourceControl.Length > 0 ? handler.Name[(sourceControl.Length + 1)..] : string.Empty;
            var draft = new HandlerDraft { Script = handler, SourceControl = sourceControl, Event = eventName };

            foreach (Match dispatch in RequestDispatchRegex.Matches(handler.Body))
            {
                foreach (Match request in RequestNameRegex.Matches(dispatch.Groups["arguments"].Value))
                    draft.DirectRequests.Add(request.Value.ToUpperInvariant());
            }
            foreach (Match call in HandlerCallRegex.Matches(handler.Body))
            {
                var called = call.Groups["name"].Value;
                if (!called.Equals(handler.Name, StringComparison.OrdinalIgnoreCase) && handlerNames.Contains(called))
                    draft.InvokedHandlers.Add(called);
            }
            var navigationIndex = 0;
            foreach (Match navigation in NavigationCallRegex.Matches(handler.Body))
            {
                var api = navigation.Groups["api"].Value;
                var arguments = SplitVbArguments(navigation.Groups["arguments"].Value);
                var expression = arguments.FirstOrDefault()?.Trim() ?? string.Empty;
                var literal = ReadQuotedLiteral(expression);
                var targetCode = NormalizeTargetScreenCode(literal);
                draft.NavigationTargets.Add(new HtsMapNavigationDefinition
                {
                    RuleId = $"MAP-NAV-{screenNumber}-{handler.Name}-{++navigationIndex:D2}",
                    SourceScreenCode = screenCode,
                    SourceControl = sourceControl,
                    Handler = handler.Name,
                    Api = api,
                    Kind = ClassifyNavigationKind(api),
                    TargetExpression = expression.Length <= 200 ? expression : expression[..200],
                    TargetScreenCode = targetCode,
                    TargetMapFile = targetCode.Length > 0 ? targetCode.ToLowerInvariant() + ".map" : string.Empty,
                    IsDynamic = targetCode.Length == 0
                });
            }

            var assignedMembers = PropertyAssignmentRegex.Matches(handler.Body)
                .Select(x => $"{x.Groups["control"].Value}.{x.Groups["member"].Value}")
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (Match memberMatch in ControlMemberRegex.Matches(handler.Body))
            {
                var controlName = memberMatch.Groups["control"].Value;
                var memberName = memberMatch.Groups["member"].Value;
                if (!controlByName.TryGetValue(controlName, out var control)) continue;

                var memberKey = $"{controlName}.{memberName}";
                var isWrite = assignedMembers.Contains(memberKey) || IsWriteMember(memberName);
                var isRead = memberName.StartsWith("Get", StringComparison.OrdinalIgnoreCase) ||
                    (!isWrite && memberName is "Value" or "CheckState" or "Caption");
                if (isWrite) draft.Writes.Add(control.LogicalName);
                if (isRead) draft.Reads.Add(control.LogicalName);
                if (isWrite && control.Kind is HtsMapControlKind.Grid or HtsMapControlKind.Chart or HtsMapControlKind.Image)
                    draft.Results.Add(control.LogicalName);
            }
            drafts[handler.Name] = draft;
        }

        var eventHandlers = drafts.Values.Select(draft =>
        {
            var requests = ExpandDraftValues(draft, drafts, x => x.DirectRequests);
            var reads = ExpandDraftValues(draft, drafts, x => x.Reads);
            var writes = ExpandDraftValues(draft, drafts, x => x.Writes);
            var results = ExpandDraftValues(draft, drafts, x => x.Results);
            var role = ClassifyHandlerRole(draft, requests, writes, controlByName);
            return new HtsMapEventHandlerDefinition
            {
                Handler = draft.Script.Name,
                SourceControl = draft.SourceControl,
                Event = draft.Event,
                SemanticRole = role,
                DirectRequestNames = SortValues(draft.DirectRequests),
                EffectiveRequestNames = SortValues(requests),
                ReadControls = SortValues(reads),
                AffectedControls = SortValues(writes.Where(x => !x.Equals(draft.SourceControl, StringComparison.OrdinalIgnoreCase))),
                ResultControls = SortValues(results),
                InvokedHandlers = SortValues(draft.InvokedHandlers),
                NavigationTargets = draft.NavigationTargets.ToArray()
            };
        }).OrderBy(x => x.Handler, StringComparer.OrdinalIgnoreCase).ToArray();

        var queryHandlers = eventHandlers.Where(x => x.SemanticRole is "Query" or "AutoQuery").ToArray();
        var resultHandlers = eventHandlers.Where(x => x.SemanticRole is "Query" or "AutoQuery" or "Pagination").ToArray();
        var inputControls = queryHandlers.SelectMany(x => x.ReadControls).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (queryHandlers.Any(x => x.InvokedHandlers.Contains("IsValidAccPw", StringComparer.OrdinalIgnoreCase)))
        {
            inputControls.UnionWith(controls
                .Where(x => x.Kind is HtsMapControlKind.Account or HtsMapControlKind.Password)
                .Select(x => x.LogicalName));
        }
        string[] ActionableSourceControls(string role) => SortValues(eventHandlers
            .Where(x => x.SemanticRole == role &&
                controlByName.TryGetValue(x.SourceControl, out var control) && control.IsActionable)
            .Select(x => x.SourceControl));
        return new HtsMapBehaviorDefinition
        {
            EventHandlers = eventHandlers,
            QueryControls = ActionableSourceControls("Query"),
            AutoQueryControls = ActionableSourceControls("AutoQuery"),
            PaginationControls = ActionableSourceControls("Pagination"),
            ExportControls = ActionableSourceControls("Export"),
            NavigationControls = ActionableSourceControls("Navigation"),
            StateControllerControls = ActionableSourceControls("StateController"),
            InputControls = SortValues(inputControls
                .Where(x => controlByName.TryGetValue(x, out var control) && control.IsActionable && control.Kind is not HtsMapControlKind.Button)),
            ResultControls = SortValues(resultHandlers.SelectMany(x => x.ResultControls)),
            NavigationTargets = eventHandlers.SelectMany(x => x.NavigationTargets).ToArray()
        };
    }

    private static HtsMapControlDefinition[] EnrichControls(
        HtsMapControlDefinition[] controls,
        HtsMapBehaviorDefinition behavior)
    {
        var rolePriority = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
        {
            ["Query"] = 100, ["AutoQuery"] = 90, ["Pagination"] = 80, ["Export"] = 70,
            ["Navigation"] = 60, ["StateController"] = 50, ["Command"] = 40,
            ["Input"] = 30, ["Result"] = 20, ["Display"] = 10, ["Event"] = 0
        };
        return controls.Select(control =>
        {
            var handlers = behavior.EventHandlers
                .Where(x => x.SourceControl.Equals(control.LogicalName, StringComparison.OrdinalIgnoreCase))
                .ToArray();
            var role = handlers
                .OrderByDescending(x => rolePriority.TryGetValue(x.SemanticRole, out var priority) ? priority : 0)
                .Select(x => x.SemanticRole)
                .FirstOrDefault();
            role ??= control.Kind switch
            {
                HtsMapControlKind.Button => "Command",
                HtsMapControlKind.Account or HtsMapControlKind.Password or HtsMapControlKind.Text or
                    HtsMapControlKind.Instrument or HtsMapControlKind.ComboBox or HtsMapControlKind.Date or
                    HtsMapControlKind.CheckBox or HtsMapControlKind.RadioGroup or HtsMapControlKind.Tab => "Input",
                HtsMapControlKind.Grid or HtsMapControlKind.Chart => "Result",
                _ => "Display"
            };
            return control with
            {
                SemanticRole = role,
                TriggeredRequestNames = SortValues(handlers.SelectMany(x => x.EffectiveRequestNames)),
                ReadControls = SortValues(handlers.SelectMany(x => x.ReadControls)),
                AffectedControls = SortValues(handlers.SelectMany(x => x.AffectedControls)),
                ResultControls = SortValues(handlers.SelectMany(x => x.ResultControls)),
                InvokedHandlers = SortValues(handlers.SelectMany(x => x.InvokedHandlers)),
                NavigationTargets = handlers.SelectMany(x => x.NavigationTargets).ToArray()
            };
        }).ToArray();
    }

    private static string ReadQuotedLiteral(string expression)
    {
        var match = Regex.Match(expression, "^\\s*\"(?<value>[^\"]+)\"\\s*$", RegexOptions.CultureInvariant);
        return match.Success ? match.Groups["value"].Value.Trim() : string.Empty;
    }

    private static string NormalizeTargetScreenCode(string literal)
    {
        if (Regex.IsMatch(literal, "^[0-9]{4}$", RegexOptions.CultureInvariant))
            return $"HT{literal}00";
        return Regex.IsMatch(literal, "^HT[A-Za-z0-9]{4,12}$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)
            ? literal.ToUpperInvariant()
            : string.Empty;
    }

    private static string ClassifyNavigationKind(string api) => api.ToUpperInvariant() switch
    {
        "DIALOGSCREENCREATE" => "Dialog",
        "CREATELINKSCREEN" => "LinkedScreen",
        "OPENSCREEN" => "EmbeddedOrChildScreen",
        "OPENMENUSCREEN" => "MenuScreen",
        _ => "DynamicScreen"
    };

    private static HashSet<string> ExpandDraftValues(
        HandlerDraft draft,
        IReadOnlyDictionary<string, HandlerDraft> drafts,
        Func<HandlerDraft, IEnumerable<string>> selector,
        HashSet<string>? visiting = null)
    {
        visiting ??= new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (!visiting.Add(draft.Script.Name)) return new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var values = new HashSet<string>(selector(draft), StringComparer.OrdinalIgnoreCase);
        foreach (var invoked in draft.InvokedHandlers)
        {
            if (drafts.TryGetValue(invoked, out var child))
                values.UnionWith(ExpandDraftValues(child, drafts, selector, visiting));
        }
        visiting.Remove(draft.Script.Name);
        return values;
    }

    private static string ClassifyHandlerRole(
        HandlerDraft draft,
        IReadOnlyCollection<string> effectiveRequests,
        IReadOnlyCollection<string> writes,
        IReadOnlyDictionary<string, HtsMapControlDefinition> controls)
    {
        if (draft.Script.Name.EndsWith("OnError", StringComparison.OrdinalIgnoreCase)) return "ErrorHandler";
        if (draft.Event.Contains("Receive", StringComparison.OrdinalIgnoreCase) ||
            draft.Event.Contains("RequestAction", StringComparison.OrdinalIgnoreCase)) return "Receive";
        if (draft.SourceControl.Length == 0)
            return draft.Script.Name.Contains("Receive", StringComparison.OrdinalIgnoreCase) ? "Receive" : "Lifecycle";

        controls.TryGetValue(draft.SourceControl, out var source);
        if (source?.Kind == HtsMapControlKind.Button)
        {
            if (draft.SourceControl.Contains("NEXT", StringComparison.OrdinalIgnoreCase) && effectiveRequests.Count > 0) return "Pagination";
            if (draft.SourceControl.Contains("EXCEL", StringComparison.OrdinalIgnoreCase) ||
                draft.Script.Body.Contains("SetPopupMenuProc", StringComparison.OrdinalIgnoreCase)) return "Export";
            if (Regex.IsMatch(draft.Script.Body, @"Open(Map|Menu|Screen)|SetLinkInfoTagData", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)) return "Navigation";
            if (effectiveRequests.Count > 0) return "Query";
            if (Regex.IsMatch(draft.SourceControl, @"^BTN_(COMM|SEARCH|QUERY)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant) &&
                Regex.IsMatch(draft.Script.Body, @"SetAccountReg|SetCommCal|ClearAllData", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)) return "Query";
            return "Command";
        }
        if (effectiveRequests.Count > 0) return "AutoQuery";
        if (writes.Any(x => !x.Equals(draft.SourceControl, StringComparison.OrdinalIgnoreCase))) return "StateController";
        return "Event";
    }

    private static bool IsWriteMember(string memberName) =>
        memberName.StartsWith("Set", StringComparison.OrdinalIgnoreCase) ||
        memberName.StartsWith("Clear", StringComparison.OrdinalIgnoreCase) ||
        memberName.StartsWith("Add", StringComparison.OrdinalIgnoreCase) ||
        memberName.StartsWith("Delete", StringComparison.OrdinalIgnoreCase) ||
        memberName.StartsWith("Enable", StringComparison.OrdinalIgnoreCase) ||
        memberName.StartsWith("Show", StringComparison.OrdinalIgnoreCase) ||
        memberName.StartsWith("Move", StringComparison.OrdinalIgnoreCase) ||
        memberName.StartsWith("Open", StringComparison.OrdinalIgnoreCase) ||
        memberName.StartsWith("Close", StringComparison.OrdinalIgnoreCase);

    private static string[] SortValues(IEnumerable<string> values) => values
        .Where(x => !string.IsNullOrWhiteSpace(x))
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
        .ToArray();

    private static HtsMapErrorOracleDefinition ParseErrorOracle(
        string script,
        string screenNumber,
        HtsMapControlDefinition[] controls)
    {
        var handlers = ParseScriptHandlers(script);

        var errorHandlers = handlers
            .Where(x => x.Name.EndsWith("OnError", StringComparison.OrdinalIgnoreCase))
            .Select(x => x.Name)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        var messages = new List<HtsMapMessageDefinition>();
        var seenMessages = new HashSet<string>(StringComparer.Ordinal);
        foreach (var handler in handlers)
        {
            foreach (Match call in MessageCallRegex.Matches(handler.Body))
            {
                var api = call.Groups["api"].Value;
                var arguments = SplitVbArguments(call.Groups["arguments"].Value);
                var messageIndex = api.Equals("FormMsgBox2", StringComparison.OrdinalIgnoreCase) ? 0 : 1;
                var titleIndex = messageIndex + 1;
                if (arguments.Length <= messageIndex) continue;
                var message = ResolveVbString(arguments[messageIndex], handler.Body, call.Index);
                var title = arguments.Length > titleIndex
                    ? ResolveVbString(arguments[titleIndex], handler.Body, call.Index)
                    : string.Empty;
                if (string.IsNullOrWhiteSpace(message)) continue;
                var classification = ClassifyMessage(handler.Name, message, title);
                var key = $"{api}\n{handler.Name}\n{message}\n{title}";
                if (!seenMessages.Add(key)) continue;

                messages.Add(new HtsMapMessageDefinition
                {
                    RuleId = $"MAP-MSG-{screenNumber}-{messages.Count + 1:D3}",
                    Api = api,
                    Handler = handler.Name,
                    Message = message,
                    Title = title,
                    Classification = classification,
                    IsExplicitError = classification == "Error",
                    ConditionExpression = FindMessageCondition(handler.Body, call.Index),
                    TargetControls = FindMessageTargetControls(
                        handler.Body,
                        call.Index + call.Length,
                        message,
                        controls)
                });
            }
        }

        var requestNames = RequestNameRegex.Matches(script)
            .Select(x => x.Value.ToUpperInvariant())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var transactionCodes = TransactionCodeRegex.Matches(script)
            .Select(x => x.Groups["code"].Value.ToUpperInvariant())
            .Where(x => !x.StartsWith("HT", StringComparison.OrdinalIgnoreCase))
            .Concat(requestNames.Select(x => x[3..]))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        return new HtsMapErrorOracleDefinition
        {
            HasReceiveErrorParameters = handlers.Any(x =>
                x.Name.Contains("Receive", StringComparison.OrdinalIgnoreCase) &&
                x.Parameters.Contains("strErrCode", StringComparison.OrdinalIgnoreCase) &&
                x.Parameters.Contains("strErrMsg", StringComparison.OrdinalIgnoreCase)),
            HasOnErrorHandler = errorHandlers.Length > 0,
            ErrorHandlers = errorHandlers,
            MessageBoxes = messages.ToArray(),
            RequestNames = requestNames,
            TransactionCodes = transactionCodes
        };
    }

    private static string FindMessageCondition(string handlerBody, int messageIndex)
    {
        var prefix = handlerBody[..Math.Min(messageIndex, handlerBody.Length)];
        var stack = new List<string>();
        foreach (var rawLine in prefix.Replace("\r", string.Empty, StringComparison.Ordinal).Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith("'", StringComparison.Ordinal)) continue;
            if (Regex.IsMatch(line, @"^End\s+If\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            {
                if (stack.Count > 0) stack.RemoveAt(stack.Count - 1);
                continue;
            }

            var elseIf = Regex.Match(line, @"^ElseIf\s+(?<condition>.+?)\s+Then\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            if (elseIf.Success)
            {
                if (stack.Count > 0) stack[^1] = elseIf.Groups["condition"].Value.Trim();
                else stack.Add(elseIf.Groups["condition"].Value.Trim());
                continue;
            }

            if (Regex.IsMatch(line, @"^Else\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            {
                if (stack.Count > 0) stack[^1] = $"ELSE({stack[^1]})";
                continue;
            }

            var ifMatch = Regex.Match(line, @"^If\s+(?<condition>.+?)\s+Then(?:\s*)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            if (ifMatch.Success) stack.Add(ifMatch.Groups["condition"].Value.Trim());
        }
        return string.Join(" AND ", stack.Where(x => x.Length > 0));
    }

    private static string[] SplitVbArguments(string arguments)
    {
        var values = new List<string>();
        var current = new StringBuilder();
        var inString = false;
        for (var index = 0; index < arguments.Length; index++)
        {
            var character = arguments[index];
            if (character == '"')
            {
                current.Append(character);
                if (inString && index + 1 < arguments.Length && arguments[index + 1] == '"')
                {
                    current.Append(arguments[++index]);
                    continue;
                }
                inString = !inString;
                continue;
            }
            if (character == ',' && !inString)
            {
                values.Add(current.ToString().Trim());
                current.Clear();
                continue;
            }
            current.Append(character);
        }
        values.Add(current.ToString().Trim());
        return values.ToArray();
    }

    private static string ResolveVbString(string expression, string handlerBody, int beforeIndex)
    {
        var trimmed = expression.Trim();
        if (trimmed.Length >= 2 && trimmed[0] == '"' && trimmed[^1] == '"')
            return trimmed[1..^1].Replace("\"\"", "\"", StringComparison.Ordinal).Trim();
        if (!IdentifierRegex.IsMatch(trimmed)) return string.Empty;

        var prefix = handlerBody[..Math.Min(beforeIndex, handlerBody.Length)];
        var assignmentPattern = $@"(?im)^\s*{Regex.Escape(trimmed)}\s*=\s*""(?<value>(?:""""|[^""])*)""\s*$";
        var matches = Regex.Matches(prefix, assignmentPattern, RegexOptions.CultureInvariant);
        if (matches.Count == 0) return string.Empty;
        return matches[^1].Groups["value"].Value.Replace("\"\"", "\"", StringComparison.Ordinal).Trim();
    }

    private static string[] FindMessageTargetControls(
        string handlerBody,
        int afterMessageIndex,
        string message,
        HtsMapControlDefinition[] controls)
    {
        var known = controls.Select(x => x.LogicalName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var targets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var remaining = handlerBody[Math.Min(afterMessageIndex, handlerBody.Length)..];
        var boundary = Regex.Match(
            remaining,
            @"(?im)^\s*(?:EXIT\s+(?:SUB|FUNCTION)|END\s+IF)\b",
            RegexOptions.CultureInvariant);
        var segmentLength = Math.Min(boundary.Success ? boundary.Index : remaining.Length, 500);
        var focusSegment = remaining[..segmentLength];
        var directFocus = Regex.Match(
            focusSegment,
            @"\b(?<control>[A-Za-z][A-Za-z0-9_]*)\.SetFocus\b",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        var namedFocus = Regex.Match(
            focusSegment,
            @"\bSetFocusCtrl\s*\(\s*""(?<control>[A-Za-z][A-Za-z0-9_]*)""",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        var nearestFocus = new[] { directFocus, namedFocus }
            .Where(x => x.Success)
            .OrderBy(x => x.Index)
            .FirstOrDefault();
        if (nearestFocus is not null && known.Contains(nearestFocus.Groups["control"].Value))
            targets.Add(nearestFocus.Groups["control"].Value);
        if (message.Contains("계좌", StringComparison.Ordinal))
            targets.UnionWith(controls.Where(x => x.Kind == HtsMapControlKind.Account).Select(x => x.LogicalName));
        if (message.Contains("비밀번호", StringComparison.Ordinal))
            targets.UnionWith(controls.Where(x => x.Kind == HtsMapControlKind.Password).Select(x => x.LogicalName));
        return SortValues(targets);
    }

    private static string ClassifyMessage(string handler, string message, string title)
    {
        var text = $"{title} {message}";
        if (Regex.IsMatch(message, @"처리\s*오류|시스템\s*오류|오류가\s*발생|에러|실패|예외|장애|Error|Exception|Fail", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            return "Error";
        if (handler.Contains("Valid", StringComparison.OrdinalIgnoreCase) ||
            handler.Contains("Before", StringComparison.OrdinalIgnoreCase) ||
            Regex.IsMatch(message, @"입력|확인하|선택하|선택해|필수|초과|잘못|없습니다|불가|클\s*수\s*없|변경\s*가능", RegexOptions.CultureInvariant))
            return "InputValidation";
        if (Regex.IsMatch(text, @"경고|주의|Warning", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            return "Warning";
        if (Regex.IsMatch(text, @"오류|에러|실패|예외|장애|Error|Exception|Fail", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            return "Error";
        return "Info";
    }

    private HtsMapControlKind MapKind(string typeCode)
    {
        if (controlKinds is not null && controlKinds.TryGetValue(typeCode, out var installedKind))
            return installedKind;
        return typeCode switch
        {
            "01" => HtsMapControlKind.EmbeddedScreen,
            "02" => HtsMapControlKind.Tab,
            "03" => HtsMapControlKind.StaticText,
            "04" => HtsMapControlKind.Label,
            "05" => HtsMapControlKind.Button,
            "06" or "07" => HtsMapControlKind.Text,
            "08" => HtsMapControlKind.Instrument,
            "09" => HtsMapControlKind.ComboBox,
            "10" => HtsMapControlKind.Account,
            "11" => HtsMapControlKind.Date,
            "12" => HtsMapControlKind.GroupBox,
            "13" => HtsMapControlKind.CheckBox,
            "14" => HtsMapControlKind.RadioGroup,
            "15" => HtsMapControlKind.Grid,
            "16" or "50" => HtsMapControlKind.Chart,
            "18" => HtsMapControlKind.Spin,
            "19" => HtsMapControlKind.Web,
            "20" => HtsMapControlKind.Image,
            "21" or "32" => HtsMapControlKind.Tree,
            "23" => HtsMapControlKind.Timer,
            "25" => HtsMapControlKind.CalendarDiary,
            "28" => HtsMapControlKind.Password,
            "31" => HtsMapControlKind.Explorer,
            "34" => HtsMapControlKind.EmbeddedFrame,
            "35" => HtsMapControlKind.SplitButton,
            "36" => HtsMapControlKind.Slider,
            _ => HtsMapControlKind.Unknown
        };
    }

    private static string MapRuleControlKind(HtsMapControlKind kind) => kind switch
    {
        HtsMapControlKind.Tab => "Tab",
        HtsMapControlKind.Button => "Button",
        HtsMapControlKind.Text or HtsMapControlKind.Instrument or HtsMapControlKind.Account or HtsMapControlKind.Password => "Text",
        HtsMapControlKind.Date => "Date",
        HtsMapControlKind.ComboBox => "ComboBox",
        HtsMapControlKind.CheckBox => "CheckBox",
        HtsMapControlKind.RadioGroup => "RadioGroup",
        HtsMapControlKind.Grid => "ListView",
        HtsMapControlKind.Tree or HtsMapControlKind.Explorer => "TreeView",
        HtsMapControlKind.Spin => "Spin",
        HtsMapControlKind.Slider => "Slider",
        HtsMapControlKind.SplitButton => "Button",
        HtsMapControlKind.CalendarDiary => "Date",
        _ => "Unknown"
    };

    private static bool IsActionable(HtsMapControlKind kind) => kind is
        HtsMapControlKind.Tab or HtsMapControlKind.Button or HtsMapControlKind.Text or
        HtsMapControlKind.Instrument or HtsMapControlKind.ComboBox or HtsMapControlKind.Account or
        HtsMapControlKind.Date or HtsMapControlKind.CheckBox or HtsMapControlKind.RadioGroup or
        HtsMapControlKind.Password or HtsMapControlKind.Tree or HtsMapControlKind.Spin or
        HtsMapControlKind.Slider or HtsMapControlKind.SplitButton or HtsMapControlKind.CalendarDiary;

    private static Encoding CreateKoreanEncoding()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        return Encoding.GetEncoding(949);
    }

    private static string NormalizeScreenNumber(string value)
    {
        var trimmed = value.Trim();
        return trimmed.Length == 3 && trimmed.All(char.IsDigit) ? trimmed.PadLeft(4, '0') : trimmed;
    }
}
