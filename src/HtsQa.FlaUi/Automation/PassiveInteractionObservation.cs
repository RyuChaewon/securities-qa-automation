// 역할: 대상 HWND의 read-only native frame·hit-test·visual signature를 만들고 manual interaction 차이를 분석한다.
// 입력/출력: root HWND와 pointer point를 frame으로, pre/post frame과 WinEvent를 interaction·zone suggestion으로 변환한다.
// 경계: 화면을 활성화하거나 input을 보내지 않고 raw text·pixel·password·verdict·승인 상태를 저장하지 않는다.
// 수정 지점: passive contracts, bridge dispatch, PowerShell recorder와 synthetic frame 테스트를 함께 변경한다.
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace HtsQa.FlaUi;

public sealed partial class FlaUiAutomationEngine
{
    public BridgeResponse ObserveInteractionFrame(BridgeRequest request)
    {
        try
        {
            var frame = PassiveInteractionObservation.CaptureFrame(request.RootHwnd, request.CapturePoint,
                request.RegionHints, request.IncludeVisualSignature, request.VisualGridColumns, request.VisualGridRows);
            return new BridgeResponse
            {
                RequestId = request.RequestId,
                Success = true,
                Verified = true,
                ActionSent = false,
                ActionVerified = false,
                Message = "사용자 input을 변경하지 않고 native interaction frame을 관측했습니다.",
                InteractionFrame = frame
            };
        }
        catch (Exception exception)
        {
            return BridgeResponse.Failure(request, "PASSIVE_FRAME_OBSERVATION_FAILED", exception.Message);
        }
    }

    public BridgeResponse AnalyzeObservedInteraction(BridgeRequest request)
    {
        if (request.PointerDown is null || request.PointerUp is null || request.PreInteractionFrame is null || request.PostInteractionFrames.Count == 0)
            return BridgeResponse.Failure(request, "PASSIVE_INTERACTION_EVIDENCE_REQUIRED", "pointer down/up과 pre/post frame이 필요합니다.");
        try
        {
            var interaction = PassiveInteractionAnalysis.CreateInteraction(request.InteractionSequence, request.PointerDown,
                request.PointerUp, request.PreInteractionFrame, request.PostInteractionFrames, request.WindowEvents,
                request.PreviousInteraction);
            return new BridgeResponse
            {
                RequestId = request.RequestId,
                Success = true,
                Verified = true,
                ActionSent = false,
                ActionVerified = false,
                Message = "manual interaction을 Discovery suggestion으로 상관분석했습니다.",
                ObservedInteraction = interaction
            };
        }
        catch (Exception exception)
        {
            return BridgeResponse.Failure(request, "PASSIVE_INTERACTION_ANALYSIS_FAILED", exception.Message);
        }
    }

    public BridgeResponse ClusterObservedInteractions(BridgeRequest request)
    {
        try
        {
            var zones = PassiveInteractionAnalysis.Cluster(request.Interactions, request.ZoneDistanceThreshold);
            return new BridgeResponse
            {
                RequestId = request.RequestId,
                Success = true,
                Verified = true,
                ActionSent = false,
                ActionVerified = false,
                Message = "manual interaction을 ReviewRequired hit-zone 후보로 묶었습니다.",
                InteractionZones = zones
            };
        }
        catch (Exception exception)
        {
            return BridgeResponse.Failure(request, "PASSIVE_INTERACTION_CLUSTER_FAILED", exception.Message);
        }
    }
}

public static class PassiveInteractionObservation
{
    private const uint GwOwner = 4;
    private const uint CwpSkipInvisible = 1;
    private const uint CwpSkipDisabled = 2;
    private const uint CwpSkipTransparent = 4;
    private const long WsPopup = unchecked((long)0x80000000);

    public static NativeInteractionFrameSnapshot CaptureFrame(long rootHwnd, CapturePoint? point,
        IReadOnlyList<LayoutRegionHint>? regionHints, bool includeVisualSignature, int visualColumns, int visualRows)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Native interaction observation requires Windows.");
        var root = new IntPtr(rootHwnd);
        if (rootHwnd == 0 || !NativeMethods.IsWindow(root)) throw new ArgumentException("Root HWND is invalid.", nameof(rootHwnd));
        var rootThread = NativeMethods.GetWindowThreadProcessId(root, out var processId);
        var rootBounds = ReadWindowBounds(root);
        var clientBounds = ReadClientScreenBounds(root);
        var dpi = NativeMethods.GetDpiForWindow(root);
        var foreground = NativeMethods.GetForegroundWindow().ToInt64();
        var focus = ReadFocus(rootThread);
        var hints = regionHints is { Count: > 0 } ? regionHints : DefaultRegions();

        var handles = EnumerateTargetWindows(root, processId);
        var windows = handles.Select((handle, index) => CreateWindowSnapshot(handle, root, (int)processId, rootBounds, hints, index))
            .OrderBy(window => window.Depth).ThenBy(window => window.ZOrder).ThenBy(window => window.Hwnd).ToArray();
        var popups = windows.Where(window => window.IsOwnedPopup || window.IsPopup && !window.IsDescendant)
            .Select(window => window.Hwnd).Distinct().OrderBy(value => value).ToArray();
        var layoutFingerprint = Hash(string.Join("\n", windows.Select(WindowFingerprintLine)));
        var visual = includeVisualSignature
            ? CaptureVisualSignature(clientBounds, Math.Clamp(visualColumns, 4, 64), Math.Clamp(visualRows, 3, 48))
            : new PassiveVisualSignature { Available = false, ErrorCode = "Disabled", PixelDataStored = false };
        var stateFingerprint = Hash(string.Join("|", layoutFingerprint, foreground, focus, visual.PerceptualHash));

        return new NativeInteractionFrameSnapshot
        {
            RootHwnd = rootHwnd,
            ProcessId = (int)processId,
            ForegroundHwnd = foreground,
            FocusHwnd = focus,
            RootBounds = rootBounds,
            RootClientBounds = clientBounds,
            Dpi = dpi,
            RegionHints = hints,
            ObservedAt = DateTimeOffset.Now,
            LayoutFingerprint = layoutFingerprint,
            StateFingerprint = stateFingerprint,
            PopupHwnds = popups,
            Windows = windows,
            HitTarget = point is null ? null : ResolveHitTarget(root, point, windows, clientBounds, hints),
            VisualSignature = visual,
            ActionSentCount = 0,
            TransactionalActionCount = 0
        };
    }

    private static IReadOnlyList<IntPtr> EnumerateTargetWindows(IntPtr root, uint processId)
    {
        var values = new List<IntPtr> { root };
        NativeMethods.EnumChildWindows(root, (hwnd, _) => { values.Add(hwnd); return true; }, IntPtr.Zero);
        NativeMethods.EnumWindows((hwnd, _) =>
        {
            NativeMethods.GetWindowThreadProcessId(hwnd, out var candidateProcess);
            if (candidateProcess != processId || hwnd == root) return true;
            var className = ReadClassName(hwnd);
            if (IsOwnedByRoot(hwnd, root) || string.Equals(className, "ComboLBox", StringComparison.OrdinalIgnoreCase)) values.Add(hwnd);
            return true;
        }, IntPtr.Zero);
        return values.Where(handle => handle != IntPtr.Zero && NativeMethods.IsWindow(handle)).Distinct().ToArray();
    }

    private static NativeInteractionWindowSnapshot CreateWindowSnapshot(IntPtr hwnd, IntPtr root, int processId,
        ElementRectangle rootBounds, IReadOnlyList<LayoutRegionHint> hints, int zOrder)
    {
        var parent = NativeMethods.GetParent(hwnd);
        var owner = NativeMethods.GetWindow(hwnd, GwOwner);
        var bounds = ReadWindowBounds(hwnd);
        var normalized = Normalize(bounds, rootBounds);
        var ancestors = ReadAncestors(hwnd, root);
        var className = ReadClassName(hwnd);
        var style = ReadWindowLong(hwnd, -16);
        var extendedStyle = ReadWindowLong(hwnd, -20);
        var textMetadata = ReadRedactedTextMetadata(hwnd, className);
        var isDescendant = hwnd == root || NativeMethods.IsChild(root, hwnd);
        var isOwnedPopup = hwnd != root && IsOwnedByRoot(hwnd, root);
        NativeMethods.GetWindowThreadProcessId(hwnd, out _);
        var signature = Hash(string.Join("|", className, NativeMethods.GetDlgCtrlID(hwnd), style, extendedStyle,
            parent.ToInt64(), owner.ToInt64(), string.Join(",", ancestors)));
        return new NativeInteractionWindowSnapshot
        {
            Hwnd = hwnd.ToInt64(),
            ParentHwnd = parent.ToInt64(),
            OwnerHwnd = owner.ToInt64(),
            RootHwnd = root.ToInt64(),
            ProcessId = processId,
            ThreadId = (int)NativeMethods.GetWindowThreadProcessId(hwnd, out _),
            Depth = ancestors.Count,
            ZOrder = zOrder,
            ClassName = className,
            ControlId = NativeMethods.GetDlgCtrlID(hwnd),
            Style = style,
            ExtendedStyle = extendedStyle,
            IsVisible = NativeMethods.IsWindowVisible(hwnd),
            IsEnabled = NativeMethods.IsWindowEnabled(hwnd),
            IsDescendant = isDescendant,
            IsOwnedPopup = isOwnedPopup,
            IsPopup = (style & WsPopup) != 0 || owner != IntPtr.Zero,
            Bounds = bounds,
            NormalizedBounds = normalized,
            SpatialRegion = ClassifyRegion(hints, normalized),
            NativeTextHash = textMetadata.Hash,
            NativeTextLength = textMetadata.Length,
            NativeSignature = signature,
            AncestorHwnds = ancestors
        };
    }

    private static InteractionHitTargetSnapshot ResolveHitTarget(IntPtr root, CapturePoint point,
        IReadOnlyList<NativeInteractionWindowSnapshot> windows, ElementRectangle clientBounds, IReadOnlyList<LayoutRegionHint> hints)
    {
        var nativePoint = new NativePoint { X = point.X, Y = point.Y };
        var fromPoint = NativeMethods.WindowFromPoint(nativePoint);
        var clientPoint = nativePoint;
        NativeMethods.ScreenToClient(root, ref clientPoint);
        var child = NativeMethods.ChildWindowFromPointEx(root, clientPoint, CwpSkipInvisible | CwpSkipDisabled | CwpSkipTransparent);
        var realChild = NativeMethods.RealChildWindowFromPoint(root, clientPoint);
        var containing = windows.Where(window => Contains(window.Bounds, point))
            .OrderBy(window => (long)Math.Max(1, window.Bounds.Width) * Math.Max(1, window.Bounds.Height))
            .ThenByDescending(window => window.Depth).ToArray();
        var known = windows.ToDictionary(window => window.Hwnd);
        var candidateHwnds = new[] { fromPoint.ToInt64(), realChild.ToInt64(), child.ToInt64() }
            .Concat(containing.Select(window => window.Hwnd)).Where(value => value != 0).Distinct().ToArray();
        var primary = candidateHwnds.Select(value => known.GetValueOrDefault(value)).FirstOrDefault(value => value is not null)
            ?? containing.FirstOrDefault();
        var insideTarget = Contains(clientBounds, point) || containing.Any(window => window.IsDescendant || window.IsOwnedPopup);
        if (primary is null)
        {
            return new InteractionHitTargetSnapshot
            {
                InsideTarget = false,
                WindowFromPointHwnd = fromPoint.ToInt64(),
                ChildWindowFromPointHwnd = child.ToInt64(),
                RealChildWindowFromPointHwnd = realChild.ToInt64(),
                ScreenPoint = new() { X = point.X, Y = point.Y },
                CandidateHwnds = candidateHwnds
            };
        }

        var parent = known.GetValueOrDefault(primary.ParentHwnd) ?? primary;
        var rootWidth = Math.Max(1, clientBounds.Width - 1);
        var rootHeight = Math.Max(1, clientBounds.Height - 1);
        var parentWidth = Math.Max(1, parent.Bounds.Width - 1);
        var parentHeight = Math.Max(1, parent.Bounds.Height - 1);
        var normalizedRootX = Clamp01((point.X - clientBounds.Left) / (double)rootWidth);
        var normalizedRootY = Clamp01((point.Y - clientBounds.Top) / (double)rootHeight);
        var regionHint = hints.Where(hint => normalizedRootX >= hint.Left && normalizedRootX < hint.Right &&
                normalizedRootY >= hint.Top && normalizedRootY < hint.Bottom)
            .OrderByDescending(hint => hint.Priority).FirstOrDefault();
        var regionLeft = clientBounds.Left + (int)Math.Round(rootWidth * (regionHint?.Left ?? 0));
        var regionTop = clientBounds.Top + (int)Math.Round(rootHeight * (regionHint?.Top ?? 0));
        var regionWidth = Math.Max(1, (int)Math.Round(rootWidth * ((regionHint?.Right ?? 1) - (regionHint?.Left ?? 0))));
        var regionHeight = Math.Max(1, (int)Math.Round(rootHeight * ((regionHint?.Bottom ?? 1) - (regionHint?.Top ?? 0))));
        var normalizedRegionX = Clamp01((point.X - regionLeft) / (double)regionWidth);
        var normalizedRegionY = Clamp01((point.Y - regionTop) / (double)regionHeight);
        return new InteractionHitTargetSnapshot
        {
            InsideTarget = insideTarget,
            WindowFromPointHwnd = fromPoint.ToInt64(),
            ChildWindowFromPointHwnd = child.ToInt64(),
            RealChildWindowFromPointHwnd = realChild.ToInt64(),
            PrimaryHwnd = primary.Hwnd,
            ParentHwnd = primary.ParentHwnd,
            NativeSignature = primary.NativeSignature,
            ClassName = primary.ClassName,
            ControlId = primary.ControlId,
            ScreenPoint = new() { X = point.X, Y = point.Y },
            RootClientPoint = new() { X = point.X - clientBounds.Left, Y = point.Y - clientBounds.Top },
            RegionRelativePoint = new() { X = point.X - regionLeft, Y = point.Y - regionTop },
            ParentClientPoint = new() { X = point.X - parent.Bounds.Left, Y = point.Y - parent.Bounds.Top },
            NormalizedRootX = normalizedRootX,
            NormalizedRootY = normalizedRootY,
            NormalizedRegionX = normalizedRegionX,
            NormalizedRegionY = normalizedRegionY,
            NormalizedParentX = Clamp01((point.X - parent.Bounds.Left) / (double)parentWidth),
            NormalizedParentY = Clamp01((point.Y - parent.Bounds.Top) / (double)parentHeight),
            SpatialRegion = regionHint?.Region ?? primary.SpatialRegion,
            CandidateHwnds = candidateHwnds,
            AncestorHwnds = primary.AncestorHwnds
        };
    }

    private static PassiveVisualSignature CaptureVisualSignature(ElementRectangle bounds, int columns, int rows)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0)
            return new() { Available = false, ErrorCode = "InvalidBounds", Columns = columns, Rows = rows, PixelDataStored = false };
        try
        {
            using var source = new Bitmap(bounds.Width, bounds.Height);
            using (var graphics = Graphics.FromImage(source))
                graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, source.Size, CopyPixelOperation.SourceCopy);
            using var reduced = new Bitmap(columns, rows);
            using (var graphics = Graphics.FromImage(reduced))
            {
                graphics.InterpolationMode = InterpolationMode.HighQualityBilinear;
                graphics.DrawImage(source, 0, 0, columns, rows);
            }
            var luminance = new List<int>(columns * rows);
            var blocks = new List<string>(columns * rows);
            for (var y = 0; y < rows; y++)
            for (var x = 0; x < columns; x++)
            {
                var color = reduced.GetPixel(x, y);
                var value = (color.R * 299 + color.G * 587 + color.B * 114) / 1000;
                luminance.Add(value);
                blocks.Add(Hash($"{color.R / 16:X1}{color.G / 16:X1}{color.B / 16:X1}")[..16]);
            }
            var average = luminance.Count == 0 ? 0 : luminance.Average();
            var bits = string.Concat(luminance.Select(value => value >= average ? '1' : '0'));
            return new()
            {
                Available = true,
                Columns = columns,
                Rows = rows,
                PerceptualHash = Hash(bits),
                BlockHashes = blocks,
                PixelDataStored = false
            };
        }
        catch
        {
            return new() { Available = false, ErrorCode = "VisualCaptureUnavailable", Columns = columns, Rows = rows, PixelDataStored = false };
        }
    }

    internal static InteractionHitTargetSnapshot ResolveHitFromInventory(NativeInteractionFrameSnapshot frame, CapturePoint point)
    {
        var root = frame.Windows.FirstOrDefault(window => window.Hwnd == frame.RootHwnd);
        var candidates = frame.Windows.Where(window => Contains(window.Bounds, point))
            .OrderBy(window => (long)Math.Max(1, window.Bounds.Width) * Math.Max(1, window.Bounds.Height))
            .ThenByDescending(window => window.Depth).ToArray();
        var primary = candidates.FirstOrDefault() ?? root;
        if (primary is null) return new() { InsideTarget = false, ScreenPoint = point };
        var parent = frame.Windows.FirstOrDefault(window => window.Hwnd == primary.ParentHwnd) ?? primary;
        var client = frame.RootClientBounds;
        var hints = frame.RegionHints.Count > 0 ? frame.RegionHints : DefaultRegions();
        var rootWidth = Math.Max(1, client.Width - 1);
        var rootHeight = Math.Max(1, client.Height - 1);
        var normalizedRootX = Clamp01((point.X - client.Left) / (double)rootWidth);
        var normalizedRootY = Clamp01((point.Y - client.Top) / (double)rootHeight);
        var regionHint = hints.Where(hint => normalizedRootX >= hint.Left && normalizedRootX < hint.Right &&
                normalizedRootY >= hint.Top && normalizedRootY < hint.Bottom)
            .OrderByDescending(hint => hint.Priority).FirstOrDefault();
        var regionLeft = client.Left + (int)Math.Round(rootWidth * (regionHint?.Left ?? 0));
        var regionTop = client.Top + (int)Math.Round(rootHeight * (regionHint?.Top ?? 0));
        var regionWidth = Math.Max(1, (int)Math.Round(rootWidth * ((regionHint?.Right ?? 1) - (regionHint?.Left ?? 0))));
        var regionHeight = Math.Max(1, (int)Math.Round(rootHeight * ((regionHint?.Bottom ?? 1) - (regionHint?.Top ?? 0))));
        return new()
        {
            InsideTarget = Contains(client, point) || candidates.Any(window => window.IsDescendant || window.IsOwnedPopup),
            PrimaryHwnd = primary.Hwnd,
            ParentHwnd = primary.ParentHwnd,
            NativeSignature = primary.NativeSignature,
            ClassName = primary.ClassName,
            ControlId = primary.ControlId,
            ScreenPoint = new() { X = point.X, Y = point.Y },
            RootClientPoint = new() { X = point.X - client.Left, Y = point.Y - client.Top },
            RegionRelativePoint = new() { X = point.X - regionLeft, Y = point.Y - regionTop },
            ParentClientPoint = new() { X = point.X - parent.Bounds.Left, Y = point.Y - parent.Bounds.Top },
            NormalizedRootX = normalizedRootX,
            NormalizedRootY = normalizedRootY,
            NormalizedRegionX = Clamp01((point.X - regionLeft) / (double)regionWidth),
            NormalizedRegionY = Clamp01((point.Y - regionTop) / (double)regionHeight),
            NormalizedParentX = Clamp01((point.X - parent.Bounds.Left) / (double)Math.Max(1, parent.Bounds.Width - 1)),
            NormalizedParentY = Clamp01((point.Y - parent.Bounds.Top) / (double)Math.Max(1, parent.Bounds.Height - 1)),
            SpatialRegion = regionHint?.Region ?? primary.SpatialRegion,
            CandidateHwnds = candidates.Select(window => window.Hwnd).ToArray(),
            AncestorHwnds = primary.AncestorHwnds
        };
    }

    private static IReadOnlyList<long> ReadAncestors(IntPtr hwnd, IntPtr root)
    {
        var values = new List<long>();
        var current = NativeMethods.GetParent(hwnd);
        while (current != IntPtr.Zero && values.Count < 64)
        {
            values.Insert(0, current.ToInt64());
            if (current == root) break;
            current = NativeMethods.GetParent(current);
        }
        return values;
    }

    private static bool IsOwnedByRoot(IntPtr hwnd, IntPtr root)
    {
        var current = NativeMethods.GetWindow(hwnd, GwOwner);
        var attempts = 0;
        while (current != IntPtr.Zero && attempts++ < 64)
        {
            if (current == root || NativeMethods.IsChild(root, current)) return true;
            current = NativeMethods.GetWindow(current, GwOwner);
        }
        return false;
    }

    private static long ReadFocus(uint threadId)
    {
        var info = new GuiThreadInfo { Size = Marshal.SizeOf<GuiThreadInfo>() };
        return NativeMethods.GetGUIThreadInfo(threadId, ref info) ? info.Focus.ToInt64() : 0;
    }

    private static ElementRectangle ReadWindowBounds(IntPtr hwnd)
    {
        NativeMethods.GetWindowRect(hwnd, out var rect);
        return new() { Left = rect.Left, Top = rect.Top, Right = rect.Right, Bottom = rect.Bottom };
    }

    private static ElementRectangle ReadClientScreenBounds(IntPtr hwnd)
    {
        NativeMethods.GetClientRect(hwnd, out var rect);
        var origin = new NativePoint();
        NativeMethods.ClientToScreen(hwnd, ref origin);
        return new() { Left = origin.X, Top = origin.Y, Right = origin.X + rect.Right - rect.Left, Bottom = origin.Y + rect.Bottom - rect.Top };
    }

    private static (string Hash, int Length) ReadRedactedTextMetadata(IntPtr hwnd, string className)
    {
        var length = Math.Clamp(NativeMethods.GetWindowTextLength(hwnd), 0, 4096);
        return (Hash($"{className}|{length}|length-only"), length);
    }

    private static string ReadClassName(IntPtr hwnd)
    {
        var value = new StringBuilder(256);
        NativeMethods.GetClassName(hwnd, value, value.Capacity);
        return value.ToString();
    }

    private static long ReadWindowLong(IntPtr hwnd, int index) => IntPtr.Size == 8
        ? NativeMethods.GetWindowLongPtr64(hwnd, index).ToInt64()
        : NativeMethods.GetWindowLong32(hwnd, index);

    private static NormalizedRectangle Normalize(ElementRectangle value, ElementRectangle root)
    {
        var width = Math.Max(1, root.Width);
        var height = Math.Max(1, root.Height);
        var left = Clamp01((value.Left - root.Left) / (double)width);
        var top = Clamp01((value.Top - root.Top) / (double)height);
        var right = Clamp01((value.Right - root.Left) / (double)width);
        var bottom = Clamp01((value.Bottom - root.Top) / (double)height);
        return new() { Left = left, Top = top, Right = right, Bottom = bottom, CenterX = (left + right) / 2, CenterY = (top + bottom) / 2 };
    }

    private static IReadOnlyList<LayoutRegionHint> DefaultRegions() =>
    [
        new() { Region = "GlobalHeader", Left = 0, Top = 0, Right = 1, Bottom = 0.12, Priority = 20 },
        new() { Region = "QuotePanel", Left = 0, Top = 0.12, Right = 0.5, Bottom = 0.62, Priority = 10 },
        new() { Region = "OrderEntryPanel", Left = 0.5, Top = 0.12, Right = 1, Bottom = 0.62, Priority = 10 },
        new() { Region = "TradeInfoPanel", Left = 0, Top = 0.62, Right = 1, Bottom = 1, Priority = 10 }
    ];

    private static string ClassifyRegion(IReadOnlyList<LayoutRegionHint> hints, NormalizedRectangle bounds) => hints
        .Where(hint => bounds.CenterX >= hint.Left && bounds.CenterX < hint.Right && bounds.CenterY >= hint.Top && bounds.CenterY < hint.Bottom)
        .OrderByDescending(hint => hint.Priority).Select(hint => hint.Region).FirstOrDefault() ?? "Unclassified";

    private static bool Contains(ElementRectangle rect, CapturePoint point) => rect.Width > 0 && rect.Height > 0 &&
        point.X >= rect.Left && point.X < rect.Right && point.Y >= rect.Top && point.Y < rect.Bottom;
    private static double Clamp01(double value) => Math.Max(0, Math.Min(1, value));
    private static string WindowFingerprintLine(NativeInteractionWindowSnapshot window) => string.Join("|",
        window.NativeSignature, window.ParentHwnd, window.OwnerHwnd, window.IsVisible, window.IsEnabled,
        window.Bounds.Left, window.Bounds.Top, window.Bounds.Right, window.Bounds.Bottom, window.NativeTextHash);
    internal static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct GuiThreadInfo
    {
        public int Size; public int Flags; public IntPtr Active; public IntPtr Focus; public IntPtr Capture;
        public IntPtr MenuOwner; public IntPtr MoveSize; public IntPtr Caret; public NativeRect CaretRect;
    }

    private delegate bool EnumWindowProc(IntPtr hwnd, IntPtr state);
    private static class NativeMethods
    {
        [DllImport("user32.dll")] internal static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern bool IsChild(IntPtr parent, IntPtr child);
        [DllImport("user32.dll")] internal static extern bool EnumChildWindows(IntPtr parent, EnumWindowProc callback, IntPtr state);
        [DllImport("user32.dll")] internal static extern bool EnumWindows(EnumWindowProc callback, IntPtr state);
        [DllImport("user32.dll")] internal static extern IntPtr GetParent(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern IntPtr GetWindow(IntPtr hwnd, uint command);
        [DllImport("user32.dll")] internal static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern bool IsWindowEnabled(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);
        [DllImport("user32.dll")] internal static extern bool GetClientRect(IntPtr hwnd, out NativeRect rect);
        [DllImport("user32.dll")] internal static extern bool ClientToScreen(IntPtr hwnd, ref NativePoint point);
        [DllImport("user32.dll")] internal static extern bool ScreenToClient(IntPtr hwnd, ref NativePoint point);
        [DllImport("user32.dll")] internal static extern IntPtr WindowFromPoint(NativePoint point);
        [DllImport("user32.dll")] internal static extern IntPtr ChildWindowFromPointEx(IntPtr parent, NativePoint point, uint flags);
        [DllImport("user32.dll")] internal static extern IntPtr RealChildWindowFromPoint(IntPtr parent, NativePoint point);
        [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll")] internal static extern bool GetGUIThreadInfo(uint threadId, ref GuiThreadInfo info);
        [DllImport("user32.dll")] internal static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern int GetDlgCtrlID(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetClassName(IntPtr hwnd, StringBuilder value, int count);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowTextLength(IntPtr hwnd);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")] internal static extern int GetWindowLong32(IntPtr hwnd, int index);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] internal static extern IntPtr GetWindowLongPtr64(IntPtr hwnd, int index);
    }
}

public static class PassiveInteractionAnalysis
{
    public static ObservedInteractionSnapshot CreateInteraction(int sequence, PassivePointerObservation pointerDown,
        PassivePointerObservation pointerUp, NativeInteractionFrameSnapshot preFrame,
        IReadOnlyList<NativeInteractionFrameSnapshot> postFrames, IReadOnlyList<PassiveWindowEventObservation> windowEvents,
        ObservedInteractionSnapshot? previousInteraction)
    {
        if (postFrames.Count == 0) throw new ArgumentException("At least one post frame is required.", nameof(postFrames));
        var finalFrame = postFrames[^1];
        var point = new CapturePoint { X = pointerUp.X, Y = pointerUp.Y };
        var hit = PassiveInteractionObservation.ResolveHitFromInventory(preFrame, point);
        var delta = CompareFrames(preFrame, postFrames, windowEvents);
        var suggestion = Suggest(hit, delta, windowEvents);
        var interactionId = $"interaction-{sequence:D4}-{PassiveInteractionObservation.Hash($"{pointerDown.ObservedAt:o}|{point.X}|{point.Y}")[..12]}";
        var doubleClick = previousInteraction is not null && previousInteraction.Button == pointerUp.Button &&
            (pointerDown.ObservedAt - previousInteraction.CompletedAt) <= TimeSpan.FromMilliseconds(500) &&
            Math.Abs(previousInteraction.ClickPoint.X - point.X) <= 4 && Math.Abs(previousInteraction.ClickPoint.Y - point.Y) <= 4;
        return new()
        {
            InteractionId = interactionId,
            Sequence = sequence,
            StartedAt = pointerDown.ObservedAt,
            CompletedAt = finalFrame.ObservedAt,
            Button = pointerUp.Button,
            DoubleClick = doubleClick,
            ClickPoint = point,
            HitTarget = hit,
            PreStateFingerprint = preFrame.StateFingerprint,
            PostStateFingerprint = finalFrame.StateFingerprint,
            PreFrameReference = $"snapshots/{interactionId}.pre.json",
            PostFrameReference = $"snapshots/{interactionId}.post.json",
            Delta = delta,
            WindowEvents = windowEvents.ToArray(),
            Suggestion = suggestion,
            ActionSentCount = 0,
            TransactionalActionCount = 0
        };
    }

    public static InteractionFrameDelta CompareFrames(NativeInteractionFrameSnapshot preFrame,
        IReadOnlyList<NativeInteractionFrameSnapshot> postFrames, IReadOnlyList<PassiveWindowEventObservation>? windowEvents = null)
    {
        var finalFrame = postFrames[^1];
        var before = preFrame.Windows.ToDictionary(window => window.Hwnd);
        var after = finalFrame.Windows.ToDictionary(window => window.Hwnd);
        var allPostHwnds = postFrames.SelectMany(frame => frame.Windows).Select(window => window.Hwnd).ToHashSet();
        var newHwnds = allPostHwnds.Except(before.Keys).OrderBy(value => value).ToArray();
        var disappeared = before.Keys.Except(after.Keys).OrderBy(value => value).ToArray();
        var allPostPopups = postFrames.SelectMany(frame => frame.PopupHwnds).ToHashSet();
        var popupCreated = allPostPopups.Except(preFrame.PopupHwnds).OrderBy(value => value).ToArray();
        var popupClosed = preFrame.PopupHwnds.Except(finalFrame.PopupHwnds).OrderBy(value => value).ToArray();
        var changes = new List<InteractionPropertyChange>();
        foreach (var hwnd in before.Keys.Intersect(after.Keys).OrderBy(value => value))
        {
            var left = before[hwnd]; var right = after[hwnd];
            AddChange(changes, hwnd, "visible", left.IsVisible, right.IsVisible);
            AddChange(changes, hwnd, "enabled", left.IsEnabled, right.IsEnabled);
            AddChange(changes, hwnd, "bounds", BoundsText(left.Bounds), BoundsText(right.Bounds));
            AddChange(changes, hwnd, "nativeTextMetadata", left.NativeTextHash, right.NativeTextHash);
        }
        var visual = postFrames.Select(frame => CompareVisual(preFrame.VisualSignature, frame.VisualSignature))
            .OrderByDescending(value => value.ChangedPixelRatioEstimate).FirstOrDefault() ?? new();
        var events = windowEvents ?? Array.Empty<PassiveWindowEventObservation>();
        var unstable = postFrames.Count >= 2 && !string.Equals(postFrames[^1].StateFingerprint,
            postFrames[^2].StateFingerprint, StringComparison.Ordinal);
        return new()
        {
            NewHwnds = newHwnds,
            DisappearedHwnds = disappeared,
            PopupCreatedHwnds = popupCreated,
            PopupClosedHwnds = popupClosed,
            Changes = changes,
            ForegroundChanged = preFrame.ForegroundHwnd != finalFrame.ForegroundHwnd,
            FocusChanged = preFrame.FocusHwnd != finalFrame.FocusHwnd,
            StateFingerprintChanged = !string.Equals(preFrame.StateFingerprint, finalFrame.StateFingerprint, StringComparison.Ordinal),
            SelectionEventObserved = events.Any(value => value.EventName.StartsWith("Selection", StringComparison.Ordinal)),
            UnstablePostState = unstable,
            VisualDiff = visual
        };
    }

    public static IReadOnlyList<InteractionZoneCandidate> Cluster(IReadOnlyList<ObservedInteractionSnapshot> interactions,
        double distanceThreshold = 0.04)
    {
        var threshold = Math.Clamp(distanceThreshold, 0.005, 0.25);
        var clusters = new List<List<ObservedInteractionSnapshot>>();
        foreach (var interaction in interactions.Where(value => value.HitTarget.InsideTarget))
        {
            var match = clusters.FirstOrDefault(cluster =>
            {
                var first = cluster[0];
                if (first.HitTarget.ParentHwnd != interaction.HitTarget.ParentHwnd ||
                    !string.Equals(first.HitTarget.NativeSignature, interaction.HitTarget.NativeSignature, StringComparison.Ordinal) ||
                    !string.Equals(first.HitTarget.SpatialRegion, interaction.HitTarget.SpatialRegion, StringComparison.Ordinal)) return false;
                var centerX = cluster.Average(value => value.HitTarget.NormalizedParentX);
                var centerY = cluster.Average(value => value.HitTarget.NormalizedParentY);
                return Distance(centerX, centerY, interaction.HitTarget.NormalizedParentX, interaction.HitTarget.NormalizedParentY) <= threshold;
            });
            if (match is null) clusters.Add([interaction]); else match.Add(interaction);
        }

        return clusters.Select((cluster, index) => new InteractionZoneCandidate
        {
            ZoneId = $"zone-{index + 1:D3}-{PassiveInteractionObservation.Hash(string.Join("|", cluster.Select(value => value.InteractionId)))[..10]}",
            ParentHwnd = cluster[0].HitTarget.ParentHwnd,
            NativeSignature = cluster[0].HitTarget.NativeSignature,
            ClassName = cluster[0].HitTarget.ClassName,
            SpatialRegion = cluster[0].HitTarget.SpatialRegion,
            CenterX = cluster.Average(value => value.HitTarget.NormalizedParentX),
            CenterY = cluster.Average(value => value.HitTarget.NormalizedParentY),
            ObservationCount = cluster.Count,
            RoleSuggestion = cluster.GroupBy(value => value.Suggestion.InferredRole).OrderByDescending(group => group.Count()).First().Key,
            ActionKindSuggestion = cluster.GroupBy(value => value.Suggestion.InferredActionKind).OrderByDescending(group => group.Count()).First().Key,
            Confidence = cluster.Average(value => value.Suggestion.Confidence),
            AutomaticallyApproved = false,
            Executable = false,
            InteractionIds = cluster.Select(value => value.InteractionId).ToArray()
        }).ToArray();
    }

    private static InteractionSuggestion Suggest(InteractionHitTargetSnapshot hit, InteractionFrameDelta delta,
        IReadOnlyList<PassiveWindowEventObservation> events)
    {
        var evidence = new List<string> { $"region={hit.SpatialRegion}", $"class={hit.ClassName}", $"hwnd={hit.PrimaryHwnd}" };
        if (delta.PopupCreatedHwnds.Count > 0 || events.Any(value => value.EventName == "Show"))
        {
            evidence.Add("popup-or-show-event");
            return new() { InferredRole = "dropdown/combo", InferredActionKind = "ExpandOrSelect", Confidence = 0.85, Ambiguous = false, Evidence = evidence };
        }
        if (delta.SelectionEventObserved)
        {
            evidence.Add("selection-event");
            return new() { InferredRole = hit.SpatialRegion == "TradeInfoPanel" ? "bottom-info-tab" : "other-selectable-control", InferredActionKind = "Select", Confidence = 0.78, Ambiguous = true, Evidence = evidence };
        }
        if (hit.SpatialRegion == "GlobalHeader" || hit.NormalizedRootY <= 0.15)
        {
            var role = hit.NormalizedRootX < 1.0 / 3 ? "top-region:left" : hit.NormalizedRootX < 2.0 / 3 ? "top-region:center" : "top-region:right";
            evidence.Add("top-band-position");
            return new() { InferredRole = role, InferredActionKind = "Select", Confidence = 0.58, Ambiguous = true, Evidence = evidence };
        }
        if (hit.SpatialRegion == "TradeInfoPanel")
        {
            var grid = hit.ClassName.Contains("Grid", StringComparison.OrdinalIgnoreCase) || hit.ClassName.Contains("List", StringComparison.OrdinalIgnoreCase);
            evidence.Add(grid ? "grid-class" : "bottom-region");
            return new() { InferredRole = grid ? "result-grid" : "bottom-info-tab", InferredActionKind = grid ? "SelectRow" : "Select", Confidence = grid ? 0.76 : 0.61, Ambiguous = !grid, Evidence = evidence };
        }
        if (hit.ClassName.Contains("Combo", StringComparison.OrdinalIgnoreCase))
            return new() { InferredRole = "price-type", InferredActionKind = "ExpandOrSelect", Confidence = 0.7, Ambiguous = true, Evidence = evidence };
        if (hit.ClassName.Contains("Edit", StringComparison.OrdinalIgnoreCase) || delta.FocusChanged)
            return new() { InferredRole = "quantity-input", InferredActionKind = "Focus", Confidence = 0.45, Ambiguous = true, Evidence = evidence };
        if (hit.ClassName.Contains("Button", StringComparison.OrdinalIgnoreCase) && hit.SpatialRegion == "OrderEntryPanel")
        {
            evidence.Add("order-entry-button-risk");
            return new() { InferredRole = "submit-candidate", InferredActionKind = "ObserveClick", Confidence = 0.4, Ambiguous = true, TransactionalRiskCandidate = true, Evidence = evidence };
        }
        return new() { InferredRole = "other-selectable-control", InferredActionKind = "ObserveClick", Confidence = delta.StateFingerprintChanged ? 0.5 : 0.3, Ambiguous = true, Evidence = evidence };
    }

    private static InteractionVisualDiff CompareVisual(PassiveVisualSignature before, PassiveVisualSignature after)
    {
        if (!before.Available || !after.Available || before.Columns != after.Columns || before.Rows != after.Rows ||
            before.BlockHashes.Count != after.BlockHashes.Count || before.BlockHashes.Count == 0) return new() { Available = false };
        var changed = new List<int>();
        for (var index = 0; index < before.BlockHashes.Count; index++)
            if (!string.Equals(before.BlockHashes[index], after.BlockHashes[index], StringComparison.Ordinal)) changed.Add(index);
        if (changed.Count == 0)
            return new() { Available = true, TotalBlockCount = before.BlockHashes.Count, BeforePerceptualHash = before.PerceptualHash, AfterPerceptualHash = after.PerceptualHash };
        var xs = changed.Select(index => index % before.Columns).ToArray();
        var ys = changed.Select(index => index / before.Columns).ToArray();
        return new()
        {
            Available = true,
            ChangedBlockCount = changed.Count,
            TotalBlockCount = before.BlockHashes.Count,
            ChangedPixelRatioEstimate = changed.Count / (double)before.BlockHashes.Count,
            ChangedRectangle = new()
            {
                Left = xs.Min() / (double)before.Columns,
                Top = ys.Min() / (double)before.Rows,
                Right = (xs.Max() + 1) / (double)before.Columns,
                Bottom = (ys.Max() + 1) / (double)before.Rows,
                CenterX = (xs.Min() + xs.Max() + 1) / (2.0 * before.Columns),
                CenterY = (ys.Min() + ys.Max() + 1) / (2.0 * before.Rows)
            },
            BeforePerceptualHash = before.PerceptualHash,
            AfterPerceptualHash = after.PerceptualHash
        };
    }

    private static void AddChange(List<InteractionPropertyChange> changes, long hwnd, string property, object before, object after)
    {
        var left = Convert.ToString(before, CultureInfo.InvariantCulture) ?? string.Empty;
        var right = Convert.ToString(after, CultureInfo.InvariantCulture) ?? string.Empty;
        if (!string.Equals(left, right, StringComparison.Ordinal)) changes.Add(new() { Hwnd = hwnd, Property = property, Before = left, After = right });
    }
    private static string BoundsText(ElementRectangle value) => $"{value.Left},{value.Top},{value.Right},{value.Bottom}";
    private static double Distance(double x1, double y1, double x2, double y2) => Math.Sqrt(Math.Pow(x1 - x2, 2) + Math.Pow(y1 - y2, 2));
}
