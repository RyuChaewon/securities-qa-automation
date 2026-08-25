// Read-only Win32 child HWND supplement when an owner-drawn provider exposes no UIA descendants.
using System.Runtime.InteropServices;
using System.Text;

namespace HtsQa.FlaUi;

public sealed partial class FlaUiAutomationEngine
{
    private IReadOnlyList<LayoutElementSnapshot> DiscoverNativeLayout(BridgeRequest request, ElementRectangle rootBounds,
        uint dpi, int processId, string processName, string fingerprint, IReadOnlyDictionary<long,string> knownHwnds,
        int remaining)
    {
        if (!OperatingSystem.IsWindows() || remaining <= 0) return Array.Empty<LayoutElementSnapshot>();
        var handles = new List<long> { request.RootHwnd };
        NativeLayoutMethods.EnumChildWindows(new IntPtr(request.RootHwnd), (hwnd, _) =>
        {
            if (handles.Count < remaining) handles.Add(hwnd.ToInt64());
            return handles.Count < remaining;
        }, IntPtr.Zero);
        var newHandles = handles.Where(hwnd => hwnd != 0 && !knownHwnds.ContainsKey(hwnd)).Distinct().ToArray();
        var ids = knownHwnds.ToDictionary(pair => pair.Key, pair => pair.Value);
        foreach (var hwnd in newHandles) ids[hwnd] = $"layout-{Sha256($"hwnd:{hwnd}")[..16]}";
        var siblings = new Dictionary<long,int>();
        var result = new List<LayoutElementSnapshot>();
        foreach (var hwnd in newHandles)
        {
            var parent = NativeLayoutMethods.GetParent(new IntPtr(hwnd)).ToInt64();
            var siblingIndex = siblings.TryGetValue(parent, out var count) ? count : 0;
            siblings[parent] = siblingIndex + 1;
            var bounds = ReadNativeBounds(hwnd);
            var normalized = Normalize(bounds, rootBounds);
            var title = ReadNativeText(hwnd);
            var className = ReadNativeClass(hwnd);
            var sensitiveKind = MatchSensitiveKind(request.SensitiveControlHints, string.Empty, title, className, "NativeWindow", false);
            var parentId = parent == request.RootHwnd ? string.Empty : ids.GetValueOrDefault(parent, string.Empty);
            var owner = NativeLayoutMethods.GetWindow(new IntPtr(hwnd), 4).ToInt64();
            var depth = hwnd == request.RootHwnd ? 0 : NativeDepth(hwnd, request.RootHwnd);
            result.Add(new LayoutElementSnapshot
            {
                ElementId = ids[hwnd],
                ParentElementId = parentId,
                Depth = depth,
                SiblingIndex = siblingIndex,
                ChildCount = 0,
                AncestorElementIds = NativeAncestors(parent, request.RootHwnd, ids),
                ContainerElementId = parentId,
                OwnerRootHwnd = owner != 0 ? owner : request.RootHwnd,
                NativeWindowHandle = hwnd,
                RedactedName = RedactName(title, sensitiveKind.Length > 0),
                ClassName = className,
                ControlType = "NativeWindow",
                FrameworkType = "Win32",
                IsEnabled = NativeLayoutMethods.IsWindowEnabled(new IntPtr(hwnd)),
                IsOffscreen = !NativeLayoutMethods.IsWindowVisible(new IntPtr(hwnd)),
                IsActionable = false,
                ScreenBounds = bounds,
                ClientBounds = new() { Left = bounds.Left - rootBounds.Left, Top = bounds.Top - rootBounds.Top,
                    Right = bounds.Right - rootBounds.Left, Bottom = bounds.Bottom - rootBounds.Top },
                NormalizedBounds = normalized,
                Center = new() { X = bounds.Left + bounds.Width / 2, Y = bounds.Top + bounds.Height / 2 },
                Dpi = dpi,
                ProcessId = processId,
                ProcessName = processName,
                WindowFingerprint = fingerprint,
                SpatialRegion = ClassifyRegion(request.RegionHints, normalized, owner, request.RootHwnd),
                ValueMasked = sensitiveKind.Length > 0,
                SensitiveKind = sensitiveKind,
                RedactionReason = sensitiveKind.Length > 0 ? "TargetSensitiveHint" : "NativeWindowTextOnly",
                Status = "ObservedNativeFallback",
                Warnings = new[] { "UIAIdentityUnavailable", "ObservationOnly" }
            });
        }
        return result;
    }

    private static int NativeDepth(long hwnd, long root)
    {
        var depth = 0; var current = hwnd;
        while (depth < 64)
        {
            var parent = NativeLayoutMethods.GetParent(new IntPtr(current)).ToInt64();
            if (parent == 0 || parent == root) return depth;
            depth++; current = parent;
        }
        return depth;
    }

    private static IReadOnlyList<string> NativeAncestors(long parent, long root, IReadOnlyDictionary<long,string> ids)
    {
        var values = new List<string>(); var current = parent;
        while (current != 0 && current != root && values.Count < 64)
        {
            if (ids.TryGetValue(current, out var id)) values.Insert(0, id);
            current = NativeLayoutMethods.GetParent(new IntPtr(current)).ToInt64();
        }
        return values;
    }

    private static string ReadNativeText(long hwnd)
    {
        var value = new StringBuilder(512); NativeLayoutMethods.GetWindowText(new IntPtr(hwnd), value, value.Capacity); return value.ToString();
    }
    private static string ReadNativeClass(long hwnd)
    {
        var value = new StringBuilder(256); NativeLayoutMethods.GetClassName(new IntPtr(hwnd), value, value.Capacity); return value.ToString();
    }
    private static ElementRectangle ReadNativeBounds(long hwnd)
    {
        NativeLayoutMethods.GetWindowRect(new IntPtr(hwnd), out var value);
        return new() { Left=value.Left,Top=value.Top,Right=value.Right,Bottom=value.Bottom };
    }

    private static class NativeLayoutMethods
    {
        internal delegate bool EnumProc(IntPtr hwnd, IntPtr state);
        [DllImport("user32.dll")] internal static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr state);
        [DllImport("user32.dll")] internal static extern IntPtr GetParent(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern IntPtr GetWindow(IntPtr hwnd, uint command);
        [DllImport("user32.dll")] internal static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern bool IsWindowEnabled(IntPtr hwnd);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] internal static extern int GetWindowText(IntPtr hwnd, StringBuilder value, int count);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] internal static extern int GetClassName(IntPtr hwnd, StringBuilder value, int count);
        [DllImport("user32.dll")] internal static extern bool GetWindowRect(IntPtr hwnd, out NativeRect value);
        [StructLayout(LayoutKind.Sequential)] internal struct NativeRect { internal int Left,Top,Right,Bottom; }
    }
}
