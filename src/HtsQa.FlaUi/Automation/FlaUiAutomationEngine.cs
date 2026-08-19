// 역할: FlaUI UIA3 기반의 창 상태 확인, 요소 탐색, 재식별과 의미 패턴 조작을 구현한다.
// 입력/출력: BridgeRequest를 받아 직렬화 가능한 BridgeResponse와 요소 snapshot을 반환한다.
// 경계: 좌표 fallback은 이 엔진이 수행하지 않으며 지원 패턴 실패를 명시 코드로 상위 실행기에 전달한다.
// 수정 지점: 새 컨트롤 동작은 selector 재검증, 실행 후 상태 확인, 통합 테스트를 한 묶음으로 추가한다.
using System.Globalization;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.WindowsAPI;
using FlaUI.UIA3;

namespace HtsQa.FlaUi;

/// <summary>
/// FlaUI UIA3를 유일한 의미 기반 탐색·조작 엔진으로 제공한다.
/// 엔진은 요청마다 HWND에서 루트를 다시 얻어 HTS의 동적 화면 재생성에 대응한다.
/// </summary>
public sealed class FlaUiAutomationEngine : IDisposable
{
    public const string EngineName = "FlaUI.UIA3";
    public const string EngineVersion = "5.0.0";

    private static readonly HashSet<string> ActionableControlTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "Button", "CheckBox", "RadioButton", "ComboBox", "Edit", "Document",
        "Tab", "TabItem", "List", "ListItem", "Slider", "Spinner", "TreeItem"
    };

    // UIA3 COM 자동화 객체를 프로세스 수명 동안 재사용해 탐색 비용과 COM 초기화 변동을 줄인다.
    private readonly UIA3Automation _automation = new();
    private bool _disposed;

    /// <summary>브리지 요청을 연산별 구현으로 배분한다.</summary>
    public BridgeResponse Execute(BridgeRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return request.Operation.Trim().ToLowerInvariant() switch
        {
            "ping" => Success(request, "FlaUI UIA3 실행기가 응답했습니다."),
            "discover" => Discover(request),
            "action" => Act(request),
            _ => BridgeResponse.Failure(request, "UNKNOWN_OPERATION", $"지원하지 않는 연산입니다: {request.Operation}")
        };
    }

    /// <summary>루트 아래 활성 요소를 UIA3 속성과 패턴 단위로 구조화한다.</summary>
    public BridgeResponse Discover(BridgeRequest request)
    {
        try
        {
            var root = GetRoot(request);
            var elements = root.FindAllDescendants()
                .Select(TryCreateSnapshot)
                .Where(snapshot => snapshot is not null)
                .Cast<ElementSnapshot>()
                .Where(IsActionable)
                .OrderBy(snapshot => snapshot.Bounds.Top)
                .ThenBy(snapshot => snapshot.Bounds.Left)
                .ToArray();

            return new BridgeResponse
            {
                RequestId = request.RequestId,
                Success = true,
                Verified = true,
                Message = $"FlaUI UIA3로 조작 가능 요소 {elements.Length}개를 탐색했습니다.",
                Elements = elements
            };
        }
        catch (Exception exception)
        {
            return BridgeResponse.Failure(request, "UIA3_DISCOVERY_FAILED", exception.Message, fallback: true);
        }
    }

    /// <summary>선택자를 현재 UIA 트리에 다시 결합한 뒤 해당 UIA 패턴을 실행하고 결과를 검증한다.</summary>
    public BridgeResponse Act(BridgeRequest request)
    {
        if (request.Selector is null)
        {
            return BridgeResponse.Failure(request, "SELECTOR_REQUIRED", "action 요청에는 요소 선택자가 필요합니다.");
        }

        try
        {
            var root = GetRoot(request);
            var element = ResolveElement(root, request.Selector);
            if (element is null)
            {
                return BridgeResponse.Failure(request, "UIA3_ELEMENT_NOT_FOUND", "동작 직전에 UIA3 요소를 다시 찾지 못했습니다.", fallback: true);
            }

            if (!SafeRead(() => element.IsEnabled, false))
            {
                return BridgeResponse.Failure(request, "UIA3_ELEMENT_DISABLED", "UIA3 요소가 비활성 상태입니다.");
            }

            return ExecuteAction(request, element);
        }
        catch (Exception exception)
        {
            return BridgeResponse.Failure(request, "UIA3_ACTION_FAILED", exception.Message, fallback: true);
        }
    }

    /// <summary>HWND를 FlaUI UIA3 AutomationElement로 변환하고 유효성을 점검한다.</summary>
    private AutomationElement GetRoot(BridgeRequest request)
    {
        if (request.RootHwnd == 0)
        {
            throw new InvalidOperationException("UIA3 루트 HWND가 지정되지 않았습니다.");
        }

        var root = _automation.FromHandle(new IntPtr(request.RootHwnd));
        return root ?? throw new InvalidOperationException($"HWND {request.RootHwnd}에서 UIA3 루트를 만들 수 없습니다.");
    }

    /// <summary>요청 동작을 FlaUI 컨트롤 래퍼 또는 저수준 UIA 패턴에 연결한다.</summary>
    private BridgeResponse ExecuteAction(BridgeRequest request, AutomationElement element)
    {
        var action = request.Action?.Trim().ToLowerInvariant() ?? string.Empty;
        return action switch
        {
            "focus" => Focus(request, element),
            "settext" => SetText(request, element, pressEnter: false),
            "settextandenter" => SetText(request, element, pressEnter: true),
            "invoke" => Invoke(request, element),
            "setchecked" => SetChecked(request, element),
            "select" => Select(request, element),
            "selectindex" => SelectByIndex(request, element),
            "selecttext" => SelectByText(request, element),
            "selecttabindex" => SelectTabByIndex(request, element),
            "setrangevalue" => SetRangeValue(request, element),
            "increment" => ChangeRange(request, element, increment: true),
            "decrement" => ChangeRange(request, element, increment: false),
            "presskey" => PressKey(request, element),
            _ => BridgeResponse.Failure(request, "UIA3_ACTION_UNSUPPORTED", $"지원하지 않는 UIA3 동작입니다: {request.Action}", fallback: true)
        };
    }

    /// <summary>ValuePattern 또는 FlaUI TextBox 래퍼로 값을 설정하고 읽기 가능한 경우 동일성을 확인한다.</summary>
    private BridgeResponse SetText(BridgeRequest request, AutomationElement element, bool pressEnter)
    {
        var value = request.Value ?? string.Empty;
        var patternName = string.Empty;

        if (element.Patterns.Value.TryGetPattern(out var valuePattern) && !valuePattern.IsReadOnly.Value)
        {
            valuePattern.SetValue(value);
            patternName = "ValuePattern.SetValue";
        }
        else
        {
            // 일부 사용자 정의 편집기는 ValuePattern은 누락되지만 포커스 후 키 입력은 지원한다.
            element.Focus();
            Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_A);
            Keyboard.Type(value);
            patternName = "Focus+Keyboard.Type";
        }

        if (pressEnter)
        {
            element.Focus();
            Keyboard.Press(VirtualKeyShort.RETURN);
            patternName += "+RETURN";
        }

        var observed = ReadValue(element);
        var verified = string.IsNullOrEmpty(observed) || string.Equals(observed, value, StringComparison.Ordinal);
        return ActionSuccess(request, patternName, verified, observed,
            pressEnter ? "텍스트를 설정하고 Enter 키를 보냈습니다." : "텍스트를 설정했습니다.");
    }

    /// <summary>InvokePattern을 사용해 버튼의 의미 동작을 실행한다.</summary>
    private static BridgeResponse Invoke(BridgeRequest request, AutomationElement element)
    {
        if (!element.Patterns.Invoke.TryGetPattern(out var invokePattern))
        {
            return BridgeResponse.Failure(request, "UIA3_PATTERN_UNSUPPORTED", "InvokePattern을 지원하지 않습니다.", fallback: true);
        }

        invokePattern.Invoke();
        return ActionSuccess(request, "InvokePattern.Invoke", verified: true, string.Empty, "버튼 동작을 실행했습니다.");
    }

    /// <summary>TogglePattern으로 목표 체크 상태까지 필요한 횟수만 토글한다.</summary>
    private static BridgeResponse SetChecked(BridgeRequest request, AutomationElement element)
    {
        if (!request.Checked.HasValue)
        {
            return BridgeResponse.Failure(request, "CHECKED_VALUE_REQUIRED", "setChecked 동작에는 checked 값이 필요합니다.");
        }
        if (!element.Patterns.Toggle.TryGetPattern(out var togglePattern))
        {
            return BridgeResponse.Failure(request, "UIA3_PATTERN_UNSUPPORTED", "TogglePattern을 지원하지 않습니다.", fallback: true);
        }

        var wanted = request.Checked.Value;
        var current = togglePattern.ToggleState.Value == ToggleState.On;
        if (current != wanted)
        {
            togglePattern.Toggle();
        }

        var after = togglePattern.ToggleState.Value == ToggleState.On;
        return ActionSuccess(request, "TogglePattern.Toggle", after == wanted, after.ToString(CultureInfo.InvariantCulture),
            wanted ? "체크 상태로 변경했습니다." : "체크 해제 상태로 변경했습니다.");
    }

    /// <summary>SelectionItemPattern으로 라디오·목록 항목·탭 항목을 선택한다.</summary>
    private BridgeResponse Select(BridgeRequest request, AutomationElement element)
    {
        if (!element.Patterns.SelectionItem.TryGetPattern(out var selectionPattern))
        {
            return BridgeResponse.Failure(request, "UIA3_PATTERN_UNSUPPORTED", "SelectionItemPattern을 지원하지 않습니다.", fallback: true);
        }

        selectionPattern.Select();
        // WinForms UIA 공급자는 기존 패턴 객체의 선택 상태 갱신이 늦을 수 있어 현재 트리에서 요소를 재식별한다.
        var selected = WaitUntil(
            () =>
            {
                var current = ResolveElement(GetRoot(request), request.Selector!);
                return current is not null &&
                       current.Patterns.SelectionItem.TryGetPattern(out var currentSelection) &&
                       SafeRead(() => currentSelection.IsSelected.Value, false);
            },
            TimeSpan.FromSeconds(1));
        return ActionSuccess(request, "SelectionItemPattern.Select", selected, selected.ToString(CultureInfo.InvariantCulture), "항목을 선택했습니다.");
    }

    /// <summary>FlaUI ComboBox/ListBox 래퍼로 인덱스 선택을 수행한다.</summary>
    private BridgeResponse SelectByIndex(BridgeRequest request, AutomationElement element)
    {
        if (!request.Index.HasValue || request.Index.Value < 0)
        {
            return BridgeResponse.Failure(request, "INDEX_REQUIRED", "selectIndex 동작에는 0 이상의 index가 필요합니다.");
        }

        var index = request.Index.Value;
        var type = NormalizeControlType(SafeRead(() => element.ControlType.ToString(), string.Empty));
        if (type.Equals("ComboBox", StringComparison.OrdinalIgnoreCase))
        {
            var combo = element.AsComboBox();
            try
            {
                // WinForms UIA 공급자는 드롭다운을 펼친 동안에만 ListItem 자식을 노출한다.
                combo.Expand();
                Thread.Sleep(120);
                var items = GetComboItems(element);
                if (items.Length > 0 && index >= items.Length)
                {
                    return BridgeResponse.Failure(request, "UIA3_INDEX_OUT_OF_RANGE", $"콤보 항목 수 {items.Length}보다 큰 인덱스 {index}가 요청되었습니다.");
                }
                if (items.Length == 0)
                {
                    return BridgeResponse.Failure(request, "UIA3_COMBO_ITEMS_NOT_EXPOSED", "콤보를 펼쳤지만 UIA3 ListItem을 찾지 못했습니다.", fallback: true);
                }

                var expected = SafeRead(() => items[index].Name, string.Empty);
                if (!items[index].Patterns.SelectionItem.TryGetPattern(out var selectionItem))
                {
                    return BridgeResponse.Failure(request, "UIA3_PATTERN_UNSUPPORTED", "콤보 항목이 SelectionItemPattern을 지원하지 않습니다.", fallback: true);
                }
                selectionItem.Select();
                Thread.Sleep(80);
                var observed = combo.SelectedItem?.Text ?? combo.Value;
                var itemSelected = SafeRead(() => selectionItem.IsSelected.Value, false);
                return ActionSuccess(request, "ComboBox.Expand+SelectionItemPattern.Select", itemSelected || string.Equals(observed, expected, StringComparison.Ordinal), observed, "콤보 항목을 선택했습니다.");
            }
            finally
            {
                SafeRun(combo.Collapse);
            }
        }
        if (type.Equals("List", StringComparison.OrdinalIgnoreCase))
        {
            var list = element.AsListBox();
            list.Select(index);
            var verified = list.SelectedItem is not null && Array.IndexOf(list.Items, list.SelectedItem) == index;
            return ActionSuccess(request, "ListBox.Select(index)", verified, list.SelectedItem?.Text ?? string.Empty, "목록 항목을 선택했습니다.");
        }

        return BridgeResponse.Failure(request, "UIA3_PATTERN_UNSUPPORTED", $"{type}에는 인덱스 선택 래퍼를 적용할 수 없습니다.", fallback: true);
    }

    /// <summary>FlaUI ComboBox/ListBox 래퍼로 표시 문자열 선택을 수행한다.</summary>
    private BridgeResponse SelectByText(BridgeRequest request, AutomationElement element)
    {
        var value = request.Value ?? string.Empty;
        var type = NormalizeControlType(SafeRead(() => element.ControlType.ToString(), string.Empty));
        if (type.Equals("ComboBox", StringComparison.OrdinalIgnoreCase))
        {
            var combo = element.AsComboBox();
            try
            {
                combo.Expand();
                Thread.Sleep(120);
                var items = GetComboItems(element);
                var target = items.FirstOrDefault(item => string.Equals(SafeRead(() => item.Name, string.Empty), value, StringComparison.Ordinal));
                if (target is null)
                {
                    return BridgeResponse.Failure(request, "UIA3_COMBO_ITEM_NOT_FOUND", $"표시값 '{value}'인 UIA3 ListItem을 찾지 못했습니다.", fallback: true);
                }
                if (!target.Patterns.SelectionItem.TryGetPattern(out var selectionItem))
                {
                    return BridgeResponse.Failure(request, "UIA3_PATTERN_UNSUPPORTED", "콤보 항목이 SelectionItemPattern을 지원하지 않습니다.", fallback: true);
                }
                selectionItem.Select();
                Thread.Sleep(80);
                var observed = combo.SelectedItem?.Text ?? combo.Value;
                var itemSelected = SafeRead(() => selectionItem.IsSelected.Value, false);
                return ActionSuccess(request, "ComboBox.Expand+SelectionItemPattern.Select", itemSelected || string.Equals(observed, value, StringComparison.Ordinal), observed, "콤보 표시값을 선택했습니다.");
            }
            finally
            {
                SafeRun(combo.Collapse);
            }
        }
        if (type.Equals("List", StringComparison.OrdinalIgnoreCase))
        {
            var list = element.AsListBox();
            list.Select(value);
            var observed = list.SelectedItem?.Text ?? string.Empty;
            return ActionSuccess(request, "ListBox.Select(text)", string.Equals(observed, value, StringComparison.Ordinal), observed, "목록 표시값을 선택했습니다.");
        }

        return BridgeResponse.Failure(request, "UIA3_PATTERN_UNSUPPORTED", $"{type}에는 문자열 선택 래퍼를 적용할 수 없습니다.", fallback: true);
    }

    /// <summary>FlaUI Tab 래퍼로 목표 탭 인덱스를 선택하고 현재 인덱스를 재확인한다.</summary>
    private static BridgeResponse SelectTabByIndex(BridgeRequest request, AutomationElement element)
    {
        if (!request.Index.HasValue || request.Index.Value < 0)
        {
            return BridgeResponse.Failure(request, "INDEX_REQUIRED", "selectTabIndex 동작에는 0 이상의 index가 필요합니다.");
        }

        var tab = element.AsTab();
        tab.SelectTabItem(request.Index.Value);
        var after = tab.SelectedTabItemIndex;
        return ActionSuccess(request, "Tab.SelectTabItem(index)", after == request.Index.Value, after.ToString(CultureInfo.InvariantCulture), "탭을 선택했습니다.");
    }

    /// <summary>Slider 또는 Spinner의 RangeValue 기반 값을 설정한다.</summary>
    private static BridgeResponse SetRangeValue(BridgeRequest request, AutomationElement element)
    {
        if (!double.TryParse(request.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var value))
        {
            return BridgeResponse.Failure(request, "RANGE_VALUE_REQUIRED", "setRangeValue 동작에는 숫자 value가 필요합니다.");
        }
        if (!element.Patterns.RangeValue.TryGetPattern(out var rangePattern) || rangePattern.IsReadOnly.Value)
        {
            return BridgeResponse.Failure(request, "UIA3_PATTERN_UNSUPPORTED", "쓰기 가능한 RangeValuePattern을 지원하지 않습니다.", fallback: true);
        }

        rangePattern.SetValue(value);
        var after = rangePattern.Value.Value;
        return ActionSuccess(request, "RangeValuePattern.SetValue", Math.Abs(after - value) < 0.0001, after.ToString(CultureInfo.InvariantCulture), "범위값을 설정했습니다.");
    }

    /// <summary>Spinner/Slider의 증감 메서드를 컨트롤 종류에 맞춰 호출한다.</summary>
    private static BridgeResponse ChangeRange(BridgeRequest request, AutomationElement element, bool increment)
    {
        var type = NormalizeControlType(SafeRead(() => element.ControlType.ToString(), string.Empty));
        if (type.Equals("Spinner", StringComparison.OrdinalIgnoreCase))
        {
            var spinner = element.AsSpinner();
            if (increment) spinner.Increment(); else spinner.Decrement();
            return ActionSuccess(request, increment ? "Spinner.Increment" : "Spinner.Decrement", true, spinner.Value.ToString(CultureInfo.InvariantCulture), "스핀 값을 변경했습니다.");
        }
        if (type.Equals("Slider", StringComparison.OrdinalIgnoreCase))
        {
            var slider = element.AsSlider();
            if (increment) slider.SmallIncrement(); else slider.SmallDecrement();
            return ActionSuccess(request, increment ? "Slider.SmallIncrement" : "Slider.SmallDecrement", true, slider.Value.ToString(CultureInfo.InvariantCulture), "슬라이더 값을 변경했습니다.");
        }

        return BridgeResponse.Failure(request, "UIA3_PATTERN_UNSUPPORTED", $"{type}에는 증감 동작을 적용할 수 없습니다.", fallback: true);
    }

    /// <summary>요소에 포커스를 주고 허용된 단일 키를 FlaUI Keyboard로 전송한다.</summary>
    private static BridgeResponse PressKey(BridgeRequest request, AutomationElement element)
    {
        element.Focus();
        var key = request.Key?.Trim().ToUpperInvariant() switch
        {
            "ENTER" or "RETURN" => VirtualKeyShort.RETURN,
            "TAB" => VirtualKeyShort.TAB,
            "ESC" or "ESCAPE" => VirtualKeyShort.ESCAPE,
            "DOWN" => VirtualKeyShort.DOWN,
            "UP" => VirtualKeyShort.UP,
            "LEFT" => VirtualKeyShort.LEFT,
            "RIGHT" => VirtualKeyShort.RIGHT,
            _ => (VirtualKeyShort?)null
        };
        if (!key.HasValue)
        {
            return BridgeResponse.Failure(request, "KEY_UNSUPPORTED", $"허용되지 않은 키입니다: {request.Key}");
        }

        Keyboard.Press(key.Value);
        return ActionSuccess(request, $"Keyboard.Press({key.Value})", true, key.Value.ToString(), "키 입력을 전송했습니다.");
    }

    /// <summary>FlaUI Focus 호출이 예외 없이 완료되는지 확인한다.</summary>
    private static BridgeResponse Focus(BridgeRequest request, AutomationElement element)
    {
        element.Focus();
        return ActionSuccess(request, "AutomationElement.Focus", true, string.Empty, "요소에 포커스를 설정했습니다.");
    }

    /// <summary>RuntimeId, HWND, 속성 일치, 좌표 근접도 순으로 현재 요소를 결정한다.</summary>
    private static AutomationElement? ResolveElement(AutomationElement root, ElementSelector selector)
    {
        var elements = root.FindAllDescendants().Prepend(root).ToArray();
        if (!string.IsNullOrWhiteSpace(selector.RuntimeId))
        {
            var byRuntimeId = elements.FirstOrDefault(element => RuntimeId(element) == selector.RuntimeId);
            if (byRuntimeId is not null) return byRuntimeId;
        }

        if (selector.NativeWindowHandle != 0)
        {
            var byHandle = elements.FirstOrDefault(element => NativeWindowHandle(element) == selector.NativeWindowHandle);
            if (byHandle is not null) return byHandle;
        }

        var typed = elements.Where(element => SelectorPropertiesMatch(element, selector)).ToArray();
        if (typed.Length == 1) return typed[0];
        if (typed.Length > 1 && selector.Bounds is not null)
        {
            return typed.OrderBy(element => RectangleDistance(Bounds(element), selector.Bounds)).First();
        }

        if (selector.Bounds is not null)
        {
            var sameType = elements.Where(element => ControlTypeMatches(element, selector.ControlType)).ToArray();
            return sameType.OrderBy(element => RectangleDistance(Bounds(element), selector.Bounds)).FirstOrDefault();
        }

        return typed.FirstOrDefault();
    }

    /// <summary>비어 있지 않은 선택자 속성만 AND 조건으로 비교한다.</summary>
    private static bool SelectorPropertiesMatch(AutomationElement element, ElementSelector selector)
    {
        if (!ControlTypeMatches(element, selector.ControlType)) return false;
        if (!StringMatches(SafeRead(() => element.AutomationId, string.Empty), selector.AutomationId)) return false;
        if (!StringMatches(SafeRead(() => element.Name, string.Empty), selector.Name)) return false;
        if (!StringMatches(SafeRead(() => element.ClassName, string.Empty), selector.ClassName)) return false;
        return true;
    }

    /// <summary>ControlType.Button 형태와 Button 형태를 같은 타입으로 정규화해 비교한다.</summary>
    private static bool ControlTypeMatches(AutomationElement element, string? selectorType)
    {
        if (string.IsNullOrWhiteSpace(selectorType)) return true;
        var actual = NormalizeControlType(SafeRead(() => element.ControlType.ToString(), string.Empty));
        return string.Equals(actual, NormalizeControlType(selectorType), StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>선택자 문자열이 비어 있으면 와일드카드로, 값이 있으면 정확히 비교한다.</summary>
    private static bool StringMatches(string actual, string? expected) =>
        string.IsNullOrWhiteSpace(expected) || string.Equals(actual, expected, StringComparison.Ordinal);

    /// <summary>두 사각형 중심 간 맨해튼 거리를 계산해 가장 가까운 동적 요소를 찾는다.</summary>
    private static long RectangleDistance(ElementRectangle left, ElementRectangle right)
    {
        var leftX = (long)left.Left + left.Width / 2L;
        var leftY = (long)left.Top + left.Height / 2L;
        var rightX = (long)right.Left + right.Width / 2L;
        var rightY = (long)right.Top + right.Height / 2L;
        return Math.Abs(leftX - rightX) + Math.Abs(leftY - rightY);
    }

    /// <summary>요소 속성 읽기 실패를 해당 요소만 제외하는 null 결과로 격리한다.</summary>
    private ElementSnapshot? TryCreateSnapshot(AutomationElement element)
    {
        try
        {
            return new ElementSnapshot
            {
                RuntimeId = RuntimeId(element),
                NativeWindowHandle = NativeWindowHandle(element),
                AutomationId = element.AutomationId ?? string.Empty,
                Name = element.Name ?? string.Empty,
                ClassName = element.ClassName ?? string.Empty,
                ControlType = $"ControlType.{NormalizeControlType(element.ControlType.ToString())}",
                FrameworkType = element.FrameworkType.ToString(),
                IsEnabled = element.IsEnabled,
                IsOffscreen = element.IsOffscreen,
                IsKeyboardFocusable = element.Properties.IsKeyboardFocusable.ValueOrDefault,
                Bounds = Bounds(element),
                SupportedActions = GetSupportedActions(element),
                Options = GetOptions(element),
                SelectedIndex = GetSelectedIndex(element),
                CurrentValue = ReadValue(element),
                Minimum = ReadRange(element, minimum: true),
                Maximum = ReadRange(element, minimum: false)
            };
        }
        catch
        {
            return null;
        }
    }

    /// <summary>실제 입력 가능한 크기·상태·타입 또는 패턴을 가진 요소만 실행 후보로 남긴다.</summary>
    private static bool IsActionable(ElementSnapshot snapshot)
    {
        var type = NormalizeControlType(snapshot.ControlType);
        return snapshot.IsEnabled && !snapshot.IsOffscreen && snapshot.Bounds.Width >= 4 && snapshot.Bounds.Height >= 4 &&
               (ActionableControlTypes.Contains(type) || snapshot.SupportedActions.Count > 0);
    }

    /// <summary>요소가 지원하는 UIA 패턴을 실행 동작 이름으로 노출한다.</summary>
    private static IReadOnlyList<string> GetSupportedActions(AutomationElement element)
    {
        var actions = new List<string>();
        var type = NormalizeControlType(SafeRead(() => element.ControlType.ToString(), string.Empty));
        if (element.Patterns.Value.IsSupported) actions.Add("setText");
        if (element.Patterns.Invoke.IsSupported) actions.Add("invoke");
        if (element.Patterns.Toggle.IsSupported) actions.Add("setChecked");
        if (element.Patterns.SelectionItem.IsSupported) actions.Add("select");
        if (element.Patterns.Selection.IsSupported) actions.Add("selectIndex");
        if (element.Patterns.RangeValue.IsSupported) actions.Add("setRangeValue");
        if (type is "ComboBox" or "List" or "Tab" && !actions.Contains("selectIndex")) actions.Add("selectIndex");
        if (SafeRead(() => element.Properties.IsKeyboardFocusable.ValueOrDefault, false)) actions.Add("pressKey");
        return actions;
    }

    /// <summary>FlaUI 컨트롤 래퍼에서 콤보·목록·탭의 실제 하위 선택지를 읽는다.</summary>
    private IReadOnlyList<ElementOptionSnapshot> GetOptions(AutomationElement element)
    {
        var type = NormalizeControlType(SafeRead(() => element.ControlType.ToString(), string.Empty));
        AutomationElement[] items = type switch
        {
            "ComboBox" => GetComboItems(element),
            "List" => SafeRead(() => element.AsListBox().Items.Cast<AutomationElement>().ToArray(), Array.Empty<AutomationElement>()),
            "Tab" => SafeRead(() => element.AsTab().TabItems.Cast<AutomationElement>().ToArray(), Array.Empty<AutomationElement>()),
            _ => Array.Empty<AutomationElement>()
        };

        return items.Select((item, index) => new ElementOptionSnapshot
        {
            Index = index,
            Name = SafeRead(() => item.Name, string.Empty),
            RuntimeId = RuntimeId(item),
            IsSelected = item.Patterns.SelectionItem.TryGetPattern(out var selection) && SafeRead(() => selection.IsSelected.Value, false)
        }).ToArray();
    }

    /// <summary>접힌 동안 항목을 숨기는 UIA 공급자를 위해 콤보를 잠시 펼쳐 항목 스냅샷을 얻는다.</summary>
    private AutomationElement[] GetComboItems(AutomationElement element)
    {
        var combo = element.AsComboBox();
        try
        {
            combo.Expand();
            Thread.Sleep(180);
            var directItems = SafeRead(() => combo.Items.Cast<AutomationElement>().ToArray(), Array.Empty<AutomationElement>());
            if (directItems.Length > 0) return directItems;

            // WinForms 드롭다운은 콤보 자식이 아니라 데스크톱의 별도 ComboLBox UIA 트리로 노출될 수 있다.
            var comboBounds = Bounds(element);
            var visibleLists = _automation.GetDesktop()
                .FindAllDescendants(factory => factory.ByControlType(ControlType.List))
                .Where(candidate => SafeRead(() => candidate.IsEnabled && !candidate.IsOffscreen, false))
                .Where(candidate => IsNearExpandedCombo(Bounds(candidate), comboBounds))
                .OrderBy(candidate => RectangleDistance(Bounds(candidate), comboBounds))
                .ToArray();

            foreach (var list in visibleLists)
            {
                var listItems = list.FindAllDescendants(factory => factory.ByControlType(ControlType.ListItem))
                    .Where(candidate => SafeRead(() => candidate.IsEnabled && !candidate.IsOffscreen, false))
                    .OrderBy(candidate => Bounds(candidate).Top)
                    .ThenBy(candidate => Bounds(candidate).Left)
                    .ToArray();
                if (listItems.Length > 0) return listItems;
            }

            return Array.Empty<AutomationElement>();
        }
        finally
        {
            SafeRun(combo.Collapse);
        }
    }

    /// <summary>펼쳐진 목록이 콤보와 수평으로 겹치고 수직으로 인접하는지 확인한다.</summary>
    private static bool IsNearExpandedCombo(ElementRectangle list, ElementRectangle combo)
    {
        var horizontalOverlap = Math.Min(list.Right, combo.Right) - Math.Max(list.Left, combo.Left);
        var verticalDistance = Math.Min(Math.Abs(list.Top - combo.Bottom), Math.Abs(combo.Top - list.Bottom));
        return horizontalOverlap > 0 && verticalDistance <= 80 && list.Width >= Math.Max(20, combo.Width / 2);
    }

    /// <summary>선택 컨테이너의 현재 인덱스를 래퍼별로 읽는다.</summary>
    private static int? GetSelectedIndex(AutomationElement element)
    {
        var type = NormalizeControlType(SafeRead(() => element.ControlType.ToString(), string.Empty));
        return type switch
        {
            "ComboBox" => SafeRead(() =>
            {
                var combo = element.AsComboBox();
                return combo.SelectedItem is null ? (int?)null : Array.IndexOf(combo.Items, combo.SelectedItem);
            }, null),
            "List" => SafeRead(() =>
            {
                var list = element.AsListBox();
                return list.SelectedItem is null ? (int?)null : Array.IndexOf(list.Items, list.SelectedItem);
            }, null),
            "Tab" => SafeRead(() => (int?)element.AsTab().SelectedTabItemIndex, null),
            _ => null
        };
    }

    /// <summary>RangeValuePattern의 최소/최대값을 지원 요소에만 기록한다.</summary>
    private static double? ReadRange(AutomationElement element, bool minimum)
    {
        if (!element.Patterns.RangeValue.TryGetPattern(out var range)) return null;
        return SafeRead(() => (double?)(minimum ? range.Minimum.Value : range.Maximum.Value), null);
    }

    /// <summary>읽기 가능한 ValuePattern 현재값을 반환하며 비지원 요소는 빈 문자열로 둔다.</summary>
    private static string ReadValue(AutomationElement element) =>
        element.Patterns.Value.TryGetPattern(out var pattern) ? SafeRead(() => pattern.Value.Value, string.Empty) : string.Empty;

    /// <summary>FlaUI RuntimeId 배열을 프로세스 간 안정적으로 전달할 문자열로 만든다.</summary>
    private static string RuntimeId(AutomationElement element) =>
        string.Join('.', SafeRead(() => element.Properties.RuntimeId.ValueOrDefault ?? Array.Empty<int>(), Array.Empty<int>()));

    /// <summary>네이티브 HWND가 없는 자체 그리기 요소도 0으로 표현해 유지한다.</summary>
    private static long NativeWindowHandle(AutomationElement element) =>
        SafeRead(() => (long)element.Properties.NativeWindowHandle.ValueOrDefault, 0L);

    /// <summary>FlaUI 사각형을 JSON 계약 좌표로 변환한다.</summary>
    private static ElementRectangle Bounds(AutomationElement element)
    {
        var rectangle = element.BoundingRectangle;
        return new ElementRectangle
        {
            Left = rectangle.Left,
            Top = rectangle.Top,
            Right = rectangle.Right,
            Bottom = rectangle.Bottom
        };
    }

    /// <summary>ControlType 접두사를 제거해 서로 다른 표현을 같은 값으로 비교한다.</summary>
    private static string NormalizeControlType(string? value) =>
        (value ?? string.Empty).Replace("ControlType.", string.Empty, StringComparison.OrdinalIgnoreCase);

    /// <summary>외부 UIA 공급자의 속성 예외를 기본값으로 제한한다.</summary>
    private static T SafeRead<T>(Func<T> reader, T fallback)
    {
        try { return reader(); }
        catch { return fallback; }
    }

    /// <summary>비동기로 반영되는 UIA 상태를 짧은 간격으로 다시 읽고 제한 시간 뒤에는 검증 실패로 반환한다.</summary>
    private static bool WaitUntil(Func<bool> predicate, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        do
        {
            if (SafeRead(predicate, false)) return true;
            Thread.Sleep(40);
        }
        while (DateTime.UtcNow < deadline);

        return SafeRead(predicate, false);
    }

    /// <summary>드롭다운 정리처럼 실패해도 원래 동작 결과를 덮지 않아야 하는 후처리를 실행한다.</summary>
    private static void SafeRun(Action action)
    {
        try { action(); }
        catch { }
    }

    /// <summary>동작 성공 응답에 사용 패턴과 검증값을 함께 넣는다.</summary>
    private static BridgeResponse ActionSuccess(BridgeRequest request, string pattern, bool verified, string observed, string message) => new()
    {
        RequestId = request.RequestId,
        Success = true,
        Verified = verified,
        Pattern = pattern,
        ObservedValue = observed,
        Message = message
    };

    /// <summary>단순 성공 응답을 만든다.</summary>
    private static BridgeResponse Success(BridgeRequest request, string message) => new()
    {
        RequestId = request.RequestId,
        Success = true,
        Verified = true,
        Message = message
    };

    /// <summary>UIA3 COM 자원을 실행기 종료 시 해제한다.</summary>
    public void Dispose()
    {
        if (_disposed) return;
        _automation.Dispose();
        _disposed = true;
        GC.SuppressFinalize(this);
    }
}
