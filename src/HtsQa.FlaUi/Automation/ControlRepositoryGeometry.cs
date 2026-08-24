// 역할: 승인된 client-relative locator를 현재 client rect와 DPI 증거에 맞춰 실행 직전 화면 점으로 변환한다.
// 경계: repository 승인/위험 판정이나 cursor 동작은 수행하지 않으며 desktop absolute 좌표를 입력 locator로 받지 않는다.
using System.Runtime.InteropServices;

namespace HtsQa.FlaUi;

public sealed record ClientGeometryRect(int Left, int Top, int Width, int Height)
{
    public bool IsValid => Width > 0 && Height > 0;
    public bool Contains(ClientGeometryPoint point) =>
        IsValid && point.X >= Left && point.Y >= Top && point.X < Left + Width && point.Y < Top + Height;
}

public sealed record ClientGeometryPoint(int X, int Y);

public sealed record ClientCoordinateTransform
{
    public bool IsValid { get; init; }
    public bool DpiTransformValid { get; init; }
    public bool InsideClientBounds { get; init; }
    public double DpiScale { get; init; }
    public ClientGeometryRect? CurrentClientRect { get; init; }
    public ClientGeometryPoint? ScreenPoint { get; init; }
    public string FailureReason { get; init; } = "";
}

public static class ControlRepositoryGeometry
{
    public static ClientCoordinateTransform Transform(double relativeX, double relativeY, ClientGeometryRect currentClientRect, uint currentDpi)
    {
        if (!currentClientRect.IsValid)
            return Invalid(currentClientRect, currentDpi, "Current client bounds are invalid.");
        if (!double.IsFinite(relativeX) || !double.IsFinite(relativeY) || relativeX < 0 || relativeX > 1 || relativeY < 0 || relativeY > 1)
            return Invalid(currentClientRect, currentDpi, "Relative coordinates must be finite normalized client values.");
        if (currentDpi == 0)
            return Invalid(currentClientRect, currentDpi, "DPI could not be observed immediately before resolution.");

        // 현재 client rect의 물리 픽셀을 사용하므로 window 이동/resize/DPI 변경 시 이전 desktop point를 재사용하지 않는다.
        var x = currentClientRect.Left + (int)Math.Round(relativeX * Math.Max(0, currentClientRect.Width - 1), MidpointRounding.AwayFromZero);
        var y = currentClientRect.Top + (int)Math.Round(relativeY * Math.Max(0, currentClientRect.Height - 1), MidpointRounding.AwayFromZero);
        var point = new ClientGeometryPoint(x, y);
        var inside = currentClientRect.Contains(point);
        return new()
        {
            IsValid = inside,
            DpiTransformValid = true,
            InsideClientBounds = inside,
            DpiScale = currentDpi / 96.0,
            CurrentClientRect = currentClientRect,
            ScreenPoint = point,
            FailureReason = inside ? "" : "Computed point is outside the current client bounds."
        };
    }

    public static ClientGeometryRect? TryReadCurrentClientRect(long hwnd)
    {
        if (!OperatingSystem.IsWindows() || hwnd == 0) return null;
        var handle = new IntPtr(hwnd);
        if (!NativeMethods.GetClientRect(handle, out var client)) return null;
        var origin = new NativePoint { X = client.Left, Y = client.Top };
        if (!NativeMethods.ClientToScreen(handle, ref origin)) return null;
        return new(origin.X, origin.Y, client.Right - client.Left, client.Bottom - client.Top);
    }

    private static ClientCoordinateTransform Invalid(ClientGeometryRect rect, uint dpi, string reason) => new()
    {
        IsValid = false,
        DpiTransformValid = dpi > 0,
        InsideClientBounds = false,
        DpiScale = dpi / 96.0,
        CurrentClientRect = rect,
        FailureReason = reason
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint { public int X; public int Y; }

    private static class NativeMethods
    {
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetClientRect(IntPtr hwnd, out NativeRect rect);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool ClientToScreen(IntPtr hwnd, ref NativePoint point);
    }
}
