// 역할: 표시된 합성 WinForms에서 native frame, hit-test, visual hash와 redaction을 실제 Win32 API로 검증한다.
// 입력/출력: fixture HWND와 button screen point를 observeInteractionFrame bridge response로 변환한다.
// 경계: mouse click·focus 변경·keyboard input·실제 HTS·ResultEvaluator와 TestResult를 수행하지 않는다.
// 수정 지점: native frame inventory, visual signature 또는 bridge frame operation 변경 시 함께 갱신한다.
using System.Text.Json;
using System.Windows.Forms;
using HtsQa.FlaUi;

namespace HtsQa.Tests.Automation;

public sealed class PassiveInteractionFrameIntegrationTests : IDisposable
{
    private readonly Fixture _fixture = Fixture.Start();

    [Fact]
    public void ObserveInteractionFrame_Reads_Native_Hit_And_Visual_Hash_Without_Plaintext_Or_Action()
    {
        using var engine = new FlaUiAutomationEngine();
        var point = _fixture.ButtonCenter();
        var response = engine.Execute(new BridgeRequest
        {
            RequestId = "frame",
            Operation = "observeInteractionFrame",
            RootHwnd = _fixture.Handle.ToInt64(),
            CapturePoint = new() { X = point.X, Y = point.Y },
            IncludeVisualSignature = true,
            VisualGridColumns = 8,
            VisualGridRows = 6,
            RegionHints = [new() { Region = "WholeFixture", Left = 0, Top = 0, Right = 1, Bottom = 1, Priority = 100 }]
        });

        Assert.True(response.Success, response.Message);
        Assert.False(response.ActionSent);
        Assert.False(response.ActionVerified);
        var frame = Assert.IsType<NativeInteractionFrameSnapshot>(response.InteractionFrame);
        Assert.Equal("Discovery", frame.ArtifactRole);
        Assert.False(frame.TestExecution);
        Assert.False(frame.VerdictEligible);
        Assert.False(frame.ResultEvaluatorInvoked);
        Assert.Equal(0, frame.ActionSentCount);
        Assert.Equal(0, frame.TransactionalActionCount);
        Assert.NotEmpty(frame.Windows);
        Assert.Contains(frame.Windows, window => window.Hwnd == _fixture.Handle.ToInt64());
        var hit = Assert.IsType<InteractionHitTargetSnapshot>(frame.HitTarget);
        Assert.True(hit.InsideTarget);
        Assert.NotEqual(0, hit.PrimaryHwnd);
        Assert.InRange(hit.NormalizedRootX, 0, 1);
        Assert.InRange(hit.NormalizedRootY, 0, 1);
        Assert.Equal("WholeFixture", hit.SpatialRegion);
        Assert.InRange(hit.NormalizedRegionX, 0, 1);
        Assert.InRange(hit.NormalizedRegionY, 0, 1);
        Assert.Equal(hit.RootClientPoint.X, hit.RegionRelativePoint.X);
        Assert.Equal(hit.RootClientPoint.Y, hit.RegionRelativePoint.Y);
        Assert.True(frame.VisualSignature.Available, frame.VisualSignature.ErrorCode);
        Assert.False(frame.VisualSignature.PixelDataStored);
        Assert.Equal(48, frame.VisualSignature.BlockHashes.Count);
        var json = JsonSerializer.Serialize(response, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
        Assert.DoesNotContain("fixture-sensitive-value", json, StringComparison.Ordinal);
    }

    public void Dispose() => _fixture.Dispose();

    private sealed class Fixture : IDisposable
    {
        private readonly Thread _thread;
        private readonly Form _form;
        private readonly Button _button;

        private Fixture(Thread thread, Form form, Button button)
        {
            _thread = thread;
            _form = form;
            _button = button;
        }

        public IntPtr Handle => _form.Handle;

        public static Fixture Start()
        {
            var ready = new TaskCompletionSource<(Form Form, Button Button)>(TaskCreationOptions.RunContinuationsAsynchronously);
            var thread = new Thread(() =>
            {
                var form = new Form { Text = "Passive Frame Fixture", Width = 480, Height = 320, Left = 120, Top = 120, StartPosition = FormStartPosition.Manual };
                var button = new Button { Text = "fixture-sensitive-value", Left = 80, Top = 70, Width = 180, Height = 45 };
                form.Controls.Add(button);
                form.Shown += (_, _) => ready.TrySetResult((form, button));
                Application.Run(form);
            }) { IsBackground = true, Name = "Passive-Frame-Fixture" };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
            var value = ready.Task.WaitAsync(TimeSpan.FromSeconds(10)).GetAwaiter().GetResult();
            return new Fixture(thread, value.Form, value.Button);
        }

        public System.Drawing.Point ButtonCenter()
        {
            if (_form.InvokeRequired)
                return (System.Drawing.Point)_form.Invoke(() => _button.PointToScreen(new System.Drawing.Point(_button.Width / 2, _button.Height / 2)));
            return _button.PointToScreen(new System.Drawing.Point(_button.Width / 2, _button.Height / 2));
        }

        public void Dispose()
        {
            try { if (!_form.IsDisposed) _form.BeginInvoke(_form.Close); } catch { }
            _thread.Join(TimeSpan.FromSeconds(5));
        }
    }
}
