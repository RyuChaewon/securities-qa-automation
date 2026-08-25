// Bounded redacted read-only UIA traversal for discovery evidence.
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using FlaUI.Core.AutomationElements;

namespace HtsQa.FlaUi;

public sealed partial class FlaUiAutomationEngine
{
    private sealed record LayoutNode(AutomationElement Element, string ParentId, int Depth, int SiblingIndex,
        IReadOnlyList<string> Ancestors, string ContainerId);

    /// <summary>Reads a bounded UIA tree without sending focus, input, invoke, selection, or pointer actions.</summary>
    public BridgeResponse DiscoverLayout(BridgeRequest request)
    {
        if (request.TimeoutMs <= 0 || request.MaxDepth < 0 || request.MaxElements <= 0)
            return BridgeResponse.Failure(request, "LAYOUT_LIMIT_INVALID", "timeout, maxDepth and maxElements must be positive bounded values.");

        try
        {
            var root = GetRoot(request);
            var rootBounds = Bounds(root);
            var dpi = ReadDpi(request.RootHwnd);
            var processId = SafeRead(() => root.Properties.ProcessId.ValueOrDefault, 0);
            var processName = SafeRead(() => Process.GetProcessById(processId).ProcessName, string.Empty);
            var fingerprint = Sha256(string.Join("|", processName,
                SafeRead(() => root.AutomationId ?? string.Empty, string.Empty),
                SafeRead(() => root.ClassName ?? string.Empty, string.Empty),
                SafeRead(() => root.FrameworkType.ToString(), string.Empty), dpi,
                rootBounds.Width, rootBounds.Height));
            var stopwatch = Stopwatch.StartNew();
            var elements = new List<LayoutElementSnapshot>();
            var diagnostics = new List<string>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var queue = new Queue<LayoutNode>();
            var providerErrors = 0;
            var duplicates = 0;
            var visited = 0;
            var truncated = false;
            var truncationReason = string.Empty;

            AutomationElement[] rootChildren;
            try { rootChildren = root.FindAllChildren(); }
            catch (Exception exception)
            {
                return BridgeResponse.Failure(request, "UIA3_LAYOUT_ROOT_TRAVERSAL_FAILED", exception.Message);
            }
            for (var index = 0; index < rootChildren.Length; index++)
                queue.Enqueue(new(rootChildren[index], string.Empty, 0, index, Array.Empty<string>(), string.Empty));

            while (queue.Count > 0)
            {
                if (stopwatch.ElapsedMilliseconds >= request.TimeoutMs)
                {
                    truncated = true;
                    truncationReason = "Timeout";
                    break;
                }
                if (visited >= request.MaxElements)
                {
                    truncated = true;
                    truncationReason = "MaxElements";
                    break;
                }

                var node = queue.Dequeue();
                visited++;
                AutomationElement[] children;
                try { children = node.Depth <= request.MaxDepth ? node.Element.FindAllChildren() : Array.Empty<AutomationElement>(); }
                catch (Exception exception)
                {
                    providerErrors++;
                    diagnostics.Add($"element[{visited}].children:{exception.GetType().Name}");
                    children = Array.Empty<AutomationElement>();
                }
                if (node.Depth >= request.MaxDepth && children.Length > 0)
                {
                    truncated = true;
                    truncationReason = "MaxDepth";
                }

                LayoutElementSnapshot? snapshot;
                try
                {
                    snapshot = CreateLayoutSnapshot(request, node, children.Length, rootBounds, dpi, processId, processName, fingerprint);
                }
                catch (Exception exception)
                {
                    providerErrors++;
                    diagnostics.Add($"element[{visited}].snapshot:{exception.GetType().Name}");
                    snapshot = null;
                }

                var elementId = snapshot?.ElementId ?? $"layout-{visited:D6}";
                var nextAncestors = node.Ancestors.Concat(new[] { elementId }).ToArray();
                var nextContainer = snapshot is not null && IsContainer(snapshot.ControlType) ? elementId : node.ContainerId;
                if (node.Depth < request.MaxDepth)
                {
                    for (var index = 0; index < children.Length; index++)
                        queue.Enqueue(new(children[index], elementId, node.Depth + 1, index, nextAncestors, nextContainer));
                }

                if (snapshot is null) continue;
                var duplicateKey = DuplicateKey(snapshot);
                if (!seen.Add(duplicateKey))
                {
                    duplicates++;
                    continue;
                }
                var visible = snapshot.ScreenBounds.Width > 0 && snapshot.ScreenBounds.Height > 0;
                if (!request.IncludeOffscreen && snapshot.IsOffscreen) continue;
                if (!request.IncludeInvisible && !visible) continue;
                if (!request.IncludeContainers && !snapshot.IsActionable) continue;
                elements.Add(snapshot);
            }

            var knownHwnds = elements.Where(element => element.NativeWindowHandle != 0)
                .GroupBy(element => element.NativeWindowHandle)
                .ToDictionary(group => group.Key, group => group.First().ElementId);
            var nativeElements = DiscoverNativeLayout(request, rootBounds, dpi, processId, processName, fingerprint,
                knownHwnds, Math.Max(0, request.MaxElements - visited))
                .Where(element => request.IncludeOffscreen || !element.IsOffscreen)
                .Where(element => request.IncludeInvisible || element.ScreenBounds.Width > 0 && element.ScreenBounds.Height > 0)
                .Where(element => request.IncludeContainers || element.IsActionable)
                .ToArray();
            if (nativeElements.Length > 0)
            {
                elements.AddRange(nativeElements);
                visited += nativeElements.Length;
                diagnostics.Add($"nativeFallback:{nativeElements.Length}");
            }

            var discovery = new LayoutDiscoverySnapshot
            {
                RootHwnd = request.RootHwnd,
                ProcessId = processId,
                ProcessName = processName,
                WindowFingerprint = fingerprint,
                RootBounds = rootBounds,
                Dpi = dpi,
                ObservedAt = DateTimeOffset.UtcNow,
                Truncated = truncated,
                TruncationReason = truncationReason,
                ProviderErrorCount = providerErrors,
                DuplicateCount = duplicates,
                VisitedCount = visited,
                IncludedCount = elements.Count,
                ActionSentCount = 0,
                TransactionalActionCount = 0,
                ProviderDiagnostics = diagnostics.Take(100).ToArray(),
                Elements = elements
            };
            return new BridgeResponse
            {
                RequestId = request.RequestId,
                Success = true,
                Verified = true,
                ActionSent = false,
                ActionVerified = false,
                Message = $"Read-only layout discovery observed {elements.Count} elements.",
                LayoutDiscovery = discovery
            };
        }
        catch (Exception exception)
        {
            return BridgeResponse.Failure(request, "UIA3_LAYOUT_DISCOVERY_FAILED", exception.Message);
        }
    }

    private LayoutElementSnapshot CreateLayoutSnapshot(BridgeRequest request, LayoutNode node, int childCount,
        ElementRectangle rootBounds, uint dpi, int processId, string processName, string fingerprint)
    {
        var element = node.Element;
        var bounds = Bounds(element);
        var runtimeId = RuntimeId(element);
        var automationId = SafeRead(() => element.AutomationId ?? string.Empty, string.Empty);
        var rawName = SafeRead(() => element.Name ?? string.Empty, string.Empty);
        var className = SafeRead(() => element.ClassName ?? string.Empty, string.Empty);
        var controlType = NormalizeControlType(SafeRead(() => element.ControlType.ToString(), string.Empty));
        var nativeHwnd = NativeWindowHandle(element);
        var password = IsPassword(element);
        var sensitiveKind = MatchSensitiveKind(request.SensitiveControlHints, automationId, rawName, className, controlType, password);
        var sensitive = password || sensitiveKind.Length > 0;
        var value = (Available: false, Value: string.Empty);
        if (request.IncludeValueMetadata && !sensitive) value = TryReadValue(element);
        var normalized = Normalize(bounds, rootBounds);
        var patterns = GetSupportedActions(element);
        var actionable = SafeRead(() => element.IsEnabled, false) &&
                         !SafeRead(() => element.IsOffscreen, true) &&
                         bounds.Width >= 4 && bounds.Height >= 4 &&
                         (ActionableControlTypes.Contains(controlType) || patterns.Count > 0);
        var identity = runtimeId.Length > 0 ? $"runtime:{runtimeId}" :
            nativeHwnd != 0 ? $"hwnd:{nativeHwnd}" :
            $"uia:{automationId}|{className}|{controlType}|{bounds.Left}|{bounds.Top}";
        var id = $"layout-{Sha256(identity)[..16]}";
        var observedValue = request.IncludeCurrentValues && !sensitive && value.Available ? value.Value : null;

        return new LayoutElementSnapshot
        {
            ElementId = id,
            ParentElementId = node.ParentId,
            Depth = node.Depth,
            SiblingIndex = node.SiblingIndex,
            ChildCount = childCount,
            AncestorElementIds = node.Ancestors,
            ContainerElementId = node.ContainerId,
            OwnerRootHwnd = request.RootHwnd,
            NativeWindowHandle = nativeHwnd,
            RuntimeId = runtimeId,
            AutomationId = automationId,
            RedactedName = RedactName(rawName, sensitive),
            ClassName = className,
            ControlType = controlType,
            FrameworkType = SafeRead(() => element.FrameworkType.ToString(), string.Empty),
            IsEnabled = SafeRead(() => element.IsEnabled, false),
            IsOffscreen = SafeRead(() => element.IsOffscreen, true),
            IsKeyboardFocusable = SafeRead(() => element.Properties.IsKeyboardFocusable.ValueOrDefault, false),
            IsKeyboardFocused = SafeRead(() => element.Properties.HasKeyboardFocus.ValueOrDefault, false),
            IsActionable = actionable,
            SupportedPatterns = patterns,
            ScreenBounds = bounds,
            ClientBounds = new() { Left = bounds.Left - rootBounds.Left, Top = bounds.Top - rootBounds.Top,
                Right = bounds.Right - rootBounds.Left, Bottom = bounds.Bottom - rootBounds.Top },
            NormalizedBounds = normalized,
            Center = new() { X = bounds.Left + bounds.Width / 2, Y = bounds.Top + bounds.Height / 2 },
            Dpi = dpi,
            ProcessId = processId,
            ProcessName = processName,
            WindowFingerprint = fingerprint,
            MapRuntimeCandidate = automationId.Length > 0 ? $"AutomationId:{automationId}" : runtimeId.Length > 0 ? $"RuntimeId:{runtimeId}" : string.Empty,
            SpatialRegion = ClassifyRegion(request.RegionHints, normalized, nativeHwnd, request.RootHwnd),
            ValuePresent = value.Available && value.Value.Length > 0,
            ValueMasked = sensitive || (!request.IncludeCurrentValues && value.Available && value.Value.Length > 0),
            ValueReadable = !sensitive && value.Available,
            ValueLength = value.Available && !sensitive ? value.Value.Length : null,
            ObservedValue = observedValue,
            IsPassword = password,
            SensitiveKind = sensitiveKind,
            RedactionReason = sensitive ? (password ? "UIA.IsPassword" : "TargetSensitiveHint") :
                observedValue is null && value.Available ? "CurrentValuesExcluded" : string.Empty,
            Warnings = nativeHwnd == 0 ? new[] { "NoNativeWindowHandle" } : Array.Empty<string>()
        };
    }

    private static string MatchSensitiveKind(IReadOnlyList<SensitiveControlHint> hints, string automationId,
        string name, string className, string controlType, bool password)
    {
        if (password) return "Password";
        foreach (var hint in hints)
        {
            if (hint.AutomationId.Length > 0 && !string.Equals(hint.AutomationId, automationId, StringComparison.Ordinal)) continue;
            if (hint.ClassName.Length > 0 && !string.Equals(hint.ClassName, className, StringComparison.Ordinal)) continue;
            if (hint.ControlType.Length > 0 && !string.Equals(hint.ControlType, controlType, StringComparison.OrdinalIgnoreCase)) continue;
            if (hint.NamePattern.Length > 0 && !Regex.IsMatch(name, hint.NamePattern, RegexOptions.IgnoreCase, TimeSpan.FromMilliseconds(100))) continue;
            return hint.SensitiveKind.Length > 0 ? hint.SensitiveKind : "Sensitive";
        }
        return Regex.IsMatch(name, "(password|passwd|account|customer|user.?id|token|auth|비밀번호|계좌|고객|사용자|인증)",
            RegexOptions.IgnoreCase, TimeSpan.FromMilliseconds(100)) ? "SensitiveCandidate" : string.Empty;
    }

    private static string RedactName(string value, bool sensitive)
    {
        if (sensitive && value.Length > 0) return "[REDACTED]";
        var redacted = Regex.Replace(value, @"(?<!\d)\d{4,}(?!\d)", "[REDACTED]");
        redacted = Regex.Replace(redacted, @"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+", "[REDACTED]");
        return redacted.Length <= 256 ? redacted : redacted[..256];
    }

    private static NormalizedRectangle Normalize(ElementRectangle value, ElementRectangle root)
    {
        double X(int x) => root.Width <= 0 ? 0 : Math.Clamp((double)(x - root.Left) / root.Width, 0, 1);
        double Y(int y) => root.Height <= 0 ? 0 : Math.Clamp((double)(y - root.Top) / root.Height, 0, 1);
        var left = X(value.Left); var right = X(value.Right); var top = Y(value.Top); var bottom = Y(value.Bottom);
        return new() { Left = left, Top = top, Right = right, Bottom = bottom,
            CenterX = (left + right) / 2, CenterY = (top + bottom) / 2 };
    }

    private static string ClassifyRegion(IReadOnlyList<LayoutRegionHint> hints, NormalizedRectangle bounds, long nativeHwnd, long rootHwnd)
    {
        var hint = hints.Where(candidate => bounds.CenterX >= candidate.Left && bounds.CenterX < candidate.Right &&
                                           bounds.CenterY >= candidate.Top && bounds.CenterY < candidate.Bottom)
            .OrderByDescending(candidate => candidate.Priority).FirstOrDefault();
        if (hint is not null) return hint.Region;
        if (nativeHwnd != 0 && nativeHwnd != rootHwnd) return "PopupOrOverlay";
        if (bounds.CenterY < 0.12) return "GlobalHeader";
        if (bounds.CenterY >= 0.62) return "TradeInfoPanel";
        if (bounds.CenterX < 0.5) return "QuotePanel";
        if (bounds.CenterY < 0.62) return "OrderEntryPanel";
        return "Unclassified";
    }

    private static bool IsContainer(string controlType) => controlType is "Window" or "Pane" or "Group" or "Tab" or "Table" or "List";

    private static string DuplicateKey(LayoutElementSnapshot snapshot) => snapshot.RuntimeId.Length > 0
        ? $"runtime:{snapshot.RuntimeId}"
        : $"{snapshot.NativeWindowHandle}|{snapshot.AutomationId}|{snapshot.ClassName}|{snapshot.ControlType}|{snapshot.ScreenBounds.Left}|{snapshot.ScreenBounds.Top}|{snapshot.ScreenBounds.Right}|{snapshot.ScreenBounds.Bottom}";
}
