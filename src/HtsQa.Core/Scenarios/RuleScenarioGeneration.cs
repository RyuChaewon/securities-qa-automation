// 역할: MAP, Plan-only 런타임 컨트롤과 데이터셋을 결합해 LLM 없는 결정론적 시나리오를 생성한다.
// 입력/출력: RuleDataset·HtsMapCatalog·runtime control plan을 승인 전 RuleScenarioSource 문서로 변환한다.
// 경계: 사용자 명시값 우선, 공식/런타임 선택지 보충, 컨트롤별 전수, 서로 다른 컨트롤의 전역 곱 금지다.
// 수정 지점: 생성 규칙은 안정적인 ID·정렬·근거를 유지하고 결정성 테스트를 반드시 추가한다.
using System.Text.RegularExpressions;

namespace HtsQa.Core;

public static class RuleScenarioGeneratorVersions
{
    public const string Generator = "HtsQa.RuleScenarioGenerator";
    public const string Version = "1.1.0";
    public const string GenerationMode = "DeterministicRuleBased";
    public const string ApprovalPolicy = "HtsQa.RuleScenarioAutoApprovalPolicy/1.0.0";
}

/// <summary>자동 생성 시 기준일, 선택지 상한과 허용 명령 범주를 제어한다.</summary>
public sealed record RuleScenarioGenerationOptions
{
    public required DateOnly ReferenceDate { get; init; }
    public int MaxOptionsPerControl { get; init; } = 40;
    public int MaxTextValuesPerControl { get; init; } = 4;
    public bool IncludeNavigationActions { get; init; } = true;
    public bool IncludePaginationActions { get; init; } = true;
    public bool IncludeStateActions { get; init; } = true;
    public string MapCatalogSha256 { get; init; } = "";
    public string RuntimeControlPlanSha256 { get; init; } = "";
}

/// <summary>생성 문서와 화면·시나리오·케이스·공백 통계를 함께 반환한다.</summary>
public sealed record RuleScenarioGenerationResult
{
    public required GeneratedScenarioDocument Document { get; init; }
    public int ScreenCount { get; init; }
    public int ScenarioCount { get; init; }
    public int VariableCount { get; init; }
    public int ProjectedCasesPerAccount { get; init; }
    public int CoverageGapCount { get; init; }
    public int RuntimeOptionControlCount { get; init; }
}

/// <summary>정적 MAP과 런타임 선택지를 실행기가 이해하는 시나리오 계약으로 변환한다.</summary>
public sealed class RuleScenarioGenerator
{
    private static readonly Regex IdentifierCharacters = new("[^A-Za-z0-9_]", RegexOptions.CultureInvariant);
    private static readonly Regex CloseControlPattern = new(
        "(^|_)(close|cancel|exit|quit|end)($|_)|닫기|종료|취소",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex LifecycleHandlerPattern = new(
        "close|destroy|exit|cancel|quit|terminate|unload|닫기|종료|취소",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>활성 데이터셋 화면을 순회하며 자동 시나리오, 변수, 로케이터 요청과 제외 사유를 생성한다.</summary>
    public RuleScenarioGenerationResult Generate(
        HtsMapCatalog catalog,
        RuleTestDataset dataset,
        IReadOnlyCollection<RuntimeControlPlanRow>? runtimeRows,
        RuleScenarioGenerationOptions options)
    {
        ArgumentNullException.ThrowIfNull(catalog);
        ArgumentNullException.ThrowIfNull(dataset);
        ArgumentNullException.ThrowIfNull(options);
        if (options.MaxOptionsPerControl < 1) throw new ArgumentOutOfRangeException(nameof(options.MaxOptionsPerControl));
        if (options.MaxTextValuesPerControl < 1) throw new ArgumentOutOfRangeException(nameof(options.MaxTextValuesPerControl));

        var runtimeByScreen = (runtimeRows ?? [])
            .GroupBy(x => x.ScreenNumber, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(x => x.Key, x => x.SelectMany(row => row.DiscoveredControls).ToArray(), StringComparer.OrdinalIgnoreCase);
        var mapByScreen = catalog.Screens
            .GroupBy(x => x.ScreenNumber, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(x => x.Key, x => x.First(), StringComparer.OrdinalIgnoreCase);
        var generatedScreens = new List<GeneratedScreenScenario>();
        var variables = new List<GeneratedScenarioVariable>();
        var locators = new Dictionary<string, GeneratedLocatorRequest>(StringComparer.OrdinalIgnoreCase);
        var reviewItems = new List<GeneratedReviewItem>();
        var runtimeOptionControls = 0;

        foreach (var datasetScreen in dataset.Screens.Where(x => x.Enabled).OrderBy(x => x.ScreenNumber, StringComparer.OrdinalIgnoreCase))
        {
            if (!mapByScreen.TryGetValue(datasetScreen.ScreenNumber, out var mapScreen))
            {
                generatedScreens.Add(new GeneratedScreenScenario
                {
                    ScreenNumber = datasetScreen.ScreenNumber,
                    ScreenName = datasetScreen.ScreenName,
                    CoverageGaps = ["MAP 기준 모델을 찾지 못해 자동 시나리오를 생성하지 못했습니다."]
                });
                reviewItems.Add(new GeneratedReviewItem
                {
                    Severity = "Required",
                    ScreenNumber = datasetScreen.ScreenNumber,
                    Subject = "MAP 기준 모델 누락",
                    Question = "설치본과 화면번호가 일치하는 MAP 파일을 확보했는지 확인해야 합니다.",
                    Reason = "정적 기준 모델이 없으면 컨트롤 경계와 역할을 안전하게 확정할 수 없습니다."
                });
                continue;
            }

            runtimeByScreen.TryGetValue(datasetScreen.ScreenNumber, out var runtimeControls);
            runtimeControls ??= [];
            var scenarios = new List<GeneratedScenario>();
            var gaps = new List<string>();
            var queryControls = ResolveControls(mapScreen, mapScreen.Behavior.QueryControls).ToArray();
            var primaryQuery = queryControls.FirstOrDefault();

            foreach (var query in queryControls)
            {
                AddLocator(locators, mapScreen, query, "Command", "MAP 조회 이벤트와 런타임 탭오더를 결합");
                scenarios.Add(CommandScenario(
                    mapScreen,
                    query,
                    "QUERY",
                    "기본 조회",
                    "P0",
                    "조회",
                    "Query",
                    "조회 완료 또는 명시적 정상 안내를 관찰"));
            }

            foreach (var control in mapScreen.Controls.Where(x => x.IsActionable).OrderBy(x => x.DefinitionOrder))
            {
                if (queryControls.Any(x => SameControl(x, control))) continue;
                var controlKind = ToRuleKind(control);
                var autoQuery = mapScreen.Behavior.AutoQueryControls.Contains(control.LogicalName, StringComparer.OrdinalIgnoreCase);
                var datasetVariable = FindDatasetVariable(dataset, mapScreen.ScreenNumber, control);
                switch (control.Kind)
                {
                    case HtsMapControlKind.Account:
                    case HtsMapControlKind.Password:
                        gaps.Add($"{control.LogicalName}: 계좌/비밀번호는 데이터셋 계정 정책과 기본 입력값을 사용하므로 자동 변형하지 않음");
                        break;

                    case HtsMapControlKind.Date:
                        AddVariableScenario(
                            mapScreen,
                            control,
                            RuleControlKind.Date,
                            RuleValueMatch.Value,
                            DateValues(dataset, mapScreen, control, options.ReferenceDate, options.MaxOptionsPerControl, datasetVariable),
                            "DATE",
                            "날짜 경계값",
                            "P1",
                            "입력",
                            primaryQuery,
                            autoQuery,
                            scenarios,
                            variables,
                            locators);
                        break;

                    case HtsMapControlKind.CheckBox:
                        AddVariableScenario(
                            mapScreen,
                            control,
                            RuleControlKind.CheckBox,
                            RuleValueMatch.Checked,
                            MergeValues(DatasetValues(datasetVariable), BooleanValues(), options.MaxOptionsPerControl),
                            "CHECK",
                            "체크 상태 전수",
                            "P1",
                            "상태",
                            primaryQuery,
                            autoQuery,
                            scenarios,
                            variables,
                            locators);
                        break;

                    case HtsMapControlKind.ComboBox:
                    case HtsMapControlKind.RadioGroup:
                    case HtsMapControlKind.Tab:
                    {
                        var optionResult = OptionValues(control, runtimeControls, datasetVariable, options.MaxOptionsPerControl);
                        if (optionResult.Values.Length == 0)
                        {
                            gaps.Add($"{control.LogicalName}: MAP과 런타임 계획 모두에서 선택 항목을 확인하지 못함");
                            break;
                        }
                        if (optionResult.RuntimeUsed) runtimeOptionControls++;
                        AddVariableScenario(
                            mapScreen,
                            control,
                            controlKind,
                            optionResult.ValueMatch,
                            optionResult.Values,
                            "OPTION",
                            "선택 항목 전수",
                            "P1",
                            "선택",
                            primaryQuery,
                            autoQuery,
                            scenarios,
                            variables,
                            locators);
                        break;
                    }

                    case HtsMapControlKind.Text:
                    case HtsMapControlKind.Instrument:
                        AddVariableScenario(
                            mapScreen,
                            control,
                            controlKind,
                            RuleValueMatch.Value,
                            TextValues(catalog, dataset, mapScreen, control, options.MaxTextValuesPerControl, datasetVariable),
                            control.Kind == HtsMapControlKind.Instrument ? "INSTRUMENT" : "TEXT",
                            control.Kind == HtsMapControlKind.Instrument ? "종목 입력 경계값" : "문자 입력 경계값",
                            "P2",
                            "입력",
                            primaryQuery,
                            autoQuery,
                            scenarios,
                            variables,
                            locators);
                        break;

                    case HtsMapControlKind.Button:
                        AddButtonScenario(mapScreen, control, scenarios, gaps, locators, options);
                        break;

                    case HtsMapControlKind.Spin:
                    case HtsMapControlKind.Slider:
                        gaps.Add($"{control.LogicalName}: {control.Kind}의 안전한 최소/최대 범위를 MAP에서 확인하지 못함");
                        break;

                    default:
                        gaps.Add($"{control.LogicalName}: 지원하지 않는 활성 컨트롤 종류 {control.Kind}");
                        break;
                }
            }

            generatedScreens.Add(new GeneratedScreenScenario
            {
                ScreenNumber = mapScreen.ScreenNumber,
                ScreenName = string.IsNullOrWhiteSpace(mapScreen.ScreenName) ? datasetScreen.ScreenName : mapScreen.ScreenName,
                Scenarios = scenarios
                    .GroupBy(x => x.ScenarioId, StringComparer.OrdinalIgnoreCase)
                    .Select(x => x.First() with { ExecutionOrder = dataset.AutoExploration.InteractionStrategy })
                    .OrderBy(x => x.Priority, StringComparer.OrdinalIgnoreCase)
                    .ThenBy(x => x.ScenarioId, StringComparer.OrdinalIgnoreCase)
                    .ToArray(),
                CoverageGaps = gaps.Distinct(StringComparer.OrdinalIgnoreCase).ToArray()
            });
        }

        var document = new GeneratedScenarioDocument
        {
            PackageVersion = ScenarioPlanVersions.SourceSchema,
            SourceInstallationFingerprint = string.IsNullOrWhiteSpace(catalog.InstallationFingerprint)
                ? ScenarioIds.Hash(string.Join('|', catalog.Screens.OrderBy(x => x.ScreenNumber).Select(x => x.SourceSha256)), 32)
                : catalog.InstallationFingerprint,
            GenerationSummary = new GeneratedScenarioSummary
            {
                ReferenceDate = options.ReferenceDate.ToString("yyyyMMdd"),
                CombinationStrategy = "컨트롤별 전수 선택 + 날짜/문자 경계값; 서로 다른 입력 컨트롤의 전역 카테시안 곱은 생성하지 않음",
                GenerationMode = RuleScenarioGeneratorVersions.GenerationMode,
                Generator = RuleScenarioGeneratorVersions.Generator,
                GeneratorVersion = RuleScenarioGeneratorVersions.Version,
                RuntimeDiscoveryUsed = runtimeRows is { Count: > 0 },
                MapCatalogSha256 = options.MapCatalogSha256,
                RuntimeControlPlanSha256 = options.RuntimeControlPlanSha256,
                Assumptions =
                [
                    $"{dataset.TargetProfile.DisplayName}의 현재 화면 기본 입력값을 유지합니다.",
                    "조회 버튼은 각 입력·선택 변경 뒤 명시적으로 실행합니다.",
                    "파일 저장 대화상자를 열 수 있는 내보내기와 화면 종료 컨트롤은 자동 실행 범위에서 제외합니다.",
                    "예상 검증 메시지는 제품 결함이 아니라 기대된 입력 검증 이벤트로 판정합니다."
                ]
            },
            Screens = generatedScreens.ToArray(),
            DatasetPatch = new GeneratedDatasetPatch
            {
                Variables = variables.ToArray(),
                LocatorRequests = locators.Values
                    .OrderBy(x => x.ScreenNumber, StringComparer.OrdinalIgnoreCase)
                    .ThenBy(x => x.LogicalName, StringComparer.OrdinalIgnoreCase)
                    .ToArray()
            },
            ReviewItems = reviewItems.ToArray()
        };
        var valuesByVariable = document.DatasetPatch.Variables.ToDictionary(x => x.Name, x => x.Values.Length, StringComparer.OrdinalIgnoreCase);
        return new RuleScenarioGenerationResult
        {
            Document = document,
            ScreenCount = document.Screens.Length,
            ScenarioCount = document.Screens.Sum(x => x.Scenarios.Length),
            VariableCount = document.DatasetPatch.Variables.Length,
            ProjectedCasesPerAccount = document.Screens.Sum(x => x.Scenarios.Sum(scenario => ScenarioCaseCount(scenario, valuesByVariable))),
            CoverageGapCount = document.Screens.Sum(x => x.CoverageGaps.Length),
            RuntimeOptionControlCount = runtimeOptionControls
        };
    }

    private static void AddButtonScenario(
        HtsMapScreenDefinition screen,
        HtsMapControlDefinition control,
        ICollection<GeneratedScenario> scenarios,
        ICollection<string> gaps,
        IDictionary<string, GeneratedLocatorRequest> locators,
        RuleScenarioGenerationOptions options)
    {
        if (IsLifecycleControl(screen, control))
        {
            gaps.Add($"{control.LogicalName}: 화면 수명주기 보호 정책에 따라 닫기/종료 컨트롤은 화면 테스트 종료 시 실행기가 처리함");
            return;
        }
        if (screen.Behavior.ExportControls.Contains(control.LogicalName, StringComparer.OrdinalIgnoreCase))
        {
            gaps.Add($"{control.LogicalName}: HTS 외부 파일 저장 대화상자 가능성이 있어 내부 조작 경계 정책상 제외함");
            return;
        }

        var isPagination = screen.Behavior.PaginationControls.Contains(control.LogicalName, StringComparer.OrdinalIgnoreCase);
        var isNavigation = screen.Behavior.NavigationControls.Contains(control.LogicalName, StringComparer.OrdinalIgnoreCase);
        var isState = screen.Behavior.StateControllerControls.Contains(control.LogicalName, StringComparer.OrdinalIgnoreCase);
        if (isPagination && !options.IncludePaginationActions || isNavigation && !options.IncludeNavigationActions || isState && !options.IncludeStateActions)
        {
            gaps.Add($"{control.LogicalName}: 자동 생성 옵션에서 해당 명령 범주를 제외함");
            return;
        }

        var category = isPagination ? "페이지" : isNavigation ? "화면내이동" : isState ? "상태" : "버튼";
        var label = isPagination ? "페이지 이동" : isNavigation ? "HTS 내부 이동" : isState ? "상태 전환" : "명령 실행";
        AddLocator(locators, screen, control, "Command", "MAP 버튼 이벤트와 런타임 탭오더를 결합");
        scenarios.Add(CommandScenario(screen, control, "BUTTON", label, isNavigation ? "P2" : "P1", category, "Click", "명령 실행 뒤 오류 팝업·비정상 로그·화면 응답을 관찰"));
    }

    private static void AddVariableScenario(
        HtsMapScreenDefinition screen,
        HtsMapControlDefinition control,
        RuleControlKind kind,
        RuleValueMatch match,
        GeneratedScenarioValue[] values,
        string idCategory,
        string title,
        string priority,
        string category,
        HtsMapControlDefinition? queryControl,
        bool autoQuery,
        ICollection<GeneratedScenario> scenarios,
        ICollection<GeneratedScenarioVariable> variables,
        IDictionary<string, GeneratedLocatorRequest> locators)
    {
        if (values.Length == 0) return;
        var variableName = $"auto_{screen.ScreenNumber}_{SafeIdentifier(control.LogicalName)}_{idCategory.ToLowerInvariant()}";
        variables.Add(new GeneratedScenarioVariable
        {
            Name = variableName,
            TargetRole = category,
            TargetLogicalName = control.LogicalName,
            ControlKind = kind,
            ValueMatch = match,
            Values = values,
            AppliesToScreens = [screen.ScreenNumber],
            Required = true,
            TriggerQueryAfterChange = false
        });

        var action = kind switch
        {
            RuleControlKind.ComboBox or RuleControlKind.RadioButton or RuleControlKind.RadioGroup or RuleControlKind.Tab => "Select",
            RuleControlKind.CheckBox => "Toggle",
            _ => "Input"
        };
        var steps = new List<GeneratedScenarioStep>
        {
            new()
            {
                Sequence = 1,
                Action = action,
                ControlLogicalName = control.LogicalName,
                ValueRef = variableName,
                ExpectedObservation = "MAP 정의와 런타임 탭오더로 대상 컨트롤을 찾아 값을 적용"
            }
        };
        if (queryControl is not null && !autoQuery)
        {
            steps.Add(new GeneratedScenarioStep
            {
                Sequence = 2,
                Action = "Query",
                ControlLogicalName = queryControl.LogicalName,
                ExpectedObservation = "입력 변경 뒤 조회 실행"
            });
            AddLocator(locators, screen, queryControl, "Command", "입력 시나리오의 명시적 조회 기준점");
        }
        steps.Add(new GeneratedScenarioStep
        {
            Sequence = steps.Count + 1,
            Action = "Observe",
            ExpectedObservation = autoQuery ? "자동 조회 완료와 명시적 오류 여부를 관찰" : "조회 또는 상태 변경 결과와 명시적 오류 여부를 관찰"
        });

        AddLocator(locators, screen, control, category, "MAP logicalName·종류·상대위치와 런타임 탭오더를 결합");
        scenarios.Add(new GeneratedScenario
        {
            ScenarioId = ScenarioId(screen.ScreenNumber, idCategory, control.LogicalName),
            Title = $"{control.LogicalName} {title}",
            Objective = $"{control.LogicalName} 컨트롤의 가능한 값 또는 경계값을 순서대로 검증",
            Priority = priority,
            Category = category,
            ExecutionOrder = "RuntimeTabOrder",
            Preconditions = ["대상 화면이 열려 있고 현재 화면 내부 컨텐츠 경계가 확정되어야 함"],
            Steps = steps.ToArray(),
            CoveredControls = queryControl is null ? [control.LogicalName] : [control.LogicalName, queryControl.LogicalName],
            CoveredValidationRuleIds = ValidationMessages(screen, control).Select(x => x.RuleId).Distinct(StringComparer.OrdinalIgnoreCase).ToArray(),
            ExpectedResult = "기대된 입력 검증은 정상 이벤트로 분리하고, 그 밖의 명시적 오류·예외·화면 비응답은 결함 후보로 기록",
            AutomationStatus = "NeedsLocator"
        });
    }

    private static GeneratedScenario CommandScenario(
        HtsMapScreenDefinition screen,
        HtsMapControlDefinition control,
        string idCategory,
        string title,
        string priority,
        string category,
        string action,
        string observation) => new()
    {
        ScenarioId = ScenarioId(screen.ScreenNumber, idCategory, control.LogicalName),
        Title = $"{control.LogicalName} {title}",
        Objective = $"{control.LogicalName} 명령 실행과 화면 응답 검증",
        Priority = priority,
        Category = category,
        ExecutionOrder = "RuntimeTabOrder",
        Preconditions = ["대상 화면이 열려 있고 현재 화면 내부 컨텐츠 경계가 확정되어야 함"],
        Steps =
        [
            new GeneratedScenarioStep
            {
                Sequence = 1,
                Action = action,
                ControlLogicalName = control.LogicalName,
                ExpectedObservation = observation
            },
            new GeneratedScenarioStep
            {
                Sequence = 2,
                Action = "Observe",
                ExpectedObservation = "예상 밖 팝업, 명시적 오류, 비정상 로그, 화면 비응답을 관찰"
            }
        ],
        CoveredControls = [control.LogicalName],
        CoveredValidationRuleIds = ValidationMessages(screen, control).Select(x => x.RuleId).Distinct(StringComparer.OrdinalIgnoreCase).ToArray(),
        ExpectedResult = "명령이 응답하고 예상 밖의 명시적 오류가 없어야 함",
        AutomationStatus = "NeedsLocator"
    };

    private static GeneratedScenarioValue[] DateValues(
        RuleTestDataset dataset,
        HtsMapScreenDefinition screen,
        HtsMapControlDefinition control,
        DateOnly referenceDate,
        int limit,
        RuleVariableDimension? explicitVariable)
    {
        var candidates = new[]
        {
            ("reference", referenceDate, "기준일"),
            ("previous-day", referenceDate.AddDays(-1), "전일"),
            ("month-start", new DateOnly(referenceDate.Year, referenceDate.Month, 1), "월초"),
            ("year-start", new DateOnly(referenceDate.Year, 1, 1), "연초"),
            ("next-day", referenceDate.AddDays(1), "익일")
        };
        var generated = candidates.GroupBy(x => x.Item2).Select(x => x.First()).Select(x => new GeneratedScenarioValue
        {
            Id = x.Item1,
            Value = x.Item2.ToString("yyyyMMdd"),
            DisplayValue = x.Item3,
            ExpectedOutcome = ObservationExpected(screen, control, RuleExpectationSource.GeneratedBoundary, "자동 생성 기준일 경계값"),
            Rationale = $"{x.Item3} 날짜 형식과 조회 응답 확인",
            SourceRefs = ["AUTO:DATE-BOUNDARY"]
        }).ToArray();
        var defaults = dataset.AutoExploration.DefaultDateValues.Select(value => DatasetDefaultValue(value, "날짜 기본값")).ToArray();
        return MergeValues(DatasetValues(explicitVariable), defaults, generated, limit);
    }

    private static GeneratedScenarioValue[] BooleanValues() =>
    [
        Value("unchecked", "false", "미체크", RuleExpectationSource.GeneratedBoundary, "체크 해제 상태"),
        Value("checked", "true", "체크", RuleExpectationSource.GeneratedBoundary, "체크 상태")
    ];

    private static (GeneratedScenarioValue[] Values, RuleValueMatch ValueMatch, bool RuntimeUsed) OptionValues(
        HtsMapControlDefinition control,
        IReadOnlyCollection<RuleDiscoveredControl> runtimeControls,
        RuleVariableDimension? explicitVariable,
        int limit)
    {
        var preferredMatch = explicitVariable?.ValueMatch;
        if (control.StaticOptions.Length > 0)
        {
            var match = preferredMatch ?? RuleValueMatch.Value;
            var automatic = control.StaticOptions.Select(option => new GeneratedScenarioValue
            {
                Id = SafeValueId(option.Id, option.Index),
                Value = match switch
                {
                    RuleValueMatch.DisplayText => option.DisplayValue,
                    RuleValueMatch.Index => option.Index.ToString(),
                    _ => option.Value
                },
                DisplayValue = option.DisplayValue,
                ExpectedOutcome = NormalizeExpected(option.ExpectedOutcome, RuleExpectationSource.InstallationInputOption, RuleExpectationConfidence.High, option.Source),
                Rationale = "HTS 설치본의 공식 선택 항목 전수",
                SourceRefs = [option.Source]
            }).ToArray();
            return (MergeValues(DatasetValues(explicitVariable), automatic, limit), match, false);
        }

        var runtime = FindRuntimeControl(control, runtimeControls);
        if (runtime is null || runtime.Options.Length == 0)
            return (DatasetValues(explicitVariable).Take(limit).ToArray(), preferredMatch ?? RuleValueMatch.Index, false);
        var runtimeMatch = preferredMatch ?? RuleValueMatch.Index;
        var values = runtime.Options.Select((option, index) => new GeneratedScenarioValue
        {
            Id = SafeValueId(option.Id, index),
            Value = runtimeMatch switch
            {
                RuleValueMatch.DisplayText => option.DisplayValue ?? option.Value,
                RuleValueMatch.Value => option.Value,
                _ => int.TryParse(option.Value, out _) ? option.Value : index.ToString()
            },
            DisplayValue = option.DisplayValue ?? option.Value,
            ExpectedOutcome = NormalizeExpected(option.ExpectedOutcome, RuleExpectationSource.RuntimeChoice, RuleExpectationConfidence.Medium, runtime.ControlId),
            Rationale = "계획 전용 런타임 탐색에서 확인한 선택 항목",
            SourceRefs = [$"RUNTIME:{runtime.ControlId}"]
        }).ToArray();
        return (MergeValues(DatasetValues(explicitVariable), values, limit), runtimeMatch, true);
    }

    private static GeneratedScenarioValue[] TextValues(
        HtsMapCatalog catalog,
        RuleTestDataset dataset,
        HtsMapScreenDefinition screen,
        HtsMapControlDefinition control,
        int limit,
        RuleVariableDimension? explicitVariable)
    {
        var values = new List<GeneratedScenarioValue>();
        values.AddRange(DatasetValues(explicitVariable));
        if (control.Kind == HtsMapControlKind.Instrument)
        {
            foreach (var sample in catalog.MasterDataSources.SelectMany(x => x.Samples).Take(Math.Max(1, limit - 1)))
            {
                values.Add(new GeneratedScenarioValue
                {
                    Id = $"master-{SafeValueId(sample.Code, values.Count)}",
                    Value = sample.Code,
                    DisplayValue = sample.Name,
                    ExpectedOutcome = NormalizeExpected(sample.ExpectedOutcome, RuleExpectationSource.InstallationMaster, RuleExpectationConfidence.High, sample.Market),
                    Rationale = "HTS 설치본 마스터 데이터의 정상 종목 표본",
                    SourceRefs = ["INSTALLATION:MASTER"]
                });
            }
        }
        else
        {
            values.AddRange(dataset.AutoExploration.DefaultTextValues.Select(value => DatasetDefaultValue(value, "문자 기본값")));
        }
        values.Add(Value("max-digits", "99999999", "99999999", RuleExpectationSource.GeneratedBoundary, "긴 숫자 및 미등록 코드 경계값", screen, control));
        return values
            .GroupBy(x => x.Value, StringComparer.Ordinal)
            .Select(x => x.First())
            .Take(limit)
            .ToArray();
    }

    private static RuleVariableDimension? FindDatasetVariable(
        RuleTestDataset dataset,
        string screenNumber,
        HtsMapControlDefinition control) => dataset.Variables.FirstOrDefault(variable =>
        (variable.AppliesToScreens.Contains("*", StringComparer.OrdinalIgnoreCase) ||
         variable.AppliesToScreens.Contains(screenNumber, StringComparer.OrdinalIgnoreCase)) &&
        (variable.Name.Equals(control.LogicalName, StringComparison.OrdinalIgnoreCase) ||
         variable.TargetRole?.Equals(control.LogicalName, StringComparison.OrdinalIgnoreCase) == true ||
         variable.Name.Equals(control.ModelId, StringComparison.OrdinalIgnoreCase) ||
         variable.TargetRole?.Equals(control.ModelId, StringComparison.OrdinalIgnoreCase) == true));

    private static GeneratedScenarioValue[] DatasetValues(RuleVariableDimension? variable) => variable?.Values.Select(value => new GeneratedScenarioValue
    {
        Id = SafeValueId(value.Id, 0),
        Value = value.Value,
        DisplayValue = value.DisplayValue ?? value.Value,
        ExpectedOutcome = NormalizeExpected(value.ExpectedOutcome, RuleExpectationSource.Dataset, RuleExpectationConfidence.High, variable.Name),
        Rationale = $"기준 데이터셋 변수 {variable.Name}에 명시된 값",
        SourceRefs = [$"DATASET:{variable.Name}"]
    }).ToArray() ?? [];

    private static GeneratedScenarioValue DatasetDefaultValue(RuleVariableValue value, string rationale) => new()
    {
        Id = SafeValueId(value.Id, 0),
        Value = value.Value,
        DisplayValue = value.DisplayValue ?? value.Value,
        ExpectedOutcome = NormalizeExpected(value.ExpectedOutcome, RuleExpectationSource.DatasetDefault, RuleExpectationConfidence.Medium, value.Id),
        Rationale = rationale,
        SourceRefs = ["DATASET:AUTO-EXPLORATION-DEFAULT"]
    };

    private static GeneratedScenarioValue[] MergeValues(
        GeneratedScenarioValue[] first,
        GeneratedScenarioValue[] second,
        int limit) => MergeValues(first, second, [], limit);

    private static GeneratedScenarioValue[] MergeValues(
        GeneratedScenarioValue[] first,
        GeneratedScenarioValue[] second,
        GeneratedScenarioValue[] third,
        int limit) => first.Concat(second).Concat(third)
        .GroupBy(x => x.Value, StringComparer.Ordinal)
        .Select(x => x.First())
        .Take(limit)
        .ToArray();

    private static GeneratedScenarioValue Value(
        string id,
        string value,
        string display,
        RuleExpectationSource source,
        string rationale,
        HtsMapScreenDefinition? screen = null,
        HtsMapControlDefinition? control = null)
    {
        var expected = screen is not null && control is not null
            ? ObservationExpected(screen, control, source, rationale)
            : new RuleExpectedOutcome
            {
                Type = RuleExpectedOutcomeType.ObservationOnly,
                QueryShouldComplete = true,
                Source = source,
                Confidence = RuleExpectationConfidence.Medium,
                Evidence = [rationale]
            };
        return new GeneratedScenarioValue
        {
            Id = id,
            Value = value,
            DisplayValue = display,
            ExpectedOutcome = expected,
            Rationale = rationale,
            SourceRefs = [$"AUTO:{source}"]
        };
    }

    private static RuleExpectedOutcome ObservationExpected(
        HtsMapScreenDefinition screen,
        HtsMapControlDefinition control,
        RuleExpectationSource source,
        string evidence)
    {
        var messages = ValidationMessages(screen, control).Where(x => !string.IsNullOrWhiteSpace(x.Message)).ToArray();
        return new RuleExpectedOutcome
        {
            Type = RuleExpectedOutcomeType.ObservationOnly,
            MessagePatterns = messages.Select(x => Regex.Escape(x.Message)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray(),
            QueryShouldComplete = null,
            Source = messages.Length > 0 ? RuleExpectationSource.MapValidation : source,
            Confidence = messages.Length > 0 ? RuleExpectationConfidence.High : RuleExpectationConfidence.Medium,
            Evidence = messages.Length > 0 ? messages.Select(x => $"MAP:{x.RuleId}").ToArray() : [evidence]
        };
    }

    private static RuleExpectedOutcome NormalizeExpected(
        RuleExpectedOutcome expected,
        RuleExpectationSource fallbackSource,
        RuleExpectationConfidence fallbackConfidence,
        string evidence)
    {
        if (expected.Type != RuleExpectedOutcomeType.Unspecified)
        {
            return expected with
            {
                Source = expected.Source == RuleExpectationSource.Unspecified ? fallbackSource : expected.Source,
                Confidence = expected.Confidence == RuleExpectationConfidence.Unspecified ? fallbackConfidence : expected.Confidence,
                Evidence = expected.Evidence.Length == 0 && !string.IsNullOrWhiteSpace(evidence) ? [evidence] : expected.Evidence
            };
        }
        return new RuleExpectedOutcome
        {
            Type = RuleExpectedOutcomeType.ObservationOnly,
            QueryShouldComplete = true,
            Source = fallbackSource,
            Confidence = fallbackConfidence,
            Evidence = string.IsNullOrWhiteSpace(evidence) ? [] : [evidence]
        };
    }

    private static RuleDiscoveredControl? FindRuntimeControl(
        HtsMapControlDefinition control,
        IEnumerable<RuleDiscoveredControl> runtimeControls) => runtimeControls
        .Where(x =>
            x.MapModelId?.Equals(control.ModelId, StringComparison.OrdinalIgnoreCase) == true ||
            x.MapModelId?.Equals(control.LogicalName, StringComparison.OrdinalIgnoreCase) == true ||
            x.Name?.Equals(control.LogicalName, StringComparison.OrdinalIgnoreCase) == true ||
            x.RuntimeName?.Equals(control.LogicalName, StringComparison.OrdinalIgnoreCase) == true ||
            x.ControlId.EndsWith(":" + control.LogicalName, StringComparison.OrdinalIgnoreCase))
        .OrderByDescending(x => x.MapMatched)
        .ThenBy(x => x.MapMatchDistance ?? double.MaxValue)
        .ThenBy(x => x.TabOrder)
        .FirstOrDefault();

    private static bool IsLifecycleControl(HtsMapScreenDefinition screen, HtsMapControlDefinition control)
    {
        if (CloseControlPattern.IsMatch(control.LogicalName)) return true;
        var eventHandlers = screen.Behavior.EventHandlers.Where(x =>
            x.SourceControl.Equals(control.LogicalName, StringComparison.OrdinalIgnoreCase) ||
            x.SourceControl.Equals(control.ModelId, StringComparison.OrdinalIgnoreCase));
        var signals = new[] { control.SemanticRole }
            .Concat(control.InvokedHandlers)
            .Concat(eventHandlers.SelectMany(x => new[] { x.Handler, x.SemanticRole }.Concat(x.InvokedHandlers)));
        return signals.Where(x => !string.IsNullOrWhiteSpace(x)).Any(x => LifecycleHandlerPattern.IsMatch(x));
    }

    private static IEnumerable<HtsMapControlDefinition> ResolveControls(HtsMapScreenDefinition screen, IEnumerable<string> names)
    {
        var set = names.ToHashSet(StringComparer.OrdinalIgnoreCase);
        return screen.Controls.Where(x => set.Contains(x.LogicalName) || set.Contains(x.ModelId));
    }

    private static IEnumerable<HtsMapMessageDefinition> ValidationMessages(HtsMapScreenDefinition screen, HtsMapControlDefinition control) =>
        screen.ErrorOracle.MessageBoxes.Where(x =>
            x.TargetControls.Contains(control.LogicalName, StringComparer.OrdinalIgnoreCase) ||
            x.TargetControls.Contains(control.ModelId, StringComparer.OrdinalIgnoreCase));

    private static RuleControlKind ToRuleKind(HtsMapControlDefinition control)
    {
        if (Enum.TryParse<RuleControlKind>(control.RuleControlKind, true, out var parsed) && parsed != RuleControlKind.Auto) return parsed;
        return control.Kind switch
        {
            HtsMapControlKind.Text or HtsMapControlKind.Instrument => RuleControlKind.Text,
            HtsMapControlKind.Date => RuleControlKind.Date,
            HtsMapControlKind.ComboBox => RuleControlKind.ComboBox,
            HtsMapControlKind.RadioGroup => RuleControlKind.RadioGroup,
            HtsMapControlKind.CheckBox => RuleControlKind.CheckBox,
            HtsMapControlKind.Tab => RuleControlKind.Tab,
            HtsMapControlKind.Button => RuleControlKind.Button,
            HtsMapControlKind.Spin => RuleControlKind.Spin,
            HtsMapControlKind.Slider => RuleControlKind.Slider,
            _ => RuleControlKind.Auto
        };
    }

    private static void AddLocator(
        IDictionary<string, GeneratedLocatorRequest> locators,
        HtsMapScreenDefinition screen,
        HtsMapControlDefinition control,
        string role,
        string evidence)
    {
        var key = $"{screen.ScreenNumber}|{control.LogicalName}";
        locators.TryAdd(key, new GeneratedLocatorRequest
        {
            ScreenNumber = screen.ScreenNumber,
            TargetRole = role,
            LogicalName = control.LogicalName,
            Reason = "자동 생성 시나리오의 물리 컨트롤 바인딩",
            RecommendedEvidence = evidence
        });
    }

    private static string ScenarioId(string screen, string category, string logicalName) =>
        $"AUTO-{screen}-{category}-{ScenarioIds.Hash(logicalName, 10).ToUpperInvariant()}";

    private static string SafeIdentifier(string value)
    {
        var safe = IdentifierCharacters.Replace(value, "_").Trim('_');
        return string.IsNullOrWhiteSpace(safe) ? $"control_{ScenarioIds.Hash(value, 8)}" : safe;
    }

    private static string SafeValueId(string value, int index)
    {
        var safe = IdentifierCharacters.Replace(value, "-").Trim('-').ToLowerInvariant();
        return string.IsNullOrWhiteSpace(safe) ? $"option-{index}-{ScenarioIds.Hash(value, 8)}" : safe;
    }

    private static bool SameControl(HtsMapControlDefinition left, HtsMapControlDefinition right) =>
        left.ModelId.Equals(right.ModelId, StringComparison.OrdinalIgnoreCase) ||
        left.LogicalName.Equals(right.LogicalName, StringComparison.OrdinalIgnoreCase);

    private static int ScenarioCaseCount(GeneratedScenario scenario, IReadOnlyDictionary<string, int> valuesByVariable)
    {
        var refs = scenario.Steps.Where(x => !string.IsNullOrWhiteSpace(x.ValueRef)).Select(x => x.ValueRef!)
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        return refs.Length == 0 ? 1 : refs.Aggregate(1, (count, valueRef) => count * valuesByVariable.GetValueOrDefault(valueRef, 0));
    }
}

/// <summary>현재 자동 생성기 서명과 필수 검토 부재를 확인한 문서만 정책 승인한다.</summary>
public sealed class RuleScenarioAutoApprovalPolicy
{
    /// <summary>외부 작성물과 필수 검토 문서를 차단하고 완전한 승인 오버레이를 생성한다.</summary>
    public ScenarioApprovalOverlay Create(GeneratedScenarioDocument source, string sourceSha256, DateTimeOffset approvedAt)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (!source.GenerationSummary.GenerationMode.Equals(RuleScenarioGeneratorVersions.GenerationMode, StringComparison.Ordinal) ||
            !source.GenerationSummary.Generator.Equals(RuleScenarioGeneratorVersions.Generator, StringComparison.Ordinal) ||
            !source.GenerationSummary.GeneratorVersion.Equals(RuleScenarioGeneratorVersions.Version, StringComparison.Ordinal))
            throw new InvalidDataException("프로그램 자동 생성기의 현재 버전으로 만든 시나리오만 정책 승인할 수 있습니다.");
        var requiredReview = source.ReviewItems.FirstOrDefault(x => x.Severity.Equals("Required", StringComparison.OrdinalIgnoreCase));
        if (requiredReview is not null)
            throw new InvalidDataException($"필수 검토 항목은 자동 승인할 수 없습니다: {requiredReview.ScreenNumber}/{requiredReview.Subject}");

        return new ScenarioApprovalOverlay
        {
            SourceSha256 = sourceSha256,
            Status = "Approved",
            ApprovedBy = RuleScenarioGeneratorVersions.ApprovalPolicy,
            ApprovedAt = approvedAt,
            ReviewDecisions = source.ReviewItems.Select(item => new ScenarioReviewDecision
            {
                ReviewId = ScenarioPlanCompiler.ReviewId(item),
                Decision = "AcceptedGap",
                Reason = $"자동 생성 정책에서 실행 제외 또는 보류로 처리: {item.Reason}",
                EvidenceRefs = [RuleScenarioGeneratorVersions.ApprovalPolicy]
            }).ToArray(),
            ScenarioDecisions = source.Screens.SelectMany(x => x.Scenarios)
                .Where(x => x.AutomationStatus.Equals("ManualReview", StringComparison.OrdinalIgnoreCase))
                .Select(x => new ScenarioExecutionDecision
                {
                    ScenarioId = x.ScenarioId,
                    Decision = "Reject",
                    Reason = "자동 승인 정책은 수동 검토 시나리오를 실행하지 않습니다."
                }).ToArray(),
            CoverageGapDecisions = source.Screens.SelectMany(screen => screen.CoverageGaps.Select(gap => new ScenarioCoverageGapDecision
            {
                ScreenNumber = screen.ScreenNumber,
                GapHash = ScenarioIds.Hash($"{screen.ScreenNumber}|{gap}", 12),
                Decision = "AcceptedGap",
                Reason = $"자동 생성 정책의 명시적 제외 항목: {gap}"
            })).ToArray()
        };
    }
}
