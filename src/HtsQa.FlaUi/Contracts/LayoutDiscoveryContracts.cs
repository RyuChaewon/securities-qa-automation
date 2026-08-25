// Read-only full UIA layout discovery contracts; never canonical test results.
namespace HtsQa.FlaUi;

public sealed class LayoutRegionHint
{
    public string Region { get; set; } = "Unclassified";
    public double Left { get; set; }
    public double Top { get; set; }
    public double Right { get; set; }
    public double Bottom { get; set; }
    public int Priority { get; set; }
}

public sealed class SensitiveControlHint
{
    public string AutomationId { get; set; } = string.Empty;
    public string NamePattern { get; set; } = string.Empty;
    public string ClassName { get; set; } = string.Empty;
    public string ControlType { get; set; } = string.Empty;
    public string SensitiveKind { get; set; } = "Sensitive";
}

public sealed class NormalizedRectangle
{
    public double Left { get; set; }
    public double Top { get; set; }
    public double Right { get; set; }
    public double Bottom { get; set; }
    public double CenterX { get; set; }
    public double CenterY { get; set; }
}

public sealed class LayoutElementSnapshot
{
    public string ElementId { get; set; } = string.Empty;
    public string ParentElementId { get; set; } = string.Empty;
    public int Depth { get; set; }
    public int SiblingIndex { get; set; }
    public int ChildCount { get; set; }
    public IReadOnlyList<string> AncestorElementIds { get; set; } = Array.Empty<string>();
    public string ContainerElementId { get; set; } = string.Empty;
    public long OwnerRootHwnd { get; set; }
    public long NativeWindowHandle { get; set; }
    public string RuntimeId { get; set; } = string.Empty;
    public string AutomationId { get; set; } = string.Empty;
    public string RedactedName { get; set; } = string.Empty;
    public string ClassName { get; set; } = string.Empty;
    public string ControlType { get; set; } = string.Empty;
    public string FrameworkType { get; set; } = string.Empty;
    public bool IsEnabled { get; set; }
    public bool IsOffscreen { get; set; }
    public bool IsKeyboardFocusable { get; set; }
    public bool IsKeyboardFocused { get; set; }
    public bool IsActionable { get; set; }
    public IReadOnlyList<string> SupportedPatterns { get; set; } = Array.Empty<string>();
    public ElementRectangle ScreenBounds { get; set; } = new();
    public ElementRectangle ClientBounds { get; set; } = new();
    public NormalizedRectangle NormalizedBounds { get; set; } = new();
    public CapturePoint Center { get; set; } = new();
    public uint Dpi { get; set; }
    public int ProcessId { get; set; }
    public string ProcessName { get; set; } = string.Empty;
    public string WindowFingerprint { get; set; } = string.Empty;
    public string MapRuntimeCandidate { get; set; } = string.Empty;
    public string SpatialRegion { get; set; } = "Unclassified";
    public bool ValuePresent { get; set; }
    public bool ValueMasked { get; set; }
    public bool ValueReadable { get; set; }
    public int? ValueLength { get; set; }
    public string? ObservedValue { get; set; }
    public bool IsPassword { get; set; }
    public string SensitiveKind { get; set; } = string.Empty;
    public string RedactionReason { get; set; } = string.Empty;
    public string Status { get; set; } = "Observed";
    public IReadOnlyList<string> Warnings { get; set; } = Array.Empty<string>();
}

public sealed class LayoutDiscoverySnapshot
{
    public string SchemaVersion { get; set; } = "1.0";
    public string ArtifactRole { get; set; } = "Discovery";
    public bool VerdictEligible { get; set; }
    public bool TestExecution { get; set; }
    public bool ResultEvaluatorInvoked { get; set; }
    public string? ScenarioId { get; set; }
    public string? CaseId { get; set; }
    public string? CanonicalVerdict { get; set; }
    public string ExecutionStatus { get; set; } = "NotExecuted";
    public string VerdictStatus { get; set; } = "NoCanonicalVerdict";
    public string EvaluatorStatus { get; set; } = "ResultEvaluatorNotInvoked";
    public long RootHwnd { get; set; }
    public int ProcessId { get; set; }
    public string ProcessName { get; set; } = string.Empty;
    public string WindowFingerprint { get; set; } = string.Empty;
    public ElementRectangle RootBounds { get; set; } = new();
    public uint Dpi { get; set; }
    public DateTimeOffset ObservedAt { get; set; }
    public bool Truncated { get; set; }
    public string TruncationReason { get; set; } = string.Empty;
    public int ProviderErrorCount { get; set; }
    public int DuplicateCount { get; set; }
    public int VisitedCount { get; set; }
    public int IncludedCount { get; set; }
    public int ActionSentCount { get; set; }
    public int TransactionalActionCount { get; set; }
    public IReadOnlyList<string> ProviderDiagnostics { get; set; } = Array.Empty<string>();
    public IReadOnlyList<LayoutElementSnapshot> Elements { get; set; } = Array.Empty<LayoutElementSnapshot>();
}
