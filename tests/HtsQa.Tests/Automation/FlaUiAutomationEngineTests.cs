// 역할: 실제 WinForms UIA 공급자에 FlaUI UIA3를 연결해 탐색, 재식별과 의미 패턴 조작을 검증한다.
// 범위: 격리된 SampleTarget만 사용하며 실제 HTS 프로세스나 사용자 세션은 조작하지 않는다.
// 수정 지점: Automation 엔진의 새 패턴 또는 오류 코드는 성공·미지원·검증 실패 사례를 함께 추가한다.
using System.Diagnostics;
using System.Windows.Forms;
using HtsQa.FlaUi;

namespace HtsQa.Tests;

/// <summary>격리된 WinForms 대상에서 UIA3 브리지의 실제 공급자 동작을 끝까지 검증한다.</summary>
public sealed class FlaUiAutomationEngineTests : IDisposable
{
    private readonly WinFormsAutomationFixture _fixture = WinFormsAutomationFixture.Start();

    /// <summary>지원 대상 컨트롤이 UIA3 탐색 결과와 사용 가능 동작에 모두 나타나는지 확인한다.</summary>
    [Fact]
    public void Discover_Returns_Actionable_WinForms_Controls_And_Patterns()
    {
        using var engine = new FlaUiAutomationEngine();
        var response = engine.Discover(Request("discover"));

        Assert.True(response.Success, response.Message);
        Assert.Contains(response.Elements, element => element.AutomationId == "accountText" && element.ControlType == "ControlType.Edit");
        Assert.Contains(response.Elements, element => element.AutomationId == "rangeCombo" && element.ControlType == "ControlType.ComboBox");
        Assert.Contains(response.Elements, element => element.AutomationId == "resultList" && element.ControlType == "ControlType.List");
        Assert.Contains(response.Elements, element => element.AutomationId == "includeCheck" && element.ControlType == "ControlType.CheckBox");
        Assert.Contains(response.Elements, element => element.AutomationId == "buyRadio" && element.ControlType == "ControlType.RadioButton");
        Assert.Contains(response.Elements, element => element.AutomationId == "mainTabs" && element.ControlType == "ControlType.Tab");
        Assert.Contains(response.Elements, element => element.AutomationId == "queryButton" && element.SupportedActions.Contains("invoke"));

        var combo = Assert.Single(response.Elements, element => element.AutomationId == "rangeCombo");
        Assert.Contains("selectIndex", combo.SupportedActions);
    }

    /// <summary>Value/Toggle/Selection/Invoke와 FlaUI 컨트롤 래퍼 동작이 실제 UI 상태를 바꾸는지 확인한다.</summary>
    [Fact]
    public void Action_Uses_FlaUi_Uia3_Patterns_And_Verifies_Changed_State()
    {
        using var engine = new FlaUiAutomationEngine();
        var elements = engine.Discover(Request("discover")).Elements;

        var text = Act(engine, elements, "accountText", "setText", value: "12345678-901");
        var combo = Act(engine, elements, "rangeCombo", "selectIndex", index: 2);
        var list = Act(engine, elements, "resultList", "selectIndex", index: 2);
        var check = Act(engine, elements, "includeCheck", "setChecked", isChecked: true);
        var radio = Act(engine, elements, "buyRadio", "select");
        var tab = Act(engine, elements, "mainTabs", "selectTabIndex", index: 1);
        var button = Act(engine, elements, "queryButton", "invoke");

        Assert.All(new[] { text, list, check, radio, tab, button }, result =>
        {
            Assert.True(result.Success, $"{result.ErrorCode}: {result.Message}");
            Assert.True(result.Verified, $"{result.Pattern}: {result.ObservedValue}");
            Assert.Equal(FlaUiAutomationEngine.EngineName, result.Engine);
        });

        // 이 WinForms 공급자는 펼친 콤보의 ListItem을 UIA3에 공개하지 않으므로 명시적 fallback이 정상 계약이다.
        Assert.False(combo.Success);
        Assert.True(combo.FallbackRequired);
        Assert.Equal("UIA3_COMBO_ITEMS_NOT_EXPOSED", combo.ErrorCode);

        Assert.Equal("12345678-901", _fixture.Read(control => ((TextBox)control["accountText"]!).Text));
        Assert.Equal(2, _fixture.Read(control => ((ListBox)control.Find("resultList", searchAllChildren: true).Single()).SelectedIndex));
        Assert.True(_fixture.Read(control => ((CheckBox)control["includeCheck"]!).Checked));
        Assert.True(_fixture.Read(control => ((RadioButton)control["buyRadio"]!).Checked));
        Assert.Equal(1, _fixture.Read(control => ((TabControl)control["mainTabs"]!).SelectedIndex));
        Assert.True(SpinWait.SpinUntil(() => _fixture.Read(control => ((Label)control["resultLabel"]!).Text) == "조회 완료", TimeSpan.FromSeconds(2)));
        Assert.Equal("InvokePattern.Invoke", button.Pattern);
    }

    /// <summary>테스트용 화면 HWND를 사용하는 공통 요청을 만든다.</summary>
    private BridgeRequest Request(string operation) => new()
    {
        RequestId = Guid.NewGuid().ToString("N"),
        Operation = operation,
        RootHwnd = _fixture.Handle.ToInt64()
    };

    /// <summary>탐색 스냅샷을 재식별 선택자로 바꿔 실제 action 요청을 실행한다.</summary>
    private BridgeResponse Act(
        FlaUiAutomationEngine engine,
        IReadOnlyList<ElementSnapshot> elements,
        string automationId,
        string action,
        string? value = null,
        int? index = null,
        bool? isChecked = null)
    {
        var element = Assert.Single(elements, candidate => candidate.AutomationId == automationId);
        return engine.Act(new BridgeRequest
        {
            RequestId = Guid.NewGuid().ToString("N"),
            Operation = "action",
            RootHwnd = _fixture.Handle.ToInt64(),
            Action = action,
            Value = value,
            Index = index,
            Checked = isChecked,
            Selector = new ElementSelector
            {
                RuntimeId = element.RuntimeId,
                NativeWindowHandle = element.NativeWindowHandle,
                AutomationId = element.AutomationId,
                Name = element.Name,
                ClassName = element.ClassName,
                ControlType = element.ControlType,
                Bounds = element.Bounds
            }
        });
    }

    /// <summary>각 테스트 뒤 WinForms 메시지 루프를 정상 종료한다.</summary>
    public void Dispose() => _fixture.Dispose();

    /// <summary>별도 STA 스레드에서 실제 UIA 공급자와 메시지 루프를 유지하는 테스트 픽스처다.</summary>
    private sealed class WinFormsAutomationFixture : IDisposable
    {
        private readonly Thread _thread;
        private readonly Form _form;

        private WinFormsAutomationFixture(Thread thread, Form form)
        {
            _thread = thread;
            _form = form;
        }

        public IntPtr Handle => _form.Handle;

        /// <summary>UI 컨트롤을 만들고 창이 실제 표시될 때까지 기다린다.</summary>
        public static WinFormsAutomationFixture Start()
        {
            var ready = new TaskCompletionSource<Form>(TaskCreationOptions.RunContinuationsAsynchronously);
            var thread = new Thread(() =>
            {
                try
                {
                    var form = BuildForm();
                    form.Shown += (_, _) => ready.TrySetResult(form);
                    Application.Run(form);
                }
                catch (Exception exception)
                {
                    ready.TrySetException(exception);
                }
            })
            {
                IsBackground = true,
                Name = "FlaUI-WinForms-Test-Target"
            };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();

            var form = ready.Task.WaitAsync(TimeSpan.FromSeconds(10)).GetAwaiter().GetResult();
            return new WinFormsAutomationFixture(thread, form);
        }

        /// <summary>HTS 조회 화면에서 쓰는 대표 컨트롤 종류를 한 폼에 구성한다.</summary>
        private static Form BuildForm()
        {
            var form = new Form
            {
                Text = "FlaUI UIA3 통합 테스트 대상",
                Name = "integrationTarget",
                Width = 640,
                Height = 420,
                StartPosition = FormStartPosition.Manual,
                Left = 80,
                Top = 80
            };

            var text = new TextBox { Name = "accountText", AccessibleName = "계좌번호", Left = 20, Top = 20, Width = 180 };
            var combo = new ComboBox { Name = "rangeCombo", AccessibleName = "조회기간", Left = 220, Top = 20, Width = 140, DropDownStyle = ComboBoxStyle.DropDownList };
            combo.Items.AddRange(new object[] { "전체", "당일", "일주일" });
            combo.SelectedIndex = 0;
            var check = new CheckBox { Name = "includeCheck", AccessibleName = "전체 포함", Text = "전체 포함", Left = 20, Top = 65, Width = 120 };
            var sell = new RadioButton { Name = "sellRadio", AccessibleName = "매도", Text = "매도", Left = 160, Top = 65, Width = 80, Checked = true };
            var buy = new RadioButton { Name = "buyRadio", AccessibleName = "매수", Text = "매수", Left = 245, Top = 65, Width = 80 };
            var tabs = new TabControl { Name = "mainTabs", AccessibleName = "결과 탭", Left = 20, Top = 110, Width = 500, Height = 180 };
            var summaryTab = new TabPage("정산내역") { Name = "summaryTab" };
            tabs.TabPages.Add(summaryTab);
            tabs.TabPages.Add(new TabPage("수수료") { Name = "feeTab" });
            var list = new ListBox { Name = "resultList", AccessibleName = "결과 목록", Left = 10, Top = 10, Width = 180, Height = 90 };
            list.Items.AddRange(new object[] { "첫째 행", "둘째 행", "셋째 행" });
            summaryTab.Controls.Add(list);
            var button = new Button { Name = "queryButton", AccessibleName = "조회", Text = "조회", Left = 380, Top = 20, Width = 90 };
            var result = new Label { Name = "resultLabel", AccessibleName = "조회 결과", Text = "대기", Left = 20, Top = 315, Width = 180 };
            button.Click += (_, _) => result.Text = "조회 완료";

            form.Controls.AddRange(new Control[] { text, combo, check, sell, buy, tabs, button, result });
            return form;
        }

        /// <summary>컨트롤 상태를 UI 스레드에서 읽어 스레드 경합 없는 검증값을 반환한다.</summary>
        public T Read<T>(Func<Control.ControlCollection, T> reader)
        {
            if (_form.InvokeRequired) return (T)_form.Invoke(() => reader(_form.Controls));
            return reader(_form.Controls);
        }

        /// <summary>폼을 닫고 STA 스레드가 끝날 때까지 제한 시간 동안 기다린다.</summary>
        public void Dispose()
        {
            try
            {
                if (!_form.IsDisposed) _form.BeginInvoke(_form.Close);
            }
            catch { }
            _thread.Join(TimeSpan.FromSeconds(5));
        }
    }
}
