// 역할: 사용자의 low-level mouse와 대상 process WinEvent를 차단 없이 작은 event queue에 적재한다.
// 입력/출력: Windows hook callback을 PassivePointerObservation/PassiveWindowEventObservation으로 변환한다.
// 경계: input을 주입·변경·차단하지 않고 F10 외 keyboard 내용을 queue나 artifact에 남기지 않는다.
// 수정 지점: recorder contract, PowerShell lifecycle과 hook/queue 단위 테스트를 함께 검증한다.
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace HtsQa.FlaUi;

public sealed class PassiveObservationQueue
{
    private readonly ConcurrentQueue<PassivePointerObservation> _pointer = new();
    private readonly ConcurrentQueue<PassiveWindowEventObservation> _window = new();

    public int PointerCount => _pointer.Count;
    public int WindowEventCount => _window.Count;

    public void EnqueuePointer(PassivePointerObservation observation) => _pointer.Enqueue(observation);
    public void EnqueueWindowEvent(PassiveWindowEventObservation observation) => _window.Enqueue(observation);
    public bool TryDequeuePointer(out PassivePointerObservation? observation) => _pointer.TryDequeue(out observation);
    public bool TryDequeueWindowEvent(out PassiveWindowEventObservation? observation) => _window.TryDequeue(out observation);
}

public sealed class PassiveInputObserver : IDisposable
{
    private const int WhMouseLl = 14;
    private const int WhKeyboardLl = 13;
    private const int WmQuit = 0x0012;
    private const int WmKeyDown = 0x0100;
    private const int WmSysKeyDown = 0x0104;
    private const int VkF10 = 0x79;
    private const uint WineventOutOfContext = 0;
    private const uint WineventSkipOwnProcess = 2;

    private readonly PassiveObservationQueue _queue = new();
    private readonly ManualResetEventSlim _ready = new(false);
    private Thread? _thread;
    private HookProc? _mouseCallback;
    private HookProc? _keyboardCallback;
    private WinEventProc? _winEventCallback;
    private IntPtr _mouseHook;
    private IntPtr _keyboardHook;
    private readonly List<IntPtr> _winEventHooks = new();
    private uint _threadId;
    private int _targetProcessId;
    private long _sequence;
    private Exception? _startupException;
    private bool _disposed;
    private volatile bool _stopRequested;

    public bool StopRequested => _stopRequested;
    public bool Started => _thread is { IsAlive: true };
    public int ActionSentCount => 0;
    public int TransactionalActionCount => 0;

    public void Start(int targetProcessId)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Passive interaction hooks require Windows.");
        if (_thread is not null) throw new InvalidOperationException("Passive input observer is already started.");
        if (targetProcessId <= 0) throw new ArgumentOutOfRangeException(nameof(targetProcessId));

        _targetProcessId = targetProcessId;
        _thread = new Thread(MessageLoop)
        {
            IsBackground = true,
            Name = "HTS-Passive-Interaction-Observer"
        };
        _thread.Start();
        if (!_ready.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("Passive input hook startup timed out.");
        if (_startupException is not null) throw new InvalidOperationException("Passive input hook startup failed.", _startupException);
    }

    public bool TryDequeuePointer(out PassivePointerObservation? observation) => _queue.TryDequeuePointer(out observation);
    public bool TryDequeueWindowEvent(out PassiveWindowEventObservation? observation) => _queue.TryDequeueWindowEvent(out observation);

    public static bool IsStopVirtualKey(int virtualKeyCode) => virtualKeyCode == VkF10;
    public static bool IsInjectedMouseFlags(uint flags) => (flags & 0x00000003) != 0;

    public static string MouseMessageName(int message) => message switch
    {
        0x0201 => "LeftDown",
        0x0202 => "LeftUp",
        0x0204 => "RightDown",
        0x0205 => "RightUp",
        _ => string.Empty
    };

    public static string WinEventName(uint eventId) => eventId switch
    {
        0x0003 => "Foreground",
        0x8002 => "Show",
        0x8003 => "Hide",
        0x8004 => "Reorder",
        0x8005 => "Focus",
        0x8006 => "Selection",
        0x8007 => "SelectionAdd",
        0x8008 => "SelectionRemove",
        0x8009 => "SelectionWithin",
        0x800C => "StateChange",
        0x800D => "LocationChange",
        0x800E => "NameChange",
        0x800F => "DescriptionChange",
        0x8010 => "ValueChange",
        _ => $"Event-{eventId:X}"
    };

    private void MessageLoop()
    {
        try
        {
            _threadId = NativeMethods.GetCurrentThreadId();
            _mouseCallback = MouseHookCallback;
            _keyboardCallback = KeyboardHookCallback;
            _winEventCallback = WinEventCallback;
            var module = NativeMethods.GetModuleHandle(null);
            _mouseHook = NativeMethods.SetWindowsHookEx(WhMouseLl, _mouseCallback, module, 0);
            _keyboardHook = NativeMethods.SetWindowsHookEx(WhKeyboardLl, _keyboardCallback, module, 0);
            if (_mouseHook == IntPtr.Zero || _keyboardHook == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Low-level passive hook registration failed.");

            AddWinEventHook(0x0003, 0x0003);
            AddWinEventHook(0x8002, 0x8005);
            AddWinEventHook(0x8006, 0x8010);
            _ready.Set();

            while (NativeMethods.GetMessage(out var message, IntPtr.Zero, 0, 0) > 0)
            {
                NativeMethods.TranslateMessage(ref message);
                NativeMethods.DispatchMessage(ref message);
            }
        }
        catch (Exception exception)
        {
            _startupException = exception;
            _ready.Set();
        }
        finally
        {
            foreach (var hook in _winEventHooks.Where(handle => handle != IntPtr.Zero)) NativeMethods.UnhookWinEvent(hook);
            if (_keyboardHook != IntPtr.Zero) NativeMethods.UnhookWindowsHookEx(_keyboardHook);
            if (_mouseHook != IntPtr.Zero) NativeMethods.UnhookWindowsHookEx(_mouseHook);
        }
    }

    private void AddWinEventHook(uint minimum, uint maximum)
    {
        var handle = NativeMethods.SetWinEventHook(minimum, maximum, IntPtr.Zero, _winEventCallback!,
            (uint)_targetProcessId, 0, WineventOutOfContext | WineventSkipOwnProcess);
        if (handle != IntPtr.Zero) _winEventHooks.Add(handle);
    }

    private IntPtr MouseHookCallback(int code, IntPtr message, IntPtr data)
    {
        if (code >= 0)
        {
            var name = MouseMessageName(message.ToInt32());
            if (name.Length > 0)
            {
                var detail = Marshal.PtrToStructure<MouseHookData>(data);
                _queue.EnqueuePointer(new PassivePointerObservation
                {
                    Sequence = Interlocked.Increment(ref _sequence),
                    ObservedAt = DateTimeOffset.Now,
                    Button = name.StartsWith("Left", StringComparison.Ordinal) ? "Left" : "Right",
                    Phase = name.EndsWith("Down", StringComparison.Ordinal) ? "Down" : "Up",
                    X = detail.Point.X,
                    Y = detail.Point.Y,
                    Injected = IsInjectedMouseFlags(detail.Flags)
                });
            }
        }
        return NativeMethods.CallNextHookEx(_mouseHook, code, message, data);
    }

    private IntPtr KeyboardHookCallback(int code, IntPtr message, IntPtr data)
    {
        if (code >= 0 && (message.ToInt32() == WmKeyDown || message.ToInt32() == WmSysKeyDown))
        {
            var virtualKeyCode = Marshal.ReadInt32(data);
            if (IsStopVirtualKey(virtualKeyCode)) _stopRequested = true;
        }
        return NativeMethods.CallNextHookEx(_keyboardHook, code, message, data);
    }

    private void WinEventCallback(IntPtr hook, uint eventId, IntPtr hwnd, int objectId, int childId, uint threadId, uint eventTime)
    {
        if (hwnd == IntPtr.Zero) return;
        NativeMethods.GetWindowThreadProcessId(hwnd, out var processId);
        if (processId != (uint)_targetProcessId) return;
        _queue.EnqueueWindowEvent(new PassiveWindowEventObservation
        {
            Sequence = Interlocked.Increment(ref _sequence),
            ObservedAt = DateTimeOffset.Now,
            EventName = WinEventName(eventId),
            EventId = eventId,
            Hwnd = hwnd.ToInt64(),
            ObjectId = objectId,
            ChildId = childId,
            ProcessId = (int)processId,
            ThreadId = (int)threadId
        });
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_threadId != 0) NativeMethods.PostThreadMessage(_threadId, WmQuit, IntPtr.Zero, IntPtr.Zero);
        _thread?.Join(TimeSpan.FromSeconds(5));
        _ready.Dispose();
    }

    private delegate IntPtr HookProc(int code, IntPtr message, IntPtr data);
    private delegate void WinEventProc(IntPtr hook, uint eventId, IntPtr hwnd, int objectId, int childId, uint threadId, uint eventTime);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseHookData
    {
        public NativePoint Point;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeMessage
    {
        public IntPtr Hwnd;
        public uint Message;
        public UIntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public NativePoint Point;
        public uint Private;
    }

    private static class NativeMethods
    {
        [DllImport("user32.dll", SetLastError = true)]
        internal static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr module, uint threadId);
        [DllImport("user32.dll", SetLastError = true)]
        internal static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")]
        internal static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr GetModuleHandle(string? moduleName);
        [DllImport("kernel32.dll")]
        internal static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")]
        internal static extern int GetMessage(out NativeMessage message, IntPtr hwnd, uint minimum, uint maximum);
        [DllImport("user32.dll")]
        internal static extern bool TranslateMessage(ref NativeMessage message);
        [DllImport("user32.dll")]
        internal static extern IntPtr DispatchMessage(ref NativeMessage message);
        [DllImport("user32.dll", SetLastError = true)]
        internal static extern bool PostThreadMessage(uint threadId, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")]
        internal static extern IntPtr SetWinEventHook(uint minimum, uint maximum, IntPtr module, WinEventProc callback,
            uint processId, uint threadId, uint flags);
        [DllImport("user32.dll")]
        internal static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("user32.dll")]
        internal static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    }
}
