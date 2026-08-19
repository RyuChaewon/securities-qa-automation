// 역할: MAP 외 설치 자료에서 화면 레지스트리, 선택지, 오류코드, 무결성, 마스터 표본과 로그 위치를 수집한다.
// 입력/출력: targetProfile 설치 루트를 읽어 계획·오라클·Excel이 소비하는 HtsInstallationCatalog를 만든다.
// 경계: 설치 파일은 읽기 전용이며 특정 고객 데이터 원문은 카탈로그에 복사하지 않는다.
// 수정 지점: 새 설치 파일 형식은 독립 로더로 추가하고 SourceFile·분류 근거·회귀 테스트를 남긴다.
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace HtsQa.Core;

// 설치 자료 직렬화 모델 ---------------------------------------------------------
public sealed record HtsScreenRegistryDefinition
{
    public required string ScreenNumber { get; init; }
    public required string Title { get; init; }
    public required string MapFile { get; init; }
    public string[] Categories { get; init; } = [];
    public required string SourceFile { get; init; }
}

public sealed record HtsScreenAliasDefinition
{
    public required string AliasScreenNumber { get; init; }
    public required string AliasTitle { get; init; }
    public required string CanonicalScreenNumber { get; init; }
    public required string CanonicalTitle { get; init; }
    public bool IsAmbiguous { get; init; }
    public required string SourceFile { get; init; }
}

public sealed record HtsTabGroupDefinition
{
    public required string GroupId { get; init; }
    public required string[] ScreenNumbers { get; init; }
    public required string SourceFile { get; init; }
}

public sealed record HtsControlTypeDefinition
{
    public required string TypeCode { get; init; }
    public required string Name { get; init; }
    public required HtsMapControlKind Kind { get; init; }
    public string Prefix { get; init; } = "";
    public int DefaultWidth { get; init; }
    public int DefaultHeight { get; init; }
    public string RuntimeDll { get; init; } = "";
    public required string Source { get; init; }
}

public sealed record HtsErrorCodeDefinition
{
    public required string Code { get; init; }
    public required string Message { get; init; }
    public required string Classification { get; init; }
    public bool IsFailure { get; init; }
    public required string SourceFile { get; init; }
}

public sealed record HtsMapDataReferenceDefinition
{
    public required string SourceFile { get; init; }
    public required string Section { get; init; }
    public string EnglishName { get; init; } = "";
    public required string Usage { get; init; }
    public string BoundControl { get; init; } = "";
    public HtsMapOptionDefinition[] Options { get; init; } = [];
}

public sealed record HtsIntegrityDefinition
{
    public required string RelativePath { get; init; }
    public required string ManifestFile { get; init; }
    public string ExpectedMd5 { get; init; } = "";
    public string ActualMd5 { get; init; } = "";
    public long ExpectedSize { get; init; }
    public long ActualSize { get; init; }
    public DateTimeOffset? DistributionTimestamp { get; init; }
    public bool Exists { get; init; }
    public bool ManifestEntryFound { get; init; }
    public bool HashMatches { get; init; }
    public bool SizeMatches { get; init; }
    public required string Status { get; init; }
}

public sealed record HtsMasterSampleDefinition
{
    public required string Code { get; init; }
    public required string Name { get; init; }
    public string Market { get; init; } = "";
    public RuleExpectedOutcome ExpectedOutcome { get; init; } = new();
}

public sealed record HtsMasterDataSourceDefinition
{
    public required string Id { get; init; }
    public required string RelativePath { get; init; }
    public required string Purpose { get; init; }
    public long RecordCount { get; init; }
    public HtsMasterSampleDefinition[] Samples { get; init; } = [];
    public HtsIntegrityDefinition? Integrity { get; init; }
}

public sealed record HtsLogSourceDefinition
{
    public required string Id { get; init; }
    public required string PathPattern { get; init; }
    public required string Mode { get; init; }
    public required string Purpose { get; init; }
    public bool Sensitive { get; init; }
    public bool FailureOnChange { get; init; }
}

/// <summary>HTS 설치 루트의 정적 자료를 읽어 MAP 카탈로그를 실행 가능한 기준 정보로 보강한다.</summary>
public sealed class HtsInstallationCatalogBuilder
{
    private const int MaxDependencyScreens = 500;
    private const int MaxDependencyDepth = 12;
    private static readonly Encoding KoreanEncoding = CreateKoreanEncoding();
    private static readonly Regex IniPathRegex = new(
        @"(?<path>[A-Za-z0-9_./\\:-]+\.ini)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private sealed record IniSection(string Name, string EnglishName, HtsMapOptionDefinition[] Options);
    private sealed record ManifestRow(string RelativePath, string Md5, long Size, DateTimeOffset? Timestamp, string ManifestFile);

    /// <summary>대상 MAP과 참조 화면을 추적하고 설치 자료·무결성·공식 값을 결합한다.</summary>
    public HtsMapCatalog Build(
        string installationRoot,
        IEnumerable<string> screenNumbers,
        string filePattern = "ht{screenNumber}00.map",
        IEnumerable<string>? familyFiles = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(installationRoot);
        var root = Path.GetFullPath(installationRoot);
        var screenDirectory = Path.Combine(root, "screen");
        if (!Directory.Exists(screenDirectory))
            throw new DirectoryNotFoundException($"HTS screen 폴더를 찾을 수 없습니다: {screenDirectory}");

        var requested = screenNumbers
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Select(NormalizeScreenNumber)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var controlTypes = LoadControlTypes(root);
        var kindMap = controlTypes
            .GroupBy(x => x.TypeCode, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(x => x.Key, x => x.First().Kind, StringComparer.OrdinalIgnoreCase);
        var parser = new HtsMapParser(kindMap);
        var family = familyFiles?
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .ToArray() ?? [];
        var baseCatalog = family.Length > 0
            ? parser.ParseFamilyCatalog(screenDirectory, requested, family, filePattern)
            : parser.ParseCatalog(screenDirectory, requested, filePattern);

        var topPaths = baseCatalog.Screens
            .Select(x => Path.GetFullPath(x.SourceFile))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var models = baseCatalog.Screens.ToDictionary(
            x => Path.GetFullPath(x.SourceFile),
            x => x,
            StringComparer.OrdinalIgnoreCase);
        var queue = new Queue<(HtsMapScreenDefinition Model, int Depth)>(baseCatalog.Screens.Select(x => (x, 0)));
        var dependencyTraversalTruncated = false;
        while (queue.Count > 0)
        {
            var (source, depth) = queue.Dequeue();
            foreach (var navigation in source.Behavior.NavigationTargets.Where(x => !x.IsDynamic && x.TargetMapFile.Length > 0))
            {
                var targetPath = Path.GetFullPath(Path.Combine(screenDirectory, navigation.TargetMapFile));
                if (!File.Exists(targetPath) || models.ContainsKey(targetPath)) continue;
                if (depth >= MaxDependencyDepth || models.Count - topPaths.Count >= MaxDependencyScreens)
                {
                    dependencyTraversalTruncated = true;
                    continue;
                }
                try
                {
                    var target = parser.Parse(targetPath);
                    models[targetPath] = target;
                    queue.Enqueue((target, depth + 1));
                }
                catch (InvalidDataException)
                {
                    // The unresolved dependency remains in the graph and is reported as a warning below.
                }
            }
        }

        var registry = LoadScreenRegistry(root);
        var scopedNumbers = requested
            .Concat(models.Values.Select(x => x.ScreenNumber))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var tabGroups = LoadTabGroups(root)
            .Where(x => x.ScreenNumbers.Any(scopedNumbers.Contains))
            .ToArray();
        var aliases = LoadScreenAliases(root, scopedNumbers, registry);
        var errorCodes = LoadErrorCodes(root);
        var iniIndex = BuildIniIndex(root);
        var manifest = LoadManifest(root);
        var masterPaths = new[] { "mst/stkcode.cod", "mst/nxtcode.cod", "mst/etfcode.cod" };
        var relevantPaths = models.Keys
            .Select(x => NormalizeRelativePath(Path.GetRelativePath(root, x)))
            .Concat(masterPaths.Where(x => File.Exists(Path.Combine(root, x.Replace('/', Path.DirectorySeparatorChar)))))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var integrity = BuildIntegrity(root, relevantPaths, manifest);
        var integrityByPath = integrity.ToDictionary(x => x.RelativePath, StringComparer.OrdinalIgnoreCase);

        var enriched = new Dictionary<string, HtsMapScreenDefinition>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in models)
        {
            var model = pair.Value;
            var resolvedNavigation = model.Behavior.NavigationTargets
                .Select(x => ResolveNavigation(x, screenDirectory, models))
                .ToArray();
            model = ApplyNavigation(model, resolvedNavigation);
            var screenRegistry = registry.FirstOrDefault(x => x.ScreenNumber == model.ScreenNumber);
            var groups = tabGroups.Where(x => x.ScreenNumbers.Contains(model.ScreenNumber)).ToArray();
            var siblings = groups.SelectMany(x => x.ScreenNumbers)
                .Where(x => !x.Equals(model.ScreenNumber, StringComparison.OrdinalIgnoreCase))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
            var dataReferences = LoadDataReferences(root, model, iniIndex);
            var controls = ApplyStaticOptions(model.Controls, dataReferences);
            var relativePath = NormalizeRelativePath(Path.GetRelativePath(root, model.SourceFile));
            integrityByPath.TryGetValue(relativePath, out var modelIntegrity);
            var warnings = model.Warnings.ToList();
            if (screenRegistry is null && topPaths.Contains(pair.Key))
                warnings.Add("menu.dat에서 현재 화면의 기준 항목을 찾지 못했습니다.");
            if (modelIntegrity is not null && modelIntegrity.Status != "MATCH")
                warnings.Add($"설치 매니페스트 검증 실패: {modelIntegrity.Status}");
            if (resolvedNavigation.Any(x => !x.IsDynamic && !x.TargetExists))
                warnings.Add("MAP이 참조하는 연결 화면 파일 중 설치본에서 찾지 못한 항목이 있습니다.");

            enriched[pair.Key] = model with
            {
                Controls = controls,
                Registry = screenRegistry,
                TabGroups = groups.Select(x => x.GroupId).ToArray(),
                TabSiblings = siblings,
                DataReferences = dataReferences,
                Integrity = modelIntegrity,
                Dependencies = resolvedNavigation,
                Warnings = warnings.Distinct(StringComparer.Ordinal).ToArray()
            };
        }

        var topScreens = baseCatalog.Screens.Select(x => enriched[Path.GetFullPath(x.SourceFile)]).ToArray();
        var dependencyScreens = enriched
            .Where(x => !topPaths.Contains(x.Key))
            .Select(x => x.Value)
            .OrderBy(x => x.ScreenCode, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var allDependencies = enriched.Values
            .SelectMany(x => x.Dependencies)
            .GroupBy(x => $"{x.SourceScreenCode}|{x.RuleId}|{x.TargetScreenCode}", StringComparer.OrdinalIgnoreCase)
            .Select(x => x.First())
            .ToArray();
        var masterSources = LoadMasterSources(root, integrityByPath);
        var fingerprint = ComputeFingerprint(integrity);
        var warningsRoot = new List<string>();
        if (integrity.Any(x => x.Status != "MATCH"))
            warningsRoot.Add("설치 파일 일부가 배포 매니페스트와 일치하지 않습니다.");
        if (baseCatalog.MissingScreens.Length > 0)
            warningsRoot.Add("요청 화면 MAP 일부가 누락되었습니다.");
        var unresolvedDependencies = allDependencies.Count(x => !x.IsDynamic && !x.TargetExists);
        if (unresolvedDependencies > 0)
            warningsRoot.Add($"정적 MAP 연결 대상 파일 {unresolvedDependencies}개를 설치본에서 찾지 못했습니다.");
        if (dependencyTraversalTruncated)
            warningsRoot.Add($"MAP 연결 탐색이 안전 한도(깊이 {MaxDependencyDepth}, 의존 화면 {MaxDependencyScreens}개)에 도달해 일부 경로를 생략했습니다.");

        return baseCatalog with
        {
            SchemaVersion = "1.4",
            Screens = topScreens,
            InstallationRoot = root,
            InstallationFingerprint = fingerprint,
            ScreenRegistry = registry.Where(x => scopedNumbers.Contains(x.ScreenNumber)).ToArray(),
            ScreenAliases = aliases,
            TabGroups = tabGroups,
            ControlTypes = controlTypes,
            ErrorCodes = errorCodes,
            IntegrityEntries = integrity,
            DependencyScreens = dependencyScreens,
            Dependencies = allDependencies,
            MasterDataSources = masterSources,
            LogSources = BuildLogSources(root),
            Warnings = warningsRoot.ToArray()
        };
    }

    private static HtsMapNavigationDefinition ResolveNavigation(
        HtsMapNavigationDefinition navigation,
        string screenDirectory,
        IReadOnlyDictionary<string, HtsMapScreenDefinition> models)
    {
        if (navigation.IsDynamic || navigation.TargetMapFile.Length == 0) return navigation;
        var targetPath = Path.GetFullPath(Path.Combine(screenDirectory, navigation.TargetMapFile));
        models.TryGetValue(targetPath, out var target);
        return navigation with
        {
            TargetExists = File.Exists(targetPath),
            TargetSourceFile = File.Exists(targetPath) ? targetPath : string.Empty,
            TargetSha256 = target?.SourceSha256 ?? string.Empty
        };
    }

    private static HtsMapScreenDefinition ApplyNavigation(
        HtsMapScreenDefinition model,
        HtsMapNavigationDefinition[] resolved)
    {
        var byRule = resolved.ToDictionary(x => x.RuleId, StringComparer.OrdinalIgnoreCase);
        HtsMapNavigationDefinition[] ResolveRows(IEnumerable<HtsMapNavigationDefinition> rows) => rows
            .Select(x => byRule.GetValueOrDefault(x.RuleId, x))
            .ToArray();
        var handlers = model.Behavior.EventHandlers.Select(x => x with
        {
            NavigationTargets = ResolveRows(x.NavigationTargets)
        }).ToArray();
        var behavior = model.Behavior with
        {
            EventHandlers = handlers,
            NavigationTargets = resolved
        };
        var controls = model.Controls.Select(x => x with
        {
            NavigationTargets = ResolveRows(x.NavigationTargets)
        }).ToArray();
        return model with { Behavior = behavior, Controls = controls, Dependencies = resolved };
    }

    private static HtsControlTypeDefinition[] LoadControlTypes(string root)
    {
        var defaultsPath = Path.Combine(root, "system", "defaultctrlinfo.ini");
        var runtimePath = Path.Combine(root, "system", "sysctrl.ini");
        var runtime = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (File.Exists(runtimePath))
        {
            var inRunSection = false;
            foreach (var raw in ReadKoreanLines(runtimePath))
            {
                var line = raw.Trim();
                if (line.StartsWith('[')) inRunSection = line.Equals("[RunControl]", StringComparison.OrdinalIgnoreCase);
                if (!inRunSection) continue;
                var match = Regex.Match(line, @"^(?<code>\d+)\s*=\s*(?<dll>[^;\s]+)", RegexOptions.CultureInvariant);
                if (match.Success) runtime[match.Groups["code"].Value.PadLeft(2, '0')] = match.Groups["dll"].Value;
            }
        }

        var result = new List<HtsControlTypeDefinition>();
        if (File.Exists(defaultsPath))
        {
            foreach (var raw in ReadKoreanLines(defaultsPath))
            {
                var match = Regex.Match(
                    raw,
                    @"^(?<code>\d{2})\s*=\s*(?<width>\d+)\s*,\s*(?<height>\d+)\s*,\s*(?<prefix>[^,]*)\s*,\s*(?<name>[^\s,]+)",
                    RegexOptions.CultureInvariant);
                if (!match.Success) continue;
                var code = match.Groups["code"].Value;
                var name = match.Groups["name"].Value.Trim();
                result.Add(new HtsControlTypeDefinition
                {
                    TypeCode = code,
                    Name = name,
                    Kind = ClassifyControlType(name),
                    Prefix = match.Groups["prefix"].Value.Trim(),
                    DefaultWidth = int.Parse(match.Groups["width"].Value, CultureInfo.InvariantCulture),
                    DefaultHeight = int.Parse(match.Groups["height"].Value, CultureInfo.InvariantCulture),
                    RuntimeDll = runtime.GetValueOrDefault(code, string.Empty),
                    Source = "defaultctrlinfo.ini+sysctrl.ini"
                });
            }
        }
        foreach (var pair in runtime.Where(x => result.All(row => row.TypeCode != x.Key)))
        {
            result.Add(new HtsControlTypeDefinition
            {
                TypeCode = pair.Key,
                Name = Path.GetFileNameWithoutExtension(pair.Value).Replace("Run", string.Empty, StringComparison.OrdinalIgnoreCase),
                Kind = ClassifyControlType(pair.Value),
                RuntimeDll = pair.Value,
                Source = "sysctrl.ini"
            });
        }
        return result.OrderBy(x => x.TypeCode, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private static HtsMapControlKind ClassifyControlType(string name)
    {
        var value = name.ToUpperInvariant();
        if (value.Contains("DLLLOADER")) return HtsMapControlKind.EmbeddedScreen;
        if (value.Contains("TAB")) return HtsMapControlKind.Tab;
        if (value.Contains("STATIC")) return HtsMapControlKind.StaticText;
        if (value.Contains("LABEL")) return HtsMapControlKind.Label;
        if (value.Contains("SPLITBUTTON") || value.Contains("PWRDLGBTN") || value.Contains("BUTTON"))
            return value.Contains("SPLIT") ? HtsMapControlKind.SplitButton : HtsMapControlKind.Button;
        if (value.Contains("MASKEDIT") || value.Contains("EDITBOX") || value.Contains("POSTNO")) return HtsMapControlKind.Text;
        if (value.Contains("JMCOMBO")) return HtsMapControlKind.Instrument;
        if (value.Contains("ACCOUNTCOMBO") || value.Contains("NEWACCNT") || value.Contains("ACCNTFIND")) return HtsMapControlKind.Account;
        if (value.Contains("TREECOMBO") || value.Contains("TREE")) return HtsMapControlKind.Tree;
        if (value.Contains("COMBO")) return HtsMapControlKind.ComboBox;
        if (value.Contains("CALENDARDIARY")) return HtsMapControlKind.CalendarDiary;
        if (value.Contains("CALENDAR")) return HtsMapControlKind.Date;
        if (value.Contains("GROUPBOX")) return HtsMapControlKind.GroupBox;
        if (value.Contains("CHECK")) return HtsMapControlKind.CheckBox;
        if (value.Contains("RADIO")) return HtsMapControlKind.RadioGroup;
        if (value.Contains("GRID")) return HtsMapControlKind.Grid;
        if (value.Contains("CHART") || value.Contains("BONG")) return HtsMapControlKind.Chart;
        if (value.Contains("SPIN")) return HtsMapControlKind.Spin;
        if (value.Contains("WEB")) return HtsMapControlKind.Web;
        if (value.Contains("IMAGE")) return HtsMapControlKind.Image;
        if (value.Contains("TIMER")) return HtsMapControlKind.Timer;
        if (value.Contains("PASSEDIT")) return HtsMapControlKind.Password;
        if (value.Contains("EXPLORER")) return HtsMapControlKind.Explorer;
        if (value.Contains("INTERFACE")) return HtsMapControlKind.EmbeddedFrame;
        if (value.Contains("TRACKBAR")) return HtsMapControlKind.Slider;
        return HtsMapControlKind.Custom;
    }

    private static HtsScreenRegistryDefinition[] LoadScreenRegistry(string root)
    {
        var path = Path.Combine(root, "system", "menu", "menu.dat");
        if (!File.Exists(path)) return [];
        var rows = new Dictionary<string, (string Title, string MapFile, HashSet<string> Categories)>(StringComparer.OrdinalIgnoreCase);
        var category = string.Empty;
        foreach (var raw in ReadKoreanLines(path))
        {
            var categoryMatch = Regex.Match(raw, @"^P\s+(?<category>\S.*?)\s*$", RegexOptions.CultureInvariant);
            if (categoryMatch.Success)
            {
                category = categoryMatch.Groups["category"].Value.Trim();
                continue;
            }
            var screenMatch = Regex.Match(
                raw,
                @"^NN(?<screen>\d{4})\s{2,}(?<title>.*?)\s{2,}.*?(?<map>HT[A-Za-z0-9]+\.map)",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            if (!screenMatch.Success) continue;
            var number = screenMatch.Groups["screen"].Value;
            if (!rows.TryGetValue(number, out var entry))
                entry = (screenMatch.Groups["title"].Value.Trim(), screenMatch.Groups["map"].Value, new(StringComparer.Ordinal));
            if (category.Length > 0) entry.Categories.Add(category);
            rows[number] = entry;
        }
        return rows.Select(x => new HtsScreenRegistryDefinition
        {
            ScreenNumber = x.Key,
            Title = x.Value.Title,
            MapFile = x.Value.MapFile,
            Categories = x.Value.Categories.ToArray(),
            SourceFile = path
        }).OrderBy(x => x.ScreenNumber, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private static HtsScreenAliasDefinition[] LoadScreenAliases(
        string root,
        IReadOnlySet<string> scope,
        IReadOnlyCollection<HtsScreenRegistryDefinition> registry)
    {
        var path = Path.Combine(root, "data", "screen_number.dat");
        if (!File.Exists(path)) return [];
        var drafts = ReadKoreanLines(path)
            .Select(x => x.Split(',', StringSplitOptions.TrimEntries))
            .Where(x => x.Length >= 4 && Regex.IsMatch(x[0], "^[0-9]{4}$") && Regex.IsMatch(x[2], "^[0-9]{4}$"))
            .Where(x => scope.Contains(x[0]) || scope.Contains(x[2]))
            .Select(x => new { AliasNumber = x[0], AliasTitle = x[1], CanonicalNumber = x[2], CanonicalTitle = x[3] })
            .ToArray();
        var ambiguousAliases = drafts.GroupBy(x => x.AliasNumber, StringComparer.OrdinalIgnoreCase)
            .Where(x => x.Select(row => row.CanonicalNumber).Distinct(StringComparer.OrdinalIgnoreCase).Count() > 1)
            .Select(x => x.Key)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var canonicalNumbers = registry.Select(x => x.ScreenNumber).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return drafts.Select(x => new HtsScreenAliasDefinition
        {
            AliasScreenNumber = x.AliasNumber,
            AliasTitle = x.AliasTitle,
            CanonicalScreenNumber = x.CanonicalNumber,
            CanonicalTitle = x.CanonicalTitle,
            IsAmbiguous = ambiguousAliases.Contains(x.AliasNumber) ||
                (canonicalNumbers.Contains(x.AliasNumber) && !x.AliasNumber.Equals(x.CanonicalNumber, StringComparison.OrdinalIgnoreCase)),
            SourceFile = path
        }).ToArray();
    }

    private static HtsTabGroupDefinition[] LoadTabGroups(string root)
    {
        var path = Path.Combine(root, "system", "tabscreen.ini");
        if (!File.Exists(path)) return [];
        var result = new List<HtsTabGroupDefinition>();
        var section = string.Empty;
        foreach (var raw in ReadKoreanLines(path))
        {
            var line = raw.Trim();
            var sectionMatch = Regex.Match(line, @"^\[(?<name>[^]]+)\]$", RegexOptions.CultureInvariant);
            if (sectionMatch.Success) { section = sectionMatch.Groups["name"].Value; continue; }
            if (!line.StartsWith("TAB=", StringComparison.OrdinalIgnoreCase)) continue;
            var screens = line[4..].Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Where(x => Regex.IsMatch(x, "^[0-9]{4}$"))
                .ToArray();
            if (screens.Length > 1)
                result.Add(new HtsTabGroupDefinition { GroupId = section, ScreenNumbers = screens, SourceFile = path });
        }
        return result.ToArray();
    }

    private static HtsErrorCodeDefinition[] LoadErrorCodes(string root)
    {
        var path = Path.Combine(root, "data", "errcode.txt");
        if (!File.Exists(path)) return [];
        var success = new HashSet<string>(["00000", "90000", "90011", "90013", "90015"], StringComparer.Ordinal);
        var noData = new HashSet<string>(["99999"], StringComparer.Ordinal);
        var authentication = new HashSet<string>(["70001", "70002", "70003", "90018", "90019"], StringComparer.Ordinal);
        var transient = new HashSet<string>(["90006", "90008", "90020", "90997"], StringComparer.Ordinal);
        var systemFailure = new HashSet<string>(["90005", "90007", "90012", "90014", "90016"], StringComparer.Ordinal);
        var result = new List<HtsErrorCodeDefinition>();
        foreach (var raw in ReadKoreanLines(path))
        {
            var match = Regex.Match(raw, @"^(?<code>\d{5})\s+(?<message>.+?)\s*$", RegexOptions.CultureInvariant);
            if (!match.Success) continue;
            var code = match.Groups["code"].Value;
            var message = Regex.Replace(
                match.Groups["message"].Value,
                @"\s+[A-Z][a-z]+\s+\d{1,2}\s+\d{4}.*$",
                string.Empty,
                RegexOptions.CultureInvariant).Trim();
            var classification = success.Contains(code) ? "Normal" :
                noData.Contains(code) ? "NoData" :
                authentication.Contains(code) ? "Authentication" :
                transient.Contains(code) ? "TransientFailure" :
                systemFailure.Contains(code) ? "SystemFailure" : "InputOrBusinessValidation";
            result.Add(new HtsErrorCodeDefinition
            {
                Code = code,
                Message = message,
                Classification = classification,
                IsFailure = classification is "Authentication" or "TransientFailure" or "SystemFailure",
                SourceFile = path
            });
        }
        return result.ToArray();
    }

    private static Dictionary<string, string[]> BuildIniIndex(string root)
    {
        var paths = new[] { Path.Combine(root, "data"), Path.Combine(root, "system") }
            .Where(Directory.Exists)
            .SelectMany(x => Directory.EnumerateFiles(x, "*.ini", SearchOption.AllDirectories));
        return paths.GroupBy(x => Path.GetFileName(x) ?? string.Empty, StringComparer.OrdinalIgnoreCase)
            .Where(x => x.Key.Length > 0)
            .ToDictionary(x => x.Key, x => x.ToArray(), StringComparer.OrdinalIgnoreCase);
    }

    private static HtsMapDataReferenceDefinition[] LoadDataReferences(
        string root,
        HtsMapScreenDefinition model,
        IReadOnlyDictionary<string, string[]> iniIndex)
    {
        var bytes = File.ReadAllBytes(model.SourceFile);
        var text = KoreanEncoding.GetString(bytes);
        var iniCache = new Dictionary<string, IniSection[]>(StringComparer.OrdinalIgnoreCase);
        var result = new List<HtsMapDataReferenceDefinition>();
        foreach (Match match in IniPathRegex.Matches(text))
        {
            var token = match.Groups["path"].Value;
            var fileName = Path.GetFileName(token.Replace('/', Path.DirectorySeparatorChar));
            if (!iniIndex.TryGetValue(fileName, out var candidates)) continue;
            var path = candidates.OrderBy(x => x.Contains(Path.DirectorySeparatorChar + "data" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ? 0 : 1).First();
            if (!iniCache.TryGetValue(path, out var sections))
            {
                sections = ReadIniSections(path);
                iniCache[path] = sections;
            }
            var nearby = text.Substring(match.Index + match.Length, Math.Min(220, text.Length - match.Index - match.Length));
            var section = sections.OrderByDescending(x => x.Name.Length)
                .FirstOrDefault(x => nearby.Contains(x.Name, StringComparison.Ordinal));
            if (section is null) continue;
            var boundControl = ResolveOptionControl(model.Controls, fileName, section);
            result.Add(new HtsMapDataReferenceDefinition
            {
                SourceFile = NormalizeRelativePath(Path.GetRelativePath(root, path)),
                Section = section.Name,
                EnglishName = section.EnglishName,
                Usage = boundControl.Length > 0 ? "InputOptions" : "ResultCodeDictionary",
                BoundControl = boundControl,
                Options = section.Options
            });
        }
        return result.GroupBy(x => $"{x.SourceFile}|{x.Section}|{x.BoundControl}", StringComparer.OrdinalIgnoreCase)
            .Select(x => x.First())
            .ToArray();
    }

    private static IniSection[] ReadIniSections(string path)
    {
        var result = new List<IniSection>();
        string? name = null;
        var englishName = string.Empty;
        var options = new List<HtsMapOptionDefinition>();
        void Flush()
        {
            if (name is not null)
                result.Add(new IniSection(name, englishName, options.ToArray()));
            name = null;
            englishName = string.Empty;
            options = [];
        }
        foreach (var raw in ReadKoreanLines(path))
        {
            var line = raw.Trim();
            var sectionMatch = Regex.Match(line, @"^\[(?<name>[^]]+)\]$", RegexOptions.CultureInvariant);
            if (sectionMatch.Success)
            {
                Flush();
                name = sectionMatch.Groups["name"].Value.Trim();
                continue;
            }
            if (name is null || line.StartsWith(';') || line.StartsWith('#')) continue;
            var delimiter = line.IndexOf('=');
            if (delimiter <= 0) continue;
            var key = line[..delimiter].Trim();
            var value = line[(delimiter + 1)..].Trim();
            if (key.Equals("ENGNAME", StringComparison.OrdinalIgnoreCase)) { englishName = value; continue; }
            if (key.Equals("FILEMEM", StringComparison.OrdinalIgnoreCase) || key.Equals("COUNT", StringComparison.OrdinalIgnoreCase)) continue;
            var keyIsCode = Regex.IsMatch(key, "^[A-Za-z0-9]{1,8}$", RegexOptions.CultureInvariant);
            var valueIsCode = Regex.IsMatch(value, "^[A-Za-z0-9]{1,8}$", RegexOptions.CultureInvariant);
            if (!keyIsCode && !valueIsCode) continue;
            var code = keyIsCode ? key : value;
            var label = keyIsCode ? value : key;
            options.Add(new HtsMapOptionDefinition
            {
                Id = $"code-{code}",
                Value = code,
                DisplayValue = label,
                Index = options.Count,
                Source = $"{Path.GetFileName(path)}:[{name}]"
            });
        }
        Flush();
        return result.ToArray();
    }

    private static string ResolveOptionControl(
        IEnumerable<HtsMapControlDefinition> controls,
        string fileName,
        IniSection section)
    {
        var scored = controls
            .Where(x => x.Kind is HtsMapControlKind.ComboBox or HtsMapControlKind.RadioGroup)
            .Select(x => new { Control = x, Score = ScoreOptionControl(x, fileName, section) })
            .Where(x => x.Score >= 10)
            .OrderByDescending(x => x.Score)
            .ToArray();
        if (scored.Length == 0 || (scored.Length > 1 && scored[0].Score == scored[1].Score)) return string.Empty;
        return scored[0].Control.LogicalName;
    }

    private static int ScoreOptionControl(HtsMapControlDefinition control, string fileName, IniSection section)
    {
        var name = control.LogicalName.ToUpperInvariant();
        var score = 0;
        if (fileName.Equals("exchange.ini", StringComparison.OrdinalIgnoreCase) &&
            (name.Contains("EXCH") || name.Contains("ATS"))) score += 20;
        if ((section.Name.Contains("신용", StringComparison.Ordinal) || section.EnglishName.Contains("CRDT", StringComparison.OrdinalIgnoreCase)) &&
            (name.Contains("CREDIT") || name.Contains("CRDT") || name.Contains("SINY"))) score += 20;
        if ((section.Name.Contains("매도", StringComparison.Ordinal) || section.Name.Contains("매수", StringComparison.Ordinal)) &&
            (name.Contains("SELL") || name.Contains("BUY") || name.Contains("MEDO") || name.Contains("MESU"))) score += 12;
        return score;
    }

    private static HtsMapControlDefinition[] ApplyStaticOptions(
        HtsMapControlDefinition[] controls,
        HtsMapDataReferenceDefinition[] references)
    {
        return controls.Select(control =>
        {
            var matches = references.Where(x => x.BoundControl.Equals(control.LogicalName, StringComparison.OrdinalIgnoreCase)).ToArray();
            if (matches.Length == 0) return control;
            return control with
            {
                StaticOptions = matches.SelectMany(x => x.Options)
                    .GroupBy(x => x.Value, StringComparer.OrdinalIgnoreCase)
                    .Select(x => x.First())
                    .Select((x, index) => x with
                    {
                        Index = index,
                        ExpectedOutcome = new RuleExpectedOutcome
                        {
                            Type = RuleExpectedOutcomeType.Success,
                            Source = RuleExpectationSource.InstallationInputOption,
                            Confidence = RuleExpectationConfidence.High,
                            Evidence = [$"HTS 설치 입력 사전: {x.Source}"],
                            QueryShouldComplete = true
                        }
                    })
                    .ToArray(),
                OptionSource = string.Join(";", matches.Select(x => $"{x.SourceFile}:[{x.Section}]").Distinct(StringComparer.OrdinalIgnoreCase))
            };
        }).ToArray();
    }

    private static Dictionary<string, ManifestRow> LoadManifest(string root)
    {
        var result = new Dictionary<string, ManifestRow>(StringComparer.OrdinalIgnoreCase);
        foreach (var manifestPath in new[] { Path.Combine(root, "screen_hts.vst"), Path.Combine(root, "mst.vst") })
        {
            if (!File.Exists(manifestPath)) continue;
            foreach (var raw in ReadKoreanLines(manifestPath))
            {
                var line = raw.Trim();
                var pathMatch = Regex.Match(line, @"\b(?<path>(?:screen|mst)/[^\s]+)\s+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
                if (!pathMatch.Success || line.Length < 44) continue;
                var md5 = line.Substring(line.Length - 44, 32).ToUpperInvariant();
                if (!Regex.IsMatch(md5, "^[0-9A-F]{32}$", RegexOptions.CultureInvariant)) continue;
                if (!long.TryParse(line[^12..], NumberStyles.None, CultureInfo.InvariantCulture, out var size)) continue;
                var prefix = line[..^44];
                var timestampMatches = Regex.Matches(prefix, @"20\d{12}", RegexOptions.CultureInvariant);
                DateTimeOffset? timestamp = null;
                if (timestampMatches.Count > 0 && DateTime.TryParseExact(
                    timestampMatches[^1].Value,
                    "yyyyMMddHHmmss",
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeLocal,
                    out var parsed)) timestamp = parsed;
                var relative = NormalizeRelativePath(pathMatch.Groups["path"].Value);
                result[relative] = new ManifestRow(relative, md5, size, timestamp, manifestPath);
            }
        }
        return result;
    }

    private static HtsIntegrityDefinition[] BuildIntegrity(
        string root,
        IEnumerable<string> relativePaths,
        IReadOnlyDictionary<string, ManifestRow> manifest)
    {
        var result = new List<HtsIntegrityDefinition>();
        foreach (var relative in relativePaths.Select(NormalizeRelativePath).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var path = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
            var exists = File.Exists(path);
            manifest.TryGetValue(relative, out var expected);
            var actualMd5 = exists ? Convert.ToHexString(MD5.HashData(File.ReadAllBytes(path))) : string.Empty;
            var actualSize = exists ? new FileInfo(path).Length : 0;
            var hashMatches = expected is not null && exists && actualMd5.Equals(expected.Md5, StringComparison.OrdinalIgnoreCase);
            var sizeMatches = expected is not null && exists && actualSize == expected.Size;
            result.Add(new HtsIntegrityDefinition
            {
                RelativePath = relative,
                ManifestFile = expected?.ManifestFile ?? string.Empty,
                ExpectedMd5 = expected?.Md5 ?? string.Empty,
                ActualMd5 = actualMd5,
                ExpectedSize = expected?.Size ?? 0,
                ActualSize = actualSize,
                DistributionTimestamp = expected?.Timestamp,
                Exists = exists,
                ManifestEntryFound = expected is not null,
                HashMatches = hashMatches,
                SizeMatches = sizeMatches,
                Status = !exists ? "FILE_MISSING" : expected is null ? "MANIFEST_MISSING" : hashMatches && sizeMatches ? "MATCH" : "MISMATCH"
            });
        }
        return result.ToArray();
    }

    private static HtsMasterDataSourceDefinition[] LoadMasterSources(
        string root,
        IReadOnlyDictionary<string, HtsIntegrityDefinition> integrity)
    {
        var definitions = new[]
        {
            (Id: "KRX_STOCK", Relative: "mst/stkcode.cod", Purpose: "KRX 주식 종목 입력값"),
            (Id: "NXT_STOCK", Relative: "mst/nxtcode.cod", Purpose: "NXT 주식 종목 입력값"),
            (Id: "ETF", Relative: "mst/etfcode.cod", Purpose: "ETF 종목 입력값")
        };
        var result = new List<HtsMasterDataSourceDefinition>();
        foreach (var definition in definitions)
        {
            var path = Path.Combine(root, definition.Relative.Replace('/', Path.DirectorySeparatorChar));
            if (!File.Exists(path)) continue;
            var lines = ReadKoreanLines(path).Where(x => !string.IsNullOrWhiteSpace(x)).ToArray();
            var samples = lines.Select(x => ParseMasterSample(x, definition.Id)).Where(x => x is not null).Cast<HtsMasterSampleDefinition>().Take(5).ToArray();
            result.Add(new HtsMasterDataSourceDefinition
            {
                Id = definition.Id,
                RelativePath = definition.Relative,
                Purpose = definition.Purpose,
                RecordCount = lines.LongLength,
                Samples = samples,
                Integrity = integrity.GetValueOrDefault(definition.Relative)
            });
        }
        return result.ToArray();
    }

    private static HtsMasterSampleDefinition? ParseMasterSample(string line, string source)
    {
        if (source == "ETF")
        {
            var match = Regex.Match(line, @"^(?<code>[A-Za-z0-9]{6})=(?<name>.*?)(?<market>\d{2})\s*$", RegexOptions.CultureInvariant);
            if (!match.Success) return null;
            return new HtsMasterSampleDefinition
            {
                Code = match.Groups["code"].Value,
                Name = match.Groups["name"].Value.Trim(),
                Market = match.Groups["market"].Value,
                ExpectedOutcome = CreateMasterSuccessOutcome(source)
            };
        }
        var stock = Regex.Match(line, @"^KR7(?<code>\d{6})\d{9}(?<name>.{1,40})", RegexOptions.CultureInvariant);
        if (!stock.Success) return null;
        var rawName = stock.Groups["name"].Value.Trim();
        var normalizedName = Regex.Split(rawName, @"\s{2,}", RegexOptions.CultureInvariant).FirstOrDefault() ?? rawName;
        return new HtsMasterSampleDefinition
        {
            Code = stock.Groups["code"].Value,
            Name = normalizedName,
            Market = source == "NXT_STOCK" ? "NXT" : "KRX",
            ExpectedOutcome = CreateMasterSuccessOutcome(source)
        };
    }

    private static RuleExpectedOutcome CreateMasterSuccessOutcome(string source) => new()
    {
        Type = RuleExpectedOutcomeType.Success,
        Source = RuleExpectationSource.InstallationMaster,
        Confidence = RuleExpectationConfidence.High,
        Evidence = [$"HTS 설치 종목 마스터: {source}"],
        QueryShouldComplete = true
    };

    private static HtsLogSourceDefinition[] BuildLogSources(string root) =>
    [
        new() { Id = "DEBUG_MAIN", PathPattern = Path.Combine(root, "log", "debugmain.log"), Mode = "AppendText", Purpose = "HTS 공통 디버그 오류" },
        new() { Id = "SOCKET_ERROR", PathPattern = Path.Combine(root, "log", "SocketErr.log"), Mode = "AppendText", Purpose = "통신 소켓 오류" },
        new() { Id = "STARTER", PathPattern = Path.Combine(root, "log", "Starter.log"), Mode = "AppendText", Purpose = "시작·업데이트 오류" },
        new() { Id = "AUTO_LOGOUT", PathPattern = Path.Combine(root, "user", "*", "AutoLogOut.log"), Mode = "AppendText", Purpose = "세션 만료·자동 로그아웃" },
        new() { Id = "LAST_DUMP", PathPattern = Path.Combine(root, "user", "LastDumpLog.ini"), Mode = "DiagnosticSnapshot", Purpose = "비정상 종료 시 마지막 화면·버튼 문맥" },
        new() { Id = "CHEJAN_DELTA", PathPattern = Path.Combine(root, "user", "*", "CheJanLog.txt"), Mode = "SensitiveDelta", Purpose = "조회 테스트 중 예상하지 못한 체결 이벤트", Sensitive = true, FailureOnChange = true }
    ];

    private static string ComputeFingerprint(IEnumerable<HtsIntegrityDefinition> entries)
    {
        var text = string.Join('\n', entries
            .OrderBy(x => x.RelativePath, StringComparer.OrdinalIgnoreCase)
            .Select(x => $"{x.RelativePath}|{x.ActualMd5}|{x.ActualSize}"));
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
    }

    private static string[] ReadKoreanLines(string path) => KoreanEncoding
        .GetString(File.ReadAllBytes(path))
        .Split(["\r\n", "\n"], StringSplitOptions.None);

    private static string NormalizeRelativePath(string path) => path.Replace('\\', '/').ToLowerInvariant();

    private static string NormalizeScreenNumber(string value)
    {
        var trimmed = value.Trim();
        return trimmed.Length == 3 && trimmed.All(char.IsDigit) ? trimmed.PadLeft(4, '0') : trimmed;
    }

    private static Encoding CreateKoreanEncoding()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        return Encoding.GetEncoding(949);
    }
}
