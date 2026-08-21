<#
.SYNOPSIS Initializes the Win32 interop contract used by HTS UI modules.
.DESCRIPTION Declares native APIs only when a non-dry-run orchestration explicitly requests them.
#>

function Initialize-HtsNativeInterop {
    if ('TargetRuleNative' -as [type]) { return }
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type @'
    using System;
    using System.Text;
    using System.Runtime.InteropServices;
    public static class TargetRuleNative {
      public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
      public delegate bool EnumChildProc(IntPtr hWnd, IntPtr lParam);
      [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
      [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumChildProc proc, IntPtr lParam);
      [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
      [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
      [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hWnd);
      [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr hWnd);
      [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
      [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
      [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
      [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
      [DllImport("user32.dll", SetLastError=true)] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
      [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetFocus(IntPtr hWnd);
      [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
      [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
      [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hWnd);
      [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint command);
      [DllImport("user32.dll")] public static extern bool IsChild(IntPtr hWndParent, IntPtr hWnd);
      [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
      [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
      [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
      [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
      [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
      [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
      [DllImport("user32.dll")] public static extern bool SetPhysicalCursorPos(int x, int y);
      [DllImport("user32.dll")] public static extern bool GetPhysicalCursorPos(out POINT point);
      [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);
      [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
      [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
      [DllImport("user32.dll")] public static extern bool LogicalToPhysicalPointForPerMonitorDPI(IntPtr hWnd, ref POINT point);
      [DllImport("user32.dll")] public static extern IntPtr GetNextDlgTabItem(IntPtr hDlg, IntPtr hCtl, bool previous);
      [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);
      [DllImport("user32.dll")] public static extern bool GetComboBoxInfo(IntPtr hwndCombo, ref COMBOBOXINFO info);
      [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
      [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
      [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
      [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, string lParam);
      [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
      [DllImport("user32.dll", SetLastError=true, EntryPoint="SendMessageTimeoutW")] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
      [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true, EntryPoint="SendMessageTimeoutW")] public static extern IntPtr SendMessageTimeoutText(IntPtr hWnd, uint msg, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
      [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr SendMessageText(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam);
      [DllImport("user32.dll", EntryPoint="GetWindowLong")] public static extern int GetWindowLong32(IntPtr hWnd, int index);
      [DllImport("user32.dll", EntryPoint="GetWindowLongPtr")] public static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int index);
      public static long GetStyle(IntPtr hWnd) { return IntPtr.Size == 8 ? GetWindowLongPtr64(hWnd, -16).ToInt64() : GetWindowLong32(hWnd, -16); }
      [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
      [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
      [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData; public uint flags; public uint time; public UIntPtr extraInfo;
      }
      [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mouse;
      }
      [StructLayout(LayoutKind.Sequential)] public struct INPUT {
        public uint type; public INPUTUNION data;
      }
      public static bool SendLeftClick() {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = 0;
        inputs[0].data.mouse.flags = 0x0002;
        inputs[1].type = 0;
        inputs[1].data.mouse.flags = 0x0004;
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) == (uint)inputs.Length;
      }
      [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
        public int cbSize; public int flags;
        public IntPtr hwndActive; public IntPtr hwndFocus; public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret;
        public RECT rcCaret;
      }
      [StructLayout(LayoutKind.Sequential)] public struct COMBOBOXINFO {
        public int cbSize; public RECT rcItem; public RECT rcButton; public int stateButton;
        public IntPtr hwndCombo; public IntPtr hwndItem; public IntPtr hwndList;
      }
    }
'@
}
