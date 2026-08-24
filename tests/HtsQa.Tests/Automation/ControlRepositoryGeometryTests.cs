// 역할: client-relative 좌표 변환과 read-only hover capture가 이동/resize/DPI 변화 및 민감정보 경계를 지키는지 검증한다.
// 범위: 순수 geometry와 격리된 sample WinForms만 사용하며 실제 HTS 또는 사용자 cursor action을 수행하지 않는다.
using System.Drawing;
using System.Text.Json;
using System.Windows.Forms;
using HtsQa.FlaUi;

namespace HtsQa.Tests;

public sealed class ControlRepositoryGeometryTests
{
    [Fact]
    public void Dpi_Change_Uses_Current_Client_Rect()
    {
        var result = ControlRepositoryGeometry.Transform(0.5, 0.25, new(100, 200, 400, 800), 144);

        Assert.True(result.IsValid);
        Assert.True(result.DpiTransformValid);
        Assert.Equal(1.5, result.DpiScale);
        Assert.Equal(new ClientGeometryPoint(300, 400), result.ScreenPoint);
    }

    [Fact]
    public void Window_Move_Does_Not_Reuse_Previous_Desktop_Point()
    {
        var first = ControlRepositoryGeometry.Transform(0.5, 0.5, new(0, 0, 201, 201), 96);
        var moved = ControlRepositoryGeometry.Transform(0.5, 0.5, new(500, 300, 201, 201), 96);

        Assert.Equal(new ClientGeometryPoint(100, 100), first.ScreenPoint);
        Assert.Equal(new ClientGeometryPoint(600, 400), moved.ScreenPoint);
        Assert.NotEqual(first.ScreenPoint, moved.ScreenPoint);
    }

    [Fact]
    public void Host_Resize_Recalculates_Relative_Point()
    {
        var small = ControlRepositoryGeometry.Transform(0.25, 0.75, new(10, 20, 101, 101), 96);
        var resized = ControlRepositoryGeometry.Transform(0.25, 0.75, new(10, 20, 401, 201), 96);

        Assert.Equal(new ClientGeometryPoint(35, 95), small.ScreenPoint);
        Assert.Equal(new ClientGeometryPoint(110, 170), resized.ScreenPoint);
    }

    [Theory]
    [InlineData(-0.01, 0.5)]
    [InlineData(1.01, 0.5)]
    [InlineData(0.5, -0.01)]
    [InlineData(0.5, 1.01)]
    public void Out_Of_Bounds_Relative_Point_Is_Blocked(double x, double y)
    {
        var result = ControlRepositoryGeometry.Transform(x, y, new(0, 0, 100, 100), 96);

        Assert.False(result.IsValid);
        Assert.False(result.InsideClientBounds);
        Assert.Null(result.ScreenPoint);
    }

    [Fact]
    public void Missing_Dpi_Is_Fail_Closed()
    {
        var result = ControlRepositoryGeometry.Transform(0.5, 0.5, new(0, 0, 100, 100), 0);

        Assert.False(result.IsValid);
        Assert.False(result.DpiTransformValid);
        Assert.Contains("DPI", result.FailureReason, StringComparison.OrdinalIgnoreCase);
    }
}

public sealed class ControlCaptureCandidateTests : IDisposable
{
    private readonly CaptureFormFixture _fixture = CaptureFormFixture.Start();

    [Fact]
    public void Capture_Is_Read_Only_ReviewRequired_And_Redacted()
    {
        using var engine = new FlaUiAutomationEngine();
        var cursorBefore = Cursor.Position;
        var point = _fixture.PointInsideButton();

        var response = engine.CaptureCandidate(new BridgeRequest
        {
            RequestId = "fixture-capture",
            Operation = "captureCandidate",
            RootHwnd = _fixture.Handle.ToInt64(),
            CapturePoint = new() { X = point.X, Y = point.Y },
            StateContext = "fixture:state",
            MapScreenCode = "FIXTURE-MAP",
            CoordinateSpace = "ScreenClient"
        });

        Assert.True(response.Success, response.Message);
        Assert.True(response.Verified);
        Assert.False(response.ActionSent);
        Assert.False(response.ActionVerified);
        var capture = Assert.IsType<ControlCaptureSnapshot>(response.CaptureCandidate);
        Assert.Equal("ReviewRequired", capture.Status);
        Assert.Equal("fixture:state", capture.StateContext);
        Assert.Equal("FIXTURE-MAP", capture.MapScreenCode);
        Assert.InRange(capture.RelativeX, 0, 1);
        Assert.InRange(capture.RelativeY, 0, 1);
        Assert.False(capture.CursorMoved);
        Assert.False(capture.ClickSent);
        Assert.True(capture.WindowWidth > 0);
        Assert.True(capture.WindowHeight > 0);
        Assert.False(capture.AutomaticallyApproved);
        Assert.Equal(64, capture.ProcessFingerprint.Length);
        Assert.Equal(64, capture.HostFingerprint.Length);
        Assert.Equal(64, capture.VisualSignatureHash.Length);
        Assert.Contains($"host-sha256:{capture.HostFingerprint}", capture.RedactedIdentityCandidates);
        Assert.All(capture.RedactedIdentityCandidates, candidate => Assert.DoesNotContain("fixture", candidate, StringComparison.OrdinalIgnoreCase));
        Assert.Equal(cursorBefore, Cursor.Position);
        Assert.Equal(0, _fixture.ClickCount);

        var json = JsonSerializer.Serialize(response);
        Assert.DoesNotContain("fixture-sensitive-value", json, StringComparison.Ordinal);
        Assert.DoesNotContain("fixture-password", json, StringComparison.Ordinal);
        Assert.Contains(capture.RedactionsApplied, x => x.Contains("current value", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Preflight_Recomputes_Current_Point_And_Reobserves_Without_Action()
    {
        using var engine = new FlaUiAutomationEngine();
        var cursorBefore = Cursor.Position;
        var response = engine.Execute(new BridgeRequest
        {
            RequestId = "fixture-preflight",
            Operation = "controlRepositoryPreflight",
            RootHwnd = _fixture.Handle.ToInt64(),
            StateContext = "fixture:state",
            MapScreenCode = "FIXTURE-MAP",
            CoordinateSpace = "ScreenClient",
            RelativeX = 0.5,
            RelativeY = 0.5
        });

        Assert.True(response.Success, response.Message);
        Assert.False(response.ActionSent);
        var observed = Assert.IsType<ControlRepositoryPreflightSnapshot>(response.ControlRepositoryPreflight);
        Assert.Equal("Observed", observed.Status);
        Assert.True(observed.CurrentClientRect.Width > 0);
        Assert.True(observed.CurrentClientRect.Height > 0);
        Assert.InRange(observed.ResolvedScreenPoint.X, observed.CurrentClientRect.Left, observed.CurrentClientRect.Right - 1);
        Assert.InRange(observed.ResolvedScreenPoint.Y, observed.CurrentClientRect.Top, observed.CurrentClientRect.Bottom - 1);
        Assert.Contains($"host-sha256:{observed.HostFingerprint}", observed.ObservedAnchorIds);
        Assert.False(observed.CursorMoved);
        Assert.False(observed.ClickSent);
        Assert.Equal(cursorBefore, Cursor.Position);
        Assert.Equal(0, _fixture.ClickCount);
    }

    [Fact]
    public void Capture_Without_Hotkey_Point_Is_Blocked_Without_Action()
    {
        using var engine = new FlaUiAutomationEngine();
        var response = engine.CaptureCandidate(new BridgeRequest { Operation = "captureCandidate", RootHwnd = _fixture.Handle.ToInt64() });

        Assert.False(response.Success);
        Assert.Equal("CAPTURE_POINT_REQUIRED", response.ErrorCode);
        Assert.False(response.ActionSent);
        Assert.Equal(0, _fixture.ClickCount);
    }

    public void Dispose() => _fixture.Dispose();

    private sealed class CaptureFormFixture : IDisposable
    {
        private readonly Thread _thread;
        private readonly Form _form;
        private int _clickCount;

        private CaptureFormFixture(Thread thread, Form form)
        {
            _thread = thread;
            _form = form;
        }

        public IntPtr Handle => _form.Handle;
        public int ClickCount => Volatile.Read(ref _clickCount);

        public Point PointInsideButton() => OnUi(() =>
        {
            var button = (Button)_form.Controls["captureTarget"]!;
            return button.PointToScreen(new Point(button.Width / 2, button.Height / 2));
        });

        public static CaptureFormFixture Start()
        {
            var ready = new TaskCompletionSource<(Thread Thread, Form Form)>(TaskCreationOptions.RunContinuationsAsynchronously);
            Thread? thread = null;
            thread = new Thread(() =>
            {
                try
                {
                    var form = new Form
                    {
                        Text = "Control Repository Capture Fixture",
                        Name = "captureFixture",
                        Width = 420,
                        Height = 240,
                        StartPosition = FormStartPosition.Manual,
                        Left = 120,
                        Top = 120
                    };
                    var button = new Button { Name = "captureTarget", AccessibleName = "capture fixture", Text = "Capture", Left = 40, Top = 40, Width = 120 };
                    var sensitive = new TextBox { Name = "sensitive", Text = "fixture-sensitive-value", Left = 40, Top = 100, Width = 150 };
                    var password = new TextBox { Name = "password", Text = "fixture-password", UseSystemPasswordChar = true, Left = 210, Top = 100, Width = 120 };
                    form.Controls.AddRange([button, sensitive, password]);
                    form.Shown += (_, _) => ready.TrySetResult((thread!, form));
                    Application.Run(form);
                }
                catch (Exception exception) { ready.TrySetException(exception); }
            }) { IsBackground = true, Name = "ControlRepository-Capture-Fixture" };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
            var result = ready.Task.WaitAsync(TimeSpan.FromSeconds(10)).GetAwaiter().GetResult();
            var fixture = new CaptureFormFixture(result.Thread, result.Form);
            ((Button)result.Form.Controls["captureTarget"]!).Click += (_, _) => Interlocked.Increment(ref fixture._clickCount);
            return fixture;
        }

        private T OnUi<T>(Func<T> action) => _form.InvokeRequired ? (T)_form.Invoke(action) : action();

        public void Dispose()
        {
            try { if (!_form.IsDisposed) _form.BeginInvoke(_form.Close); }
            catch { }
            _thread.Join(TimeSpan.FromSeconds(5));
        }
    }
}
